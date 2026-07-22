import CoreGraphics
import Foundation

struct MCPToolService: MCPToolHandling {
    static let statusToolName = "opensnapx_status"
    static let listWindowsToolName = "opensnapx_list_windows"
    static let captureWindowToolName = "opensnapx_capture_window_ocr"
    static let maximumScreenshotBytes = 128 * 1_024 * 1_024
    static let defaultWindowLimit = 50
    static let maximumWindowLimit = 200
    static let maximumAmbiguousWindowCandidates = 50

    let windowService: any WindowCaptureService
    let ocrService: any OCRService
    let permissionChecker: @Sendable () -> Bool
    private let captureLimiter: MCPToolRequestLimiter

    init(
        windowService: any WindowCaptureService,
        ocrService: any OCRService,
        permissionChecker: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() },
        maximumConcurrentCaptures: Int = 1
    ) {
        self.windowService = windowService
        self.ocrService = ocrService
        self.permissionChecker = permissionChecker
        captureLimiter = MCPToolRequestLimiter(limit: maximumConcurrentCaptures)
    }

    var toolDefinitions: [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: Self.statusToolName,
                title: "OpenSnapX Status",
                description: "Check whether local window capture is enabled and whether macOS Screen Recording permission is available.",
                inputSchema: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false)
                ]),
                outputSchema: Self.outputSchema(required: ["mcp_enabled", "screen_recording_authorized"])
            ),
            MCPToolDefinition(
                name: Self.listWindowsToolName,
                title: "List macOS Applications and Windows",
                description: "List discoverable macOS windows. Filter by the target app or title to keep responses small. Window IDs are ephemeral; call this immediately before capture.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "maxLength": .integer(200),
                            "description": .string("Case-insensitive app name, bundle ID, or window-title filter.")
                        ]),
                        "available_only": .object([
                            "type": .string("boolean"),
                            "default": .bool(true),
                            "description": .string("Return only windows currently available for capture.")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "minimum": .integer(1),
                            "maximum": .integer(Int64(Self.maximumWindowLimit)),
                            "default": .integer(Int64(Self.defaultWindowLimit)),
                            "description": .string("Maximum number of matching windows to return after filtering and sorting.")
                        ])
                    ]),
                    "additionalProperties": .bool(false)
                ]),
                outputSchema: Self.outputSchema(required: [
                    "applications", "windows", "returned_count", "matched_count", "truncated"
                ])
            ),
            MCPToolDefinition(
                name: Self.captureWindowToolName,
                title: "Capture Window and Run OCR",
                description: "Capture a non-focused, non-minimized macOS window or normalized region and return concise on-device OCR text. OCR block geometry and PNG pixels are omitted unless explicitly requested. Captures are never added to OpenSnapX history.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "window_id": .object([
                            "type": .string("integer"),
                            "minimum": .integer(0),
                            "maximum": .integer(Int64(UInt32.max)),
                            "description": .string("Window ID returned by opensnapx_list_windows.")
                        ]),
                        "query": .object([
                            "type": .string("string"),
                            "maxLength": .integer(200),
                            "description": .string("Case-insensitive window-title or application-name target. A unique best capturable match is required.")
                        ]),
                        "bundle_id": .object([
                            "type": .string("string"),
                            "maxLength": .integer(200),
                            "description": .string("Exact application bundle identifier used to narrow query targeting.")
                        ]),
                        "include_screenshot": .object([
                            "type": .string("boolean"),
                            "default": .bool(false),
                            "description": .string("Return the captured window or selected region as a PNG at original pixel density. Leave false for text-reading and OCR requests.")
                        ]),
                        "include_ocr_blocks": .object([
                            "type": .string("boolean"),
                            "default": .bool(false),
                            "description": .string("Return per-block confidence and top-left normalized coordinates relative to the OCR image or selected region. Leave false unless spatial OCR data is needed.")
                        ]),
                        "region": .object([
                            "type": .string("object"),
                            "description": .string("Optional top-left-origin crop in normalized window-image coordinates. Cropping happens before OCR and PNG encoding."),
                            "properties": .object([
                                "x": Self.normalizedNumberSchema,
                                "y": Self.normalizedNumberSchema,
                                "width": Self.normalizedNumberSchema,
                                "height": Self.normalizedNumberSchema
                            ]),
                            "required": .array([.string("x"), .string("y"), .string("width"), .string("height")]),
                            "additionalProperties": .bool(false)
                        ])
                    ]),
                    "oneOf": .array([
                        .object([
                            "required": .array([.string("window_id")]),
                            "not": .object([
                                "anyOf": .array([
                                    .object(["required": .array([.string("query")])]),
                                    .object(["required": .array([.string("bundle_id")])])
                                ])
                            ])
                        ]),
                        .object([
                            "anyOf": .array([
                                .object(["required": .array([.string("query")])]),
                                .object(["required": .array([.string("bundle_id")])])
                            ]),
                            "not": .object(["required": .array([.string("window_id")])])
                        ])
                    ]),
                    "additionalProperties": .bool(false)
                ]),
                outputSchema: Self.outputSchema(required: ["text", "window", "capture"])
            )
        ]
    }

    func callTool(name: String, arguments: [String: JSONValue]) async -> MCPToolCallResult {
        switch name {
        case Self.statusToolName:
            guard arguments.isEmpty else {
                return .failure(code: "invalid_arguments", message: "opensnapx_status does not accept arguments.")
            }
            return status()
        case Self.listWindowsToolName:
            return await listWindows(arguments: arguments)
        case Self.captureWindowToolName:
            return await captureWindow(arguments: arguments)
        default:
            return .failure(code: "unknown_tool", message: "Unknown OpenSnapX tool: \(name)")
        }
    }

    private func status() -> MCPToolCallResult {
        let authorized = permissionChecker()
        return .success(
            structuredContent: .object([
                "mcp_enabled": .bool(true),
                "screen_recording_authorized": .bool(authorized),
                "accessibility_required": .bool(false),
                "transport": .string("local_unix_socket_via_stdio"),
                "captures_persisted": .bool(false)
            ]),
            textContent: authorized
                ? "OpenSnapX is ready for local window OCR."
                : "OpenSnapX needs Screen Recording permission."
        )
    }

    private func listWindows(arguments: [String: JSONValue]) async -> MCPToolCallResult {
        let allowedArguments: Set<String> = ["query", "available_only", "limit"]
        guard Set(arguments.keys).isSubset(of: allowedArguments) else {
            return .failure(code: "invalid_arguments", message: "Unsupported window-list argument.")
        }

        let query: String?
        if let value = arguments["query"] {
            guard let string = value.stringValue else {
                return .failure(code: "invalid_arguments", message: "query must be a string.")
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 200 else {
                return .failure(code: "invalid_arguments", message: "query must contain 1 to 200 characters.")
            }
            query = trimmed
        } else {
            query = nil
        }

        let availableOnly: Bool
        if let value = arguments["available_only"] {
            guard let bool = value.boolValue else {
                return .failure(code: "invalid_arguments", message: "available_only must be true or false.")
            }
            availableOnly = bool
        } else {
            availableOnly = true
        }

        let limit: Int
        if let value = arguments["limit"] {
            guard let integer = Self.integerValue(value),
                  (1...Self.maximumWindowLimit).contains(integer) else {
                return .failure(
                    code: "invalid_arguments",
                    message: "limit must be an integer from 1 to \(Self.maximumWindowLimit)."
                )
            }
            limit = integer
        } else {
            limit = Self.defaultWindowLimit
        }

        guard permissionChecker() else { return permissionFailure() }
        do {
            let catalog = try await windowService.windowCatalog(includeOffscreenWindows: true)
            let matchedWindows = catalog.windows.filter { window in
                guard !availableOnly || window.isCapturable else { return false }
                guard let query else { return true }
                return window.applicationName.localizedCaseInsensitiveContains(query)
                    || window.bundleIdentifier?.localizedCaseInsensitiveContains(query) == true
                    || window.title.localizedCaseInsensitiveContains(query)
            }.sorted { lhs, rhs in
                let applicationOrder = lhs.applicationName.localizedStandardCompare(rhs.applicationName)
                if applicationOrder != .orderedSame {
                    return applicationOrder == .orderedAscending
                }
                let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                return lhs.id < rhs.id
            }
            let returnedWindows = Array(matchedWindows.prefix(limit))
            let returnedProcessIDs = Set(returnedWindows.compactMap(\.processID))
            let returnedApplications = catalog.applications.filter {
                returnedProcessIDs.contains($0.processID)
            }
            let windowsByProcess = Dictionary(grouping: returnedWindows, by: \.processID)
            let applications = returnedApplications.map { application -> JSONValue in
                let windowIDs = (windowsByProcess[application.processID] ?? []).map {
                    JSONValue.integer(Int64($0.id))
                }
                var object: [String: JSONValue] = [
                    "pid": .integer(Int64(application.processID)),
                    "name": .string(application.applicationName),
                    "is_active": .bool(application.isActive),
                    "is_hidden": .bool(application.isHidden),
                    "window_ids": .array(windowIDs)
                ]
                if let bundleIdentifier = application.bundleIdentifier {
                    object["bundle_id"] = .string(bundleIdentifier)
                }
                return .object(object)
            }
            let windows = returnedWindows.map { windowValue($0) }
            let summary = returnedWindows.isEmpty
                ? "No matching windows."
                : returnedWindows.map { window in
                    let title = window.title.isEmpty ? "Untitled" : window.title
                    let availability = window.isCapturable ? "available" : "unavailable"
                    return "\(window.applicationName) — \(title) — window_id \(window.id) — \(availability)"
                }.joined(separator: "\n")
            return .success(
                structuredContent: .object([
                    "applications": .array(applications),
                    "windows": .array(windows),
                    "returned_count": .integer(Int64(returnedWindows.count)),
                    "matched_count": .integer(Int64(matchedWindows.count)),
                    "truncated": .bool(returnedWindows.count < matchedWindows.count),
                    "window_ids_are_ephemeral": .bool(true)
                ]),
                textContent: summary
            )
        } catch OpenSnapXError.permissionDenied {
            return permissionFailure()
        } catch {
            return .failure(code: "window_discovery_failed", message: error.localizedDescription)
        }
    }

    private func captureWindow(arguments: [String: JSONValue]) async -> MCPToolCallResult {
        let allowedArguments: Set<String> = [
            "window_id", "query", "bundle_id", "include_screenshot", "include_ocr_blocks", "region"
        ]
        guard Set(arguments.keys).isSubset(of: allowedArguments) else {
            return .failure(
                code: "invalid_arguments",
                message: "Unsupported window-capture argument."
            )
        }

        let target: CaptureTarget
        if let windowIDValue = arguments["window_id"] {
            guard arguments["query"] == nil,
                  arguments["bundle_id"] == nil,
                  let windowID = windowIDValue.uint32Value else {
                return .failure(
                    code: "invalid_arguments",
                    message: "Use window_id alone for targeting, or use query and/or bundle_id without window_id."
                )
            }
            target = .windowID(windowID)
        } else {
            let query: String?
            if let value = arguments["query"] {
                guard let parsed = Self.nonEmptyString(value, named: "query") else {
                    return .failure(code: "invalid_arguments", message: "query must contain 1 to 200 characters.")
                }
                query = parsed
            } else {
                query = nil
            }
            let bundleIdentifier: String?
            if let value = arguments["bundle_id"] {
                guard let parsed = Self.nonEmptyString(value, named: "bundle_id") else {
                    return .failure(code: "invalid_arguments", message: "bundle_id must contain 1 to 200 characters.")
                }
                bundleIdentifier = parsed
            } else {
                bundleIdentifier = nil
            }
            guard query != nil || bundleIdentifier != nil else {
                return .failure(
                    code: "invalid_arguments",
                    message: "Provide exactly one targeting mode: window_id, or query and/or bundle_id."
                )
            }
            target = .search(query: query, bundleIdentifier: bundleIdentifier)
        }

        let includeScreenshot: Bool
        if let value = arguments["include_screenshot"] {
            guard let bool = value.boolValue else {
                return .failure(code: "invalid_arguments", message: "include_screenshot must be true or false.")
            }
            includeScreenshot = bool
        } else {
            includeScreenshot = false
        }
        let includeOCRBlocks: Bool
        if let value = arguments["include_ocr_blocks"] {
            guard let bool = value.boolValue else {
                return .failure(code: "invalid_arguments", message: "include_ocr_blocks must be true or false.")
            }
            includeOCRBlocks = bool
        } else {
            includeOCRBlocks = false
        }

        let region: NormalizedRegion?
        if let value = arguments["region"] {
            guard let parsed = Self.normalizedRegion(value) else {
                return .failure(
                    code: "invalid_arguments",
                    message: "region must contain finite x, y, width, and height values inside [0,1], with positive size and x + width / y + height no greater than 1."
                )
            }
            region = parsed
        } else {
            region = nil
        }
        guard permissionChecker() else { return permissionFailure() }

        return await captureLimiter.run { [self] in
            await performCaptureWindow(
                target: target,
                includeScreenshot: includeScreenshot,
                includeOCRBlocks: includeOCRBlocks,
                region: region
            )
        }
    }

    private func performCaptureWindow(
        target: CaptureTarget,
        includeScreenshot: Bool,
        includeOCRBlocks: Bool,
        region: NormalizedRegion?
    ) async -> MCPToolCallResult {
        do {
            let windowID: UInt32
            switch target {
            case let .windowID(id):
                windowID = id
            case let .search(query, bundleIdentifier):
                let catalog: WindowCatalog
                do {
                    catalog = try await windowService.windowCatalog(includeOffscreenWindows: true)
                } catch OpenSnapXError.permissionDenied {
                    return permissionFailure()
                } catch {
                    return .failure(code: "window_discovery_failed", message: error.localizedDescription)
                }
                switch Self.resolveCaptureTarget(
                    in: catalog.windows,
                    query: query,
                    bundleIdentifier: bundleIdentifier
                ) {
                case let .success(window):
                    windowID = window.id
                case let .failure(.ambiguous(candidates)):
                    let returnedCandidates = Array(candidates.prefix(Self.maximumAmbiguousWindowCandidates))
                    return .failure(
                        code: "ambiguous_window",
                        message: "Multiple capturable windows match the target equally well.",
                        recovery: "Retry with a more specific query, call opensnapx_list_windows with a filter, or capture one of the returned candidate window IDs.",
                        details: [
                            "candidate_window_ids": .array(returnedCandidates.map { .integer(Int64($0.id)) }),
                            "candidates": .array(returnedCandidates.map { windowValue($0) }),
                            "returned_candidate_count": .integer(Int64(returnedCandidates.count)),
                            "matched_candidate_count": .integer(Int64(candidates.count)),
                            "candidates_truncated": .bool(returnedCandidates.count < candidates.count)
                        ]
                    )
                case .failure(.unavailable):
                    return .failure(
                        code: "window_unavailable",
                        message: "No capturable window matches the requested query and bundle identifier.",
                        recovery: "Call opensnapx_list_windows to inspect available windows, then retry with a more specific target."
                    )
                }
            }

            let capture = try await windowService.captureWindow(id: windowID)
            let preparedImage: PreparedCaptureImage
            if let region {
                guard let cropped = Self.crop(capture.result.image, to: region) else {
                    return .failure(
                        code: "invalid_arguments",
                        message: "The requested region does not contain any image pixels."
                    )
                }
                preparedImage = cropped
            } else {
                preparedImage = PreparedCaptureImage(image: capture.result.image, region: nil)
            }

            let ocr = try await ocrService.recognize(ImagePayload(image: preparedImage.image))
            let text = ocr.map(\.text).joined(separator: "\n")
            let screenshotData: Data?
            if includeScreenshot {
                let image = preparedImage.image
                let dpi = ImageCodec.dpi(forDisplayScale: capture.result.displayScale)
                screenshotData = try await Task.detached(priority: .utility) {
                    try ImageCodec.data(from: image, format: .png, dpi: dpi)
                }.value
                if let screenshotData, screenshotData.count > Self.maximumScreenshotBytes {
                    return .failure(
                        code: "screenshot_too_large",
                        message: "The original-pixel-density PNG is too large to return safely.",
                        recovery: "Retry with include_screenshot set to false to receive OCR and metadata only."
                    )
                }
            } else {
                screenshotData = nil
            }

            var captureMetadata: [String: JSONValue] = [
                "captured_at": .string(Self.timestamp(capture.result.createdAt)),
                "pixel_width": .integer(Int64(preparedImage.image.width)),
                "pixel_height": .integer(Int64(preparedImage.image.height)),
                "display_scale": .number(capture.result.displayScale),
                "ocr_block_count": .integer(Int64(ocr.count)),
                "screenshot_included": .bool(screenshotData != nil),
                "screenshot_mime_type": screenshotData == nil ? .null : .string("image/png"),
                "persisted": .bool(false)
            ]
            if let appliedRegion = preparedImage.region {
                captureMetadata["region"] = rectValue(appliedRegion.rect)
                captureMetadata["region_coordinate_origin"] = .string("top_left")
            }
            var structuredContent: [String: JSONValue] = [
                "text": .string(text),
                "window": windowValue(capture.window),
                "capture": .object(captureMetadata)
            ]
            if includeOCRBlocks {
                structuredContent["ocr_blocks"] = .array(ocr.map { result in
                    .object([
                        "text": .string(result.text),
                        "confidence": .number(Double(result.confidence)),
                        "normalized_bounds": rectValue(result.normalizedBounds.cgRect)
                    ])
                })
            }
            return .success(
                structuredContent: .object(structuredContent),
                imageData: screenshotData,
                textContent: text
            )
        } catch OpenSnapXError.permissionDenied {
            return permissionFailure()
        } catch let OpenSnapXError.windowUnavailable(message) {
            return .failure(
                code: "window_unavailable",
                message: message,
                recovery: "Call opensnapx_list_windows again and choose a window whose capture_availability is available."
            )
        } catch {
            return .failure(code: "capture_or_ocr_failed", message: error.localizedDescription)
        }
    }

    private func permissionFailure() -> MCPToolCallResult {
        .failure(
            code: "screen_recording_permission_required",
            message: "OpenSnapX does not have macOS Screen Recording permission.",
            recovery: "Open OpenSnapX Settings, grant Screen Recording access, and then retry. Accessibility permission is not required."
        )
    }

    private static func resolveCaptureTarget(
        in windows: [WindowCandidate],
        query: String?,
        bundleIdentifier: String?
    ) -> Result<WindowCandidate, CaptureTargetResolutionError> {
        var candidates = windows.filter(\.isCapturable)
        if let bundleIdentifier {
            candidates = candidates.filter {
                $0.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
            }
        }
        guard !candidates.isEmpty else { return .failure(.unavailable) }

        guard let query else {
            let sorted = candidates.sorted { $0.id < $1.id }
            guard sorted.count == 1, let match = sorted.first else {
                return .failure(.ambiguous(sorted))
            }
            return .success(match)
        }

        let scored = candidates.compactMap { window -> (window: WindowCandidate, score: Int)? in
            let score: Int
            if window.title.localizedCaseInsensitiveCompare(query) == .orderedSame {
                score = 400
            } else if window.title.localizedCaseInsensitiveContains(query) {
                score = 300
            } else if window.applicationName.localizedCaseInsensitiveCompare(query) == .orderedSame {
                score = 200
            } else if window.applicationName.localizedCaseInsensitiveContains(query) {
                score = 100
            } else {
                return nil
            }
            return (window, score)
        }
        guard let bestScore = scored.map(\.score).max() else { return .failure(.unavailable) }
        let bestMatches = scored
            .filter { $0.score == bestScore }
            .map(\.window)
            .sorted { $0.id < $1.id }
        guard bestMatches.count == 1, let match = bestMatches.first else {
            return .failure(.ambiguous(bestMatches))
        }
        return .success(match)
    }

    private static func crop(_ image: CGImage, to region: NormalizedRegion) -> PreparedCaptureImage? {
        let imageWidth = Double(image.width)
        let imageHeight = Double(image.height)
        let minimumX = floor(region.x * imageWidth)
        let minimumY = floor(region.y * imageHeight)
        let maximumX = ceil((region.x + region.width) * imageWidth)
        let maximumY = ceil((region.y + region.height) * imageHeight)
        let pixelRect = CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
        guard pixelRect.width > 0,
              pixelRect.height > 0,
              pixelRect.minX >= 0,
              pixelRect.minY >= 0,
              pixelRect.maxX <= imageWidth,
              pixelRect.maxY <= imageHeight,
              let cropped = image.cropping(to: pixelRect) else { return nil }

        let appliedRegion = NormalizedRegion(
            x: Double(pixelRect.minX) / imageWidth,
            y: Double(pixelRect.minY) / imageHeight,
            width: Double(pixelRect.width) / imageWidth,
            height: Double(pixelRect.height) / imageHeight
        )
        return PreparedCaptureImage(image: cropped, region: appliedRegion)
    }

    private static func normalizedRegion(_ value: JSONValue) -> NormalizedRegion? {
        guard let object = value.objectValue,
              Set(object.keys) == Set(["x", "y", "width", "height"]),
              let rawX = object["x"].flatMap(numberValue),
              let rawY = object["y"].flatMap(numberValue),
              let rawWidth = object["width"].flatMap(numberValue),
              let rawHeight = object["height"].flatMap(numberValue),
              rawX.isFinite,
              rawY.isFinite,
              rawWidth.isFinite,
              rawHeight.isFinite,
              rawWidth > 0,
              rawHeight > 0 else { return nil }

        let epsilon = 1e-9
        guard rawX >= -epsilon,
              rawY >= -epsilon,
              rawX + rawWidth <= 1 + epsilon,
              rawY + rawHeight <= 1 + epsilon else { return nil }
        let x = min(1, max(0, rawX))
        let y = min(1, max(0, rawY))
        let maximumX = min(1, max(0, rawX + rawWidth))
        let maximumY = min(1, max(0, rawY + rawHeight))
        guard maximumX > x, maximumY > y else { return nil }
        return NormalizedRegion(x: x, y: y, width: maximumX - x, height: maximumY - y)
    }

    private static func nonEmptyString(_ value: JSONValue, named _: String) -> String? {
        guard let string = value.stringValue else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
        return trimmed
    }

    private static func integerValue(_ value: JSONValue) -> Int? {
        switch value {
        case let .integer(integer):
            return Int(exactly: integer)
        case let .number(number) where number.isFinite && number.rounded() == number:
            return Int(exactly: number)
        default:
            return nil
        }
    }

    private static func numberValue(_ value: JSONValue) -> Double? {
        switch value {
        case let .integer(integer): Double(integer)
        case let .number(number): number
        default: nil
        }
    }

    private func windowValue(_ window: WindowCandidate) -> JSONValue {
        var object: [String: JSONValue] = [
            "window_id": .integer(Int64(window.id)),
            "title": .string(window.title),
            "application_name": .string(window.applicationName),
            "frame": rectValue(window.frame),
            "is_on_screen": .bool(window.isOnScreen),
            "window_layer": .integer(Int64(window.windowLayer)),
            "capture_availability": .string(window.isCapturable ? "available" : "unavailable"),
            "unavailable_reason": window.isCapturable
                ? .null
                : .string("The window is minimized or is not currently on screen.")
        ]
        if let bundleIdentifier = window.bundleIdentifier {
            object["bundle_id"] = .string(bundleIdentifier)
        }
        if let processID = window.processID {
            object["pid"] = .integer(Int64(processID))
        }
        return .object(object)
    }

    private func rectValue(_ rect: CGRect) -> JSONValue {
        .object([
            "x": .number(rect.origin.x),
            "y": .number(rect.origin.y),
            "width": .number(rect.width),
            "height": .number(rect.height)
        ])
    }

    private static func outputSchema(required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "anyOf": .array([
                .object(["required": .array(required.map(JSONValue.string))]),
                .object(["required": .array([.string("error")])])
            ])
        ])
    }

    private static var normalizedNumberSchema: JSONValue {
        .object([
            "type": .string("number"),
            "minimum": .integer(0),
            "maximum": .integer(1)
        ])
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private enum CaptureTarget: Sendable {
    case windowID(UInt32)
    case search(query: String?, bundleIdentifier: String?)
}

private enum CaptureTargetResolutionError: Error {
    case ambiguous([WindowCandidate])
    case unavailable
}

private struct NormalizedRegion: Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private struct PreparedCaptureImage: @unchecked Sendable {
    let image: CGImage
    let region: NormalizedRegion?
}

private actor MCPToolRequestLimiter {
    private let limit: Int
    private var activeRequests = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func run<Result: Sendable>(
        _ operation: @Sendable () async -> Result
    ) async -> Result {
        await acquire()
        let result = await operation()
        release()
        return result
    }

    private func acquire() async {
        if activeRequests < limit {
            activeRequests += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            activeRequests = max(0, activeRequests - 1)
            return
        }
        waiters.removeFirst().resume()
    }
}
