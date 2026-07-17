import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageCodec {
    static func dpi(forDisplayScale displayScale: Double) -> Double {
        72 * max(1, displayScale)
    }

    static func data(
        from image: CGImage,
        format: ExportFormat,
        quality: Double = 0.9,
        dpi: Double? = nil
    ) throws -> Data {
        let data = NSMutableData()
        let type = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw OpenSnapXError.captureFailed("Could not create an image encoder.")
        }
        CGImageDestinationAddImage(
            destination,
            image,
            encodingProperties(format: format, quality: quality, dpi: dpi) as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw OpenSnapXError.captureFailed("Could not encode the image.")
        }
        return data as Data
    }

    static func write(
        _ image: CGImage,
        to url: URL,
        format: ExportFormat,
        quality: Double = 0.9,
        dpi: Double? = nil
    ) throws {
        let type = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw OpenSnapXError.captureFailed("Could not create an image encoder.")
        }
        CGImageDestinationAddImage(
            destination,
            image,
            encodingProperties(format: format, quality: quality, dpi: dpi) as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw OpenSnapXError.captureFailed("Could not encode the image.")
        }
    }

    static func image(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OpenSnapXError.invalidHistoryEntry
        }
        return image
    }

    static func image(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else {
            throw OpenSnapXError.invalidHistoryEntry
        }
        return image
    }

    static func resized(_ image: CGImage, to pixelSize: CGSize) throws -> CGImage {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width >= 1, pixelSize.height >= 1,
              pixelSize.width <= CGFloat(Int.max), pixelSize.height <= CGFloat(Int.max) else {
            throw OpenSnapXError.captureFailed("The requested image size is invalid.")
        }
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())
        guard width != image.width || height != image.height else { return image }
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw OpenSnapXError.captureFailed("Could not resize the image.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else {
            throw OpenSnapXError.captureFailed("Could not finish resizing the image.")
        }
        return resized
    }

    static func thumbnail(from image: CGImage, maximumPixelSize: Int = 480) throws -> CGImage {
        guard maximumPixelSize > 0 else {
            throw OpenSnapXError.captureFailed("Could not create a history thumbnail.")
        }
        let largestDimension = max(image.width, image.height)
        guard largestDimension > maximumPixelSize else { return image }

        let scale = Double(maximumPixelSize) / Double(largestDimension)
        let size = CGSize(
            width: max(1, Int((Double(image.width) * scale).rounded())),
            height: max(1, Int((Double(image.height) * scale).rounded()))
        )
        return try resized(image, to: size)
    }

    private static func encodingProperties(
        format: ExportFormat,
        quality: Double,
        dpi: Double?
    ) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if let dpi, dpi.isFinite, dpi > 0 {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        return properties
    }
}

