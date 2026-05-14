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

    /// Returns nil if input doesn't match the shorthand grammar.
    static func parse(_ input: String) -> Parsed? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Split off " as <alias>" if present.
        var body = trimmed
        var alias: String? = nil
        if let asRange = trimmed.range(of: #"\s+as\s+([^\s]+)\s*$"#, options: .regularExpression) {
            let aliasPart = trimmed[asRange]
            // Extract alias token after "as "
            let tokens = aliasPart.split(separator: " ", omittingEmptySubsequences: true)
            if let last = tokens.last { alias = String(last) }
            body = String(trimmed[..<asRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        // Grammar: [user@]host[:port]   host may be [IPv6] or plain
        let pattern = #"^(?:([^@\s]+)@)?(\[[^\]]+\]|[^\s:]+)(?::(\d+))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        guard let m = regex.firstMatch(in: body, range: range) else { return nil }

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
