import AppKit

@MainActor
final class TextReviewWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let onCopy: (String) -> Void
    private let onClose: () -> Void
    private let textView = NSTextView()
    private let copyButton = NSButton(title: "Copy & Close", target: nil, action: nil)

    init(
        text: String,
        onCopy: @escaping (String) -> Void,
        onClose: @escaping () -> Void = {}
    ) {
        self.onCopy = onCopy
        self.onClose = onClose

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Review Recognized Text"
        window.minSize = CGSize(width: 420, height: 260)
        super.init(window: window)
        window.delegate = self
        configure(text: text)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        ApplicationPresentation.activateRegularApplication()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func textDidChange(_ notification: Notification) {
        updateCopyButton()
    }

    private func configure(text: String) {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Review and correct the recognized text")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "The captured image was processed in memory and is not saved to History.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView

        textView.string = text
        textView.delegate = self
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Recognized text")

        copyButton.target = self
        copyButton.action = #selector(copyAndClose)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .large
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = [.command]
        copyButton.toolTip = "Copy the reviewed text and close this window (Command-Return)"
        copyButton.setAccessibilityHelp(copyButton.toolTip)
        updateCopyButton()

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [buttonSpacer, copyButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let root = NSStackView(views: [title, detail, scrollView, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        for view in [title, detail, scrollView, buttons] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
    }

    private func updateCopyButton() {
        copyButton.isEnabled = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func copyAndClose() {
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onCopy(text)
        close()
    }
}
