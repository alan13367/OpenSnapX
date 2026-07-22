import CoreGraphics
import XCTest
@testable import OpenSnapX

final class ScrollingCaptureEngineTests: XCTestCase {
    func testFindsOverlapAndRestoresSyntheticLongImage() throws {
        let long = try stripedImage(width: 96, height: 400)
        let first = long.cropping(to: CGRect(x: 0, y: 0, width: 96, height: 240))!
        let second = long.cropping(to: CGRect(x: 0, y: 160, width: 96, height: 240))!
        let engine = AccelerateScrollingCaptureEngine(maximumMeanSquaredError: 1)
        let match = try engine.match(previous: ImagePayload(image: first), next: ImagePayload(image: second))
        XCTAssertLessThanOrEqual(abs(match.overlapRows - 80), 2)
        let stitched = try engine.stitch([ImagePayload(image: first), ImagePayload(image: second)])
        XCTAssertEqual(stitched.image.width, 96)
        XCTAssertEqual(stitched.image.height, 400)
        XCTAssertEqual(try rgbaBytes(stitched.image), try rgbaBytes(long))
    }

    func testRejectsFramesWithoutReliableOverlap() throws {
        let white = try solidImage(width: 80, height: 160)
        let black = try solidImage(width: 80, height: 160, color: CGColor(gray: 0, alpha: 1))
        let engine = AccelerateScrollingCaptureEngine(maximumMeanSquaredError: 1)
        XCTAssertThrowsError(try engine.match(previous: ImagePayload(image: white), next: ImagePayload(image: black)))
    }

    func testCaptureBudgetRejectsFrameBeforeCombinedWorkingSetExceedsLimit() {
        var budget = ScrollingCaptureBudget(maximumWorkingBytes: 200)

        XCTAssertTrue(budget.reserveFrame(width: 4, height: 4, bytesPerRow: 16, overlapRows: 0))
        XCTAssertFalse(budget.reserveFrame(width: 4, height: 4, bytesPerRow: 16, overlapRows: 2))
        XCTAssertEqual(budget.retainedImageBytes, 64)
        XCTAssertEqual(budget.outputHeight, 4)
    }

    private func stripedImage(width: Int, height: Int) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for row in 0..<height {
            let value = CGFloat((row * 37) % 255) / 255
            context.setFillColor(CGColor(red: value, green: 1 - value, blue: CGFloat(row % 83) / 83, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: width, height: 1))
        }
        return context.makeImage()!
    }
}

private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
    let bytesPerRow = image.width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: &bytes,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw OpenSnapXError.captureFailed("Could not inspect scrolling test pixels.")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}
