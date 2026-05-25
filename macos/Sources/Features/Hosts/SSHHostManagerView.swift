import AppKit
import SwiftUI

/// Standalone window for managing SSH hosts. Entry point is the Command
/// Palette item "SSH: Manage Hosts...".
@MainActor
final class SSHHostManagerWindowController: NSWindowController {
    // Strong reference: keeping the controller (and its already-built SwiftUI
    // view) alive makes reopening instant. With a weak ref the controller was
    // deallocated after each show(), so every open rebuilt the whole
    // NavigationSplitView graph synchronously — the source of the slow open.
    static private var existing: SSHHostManagerWindowController?

    static func show() {
        // Pick up any hosts added since (e.g. auto-added from a terminal ssh).
        SSHHostStore.shared.reload()
        if let existing {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SSHHostManagerWindowController()
        existing = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "SSH Hosts"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)

        super.init(window: window)
        window.contentView = NSHostingView(rootView: SSHHostManagerView())
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

struct SSHHostManagerView: View {
    @ObservedObject private var store = SSHHostStore.shared
    @State private var selection: String?
    @State private var search: String = ""
    @State private var showingAdd = false

    var filteredHosts: [SSHHost] {
        if search.isEmpty { return store.hosts }
        let q = search.lowercased()
        return store.hosts.filter {
            $0.alias.lowercased().contains(q)
            || ($0.config.hostName ?? "").lowercased().contains(q)
            || ($0.metadata.tags.joined(separator: " ").lowercased().contains(q))
        }
    }

    var groups: [(String, [SSHHost])] {
        let grouped = Dictionary(grouping: filteredHosts) { host -> String in
            if host.metadata.autoAdded { return "Auto-added" }
            return host.metadata.group?.isEmpty == false ? host.metadata.group! : "Ungrouped"
        }
        return grouped
            .map { ($0.key, $0.value.sorted { $0.alias < $1.alias }) }
            .sorted { lhs, rhs in
                // Ungrouped first, Auto-added last
                if lhs.0 == "Ungrouped" { return true }
                if rhs.0 == "Ungrouped" { return false }
                if lhs.0 == "Auto-added" { return false }
                if rhs.0 == "Auto-added" { return true }
                return lhs.0 < rhs.0
            }
    }

    var body: some View {
        // HSplitView (lightweight AppKit-backed) instead of NavigationSplitView,
        // whose first instantiation can take seconds on macOS — this is a flat
        // master/detail UI with no navigation stack, so the heavier control
        // isn't needed.
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            detailPane
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 440)
        .sheet(isPresented: $showingAdd) {
            SSHAddHostSheet { selection = $0 }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let alias = selection, let host = store.hosts.first(where: { $0.alias == alias }) {
            SSHHostDetailView(host: host, onRename: { newAlias in selection = newAlias })
                .id(alias)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Select a host").font(.headline).foregroundStyle(.secondary)
                Text("Pick a host on the left, or click + to add.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                Button { showingAdd = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add new SSH host")
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))

            List(selection: $selection) {
                ForEach(groups, id: \.0) { group, hosts in
                    Section(header: Text(group)) {
                        ForEach(hosts) { host in
                            SSHHostRow(host: host)
                                .tag(host.alias as String?)
                                // Handle clicks explicitly so single vs. double
                                // are unambiguous and don't fight List's own
                                // selection gesture: single = show detail,
                                // double = connect. (count:2 must come first.)
                                .onTapGesture(count: 2) { store.connect(host) }
                                .onTapGesture(count: 1) { selection = host.alias }
                        }
                    }
                }
            }
        }
    }
}

private struct SSHHostRow: View {
    let host: SSHHost

    var body: some View {
        HStack(spacing: 8) {
            if host.metadata.pinned {
                Image(systemName: "pin.fill").foregroundStyle(.orange).font(.caption)
            } else {
                Image(systemName: "network").foregroundStyle(.secondary).font(.caption)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias).fontWeight(.medium)
                Text(host.displayHost).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if host.metadata.useCount > 0 {
                Text("\(host.metadata.useCount)")
                    .font(.caption2).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(nsColor: .quaternaryLabelColor))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Make the whole row (including the trailing empty space) clickable;
        // otherwise only the content area registers selection/double-click.
        .contentShape(Rectangle())
    }
}

private struct SSHHostDetailView: View {
    let host: SSHHost
    var onRename: ((String) -> Void)? = nil
    @ObservedObject private var store = SSHHostStore.shared
    @State private var showingDeleteAlert = false
    @State private var passwordInput = ""
    @State private var passwordSaved = false
    @State private var aliasDraft = ""
    @State private var aliasError: String? = nil

    private var meta: SSHHostMetadata { host.metadata }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                section("Connection") {
                    HStack(alignment: .center) {
                        Text("Alias").frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                        TextField("alias", text: $aliasDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitRename() }
                        if aliasDraft != host.alias && !aliasDraft.isEmpty {
                            Button("Rename") { commitRename() }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    if let aliasError {
                        Text(aliasError).font(.caption).foregroundStyle(.red)
                    }
                    LabeledContent("Host", value: host.config.hostName ?? host.alias)
                    if let u = host.config.user { LabeledContent("User", value: u) }
                    LabeledContent("Port", value: "\(host.config.port ?? 22)")
                    if let k = host.config.identityFile { LabeledContent("Identity", value: k) }
                    if let j = host.config.proxyJump { LabeledContent("Jump", value: j) }
                }
                .help("Alias is editable here. Other connection details come from ~/.ssh/config — edit that file to change them.")

                section("Authentication") {
                    if passwordSaved {
                        Label("Password saved in macOS Keychain", systemImage: "key.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                    HStack {
                        SecureField(passwordSaved ? "Replace stored password" : "Password (optional)",
                                    text: $passwordInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            SSHKeychain.set(password: passwordInput, for: host.alias)
                            passwordInput = ""
                            passwordSaved = true
                        }
                        .disabled(passwordInput.isEmpty)
                        if passwordSaved {
                            Button("Clear") {
                                SSHKeychain.remove(for: host.alias)
                                passwordSaved = false
                            }
                        }
                    }
                    Text("Auto-filled on connect via the Keychain (SSH_ASKPASS). SSH keys are more secure — use this only for password-only hosts.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                section("Wavetty Metadata") {
                    Toggle("Pinned", isOn: Binding(
                        get: { meta.pinned },
                        set: { v in store.updateMetadata(host.alias) { $0.pinned = v } }
                    ))

                    HStack(alignment: .top) {
                        Text("Group").frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                        TextField("e.g. Production", text: Binding(
                            get: { meta.group ?? "" },
                            set: { v in store.updateMetadata(host.alias) { $0.group = v.isEmpty ? nil : v } }
                        )).textFieldStyle(.roundedBorder)
                    }

                    HStack(alignment: .top) {
                        Text("Tags").frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                        TextField("comma-separated", text: Binding(
                            get: { meta.tags.joined(separator: ", ") },
                            set: { v in
                                let tags = v.split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }
                                store.updateMetadata(host.alias) { $0.tags = tags }
                            }
                        )).textFieldStyle(.roundedBorder)
                    }

                    HStack(alignment: .top) {
                        Text("Note").frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                        TextEditor(text: Binding(
                            get: { meta.note ?? "" },
                            set: { v in store.updateMetadata(host.alias) { $0.note = v.isEmpty ? nil : v } }
                        ))
                        .frame(height: 40)
                        .border(Color(nsColor: .separatorColor))
                    }
                }

                section("Statistics") {
                    LabeledContent("Use count", value: "\(meta.useCount)")
                    LabeledContent("Last connected", value: meta.lastConnected.map(relative) ?? "Never")
                    LabeledContent("Added", value: relative(meta.addedAt))
                    if meta.autoAdded {
                        Label("Added automatically from command palette", systemImage: "wand.and.stars")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                actions
            }
            .padding(20)
        }
        .onAppear {
            passwordSaved = SSHKeychain.hasPassword(for: host.alias)
            aliasDraft = host.alias
            aliasError = nil
        }
        .alert("Delete \"\(host.alias)\"?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                try? store.removeHost(alias: host.alias)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the Host block from ~/.ssh/config and Wavetty's metadata. ssh \(host.alias) will no longer work.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Image(systemName: "network")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(host.alias).font(.title2).fontWeight(.semibold)
                Text(host.displayHost).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
    }

    private var actions: some View {
        HStack {
            Button {
                store.connect(host)
            } label: {
                Label("Connect", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])

            Spacer()

            Button(role: .destructive) {
                showingDeleteAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding(.top, 6)
    }

    private func commitRename() {
        let newAlias = aliasDraft.trimmingCharacters(in: .whitespaces)
        guard newAlias != host.alias else { aliasError = nil; return }
        guard !newAlias.isEmpty else { aliasError = "Alias is required"; return }
        do {
            try store.renameHost(from: host.alias, to: newAlias)
            aliasError = nil
            // Tell the parent to point its selection at the new alias so the
            // detail view (which is keyed by .id(alias)) follows the rename.
            onRename?(newAlias)
        } catch {
            aliasError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) { content() }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct SSHAddHostSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var host = ""
    @State private var user = ""
    @State private var port = ""
    @State private var identityFile = ""
    @State private var proxyJump = ""
    @State private var group = ""
    @State private var errorMessage: String?
    let onAdded: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add SSH Host").font(.headline)

            Form {
                TextField("Alias *", text: $alias).help("Name used by `ssh <alias>`")
                TextField("Host *", text: $host)
                TextField("User", text: $user)
                TextField("Port", text: $port).help("Default 22 if blank")
                TextField("Identity file", text: $identityFile).help("e.g. ~/.ssh/id_ed25519")
                TextField("Jump host", text: $proxyJump).help("ProxyJump alias or user@host")
                TextField("Group", text: $group).help("Wavetty-only label for organizing")
            }

            if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Add") { submit() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(alias.isEmpty || host.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func submit() {
        do {
            let portNum = Int(port.trimmingCharacters(in: .whitespaces))
            let new = try SSHHostStore.shared.addHost(
                alias: alias.trimmingCharacters(in: .whitespaces),
                hostName: host.trimmingCharacters(in: .whitespaces),
                user: user.trimmingCharacters(in: .whitespaces),
                port: portNum,
                identityFile: identityFile.trimmingCharacters(in: .whitespaces),
                proxyJump: proxyJump.trimmingCharacters(in: .whitespaces),
                group: group.trimmingCharacters(in: .whitespaces).isEmpty ? nil : group
            )
            onAdded(new.alias)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
