import CoreGraphics

struct EditorToolbarStyle: Equatable {
    var color = RGBAColor.red
    var strokeWidth: Double = 15
    var counterFontSize: Double = 24
}

enum EditorToolbarCommand {
    case copyRendered
    case saveRendered
    case undo
    case redo
    case clearAllEdits
    case discardCapture
    case selectTool(EditorTool)
    case changeStyle(EditorToolbarStyle)
    case copyColorHex(String)
    case resizeImage(CGSize)
    case toggleRecognizedText
    case showBackdrop
}

@MainActor
protocol EditorToolbarControllerDelegate: AnyObject {
    func editorToolbar(_ toolbar: EditorToolbarController, perform command: EditorToolbarCommand)
}
