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

enum WindowSelectionEngine {
    static func orderedFrontToBack(
        _ candidates: [WindowCandidate],
        windowIDs: [UInt32]
    ) -> [WindowCandidate] {
        var ranks: [UInt32: Int] = [:]
        for (index, windowID) in windowIDs.enumerated() where ranks[windowID] == nil {
            ranks[windowID] = index
        }
        return candidates.enumerated().sorted { lhs, rhs in
            let lhsRank = ranks[lhs.element.id] ?? Int.max
            let rhsRank = ranks[rhs.element.id] ?? Int.max
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }.map(\.element)
    }

    static func frontmostCandidate(
        at screenPoint: CGPoint,
        in candidates: [WindowCandidate]
    ) -> WindowCandidate? {
        candidates.first {
            $0.isCapturable
                && $0.bundleIdentifier != "com.apple.dock"
                && $0.frame.contains(screenPoint)
        }
    }
}

protocol WindowCaptureService: Sendable {
    func windowCatalog(includeOffscreenWindows: Bool) async throws -> WindowCatalog
    func captureWindow(id: UInt32) async throws -> WindowCapture
}

protocol CaptureService: Sendable {
    func capture(_ request: CaptureRequest) async throws -> CaptureResult
    func availableWindows() async throws -> [WindowCandidate]
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

        if (request.mode == .region || request.mode == .text),
           let screenSelection = request.screenSelection?.cgRect {
            return try await captureDesktopRegion(
                screenSelection,
                mode: request.mode,
                includeCursor: request.includeCursor,
                content: content,
                excludedWindows: excludedWindows
            )
        }

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

    func availableWindows() async throws -> [WindowCandidate] {
        try await discoverWindows(includeOffscreenWindows: false)
    }

    private func captureDesktopRegion(
        _ screenRect: CGRect,
        mode: CaptureMode,
        includeCursor: Bool,
        content: SCShareableContent,
        excludedWindows: [SCWindow]
    ) async throws -> CaptureResult {
        let screenDescriptors = await MainActor.run {
            NSScreen.screens.compactMap { screen -> DisplayGeometry.ScreenDescriptor? in
                guard let displayID = DisplayGeometry.displayID(for: screen) else { return nil }
                return DisplayGeometry.ScreenDescriptor(
                    displayID: displayID,
                    frame: screen.frame,
                    scale: screen.backingScaleFactor
                )
            }
        }

        var filters: [UInt32: SCContentFilter] = [:]
        var captureSizes: [UInt32: CGSize] = [:]
        var effectiveDescriptors: [DisplayGeometry.ScreenDescriptor] = []
        for descriptor in screenDescriptors where descriptor.frame.intersects(screenRect) {
            guard let display = content.displays.first(where: { $0.displayID == descriptor.displayID }) else {
                continue
            }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let scale = filter.pointPixelScale > 0
                ? max(1, CGFloat(filter.pointPixelScale))
                : max(1, descriptor.scale)
            filters[descriptor.displayID] = filter
            captureSizes[descriptor.displayID] = capturePixelSize(
                for: filter,
                fallbackPointSize: CGSize(width: display.width, height: display.height),
                fallbackScale: descriptor.scale
            )
            effectiveDescriptors.append(DisplayGeometry.ScreenDescriptor(
                displayID: descriptor.displayID,
                frame: descriptor.frame,
                scale: scale
            ))
        }

        guard let layout = DisplayGeometry.regionLayout(
            for: screenRect,
            screens: effectiveDescriptors
        ) else {
            throw OpenSnapXError.captureFailed("The selected area does not intersect a display.")
        }

        var displayImages: [UInt32: CGImage] = [:]
        for slice in layout.slices {
            guard let filter = filters[slice.displayID],
                  let captureSize = captureSizes[slice.displayID] else { continue }
            let configuration = makeConfiguration(
                width: max(1, Int(captureSize.width)),
                height: max(1, Int(captureSize.height)),
                includeCursor: includeCursor
            )
            displayImages[slice.displayID] = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        }

        let width = max(1, Int(layout.pixelSize.width))
        let height = max(1, Int(layout.pixelSize.height))
        let colorSpace = displayImages.values.first?.colorSpace
            ?? CGColorSpace(name: CGColorSpace.displayP3)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw OpenSnapXError.captureFailed("Could not create the multi-display capture canvas.")
        }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        var drewSlice = false
        for slice in layout.slices {
            guard let displayImage = displayImages[slice.displayID] else { continue }
            let imageBounds = CGRect(
                x: 0,
                y: 0,
                width: displayImage.width,
                height: displayImage.height
            )
            let cropRect = slice.sourcePixelRect.standardized.integral.intersection(imageBounds)
            guard cropRect.width > 0,
                  cropRect.height > 0,
                  let cropped = displayImage.cropping(to: cropRect) else { continue }
            context.draw(cropped, in: slice.destinationPixelRect)
            drewSlice = true
        }
        guard drewSlice, let image = context.makeImage() else {
            throw OpenSnapXError.captureFailed("Could not finish the multi-display capture.")
        }
        return CaptureResult(
            image: image,
            mode: mode,
            displayScale: Double(layout.scale),
            sourceRect: CanvasRect(CGRect(origin: .zero, size: layout.pixelSize))
        )
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
        let primaryDisplayTop = await MainActor.run { NSScreen.screens.first?.frame.maxY ?? 0 }
        let candidates = content.windows.compactMap { window -> WindowCandidate? in
            guard window.frame.width >= 40,
                  window.frame.height >= 40,
                  window.owningApplication?.bundleIdentifier != ownBundleID else { return nil }
            return Self.candidate(from: window, primaryDisplayTop: primaryDisplayTop)
        }
        return WindowSelectionEngine.orderedFrontToBack(
            candidates,
            windowIDs: Self.frontToBackWindowIDs()
        )
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
        let primaryDisplayTop = await MainActor.run { NSScreen.screens.first?.frame.maxY ?? 0 }
        return WindowCapture(
            result: CaptureResult(image: image, mode: .window, displayScale: windowScale),
            window: Self.candidate(from: window, primaryDisplayTop: primaryDisplayTop)
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

    private static func candidate(from window: SCWindow, primaryDisplayTop: CGFloat) -> WindowCandidate {
        let app = window.owningApplication
        return WindowCandidate(
            id: window.windowID,
            title: window.title ?? "Window",
            applicationName: app?.applicationName ?? "Application",
            bundleIdentifier: app?.bundleIdentifier,
            processID: app?.processID,
            frame: DisplayGeometry.appKitRect(
                fromQuartzRect: window.frame,
                primaryDisplayTop: primaryDisplayTop
            ),
            isOnScreen: window.isOnScreen,
            windowLayer: window.windowLayer
        )
    }

    private static func frontToBackWindowIDs() -> [UInt32] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return windowInfo.compactMap { info in
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01 else { return nil }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
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
        DisplayGeometry.appKitRect(
            fromQuartzRect: screenCaptureFrame,
            primaryDisplayTop: NSScreen.screens.first?.frame.maxY ?? 0
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
