import AppKit

/// Adds a top-level "SSH" menu to the menu bar, built entirely in code so we
/// don't touch the upstream MainMenu.xib (keeps rebases clean). The menu lists
/// pinned/recent hosts for one-click connect and opens the host manager.
@MainActor
final class SSHMenuController: NSObject, NSMenuDelegate {
    static let shared = SSHMenuController()

    private lazy var menuItem: NSMenuItem = {
        let item = NSMenuItem(title: "SSH", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "SSH")
        menu.delegate = self        // rebuilt on open via menuNeedsUpdate
        item.submenu = menu
        return item
    }()

    /// Inserts the SSH menu into the main menu (idempotent). Call once at launch.
    func install() {
        guard let main = NSApp.mainMenu else { return }
        guard !main.items.contains(where: { $0.submenu?.title == "SSH" }) else { return }
        // Place it just before the Window menu, or append if not found.
        let windowIndex = main.indexOfItem(withTitle: "Window")
        if windowIndex >= 0 {
            main.insertItem(menuItem, at: windowIndex)
        } else {
            main.addItem(menuItem)
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // New tab to the current surface's SSH host (⇧⌘T). Kept first and
        // static so its key equivalent works even when the menu isn't open.
        let newSSHTab = NSMenuItem(
            title: "New Tab to Current SSH Host",
            action: #selector(newSSHTab(_:)),
            keyEquivalent: "t")
        newSSHTab.keyEquivalentModifierMask = [.command, .shift]
        newSSHTab.target = self
        newSSHTab.image = NSImage(systemSymbolName: "plus.rectangle.on.rectangle", accessibilityDescription: nil)
        menu.addItem(newSSHTab)
        menu.addItem(.separator())

        let hosts = SSHHostStore.shared.suggestions(for: "", limit: 15)
        if hosts.isEmpty {
            let empty = NSMenuItem(title: "No SSH Hosts", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for host in hosts {
                let item = NSMenuItem(
                    title: host.alias,
                    action: #selector(connect(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = host.alias
                item.image = NSImage(
                    systemSymbolName: host.metadata.pinned ? "pin.fill" : "network",
                    accessibilityDescription: nil)
                item.toolTip = host.displayHost
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let manage = NSMenuItem(
            title: "Manage Hosts…",
            action: #selector(manage),
            keyEquivalent: "k")
        manage.keyEquivalentModifierMask = [.command, .shift]
        manage.target = self
        menu.addItem(manage)
    }

    @objc private func connect(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        SSHHostStore.shared.connect(alias: alias)
    }

    @objc private func newSSHTab(_ sender: Any?) {
        // If the focused surface is an SSH session, open a new tab to the same
        // host. Otherwise fall back to a normal new tab.
        if !SSHHostStore.shared.openSSHTabFromFocused() {
            (NSApp.delegate as? AppDelegate)?.newTab(sender)
        }
    }

    @objc private func manage() {
        SSHHostManagerWindowController.show()
    }
}
