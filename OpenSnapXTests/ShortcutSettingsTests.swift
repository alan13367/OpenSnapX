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
    }

    func testShortcutDisplayStringUsesMacModifierOrder() {
        let shortcut = ShortcutDefinition(
            keyCode: UInt32(kVK_ANSI_4),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            keyLabel: "4"
        )
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘4")
    }

    func testGlobalShortcutsAreRegisteredExclusively() {
        XCTAssertEqual(
            CarbonShortcutManager.registrationOptions,
            OptionBits(kEventHotKeyExclusive)
        )
    }
}
