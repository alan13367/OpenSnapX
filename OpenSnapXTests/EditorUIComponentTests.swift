import AppKit
import XCTest
@testable import OpenSnapX

@MainActor
final class EditorUIComponentTests: XCTestCase {
    func testTextFormattingFontSizeActionReachesFormattingTarget() throws {
        let target = TextFormattingTargetSpy()
        let controller = TextFormattingToolbarController(target: target)
        controller.loadViewIfNeeded()
        let sizeCombo = try XCTUnwrap(findSubview(of: NSComboBox.self, in: controller.view))

        sizeCombo.stringValue = "48"
        _ = sizeCombo.sendAction(sizeCombo.action, to: sizeCombo.target)

        XCTAssertEqual(target.fontSize, 48)
    }

    func testTypedTextFormattingFontSizeAppliesWhenEditingEnds() throws {
        let target = TextFormattingTargetSpy()
        let controller = TextFormattingToolbarController(target: target)
        controller.loadViewIfNeeded()
        let sizeCombo = try XCTUnwrap(findSubview(of: NSComboBox.self, in: controller.view))

        sizeCombo.stringValue = "36"
        controller.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: sizeCombo
        ))

        XCTAssertEqual(target.fontSize, 36)
    }

    func testFontSizeActionIsNotRepeatedWhenEditingEnds() throws {
        let target = TextFormattingTargetSpy()
        let controller = TextFormattingToolbarController(target: target)
        controller.loadViewIfNeeded()
        let sizeCombo = try XCTUnwrap(findSubview(of: NSComboBox.self, in: controller.view))

        sizeCombo.stringValue = "36"
        _ = sizeCombo.sendAction(sizeCombo.action, to: sizeCombo.target)
        controller.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: sizeCombo
        ))

        XCTAssertEqual(target.fontSizeCalls, 1)
    }

    func testChangingFontSizeAtCaretOnlyUpdatesTypingAttributes() throws {
        let text = "Existing text"
        let annotation = Annotation(
            kind: .text,
            frame: CanvasRect(CGRect(x: 10, y: 10, width: 220, height: 48)),
            text: text,
            style: AnnotationStyle(fontSize: 24)
        )
        let canvas = EditorCanvasView(
            image: try solidImage(width: 320, height: 120),
            canvasSize: CGSize(width: 320, height: 120),
            annotations: [annotation],
            ocrResults: []
        )
        let canvasPoint = CGPoint(x: 20, y: 20)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: canvas.convert(canvasPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1
        ))
        canvas.mouseDown(with: event)
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))

        canvas.setTextFontSize(40)

        let existingFont = try XCTUnwrap(editor.textStorage?.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? NSFont)
        let typingFont = try XCTUnwrap(editor.typingAttributes[.font] as? NSFont)
        XCTAssertEqual(existingFont.pointSize, 24)
        XCTAssertEqual(typingFont.pointSize, 40)
    }

    private func findSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = findSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}

@MainActor
private final class TextFormattingTargetSpy: EditorTextFormattingTarget {
    var fontSize: CGFloat?
    var fontSizeCalls = 0

    func setTextFontFamily(_ family: String) {}
    func setTextFontSize(_ size: CGFloat) {
        fontSize = size
        fontSizeCalls += 1
    }
    func toggleTextBold() {}
    func toggleTextItalic() {}
    func toggleTextUnderline() {}
    func toggleTextStrikethrough() {}
    func setTextForegroundColor(_ color: NSColor) {}
    func toggleTextBackground() {}
    func setTextBackgroundColor(_ color: NSColor) {}
    func setTextAlignment(_ alignment: RichTextAlignment) {}
}
