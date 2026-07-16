@preconcurrency import ScreenCaptureKit
import AppKit
import CoreGraphics
import CoreImage
import Foundation

struct WindowCandidate: @unchecked Sendable {
    let id: UInt32
    let title: String
    let applicationName: String
    let frame: CGRect
    let window: SCWindow
}

protocol CaptureService: Sendable {
    func capture(_ request: CaptureRequest) async throws -> CaptureResult
    func availableWindows() async throws -> [WindowCandidate]
}

final class ScreenCaptureService: CaptureService, @unchecked Sendable {
    func capture(_ request: CaptureRequest) async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else { throw OpenSnapXError.permissionDenied }

        if request.delaySeconds > 0 {
            try await Task.sleep(for: .seconds(request.delaySeconds))
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownWindowIDs = Set(content.windows.compactMap { window -> CGWindowID? in
            window.owningApplication?.bundleIdentifier == ownBundleID ? window.windowID : nil
        })
        let excludedWindows = content.windows.filter { ownWindowIDs.contains($0.windowID) }

        switch request.mode {
        case .window:
            guard let windowID = request.windowID,
                  let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw OpenSnapXError.captureFailed("The selected window disappeared.")
            }
            let windowScale = NSScreen.screens.first(where: { $0.frame.intersects(appKitFrame(for: window.frame)) })?.backingScaleFactor ?? 2
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = makeConfiguration(
                width: max(1, Int(window.frame.width * windowScale)),
                height: max(1, Int(window.frame.height * windowScale)),
                includeCursor: request.includeCursor
            )
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return CaptureResult(image: normalizedSRGB(image), mode: request.mode, displayScale: windowScale)

        case .region, .text, .scrolling, .display:
            guard let display = resolveDisplay(request.displayID, in: content.displays) else {
                throw OpenSnapXError.displayNotFound
            }
            let displayScale = scale(for: display)
            let captureSize = DisplayGeometry.pixelSize(
                from: CGSize(width: display.width, height: display.height),
                scale: displayScale
            )
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let configuration = makeConfiguration(
                width: max(1, Int(captureSize.width)),
                height: max(1, Int(captureSize.height)),
                includeCursor: request.includeCursor
            )
            let fullImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard request.mode != .display, let selection = request.selection?.cgRect else {
                return CaptureResult(image: normalizedSRGB(fullImage), mode: request.mode, displayScale: displayScale)
            }

            let imageBounds = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
            let cropRect = selection.standardized.integral
            guard cropRect.width > 0,
                  cropRect.height > 0,
                  imageBounds.contains(cropRect),
                  let cropped = fullImage.cropping(to: cropRect) else {
                throw OpenSnapXError.captureFailed("The selected area is outside the display.")
            }
            return CaptureResult(
                image: normalizedSRGB(cropped),
                mode: request.mode,
                displayScale: displayScale,
                sourceRect: CanvasRect(cropRect)
            )
        }
    }

    func availableWindows() async throws -> [WindowCandidate] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? 0

        return content.windows.compactMap { window in
            guard window.frame.width >= 40,
                  window.frame.height >= 40,
                  window.owningApplication?.bundleIdentifier != ownBundleID else { return nil }
            let appKitFrame = CGRect(
                x: window.frame.minX,
                y: desktopTop - window.frame.maxY,
                width: window.frame.width,
                height: window.frame.height
            )
            return WindowCandidate(
                id: window.windowID,
                title: window.title ?? "Window",
                applicationName: window.owningApplication?.applicationName ?? "Application",
                frame: appKitFrame,
                window: window
            )
        }
    }

    private func resolveDisplay(_ requestedID: UInt32?, in displays: [SCDisplay]) -> SCDisplay? {
        if let requestedID {
            return displays.first { $0.displayID == requestedID }
        }
        let point = NSEvent.mouseLocation
        guard let screen = DisplayGeometry.screen(containing: point),
              let displayID = DisplayGeometry.displayID(for: screen) else {
            return displays.first
        }
        return displays.first { $0.displayID == displayID }
    }

    private func appKitFrame(for screenCaptureFrame: CGRect) -> CGRect {
        let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        return CGRect(
            x: screenCaptureFrame.minX,
            y: desktopTop - screenCaptureFrame.maxY,
            width: screenCaptureFrame.width,
            height: screenCaptureFrame.height
        )
    }

    private func scale(for display: SCDisplay) -> Double {
        guard let screen = NSScreen.screens.first(where: { DisplayGeometry.displayID(for: $0) == display.displayID }) else { return 1 }
        return screen.backingScaleFactor
    }

    private func makeConfiguration(width: Int, height: Int, includeCursor: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = includeCursor
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }

    private func normalizedSRGB(_ image: CGImage) -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
