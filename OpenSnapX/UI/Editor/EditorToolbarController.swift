import AppKit

@MainActor
final class EditorToolbarController: NSViewController {
    weak var delegate: (any EditorToolbarControllerDelegate)?

    private let originalPixelSize: CGSize
    private let displayScale: CGFloat
    private var currentPixelSize: CGSize
    private(set) var showsLogicalImageSize: Bool
    private(set) var activeTool: EditorTool = .select
    private(set) var style = EditorToolbarStyle(
        color: RGBAColor(NSColor.systemRed),
        strokeWidth: 15,
        counterFontSize: 24
    )

    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 15, minValue: 1, maxValue: 28, target: nil, action: nil)
    private let counterFontSlider = NSSlider(value: 24, minValue: 12, maxValue: 96, target: nil, action: nil)
    private let colorLabel = NSTextField(labelWithString: "#FF0000")
    private let widthLabel = NSTextField(labelWithString: "15 pt")
    private let widthCaption = NSTextField(labelWithString: "Stroke width")
    private let imageSizeLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var colorPalettePopover: NSPopover?
    private var imageSizePopover: NSPopover?
    private var toolButtons: [EditorTool: EditorChromeButton] = [:]
    private var moreToolsButton: EditorChromeButton?
    private var selectedAnnotationKind: AnnotationKind?
    private weak var styleMetricGroup: NSView?
    private var hasOCRResults = false
    private var isOCRSelectionActive = false

    init(
        originalPixelSize: CGSize,
        currentPixelSize: CGSize,
        displayScale: CGFloat,
        showsLogicalImageSize: Bool
    ) {
        self.originalPixelSize = originalPixelSize
        self.currentPixelSize = currentPixelSize
        self.displayScale = displayScale
        self.showsLogicalImageSize = showsLogicalImageSize
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
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
        view = bar
        updateStyleLabels()
        updateImageSizeLabel()
    }

    func setActiveTool(_ tool: EditorTool) {
        activeTool = tool
        for (candidate, button) in toolButtons {
            button.setSelected(candidate == tool)
        }
        moreToolsButton?.setSelected(toolButtons[tool] == nil)
        updateStyleLabels()
    }

    func updateSelection(_ annotation: Annotation?) {
        selectedAnnotationKind = annotation?.kind
        if let annotation,
           EditorTool(rawValue: annotation.kind.rawValue)?.usesStrokeWidth == true {
            colorWell.color = annotation.style.strokeColor.nsColor
            widthSlider.maxValue = max(28, annotation.style.lineWidth)
            widthSlider.doubleValue = annotation.style.lineWidth
            style.color = annotation.style.strokeColor
            style.strokeWidth = annotation.style.lineWidth
        } else if let annotation, annotation.kind == .counter {
            colorWell.color = annotation.style.strokeColor.nsColor
            counterFontSlider.maxValue = max(96, annotation.style.fontSize)
            counterFontSlider.doubleValue = annotation.style.fontSize
            style.color = annotation.style.strokeColor
            style.counterFontSize = annotation.style.fontSize
        }
        updateStyleLabels()
    }

    func updateImageSize(_ size: CGSize, showsLogicalSize: Bool? = nil) {
        currentPixelSize = size
        if let showsLogicalSize { showsLogicalImageSize = showsLogicalSize }
        updateImageSizeLabel()
    }

    func updateZoom(_ magnification: CGFloat) {
        zoomLabel.stringValue = "\(Int((magnification * 100).rounded()))%"
    }

    func updateOCRState(hasResults: Bool, isSelectionActive: Bool) {
        hasOCRResults = hasResults
        isOCRSelectionActive = isSelectionActive
    }

    private func emit(_ command: EditorToolbarCommand) {
        delegate?.editorToolbar(self, perform: command)
    }

    private func selectTool(_ tool: EditorTool) {
        setActiveTool(tool)
        emit(.selectTool(tool))
    }

    private func makeExportStrip() -> NSView {
        let stack = chromeStack(spacing: 4)
        stack.addArrangedSubview(chromeButton(symbol: "doc.on.doc", label: "Copy", hint: "Copy image") { [weak self] in
            self?.emit(.copyRendered)
        })
        stack.addArrangedSubview(chromeButton(symbol: "square.and.arrow.down", label: "Save", hint: "Save image") { [weak self] in
            self?.emit(.saveRendered)
        })
        return stack
    }

    private func makeHistoryStrip() -> NSView {
        let stack = chromeStack(spacing: 4)
        stack.addArrangedSubview(chromeButton(symbol: "arrow.uturn.backward", label: "Undo", hint: "Undo last edit") { [weak self] in
            self?.emit(.undo)
        })
        stack.addArrangedSubview(chromeButton(symbol: "arrow.uturn.forward", label: "Redo", hint: "Redo last edit") { [weak self] in
            self?.emit(.redo)
        })
        stack.addArrangedSubview(chromeButton(symbol: "eraser", label: "Clear all edits", hint: "Clear all edits • Undoable") { [weak self] in
            self?.emit(.clearAllEdits)
        })
        stack.addArrangedSubview(chromeSeparator())
        stack.addArrangedSubview(chromeButton(symbol: "trash", label: "Discard capture", hint: "Discard capture and delete from history") { [weak self] in
            self?.emit(.discardCapture)
        })
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

        let more = EditorChromeButton(symbol: "ellipsis", label: "More tools and actions", showsSelection: true) { [weak self] in
            guard let self, let button = self.moreToolsButton else { return }
            self.showMoreTools(button)
        }
        more.toolTip = "More tools"
        more.setAccessibilityHelp("More tools")
        moreToolsButton = more
        stack.addArrangedSubview(more)
        return stack
    }

    private func makeToolGroup(_ tools: [EditorTool], accessibilityLabel: String) -> NSView {
        let stack = chromeStack(spacing: 2)
        stack.setAccessibilityLabel(accessibilityLabel)
        for tool in tools {
            let button = EditorChromeButton(symbol: tool.symbol, label: tool.rawValue.capitalized, showsSelection: true) { [weak self] in
                self?.selectTool(tool)
            }
            let hint = toolHint(for: tool)
            button.toolTip = hint
            button.setAccessibilityHelp(hint)
            button.setSelected(tool == activeTool)
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
        sizeGroup.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showImageSizePopover(_:))))
        let zoomGroup = metadataGroup(valueLabel: zoomLabel, caption: "Zoom")

        let stack = NSStackView(views: [
            colorGroup, chromeSeparator(), widthGroup, chromeSeparator(),
            sizeGroup, chromeSeparator(), zoomGroup
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
        return stack
    }

    private func makeColorInfo() -> NSView {
        colorWell.color = style.color.nsColor
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
        colorLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(copyColorHex)))
        colorLabel.setAccessibilityLabel("Color hex, click or press Tab to copy")
        return row
    }

    private func makeWidthInfo() -> NSView {
        widthLabel.font = .systemFont(ofSize: 13, weight: .medium)
        widthLabel.textColor = .labelColor
        widthLabel.alignment = .left
        widthCaption.font = .systemFont(ofSize: 11)
        widthCaption.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [widthLabel, widthCaption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.button)
        styleMetricGroup = stack
        stack.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showStyleMetricPopover(_:))))
        return stack
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
        let samplerButton = NSButton(title: "Pick from Capture", target: self, action: #selector(sampleColorFromCapture))
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

    @objc private func showStyleMetricPopover(_ sender: NSClickGestureRecognizer) {
        guard let anchor = sender.view else { return }
        let slider: NSSlider
        if isCounterSizeContext {
            counterFontSlider.target = self
            counterFontSlider.action = #selector(styleChanged)
            counterFontSlider.toolTip = "Step number size: 12–96 pt"
            counterFontSlider.setAccessibilityLabel("Step number size in points")
            slider = counterFontSlider
        } else {
            widthSlider.target = self
            widthSlider.action = #selector(styleChanged)
            widthSlider.toolTip = "Stroke width: 1–28 pt"
            widthSlider.setAccessibilityLabel("Stroke width in points")
            slider = widthSlider
        }
        slider.isContinuous = true
        slider.controlSize = .small
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 168, height: 44))
        slider.frame = CGRect(x: 14, y: 10, width: 140, height: 24)
        slider.removeFromSuperview()
        container.addSubview(slider)
        let controller = NSViewController()
        controller.view = container
        let popover = NSPopover()
        popover.contentSize = container.frame.size
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    @objc private func showImageSizePopover(_ sender: NSClickGestureRecognizer) {
        guard let anchor = sender.view else { return }
        imageSizePopover?.close()
        let controller = ImageResizePopoverController(
            originalPixelSize: originalPixelSize,
            currentPixelSize: currentPixelSize,
            displayScale: max(1, displayScale),
            showsLogicalSize: showsLogicalImageSize,
            onLogicalSizeChanged: { [weak self] showsLogicalSize in
                guard let self else { return }
                self.showsLogicalImageSize = showsLogicalSize
                self.updateImageSizeLabel()
            },
            onResize: { [weak self] size in
                guard let self else { return }
                self.emit(.resizeImage(size))
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

    @objc private func showMoreTools(_ sender: NSView) {
        let menu = NSMenu(title: "More tools")
        for tool in [EditorTool.blur, .pixelate, .redact, .crop] {
            let item = NSMenuItem(title: tool.rawValue.capitalized, action: #selector(selectToolFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tool.rawValue
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: item.title)
            item.state = activeTool == tool ? .on : .off
            item.toolTip = toolHint(for: tool)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let recognizeTitle = isOCRSelectionActive
            ? "Hide Text Selection"
            : (hasOCRResults ? "Select Recognized Text" : "Recognize Text")
        let recognize = NSMenuItem(title: recognizeTitle, action: #selector(toggleRecognizedText), keyEquivalent: "")
        recognize.target = self
        recognize.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: recognize.title)
        recognize.state = isOCRSelectionActive ? .on : .off
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
        guard let rawValue = sender.representedObject as? String,
              let tool = EditorTool(rawValue: rawValue) else { return }
        selectTool(tool)
    }

    @objc private func toggleRecognizedText() { emit(.toggleRecognizedText) }
    @objc private func showBackdrop() { emit(.showBackdrop) }

    @objc private func styleChanged() {
        style.color = RGBAColor(colorWell.color)
        style.strokeWidth = widthSlider.doubleValue
        style.counterFontSize = counterFontSlider.doubleValue
        updateStyleLabels()
        emit(.changeStyle(style))
    }

    @objc private func copyColorHex() {
        emit(.copyColorHex(hexString(for: colorWell.color)))
    }

    private var isCounterSizeContext: Bool {
        activeTool == .counter || (activeTool == .select && selectedAnnotationKind == .counter)
    }

    private func updateStyleLabels() {
        colorLabel.stringValue = hexString(for: colorWell.color)
        let metricName: String
        if isCounterSizeContext {
            widthLabel.stringValue = "\(Int(counterFontSlider.doubleValue.rounded())) pt"
            metricName = "Number size"
        } else {
            widthLabel.stringValue = "\(Int(widthSlider.doubleValue.rounded())) pt"
            metricName = "Stroke width"
        }
        widthCaption.stringValue = metricName
        widthLabel.toolTip = metricName
        styleMetricGroup?.toolTip = metricName
        styleMetricGroup?.setAccessibilityLabel(metricName)
        styleMetricGroup?.setAccessibilityHelp("Click to change \(metricName.lowercased())")
        for (tool, button) in toolButtons {
            let hint = toolHint(for: tool)
            button.toolTip = hint
            button.setAccessibilityHelp(hint)
        }
    }

    private func updateImageSizeLabel() {
        let width = currentPixelSize.width
        let height = currentPixelSize.height
        if showsLogicalImageSize {
            let scale = max(1, displayScale)
            imageSizeLabel.stringValue = "\(formattedDimension(width / scale))×\(formattedDimension(height / scale))pt"
        } else {
            imageSizeLabel.stringValue = "\(Int(width))×\(Int(height))px"
        }
        imageSizeLabel.toolTip = "Resize screenshot"
        imageSizeLabel.setAccessibilityLabel("Image size \(imageSizeLabel.stringValue). Click to resize.")
    }

    private func toolHint(for tool: EditorTool) -> String {
        if tool == .counter {
            return "\(tool.hint) • Number: \(Int(counterFontSlider.doubleValue.rounded())) pt"
        }
        guard tool.usesStrokeWidth else { return tool.hint }
        return "\(tool.hint) • Stroke: \(Int(widthSlider.doubleValue.rounded())) pt"
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

    private func chromeButton(symbol: String, label: String, hint: String, action: @escaping () -> Void) -> EditorChromeButton {
        let button = EditorChromeButton(symbol: symbol, label: label, showsSelection: false, action: action)
        button.toolTip = hint
        button.setAccessibilityHelp(hint)
        return button
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
}
