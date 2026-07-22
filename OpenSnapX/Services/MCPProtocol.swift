import Foundation

actor MCPClientSession {
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    private let toolHandler: any MCPToolHandling
    private let onToolActivity: @Sendable (Bool) -> Void
    private var negotiatedProtocolVersion: String?
    private var initialized = false
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        toolHandler: any MCPToolHandling,
        onToolActivity: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        self.toolHandler = toolHandler
        self.onToolActivity = onToolActivity
        encoder.outputFormatting = [.sortedKeys]
    }

    func handle(_ data: Data) async -> Data? {
        let value: JSONValue
        do {
            value = try decoder.decode(JSONValue.self, from: data)
        } catch {
            return encode(errorResponse(id: .null, code: -32700, message: "Parse error"))
        }
        guard let request = value.objectValue,
              request["jsonrpc"]?.stringValue == "2.0",
              let method = request["method"]?.stringValue else {
            return encode(errorResponse(id: requestID(from: value) ?? .null, code: -32600, message: "Invalid Request"))
        }

        let id = request["id"]
        if let id, !id.isRequestID {
            return encode(errorResponse(id: .null, code: -32600, message: "Invalid Request"))
        }
        let params: [String: JSONValue]
        if let paramsValue = request["params"] {
            guard let object = paramsValue.objectValue else {
                guard let id else { return nil }
                return encode(errorResponse(id: id, code: -32602, message: "Request parameters must be an object"))
            }
            params = object
        } else {
            params = [:]
        }

        switch method {
        case "initialize":
            guard let id else { return nil }
            guard params["protocolVersion"]?.stringValue?.isEmpty == false,
                  params["capabilities"]?.objectValue != nil,
                  let clientInfo = params["clientInfo"]?.objectValue,
                  clientInfo["name"]?.stringValue?.isEmpty == false,
                  clientInfo["version"]?.stringValue?.isEmpty == false else {
                return encode(errorResponse(id: id, code: -32602, message: "Invalid initialize parameters"))
            }
            return encode(initializeResponse(id: id, params: params))

        case "notifications/initialized":
            if negotiatedProtocolVersion != nil { initialized = true }
            return nil

        case "notifications/cancelled":
            return nil

        case "ping":
            guard let id else { return nil }
            return encode(successResponse(id: id, result: .object([:])))

        case "tools/list":
            guard let id else { return nil }
            guard initialized else {
                return encode(errorResponse(id: id, code: -32002, message: "MCP session is not initialized"))
            }
            return encode(successResponse(id: id, result: listToolsResult()))

        case "tools/call":
            guard let id else { return nil }
            guard initialized else {
                return encode(errorResponse(id: id, code: -32002, message: "MCP session is not initialized"))
            }
            guard let name = params["name"]?.stringValue else {
                return encode(errorResponse(id: id, code: -32602, message: "Tool name is required"))
            }
            guard toolHandler.toolDefinitions.contains(where: { $0.name == name }) else {
                return encode(errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)"))
            }
            let arguments: [String: JSONValue]
            if let argumentValue = params["arguments"] {
                guard let object = argumentValue.objectValue else {
                    return encode(errorResponse(id: id, code: -32602, message: "Tool arguments must be an object"))
                }
                arguments = object
            } else {
                arguments = [:]
            }
            onToolActivity(true)
            let result = await toolHandler.callTool(name: name, arguments: arguments)
            onToolActivity(false)
            return encode(successResponse(id: id, result: toolCallValue(result)))

        default:
            guard let id else { return nil }
            return encode(errorResponse(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func initializeResponse(id: JSONValue, params: [String: JSONValue]) -> JSONValue {
        let requestedVersion = params["protocolVersion"]?.stringValue
        let version = requestedVersion.flatMap {
            Self.supportedProtocolVersions.contains($0) ? $0 : nil
        } ?? Self.supportedProtocolVersions[0]
        negotiatedProtocolVersion = version
        initialized = false
        var serverInfo: [String: JSONValue] = [
            "name": .string("opensnapx-local-ocr"),
            "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
        ]
        if version != "2025-03-26" {
            serverInfo["title"] = .string("OpenSnapX Local Window OCR")
            serverInfo["description"] = .string("Local, on-device macOS window capture and OCR")
        }
        return successResponse(id: id, result: .object([
            "protocolVersion": .string(version),
            "capabilities": .object([
                "tools": .object([:])
            ]),
            "serverInfo": .object(serverInfo),
            "instructions": .string("opensnapx_list_windows defaults to available windows and a 50-result limit. Prefer opensnapx_capture_window_ocr with query and/or an exact bundle_id; use list_windows when targeting is ambiguous. For ordinary text-reading requests, omit include_screenshot and include_ocr_blocks. Captures are never saved to OpenSnapX history.")
        ]))
    }

    private func listToolsResult() -> JSONValue {
        let supportsStructuredContent = negotiatedProtocolVersion != "2025-03-26"
        return .object([
            "tools": .array(toolHandler.toolDefinitions.map { definition in
                var tool: [String: JSONValue] = [
                    "name": .string(definition.name),
                    "description": .string(definition.description),
                    "inputSchema": definition.inputSchema,
                    "annotations": .object([
                        "readOnlyHint": .bool(true),
                        "destructiveHint": .bool(false),
                        "idempotentHint": .bool(false),
                        "openWorldHint": .bool(false)
                    ])
                ]
                if supportsStructuredContent {
                    tool["title"] = .string(definition.title)
                    if let outputSchema = definition.outputSchema { tool["outputSchema"] = outputSchema }
                }
                return .object(tool)
            })
        ])
    }

    private func toolCallValue(_ result: MCPToolCallResult) -> JSONValue {
        var value: [String: JSONValue] = [
            "content": .array(result.content.map { content in
                switch content {
                case let .text(text):
                    return .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                case let .image(data, mimeType):
                    return .object([
                        "type": .string("image"),
                        "data": .string(data.base64EncodedString()),
                        "mimeType": .string(mimeType)
                    ])
                }
            }),
            "isError": .bool(result.isError)
        ]
        if negotiatedProtocolVersion != "2025-03-26",
           let structuredContent = result.structuredContent {
            value["structuredContent"] = structuredContent
        }
        return .object(value)
    }

    private func successResponse(id: JSONValue, result: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result
        ])
    }

    private func errorResponse(id: JSONValue, code: Int64, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .integer(code),
                "message": .string(message)
            ])
        ])
    }

    private func requestID(from value: JSONValue) -> JSONValue? {
        value.objectValue?["id"]
    }

    private func encode(_ value: JSONValue) -> Data? {
        try? encoder.encode(value)
    }
}
