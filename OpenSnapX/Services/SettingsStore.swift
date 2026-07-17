import Foundation

@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private enum Key {
        static let completedOnboarding = "completedOnboarding"
        static let historyRetentionDays = "historyRetentionDays"
        static let includeCursor = "includeCursor"
        static let captureSoundEnabled = "captureSoundEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let exportFormat = "exportFormat"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.historyRetentionDays: 7,
            Key.includeCursor: false,
            Key.captureSoundEnabled: true,
            Key.launchAtLogin: false,
            Key.exportFormat: ExportFormat.png.rawValue
        ])
    }

    var completedOnboarding: Bool {
        get { defaults.bool(forKey: Key.completedOnboarding) }
        set { defaults.set(newValue, forKey: Key.completedOnboarding) }
    }

    var historyRetentionDays: Int {
        get { defaults.integer(forKey: Key.historyRetentionDays) }
        set { defaults.set(newValue, forKey: Key.historyRetentionDays) }
    }

    var includeCursor: Bool {
        get { defaults.bool(forKey: Key.includeCursor) }
        set { defaults.set(newValue, forKey: Key.includeCursor) }
    }

    var captureSoundEnabled: Bool {
        get { defaults.bool(forKey: Key.captureSoundEnabled) }
        set { defaults.set(newValue, forKey: Key.captureSoundEnabled) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    var exportFormat: ExportFormat {
        get { ExportFormat(rawValue: defaults.string(forKey: Key.exportFormat) ?? "") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: Key.exportFormat) }
    }

    func shortcut(for action: ShortcutAction) -> ShortcutDefinition {
        guard let data = defaults.data(forKey: shortcutKey(for: action)),
              var shortcut = try? JSONDecoder().decode(ShortcutDefinition.self, from: data) else {
            return action.defaultShortcut
        }
        if let keyLabel = ShortcutDefinition.numberRowKeyLabel(for: shortcut.keyCode),
           shortcut.keyLabel != keyLabel {
            shortcut.keyLabel = keyLabel
            setShortcut(shortcut, for: action)
        }
        return shortcut
    }

    func setShortcut(_ shortcut: ShortcutDefinition, for action: ShortcutAction) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: shortcutKey(for: action))
    }

    var shortcutDefinitions: [ShortcutAction: ShortcutDefinition] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, shortcut(for: $0)) })
    }

    private func shortcutKey(for action: ShortcutAction) -> String {
        "shortcut.\(action.rawValue)"
    }
}
