import Foundation
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import HummingbirdWebSocket
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
    func perform(_ job: InputJob) async -> ErrorCode? { nil }
    func viewingChanged(_ window: WindowItem?) {}
}

/// The /ws handshake through the real server (D6): wrong, late, or non-auth first messages
/// close the socket; the right secret gets `hello` and can use the session.
@Suite(.serialized) struct AuthTests {
    static let secret = PairingSecret.generate()

    func withServer(_ body: @escaping @Sendable (any TestClientProtocol, SessionHub) async throws -> Void) async throws {
        let hub = SessionHub(secret: Self.secret, backend: FakeBackend(), authTimeout: .milliseconds(300))
        let app = Server.makeApplication(port: 0, webRoot: nil, hub: hub)
        try await app.test(.live) { client in try await body(client, hub) }
    }

    @Test func wrongSecretClosesWith4001() async throws {
        try await withServer { client, _ in
            let close = try await client.ws("/ws") { inbound, outbound, _ in
                try await outbound.write(.text(#"{"t":"auth","secret":"wrong"}"#))
                for try await _ in inbound {}
            }
            #expect(close?.closeCode == .unknown(4001))
        }
    }

    @Test func missingAuthTimesOutWith4003() async throws {
        try await withServer { client, _ in
            let close = try await client.ws("/ws") { inbound, _, _ in
                for try await _ in inbound {}
            }
            #expect(close?.closeCode == .unknown(4003))
        }
    }

    @Test func nonAuthFirstMessageClosesWith4003() async throws {
        try await withServer { client, _ in
            let close = try await client.ws("/ws") { inbound, outbound, _ in
                try await outbound.write(.text(#"{"t":"windows.list"}"#))
                for try await _ in inbound {}
            }
            #expect(close?.closeCode == .unknown(4003))
        }
    }

    @Test func rightSecretGetsHelloAndWindows() async throws {
        try await withServer { client, _ in
            try await client.ws("/ws") { inbound, outbound, _ in
                try await outbound.write(.text(#"{"t":"auth","secret":"\#(Self.secret)","client":"test"}"#))
                var it = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                let hello = try await it.next()
                guard case .text(let h)? = hello else { Issue.record("no hello"); return }
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

    @Test func resetPairingClosesOpenSessionWith4001() async throws {
        try await withServer { client, hub in
            let close = try await client.ws("/ws") { inbound, outbound, _ in
                try await outbound.write(.text(#"{"t":"auth","secret":"\#(Self.secret)"}"#))
                var it = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                _ = try await it.next() // hello
                await hub.resetSecret(PairingSecret.generate())
                while try await it.next() != nil {}
            }
            #expect(close?.closeCode == .unknown(4001))
        }
    }
}
