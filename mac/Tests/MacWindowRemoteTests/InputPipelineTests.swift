import Foundation
import Testing
@testable import MacWindowRemote

private final class RecordingBackend: SessionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [String] = []
    private var actions: [InputAction] = []
    var performed: [String] { lock.withLock { kinds } }
    var performedActions: [InputAction] { lock.withLock { actions } }

    func permissions() -> PermissionsStatus { PermissionsStatus(screenRecording: true, accessibility: true) }
    func listWindows() async throws -> [WindowItem] { [] }
    func startCapture(windowId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> CaptureStart { .windowGone }
    func perform(_ action: InputAction) async -> ErrorCode? {
        // Posting takes a moment, so later input arrives while a post is in flight.
        try? await Task.sleep(for: .milliseconds(2))
        lock.withLock { kinds.append(action.kind.logName); actions.append(action) }
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

    /// D45: a desktop mouse button goes down where the mouse is, and a point that arrives
    /// after a newer one (the motion channel is unordered) does not move the cursor back.
    @Test func desktopMouseUsesAbsolutePositions() async throws {
        let backend = RecordingBackend()
        let pipeline = InputPipeline(backend: backend, onError: { _ in }, onCursor: { _, _ in })
        await pipeline.setTarget(1)
        await pipeline.submitPoint(seq: 5, u: 0.2, v: 0.3)
        await pipeline.submitPoint(seq: 4, u: 0.9, v: 0.9)
        await pipeline.submitMouse(.left, down: true, clicks: 2, seq: 6, u: 0.25, v: 0.35)
        await pipeline.submitMouse(.left, down: false, clicks: 2, seq: 7, u: 0.4, v: 0.5)
        let deadline = ContinuousClock.now + .seconds(5)
        while !backend.performed.contains("mouse.left.up"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let buttons = backend.performedActions.filter { $0.kind.logName.hasPrefix("mouse.") }
        #expect(buttons.map(\.kind.logName) == ["mouse.left.down", "mouse.left.up"])
        #expect(buttons.map(\.cursor) == [CursorState(u: 0.25, v: 0.35), CursorState(u: 0.4, v: 0.5)])
        let moves = backend.performedActions.filter { $0.kind.logName == "move" }
        #expect(!moves.contains { $0.cursor == CursorState(u: 0.9, v: 0.9) })
        await pipeline.shutdown()
    }
}
