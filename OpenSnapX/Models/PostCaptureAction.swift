enum PostCaptureAction: String, CaseIterable, Sendable {
    case openEditor
    case copyToClipboard
    case keepInHistoryOnly
    case copyRecognizedText
    case reviewBeforeCopy

    var title: String {
        switch self {
        case .openEditor: "Open Editor"
        case .copyToClipboard: "Copy to Clipboard"
        case .keepInHistoryOnly: "Keep in History Only"
        case .copyRecognizedText: "Copy Recognized Text"
        case .reviewBeforeCopy: "Review Before Copy"
        }
    }

    static func availableActions(for mode: CaptureMode) -> [PostCaptureAction] {
        if mode == .text {
            return [.copyRecognizedText, .reviewBeforeCopy]
        }
        return [.openEditor, .copyToClipboard, .keepInHistoryOnly]
    }

    static func defaultAction(for mode: CaptureMode) -> PostCaptureAction {
        mode == .text ? .copyRecognizedText : .openEditor
    }

    func isAvailable(for mode: CaptureMode) -> Bool {
        Self.availableActions(for: mode).contains(self)
    }
}
