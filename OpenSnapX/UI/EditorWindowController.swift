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
    private let colorLabel = NSTextField(labelWithString: "#FF0000")
    private let widthLabel = NSTextField(labelWithString: "4 pt")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var toolButtons: [EditorTool: EditorChromeButton] = [:]
    private var moreToolsButton: EditorChromeButton?
    private var persistTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private weak var editorBar: NSView?

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
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.minSize = CGSize(width: 840, height: 520)
        super.init(window: window)
        window.delegate = self
        configureUI()
        canvas.onAnnotationsChanged = { [weak self] annotations in self?.annotationsChanged(annotations) }
        canvas.onOCRSelection = { [weak self] result in self?.copyOCRResult(result) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handleLocalKeyDown(event)
        }
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        alignWindowControls()
        DispatchQueue.main.async { [weak self] in self?.alignWindowControls() }
    }

    func windowDidResize(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.alignWindowControls() }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.alignWindowControls() }
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        persistTask?.cancel()
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
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

        let editorBar = makeEditorBar()
        self.editorBar = editorBar
        root.addArrangedSubview(editorBar)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 4
        let canvasBackground = NSColor.windowBackgroundColor.blended(withFraction: 0.08, of: .black) ?? .windowBackgroundColor
        let clipView = CenteredClipView()
        clipView.drawsBackground = true
        clipView.backgroundColor = canvasBackground
        scrollView.contentView = clipView
        scrollView.backgroundColor = canvasBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        canvas.frame = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        scrollView.documentView = canvas
        root.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            editorBar.heightAnchor.constraint(equalToConstant: 52)
        ])
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            content.layoutSubtreeIfNeeded()
            let fit = min(
                self.scrollView.contentSize.width / CGFloat(self.sourceImage.width),
                self.scrollView.contentSize.height / CGFloat(self.sourceImage.height),
                1
            )
            self.scrollView.magnification = max(0.1, fit * 0.92)
            self.scrollView.contentView.scroll(to: self.scrollView.contentView.bounds.origin)
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            self.updateZoomLabel()
        }
    }

    private func makeEditorBar() -> NSView {
        let bar = EditorTitlebarView()
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        bar.state = .followsWindowActiveState

        let controls = chromeStack(spacing: 4)
        controls.addArrangedSubview(makeExportStrip())
        controls.addArrangedSubview(chromeSeparator())
        controls.addArrangedSubview(makeHistoryStrip())
        controls.addArrangedSubview(chromeSeparator())
        controls.addArrangedSubview(makeToolStrip())
        let info = makeInfoStrip()

        controls.translatesAutoresizingMaskIntoConstraints = false
        info.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(controls)
        bar.addSubview(info)

        controls.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        info.setContentHuggingPriority(.required, for: .horizontal)
        info.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 92),
            controls.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: info.leadingAnchor, constant: -10),
            info.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            info.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        return bar
    }

    private func makeExportStrip() -> NSView {
        let stack = chromeStack(spacing: 4)
        stack.addArrangedSubview(chromeButton(symbol: "doc.on.doc", label: "Copy") { [weak self] in self?.copyRendered() })
        stack.addArrangedSubview(chromeButton(symbol: "square.and.arrow.down", label: "Save") { [weak self] in self?.saveRendered() })
        return stack
    }

    private func makeHistoryStrip() -> NSView {
        let stack = chromeStack(spacing: 4)
        stack.addArrangedSubview(chromeButton(symbol: "arrow.uturn.backward", label: "Undo") { [weak self] in self?.undo() })
        stack.addArrangedSubview(chromeButton(symbol: "arrow.uturn.forward", label: "Redo") { [weak self] in self?.redo() })
        return stack
    }

    private func makeToolStrip() -> NSView {
        let stack = chromeStack(spacing: 2)
        let primaryTools: [EditorTool] = [.select, .arrow, .line, .text, .counter, .rectangle, .ellipse, .pen, .highlighter]
        for tool in primaryTools {
            let button = EditorChromeButton(
                symbol: tool.symbol,
                label: tool.rawValue.capitalized,
                showsSelection: true
            ) { [weak self] in self?.selectTool(tool) }
            button.toolTip = tool.rawValue.capitalized
            button.setSelected(tool == canvas.tool)
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }

        let more = EditorChromeButton(
            symbol: "ellipsis",
            label: "More tools and actions",
            showsSelection: true
        ) { [weak self] in
            guard let self, let button = self.moreToolsButton else { return }
            self.showMoreTools(button)
        }
        more.toolTip = "More tools and actions"
        moreToolsButton = more
        stack.addArrangedSubview(more)
        return stack
    }

    private func makeInfoStrip() -> NSView {
        let colorGroup = makeColorInfo()
        let widthGroup = makeWidthInfo()
        let scale = max(1, session.manifest.displayScale)
        let width = CGFloat(sourceImage.width) / scale
        let height = CGFloat(sourceImage.height) / scale
        let sizeGroup = metadataGroup(
            value: "\(formattedDimension(width))×\(formattedDimension(height))pt",
            caption: "Image size"
        )
        let zoomGroup = metadataGroup(valueLabel: zoomLabel, caption: "Zoom")

        let stack = NSStackView(views: [
            colorGroup,
            chromeSeparator(),
            widthGroup,
            chromeSeparator(),
            sizeGroup,
            chromeSeparator(),
            zoomGroup
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
        return stack
    }

    private func makeColorInfo() -> NSView {
        colorWell.color = .systemRed
        colorWell.colorWellStyle = .minimal
        colorWell.target = self
        colorWell.action = #selector(styleChanged)
        colorWell.toolTip = "Annotation color"
        colorWell.setAccessibilityLabel("Annotation color")
        colorWell.widthAnchor.constraint(equalToConstant: 22).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true

        colorLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        colorLabel.textColor = .labelColor
        colorLabel.isSelectable = false
        colorLabel.toolTip = "Press Tab to copy"
        let caption = NSTextField(labelWithString: "Tab to copy")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [colorLabel, caption])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0

        let row = NSStackView(views: [colorWell, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let copyClick = NSClickGestureRecognizer(target: self, action: #selector(copyColorHex))
        colorLabel.addGestureRecognizer(copyClick)
        colorLabel.setAccessibilityLabel("Color hex, click or press Tab to copy")
        updateStyleLabels()
        return row
    }

    private func makeWidthInfo() -> NSView {
        widthLabel.font = .systemFont(ofSize: 13, weight: .medium)
        widthLabel.textColor = .labelColor
        widthLabel.alignment = .left
        widthLabel.toolTip = "Click to adjust stroke width"

        let caption = NSTextField(labelWithString: "Stroke")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [widthLabel, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.button)
        stack.setAccessibilityLabel("Stroke width")

        let click = NSClickGestureRecognizer(target: self, action: #selector(showStrokePopover(_:)))
        stack.addGestureRecognizer(click)
        updateStyleLabels()
        return stack
    }

    @objc private func showStrokePopover(_ sender: NSClickGestureRecognizer) {
        guard let anchor = sender.view else { return }
        widthSlider.target = self
        widthSlider.action = #selector(styleChanged)
        widthSlider.controlSize = .small
        widthSlider.frame = CGRect(x: 0, y: 0, width: 140, height: 24)

        let container = NSView(frame: CGRect(x: 0, y: 0, width: 168, height: 44))
        widthSlider.frame = CGRect(x: 14, y: 10, width: 140, height: 24)
        if widthSlider.superview != container {
            widthSlider.removeFromSuperview()
            container.addSubview(widthSlider)
        }

        let popover = NSPopover()
        popover.contentSize = container.frame.size
        popover.behavior = .transient
        popover.animates = true
        let controller = NSViewController()
        controller.view = container
        popover.contentViewController = controller
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func metadataGroup(value: String, caption: String) -> NSView {
        let label = NSTextField(labelWithString: value)
        return metadataGroup(valueLabel: label, caption: caption)
    }

    private func metadataGroup(valueLabel: NSTextField, caption: String) -> NSView {
        valueLabel.font = .systemFont(ofSize: 13, weight: .medium)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .left
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [valueLabel, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        return stack
    }

    private func chromeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.alphaValue = 0.4
        box.setContentHuggingPriority(.required, for: .horizontal)
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return box
    }

    private func chromeStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func chromeButton(symbol: String, label: String, action: @escaping () -> Void) -> EditorChromeButton {
        let button = EditorChromeButton(symbol: symbol, label: label, showsSelection: false, action: action)
        button.toolTip = label
        return button
    }

    private func alignWindowControls() {
        guard let window,
              !window.styleMask.contains(.fullScreen),
              let editorBar else { return }
        editorBar.layoutSubtreeIfNeeded()
        let barCenterInWindow = editorBar.convert(
            CGPoint(x: editorBar.bounds.midX, y: editorBar.bounds.midY),
            to: nil
        ).y
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(buttonType),
                  let container = button.superview else { continue }
            let centerInContainer = container.convert(CGPoint(x: 0, y: barCenterInWindow), from: nil).y
            var origin = button.frame.origin
            origin.y = (centerInContainer - button.frame.height / 2).rounded()
            button.setFrameOrigin(origin)
        }
    }

    private func selectTool(_ tool: EditorTool) {
        canvas.tool = tool
        for (candidate, button) in toolButtons {
            button.setSelected(candidate == tool)
        }
        moreToolsButton?.setSelected(toolButtons[tool] == nil)
        applyStyle()
    }

    @objc private func showMoreTools(_ sender: NSView) {
        let menu = NSMenu(title: "More tools")
        for tool in [EditorTool.blur, .pixelate, .redact, .crop] {
            let item = NSMenuItem(title: tool.rawValue.capitalized, action: #selector(selectToolFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tool.rawValue
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: item.title)
            item.state = canvas.tool == tool ? .on : .off
            if tool == .redact {
                item.toolTip = "Redact securely in exports; the editable source stays in local history"
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let recognize = NSMenuItem(title: "Recognize Text", action: #selector(recognizeText), keyEquivalent: "")
        recognize.target = self
        recognize.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: recognize.title)
        menu.addItem(recognize)
        let backdrop = NSMenuItem(title: "Backdrop…", action: #selector(showBackdrop), keyEquivalent: "")
        backdrop.target = self
        backdrop.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: backdrop.title)
        menu.addItem(backdrop)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func selectToolFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let tool = EditorTool(rawValue: rawValue) else { return }
        selectTool(tool)
    }

    @objc private func styleChanged() {
        updateStyleLabels()
        applyStyle()
    }

    @objc private func copyColorHex() {
        let hex = hexString(for: colorWell.color)
        exportService.copyText(hex)
        showTransientMessage("Copied \(hex)")
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> NSEvent? {
        // Shottr-style: Tab copies the active color hex when a text field is not focused.
        guard event.keyCode == 48,
              !(window?.firstResponder is NSTextView),
              !(window?.firstResponder is NSTextField) else {
            return event
        }
        copyColorHex()
        return nil
    }

    @objc private func clipViewBoundsChanged() {
        updateZoomLabel()
    }

    private func updateStyleLabels() {
        colorLabel.stringValue = hexString(for: colorWell.color)
        widthLabel.stringValue = "\(Int(widthSlider.doubleValue.rounded())) pt"
    }

    private func updateZoomLabel() {
        zoomLabel.stringValue = "\(Int((scrollView.magnification * 100).rounded()))%"
    }

    private func hexString(for color: NSColor) -> String {
        guard let color = color.usingColorSpace(.sRGB) else { return "#FF0000" }
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }

    private func formattedDimension(_ value: CGFloat) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

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
private final class EditorTitlebarView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
private final class EditorChromeButton: NSButton {
    private let closure: () -> Void
    private let showsSelection: Bool
    private var isHovered = false

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
        setAccessibilityLabel(label)
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
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
private final class CenteredClipView: NSClipView {
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
