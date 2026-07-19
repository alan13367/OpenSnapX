import AppKit

@MainActor
final class BackdropPreviewView: NSView {
    private let image: NSImage
    private let imagePixelSize: CGSize
    var configuration: BackdropConfiguration { didSet { needsDisplay = true } }

    init(image: CGImage, imagePixelSize: CGSize, configuration: BackdropConfiguration) {
        self.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        self.imagePixelSize = imagePixelSize
        self.configuration = configuration
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        setAccessibilityRole(.image)
        setAccessibilityLabel("Backdrop export preview")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        let available = bounds.insetBy(dx: 14, dy: 14)
        guard configuration.isEnabled else {
            let imageRect = fittedRect(
                aspect: imagePixelSize.width / imagePixelSize.height,
                inside: available.insetBy(dx: 28, dy: 8)
            )
            image.draw(in: imageRect)
            return
        }

        let sourceWidth = imagePixelSize.width
        let sourceHeight = imagePixelSize.height
        let padding = CGFloat(configuration.padding)
        var canvasSize = CGSize(width: sourceWidth + padding * 2, height: sourceHeight + padding * 2)
        switch configuration.aspect {
        case .automatic: break
        case .square: canvasSize = fittedCanvas(content: canvasSize, aspect: 1)
        case .fourByThree: canvasSize = fittedCanvas(content: canvasSize, aspect: 4.0 / 3.0)
        case .sixteenByNine: canvasSize = fittedCanvas(content: canvasSize, aspect: 16.0 / 9.0)
        }
        let canvasRect = fittedRect(aspect: canvasSize.width / canvasSize.height, inside: available)
        let canvasPath = NSBezierPath(roundedRect: canvasRect, xRadius: 6, yRadius: 6)
        if configuration.useGradient {
            NSGradient(starting: configuration.startColor.nsColor, ending: configuration.endColor.nsColor)?.draw(in: canvasPath, angle: -45)
        } else {
            configuration.startColor.nsColor.setFill()
            canvasPath.fill()
        }

        let scale = min(canvasRect.width / canvasSize.width, canvasRect.height / canvasSize.height)
        let imageRect = CGRect(
            x: canvasRect.midX - sourceWidth * scale / 2,
            y: canvasRect.midY - sourceHeight * scale / 2,
            width: sourceWidth * scale,
            height: sourceHeight * scale
        )
        let cornerRadius = CGFloat(configuration.cornerRadius) * scale
        let imagePath = NSBezierPath(roundedRect: imageRect, xRadius: cornerRadius, yRadius: cornerRadius)
        if configuration.shadowRadius > 0 {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = min(18, CGFloat(configuration.shadowRadius) * scale)
            shadow.shadowOffset = CGSize(width: 0, height: -3)
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            imagePath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        imagePath.addClip()
        image.draw(in: imageRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func fittedRect(aspect: CGFloat, inside rect: CGRect) -> CGRect {
        if rect.width / rect.height > aspect {
            let width = rect.height * aspect
            return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        }
        let height = rect.width / aspect
        return CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }

    private func fittedCanvas(content: CGSize, aspect: CGFloat) -> CGSize {
        if content.width / content.height > aspect {
            return CGSize(width: content.width, height: content.width / aspect)
        }
        return CGSize(width: content.height * aspect, height: content.height)
    }
}
