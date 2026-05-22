import Foundation

/// Stores per-host SSH passwords in the macOS login Keychain (encrypted at
/// rest). Uses the `security` CLI for both write and read so the askpass
/// helper — which also shells out to `security` — can read the item without a
/// GUI authorization prompt.
///
/// Note: SSH keys are more secure and should be preferred. This exists for
/// password-only hosts where the user explicitly opts in.
enum SSHKeychain {
    static let service = "com.modincompany.wavetty.ssh-password"

    @discardableResult
    private static func security(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return (-1, "") }
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, text)
    }

    /// Stores (or updates) the password for an alias. `-T /usr/bin/security`
    /// trusts the security tool itself so later reads don't prompt.
    static func set(password: String, for alias: String) {
        security([
            "add-generic-password", "-U",
            "-s", service, "-a", alias,
            "-w", password,
            "-T", "/usr/bin/security",
        ])
    }

    static func password(for alias: String) -> String? {
        let result = security(["find-generic-password", "-s", service, "-a", alias, "-w"])
        return (result.status == 0 && !result.output.isEmpty) ? result.output : nil
    }

    static func hasPassword(for alias: String) -> Bool {
        security(["find-generic-password", "-s", service, "-a", alias]).status == 0
    }

    static func remove(for alias: String) {
        security(["delete-generic-password", "-s", service, "-a", alias])
    }
}
