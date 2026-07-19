import AppKit

@MainActor
final class EditorCanvasView: NSView, NSTextViewDelegate, NSPopoverDelegate, EditorTextFormattingTarget {
    var tool: EditorTool = .select {
        didSet {
            // Assigning a tool is an explicit mode change, even when Select is
            // clicked while already active. End inline editing so the text can
            // receive canvas drag events again.
            if textEditor != nil { commitTextEditing() }
            hideTextToolbar()
            if tool != .select { selectedID = nil }
        }
    }
    var style = AnnotationStyle()
    var counterFontSize: Double = 24
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

    private let renderer: EditorCanvasRenderer
    private var draft: Annotation?
    private var selectedID: UUID? {
        didSet {
            guard oldValue != selectedID else { return }
            let selected = selectedID.flatMap { id in annotations.first { $0.id == id } }
            if selected?.kind != .text { hideTextToolbar() }
            onSelectionChanged?(selected)
        }
    }
    private var dragStart: CGPoint?
    private var originalFrame: CGRect?
    private var originalPoints: [CanvasPoint] = []
    private var originalFontSize: Double?
    private var dragOperation: AnnotationDragOperation?
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
        renderer = EditorCanvasRenderer(image: image)
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
        originalFontSize = nil
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
        originalFontSize = nil
        dragOperation = nil
        copiedAnnotation = nil
        self.annotations = annotations
        self.ocrResults = ocrResults
        self.isOCRSelectionActive = isOCRSelectionActive && !ocrResults.isEmpty
        counter = (annotations.compactMap(\.counter).max() ?? 0) + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        renderer.draw(
            in: bounds,
            annotations: annotations,
            draft: draft,
            selectedID: selectedID,
            editingTextID: editingTextID,
            magnification: enclosingScrollView?.magnification ?? 1,
            ocrResults: ocrResults,
            isOCRSelectionActive: isOCRSelectionActive,
            selectedOCRIDs: selectedOCRIDs,
            ocrSelectionRect: ocrSelectionRect
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = AnnotationCanvasGeometry.clamped(convert(event.locationInWindow, from: nil), to: bounds)
        if isOCRSelectionActive {
            ocrDragStart = point
            ocrSelectionRect = CGRect(origin: point, size: .zero)
            selectedOCRIDs = Set(AnnotationCanvasGeometry.ocrResult(
                at: point,
                in: ocrResults,
                bounds: bounds
            ).map { [$0.id] } ?? [])
            needsDisplay = true
            return
        }

        if textEditor != nil { commitTextEditing() }
        if tool == .select,
           event.clickCount >= 2,
           let textAnnotation = AnnotationCanvasGeometry.annotation(at: point, in: annotations),
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
               let operation = AnnotationCanvasGeometry.dragOperation(
                   for: selected,
                   at: point,
                   selectionPadding: overlayMetric(5),
                   handleSize: overlayMetric(20)
               ) {
                dragOperation = operation
            } else {
                selectedID = AnnotationCanvasGeometry.annotation(at: point, in: annotations)?.id
                dragOperation = selectedID == nil ? nil : .move
            }
            if let selectedID, let selected = annotations.first(where: { $0.id == selectedID }) {
                originalFrame = AnnotationCanvasGeometry.geometryFrame(for: selected)
                originalPoints = selected.points
                originalFontSize = selected.style.fontSize
                hideTextToolbar()
            } else {
                originalFrame = nil
                originalPoints = []
                originalFontSize = nil
                hideTextToolbar()
            }
        } else if let kind = tool.annotationKind {
            hideTextToolbar()
            draft = Annotation(kind: kind, frame: CanvasRect(CGRect(origin: point, size: .zero)), points: [CanvasPoint(point)], style: style)
            if kind == .counter {
                draft?.counter = counter
                draft?.style.fontSize = counterFontSize
            }
            if kind == .text { draft?.text = "" }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = AnnotationCanvasGeometry.clamped(convert(event.locationInWindow, from: nil), to: bounds)
        if isOCRSelectionActive, let start = ocrDragStart {
            let selection = AnnotationCanvasGeometry.rect(from: start, to: point)
            ocrSelectionRect = selection
            selectedOCRIDs = Set(ocrResults.filter { AnnotationCanvasGeometry.ocrFrame(for: $0, in: bounds).intersects(selection) }.map(\.id))
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
                let newFrame = AnnotationCanvasGeometry.resizedFrame(originalFrame, for: dragOperation, by: delta)
                annotations[index].frame = CanvasRect(newFrame)
                annotations[index].points = AnnotationCanvasGeometry.resizedPoints(
                    originalPoints,
                    from: originalFrame,
                    to: newFrame
                )
                if annotations[index].kind == .counter, let originalFontSize {
                    annotations[index].style.fontSize = AnnotationCanvasGeometry.resizedFontSize(
                        originalFontSize,
                        from: originalFrame,
                        to: newFrame
                    )
                }
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
            if draft.kind == .pen || draft.kind == .highlighter {
                draft.points.append(CanvasPoint(point))
                draft.frame = CanvasRect(AnnotationCanvasGeometry.frame(
                    containing: draft.points,
                    fallback: draft.frame.cgRect
                ))
            } else {
                draft.frame = CanvasRect(AnnotationCanvasGeometry.rect(from: start, to: point))
                draft.points = [CanvasPoint(start), CanvasPoint(point)]
            }
            self.draft = draft
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isOCRSelectionActive {
            if let start = ocrDragStart {
                let point = AnnotationCanvasGeometry.clamped(convert(event.locationInWindow, from: nil), to: bounds)
                if hypot(point.x - start.x, point.y - start.y) < 3,
                   let result = AnnotationCanvasGeometry.ocrResult(at: point, in: ocrResults, bounds: bounds) {
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
            originalFontSize = nil
            dragOperation = nil
            didModifySelection = false
        }
        if tool == .select {
            if didModifySelection {
                onAnnotationsChanged?(annotations)
                if let selectedID {
                    onSelectionChanged?(annotations.first { $0.id == selectedID })
                }
            }
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
            if draft.kind == .counter {
                draft.frame = CanvasRect(AnnotationCanvasGeometry.defaultCounterFrame(centeredAt: draft.frame.cgRect.origin, annotation: draft))
            } else {
                draft.frame = CanvasRect(CGRect(x: draft.frame.x - 16, y: draft.frame.y - 16, width: 32, height: 32))
            }
        }
        if draft.kind == .counter {
            draft.frame = CanvasRect(AnnotationCanvasGeometry.counterFrameEnsuringTextFits(draft))
            counter += 1
        }
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
        editor.onEscape = { [weak self] in
            self?.commitTextEditing()
            self?.hideTextToolbar()
        }
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
        let controller = TextFormattingToolbarController(target: self)
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
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

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === textToolbarPopover else { return }
        textToolbarPopover = nil
        textToolbarController = nil
    }

    private func refreshTextToolbar() {
        textToolbarController?.update(style: currentTextStyle())
    }

    private func currentTextStyle() -> RichTextStyle? {
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

    func setTextFontFamily(_ family: String) {
        mutateSelectedTextStyle { $0.fontFamily = family }
    }

    func setTextFontSize(_ size: CGFloat) {
        mutateSelectedTextStyle { $0.fontSize = min(max(1, size), 512) }
    }

    func toggleTextBold() {
        let value = !(currentTextStyle()?.isBold ?? false)
        mutateSelectedTextStyle { $0.isBold = value }
    }

    func toggleTextItalic() {
        let value = !(currentTextStyle()?.isItalic ?? false)
        mutateSelectedTextStyle { $0.isItalic = value }
    }

    func toggleTextUnderline() {
        let value = !(currentTextStyle()?.isUnderlined ?? false)
        mutateSelectedTextStyle { $0.isUnderlined = value }
    }

    func toggleTextStrikethrough() {
        let value = !(currentTextStyle()?.isStruckThrough ?? false)
        mutateSelectedTextStyle { $0.isStruckThrough = value }
    }

    func setTextForegroundColor(_ color: NSColor) {
        mutateSelectedTextStyle { $0.foregroundColor = RGBAColor(color) }
    }

    func toggleTextBackground() {
        let current = currentTextStyle()?.backgroundColor
        mutateSelectedTextStyle {
            $0.backgroundColor = current == nil
                ? RGBAColor(red: 1, green: 0.86, blue: 0.2, alpha: 0.65)
                : nil
        }
    }

    func setTextBackgroundColor(_ color: NSColor) {
        mutateSelectedTextStyle { $0.backgroundColor = RGBAColor(color) }
    }

    func setTextAlignment(_ alignment: RichTextAlignment) {
        mutateSelectedTextStyle(usesParagraphRange: true) { $0.alignment = alignment }
    }

    private func mutateSelectedTextStyle(
        usesParagraphRange: Bool = false,
        _ mutation: (inout RichTextStyle) -> Void
    ) {
        guard let selectedID,
              let selectedIndex = annotations.firstIndex(where: { $0.id == selectedID && $0.kind == .text }) else { return }
        guard let editor = textEditor else {
            mutateTextAnnotation(at: selectedIndex, mutation)
            return
        }
        guard let editingTextID,
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

    private func mutateTextAnnotation(
        at index: Int,
        _ mutation: (inout RichTextStyle) -> Void
    ) {
        var annotation = annotations[index]
        let fallback = RichTextBridge.defaultStyle(for: annotation)
        let attributed = RichTextBridge.attributedString(for: annotation)
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return }

        var replacements: [(NSRange, [NSAttributedString.Key: Any])] = []
        attributed.enumerateAttributes(in: fullRange, options: []) { values, range, _ in
            var style = RichTextBridge.style(from: values, fallback: fallback)
            mutation(&style)
            replacements.append((range, RichTextBridge.attributes(for: style)))
        }
        attributed.beginEditing()
        for (range, attributes) in replacements {
            attributed.setAttributes(attributes, range: range)
        }
        attributed.endEditing()

        let document = RichTextBridge.document(from: attributed, fallback: fallback)
        annotation.text = document.string
        annotation.richText = document
        var frame = annotation.frame.cgRect
        let layoutWidth = max(1, frame.width - 4)
        let requiredHeight = ceil(attributed.boundingRect(
            with: CGSize(width: layoutWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height + 4)
        frame.size.height = min(
            max(frame.height, requiredHeight),
            max(8, bounds.maxY - frame.minY)
        )
        annotation.frame = CanvasRect(frame)
        annotations[index] = annotation
        onAnnotationsChanged?(annotations)
        refreshTextToolbar()
    }

    func applyCounterStyleToSelection(color: RGBAColor, fontSize: Double) {
        guard let selectedID,
              let index = annotations.firstIndex(where: { $0.id == selectedID }),
              annotations[index].kind == .counter else { return }
        var annotation = annotations[index]
        guard annotation.style.strokeColor != color || annotation.style.fontSize != fontSize else { return }
        annotation.style.strokeColor = color
        annotation.style.fontSize = fontSize
        annotation.frame = CanvasRect(AnnotationCanvasGeometry.counterFrameEnsuringTextFits(annotation))
        annotations[index] = annotation
        onAnnotationsChanged?(annotations)
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

    private func overlayMetric(_ screenPoints: CGFloat) -> CGFloat {
        screenPoints / max(enclosingScrollView?.magnification ?? 1, 0.01)
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
        setCursor(for: AnnotationCanvasGeometry.clamped(convert(event.locationInWindow, from: nil), to: bounds))
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
            return AnnotationCanvasGeometry.selectionHandle(at: start, size: overlayMetric(20)).contains(point)
                || AnnotationCanvasGeometry.selectionHandle(at: end, size: overlayMetric(20)).contains(point)
                ? .pointingHand
                : .arrow
        }
        guard let index = AnnotationCanvasGeometry.resizeHandles(
            for: AnnotationCanvasGeometry.selectionFrame(for: annotation, overlayPadding: overlayMetric(5)),
            size: overlayMetric(20)
        )
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
