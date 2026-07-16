import CoreGraphics
import XCTest
@testable import OpenSnapX

final class OCRServiceTests: XCTestCase {
    func testVisionBoundsConvertToTopLeftCoordinates() {
        let converted = VisionOCRService.topLeftNormalizedBounds(
            fromVisionBounds: CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.25)
        )
        XCTAssertEqual(converted.minX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(converted.minY, 0.65, accuracy: 0.0001)
        XCTAssertEqual(converted.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(converted.height, 0.25, accuracy: 0.0001)
    }

    func testReadingOrderSortsRowsThenColumns() {
        let lower = OCRResult(text: "C", confidence: 1, normalizedBounds: CanvasRect(CGRect(x: 0, y: 0.5, width: 0.1, height: 0.1)))
        let upperRight = OCRResult(text: "B", confidence: 1, normalizedBounds: CanvasRect(CGRect(x: 0.5, y: 0.1, width: 0.1, height: 0.1)))
        let upperLeft = OCRResult(text: "A", confidence: 1, normalizedBounds: CanvasRect(CGRect(x: 0.1, y: 0.105, width: 0.1, height: 0.1)))
        XCTAssertEqual(VisionOCRService.readingOrder([lower, upperRight, upperLeft]).map(\.text), ["A", "B", "C"])
    }
}

