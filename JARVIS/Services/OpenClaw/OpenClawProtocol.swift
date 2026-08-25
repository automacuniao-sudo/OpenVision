// JARVIS - OpenClawProtocol.swift
// OpenClaw WebSocket protocol message types

import Foundation

// MARK: - Request/Response Types

struct OpenClawRequest: Codable {
    let type: String
    let id: String
    let method: String
    let params: [String: AnyCodable]

    init(id: String, method: String, params: [String: Any] = [:]) {
        self.type = "req"
        self.id = id
        self.method = method
        self.params = params.mapValues { AnyCodable($0) }
    }
}

struct OpenClawResponse: Codable {
    let type: String
    let id: String
    let ok: Bool
    let payload: [String: AnyCodable]?
    let error: OpenClawError?
}

struct OpenClawEvent: Codable {
    let type: String
    let event: String
    let payload: [String: AnyCodable]?
    let seq: Int?
}

struct OpenClawError: Codable {
    let code: String?
    let message: String?
    let details: [String: AnyCodable]?
}

// MARK: - AnyCodable

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let int64 as Int64:
            try container.encode(int64)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        case let array as [String]:
            try container.encode(array)
        case let dict as [String: Bool]:
            try container.encode(dict)
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Cannot encode value of type \(type(of: value))"))
        }
    }

    var stringValue: String? { value as? String }
    var intValue: Int? { value as? Int }
    var doubleValue: Double? { value as? Double }
    var boolValue: Bool? { value as? Bool }
    var arrayValue: [Any]? { value as? [Any] }
    var dictionaryValue: [String: Any]? { value as? [String: Any] }
}

// MARK: - Message Content Types

enum OpenClawContentType: String {
    case text
    case image
    case toolCall = "tool_call"
    case toolResult = "tool_result"
}

struct OpenClawImageContent {
    let mimeType: String
    let data: Data

    var base64Encoded: String { data.base64EncodedString() }

    init(jpegData: Data) {
        mimeType = "image/jpeg"
        data = jpegData
    }

    init(pngData: Data) {
        mimeType = "image/png"
        data = pngData
    }
}

// MARK: - Event Types

enum OpenClawEventType: String {
    case agentMessage = "agent_message"
    case toolStatus = "tool_status"
    case runStarted = "run_started"
    case runCompleted = "run_completed"
    case error = "error"
}

// MARK: - Method Names

enum OpenClawMethod: String {
    case connect = "connect"
    case sendMessage = "chat.send"
    case cancelRun = "run/cancel"
    case toolResult = "tool.result"
}
