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
    /// D35: the window's size cannot be set (or no AX window matches it).
    case windowNotResizable = "window_not_resizable"
    /// D35: full-screen windows are not resized.
    case windowFullscreen = "window_fullscreen"
    /// D35: restore without a saved frame.
    case windowNotFitted = "window_not_fitted"
    /// D39: Mac audio cannot be tapped (macOS before 14.2, or the tap could not be created).
    case audioUnavailable = "audio_unavailable"
    /// D39: the tap yields only silence while a tapped app plays, which is what a missing
    /// System Audio Recording grant looks like.
    case permissionAudioCapture = "permission_audio_capture"
    /// D40: `app.open` with an id that is not in the last app list.
    case appNotFound = "app_not_found"
    /// D40: the app could not be launched or activated.
    case appLaunchFailed = "app_launch_failed"
    /// D40: no window of the opened app appeared within 10 s.
    case appNoWindow = "app_no_window"
    /// D43: the viewed app has no readable menu bar.
    case menuUnavailable = "menu_unavailable"
    /// D43: the pressed item is not in the current listing or the menu changed since.
    case menuStale = "menu_stale"
    /// D43: the item is disabled now.
    case menuDisabled = "menu_disabled"
    /// D43: AXPress failed.
    case menuFailed = "menu_failed"
    /// D47: the path does not exist.
    case notFound = "not_found"
    /// D47: a folder was expected.
    case notADirectory = "not_a_directory"
    /// D47: permission or privacy (TCC) refusal.
    case noAccess = "no_access"
    case `internal` = "internal"
}

// MARK: Client → server

enum ClientMessage: Equatable {
    case windowsList
    case viewStart(windowId: UInt32)
    case viewStop
    /// Thumbnails of the quick-switch slot windows, at most `maxThumbnailRequest` (D33).
    case thumbsRequest(windowIds: [UInt32])
    /// WebRTC offer for peer connection number `pc` (D22).
    case rtcOffer(pc: Int, sdp: String)
    /// Trickled ICE candidate; nil is the end of candidates (D22).
    case rtcIce(pc: Int, candidate: RemoteCandidate?)
    /// Relative cursor move in window-normalized units (D24).
    case move(seq: Int, dx: Double, dy: Double)
    /// Scroll in window-normalized units (D26).
    case scroll(du: Double, dv: Double)
    /// Absolute cursor position in window-normalized units, from a desktop mouse (D45). `seq`
    /// shares the `move` counter; a point older than the last applied one is dropped.
    case point(seq: Int, u: Double, v: Double)
    /// A desktop mouse button going down or up at (u, v), with the browser's click count (D45).
    case mouse(button: MouseButton, down: Bool, clicks: Int, seq: Int, u: Double, v: Double)
    case click
    case rightClick
    case drag(start: Bool)
    case text(String)
    /// `mods` are distinct and in `KeyModifier` case order (D34).
    case key(name: String, mods: [KeyModifier])
    /// Resize the viewed window to `aspect` (width / height) on its screen (D35).
    case windowFitPhone(aspect: Double)
    /// Put the viewed window back to its frame before the first fit (D35).
    case windowRestore
    /// Play Mac audio on the phone: off, the viewed window's app, or the whole Mac (D39).
    case audio(mode: AudioMode)
    /// The Apps tab list (D40).
    case appsList
    /// Launch or activate an app of the last list and view its front window (D40).
    case appOpen(id: String)
    /// The viewed app's menu bar (D43).
    case menuList
    /// Press the item `id` of listing `gen` (D43).
    case menuPress(id: String, gen: Int)
    /// A folder listing (D47) in `sort` order (D55); `path` is absolute or starts with `~`.
    case filesList(id: String, path: String, hidden: Bool, sort: FileSort)
    /// File-name search under `base` (D47).
    case filesSearch(id: String, base: String, query: String, hidden: Bool)
    /// A one-time download URL for exactly these absolute paths (D47).
    case downloadRequest(id: String, paths: [String])
}

/// A desktop mouse button (D45).
enum MouseButton: String, Sendable, Equatable {
    case left, right, middle
}

/// What Mac audio goes to the phone (D39). Not persisted on the Mac; the phone re-sends it.
enum AudioMode: String, Codable, Equatable, Sendable {
    case off, app, all
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
        let windowIds: [UInt32]?
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
        let aspect: Double?
        let mode: String?
        let id: String?
        let gen: Int?
        let u: Double?
        let v: Double?
        let button: String?
        let clicks: Int?
        let path: String?
        let hidden: Bool?
        let base: String?
        let q: String?
        let paths: [String]?
        let sort: String?
        let desc: Bool?
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
        func sequence() throws -> Int {
            let seq = try require(e.seq, "seq")
            guard seq >= 0 else { throw ProtocolError.invalidValue("seq") }
            return seq
        }
        // D45: an absolute position is finite and within [0, 1].
        func position(_ value: Double?, _ name: String) throws -> Double {
            let x = try require(value, name)
            guard x.isFinite, (0...1).contains(x) else { throw ProtocolError.invalidValue(name) }
            return x
        }
        func requestId() throws -> String {
            let id = try require(e.id, "id")
            guard !id.isEmpty, id.count <= 64 else { throw ProtocolError.invalidValue("id") }
            return id
        }
        switch e.t {
        case "windows.list":
            return .windowsList
        case "view.start":
            return .viewStart(windowId: try require(e.windowId, "windowId"))
        case "view.stop":
            return .viewStop
        case "thumbs.request":
            let ids = try require(e.windowIds, "windowIds")
            guard ids.count <= maxThumbnailRequest else { throw ProtocolError.invalidValue("windowIds") }
            return .thumbsRequest(windowIds: ids)
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
        case "point":
            return .point(seq: try sequence(), u: try position(e.u, "u"), v: try position(e.v, "v"))
        case "mouse":
            guard let button = MouseButton(rawValue: try require(e.button, "button")) else {
                throw ProtocolError.invalidValue("button")
            }
            let down: Bool
            switch try require(e.state, "state") {
            case "down": down = true
            case "up": down = false
            default: throw ProtocolError.invalidValue("state")
            }
            let clicks = e.clicks ?? 1
            guard (1...3).contains(clicks) else { throw ProtocolError.invalidValue("clicks") }
            return .mouse(button: button, down: down, clicks: clicks, seq: try sequence(),
                          u: try position(e.u, "u"), v: try position(e.v, "v"))
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
            // D34: each mod is known and appears at most once.
            let raw = e.mods ?? []
            let mods = raw.compactMap(KeyModifier.init(rawValue:))
            guard mods.count == raw.count, Set(mods).count == mods.count else {
                throw ProtocolError.invalidValue("mods")
            }
            return .key(name: name, mods: KeyModifier.allCases.filter(mods.contains))
        case "window.fitPhone":
            let aspect = try require(e.aspect, "aspect")
            guard aspect.isFinite, WindowFit.aspectRange.contains(aspect) else { throw ProtocolError.invalidValue("aspect") }
            return .windowFitPhone(aspect: aspect)
        case "window.restore":
            return .windowRestore
        case "audio":
            guard let mode = AudioMode(rawValue: try require(e.mode, "mode")) else {
                throw ProtocolError.invalidValue("mode")
            }
            return .audio(mode: mode)
        case "apps.list":
            return .appsList
        case "app.open":
            let id = try require(e.id, "id")
            guard !id.isEmpty, id.count <= 64 else { throw ProtocolError.invalidValue("id") }
            return .appOpen(id: id)
        case "menu.list":
            return .menuList
        case "menu.press":
            let id = try require(e.id, "id")
            guard MenuTree.path(id) != nil else { throw ProtocolError.invalidValue("id") }
            let gen = try require(e.gen, "gen")
            guard gen > 0 else { throw ProtocolError.invalidValue("gen") }
            return .menuPress(id: id, gen: gen)
        case "files.list":
            let path = try require(e.path, "path")
            guard !path.isEmpty, path.utf8.count <= maxPathBytes else { throw ProtocolError.invalidValue("path") }
            var sort = FileSort.name
            if let raw = e.sort {
                guard let key = FileSort.Key(rawValue: raw) else { throw ProtocolError.invalidValue("sort") }
                sort = FileSort(key: key, descending: e.desc ?? false)
            }
            return .filesList(id: try requestId(), path: path, hidden: e.hidden ?? false, sort: sort)
        case "files.search":
            let base = try require(e.base, "base")
            let query = try require(e.q, "q")
            guard !base.isEmpty, base.utf8.count <= maxPathBytes else { throw ProtocolError.invalidValue("base") }
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty, query.count <= 255 else {
                throw ProtocolError.invalidValue("q")
            }
            return .filesSearch(id: try requestId(), base: base, query: query, hidden: e.hidden ?? false)
        case "download.request":
            let paths = try require(e.paths, "paths")
            guard !paths.isEmpty, paths.count <= DownloadPlanner.maxPaths,
                  paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= maxPathBytes }) else {
                throw ProtocolError.invalidValue("paths")
            }
            return .downloadRequest(id: try requestId(), paths: paths)
        default:
            throw ProtocolError.unknownType(e.t)
        }
    }

    /// Longest path accepted from the client (D47); macOS paths are at most 1024 bytes.
    static let maxPathBytes = 4096

    /// The phone has three quick-switch slots (D33).
    static let maxThumbnailRequest = 3

    /// The channel that carries this message type (D22).
    var channel: MessageChannel {
        switch self {
        case .windowsList, .viewStart, .viewStop, .thumbsRequest, .rtcOffer, .rtcIce, .appsList, .appOpen, .menuList, .menuPress,
             .filesList, .filesSearch, .downloadRequest:
            return .socket
        case .move, .scroll, .point: return .motion
        case .mouse, .click, .rightClick, .drag, .text, .key, .windowFitPhone, .windowRestore, .audio: return .control
        }
    }

    var typeName: String {
        switch self {
        case .windowsList: return "windows.list"
        case .viewStart: return "view.start"
        case .viewStop: return "view.stop"
        case .thumbsRequest: return "thumbs.request"
        case .rtcOffer: return "rtc.offer"
        case .rtcIce: return "rtc.ice"
        case .move: return "move"
        case .scroll: return "scroll"
        case .point: return "point"
        case .mouse: return "mouse"
        case .click: return "click"
        case .rightClick: return "rightClick"
        case .drag: return "drag"
        case .text: return "text"
        case .key: return "key"
        case .windowFitPhone: return "window.fitPhone"
        case .windowRestore: return "window.restore"
        case .audio: return "audio"
        case .appsList: return "apps.list"
        case .appOpen: return "app.open"
        case .menuList: return "menu.list"
        case .menuPress: return "menu.press"
        case .filesList: return "files.list"
        case .filesSearch: return "files.search"
        case .downloadRequest: return "download.request"
        }
    }
}

// MARK: Binary client → server (D36)

/// A binary WebSocket message (§4.1): `[uint32 BE headerLength][header JSON][payload]`.
/// Clipboard text and image uploads travel this way on the authenticated WebSocket (D36).
enum BinaryClientMessage: Equatable {
    /// Put `text` on the Mac clipboard and paste it into the viewed window.
    case clipboardPaste(id: String, text: String)
    /// Put `text` on the Mac clipboard only, without pasting (D52 Copy to Mac).
    case clipboardSet(id: String, text: String)
    /// One chunk of an image; `size` is the whole image, `offset` where `bytes` go.
    case imageChunk(id: String, size: Int, offset: Int, bytes: Data)
    /// One chunk of any file (D42); `name` is the phone's file name on the chunk at offset 0 and
    /// empty on the others.
    case fileChunk(id: String, size: Int, offset: Int, bytes: Data, name: String)

    /// Clipboard text is at most 1 MiB of UTF-8 (D11).
    static let maxClipboardBytes = 1 << 20
    /// The phone sends image chunks of this size; the last one may be shorter.
    static let maxChunkBytes = 256 << 10
    static let maxHeaderBytes = 1024

    private struct Header: Decodable {
        let t: String
        let id: String?
        let size: Int?
        let offset: Int?
        let name: String?
    }

    /// Decodes the framing, the header, and its values. A clipboard payload over 1 MiB throws
    /// `tooLarge` with the id, so the reply can name the request.
    static func decode(_ data: Data) throws -> BinaryClientMessage {
        let bytes = [UInt8](data.prefix(4))
        guard bytes.count == 4 else { throw ProtocolError.malformed }
        let headerLength = bytes.reduce(0) { $0 << 8 | Int($1) }
        guard headerLength > 0, headerLength <= maxHeaderBytes, data.count >= 4 + headerLength else {
            throw ProtocolError.malformed
        }
        let start = data.startIndex
        let headerData = data[(start + 4)..<(start + 4 + headerLength)]
        let payload = Data(data[(start + 4 + headerLength)...])
        let h: Header
        do { h = try JSONDecoder().decode(Header.self, from: headerData) } catch { throw ProtocolError.malformed }
        guard let id = h.id, !id.isEmpty, id.count <= 64 else { throw ProtocolError.invalidValue("id") }
        switch h.t {
        case "clipboard.paste", "clipboard.set":
            guard payload.count <= maxClipboardBytes else { throw UploadRejection(id: id, code: .tooLarge) }
            guard !payload.isEmpty, let text = String(data: payload, encoding: .utf8) else {
                throw ProtocolError.invalidValue("text")
            }
            return h.t == "clipboard.paste" ? .clipboardPaste(id: id, text: text) : .clipboardSet(id: id, text: text)
        case "image.chunk", "file.chunk":
            guard let size = h.size, size > 0 else { throw ProtocolError.invalidValue("size") }
            guard let offset = h.offset, offset >= 0 else { throw ProtocolError.invalidValue("offset") }
            guard !payload.isEmpty, payload.count <= maxChunkBytes, offset + payload.count <= size else {
                throw ProtocolError.invalidValue("chunk")
            }
            if h.t == "image.chunk" { return .imageChunk(id: id, size: size, offset: offset, bytes: payload) }
            return .fileChunk(id: id, size: size, offset: offset, bytes: payload, name: offset == 0 ? h.name ?? "" : "")
        default:
            throw ProtocolError.unknownType(h.t)
        }
    }
}

/// A request rejected with a specific error code and its id (D36).
struct UploadRejection: Error, Equatable {
    let id: String
    let code: ErrorCode
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
    /// A slot window's thumbnail; nil when there is none (D33).
    case thumb(windowId: UInt32, jpeg: Data?)
    /// Result of `window.fitPhone` / `window.restore` (D35).
    case windowFit(windowId: UInt32, state: WindowFitState, clamped: Bool)
    /// Success of a binary request (D36); `path` is the saved image.
    case result(id: String, path: String?)
    /// The view moved to the window that ⌘Tab or ⌘F1 brought forward (D38).
    case viewSwitched(windowId: UInt32, app: String, title: String)
    /// The audio mode the Mac applies (D39): the echo of `audio`, or `off` after a failure.
    case audioState(mode: AudioMode)
    /// The Apps tab list (D40).
    case apps([AppItem])
    /// The viewed app's menus (D43); `gen` names this listing for `menu.press`.
    case menu(gen: Int, windowId: UInt32, listing: MenuListing)
    /// A `menu.press` succeeded (D43).
    case menuPressed(id: String)
    /// A folder listing with the quick places (D47).
    case files(id: String, listing: FileListing, places: [FilePlace])
    /// File-name search results (D47).
    case filesFound(id: String, result: FileSearchResult)
    /// A one-time download URL (D47).
    case downloadReady(id: String, url: String, name: String, size: Int64)
    /// Text copied on the Mac (D51); nil text means it was over 1 MiB and is not sent.
    case clipboardMac(seq: Int, text: String?)

    private struct Hello: Encodable { let t = "hello"; let server = "0.1"; let permissions: PermissionsStatus }
    private struct Windows: Encodable { let t = "windows"; let items: [WindowItem] }
    private struct View: Encodable {
        let t = "view.state"; let windowId: UInt32; let state: ViewState; let reason: String?
    }
    private struct Failure: Encodable { let t = "error"; let id: String?; let code: ErrorCode; let message: String }
    private struct Ping: Encodable { let t = "ping" }
    private struct Cursor: Encodable { let t = "cursor"; let u: Double; let v: Double; let seq: Int }
    private struct Thumb: Encodable {
        let t = "thumb"; let windowId: UInt32; let jpeg: String?; let missing: Bool?
    }
    private struct Fit: Encodable {
        let t = "window.fit"; let windowId: UInt32; let state: WindowFitState; let clamped: Bool
    }
    private struct Switched: Encodable { let t = "view.switched"; let windowId: UInt32; let app: String; let title: String }
    private struct Apps: Encodable { let t = "apps"; let items: [AppItem] }
    private struct Menu: Encodable {
        let t = "menu"; let gen: Int; let windowId: UInt32; let menus: [MenuNode]; let truncated: Bool
    }
    private struct MenuPressed: Encodable { let t = "menu.pressed"; let id: String }
    private struct Files: Encodable {
        let t = "files"; let id: String; let path: String; let entries: [FileEntry]; let total: Int
        let truncated: Bool; let places: [FilePlace]
    }
    private struct Found: Encodable {
        let t = "files.found"; let id: String; let base: String; let entries: [FileEntry]
        let truncated: Bool; let timedOut: Bool
    }
    private struct Ready: Encodable { let t = "download.ready"; let id: String; let url: String; let name: String; let size: Int64 }
    private struct ClipboardMac: Encodable {
        let t = "clipboard.mac"; let seq: Int; let text: String?; let truncated: Bool?
    }
    private struct Audio: Encodable { let t = "audio.state"; let mode: AudioMode }
    private struct Result: Encodable { let t = "result"; let id: String; let ok = true; let path: String? }
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
        case .thumb(let id, let jpeg):
            data = try? encoder.encode(Thumb(windowId: id, jpeg: jpeg?.base64EncodedString(), missing: jpeg == nil ? true : nil))
        case .windowFit(let id, let state, let clamped):
            data = try? encoder.encode(Fit(windowId: id, state: state, clamped: clamped))
        case .result(let id, let path):
            data = try? encoder.encode(Result(id: id, path: path))
        case .viewSwitched(let id, let app, let title):
            data = try? encoder.encode(Switched(windowId: id, app: app, title: title))
        case .audioState(let mode):
            data = try? encoder.encode(Audio(mode: mode))
        case .apps(let items):
            data = try? encoder.encode(Apps(items: items))
        case .menu(let gen, let windowId, let listing):
            data = try? encoder.encode(Menu(gen: gen, windowId: windowId, menus: listing.menus, truncated: listing.truncated))
        case .menuPressed(let id):
            data = try? encoder.encode(MenuPressed(id: id))
        case .files(let id, let listing, let places):
            data = try? encoder.encode(Files(id: id, path: listing.path, entries: listing.entries, total: listing.total,
                                             truncated: listing.truncated, places: places))
        case .filesFound(let id, let result):
            data = try? encoder.encode(Found(id: id, base: result.base, entries: result.entries,
                                             truncated: result.truncated, timedOut: result.timedOut))
        case .downloadReady(let id, let url, let name, let size):
            data = try? encoder.encode(Ready(id: id, url: url, name: name, size: size))
        case .clipboardMac(let seq, let text):
            data = try? encoder.encode(ClipboardMac(seq: seq, text: text, truncated: text == nil ? true : nil))
        }
        return String(decoding: data ?? Data(), as: UTF8.self)
    }
}

struct LocalCandidate: Equatable, Sendable {
    var sdp: String
    var sdpMid: String?
    var sdpMLineIndex: Int32
}
