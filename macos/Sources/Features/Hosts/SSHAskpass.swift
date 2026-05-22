import Foundation

/// Wires up SSH password auto-entry via the `SSH_ASKPASS` mechanism backed by
/// the Keychain. When a host has a stored password, connecting sets the
/// environment so `ssh` invokes our helper script, which fetches the password
/// from the Keychain (see `SSHKeychain`) and feeds it to ssh — no manual typing.
enum SSHAskpass {
    /// Writes (once) the askpass helper script and returns its path. The helper
    /// reads the password for `$WAVETTY_SSH_ALIAS` from the Keychain via the
    /// `security` tool.
    static func helperPath() -> String? {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.modincompany.wavetty"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ssh-askpass.sh")

        let script = """
        #!/bin/sh
        # Wavetty SSH askpass helper. Invoked by ssh to obtain a password.
        exec /usr/bin/security find-generic-password \
        -s "\(SSHKeychain.service)" -a "$WAVETTY_SSH_ALIAS" -w 2>/dev/null
        """

        // Rewrite each time so the script stays in sync with the app.
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    /// Environment variables to attach to an `ssh` surface so it auto-fills the
    /// stored password, or nil if no password is stored for this alias.
    static func environment(for alias: String) -> [String: String]? {
        guard SSHKeychain.hasPassword(for: alias), let helper = helperPath() else { return nil }
        return [
            "SSH_ASKPASS": helper,
            // OpenSSH 8.4+: use askpass even when a TTY is present.
            "SSH_ASKPASS_REQUIRE": "force",
            // Older ssh required DISPLAY to be set before consulting askpass.
            "DISPLAY": ":0",
            "WAVETTY_SSH_ALIAS": alias,
        ]
    }
}
