import SwiftUI
import GhosttyKit

struct TerminalCommandPaletteView: View {
    /// The surface that this command palette represents.
    let surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view, this will be set to false if any actions
    /// result in the view disappearing.
    @Binding var isPresented: Bool

    /// The configuration so we can lookup keyboard shortcuts.
    @ObservedObject var ghosttyConfig: Ghostty.Config

    /// The update view model for showing update commands.
    var updateViewModel: UpdateViewModel?

    /// The callback when an action is submitted.
    var onAction: ((String) -> Void)

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            options: commandOptions,
                            dynamicOptions: sshDynamicOptions
                        )
                        .zIndex(1) // Ensure it's on top

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the command palette disappears we need to send focus back to the
            // surface view we were overlaid on top of. There's probably a better way
            // to handle the first responder state here but I don't know it.
            if !newValue {
                // Has to be on queue because onChange happens on a user-interactive
                // thread and Xcode is mad about this call on that.
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    /// All commands available in the command palette, combining update and terminal options.
    private var commandOptions: [CommandOption] {
        var options: [CommandOption] = []
        // Updates always appear first
        options.append(contentsOf: updateOptions)

        // Sort the rest. We replace ":" with a character that sorts before space
        // so that "Foo:" sorts before "Foo Bar:". Use sortKey as a tie-breaker
        // for stable ordering when titles are equal.
        options.append(contentsOf: (jumpOptions + terminalOptions).sorted { a, b in
            let aNormalized = a.title.replacingOccurrences(of: ":", with: "\t")
            let bNormalized = b.title.replacingOccurrences(of: ":", with: "\t")
            let comparison = aNormalized.localizedCaseInsensitiveCompare(bNormalized)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            // Tie-breaker: use sortKey if both have one
            if let aSortKey = a.sortKey, let bSortKey = b.sortKey {
                return aSortKey < bSortKey
            }
            return false
        })
        return options
    }

    /// Commands for installing or canceling available updates.
    private var updateOptions: [CommandOption] {
        var options: [CommandOption] = []

        guard let updateViewModel, updateViewModel.state.isInstallable else {
            return options
        }

        // We override the update available one only because we want to properly
        // convey it'll go all the way through.
        let title: String
        if case .updateAvailable = updateViewModel.state {
            title = "Update Wavetty and Restart"
        } else {
            title = updateViewModel.text
        }

        options.append(CommandOption(
            title: title,
            description: updateViewModel.description,
            leadingIcon: updateViewModel.iconName ?? "shippingbox.fill",
            badge: updateViewModel.badge,
            emphasis: true
        ) {
            (NSApp.delegate as? AppDelegate)?.updateController.installUpdate()
        })

        options.append(CommandOption(
            title: "Cancel or Skip Update",
            description: "Dismiss the current update process"
        ) {
            updateViewModel.state.cancel()
        })

        return options
    }

    /// Custom commands from the command-palette-entry configuration.
    private var terminalOptions: [CommandOption] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return [] }
        return appDelegate.ghostty.config.commandPaletteEntries
            .filter(\.isSupported)
            .map { c in
                let symbols = appDelegate.ghostty.config.keyboardShortcut(for: c.action)?.keyList
                return CommandOption(
                    title: c.title,
                    description: c.description,
                    symbols: symbols
                ) {
                    onAction(c.action)
                }
            }
    }

    /// Commands for jumping to other terminal surfaces.
    private var jumpOptions: [CommandOption] {
        TerminalController.all.flatMap { controller -> [CommandOption] in
            guard let window = controller.window else { return [] }

            let color = (window as? TerminalWindow)?.tabColor
            let displayColor = color != TerminalTabColor.none ? color : nil

            return controller.surfaceTree.map { surface in
                let terminalTitle = surface.title.isEmpty ? window.title : surface.title
                let displayTitle: String
                if let override = controller.titleOverride, !override.isEmpty {
                    displayTitle = override
                } else if !terminalTitle.isEmpty {
                    displayTitle = terminalTitle
                } else {
                    displayTitle = "Untitled"
                }
                let pwd = surface.pwd?.abbreviatedPath
                let subtitle: String? = if let pwd, !displayTitle.contains(pwd) {
                    pwd
                } else {
                    nil
                }

                return CommandOption(
                    title: "Focus: \(displayTitle)",
                    subtitle: subtitle,
                    leadingIcon: "rectangle.on.rectangle",
                    leadingColor: displayColor?.displayColor.map { Color($0) },
                    sortKey: AnySortKey(ObjectIdentifier(surface))
                ) {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyPresentTerminal,
                        object: surface
                    )
                }
            }
        }
    }


    /// Wavetty: SSH host suggestions activated when the user types "ssh".
    /// Bypasses the palette's title/subtitle filter — we handle matching
    /// ourselves so the items only appear in SSH mode.
    private func sshDynamicOptions(query: String) -> [CommandOption] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard lower == "ssh" || lower.hasPrefix("ssh ") else { return [] }

        let body: String = if lower == "ssh" {
            ""
        } else {
            String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }

        var items: [CommandOption] = []

        // (1) "Add & Connect" item when body parses as a URI we don't already have.
        // Heuristic: must contain @, :, or . to look like a real host (avoids
        // false-positive when user types short alias guesses).
        if !body.isEmpty,
           body.contains(where: { "@:.".contains($0) }),
           let parsed = SSHURIParser.parse(body),
           SSHHostStore.shared.existingMatch(for: parsed) == nil {
            let alias = parsed.explicitAlias
                ?? SSHHostStore.shared.generateAlias(host: parsed.host, user: parsed.user, port: parsed.port)
            let target = "\(parsed.user.map { "\($0)@" } ?? "")\(parsed.host)\(parsed.port.map { ":\($0)" } ?? "")"
            items.append(CommandOption(
                title: "SSH: Add & Connect \(target)",
                subtitle: "Save as \"\(alias)\" in ~/.ssh/config",
                leadingIcon: "plus.circle.fill",
                emphasis: true
            ) {
                _ = SSHHostStore.shared.connect(uri: body)
            })
        }

        // (2) Existing host suggestions filtered by body.
        for host in SSHHostStore.shared.suggestions(for: body) {
            items.append(CommandOption(
                title: "SSH: \(host.alias)",
                subtitle: host.displayHost,
                leadingIcon: host.metadata.pinned ? "pin.fill" : "network"
            ) {
                SSHHostStore.shared.connect(host)
            })
        }

        // (3) Always offer the manager when in "ssh" mode.
        items.append(CommandOption(
            title: "SSH: Manage Hosts…",
            subtitle: "Edit metadata, add/remove hosts",
            leadingIcon: "slider.horizontal.3"
        ) {
            SSHHostManagerWindowController.show()
        })

        return items
    }
}

/// This is done to ensure that the given view is in the responder chain.
private struct ResponderChainInjector: NSViewRepresentable {
    let responder: NSResponder

    func makeNSView(context: Context) -> NSView {
        let dummy = NSView()
        DispatchQueue.main.async {
            dummy.nextResponder = responder
        }
        return dummy
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
