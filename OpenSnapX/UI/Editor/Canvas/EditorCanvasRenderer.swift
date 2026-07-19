import AppKit
import CoreImage

@MainActor
final class EditorCanvasRenderer {
    private let image: CGImage
    private let effectContext = CIContext(options: [.cacheIntermediates: false])
    private let effectPreviewCache = NSCache<NSString, CGImage>()

    init(image: CGImage) {
        self.image = image
    }

    func draw(
        in bounds: CGRect,
        annotations: [Annotation],
        draft: Annotation?,
        selectedID: UUID?,
        editingTextID: UUID?,
        magnification: CGFloat,
        ocrResults: [OCRResult],
        isOCRSelectionActive: Bool,
        selectedOCRIDs: Set<UUID>,
        ocrSelectionRect: CGRect?
    ) {
        drawCanvasImage(image, in: bounds)
        let visibleAnnotations = annotations + (draft.map { [$0] } ?? [])
        for annotation in visibleAnnotations where annotation.kind == .blur || annotation.kind == .pixelate {
            drawAnnotation(annotation, in: bounds, editingTextID: editingTextID, magnification: magnification)
        }
        for annotation in visibleAnnotations where annotation.kind != .blur && annotation.kind != .pixelate {
            drawAnnotation(annotation, in: bounds, editingTextID: editingTextID, magnification: magnification)
        }
        if let selectedID,
           let annotation = visibleAnnotations.first(where: { $0.id == selectedID }) {
            drawSelection(for: annotation, magnification: magnification)
        }
        drawOCR(
            results: ocrResults,
            in: bounds,
            isActive: isOCRSelectionActive,
            selectedIDs: selectedOCRIDs,
            selectionRect: ocrSelectionRect
        )
    }

    private func drawAnnotation(
        _ annotation: Annotation,
        in bounds: CGRect,
        editingTextID: UUID?,
        magnification: CGFloat
    ) {
        let frame = annotation.frame.cgRect
        let color = annotation.style.strokeColor.nsColor.withAlphaComponent(annotation.style.opacity)
        color.setStroke()
        (annotation.style.fillColor?.nsColor ?? .clear).setFill()
        let path = NSBezierPath()
        path.lineWidth = annotation.style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch annotation.kind {
        case .arrow, .line:
            let start = annotation.points.first?.cgPoint ?? frame.origin
            let end = annotation.points.last?.cgPoint ?? CGPoint(x: frame.maxX, y: frame.maxY)
            path.move(to: start)
            path.line(to: end)
            path.stroke()
            if annotation.kind == .arrow, annotation.style.arrowHead != .none {
                drawArrow(from: start, to: end, style: annotation.style)
                if annotation.style.arrowHead == .both {
                    drawArrow(from: end, to: start, style: annotation.style)
                }
            }
        case .rectangle, .redact, .blur, .pixelate, .crop:
            let rectPath = NSBezierPath(rect: frame)
            rectPath.lineWidth = annotation.style.lineWidth
            rectPath.lineJoinStyle = .round
            if annotation.kind == .redact {
                (annotation.style.fillColor?.nsColor ?? .black).setFill()
                rectPath.fill()
            } else if annotation.kind == .blur || annotation.kind == .pixelate {
                if let preview = effectPreviewImage(kind: annotation.kind) {
                    drawCanvasImage(preview, in: bounds, clippedTo: frame)
                }
                NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
                let dash: [CGFloat] = [6, 3]
                rectPath.lineWidth = 1.5
                rectPath.setLineDash(dash, count: dash.count, phase: 0)
                rectPath.stroke()
            } else if annotation.kind == .crop {
                let dash = [overlayMetric(8, magnification: magnification), overlayMetric(4, magnification: magnification)]
                rectPath.lineWidth = overlayMetric(1.5, magnification: magnification)
                rectPath.setLineDash(dash, count: dash.count, phase: 0)
                rectPath.stroke()
            } else {
                if annotation.style.fillColor != nil { rectPath.fill() }
                rectPath.stroke()
            }
        case .ellipse:
            let ellipse = NSBezierPath(ovalIn: frame)
            ellipse.lineWidth = annotation.style.lineWidth
            if annotation.style.fillColor != nil { ellipse.fill() }
            ellipse.stroke()
        case .pen, .highlighter:
            guard let first = annotation.points.first else { break }
            if annotation.kind == .highlighter {
                annotation.style.strokeColor.nsColor.withAlphaComponent(0.38).setStroke()
            }
            path.move(to: first.cgPoint)
            for point in annotation.points.dropFirst() { path.line(to: point.cgPoint) }
            path.stroke()
        case .text:
            if annotation.id != editingTextID {
                RichTextBridge.attributedString(for: annotation).draw(
                    with: frame.insetBy(dx: 2, dy: 2),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
            }
        case .counter:
            color.setFill()
            NSBezierPath(ovalIn: frame).fill()
            let value = String(annotation.counter ?? 1)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: annotation.style.fontSize, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let size = value.size(withAttributes: attributes)
            value.draw(
                at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, style: AnnotationStyle) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(14, style.lineWidth * 4)
        let spread = CGFloat.pi / 7
        let head = NSBezierPath()
        head.lineWidth = style.lineWidth
        head.move(to: end)
        head.line(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
        head.move(to: end)
        head.line(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
        head.stroke()
    }

    private func drawSelection(for annotation: Annotation, magnification: CGFloat) {
        if annotation.kind == .line || annotation.kind == .arrow,
           let start = annotation.points.first?.cgPoint,
           let end = annotation.points.last?.cgPoint {
            drawSelectionHandle(at: start, magnification: magnification)
            drawSelectionHandle(at: end, magnification: magnification)
            return
        }
        let frame = AnnotationCanvasGeometry.selectionFrame(
            for: annotation,
            overlayPadding: overlayMetric(5, magnification: magnification)
        )
        drawSelectionOutline(in: frame, magnification: magnification)
        for hitArea in AnnotationCanvasGeometry.resizeHandles(
            for: frame,
            size: overlayMetric(20, magnification: magnification)
        ) {
            drawResizeHandle(in: visualResizeHandle(for: hitArea, magnification: magnification), magnification: magnification)
        }
    }

    private func drawOCR(
        results: [OCRResult],
        in bounds: CGRect,
        isActive: Bool,
        selectedIDs: Set<UUID>,
        selectionRect: CGRect?
    ) {
        guard isActive, !results.isEmpty else { return }
        for result in results {
            let frame = AnnotationCanvasGeometry.ocrFrame(for: result, in: bounds)
            let path = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
            if selectedIDs.contains(result.id) {
                NSColor.systemCyan.withAlphaComponent(0.20).setFill()
                path.fill()
            }
            NSColor.systemCyan.withAlphaComponent(0.9).setStroke()
            path.lineWidth = selectedIDs.contains(result.id) ? 2.5 : 1.5
            path.stroke()
        }
        if let selectionRect, selectionRect.width > 1 || selectionRect.height > 1 {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSColor.controlAccentColor.setStroke()
            let marquee = NSBezierPath(rect: selectionRect)
            marquee.lineWidth = 1
            marquee.fill()
            marquee.stroke()
        }
    }

    private func drawCanvasImage(_ canvasImage: CGImage, in bounds: CGRect, clippedTo clipRect: CGRect? = nil) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if let clipRect { context.clip(to: clipRect) }
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(canvasImage, in: bounds)
        context.restoreGState()
    }

    private func effectPreviewImage(kind: AnnotationKind) -> CGImage? {
        let key = kind.rawValue as NSString
        if let cached = effectPreviewCache.object(forKey: key) { return cached }
        guard let preview = makeEffectPreview(kind: kind) else { return nil }
        effectPreviewCache.setObject(preview, forKey: key, cost: preview.bytesPerRow * preview.height)
        return preview
    }

    private func makeEffectPreview(kind: AnnotationKind) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output: CIImage
        switch kind {
        case .blur:
            output = input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12])
                .cropped(to: input.extent)
        case .pixelate:
            output = input
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 14])
                .cropped(to: input.extent)
        default:
            return nil
        }
        return effectContext.createCGImage(output, from: input.extent)
    }

    private func drawSelectionHandle(at point: CGPoint, magnification: CGFloat) {
        let size = overlayMetric(12, magnification: magnification)
        let frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        drawHandlePath(NSBezierPath(ovalIn: frame), magnification: magnification)
    }

    private func drawSelectionOutline(in frame: CGRect, magnification: CGFloat) {
        let path = NSBezierPath(rect: frame)
        path.lineJoinStyle = .round
        NSColor.black.withAlphaComponent(0.72).setStroke()
        path.lineWidth = overlayMetric(5, magnification: magnification)
        path.stroke()
        NSColor.white.withAlphaComponent(0.96).setStroke()
        path.lineWidth = overlayMetric(3, magnification: magnification)
        path.stroke()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = overlayMetric(1.5, magnification: magnification)
        path.stroke()
    }

    private func drawResizeHandle(in frame: CGRect, magnification: CGFloat) {
        let radius = overlayMetric(3, magnification: magnification)
        drawHandlePath(NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius), magnification: magnification)
    }

    private func drawHandlePath(_ path: NSBezierPath, magnification: CGFloat) {
        NSColor.controlAccentColor.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.78).setStroke()
        path.lineWidth = overlayMetric(4, magnification: magnification)
        path.stroke()
        NSColor.white.setStroke()
        path.lineWidth = overlayMetric(2, magnification: magnification)
        path.stroke()
    }

    private func visualResizeHandle(for hitArea: CGRect, magnification: CGFloat) -> CGRect {
        let size = overlayMetric(12, magnification: magnification)
        return CGRect(x: hitArea.midX - size / 2, y: hitArea.midY - size / 2, width: size, height: size)
    }

    private func overlayMetric(_ screenPoints: CGFloat, magnification: CGFloat) -> CGFloat {
        screenPoints / max(magnification, 0.01)
    }
}
