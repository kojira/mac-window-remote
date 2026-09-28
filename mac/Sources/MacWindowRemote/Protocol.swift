import Foundation

// Wire protocol (DESIGN.md §4). Text messages are single JSON objects with a `t` field.
// Binary messages are `[uint32 BE headerLength][JSON header][payload]` (§4.1).

enum CloseCode {
    static let authFailed: UInt16 = 4001
    static let replaced: UInt16 = 4002
    static let protocolError: UInt16 = 4003
}

enum ErrorCode: String, Codable {
    case badRequest = "bad_request"
    case tooLarge = "too_large"
    case unsupportedType = "unsupported_type"
    case windowNotFound = "window_not_found"
    case staleCoordinates = "stale_coordinates"
    case permissionScreenRecording = "permission_screen_recording"
    case permissionAccessibility = "permission_accessibility"
    case `internal` = "internal"
}

struct Rect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

// MARK: Client → server

enum PointerAction: String {
    case click
    case doubleClick
}

enum ClientMessage: Equatable {
    case auth(secret: String)
    case windowsList
    case viewStart(windowId: UInt32)
    case viewStop
    case frameAck(frameId: Int)
    case pointer(action: PointerAction, u: Double, v: Double, frameId: Int?)
    case scroll(u: Double, v: Double, du: Double, dv: Double, frameId: Int?)
    case text(String)
    case key(name: String)
}

enum ProtocolError: Error, Equatable {
    case malformed
    case unknownType(String)
    case invalidValue(String)
}

extension ClientMessage {
    private struct Envelope: Decodable {
        let t: String
        let secret: String?
        let windowId: UInt32?
        let frameId: Int?
        let action: String?
        let u: Double?
        let v: Double?
        let du: Double?
        let dv: Double?
        let text: String?
        let key: String?
        let mods: [String]?
    }

    static func decode(_ data: Data) throws -> ClientMessage {
        let e: Envelope
        do {
            e = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ProtocolError.malformed
        }
        func require<T>(_ value: T?, _ name: String) throws -> T {
            guard let value else { throw ProtocolError.invalidValue(name) }
            return value
        }
        func unit(_ value: Double?, _ name: String) throws -> Double {
            let x = try require(value, name)
            guard x.isFinite, x >= 0, x <= 1 else { throw ProtocolError.invalidValue(name) }
            return x
        }
        func delta(_ value: Double?, _ name: String) throws -> Double {
            let x = try require(value, name)
            guard x.isFinite, abs(x) <= 10 else { throw ProtocolError.invalidValue(name) }
            return x
        }
        switch e.t {
        case "auth":
            return .auth(secret: try require(e.secret, "secret"))
        case "windows.list":
            return .windowsList
        case "view.start":
            return .viewStart(windowId: try require(e.windowId, "windowId"))
        case "view.stop":
            return .viewStop
        case "frame.ack":
            return .frameAck(frameId: try require(e.frameId, "frameId"))
        case "pointer":
            guard let action = PointerAction(rawValue: try require(e.action, "action")) else {
                throw ProtocolError.invalidValue("action")
            }
            return .pointer(action: action, u: try unit(e.u, "u"), v: try unit(e.v, "v"), frameId: e.frameId)
        case "scroll":
            return .scroll(
                u: try unit(e.u, "u"), v: try unit(e.v, "v"),
                du: try delta(e.du, "du"), dv: try delta(e.dv, "dv"),
                frameId: e.frameId)
        case "text":
            return .text(try require(e.text, "text"))
        case "key":
            let name = try require(e.key, "key")
            guard KeyMap.keyCode(for: name) != nil else { throw ProtocolError.invalidValue("key") }
            // Modifier combos arrive with the key bar in slice 4.
            guard (e.mods ?? []).isEmpty else { throw ProtocolError.invalidValue("mods") }
            return .key(name: name)
        default:
            throw ProtocolError.unknownType(e.t)
        }
    }
}

// MARK: Server → client

struct PermissionsStatus: Codable, Equatable {
    var screenRecording: Bool
    var accessibility: Bool
}

struct WindowItem: Codable, Equatable {
    var id: UInt32
    var pid: Int32
    var app: String
    var title: String
    var w: Double
    var h: Double
}

enum ViewState: String, Codable {
    case starting, streaming
    case windowGone = "window_gone"
    case captureUnavailable = "capture_unavailable"
    case stopped
}

enum ServerMessage {
    case hello(permissions: PermissionsStatus)
    case windows([WindowItem])
    case viewState(windowId: UInt32, state: ViewState, reason: String?)
    case error(code: ErrorCode, message: String, id: String? = nil)
    case ping

    private struct Hello: Encodable { let t = "hello"; let server = "0.1"; let permissions: PermissionsStatus }
    private struct Windows: Encodable { let t = "windows"; let items: [WindowItem] }
    private struct View: Encodable {
        let t = "view.state"; let windowId: UInt32; let state: ViewState; let reason: String?
    }
    private struct Failure: Encodable { let t = "error"; let id: String?; let code: ErrorCode; let message: String }
    private struct Ping: Encodable { let t = "ping" }

    func jsonString() -> String {
        let encoder = JSONEncoder()
        let data: Data?
        switch self {
        case .hello(let p): data = try? encoder.encode(Hello(permissions: p))
        case .windows(let items): data = try? encoder.encode(Windows(items: items))
        case .viewState(let id, let state, let reason):
            data = try? encoder.encode(View(windowId: id, state: state, reason: reason))
        case .error(let code, let message, let id):
            data = try? encoder.encode(Failure(id: id, code: code, message: message))
        case .ping: data = try? encoder.encode(Ping())
        }
        return String(decoding: data ?? Data(), as: UTF8.self)
    }
}

/// Header of a binary `frame` message (§4.1, D7).
struct FrameHeader: Codable, Equatable {
    var t = "frame"
    var frameId: Int
    var windowId: UInt32
    var width: Int
    var height: Int
    /// The window's content rect inside the image, in image px.
    var content: Rect
    /// The window's global frame in points at capture time (top-left origin, CG global coordinates).
    var window: Rect
}

// MARK: Binary framing

enum BinaryFraming {
    static func encode(header: Data, payload: Data) -> Data {
        var out = Data(capacity: 4 + header.count + payload.count)
        let length = UInt32(header.count).bigEndian
        withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
        out.append(header)
        out.append(payload)
        return out
    }

    static func decode(_ message: Data) throws -> (header: Data, payload: Data) {
        let bytes = [UInt8](message.prefix(4))
        guard bytes.count == 4 else { throw ProtocolError.malformed }
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length <= message.count - 4 else { throw ProtocolError.malformed }
        let start = message.startIndex + 4
        let header = message.subdata(in: start..<(start + length))
        let payload = message.subdata(in: (start + length)..<message.endIndex)
        return (header, payload)
    }
}
