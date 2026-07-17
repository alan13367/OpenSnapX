import Carbon
import Foundation

enum ShortcutAction: UInt32, CaseIterable, Sendable {
    case captureText = 2
    case captureDisplay = 3
    case captureRegion = 4
    case captureScrolling = 5
    case colorPicker = 6

    static let presentationOrder: [ShortcutAction] = [
        .captureRegion,
        .captureDisplay,
        .captureScrolling,
        .captureText,
        .colorPicker
    ]

    var title: String {
        switch self {
        case .captureText: "Capture Text"
        case .captureDisplay: "Capture Display"
        case .captureRegion: "Capture Area / Window"
        case .captureScrolling: "Scrolling Capture"
        case .colorPicker: "Color Picker"
        }
    }

    var detail: String {
        switch self {
        case .captureText: "Select a region and copy recognized text"
        case .captureDisplay: "Capture the display under the pointer"
        case .captureRegion: "Drag an area or press Space for a window"
        case .captureScrolling: "Select an area and stitch it as you scroll"
        case .colorPicker: "Pick any on-screen color and copy its hex value"
        }
    }

    var symbolName: String {
        switch self {
        case .captureText: "text.viewfinder"
        case .captureDisplay: "display"
        case .captureRegion: "viewfinder.rectangular"
        case .captureScrolling: "rectangle.stack"
        case .colorPicker: "eyedropper"
        }
    }

    var defaultShortcut: ShortcutDefinition {
        let keyCode: UInt32
        let keyLabel: String
        switch self {
        case .captureText:
            keyCode = UInt32(kVK_ANSI_2)
            keyLabel = "2"
        case .captureDisplay:
            keyCode = UInt32(kVK_ANSI_3)
            keyLabel = "3"
        case .captureRegion:
            keyCode = UInt32(kVK_ANSI_4)
            keyLabel = "4"
        case .captureScrolling:
            keyCode = UInt32(kVK_ANSI_6)
            keyLabel = "6"
        case .colorPicker:
            keyCode = UInt32(kVK_ANSI_C)
            keyLabel = "C"
        }
        return ShortcutDefinition(
            keyCode: keyCode,
            modifiers: UInt32(cmdKey | shiftKey),
            keyLabel: keyLabel
        )
    }
}

extension ShortcutDefinition {
    static func numberRowKeyLabel(for keyCode: UInt32) -> String? {
        switch Int(keyCode) {
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        default: nil
        }
    }

    /// Apple's screenshot shortcuts are handled outside Carbon's app hot-key
    /// registry, so an exclusive registration can still fire alongside them.
    var matchesBuiltInScreenshotShortcut: Bool {
        let screenshotKeyCodes: Set<UInt32> = [
            UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4),
            UInt32(kVK_ANSI_5),
            UInt32(kVK_ANSI_6)
        ]
        guard screenshotKeyCodes.contains(keyCode) else { return false }

        let requiredModifiers = UInt32(cmdKey | shiftKey)
        let allowedModifiers = UInt32(cmdKey | shiftKey | controlKey)
        return modifiers & requiredModifiers == requiredModifiers
            && modifiers & ~allowedModifiers == 0
    }
}

struct ShortcutRegistrationResult: Sendable {
    var action: ShortcutAction
    var succeeded: Bool
    var status: OSStatus
}

@MainActor
protocol ShortcutManager: AnyObject {
    var onAction: ((ShortcutAction) -> Void)? { get set }
    func register(_ definitions: [ShortcutAction: ShortcutDefinition]) -> [ShortcutRegistrationResult]
    func unregisterAll()
}

@MainActor
final class CarbonShortcutManager: ShortcutManager {
    static let registrationOptions = OptionBits(kEventHotKeyExclusive)

    var onAction: ((ShortcutAction) -> Void)?

    private var hotKeys: [ShortcutAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      let action = ShortcutAction(rawValue: hotKeyID.id) else { return status }
                let manager = Unmanaged<CarbonShortcutManager>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { manager.onAction?(action) }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &eventHandler
        )
    }

    func register(_ definitions: [ShortcutAction: ShortcutDefinition]) -> [ShortcutRegistrationResult] {
        unregisterAll()
        return ShortcutAction.allCases.map { action in
            let definition = definitions[action] ?? action.defaultShortcut
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: fourCharCode("OSXK"), id: action.rawValue)
            let status = RegisterEventHotKey(
                definition.keyCode,
                definition.modifiers,
                id,
                GetApplicationEventTarget(),
                Self.registrationOptions,
                &reference
            )
            if status == noErr, let reference { hotKeys[action] = reference }
            return ShortcutRegistrationResult(action: action, succeeded: status == noErr, status: status)
        }
    }

    func unregisterAll() {
        for reference in hotKeys.values { UnregisterEventHotKey(reference) }
        hotKeys.removeAll()
    }

    private func fourCharCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
