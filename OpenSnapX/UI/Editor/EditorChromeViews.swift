import AppKit

@MainActor
final class EditorTitlebarView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
final class EditorChromeButton: NSButton {
    private let closure: () -> Void
    private let showsSelection: Bool
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    init(symbol: String, label: String, showsSelection: Bool, action: @escaping () -> Void) {
        self.showsSelection = showsSelection
        closure = action
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
        imagePosition = .imageOnly
        isBordered = false
        focusRingType = .none
        contentTintColor = .labelColor
        target = self
        self.action = #selector(invoke)
        toolTip = label
        setAccessibilityLabel(label)
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        super.updateTrackingAreas()
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let selected = showsSelection && state == .on
        if selected || isHovered {
            let alpha: CGFloat = selected ? 0.10 : 0.06
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            let highlightRect = bounds.insetBy(dx: 3, dy: 3)
            NSBezierPath(roundedRect: highlightRect, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    func setSelected(_ selected: Bool) {
        state = selected ? .on : .off
        contentTintColor = .labelColor
        needsDisplay = true
    }

    @objc private func invoke() { closure() }
}

@MainActor
final class CenteredClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrained }
        let documentFrame = documentView.frame
        if constrained.width > documentFrame.width {
            constrained.origin.x = documentFrame.midX - constrained.width / 2
        }
        if constrained.height > documentFrame.height {
            constrained.origin.y = documentFrame.midY - constrained.height / 2
        }
        return constrained
    }
}
