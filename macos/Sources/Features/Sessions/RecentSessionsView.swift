import AppKit
import SwiftUI

// Wavetty: window controller for the Recent Sessions list.
@MainActor
final class RecentSessionsWindowController: NSWindowController {
    private static var existing: RecentSessionsWindowController?

    static func show() {
        if let existing {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = RecentSessionsWindowController()
        existing = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Recent Sessions"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: RecentSessionsView())
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

struct RecentSessionsView: View {
    @ObservedObject private var store = SessionHistoryStore.shared
    @State private var pendingDelete: RecentWindow?

    var body: some View {
        VStack(spacing: 0) {
            if store.recentWindows.isEmpty {
                Spacer()
                Text("최근 접속 기록이 없습니다")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(store.recentWindows, id: \.id) { window in
                        RecentSessionRow(window: window, onDelete: {
                            pendingDelete = window
                        }, onRestore: {
                            store.restore(window)
                        })
                    }
                }
                .listStyle(.plain)
            }

            Divider()
            HStack {
                Button("전체 삭제") {
                    store.clear()
                }
                .foregroundStyle(.red)
                .disabled(store.recentWindows.isEmpty)
                Spacer()
                Button("닫기") {
                    NSApp.keyWindow?.close()
                }
            }
            .padding(12)
        }
        .frame(minWidth: 380, minHeight: 300)
        .alert("삭제하시겠습니까?", isPresented: deleteAlertBinding) {
            Button("삭제", role: .destructive) {
                if let w = pendingDelete {
                    store.remove(id: w.id)
                }
                pendingDelete = nil
            }
            Button("취소", role: .cancel) { pendingDelete = nil }
        } message: {
            if let w = pendingDelete {
                Text("\"\(w.displayName)\" 항목을 최근 접속 기록에서 삭제합니다.")
            }
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

private struct RecentSessionRow: View {
    let window: RecentWindow
    let onDelete: () -> Void
    let onRestore: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: window.isSSH ? "network" : "macwindow")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(window.displayName)
                    .lineLimit(1)
                (Text(window.lastUsed, style: .relative) + Text(" 전"))
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Spacer()

            Button(action: onRestore) {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("복원")
            .opacity(hovering ? 1 : 0)

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("삭제")
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onRestore() }
    }
}
