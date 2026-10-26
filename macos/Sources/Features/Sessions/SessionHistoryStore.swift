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
    /// The live surface this leaf was captured from. This — not the directory
    /// — is what ties an entry to a window: two windows in the same folder are
    /// different sessions with different histories.
    var surfaceID: String?
    /// The program's title at capture (e.g. `✳ Claude Code`), shown after the
    /// folder in the menus like a live window's title.
    var title: String?

    /// `surfaceID`, falling back to the scrollback file name for entries saved
    /// before the field existed (those files were already named by surface id).
    var resolvedSurfaceID: String? {
        if let surfaceID { return surfaceID }
        guard let file = scrollbackFile else { return nil }
        let name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        return UUID(uuidString: name) != nil ? name : nil
    }
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

    /// Every leaf in the tree, left to right.
    var leaves: [SessionLeaf] {
        switch self {
        case .leaf(let l): return [l]
        case .split(_, _, let left, let right): return left.leaves + right.leaves
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
        // Same "folder — title" form as live window titles.
        let titled = tabs.first?.root.firstLeaf?.title.map { "\(base) — \($0)" } ?? base
        return tabs.count > 1 ? "\(titled)  (+\(tabs.count - 1) tabs)" : titled
    }

    /// Whether the first leaf is an SSH session (for the menu icon).
    var isSSH: Bool { tabs.first?.root.firstLeaf?.sshAlias != nil }

    /// Ids of the surfaces this entry was captured from — its identity.
    var surfaceIDs: Set<String> {
        Set(tabs.flatMap { $0.root.leaves.compactMap(\.resolvedSurfaceID) })
    }

    /// Menu labels for `windows`, in order. Entries are identified by session,
    /// not folder, so two can share a display name; those get their last-used
    /// time appended so the menu can tell them apart.
    static func menuTitles(for windows: [RecentWindow]) -> [String] {
        var counts: [String: Int] = [:]
        for w in windows { counts[w.displayName, default: 0] += 1 }
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d HH:mm"
        return windows.map { w in
            (counts[w.displayName] ?? 0) > 1
                ? "\(w.displayName)  · \(fmt.string(from: w.lastUsed))"
                : w.displayName
        }
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

    /// Live window/tab-group object ids the user explicitly removed while still
    /// open. The sweep skips capturing *these specific windows* so a delete
    /// isn't immediately undone by the next capture. A brand-new window (e.g. a
    /// reconnect to the same host) is a different object and is captured
    /// normally. Stale ids are pruned each sweep (see `sweepAllWindows`).
    private var suppressedWindows: Set<ObjectIdentifier> = []

    /// SSH alias tagged at session creation (connect or restore), keyed by
    /// surface id. `captureNode` prefers this over live foreground-process
    /// inspection, so a session opened as `ssh <alias>` is recorded as
    /// ssh:<alias> even if ssh already exited (e.g. a quick connect/disconnect)
    /// by the time a sweep captures it. Pruned to live surfaces each sweep.
    private var taggedSSHAliases: [UUID: String] = [:]

    /// Tag a surface as an SSH session to `alias`. Called from the SSH connect
    /// path and from restore so capture doesn't depend on ssh still running.
    func noteSSHSession(surfaceID: UUID, alias: String) {
        taggedSSHAliases[surfaceID] = alias
    }

    /// The SSH alias a surface was tagged with at connect/restore, if any.
    func taggedSSHAlias(for surfaceID: UUID) -> String? {
        taggedSSHAliases[surfaceID]
    }

    /// Maps each live tab window to the recent entry it currently belongs to, so
    /// a window that gains or loses a tab updates that single entry instead of
    /// leaving behind one entry per tab count. Keyed per tab window (not per tab
    /// group) so it survives the no-group → group transition that happens when a
    /// window's first extra tab is opened. Pruned to live windows each sweep.
    private var windowEntryIDs: [ObjectIdentifier: UUID] = [:]

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
        // A closing multi-tab window drops its tabs one-by-one, so every
        // capture here sees fewer tabs. snapshotGroup never applies a shrink
        // directly; it defers to scheduleShrinkReeval, which keeps the
        // full-size entry when no live window survives (window close) and
        // re-captures smaller when one does (single tab close).
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
        // Don't capture mid-restore. Rebuilding a multi-tab window briefly
        // passes through 1-tab states (makeKeyAndOrderFront fires resignKey on
        // the previous window before the other tabs are attached); capturing or
        // mutating store state during that window corrupts the entry and can
        // disrupt the tab attachment itself. A single capture runs after the
        // restore completes.
        guard restoringIDs.isEmpty else { return }

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

        // Drop suppression ids for windows that have since closed.
        suppressedWindows.formIntersection(Set(order))

        // Prune ssh tags down to surfaces that still exist.
        if !taggedSSHAliases.isEmpty {
            var liveSurfaceIDs: Set<UUID> = []
            for window in NSApp.windows {
                guard let controller = window.windowController as? BaseTerminalController else { continue }
                for view in controller.surfaceTree { liveSurfaceIDs.insert(view.id) }
            }
            taggedSSHAliases = taggedSSHAliases.filter { liveSurfaceIDs.contains($0.key) }
        }

        // Prune window→entry mappings down to windows that still exist.
        if !windowEntryIDs.isEmpty {
            var liveWindowIDs: Set<ObjectIdentifier> = []
            for window in NSApp.windows where window.windowController is TerminalController {
                liveWindowIDs.insert(ObjectIdentifier(window))
            }
            windowEntryIDs = windowEntryIDs.filter { liveWindowIDs.contains($0.key) }
        }

        var changed = false
        for key in order {
            // Skip windows the user explicitly removed (until they close).
            if suppressedWindows.contains(key) { continue }
            if snapshotGroup(anyWindow: groups[key]!, save: false) { changed = true }
        }
        if changed { Self.save(recentWindows) }
    }

    /// Tab-entry ids whose live window just shrank; a deferred re-check decides
    /// whether it was a tab close (window survives → apply the shrink) or a
    /// window close (window gone → keep the full entry for restore).
    private var pendingShrinkReeval: Set<UUID> = []

    /// Snapshots one window/tab-group into a single `RecentWindow` entry.
    @discardableResult
    private func snapshotGroup(anyWindow: NSWindow, save: Bool, allowShrink: Bool = false) -> Bool {
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

        var entry = RecentWindow(
            id: UUID(), lastUsed: Date(), frame: WindowFrame(frameWindow.frame), tabs: tabs)
        let liveSurfaceIDs = entry.surfaceIDs

        // Which entry is this window? Identity is the session, never the folder:
        //  1. the entry a member tab window is already mapped to (the same live
        //     window across captures, or a window `restore` just rebuilt);
        //  2. else an entry captured from these same surfaces (a window macOS
        //     state restoration reopened at launch keeps its surface ids);
        //  3. else it's a new session and gets its own entry — even if another
        //     entry lists the same folders. (Matching by folder merged distinct
        //     windows into one entry and restored one window's history into
        //     another.)
        let memberKeys = tabWindows.map { ObjectIdentifier($0) }
        let mappedIDs = Set(memberKeys.compactMap { windowEntryIDs[$0] })
            .filter { id in recentWindows.contains { $0.id == id } }
        let targetID: UUID? =
            windowEntryIDs[ObjectIdentifier(frameWindow)].flatMap { id in mappedIDs.contains(id) ? id : nil }
            ?? mappedIDs.first
            ?? recentWindows.first { !$0.surfaceIDs.isDisjoint(with: liveSurfaceIDs) }?.id

        // Map before the shrink check below: its deferred re-check finds the
        // survivor through this mapping, including a window matched by surface
        // ids alone (otherwise that window would be deferred forever).
        if let targetID { for key in memberKeys { windowEntryIDs[key] = targetID } }

        // This window maps to an entry with MORE tabs than we see now, so it is
        // shrinking. We can't yet tell a single-tab close (window survives →
        // the closed tab + its scrollback should be dropped) from a window close
        // (tabs close one-by-one, each a smaller capture ending at 1 → we must
        // keep the full entry for restore). Defer: don't overwrite now; a
        // re-check decides once the close settles (see scheduleShrinkReeval).
        if !allowShrink, let targetID,
           (recentWindows.first { $0.id == targetID }?.tabs.count ?? 0) > tabs.count {
            scheduleShrinkReeval(mappedID: targetID)
            return false
        }

        if let targetID { entry.id = targetID }
        for key in memberKeys { windowEntryIDs[key] = entry.id }

        // Tabs dragged in from another window still map to that window's entry.
        // Once no live window maps to it and everything it held is now here,
        // it is fully absorbed — drop it rather than leave a phantom duplicate.
        var removedAbsorbed = false
        for id in mappedIDs where id != entry.id {
            let stillLive = windowEntryIDs.contains { key, value in
                value == id && NSApp.windows.contains { ObjectIdentifier($0) == key && $0.isVisible }
            }
            guard !stillLive,
                  let other = recentWindows.first(where: { $0.id == id }),
                  other.surfaceIDs.isSubset(of: liveSurfaceIDs) else { continue }
            recentWindows.removeAll { $0.id == id }
            removedAbsorbed = true
        }

        let changed = upsert(entry, save: false)
        if (changed || removedAbsorbed) && save { Self.save(recentWindows) }
        return changed || removedAbsorbed
    }

    /// After a window shrinks, wait for the close to settle and decide: if a
    /// live window still maps to this entry, the user closed a single tab and
    /// kept the window — re-capture it at its current (smaller) size so the
    /// closed tab and its scrollback are dropped and won't be restored. If no
    /// live window maps to it, the whole window was closed — leave the full
    /// entry intact so it can be restored with all its tabs.
    private func scheduleShrinkReeval(mappedID: UUID) {
        guard pendingShrinkReeval.insert(mappedID).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.pendingShrinkReeval.remove(mappedID)
            // `isVisible` matters: a closed window can linger in NSApp.windows
            // until it is released, and treating one as a survivor would read a
            // whole-window close as a tab close and truncate the entry.
            guard let survivor = NSApp.windows.first(where: { w in
                w.isVisible &&
                w.windowController is TerminalController &&
                self.windowEntryIDs[ObjectIdentifier(w)] == mappedID
            }) else { return }
            self.snapshotGroup(anyWindow: survivor, save: true, allowShrink: true)
        }
    }

    /// Walks a live split-tree node into our serializable `SessionNode`.
    private func captureNode(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> SessionNode {
        switch node {
        case .leaf(let view):
            var leaf = SessionLeaf()
            leaf.surfaceID = view.id.uuidString
            leaf.title = WavettyWindowTitles.programTitle(of: view)
            // Prefer the alias tagged at session creation (survives ssh exit),
            // then fall back to live foreground-process inspection.
            if let alias = taggedSSHAliases[view.id] ?? sshAlias(of: view) {
                leaf.sshAlias = alias
            } else if let dir = effectivePwd(of: view), isLocalDirectory(dir) {
                leaf.workingDirectory = dir
            }
            // Capture color-preserving scrollback to a file keyed by the
            // surface's unique id. Keying by host/dir was wrong: multiple tabs
            // in the same directory (or to the same host) then shared one file,
            // so restoring one tab showed another tab's output. The surface id
            // is unique per live surface, stable across re-captures of the same
            // session, and orphaned files are pruned on save (cleanupOrphans).
            if (leaf.sshAlias != nil || leaf.workingDirectory != nil),
               let surface = view.surface {
                if let text = dumpScrollbackStyled(surface), !text.isEmpty {
                    let file = Self.scrollbackPath(key: view.id.uuidString)
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
        // Descend the process tree: ghostty wraps the shell in a root-owned
        // `/usr/bin/login` whose argv we can't read, but the real `ssh` runs as
        // a readable child. (Inspecting only the foreground pid missed these.)
        guard pid != 0,
              let uri = SSHProcessInspector.sshURI(fromTreeRoot: Int32(truncatingIfNeeded: pid)),
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

    /// Inserts `entry`, or replaces the entry with the same id (the same
    /// session). A bare timestamp bump on identical content is ignored to avoid
    /// disk churn; a moved window or changed layout/output moves it to the
    /// front and persists.
    @discardableResult
    private func upsert(_ entry: RecentWindow, save: Bool) -> Bool {
        if let idx = recentWindows.firstIndex(where: { $0.id == entry.id }) {
            let existing = recentWindows[idx]
            if existing.frame == entry.frame && existing.tabs == entry.tabs {
                recentWindows[idx].lastUsed = entry.lastUsed
                return false
            }
            recentWindows.remove(at: idx)
            recentWindows.insert(entry, at: 0)
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

    func remove(id: UUID) {
        // If a live window currently matches this entry, suppress that specific
        // window so the next sweep doesn't re-capture it back into the list. A
        // later reconnect opens a different window object and is captured.
        if let live = liveWindow(for: id) {
            let repObject: AnyObject = live.tabGroup ?? live
            suppressedWindows.insert(ObjectIdentifier(repObject))
        }
        recentWindows.removeAll { $0.id == id }
        Self.save(recentWindows)
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

    // Wavetty: tracks IDs currently mid-restore to block duplicate clicks.
    private var restoringIDs: Set<UUID> = []

    /// Reopens a window restored to its last position/size, rebuilding every
    /// tab and split. Local leaves cd into their directory; SSH leaves reconnect.
    func restore(_ window: RecentWindow) {
        // Block re-entry: prevents duplicate restores from double-click or
        // rapidly clicking the same item before the first restore finishes.
        guard !restoringIDs.contains(window.id) else { return }

        // If this very session is still open, focus it instead of opening a
        // duplicate. Matched by session identity, not folders: another window
        // in the same folders is a different session and must not be focused.
        if let live = liveWindow(for: window.id) {
            if let group = live.tabGroup, group.selectedWindow !== live {
                group.selectedWindow = live
            }
            live.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let app = appDelegate.ghostty.app,
              !window.tabs.isEmpty else { return }
        // First tab becomes the primary window. A plain controller init does
        // not present its window (unlike newWindow/newTab which schedule it),
        // so we explicitly show + order front here.
        let firstTree = SplitTree(root: buildNode(window.tabs[0].root, app: app), zoomed: nil)
        let primary = TerminalController(appDelegate.ghostty, withSurfaceTree: firstTree)
        // Set the guard only once the restore is certain to proceed: an early
        // return past it would leave the id stuck in restoringIDs, blocking
        // every later restore of this entry (and all sweeps) for the app's life.
        guard let primaryWindow = primary.window else { return }
        restoringIDs.insert(window.id)

        DispatchQueue.main.async {
            primary.showWindow(nil)
            primaryWindow.makeKeyAndOrderFront(nil)

            // Remaining tabs join the primary window's tab group. This mirrors
            // TerminalController.newTab: creating a terminal window while the
            // primary is key makes macOS auto-add it to the primary's tab group;
            // we must remove it before our explicit add or AppKit's
            // tabbedWindows state gets corrupted and the tabs end up as separate
            // (1-tab) windows — which then capture as a single-tab entry.
            // The rebuilt window IS this entry: map it now, so its captures
            // update this entry rather than being matched some other way.
            self.windowEntryIDs[ObjectIdentifier(primaryWindow)] = window.id
            for tab in window.tabs.dropFirst() {
                let tree = SplitTree(root: self.buildNode(tab.root, app: app), zoomed: nil)
                let controller = TerminalController(appDelegate.ghostty, withSurfaceTree: tree)
                guard let tabWindow = controller.window else { continue }
                self.windowEntryIDs[ObjectIdentifier(tabWindow)] = window.id
                if let group = primaryWindow.tabGroup,
                   group.windows.firstIndex(of: tabWindow) != nil {
                    group.removeWindow(tabWindow)
                }
                if tabWindow.tabbingMode != .disallowed {
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
            // Capture only once the tab group reflects the full tab count (sweeps
            // stay blocked via restoringIDs until then), so we never record a
            // transient 1-tab state.
            self.captureRestoredWindowWhenSettled(
                primaryWindow, id: window.id, expectedTabs: window.tabs.count, attempts: 0)
        }
    }

    /// Polls until the restored window's tab group has all its tabs, then clears
    /// the restore guard and captures. Avoids recording a half-built (1-tab)
    /// state while still guaranteeing the guard is cleared on failure.
    private func captureRestoredWindowWhenSettled(
        _ primaryWindow: NSWindow, id: UUID, expectedTabs: Int, attempts: Int
    ) {
        let liveTabs = (primaryWindow.tabGroup?.windows ?? [primaryWindow])
            .filter { $0.windowController is TerminalController }.count
        // Also wait for the saved scrollback to be injected. Capturing first
        // would record the new surfaces' still-empty screens and delete the old
        // scrollback files as orphans — losing the history being restored.
        if (liveTabs >= expectedTabs && pendingInjections.isEmpty) || attempts >= 60 {
            restoringIDs.remove(id)
            captureNow()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak primaryWindow] in
            guard let self else { return }
            guard let primaryWindow else { self.restoringIDs.remove(id); return }
            self.captureRestoredWindowWhenSettled(
                primaryWindow, id: id, expectedTabs: expectedTabs, attempts: attempts + 1)
        }
    }

    /// The open, visible terminal window currently mapped to entry `id`, if
    /// any — how restore finds "this session is already open" and remove finds
    /// the window to suppress.
    private func liveWindow(for id: UUID) -> NSWindow? {
        NSApp.windows.first { w in
            w.isVisible &&
            w.windowController is TerminalController &&
            windowEntryIDs[ObjectIdentifier(w)] == id
        }
    }

    /// Per-surface work to run after a restored surface attaches: inject its
    /// color-preserving scrollback (no shell echo) and start ssh via stdin.
    private struct PendingRestore { var file: String?; var ssh: String? }
    private var pendingRestores: [UUID: PendingRestore] = [:]

    /// Restored surfaces whose scrollback hasn't been injected yet.
    private var pendingInjections: Set<UUID> = []

    private func processPendingRestores() {
        let pending = pendingRestores
        pendingRestores.removeAll()
        pendingInjections.formUnion(pending.keys)
        for (uuid, info) in pending {
            injectRestore(uuid: uuid, info: info, attempts: 0)
        }
    }

    private func injectRestore(uuid: UUID, info: PendingRestore, attempts: Int) {
        guard let view = findSurfaceView(uuid), let surface = view.surface else {
            // Surface not attached yet; retry briefly (mirrors ghostty's own
            // restore polling).
            guard attempts < 40 else { pendingInjections.remove(uuid); return }
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
        pendingInjections.remove(uuid)
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
            if let alias = leaf.sshAlias {
                // Keep the ssh tag so a re-capture of the restored session is
                // recorded as ssh:<alias> regardless of process state.
                taggedSSHAliases[view.id] = alias
            }
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
        // Only exact duplicates (the same surfaces) collapse. Entries that merely
        // share folders are different sessions and are all kept. Stored
        // most-recent-first, so the first of each is the newest.
        var seen = Set<Set<String>>()
        return decoded.filter { w in
            let ids = w.surfaceIDs
            return ids.isEmpty || seen.insert(ids).inserted
        }
    }

    private static func save(_ windows: [RecentWindow]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(windows) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
        cleanupOrphanScrollback(windows)
    }

    /// Delete scrollback files no longer referenced by any retained window.
    /// Surface-id-keyed files would otherwise accumulate as sessions churn.
    private static func cleanupOrphanScrollback(_ windows: [RecentWindow]) {
        var referenced = Set<String>()
        func collect(_ node: SessionNode) {
            switch node {
            case .leaf(let leaf):
                if let f = leaf.scrollbackFile { referenced.insert(f) }
            case .split(_, _, let l, let r):
                collect(l); collect(r)
            }
        }
        for w in windows { for t in w.tabs { collect(t.root) } }

        let dir = scrollbackDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in files where name.hasSuffix(".ansi") {
            let full = (dir as NSString).appendingPathComponent(name)
            if !referenced.contains(full) {
                try? FileManager.default.removeItem(atPath: full)
            }
        }
    }
}

extension Notification.Name {
    /// Posted by a surface when its child process exits, so the session store
    /// can capture the final screen.
    static let wavettyChildExited = Notification.Name("WavettyChildExited")
}
