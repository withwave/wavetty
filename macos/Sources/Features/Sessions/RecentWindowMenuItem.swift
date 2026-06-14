import AppKit

// Wavetty: custom NSMenuItem view for Recent Windows in the Dock menu.
// Click the row = restore; hover to reveal the × button = delete.
final class RecentWindowMenuItemView: NSView {
    private let recentWindow: RecentWindow
    private let onRestore: () -> Void
    private let onRemove: () -> Void

    private let removeButton = NSButton(frame: .zero)
    private var isHighlighted = false

    init(recentWindow: RecentWindow,
         onRestore: @escaping () -> Void,
         onRemove:  @escaping () -> Void) {
        self.recentWindow = recentWindow
        self.onRestore    = onRestore
        self.onRemove     = onRemove
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        setup()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func setup() {
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                     accessibilityDescription: "Remove")
        removeButton.bezelStyle = .regularSquare
        removeButton.isBordered = false
        removeButton.alphaValue = 0
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 14),
            removeButton.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Highlight background (mimics NSMenuItem selection).
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }

        // Icon
        let iconName = recentWindow.isSSH ? "network" : "macwindow"
        let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        icon?.draw(in: NSRect(x: 14, y: 4, width: 14, height: 14),
                   from: .zero, operation: .sourceOver,
                   fraction: isHighlighted ? 1.0 : 0.8)

        // Title
        let fg: NSColor = isHighlighted ? .white : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: fg,
        ]
        let maxW = bounds.width - 56   // leave room for x button
        (recentWindow.displayName as NSString).draw(
            in: NSRect(x: 34, y: 5, width: maxW, height: 14),
            withAttributes: attrs)
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        needsDisplay = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            removeButton.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            removeButton.animator().alphaValue = 0
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Ignore clicks that land on the remove button (handled by the button).
        let loc = convert(event.locationInWindow, from: nil)
        guard !removeButton.frame.contains(loc) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onRestore()
    }

    @objc private func removeTapped() {
        enclosingMenuItem?.menu?.cancelTracking()
        onRemove()
    }
}
