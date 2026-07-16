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
