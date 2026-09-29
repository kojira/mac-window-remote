import Foundation

/// One input as posted by the backend (D26). `cursor` is the Mac-owned cursor (D24) at the
/// time the input was submitted, so a click lands where the user saw the overlay arrow.
struct InputAction: Sendable {
    enum Kind: Sendable {
        /// Pointer to `cursor`; a drag while the button is held (D26).
        case move
        /// Scroll at `cursor`, in window-normalized units (D26).
        case scroll(du: Double, dv: Double)
        case click
        case rightClick
        case dragStart
        case dragEnd
        case text(String)
        case key(String)
    }
    let windowId: UInt32
    let cursor: CursorState
    let kind: Kind
    /// When the message arrived, to log queueing plus posting latency.
    var received = ContinuousClock.now
}

/// Discrete inputs that `InputPipeline.submit` accepts.
enum DiscreteInput: Sendable {
    case click, rightClick, dragStart, dragEnd
    case text(String)
    case key(String)
}

/// The input actor (D24, D25). It owns the cursor for the viewed window, coalesces moves and
/// scrolls (latest wins, deltas summed), and runs discrete inputs in order. Motion is posted
/// independently of discrete inputs, so the cursor never queues behind a slow input such as
/// typing; motion that arrived before a discrete input is posted before it.
actor InputPipeline {
    /// At most 30 cursor confirmations per second (D24).
    static let cursorReportInterval: Duration = .milliseconds(33)

    private let backend: any SessionBackend
    private let onError: @Sendable (ErrorCode) async -> Void
    private let onCursor: @Sendable (CursorState, Int) async -> Void

    private var target: UInt32?
    private var cursor = CursorState()
    private var appliedSeq = 0

    // Motion accumulators.
    private var motionDirty = false
    private var pendingScroll: (du: Double, dv: Double)?
    private var motionTask: Task<Void, Never>?
    /// The one motion post in progress; motion posts never overlap, so they land in order.
    private var motionPost: Task<Void, Never>?

    // Discrete inputs, in order.
    private var discrete: [InputAction] = []
    private var discreteTask: Task<Void, Never>?

    // Cursor confirmation throttle.
    private var lastCursorReport: ContinuousClock.Instant?
    private var cursorReportScheduled = false

    private var closed = false

    init(backend: any SessionBackend,
         onError: @escaping @Sendable (ErrorCode) async -> Void,
         onCursor: @escaping @Sendable (CursorState, Int) async -> Void) {
        self.backend = backend
        self.onError = onError
        self.onCursor = onCursor
    }

    /// Viewing started (`windowId`) or stopped (nil). Releases a held button (D26). A new
    /// window puts the cursor at its center and brings it to the front once (D25).
    func setTarget(_ windowId: UInt32?) async {
        if windowId != target {
            discrete.removeAll()
            pendingScroll = nil
            motionDirty = false
            await backend.releaseButton()
            cursor = CursorState()
        }
        target = windowId
        guard let windowId, !closed else { return }
        await backend.focus(windowId: windowId)
        await onCursor(cursor, appliedSeq)
    }

    func submitMove(seq: Int, dx: Double, dy: Double) {
        guard target != nil, !closed else { return }
        cursor.apply(dx: dx, dy: dy)
        appliedSeq = max(appliedSeq, seq)
        motionDirty = true
        scheduleMotion()
    }

    func submitScroll(du: Double, dv: Double) {
        guard target != nil, !closed else { return }
        let s = pendingScroll ?? (0, 0)
        pendingScroll = (s.du + du, s.dv + dv)
        scheduleMotion()
    }

    func submit(_ input: DiscreteInput) {
        guard let target, !closed else {
            log.info("input dropped kind=\(input.logName, privacy: .public) reason=not_viewing")
            return
        }
        let kind: InputAction.Kind
        switch input {
        case .click: kind = .click
        case .rightClick: kind = .rightClick
        case .dragStart: kind = .dragStart
        case .dragEnd: kind = .dragEnd
        case .text(let text): kind = .text(text)
        case .key(let name): kind = .key(name)
        }
        discrete.append(InputAction(windowId: target, cursor: cursor, kind: kind))
        guard discreteTask == nil else { return }
        discreteTask = Task { await self.runDiscrete() }
    }

    /// Disconnect: release a held button and drop pending input (D26).
    func shutdown() async {
        closed = true
        await setTarget(nil)
    }

    // MARK: Draining

    private func scheduleMotion() {
        guard motionTask == nil else { return }
        motionTask = Task { await self.runMotion() }
    }

    private func runMotion() async {
        while motionDirty || pendingScroll != nil {
            guard await drainMotionOnce() else { break }
        }
        motionTask = nil
    }

    /// Posts the accumulated move and scroll once. Returns false when there is no target.
    private func drainMotionOnce() async -> Bool {
        // Wait until no post is in progress, so posts never overlap. A post that has finished
        // is cleared here too: its own caller may not have resumed yet, and awaiting a
        // finished task again returns at once, which would spin on the actor forever.
        while let post = motionPost {
            await post.value
            if motionPost == post { motionPost = nil }
        }
        guard let target, !closed else { return false }
        guard motionDirty || pendingScroll != nil else { return true }
        let moved = motionDirty
        let scroll = pendingScroll
        motionDirty = false
        pendingScroll = nil
        let at = cursor
        let backend = backend
        let onError = onError
        let post = Task {
            if moved {
                _ = await backend.perform(InputAction(windowId: target, cursor: at, kind: .move))
            }
            if let scroll, let code = await backend.perform(
                InputAction(windowId: target, cursor: at, kind: .scroll(du: scroll.du, dv: scroll.dv))) {
                await onError(code)
            }
        }
        motionPost = post
        await post.value
        // Only the post this call started is cleared. A waiter that resumes first must not
        // see a finished post as still in progress; `await` on a finished task returns
        // without suspending, so that would spin on the actor and starve every other input.
        if motionPost == post { motionPost = nil }
        if moved { reportCursorSoon() }
        return true
    }

    private func runDiscrete() async {
        while !discrete.isEmpty, !closed {
            let action = discrete.removeFirst()
            // Motion that arrived earlier is posted first. It is drained here rather than
            // awaited, so continuous finger movement cannot hold a click back.
            if motionDirty || pendingScroll != nil { _ = await drainMotionOnce() }
            if let code = await backend.perform(action) {
                await onError(code)
            }
            // A click posted at an older cursor leaves the pointer there; move it back to the
            // cursor the phone shows.
            if action.cursor != cursor, target != nil {
                motionDirty = true
                scheduleMotion()
            }
        }
        discreteTask = nil
    }

    private func reportCursorSoon() {
        guard !cursorReportScheduled else { return }
        let now = ContinuousClock.now
        if let last = lastCursorReport, now - last < Self.cursorReportInterval {
            cursorReportScheduled = true
            let delay = Self.cursorReportInterval - (now - last)
            Task {
                try? await Task.sleep(for: delay)
                await self.sendCursorReport()
            }
            return
        }
        lastCursorReport = now
        let (c, seq) = (cursor, appliedSeq)
        Task { await onCursor(c, seq) }
    }

    private func sendCursorReport() async {
        cursorReportScheduled = false
        guard !closed else { return }
        lastCursorReport = ContinuousClock.now
        await onCursor(cursor, appliedSeq)
    }
}

extension DiscreteInput {
    /// Log label; never includes typed text.
    var logName: String {
        switch self {
        case .click: return "click"
        case .rightClick: return "rightClick"
        case .dragStart: return "drag.start"
        case .dragEnd: return "drag.end"
        case .text: return "text"
        case .key: return "key"
        }
    }
}

extension InputAction.Kind {
    /// Log label; never includes typed text.
    var logName: String {
        switch self {
        case .move: return "move"
        case .scroll: return "scroll"
        case .click: return "click"
        case .rightClick: return "rightClick"
        case .dragStart: return "drag.start"
        case .dragEnd: return "drag.end"
        case .text: return "text"
        case .key: return "key"
        }
    }
}
