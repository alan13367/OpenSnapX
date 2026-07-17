import AppKit
import Carbon
import CoreGraphics
import OSLog

@MainActor
final class AppCoordinator: NSObject {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenSnapX", category: "App")
    private let settings = SettingsStore.shared
    private let permissionService = ScreenPermissionService()
    private let captureService: any CaptureService = ScreenCaptureService()
    private let historyStore: any HistoryStore = LocalHistoryStore()
    private let renderer: any ImageRenderer = CoreGraphicsImageRenderer()
    private let ocrService: any OCRService = VisionOCRService()
    private let scrollingEngine: any ScrollingCaptureEngine = AccelerateScrollingCaptureEngine()
    private let exportService = ExportService()
    private let captureSoundPlayer: any CaptureSoundPlaying = SystemCaptureSoundPlayer()
    private let shortcutManager: any ShortcutManager = CarbonShortcutManager()
    private let overlayController = CaptureOverlayController()
    private let pinnedController = PinnedImageController()

    private var statusItem: NSStatusItem!
    private var onboardingController: OnboardingWindowController?
    private var settingsController: SettingsWindowController?
    private var historyController: HistoryWindowController?
    private var editorControllers: [UUID: EditorWindowController] = [:]
    private var latestEditorID: UUID?
    private var scrollingController: ScrollingCaptureController?
    private var shortcutConflicts: [ShortcutAction] = []
    private var colorNoticePanel: NSPanel?
    private var colorNoticeTask: Task<Void, Never>?

    func start() {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        shortcutManager.onAction = { [weak self] action in self?.handleShortcut(action) }
        _ = registerConfiguredShortcuts()
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: nil)
        Task {
            await historyStore.cleanup(retentionDays: settings.historyRetentionDays)
            await rebuildMenu()
        }
        if !settings.completedOnboarding { showOnboarding() }
    }

    func stop() {
        shortcutManager.unregisterAll()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "OpenSnapX")
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
                    let candidates = mode == .window ? try await captureService.availableWindows() : []
                    let freezesSelection = mode == .region || mode == .text
                    let frozenDisplays = freezesSelection ? try await captureFrozenDisplays() : [:]
                    let selection = try await overlayController.select(
                        mode: mode,
                        candidates: candidates,
                        frozenDisplays: frozenDisplays
                    )
                    let request = CaptureRequest(
                        mode: selection.mode == .window ? .window : mode,
                        includeCursor: settings.includeCursor,
                        displayID: selection.displayID,
                        selection: selection.pixelRect,
                        windowID: selection.windowID
                    )
                    if freezesSelection,
                       selection.mode != .window,
                       !settings.includeCursor,
                       let frozenImage = frozenDisplays[selection.displayID] {
                        result = try frozenRegionResult(
                            image: frozenImage,
                            selection: selection,
                            mode: mode
                        )
                    } else if mode == .scrolling {
                        let controller = ScrollingCaptureController(captureService: captureService, engine: scrollingEngine)
                        scrollingController = controller
                        do {
                            let stitched = try await controller.start(request: request)
                            scrollingController = nil
                            result = CaptureResult(image: stitched.image, mode: .scrolling, displayScale: 1, sourceRect: selection.pixelRect)
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

    private func captureFrozenDisplays() async throws -> [UInt32: CGImage] {
        let displayIDs = NSScreen.screens.compactMap(DisplayGeometry.displayID(for:))
        let captures = try await captureService.captureDisplays(displayIDs)
        return captures.mapValues(\.image)
    }

    private func frozenRegionResult(
        image: CGImage,
        selection: OverlaySelection,
        mode: CaptureMode
    ) throws -> CaptureResult {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let cropRect = selection.pixelRect.cgRect.standardized.integral
        guard cropRect.width > 0,
              cropRect.height > 0,
              imageBounds.contains(cropRect),
              let cropped = image.cropping(to: cropRect) else {
            throw OpenSnapXError.captureFailed("The selected area is outside the frozen display.")
        }
        let scale = NSScreen.screens.first {
            DisplayGeometry.displayID(for: $0) == selection.displayID
        }?.backingScaleFactor ?? 1
        return CaptureResult(
            image: cropped,
            mode: mode,
            displayScale: scale,
            sourceRect: CanvasRect(cropRect)
        )
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
            let results: [OCRResult]
            do {
                results = try await ocrService.recognize(ImagePayload(image: result.image))
            } catch {
                Task(priority: .utility) {
                    do {
                        _ = try await historyStore.create(from: result)
                        await rebuildMenu()
                    } catch {
                        present(error)
                    }
                }
                throw error
            }

            let text = results.map(\.text).joined(separator: "\n")
            if !text.isEmpty { exportService.copyText(text); showNotice("Text copied") }
            else { showNotice("No text recognized") }
            Task(priority: .utility) {
                do {
                    var session = try await historyStore.create(from: result)
                    session.ocrResults = results
                    try await historyStore.save(session)
                    await rebuildMenu()
                } catch {
                    present(error)
                }
            }
            return
        }

        let session = CaptureSession(captureResult: result)
        let initialPersistence = Task(priority: .utility) {
            _ = try await historyStore.create(from: result)
        }
        openEditor(
            session: session,
            image: result.image,
            initialPersistence: initialPersistence
        )
        Task {
            do {
                try await initialPersistence.value
                await rebuildMenu()
            } catch {
                present(error)
            }
        }
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
        controller.onCopy = { [weak self] id in self?.withHistoryImage(id: id) { self?.exportService.copy($0) } }
        controller.onPin = { [weak self] id in self?.withHistoryImage(id: id) { self?.pinnedController.pin($0) } }
        controller.onDelete = { [weak self] ids in self?.deleteHistory(ids: ids) }
        historyController = controller
        Task { await refreshHistoryWindow(controller); controller.show() }
    }

    @objc private func showSettings() {
        let controller = settingsController ?? SettingsWindowController(
            settings: settings,
            registerShortcuts: { [weak self] in self?.registerConfiguredShortcuts() ?? [] },
            showOnboarding: { [weak self] in self?.showOnboarding() }
        )
        settingsController = controller
        controller.show()
    }

    @objc private func showOnboarding() {
        let controller = onboardingController ?? OnboardingWindowController(
            permissionService: permissionService,
            settings: settings,
            registerShortcuts: { [weak self] in self?.registerConfiguredShortcuts() ?? [] },
            onFinish: { [weak self] in
                guard let self else { return }
                self.settings.completedOnboarding = true
                _ = self.registerConfiguredShortcuts()
            }
        )
        onboardingController = controller
        controller.show()
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

    private func withHistoryImage(id: UUID, action: @escaping (CGImage) -> Void) {
        Task {
            do {
                let (session, payload) = try await historyStore.load(id: id)
                let renderer = self.renderer
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try renderer.render(source: payload, session: session, options: ExportOptions()).image
                }.value
                action(rendered)
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
