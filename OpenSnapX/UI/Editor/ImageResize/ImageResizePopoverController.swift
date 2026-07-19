import AppKit

@MainActor
final class ImageResizePopoverController: NSViewController, NSTextFieldDelegate {
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
