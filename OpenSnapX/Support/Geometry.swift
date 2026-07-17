import AppKit
import CoreGraphics

enum DisplayGeometry {
    static func pixelSize(from pointSize: CGSize, scale: CGFloat) -> CGSize {
        CGSize(
            width: (pointSize.width * scale).rounded(),
            height: (pointSize.height * scale).rounded()
        )
    }

    static func pixelRect(from screenRect: CGRect, on screen: NSScreen) -> CGRect {
        pixelRect(from: screenRect, screenFrame: screen.frame, scale: screen.backingScaleFactor)
    }

    static func pixelRect(from screenRect: CGRect, screenFrame: CGRect, scale: CGFloat) -> CGRect {
        let localX = screenRect.minX - screenFrame.minX
        let localYFromBottom = screenRect.minY - screenFrame.minY
        let flippedY = screenFrame.height - localYFromBottom - screenRect.height
        return CGRect(
            x: (localX * scale).rounded(.down),
            y: (flippedY * scale).rounded(.down),
            width: (screenRect.width * scale).rounded(.up),
            height: (screenRect.height * scale).rounded(.up)
        )
    }

    static func screen(containing point: CGPoint, screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

enum ImageResizeGeometry {
    static func scaledAnnotations(
        _ annotations: [Annotation],
        from sourceSize: CGSize,
        to targetSize: CGSize
    ) -> [Annotation] {
        guard sourceSize.width > 0, sourceSize.height > 0,
              targetSize.width > 0, targetSize.height > 0 else { return annotations }
        let scaleX = targetSize.width / sourceSize.width
        let scaleY = targetSize.height / sourceSize.height
        let strokeScale = sqrt(scaleX * scaleY)

        return annotations.map { annotation in
            var result = annotation
            let frame = annotation.frame.cgRect
            result.frame = CanvasRect(CGRect(
                x: frame.minX * scaleX,
                y: frame.minY * scaleY,
                width: frame.width * scaleX,
                height: frame.height * scaleY
            ))
            result.points = annotation.points.map { point in
                CanvasPoint(CGPoint(
                    x: point.x * Double(scaleX),
                    y: point.y * Double(scaleY)
                ))
            }
            result.style.lineWidth *= Double(strokeScale)
            result.style.fontSize *= Double(scaleY)
            if var document = result.richText {
                document.runs = document.runs.map { run in
                    var scaledRun = run
                    scaledRun.style.fontSize *= Double(scaleY)
                    return scaledRun
                }
                result.richText = document
            }
            return result
        }
    }
}

extension CGRect {
    var standardizedPositive: CGRect {
        CGRect(
            x: minX,
            y: minY,
            width: abs(width),
            height: abs(height)
        ).standardized
    }
}
