import AppKit
import Foundation

/// Combined view of an SSH host: config entry from `~/.ssh/config` plus
/// Wavetty's sidecar metadata.
struct SSHHost: Identifiable, Equatable {
    let alias: String
    let config: SSHConfigEntry
    var metadata: SSHHostMetadata

    var id: String { alias }

    /// Human-readable target like `pss@new.domain.com:2244`.
    var displayHost: String {
        let h = config.hostName ?? alias
        let u = config.user.map { "\($0)@" } ?? ""
        let p = config.port.map { ":\($0)" } ?? ""
        return "\(u)\(h)\(p)"
    }
}

/// Single source of truth for SSH host operations. Reads `~/.ssh/config`
/// and the sidecar metadata, exposes connect/add/update APIs.
@MainActor
final class SSHHostStore: ObservableObject {
    static let shared = SSHHostStore()

    @Published private(set) var hosts: [SSHHost] = []

    private var metadata: [String: SSHHostMetadata] = [:]
    private var configEntries: [SSHConfigEntry] = []

    private init() {
        reload()
    }

    func reload() {
        configEntries = SSHConfigParser.parse()
        metadata = SSHHostMetadataStore.load()
        rebuild()
    }

    private func rebuild() {
        hosts = configEntries.map { entry in
            SSHHost(alias: entry.alias, config: entry, metadata: metadata[entry.alias] ?? SSHHostMetadata())
        }
    }

    // MARK: - Query

    func suggestions(for query: String, limit: Int = 20) -> [SSHHost] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let scored: [(SSHHost, Int)] = hosts.map { host in
            (host, score(host: host, query: q))
        }
        return scored
            .filter { $0.1 >= 0 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.alias.localizedCaseInsensitiveCompare(rhs.0.alias) == .orderedAscending
            }
            .prefix(limit)
            .map { $0.0 }
    }

    private func score(host: SSHHost, query q: String) -> Int {
        var s = 0
        if host.metadata.pinned { s += 1000 }
        if let last = host.metadata.lastConnected {
            let hours = Date().timeIntervalSince(last) / 3600
            if hours < 24 { s += 100 - Int(hours * 2) }
            else if hours < 24 * 7 { s += 50 - Int(hours / 24) * 5 }
        }
        s += min(host.metadata.useCount * 2, 50)

        guard !q.isEmpty else { return s }

        let aliasLower = host.alias.lowercased()
        let hostLower = (host.config.hostName ?? "").lowercased()
        if aliasLower == q { s += 500 }
        else if aliasLower.hasPrefix(q) { s += 300 }
        else if aliasLower.contains(q) { s += 200 }
        else if hostLower.contains(q) { s += 100 }
        else { return -1 }
        return s
    }

    /// Returns existing host matching a parsed URI by content, if any.
    func existingMatch(for uri: SSHURIParser.Parsed) -> SSHHost? {
        if let explicit = uri.explicitAlias,
           let h = hosts.first(where: { $0.alias == explicit }) { return h }
        return hosts.first { h in
            (h.config.hostName ?? h.alias) == uri.host &&
            (h.config.user ?? "") == (uri.user ?? "") &&
            (h.config.port ?? 22) == (uri.port ?? 22)
        }
    }

    // MARK: - Mutate

    /// Generates an alias that doesn't collide with existing ones.
    func generateAlias(host: String, user: String?, port: Int?) -> String {
        let existing = Set(hosts.map { $0.alias })
        if !existing.contains(host) { return host }
        let userHost = user.map { "\($0)-\(host)" } ?? host
        if !existing.contains(userHost) { return userHost }
        let withPort = "\(userHost)-\(port ?? 22)"
        if !existing.contains(withPort) { return withPort }
        // Last-resort suffix counter
        var i = 2
        while existing.contains("\(withPort)-\(i)") { i += 1 }
        return "\(withPort)-\(i)"
    }

    /// Parses a freeform URI, appends a new Host block to `~/.ssh/config`,
    /// writes metadata, and reloads.
    @discardableResult
    func addFromURI(_ uri: String) throws -> SSHHost {
        guard let parsed = SSHURIParser.parse(uri) else {
            throw NSError(domain: "Wavetty.SSH", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid SSH target: \(uri)"])
        }
        if let existing = existingMatch(for: parsed) { return existing }
        let alias = parsed.explicitAlias ?? generateAlias(host: parsed.host, user: parsed.user, port: parsed.port)
        let entry = SSHConfigEntry(
            alias: alias,
            hostName: parsed.host,
            user: parsed.user,
            port: parsed.port
        )
        try SSHConfigParser.appendHost(entry)
        metadata[alias] = SSHHostMetadata(autoAdded: true)
        SSHHostMetadataStore.save(metadata)
        reload()
        return hosts.first(where: { $0.alias == alias })
            ?? SSHHost(alias: alias, config: entry, metadata: metadata[alias]!)
    }

    func recordConnection(_ alias: String) {
        var m = metadata[alias] ?? SSHHostMetadata()
        m.lastConnected = Date()
        m.useCount += 1
        metadata[alias] = m
        SSHHostMetadataStore.save(metadata)
        rebuild()
    }

    // MARK: - Connect

    /// Opens a new tab (or new window) running `ssh <alias>` directly as
    /// the surface's command.
    func connect(_ host: SSHHost) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "ssh \(host.alias)"
        config.waitAfterCommand = true

        let parent = NSApp.keyWindow
        if TerminalController.newTab(appDelegate.ghostty, from: parent, withBaseConfig: config) == nil {
            _ = TerminalController.newWindow(appDelegate.ghostty, withBaseConfig: config, withParent: parent)
        }
        recordConnection(host.alias)
    }

    /// Convenience: connect by alias string. Returns true if connected.
    @discardableResult
    func connect(alias: String) -> Bool {
        guard let host = hosts.first(where: { $0.alias == alias }) else { return false }
        connect(host)
        return true
    }

    /// Connect from a freeform URI: reuse existing host if found, otherwise add new.
    @discardableResult
    func connect(uri: String) -> Bool {
        guard let parsed = SSHURIParser.parse(uri) else { return false }
        if let existing = existingMatch(for: parsed) {
            connect(existing)
            return true
        }
        guard let added = try? addFromURI(uri) else { return false }
        connect(added)
        return true
    }
}
