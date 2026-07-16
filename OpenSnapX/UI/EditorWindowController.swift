import AppKit

enum EditorTool: String, CaseIterable {
    case select
    case arrow
    case line
    case rectangle
    case ellipse
    case text
    case pen
    case highlighter
    case counter
    case blur
    case pixelate
    case redact
    case crop

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .counter: "1.circle"
        case .blur: "drop.halffull"
        case .pixelate: "square.grid.3x3"
        case .redact: "rectangle.fill"
        case .crop: "crop"
        }
    }

    var annotationKind: AnnotationKind? { AnnotationKind(rawValue: rawValue) }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private var session: CaptureSession
    private let sourceImage: CGImage
    private let historyStore: any HistoryStore
    private let renderer: any ImageRenderer
    private let ocrService: any OCRService
    private let exportService: ExportService
    private let canvas: EditorCanvasView
    private let scrollView = NSScrollView()
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 28, target: nil, action: nil)
    private var persistTask: Task<Void, Never>?

    init(
        session: CaptureSession,
        image: CGImage,
        historyStore: any HistoryStore,
        renderer: any ImageRenderer,
        ocrService: any OCRService,
        exportService: ExportService
    ) {
        self.session = session
        sourceImage = image
        self.historyStore = historyStore
        self.renderer = renderer
        self.ocrService = ocrService
        self.exportService = exportService
        canvas = EditorCanvasView(image: image, annotations: session.annotations, ocrResults: session.ocrResults)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenSnapX Editor"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.minSize = CGSize(width: 760, height: 480)
        super.init(window: window)
        window.delegate = self
        configureUI()
        canvas.onAnnotationsChanged = { [weak self] annotations in self?.annotationsChanged(annotations) }
        canvas.onOCRSelection = { [weak self] result in self?.copyOCRResult(result) }
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        persistTask?.cancel()
        let session = self.session
        Task { try? await historyStore.save(session) }
    }

    private func configureUI() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        let toolbar = makeToolbar()
        root.addArrangedSubview(toolbar)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 4
        scrollView.backgroundColor = NSColor.windowBackgroundColor.blended(withFraction: 0.12, of: .black) ?? .windowBackgroundColor
        canvas.frame = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        scrollView.documentView = canvas
        root.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 52)
        ])

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let fit = min(
                self.scrollView.contentSize.width / CGFloat(self.sourceImage.width),
                self.scrollView.contentSize.height / CGFloat(self.sourceImage.height),
                1
            )
            self.scrollView.magnification = max(0.1, fit * 0.92)
        }
    }

    private func makeToolbar() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .headerView
        effect.blendingMode = .withinWindow
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        for tool in EditorTool.allCases {
            let button = EditorToolButton(tool: tool) { [weak self] selected in self?.selectTool(selected) }
            button.isBordered = false
            button.toolTip = tool == .redact
                ? "Redact securely in exports (the editable source remains in local history)"
                : tool.rawValue.capitalized
            button.setAccessibilityLabel(tool.rawValue.capitalized)
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(separator())
        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(styleChanged)
        colorWell.toolTip = "Annotation color"
        stack.addArrangedSubview(colorWell)
        widthSlider.target = self
        widthSlider.action = #selector(styleChanged)
        widthSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        widthSlider.toolTip = "Line width"
        stack.addArrangedSubview(widthSlider)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(toolbarButton("arrow.uturn.backward", "Undo", #selector(undo)))
        stack.addArrangedSubview(toolbarButton("arrow.uturn.forward", "Redo", #selector(redo)))
        stack.addArrangedSubview(toolbarButton("text.viewfinder", "Recognize Text", #selector(recognizeText)))
        stack.addArrangedSubview(toolbarButton("sparkles.rectangle.stack", "Backdrop", #selector(showBackdrop)))
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(toolbarButton("doc.on.doc", "Copy", #selector(copyRendered)))
        stack.addArrangedSubview(toolbarButton("square.and.arrow.down", "Save", #selector(saveRendered)))
        return effect
    }

    private func toolbarButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return box
    }

    private func selectTool(_ tool: EditorTool) {
        canvas.tool = tool
        applyStyle()
    }

    @objc private func styleChanged() { applyStyle() }

    private func applyStyle() {
        canvas.style.strokeColor = RGBAColor(colorWell.color)
        canvas.style.lineWidth = widthSlider.doubleValue
        canvas.style.fillColor = canvas.tool == .redact ? .black : nil
        canvas.style.opacity = canvas.tool == .highlighter ? 0.38 : 1
    }

    private func annotationsChanged(_ annotations: [Annotation]) {
        let previous = session.annotations
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.replaceAnnotations(previous)
        }
        session.annotations = annotations
        schedulePersist()
    }

    private func replaceAnnotations(_ annotations: [Annotation]) {
        let current = session.annotations
        window?.undoManager?.registerUndo(withTarget: self) { target in target.replaceAnnotations(current) }
        session.annotations = annotations
        canvas.annotations = annotations
        schedulePersist()
    }

    @objc private func undo() { window?.undoManager?.undo() }
    @objc private func redo() { window?.undoManager?.redo() }

    @objc private func recognizeText() {
        Task {
            do {
                let results = try await ocrService.recognize(ImagePayload(image: sourceImage))
                session.ocrResults = results
                canvas.ocrResults = results
                schedulePersist()
                if !results.isEmpty {
                    exportService.copyText(results.map(\.text).joined(separator: "\n"))
                    showTransientMessage("Recognized \(results.count) text regions and copied them.")
                } else {
                    showTransientMessage("No text was recognized.")
                }
            } catch { present(error) }
        }
    }

    @objc private func showBackdrop() {
        guard let window else { return }
        let controller = BackdropPanelController(configuration: session.manifest.backdrop) { [weak self] configuration in
            self?.session.manifest.backdrop = configuration
            self?.schedulePersist()
        }
        window.beginSheet(controller.window!)
    }

    @objc private func copyRendered() {
        do { exportService.copy(try renderedImage()) } catch { present(error) }
    }

    @objc private func saveRendered() {
        Task {
            do { _ = try await exportService.save(try renderedImage()) } catch { present(error) }
        }
    }

    private func renderedImage() throws -> CGImage {
        try renderer.render(source: ImagePayload(image: sourceImage), session: session, options: ExportOptions()).image
    }

    private func copyOCRResult(_ result: OCRResult) {
        exportService.copyText(result.text)
        showTransientMessage("Copied “\(result.text)”")
    }

    private func schedulePersist() {
        persistTask?.cancel()
        let session = self.session
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            try? await historyStore.save(session)
        }
    }

    private func showTransientMessage(_ text: String) {
        guard let content = window?.contentView else { return }
        let label = NSTextField(labelWithString: text)
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.92).cgColor
        label.layer?.cornerRadius = 8
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            label.heightAnchor.constraint(equalToConstant: 34)
        ])
        Task {
            try? await Task.sleep(for: .seconds(2))
            label.removeFromSuperview()
        }
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
    }
}

@MainActor
private final class EditorToolButton: NSButton {
    private let tool: EditorTool
    private let closure: (EditorTool) -> Void

    init(tool: EditorTool, action: @escaping (EditorTool) -> Void) {
        self.tool = tool
        closure = action
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.rawValue)
        target = self
        self.action = #selector(invoke)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { closure(tool) }
}

@MainActor
final class EditorCanvasView: NSView {
    var tool: EditorTool = .select
    var style = AnnotationStyle()
    var annotations: [Annotation] { didSet { needsDisplay = true } }
    var ocrResults: [OCRResult] { didSet { needsDisplay = true } }
    var onAnnotationsChanged: (([Annotation]) -> Void)?
    var onOCRSelection: ((OCRResult) -> Void)?

    private let image: CGImage
    private var draft: Annotation?
    private var selectedID: UUID?
    private var dragStart: CGPoint?
    private var originalFrame: CGRect?
    private var isResizing = false
    private var copiedAnnotation: Annotation?
    private var counter = 1

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage, annotations: [Annotation], ocrResults: [OCRResult]) {
        self.image = image
        self.annotations = annotations
        self.ocrResults = ocrResults
        super.init(frame: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        wantsLayer = true
        setAccessibilityRole(.image)
        setAccessibilityLabel("Screenshot annotation canvas")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
        for annotation in annotations + (draft.map { [$0] } ?? []) { draw(annotation) }
        drawOCR()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let result = ocrResult(at: point) {
            onOCRSelection?(result)
            return
        }
        dragStart = point
        if tool == .select {
            if let selectedID,
               let selected = annotations.first(where: { $0.id == selectedID }),
               resizeHandle(for: selected.frame.cgRect).contains(point) {
                isResizing = true
            } else {
                selectedID = annotations.last(where: { $0.frame.cgRect.insetBy(dx: -5, dy: -5).contains(point) })?.id
                isResizing = false
            }
            originalFrame = selectedID.flatMap { id in annotations.first(where: { $0.id == id })?.frame.cgRect }
        } else if let kind = tool.annotationKind {
            draft = Annotation(kind: kind, frame: CanvasRect(CGRect(origin: point, size: .zero)), points: [CanvasPoint(point)], style: style)
            if kind == .counter { draft?.counter = counter }
            if kind == .text { draft?.text = "Text" }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        if tool == .select, let id = selectedID, let originalFrame {
            if let index = annotations.firstIndex(where: { $0.id == id }) {
                if isResizing {
                    annotations[index].frame = CanvasRect(CGRect(
                        x: originalFrame.minX,
                        y: originalFrame.minY,
                        width: max(4, originalFrame.width + point.x - start.x),
                        height: max(4, originalFrame.height + point.y - start.y)
                    ))
                } else {
                    let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
                    annotations[index].frame = CanvasRect(originalFrame.offsetBy(dx: delta.x, dy: delta.y))
                }
            }
        } else if var draft {
            let frame = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            draft.frame = CanvasRect(frame)
            if draft.kind == .pen || draft.kind == .highlighter {
                draft.points.append(CanvasPoint(point))
            } else {
                draft.points = [CanvasPoint(start), CanvasPoint(point)]
            }
            self.draft = draft
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; originalFrame = nil; isResizing = false }
        if tool == .select {
            onAnnotationsChanged?(annotations)
            return
        }
        guard var draft else { return }
        self.draft = nil
        if draft.frame.cgRect.width < 2 && draft.frame.cgRect.height < 2 {
            draft.frame = CanvasRect(CGRect(x: draft.frame.x - 16, y: draft.frame.y - 16, width: 32, height: 32))
        }
        if draft.kind == .text, let text = requestText(), !text.isEmpty { draft.text = text }
        if draft.kind == .counter { counter += 1 }
        annotations.append(draft)
        selectedID = draft.id
        onAnnotationsChanged?(annotations)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            guard let selectedID else { return }
            annotations.removeAll { $0.id == selectedID }
            self.selectedID = nil
            onAnnotationsChanged?(annotations)
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c",
                  let selectedID, let selected = annotations.first(where: { $0.id == selectedID }) {
            copiedAnnotation = selected
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v", var copy = copiedAnnotation {
            copy.id = UUID()
            copy.frame = CanvasRect(copy.frame.cgRect.offsetBy(dx: 12, dy: 12))
            annotations.append(copy)
            selectedID = copy.id
            onAnnotationsChanged?(annotations)
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "d",
                  let selectedID, let selected = annotations.first(where: { $0.id == selectedID }) {
            var copy = selected
            copy.id = UUID()
            copy.frame = CanvasRect(copy.frame.cgRect.offsetBy(dx: 12, dy: 12))
            annotations.append(copy)
            self.selectedID = copy.id
            onAnnotationsChanged?(annotations)
        } else {
            super.keyDown(with: event)
        }
    }

    private func draw(_ annotation: Annotation) {
        let frame = annotation.frame.cgRect
        let color = annotation.style.strokeColor.nsColor.withAlphaComponent(annotation.style.opacity)
        color.setStroke()
        (annotation.style.fillColor?.nsColor ?? .clear).setFill()
        let path = NSBezierPath()
        path.lineWidth = annotation.style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch annotation.kind {
        case .arrow, .line:
            let start = annotation.points.first?.cgPoint ?? frame.origin
            let end = annotation.points.last?.cgPoint ?? CGPoint(x: frame.maxX, y: frame.maxY)
            path.move(to: start); path.line(to: end); path.stroke()
            if annotation.kind == .arrow { drawArrow(from: start, to: end, style: annotation.style) }
        case .rectangle, .redact, .blur, .pixelate, .crop:
            let rectPath = NSBezierPath(rect: frame)
            if annotation.kind == .redact { (annotation.style.fillColor?.nsColor ?? .black).setFill(); rectPath.fill() }
            else if annotation.kind == .blur || annotation.kind == .pixelate {
                NSColor.systemGray.withAlphaComponent(0.34).setFill(); rectPath.fill(); rectPath.stroke()
            } else if annotation.kind == .crop {
                let dash: [CGFloat] = [8, 4]; rectPath.setLineDash(dash, count: 2, phase: 0); rectPath.stroke()
            } else { if annotation.style.fillColor != nil { rectPath.fill() }; rectPath.stroke() }
        case .ellipse:
            let ellipse = NSBezierPath(ovalIn: frame); if annotation.style.fillColor != nil { ellipse.fill() }; ellipse.stroke()
        case .pen, .highlighter:
            guard let first = annotation.points.first else { break }
            if annotation.kind == .highlighter { annotation.style.strokeColor.nsColor.withAlphaComponent(0.38).setStroke() }
            path.move(to: first.cgPoint)
            for point in annotation.points.dropFirst() { path.line(to: point.cgPoint) }
            path.stroke()
        case .text:
            (annotation.text ?? "Text").draw(in: frame, withAttributes: [
                .font: NSFont.systemFont(ofSize: annotation.style.fontSize, weight: .medium),
                .foregroundColor: color
            ])
        case .counter:
            color.setFill(); NSBezierPath(ovalIn: frame).fill()
            let value = String(annotation.counter ?? 1)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: annotation.style.fontSize, weight: .bold), .foregroundColor: NSColor.white]
            let size = value.size(withAttributes: attributes)
            value.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), withAttributes: attributes)
        }
        if annotation.id == selectedID {
            NSColor.controlAccentColor.setStroke()
            let selectionPath = NSBezierPath(rect: frame.insetBy(dx: -4, dy: -4)); selectionPath.lineWidth = 1; selectionPath.stroke()
            NSColor.white.setFill()
            NSColor.controlAccentColor.setStroke()
            let handle = NSBezierPath(roundedRect: resizeHandle(for: frame), xRadius: 2, yRadius: 2)
            handle.fill(); handle.stroke()
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, style: AnnotationStyle) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(10, style.lineWidth * 3.5)
        let spread = CGFloat.pi / 7
        let head = NSBezierPath()
        head.lineWidth = style.lineWidth
        head.move(to: end)
        head.line(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
        head.move(to: end)
        head.line(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
        head.stroke()
    }

    private func drawOCR() {
        guard !ocrResults.isEmpty else { return }
        NSColor.systemCyan.withAlphaComponent(0.85).setStroke()
        for result in ocrResults {
            let normalized = result.normalizedBounds.cgRect
            let frame = CGRect(x: normalized.minX * bounds.width, y: normalized.minY * bounds.height, width: normalized.width * bounds.width, height: normalized.height * bounds.height)
            let path = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private func ocrResult(at point: CGPoint) -> OCRResult? {
        ocrResults.first {
            let normalized = $0.normalizedBounds.cgRect
            return CGRect(x: normalized.minX * bounds.width, y: normalized.minY * bounds.height, width: normalized.width * bounds.width, height: normalized.height * bounds.height).contains(point)
        }
    }

    private func requestText() -> String? {
        let alert = NSAlert()
        alert.messageText = "Text Annotation"
        let field = NSTextField(string: "Text")
        field.frame = CGRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func resizeHandle(for frame: CGRect) -> CGRect {
        CGRect(x: frame.maxX - 6, y: frame.maxY - 6, width: 12, height: 12)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), bounds.maxX), y: min(max(0, point.y), bounds.maxY))
    }
}

@MainActor
private final class BackdropPanelController: NSWindowController {
    private var configuration: BackdropConfiguration
    private let onSave: (BackdropConfiguration) -> Void
    private let enabled = NSButton(checkboxWithTitle: "Enable backdrop", target: nil, action: nil)
    private let padding = NSSlider(value: 48, minValue: 0, maxValue: 180, target: nil, action: nil)
    private let radius = NSSlider(value: 16, minValue: 0, maxValue: 64, target: nil, action: nil)
    private let shadow = NSSlider(value: 18, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let gradient = NSButton(checkboxWithTitle: "Gradient", target: nil, action: nil)
    private let startColor = NSColorWell()
    private let endColor = NSColorWell()
    private let aspect = NSPopUpButton()

    init(configuration: BackdropConfiguration, onSave: @escaping (BackdropConfiguration) -> Void) {
        self.configuration = configuration
        self.onSave = onSave
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 410), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Backdrop"
        super.init(window: window)
        configure()
    }

    required init?(coder: NSCoder) { nil }

    private func configure() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        enabled.state = configuration.isEnabled ? .on : .off
        padding.doubleValue = configuration.padding
        radius.doubleValue = configuration.cornerRadius
        shadow.doubleValue = configuration.shadowRadius
        gradient.state = configuration.useGradient ? .on : .off
        startColor.color = configuration.startColor.nsColor
        endColor.color = configuration.endColor.nsColor
        aspect.addItems(withTitles: ["Automatic", "1:1", "4:3", "16:9"])
        aspect.selectItem(at: BackdropAspect.allCases.firstIndex(of: configuration.aspect) ?? 0)
        stack.addArrangedSubview(enabled)
        stack.addArrangedSubview(labeled("Padding", padding))
        stack.addArrangedSubview(labeled("Corner radius", radius))
        stack.addArrangedSubview(labeled("Shadow", shadow))
        stack.addArrangedSubview(gradient)
        let colors = NSStackView(views: [startColor, endColor])
        colors.orientation = .horizontal
        colors.spacing = 12
        stack.addArrangedSubview(labeled("Colors", colors))
        stack.addArrangedSubview(labeled("Canvas", aspect))
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.addArrangedSubview(NSButton(title: "Cancel", target: self, action: #selector(cancel)))
        buttons.addArrangedSubview(NSButton(title: "Apply", target: self, action: #selector(apply)))
        stack.addArrangedSubview(buttons)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func labeled(_ text: String, _ control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        let label = NSTextField(labelWithString: text)
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        row.addArrangedSubview(label); row.addArrangedSubview(control)
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return row
    }

    @objc private func cancel() { window?.sheetParent?.endSheet(window!) }
    @objc private func apply() {
        configuration.isEnabled = enabled.state == .on
        configuration.padding = padding.doubleValue
        configuration.cornerRadius = radius.doubleValue
        configuration.shadowRadius = shadow.doubleValue
        configuration.useGradient = gradient.state == .on
        configuration.startColor = RGBAColor(startColor.color)
        configuration.endColor = RGBAColor(endColor.color)
        configuration.aspect = BackdropAspect.allCases[aspect.indexOfSelectedItem]
        onSave(configuration)
        cancel()
    }
}
