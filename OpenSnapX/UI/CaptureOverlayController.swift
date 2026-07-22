import AppKit
import CoreGraphics

struct OverlaySelection: Sendable {
    let mode: CaptureMode
    let displayID: UInt32
    let screenRect: CanvasRect
    let pixelRect: CanvasRect
    let windowID: UInt32?
}

enum CaptureOverlayGeometry {
    static func panelContentRect(for screenFrame: CGRect) -> CGRect {
        CGRect(origin: .zero, size: screenFrame.size)
    }

    static func visibleSelection(_ selection: CGRect, within bounds: CGRect) -> CGRect? {
        let visible = selection.intersection(bounds)
        guard !visible.isNull,
              !visible.isEmpty,
              visible.minX.isFinite,
              visible.minY.isFinite,
              visible.width.isFinite,
              visible.height.isFinite else { return nil }
        return visible
    }

    static func isValidHintPoint(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}

@MainActor
final class CaptureOverlayController {
    private var windows: [NSPanel] = []
    private var views: [CaptureOverlayView] = []
    private var candidates: [WindowCandidate] = []
    private var activeMode: CaptureMode = .region
    private var continuation: CheckedContinuation<OverlaySelection, Error>?
    private var completed = false

    func select(
        mode: CaptureMode,
        candidates: [WindowCandidate] = []
    ) async throws -> OverlaySelection {
        cancelExisting()
        completed = false
        activeMode = mode
        self.candidates = candidates
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let screens = NSScreen.screens
            let desktopFrame = screens.reduce(CGRect.null) { $0.union($1.frame) }
            for screen in screens {
                guard let displayID = DisplayGeometry.displayID(for: screen) else { continue }
                let panel = OverlayPanel(
                    contentRect: CaptureOverlayGeometry.panelContentRect(for: screen.frame),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false,
                    screen: screen
                )
                panel.setFrame(screen.frame, display: false)
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
                    desktopFrame: desktopFrame
                )
                view.onComplete = { [weak self] result in self?.finish(result) }
                view.onCancel = { [weak self] in self?.cancel() }
                view.onWindowHover = { [weak self] candidate in self?.updateHoveredWindow(candidate) }
                view.onModeToggle = { [weak self] in self?.toggleSelectionMode() }
                view.onSelectionChanged = { [weak self] selection in
                    self?.updateRegionSelection(selection)
                }
                panel.contentView = view
                views.append(view)
                windows.append(panel)
                panel.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
            windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
            if activeMode == .window {
                updateHoveredWindow(WindowSelectionEngine.frontmostCandidate(
                    at: NSEvent.mouseLocation,
                    in: candidates
                ))
            }
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

    private func updateHoveredWindow(_ candidate: WindowCandidate?) {
        guard activeMode == .window else { return }
        views.forEach { $0.showHoveredWindow(candidate) }
    }

    private func updateRegionSelection(_ selection: CGRect) {
        guard activeMode != .window else { return }
        views.forEach { $0.showRegionSelection(selection) }
    }

    private func toggleSelectionMode() {
        activeMode = activeMode == .window ? .region : .window
        let hoveredWindow = activeMode == .window
            ? WindowSelectionEngine.frontmostCandidate(at: NSEvent.mouseLocation, in: candidates)
            : nil
        views.forEach { $0.setMode(activeMode, hoveredWindow: hoveredWindow) }
    }

    private func closeWindows() {
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows.removeAll()
        views.removeAll()
        candidates.removeAll()
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class CaptureOverlayView: NSView {
    var onComplete: ((OverlaySelection) -> Void)?
    var onCancel: (() -> Void)?
    var onWindowHover: ((WindowCandidate?) -> Void)?
    var onModeToggle: (() -> Void)?
    var onSelectionChanged: ((CGRect) -> Void)?

    private let captureScreen: NSScreen
    private let displayID: UInt32
    private let candidates: [WindowCandidate]
    private let desktopFrame: CGRect
    private var mode: CaptureMode
    private var screenSelection: CGRect = .zero
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
        desktopFrame: CGRect
    ) {
        captureScreen = screen
        self.displayID = displayID
        self.mode = mode
        self.candidates = candidates
        self.desktopFrame = desktopFrame
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
        let hoveredWindow = candidate(at: event.locationInWindow)
        showHoveredWindow(hoveredWindow)
        onWindowHover?(hoveredWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = screenPoint(for: event)
        if mode == .window {
            if let selectedWindow = candidate(at: event.locationInWindow) {
                showHoveredWindow(selectedWindow)
                onWindowHover?(selectedWindow)
                complete(windowCandidate: selectedWindow)
            }
            return
        }
        dragAnchor = point
        didMove = false
        if screenSelection.insetBy(dx: -5, dy: -5).contains(point), !screenSelection.isEmpty {
            isMoving = true
            originalSelection = screenSelection
        } else {
            isMoving = false
            screenSelection = CGRect(origin: point, size: .zero)
        }
        publishSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragAnchor else { return }
        let point = selectionPoint(for: event)
        didMove = hypot(point.x - dragAnchor.x, point.y - dragAnchor.y) > 2
        if isMoving {
            let delta = CGPoint(x: point.x - dragAnchor.x, y: point.y - dragAnchor.y)
            screenSelection = constrainedToDesktop(
                originalSelection.offsetBy(dx: delta.x, dy: delta.y)
            )
        } else {
            screenSelection = CGRect(
                x: min(dragAnchor.x, point.x),
                y: min(dragAnchor.y, point.y),
                width: abs(point.x - dragAnchor.x),
                height: abs(point.y - dragAnchor.y)
            )
        }
        publishSelection()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragAnchor = nil }
        let isValidSelection = screenSelection.width >= 2 && screenSelection.height >= 2
        let shouldCaptureNewSelection = !isMoving && isValidSelection
        let shouldCaptureExistingSelection = isMoving && !didMove && isValidSelection
        isMoving = false
        if shouldCaptureNewSelection || shouldCaptureExistingSelection {
            completeSelection()
            return
        }
        publishSelection()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onCancel?()
        case 36, 76:
            if mode == .window, let hoveredWindow {
                complete(windowCandidate: hoveredWindow)
            } else {
                completeSelection()
            }
        case 49:
            onModeToggle?()
        case 123, 124, 125, 126:
            nudgeSelection(keyCode: event.keyCode, amount: event.modifierFlags.contains(.shift) ? 10 : 1)
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if mode == .window {
            drawWindowSelection()
            return
        }

        let selection = localFrame(for: screenSelection)
        NSColor.black.withAlphaComponent(0.36).setFill()
        let dim = NSBezierPath(rect: bounds)
        if !screenSelection.isEmpty {
            dim.appendRect(selection)
            dim.windingRule = .evenOdd
        }
        dim.fill()

        guard !screenSelection.isEmpty else {
            if containsMouse {
                drawHint("Drag across any display • Space selects a window • Esc cancels", at: CGPoint(x: bounds.midX, y: bounds.maxY - 44))
            }
            return
        }
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 2
        outline.stroke()
        drawHandles(for: selection)
        if containsMouse,
           let visibleSelection = CaptureOverlayGeometry.visibleSelection(
               selection,
               within: bounds
           ) {
            let scale = NSScreen.screens
                .filter { $0.frame.intersects(screenSelection) }
                .map(\.backingScaleFactor)
                .max() ?? captureScreen.backingScaleFactor
            let dimensions = "\(Int((screenSelection.width * scale).rounded())) × \(Int((screenSelection.height * scale).rounded()))"
            let hintX = min(max(visibleSelection.midX, 80), bounds.maxX - 80)
            drawHint(dimensions, at: CGPoint(x: hintX, y: max(24, visibleSelection.minY - 24)))
            drawHint(dragAnchor != nil ? "Release to capture • Esc cancels" : "Arrow keys adjust • ↩ captures • Esc cancels", at: CGPoint(x: hintX, y: min(bounds.maxY - 24, visibleSelection.maxY + 30)))
        }
    }

    private func drawWindowSelection() {
        NSColor.black.withAlphaComponent(0.16).setFill()
        NSBezierPath(rect: bounds).fill()

        let selection = localFrame(for: screenSelection)
        if !screenSelection.isEmpty, selection.intersects(bounds) {
            let highlight = NSBezierPath(roundedRect: selection, xRadius: 10, yRadius: 10)
            NSColor.systemBlue.withAlphaComponent(0.42).setFill()
            highlight.fill()
            NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
            highlight.lineWidth = 2
            highlight.stroke()
        }

        drawHint(
            screenSelection.isEmpty
                ? "Move over a window • Space selects an area • Esc cancels"
                : "Click to capture • Space selects an area • Esc cancels",
            at: CGPoint(x: bounds.midX, y: bounds.maxY - 44)
        )
    }

    private func drawHandles(for selection: CGRect) {
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
        guard CaptureOverlayGeometry.isValidHintPoint(point) else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        let frame = CGRect(x: point.x - size.width / 2 - 10, y: point.y - size.height / 2 - 5, width: size.width + 20, height: size.height + 10)
        guard frame.minX.isFinite,
              frame.minY.isFinite,
              frame.width.isFinite,
              frame.height.isFinite else { return }
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
        text.draw(at: CGPoint(x: frame.minX + 10, y: frame.minY + 5), withAttributes: attributes)
    }

    private func nudgeSelection(keyCode: UInt16, amount: CGFloat) {
        guard !screenSelection.isEmpty else { return }
        switch keyCode {
        case 123: screenSelection.origin.x -= amount
        case 124: screenSelection.origin.x += amount
        case 125: screenSelection.origin.y -= amount
        case 126: screenSelection.origin.y += amount
        default: break
        }
        screenSelection = constrainedToDesktop(screenSelection)
        publishSelection()
    }

    private func completeSelection() {
        guard screenSelection.width >= 2, screenSelection.height >= 2 else { return }
        let pixelRect = DisplayGeometry.pixelRect(from: screenSelection, on: captureScreen)
        onComplete?(OverlaySelection(
            mode: mode,
            displayID: displayID,
            screenRect: CanvasRect(screenSelection),
            pixelRect: CanvasRect(pixelRect),
            windowID: nil
        ))
    }

    private func complete(windowCandidate: WindowCandidate) {
        let pixelRect = DisplayGeometry.pixelRect(from: windowCandidate.frame, on: captureScreen)
        onComplete?(OverlaySelection(
            mode: .window,
            displayID: displayID,
            screenRect: CanvasRect(windowCandidate.frame),
            pixelRect: CanvasRect(pixelRect),
            windowID: windowCandidate.id
        ))
    }

    func showHoveredWindow(_ candidate: WindowCandidate?) {
        guard mode == .window else { return }
        hoveredWindow = candidate
        screenSelection = candidate?.frame ?? .zero
        needsDisplay = true
    }

    func showRegionSelection(_ selection: CGRect) {
        guard mode != .window else { return }
        screenSelection = selection
        needsDisplay = true
    }

    func setMode(_ mode: CaptureMode, hoveredWindow: WindowCandidate?) {
        self.mode = mode
        screenSelection = .zero
        dragAnchor = nil
        isMoving = false
        self.hoveredWindow = nil
        if mode == .window {
            showHoveredWindow(hoveredWindow)
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func candidate(at windowPoint: CGPoint) -> WindowCandidate? {
        guard let window else { return nil }
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        return WindowSelectionEngine.frontmostCandidate(at: screenPoint, in: candidates)
    }

    private func localFrame(for screenRect: CGRect) -> CGRect {
        guard let window else { return .zero }
        let windowRect = window.convertFromScreen(screenRect)
        return convert(windowRect, from: nil)
    }

    private func clampedLocalPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), bounds.maxX), y: min(max(0, point.y), bounds.maxY))
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    private func selectionPoint(for event: NSEvent) -> CGPoint {
        guard mode != .region, mode != .text, let window else {
            return screenPoint(for: event)
        }
        let localPoint = clampedLocalPoint(convert(event.locationInWindow, from: nil))
        let windowPoint = convert(localPoint, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }

    private func constrainedToDesktop(_ rect: CGRect) -> CGRect {
        var result = rect
        if result.width <= desktopFrame.width {
            result.origin.x = min(max(result.origin.x, desktopFrame.minX), desktopFrame.maxX - result.width)
        }
        if result.height <= desktopFrame.height {
            result.origin.y = min(max(result.origin.y, desktopFrame.minY), desktopFrame.maxY - result.height)
        }
        return result
    }

    private func publishSelection() {
        needsDisplay = true
        onSelectionChanged?(screenSelection)
    }

    private var containsMouse: Bool {
        captureScreen.frame.contains(NSEvent.mouseLocation)
    }
}
