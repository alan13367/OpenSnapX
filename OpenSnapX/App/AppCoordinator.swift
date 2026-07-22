import AppKit
import Carbon
import CoreGraphics
import OSLog

@MainActor
final class AppCoordinator: NSObject {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenSnapX", category: "App")
    private let settings = SettingsStore.shared
    private let permissionService = ScreenPermissionService()
    private let captureService = ScreenCaptureService()
    private let historyStore: any HistoryStore = LocalHistoryStore()
    private let renderer: any ImageRenderer = CoreGraphicsImageRenderer()
    private let ocrService: any OCRService = VisionOCRService()
    private let scrollingEngine: any ScrollingCaptureEngine = AccelerateScrollingCaptureEngine()
    private let exportService = ExportService()
    private let captureSoundPlayer: any CaptureSoundPlaying = SystemCaptureSoundPlayer()
    private let shortcutManager: any ShortcutManager = CarbonShortcutManager()
    private let overlayController = CaptureOverlayController()
    private let pinnedController = PinnedImageController()
    private let agentSkillInstaller: any AgentSkillInstalling = LocalAgentSkillInstaller()
    private lazy var mcpServer: any MCPServer = UnixSocketMCPServer(
        toolHandler: MCPToolService(windowService: captureService, ocrService: ocrService)
    )

    private var statusItem: NSStatusItem!
    private var onboardingController: OnboardingWindowController?
    private var settingsController: SettingsWindowController?
    private var historyController: HistoryWindowController?
    private var editorControllers: [UUID: EditorWindowController] = [:]
    private var latestEditorID: UUID?
    private var textReviewControllers: [UUID: TextReviewWindowController] = [:]
    private var scrollingController: ScrollingCaptureController?
    private var shortcutConflicts: [ShortcutAction] = []
    private var colorNoticePanel: NSPanel?
    private var colorNoticeTask: Task<Void, Never>?
    private var historyCleanupTask: Task<Void, Never>?

    private static let historyCleanupInterval: Duration = .seconds(15 * 60)

    func start() {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        mcpServer.onStatusChange = { [weak self] status in
            self?.mcpStatusDidChange(status)
        }
        if settings.mcpEnabled { mcpServer.start() }
        shortcutManager.onAction = { [weak self] action in self?.handleShortcut(action) }
        _ = registerConfiguredShortcuts()
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: nil)
        startHistoryCleanupSchedule()
        if !settings.completedOnboarding { showOnboarding() }
    }

    func stop() {
        historyCleanupTask?.cancel()
        historyCleanupTask = nil
        mcpServer.stop()
        shortcutManager.unregisterAll()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "OpenSnapX")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "OpenSnapX"
        statusItem.menu = NSMenu(title: "OpenSnapX")
        rebuildMenuSynchronously(recent: [])
    }

    private func rebuildMenu() async {
        let recent = Array(await historyStore.list().prefix(5))
        rebuildMenuSynchronously(recent: recent)
    }

    private func rebuildMenuSynchronously(recent: [CaptureSession]) {
        let menu = NSMenu(title: "OpenSnapX")
        menu.addItem(captureItem("Capture Area", #selector(captureRegion), shortcut: .captureRegion))
        menu.addItem(item("Capture Window", #selector(captureWindow)))
        menu.addItem(captureItem("Capture Display", #selector(captureDisplay), shortcut: .captureDisplay))
        menu.addItem(captureItem("Scrolling Capture", #selector(captureScrolling), shortcut: .captureScrolling))
        menu.addItem(captureItem("Capture Text", #selector(captureText), shortcut: .captureText))
        menu.addItem(.separator())
        menu.addItem(captureItem("Color Picker", #selector(pickColor), shortcut: .colorPicker))
        if settings.mcpEnabled {
            menu.addItem(.separator())
            let mcpItem = item(mcpMenuTitle, #selector(showSettings))
            mcpItem.tag = 9_001
            mcpItem.image = NSImage(
                systemSymbolName: mcpServer.status.activeRequests > 0 ? "sparkles.rectangle.stack.fill" : "network",
                accessibilityDescription: "Local MCP status"
            )
            menu.addItem(mcpItem)
        }
        if !shortcutConflicts.isEmpty {
            let warning = NSMenuItem(title: "⚠ Keyboard shortcut conflict", action: #selector(showOnboarding), keyEquivalent: "")
            warning.target = self
            menu.addItem(.separator())
            menu.addItem(warning)
        }
        menu.addItem(.separator())
        if !recent.isEmpty {
            let heading = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            let formatter = RelativeDateTimeFormatter()
            for session in recent {
                let title = "\(session.manifest.captureMode.displayName) • \(formatter.localizedString(for: session.manifest.createdAt, relativeTo: Date()))"
                let recentItem = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
                recentItem.target = self
                recentItem.representedObject = session.id.uuidString
                menu.addItem(recentItem)
            }
        }
        menu.addItem(item("History…", #selector(showHistory), key: "h"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("About OpenSnapX", #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit OpenSnapX", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        if ["2", "3", "4", "5"].contains(key) { item.keyEquivalentModifierMask = [.command, .shift] }
        return item
    }

    private var mcpPresentationStatus: String {
        guard settings.mcpEnabled else { return "Off" }
        switch mcpServer.status.phase {
        case .stopped, .starting:
            return "Starting…"
        case let .failed(message):
            return "Error — \(message)"
        case .listening:
            if !permissionService.isAuthorized { return "Screen Access Needed" }
            if mcpServer.status.activeRequests > 0 { return "Agent Request Active…" }
            if mcpServer.status.connectedClients == 1 { return "1 Agent Connected" }
            if mcpServer.status.connectedClients > 1 {
                return "\(mcpServer.status.connectedClients) Agents Connected"
            }
            return "Ready"
        }
    }

    private var mcpMenuTitle: String { "Local MCP: \(mcpPresentationStatus)" }

    private func captureItem(_ title: String, _ selector: Selector, shortcut action: ShortcutAction) -> NSMenuItem {
        let definition = settings.shortcut(for: action)
        let key = definition.keyLabel.count == 1 ? definition.keyLabel.lowercased() : ""
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        var modifiers: NSEvent.ModifierFlags = []
        if definition.modifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        if definition.modifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if definition.modifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if definition.modifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @discardableResult
    private func registerConfiguredShortcuts() -> [ShortcutRegistrationResult] {
        let results = shortcutManager.register(settings.shortcutDefinitions)
        shortcutConflicts = results.filter { !$0.succeeded }.map(\.action)
        if statusItem != nil { Task { await rebuildMenu() } }
        return results
    }

    private func handleShortcut(_ action: ShortcutAction) {
        switch action {
        case .captureText: performCapture(mode: .text)
        case .captureDisplay: performCapture(mode: .display)
        case .captureRegion: performCapture(mode: .region)
        case .captureScrolling: performCapture(mode: .scrolling)
        case .colorPicker: pickColor()
        }
    }

    @objc private func captureRegion() { performCapture(mode: .region) }
    @objc private func captureWindow() { performCapture(mode: .window) }
    @objc private func captureDisplay() { performCapture(mode: .display) }
    @objc private func captureScrolling() { performCapture(mode: .scrolling) }
    @objc private func captureText() { performCapture(mode: .text) }

    @objc private func pickColor() {
        NSColorSampler().show { [weak self] color in
            Task { @MainActor [weak self] in
                guard let self, let color, let hex = self.hexString(for: color) else { return }
                self.exportService.copyText(hex)
                self.showColorNotice(color: color, hex: hex)
            }
        }
    }

    private func performCapture(mode: CaptureMode) {
        guard permissionService.isAuthorized else {
            showOnboarding()
            return
        }
        logger.info("Starting \(mode.rawValue, privacy: .public) capture")
        Task {
            do {
                let result: CaptureResult
                if mode == .display {
                    let screen = DisplayGeometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
                    let displayID = screen.flatMap(DisplayGeometry.displayID(for:))
                    result = try await captureService.capture(CaptureRequest(mode: .display, includeCursor: settings.includeCursor, displayID: displayID))
                } else {
                    let candidates = mode == .window || mode == .region
                        ? try await captureService.availableWindows()
                        : []
                    let selection = try await overlayController.select(
                        mode: mode,
                        candidates: candidates
                    )
                    let request = CaptureRequest(
                        mode: selection.mode == .window ? .window : mode,
                        includeCursor: settings.includeCursor,
                        displayID: selection.displayID,
                        selection: selection.pixelRect,
                        screenSelection: selection.mode == .window || mode == .scrolling
                            ? nil
                            : selection.screenRect,
                        windowID: selection.windowID
                    )
                    if mode == .scrolling {
                        let controller = ScrollingCaptureController(captureService: captureService, engine: scrollingEngine)
                        scrollingController = controller
                        do {
                            let stitched = try await controller.start(request: request)
                            scrollingController = nil
                            let displayScale = NSScreen.screens.first {
                                DisplayGeometry.displayID(for: $0) == selection.displayID
                            }?.backingScaleFactor ?? 1
                            result = CaptureResult(
                                image: stitched.image,
                                mode: .scrolling,
                                displayScale: displayScale,
                                sourceRect: selection.pixelRect
                            )
                        } catch {
                            scrollingController = nil
                            throw error
                        }
                    } else {
                        result = try await captureService.capture(request)
                    }
                }
                playCaptureSoundIfNeeded(for: result.mode)
                try await completeCapture(result)
            } catch OpenSnapXError.selectionCancelled {
                logger.debug("Capture cancelled")
            } catch {
                present(error)
            }
        }
    }

    private func playCaptureSoundIfNeeded(for mode: CaptureMode) {
        guard settings.captureSoundEnabled else { return }
        switch mode {
        case .region, .window, .display:
            captureSoundPlayer.playCaptureSound()
        case .scrolling, .text:
            break
        }
    }

    private func completeCapture(_ result: CaptureResult) async throws {
        if result.mode == .text {
            try await completeTextCapture(result)
            return
        }

        let action = settings.postCaptureAction(for: result.mode)
        let initialPersistence = Task(priority: .utility) {
            _ = try await historyStore.create(from: result)
        }
        observeHistoryPersistence(initialPersistence)

        switch action {
        case .openEditor:
            openEditor(
                session: CaptureSession(captureResult: result),
                image: result.image,
                initialPersistence: initialPersistence
            )
        case .copyToClipboard:
            await exportService.copy(result.image, displayScale: result.displayScale)
            showNotice("Image copied")
        case .keepInHistoryOnly:
            break
        case .copyRecognizedText, .reviewBeforeCopy:
            assertionFailure("Text-only post-capture action used for an image capture")
        }
    }

    private func completeTextCapture(_ result: CaptureResult) async throws {
        let results = try await ocrService.recognize(ImagePayload(image: result.image))
        let text = results.map(\.text).joined(separator: "\n")

        switch settings.postCaptureAction(for: .text) {
        case .copyRecognizedText:
            if text.isEmpty {
                showNotice("No text recognized")
            } else {
                exportService.copyText(text)
                showNotice("Text copied")
            }
        case .reviewBeforeCopy:
            showTextReview(text)
        case .openEditor, .copyToClipboard, .keepInHistoryOnly:
            assertionFailure("Image post-capture action used for Capture Text")
        }
    }

    private func observeHistoryPersistence(_ persistence: Task<Void, Error>) {
        Task {
            do {
                try await persistence.value
                await rebuildMenu()
            } catch {
                present(error)
            }
        }
    }

    private func showTextReview(_ text: String) {
        let id = UUID()
        let controller = TextReviewWindowController(
            text: text,
            onCopy: { [weak self] text in
                self?.exportService.copyText(text)
                self?.showNotice("Text copied")
            },
            onClose: { [weak self] in
                self?.textReviewControllers.removeValue(forKey: id)
            }
        )
        textReviewControllers[id] = controller
        controller.show()
    }

    private func openEditor(id: UUID) {
        latestEditorID = id
        if let editor = editorControllers[id] {
            editor.show()
            return
        }
        Task {
            do {
                let (session, payload) = try await historyStore.load(id: id)
                openEditor(session: session, image: payload.image)
            } catch { present(error) }
        }
    }

    private func openEditor(
        session: CaptureSession,
        image: CGImage,
        initialPersistence: Task<Void, Error>? = nil
    ) {
        let id = session.id
        latestEditorID = id
        if let editor = editorControllers[id] {
            editor.show()
            return
        }
        let editor = EditorWindowController(
            session: session,
            image: image,
            historyStore: historyStore,
            renderer: renderer,
            ocrService: ocrService,
            exportService: exportService,
            initialPersistence: initialPersistence,
            onSessionSaved: { [weak self] id in
                self?.historySessionDidChange(id: id)
            },
            onDiscardCapture: { [weak self] id in
                guard let self else { return }
                try await self.discardCaptureFromEditor(id: id)
            }
        )
        editorControllers[id] = editor
        editor.show()
    }

    func reopenLastEditor() {
        guard let latestEditorID else { return }
        openEditor(id: latestEditorID)
    }

    @objc private func showHistory() {
        let controller = historyController ?? HistoryWindowController()
        controller.onOpen = { [weak self] id in self?.openEditor(id: id) }
        controller.onCopy = { [weak self] id in
            self?.withHistoryImage(id: id) { image, displayScale in
                await self?.exportService.copy(image, displayScale: displayScale)
            }
        }
        controller.onPin = { [weak self] id in
            self?.withHistoryImage(id: id) { image, _ in self?.pinnedController.pin(image) }
        }
        controller.onDelete = { [weak self] ids in self?.deleteHistory(ids: ids) }
        historyController = controller
        Task { await refreshHistoryWindow(controller); controller.show() }
    }

    @objc private func showSettings() {
        let controller = settingsController ?? SettingsWindowController(
            settings: settings,
            registerShortcuts: { [weak self] in self?.registerConfiguredShortcuts() ?? [] },
            showOnboarding: { [weak self] in self?.showOnboarding() },
            historyRetentionChanged: { [weak self] _ in self?.startHistoryCleanupSchedule() },
            setMCPEnabled: { [weak self] enabled in self?.setMCPEnabled(enabled) },
            installAgentSkill: { [weak self] in self?.installAgentSkill() },
            copyMCPConfiguration: { [weak self] in self?.copyMCPConfiguration() }
        )
        settingsController = controller
        controller.updateMCPStatus(mcpPresentationStatus)
        controller.show()
    }

    private func startHistoryCleanupSchedule() {
        historyCleanupTask?.cancel()
        historyCleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.performHistoryCleanup()
                do {
                    try await Task.sleep(for: Self.historyCleanupInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func performHistoryCleanup() async {
        await historyStore.cleanup(retentionDays: settings.historyRetentionDays)
        guard !Task.isCancelled else { return }
        if let historyController, historyController.window?.isVisible == true {
            await refreshHistoryWindow(historyController)
        }
        await rebuildMenu()
    }

    @objc private func showOnboarding() {
        let controller = onboardingController ?? OnboardingWindowController(
            permissionService: permissionService,
            settings: settings,
            registerShortcuts: { [weak self] in self?.registerConfiguredShortcuts() ?? [] },
            setMCPEnabled: { [weak self] enabled in self?.setMCPEnabled(enabled) },
            installAgentSkill: { [weak self] in self?.installAgentSkill() },
            onFinish: { [weak self] in
                guard let self else { return }
                self.settings.completedOnboarding = true
                _ = self.registerConfiguredShortcuts()
                Task { await self.rebuildMenu() }
            }
        )
        onboardingController = controller
        controller.show()
    }

    private func setMCPEnabled(_ enabled: Bool) {
        settings.mcpEnabled = enabled
        if enabled { mcpServer.start() }
        else { mcpServer.stop() }
        settingsController?.updateMCPStatus(mcpPresentationStatus)
        onboardingController?.updateMCPEnabled(enabled)
        Task { await rebuildMenu() }
    }

    private func mcpStatusDidChange(_: MCPServerStatus) {
        settingsController?.updateMCPStatus(mcpPresentationStatus)
        guard let mcpItem = statusItem.menu?.item(withTag: 9_001) else { return }
        mcpItem.title = mcpMenuTitle
        mcpItem.image = NSImage(
            systemSymbolName: mcpServer.status.activeRequests > 0 ? "sparkles.rectangle.stack.fill" : "network",
            accessibilityDescription: "Local MCP status"
        )
    }

    private func installAgentSkill() {
        let choice = NSAlert()
        choice.messageText = "Install the OpenSnapX OCR agent skill"
        choice.informativeText = "Install globally for all projects, or choose a specific project. OpenSnapX will ask you to select the destination before writing files."
        choice.addButton(withTitle: "Install Globally")
        choice.addButton(withTitle: "Install in Project")
        choice.addButton(withTitle: "Cancel")

        let scope: AgentSkillInstallScope
        switch choice.runModal() {
        case .alertFirstButtonReturn: scope = .global
        case .alertSecondButtonReturn: scope = .project
        default: return
        }

        do {
            guard let destination = try agentSkillInstaller.install(
                scope: scope,
                presentingWindow: settingsController?.window ?? onboardingController?.window
            ) else { return }
            copyToPasteboard(LocalAgentSkillInstaller.mcpConfiguration(for: destination))
            let confirmation = NSAlert()
            confirmation.messageText = "Agent skill installed"
            confirmation.informativeText = "Installed at \(destination.path). An MCP client configuration using its connector has been copied to the clipboard."
            confirmation.runModal()
        } catch {
            present(error)
        }
    }

    private func copyMCPConfiguration() {
        let destination = LocalAgentSkillInstaller.globalSkillsDirectory
            .appendingPathComponent("opensnapx-ocr", isDirectory: true)
        copyToPasteboard(LocalAgentSkillInstaller.mcpConfiguration(for: destination))
        showNotice("MCP configuration copied")
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "OpenSnapX",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            .credits: NSAttributedString(string: "Native, private, and open source. Licensed under GPLv3.")
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        openEditor(id: id)
    }

    private func withHistoryImage(
        id: UUID,
        action: @escaping (CGImage, Double) async -> Void
    ) {
        Task {
            do {
                let (session, payload) = try await historyStore.load(id: id)
                let renderer = self.renderer
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try renderer.render(source: payload, session: session, options: ExportOptions()).image
                }.value
                await action(rendered, session.manifest.displayScale)
            } catch { present(error) }
        }
    }

    private func deleteHistory(ids: [UUID]) {
        Task {
            for id in ids {
                try? await historyStore.delete(id: id)
            }
            if let historyController { await refreshHistoryWindow(historyController) }
            await rebuildMenu()
        }
    }

    private func discardCaptureFromEditor(id: UUID) async throws {
        try await historyStore.delete(id: id)
        editorControllers.removeValue(forKey: id)
        if latestEditorID == id { latestEditorID = nil }
        if let historyController { await refreshHistoryWindow(historyController) }
        await rebuildMenu()
    }

    private func refreshHistoryWindow(_ controller: HistoryWindowController) async {
        let sessions = await historyStore.list()
        var thumbnails: [UUID: CGImage] = [:]
        for session in sessions {
            if let payload = try? await historyStore.thumbnail(id: session.id) {
                thumbnails[session.id] = payload.image
            }
        }
        controller.update(sessions, thumbnails: thumbnails)
    }

    private func historySessionDidChange(id: UUID) {
        guard let controller = historyController, controller.window?.isVisible == true else { return }
        Task {
            guard let session = await historyStore.list().first(where: { $0.id == id }),
                  let thumbnail = try? await historyStore.thumbnail(id: id) else { return }
            controller.update(session: session, thumbnail: thumbnail.image)
        }
    }

    private func showColorNotice(color: NSColor, hex: String) {
        colorNoticeTask?.cancel()
        colorNoticePanel?.close()

        let panelSize = CGSize(width: 274, height: 72)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: panelSize))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        let swatch = NSView()
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = color.cgColor
        swatch.layer?.cornerRadius = 10
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        swatch.setAccessibilityElement(true)
        swatch.setAccessibilityLabel("Selected color \(hex)")

        let title = NSTextField(labelWithString: "Color copied")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let value = NSTextField(labelWithString: hex)
        value.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        value.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, value])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        check.contentTintColor = .systemGreen
        check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)

        let content = NSStackView(views: [swatch, labels, check])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 44),
            swatch.heightAnchor.constraint(equalToConstant: 44),
            check.widthAnchor.constraint(equalToConstant: 22),
            check.heightAnchor.constraint(equalToConstant: 22)
        ])

        panel.contentView = effect
        let screen = DisplayGeometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.maxY - panelSize.height - 56
            ))
        } else {
            panel.center()
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        colorNoticePanel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        colorNoticeTask = Task { [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in panel.close() }
            })
            self.colorNoticePanel = nil
            self.colorNoticeTask = nil
        }
    }

    private func hexString(for color: NSColor) -> String? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((min(max(color.redComponent, 0), 1) * 255).rounded()),
            Int((min(max(color.greenComponent, 0), 1) * 255).rounded()),
            Int((min(max(color.blueComponent, 0), 1) * 255).rounded())
        )
    }

    private func showNotice(_ text: String) {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 220, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let effect = NSVisualEffectView()
        effect.material = .hudWindow; effect.state = .active; effect.wantsLayer = true; effect.layer?.cornerRadius = 12
        let label = NSTextField(labelWithString: text); label.alignment = .center; label.font = .systemFont(ofSize: 14, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: effect.leadingAnchor), label.trailingAnchor.constraint(equalTo: effect.trailingAnchor), label.centerYAnchor.constraint(equalTo: effect.centerYAnchor)])
        panel.contentView = effect; panel.center(); panel.orderFrontRegardless()
        Task { try? await Task.sleep(for: .seconds(1.4)); panel.orderOut(nil); panel.close() }
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    @objc private func windowClosed(_ notification: Notification) {
        if let closedWindow = notification.object as? NSWindow,
           let closedEditorID = editorControllers.first(where: { $0.value.window === closedWindow })?.key {
            editorControllers.removeValue(forKey: closedEditorID)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            let hasRegularWindow = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel && $0.styleMask.contains(.nonactivatingPanel)) }
            if !hasRegularWindow, latestEditorID == nil { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
