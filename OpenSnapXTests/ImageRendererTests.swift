import AppKit
import CoreGraphics
import XCTest
@testable import OpenSnapX

final class ImageRendererTests: XCTestCase {
    func testRedactionIsFlattenedIntoRenderedPixels() throws {
        let source = try solidImage(width: 80, height: 80)
        let redact = Annotation(
            kind: .redact,
            frame: CanvasRect(CGRect(x: 10, y: 10, width: 30, height: 30)),
            style: AnnotationStyle(strokeColor: .black, fillColor: .black)
        )
        let session = CaptureSession(
            manifest: CaptureManifest(id: UUID(), createdAt: .now, modifiedAt: .now, captureMode: .region, pixelWidth: 80, pixelHeight: 80, displayScale: 1),
            annotations: [redact],
            ocrResults: []
        )
        let output = try CoreGraphicsImageRenderer().render(source: ImagePayload(image: source), session: session, options: ExportOptions()).image
        let bitmap = NSBitmapImageRep(cgImage: output)
        var redactedPixels = 0
        for y in 0..<80 {
            for x in 0..<80 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(NSColorSpace.sRGB) else { continue }
                if color.redComponent < 0.05, color.greenComponent < 0.05, color.blueComponent < 0.05 {
                    redactedPixels += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(redactedPixels, 850)
        XCTAssertLessThanOrEqual(redactedPixels, 950)
    }

    func testRichTextBackgroundAndForegroundAreFlattened() throws {
        let source = try solidImage(width: 180, height: 90)
        let style = RichTextStyle(
            fontFamily: "Helvetica",
            fontSize: 34,
            isBold: true,
            isUnderlined: true,
            isStruckThrough: true,
            foregroundColor: RGBAColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1),
            backgroundColor: RGBAColor(red: 1, green: 0.85, blue: 0.05, alpha: 1),
            alignment: .center
        )
        let text = "Rich text"
        let annotation = Annotation(
            kind: .text,
            frame: CanvasRect(CGRect(x: 10, y: 10, width: 160, height: 60)),
            text: text,
            richText: RichTextDocument(
                string: text,
                runs: [RichTextRun(location: 0, length: text.utf16.count, style: style)]
            )
        )
        let session = CaptureSession(
            manifest: CaptureManifest(
                id: UUID(), createdAt: .now, modifiedAt: .now, captureMode: .region,
                pixelWidth: 180, pixelHeight: 90, displayScale: 1
            ),
            annotations: [annotation],
            ocrResults: []
        )

        let output = try CoreGraphicsImageRenderer().render(
            source: ImagePayload(image: source),
            session: session,
            options: ExportOptions()
        ).image
        let bitmap = NSBitmapImageRep(cgImage: output)
        var redPixels = 0
        var yellowPixels = 0
        for y in 0..<output.height {
            for x in 0..<output.width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.65,
                   color.greenComponent < 0.35,
                   color.blueComponent < 0.35 {
                    redPixels += 1
                }
                if color.redComponent > 0.8,
                   color.greenComponent > 0.6,
                   color.blueComponent < 0.35 {
                    yellowPixels += 1
                }
            }
        }

        XCTAssertGreaterThan(redPixels, 50)
        XCTAssertGreaterThan(yellowPixels, 300)
    }

    func testBackdropIncreasesCanvasSize() throws {
        let source = try solidImage(width: 100, height: 60)
        var manifest = CaptureManifest(id: UUID(), createdAt: .now, modifiedAt: .now, captureMode: .region, pixelWidth: 100, pixelHeight: 60, displayScale: 1)
        manifest.backdrop.isEnabled = true
        manifest.backdrop.padding = 20
        let session = CaptureSession(manifest: manifest, annotations: [], ocrResults: [])
        let output = try CoreGraphicsImageRenderer().render(source: ImagePayload(image: source), session: session, options: ExportOptions()).image
        XCTAssertEqual(output.width, 140)
        XCTAssertEqual(output.height, 100)
    }
}
