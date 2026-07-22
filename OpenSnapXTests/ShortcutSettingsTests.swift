import AppKit
import Carbon
import XCTest
@testable import OpenSnapX

@MainActor
final class ShortcutSettingsTests: XCTestCase {
    func testCustomShortcutPersistsAndOtherActionsKeepDefaults() {
        let suiteName = "OpenSnapXTests.shortcuts.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        let custom = ShortcutDefinition(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(controlKey | optionKey),
            keyLabel: "S"
        )
        settings.setShortcut(custom, for: .captureRegion)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.shortcut(for: .captureRegion), custom)
        XCTAssertEqual(reloaded.shortcut(for: .captureDisplay), ShortcutAction.captureDisplay.defaultShortcut)
        XCTAssertEqual(reloaded.shortcut(for: .captureScrolling), ShortcutAction.captureScrolling.defaultShortcut)
        XCTAssertEqual(reloaded.shortcut(for: .colorPicker), ShortcutAction.colorPicker.defaultShortcut)
    }

    func testColorPickerDefaultsToCommandShiftC() {
        let shortcut = ShortcutAction.colorPicker.defaultShortcut
        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_C))
        XCTAssertEqual(shortcut.modifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(shortcut.keyLabel, "C")
        XCTAssertEqual(shortcut.displayString, "⇧⌘C")
    }

    func testScrollingCaptureDefaultsToCommandShift6() {
        let shortcut = ShortcutAction.captureScrolling.defaultShortcut
        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_6))
        XCTAssertEqual(shortcut.modifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(shortcut.keyLabel, "6")
        XCTAssertEqual(shortcut.displayString, "⇧⌘6")
    }

    func testCaptureSoundDefaultsToEnabledAndPersists() {
        let suiteName = "OpenSnapXTests.captureSound.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.captureSoundEnabled)

        settings.captureSoundEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults).captureSoundEnabled)
    }

    func testPostCaptureActionsPreserveExistingDefaults() {
        let suiteName = "OpenSnapXTests.postCaptureDefaults.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.postCaptureAction(for: .region), .openEditor)
        XCTAssertEqual(settings.postCaptureAction(for: .window), .openEditor)
        XCTAssertEqual(settings.postCaptureAction(for: .display), .openEditor)
        XCTAssertEqual(settings.postCaptureAction(for: .scrolling), .openEditor)
        XCTAssertEqual(settings.postCaptureAction(for: .text), .copyRecognizedText)
    }

    func testPostCaptureActionsPersistPerCaptureMode() {
        let suiteName = "OpenSnapXTests.postCapturePersistence.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        settings.setPostCaptureAction(.copyToClipboard, for: .region)
        settings.setPostCaptureAction(.keepInHistoryOnly, for: .window)
        settings.setPostCaptureAction(.reviewBeforeCopy, for: .text)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.postCaptureAction(for: .region), .copyToClipboard)
        XCTAssertEqual(reloaded.postCaptureAction(for: .window), .keepInHistoryOnly)
        XCTAssertEqual(reloaded.postCaptureAction(for: .display), .openEditor)
        XCTAssertEqual(reloaded.postCaptureAction(for: .text), .reviewBeforeCopy)
    }

    func testTextCaptureOnlyOffersNonRetainingTextActions() {
        XCTAssertEqual(
            PostCaptureAction.availableActions(for: .text),
            [.copyRecognizedText, .reviewBeforeCopy]
        )
        XCTAssertFalse(PostCaptureAction.copyRecognizedText.isAvailable(for: .region))
        XCTAssertFalse(PostCaptureAction.keepInHistoryOnly.isAvailable(for: .text))
    }

    func testInvalidPostCaptureActionFallsBackToModeDefault() {
        let suiteName = "OpenSnapXTests.postCaptureValidation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        settings.setPostCaptureAction(.reviewBeforeCopy, for: .display)
        settings.setPostCaptureAction(.openEditor, for: .text)

        XCTAssertEqual(settings.postCaptureAction(for: .display), .openEditor)
        XCTAssertEqual(settings.postCaptureAction(for: .text), .copyRecognizedText)
    }

    func testSettingsExposeGeneralAndActionsTabs() throws {
        let suiteName = "OpenSnapXTests.settingsTabs.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = SettingsWindowController(
            settings: SettingsStore(defaults: defaults),
            registerShortcuts: { [] },
            showOnboarding: {},
            setMCPEnabled: { _ in },
            installAgentSkill: {},
            copyMCPConfiguration: {}
        )
        let toolbar = try XCTUnwrap(controller.window?.toolbar)

        XCTAssertEqual(toolbar.items.map(\.label), ["General", "Actions"])
        XCTAssertEqual(toolbar.selectedItemIdentifier?.rawValue, "GeneralSettings")
    }

    func testChangingHistoryRetentionRequestsImmediateCleanup() throws {
        let suiteName = "OpenSnapXTests.historyRetention.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        var requestedRetentionDays: [Int] = []
        let controller = SettingsWindowController(
            settings: settings,
            registerShortcuts: { [] },
            showOnboarding: {},
            historyRetentionChanged: { requestedRetentionDays.append($0) },
            setMCPEnabled: { _ in },
            installAgentSkill: {},
            copyMCPConfiguration: {}
        )
        let contentView = try XCTUnwrap(controller.window?.contentView)
        let retention = try XCTUnwrap(findView(in: contentView) { view in
            guard let popUp = view as? NSPopUpButton else { return false }
            return popUp.itemTitles == ["1 day", "7 days", "30 days", "Forever"]
        } as? NSPopUpButton)

        retention.selectItem(withTitle: "1 day")
        XCTAssertTrue(retention.sendAction(retention.action, to: retention.target))

        XCTAssertEqual(settings.historyRetentionDays, 1)
        XCTAssertEqual(requestedRetentionDays, [1])
    }

    func testMCPDefaultsToDisabledAndPersistsExplicitOptIn() {
        let suiteName = "OpenSnapXTests.mcp.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.mcpEnabled)

        settings.mcpEnabled = true
        XCTAssertTrue(SettingsStore(defaults: defaults).mcpEnabled)
    }

    func testShortcutDisplayStringUsesMacModifierOrder() {
        let shortcut = ShortcutDefinition(
            keyCode: UInt32(kVK_ANSI_4),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            keyLabel: "4"
        )
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘4")
    }

    func testNumberRowShortcutUsesKeyCapInsteadOfShiftedCharacter() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "&",
            charactersIgnoringModifiers: "&",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_6)
        ))
        XCTAssertEqual(ShortcutRecorderControl.keyLabel(for: event), "6")
    }

    func testPersistedShiftedNumberLabelIsNormalizedToKeyCap() {
        let suiteName = "OpenSnapXTests.numberLabel.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        settings.setShortcut(ShortcutDefinition(
            keyCode: UInt32(kVK_ANSI_6),
            modifiers: UInt32(cmdKey | shiftKey),
            keyLabel: "&"
        ), for: .captureScrolling)

        let shortcut = settings.shortcut(for: .captureScrolling)
        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_6))
        XCTAssertEqual(shortcut.keyLabel, "6")
        XCTAssertEqual(shortcut.displayString, "⇧⌘6")
    }

    func testKnownAppleScreenshotShortcutsAreIdentified() {
        XCTAssertTrue(ShortcutAction.captureDisplay.defaultShortcut.matchesBuiltInScreenshotShortcut)
        XCTAssertTrue(ShortcutAction.captureRegion.defaultShortcut.matchesBuiltInScreenshotShortcut)
        XCTAssertTrue(ShortcutAction.captureScrolling.defaultShortcut.matchesBuiltInScreenshotShortcut)
        XCTAssertFalse(ShortcutAction.captureText.defaultShortcut.matchesBuiltInScreenshotShortcut)
        XCTAssertFalse(ShortcutAction.colorPicker.defaultShortcut.matchesBuiltInScreenshotShortcut)

        let clipboardVariant = ShortcutDefinition(
            keyCode: UInt32(kVK_ANSI_4),
            modifiers: UInt32(controlKey | shiftKey | cmdKey),
            keyLabel: "4"
        )
        XCTAssertTrue(clipboardVariant.matchesBuiltInScreenshotShortcut)

        let conflictFreeVariant = ShortcutDefinition(
            keyCode: UInt32(kVK_ANSI_4),
            modifiers: UInt32(controlKey | shiftKey),
            keyLabel: "4"
        )
        XCTAssertFalse(conflictFreeVariant.matchesBuiltInScreenshotShortcut)
    }

    func testGlobalShortcutsAreRegisteredExclusivelyAgainstOtherAppHotKeys() {
        XCTAssertEqual(
            CarbonShortcutManager.registrationOptions,
            OptionBits(kEventHotKeyExclusive)
        )
    }
}

private func findView(in root: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
    if predicate(root) { return root }
    for subview in root.subviews {
        if let match = findView(in: subview, matching: predicate) { return match }
    }
    return nil
}
