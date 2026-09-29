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

/// Views window 7 and records pastes instead of touching the pasteboard.
private final class PasteRecordingBackend: SessionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var pasted: [String] { lock.withLock { texts } }

    func permissions() -> PermissionsStatus { PermissionsStatus(screenRecording: true, accessibility: true) }
    func listWindows() async throws -> [WindowItem] { [] }
    func startCapture(windowId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> CaptureStart {
        .started(NoCapture(), WindowItem(id: windowId, pid: 1, app: "Editor", title: "Notes", w: 800, h: 600))
    }
    func perform(_ action: InputAction) async -> ErrorCode? {
        if case .paste(let text) = action.kind { lock.withLock { texts.append(text) } }
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
}

/// D36 through the real server and session: chunks are assembled, saved in the uploads
/// directory, and the path is pasted into the viewed window before `result`.
@Suite(.serialized) struct SessionUploadTests {
    static let owner = "owner@example.com"

    static func frame(_ header: String, _ payload: Data) -> ByteBuffer {
        let h = Data(header.utf8)
        let n = UInt32(h.count)
        return ByteBuffer(bytes: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + h + payload)
    }

    @Test func imageIsSavedAndItsPathPasted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwr-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UploadStore(directory: root.appendingPathComponent("uploads"))
        let backend = PasteRecordingBackend()
        let hub = SessionHub(owner: OwnerLogin(override: { "" }, query: { Self.owner }), backend: backend, uploads: store)
        let app = Server.makeApplication(port: 0, webRoot: nil, hub: hub)
        let image = UploadsTests.jpeg + Data(repeating: 9, count: 300_000)
        try await app.test(.live) { client in
            var fields = HTTPFields()
            fields[HTTPField.Name(TailscaleIdentity.loginHeader)!] = Self.owner
            try await client.ws("/ws", configuration: WebSocketClientConfiguration(additionalHeaders: fields)) { inbound, outbound, _ in
                var it = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                func nextText() async throws -> String? {
                    guard case .text(let t)? = try await it.next() else { return nil }
                    return t
                }
                _ = try await nextText() // hello
                try await outbound.write(.text(#"{"t":"view.start","windowId":7}"#))
                _ = try await nextText() // starting
                _ = try await nextText() // streaming
                let chunk = BinaryClientMessage.maxChunkBytes
                for offset in stride(from: 0, to: image.count, by: chunk) {
                    let part = image[offset..<min(offset + chunk, image.count)]
                    try await outbound.write(.binary(Self.frame(
                        #"{"t":"image.chunk","id":"i1","size":\#(image.count),"offset":\#(offset)}"#, Data(part))))
                }
                guard let reply = try await nextText() else { Issue.record("no reply"); return }
                #expect(reply.contains(#""t":"result""#) && reply.contains(#""id":"i1""#))
                let saved = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
                #expect(saved.count == 1)
                #expect(saved.first?.pathExtension == "jpg")
                if let url = saved.first {
                    #expect(try Data(contentsOf: url) == image)
                    // The pasted path is the saved file under the store directory ($TMPDIR is
                    // reached through /var → /private/var, so compare after resolving).
                    #expect(backend.pasted.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                            == [url.resolvingSymlinksInPath().path])
                }

                try await outbound.write(.binary(Self.frame(#"{"t":"clipboard.paste","id":"c1"}"#, Data("行1\n行2".utf8))))
                guard let r2 = try await nextText() else { Issue.record("no reply"); return }
                #expect(r2.contains(#""t":"result""#) && r2.contains(#""id":"c1""#))
                #expect(backend.pasted.last == "行1\n行2")
                try await outbound.close(.normalClosure, reason: nil)
            }
        }
    }
}
