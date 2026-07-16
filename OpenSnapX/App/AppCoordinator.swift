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
    private let shortcutManager: any ShortcutManager = CarbonShortcutManager()
    private let overlayController = CaptureOverlayController()
    private let previewController = FloatingPreviewController()
    private let pinnedController = PinnedImageController()

    private var statusItem: NSStatusItem!
    private var onboardingController: OnboardingWindowController?
    private var settingsController: SettingsWindowController?
    private var historyController: HistoryWindowController?
    private var paletteController: CapturePaletteWindowController?
    private var editorControllers: [UUID: EditorWindowController] = [:]
    private var scrollingController: ScrollingCaptureController?
    private var shortcutConflicts: [ShortcutAction] = []

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
        menu.addItem(item("Scrolling Capture", #selector(captureScrolling)))
        menu.addItem(captureItem("Capture Text", #selector(captureText), shortcut: .captureText))
        menu.addItem(captureItem("Capture Palette…", #selector(showPalette), shortcut: .capturePalette))
        if !shortcutConflicts.isEmpty {
            let warning = NSMenuItem(title: "⚠ Screenshot shortcut conflict", action: #selector(showOnboarding), keyEquivalent: "")
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
        case .capturePalette: showPalette()
        }
    }

    @objc private func captureRegion() { performCapture(mode: .region) }
    @objc private func captureWindow() { performCapture(mode: .window) }
    @objc private func captureDisplay() { performCapture(mode: .display) }
    @objc private func captureScrolling() { performCapture(mode: .scrolling) }
    @objc private func captureText() { performCapture(mode: .text) }

    private func performCapture(mode: CaptureMode, delay: Int = 0) {
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
                    result = try await captureService.capture(CaptureRequest(mode: .display, delaySeconds: delay, includeCursor: settings.includeCursor, displayID: displayID))
                } else {
                    let candidates = mode == .window ? try await captureService.availableWindows() : []
                    let selection = try await overlayController.select(mode: mode, candidates: candidates)
                    try? await Task.sleep(for: .milliseconds(120))
                    let request = CaptureRequest(
                        mode: selection.mode == .window ? .window : mode,
                        delaySeconds: delay,
                        includeCursor: settings.includeCursor,
                        displayID: selection.displayID,
                        selection: selection.pixelRect,
                        windowID: selection.windowID
                    )
                    if mode == .scrolling {
                        let controller = ScrollingCaptureController(captureService: captureService, engine: scrollingEngine)
                        scrollingController = controller
                        let stitched = try await controller.start(request: request)
                        scrollingController = nil
                        result = CaptureResult(image: stitched.image, mode: .scrolling, displayScale: 1, sourceRect: selection.pixelRect)
                    } else {
                        result = try await captureService.capture(request)
                    }
                }
                try await completeCapture(result)
            } catch OpenSnapXError.selectionCancelled {
                logger.debug("Capture cancelled")
            } catch {
                present(error)
            }
        }
    }

    private func completeCapture(_ result: CaptureResult) async throws {
        let session = try await historyStore.create(from: result)
        await rebuildMenu()
        if result.mode == .text {
            let results = try await ocrService.recognize(ImagePayload(image: result.image))
            var updated = session
            updated.ocrResults = results
            try await historyStore.save(updated)
            let text = results.map(\.text).joined(separator: "\n")
            if !text.isEmpty { exportService.copyText(text); showNotice("Text copied") }
            else { showNotice("No text recognized") }
            return
        }
        switch settings.postCaptureAction {
        case .preview: showPreview(session: session, image: result.image)
        case .copy: exportService.copy(result.image); showNotice("Screenshot copied")
        case .save: _ = try await exportService.save(result.image)
        case .copyAndPreview: exportService.copy(result.image); showPreview(session: session, image: result.image)
        }
    }

    private func showPreview(session: CaptureSession, image: CGImage) {
        let id = session.id
        previewController.show(id: id, image: image, duration: settings.previewDuration, actions: .init(
            edit: { [weak self] in self?.previewController.dismiss(id: id); self?.openEditor(id: id) },
            copy: { [weak self] in self?.exportService.copy(image); self?.showNotice("Screenshot copied") },
            save: { [weak self] in Task { _ = try? await self?.exportService.save(image) } },
            share: { [weak self] view in self?.exportService.share(image, relativeTo: view.bounds, of: view) },
            pin: { [weak self] in self?.pinnedController.pin(image); self?.previewController.dismiss(id: id) },
            dismiss: { [weak self] in self?.previewController.dismiss(id: id) }
        ))
    }

    private func openEditor(id: UUID) {
        Task {
            do {
                let (session, payload) = try await historyStore.load(id: id)
                let editor = EditorWindowController(
                    session: session,
                    image: payload.image,
                    historyStore: historyStore,
                    renderer: renderer,
                    ocrService: ocrService,
                    exportService: exportService
                )
                editorControllers[id] = editor
                editor.show()
            } catch { present(error) }
        }
    }

    @objc private func showPalette() {
        let controller = paletteController ?? CapturePaletteWindowController()
        controller.onCapture = { [weak self] mode, delay in self?.performCapture(mode: mode, delay: delay) }
        paletteController = controller
        controller.show()
    }

    @objc private func showHistory() {
        let controller = historyController ?? HistoryWindowController()
        controller.onOpen = { [weak self] id in self?.openEditor(id: id) }
        controller.onCopy = { [weak self] id in self?.withHistoryImage(id: id) { self?.exportService.copy($0) } }
        controller.onPin = { [weak self] id in self?.withHistoryImage(id: id) { self?.pinnedController.pin($0) } }
        controller.onDelete = { [weak self] id in self?.deleteHistory(id: id) }
        historyController = controller
        Task { await refreshHistoryWindow(controller); controller.show() }
    }

    @objc private func showSettings() {
        let controller = settingsController ?? SettingsWindowController(settings: settings) { [weak self] in
            self?.registerConfiguredShortcuts() ?? []
        }
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
            do { let (_, payload) = try await historyStore.load(id: id); action(payload.image) }
            catch { present(error) }
        }
    }

    private func deleteHistory(id: UUID) {
        Task {
            try? await historyStore.delete(id: id)
            if let historyController { await refreshHistoryWindow(historyController) }
            await rebuildMenu()
        }
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
        editorControllers = editorControllers.filter { $0.value.window?.isVisible == true }
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            let hasRegularWindow = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel && $0.styleMask.contains(.nonactivatingPanel)) }
            if !hasRegularWindow { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
