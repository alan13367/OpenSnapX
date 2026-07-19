import AppKit

@MainActor
final class EditorNoticePresenter {
    private weak var hostView: NSView?
    private weak var anchorView: NSView?
    private var notice: EditorTransientNoticeView?
    private var dismissalTask: Task<Void, Never>?

    func attach(to hostView: NSView, below anchorView: NSView) {
        self.hostView = hostView
        self.anchorView = anchorView
    }

    func show(_ text: String, style: EditorNoticeStyle) {
        guard let hostView else { return }
        dismissalTask?.cancel()
        notice?.removeFromSuperview()

        let notice = EditorTransientNoticeView(text: text, style: style)
        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.alphaValue = 0
        hostView.addSubview(notice)
        self.notice = notice

        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: hostView.centerXAnchor),
            notice.topAnchor.constraint(equalTo: anchorView?.bottomAnchor ?? hostView.topAnchor, constant: 12),
            notice.leadingAnchor.constraint(greaterThanOrEqualTo: hostView.leadingAnchor, constant: 20),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: hostView.trailingAnchor, constant: -20),
            notice.widthAnchor.constraint(lessThanOrEqualToConstant: 500)
        ])
        hostView.layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            notice.animator().alphaValue = 1
        }
        dismissalTask = Task { [weak self, weak notice] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled, let self, let notice else { return }
            self.dismiss(notice)
        }
    }

    func dismissImmediately() {
        dismissalTask?.cancel()
        dismissalTask = nil
        notice?.removeFromSuperview()
        notice = nil
    }

    private func dismiss(_ notice: EditorTransientNoticeView) {
        guard self.notice === notice else { return }
        self.notice = nil
        dismissalTask = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            notice.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { notice.removeFromSuperview() }
        }
    }
}

enum EditorNoticeStyle {
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
final class EditorTransientNoticeView: NSVisualEffectView {
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
