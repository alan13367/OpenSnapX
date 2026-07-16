import AppKit
import Carbon

extension ShortcutDefinition {
    var displayString: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        value += keyLabel.uppercased()
        return value
    }
}

@MainActor
final class ShortcutRecorderControl: NSControl {
    var shortcut: ShortcutDefinition {
        didSet {
            needsDisplay = true
            setAccessibilityValue(shortcut.displayString)
        }
    }
    var onChange: ((ShortcutDefinition) -> Void)?

    private var isRecordingShortcut = false
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 136, height: 34) }

    init(shortcut: ShortcutDefinition) {
        self.shortcut = shortcut
        super.init(frame: CGRect(x: 0, y: 0, width: 136, height: 34))
        focusRingType = .exterior
        setAccessibilityRole(.button)
        setAccessibilityLabel("Record keyboard shortcut")
        setAccessibilityValue(shortcut.displayString)
        toolTip = "Click, then press a keyboard shortcut"
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecordingShortcut = true
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        isRecordingShortcut = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else { return super.keyDown(with: event) }
        if event.keyCode == UInt16(kVK_Escape) {
            isRecordingShortcut = false
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return
        }

        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        let hasPrimaryModifier = modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
        guard hasPrimaryModifier, let label = Self.keyLabel(for: event), !label.isEmpty else {
            NSSound.beep()
            return
        }

        shortcut = ShortcutDefinition(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        isRecordingShortcut = false
        window?.makeFirstResponder(nil)
        onChange?(shortcut)
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        let fill = isRecordingShortcut
            ? NSColor.controlAccentColor.withAlphaComponent(0.14)
            : (hovered ? NSColor.controlBackgroundColor.blended(withFraction: 0.08, of: .labelColor) ?? .controlBackgroundColor : .controlBackgroundColor)
        fill.setFill()
        path.fill()
        (isRecordingShortcut ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecordingShortcut ? 2 : 1
        path.stroke()

        let text = isRecordingShortcut ? "Press shortcut…" : shortcut.displayString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: isRecordingShortcut ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)

    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    private static func keyLabel(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_DownArrow: return "↓"
        case kVK_UpArrow: return "↑"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default:
            if let number = functionKeyNumbers[Int(event.keyCode)] { return "F\(number)" }
            return event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
    }

    private static let functionKeyNumbers: [Int: Int] = [
            kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5,
            kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
            kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15,
            kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20
        ]
}
