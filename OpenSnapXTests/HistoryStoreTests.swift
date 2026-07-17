import AppKit
import CoreGraphics
import XCTest
@testable import OpenSnapX

final class HistoryStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateLoadUpdateAndDelete() async throws {
        let store = LocalHistoryStore(rootURL: root)
        let result = CaptureResult(image: try solidImage(width: 32, height: 24), mode: .region, displayScale: 2)
        var session = try await store.create(from: result)
        session.annotations.append(Annotation(kind: .redact, frame: CanvasRect(CGRect(x: 2, y: 2, width: 8, height: 8))))
        try await store.save(session)
        let (loaded, image) = try await store.load(id: result.id)
        let thumbnail = try await store.thumbnail(id: result.id).image
        XCTAssertEqual(loaded.annotations.count, 1)
        XCTAssertEqual(image.image.width, 32)
        XCTAssertGreaterThan(darkPixelCount(in: thumbnail), 40)
        let beforeDelete = await store.list()
        XCTAssertEqual(beforeDelete.count, 1)
        try await store.delete(id: result.id)
        let afterDelete = await store.list()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testThumbnailPreservesAspectRatioWithinMaximumSize() throws {
        let thumbnail = try ImageCodec.thumbnail(from: solidImage(width: 1_200, height: 800), maximumPixelSize: 480)
        XCTAssertEqual(thumbnail.width, 480)
        XCTAssertEqual(thumbnail.height, 320)
    }

    func testCleanupExpiresOldSessionsAndIgnoresCorruptEntries() async throws {
        let store = LocalHistoryStore(rootURL: root)
        let old = CaptureResult(image: try solidImage(width: 8, height: 8), mode: .display, createdAt: Date(timeIntervalSinceNow: -10 * 86_400))
        _ = try await store.create(from: old)
        let corrupt = root.appendingPathComponent("corrupt.opensnapx", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("manifest.json"))
        await store.cleanup(retentionDays: 7)
        let remaining = await store.list()
        XCTAssertTrue(remaining.isEmpty)
    }
}

private func darkPixelCount(in image: CGImage) -> Int {
    let bitmap = NSBitmapImageRep(cgImage: image)
    var count = 0
    for y in 0..<image.height {
        for x in 0..<image.width {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.redComponent < 0.2, color.greenComponent < 0.2, color.blueComponent < 0.2 {
                count += 1
            }
        }
    }
    return count
}

func solidImage(width: Int, height: Int, color: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)) throws -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}
