import AppKit

@MainActor
final class BackdropPanelController: NSWindowController, NSWindowDelegate {
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
