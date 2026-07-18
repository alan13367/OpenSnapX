@preconcurrency import ScreenCaptureKit
import AppKit
import CoreGraphics
import Foundation

struct RunningApplicationCandidate: Sendable {
    let processID: Int32
    let applicationName: String
    let bundleIdentifier: String?
    let isActive: Bool
    let isHidden: Bool
}

struct WindowCandidate: @unchecked Sendable {
    let id: UInt32
    let title: String
    let applicationName: String
    let bundleIdentifier: String?
    let processID: Int32?
    let frame: CGRect
    let isOnScreen: Bool
    let windowLayer: Int

    var isCapturable: Bool { isOnScreen }
}

struct WindowCatalog: Sendable {
    let applications: [RunningApplicationCandidate]
    let windows: [WindowCandidate]
}

struct WindowCapture: @unchecked Sendable {
    let result: CaptureResult
    let window: WindowCandidate
}

protocol WindowCaptureService: Sendable {
    func windowCatalog(includeOffscreenWindows: Bool) async throws -> WindowCatalog
    func captureWindow(id: UInt32) async throws -> WindowCapture
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

final class ScreenCaptureService: CaptureService, WindowCaptureService, @unchecked Sendable {
    func capture(_ request: CaptureRequest) async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else { throw OpenSnapXError.permissionDenied }

        if request.mode == .window {
            guard let windowID = request.windowID else {
                throw OpenSnapXError.windowUnavailable("No window was selected.")
            }
            return try await captureWindow(id: windowID, includeCursor: request.includeCursor).result
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownWindowIDs = Set(content.windows.compactMap { window -> CGWindowID? in
            window.owningApplication?.bundleIdentifier == ownBundleID ? window.windowID : nil
        })
        let excludedWindows = content.windows.filter { ownWindowIDs.contains($0.windowID) }

        switch request.mode {
        case .window:
            throw OpenSnapXError.windowUnavailable("No window was selected.")

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
        try await discoverWindows(includeOffscreenWindows: false)
    }

    func windowCatalog(includeOffscreenWindows: Bool) async throws -> WindowCatalog {
        let windows = try await discoverWindows(includeOffscreenWindows: includeOffscreenWindows)
        let applications = await runningApplications()
        return WindowCatalog(
            applications: applications.sorted {
                $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending
            },
            windows: windows
        )
    }

    private func discoverWindows(includeOffscreenWindows: Bool) async throws -> [WindowCandidate] {
        guard CGPreflightScreenCaptureAccess() else { throw OpenSnapXError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: !includeOffscreenWindows
        )
        let ownBundleID = Bundle.main.bundleIdentifier
        let desktopTop = await MainActor.run { NSScreen.screens.map(\.frame.maxY).max() ?? 0 }
        return content.windows.compactMap { window -> WindowCandidate? in
            guard window.frame.width >= 40,
                  window.frame.height >= 40,
                  window.owningApplication?.bundleIdentifier != ownBundleID else { return nil }
            return Self.candidate(from: window, desktopTop: desktopTop)
        }
    }

    func captureWindow(id: UInt32) async throws -> WindowCapture {
        try await captureWindow(id: id, includeCursor: false)
    }

    private func captureWindow(id: UInt32, includeCursor: Bool) async throws -> WindowCapture {
        guard CGPreflightScreenCaptureAccess() else { throw OpenSnapXError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == id }),
              window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            throw OpenSnapXError.windowUnavailable("The requested window is no longer available.")
        }
        guard window.isOnScreen else {
            throw OpenSnapXError.windowUnavailable("The requested window is minimized or is not currently on screen.")
        }

        let appKitFrame = await MainActor.run { self.appKitFrame(for: window.frame) }
        let fallbackScale = await MainActor.run {
            NSScreen.screens.first { $0.frame.intersects(appKitFrame) }?.backingScaleFactor ?? 2
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
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
            includeCursor: includeCursor
        )
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let desktopTop = await MainActor.run { NSScreen.screens.map(\.frame.maxY).max() ?? 0 }
        return WindowCapture(
            result: CaptureResult(image: image, mode: .window, displayScale: windowScale),
            window: Self.candidate(from: window, desktopTop: desktopTop)
        )
    }

    @MainActor
    private func runningApplications() -> [RunningApplicationCandidate] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated,
                  application.activationPolicy != .prohibited,
                  let name = application.localizedName,
                  !name.isEmpty else { return nil }
            return RunningApplicationCandidate(
                processID: application.processIdentifier,
                applicationName: name,
                bundleIdentifier: application.bundleIdentifier,
                isActive: application.isActive,
                isHidden: application.isHidden
            )
        }
    }

    private static func candidate(from window: SCWindow, desktopTop: CGFloat) -> WindowCandidate {
        let app = window.owningApplication
        return WindowCandidate(
            id: window.windowID,
            title: window.title ?? "Window",
            applicationName: app?.applicationName ?? "Application",
            bundleIdentifier: app?.bundleIdentifier,
            processID: app?.processID,
            frame: CGRect(
                x: window.frame.minX,
                y: desktopTop - window.frame.maxY,
                width: window.frame.width,
                height: window.frame.height
            ),
            isOnScreen: window.isOnScreen,
            windowLayer: window.windowLayer
        )
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
