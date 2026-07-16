import AppKit
import CoreGraphics

@MainActor
final class ScreenPermissionService {
    var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func openKeyboardShortcutSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts",
            "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts"
        ]
        guard let url = candidates.compactMap(URL.init(string:)).first else { return }
        NSWorkspace.shared.open(url)
    }
}
