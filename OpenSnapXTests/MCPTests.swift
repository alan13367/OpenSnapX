import CoreGraphics
import Foundation
import XCTest
@testable import OpenSnapX

final class MCPProtocolTests: XCTestCase {
    func testInitializeThenListsToolsAfterInitializedNotification() async throws {
        let session = MCPClientSession(toolHandler: StubMCPToolHandler())

        let initialize = try await send([
            "jsonrpc": .string("2.0"),
            "id": .integer(1),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string("2025-11-25"),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("Tests"), "version": .string("1")])
            ])
        ], to: session)
        XCTAssertEqual(
            initialize.objectValue?["result"]?.objectValue?["protocolVersion"],
            .string("2025-11-25")
        )

        let beforeInitialized = try await send([
            "jsonrpc": .string("2.0"),
            "id": .integer(2),
            "method": .string("tools/list"),
            "params": .object([:])
        ], to: session)
        XCTAssertEqual(
            beforeInitialized.objectValue?["error"]?.objectValue?["code"],
            .integer(-32002)
        )

        let notification = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized")
        ]))
        let notificationResponse = await session.handle(notification)
        XCTAssertNil(notificationResponse)

        let tools = try await send([
            "jsonrpc": .string("2.0"),
            "id": .integer(3),
            "method": .string("tools/list"),
            "params": .object([:])
        ], to: session)
        let listed = tools.objectValue?["result"]?.objectValue?["tools"]?.arrayValue
        XCTAssertEqual(listed?.first?.objectValue?["name"], .string("stub_tool"))
    }

    func testToolCallReturnsStructuredAndImageContent() async throws {
        let session = MCPClientSession(toolHandler: StubMCPToolHandler())
        _ = try await send([
            "jsonrpc": .string("2.0"),
            "id": .integer(1),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string("2025-11-25"),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("Tests"), "version": .string("1")])
            ])
        ], to: session)
        let initialized = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized")
        ]))
        _ = await session.handle(initialized)

        let response = try await send([
            "jsonrpc": .string("2.0"),
            "id": .integer(2),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string("stub_tool"),
                "arguments": .object([:])
            ])
        ], to: session)
        let result = try XCTUnwrap(response.objectValue?["result"]?.objectValue)
        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertEqual(result["structuredContent"], .object(["ok": .bool(true)]))
        let content = try XCTUnwrap(result["content"]?.arrayValue)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1].objectValue?["type"], .string("image"))
        XCTAssertEqual(content[1].objectValue?["data"], .string(Data([1, 2, 3]).base64EncodedString()))
    }

    func testUnknownToolReturnsProtocolError() async throws {
        let session = MCPClientSession(toolHandler: StubMCPToolHandler())
        try await initialize(session, protocolVersion: "2025-11-25")

        let response = try await send([
            "jsonrpc": .string("2.0"),
            "id": .integer(2),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string("missing_tool"),
                "arguments": .object([:])
            ])
        ], to: session)
        XCTAssertEqual(response.objectValue?["error"]?.objectValue?["code"], .integer(-32602))
        XCTAssertEqual(
            response.objectValue?["error"]?.objectValue?["message"],
            .string("Unknown tool: missing_tool")
        )
    }

    func testLegacyProtocolOmitsNewerStructuredToolFields() async throws {
        let session = MCPClientSession(toolHandler: StubMCPToolHandler())
        try await initialize(session, protocolVersion: "2025-03-26")

        let toolsResponse = try await send([
            "jsonrpc": .string("2.0"),
            "id": .integer(2),
            "method": .string("tools/list"),
            "params": .object([:])
        ], to: session)
        let tool = try XCTUnwrap(
            toolsResponse.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.first?.objectValue
        )
        XCTAssertNil(tool["title"])
        XCTAssertNil(tool["outputSchema"])

        let callResponse = try await send([
            "jsonrpc": .string("2.0"),
            "id": .integer(3),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string("stub_tool"),
                "arguments": .object([:])
            ])
        ], to: session)
        XCTAssertNil(callResponse.objectValue?["result"]?.objectValue?["structuredContent"])
    }

    func testInitializeRequiresMCPClientInformation() async throws {
        let session = MCPClientSession(toolHandler: StubMCPToolHandler())
        let response = try await send([
            "jsonrpc": .string("2.0"),
            "id": .integer(1),
            "method": .string("initialize"),
            "params": .object(["protocolVersion": .string("2025-11-25")])
        ], to: session)
        XCTAssertEqual(response.objectValue?["error"]?.objectValue?["code"], .integer(-32602))
    }

    private func initialize(_ session: MCPClientSession, protocolVersion: String) async throws {
        _ = try await send([
            "jsonrpc": .string("2.0"),
            "id": .integer(1),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("Tests"), "version": .string("1")])
            ])
        ], to: session)
        let initialized = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized")
        ]))
        _ = await session.handle(initialized)
    }

    private func send(_ object: [String: JSONValue], to session: MCPClientSession) async throws -> JSONValue {
        let data = try JSONEncoder().encode(JSONValue.object(object))
        let sessionResponse = await session.handle(data)
        let response = try XCTUnwrap(sessionResponse)
        return try JSONDecoder().decode(JSONValue.self, from: response)
    }
}

final class MCPToolServiceTests: XCTestCase {
    func testListWindowsDefaultsToAvailableWindows() async throws {
        let fixtures = try MCPFixtures()
        let service = MCPToolService(
            windowService: fixtures.windowService,
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(name: MCPToolService.listWindowsToolName, arguments: [:])
        XCTAssertFalse(result.isError)
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        let windows = try XCTUnwrap(structured["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].objectValue?["capture_availability"], .string("available"))
        XCTAssertEqual(structured["returned_count"], .integer(1))
        XCTAssertEqual(structured["matched_count"], .integer(1))
        XCTAssertEqual(structured["truncated"], .bool(false))
    }

    func testListWindowsCanIncludeUnavailableWindowsExplicitly() async throws {
        let fixtures = try MCPFixtures()
        let service = MCPToolService(
            windowService: fixtures.windowService,
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.listWindowsToolName,
            arguments: ["available_only": .bool(false)]
        )
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        let windows = try XCTUnwrap(structured["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[1].objectValue?["capture_availability"], .string("unavailable"))
        XCTAssertEqual(structured["matched_count"], .integer(2))
    }

    func testListWindowsLimitTruncatesWindowsApplicationsAndReportsCounts() async throws {
        let fixtures = try MCPFixtures()
        let secondApplication = RunningApplicationCandidate(
            processID: 200,
            applicationName: "Preview",
            bundleIdentifier: "com.apple.Preview",
            isActive: false,
            isHidden: false
        )
        let secondWindow = WindowCandidate(
            id: 44,
            title: "Image",
            applicationName: "Preview",
            bundleIdentifier: "com.apple.Preview",
            processID: 200,
            frame: CGRect(x: 0, y: 0, width: 200, height: 100),
            isOnScreen: true,
            windowLayer: 0
        )
        let catalog = WindowCatalog(
            applications: fixtures.windowService.catalog.applications + [secondApplication],
            windows: fixtures.windowService.catalog.windows + [secondWindow]
        )
        let service = MCPToolService(
            windowService: FixtureWindowService(catalog: catalog, capture: fixtures.windowService.capture),
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.listWindowsToolName,
            arguments: ["limit": .integer(1)]
        )
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(structured["windows"]?.arrayValue?.count, 1)
        XCTAssertEqual(structured["applications"]?.arrayValue?.count, 1)
        XCTAssertEqual(structured["returned_count"], .integer(1))
        XCTAssertEqual(structured["matched_count"], .integer(2))
        XCTAssertEqual(structured["truncated"], .bool(true))
    }

    func testListWindowsFiltersByQueryAndAvailability() async throws {
        let fixtures = try MCPFixtures()
        let service = MCPToolService(
            windowService: fixtures.windowService,
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.listWindowsToolName,
            arguments: [
                "query": .string("document"),
                "available_only": .bool(true)
            ]
        )
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        let windows = try XCTUnwrap(structured["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].objectValue?["window_id"], .integer(42))
        guard case let .text(summary)? = result.content.first else {
            return XCTFail("Expected concise text content")
        }
        XCTAssertEqual(summary, "Notes — Document — window_id 42 — available")
    }

    func testCaptureResolvesUniqueWindowByQuery() async throws {
        let fixtures = try MCPFixtures()
        let service = MCPToolService(
            windowService: fixtures.windowService,
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.captureWindowToolName,
            arguments: ["query": .string("document")]
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(
            result.structuredContent?.objectValue?["window"]?.objectValue?["window_id"],
            .integer(42)
        )
        XCTAssertEqual(result.structuredContent?.objectValue?["text"], .string("Hello\nWorld"))
    }

    func testCaptureResolvesUniqueWindowByExactBundleIdentifier() async throws {
        let fixtures = try MCPFixtures()
        let service = MCPToolService(
            windowService: fixtures.windowService,
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.captureWindowToolName,
            arguments: ["bundle_id": .string("com.apple.Notes")]
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(
            result.structuredContent?.objectValue?["window"]?.objectValue?["window_id"],
            .integer(42)
        )
    }

    func testCaptureReturnsCandidatesForAmbiguousQuery() async throws {
        let fixtures = try MCPFixtures()
        let secondWindow = WindowCandidate(
            id: 44,
            title: "Other Document",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            processID: 100,
            frame: CGRect(x: 0, y: 0, width: 200, height: 100),
            isOnScreen: true,
            windowLayer: 0
        )
        let catalog = WindowCatalog(
            applications: fixtures.windowService.catalog.applications,
            windows: fixtures.windowService.catalog.windows + [secondWindow]
        )
        let service = MCPToolService(
            windowService: FixtureWindowService(catalog: catalog, capture: fixtures.windowService.capture),
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.captureWindowToolName,
            arguments: ["query": .string("Notes")]
        )
        XCTAssertTrue(result.isError)
        let error = try XCTUnwrap(result.structuredContent?.objectValue?["error"]?.objectValue)
        XCTAssertEqual(error["code"], .string("ambiguous_window"))
        XCTAssertEqual(error["candidate_window_ids"], .array([.integer(42), .integer(44)]))
        XCTAssertEqual(error["returned_candidate_count"], .integer(2))
        XCTAssertEqual(error["matched_candidate_count"], .integer(2))
        XCTAssertEqual(error["candidates_truncated"], .bool(false))
    }

    func testCaptureBoundsAmbiguousCandidateDetails() async throws {
        let fixtures = try MCPFixtures()
        let additionalWindows = (0..<60).map { index in
            WindowCandidate(
                id: UInt32(100 + index),
                title: "Document \(index)",
                applicationName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                processID: 100,
                frame: CGRect(x: 0, y: 0, width: 200, height: 100),
                isOnScreen: true,
                windowLayer: 0
            )
        }
        let catalog = WindowCatalog(
            applications: fixtures.windowService.catalog.applications,
            windows: fixtures.windowService.catalog.windows + additionalWindows
        )
        let service = MCPToolService(
            windowService: FixtureWindowService(catalog: catalog, capture: fixtures.windowService.capture),
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.captureWindowToolName,
            arguments: ["query": .string("Notes")]
        )
        XCTAssertTrue(result.isError)
        let error = try XCTUnwrap(result.structuredContent?.objectValue?["error"]?.objectValue)
        XCTAssertEqual(
            error["candidate_window_ids"]?.arrayValue?.count,
            MCPToolService.maximumAmbiguousWindowCandidates
        )
        XCTAssertEqual(
            error["candidates"]?.arrayValue?.count,
            MCPToolService.maximumAmbiguousWindowCandidates
        )
        XCTAssertEqual(
            error["returned_candidate_count"],
            .integer(Int64(MCPToolService.maximumAmbiguousWindowCandidates))
        )
        XCTAssertEqual(error["matched_candidate_count"], .integer(61))
        XCTAssertEqual(error["candidates_truncated"], .bool(true))
    }

    func testCaptureRejectsMixedIDAndQueryTargeting() async throws {
        let fixtures = try MCPFixtures()
        let service = MCPToolService(
            windowService: fixtures.windowService,
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.captureWindowToolName,
            arguments: ["window_id": .integer(42), "query": .string("Document")]
        )
        XCTAssertTrue(result.isError)
        XCTAssertEqual(
            result.structuredContent?.objectValue?["error"]?.objectValue?["code"],
            .string("invalid_arguments")
        )
    }

    func testCaptureReturnsOCRWithoutScreenshotOrPersistenceByDefault() async throws {
        let fixtures = try MCPFixtures()
        let service = MCPToolService(
            windowService: fixtures.windowService,
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.captureWindowToolName,
            arguments: ["window_id": .integer(42)]
        )
        XCTAssertFalse(result.isError)
        XCTAssertFalse(result.content.contains { content in
            if case .image = content { return true }
            return false
        })
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(structured["text"], .string("Hello\nWorld"))
        XCTAssertNil(structured["ocr_blocks"])
        guard case let .text(contentText)? = result.content.first else {
            return XCTFail("Expected OCR text content")
        }
        XCTAssertEqual(contentText, "Hello\nWorld")
        let capture = try XCTUnwrap(structured["capture"]?.objectValue)
        XCTAssertEqual(capture["ocr_block_count"], .integer(2))
        XCTAssertEqual(capture["pixel_width"], .integer(4))
        XCTAssertEqual(capture["pixel_height"], .integer(3))
        XCTAssertEqual(capture["screenshot_included"], .bool(false))
        XCTAssertEqual(capture["persisted"], .bool(false))
    }

    func testCaptureReturnsOCRBlocksOnlyWhenRequested() async throws {
        let fixtures = try MCPFixtures()
        let service = MCPToolService(
            windowService: fixtures.windowService,
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.captureWindowToolName,
            arguments: [
                "window_id": .integer(42),
                "include_ocr_blocks": .bool(true)
            ]
        )
        let blocks = result.structuredContent?.objectValue?["ocr_blocks"]?.arrayValue
        XCTAssertEqual(blocks?.count, 2)
    }

    func testCaptureReturnsOriginalResolutionPNGWhenRequested() async throws {
        let fixtures = try MCPFixtures()
        let service = MCPToolService(
            windowService: fixtures.windowService,
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.captureWindowToolName,
            arguments: [
                "window_id": .integer(42),
                "include_screenshot": .bool(true)
            ]
        )
        let imageData = result.content.compactMap { content -> Data? in
            if case let .image(data, mimeType) = content {
                XCTAssertEqual(mimeType, "image/png")
                return data
            }
            return nil
        }.first
        let decoded = try ImageCodec.image(from: XCTUnwrap(imageData))
        XCTAssertEqual(decoded.width, 4)
        XCTAssertEqual(decoded.height, 3)
    }

    func testRegionCropsImageBeforeOCRAndPNGEncoding() async throws {
        let fixtures = try MCPFixtures()
        let service = MCPToolService(
            windowService: fixtures.windowService,
            ocrService: DimensionOCRService(),
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.captureWindowToolName,
            arguments: [
                "window_id": .integer(42),
                "include_screenshot": .bool(true),
                "region": .object([
                    "x": .number(0.25),
                    "y": .integer(0),
                    "width": .number(0.5),
                    "height": .number(2.0 / 3.0)
                ])
            ]
        )
        XCTAssertFalse(result.isError)
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(structured["text"], .string("2x2"))
        let capture = try XCTUnwrap(structured["capture"]?.objectValue)
        XCTAssertEqual(capture["pixel_width"], .integer(2))
        XCTAssertEqual(capture["pixel_height"], .integer(2))
        XCTAssertEqual(capture["region_coordinate_origin"], .string("top_left"))
        XCTAssertEqual(capture["region"], .object([
            "x": .number(0.25),
            "y": .number(0),
            "width": .number(0.5),
            "height": .number(2.0 / 3.0)
        ]))
        let imageData = result.content.compactMap { content -> Data? in
            guard case let .image(data, _) = content else { return nil }
            return data
        }.first
        let decoded = try ImageCodec.image(from: XCTUnwrap(imageData))
        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 2)
    }

    func testCaptureRejectsRegionOutsideNormalizedBounds() async throws {
        let fixtures = try MCPFixtures()
        let service = MCPToolService(
            windowService: fixtures.windowService,
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.captureWindowToolName,
            arguments: [
                "window_id": .integer(42),
                "region": .object([
                    "x": .number(0.8),
                    "y": .integer(0),
                    "width": .number(0.3),
                    "height": .integer(1)
                ])
            ]
        )
        XCTAssertTrue(result.isError)
        XCTAssertEqual(
            result.structuredContent?.objectValue?["error"]?.objectValue?["code"],
            .string("invalid_arguments")
        )
    }

    func testUnavailableWindowReturnsRefreshGuidance() async throws {
        let fixtures = try MCPFixtures()
        let service = MCPToolService(
            windowService: fixtures.windowService,
            ocrService: fixtures.ocrService,
            permissionChecker: { true }
        )
        let result = await service.callTool(
            name: MCPToolService.captureWindowToolName,
            arguments: ["window_id": .integer(999)]
        )
        XCTAssertTrue(result.isError)
        let error = result.structuredContent?.objectValue?["error"]?.objectValue
        XCTAssertEqual(error?["code"], .string("window_unavailable"))
        XCTAssertTrue(error?["recovery"]?.stringValue?.contains("opensnapx_list_windows") == true)
    }

    func testMissingPermissionReturnsActionableToolError() async throws {
        let fixtures = try MCPFixtures()
        let service = MCPToolService(
            windowService: fixtures.windowService,
            ocrService: fixtures.ocrService,
            permissionChecker: { false }
        )
        let result = await service.callTool(name: MCPToolService.listWindowsToolName, arguments: [:])
        XCTAssertTrue(result.isError)
        let error = result.structuredContent?.objectValue?["error"]?.objectValue
        XCTAssertEqual(error?["code"], .string("screen_recording_permission_required"))
        XCTAssertTrue(error?["recovery"]?.stringValue?.contains("Accessibility permission is not required") == true)
    }
}

@MainActor
final class MCPServerLifecycleTests: XCTestCase {
    func testBundledAgentSkillContainsConnectorAndOneShotHelper() throws {
        let skill = try XCTUnwrap(Bundle.main.url(forResource: "opensnapx-ocr", withExtension: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: skill.appendingPathComponent("scripts/connect.sh").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: skill.appendingPathComponent("scripts/call.sh").path))
    }

    func testServerPublishesAndRemovesRestrictedSocket() throws {
        let root = FileManager.default.temporaryDirectory
        let pointer = root.appendingPathComponent("opensnapx-mcp-test-\(UUID().uuidString.prefix(8)).pointer")
        defer { try? FileManager.default.removeItem(at: pointer) }
        let server = UnixSocketMCPServer(
            toolHandler: StubMCPToolHandler(),
            socketDirectory: root,
            pointerURL: pointer
        )

        server.start()
        XCTAssertEqual(server.status.phase, .listening)
        let socketPath = try String(contentsOf: pointer, encoding: .utf8)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath, isDirectory: &isDirectory))
        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        server.stop()
        XCTAssertEqual(server.status.phase, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pointer.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testGeneratedMCPConfigurationEscapesUnusualPaths() throws {
        let skillURL = URL(fileURLWithPath: "/tmp/OpenSnapX \"skill\"\nfolder")
        let configuration = LocalAgentSkillInstaller.mcpConfiguration(for: skillURL)
        let data = try XCTUnwrap(configuration.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: [String: String]]]
        )
        XCTAssertEqual(
            object["mcpServers"]?["opensnapx"]?["command"],
            skillURL.appendingPathComponent("scripts/connect.sh").path
        )
    }
}

private struct StubMCPToolHandler: MCPToolHandling {
    let toolDefinitions = [
        MCPToolDefinition(
            name: "stub_tool",
            title: "Stub",
            description: "Test tool",
            inputSchema: .object(["type": .string("object")]),
            outputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("ok")])
            ])
        )
    ]

    func callTool(name: String, arguments: [String: JSONValue]) async -> MCPToolCallResult {
        .success(structuredContent: .object(["ok": .bool(true)]), imageData: Data([1, 2, 3]))
    }
}

private struct MCPFixtures {
    let windowService: FixtureWindowService
    let ocrService: FixtureOCRService

    init() throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 4,
            height: 3,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let image = try XCTUnwrap(context.makeImage())
        let app = RunningApplicationCandidate(
            processID: 100,
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            isActive: false,
            isHidden: false
        )
        let available = WindowCandidate(
            id: 42,
            title: "Document",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            processID: 100,
            frame: CGRect(x: 10, y: 20, width: 200, height: 100),
            isOnScreen: true,
            windowLayer: 0
        )
        let minimized = WindowCandidate(
            id: 43,
            title: "Minimized",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            processID: 100,
            frame: CGRect(x: 0, y: 0, width: 200, height: 100),
            isOnScreen: false,
            windowLayer: 0
        )
        let result = CaptureResult(image: image, mode: .window, displayScale: 2)
        windowService = FixtureWindowService(
            catalog: WindowCatalog(applications: [app], windows: [available, minimized]),
            capture: WindowCapture(result: result, window: available)
        )
        ocrService = FixtureOCRService(results: [
            OCRResult(text: "Hello", confidence: 0.99, normalizedBounds: CanvasRect(CGRect(x: 0, y: 0, width: 1, height: 0.4))),
            OCRResult(text: "World", confidence: 0.95, normalizedBounds: CanvasRect(CGRect(x: 0, y: 0.5, width: 1, height: 0.4)))
        ])
    }
}

private struct FixtureWindowService: WindowCaptureService {
    let catalog: WindowCatalog
    let capture: WindowCapture

    func windowCatalog(includeOffscreenWindows: Bool) async throws -> WindowCatalog { catalog }
    func captureWindow(id: UInt32) async throws -> WindowCapture {
        guard id == capture.window.id else { throw OpenSnapXError.windowUnavailable("Missing") }
        return capture
    }
}

private struct FixtureOCRService: OCRService {
    let results: [OCRResult]
    func recognize(_ image: ImagePayload) async throws -> [OCRResult] { results }
}

private struct DimensionOCRService: OCRService {
    func recognize(_ image: ImagePayload) async throws -> [OCRResult] {
        [OCRResult(
            text: "\(image.image.width)x\(image.image.height)",
            confidence: 1,
            normalizedBounds: CanvasRect(CGRect(x: 0, y: 0, width: 1, height: 1))
        )]
    }
}
