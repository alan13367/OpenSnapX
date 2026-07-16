@preconcurrency import Vision
import CoreGraphics
import Foundation

protocol OCRService: Sendable {
    func recognize(_ image: ImagePayload) async throws -> [OCRResult]
}

struct VisionOCRService: OCRService {
    func recognize(_ image: ImagePayload) async throws -> [OCRResult] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: image.image, orientation: .up)
            try handler.perform([request])
            let results = (request.results ?? []).compactMap { observation -> OCRResult? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let topLeftBounds = Self.topLeftNormalizedBounds(fromVisionBounds: observation.boundingBox)
                return OCRResult(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    normalizedBounds: CanvasRect(topLeftBounds)
                )
            }
            return Self.readingOrder(results)
        }.value
    }

    static func topLeftNormalizedBounds(fromVisionBounds bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: 1 - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
    }

    static func readingOrder(_ results: [OCRResult]) -> [OCRResult] {
        results.sorted {
                let lhs = $0.normalizedBounds.cgRect
                let rhs = $1.normalizedBounds.cgRect
                if abs(lhs.minY - rhs.minY) > 0.015 { return lhs.minY < rhs.minY }
                return lhs.minX < rhs.minX
            }
    }
}
