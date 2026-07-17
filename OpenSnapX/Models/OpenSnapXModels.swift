import CoreGraphics
import Foundation

enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case region
    case window
    case display
    case scrolling
    case text

    var displayName: String {
        switch self {
        case .region: "Capture Area"
        case .window: "Capture Window"
        case .display: "Capture Display"
        case .scrolling: "Scrolling Capture"
        case .text: "Capture Text"
        }
    }
}

struct CanvasPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct CanvasRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct CaptureRequest: Codable, Sendable {
    var mode: CaptureMode
    var includeCursor = false
    var displayID: UInt32?
    var selection: CanvasRect?
    var windowID: UInt32?
}

struct ImagePayload: @unchecked Sendable {
    let image: CGImage
}

struct CaptureResult: @unchecked Sendable {
    let id: UUID
    let image: CGImage
    let mode: CaptureMode
    let createdAt: Date
    let displayScale: Double
    let sourceRect: CanvasRect?

    init(
        id: UUID = UUID(),
        image: CGImage,
        mode: CaptureMode,
        createdAt: Date = Date(),
        displayScale: Double = 1,
        sourceRect: CanvasRect? = nil
    ) {
        self.id = id
        self.image = image
        self.mode = mode
        self.createdAt = createdAt
        self.displayScale = displayScale
        self.sourceRect = sourceRect
    }
}

enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case arrow
    case line
    case rectangle
    case ellipse
    case text
    case pen
    case highlighter
    case counter
    case blur
    case pixelate
    case redact
    case crop
}

struct RGBAColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let red = RGBAColor(red: 0.96, green: 0.19, blue: 0.22, alpha: 1)
    static let yellow = RGBAColor(red: 1, green: 0.82, blue: 0.1, alpha: 0.55)
    static let black = RGBAColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
    static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
}

enum ArrowHeadStyle: String, Codable, Sendable {
    case end
    case both
    case none
}

enum RichTextAlignment: String, Codable, Hashable, Sendable {
    case left
    case center
    case right
    case justified
}

struct RichTextStyle: Codable, Hashable, Sendable {
    var fontFamily = "SF Pro"
    var fontSize: Double = 24
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var isStruckThrough = false
    var foregroundColor: RGBAColor = .red
    var backgroundColor: RGBAColor?
    var alignment: RichTextAlignment = .left
}

struct RichTextRun: Codable, Hashable, Sendable {
    /// UTF-16 offsets, matching the ranges used by NSTextStorage and Core Text.
    var location: Int
    var length: Int
    var style: RichTextStyle
}

struct RichTextDocument: Codable, Hashable, Sendable {
    var string: String
    var runs: [RichTextRun]
}

struct AnnotationStyle: Codable, Hashable, Sendable {
    var strokeColor: RGBAColor = .red
    var fillColor: RGBAColor?
    var lineWidth: Double = 5
    var opacity: Double = 1
    var fontSize: Double = 24
    var arrowHead: ArrowHeadStyle = .end
}

struct Annotation: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: AnnotationKind
    var frame: CanvasRect
    var points: [CanvasPoint] = []
    var text: String?
    var richText: RichTextDocument?
    var counter: Int?
    var style = AnnotationStyle()
}

enum BackdropAspect: String, Codable, CaseIterable, Sendable {
    case automatic
    case square
    case fourByThree
    case sixteenByNine
}

struct BackdropConfiguration: Codable, Hashable, Sendable {
    var isEnabled = false
    var padding: Double = 48
    var cornerRadius: Double = 16
    var shadowRadius: Double = 18
    var startColor = RGBAColor(red: 0.24, green: 0.32, blue: 0.82, alpha: 1)
    var endColor = RGBAColor(red: 0.72, green: 0.30, blue: 0.82, alpha: 1)
    var useGradient = true
    var aspect: BackdropAspect = .automatic
}

struct OCRResult: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var text: String
    var confidence: Float
    var normalizedBounds: CanvasRect
}

struct CaptureManifest: Codable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var id: UUID
    var createdAt: Date
    var modifiedAt: Date
    var captureMode: CaptureMode
    var pixelWidth: Int
    var pixelHeight: Int
    var displayScale: Double
    var sourceRect: CanvasRect?
    var backdrop = BackdropConfiguration()
}

struct CaptureSession: Codable, Identifiable, Sendable {
    var manifest: CaptureManifest
    var annotations: [Annotation]
    var ocrResults: [OCRResult]

    init(manifest: CaptureManifest, annotations: [Annotation], ocrResults: [OCRResult]) {
        self.manifest = manifest
        self.annotations = annotations
        self.ocrResults = ocrResults
    }

    init(captureResult result: CaptureResult) {
        manifest = CaptureManifest(
            id: result.id,
            createdAt: result.createdAt,
            modifiedAt: result.createdAt,
            captureMode: result.mode,
            pixelWidth: result.image.width,
            pixelHeight: result.image.height,
            displayScale: result.displayScale,
            sourceRect: result.sourceRect
        )
        annotations = []
        ocrResults = []
    }

    var id: UUID { manifest.id }
}

enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
}

struct ExportOptions: Codable, Sendable {
    var format: ExportFormat = .png
    var jpegQuality: Double = 0.9
    var flattenAnnotations = true
    var stripMetadata = true
    var colorSpaceName = "sRGB"
}

struct ShortcutDefinition: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }
}

enum OpenSnapXError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case selectionCancelled
    case captureFailed(String)
    case invalidHistoryEntry
    case noScrollOverlap

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Screen Recording permission is required to capture the screen."
        case .displayNotFound: "The selected display is no longer available."
        case .selectionCancelled: "Capture cancelled."
        case let .captureFailed(message): "Capture failed: \(message)"
        case .invalidHistoryEntry: "This history entry is incomplete or corrupt."
        case .noScrollOverlap: "OpenSnapX could not find a reliable overlap between scrolling frames."
        }
    }
}
