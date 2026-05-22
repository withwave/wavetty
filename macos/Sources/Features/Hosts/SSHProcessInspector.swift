import Darwin
import Foundation

/// Detects an `ssh user@host` invocation running directly in a terminal (i.e.
/// typed by the user, not launched via the command palette) by inspecting the
/// foreground process's argument vector. Lets Wavetty record/auto-add hosts the
/// user connects to manually.
enum SSHProcessInspector {
    /// Returns the argument vector of `pid` via `sysctl(KERN_PROCARGS2)`, or nil.
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // Layout: int32 argc, exec_path\0, \0-padding, argv[0]\0 ... argv[argc-1]\0, env...
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            dst.copyBytes(from: buffer[0..<MemoryLayout<Int32>.size])
        }
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }   // skip exec path
        while index < size && buffer[index] == 0 { index += 1 }   // skip null padding

        var args: [String] = []
        var current: [UInt8] = []
        while index < size && args.count < Int(argc) {
            let byte = buffer[index]
            if byte == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
            index += 1
        }
        return args.isEmpty ? nil : args
    }

    /// If `args` is an `ssh` invocation, returns a `user@host[:port]` URI string
    /// (parseable by `SSHURIParser`). Returns nil for anything else.
    static func sshURI(from args: [String]) -> String? {
        guard let program = args.first,
              (program as NSString).lastPathComponent == "ssh" else { return nil }

        // ssh single-letter options that consume the next argument.
        let valueOptions: Set<Character> = [
            "B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l",
            "m", "O", "o", "P", "p", "Q", "R", "S", "W", "w",
        ]

        var user: String?
        var port: Int?
        var host: String?

        var i = 1
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("-") && arg.count >= 2 {
                let flag = arg[arg.index(arg.startIndex, offsetBy: 1)]
                if arg.count > 2 && valueOptions.contains(flag) {
                    let value = String(arg.dropFirst(2))      // attached, e.g. -p2244
                    if flag == "p" { port = Int(value) }
                    if flag == "l" { user = value }
                } else if valueOptions.contains(flag) {
                    i += 1                                      // value is the next arg
                    if i < args.count {
                        if flag == "p" { port = Int(args[i]) }
                        if flag == "l" { user = args[i] }
                    }
                }
                // else: boolean flag (e.g. -t, -v), ignore
                i += 1
                continue
            }
            // First positional argument is [user@]host; the rest is a remote command.
            host = arg
            break
        }

        guard var h = host, !h.isEmpty else { return nil }
        if let at = h.firstIndex(of: "@") {
            user = String(h[..<at])
            h = String(h[h.index(after: at)...])
        }
        guard !h.isEmpty else { return nil }

        var uri = ""
        if let user, !user.isEmpty { uri += "\(user)@" }
        uri += h
        if let port { uri += ":\(port)" }
        return uri
    }
}
