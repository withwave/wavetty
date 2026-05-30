import AppKit
import Foundation
import GhosttyKit

/// Reads and writes Ghostty's `key = value` config file for Wavetty's GUI
/// settings form. We deliberately keep this minimal and line-oriented (like
/// SSHConfigParser): we only touch the specific keys the form manages and
/// preserve every other line — including comments and hand-written keybinds —
/// so a user's existing config is never reformatted or lost.
@MainActor
final class WavettyConfigStore: ObservableObject {
    static let shared = WavettyConfigStore()

    /// Absolute path to the active config file (created on first save if absent).
    let path: String

    /// Parsed `key -> value` for the keys present in the file.
    @Published private(set) var values: [String: String] = [:]

    private init() {
        path = Ghostty.AllocatedString(ghostty_config_open_path()).string
        reload()
    }

    func reload() {
        values = Self.parse(path)
    }

    /// Current value for a key as written in the file (empty string if unset).
    func value(_ key: String) -> String { values[key] ?? "" }

    private static func parse(_ path: String) -> [String: String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = val }
        }
        return result
    }

    /// Sets (or, when `value` is empty, removes) a single key in the config
    /// file, preserving all other lines, then reloads Ghostty's config so the
    /// change applies live. Returns false on write failure.
    @discardableResult
    func setValue(_ key: String, _ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        var lines = (try? String(contentsOfFile: path, encoding: .utf8))?
            .components(separatedBy: "\n") ?? []

        var replaced = false
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty || !line.contains("=") { i += 1; continue }
            let k = String(line[..<line.firstIndex(of: "=")!]).trimmingCharacters(in: .whitespaces)
            if k == key {
                if trimmed.isEmpty {
                    lines.remove(at: i)
                    replaced = true
                    continue
                }
                lines[i] = "\(key) = \(trimmed)"
                replaced = true
            }
            i += 1
        }

        if !replaced && !trimmed.isEmpty {
            if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            lines.append("\(key) = \(trimmed)")
        }

        // Ensure the parent directory exists (config file may not exist yet).
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        let output = lines.joined(separator: "\n")
        guard (try? output.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return false
        }

        reload()
        (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
        return true
    }
}
