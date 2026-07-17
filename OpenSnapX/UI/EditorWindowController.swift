import AppKit
import CoreImage

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

    var hint: String {
        switch self {
        case .select: "Select and resize edits"
        case .arrow: "Draw an arrow"
        case .line: "Draw a line"
        case .rectangle: "Draw a rectangle"
        case .ellipse: "Draw an ellipse"
        case .text: "Add text"
        case .pen: "Draw freehand"
        case .highlighter: "Highlight an area"
        case .counter: "Add a step number"
        case .blur: "Blur an area"
        case .pixelate: "Pixelate an area"
        case .redact: "Redact an area"
        case .crop: "Crop the image"
        }
    }

    var usesStrokeWidth: Bool {
        switch self {
        case .arrow, .line, .rectangle, .ellipse, .pen, .highlighter: true
        case .select, .text, .counter, .blur, .pixelate, .redact, .crop: false
        }
    }
}

private struct EditorEdits {
    var annotations: [Annotation] = []
    var ocrResults: [OCRResult] = []
    var backdrop = BackdropConfiguration()
    var isOCRSelectionActive = false
}

private struct EditorImageGeometry {
    var annotations: [Annotation]
    var resize: ImageResizeConfiguration?
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private var session: CaptureSession
    private let sourceImage: CGImage
    private let historyStore: any HistoryStore
    private let renderer: any ImageRenderer
    private let ocrService: any OCRService
    private let exportService: ExportService
    private let onSessionSaved: (UUID) -> Void
    private let onDiscardCapture: (UUID) async throws -> Void
    private var initialPersistence: Task<Void, Error>?
    private let canvas: EditorCanvasView
    private let scrollView = NSScrollView()
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 15, minValue: 1, maxValue: 28, target: nil, action: nil)
    private let colorLabel = NSTextField(labelWithString: "#FF0000")
    private let widthLabel = NSTextField(labelWithString: "15 pt")
    private let imageSizeLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var colorPalettePopover: NSPopover?
    private var imageSizePopover: NSPopover?
    private var toolButtons: [EditorTool: EditorChromeButton] = [:]
    private var moreToolsButton: EditorChromeButton?
    private var persistTask: Task<Void, Never>?
    private var transientNoticeTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var backdropPanelController: BackdropPanelController?
    private var transientNotice: EditorTransientNoticeView?
    private var isDiscardingCapture = false
    private weak var editorBar: NSView?
    private var displayedCanvasMagnification: CGFloat = 1
    private var showsLogicalImageSize = true

    init(
        session: CaptureSession,
        image: CGImage,
        historyStore: any HistoryStore,
        renderer: any ImageRenderer,
        ocrService: any OCRService,
        exportService: ExportService,
        initialPersistence: Task<Void, Error>? = nil,
        onSessionSaved: @escaping (UUID) -> Void,
        onDiscardCapture: @escaping (UUID) async throws -> Void
    ) {
        self.session = session
        sourceImage = image
        showsLogicalImageSize = session.manifest.resize == nil
        self.historyStore = historyStore
        self.renderer = renderer
        self.ocrService = ocrService
        self.exportService = exportService
        self.initialPersistence = initialPersistence
        self.onSessionSaved = onSessionSaved
        self.onDiscardCapture = onDiscardCapture
        canvas = EditorCanvasView(
            image: image,
            canvasSize: session.manifest.outputPixelSize,
            annotations: session.annotations,
            ocrResults: session.ocrResults
        )
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
        canvas.onSelectionChanged = { [weak self] annotation in self?.selectionChanged(annotation) }
        canvas.onOCRSelection = { [weak self] results in self?.copyOCRResults(results) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handleLocalKeyDown(event)
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.canvas.commitTextEditingIfClickIsOutside(event)
            return event
        }
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        let shouldCenter = window?.isVisible != true && window?.isMiniaturized != true
        ApplicationPresentation.activateRegularApplication()
        NSApp.unhide(nil)
        showWindow(nil)
        if shouldCenter { window?.center() }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
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
        canvas.commitTextEditing()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        persistTask?.cancel()
        transientNoticeTask?.cancel()
        transientNotice?.removeFromSuperview()
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        guard !isDiscardingCapture else { return }
        let session = self.session
        Task {
            guard (try? await waitForInitialPersistence()) != nil else { return }
            do {
                try await historyStore.save(session)
                onSessionSaved(session.id)
            } catch { return }
        }
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
                self.scrollView.contentSize.width / self.canvas.frame.width,
                self.scrollView.contentSize.height / self.canvas.frame.height,
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
        stack.addArrangedSubview(chromeButton(
            symbol: "doc.on.doc",
            label: "Copy",
            hint: "Copy image"
        ) { [weak self] in self?.copyRendered() })
        stack.addArrangedSubview(chromeButton(
            symbol: "square.and.arrow.down",
            label: "Save",
            hint: "Save image"
        ) { [weak self] in self?.saveRendered() })
        return stack
    }

    private func makeHistoryStrip() -> NSView {
        let stack = chromeStack(spacing: 4)
        stack.addArrangedSubview(chromeButton(
            symbol: "arrow.uturn.backward",
            label: "Undo",
            hint: "Undo last edit"
        ) { [weak self] in self?.undo() })
        stack.addArrangedSubview(chromeButton(
            symbol: "arrow.uturn.forward",
            label: "Redo",
            hint: "Redo last edit"
        ) { [weak self] in self?.redo() })
        stack.addArrangedSubview(chromeButton(
            symbol: "eraser",
            label: "Clear all edits",
            hint: "Clear all edits • Undoable"
        ) { [weak self] in self?.clearAllEdits() })
        stack.addArrangedSubview(chromeSeparator())
        stack.addArrangedSubview(chromeButton(
            symbol: "trash",
            label: "Discard capture",
            hint: "Discard capture and delete from history"
        ) { [weak self] in self?.confirmDiscardCapture() })
        return stack
    }

    private func makeToolStrip() -> NSView {
        let stack = chromeStack(spacing: 4)
        let groups: [(name: String, tools: [EditorTool])] = [
            ("Selection", [.select]),
            ("Arrows and lines", [.arrow, .line]),
            ("Shapes", [.rectangle, .ellipse]),
            ("Freehand", [.pen, .highlighter]),
            ("Labels", [.text, .counter])
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { stack.addArrangedSubview(chromeSeparator()) }
            stack.addArrangedSubview(makeToolGroup(group.tools, accessibilityLabel: group.name))
        }
        stack.addArrangedSubview(chromeSeparator())

        let more = EditorChromeButton(
            symbol: "ellipsis",
            label: "More tools and actions",
            showsSelection: true
        ) { [weak self] in
            guard let self, let button = self.moreToolsButton else { return }
            self.showMoreTools(button)
        }
        let moreHint = "More tools"
        more.toolTip = moreHint
        more.setAccessibilityHelp(moreHint)
        moreToolsButton = more
        stack.addArrangedSubview(more)
        return stack
    }

    private func makeToolGroup(_ tools: [EditorTool], accessibilityLabel: String) -> NSView {
        let stack = chromeStack(spacing: 2)
        stack.setAccessibilityLabel(accessibilityLabel)
        for tool in tools {
            let button = EditorChromeButton(
                symbol: tool.symbol,
                label: tool.rawValue.capitalized,
                showsSelection: true
            ) { [weak self] in self?.selectTool(tool) }
            let hint = toolHint(for: tool)
            button.toolTip = hint
            button.setAccessibilityHelp(hint)
            button.setSelected(tool == canvas.tool)
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }
        return stack
    }

    private func makeInfoStrip() -> NSView {
        let colorGroup = makeColorInfo()
        let widthGroup = makeWidthInfo()
        let sizeGroup = metadataGroup(valueLabel: imageSizeLabel, caption: "Image size")
        sizeGroup.setAccessibilityElement(true)
        sizeGroup.setAccessibilityRole(.button)
        sizeGroup.setAccessibilityLabel("Image size")
        sizeGroup.setAccessibilityHelp("Click to resize the screenshot")
        sizeGroup.toolTip = "Resize screenshot"
        sizeGroup.addGestureRecognizer(NSClickGestureRecognizer(
            target: self,
            action: #selector(showImageSizePopover(_:))
        ))
        updateImageSizeLabel()
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
        colorWell.pulldownTarget = self
        colorWell.pulldownAction = #selector(showColorPalette(_:))
        colorWell.supportsAlpha = false
        colorWell.toolTip = "Annotation color"
        colorWell.setAccessibilityLabel("Annotation color")
        colorWell.widthAnchor.constraint(equalToConstant: 22).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true

        colorLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        colorLabel.textColor = .labelColor
        colorLabel.isSelectable = false
        colorLabel.toolTip = "Copy color hex"
        let caption = NSTextField(labelWithString: "Color")
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

    @objc private func showColorPalette(_ sender: NSColorWell) {
        colorPalettePopover?.close()

        let paletteStack = NSStackView()
        paletteStack.orientation = .vertical
        paletteStack.alignment = .centerX
        paletteStack.spacing = 6

        let colors = annotationPaletteColors
        for startIndex in stride(from: 0, to: colors.count, by: 5) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            for index in startIndex ..< min(startIndex + 5, colors.count) {
                let color = colors[index]
                let button = NSButton(image: colorSwatchImage(color), target: self, action: #selector(selectPaletteColor(_:)))
                button.tag = index
                button.isBordered = false
                button.imagePosition = .imageOnly
                button.toolTip = hexString(for: color)
                button.setAccessibilityLabel("Use color \(hexString(for: color))")
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
                button.heightAnchor.constraint(equalToConstant: 28).isActive = true
                row.addArrangedSubview(button)
            }
            paletteStack.addArrangedSubview(row)
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 164).isActive = true
        paletteStack.addArrangedSubview(separator)

        let samplerButton = NSButton(
            title: "Pick from Capture",
            target: self,
            action: #selector(sampleColorFromCapture)
        )
        samplerButton.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)
        samplerButton.imagePosition = .imageLeading
        samplerButton.bezelStyle = .rounded
        samplerButton.toolTip = "Pick a color from the captured image"
        samplerButton.setAccessibilityLabel("Pick a color from the captured image")
        samplerButton.widthAnchor.constraint(equalToConstant: 164).isActive = true
        paletteStack.addArrangedSubview(samplerButton)

        let content = NSView(frame: CGRect(x: 0, y: 0, width: 188, height: 204))
        paletteStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(paletteStack)
        NSLayoutConstraint.activate([
            paletteStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            paletteStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            paletteStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            paletteStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])

        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = content.frame.size
        popover.contentViewController = controller
        colorPalettePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func selectPaletteColor(_ sender: NSButton) {
        guard annotationPaletteColors.indices.contains(sender.tag) else { return }
        applyPickedColor(annotationPaletteColors[sender.tag])
        colorPalettePopover?.close()
    }

    @objc private func sampleColorFromCapture() {
        colorPalettePopover?.close()
        NSColorSampler().show { [weak self] color in
            Task { @MainActor [weak self] in
                guard let self, let color else { return }
                self.applyPickedColor(color)
            }
        }
    }

    private func applyPickedColor(_ color: NSColor) {
        colorWell.color = color
        styleChanged()
    }

    private var annotationPaletteColors: [NSColor] {
        [
            .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint,
            .systemTeal, .systemCyan, .systemBlue, .systemIndigo, .systemPurple,
            .systemPink, .systemBrown,
            NSColor(srgbRed: 0.55, green: 0.10, blue: 0.18, alpha: 1),
            NSColor(srgbRed: 0.45, green: 0.72, blue: 0.12, alpha: 1),
            NSColor(srgbRed: 0.08, green: 0.18, blue: 0.42, alpha: 1),
            .black, .darkGray, .gray, .lightGray, .white
        ]
    }

    private func colorSwatchImage(_ color: NSColor) -> NSImage {
        let isSelected = hexString(for: color) == hexString(for: colorWell.color)
        return NSImage(size: CGSize(width: 24, height: 24), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            color.setFill()
            circle.fill()
            (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            circle.lineWidth = isSelected ? 3 : 1
            circle.stroke()
            return true
        }
    }

    private func makeWidthInfo() -> NSView {
        widthLabel.font = .systemFont(ofSize: 13, weight: .medium)
        widthLabel.textColor = .labelColor
        widthLabel.alignment = .left
        let widthHint = "Stroke width"
        widthLabel.toolTip = widthHint

        let caption = NSTextField(labelWithString: "Stroke width")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [widthLabel, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.button)
        stack.setAccessibilityLabel("Stroke width")
        stack.setAccessibilityHelp(widthHint)
        stack.toolTip = widthHint

        let click = NSClickGestureRecognizer(target: self, action: #selector(showStrokePopover(_:)))
        stack.addGestureRecognizer(click)
        updateStyleLabels()
        return stack
    }

    @objc private func showStrokePopover(_ sender: NSClickGestureRecognizer) {
        guard let anchor = sender.view else { return }
        widthSlider.target = self
        widthSlider.action = #selector(styleChanged)
        widthSlider.isContinuous = true
        widthSlider.controlSize = .small
        widthSlider.toolTip = "Stroke width: 1–28 pt"
        widthSlider.setAccessibilityLabel("Stroke width in points")
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

    @objc private func showImageSizePopover(_ sender: NSClickGestureRecognizer) {
        guard let anchor = sender.view else { return }
        imageSizePopover?.close()

        let controller = ImageResizePopoverController(
            originalPixelSize: CGSize(width: sourceImage.width, height: sourceImage.height),
            currentPixelSize: session.manifest.outputPixelSize,
            displayScale: max(1, session.manifest.displayScale),
            showsLogicalSize: showsLogicalImageSize,
            onLogicalSizeChanged: { [weak self] showsLogicalSize in
                self?.showsLogicalImageSize = showsLogicalSize
                self?.updateImageSizeLabel()
            },
            onResize: { [weak self] size in
                guard let self else { return }
                self.applyImageResize(to: size)
                self.imageSizePopover?.performClose(nil)
            }
        )
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        imageSizePopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
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

    private func chromeButton(
        symbol: String,
        label: String,
        hint: String,
        action: @escaping () -> Void
    ) -> EditorChromeButton {
        let button = EditorChromeButton(symbol: symbol, label: label, showsSelection: false, action: action)
        button.toolTip = hint
        button.setAccessibilityHelp(hint)
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
            item.toolTip = toolHint(for: tool)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let recognizeTitle: String
        if canvas.isOCRSelectionActive {
            recognizeTitle = "Hide Text Selection"
        } else if canvas.ocrResults.isEmpty {
            recognizeTitle = "Recognize Text"
        } else {
            recognizeTitle = "Select Recognized Text"
        }
        let recognize = NSMenuItem(title: recognizeTitle, action: #selector(toggleRecognizedText), keyEquivalent: "")
        recognize.target = self
        recognize.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: recognize.title)
        recognize.state = canvas.isOCRSelectionActive ? .on : .off
        recognize.toolTip = "Select detected text"
        menu.addItem(recognize)
        let backdrop = NSMenuItem(title: "Backdrop…", action: #selector(showBackdrop), keyEquivalent: "")
        backdrop.target = self
        backdrop.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: backdrop.title)
        backdrop.toolTip = "Add an export backdrop"
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
        canvas.applyStrokeToSelection(
            color: RGBAColor(colorWell.color),
            lineWidth: widthSlider.doubleValue
        )
    }

    private func selectionChanged(_ annotation: Annotation?) {
        guard let annotation,
              EditorTool(rawValue: annotation.kind.rawValue)?.usesStrokeWidth == true else { return }
        colorWell.color = annotation.style.strokeColor.nsColor
        widthSlider.maxValue = max(28, annotation.style.lineWidth)
        widthSlider.doubleValue = annotation.style.lineWidth
        updateStyleLabels()
    }

    @objc private func copyColorHex() {
        let hex = hexString(for: colorWell.color)
        exportService.copyText(hex)
        showTransientMessage("Copied \(hex)", style: .success)
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53, canvas.tool != .select {
            canvas.commitTextEditing()
            selectTool(.select)
            return nil
        }

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
        for (tool, button) in toolButtons {
            let hint = toolHint(for: tool)
            button.toolTip = hint
            button.setAccessibilityHelp(hint)
        }
    }

    private func toolHint(for tool: EditorTool) -> String {
        guard tool.usesStrokeWidth else { return tool.hint }
        let width = Int(widthSlider.doubleValue.rounded())
        return "\(tool.hint) • Stroke: \(width) pt"
    }

    private func updateZoomLabel() {
        let magnification = scrollView.magnification
        zoomLabel.stringValue = "\(Int((magnification * 100).rounded()))%"
        if abs(magnification - displayedCanvasMagnification) > 0.0001 {
            displayedCanvasMagnification = magnification
            canvas.needsDisplay = true
        }
    }

    private func updateImageSizeLabel() {
        let width = CGFloat(session.manifest.outputPixelWidth)
        let height = CGFloat(session.manifest.outputPixelHeight)
        if showsLogicalImageSize {
            let scale = max(1, session.manifest.displayScale)
            imageSizeLabel.stringValue = "\(formattedDimension(width / scale))×\(formattedDimension(height / scale))pt"
        } else {
            imageSizeLabel.stringValue = "\(Int(width))×\(Int(height))px"
        }
        imageSizeLabel.toolTip = "Resize screenshot"
        imageSizeLabel.setAccessibilityLabel("Image size \(imageSizeLabel.stringValue). Click to resize.")
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

    private func applyImageResize(to requestedSize: CGSize) {
        canvas.commitTextEditing()
        let targetSize = CGSize(
            width: max(1, Int(requestedSize.width.rounded())),
            height: max(1, Int(requestedSize.height.rounded()))
        )
        let currentSize = session.manifest.outputPixelSize
        guard targetSize != currentSize else { return }

        let previous = EditorImageGeometry(
            annotations: session.annotations,
            resize: session.manifest.resize
        )
        let originalSize = CGSize(width: sourceImage.width, height: sourceImage.height)
        let resize = targetSize == originalSize
            ? nil
            : ImageResizeConfiguration(
                pixelWidth: Int(targetSize.width),
                pixelHeight: Int(targetSize.height)
            )
        let annotations = ImageResizeGeometry.scaledAnnotations(
            session.annotations,
            from: currentSize,
            to: targetSize
        )
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.replaceImageGeometry(previous)
        }
        window?.undoManager?.setActionName("Resize Image")
        // Resizing is specified in physical pixels, so show that same value in
        // the editor after applying it. Users can switch back to logical points.
        showsLogicalImageSize = false
        applyImageGeometry(EditorImageGeometry(annotations: annotations, resize: resize))
        showTransientMessage(
            "Resized to \(Int(targetSize.width)) × \(Int(targetSize.height)) px",
            style: .success
        )
    }

    private func replaceImageGeometry(_ geometry: EditorImageGeometry) {
        let current = EditorImageGeometry(
            annotations: session.annotations,
            resize: session.manifest.resize
        )
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.replaceImageGeometry(current)
        }
        window?.undoManager?.setActionName("Resize Image")
        applyImageGeometry(geometry)
    }

    private func applyImageGeometry(_ geometry: EditorImageGeometry) {
        session.annotations = geometry.annotations
        session.manifest.resize = geometry.resize
        canvas.resize(
            to: session.manifest.outputPixelSize,
            annotations: geometry.annotations
        )
        updateImageSizeLabel()
        fitCanvasAfterResize()
        schedulePersist()
    }

    private func fitCanvasAfterResize() {
        scrollView.layoutSubtreeIfNeeded()
        let fit = min(
            scrollView.contentSize.width / canvas.frame.width,
            scrollView.contentSize.height / canvas.frame.height,
            1
        )
        scrollView.magnification = min(scrollView.maxMagnification, max(scrollView.minMagnification, fit * 0.92))
        scrollView.contentView.scroll(to: scrollView.contentView.bounds.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateZoomLabel()
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

    @objc private func undo() {
        canvas.commitTextEditing()
        window?.undoManager?.undo()
    }

    @objc private func redo() {
        canvas.commitTextEditing()
        window?.undoManager?.redo()
    }

    private func confirmDiscardCapture() {
        guard let window, !isDiscardingCapture else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard Capture?"
        alert.informativeText = "This permanently removes the capture from history."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.discardCapture()
        }
    }

    private func discardCapture() {
        guard !isDiscardingCapture else { return }
        isDiscardingCapture = true
        persistTask?.cancel()
        Task {
            do {
                try await waitForInitialPersistence()
                try await onDiscardCapture(session.id)
                window?.close()
            } catch {
                isDiscardingCapture = false
                present(error)
            }
        }
    }

    private func clearAllEdits() {
        let current = EditorEdits(
            annotations: session.annotations,
            ocrResults: session.ocrResults,
            backdrop: session.manifest.backdrop,
            isOCRSelectionActive: canvas.isOCRSelectionActive
        )
        guard !current.annotations.isEmpty
                || !current.ocrResults.isEmpty
                || current.backdrop != BackdropConfiguration() else {
            showTransientMessage("Nothing to clear", style: .information)
            return
        }
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.replaceEdits(current)
        }
        window?.undoManager?.setActionName("Clear All Edits")
        applyEdits(EditorEdits())
        showTransientMessage("Edits cleared — Undo restores them", style: .success)
    }

    private func replaceEdits(_ edits: EditorEdits) {
        let current = EditorEdits(
            annotations: session.annotations,
            ocrResults: session.ocrResults,
            backdrop: session.manifest.backdrop,
            isOCRSelectionActive: canvas.isOCRSelectionActive
        )
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.replaceEdits(current)
        }
        window?.undoManager?.setActionName("Clear All Edits")
        applyEdits(edits)
    }

    private func applyEdits(_ edits: EditorEdits) {
        session.annotations = edits.annotations
        session.ocrResults = edits.ocrResults
        session.manifest.backdrop = edits.backdrop
        canvas.replaceEdits(
            annotations: edits.annotations,
            ocrResults: edits.ocrResults,
            isOCRSelectionActive: edits.isOCRSelectionActive
        )
        schedulePersist()
    }

    @objc private func toggleRecognizedText() {
        if canvas.isOCRSelectionActive {
            canvas.isOCRSelectionActive = false
            showTransientMessage("Text selection hidden", style: .information)
            return
        }
        if !canvas.ocrResults.isEmpty {
            canvas.isOCRSelectionActive = true
            showTransientMessage("Click text or drag across regions to copy", style: .tip)
            return
        }
        Task {
            do {
                let results = try await ocrService.recognize(ImagePayload(image: sourceImage))
                session.ocrResults = results
                canvas.ocrResults = results
                canvas.isOCRSelectionActive = !results.isEmpty
                schedulePersist()
                if !results.isEmpty {
                    showTransientMessage("Text ready — click or drag across regions to copy", style: .success)
                } else {
                    showTransientMessage("No text recognized", style: .information)
                }
            } catch { present(error) }
        }
    }

    @objc private func showBackdrop() {
        guard let window else { return }
        if let backdropPanelController {
            backdropPanelController.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = BackdropPanelController(
            configuration: session.manifest.backdrop,
            image: sourceImage,
            imagePixelSize: session.manifest.outputPixelSize
        ) { [weak self] configuration in
            self?.session.manifest.backdrop = configuration
            self?.schedulePersist()
        }
        backdropPanelController = controller
        guard let panel = controller.window else { return }
        window.beginSheet(panel) { [weak self] _ in
            self?.backdropPanelController = nil
        }
    }

    @objc private func copyRendered() {
        Task {
            do {
                exportService.copy(try await renderedImage())
                window?.close()
            } catch {
                present(error)
            }
        }
    }

    @objc private func saveRendered() {
        Task {
            do { _ = try await exportService.save(try await renderedImage()) } catch { present(error) }
        }
    }

    private func renderedImage() async throws -> CGImage {
        canvas.commitTextEditing()
        let renderer = self.renderer
        let source = ImagePayload(image: sourceImage)
        let session = self.session
        return try await Task.detached(priority: .userInitiated) {
            try renderer.render(source: source, session: session, options: ExportOptions()).image
        }.value
    }

    private func copyOCRResults(_ results: [OCRResult]) {
        guard !results.isEmpty else { return }
        let text = results.map(\.text).joined(separator: "\n")
        exportService.copyText(text)
        if results.count == 1 {
            showTransientMessage("Text copied", style: .success)
        } else {
            showTransientMessage("\(results.count) text regions copied", style: .success)
        }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        let session = self.session
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled,
                  (try? await waitForInitialPersistence()) != nil,
                  !Task.isCancelled else { return }
            do {
                try await historyStore.save(session)
                guard !Task.isCancelled else { return }
                onSessionSaved(session.id)
            } catch { return }
        }
    }

    private func waitForInitialPersistence() async throws {
        guard let initialPersistence else { return }
        try await initialPersistence.value
        self.initialPersistence = nil
    }

    private func showTransientMessage(_ text: String, style: EditorNoticeStyle) {
        guard let content = window?.contentView else { return }

        transientNoticeTask?.cancel()
        transientNotice?.removeFromSuperview()

        let notice = EditorTransientNoticeView(text: text, style: style)
        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.alphaValue = 0
        content.addSubview(notice)
        transientNotice = notice

        let topAnchor = editorBar?.bottomAnchor ?? content.topAnchor
        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            notice.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            notice.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            notice.widthAnchor.constraint(lessThanOrEqualToConstant: 500)
        ])
        content.layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            notice.animator().alphaValue = 1
        }

        transientNoticeTask = Task { [weak self, weak notice] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled, let self, let notice else { return }
            self.dismissTransientMessage(notice)
        }
    }

    private func dismissTransientMessage(_ notice: EditorTransientNoticeView) {
        guard transientNotice === notice else { return }
        transientNotice = nil
        transientNoticeTask = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            notice.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                notice.removeFromSuperview()
            }
        }
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
    }
}

private enum EditorNoticeStyle {
    case success
    case information
    case tip

    var symbolName: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .information: "info.circle.fill"
        case .tip: "hand.point.up.left.fill"
        }
    }

    var tintColor: NSColor {
        switch self {
        case .success: .systemGreen
        case .information, .tip: .controlAccentColor
        }
    }
}

@MainActor
private final class EditorTransientNoticeView: NSVisualEffectView {
    init(text: String, style: EditorNoticeStyle) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: style.symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(symbolConfiguration)
        icon.contentTintColor = style.tintColor
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 17),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        updateBorderColor()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
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
private final class ImageResizePopoverController: NSViewController, NSTextFieldDelegate {
    private static let presetScales: [CGFloat] = [0.25, 1.0 / 3.0, 0.5, 1, 2, 4]
    private static let maximumDimension = 200_000
    private static let maximumPixelCount = 100_000_000

    private let originalPixelSize: CGSize
    private let currentPixelSize: CGSize
    private let displayScale: CGFloat
    private let initialShowsLogicalSize: Bool
    private let onLogicalSizeChanged: (Bool) -> Void
    private let onResize: (CGSize) -> Void
    private let logicalSizeSwitch = NSSwitch()
    private let presets = NSSegmentedControl(
        labels: ["25%", "33%", "50%", "1×", "2×", "4×"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let constrainProportions = NSButton(
        checkboxWithTitle: "Constrain proportions",
        target: nil,
        action: nil
    )
    private let errorLabel = NSTextField(labelWithString: "")
    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.usesGroupingSeparator = true
        return formatter
    }()
    private var isUpdatingFields = false

    init(
        originalPixelSize: CGSize,
        currentPixelSize: CGSize,
        displayScale: CGFloat,
        showsLogicalSize: Bool,
        onLogicalSizeChanged: @escaping (Bool) -> Void,
        onResize: @escaping (CGSize) -> Void
    ) {
        self.originalPixelSize = originalPixelSize
        self.currentPixelSize = currentPixelSize
        self.displayScale = displayScale
        initialShowsLogicalSize = showsLogicalSize
        self.onLogicalSizeChanged = onLogicalSizeChanged
        self.onResize = onResize
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 390, height: 252))
        view = content
        preferredContentSize = content.frame.size

        let logicalTitle = NSTextField(labelWithString: "Show Size in Logical Points")
        logicalTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        logicalSizeSwitch.state = initialShowsLogicalSize ? .on : .off
        logicalSizeSwitch.target = self
        logicalSizeSwitch.action = #selector(logicalSizeChanged)
        logicalSizeSwitch.toolTip = "Switch the editor size between logical points and physical pixels"
        logicalSizeSwitch.setAccessibilityLabel("Show image size in logical points")
        let logicalSpacer = NSView()
        logicalSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let logicalRow = NSStackView(views: [logicalTitle, logicalSpacer, logicalSizeSwitch])
        logicalRow.orientation = .horizontal
        logicalRow.alignment = .centerY

        let scaleDescription: String
        if displayScale == 1 {
            scaleDescription = "One logical point equals one physical pixel for this capture."
        } else {
            scaleDescription = "One logical point equals \(String(format: "%g", displayScale)) physical pixels for this capture."
        }
        let explanation = NSTextField(wrappingLabelWithString: scaleDescription)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 2

        let separator = NSBox()
        separator.boxType = .separator

        let resizeTitle = NSTextField(labelWithString: "Resize Image")
        resizeTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        presets.target = self
        presets.action = #selector(presetChanged)
        presets.segmentStyle = .rounded
        presets.setAccessibilityLabel("Resize presets")
        selectMatchingPreset()

        configureDimensionField(widthField, label: "Image width in pixels")
        configureDimensionField(heightField, label: "Image height in pixels")
        setDimensionFields(to: currentPixelSize)

        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor
        let pixels = NSTextField(labelWithString: "px")
        pixels.textColor = .secondaryLabelColor
        let resizeButton = NSButton(title: "Resize", target: self, action: #selector(resize))
        resizeButton.bezelStyle = .rounded
        resizeButton.keyEquivalent = "\r"
        resizeButton.toolTip = "Apply the new image size"
        resizeButton.setAccessibilityLabel("Resize image")
        let fieldsRow = NSStackView(views: [widthField, times, heightField, pixels, resizeButton])
        fieldsRow.orientation = .horizontal
        fieldsRow.alignment = .centerY
        fieldsRow.spacing = 8

        constrainProportions.state = .on
        constrainProportions.toolTip = "Keep the screenshot's original aspect ratio"
        constrainProportions.setAccessibilityLabel("Constrain image proportions")

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [
            logicalRow, explanation, separator, resizeTitle, presets,
            fieldsRow, constrainProportions, errorLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            logicalRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            presets.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fieldsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            widthField.widthAnchor.constraint(equalToConstant: 94),
            heightField.widthAnchor.constraint(equalToConstant: 94)
        ])
    }

    private func configureDimensionField(_ field: NSTextField, label: String) {
        field.formatter = numberFormatter
        field.alignment = .right
        field.delegate = self
        field.target = self
        field.action = #selector(dimensionEditingEnded)
        field.toolTip = label
        field.setAccessibilityLabel(label)
    }

    private func setDimensionFields(to size: CGSize) {
        isUpdatingFields = true
        widthField.stringValue = numberFormatter.string(from: NSNumber(value: Int(size.width.rounded())))
            ?? String(Int(size.width.rounded()))
        heightField.stringValue = numberFormatter.string(from: NSNumber(value: Int(size.height.rounded())))
            ?? String(Int(size.height.rounded()))
        isUpdatingFields = false
    }

    private func selectMatchingPreset() {
        presets.selectedSegment = Self.presetScales.firstIndex { scale in
            presetSize(for: scale) == currentPixelSize
        } ?? -1
    }

    private func presetSize(for scale: CGFloat) -> CGSize {
        CGSize(
            width: max(1, Int((originalPixelSize.width * scale).rounded())),
            height: max(1, Int((originalPixelSize.height * scale).rounded()))
        )
    }

    private func pixelValue(in field: NSTextField) -> Int? {
        guard let number = numberFormatter.number(from: field.stringValue) else { return nil }
        let value = number.intValue
        return value > 0 ? value : nil
    }

    private func updateConstrainedDimension(changedField: NSTextField) {
        guard !isUpdatingFields, constrainProportions.state == .on else { return }
        isUpdatingFields = true
        if changedField === widthField, let width = pixelValue(in: widthField) {
            let height = max(1, Int((CGFloat(width) * originalPixelSize.height / originalPixelSize.width).rounded()))
            heightField.stringValue = numberFormatter.string(from: NSNumber(value: height)) ?? String(height)
        } else if changedField === heightField, let height = pixelValue(in: heightField) {
            let width = max(1, Int((CGFloat(height) * originalPixelSize.width / originalPixelSize.height).rounded()))
            widthField.stringValue = numberFormatter.string(from: NSNumber(value: width)) ?? String(width)
        }
        isUpdatingFields = false
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        presets.selectedSegment = -1
        errorLabel.stringValue = ""
        updateConstrainedDimension(changedField: field)
    }

    @objc private func logicalSizeChanged() {
        onLogicalSizeChanged(logicalSizeSwitch.state == .on)
    }

    @objc private func presetChanged() {
        guard Self.presetScales.indices.contains(presets.selectedSegment) else { return }
        setDimensionFields(to: presetSize(for: Self.presetScales[presets.selectedSegment]))
        errorLabel.stringValue = ""
    }

    @objc private func dimensionEditingEnded(_ sender: NSTextField) {
        updateConstrainedDimension(changedField: sender)
    }

    @objc private func resize() {
        guard let width = pixelValue(in: widthField),
              let height = pixelValue(in: heightField) else {
            errorLabel.stringValue = "Enter a width and height greater than zero."
            NSSound.beep()
            return
        }
        let isOriginalSize = width == Int(originalPixelSize.width)
            && height == Int(originalPixelSize.height)
        guard isOriginalSize || (width <= Self.maximumDimension && height <= Self.maximumDimension) else {
            errorLabel.stringValue = "Each dimension must be 200,000 px or less."
            NSSound.beep()
            return
        }
        guard isOriginalSize || width <= Self.maximumPixelCount / height else {
            errorLabel.stringValue = "The requested image is too large to render safely."
            NSSound.beep()
            return
        }
        onResize(CGSize(width: width, height: height))
    }
}

struct AnnotationCanvasGeometry {
    static func translated(_ annotation: Annotation, by delta: CGPoint) -> Annotation {
        var translated = annotation
        translated.frame = CanvasRect(annotation.frame.cgRect.offsetBy(dx: delta.x, dy: delta.y))
        translated.points = movedPoints(annotation.points, by: delta)
        return translated
    }

    static func movedPoints(_ points: [CanvasPoint], by delta: CGPoint) -> [CanvasPoint] {
        points.map { CanvasPoint(CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)) }
    }

    static func resizedPoints(_ points: [CanvasPoint], from oldFrame: CGRect, to newFrame: CGRect) -> [CanvasPoint] {
        points.map { point in
            let xFraction = oldFrame.width == 0 ? 0 : (point.x - oldFrame.minX) / oldFrame.width
            let yFraction = oldFrame.height == 0 ? 0 : (point.y - oldFrame.minY) / oldFrame.height
            return CanvasPoint(CGPoint(
                x: newFrame.minX + xFraction * newFrame.width,
                y: newFrame.minY + yFraction * newFrame.height
            ))
        }
    }

    static func frame(containing points: [CanvasPoint], fallback: CGRect) -> CGRect {
        guard let first = points.first else { return fallback }
        return points.dropFirst().reduce(CGRect(x: first.x, y: first.y, width: 0, height: 0)) { frame, point in
            frame.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
        }
    }

    static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let closest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }
}

@MainActor
final class EditorCanvasView: NSView, NSTextViewDelegate {
    var tool: EditorTool = .select {
        didSet {
            if oldValue != tool, textEditor != nil { commitTextEditing() }
            if tool != .select && tool != .text { hideTextToolbar() }
        }
    }
    var style = AnnotationStyle()
    var annotations: [Annotation] {
        didSet {
            if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
            needsDisplay = true
        }
    }
    var ocrResults: [OCRResult] {
        didSet {
            selectedOCRIDs.removeAll()
            needsDisplay = true
        }
    }
    var isOCRSelectionActive = false {
        didSet {
            selectedOCRIDs.removeAll()
            ocrSelectionRect = nil
            needsDisplay = true
        }
    }
    var onAnnotationsChanged: (([Annotation]) -> Void)?
    var onSelectionChanged: ((Annotation?) -> Void)?
    var onOCRSelection: (([OCRResult]) -> Void)?

    private enum DragOperation {
        case move
        case startPoint
        case endPoint
        case resizeTopLeft
        case resizeTopRight
        case resizeBottomLeft
        case resizeBottomRight
        case resizeTop
        case resizeBottom
        case resizeLeft
        case resizeRight
    }

    private let image: CGImage
    private let effectContext = CIContext(options: [.cacheIntermediates: false])
    private let effectPreviewCache = NSCache<NSString, CGImage>()
    private var draft: Annotation?
    private var selectedID: UUID? {
        didSet {
            guard oldValue != selectedID else { return }
            onSelectionChanged?(selectedID.flatMap { id in annotations.first { $0.id == id } })
        }
    }
    private var dragStart: CGPoint?
    private var originalFrame: CGRect?
    private var originalPoints: [CanvasPoint] = []
    private var dragOperation: DragOperation?
    private var didModifySelection = false
    private var ocrDragStart: CGPoint?
    private var ocrSelectionRect: CGRect?
    private var selectedOCRIDs = Set<UUID>()
    private var copiedAnnotation: Annotation?
    private var counter = 1
    private var textEditor: InlineTextView?
    private var editingTextID: UUID?
    private var textMinimumHeight: CGFloat = 0
    private var textEditingOriginalAnnotation: Annotation?
    private var isEditingNewText = false
    private var textToolbarPopover: NSPopover?
    private var textToolbarController: TextFormattingToolbarController?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage, canvasSize: CGSize, annotations: [Annotation], ocrResults: [OCRResult]) {
        self.image = image
        self.annotations = annotations
        self.ocrResults = ocrResults
        super.init(frame: CGRect(origin: .zero, size: canvasSize))
        counter = (annotations.compactMap(\.counter).max() ?? 0) + 1
        wantsLayer = true
        setAccessibilityRole(.image)
        setAccessibilityLabel("Screenshot annotation canvas")
    }

    required init?(coder: NSCoder) { nil }

    func resize(to canvasSize: CGSize, annotations: [Annotation]) {
        discardTextEditingOverlay()
        hideTextToolbar()
        draft = nil
        dragStart = nil
        originalFrame = nil
        originalPoints = []
        dragOperation = nil
        copiedAnnotation = nil
        self.annotations = annotations
        setFrameSize(canvasSize)
        setBoundsSize(canvasSize)
        if let selectedID {
            onSelectionChanged?(annotations.first { $0.id == selectedID })
        }
        counter = (annotations.compactMap(\.counter).max() ?? 0) + 1
        needsDisplay = true
    }

    func replaceEdits(annotations: [Annotation], ocrResults: [OCRResult], isOCRSelectionActive: Bool) {
        discardTextEditingOverlay()
        hideTextToolbar()
        draft = nil
        selectedID = nil
        dragStart = nil
        originalFrame = nil
        originalPoints = []
        dragOperation = nil
        copiedAnnotation = nil
        self.annotations = annotations
        self.ocrResults = ocrResults
        self.isOCRSelectionActive = isOCRSelectionActive && !ocrResults.isEmpty
        counter = (annotations.compactMap(\.counter).max() ?? 0) + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCanvasImage(image)
        let visibleAnnotations = annotations + (draft.map { [$0] } ?? [])
        for annotation in visibleAnnotations where annotation.kind == .blur || annotation.kind == .pixelate {
            draw(annotation)
        }
        for annotation in visibleAnnotations where annotation.kind != .blur && annotation.kind != .pixelate {
            draw(annotation)
        }
        drawOCR()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = clamped(convert(event.locationInWindow, from: nil))
        if isOCRSelectionActive {
            ocrDragStart = point
            ocrSelectionRect = CGRect(origin: point, size: .zero)
            selectedOCRIDs = Set(ocrResult(at: point).map { [$0.id] } ?? [])
            needsDisplay = true
            return
        }

        if textEditor != nil { commitTextEditing() }
        if tool == .select,
           event.clickCount >= 2,
           let textAnnotation = annotation(at: point),
           textAnnotation.kind == .text {
            selectedID = textAnnotation.id
            beginTextEditing(annotationID: textAnnotation.id, selectAll: false)
            needsDisplay = true
            return
        }

        dragStart = point
        didModifySelection = false
        if tool == .select {
            if let selectedID,
               let selected = annotations.first(where: { $0.id == selectedID }),
               let operation = handleOperation(for: selected, at: point) {
                dragOperation = operation
            } else {
                selectedID = annotation(at: point)?.id
                dragOperation = selectedID == nil ? nil : .move
            }
            if let selectedID, let selected = annotations.first(where: { $0.id == selectedID }) {
                originalFrame = selected.frame.cgRect
                originalPoints = selected.points
                if selected.kind != .text { hideTextToolbar() }
            } else {
                originalFrame = nil
                originalPoints = []
                hideTextToolbar()
            }
        } else if let kind = tool.annotationKind {
            hideTextToolbar()
            draft = Annotation(kind: kind, frame: CanvasRect(CGRect(origin: point, size: .zero)), points: [CanvasPoint(point)], style: style)
            if kind == .counter { draft?.counter = counter }
            if kind == .text { draft?.text = "" }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        if isOCRSelectionActive, let start = ocrDragStart {
            let selection = rect(from: start, to: point)
            ocrSelectionRect = selection
            selectedOCRIDs = Set(ocrResults.filter { ocrFrame(for: $0).intersects(selection) }.map(\.id))
            needsDisplay = true
            return
        }

        guard let start = dragStart else { return }
        if tool == .select,
           let id = selectedID,
           let index = annotations.firstIndex(where: { $0.id == id }),
           let originalFrame,
           let dragOperation {
            switch dragOperation {
            case .move:
                let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
                annotations[index].frame = CanvasRect(originalFrame.offsetBy(dx: delta.x, dy: delta.y))
                annotations[index].points = AnnotationCanvasGeometry.movedPoints(originalPoints, by: delta)
            case .resizeTopLeft, .resizeTopRight, .resizeBottomLeft, .resizeBottomRight,
                 .resizeTop, .resizeBottom, .resizeLeft, .resizeRight:
                let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
                let newFrame = resizedFrame(originalFrame, for: dragOperation, by: delta)
                annotations[index].frame = CanvasRect(newFrame)
                annotations[index].points = AnnotationCanvasGeometry.resizedPoints(
                    originalPoints,
                    from: originalFrame,
                    to: newFrame
                )
            case .startPoint, .endPoint:
                var points = originalPoints
                guard !points.isEmpty else { break }
                let pointIndex = if case .startPoint = dragOperation {
                    points.startIndex
                } else {
                    points.index(before: points.endIndex)
                }
                points[pointIndex] = CanvasPoint(point)
                annotations[index].points = points
                annotations[index].frame = CanvasRect(AnnotationCanvasGeometry.frame(containing: points, fallback: originalFrame))
            }
            didModifySelection = true
        } else if var draft {
            let frame = rect(from: start, to: point)
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
        if isOCRSelectionActive {
            if let start = ocrDragStart {
                let point = clamped(convert(event.locationInWindow, from: nil))
                if hypot(point.x - start.x, point.y - start.y) < 3, let result = ocrResult(at: point) {
                    selectedOCRIDs = [result.id]
                }
                let selected = ocrResults.filter { selectedOCRIDs.contains($0.id) }
                onOCRSelection?(selected)
            }
            ocrDragStart = nil
            ocrSelectionRect = nil
            needsDisplay = true
            return
        }

        defer {
            dragStart = nil
            originalFrame = nil
            originalPoints = []
            dragOperation = nil
            didModifySelection = false
        }
        if tool == .select {
            if didModifySelection { onAnnotationsChanged?(annotations) }
            if let selectedID,
               annotations.first(where: { $0.id == selectedID })?.kind == .text {
                showTextToolbar(for: selectedID)
            }
            return
        }
        guard var draft else { return }
        self.draft = nil
        if draft.kind == .text {
            var frame = draft.frame.cgRect
            if frame.width < 4 && frame.height < 4 {
                frame = CGRect(x: frame.minX, y: frame.minY, width: 240, height: max(38, style.fontSize * 1.45))
            } else {
                frame.size.width = max(80, frame.width)
                frame.size.height = max(style.fontSize * 1.45, frame.height)
            }
            frame.size.width = min(frame.width, bounds.maxX - frame.minX)
            frame.size.height = min(frame.height, bounds.maxY - frame.minY)
            draft.frame = CanvasRect(frame)
            draft.richText = RichTextDocument(string: "", runs: [])
            annotations.append(draft)
            selectedID = draft.id
            beginTextEditing(annotationID: draft.id, selectAll: false, isNew: true)
            return
        }
        if draft.frame.cgRect.width < 2 && draft.frame.cgRect.height < 2 {
            draft.frame = CanvasRect(CGRect(x: draft.frame.x - 16, y: draft.frame.y - 16, width: 32, height: 32))
        }
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
            hideTextToolbar()
            onAnnotationsChanged?(annotations)
        } else if [123, 124, 125, 126].contains(event.keyCode),
                  let selectedID,
                  let index = annotations.firstIndex(where: { $0.id == selectedID }) {
            let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: CGPoint
            switch event.keyCode {
            case 123: delta = CGPoint(x: -amount, y: 0)
            case 124: delta = CGPoint(x: amount, y: 0)
            case 125: delta = CGPoint(x: 0, y: amount)
            default: delta = CGPoint(x: 0, y: -amount)
            }
            annotations[index] = AnnotationCanvasGeometry.translated(annotations[index], by: delta)
            onAnnotationsChanged?(annotations)
            if annotations[index].kind == .text { showTextToolbar(for: selectedID) }
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c",
                  let selectedID, let selected = annotations.first(where: { $0.id == selectedID }) {
            copiedAnnotation = selected
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v", let copiedAnnotation {
            var copy = AnnotationCanvasGeometry.translated(copiedAnnotation, by: CGPoint(x: 12, y: 12))
            copy.id = UUID()
            annotations.append(copy)
            selectedID = copy.id
            onAnnotationsChanged?(annotations)
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "d",
                  let selectedID, let selected = annotations.first(where: { $0.id == selectedID }) {
            var copy = AnnotationCanvasGeometry.translated(selected, by: CGPoint(x: 12, y: 12))
            copy.id = UUID()
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
            if annotation.kind == .arrow, annotation.style.arrowHead != .none {
                drawArrow(from: start, to: end, style: annotation.style)
                if annotation.style.arrowHead == .both {
                    drawArrow(from: end, to: start, style: annotation.style)
                }
            }
        case .rectangle, .redact, .blur, .pixelate, .crop:
            let rectPath = NSBezierPath(rect: frame)
            rectPath.lineWidth = annotation.style.lineWidth
            rectPath.lineJoinStyle = .round
            if annotation.kind == .redact { (annotation.style.fillColor?.nsColor ?? .black).setFill(); rectPath.fill() }
            else if annotation.kind == .blur || annotation.kind == .pixelate {
                if let preview = effectPreviewImage(kind: annotation.kind) {
                    drawCanvasImage(preview, clippedTo: frame)
                }
                NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
                let dash: [CGFloat] = [6, 3]
                rectPath.lineWidth = 1.5
                rectPath.setLineDash(dash, count: dash.count, phase: 0)
                rectPath.stroke()
            } else if annotation.kind == .crop {
                let dash = [overlayMetric(8), overlayMetric(4)]
                rectPath.lineWidth = overlayMetric(1.5)
                rectPath.setLineDash(dash, count: dash.count, phase: 0)
                rectPath.stroke()
            } else { if annotation.style.fillColor != nil { rectPath.fill() }; rectPath.stroke() }
        case .ellipse:
            let ellipse = NSBezierPath(ovalIn: frame)
            ellipse.lineWidth = annotation.style.lineWidth
            if annotation.style.fillColor != nil { ellipse.fill() }
            ellipse.stroke()
        case .pen, .highlighter:
            guard let first = annotation.points.first else { break }
            if annotation.kind == .highlighter { annotation.style.strokeColor.nsColor.withAlphaComponent(0.38).setStroke() }
            path.move(to: first.cgPoint)
            for point in annotation.points.dropFirst() { path.line(to: point.cgPoint) }
            path.stroke()
        case .text:
            if annotation.id != editingTextID {
                RichTextBridge.attributedString(for: annotation).draw(
                    with: frame.insetBy(dx: 2, dy: 2),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
            }
        case .counter:
            color.setFill(); NSBezierPath(ovalIn: frame).fill()
            let value = String(annotation.counter ?? 1)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: annotation.style.fontSize, weight: .bold), .foregroundColor: NSColor.white]
            let size = value.size(withAttributes: attributes)
            value.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), withAttributes: attributes)
        }
        if annotation.id == selectedID {
            if annotation.kind == .line || annotation.kind == .arrow,
               let start = annotation.points.first?.cgPoint,
               let end = annotation.points.last?.cgPoint {
                drawSelectionHandle(at: start)
                drawSelectionHandle(at: end)
            } else {
                let selectionFrame = selectionFrame(for: annotation)
                drawSelectionOutline(in: selectionFrame)
                for hitArea in resizeHandles(for: selectionFrame) {
                    drawResizeHandle(in: visualResizeHandle(for: hitArea))
                }
            }
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, style: AnnotationStyle) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(14, style.lineWidth * 4)
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
        guard isOCRSelectionActive, !ocrResults.isEmpty else { return }
        for result in ocrResults {
            let frame = ocrFrame(for: result)
            let path = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
            if selectedOCRIDs.contains(result.id) {
                NSColor.systemCyan.withAlphaComponent(0.20).setFill()
                path.fill()
            }
            NSColor.systemCyan.withAlphaComponent(0.9).setStroke()
            path.lineWidth = selectedOCRIDs.contains(result.id) ? 2.5 : 1.5
            path.stroke()
        }
        if let ocrSelectionRect, ocrSelectionRect.width > 1 || ocrSelectionRect.height > 1 {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSColor.controlAccentColor.setStroke()
            let marquee = NSBezierPath(rect: ocrSelectionRect)
            marquee.lineWidth = 1
            marquee.fill()
            marquee.stroke()
        }
    }

    private func ocrResult(at point: CGPoint) -> OCRResult? {
        ocrResults.first { ocrFrame(for: $0).insetBy(dx: -2, dy: -2).contains(point) }
    }

    private func ocrFrame(for result: OCRResult) -> CGRect {
        let normalized = result.normalizedBounds.cgRect
        return CGRect(
            x: normalized.minX * bounds.width,
            y: normalized.minY * bounds.height,
            width: normalized.width * bounds.width,
            height: normalized.height * bounds.height
        )
    }

    private func drawCanvasImage(_ canvasImage: CGImage, clippedTo clipRect: CGRect? = nil) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if let clipRect { context.clip(to: clipRect) }
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(canvasImage, in: bounds)
        context.restoreGState()
    }

    private func effectPreviewImage(kind: AnnotationKind) -> CGImage? {
        let key = kind.rawValue as NSString
        if let cached = effectPreviewCache.object(forKey: key) { return cached }
        guard let preview = makeEffectPreview(kind: kind) else { return nil }
        effectPreviewCache.setObject(
            preview,
            forKey: key,
            cost: preview.bytesPerRow * preview.height
        )
        return preview
    }

    private func makeEffectPreview(kind: AnnotationKind) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output: CIImage
        switch kind {
        case .blur:
            output = input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12])
                .cropped(to: input.extent)
        case .pixelate:
            output = input
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 14])
                .cropped(to: input.extent)
        default:
            return nil
        }
        return effectContext.createCGImage(output, from: input.extent)
    }

    private func annotation(at point: CGPoint) -> Annotation? {
        annotations.reversed().first { annotation in
            if annotation.kind == .line || annotation.kind == .arrow,
               let start = annotation.points.first?.cgPoint,
               let end = annotation.points.last?.cgPoint {
                return AnnotationCanvasGeometry.distance(from: point, toSegmentFrom: start, to: end) <= max(8, annotation.style.lineWidth + 4)
            }
            return annotation.frame.cgRect.insetBy(dx: -5, dy: -5).contains(point)
        }
    }

    private func handleOperation(for annotation: Annotation, at point: CGPoint) -> DragOperation? {
        if annotation.kind == .line || annotation.kind == .arrow,
           let start = annotation.points.first?.cgPoint,
           let end = annotation.points.last?.cgPoint {
            if selectionHandle(at: start).contains(point) { return .startPoint }
            if selectionHandle(at: end).contains(point) { return .endPoint }
            if AnnotationCanvasGeometry.distance(from: point, toSegmentFrom: start, to: end) <= max(8, annotation.style.lineWidth + 4) {
                return .move
            }
            return nil
        }
        let handles = resizeHandles(for: selectionFrame(for: annotation))
        // Corners first (priority), then edges, then body.
        let corners = Array(handles.prefix(4))
        for (i, handle) in corners.enumerated() {
            if handle.contains(point) {
                return [.resizeTopLeft, .resizeTopRight, .resizeBottomLeft, .resizeBottomRight][i]
            }
        }
        let edges = Array(handles.dropFirst(4))
        for (i, handle) in edges.enumerated() {
            if handle.contains(point) {
                return [.resizeTop, .resizeBottom, .resizeLeft, .resizeRight][i]
            }
        }
        return annotation.frame.cgRect.insetBy(dx: -5, dy: -5).contains(point) ? .move : nil
    }

    private func drawSelectionHandle(at point: CGPoint) {
        let size = overlayMetric(12)
        let frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        drawHandlePath(NSBezierPath(ovalIn: frame))
    }

    private func selectionHandle(at point: CGPoint) -> CGRect {
        let size = overlayMetric(20)
        return CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    func commitTextEditingIfClickIsOutside(_ event: NSEvent) {
        guard let editor = textEditor else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !editor.frame.contains(point) { commitTextEditing() }
    }

    func commitTextEditing() {
        guard let editingTextID,
              let index = annotations.firstIndex(where: { $0.id == editingTextID }) else {
            discardTextEditingOverlay()
            return
        }
        syncTextAnnotation(resizeToFit: true)
        let original = textEditingOriginalAnnotation
        let wasNew = isEditingNewText
        let isEmpty = annotations[index].text?.isEmpty != false

        discardTextEditingOverlay()
        if isEmpty {
            annotations.remove(at: index)
            selectedID = nil
            hideTextToolbar()
            if !wasNew { onAnnotationsChanged?(annotations) }
        } else {
            selectedID = editingTextID
            if wasNew || original != annotations[index] {
                onAnnotationsChanged?(annotations)
            }
            showTextToolbar(for: editingTextID)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func beginTextEditing(annotationID: UUID, selectAll: Bool, isNew: Bool = false) {
        if editingTextID == annotationID, let textEditor {
            window?.makeFirstResponder(textEditor)
            if selectAll { textEditor.selectAll(nil) }
            return
        }
        if textEditor != nil { commitTextEditing() }
        guard let annotation = annotations.first(where: { $0.id == annotationID }),
              annotation.kind == .text else { return }

        let editor = InlineTextView(frame: annotation.frame.cgRect)
        editor.drawsBackground = false
        editor.isRichText = true
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = CGSize(width: annotation.frame.width, height: annotation.frame.height)
        editor.maxSize = CGSize(width: annotation.frame.width, height: .greatestFiniteMagnitude)
        editor.textContainerInset = CGSize(width: 2, height: 2)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        let attributedText = RichTextBridge.attributedString(for: annotation)
        editor.textStorage?.setAttributedString(attributedText)
        if attributedText.length == 0 {
            editor.typingAttributes = RichTextBridge.attributes(for: RichTextBridge.defaultStyle(for: annotation))
        }
        editor.delegate = self
        editor.onEscape = { [weak self] in self?.commitTextEditing() }
        editor.setAccessibilityLabel("Text annotation editor")

        textEditor = editor
        editingTextID = annotationID
        textMinimumHeight = annotation.frame.height
        textEditingOriginalAnnotation = annotation
        isEditingNewText = isNew
        selectedID = annotationID
        addSubview(editor)
        window?.makeFirstResponder(editor)
        if selectAll {
            editor.selectAll(nil)
        } else {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
        resizeTextEditorToFit()
        showTextToolbar(for: annotationID)
        needsDisplay = true
    }

    private func discardTextEditingOverlay() {
        textEditor?.delegate = nil
        textEditor?.removeFromSuperview()
        textEditor = nil
        editingTextID = nil
        textMinimumHeight = 0
        textEditingOriginalAnnotation = nil
        isEditingNewText = false
    }

    func textDidChange(_ notification: Notification) {
        syncTextAnnotation(resizeToFit: true)
        refreshTextToolbar()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshTextToolbar()
    }

    private func syncTextAnnotation(resizeToFit: Bool) {
        guard let editor = textEditor,
              let editingTextID,
              let index = annotations.firstIndex(where: { $0.id == editingTextID }) else { return }
        if resizeToFit { resizeTextEditorToFit() }
        let fallback = RichTextBridge.defaultStyle(for: annotations[index])
        let document = RichTextBridge.document(from: editor.attributedString(), fallback: fallback)
        annotations[index].text = document.string
        annotations[index].richText = document
        annotations[index].frame = CanvasRect(editor.frame)
        needsDisplay = true
    }

    private func resizeTextEditorToFit() {
        guard let editor = textEditor,
              let layoutManager = editor.layoutManager,
              let textContainer = editor.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height + editor.textContainerInset.height * 2)
        var frame = editor.frame
        frame.size.height = min(
            max(textMinimumHeight, usedHeight, 8),
            max(8, bounds.maxY - frame.minY)
        )
        editor.frame = frame
    }

    private func showTextToolbar(for annotationID: UUID) {
        guard let annotation = annotations.first(where: { $0.id == annotationID }),
              annotation.kind == .text,
              window != nil else { return }
        hideTextToolbar()
        let controller = TextFormattingToolbarController(canvas: self)
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = controller
        textToolbarController = controller
        textToolbarPopover = popover
        controller.loadViewIfNeeded()
        controller.update(style: currentTextStyle())
        popover.show(
            relativeTo: annotation.frame.cgRect.insetBy(dx: -3, dy: -3),
            of: self,
            preferredEdge: .minY
        )
    }

    private func hideTextToolbar() {
        textToolbarPopover?.close()
        textToolbarPopover = nil
        textToolbarController = nil
    }

    private func refreshTextToolbar() {
        textToolbarController?.update(style: currentTextStyle())
    }

    fileprivate func currentTextStyle() -> RichTextStyle? {
        if let editor = textEditor {
            let fallback: RichTextStyle
            if let editingTextID,
               let annotation = annotations.first(where: { $0.id == editingTextID }) {
                fallback = RichTextBridge.defaultStyle(for: annotation)
            } else {
                fallback = RichTextStyle()
            }
            let storage = editor.textStorage ?? NSTextStorage()
            var location = editor.selectedRange().location
            if storage.length > 0 { location = min(location, storage.length - 1) }
            guard storage.length > 0 else {
                return RichTextBridge.style(from: editor.typingAttributes, fallback: fallback)
            }
            return RichTextBridge.style(
                from: storage.attributes(at: location, effectiveRange: nil),
                fallback: fallback
            )
        }
        guard let selectedID,
              let annotation = annotations.first(where: { $0.id == selectedID }) else { return nil }
        return annotation.richText?.runs.first?.style ?? RichTextBridge.defaultStyle(for: annotation)
    }

    fileprivate func setTextFontFamily(_ family: String) {
        mutateSelectedTextStyle { $0.fontFamily = family }
    }

    fileprivate func setTextFontSize(_ size: CGFloat) {
        mutateSelectedTextStyle { $0.fontSize = min(max(1, size), 512) }
    }

    fileprivate func toggleTextBold() {
        let value = !(currentTextStyle()?.isBold ?? false)
        mutateSelectedTextStyle { $0.isBold = value }
    }

    fileprivate func toggleTextItalic() {
        let value = !(currentTextStyle()?.isItalic ?? false)
        mutateSelectedTextStyle { $0.isItalic = value }
    }

    fileprivate func toggleTextUnderline() {
        let value = !(currentTextStyle()?.isUnderlined ?? false)
        mutateSelectedTextStyle { $0.isUnderlined = value }
    }

    fileprivate func toggleTextStrikethrough() {
        let value = !(currentTextStyle()?.isStruckThrough ?? false)
        mutateSelectedTextStyle { $0.isStruckThrough = value }
    }

    fileprivate func setTextForegroundColor(_ color: NSColor) {
        mutateSelectedTextStyle { $0.foregroundColor = RGBAColor(color) }
    }

    fileprivate func toggleTextBackground() {
        let current = currentTextStyle()?.backgroundColor
        mutateSelectedTextStyle {
            $0.backgroundColor = current == nil
                ? RGBAColor(red: 1, green: 0.86, blue: 0.2, alpha: 0.65)
                : nil
        }
    }

    fileprivate func setTextBackgroundColor(_ color: NSColor) {
        mutateSelectedTextStyle { $0.backgroundColor = RGBAColor(color) }
    }

    fileprivate func setTextAlignment(_ alignment: RichTextAlignment) {
        mutateSelectedTextStyle(usesParagraphRange: true) { $0.alignment = alignment }
    }

    private func mutateSelectedTextStyle(
        usesParagraphRange: Bool = false,
        _ mutation: (inout RichTextStyle) -> Void
    ) {
        guard let selectedID,
              annotations.first(where: { $0.id == selectedID })?.kind == .text else { return }
        if textEditor == nil {
            beginTextEditing(annotationID: selectedID, selectAll: true)
        }
        guard let editor = textEditor,
              let editingTextID,
              let annotation = annotations.first(where: { $0.id == editingTextID }) else { return }
        let fallback = RichTextBridge.defaultStyle(for: annotation)
        let selectedRange = editor.selectedRange()
        let formattingRange = usesParagraphRange
            ? (editor.string as NSString).paragraphRange(for: selectedRange)
            : selectedRange

        if formattingRange.length == 0 {
            var style = RichTextBridge.style(from: editor.typingAttributes, fallback: currentTextStyle() ?? fallback)
            mutation(&style)
            editor.typingAttributes = RichTextBridge.attributes(for: style)
        } else {
            let storage = editor.textStorage ?? NSTextStorage()
            var replacements: [(NSRange, [NSAttributedString.Key: Any])] = []
            storage.enumerateAttributes(in: formattingRange, options: []) { values, range, _ in
                var style = RichTextBridge.style(from: values, fallback: fallback)
                mutation(&style)
                replacements.append((range, RichTextBridge.attributes(for: style)))
            }
            storage.beginEditing()
            for (range, attributes) in replacements {
                storage.setAttributes(attributes, range: range)
            }
            storage.endEditing()
            editor.setSelectedRange(selectedRange)
        }
        syncTextAnnotation(resizeToFit: true)
        refreshTextToolbar()
    }

    func applyStrokeToSelection(color: RGBAColor, lineWidth: Double) {
        guard let selectedID,
              let index = annotations.firstIndex(where: { $0.id == selectedID }),
              EditorTool(rawValue: annotations[index].kind.rawValue)?.usesStrokeWidth == true else { return }
        var annotation = annotations[index]
        guard annotation.style.strokeColor != color || annotation.style.lineWidth != lineWidth else { return }
        annotation.style.strokeColor = color
        annotation.style.lineWidth = lineWidth
        annotations[index] = annotation
        onAnnotationsChanged?(annotations)
    }

    private func resizedFrame(_ frame: CGRect, for operation: DragOperation, by delta: CGPoint) -> CGRect {
        let minimumSize: CGFloat = 4
        var left = frame.minX
        var right = frame.maxX
        var top = frame.minY
        var bottom = frame.maxY

        switch operation {
        case .resizeTopLeft, .resizeBottomLeft, .resizeLeft:
            left = min(frame.maxX - minimumSize, frame.minX + delta.x)
        case .resizeTopRight, .resizeBottomRight, .resizeRight:
            right = max(frame.minX + minimumSize, frame.maxX + delta.x)
        case .move, .startPoint, .endPoint, .resizeTop, .resizeBottom:
            break
        }
        switch operation {
        case .resizeTopLeft, .resizeTopRight, .resizeTop:
            top = min(frame.maxY - minimumSize, frame.minY + delta.y)
        case .resizeBottomLeft, .resizeBottomRight, .resizeBottom:
            bottom = max(frame.minY + minimumSize, frame.maxY + delta.y)
        case .move, .startPoint, .endPoint, .resizeLeft, .resizeRight:
            break
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func selectionFrame(for annotation: Annotation) -> CGRect {
        let usesStroke = EditorTool(rawValue: annotation.kind.rawValue)?.usesStrokeWidth == true
        let outset = usesStroke
            ? annotation.style.lineWidth / 2 + overlayMetric(5)
            : overlayMetric(5)
        return annotation.frame.cgRect.insetBy(dx: -outset, dy: -outset)
    }

    private func drawSelectionOutline(in frame: CGRect) {
        let path = NSBezierPath(rect: frame)
        path.lineJoinStyle = .round
        NSColor.black.withAlphaComponent(0.72).setStroke()
        path.lineWidth = overlayMetric(5)
        path.stroke()
        NSColor.white.withAlphaComponent(0.96).setStroke()
        path.lineWidth = overlayMetric(3)
        path.stroke()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = overlayMetric(1.5)
        path.stroke()
    }

    private func drawResizeHandle(in frame: CGRect) {
        let radius = overlayMetric(3)
        drawHandlePath(NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius))
    }

    private func drawHandlePath(_ path: NSBezierPath) {
        NSColor.controlAccentColor.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.78).setStroke()
        path.lineWidth = overlayMetric(4)
        path.stroke()
        NSColor.white.setStroke()
        path.lineWidth = overlayMetric(2)
        path.stroke()
    }

    private func resizeHandles(for frame: CGRect) -> [CGRect] {
        let size = overlayMetric(20)
        let half = size / 2
        let centers = [
            CGPoint(x: frame.minX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.minX, y: frame.maxY),
            CGPoint(x: frame.maxX, y: frame.maxY),
            CGPoint(x: frame.midX, y: frame.minY),
            CGPoint(x: frame.midX, y: frame.maxY),
            CGPoint(x: frame.minX, y: frame.midY),
            CGPoint(x: frame.maxX, y: frame.midY)
        ]
        return centers.map {
            CGRect(x: $0.x - half, y: $0.y - half, width: size, height: size)
        }
    }

    private func visualResizeHandle(for hitArea: CGRect) -> CGRect {
        let size = overlayMetric(12)
        return CGRect(
            x: hitArea.midX - size / 2,
            y: hitArea.midY - size / 2,
            width: size,
            height: size
        )
    }

    private func overlayMetric(_ screenPoints: CGFloat) -> CGFloat {
        screenPoints / max(enclosingScrollView?.magnification ?? 1, 0.01)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), bounds.maxX), y: min(max(0, point.y), bounds.maxY))
    }

    private var hoverTrackingArea: NSTrackingArea?
    private var currentCursor = NSCursor.arrow

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard dragOperation == nil else { return }
        setCursor(for: clamped(convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
        currentCursor = .arrow
    }

    private func setCursor(for point: CGPoint) {
        let cursor = cursorForPoint(point)
        guard cursor != currentCursor else { return }
        cursor.set()
        currentCursor = cursor
    }

    private func cursorForPoint(_ point: CGPoint) -> NSCursor {
        guard tool == .select,
              let selectedID,
              let annotation = annotations.first(where: { $0.id == selectedID }) else { return .arrow }
        if annotation.kind == .line || annotation.kind == .arrow,
           let start = annotation.points.first?.cgPoint,
           let end = annotation.points.last?.cgPoint {
            return selectionHandle(at: start).contains(point) || selectionHandle(at: end).contains(point)
                ? .pointingHand
                : .arrow
        }
        guard let index = resizeHandles(for: selectionFrame(for: annotation))
            .firstIndex(where: { $0.contains(point) }) else { return .arrow }
        switch index {
        case 0, 3: return cachedMainDiagonalCursor
        case 1, 2: return cachedAntiDiagonalCursor
        case 4: return .resizeUp
        case 5: return .resizeDown
        case 6: return .resizeLeft
        case 7: return .resizeRight
        default: return .arrow
        }
    }

    private lazy var cachedMainDiagonalCursor = Self.makeDiagonalResizeCursor(mainDiagonal: true)
    private lazy var cachedAntiDiagonalCursor = Self.makeDiagonalResizeCursor(mainDiagonal: false)

    private static func makeDiagonalResizeCursor(mainDiagonal: Bool) -> NSCursor {
        let image = NSImage(size: CGSize(width: 22, height: 22), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath()
            let start = mainDiagonal ? CGPoint(x: 5, y: 17) : CGPoint(x: 5, y: 5)
            let end = mainDiagonal ? CGPoint(x: 17, y: 5) : CGPoint(x: 17, y: 17)
            path.move(to: start)
            path.line(to: end)
            path.move(to: CGPoint(x: start.x, y: start.y + (mainDiagonal ? -5 : 5)))
            path.line(to: start)
            path.line(to: CGPoint(x: start.x + 5, y: start.y))
            path.move(to: CGPoint(x: end.x - 5, y: end.y))
            path.line(to: end)
            path.line(to: CGPoint(x: end.x, y: end.y + (mainDiagonal ? 5 : -5)))
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 11, y: 11))
    }
}

@MainActor
private final class InlineTextView: NSTextView {
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class TextFormattingToolbarController: NSViewController {
    private weak var canvas: EditorCanvasView?
    private let fontPopup = NSPopUpButton()
    private let sizeCombo = NSComboBox()
    private let boldButton = NSButton(title: "B", target: nil, action: nil)
    private let italicButton = NSButton(title: "I", target: nil, action: nil)
    private let underlineButton = NSButton(title: "U", target: nil, action: nil)
    private let strikeButton = NSButton(title: "S", target: nil, action: nil)
    private let backgroundButton = NSButton(title: "H", target: nil, action: nil)
    private let foregroundWell = NSColorWell()
    private let backgroundWell = NSColorWell()
    private let alignment = NSSegmentedControl(
        images: ["text.alignleft", "text.aligncenter", "text.alignright", "text.justify"]
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) },
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var isUpdating = false

    init(canvas: EditorCanvasView) {
        self.canvas = canvas
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 594, height: 48))
        view = content

        fontPopup.addItems(withTitles: NSFontManager.shared.availableFontFamilies.sorted())
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        fontPopup.toolTip = "Font family"
        fontPopup.setAccessibilityLabel("Font family")
        fontPopup.widthAnchor.constraint(equalToConstant: 164).isActive = true

        sizeCombo.addItems(withObjectValues: [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72])
        sizeCombo.isEditable = true
        sizeCombo.target = self
        sizeCombo.action = #selector(sizeChanged)
        sizeCombo.toolTip = "Font size"
        sizeCombo.setAccessibilityLabel("Font size")
        sizeCombo.widthAnchor.constraint(equalToConstant: 56).isActive = true

        configureToggle(boldButton, label: "Bold", action: #selector(toggleBold))
        boldButton.font = .boldSystemFont(ofSize: 13)
        configureToggle(italicButton, label: "Italic", action: #selector(toggleItalic))
        italicButton.font = NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
        configureToggle(underlineButton, label: "Underline", action: #selector(toggleUnderline))
        underlineButton.attributedTitle = NSAttributedString(
            string: "U",
            attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
        )
        configureToggle(strikeButton, label: "Strikethrough", action: #selector(toggleStrike))
        strikeButton.attributedTitle = NSAttributedString(
            string: "S",
            attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        )
        configureToggle(backgroundButton, label: "Text background", action: #selector(toggleBackground))

        configureColorWell(foregroundWell, label: "Text color", action: #selector(foregroundChanged))
        configureColorWell(backgroundWell, label: "Background color", action: #selector(backgroundChanged))

        alignment.target = self
        alignment.action = #selector(alignmentChanged)
        alignment.toolTip = "Text alignment"
        alignment.setAccessibilityLabel("Text alignment")
        alignment.widthAnchor.constraint(equalToConstant: 108).isActive = true
        alignment.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let stack = NSStackView(views: [
            fontPopup, sizeCombo,
            boldButton, italicButton, underlineButton, strikeButton,
            separator, foregroundWell, backgroundButton, backgroundWell,
            alignment
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
    }

    func update(style: RichTextStyle?) {
        guard isViewLoaded, let style else { return }
        isUpdating = true
        if fontPopup.itemTitles.contains(style.fontFamily) {
            fontPopup.selectItem(withTitle: style.fontFamily)
        } else {
            fontPopup.addItem(withTitle: style.fontFamily)
            fontPopup.selectItem(withTitle: style.fontFamily)
        }
        sizeCombo.stringValue = String(format: "%g", style.fontSize)
        boldButton.state = style.isBold ? .on : .off
        italicButton.state = style.isItalic ? .on : .off
        underlineButton.state = style.isUnderlined ? .on : .off
        strikeButton.state = style.isStruckThrough ? .on : .off
        backgroundButton.state = style.backgroundColor == nil ? .off : .on
        foregroundWell.color = style.foregroundColor.nsColor
        backgroundWell.color = style.backgroundColor?.nsColor
            ?? NSColor(srgbRed: 1, green: 0.86, blue: 0.2, alpha: 0.65)
        switch style.alignment {
        case .left: alignment.selectedSegment = 0
        case .center: alignment.selectedSegment = 1
        case .right: alignment.selectedSegment = 2
        case .justified: alignment.selectedSegment = 3
        }
        isUpdating = false
    }

    private func configureToggle(_ button: NSButton, label: String, action: Selector) {
        button.setButtonType(.toggle)
        button.bezelStyle = .texturedRounded
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func configureColorWell(_ well: NSColorWell, label: String, action: Selector) {
        well.colorWellStyle = .minimal
        well.target = self
        well.action = action
        well.toolTip = label
        well.setAccessibilityLabel(label)
        well.widthAnchor.constraint(equalToConstant: 24).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @objc private func fontChanged() {
        guard !isUpdating, let family = fontPopup.titleOfSelectedItem else { return }
        canvas?.setTextFontFamily(family)
    }

    @objc private func sizeChanged() {
        guard !isUpdating, let size = Double(sizeCombo.stringValue), size > 0 else { return }
        canvas?.setTextFontSize(size)
    }

    @objc private func toggleBold() { if !isUpdating { canvas?.toggleTextBold() } }
    @objc private func toggleItalic() { if !isUpdating { canvas?.toggleTextItalic() } }
    @objc private func toggleUnderline() { if !isUpdating { canvas?.toggleTextUnderline() } }
    @objc private func toggleStrike() { if !isUpdating { canvas?.toggleTextStrikethrough() } }
    @objc private func toggleBackground() { if !isUpdating { canvas?.toggleTextBackground() } }

    @objc private func foregroundChanged() {
        if !isUpdating { canvas?.setTextForegroundColor(foregroundWell.color) }
    }

    @objc private func backgroundChanged() {
        if !isUpdating { canvas?.setTextBackgroundColor(backgroundWell.color) }
    }

    @objc private func alignmentChanged() {
        guard !isUpdating else { return }
        let value: RichTextAlignment
        switch alignment.selectedSegment {
        case 1: value = .center
        case 2: value = .right
        case 3: value = .justified
        default: value = .left
        }
        canvas?.setTextAlignment(value)
    }
}

@MainActor
private final class BackdropPanelController: NSWindowController, NSWindowDelegate {
    private var configuration: BackdropConfiguration
    private let onSave: (BackdropConfiguration) -> Void
    private let preview: BackdropPreviewView
    private let enabled = NSButton(checkboxWithTitle: "Add backdrop when copying or saving", target: nil, action: nil)
    private let padding = NSSlider(value: 48, minValue: 0, maxValue: 180, target: nil, action: nil)
    private let radius = NSSlider(value: 16, minValue: 0, maxValue: 64, target: nil, action: nil)
    private let shadow = NSSlider(value: 18, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let gradient = NSButton(checkboxWithTitle: "Use gradient", target: nil, action: nil)
    private let startColor = NSColorWell()
    private let endColor = NSColorWell()
    private let aspect = NSPopUpButton()

    init(
        configuration: BackdropConfiguration,
        image: CGImage,
        imagePixelSize: CGSize,
        onSave: @escaping (BackdropConfiguration) -> Void
    ) {
        self.configuration = configuration
        self.onSave = onSave
        preview = BackdropPreviewView(image: image, imagePixelSize: imagePixelSize, configuration: configuration)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 590),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Backdrop"
        super.init(window: window)
        window.delegate = self
        configure()
    }

    required init?(coder: NSCoder) { nil }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    private func configure() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let explanation = NSTextField(wrappingLabelWithString: "Backdrop adds a presentation background, padding, rounded corners, and a shadow to exported copies. Your editable screenshot stays unchanged.")
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 3

        enabled.state = configuration.isEnabled ? .on : .off
        padding.doubleValue = configuration.padding
        radius.doubleValue = configuration.cornerRadius
        shadow.doubleValue = configuration.shadowRadius
        gradient.state = configuration.useGradient ? .on : .off
        startColor.color = configuration.startColor.nsColor
        endColor.color = configuration.endColor.nsColor
        aspect.addItems(withTitles: ["Automatic", "Square (1:1)", "Standard (4:3)", "Widescreen (16:9)"])
        aspect.selectItem(at: BackdropAspect.allCases.firstIndex(of: configuration.aspect) ?? 0)

        for control in [enabled, gradient] {
            control.target = self
            control.action = #selector(previewChanged)
        }
        for control in [padding, radius, shadow] {
            control.target = self
            control.action = #selector(previewChanged)
        }
        for colorWell in [startColor, endColor] {
            colorWell.target = self
            colorWell.action = #selector(previewChanged)
            colorWell.colorWellStyle = .minimal
            colorWell.setAccessibilityLabel("Backdrop color")
        }
        aspect.target = self
        aspect.action = #selector(previewChanged)

        let colors = NSStackView(views: [startColor, endColor])
        colors.orientation = .horizontal
        colors.spacing = 12

        stack.addArrangedSubview(explanation)
        stack.addArrangedSubview(preview)
        stack.addArrangedSubview(enabled)
        stack.addArrangedSubview(labeled("Padding", padding))
        stack.addArrangedSubview(labeled("Corner radius", radius))
        stack.addArrangedSubview(labeled("Shadow", shadow))
        stack.addArrangedSubview(gradient)
        stack.addArrangedSubview(labeled("Colors", colors))
        stack.addArrangedSubview(labeled("Canvas", aspect))

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(apply))
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, applyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(equalToConstant: 170),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateControlsEnabledState()
    }

    private func labeled(_ text: String, _ control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let label = NSTextField(labelWithString: text)
        label.widthAnchor.constraint(equalToConstant: 112).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        return row
    }

    private func currentConfiguration() -> BackdropConfiguration {
        var result = configuration
        result.isEnabled = enabled.state == .on
        result.padding = padding.doubleValue
        result.cornerRadius = radius.doubleValue
        result.shadowRadius = shadow.doubleValue
        result.useGradient = gradient.state == .on
        result.startColor = RGBAColor(startColor.color)
        result.endColor = RGBAColor(endColor.color)
        result.aspect = BackdropAspect.allCases[max(0, aspect.indexOfSelectedItem)]
        return result
    }

    private func updateControlsEnabledState() {
        let isEnabled = enabled.state == .on
        for control in [padding, radius, shadow, gradient, startColor, endColor, aspect] {
            control.isEnabled = isEnabled
        }
        endColor.isEnabled = isEnabled && gradient.state == .on
    }

    @objc private func previewChanged() {
        updateControlsEnabledState()
        preview.configuration = currentConfiguration()
    }

    @objc private func cancel() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: .cancel)
        } else {
            window.orderOut(nil)
        }
    }

    @objc private func apply() {
        configuration = currentConfiguration()
        onSave(configuration)
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: .OK)
        } else {
            window.orderOut(nil)
        }
    }
}

@MainActor
private final class BackdropPreviewView: NSView {
    private let image: NSImage
    private let imagePixelSize: CGSize
    var configuration: BackdropConfiguration { didSet { needsDisplay = true } }

    init(image: CGImage, imagePixelSize: CGSize, configuration: BackdropConfiguration) {
        self.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        self.imagePixelSize = imagePixelSize
        self.configuration = configuration
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        setAccessibilityRole(.image)
        setAccessibilityLabel("Backdrop export preview")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        let available = bounds.insetBy(dx: 14, dy: 14)
        guard configuration.isEnabled else {
            let imageRect = fittedRect(
                aspect: imagePixelSize.width / imagePixelSize.height,
                inside: available.insetBy(dx: 28, dy: 8)
            )
            image.draw(in: imageRect)
            return
        }

        let sourceWidth = imagePixelSize.width
        let sourceHeight = imagePixelSize.height
        let padding = CGFloat(configuration.padding)
        var canvasSize = CGSize(width: sourceWidth + padding * 2, height: sourceHeight + padding * 2)
        switch configuration.aspect {
        case .automatic: break
        case .square: canvasSize = fittedCanvas(content: canvasSize, aspect: 1)
        case .fourByThree: canvasSize = fittedCanvas(content: canvasSize, aspect: 4.0 / 3.0)
        case .sixteenByNine: canvasSize = fittedCanvas(content: canvasSize, aspect: 16.0 / 9.0)
        }
        let canvasRect = fittedRect(aspect: canvasSize.width / canvasSize.height, inside: available)
        let canvasPath = NSBezierPath(roundedRect: canvasRect, xRadius: 6, yRadius: 6)
        if configuration.useGradient {
            NSGradient(starting: configuration.startColor.nsColor, ending: configuration.endColor.nsColor)?.draw(in: canvasPath, angle: -45)
        } else {
            configuration.startColor.nsColor.setFill()
            canvasPath.fill()
        }

        let scale = min(canvasRect.width / canvasSize.width, canvasRect.height / canvasSize.height)
        let imageRect = CGRect(
            x: canvasRect.midX - sourceWidth * scale / 2,
            y: canvasRect.midY - sourceHeight * scale / 2,
            width: sourceWidth * scale,
            height: sourceHeight * scale
        )
        let cornerRadius = CGFloat(configuration.cornerRadius) * scale
        let imagePath = NSBezierPath(roundedRect: imageRect, xRadius: cornerRadius, yRadius: cornerRadius)
        if configuration.shadowRadius > 0 {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = min(18, CGFloat(configuration.shadowRadius) * scale)
            shadow.shadowOffset = CGSize(width: 0, height: -3)
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            imagePath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        imagePath.addClip()
        image.draw(in: imageRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func fittedRect(aspect: CGFloat, inside rect: CGRect) -> CGRect {
        if rect.width / rect.height > aspect {
            let width = rect.height * aspect
            return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        }
        let height = rect.width / aspect
        return CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }

    private func fittedCanvas(content: CGSize, aspect: CGFloat) -> CGSize {
        if content.width / content.height > aspect {
            return CGSize(width: content.width, height: content.width / aspect)
        }
        return CGSize(width: content.height * aspect, height: content.height)
    }
}
