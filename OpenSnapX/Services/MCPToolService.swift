import CoreGraphics
import Foundation

struct MCPToolService: MCPToolHandling {
    static let statusToolName = "opensnapx_status"
    static let listWindowsToolName = "opensnapx_list_windows"
    static let captureWindowToolName = "opensnapx_capture_window_ocr"
    static let maximumScreenshotBytes = 128 * 1_024 * 1_024

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
                            "default": .bool(false),
                            "description": .string("Return only windows currently available for capture.")
                        ])
                    ]),
                    "additionalProperties": .bool(false)
                ]),
                outputSchema: Self.outputSchema(required: ["applications", "windows"])
            ),
            MCPToolDefinition(
                name: Self.captureWindowToolName,
                title: "Capture Window and Run OCR",
                description: "Capture a non-focused, non-minimized macOS window and return concise on-device OCR text. OCR block geometry and the original-resolution PNG are omitted unless explicitly requested. Captures are never added to OpenSnapX history.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "window_id": .object([
                            "type": .string("integer"),
                            "minimum": .integer(0),
                            "maximum": .integer(Int64(UInt32.max)),
                            "description": .string("Window ID returned by opensnapx_list_windows.")
                        ]),
                        "include_screenshot": .object([
                            "type": .string("boolean"),
                            "default": .bool(false),
                            "description": .string("Return the original-resolution PNG. Leave false for text-reading and OCR requests.")
                        ]),
                        "include_ocr_blocks": .object([
                            "type": .string("boolean"),
                            "default": .bool(false),
                            "description": .string("Return per-block confidence and coordinates. Leave false unless spatial OCR data is needed.")
                        ])
                    ]),
                    "required": .array([.string("window_id")]),
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
        let allowedArguments: Set<String> = ["query", "available_only"]
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
            availableOnly = false
        }

        guard permissionChecker() else { return permissionFailure() }
        do {
            let catalog = try await windowService.windowCatalog(includeOffscreenWindows: true)
            let filteredWindows = catalog.windows.filter { window in
                guard !availableOnly || window.isCapturable else { return false }
                guard let query else { return true }
                return window.applicationName.localizedCaseInsensitiveContains(query)
                    || window.bundleIdentifier?.localizedCaseInsensitiveContains(query) == true
                    || window.title.localizedCaseInsensitiveContains(query)
            }.sorted {
                if $0.applicationName != $1.applicationName {
                    return $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            let filteredProcessIDs = Set(filteredWindows.compactMap(\.processID))
            let filteredApplications = catalog.applications.filter { application in
                if let query {
                    return application.applicationName.localizedCaseInsensitiveContains(query)
                        || application.bundleIdentifier?.localizedCaseInsensitiveContains(query) == true
                        || filteredProcessIDs.contains(application.processID)
                }
                return !availableOnly || filteredProcessIDs.contains(application.processID)
            }
            let windowsByProcess = Dictionary(grouping: filteredWindows, by: \.processID)
            let applications = filteredApplications.map { application -> JSONValue in
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
            let windows = filteredWindows.map { windowValue($0) }
            let summary = filteredWindows.isEmpty
                ? "No matching windows."
                : filteredWindows.map { window in
                    let title = window.title.isEmpty ? "Untitled" : window.title
                    let availability = window.isCapturable ? "available" : "unavailable"
                    return "\(window.applicationName) — \(title) — window_id \(window.id) — \(availability)"
                }.joined(separator: "\n")
            return .success(
                structuredContent: .object([
                    "applications": .array(applications),
                    "windows": .array(windows),
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
        let allowedArguments: Set<String> = ["window_id", "include_screenshot", "include_ocr_blocks"]
        guard Set(arguments.keys).isSubset(of: allowedArguments),
              let windowID = arguments["window_id"]?.uint32Value else {
            return .failure(
                code: "invalid_arguments",
                message: "window_id must be an unsigned 32-bit integer returned by opensnapx_list_windows."
            )
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
        guard permissionChecker() else { return permissionFailure() }

        return await captureLimiter.run { [self] in
            await performCaptureWindow(
                id: windowID,
                includeScreenshot: includeScreenshot,
                includeOCRBlocks: includeOCRBlocks
            )
        }
    }

    private func performCaptureWindow(
        id windowID: UInt32,
        includeScreenshot: Bool,
        includeOCRBlocks: Bool
    ) async -> MCPToolCallResult {
        do {
            let capture = try await windowService.captureWindow(id: windowID)
            let ocr = try await ocrService.recognize(ImagePayload(image: capture.result.image))
            let text = ocr.map(\.text).joined(separator: "\n")
            let screenshotData: Data?
            if includeScreenshot {
                let image = capture.result.image
                let dpi = ImageCodec.dpi(forDisplayScale: capture.result.displayScale)
                screenshotData = try await Task.detached(priority: .utility) {
                    try ImageCodec.data(from: image, format: .png, dpi: dpi)
                }.value
                if let screenshotData, screenshotData.count > Self.maximumScreenshotBytes {
                    return .failure(
                        code: "screenshot_too_large",
                        message: "The original-resolution PNG is too large to return safely.",
                        recovery: "Retry with include_screenshot set to false to receive OCR and metadata only."
                    )
                }
            } else {
                screenshotData = nil
            }

            let captureMetadata: [String: JSONValue] = [
                "captured_at": .string(Self.timestamp(capture.result.createdAt)),
                "pixel_width": .integer(Int64(capture.result.image.width)),
                "pixel_height": .integer(Int64(capture.result.image.height)),
                "display_scale": .number(capture.result.displayScale),
                "ocr_block_count": .integer(Int64(ocr.count)),
                "screenshot_included": .bool(screenshotData != nil),
                "screenshot_mime_type": screenshotData == nil ? .null : .string("image/png"),
                "persisted": .bool(false)
            ]
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

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
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
