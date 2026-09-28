import Foundation

// Wire protocol (DESIGN.md §4, amended by D22 and D28). Every message is one JSON object with a
// `t` field. The WebSocket carries auth, the window list, viewing, and WebRTC signaling; the
// data channels `motion` and `control` carry input and input results (D22).

enum CloseCode {
    /// Not the Mac owner's Tailscale login, or no login (D32).
    static let notAllowed: UInt16 = 4001
    static let replaced: UInt16 = 4002
}

enum ErrorCode: String, Codable {
    case badRequest = "bad_request"
    case tooLarge = "too_large"
    case unsupportedType = "unsupported_type"
    case windowNotFound = "window_not_found"
    case permissionScreenRecording = "permission_screen_recording"
    case permissionAccessibility = "permission_accessibility"
    /// The server could not answer a WebRTC offer (D28).
    case rtcFailed = "rtc_failed"
    case `internal` = "internal"
}

// MARK: Client → server

enum ClientMessage: Equatable {
    case windowsList
    case viewStart(windowId: UInt32)
    case viewStop
    /// WebRTC offer for peer connection number `pc` (D22).
    case rtcOffer(pc: Int, sdp: String)
    /// Trickled ICE candidate; nil is the end of candidates (D22).
    case rtcIce(pc: Int, candidate: RemoteCandidate?)
    /// Relative cursor move in window-normalized units (D24).
    case move(seq: Int, dx: Double, dy: Double)
    /// Scroll in window-normalized units (D26).
    case scroll(du: Double, dv: Double)
    case click
    case rightClick
    case drag(start: Bool)
    case text(String)
    case key(name: String)
}

struct RemoteCandidate: Equatable, Sendable {
    var sdp: String
    var sdpMid: String?
    var sdpMLineIndex: Int32?
}

/// Where a client message arrived (D22). Each type is accepted on exactly one of them.
enum MessageChannel: Sendable {
    case socket, motion, control
}

enum ProtocolError: Error, Equatable {
    case malformed
    case unknownType(String)
    case invalidValue(String)
    /// A known type on a channel that does not carry it (D22).
    case wrongChannel(String)
}

extension ClientMessage {
    private struct Envelope: Decodable {
        let t: String
        let windowId: UInt32?
        let pc: Int?
        let sdp: String?
        let candidate: String?
        let sdpMid: String?
        let sdpMLineIndex: Int32?
        let seq: Int?
        let dx: Double?
        let dy: Double?
        let du: Double?
        let dv: Double?
        let state: String?
        let text: String?
        let key: String?
        let mods: [String]?
    }

    /// Decodes a message and checks that `channel` carries its type (D22, D28).
    static func decode(_ data: Data, on channel: MessageChannel) throws -> ClientMessage {
        let message = try decode(data)
        guard message.channel == channel else { throw ProtocolError.wrongChannel(message.typeName) }
        return message
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
        func peerNumber(_ value: Int?) throws -> Int {
            let pc = try require(value, "pc")
            guard pc >= 0 else { throw ProtocolError.invalidValue("pc") }
            return pc
        }
        // D28: deltas are finite and within [-1, 1].
        func delta(_ value: Double?, _ name: String) throws -> Double {
            let x = try require(value, name)
            guard x.isFinite, abs(x) <= 1 else { throw ProtocolError.invalidValue(name) }
            return x
        }
        switch e.t {
        case "windows.list":
            return .windowsList
        case "view.start":
            return .viewStart(windowId: try require(e.windowId, "windowId"))
        case "view.stop":
            return .viewStop
        case "rtc.offer":
            return .rtcOffer(pc: try peerNumber(e.pc), sdp: try require(e.sdp, "sdp"))
        case "rtc.ice":
            let pc = try peerNumber(e.pc)
            guard let sdp = e.candidate else { return .rtcIce(pc: pc, candidate: nil) }
            return .rtcIce(pc: pc, candidate: RemoteCandidate(sdp: sdp, sdpMid: e.sdpMid, sdpMLineIndex: e.sdpMLineIndex))
        case "move":
            let seq = try require(e.seq, "seq")
            guard seq >= 0 else { throw ProtocolError.invalidValue("seq") }
            return .move(seq: seq, dx: try delta(e.dx, "dx"), dy: try delta(e.dy, "dy"))
        case "scroll":
            return .scroll(du: try delta(e.du, "du"), dv: try delta(e.dv, "dv"))
        case "click":
            return .click
        case "rightClick":
            return .rightClick
        case "drag":
            switch try require(e.state, "state") {
            case "start": return .drag(start: true)
            case "end": return .drag(start: false)
            default: throw ProtocolError.invalidValue("state")
            }
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

    /// The channel that carries this message type (D22).
    var channel: MessageChannel {
        switch self {
        case .windowsList, .viewStart, .viewStop, .rtcOffer, .rtcIce: return .socket
        case .move, .scroll: return .motion
        case .click, .rightClick, .drag, .text, .key: return .control
        }
    }

    var typeName: String {
        switch self {
        case .windowsList: return "windows.list"
        case .viewStart: return "view.start"
        case .viewStop: return "view.stop"
        case .rtcOffer: return "rtc.offer"
        case .rtcIce: return "rtc.ice"
        case .move: return "move"
        case .scroll: return "scroll"
        case .click: return "click"
        case .rightClick: return "rightClick"
        case .drag: return "drag"
        case .text: return "text"
        case .key: return "key"
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
    /// Server-confirmed cursor position (D24); `seq` is the highest applied `move.seq`.
    case cursor(u: Double, v: Double, seq: Int)
    case rtcAnswer(pc: Int, sdp: String)
    /// Local ICE candidate; nil is the end of candidates (D22).
    case rtcIce(pc: Int, candidate: LocalCandidate?)

    private struct Hello: Encodable { let t = "hello"; let server = "0.1"; let permissions: PermissionsStatus }
    private struct Windows: Encodable { let t = "windows"; let items: [WindowItem] }
    private struct View: Encodable {
        let t = "view.state"; let windowId: UInt32; let state: ViewState; let reason: String?
    }
    private struct Failure: Encodable { let t = "error"; let id: String?; let code: ErrorCode; let message: String }
    private struct Ping: Encodable { let t = "ping" }
    private struct Cursor: Encodable { let t = "cursor"; let u: Double; let v: Double; let seq: Int }
    private struct Answer: Encodable { let t = "rtc.answer"; let pc: Int; let sdp: String }
    private struct Ice: Encodable {
        let pc: Int
        let candidate: LocalCandidate?
        enum Keys: String, CodingKey { case t, pc, candidate, sdpMid, sdpMLineIndex }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode("rtc.ice", forKey: .t)
            try c.encode(pc, forKey: .pc)
            if let candidate {
                try c.encode(candidate.sdp, forKey: .candidate)
                try c.encodeIfPresent(candidate.sdpMid, forKey: .sdpMid)
                try c.encode(candidate.sdpMLineIndex, forKey: .sdpMLineIndex)
            } else {
                try c.encodeNil(forKey: .candidate)
            }
        }
    }

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
        case .cursor(let u, let v, let seq): data = try? encoder.encode(Cursor(u: u, v: v, seq: seq))
        case .rtcAnswer(let pc, let sdp): data = try? encoder.encode(Answer(pc: pc, sdp: sdp))
        case .rtcIce(let pc, let candidate): data = try? encoder.encode(Ice(pc: pc, candidate: candidate))
        }
        return String(decoding: data ?? Data(), as: UTF8.self)
    }
}

struct LocalCandidate: Equatable, Sendable {
    var sdp: String
    var sdpMid: String?
    var sdpMLineIndex: Int32
}
