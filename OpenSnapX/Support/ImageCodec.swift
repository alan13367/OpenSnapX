import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageCodec {
    static func data(from image: CGImage, format: ExportFormat, quality: Double = 0.9) throws -> Data {
        let data = NSMutableData()
        let type = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw OpenSnapXError.captureFailed("Could not create an image encoder.")
        }
        let properties: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: quality]
            : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OpenSnapXError.captureFailed("Could not encode the image.")
        }
        return data as Data
    }

    static func image(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OpenSnapXError.invalidHistoryEntry
        }
        return image
    }

    static func image(at url: URL) throws -> CGImage {
        try image(from: Data(contentsOf: url))
    }

    static func thumbnail(from image: CGImage, maximumPixelSize: Int = 480) throws -> CGImage {
        let sourceData = try data(from: image, format: .png)
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else {
            throw OpenSnapXError.captureFailed("Could not create a history thumbnail.")
        }
        return thumbnail
    }
}

