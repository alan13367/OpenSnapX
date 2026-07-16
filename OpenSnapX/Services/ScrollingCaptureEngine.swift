import Accelerate
import CoreGraphics
import Foundation

struct ScrollStitchMatch: Sendable {
    let overlapRows: Int
    let score: Float
}

protocol ScrollingCaptureEngine: Sendable {
    func stitch(_ frames: [ImagePayload]) throws -> ImagePayload
    func match(previous: ImagePayload, next: ImagePayload) throws -> ScrollStitchMatch
}

struct AccelerateScrollingCaptureEngine: ScrollingCaptureEngine {
    var minimumOverlapFraction: Double = 0.12
    var maximumOverlapFraction: Double = 0.82
    var maximumMeanSquaredError: Float = 650

    func stitch(_ frames: [ImagePayload]) throws -> ImagePayload {
        guard let first = frames.first else { throw OpenSnapXError.noScrollOverlap }
        guard frames.count > 1 else { return first }
        var matches: [ScrollStitchMatch] = []
        for pair in zip(frames, frames.dropFirst()) {
            matches.append(try match(previous: pair.0, next: pair.1))
        }
        let width = frames.map { $0.image.width }.min() ?? first.image.width
        let totalHeight = first.image.height + zip(frames.dropFirst(), matches).reduce(0) { partial, item in
            partial + item.0.image.height - item.1.overlapRows
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: totalHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw OpenSnapXError.captureFailed("Could not create the scrolling canvas.") }

        var top = totalHeight
        for (index, frame) in frames.enumerated() {
            let overlap = index == 0 ? 0 : matches[index - 1].overlapRows
            let sourceHeight = frame.image.height - overlap
            guard sourceHeight > 0,
                  let slice = frame.image.cropping(to: CGRect(x: 0, y: 0, width: width, height: sourceHeight)) else { continue }
            top -= sourceHeight
            context.draw(slice, in: CGRect(x: 0, y: top, width: width, height: sourceHeight))
        }
        guard let image = context.makeImage() else { throw OpenSnapXError.captureFailed("Could not finish the scrolling image.") }
        return ImagePayload(image: image)
    }

    func match(previous: ImagePayload, next: ImagePayload) throws -> ScrollStitchMatch {
        let width = min(previous.image.width, next.image.width)
        let height = min(previous.image.height, next.image.height)
        guard width > 16, height > 40 else { throw OpenSnapXError.noScrollOverlap }
        let sampleWidth = min(width, 256)
        let previousGray = try grayscale(previous.image, width: sampleWidth, height: height)
        let nextGray = try grayscale(next.image, width: sampleWidth, height: height)
        let minimum = max(24, Int(Double(height) * minimumOverlapFraction))
        let maximum = min(height - 12, Int(Double(height) * maximumOverlapFraction))
        let headerInset = min(48, height / 10)
        var best: ScrollStitchMatch?

        for overlap in stride(from: minimum, through: maximum, by: max(2, height / 240)) {
            let comparableRows = max(8, overlap - headerInset)
            let previousStart = (height - comparableRows) * sampleWidth
            let nextStart = headerInset * sampleWidth
            let count = comparableRows * sampleWidth
            guard previousStart + count <= previousGray.count, nextStart + count <= nextGray.count else { continue }
            let lhs = Array(previousGray[previousStart..<(previousStart + count)])
            let rhs = Array(nextGray[nextStart..<(nextStart + count)])
            let differences = vDSP.subtract(lhs, rhs)
            let mse = vDSP.meanSquare(differences)
            if best == nil || mse < best!.score {
                best = ScrollStitchMatch(overlapRows: overlap, score: mse)
            }
        }
        guard let best, best.score <= maximumMeanSquaredError else { throw OpenSnapXError.noScrollOverlap }
        return best
    }

    private func grayscale(_ image: CGImage, width: Int, height: Int) throws -> [Float] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { throw OpenSnapXError.noScrollOverlap }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return vDSP.integerToFloatingPoint(bytes, floatingPointType: Float.self)
    }
}
