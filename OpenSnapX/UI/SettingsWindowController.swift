import AppKit
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settings: SettingsStore
    private let registerShortcuts: () -> [ShortcutRegistrationResult]
    private let showOnboarding: () -> Void
    private let setMCPEnabled: (Bool) -> Void
    private let installAgentSkill: () -> Void
    private let copyMCPConfiguration: () -> Void
    private let permissionService = ScreenPermissionService()

    private let retention = NSPopUpButton()
    private let cursor = NSButton(checkboxWithTitle: "Include the pointer in captures", target: nil, action: nil)
    private let captureSound = NSButton(checkboxWithTitle: "Play a sound after capture", target: nil, action: nil)
    private let launch = NSButton(checkboxWithTitle: "Launch OpenSnapX at login", target: nil, action: nil)
    private let mcpEnabled = NSButton(checkboxWithTitle: "Enable local MCP for AI agents", target: nil, action: nil)
    private let mcpStatus = NSTextField(labelWithString: "Off")
    private var shortcutRecorders: [ShortcutAction: ShortcutRecorderControl] = [:]
    private var shortcutStatusLabels: [ShortcutAction: NSTextField] = [:]

    init(
        settings: SettingsStore,
        registerShortcuts: @escaping () -> [ShortcutRegistrationResult],
        showOnboarding: @escaping () -> Void,
        setMCPEnabled: @escaping (Bool) -> Void,
        installAgentSkill: @escaping () -> Void,
        copyMCPConfiguration: @escaping () -> Void
    ) {
        self.settings = settings
        self.registerShortcuts = registerShortcuts
        self.showOnboarding = showOnboarding
        self.setMCPEnabled = setMCPEnabled
        self.installAgentSkill = installAgentSkill
        self.copyMCPConfiguration = copyMCPConfiguration

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenSnapX Settings"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 720, height: 740)
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

        let captureSection = makeCaptureSection()
        let mcpSection = makeMCPSection()
        let shortcutSection = makeShortcutSection()
        let footer = makeFooter()

        for view in [header, captureSection, mcpSection, shortcutSection, footer] {
            view.setContentHuggingPriority(.required, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        let root = verticalStack([
            header,
            separator(),
            captureSection,
            separator(),
            mcpSection,
            separator(),
            shortcutSection,
            separator(),
            footer
        ], spacing: 14)
        let documentView = SettingsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        content.addSubview(scrollView)

        root.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(root)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            root.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 36),
            root.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -36),
            root.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 40),
            root.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24)
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
        mcpEnabled.state = settings.mcpEnabled ? .on : .off

        for control in [retention, cursor, captureSound] {
            control.target = self
            control.action = #selector(preferencesChanged)
        }
        launch.target = self
        launch.action = #selector(launchAtLoginChanged)
        mcpEnabled.target = self
        mcpEnabled.action = #selector(mcpEnabledChanged)

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
            preferenceRow("History retention", detail: "How long editable captures are kept", control: retention)
        ], spacing: 0)

        cursor.font = .systemFont(ofSize: 13)
        captureSound.font = .systemFont(ofSize: 13)
        launch.font = .systemFont(ofSize: 13)
        cursor.widthAnchor.constraint(equalToConstant: 210).isActive = true
        let checkSpacer = NSView()
        checkSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let captureChecks = horizontalStack([cursor, captureSound, checkSpacer], spacing: 24)
        captureChecks.edgeInsets = NSEdgeInsets(top: 4, left: 34, bottom: 0, right: 0)

        let launchSpacer = NSView()
        launchSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let launchRow = horizontalStack([launch, launchSpacer], spacing: 0)
        launchRow.edgeInsets = NSEdgeInsets(top: 0, left: 34, bottom: 0, right: 0)
        let checks = verticalStack([captureChecks, launchRow], spacing: 8)

        return verticalStack([heading, options, checks], spacing: 10)
    }

    private func makeMCPSection() -> NSView {
        let heading = sectionHeading(
            "AI Agents",
            detail: "Optional local MCP access for window OCR by clients running as your macOS user, without per-request confirmation. Captures are not added to history.",
            symbol: "network",
            color: .systemGreen
        )

        mcpEnabled.font = .systemFont(ofSize: 13)
        mcpEnabled.toolTip = "Allow local MCP clients running as your macOS user to list and capture non-focused windows"
        mcpEnabled.setAccessibilityHelp(mcpEnabled.toolTip)
        mcpStatus.font = .systemFont(ofSize: 11, weight: .medium)
        mcpStatus.alignment = .right
        mcpStatus.lineBreakMode = .byTruncatingMiddle
        mcpStatus.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = horizontalStack([mcpEnabled, statusSpacer, mcpStatus], spacing: 10)
        statusRow.edgeInsets = NSEdgeInsets(top: 4, left: 34, bottom: 0, right: 0)

        let install = NSButton(title: "Install Agent Skill…", target: self, action: #selector(installSkill))
        install.bezelStyle = .rounded
        install.toolTip = "Install globally by default, or choose a project-specific .agents/skills folder"
        install.setAccessibilityHelp(install.toolTip)
        let copy = NSButton(title: "Copy Global Config", target: self, action: #selector(copyConfiguration))
        copy.bezelStyle = .rounded
        copy.toolTip = "Copy a client configuration for the default global skill location"
        copy.setAccessibilityHelp(copy.toolTip)
        let privacy = NSButton(title: "Screen Recording Settings…", target: self, action: #selector(openScreenRecordingSettings))
        privacy.bezelStyle = .rounded
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = horizontalStack([buttonSpacer, privacy, copy, install], spacing: 8)

        return verticalStack([heading, statusRow, buttons], spacing: 8)
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
        rerun.toolTip = "Review screen access, local MCP, and keyboard shortcut setup"
        rerun.setAccessibilityHelp(rerun.toolTip)

        let note = NSTextField(labelWithString: "Screen access, local MCP, and shortcut setup")
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
        labels.widthAnchor.constraint(equalToConstant: 218).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = horizontalStack([labels, control, spacer], spacing: 16)
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
        let row = horizontalStack([icon, labels, recorder, status, spacer], spacing: 10)
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
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

    @objc private func mcpEnabledChanged() {
        setMCPEnabled(mcpEnabled.state == .on)
    }

    @objc private func installSkill() {
        installAgentSkill()
    }

    @objc private func copyConfiguration() {
        copyMCPConfiguration()
    }

    @objc private func openScreenRecordingSettings() {
        permissionService.openSystemSettings()
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

    func updateMCPStatus(_ status: String) {
        mcpEnabled.state = settings.mcpEnabled ? .on : .off
        mcpStatus.stringValue = "●  \(status)"
        if status == "Ready" || status.contains("Connected") || status == "Agent Request Active…" {
            mcpStatus.textColor = .systemGreen
        } else if status == "Off" {
            mcpStatus.textColor = .secondaryLabelColor
        } else {
            mcpStatus.textColor = .systemOrange
        }
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

@MainActor
private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
