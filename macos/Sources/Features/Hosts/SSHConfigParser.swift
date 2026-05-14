import Foundation

/// One parsed `Host` block from `~/.ssh/config`.
struct SSHConfigEntry: Equatable {
    var alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFile: String?
    var proxyJump: String?
}

/// Reads and appends entries to `~/.ssh/config`.
///
/// Reading is best-effort: keys that aren't `Host` / `HostName` / `User` /
/// `Port` / `IdentityFile` / `ProxyJump` are ignored. Wildcard patterns
/// (`*`, `?`, `!`) are skipped from the returned list — they're not
/// connectable targets.
///
/// Writing is append-only: new `Host` blocks are added at the end with a
/// timestamp header. Existing blocks are never modified.
enum SSHConfigParser {
    static var configPath: String {
        NSString(string: "~/.ssh/config").expandingTildeInPath
    }

    static func parse() -> [SSHConfigEntry] {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return []
        }
        return parse(content: content)
    }

    static func parse(content: String) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var current: SSHConfigEntry? = nil

        for rawLine in content.components(separatedBy: "\n") {
            let stripped = rawLine.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped.hasPrefix("#") { continue }

            // Split key + value. ssh_config uses `Key Value` or `Key=Value`.
            let normalized = stripped.replacingOccurrences(of: "=", with: " ")
            let parts = normalized.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)

            if key == "host" {
                if let prev = current { entries.append(prev) }
                let firstAlias = value.split(separator: " ").first.map(String.init) ?? value
                if firstAlias.contains(where: { "*?!".contains($0) }) {
                    current = nil
                    continue
                }
                current = SSHConfigEntry(alias: firstAlias)
            } else {
                guard current != nil else { continue }
                switch key {
                case "hostname":     current!.hostName = value
                case "user":         current!.user = value
                case "port":         current!.port = Int(value)
                case "identityfile": current!.identityFile = value
                case "proxyjump":    current!.proxyJump = value
                default: break
                }
            }
        }
        if let last = current { entries.append(last) }
        return entries
    }

    /// Appends a host block to `~/.ssh/config`. Creates the file (and
    /// `~/.ssh/` dir) with safe permissions if missing.
    static func appendHost(_ entry: SSHConfigEntry) throws {
        let path = configPath
        let dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default

        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        var block = "\n# Added by Wavetty \(timestamp)\n"
        block += "Host \(entry.alias)\n"
        block += "    HostName \(entry.hostName ?? entry.alias)\n"
        if let u = entry.user         { block += "    User \(u)\n" }
        if let p = entry.port         { block += "    Port \(p)\n" }
        if let k = entry.identityFile { block += "    IdentityFile \(k)\n" }
        if let j = entry.proxyJump    { block += "    ProxyJump \(j)\n" }

        if fm.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = block.data(using: .utf8) { try handle.write(contentsOf: data) }
        } else {
            try block.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    /// Removes a Host block from `~/.ssh/config`. Only blocks where the first
    /// `Host` pattern token matches `alias` exactly are removed. The directly
    /// preceding "# Added by Wavetty" comment (if any) is also stripped.
    ///
    /// To avoid silently destroying user-curated entries, the caller is
    /// expected to confirm with the user before invoking this.
    static func removeHost(alias: String) throws {
        let path = configPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        let content = try String(contentsOfFile: path, encoding: .utf8)

        // Always end with newline for line-oriented slicing.
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var output: [String] = []
        var inMatchingBlock = false
        var pendingCommentIdx: Int? = nil

        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            let isHostLine = stripped.lowercased().hasPrefix("host ") || stripped.lowercased() == "host"

            if isHostLine {
                // Starting a new block. Pop pending comment unless we're about to
                // delete this block (in which case drop the "Added by Wavetty" too).
                let normalized = stripped.replacingOccurrences(of: "=", with: " ")
                let parts = normalized.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                let firstAlias = parts.count >= 2
                    ? (parts[1].split(separator: " ").first.map(String.init) ?? "")
                    : ""

                if firstAlias == alias {
                    inMatchingBlock = true
                    // Drop pending comment if it looks like a Wavetty marker.
                    if let idx = pendingCommentIdx {
                        let comment = output[idx].trimmingCharacters(in: .whitespaces)
                        if comment.hasPrefix("# Added by Wavetty") {
                            output.remove(at: idx)
                        }
                    }
                    pendingCommentIdx = nil
                    continue
                } else {
                    inMatchingBlock = false
                    pendingCommentIdx = nil
                    output.append(line)
                    continue
                }
            }

            if inMatchingBlock {
                // Inside the block we're removing — skip everything until next Host.
                // But if we hit a blank line, that ends the block content;
                // also skip that blank to avoid leaving double blanks.
                if stripped.isEmpty {
                    inMatchingBlock = false
                }
                continue
            }

            // Track comment lines so we can drop "# Added by Wavetty <ts>" if it
            // immediately precedes the block we're deleting.
            if stripped.hasPrefix("#") {
                pendingCommentIdx = output.count
            } else if !stripped.isEmpty {
                pendingCommentIdx = nil
            }
            output.append(line)
        }

        // Collapse runs of 3+ blank lines down to 2 (cosmetic).
        var cleaned: [String] = []
        var blankRun = 0
        for line in output {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun <= 2 { cleaned.append(line) }
            } else {
                blankRun = 0
                cleaned.append(line)
            }
        }

        let newContent = cleaned.joined(separator: "\n") + "\n"
        // Atomic write
        let tmpURL = URL(fileURLWithPath: path).appendingPathExtension("wavetty-tmp")
        try newContent.write(to: tmpURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: tmpURL)
    }
}
