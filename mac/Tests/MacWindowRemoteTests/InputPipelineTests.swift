import Foundation
import Testing
@testable import MacWindowRemote

private final class RecordingBackend: SessionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [String] = []
    var performed: [String] { lock.withLock { kinds } }

    func permissions() -> PermissionsStatus { PermissionsStatus(screenRecording: true, accessibility: true) }
    func listWindows() async throws -> [WindowItem] { [] }
    func startCapture(windowId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> CaptureStart { .windowGone }
    func perform(_ action: InputAction) async -> ErrorCode? {
        // Posting takes a moment, so later input arrives while a post is in flight.
        try? await Task.sleep(for: .milliseconds(2))
        lock.withLock { kinds.append(action.kind.logName) }
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
    func listMenu(windowId: UInt32) async -> MenuListOutcome { .failed(.menuUnavailable) }
}

@Suite struct InputPipelineTests {
    /// A discrete input that waits for an in-flight motion post must not spin on the
    /// finished post (a livelock that stopped all later input).
    @Test func clicksAfterMovesAreAllPosted() async throws {
        let backend = RecordingBackend()
        let pipeline = InputPipeline(backend: backend, onError: { _ in }, onCursor: { _, _ in })
        await pipeline.setTarget(1)
        for round in 0..<20 {
            await pipeline.submitMove(seq: round * 2 + 1, dx: 0.01, dy: 0)
            await pipeline.submit(.click)
            await pipeline.submitMove(seq: round * 2 + 2, dx: -0.01, dy: 0)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while backend.performed.filter({ $0 == "click" }).count < 20, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(backend.performed.filter { $0 == "click" }.count == 20)
        await pipeline.shutdown()
    }
}
