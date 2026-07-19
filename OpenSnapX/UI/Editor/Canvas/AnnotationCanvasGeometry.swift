import AppKit

enum AnnotationDragOperation: Equatable {
    case move
    case startPoint
    case endPoint
    case resizeTopLeft
    case resizeTopRight
    case resizeBottomLeft
    case resizeBottomRight
    case resizeTop
    case resizeBottom
    case resizeLeft
    case resizeRight
}

struct AnnotationCanvasGeometry {
    static func translated(_ annotation: Annotation, by delta: CGPoint) -> Annotation {
        var translated = annotation
        translated.frame = CanvasRect(annotation.frame.cgRect.offsetBy(dx: delta.x, dy: delta.y))
        translated.points = movedPoints(annotation.points, by: delta)
        return translated
    }

    static func movedPoints(_ points: [CanvasPoint], by delta: CGPoint) -> [CanvasPoint] {
        points.map { CanvasPoint(CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)) }
    }

    static func resizedPoints(_ points: [CanvasPoint], from oldFrame: CGRect, to newFrame: CGRect) -> [CanvasPoint] {
        points.map { point in
            let xFraction = oldFrame.width == 0 ? 0 : (point.x - oldFrame.minX) / oldFrame.width
            let yFraction = oldFrame.height == 0 ? 0 : (point.y - oldFrame.minY) / oldFrame.height
            return CanvasPoint(CGPoint(
                x: newFrame.minX + xFraction * newFrame.width,
                y: newFrame.minY + yFraction * newFrame.height
            ))
        }
    }

    static func frame(containing points: [CanvasPoint], fallback: CGRect) -> CGRect {
        guard let first = points.first else { return fallback }
        return points.dropFirst().reduce(CGRect(x: first.x, y: first.y, width: 0, height: 0)) { frame, point in
            frame.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
        }
    }

    static func geometryFrame(for annotation: Annotation) -> CGRect {
        switch annotation.kind {
        case .pen, .highlighter:
            frame(containing: annotation.points, fallback: annotation.frame.cgRect)
        default:
            annotation.frame.cgRect
        }
    }

    static func resizedFontSize(_ fontSize: Double, from oldFrame: CGRect, to newFrame: CGRect) -> Double {
        let oldDiameter = min(oldFrame.width, oldFrame.height)
        let newDiameter = min(newFrame.width, newFrame.height)
        guard oldDiameter > 0 else { return fontSize }
        return max(1, fontSize * newDiameter / oldDiameter)
    }

    static func resizedFrame(
        _ frame: CGRect,
        for operation: AnnotationDragOperation,
        by delta: CGPoint,
        minimumSize: CGFloat = 4
    ) -> CGRect {
        var left = frame.minX
        var right = frame.maxX
        var top = frame.minY
        var bottom = frame.maxY
        switch operation {
        case .resizeTopLeft, .resizeBottomLeft, .resizeLeft:
            left = min(frame.maxX - minimumSize, frame.minX + delta.x)
        case .resizeTopRight, .resizeBottomRight, .resizeRight:
            right = max(frame.minX + minimumSize, frame.maxX + delta.x)
        case .move, .startPoint, .endPoint, .resizeTop, .resizeBottom:
            break
        }
        switch operation {
        case .resizeTopLeft, .resizeTopRight, .resizeTop:
            top = min(frame.maxY - minimumSize, frame.minY + delta.y)
        case .resizeBottomLeft, .resizeBottomRight, .resizeBottom:
            bottom = max(frame.minY + minimumSize, frame.maxY + delta.y)
        case .move, .startPoint, .endPoint, .resizeLeft, .resizeRight:
            break
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func selectionFrame(for annotation: Annotation, overlayPadding: CGFloat) -> CGRect {
        let usesStroke = EditorTool(rawValue: annotation.kind.rawValue)?.usesStrokeWidth == true
        let outset = usesStroke ? annotation.style.lineWidth / 2 + overlayPadding : overlayPadding
        return geometryFrame(for: annotation).insetBy(dx: -outset, dy: -outset)
    }

    static func resizeHandles(for frame: CGRect, size: CGFloat) -> [CGRect] {
        let half = size / 2
        let centers = [
            CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY),
            CGPoint(x: frame.midX, y: frame.minY), CGPoint(x: frame.midX, y: frame.maxY),
            CGPoint(x: frame.minX, y: frame.midY), CGPoint(x: frame.maxX, y: frame.midY)
        ]
        return centers.map { CGRect(x: $0.x - half, y: $0.y - half, width: size, height: size) }
    }

    static func selectionHandle(at point: CGPoint, size: CGFloat) -> CGRect {
        CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    static func annotation(at point: CGPoint, in annotations: [Annotation]) -> Annotation? {
        annotations.reversed().first { annotation in
            if annotation.kind == .line || annotation.kind == .arrow,
               let start = annotation.points.first?.cgPoint,
               let end = annotation.points.last?.cgPoint {
                return distance(from: point, toSegmentFrom: start, to: end)
                    <= max(8, annotation.style.lineWidth + 4)
            }
            return geometryFrame(for: annotation).insetBy(dx: -5, dy: -5).contains(point)
        }
    }

    static func dragOperation(
        for annotation: Annotation,
        at point: CGPoint,
        selectionPadding: CGFloat,
        handleSize: CGFloat
    ) -> AnnotationDragOperation? {
        if annotation.kind == .line || annotation.kind == .arrow,
           let start = annotation.points.first?.cgPoint,
           let end = annotation.points.last?.cgPoint {
            if selectionHandle(at: start, size: handleSize).contains(point) { return .startPoint }
            if selectionHandle(at: end, size: handleSize).contains(point) { return .endPoint }
            if distance(from: point, toSegmentFrom: start, to: end) <= max(8, annotation.style.lineWidth + 4) {
                return .move
            }
            return nil
        }
        let handles = resizeHandles(
            for: selectionFrame(for: annotation, overlayPadding: selectionPadding),
            size: handleSize
        )
        for (index, handle) in handles.prefix(4).enumerated() where handle.contains(point) {
            return [.resizeTopLeft, .resizeTopRight, .resizeBottomLeft, .resizeBottomRight][index]
        }
        for (index, handle) in handles.dropFirst(4).enumerated() where handle.contains(point) {
            return [.resizeTop, .resizeBottom, .resizeLeft, .resizeRight][index]
        }
        return geometryFrame(for: annotation).insetBy(dx: -5, dy: -5).contains(point) ? .move : nil
    }

    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(0, point.x), bounds.maxX), y: min(max(0, point.y), bounds.maxY))
    }

    static func ocrFrame(for result: OCRResult, in bounds: CGRect) -> CGRect {
        let normalized = result.normalizedBounds.cgRect
        return CGRect(
            x: normalized.minX * bounds.width,
            y: normalized.minY * bounds.height,
            width: normalized.width * bounds.width,
            height: normalized.height * bounds.height
        )
    }

    static func ocrResult(at point: CGPoint, in results: [OCRResult], bounds: CGRect) -> OCRResult? {
        results.first { ocrFrame(for: $0, in: bounds).insetBy(dx: -2, dy: -2).contains(point) }
    }

    static func defaultCounterFrame(centeredAt center: CGPoint, annotation: Annotation) -> CGRect {
        let font = NSFont.systemFont(ofSize: annotation.style.fontSize, weight: .bold)
        let textSize = String(annotation.counter ?? 1).size(withAttributes: [.font: font])
        let diameter = ceil(max(32, textSize.width + 12, textSize.height + 8))
        return CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    static func counterFrameEnsuringTextFits(_ annotation: Annotation) -> CGRect {
        let required = defaultCounterFrame(centeredAt: .zero, annotation: annotation).width
        let frame = annotation.frame.cgRect
        guard frame.width < required || frame.height < required else { return frame }
        let width = max(frame.width, required)
        let height = max(frame.height, required)
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let closest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }
}
