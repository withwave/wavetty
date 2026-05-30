import AppKit
import Foundation
import GhosttyKit

/// Screen frame of a window, so reopening restores its last position and size.
struct WindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// One terminal surface (a leaf of a split tree): either a local shell in a
/// directory, or an SSH session by alias.
struct SessionLeaf: Codable, Equatable {
    var workingDirectory: String?
    var sshAlias: String?
    /// Path to a file holding this surface's color-preserving (VT/SGR)
    /// scrollback, captured so a reopened session shows its prior output.
    var scrollbackFile: String?
}

enum SplitDir: String, Codable { case horizontal, vertical }

/// Mirror of `SplitTree.Node` reduced to what we need to persist & rebuild:
/// the split structure plus each leaf's directory/host.
indirect enum SessionNode: Codable, Equatable {
    case leaf(SessionLeaf)
    case split(direction: SplitDir, ratio: Double, left: SessionNode, right: SessionNode)

    /// The left-most leaf, used for a window's display label.
    var firstLeaf: SessionLeaf? {
        switch self {
        case .leaf(let l): return l
        case .split(_, _, let left, _): return left.firstLeaf
        }
    }

    /// Frame-independent structural signature (dirs / ssh / split layout) used
    /// to dedup windows with identical content.
    var signature: String {
        switch self {
        case .leaf(let l):
            return l.sshAlias.map { "ssh:\($0)" } ?? (l.workingDirectory ?? "∅")
        case .split(let dir, _, let left, let right):
            return "(\(dir.rawValue) \(left.signature) \(right.signature))"
        }
    }
}

/// A single tab within a window: its split tree.
struct SessionTab: Codable, Equatable {
    var root: SessionNode
}

/// A whole terminal window captured for restoration: its tabs (each with
/// splits), in order, plus the window frame. Reopening rebuilds the entire
/// window — tabs, splits, directories, and SSH reconnects — at its last
/// position and size.
struct RecentWindow: Codable, Equatable {
    var id: UUID
    var lastUsed: Date
    var frame: WindowFrame?
    var tabs: [SessionTab]

    /// Menu label: first tab's first leaf, plus a tab count when there's more
    /// than one tab.
    var displayName: String {
        let base: String
        switch tabs.first?.root.firstLeaf {
        case .some(let leaf) where leaf.sshAlias != nil:
            base = "ssh \(leaf.sshAlias!)"
        case .some(let leaf) where leaf.workingDirectory != nil:
            let abbreviated = (leaf.workingDirectory! as NSString).abbreviatingWithTildeInPath
            base = abbreviated.isEmpty ? leaf.workingDirectory! : abbreviated
        default:
            base = "Terminal"
        }
        return tabs.count > 1 ? "\(base)  (+\(tabs.count - 1) tabs)" : base
    }

    /// Whether the first leaf is an SSH session (for the menu icon).
    var isSSH: Bool { tabs.first?.root.firstLeaf?.sshAlias != nil }

    /// Frame-independent content signature: same tabs/dirs/splits/hosts collapse
    /// to one entry regardless of window position or which launch produced it.
    var signature: String {
        tabs.map { $0.root.signature }.joined(separator: " ⇥ ")
    }
}

/// Single source of truth for Wavetty's recent-window history. Snapshots open
/// windows (tabs + splits + frame) periodically and at termination so a closed
/// window — or a force-killed app — can still be reopened from the Dock menu.
///
/// This is **not** macOS state restoration (we keep `window-save-state =
/// default`, so a clean quit doesn't auto-reopen). It's a deliberate "recents"
/// list the user picks from.
@MainActor
final class SessionHistoryStore: ObservableObject {
    static let shared = SessionHistoryStore()

    /// Cap on retained windows (LRU eviction beyond this).
    static let maxEntries = 16

    @Published private(set) var recentWindows: [RecentWindow] = []

    private init() {
        recentWindows = Self.load()

        // Capture only on real events — no periodic sweep. Dumping scrollback
        // is not cheap, and the events below cover every case the user cares
        // about: closing a tab/window, an ssh disconnect (child exit), losing
        // key focus (switching away), and app termination. Only an app crash /
        // SIGKILL escapes these, which is rare.
        let nc = NotificationCenter.default
        nc.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
        nc.addObserver(
            self, selector: #selector(appWillTerminate(_:)),
            name: NSApplication.willTerminateNotification, object: nil)
        nc.addObserver(
            self, selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil)
        // Capture the moment a child process exits (e.g. ssh disconnect) so the
        // session's final screen is saved before it's gone.
        nc.addObserver(
            self, selector: #selector(childDidExit(_:)),
            name: .wavettyChildExited, object: nil)
    }

    // MARK: - Recording

    @objc private func windowWillClose(_ note: Notification) {
        // The closing window's last good snapshot already lives in the list
        // (from the periodic sweep); just refresh whatever remains open. We
        // never delete entries on close, so the closed window stays reopenable.
        sweepAllWindows()
    }

    @objc private func appWillTerminate(_ note: Notification) {
        sweepAllWindows()
    }

    @objc private func windowDidResignKey(_ note: Notification) {
        sweepAllWindows()
    }

    @objc private func childDidExit(_ note: Notification) {
        // The surface still holds its final screen at this point (ghostty keeps
        // the surface alive to show "[process exited]"), so capturing now grabs
        // the last output — e.g. everything up to an ssh disconnect.
        sweepAllWindows()
    }

    /// Snapshot all open terminal windows immediately (used right after an SSH
    /// connect so it's persisted without waiting for the next sweep).
    func captureNow() {
        sweepAllWindows()
    }

    /// Groups open terminal windows by tab group and snapshots each group.
    private func sweepAllWindows() {
        var groups: [ObjectIdentifier: NSWindow] = [:]
        var order: [ObjectIdentifier] = []
        for window in NSApp.windows {
            guard window.windowController is TerminalController else { continue }
            let repObject: AnyObject = window.tabGroup ?? window
            let key = ObjectIdentifier(repObject)
            if groups[key] == nil {
                groups[key] = window
                order.append(key)
            }
        }

        var changed = false
        for key in order {
            if snapshotGroup(anyWindow: groups[key]!, save: false) { changed = true }
        }
        if changed { Self.save(recentWindows) }
    }

    /// Snapshots one window/tab-group into a single `RecentWindow` entry.
    @discardableResult
    private func snapshotGroup(anyWindow: NSWindow, save: Bool) -> Bool {
        // Ordered tab windows (a single window has no tabGroup or a group of one).
        let tabWindows: [NSWindow]
        if let group = anyWindow.tabGroup {
            tabWindows = group.windows.filter { $0.windowController is TerminalController }
        } else {
            tabWindows = [anyWindow]
        }
        guard let frameWindow = tabWindows.first else { return false }

        var tabs: [SessionTab] = []
        for window in tabWindows {
            guard let controller = window.windowController as? TerminalController,
                  let root = controller.surfaceTree.root else { continue }
            tabs.append(SessionTab(root: captureNode(root)))
        }
        guard !tabs.isEmpty else { return false }

        let entry = RecentWindow(
            id: UUID(), lastUsed: Date(), frame: WindowFrame(frameWindow.frame), tabs: tabs)
        return upsert(entry, save: save)
    }

    /// Walks a live split-tree node into our serializable `SessionNode`.
    private func captureNode(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> SessionNode {
        switch node {
        case .leaf(let view):
            var leaf = SessionLeaf()
            if let alias = sshAlias(of: view) {
                leaf.sshAlias = alias
            } else if let dir = effectivePwd(of: view), isLocalDirectory(dir) {
                leaf.workingDirectory = dir
            }
            // Capture color-preserving scrollback to a deterministic file (keyed
            // by host/dir) so the same session overwrites in place rather than
            // accumulating files. Only when there's something to identify it by.
            if let key = scrollbackKey(for: leaf), let surface = view.surface {
                if let text = dumpScrollbackStyled(surface), !text.isEmpty {
                    let file = Self.scrollbackPath(key: key)
                    if (try? text.write(toFile: file, atomically: true, encoding: .utf8)) != nil {
                        leaf.scrollbackFile = file
                    }
                }
            }
            return .leaf(leaf)
        case .split(let split):
            return .split(
                direction: split.direction == .horizontal ? .horizontal : .vertical,
                ratio: split.ratio,
                left: captureNode(split.left),
                right: captureNode(split.right))
        }
    }

    private func isLocalDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Scrollback capture

    /// Color-preserving (VT/SGR) scrollback text for a surface, or nil if empty.
    private func dumpScrollbackStyled(_ surface: ghostty_surface_t) -> String? {
        let text = Ghostty.AllocatedString(ghostty_surface_dump_scrollback_styled(surface)).string
        return text.isEmpty ? nil : text
    }

    /// A stable filename key for a leaf, so the same host/dir overwrites in
    /// place. nil when the leaf has nothing identifying to key on.
    private func scrollbackKey(for leaf: SessionLeaf) -> String? {
        if let alias = leaf.sshAlias { return "ssh-\(alias)" }
        if let dir = leaf.workingDirectory { return "dir-\(dir)" }
        return nil
    }

    private static var scrollbackDir: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.modincompany.wavetty"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("scrollback", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private static func scrollbackPath(key: String) -> String {
        let safe = key.map { ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "_" }
        return (scrollbackDir as NSString).appendingPathComponent(String(safe) + ".ansi")
    }


    /// If the surface's foreground process is `ssh user@host`, returns the
    /// ssh_config alias for it — adding the host to `~/.ssh/config` if needed,
    /// the same way the command-palette "Add & Connect" flow does. This is what
    /// makes a host the user typed `ssh ...` for directly in the terminal show
    /// up in the SSH manager and the recent-windows list.
    private func sshAlias(of view: Ghostty.SurfaceView) -> String? {
        guard let surface = view.surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        guard pid != 0,
              let args = SSHProcessInspector.arguments(of: Int32(truncatingIfNeeded: pid)),
              let uri = SSHProcessInspector.sshURI(from: args),
              let parsed = SSHURIParser.parse(uri) else { return nil }

        if let existing = SSHHostStore.shared.existingMatch(for: parsed) {
            return existing.alias
        }
        return (try? SSHHostStore.shared.addFromURI(uri))?.alias
    }

    /// The surface's working directory: OSC 7 value, else queried from the
    /// foreground process via libghostty.
    private func effectivePwd(of surfaceView: Ghostty.SurfaceView) -> String? {
        if let p = surfaceView.pwd, !p.isEmpty { return p }
        guard let handle = surfaceView.surface else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        let len = ghostty_surface_pwd(handle, &buf, 4096)
        return len > 0 ? String(cString: buf) : nil
    }

    /// Upserts a window entry deduped by content signature (so the same window
    /// across sweeps, restores, and app launches is one entry — not many). A
    /// bare timestamp bump on identical content is ignored to avoid disk churn;
    /// a moved window (changed frame) or changed layout moves it to the front
    /// and persists.
    @discardableResult
    private func upsert(_ entry: RecentWindow, save: Bool) -> Bool {
        let sig = entry.signature
        if let idx = recentWindows.firstIndex(where: { $0.signature == sig }) {
            let existing = recentWindows[idx]
            if existing.frame == entry.frame && existing.tabs == entry.tabs {
                recentWindows[idx].lastUsed = entry.lastUsed
                return false
            }
            // Same window, changed position/layout: keep its id, move to front.
            var updated = entry
            updated.id = existing.id
            recentWindows.remove(at: idx)
            recentWindows.insert(updated, at: 0)
            if save { Self.save(recentWindows) }
            return true
        }
        recentWindows.insert(entry, at: 0)
        if recentWindows.count > Self.maxEntries {
            recentWindows = Array(recentWindows.prefix(Self.maxEntries))
        }
        if save { Self.save(recentWindows) }
        return true
    }

    func clear() {
        recentWindows = []
        Self.save(recentWindows)
    }

    /// Migrates every ssh leaf in the saved windows from one alias to another,
    /// used when the user renames a host in the SSH manager.
    func renameSSH(from oldAlias: String, to newAlias: String) {
        guard oldAlias != newAlias else { return }
        var changed = false
        recentWindows = recentWindows.map { window in
            var updated = window
            updated.tabs = window.tabs.map { tab in
                var t = tab
                let (root, didChange) = Self.renameLeaves(t.root, from: oldAlias, to: newAlias)
                t.root = root
                if didChange { changed = true }
                return t
            }
            return updated
        }
        if changed { Self.save(recentWindows) }
    }

    private static func renameLeaves(_ node: SessionNode, from old: String, to new: String) -> (SessionNode, Bool) {
        switch node {
        case .leaf(var leaf):
            if leaf.sshAlias == old {
                leaf.sshAlias = new
                return (.leaf(leaf), true)
            }
            return (.leaf(leaf), false)
        case .split(let direction, let ratio, let left, let right):
            let (l, lc) = renameLeaves(left, from: old, to: new)
            let (r, rc) = renameLeaves(right, from: old, to: new)
            return (.split(direction: direction, ratio: ratio, left: l, right: r), lc || rc)
        }
    }

    // MARK: - Restore

    /// Reopens a window restored to its last position/size, rebuilding every
    /// tab and split. Local leaves cd into their directory; SSH leaves reconnect.
    func restore(_ window: RecentWindow) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let app = appDelegate.ghostty.app,
              !window.tabs.isEmpty else { return }

        // First tab becomes the primary window. A plain controller init does
        // not present its window (unlike newWindow/newTab which schedule it),
        // so we explicitly show + order front here.
        let firstTree = SplitTree(root: buildNode(window.tabs[0].root, app: app), zoomed: nil)
        let primary = TerminalController(appDelegate.ghostty, withSurfaceTree: firstTree)
        guard let primaryWindow = primary.window else { return }

        DispatchQueue.main.async {
            primary.showWindow(nil)
            primaryWindow.makeKeyAndOrderFront(nil)

            // Remaining tabs join the primary window's tab group.
            for tab in window.tabs.dropFirst() {
                let tree = SplitTree(root: self.buildNode(tab.root, app: app), zoomed: nil)
                let controller = TerminalController(appDelegate.ghostty, withSurfaceTree: tree)
                if let tabWindow = controller.window {
                    primaryWindow.addTabbedWindowSafely(tabWindow, ordered: .above)
                }
            }

            // Restore last position + size, then bring the app forward.
            if let frame = window.frame {
                primaryWindow.setFrame(frame.cgRect, display: true)
            }
            primaryWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            // Inject color scrollback + start ssh once surfaces attach.
            self.processPendingRestores()
        }
    }

    /// Per-surface work to run after a restored surface attaches: inject its
    /// color-preserving scrollback (no shell echo) and start ssh via stdin.
    private struct PendingRestore { var file: String?; var ssh: String? }
    private var pendingRestores: [UUID: PendingRestore] = [:]

    private func processPendingRestores() {
        let pending = pendingRestores
        pendingRestores.removeAll()
        for (uuid, info) in pending {
            injectRestore(uuid: uuid, info: info, attempts: 0)
        }
    }

    private func injectRestore(uuid: UUID, info: PendingRestore, attempts: Int) {
        guard let view = findSurfaceView(uuid), let surface = view.surface else {
            // Surface not attached yet; retry briefly (mirrors ghostty's own
            // restore polling).
            guard attempts < 40 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.injectRestore(uuid: uuid, info: info, attempts: attempts + 1)
            }
            return
        }

        if let file = info.file,
           let text = try? String(contentsOfFile: file, encoding: .utf8),
           !text.isEmpty {
            // Route through the VT parser so colors render; no PTY/shell echo.
            Self.writeStyled(surface, text)
            Self.writeStyled(surface, "\r\n\u{1b}[2m──── previous session ──── \u{1b}[0m\r\n")
        }

        if let ssh = info.ssh {
            // Send `ssh <host>` as if typed; the shell runs it (and the askpass
            // env we set makes it auto-login).
            Self.sendText(surface, "ssh \(ssh)\r")
        }
    }

    private func findSurfaceView(_ uuid: UUID) -> Ghostty.SurfaceView? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            for view in controller.surfaceTree where view.id == uuid { return view }
        }
        return nil
    }

    private static func writeStyled(_ surface: ghostty_surface_t, _ text: String) {
        text.withCString { ptr in
            ghostty_surface_write_styled_to_screen(surface, ptr, UInt(strlen(ptr)))
        }
    }

    private static func sendText(_ surface: ghostty_surface_t, _ text: String) {
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    /// Rebuilds a live split-tree node from a captured `SessionNode`.
    private func buildNode(_ node: SessionNode, app: ghostty_app_t) -> SplitTree<Ghostty.SurfaceView>.Node {
        switch node {
        case .leaf(let leaf):
            // Always open a plain shell. Scrollback injection (color-preserving,
            // no echo) and the ssh start happen AFTER the surface attaches —
            // see processPendingRestores. Doing it post-attach avoids echoing
            // any command into the screen (which previously got re-captured
            // into the scrollback, corrupting it).
            var config = Ghostty.SurfaceConfiguration()
            if let dir = leaf.workingDirectory {
                config.workingDirectory = dir
            }
            if let alias = leaf.sshAlias, let env = SSHAskpass.environment(for: alias) {
                // Carry Keychain askpass env so the ssh we start via stdin
                // auto-fills the stored password.
                for (k, v) in env { config.environmentVariables[k] = v }
            }

            let view = Ghostty.SurfaceView(app, baseConfig: config)
            if leaf.scrollbackFile != nil || leaf.sshAlias != nil {
                pendingRestores[view.id] = .init(file: leaf.scrollbackFile, ssh: leaf.sshAlias)
            }
            return .leaf(view: view)
        case .split(let direction, let ratio, let left, let right):
            return .split(.init(
                direction: direction == .horizontal ? .horizontal : .vertical,
                ratio: ratio,
                left: buildNode(left, app: app),
                right: buildNode(right, app: app)))
        }
    }

    // MARK: - Persistence

    private static var storeURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.modincompany.wavetty"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recent-windows.json")
    }

    private static func load() -> [RecentWindow] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = (try? dec.decode([RecentWindow].self, from: data)) ?? []
        // Collapse any historical duplicates (older files predate signature
        // dedup). Stored most-recent-first, so keep the first of each signature.
        var seen = Set<String>()
        return decoded.filter { seen.insert($0.signature).inserted }
    }

    private static func save(_ windows: [RecentWindow]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(windows) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}

extension Notification.Name {
    /// Posted by a surface when its child process exits, so the session store
    /// can capture the final screen.
    static let wavettyChildExited = Notification.Name("WavettyChildExited")
}
