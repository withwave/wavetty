import AppKit

/// Adds a "Recent Windows" submenu under the menu bar's File menu, built
/// entirely in code so we don't touch the upstream MainMenu.xib (keeps rebases
/// clean). It mirrors the Dock menu's Recent Windows section: click a row to
/// restore, hold ⌥ to turn the row into a delete (Finder-style alternate item).
@MainActor
final class RecentWindowsMenuController: NSObject, NSMenuDelegate {
    static let shared = RecentWindowsMenuController()

    private lazy var menuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Recent Windows", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Recent Windows")
        menu.delegate = self        // rebuilt on open via menuNeedsUpdate
        item.submenu = menu
        return item
    }()

    /// Inserts the "Recent Windows" submenu under the File menu (idempotent).
    /// Call once at launch.
    func install() {
        guard let main = NSApp.mainMenu,
              let fileMenu = main.item(withTitle: "File")?.submenu else { return }
        guard !fileMenu.items.contains(where: { $0.submenu === menuItem.submenu }) else { return }
        // Place it right after the New Window / New Tab group; append otherwise.
        let anchor = fileMenu.indexOfItem(withTitle: "New Tab")
        if anchor >= 0 {
            fileMenu.insertItem(menuItem, at: anchor + 1)
        } else {
            fileMenu.addItem(menuItem)
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let windows = SessionHistoryStore.shared.recentWindows
        if windows.isEmpty {
            let empty = NSMenuItem(title: "No Recent Windows", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let hint = NSMenuItem(title: "클릭=복원, ⌥옵션+클릭=삭제", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        for window in windows {
            // Click the row to restore.
            let item = NSMenuItem(
                title: window.displayName,
                action: #selector(restore(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = window
            item.keyEquivalentModifierMask = []   // primary shows with no modifier
            item.image = NSImage(
                systemSymbolName: window.isSSH ? "network" : "macwindow",
                accessibilityDescription: nil)
            menu.addItem(item)

            // Option-key alternate: holding ⌥ turns the row into delete.
            let removeItem = NSMenuItem(
                title: "Remove “\(window.displayName)” from List",
                action: #selector(remove(_:)),
                keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = window
            removeItem.isAlternate = true
            removeItem.keyEquivalentModifierMask = .option
            removeItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            menu.addItem(removeItem)
        }
    }

    @objc private func restore(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? RecentWindow else { return }
        SessionHistoryStore.shared.restore(window)
    }

    @objc private func remove(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? RecentWindow else { return }
        SessionHistoryStore.shared.remove(id: window.id)
    }
}
