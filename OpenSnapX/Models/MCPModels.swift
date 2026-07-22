import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var uint32Value: UInt32? {
        switch self {
        case let .integer(value) where value >= 0 && value <= Int64(UInt32.max):
            return UInt32(value)
        case let .number(value) where value.isFinite && value.rounded() == value && value >= 0 && value <= Double(UInt32.max):
            return UInt32(value)
        default:
            return nil
        }
    }

    var isRequestID: Bool {
        switch self {
        case .integer, .string:
            return true
        case let .number(value):
            return value.isFinite
        default:
            return false
        }
    }
}

struct MCPToolDefinition: Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    let outputSchema: JSONValue?
}

enum MCPContent: Sendable {
    case text(String)
    case image(Data, mimeType: String)
}

struct MCPToolCallResult: Sendable {
    let content: [MCPContent]
    let structuredContent: JSONValue?
    let isError: Bool

    static func success(
        structuredContent: JSONValue,
        imageData: Data? = nil,
        textContent: String? = nil
    ) -> MCPToolCallResult {
        let text: String
        if let textContent {
            text = textContent
        } else if let data = try? JSONEncoder().encode(structuredContent),
                  let encoded = String(data: data, encoding: .utf8) {
            text = encoded
        } else {
            text = "OpenSnapX completed the request."
        }
        var content: [MCPContent] = [.text(text)]
        if let imageData { content.append(.image(imageData, mimeType: "image/png")) }
        return MCPToolCallResult(content: content, structuredContent: structuredContent, isError: false)
    }

    static func failure(
        code: String,
        message: String,
        recovery: String? = nil,
        details: [String: JSONValue] = [:]
    ) -> MCPToolCallResult {
        var error = details
        error["code"] = .string(code)
        error["message"] = .string(message)
        if let recovery { error["recovery"] = .string(recovery) }
        return MCPToolCallResult(
            content: [.text(message + (recovery.map { " \($0)" } ?? ""))],
            structuredContent: .object(["error": .object(error)]),
            isError: true
        )
    }
}

protocol MCPToolHandling: Sendable {
    var toolDefinitions: [MCPToolDefinition] { get }
    func callTool(name: String, arguments: [String: JSONValue]) async -> MCPToolCallResult
}

enum MCPServerPhase: Equatable, Sendable {
    case stopped
    case starting
    case listening
    case failed(String)
}

struct MCPServerStatus: Equatable, Sendable {
    var phase: MCPServerPhase = .stopped
    var connectedClients = 0
    var activeRequests = 0
}

@MainActor
protocol MCPServer: AnyObject {
    var status: MCPServerStatus { get }
    var onStatusChange: (@MainActor (MCPServerStatus) -> Void)? { get set }
    func start()
    func stop()
}

enum AgentSkillInstallScope: Sendable {
    case global
    case project
}
