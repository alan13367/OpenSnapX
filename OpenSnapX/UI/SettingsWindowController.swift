import AppKit
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settings: SettingsStore
    private let registerShortcuts: () -> [ShortcutRegistrationResult]
    private let permissionService = ScreenPermissionService()

    private let preview = NSPopUpButton()
    private let retention = NSPopUpButton()
    private let postCapture = NSPopUpButton()
    private let cursor = NSButton(checkboxWithTitle: "Include the pointer in captures", target: nil, action: nil)
    private let launch = NSButton(checkboxWithTitle: "Launch OpenSnapX at login", target: nil, action: nil)
    private var shortcutRecorders: [ShortcutAction: ShortcutRecorderControl] = [:]
    private var shortcutStatusLabels: [ShortcutAction: NSTextField] = [:]

    init(settings: SettingsStore, registerShortcuts: @escaping () -> [ShortcutRegistrationResult]) {
        self.settings = settings
        self.registerShortcuts = registerShortcuts
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 650, height: 720),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenSnapX Settings"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 620, height: 680)
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
        refreshShortcutStatuses(registerShortcuts())
    }

    private func configure() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Tune the capture workflow to fit how you work.")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4

        let stack = NSStackView(views: [header, makeGeneralCard(), makeShortcutCard()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 42),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26)
        ])
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    private func makeGeneralCard() -> NSView {
        preview.addItems(withTitles: ["3 seconds", "5 seconds", "8 seconds", "Never dismiss"])
        preview.selectItem(at: [3.0, 5.0, 8.0, 0.0].firstIndex(of: settings.previewDuration) ?? 2)
        retention.addItems(withTitles: ["1 day", "7 days", "30 days", "Forever"])
        retention.selectItem(at: [1, 7, 30, 0].firstIndex(of: settings.historyRetentionDays) ?? 1)
        postCapture.addItems(withTitles: ["Floating preview", "Copy", "Save", "Copy and preview"])
        postCapture.selectItem(at: PostCaptureAction.allCases.firstIndex(of: settings.postCaptureAction) ?? 0)
        cursor.state = settings.includeCursor ? .on : .off
        launch.state = settings.launchAtLogin ? .on : .off

        for control in [preview, retention, postCapture, cursor] {
            control.target = self
            control.action = #selector(preferencesChanged)
        }
        launch.target = self
        launch.action = #selector(launchAtLoginChanged)

        let card = SettingsCardView()
        let heading = sectionHeading("Capture workflow", symbol: "camera.viewfinder")
        let rows = [
            settingRow("Floating preview", control: preview),
            settingRow("History retention", control: retention),
            settingRow("After capture", control: postCapture)
        ]
        let checks = NSStackView(views: [cursor, launch])
        checks.orientation = .vertical
        checks.alignment = .leading
        checks.spacing = 9

        install([heading] + rows + [checks], in: card, spacing: 11)
        card.heightAnchor.constraint(equalToConstant: 245).isActive = true
        return card
    }

    private func makeShortcutCard() -> NSView {
        let card = SettingsCardView()

        let title = NSTextField(labelWithString: "Keyboard shortcuts")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "Click a shortcut to record a new combination. OpenSnapX takes priority while it is running and releases the shortcut when it quits.")
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        let headingText = NSStackView(views: [title, detail])
        headingText.orientation = .vertical
        headingText.alignment = .leading
        headingText.spacing = 3
        let icon = symbolView("command")
        let heading = NSStackView(views: [icon, headingText])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 10

        var views: [NSView] = [heading]
        for action in ShortcutAction.presentationOrder { views.append(shortcutRow(for: action)) }

        let systemSettings = NSButton(title: "Apple Screenshot Shortcuts…", target: self, action: #selector(openKeyboardSettings))
        systemSettings.bezelStyle = .inline
        systemSettings.contentTintColor = .controlAccentColor
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(resetShortcuts))
        reset.bezelStyle = .inline
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [systemSettings, spacer, reset])
        footer.orientation = .horizontal
        views.append(footer)

        install(views, in: card, spacing: 10)
        card.heightAnchor.constraint(equalToConstant: 350).isActive = true
        return card
    }

    private func shortcutRow(for action: ShortcutAction) -> NSView {
        let title = NSTextField(labelWithString: action.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

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
        status.widthAnchor.constraint(equalToConstant: 72).isActive = true
        shortcutStatusLabels[action] = status

        let row = NSStackView(views: [symbolView(action.symbolName, size: 14), title, recorder, status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.heightAnchor.constraint(equalToConstant: 38).isActive = true
        return row
    }

    private func sectionHeading(_ title: String, symbol: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        let stack = NSStackView(views: [symbolView(symbol), label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func symbolView(_ name: String, size: CGFloat = 18) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        view.contentTintColor = .controlAccentColor
        view.widthAnchor.constraint(equalToConstant: 25).isActive = true
        return view
    }

    private func settingRow(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.widthAnchor.constraint(equalToConstant: 225).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
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

    @objc private func preferencesChanged() {
        settings.previewDuration = [3.0, 5.0, 8.0, 0.0][preview.indexOfSelectedItem]
        settings.historyRetentionDays = [1, 7, 30, 0][retention.indexOfSelectedItem]
        settings.postCaptureAction = PostCaptureAction.allCases[postCapture.indexOfSelectedItem]
        settings.includeCursor = cursor.state == .on
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

    @objc private func openKeyboardSettings() { permissionService.openKeyboardShortcutSettings() }

    @objc private func resetShortcuts() {
        for action in ShortcutAction.allCases {
            settings.setShortcut(action.defaultShortcut, for: action)
            shortcutRecorders[action]?.shortcut = action.defaultShortcut
        }
        refreshShortcutStatuses(registerShortcuts())
    }

    private func refreshShortcutStatuses(_ results: [ShortcutRegistrationResult]) {
        for result in results {
            guard let label = shortcutStatusLabels[result.action] else { continue }
            label.stringValue = result.succeeded ? "● Ready" : "● In use"
            label.textColor = result.succeeded ? .systemGreen : .systemOrange
            label.toolTip = result.succeeded ? "Shortcut registered exclusively while OpenSnapX is running" : "Another app has reserved this combination exclusively (error \(result.status))."
        }
    }
}

private final class SettingsCardView: NSVisualEffectView {
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
