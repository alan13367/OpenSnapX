import AppKit
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settings: SettingsStore
    private let registerShortcuts: () -> [ShortcutRegistrationResult]
    private let showOnboarding: () -> Void
    private let permissionService = ScreenPermissionService()

    private let retention = NSPopUpButton()
    private let cursor = NSButton(checkboxWithTitle: "Include the pointer in captures", target: nil, action: nil)
    private let captureSound = NSButton(checkboxWithTitle: "Play a sound after capture", target: nil, action: nil)
    private let launch = NSButton(checkboxWithTitle: "Launch OpenSnapX at login", target: nil, action: nil)
    private var shortcutRecorders: [ShortcutAction: ShortcutRecorderControl] = [:]
    private var shortcutStatusLabels: [ShortcutAction: NSTextField] = [:]

    init(
        settings: SettingsStore,
        registerShortcuts: @escaping () -> [ShortcutRegistrationResult],
        showOnboarding: @escaping () -> Void
    ) {
        self.settings = settings
        self.registerShortcuts = registerShortcuts
        self.showOnboarding = showOnboarding

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenSnapX Settings"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 720, height: 720)
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        configure()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        ApplicationPresentation.activateRegularApplication()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshShortcutStatuses(registerShortcuts())
    }

    private func configure() {
        guard let content = window?.contentView else { return }

        configureControls()

        let appIcon = NSImageView(image: NSApp.applicationIconImage)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            appIcon.widthAnchor.constraint(equalToConstant: 56),
            appIcon.heightAnchor.constraint(equalToConstant: 56)
        ])

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Make OpenSnapX fit the way you capture.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let headerLabels = verticalStack([title, subtitle], spacing: 4)
        headerLabels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = horizontalStack([appIcon, headerLabels], spacing: 16)
        header.alignment = .centerY
        headerLabels.trailingAnchor.constraint(equalTo: header.trailingAnchor).isActive = true

        let root = verticalStack([
            header,
            separator(),
            makeCaptureSection(),
            separator(),
            makeShortcutSection(),
            separator(),
            makeFooter()
        ], spacing: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
    }

    private func configureControls() {
        retention.addItems(withTitles: ["1 day", "7 days", "30 days", "Forever"])
        retention.selectItem(at: [1, 7, 30, 0].firstIndex(of: settings.historyRetentionDays) ?? 1)
        cursor.state = settings.includeCursor ? .on : .off
        captureSound.state = settings.captureSoundEnabled ? .on : .off
        launch.state = settings.launchAtLogin ? .on : .off

        for control in [retention, cursor, captureSound] {
            control.target = self
            control.action = #selector(preferencesChanged)
        }
        launch.target = self
        launch.action = #selector(launchAtLoginChanged)

        retention.controlSize = .regular
        retention.widthAnchor.constraint(equalToConstant: 220).isActive = true
    }

    private func makeCaptureSection() -> NSView {
        let heading = sectionHeading(
            "Capture",
            detail: "Captured screenshots open directly in the editor.",
            symbol: "camera.viewfinder",
            color: .systemBlue
        )

        let options = verticalStack([
            preferenceRow("History retention", detail: "How long editable captures stay on this Mac", control: retention)
        ], spacing: 0)

        cursor.font = .systemFont(ofSize: 13)
        captureSound.font = .systemFont(ofSize: 13)
        launch.font = .systemFont(ofSize: 13)
        let checkSpacer = NSView()
        checkSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let captureChecks = horizontalStack([cursor, captureSound, checkSpacer], spacing: 24)
        let checks = verticalStack([captureChecks, launch], spacing: 8)
        checks.edgeInsets = NSEdgeInsets(top: 4, left: 34, bottom: 0, right: 0)

        return verticalStack([heading, options, checks], spacing: 10)
    }

    private func makeShortcutSection() -> NSView {
        let heading = sectionHeading(
            "Keyboard shortcuts",
            detail: "Apple’s ⌘⇧3/4/5 actions can run at the same time. To use those combinations only with OpenSnapX, disable their matches in Apple’s Screenshot settings.",
            symbol: "command",
            color: .systemPurple
        )

        var rows: [NSView] = []
        for (index, action) in ShortcutAction.presentationOrder.enumerated() {
            if index > 0 { rows.append(insetSeparator()) }
            rows.append(shortcutRow(for: action))
        }
        let shortcuts = verticalStack(rows, spacing: 0)

        let appleSettings = NSButton(title: "Apple Screenshot Settings…", target: self, action: #selector(openKeyboardSettings))
        appleSettings.bezelStyle = .rounded
        appleSettings.toolTip = "In Keyboard Shortcuts, select Screenshots and turn off the shortcuts assigned to OpenSnapX"
        appleSettings.setAccessibilityHelp(appleSettings.toolTip)

        let reset = NSButton(title: "Restore Shortcut Defaults", target: self, action: #selector(resetShortcuts))
        reset.bezelStyle = .rounded

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = horizontalStack([buttonSpacer, reset, appleSettings], spacing: 8)

        return verticalStack([heading, shortcuts, buttons], spacing: 10)
    }

    private func makeFooter() -> NSView {
        let rerun = NSButton(title: "Run Onboarding Again…", target: self, action: #selector(rerunOnboarding))
        rerun.bezelStyle = .rounded
        rerun.toolTip = "Review screen access and keyboard shortcut setup"
        rerun.setAccessibilityHelp(rerun.toolTip)

        let note = NSTextField(labelWithString: "Screen access and shortcut setup")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return horizontalStack([rerun, note, spacer], spacing: 10)
    }

    private func preferenceRow(_ title: String, detail: String, control: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let labels = verticalStack([titleLabel, detailLabel], spacing: 2)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = horizontalStack([labels, control], spacing: 16)
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 6, left: 34, bottom: 6, right: 0)
        row.heightAnchor.constraint(equalToConstant: 48).isActive = true
        return row
    }

    private func shortcutRow(for action: ShortcutAction) -> NSView {
        let icon = symbolView(action.symbolName, size: 14, color: .secondaryLabelColor)

        let title = NSTextField(labelWithString: action.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: action.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let labels = verticalStack([title, detail], spacing: 2)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

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
        status.widthAnchor.constraint(equalToConstant: 88).isActive = true
        shortcutStatusLabels[action] = status

        let row = horizontalStack([icon, labels, recorder, status], spacing: 10)
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 0)
        row.heightAnchor.constraint(equalToConstant: 47).isActive = true
        return row
    }

    private func sectionHeading(_ title: String, detail: String, symbol: String, color: NSColor) -> NSView {
        let icon = symbolView(symbol, size: 17, color: color)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        let labels = verticalStack([titleLabel, detailLabel], spacing: 3)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let heading = horizontalStack([icon, labels], spacing: 10)
        heading.alignment = .top
        labels.trailingAnchor.constraint(equalTo: heading.trailingAnchor).isActive = true
        return heading
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

    @objc private func preferencesChanged() {
        settings.historyRetentionDays = [1, 7, 30, 0][retention.indexOfSelectedItem]
        settings.includeCursor = cursor.state == .on
        settings.captureSoundEnabled = captureSound.state == .on
    }

    @objc private func launchAtLoginChanged() {
        let shouldLaunch = launch.state == .on
        do {
            if shouldLaunch { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            settings.launchAtLogin = shouldLaunch
        } catch {
            launch.state = settings.launchAtLogin ? .on : .off
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    @objc private func openKeyboardSettings() {
        permissionService.openKeyboardShortcutSettings()
    }

    @objc private func resetShortcuts() {
        for action in ShortcutAction.allCases {
            settings.setShortcut(action.defaultShortcut, for: action)
            shortcutRecorders[action]?.shortcut = action.defaultShortcut
        }
        refreshShortcutStatuses(registerShortcuts())
    }

    @objc private func rerunOnboarding() {
        window?.orderOut(nil)
        showOnboarding()
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
}
