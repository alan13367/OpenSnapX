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
