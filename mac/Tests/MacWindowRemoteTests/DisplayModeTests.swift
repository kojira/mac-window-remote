import CoreGraphics
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import HummingbirdWebSocket
import WSClient
import Testing
@testable import MacWindowRemote

private final class NoCapture: CaptureHandle { func stop() {} }

/// Records display-mode posts instead of CGEvents (D56).
private final class RecordingPoster: DisplayEventPoster, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var posts: [String] { lock.withLock { log } }
    private func add(_ s: String) { lock.withLock { log.append(s) } }
    func move(to p: CGPoint) async { add("move \(Int(p.x)),\(Int(p.y))") }
    func click(at p: CGPoint, clickState: Int) async { add("click \(Int(p.x)),\(Int(p.y)) x\(clickState)") }
    func rightClick(at p: CGPoint) async { add("rightClick \(Int(p.x)),\(Int(p.y))") }
    func buttonDown(_ button: CGMouseButton, at p: CGPoint, clickState: Int) async { add("down \(button.rawValue) \(Int(p.x)),\(Int(p.y))") }
    func buttonUp(_ button: CGMouseButton, at p: CGPoint, clickState: Int) async { add("up \(button.rawValue) \(Int(p.x)),\(Int(p.y))") }
    func scroll(at p: CGPoint, dx: Double, dy: Double) async { add("scroll \(Int(dx)),\(Int(dy))") }
    func key(_ name: String, mods: [KeyModifier]) async { add("key \(name)") }
    func type(_ text: String) async { add("type \(text)") }
    func paste(_ text: String) async { add("paste") }
}

/// A backend with one display (id 2) at a fake frame; records focus calls and display actions.
private final class DisplayBackend: SessionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var focused: [UInt32] = []
    private var actions: [InputAction] = []
    private var wakes = 0
    private var displayViews: [UInt32?] = []
    var focusCalls: [UInt32] { lock.withLock { focused } }
    var performed: [InputAction] { lock.withLock { actions } }
    var wakeCount: Int { lock.withLock { wakes } }
    var displayViewChanges: [UInt32?] { lock.withLock { displayViews } }
    let mouse = CGPoint(x: -1000, y: 300)
    let frame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)

    func permissions() -> PermissionsStatus { PermissionsStatus(screenRecording: true, accessibility: true) }
    func listWindows() async throws -> [WindowItem] { [] }
    func startCapture(windowId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> CaptureStart {
        .started(NoCapture(), WindowItem(id: windowId, pid: 1, app: "Editor", title: "Notes", w: 800, h: 600))
    }
    func perform(_ action: InputAction) async -> ErrorCode? {
        lock.withLock { actions.append(action) }
        return nil
    }
    func focus(windowId: UInt32) async { lock.withLock { focused.append(windowId) } }
    func releaseButton() async {}
    func thumbnails(windowIds: [UInt32]) async -> [(windowId: UInt32, jpeg: Data?)] { [] }
    func viewingChanged(_ window: WindowItem?) {}
    func fitWindow(windowId: UInt32, aspect: Double) async -> WindowFitOutcome { .failed(.windowNotFound) }
    func restoreWindow(windowId: UInt32) async -> WindowFitOutcome { .failed(.windowNotFound) }
    func windowAfterSwitch(from windowId: UInt32) async -> WindowItem? { nil }
    func makePeer() -> RTCPeer? { nil }
    func setAudio(_ target: AudioTarget?, events: @escaping @Sendable (AudioEvent) -> Void) -> Bool { true }
    func listApps() async -> [AppItem] { [] }
    func appIcon(id: String) async -> Data? { nil }
    func openApp(id: String) async -> AppOpenOutcome { .failed(.appNotFound) }
    func listMenu(windowId: UInt32) async -> MenuListOutcome { .failed(.menuUnavailable) }
    func listDisplays() async throws -> [DisplayItem] {
        [DisplayItem(id: 1, name: "Built-in", w: 1512, h: 982, jpeg: Data([0xFF, 0xD8])),
         DisplayItem(id: 2, name: "Studio", w: 1920, h: 1080)]
    }
    func startDisplayCapture(displayId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> DisplayCaptureStart {
        displayId == 2 ? .started(NoCapture(), DisplayItem(id: 2, name: "Studio", w: 1920, h: 1080)) : .displayGone
    }
    func displayCursor(displayId: UInt32) async -> CursorState? {
        displayId == 2 ? DisplayGeometry.cursor(at: mouse, in: frame) : nil
    }
    func viewingDisplayChanged(_ display: DisplayItem?) { lock.withLock { displayViews.append(display?.id) } }
    func declareUserActivity() { lock.withLock { wakes += 1 } }
    func frontWindow(onDisplay displayId: UInt32) async -> WindowItem? {
        displayId == 2 ? WindowItem(id: 7, pid: 1, app: "Editor", title: "Notes", w: 800, h: 600) : nil
    }
}

@Suite struct DisplayModeTests {
    @Test func viewTargetKeepsWindowIdOnlyForWindows() {
        #expect(ViewTarget.window(7).windowId == 7)
        #expect(ViewTarget.display(7).windowId == nil)
        #expect(ViewTarget.window(7) != ViewTarget.display(7))
    }

    @Test func decodesDisplayViewAndList() throws {
        #expect(try ClientMessage.decode(Data(#"{"t":"view.start","displayId":69733378}"#.utf8), on: .socket)
                == .viewStartDisplay(displayId: 69733378))
        #expect(try ClientMessage.decode(Data(#"{"t":"view.start","windowId":3}"#.utf8)) == .viewStart(windowId: 3))
        #expect(try ClientMessage.decode(Data(#"{"t":"displays.list"}"#.utf8), on: .socket) == .displaysList)
        #expect(throws: ProtocolError.invalidValue("windowId")) { try ClientMessage.decode(Data(#"{"t":"view.start"}"#.utf8)) }
        #expect(throws: ProtocolError.wrongChannel("displays.list")) {
            try ClientMessage.decode(Data(#"{"t":"displays.list"}"#.utf8), on: .control)
        }
    }

    @Test func encodesDisplaysAndDisplayViewState() throws {
        func object(_ m: ServerMessage) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(m.jsonString().utf8)) as! [String: Any]
        }
        let list = try object(.displays([DisplayItem(id: 1, name: "Built-in", w: 1512, h: 982, jpeg: Data([0xFF, 0xD8])),
                                         DisplayItem(id: 2, name: "Studio", w: 1920, h: 1080)]))
        #expect(list["t"] as? String == "displays")
        let items = list["items"] as! [[String: Any]]
        #expect(items.count == 2)
        #expect(items[0]["id"] as? Int == 1 && items[0]["name"] as? String == "Built-in" && items[0]["jpeg"] as? String == "/9g=")
        #expect(items[1]["w"] as? Double == 1920 && items[1]["jpeg"] == nil)
        let state = try object(.displayViewState(displayId: 2, state: .windowGone, reason: nil))
        #expect(state["t"] as? String == "view.state" && state["displayId"] as? Int == 2 && state["state"] as? String == "window_gone")
        #expect(state["windowId"] == nil)
    }

    /// Displays left of and above the main one have negative origins; the Mac pointer on
    /// another display is clamped to this one's edge.
    @Test func displayCoordinatesWithSeveralDisplays() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        #expect(CursorState(u: 0.5, v: 0.5).globalPoint(in: left) == CGPoint(x: -960, y: 340))
        #expect(CursorState(u: 1, v: 1).globalPoint(in: left) == CGPoint(x: -1, y: 879))
        #expect(DisplayGeometry.cursor(at: CGPoint(x: -960, y: 340), in: left) == CursorState(u: 0.5, v: 0.5))
        #expect(DisplayGeometry.cursor(at: CGPoint(x: 756, y: 491), in: main) == CursorState(u: 0.5, v: 0.5))
        // On the main display while the left one is viewed: clamped to its right edge.
        #expect(DisplayGeometry.cursor(at: CGPoint(x: 100, y: 1500), in: left) == CursorState(u: 1, v: 1))
        #expect(DisplayGeometry.cursor(at: CGPoint(x: 10, y: 10), in: .zero) == CursorState())
    }

    @Test func displayInputPostsAtThePoint() async {
        let poster = RecordingPoster()
        let frame = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let at = CursorState(u: 0.5, v: 0.5)
        for kind: InputAction.Kind in [.move, .click, .rightClick, .scroll(du: 0, dv: 0.1), .key("c", mods: [.cmd]),
                                       .text("hi"), .paste("x"), .mouseButton(.left, down: true, clicks: 1)] {
            #expect(await DisplayInput.perform(InputAction(target: .display(2), cursor: at, kind: kind), frame: frame,
                                               clickState: 2, poster: poster) == nil)
        }
        #expect(poster.posts == ["move -960,340", "click -960,340 x2", "rightClick -960,340", "scroll 0,108",
                                 "key c", "type hi", "paste", "down 0 -960,340"])
        #expect(await DisplayInput.perform(InputAction(target: .display(2), cursor: at, kind: .menuPress(path: [1], titles: ["File"])),
                                           frame: frame, clickState: 1, poster: poster) == .menuUnavailable)
    }

    /// D56: viewing a display never focuses a window, the cursor starts at the Mac pointer, and
    /// inputs carry the display target.
    @Test func displayTargetNeverRaises() async throws {
        let backend = DisplayBackend()
        let cursors = CursorLog()
        let pipeline = InputPipeline(backend: backend, onError: { _ in }, onCursor: { c, _ in cursors.add(c) })
        await pipeline.setTarget(.display(2))
        await pipeline.submit(.click)
        await pipeline.submit(.key("a", mods: []))
        let deadline = ContinuousClock.now + .seconds(5)
        while backend.performed.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(backend.focusCalls.isEmpty)
        #expect(backend.performed.map(\.target) == [.display(2), .display(2)])
        let expected = DisplayGeometry.cursor(at: backend.mouse, in: backend.frame)
        #expect(cursors.first == expected)
        #expect(backend.performed.first?.cursor == expected)
        await pipeline.setTarget(.window(5))
        #expect(backend.focusCalls == [5])
        await pipeline.shutdown()
    }

    @Test func bitrateFloorIsHigherForDisplays() {
        #expect(RTCPeer.minBitrateBps(viewingDisplay: false) == 1_500_000)
        #expect(RTCPeer.minBitrateBps(viewingDisplay: true) == 3_000_000)
    }

}

private final class CursorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [CursorState] = []
    var first: CursorState? { lock.withLock { all.first } }
    func add(_ c: CursorState) { lock.withLock { all.append(c) } }
}

/// D56 through the real server and session: list, view a display, wake, and a removed display.
@Suite(.serialized) struct SessionDisplayTests {
    static let owner = "owner@example.com"

    static func isState(_ text: String, _ key: String, _ id: Int, _ state: String) -> Bool {
        guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return false }
        return o["t"] as? String == "view.state" && o[key] as? Int == id && o["state"] as? String == state
    }

    @Test func listsAndViewsADisplay() async throws {
        let backend = DisplayBackend()
        let hub = SessionHub(owner: OwnerLogin(override: { "" }, query: { Self.owner }), backend: backend)
        let app = Server.makeApplication(port: 0, webRoot: nil, hub: hub)
        try await app.test(.live) { client in
            var fields = HTTPFields()
            fields[HTTPField.Name(TailscaleIdentity.loginHeader)!] = Self.owner
            try await client.ws("/ws", configuration: WebSocketClientConfiguration(additionalHeaders: fields)) { inbound, outbound, _ in
                var it = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                func nextText() async throws -> String {
                    guard case .text(let t)? = try await it.next() else { Issue.record("no reply"); return "" }
                    return t
                }
                _ = try await nextText() // hello
                try await outbound.write(.text(#"{"t":"displays.list"}"#))
                let list = try await nextText()
                #expect(list.contains(#""t":"displays""#) && list.contains(#""name":"Studio""#))
                try await outbound.write(.text(#"{"t":"view.start","displayId":2}"#))
                #expect(Self.isState(try await nextText(), "displayId", 2, "starting"))
                #expect(Self.isState(try await nextText(), "displayId", 2, "streaming"))
                #expect(backend.wakeCount == 1)
                // D59: the front window is only named; the view stays on the display until view.start.
                try await outbound.write(.text(#"{"t":"view.front","displayId":2}"#))
                let front = try await nextText()
                #expect(front.contains(#""t":"view.front.result""#) && front.contains(#""windowId":7"#))
                try await outbound.write(.text(#"{"t":"view.front","displayId":9}"#))
                let none = try await nextText()
                #expect(none.contains(#""t":"view.front.result""#) && !none.contains("windowId"))
                #expect(backend.displayViewChanges == [2])
                #expect(backend.displayViewChanges == [2])
                // A display that is not connected ends the view like a closed window.
                try await outbound.write(.text(#"{"t":"view.start","displayId":9}"#))
                #expect(Self.isState(try await nextText(), "displayId", 9, "starting"))
                #expect(Self.isState(try await nextText(), "displayId", 9, "window_gone"))
                #expect(backend.displayViewChanges == [2, nil])
                try await outbound.write(.text(#"{"t":"view.start","windowId":7}"#))
                #expect(Self.isState(try await nextText(), "windowId", 7, "starting"))
                #expect(Self.isState(try await nextText(), "windowId", 7, "streaming"))
                #expect(backend.wakeCount == 3)
                try await outbound.close(.normalClosure, reason: nil)
            }
        }
    }
}
