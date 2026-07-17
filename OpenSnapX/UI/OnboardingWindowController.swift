import AppKit
import QuartzCore

@MainActor
final class OnboardingWindowController: NSWindowController {
    private let permissionService: ScreenPermissionService
    private let settings: SettingsStore
    private let registerShortcuts: () -> [ShortcutRegistrationResult]
    private let onFinish: () -> Void

    private let permissionStatus = NSTextField(labelWithString: "")
    private let appleShortcutGuideDetail = NSTextField(wrappingLabelWithString: "")
    private var shortcutStatusLabels: [ShortcutAction: NSTextField] = [:]
    private var shortcutRecorders: [ShortcutAction: ShortcutRecorderControl] = [:]
    private var permissionPollTimer: Timer?
    private var shortcutGuidePanel: NSPanel?

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
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 800),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to OpenSnapX"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 720, height: 780)
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
        let detail = NSTextField(wrappingLabelWithString: "OpenSnapX uses Apple’s screenshot key combinations by default. Turn off only the matching Apple shortcuts to prevent both capture tools from firing.")
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

        let reset = NSButton(title: "Restore Shortcut Defaults", target: self, action: #selector(resetShortcuts))
        reset.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = horizontalStack([spacer, reset], spacing: 8)

        return verticalStack([heading, shortcuts, makeAppleShortcutGuide(), buttons], spacing: 9)
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
            self.refreshAppleShortcutGuidance()
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

    private func makeAppleShortcutGuide() -> NSView {
        let card = ShortcutSetupCardView()

        let title = NSTextField(labelWithString: "Prevent duplicate captures")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        appleShortcutGuideDetail.font = .systemFont(ofSize: 11)
        appleShortcutGuideDetail.textColor = .secondaryLabelColor
        appleShortcutGuideDetail.maximumNumberOfLines = 2
        let labels = verticalStack([title, appleShortcutGuideDetail], spacing: 2)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let open = NSButton(title: "Open Settings…", target: self, action: #selector(openKeyboardSettings))
        open.bezelStyle = .rounded
        open.toolTip = "Open Keyboard Shortcuts, then select Screenshots in the left sidebar"
        open.setAccessibilityHelp(open.toolTip)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let content = horizontalStack([
            symbolView("camera.viewfinder", size: 17, color: .systemOrange),
            labels,
            spacer,
            animatedGuideArrow(),
            open
        ], spacing: 9)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
        refreshAppleShortcutGuidance()
        return card
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
        showAppleShortcutGuide()
    }

    @objc private func dismissShortcutGuide() {
        shortcutGuidePanel?.orderOut(nil)
        shortcutGuidePanel?.close()
        shortcutGuidePanel = nil
    }

    @objc private func resetShortcuts() {
        for action in ShortcutAction.presentationOrder {
            settings.setShortcut(action.defaultShortcut, for: action)
        }
        rebuildShortcutRecorders()
        refreshShortcutStatuses(registerShortcuts())
        refreshAppleShortcutGuidance()
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

    private func refreshAppleShortcutGuidance() {
        let shortcuts = matchingAppleScreenshotShortcuts
        if shortcuts.isEmpty {
            appleShortcutGuideDetail.stringValue = "Your current shortcuts do not overlap Apple’s screenshot shortcuts."
        } else {
            appleShortcutGuideDetail.stringValue = "Select Screenshots, then uncheck \(formattedShortcutList(shortcuts))."
        }
    }

    private var matchingAppleScreenshotShortcuts: [String] {
        var seen: Set<String> = []
        return ShortcutAction.presentationOrder
            .map { settings.shortcut(for: $0) }
            .filter(\.matchesBuiltInScreenshotShortcut)
            .sorted { $0.keyLabel.localizedStandardCompare($1.keyLabel) == .orderedAscending }
            .map(\.displayString)
            .filter { seen.insert($0).inserted }
    }

    private func formattedShortcutList(_ shortcuts: [String]) -> String {
        switch shortcuts.count {
        case 0: return ""
        case 1: return shortcuts[0]
        case 2: return shortcuts.joined(separator: " and ")
        default: return shortcuts.dropLast().joined(separator: ", ") + ", and " + (shortcuts.last ?? "")
        }
    }

    private func animatedGuideArrow() -> NSImageView {
        let arrow = symbolView("arrow.left", size: 14, color: .systemOrange)
        arrow.setAccessibilityElement(false)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return arrow }
        arrow.wantsLayer = true
        let motion = CABasicAnimation(keyPath: "transform.translation.x")
        motion.fromValue = 3
        motion.toValue = -3
        motion.duration = 0.65
        motion.autoreverses = true
        motion.repeatCount = .infinity
        motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arrow.layer?.add(motion, forKey: "guideMotion")
        return arrow
    }

    private func showAppleShortcutGuide() {
        dismissShortcutGuide()

        let panelSize = NSSize(width: 392, height: 192)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: panelSize))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "Finish in Apple’s Screenshot settings")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss guide") ?? NSImage(),
            target: self,
            action: #selector(dismissShortcutGuide)
        )
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.setAccessibilityLabel("Dismiss shortcut guide")
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = horizontalStack([title, titleSpacer, close], spacing: 8)

        let firstStep = floatingGuideStep(
            number: "1",
            title: "Select Screenshots",
            detail: "in the left sidebar of Keyboard Shortcuts",
            accessory: animatedGuideArrow()
        )
        let shortcuts = matchingAppleScreenshotShortcuts
        let secondDetail = shortcuts.isEmpty
            ? "No matching Apple shortcuts need to be disabled."
            : "Uncheck only the Apple rows showing \(formattedShortcutList(shortcuts))."
        let secondStep = floatingGuideStep(
            number: "2",
            title: "Turn off the matching boxes",
            detail: secondDetail
        )
        let note = NSTextField(wrappingLabelWithString: "Other Apple shortcuts—including ⌃ Control variants—can stay enabled unless you assigned the same combination in OpenSnapX.")
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.maximumNumberOfLines = 2

        let root = verticalStack([header, firstStep, secondStep, note], spacing: 9)
        root.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            root.bottomAnchor.constraint(lessThanOrEqualTo: effect.bottomAnchor, constant: -12)
        ])
        panel.contentView = effect

        let screen = window?.screen ?? DisplayGeometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(
                x: visibleFrame.maxX - panelSize.width - 22,
                y: visibleFrame.maxY - panelSize.height - 22
            ))
        }
        shortcutGuidePanel = panel
        panel.orderFrontRegardless()
    }

    private func floatingGuideStep(number: String, title: String, detail: String, accessory: NSView? = nil) -> NSView {
        let numberLabel = NSTextField(labelWithString: number)
        numberLabel.font = .systemFont(ofSize: 11, weight: .bold)
        numberLabel.alignment = .center
        numberLabel.textColor = .white
        numberLabel.backgroundColor = .systemBlue
        numberLabel.drawsBackground = true
        numberLabel.wantsLayer = true
        numberLabel.layer?.cornerRadius = 10
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            numberLabel.widthAnchor.constraint(equalToConstant: 20),
            numberLabel.heightAnchor.constraint(equalToConstant: 20)
        ])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        let labels = verticalStack([titleLabel, detailLabel], spacing: 1)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = horizontalStack([numberLabel, labels, spacer] + (accessory.map { [$0] } ?? []), spacing: 9)
        row.alignment = .centerY
        return row
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        if shortcutGuidePanel != nil { dismissShortcutGuide() }
    }

    func windowWillClose(_ notification: Notification) {
        stopPermissionPolling()
        dismissShortcutGuide()
    }
}

@MainActor
private final class ShortcutSetupCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.07).cgColor
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.28).cgColor
        layer?.borderWidth = 1
    }
}
