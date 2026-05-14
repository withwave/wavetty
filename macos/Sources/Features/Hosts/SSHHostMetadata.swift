import Foundation

/// Wavetty-specific per-host metadata that lives next to (not inside)
/// `~/.ssh/config`. Keyed by Host alias in a sidecar JSON file.
struct SSHHostMetadata: Codable, Equatable {
    var lastConnected: Date?
    var useCount: Int
    var tags: [String]
    var group: String?
    var note: String?
    var autoAdded: Bool
    var addedAt: Date
    var pinned: Bool

    init(
        lastConnected: Date? = nil,
        useCount: Int = 0,
        tags: [String] = [],
        group: String? = nil,
        note: String? = nil,
        autoAdded: Bool = false,
        addedAt: Date = Date(),
        pinned: Bool = false
    ) {
        self.lastConnected = lastConnected
        self.useCount = useCount
        self.tags = tags
        self.group = group
        self.note = note
        self.autoAdded = autoAdded
        self.addedAt = addedAt
        self.pinned = pinned
    }
}

/// Disk-backed store for `[alias: SSHHostMetadata]`.
enum SSHHostMetadataStore {
    static var storeURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.modincompany.wavetty"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hosts-metadata.json")
    }

    static func load() -> [String: SSHHostMetadata] {
        guard let data = try? Data(contentsOf: storeURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: SSHHostMetadata].self, from: data)) ?? [:]
    }

    static func save(_ dict: [String: SSHHostMetadata]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(dict) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
