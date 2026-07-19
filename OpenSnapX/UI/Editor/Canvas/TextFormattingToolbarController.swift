import AppKit

@MainActor
protocol EditorTextFormattingTarget: AnyObject {
    func setTextFontFamily(_ family: String)
    func setTextFontSize(_ size: CGFloat)
    func toggleTextBold()
    func toggleTextItalic()
    func toggleTextUnderline()
    func toggleTextStrikethrough()
    func setTextForegroundColor(_ color: NSColor)
    func toggleTextBackground()
    func setTextBackgroundColor(_ color: NSColor)
    func setTextAlignment(_ alignment: RichTextAlignment)
}

@MainActor
final class TextFormattingToolbarController: NSViewController, NSComboBoxDelegate {
    private weak var target: (any EditorTextFormattingTarget)?
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
    private var lastActionFontSize: Double?

    init(target: any EditorTextFormattingTarget) {
        self.target = target
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
        sizeCombo.delegate = self
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
        target?.setTextFontFamily(family)
    }

    @objc private func sizeChanged() {
        guard let size = fontSizeValue(), size != lastActionFontSize else { return }
        lastActionFontSize = size
        target?.setTextFontSize(size)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSComboBox === sizeCombo else { return }
        defer { lastActionFontSize = nil }
        guard let size = fontSizeValue(), size != lastActionFontSize else { return }
        target?.setTextFontSize(size)
    }

    private func fontSizeValue() -> Double? {
        guard !isUpdating, let size = Double(sizeCombo.stringValue), size > 0 else { return nil }
        return size
    }

    @objc private func toggleBold() { if !isUpdating { target?.toggleTextBold() } }
    @objc private func toggleItalic() { if !isUpdating { target?.toggleTextItalic() } }
    @objc private func toggleUnderline() { if !isUpdating { target?.toggleTextUnderline() } }
    @objc private func toggleStrike() { if !isUpdating { target?.toggleTextStrikethrough() } }
    @objc private func toggleBackground() { if !isUpdating { target?.toggleTextBackground() } }

    @objc private func foregroundChanged() {
        if !isUpdating { target?.setTextForegroundColor(foregroundWell.color) }
    }

    @objc private func backgroundChanged() {
        if !isUpdating { target?.setTextBackgroundColor(backgroundWell.color) }
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
        target?.setTextAlignment(value)
    }
}
