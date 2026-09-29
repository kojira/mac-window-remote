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

/// Views window 7, lists a fixed menu, and records menu presses instead of using AX.
private final class MenuRecordingBackend: SessionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var presses: [[Int]] = []
    var pressed: [[Int]] { lock.withLock { presses } }

    func permissions() -> PermissionsStatus { PermissionsStatus(screenRecording: true, accessibility: true) }
    func listWindows() async throws -> [WindowItem] { [] }
    func startCapture(windowId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> CaptureStart {
        .started(NoCapture(), WindowItem(id: windowId, pid: 1, app: "Editor", title: "Notes", w: 800, h: 600))
    }
    func perform(_ action: InputAction) async -> ErrorCode? {
        if case .menuPress(let path, let titles) = action.kind {
            #expect(titles == ["File", "New"])
            lock.withLock { presses.append(path) }
        }
        return nil
    }
    func focus(windowId: UInt32) async {}
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
    func listMenu(windowId: UInt32) async -> MenuListOutcome {
        let file = MenuNode(path: [1], title: "File", items: [
            MenuNode(path: [1, 0], title: "New"),
            MenuNode(path: [1, 1], title: "Recent", items: [MenuNode(path: [1, 1, 0], title: "a.txt")]),
        ])
        return .listed(MenuListing(menus: [file], truncated: false))
    }
}

/// D43 through the real server and session: only leaves of the latest listing are pressed.
@Suite(.serialized) struct SessionMenuTests {
    static let owner = "owner@example.com"

    @Test func onlyLeavesOfTheLatestListingArePressed() async throws {
        let backend = MenuRecordingBackend()
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
                // Before viewing there is no menu.
                try await outbound.write(.text(#"{"t":"menu.list"}"#))
                #expect(try await nextText().contains(#""code":"window_not_found""#))
                try await outbound.write(.text(#"{"t":"view.start","windowId":7}"#))
                _ = try await nextText() // starting
                _ = try await nextText() // streaming
                try await outbound.write(.text(#"{"t":"menu.list"}"#))
                let listed = try await nextText()
                #expect(listed.contains(#""t":"menu""#) && listed.contains(#""gen":1"#) && listed.contains(#""windowId":7"#))
                try await outbound.write(.text(#"{"t":"menu.list"}"#))
                #expect(try await nextText().contains(#""gen":2"#))

                // An older listing, a submenu, and an unknown id are stale; nothing is pressed.
                for request in [#"{"t":"menu.press","id":"1.0","gen":1}"#, #"{"t":"menu.press","id":"1.1","gen":2}"#,
                                #"{"t":"menu.press","id":"1.5","gen":2}"#] {
                    try await outbound.write(.text(request))
                    #expect(try await nextText().contains(#""code":"menu_stale""#))
                }
                #expect(backend.pressed.isEmpty)

                try await outbound.write(.text(#"{"t":"menu.press","id":"1.0","gen":2}"#))
                let reply = try await nextText()
                #expect(reply.contains(#""t":"menu.pressed""#) && reply.contains(#""id":"1.0""#))
                #expect(backend.pressed == [[1, 0]])
                try await outbound.close(.normalClosure, reason: nil)
            }
        }
    }
}
