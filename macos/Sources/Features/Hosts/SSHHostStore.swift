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

    /// Patch metadata for a host. Creates an entry if missing.
    func updateMetadata(_ alias: String, _ transform: (inout SSHHostMetadata) -> Void) {
        var m = metadata[alias] ?? SSHHostMetadata()
        transform(&m)
        metadata[alias] = m
        SSHHostMetadataStore.save(metadata)
        rebuild()
    }

    /// Adds a host with explicit fields (from the manager UI's Add form).
    @discardableResult
    func addHost(
        alias: String,
        hostName: String,
        user: String?,
        port: Int?,
        identityFile: String?,
        proxyJump: String?,
        group: String?
    ) throws -> SSHHost {
        guard !alias.isEmpty, alias.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else {
            throw NSError(domain: "Wavetty.SSH", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid alias: must contain only letters, digits, '.', '_', '-'"])
        }
        guard !hosts.contains(where: { $0.alias == alias }) else {
            throw NSError(domain: "Wavetty.SSH", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Alias '\(alias)' already exists"])
        }
        let entry = SSHConfigEntry(
            alias: alias,
            hostName: hostName,
            user: user?.isEmpty == false ? user : nil,
            port: port,
            identityFile: identityFile?.isEmpty == false ? identityFile : nil,
            proxyJump: proxyJump?.isEmpty == false ? proxyJump : nil
        )
        try SSHConfigParser.appendHost(entry)
        metadata[alias] = SSHHostMetadata(group: group, autoAdded: false)
        SSHHostMetadataStore.save(metadata)
        reload()
        return hosts.first(where: { $0.alias == alias })
            ?? SSHHost(alias: alias, config: entry, metadata: metadata[alias]!)
    }

    /// Removes a host's ssh_config block AND metadata. Caller must confirm
    /// with the user first — this is destructive on user-curated entries.
    func removeHost(alias: String) throws {
        try SSHConfigParser.removeHost(alias: alias)
        metadata.removeValue(forKey: alias)
        SSHHostMetadataStore.save(metadata)
        reload()
    }

    // MARK: - Connect

    /// Opens a new tab (or new window) running `ssh <alias>` directly as
    /// the surface's command.
    func connect(_ host: SSHHost) {
        _ = open(host, inNewWindow: false)
    }

    /// Opens `ssh <alias>` as a surface command, in a new tab or a new window.
    /// Returns the controller so callers can position the window. Records the
    /// connection and registers the window as an SSH window for frame tracking.
    @discardableResult
    func open(_ host: SSHHost, inNewWindow: Bool) -> TerminalController? {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "ssh \(host.alias)"
        config.waitAfterCommand = true

        // If a password is stored for this host, set up Keychain-backed
        // SSH_ASKPASS so ssh auto-fills it.
        if let env = SSHAskpass.environment(for: host.alias) {
            for (key, value) in env { config.environmentVariables[key] = value }
        }

        let parent = NSApp.keyWindow
        let controller: TerminalController?
        if inNewWindow {
            controller = TerminalController.newWindow(appDelegate.ghostty, withBaseConfig: config, withParent: parent)
        } else if let tab = TerminalController.newTab(appDelegate.ghostty, from: parent, withBaseConfig: config) {
            controller = tab
        } else {
            controller = TerminalController.newWindow(appDelegate.ghostty, withBaseConfig: config, withParent: parent)
        }

        recordConnection(host.alias)
        // Capture the session shortly after the ssh process is up so a quick
        // force-kill still records it (the periodic sweep also covers this).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            SessionHistoryStore.shared.captureNow()
        }
        return controller
    }

    /// Convenience: connect by alias string. Returns true if connected.
    @discardableResult
    func connect(alias: String) -> Bool {
        guard let host = hosts.first(where: { $0.alias == alias }) else { return false }
        connect(host)
        return true
    }

    /// Open by alias in a new window. Returns the controller, or nil if the
    /// alias is unknown.
    func open(alias: String, inNewWindow: Bool) -> TerminalController? {
        guard let host = hosts.first(where: { $0.alias == alias }) else { return nil }
        return open(host, inNewWindow: inNewWindow)
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
