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
    private var permissionPollTimer: Timer?

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
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 760),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to OpenSnapX"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 720, height: 740)
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        window.delegate = self
        configure()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        ApplicationPresentation.activateRegularApplication()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshPermissionStatus()
        startPermissionPolling()
        refreshShortcutStatuses(registerShortcuts())
    }

    private func configure() {
        guard let content = window?.contentView else { return }

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64)
        ])

        let title = NSTextField(labelWithString: "Welcome to OpenSnapX")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: "The fast, private screenshot toolkit built for your Mac. Set up screen access and shortcuts, then you’re ready to capture.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        let headerLabels = verticalStack([title, subtitle], spacing: 5)
        headerLabels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = horizontalStack([icon, headerLabels], spacing: 18)
        header.alignment = .centerY
        headerLabels.trailingAnchor.constraint(equalTo: header.trailingAnchor).isActive = true

        let permissionSection = makePermissionSection()
        let shortcutSection = makeShortcutSection()
        let flexibleSpace = NSView()
        flexibleSpace.setContentHuggingPriority(.defaultLow, for: .vertical)
        flexibleSpace.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        for view in [header, permissionSection, shortcutSection] {
            view.setContentHuggingPriority(.required, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        let root = verticalStack([
            header,
            separator(),
            permissionSection,
            separator(),
            shortcutSection,
            flexibleSpace,
            separator(),
            makeFooter()
        ], spacing: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 34),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -34),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
    }

    private func makePermissionSection() -> NSView {
        let title = NSTextField(labelWithString: "Screen access")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "macOS requires Screen Recording permission before OpenSnapX can capture. It only reads the screen when you start a capture.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        let labels = verticalStack([title, detail], spacing: 3)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        permissionStatus.font = .systemFont(ofSize: 11, weight: .medium)
        permissionStatus.alignment = .left
        permissionStatus.widthAnchor.constraint(equalToConstant: 92).isActive = true

        let heading = horizontalStack([
            symbolView("rectangle.inset.filled.and.person.filled", size: 17, color: .systemBlue),
            labels,
            permissionStatus
        ], spacing: 10)
        heading.alignment = .top
        labels.widthAnchor.constraint(equalTo: heading.widthAnchor, constant: -136).isActive = true

        let request = NSButton(title: "Allow Screen Access", target: self, action: #selector(requestPermission))
        request.bezelStyle = .rounded
        let open = NSButton(title: "Open Privacy Settings", target: self, action: #selector(openPrivacySettings))
        open.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = horizontalStack([spacer, open, request], spacing: 8)

        return verticalStack([heading, buttons], spacing: 10)
    }

    private func makeShortcutSection() -> NSView {
        let title = NSTextField(labelWithString: "Keyboard shortcuts")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "Apple’s ⌘⇧3/4/5 actions can run at the same time. To use those combinations only with OpenSnapX, disable their matches in Apple’s Screenshot settings.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        let labels = verticalStack([title, detail], spacing: 3)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = horizontalStack([
            symbolView("command", size: 17, color: .systemPurple),
            labels
        ], spacing: 10)
        heading.alignment = .top
        labels.trailingAnchor.constraint(equalTo: heading.trailingAnchor).isActive = true

        var rows: [NSView] = []
        for (index, action) in ShortcutAction.presentationOrder.enumerated() {
            if index > 0 { rows.append(insetSeparator()) }
            rows.append(shortcutRow(for: action))
        }
        let shortcuts = verticalStack(rows, spacing: 0)

        let open = NSButton(title: "Apple Screenshot Settings…", target: self, action: #selector(openKeyboardSettings))
        open.bezelStyle = .rounded
        open.toolTip = "In Keyboard Shortcuts, select Screenshots and turn off the shortcuts assigned to OpenSnapX"
        open.setAccessibilityHelp(open.toolTip)
        let reset = NSButton(title: "Restore Shortcut Defaults", target: self, action: #selector(resetShortcuts))
        reset.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = horizontalStack([spacer, reset, open], spacing: 8)

        return verticalStack([heading, shortcuts, buttons], spacing: 9)
    }

    private func makeFooter() -> NSView {
        let privacy = NSTextField(labelWithString: "Everything stays on this Mac. OpenSnapX makes no network requests.")
        privacy.textColor = .tertiaryLabelColor
        privacy.font = .systemFont(ofSize: 11)

        let finish = NSButton(title: "Finish Setup", target: self, action: #selector(finish))
        finish.bezelStyle = .rounded
        finish.controlSize = .large
        finish.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return horizontalStack([privacy, spacer, finish], spacing: 12)
    }

    private func shortcutRow(for action: ShortcutAction) -> NSView {
        let title = NSTextField(labelWithString: action.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: action.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let labels = verticalStack([title, detail], spacing: 2)
        labels.widthAnchor.constraint(equalToConstant: 224).isActive = true

        let recorder = ShortcutRecorderControl(shortcut: settings.shortcut(for: action))
        recorder.onChange = { [weak self] shortcut in
            guard let self else { return }
            self.settings.setShortcut(shortcut, for: action)
            self.refreshShortcutStatuses(self.registerShortcuts())
        }
        recorder.widthAnchor.constraint(equalToConstant: 126).isActive = true
        shortcutRecorders[action] = recorder

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.alignment = .left
        status.lineBreakMode = .byTruncatingTail
        status.widthAnchor.constraint(equalToConstant: 96).isActive = true
        shortcutStatusLabels[action] = status

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = horizontalStack([
            symbolView(action.symbolName, size: 14, color: .secondaryLabelColor),
            labels,
            recorder,
            status,
            spacer
        ], spacing: 10)
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        row.heightAnchor.constraint(equalToConstant: 45).isActive = true
        return row
    }

    private func symbolView(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        let view = NSImageView(image: image)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        view.contentTintColor = color
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 24).isActive = true
        view.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return view
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func horizontalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func insetSeparator() -> NSView {
        let container = NSView()
        let line = separator()
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 34),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 1)
        ])
        return container
    }

    @objc private func requestPermission() {
        _ = permissionService.request()
        refreshPermissionStatus()
        startPermissionPolling()
    }

    @objc private func openPrivacySettings() {
        permissionService.openSystemSettings()
    }

    @objc private func openKeyboardSettings() {
        permissionService.openKeyboardShortcutSettings()
    }

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

    private func startPermissionPolling() {
        guard permissionPollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPermissionStatus()
            }
        }
        permissionPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func refreshShortcutStatuses(_ results: [ShortcutRegistrationResult]) {
        for result in results {
            guard let label = shortcutStatusLabels[result.action] else { continue }
            let shortcut = settings.shortcut(for: result.action)
            if !result.succeeded {
                label.stringValue = "●  In use"
                label.textColor = .systemOrange
                label.toolTip = "Another app has reserved this shortcut (error \(result.status))."
            } else if shortcut.matchesBuiltInScreenshotShortcut {
                label.stringValue = "●  Check Apple"
                label.textColor = .systemOrange
                label.toolTip = "Registered in OpenSnapX, but this matches a built-in macOS screenshot shortcut. Disable the matching Apple shortcut if both actions run."
            } else {
                label.stringValue = "●  Ready"
                label.textColor = .systemGreen
                label.toolTip = "Shortcut registered while OpenSnapX is running."
            }
        }
    }

    private func rebuildShortcutRecorders() {
        for (action, recorder) in shortcutRecorders {
            recorder.shortcut = settings.shortcut(for: action)
        }
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        stopPermissionPolling()
    }
}
