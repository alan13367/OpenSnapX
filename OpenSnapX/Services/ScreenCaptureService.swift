@preconcurrency import ScreenCaptureKit
import AppKit
import CoreGraphics
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
    func captureDisplays(_ displayIDs: [UInt32]) async throws -> [UInt32: CaptureResult]
    func availableWindows() async throws -> [WindowCandidate]
}

extension CaptureService {
    func captureDisplays(_ displayIDs: [UInt32]) async throws -> [UInt32: CaptureResult] {
        var captures: [UInt32: CaptureResult] = [:]
        captures.reserveCapacity(displayIDs.count)
        for displayID in displayIDs {
            captures[displayID] = try await capture(CaptureRequest(
                mode: .display,
                includeCursor: false,
                displayID: displayID
            ))
        }
        return captures
    }
}

final class ScreenCaptureService: CaptureService, @unchecked Sendable {
    func capture(_ request: CaptureRequest) async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else { throw OpenSnapXError.permissionDenied }

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
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let fallbackScale = NSScreen.screens.first {
                $0.frame.intersects(appKitFrame(for: window.frame))
            }?.backingScaleFactor ?? 2
            let windowScale = filter.pointPixelScale > 0
                ? max(1, Double(filter.pointPixelScale))
                : max(1, Double(fallbackScale))
            let captureSize = capturePixelSize(
                for: filter,
                fallbackPointSize: window.frame.size,
                fallbackScale: fallbackScale
            )
            let configuration = makeConfiguration(
                width: max(1, Int(captureSize.width)),
                height: max(1, Int(captureSize.height)),
                includeCursor: request.includeCursor
            )
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return CaptureResult(image: image, mode: request.mode, displayScale: windowScale)

        case .region, .text, .scrolling, .display:
            guard let display = resolveDisplay(request.displayID, in: content.displays) else {
                throw OpenSnapXError.displayNotFound
            }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let fallbackScale = NSScreen.screens.first {
                DisplayGeometry.displayID(for: $0) == display.displayID
            }?.backingScaleFactor ?? 1
            let displayScale = filter.pointPixelScale > 0
                ? max(1, Double(filter.pointPixelScale))
                : max(1, Double(fallbackScale))
            let captureSize = capturePixelSize(
                for: filter,
                fallbackPointSize: CGSize(width: display.width, height: display.height),
                fallbackScale: fallbackScale
            )
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
                return CaptureResult(image: fullImage, mode: request.mode, displayScale: displayScale)
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
                image: cropped,
                mode: request.mode,
                displayScale: displayScale,
                sourceRect: CanvasRect(cropRect)
            )
        }
    }

    func captureDisplays(_ displayIDs: [UInt32]) async throws -> [UInt32: CaptureResult] {
        guard CGPreflightScreenCaptureAccess() else { throw OpenSnapXError.permissionDenied }
        guard !displayIDs.isEmpty else { return [:] }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        let excludedWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == ownBundleID
        }
        var captures: [UInt32: CaptureResult] = [:]
        captures.reserveCapacity(displayIDs.count)

        for displayID in displayIDs {
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw OpenSnapXError.displayNotFound
            }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let fallbackScale = NSScreen.screens.first {
                DisplayGeometry.displayID(for: $0) == display.displayID
            }?.backingScaleFactor ?? 1
            let displayScale = filter.pointPixelScale > 0
                ? max(1, Double(filter.pointPixelScale))
                : max(1, Double(fallbackScale))
            let captureSize = capturePixelSize(
                for: filter,
                fallbackPointSize: CGSize(width: display.width, height: display.height),
                fallbackScale: fallbackScale
            )
            let configuration = makeConfiguration(
                width: max(1, Int(captureSize.width)),
                height: max(1, Int(captureSize.height)),
                includeCursor: false
            )
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            captures[displayID] = CaptureResult(
                image: image,
                mode: .display,
                displayScale: displayScale
            )
        }
        return captures
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

    private func capturePixelSize(
        for filter: SCContentFilter,
        fallbackPointSize: CGSize,
        fallbackScale: CGFloat
    ) -> CGSize {
        let pointSize = filter.contentRect.width > 0 && filter.contentRect.height > 0
            ? filter.contentRect.size
            : fallbackPointSize
        let scale = filter.pointPixelScale > 0
            ? CGFloat(filter.pointPixelScale)
            : fallbackScale
        return DisplayGeometry.pixelSize(from: pointSize, scale: scale)
    }

    private func makeConfiguration(width: Int, height: Int, includeCursor: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = includeCursor
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }
}
