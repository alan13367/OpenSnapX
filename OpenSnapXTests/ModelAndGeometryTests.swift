import CoreGraphics
import XCTest
@testable import OpenSnapX

final class ModelAndGeometryTests: XCTestCase {
    func testDisplayPointSizeExpandsToRetinaCapturePixels() {
        let pixels = DisplayGeometry.pixelSize(from: CGSize(width: 1512, height: 982), scale: 2)
        XCTAssertEqual(pixels, CGSize(width: 3024, height: 1964))
    }

    func testDisplayPointSizeStaysUnchangedAtOneX() {
        let pixels = DisplayGeometry.pixelSize(from: CGSize(width: 1920, height: 1080), scale: 1)
        XCTAssertEqual(pixels, CGSize(width: 1920, height: 1080))
    }

    func testPixelConversionForRetinaDisplayWithNegativeOrigin() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: -1340, y: 650, width: 200, height: 100)
        let pixels = DisplayGeometry.pixelRect(from: selection, screenFrame: screen, scale: 2)
        XCTAssertEqual(pixels, CGRect(x: 200, y: 300, width: 400, height: 200))
    }

    func testPixelConversionForVerticallyArrangedDisplay() {
        let screen = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        let selection = CGRect(x: 10, y: 1870, width: 100, height: 50)
        let pixels = DisplayGeometry.pixelRect(from: selection, screenFrame: screen, scale: 1)
        XCTAssertEqual(pixels, CGRect(x: 10, y: 60, width: 100, height: 50))
    }

    func testMovingAnnotationPointsMovesRenderedLineWithItsFrame() {
        let points = [CanvasPoint(CGPoint(x: 10, y: 20)), CanvasPoint(CGPoint(x: 90, y: 60))]
        let moved = AnnotationCanvasGeometry.movedPoints(points, by: CGPoint(x: 15, y: -5))
        XCTAssertEqual(moved.map(\.cgPoint), [CGPoint(x: 25, y: 15), CGPoint(x: 105, y: 55)])
    }

    func testTranslatingAnnotationMovesFrameAndPointsTogether() {
        let annotation = Annotation(
            kind: .pen,
            frame: CanvasRect(CGRect(x: 10, y: 20, width: 80, height: 40)),
            points: [CanvasPoint(CGPoint(x: 10, y: 20)), CanvasPoint(CGPoint(x: 90, y: 60))]
        )
        let translated = AnnotationCanvasGeometry.translated(annotation, by: CGPoint(x: 12, y: 12))
        XCTAssertEqual(translated.frame.cgRect, CGRect(x: 22, y: 32, width: 80, height: 40))
        XCTAssertEqual(translated.points.map(\.cgPoint), [CGPoint(x: 22, y: 32), CGPoint(x: 102, y: 72)])
    }

    func testResizingAnnotationPointsMovesLineEndpoints() {
        let points = [CanvasPoint(CGPoint(x: 10, y: 20)), CanvasPoint(CGPoint(x: 90, y: 60))]
        let resized = AnnotationCanvasGeometry.resizedPoints(
            points,
            from: CGRect(x: 10, y: 20, width: 80, height: 40),
            to: CGRect(x: 10, y: 20, width: 160, height: 80)
        )
        XCTAssertEqual(resized.map(\.cgPoint), [CGPoint(x: 10, y: 20), CGPoint(x: 170, y: 100)])
    }

    func testLineHitAreaIsEasierThanItsVisibleStroke() {
        let distance = AnnotationCanvasGeometry.distance(
            from: CGPoint(x: 50, y: 26),
            toSegmentFrom: CGPoint(x: 10, y: 20),
            to: CGPoint(x: 90, y: 20)
        )
        XCTAssertEqual(distance, 6, accuracy: 0.001)
    }

    func testCaptureResultBuildsImmediateInMemorySession() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceRect = CanvasRect(CGRect(x: 10, y: 20, width: 320, height: 180))
        let result = CaptureResult(
            image: try solidImage(width: 320, height: 180),
            mode: .region,
            createdAt: createdAt,
            displayScale: 2,
            sourceRect: sourceRect
        )
        let session = CaptureSession(captureResult: result)

        XCTAssertEqual(session.id, result.id)
        XCTAssertEqual(session.manifest.createdAt, createdAt)
        XCTAssertEqual(session.manifest.modifiedAt, createdAt)
        XCTAssertEqual(session.manifest.pixelWidth, 320)
        XCTAssertEqual(session.manifest.pixelHeight, 180)
        XCTAssertEqual(session.manifest.displayScale, 2)
        XCTAssertEqual(session.manifest.sourceRect, sourceRect)
        XCTAssertTrue(session.annotations.isEmpty)
        XCTAssertTrue(session.ocrResults.isEmpty)
    }

    func testCaptureSessionRoundTripsVersionedAnnotations() throws {
        let annotation = Annotation(
            kind: .arrow,
            frame: CanvasRect(CGRect(x: 10, y: 20, width: 80, height: 40)),
            points: [CanvasPoint(CGPoint(x: 10, y: 20)), CanvasPoint(CGPoint(x: 90, y: 60))],
            style: AnnotationStyle(strokeColor: .red, lineWidth: 7)
        )
        let manifest = CaptureManifest(
            id: UUID(), createdAt: .now, modifiedAt: .now, captureMode: .region,
            pixelWidth: 800, pixelHeight: 600, displayScale: 2
        )
        let session = CaptureSession(manifest: manifest, annotations: [annotation], ocrResults: [])
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(CaptureSession.self, from: data)
        XCTAssertEqual(decoded.manifest.schemaVersion, 1)
        XCTAssertEqual(decoded.annotations, [annotation])
    }
}
