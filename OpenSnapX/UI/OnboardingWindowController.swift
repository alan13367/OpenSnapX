import AppKit

@MainActor
final class OnboardingWindowController: NSWindowController {
    private let permissionService: ScreenPermissionService
    private let settings: SettingsStore
    private let registerShortcuts: () -> [ShortcutRegistrationResult]
    private let onFinish: () -> Void

    private let permissionStatus = NSTextField(labelWithString: "")
    private var shortcutStatusLabels: [ShortcutAction: NSTextField] = [:]
    private var shortcutRecorders: [ShortcutAction: ShortcutRecorderControl] = [:]

    init(
        permissionService: ScreenPermissionService,
        settings: SettingsStore,
        registerShortcuts: @escaping () -> [ShortcutRegistrationResult],
        onFinish: @escaping () -> Void
    ) {
        self.permissionService = permissionService
        self.settings = settings
        self.registerShortcuts = registerShortcuts
        self.onFinish = onFinish

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to OpenSnapX"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 700, height: 680)
        super.init(window: window)
        configure()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshPermissionStatus()
        refreshShortcutStatuses(registerShortcuts())
    }

    private func configure() {
        guard let content = window?.contentView else { return }

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 78),
            icon.heightAnchor.constraint(equalToConstant: 78)
        ])

        let title = NSTextField(labelWithString: "Welcome to OpenSnapX")
        title.font = .systemFont(ofSize: 30, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: "The fast, private screenshot toolkit built for your Mac. Set up two things and you’re ready to capture.")
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2

        let headline = NSStackView(views: [title, subtitle])
        headline.orientation = .vertical
        headline.alignment = .leading
        headline.spacing = 7
        let header = NSStackView(views: [icon, headline])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 20

        let permissionCard = makePermissionCard()
        let shortcutsCard = makeShortcutsCard()

        let privacy = NSTextField(labelWithString: "Everything stays on this Mac. OpenSnapX makes no network requests.")
        privacy.textColor = .tertiaryLabelColor
        privacy.font = .systemFont(ofSize: 12)

        let finish = NSButton(title: "Finish Setup", target: self, action: #selector(finish))
        finish.bezelStyle = .rounded
        finish.controlSize = .large
        finish.keyEquivalent = "\r"

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [privacy, footerSpacer, finish])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12

        let stack = NSStackView(views: [header, permissionCard, shortcutsCard, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -34),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 42),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissionCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutsCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func makePermissionCard() -> NSView {
        let card = OnboardingCardView()

        let symbol = makeSymbol("rectangle.inset.filled.and.person.filled", color: .systemBlue)
        let title = NSTextField(labelWithString: "Allow screen access")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "macOS requires Screen Recording permission before OpenSnapX can capture. It only reads the screen when you start a capture.")
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2

        permissionStatus.font = .systemFont(ofSize: 12, weight: .semibold)
        permissionStatus.alignment = .right

        let headingText = NSStackView(views: [title, detail])
        headingText.orientation = .vertical
        headingText.alignment = .leading
        headingText.spacing = 4
        let heading = NSStackView(views: [symbol, headingText, permissionStatus])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 12
        headingText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        permissionStatus.widthAnchor.constraint(equalToConstant: 112).isActive = true

        let request = NSButton(title: "Allow Screen Access", target: self, action: #selector(requestPermission))
        request.bezelStyle = .rounded
        let open = NSButton(title: "Open Privacy Settings", target: self, action: #selector(openPrivacySettings))
        open.bezelStyle = .rounded
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [buttonSpacer, open, request])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        install([heading, buttons], in: card, spacing: 16)
        card.heightAnchor.constraint(equalToConstant: 158).isActive = true
        return card
    }

    private func makeShortcutsCard() -> NSView {
        let card = OnboardingCardView()

        let symbol = makeSymbol("command", color: .systemPurple)
        let title = NSTextField(labelWithString: "Choose your capture shortcuts")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "Click a shortcut, then press the combination you want. If macOS already owns it, disable Apple’s matching screenshot shortcut and retry.")
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        let headingText = NSStackView(views: [title, detail])
        headingText.orientation = .vertical
        headingText.alignment = .leading
        headingText.spacing = 4
        let heading = NSStackView(views: [symbol, headingText])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 12

        var views: [NSView] = [heading]
        for action in ShortcutAction.presentationOrder {
            views.append(shortcutRow(for: action))
        }

        let open = NSButton(title: "Open Apple Screenshot Shortcuts…", target: self, action: #selector(openKeyboardSettings))
        open.bezelStyle = .inline
        open.contentTintColor = .controlAccentColor
        let reset = NSButton(title: "Restore OpenSnapX Defaults", target: self, action: #selector(resetShortcuts))
        reset.bezelStyle = .inline
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [open, spacer, reset])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY

        views.append(buttons)
        install(views, in: card, spacing: 11)
        card.heightAnchor.constraint(equalToConstant: 330).isActive = true
        return card
    }

    private func shortcutRow(for action: ShortcutAction) -> NSView {
        let symbol = makeSymbol(action.symbolName, color: .secondaryLabelColor, size: 16)

        let title = NSTextField(labelWithString: action.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: action.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let recorder = ShortcutRecorderControl(shortcut: settings.shortcut(for: action))
        recorder.onChange = { [weak self] shortcut in
            guard let self else { return }
            self.settings.setShortcut(shortcut, for: action)
            self.refreshShortcutStatuses(self.registerShortcuts())
        }
        recorder.widthAnchor.constraint(equalToConstant: 136).isActive = true
        shortcutRecorders[action] = recorder

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11, weight: .semibold)
        status.alignment = .right
        status.widthAnchor.constraint(equalToConstant: 76).isActive = true
        shortcutStatusLabels[action] = status

        let row = NSStackView(views: [symbol, text, recorder, status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return row
    }

    private func install(_ views: [NSView], in card: NSView, spacing: CGFloat) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
        ])
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    private func makeSymbol(_ name: String, color: NSColor, size: CGFloat = 20) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let view = NSImageView(image: image ?? NSImage())
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        view.contentTintColor = color
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 28),
            view.heightAnchor.constraint(equalToConstant: 28)
        ])
        return view
    }

    @objc private func requestPermission() {
        _ = permissionService.request()
        refreshPermissionStatus()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            refreshPermissionStatus()
        }
    }

    @objc private func openPrivacySettings() { permissionService.openSystemSettings() }
    @objc private func openKeyboardSettings() { permissionService.openKeyboardShortcutSettings() }

    @objc private func resetShortcuts() {
        for action in ShortcutAction.presentationOrder {
            settings.setShortcut(action.defaultShortcut, for: action)
        }
        rebuildShortcutRecorders()
        refreshShortcutStatuses(registerShortcuts())
    }

    @objc private func finish() {
        onFinish()
        close()
    }

    private func refreshPermissionStatus() {
        let authorized = permissionService.isAuthorized
        permissionStatus.stringValue = authorized ? "●  Ready" : "●  Not allowed"
        permissionStatus.textColor = authorized ? .systemGreen : .systemOrange
    }

    private func refreshShortcutStatuses(_ results: [ShortcutRegistrationResult]) {
        for result in results {
            guard let label = shortcutStatusLabels[result.action] else { continue }
            label.stringValue = result.succeeded ? "●  Ready" : "●  In use"
            label.textColor = result.succeeded ? .systemGreen : .systemOrange
            label.toolTip = result.succeeded ? "Shortcut registered" : "This shortcut is already registered by macOS or another app (error \(result.status))."
        }
    }

    private func rebuildShortcutRecorders() {
        for (action, recorder) in shortcutRecorders {
            recorder.shortcut = settings.shortcut(for: action)
        }
    }
}

private final class OnboardingCardView: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .contentBackground
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }

    required init?(coder: NSCoder) { nil }
}
