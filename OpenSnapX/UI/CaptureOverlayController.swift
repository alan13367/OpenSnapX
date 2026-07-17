import AppKit
import CoreGraphics

struct OverlaySelection: Sendable {
    let mode: CaptureMode
    let displayID: UInt32
    let screenRect: CanvasRect
    let pixelRect: CanvasRect
    let windowID: UInt32?
}

@MainActor
final class CaptureOverlayController {
    private var windows: [NSPanel] = []
    private var continuation: CheckedContinuation<OverlaySelection, Error>?
    private var completed = false

    func select(
        mode: CaptureMode,
        candidates: [WindowCandidate] = [],
        frozenDisplays: [UInt32: CGImage] = [:]
    ) async throws -> OverlaySelection {
        cancelExisting()
        completed = false
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                guard let displayID = DisplayGeometry.displayID(for: screen) else { continue }
                let panel = OverlayPanel(
                    contentRect: screen.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false,
                    screen: screen
                )
                panel.level = .screenSaver
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                panel.ignoresMouseEvents = false
                panel.acceptsMouseMovedEvents = true
                let view = CaptureOverlayView(
                    screen: screen,
                    displayID: displayID,
                    mode: mode,
                    candidates: candidates,
                    frozenImage: frozenDisplays[displayID]
                )
                view.onComplete = { [weak self] result in self?.finish(result) }
                view.onCancel = { [weak self] in self?.cancel() }
                panel.contentView = view
                windows.append(panel)
                panel.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
            windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
        }
    }

    func cancel() {
        guard !completed else { return }
        completed = true
        closeWindows()
        continuation?.resume(throwing: OpenSnapXError.selectionCancelled)
        continuation = nil
    }

    private func finish(_ selection: OverlaySelection) {
        guard !completed else { return }
        completed = true
        closeWindows()
        continuation?.resume(returning: selection)
        continuation = nil
    }

    private func cancelExisting() {
        if continuation != nil { cancel() }
        closeWindows()
    }

    private func closeWindows() {
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows.removeAll()
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class CaptureOverlayView: NSView {
    var onComplete: ((OverlaySelection) -> Void)?
    var onCancel: (() -> Void)?

    private let captureScreen: NSScreen
    private let displayID: UInt32
    private let candidates: [WindowCandidate]
    private let frozenImage: CGImage?
    private var mode: CaptureMode
    private var selection: CGRect = .zero
    private var dragAnchor: CGPoint?
    private var originalSelection: CGRect = .zero
    private var isMoving = false
    private var didMove = false
    private var hoveredWindow: WindowCandidate?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        screen: NSScreen,
        displayID: UInt32,
        mode: CaptureMode,
        candidates: [WindowCandidate],
        frozenImage: CGImage?
    ) {
        captureScreen = screen
        self.displayID = displayID
        self.mode = mode
        self.candidates = candidates
        self.frozenImage = frozenImage
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: mode == .window ? .pointingHand : Self.precisionCursor)
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .window else { return }
        hoveredWindow = candidate(at: event.locationInWindow)
        selection = hoveredWindow.map(localFrame(for:)) ?? .zero
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if mode == .window {
            if let selectedWindow = hoveredWindow ?? candidate(at: event.locationInWindow) {
                complete(windowCandidate: selectedWindow)
            }
            return
        }
        dragAnchor = point
        didMove = false
        if selection.insetBy(dx: -5, dy: -5).contains(point), !selection.isEmpty {
            isMoving = true
            originalSelection = selection
        } else {
            isMoving = false
            selection = CGRect(origin: point, size: .zero)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragAnchor else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        didMove = hypot(point.x - dragAnchor.x, point.y - dragAnchor.y) > 2
        if isMoving {
            let delta = CGPoint(x: point.x - dragAnchor.x, y: point.y - dragAnchor.y)
            selection = originalSelection.offsetBy(dx: delta.x, dy: delta.y)
            selection.origin.x = min(max(0, selection.origin.x), bounds.width - selection.width)
            selection.origin.y = min(max(0, selection.origin.y), bounds.height - selection.height)
        } else {
            selection = CGRect(
                x: min(dragAnchor.x, point.x),
                y: min(dragAnchor.y, point.y),
                width: abs(point.x - dragAnchor.x),
                height: abs(point.y - dragAnchor.y)
            )
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragAnchor = nil }
        let isValidSelection = selection.width >= 2 && selection.height >= 2
        let shouldCaptureNewSelection = !isMoving && isValidSelection
        let shouldCaptureExistingSelection = isMoving && !didMove && isValidSelection
        isMoving = false
        if shouldCaptureNewSelection || shouldCaptureExistingSelection {
            completeSelection()
            return
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onCancel?()
        case 36, 76:
            completeSelection()
        case 49:
            mode = mode == .window ? .region : .window
            selection = .zero
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        case 123, 124, 125, 126:
            nudgeSelection(keyCode: event.keyCode, amount: event.modifierFlags.contains(.shift) ? 10 : 1)
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let frozenImage, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.interpolationQuality = .none
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(frozenImage, in: bounds)
            context.restoreGState()
        }
        NSColor.black.withAlphaComponent(0.36).setFill()
        let dim = NSBezierPath(rect: bounds)
        if !selection.isEmpty {
            dim.appendRect(selection)
            dim.windingRule = .evenOdd
        }
        dim.fill()

        guard !selection.isEmpty else {
            drawHint("Drag and release to capture • Space selects a window • Esc cancels", at: CGPoint(x: bounds.midX, y: bounds.maxY - 44))
            return
        }
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 2
        outline.stroke()
        drawHandles()
        let scale = captureScreen.backingScaleFactor
        let dimensions = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded()))"
        drawHint(dimensions, at: CGPoint(x: selection.midX, y: max(24, selection.minY - 24)))
        drawHint(dragAnchor != nil ? "Release to capture • Esc cancels" : "Arrow keys adjust • ↩ captures • Esc cancels", at: CGPoint(x: selection.midX, y: min(bounds.maxY - 24, selection.maxY + 30)))
    }

    private func drawHandles() {
        NSColor.white.setFill()
        let points = [
            CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.midX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
            CGPoint(x: selection.minX, y: selection.midY), CGPoint(x: selection.maxX, y: selection.midY),
            CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.midX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY)
        ]
        for point in points { NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill() }
    }

    private static let precisionCursor: NSCursor = {
        let center = CGPoint(x: 12, y: 12)
        let image = NSImage(size: CGSize(width: 24, height: 24), flipped: false) { _ in
            let crosshair = NSBezierPath()
            crosshair.move(to: CGPoint(x: 1.5, y: center.y))
            crosshair.line(to: CGPoint(x: 9, y: center.y))
            crosshair.move(to: CGPoint(x: 15, y: center.y))
            crosshair.line(to: CGPoint(x: 22.5, y: center.y))
            crosshair.move(to: CGPoint(x: center.x, y: 1.5))
            crosshair.line(to: CGPoint(x: center.x, y: 9))
            crosshair.move(to: CGPoint(x: center.x, y: 15))
            crosshair.line(to: CGPoint(x: center.x, y: 22.5))
            crosshair.lineCapStyle = .round

            NSColor.black.withAlphaComponent(0.82).setStroke()
            crosshair.lineWidth = 3
            crosshair.stroke()
            NSColor.white.withAlphaComponent(0.96).setStroke()
            crosshair.lineWidth = 1
            crosshair.stroke()

            NSColor.black.withAlphaComponent(0.88).setFill()
            NSBezierPath(ovalIn: CGRect(x: 10.5, y: 10.5, width: 3, height: 3)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: 11.5, y: 11.5, width: 1, height: 1)).fill()
            return true
        }
        image.isTemplate = false
        return NSCursor(image: image, hotSpot: center)
    }()

    private func drawHint(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        let frame = CGRect(x: point.x - size.width / 2 - 10, y: point.y - size.height / 2 - 5, width: size.width + 20, height: size.height + 10)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
        text.draw(at: CGPoint(x: frame.minX + 10, y: frame.minY + 5), withAttributes: attributes)
    }

    private func nudgeSelection(keyCode: UInt16, amount: CGFloat) {
        guard !selection.isEmpty else { return }
        switch keyCode {
        case 123: selection.origin.x -= amount
        case 124: selection.origin.x += amount
        case 125: selection.origin.y += amount
        case 126: selection.origin.y -= amount
        default: break
        }
        selection.origin.x = min(max(0, selection.origin.x), bounds.width - selection.width)
        selection.origin.y = min(max(0, selection.origin.y), bounds.height - selection.height)
        needsDisplay = true
    }

    private func completeSelection() {
        guard selection.width >= 2, selection.height >= 2, let window else { return }
        let windowRect = convert(selection, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        let pixelRect = DisplayGeometry.pixelRect(from: screenRect, on: captureScreen)
        onComplete?(OverlaySelection(
            mode: mode,
            displayID: displayID,
            screenRect: CanvasRect(screenRect),
            pixelRect: CanvasRect(pixelRect),
            windowID: nil
        ))
    }

    private func complete(windowCandidate: WindowCandidate) {
        guard let screen = DisplayGeometry.screen(containing: CGPoint(x: windowCandidate.frame.midX, y: windowCandidate.frame.midY)) else { return }
        let pixelRect = DisplayGeometry.pixelRect(from: windowCandidate.frame, on: screen)
        onComplete?(OverlaySelection(
            mode: .window,
            displayID: DisplayGeometry.displayID(for: screen) ?? displayID,
            screenRect: CanvasRect(windowCandidate.frame),
            pixelRect: CanvasRect(pixelRect),
            windowID: windowCandidate.id
        ))
    }

    private func candidate(at windowPoint: CGPoint) -> WindowCandidate? {
        guard let window else { return nil }
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        return candidates.first { $0.frame.contains(screenPoint) }
    }

    private func localFrame(for candidate: WindowCandidate) -> CGRect {
        guard let window else { return .zero }
        let windowRect = window.convertFromScreen(candidate.frame)
        return convert(windowRect, from: nil)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), bounds.maxX), y: min(max(0, point.y), bounds.maxY))
    }
}
