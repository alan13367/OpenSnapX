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

    func testShortcutDisplayStringUsesMacModifierOrder() {
        let shortcut = ShortcutDefinition(
            keyCode: UInt32(kVK_ANSI_4),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            keyLabel: "4"
        )
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘4")
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
