import Foundation

// ---------------------------------------------------------------------------
// EngineProtocol — message types for the OpenVerb engine IPC protocol.
//
// Wire format: newline-delimited JSON (text messages), plus raw binary frames
// for PCM audio (4-byte big-endian length + payload) — NOT decoded here.
//
// Server → client messages: ServerMessage enum.
// Client → server messages: SessionStart, Ping, Shutdown structs.
//
// NOTE: There is no SessionEnd JSON struct. End-of-audio is signaled by the
// binary sentinel: four zero bytes (0x00 0x00 0x00 0x00). The session.end
// JSON message exists only for the engine's built-in --mic mode (CLI path),
// which the app does not use.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// ServerMessage — messages received from the engine.
//
// Decoded via TypeProbe: first extract the "type" field, then decode the
// full payload for the matched type.
// ---------------------------------------------------------------------------

enum ServerMessage {
    case ready
    case pong
    /// percent: 0.0–1.0 (engine sends fractional value, not a 0–100 scale).
    /// Path A inference may produce non-monotonic estimates.
    case progress(percent: Double)
    case result(text: String?, command: Command?)
    case error(code: String, message: String)
    /// Warning does NOT end the session; client logs and continues streaming.
    case warning(code: String, message: String)
    case partialResult(text: String, chunkId: Int, isFinal: Bool)
    case queueStatus(pending: Int, inFlight: Int, etaMs: Int)
}

// ---------------------------------------------------------------------------
// Command — structured voice command in a result message.
//
// If the JSON has a "command" key but the "action" field is missing or empty,
// treat as no command (use text result instead).
// ---------------------------------------------------------------------------

struct Command: Decodable {
    let action: String
}

// ---------------------------------------------------------------------------
// Client → server message structs.
//
// All structs carry a `type` field that the engine uses as a discriminator.
// ---------------------------------------------------------------------------

struct SessionStart: Encodable {
    let type: String = "session.start"
    let context: [String: String]

    private enum CodingKeys: String, CodingKey {
        case type, context
    }
}

struct Ping: Encodable {
    let type: String = "ping"
}

struct Shutdown: Encodable {
    let type: String = "session.shutdown"
}

// ---------------------------------------------------------------------------
// TypeProbe — lightweight struct to read the "type" discriminator before
// dispatching to the full decode path.  Keeps decode logic simple and fast.
// ---------------------------------------------------------------------------

private struct TypeProbe: Decodable {
    let type: String
}

// ---------------------------------------------------------------------------
// ServerMessage decoding
// ---------------------------------------------------------------------------

extension ServerMessage {
    static func fromJSON(_ data: Data) throws -> ServerMessage {
        let decoder = JSONDecoder()
        let probe = try decoder.decode(TypeProbe.self, from: data)

        switch probe.type {
        case "session.ready":
            return .ready

        case "pong":
            return .pong

        case "progress":
            struct Payload: Decodable { let percent: Double }
            let p = try decoder.decode(Payload.self, from: data)
            return .progress(percent: p.percent)

        case "result":
            struct Payload: Decodable {
                let text: String?
                let command: RawCommand?

                struct RawCommand: Decodable {
                    let action: String?
                }
            }
            let p = try decoder.decode(Payload.self, from: data)
            // If action is missing or empty, treat as no command.
            let cmd: Command? = p.command.flatMap { raw in
                guard let a = raw.action, !a.isEmpty else { return nil }
                return Command(action: a)
            }
            return .result(text: p.text, command: cmd)

        case "error":
            struct Payload: Decodable { let code: String; let message: String }
            let p = try decoder.decode(Payload.self, from: data)
            return .error(code: p.code, message: p.message)

        case "warning":
            struct Payload: Decodable { let code: String; let message: String }
            let p = try decoder.decode(Payload.self, from: data)
            return .warning(code: p.code, message: p.message)

        case "partial_result":
            struct Payload: Decodable {
                let chunk_id: Int
                let text: String
                let is_final: Bool
            }
            let p = try decoder.decode(Payload.self, from: data)
            return .partialResult(text: p.text, chunkId: p.chunk_id, isFinal: p.is_final)

        case "queue_status":
            struct Payload: Decodable {
                let pending: Int
                let in_flight: Int
                let eta_ms: Int
            }
            let p = try decoder.decode(Payload.self, from: data)
            return .queueStatus(pending: p.pending, inFlight: p.in_flight, etaMs: p.eta_ms)

        default:
            throw EngineProtocolError.unknownType(probe.type)
        }
    }
}

// ---------------------------------------------------------------------------
// EngineProtocolError
// ---------------------------------------------------------------------------

enum EngineProtocolError: Error, CustomStringConvertible {
    case unknownType(String)

    var description: String {
        switch self {
        case .unknownType(let t):
            return "unknown server message type: \(t)"
        }
    }
}
