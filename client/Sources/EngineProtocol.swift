import Foundation

// ---------------------------------------------------------------------------
// ServerMessage — messages received from the engine (server → client).
//
// Decoded by first reading the "type" field, then switching on it to
// extract type-specific payload.
// ---------------------------------------------------------------------------

public enum ServerMessage {
    case ready
    case pong
    case progress(percent: Double)
    case result(text: String?, command: Command?)
    case error(code: String, message: String)
    case warning(code: String, message: String)
}

// ---------------------------------------------------------------------------
// Command — structured command extracted by the model.
// The engine sends null when no command is present, or {"action": "..."}.
// ---------------------------------------------------------------------------

public struct Command: Decodable {
    public let action: String
}

// ---------------------------------------------------------------------------
// Client→Server message structs — encode to JSON with a "type" field.
// ---------------------------------------------------------------------------

struct SessionStart: Encodable {
    let type: String = "session.start"
    let context: [String: String]
}

struct Ping: Encodable {
    let type: String = "ping"
}

struct Shutdown: Encodable {
    let type: String = "session.shutdown"
}

// ---------------------------------------------------------------------------
// TypeProbe — lightweight struct to read the "type" discriminator before
// dispatching to the full decode path.
// ---------------------------------------------------------------------------

private struct TypeProbe: Decodable {
    let type: String
}

// ---------------------------------------------------------------------------
// ServerMessage decoding
// ---------------------------------------------------------------------------

extension ServerMessage {
    public static func fromJSON(_ data: Data) throws -> ServerMessage {
        let probe = try JSONDecoder().decode(TypeProbe.self, from: data)

        switch probe.type {
        case "session.ready":
            return .ready
        case "pong":
            return .pong
        case "progress":
            struct Payload: Decodable { let percent: Double }
            let p = try JSONDecoder().decode(Payload.self, from: data)
            return .progress(percent: p.percent)
        case "result":
            struct Payload: Decodable {
                let text: String?
                let command: Command?
            }
            let p = try JSONDecoder().decode(Payload.self, from: data)
            return .result(text: p.text, command: p.command)
        case "error":
            struct Payload: Decodable {
                let code: String
                let message: String
            }
            let p = try JSONDecoder().decode(Payload.self, from: data)
            return .error(code: p.code, message: p.message)
        case "warning":
            struct Payload: Decodable {
                let code: String
                let message: String
            }
            let p = try JSONDecoder().decode(Payload.self, from: data)
            return .warning(code: p.code, message: p.message)
        default:
            throw EngineProtocolError.unknownType(probe.type)
        }
    }
}

public enum EngineProtocolError: Error, CustomStringConvertible {
    case unknownType(String)

    public var description: String {
        switch self {
        case .unknownType(let t):
            return "unknown server message type: \(t)"
        }
    }
}
