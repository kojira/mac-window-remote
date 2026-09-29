import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import HummingbirdWebSocket
import WSClient
import Testing
@testable import MacWindowRemote

private final class FakeBackend: SessionBackend {
    func permissions() -> PermissionsStatus { PermissionsStatus(screenRecording: true, accessibility: false) }
    func listWindows() async throws -> [WindowItem] {
        [WindowItem(id: 7, pid: 1, app: "Editor", title: "Notes", w: 800, h: 600)]
    }
    func startCapture(windowId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> CaptureStart {
        .windowGone
    }
    func perform(_ action: InputAction) async -> ErrorCode? { nil }
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
}

/// The Tailscale identity check through the real server (D32): only the owner's
/// `Tailscale-User-Login` gets the page and a session; others get 403 or close 4001.
@Suite(.serialized) struct AuthTests {
    static let owner = "owner@example.com"
    static let header = HTTPField.Name(TailscaleIdentity.loginHeader)!

    func withServer(_ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void) async throws {
        let hub = SessionHub(owner: OwnerLogin(override: { "" }, query: { Self.owner }), backend: FakeBackend())
        let app = Server.makeApplication(port: 0, webRoot: nil, hub: hub)
        try await app.test(.live) { client in try await body(client) }
    }

    func headers(_ login: String?) -> WebSocketClientConfiguration {
        var fields = HTTPFields()
        if let login { fields[Self.header] = login }
        return WebSocketClientConfiguration(additionalHeaders: fields)
    }

    @Test func httpWithoutOwnerLoginIs403() async throws {
        try await withServer { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .forbidden)
                #expect(String(buffer: response.body).contains("Not allowed: sign in to Tailscale as the Mac owner"))
            }
            try await client.execute(uri: "/", method: .get, headers: [Self.header: "someone@example.com"]) { response in
                #expect(response.status == .forbidden)
            }
            // The owner passes the check; with no web root, the router answers 404.
            try await client.execute(uri: "/", method: .get, headers: [Self.header: Self.owner]) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test func wsWithoutLoginClosesWith4001() async throws {
        try await withServer { client in
            let close = try await client.ws("/ws", configuration: headers(nil)) { inbound, _, _ in
                for try await _ in inbound {}
            }
            #expect(close?.closeCode == .unknown(4001))
        }
    }

    @Test func wsWithAnotherLoginClosesWith4001() async throws {
        try await withServer { client in
            let close = try await client.ws("/ws", configuration: headers("someone@example.com")) { inbound, _, _ in
                for try await _ in inbound {}
            }
            #expect(close?.closeCode == .unknown(4001))
        }
    }

    @Test func ownerGetsHelloAndWindows() async throws {
        try await withServer { client in
            try await client.ws("/ws", configuration: headers("Owner@Example.com")) { inbound, outbound, _ in
                var it = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                guard case .text(let h)? = try await it.next() else { Issue.record("no hello"); return }
                #expect(h.contains(#""t":"hello""#))
                #expect(h.contains(#""accessibility":false"#))
                try await outbound.write(.text(#"{"t":"windows.list"}"#))
                guard case .text(let w)? = try await it.next() else { Issue.record("no windows"); return }
                #expect(w.contains(#""t":"windows""#))
                #expect(w.contains(#""app":"Editor""#))
                try await outbound.close(.normalClosure, reason: nil)
            }
        }
    }

    /// D36: binary requests pass the server's frame limit and get an `error` with their id.
    @Test func binaryRequestsGetRepliesWithTheirId() async throws {
        try await withServer { client in
            try await client.ws("/ws", configuration: headers(Self.owner)) { inbound, outbound, _ in
                var it = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                guard case .text? = try await it.next() else { Issue.record("no hello"); return }
                func frame(_ header: String, _ payload: Data) -> ByteBuffer {
                    let h = Data(header.utf8)
                    let n = UInt32(h.count)
                    return ByteBuffer(bytes: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + h + payload)
                }
                // Over 1 MiB of text: rejected, and the Mac clipboard is not touched.
                let big = Data(repeating: 0x61, count: BinaryClientMessage.maxClipboardBytes + 1)
                try await outbound.write(.binary(frame(#"{"t":"clipboard.paste","id":"c1"}"#, big)))
                guard case .text(let e1)? = try await it.next() else { Issue.record("no reply"); return }
                #expect(e1.contains(#""id":"c1""#) && e1.contains(#""code":"too_large""#))
                // No window is viewed.
                try await outbound.write(.binary(frame(#"{"t":"image.chunk","id":"i1","size":12,"offset":0}"#, UploadsTests.png)))
                guard case .text(let e2)? = try await it.next() else { Issue.record("no reply"); return }
                #expect(e2.contains(#""id":"i1""#) && e2.contains(#""code":"window_not_found""#))
                try await outbound.close(.normalClosure, reason: nil)
            }
        }
    }
}
