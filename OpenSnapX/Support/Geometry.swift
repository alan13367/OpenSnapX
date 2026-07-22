import AppKit
import CoreGraphics

enum DisplayGeometry {
    struct ScreenDescriptor: Equatable, Sendable {
        let displayID: UInt32
        let frame: CGRect
        let scale: CGFloat
    }

    struct RegionSlice: Equatable, Sendable {
        let displayID: UInt32
        let screenRect: CGRect
        let sourcePixelRect: CGRect
        let destinationPixelRect: CGRect
    }

    struct RegionLayout: Equatable, Sendable {
        let selection: CGRect
        let scale: CGFloat
        let pixelSize: CGSize
        let slices: [RegionSlice]
    }

    static func pixelSize(from pointSize: CGSize, scale: CGFloat) -> CGSize {
        CGSize(
            width: (pointSize.width * scale).rounded(),
            height: (pointSize.height * scale).rounded()
        )
    }

    static func pixelRect(from screenRect: CGRect, on screen: NSScreen) -> CGRect {
        pixelRect(from: screenRect, screenFrame: screen.frame, scale: screen.backingScaleFactor)
    }

    static func appKitRect(fromQuartzRect rect: CGRect, primaryDisplayTop: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryDisplayTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )
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

    static func regionLayout(
        for screenRect: CGRect,
        screens: [ScreenDescriptor]
    ) -> RegionLayout? {
        let selection = screenRect.standardized.integral
        let intersectingScreens = screens.filter {
            !$0.frame.intersection(selection).isNull && !$0.frame.intersection(selection).isEmpty
        }
        guard selection.width > 0,
              selection.height > 0,
              !intersectingScreens.isEmpty else { return nil }

        let outputScale = intersectingScreens.map(\.scale).max() ?? 1
        let pixelSize = CGSize(
            width: (selection.width * outputScale).rounded(.up),
            height: (selection.height * outputScale).rounded(.up)
        )
        let slices = intersectingScreens.map { screen in
            let intersection = selection.intersection(screen.frame)
            let destinationMinX = ((intersection.minX - selection.minX) * outputScale).rounded(.down)
            let destinationMinY = ((intersection.minY - selection.minY) * outputScale).rounded(.down)
            let destinationMaxX = ((intersection.maxX - selection.minX) * outputScale).rounded(.up)
            let destinationMaxY = ((intersection.maxY - selection.minY) * outputScale).rounded(.up)
            return RegionSlice(
                displayID: screen.displayID,
                screenRect: intersection,
                sourcePixelRect: pixelRect(
                    from: intersection,
                    screenFrame: screen.frame,
                    scale: screen.scale
                ),
                destinationPixelRect: CGRect(
                    x: destinationMinX,
                    y: destinationMinY,
                    width: destinationMaxX - destinationMinX,
                    height: destinationMaxY - destinationMinY
                )
            )
        }
        return RegionLayout(
            selection: selection,
            scale: outputScale,
            pixelSize: pixelSize,
            slices: slices
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
