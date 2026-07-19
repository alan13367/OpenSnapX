import AppKit

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
final class EditorWindowController: NSWindowController, NSWindowDelegate, EditorToolbarControllerDelegate {
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
    private let toolbar: EditorToolbarController
    private let scrollView = NSScrollView()
    private var persistTask: Task<Void, Never>?
    private let noticePresenter = EditorNoticePresenter()
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var backdropPanelController: BackdropPanelController?
    private var isDiscardingCapture = false
    private var displayedCanvasMagnification: CGFloat = 1

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
        toolbar = EditorToolbarController(
            originalPixelSize: CGSize(width: image.width, height: image.height),
            currentPixelSize: session.manifest.outputPixelSize,
            displayScale: max(1, session.manifest.displayScale),
            showsLogicalImageSize: session.manifest.resize == nil
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
        toolbar.delegate = self
        configureUI()
        canvas.onAnnotationsChanged = { [weak self] annotations in self?.annotationsChanged(annotations) }
        canvas.onSelectionChanged = { [weak self] annotation in self?.toolbar.updateSelection(annotation) }
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
        noticePresenter.dismissImmediately()
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

        toolbar.loadViewIfNeeded()
        root.addArrangedSubview(toolbar.view)
        noticePresenter.attach(to: content, below: toolbar.view)
        toolbar.updateOCRState(
            hasResults: !canvas.ocrResults.isEmpty,
            isSelectionActive: canvas.isOCRSelectionActive
        )

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
            toolbar.view.heightAnchor.constraint(equalToConstant: 52)
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
            self.updateZoom()
        }
    }

    private func alignWindowControls() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let editorBar = toolbar.view
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

    func editorToolbar(_ toolbar: EditorToolbarController, perform command: EditorToolbarCommand) {
        switch command {
        case .copyRendered: copyRendered()
        case .saveRendered: saveRendered()
        case .undo: undo()
        case .redo: redo()
        case .clearAllEdits: clearAllEdits()
        case .discardCapture: confirmDiscardCapture()
        case let .selectTool(tool): applyTool(tool)
        case let .changeStyle(style): applyToolbarStyle(style)
        case let .copyColorHex(hex):
            exportService.copyText(hex)
            noticePresenter.show("Copied \(hex)", style: .success)
        case let .resizeImage(size): applyImageResize(to: size)
        case .toggleRecognizedText: toggleRecognizedText()
        case .showBackdrop: showBackdrop()
        }
    }

    private func applyTool(_ tool: EditorTool) {
        canvas.tool = tool
        toolbar.setActiveTool(tool)
        configureCanvasStyle(toolbar.style)
    }

    private func applyToolbarStyle(_ style: EditorToolbarStyle) {
        configureCanvasStyle(style)
        canvas.applyStrokeToSelection(color: style.color, lineWidth: style.strokeWidth)
        canvas.applyCounterStyleToSelection(color: style.color, fontSize: style.counterFontSize)
    }

    private func configureCanvasStyle(_ style: EditorToolbarStyle) {
        canvas.style.strokeColor = style.color
        canvas.style.lineWidth = style.strokeWidth
        canvas.counterFontSize = style.counterFontSize
        canvas.style.fillColor = canvas.tool == .redact ? .black : nil
        canvas.style.opacity = canvas.tool == .highlighter ? 0.38 : 1
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53, canvas.tool != .select {
            canvas.commitTextEditing()
            applyTool(.select)
            return nil
        }
        guard event.keyCode == 48,
              !(window?.firstResponder is NSTextView),
              !(window?.firstResponder is NSTextField) else {
            return event
        }
        let color = toolbar.style.color.nsColor
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let hex = String(
            format: "#%02X%02X%02X",
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded())
        )
        exportService.copyText(hex)
        noticePresenter.show("Copied \(hex)", style: .success)
        return nil
    }

    @objc private func clipViewBoundsChanged() {
        updateZoom()
    }

    private func updateZoom() {
        let magnification = scrollView.magnification
        toolbar.updateZoom(magnification)
        if abs(magnification - displayedCanvasMagnification) > 0.0001 {
            displayedCanvasMagnification = magnification
            canvas.needsDisplay = true
        }
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
        applyImageGeometry(EditorImageGeometry(annotations: annotations, resize: resize))
        noticePresenter.show(
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
        toolbar.updateImageSize(session.manifest.outputPixelSize, showsLogicalSize: false)
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
        updateZoom()
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
            noticePresenter.show("Nothing to clear", style: .information)
            return
        }
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.replaceEdits(current)
        }
        window?.undoManager?.setActionName("Clear All Edits")
        applyEdits(EditorEdits())
        noticePresenter.show("Edits cleared — Undo restores them", style: .success)
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
        toolbar.updateOCRState(
            hasResults: !edits.ocrResults.isEmpty,
            isSelectionActive: canvas.isOCRSelectionActive
        )
        schedulePersist()
    }

    @objc private func toggleRecognizedText() {
        if canvas.isOCRSelectionActive {
            canvas.isOCRSelectionActive = false
            toolbar.updateOCRState(hasResults: !canvas.ocrResults.isEmpty, isSelectionActive: false)
            noticePresenter.show("Text selection hidden", style: .information)
            return
        }
        if !canvas.ocrResults.isEmpty {
            canvas.isOCRSelectionActive = true
            toolbar.updateOCRState(hasResults: true, isSelectionActive: true)
            noticePresenter.show("Click text or drag across regions to copy", style: .tip)
            return
        }
        Task {
            do {
                let results = try await ocrService.recognize(ImagePayload(image: sourceImage))
                session.ocrResults = results
                canvas.ocrResults = results
                canvas.isOCRSelectionActive = !results.isEmpty
                toolbar.updateOCRState(
                    hasResults: !results.isEmpty,
                    isSelectionActive: canvas.isOCRSelectionActive
                )
                schedulePersist()
                if !results.isEmpty {
                    noticePresenter.show("Text ready — click or drag across regions to copy", style: .success)
                } else {
                    noticePresenter.show("No text recognized", style: .information)
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
                await exportService.copy(
                    try await renderedImage(),
                    displayScale: session.manifest.displayScale
                )
                window?.close()
            } catch {
                present(error)
            }
        }
    }

    @objc private func saveRendered() {
        Task {
            do {
                _ = try await exportService.save(
                    try await renderedImage(),
                    displayScale: session.manifest.displayScale
                )
            } catch { present(error) }
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
            noticePresenter.show("Text copied", style: .success)
        } else {
            noticePresenter.show("\(results.count) text regions copied", style: .success)
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

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
    }
}
