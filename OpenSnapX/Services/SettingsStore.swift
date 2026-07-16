import Foundation

@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private enum Key {
        static let completedOnboarding = "completedOnboarding"
        static let previewDuration = "previewDuration"
        static let historyRetentionDays = "historyRetentionDays"
        static let postCaptureAction = "postCaptureAction"
        static let includeCursor = "includeCursor"
        static let defaultDelay = "defaultDelay"
        static let launchAtLogin = "launchAtLogin"
        static let exportFormat = "exportFormat"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.previewDuration: 8.0,
            Key.historyRetentionDays: 7,
            Key.postCaptureAction: PostCaptureAction.preview.rawValue,
            Key.includeCursor: false,
            Key.defaultDelay: 5,
            Key.launchAtLogin: false,
            Key.exportFormat: ExportFormat.png.rawValue
        ])
    }

    var completedOnboarding: Bool {
        get { defaults.bool(forKey: Key.completedOnboarding) }
        set { defaults.set(newValue, forKey: Key.completedOnboarding) }
    }

    var previewDuration: TimeInterval {
        get { defaults.double(forKey: Key.previewDuration) }
        set { defaults.set(newValue, forKey: Key.previewDuration) }
    }

    var historyRetentionDays: Int {
        get { defaults.integer(forKey: Key.historyRetentionDays) }
        set { defaults.set(newValue, forKey: Key.historyRetentionDays) }
    }

    var postCaptureAction: PostCaptureAction {
        get { PostCaptureAction(rawValue: defaults.string(forKey: Key.postCaptureAction) ?? "") ?? .preview }
        set { defaults.set(newValue.rawValue, forKey: Key.postCaptureAction) }
    }

    var includeCursor: Bool {
        get { defaults.bool(forKey: Key.includeCursor) }
        set { defaults.set(newValue, forKey: Key.includeCursor) }
    }

    var defaultDelay: Int {
        get { defaults.integer(forKey: Key.defaultDelay) }
        set { defaults.set(newValue, forKey: Key.defaultDelay) }
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
              let shortcut = try? JSONDecoder().decode(ShortcutDefinition.self, from: data) else {
            return action.defaultShortcut
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
