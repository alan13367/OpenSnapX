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
