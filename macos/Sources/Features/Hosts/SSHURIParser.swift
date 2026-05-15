import Foundation

/// Parses Wavetty's shorthand SSH URI syntax (not the standard ssh:// URI).
///
/// Accepted forms:
///   * `host`
///   * `user@host`
///   * `user@host:port`
///   * `host:port`
///   * `[::1]:port`           IPv6 with optional port
///   * `... as alias`         Trailing alias hint
enum SSHURIParser {
    struct Parsed: Equatable {
        var user: String?
        var host: String
        var port: Int?
        var explicitAlias: String?
    }

    /// Compile regex once at static-init time. NSRegularExpression compilation
    /// (ICU) is ~ms-scale on Intel Macs and we're called on every palette
    /// keystroke, so caching is worth it.
    private static let uriRegex: NSRegularExpression = {
        let pattern = #"^(?:([^@\s]+)@)?(\[[^\]]+\]|[^\s:]+)(?::(\d+))?$"#
        // Pattern is constant and known-valid; force-unwrap.
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let aliasSuffixRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\s+as\s+([^\s]+)\s*$"#)
    }()

    /// Returns nil if input doesn't match the shorthand grammar.
    static func parse(_ input: String) -> Parsed? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Split off " as <alias>" if present.
        var body = trimmed
        var alias: String? = nil
        let fullRange = NSRange(trimmed.startIndex..., in: trimmed)
        if let m = aliasSuffixRegex.firstMatch(in: trimmed, range: fullRange),
           let aliasRange = Range(m.range(at: 1), in: trimmed),
           let cutRange = Range(m.range, in: trimmed) {
            alias = String(trimmed[aliasRange])
            body = String(trimmed[..<cutRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        let range = NSRange(body.startIndex..., in: body)
        guard let m = uriRegex.firstMatch(in: body, range: range) else { return nil }

        var user: String? = nil
        if let r = Range(m.range(at: 1), in: body), !body[r].isEmpty {
            user = String(body[r])
        }
        guard let hostRange = Range(m.range(at: 2), in: body) else { return nil }
        var host = String(body[hostRange])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        var port: Int? = nil
        if let r = Range(m.range(at: 3), in: body), let p = Int(body[r]), p > 0, p <= 65535 {
            port = p
        }

        // Validate alias chars
        if let a = alias, !a.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) {
            alias = nil
        }

        return Parsed(user: user, host: host, port: port, explicitAlias: alias)
    }
}
