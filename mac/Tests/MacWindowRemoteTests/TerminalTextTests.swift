import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import HummingbirdWebSocket
import WSClient
import Testing
@testable import MacWindowRemote

// D67, the Terminal text view, with fakes only: no Accessibility call is made.

/// A clock that moves only when the test advances it. A sleep ends when the time reaches its
/// deadline or when its task is cancelled.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: (deadline: Instant, resume: CheckedContinuation<Void, Never>)] = [:]

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if deadline <= current || Task.isCancelled { return true }
                    sleepers[id] = (deadline, c)
                    return false
                }
                if resumeNow { c.resume() }
            }
        } onCancel: {
            lock.withLock { sleepers.removeValue(forKey: id) }?.resume.resume()
        }
        try Task.checkCancellation()
    }

    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            current = current.advanced(by: duration)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for key in ready.keys { sleepers.removeValue(forKey: key) }
            return ready.values.map(\.resume)
        }
        for c in due { c.resume() }
    }
}

/// Returns the reads it is given, in order, repeating the last one; counts reads.
final class FakeTerminalSource: TerminalTextSource, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [TerminalTextRead]
    private var count = 0
    init(_ reads: [TerminalTextRead]) { queue = reads }
    var reads: Int { lock.withLock { count } }
    func set(_ read: TerminalTextRead) { lock.withLock { queue = [read] } }
    func read(windowId: UInt32, pid: pid_t) -> TerminalTextRead {
        lock.withLock {
            count += 1
            return queue.count > 1 ? queue.removeFirst() : queue[0]
        }
    }
}

/// Collects the poller's outcomes.
final class OutcomeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TerminalTextWatch.Outcome] = []
    var all: [TerminalTextWatch.Outcome] { lock.withLock { items } }
    func add(_ o: TerminalTextWatch.Outcome) { lock.withLock { items.append(o) } }
}

/// Waits (in real time, briefly) until `condition` holds.
func eventually(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}

/// A fake AX tree: each node has a role, children, and maybe a value.
struct FakeTree: TerminalTextTree {
    final class Node {
        let role: String
        let value: String?
        let children: [Node]
        init(_ role: String, value: String? = nil, _ children: [Node] = []) {
            self.role = role
            self.value = value
            self.children = children
        }
    }
    func role(_ element: Node) -> String? { element.role }
    func children(_ element: Node) -> [Node] { element.children }
    func stringValue(_ element: Node) -> String? { element.value }
}

@Suite(.timeLimit(.minutes(1))) struct TerminalTextTests {
    @Test func onlyTerminalAppOffersTheTextView() {
        #expect(TerminalText.isSupported(bundleId: "com.apple.Terminal"))
        #expect(!TerminalText.isSupported(bundleId: "com.googlecode.iterm2"))
        #expect(!TerminalText.isSupported(bundleId: "com.apple.TextEdit"))
        #expect(!TerminalText.isSupported(bundleId: nil))
    }

    @Test func capKeepsTheLastLines() {
        let text = (1...5).map { "line \($0)" }.joined(separator: "\n")
        #expect(TerminalText.cap(text, maxLines: 3, maxBytes: 1000) == "line 3\nline 4\nline 5")
        #expect(TerminalText.cap(text, maxLines: 5, maxBytes: 1000) == text)
        #expect(TerminalText.cap(text + "\n", maxLines: 2, maxBytes: 1000) == "line 5\n")
        #expect(TerminalText.cap("", maxLines: 3, maxBytes: 10) == "")
    }

    @Test func capKeepsTheLastBytesFromALineStart() {
        let text = "aaaa\nbbbb\ncccc"
        // The last 7 bytes are "b\ncccc"; the partial line is dropped.
        #expect(TerminalText.cap(text, maxLines: 100, maxBytes: 7) == "cccc")
        // Without a line break in the kept part, it cuts at a character, never inside one.
        let wide = String(repeating: "あ", count: 10) // 3 bytes each
        let cut = TerminalText.cap(wide, maxLines: 100, maxBytes: 8)
        #expect(cut == "ああ")
        #expect(cut.utf8.count <= 8)
    }

    @Test func defaultCapIs2000LinesAnd512KiB() {
        #expect(TerminalText.maxLines == 2000)
        #expect(TerminalText.maxBytes == 512 * 1024)
        let lines = (1...2500).map { "\($0)" }.joined(separator: "\n")
        let capped = TerminalText.cap(lines)
        #expect(capped.split(separator: "\n", omittingEmptySubsequences: false).count == 2000)
        #expect(capped.hasPrefix("501\n") && capped.hasSuffix("\n2500"))
        let big = String(repeating: String(repeating: "x", count: 1023) + "\n", count: 600)
        #expect(TerminalText.cap(big).utf8.count <= TerminalText.maxBytes)
    }

    @Test func watchSendsOnlyChangesWithRisingRev() {
        var watch = TerminalTextWatch()
        #expect(watch.receive(.text("a")) == .send(text: "a", rev: 1))
        #expect(watch.receive(.text("a")) == .unchanged)
        #expect(watch.receive(.text("ab")) == .send(text: "ab", rev: 2))
        watch.reset()
        // A new term.start sends the same text again, with a newer rev.
        #expect(watch.receive(.text("ab")) == .send(text: "ab", rev: 3))
        #expect(TerminalText.hash("ab") == TerminalText.hash("ab"))
        #expect(TerminalText.hash("ab") != TerminalText.hash("ba"))
    }

    @Test func watchMapsReadsToErrorCodes() {
        var watch = TerminalTextWatch()
        #expect(watch.receive(.noText) == .error(.noText))
        #expect(watch.receive(.axDenied) == .error(.axDenied))
        #expect(watch.receive(.windowGone) == .windowGone)
        #expect(TerminalTextError.notTerminal.rawValue == "not_terminal")
        #expect(TerminalTextError.noText.rawValue == "no_text")
        #expect(TerminalTextError.axDenied.rawValue == "ax_denied")
    }

    @Test func textAreaIsTheFirstOneInAScrollArea() {
        typealias N = FakeTree.Node
        let window = N("AXWindow", [
            N("AXButton"),
            N("AXTextArea", value: "not in a scroll area"),
            N("AXSplitGroup", [
                N("AXScrollArea", [N("AXTextArea", value: "$ ls\nfile"), N("AXScrollBar")]),
            ]),
        ])
        #expect(TerminalTextArea.text(in: window, tree: FakeTree()) == "$ ls\nfile")
        #expect(TerminalTextArea.text(in: N("AXWindow", [N("AXButton")]), tree: FakeTree()) == nil)
        let noValue = N("AXWindow", [N("AXScrollArea", [N("AXTextArea")])])
        #expect(TerminalTextArea.text(in: noValue, tree: FakeTree()) == nil)
    }

    @Test func scheduleReadsEverySecondAndSoonAfterInput() {
        let clock = ManualClock()
        let t0 = clock.now
        var s = TerminalPollSchedule(timing: TerminalPollTiming(), start: t0)
        #expect(s.nextDeadline == t0)
        s.didRead(startedAt: t0)
        #expect(s.nextDeadline == t0.advanced(by: .seconds(1)))
        // Input at 0.3 s → read at 0.45 s; more input at 0.4 s moves it to 0.55 s.
        s.inputArrived(at: t0.advanced(by: .milliseconds(300)))
        #expect(s.nextDeadline == t0.advanced(by: .milliseconds(450)))
        s.inputArrived(at: t0.advanced(by: .milliseconds(400)))
        #expect(s.nextDeadline == t0.advanced(by: .milliseconds(550)))
        s.didRead(startedAt: t0.advanced(by: .milliseconds(550)))
        #expect(s.nudge == nil)
        #expect(s.nextDeadline == t0.advanced(by: .milliseconds(1550)))
        // An input after the read started keeps its own nudge.
        s.inputArrived(at: t0.advanced(by: .milliseconds(600)))
        s.didRead(startedAt: t0.advanced(by: .milliseconds(560)))
        #expect(s.nextDeadline == t0.advanced(by: .milliseconds(750)))
    }

    @Test func pollerReadsAtOnceThenEverySecondAndStops() async {
        let clock = ManualClock()
        let source = FakeTerminalSource([.text("one")])
        let log = OutcomeLog()
        let poller = TerminalTextPoller(source: source, clock: clock) { _, _, o in log.add(o) }
        await poller.start(windowId: 7, pid: 1)
        await eventually { log.all.count == 1 && clock.sleeperCount == 1 }
        #expect(log.all == [.send(text: "one", rev: 1)])
        clock.advance(by: .milliseconds(999))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(source.reads == 1)
        clock.advance(by: .milliseconds(1))
        await eventually { source.reads == 2 && clock.sleeperCount == 1 }
        #expect(log.all.count == 1, "the same text is not sent again")
        source.set(.text("two"))
        clock.advance(by: .seconds(1))
        await eventually { log.all.count == 2 }
        #expect(log.all.last == .send(text: "two", rev: 2))
        await poller.stop()
        #expect(await !poller.isRunning)
        let before = source.reads
        clock.advance(by: .seconds(5))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(source.reads == before)
    }

    @Test func pollerReadsSoonAfterInputDebounced() async {
        let clock = ManualClock()
        let source = FakeTerminalSource([.text("a")])
        let poller = TerminalTextPoller(source: source, clock: clock) { _, _, _ in }
        await poller.start(windowId: 7, pid: 1)
        await eventually { source.reads == 1 && clock.sleeperCount == 1 }
        clock.advance(by: .milliseconds(100))
        await poller.inputArrived()
        await eventually { clock.sleeperCount == 1 }
        clock.advance(by: .milliseconds(100))
        await poller.inputArrived() // at 0.2 s: the read moves to 0.35 s
        await eventually { clock.sleeperCount == 1 }
        clock.advance(by: .milliseconds(100)) // 0.3 s
        try? await Task.sleep(for: .milliseconds(30))
        #expect(source.reads == 1)
        clock.advance(by: .milliseconds(50)) // 0.35 s
        await eventually { source.reads == 2 }
        #expect(source.reads == 2)
    }

    @Test func aStaleStopLeavesANewerStartRunning() async {
        let clock = ManualClock()
        let poller = TerminalTextPoller(source: FakeTerminalSource([.text("a")]), clock: clock) { _, _, _ in }
        let first = await poller.start(windowId: 7, pid: 1)
        let second = await poller.start(windowId: 7, pid: 1)
        #expect(second != first)
        await poller.stop(gen: first)
        #expect(await poller.isRunning)
        await poller.stop(gen: second)
        #expect(await !poller.isRunning)
    }

    @Test func pollerStopsOnErrorAndReportsIt() async {
        let clock = ManualClock()
        let source = FakeTerminalSource([.text("a"), .axDenied])
        let log = OutcomeLog()
        let poller = TerminalTextPoller(source: source, clock: clock) { _, _, o in log.add(o) }
        await poller.start(windowId: 7, pid: 1)
        await eventually { log.all.count == 1 && clock.sleeperCount == 1 }
        clock.advance(by: .seconds(1))
        await eventually { log.all.count == 2 }
        #expect(log.all.last == .error(.axDenied))
        #expect(await !poller.isRunning)
    }

    @Test func protocolDecodesAndEncodes() throws {
        #expect(try ClientMessage.decode(Data(#"{"t":"term.start","windowId":7}"#.utf8), on: .socket) == .termStart(windowId: 7))
        #expect(try ClientMessage.decode(Data(#"{"t":"term.stop"}"#.utf8), on: .socket) == .termStop)
        #expect(throws: ProtocolError.invalidValue("windowId")) { try ClientMessage.decode(Data(#"{"t":"term.start"}"#.utf8)) }
        #expect(throws: ProtocolError.wrongChannel("term.start")) {
            try ClientMessage.decode(Data(#"{"t":"term.start","windowId":7}"#.utf8), on: .control)
        }
        func json(_ m: ServerMessage) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(m.jsonString().utf8)) as! [String: Any]
        }
        let text = try json(.termText(windowId: 7, text: "$ ls\n", rev: 3))
        #expect(text["t"] as? String == "term.text" && text["windowId"] as? Int == 7)
        #expect(text["text"] as? String == "$ ls\n" && text["rev"] as? Int == 3)
        let error = try json(.termError(windowId: 7, code: .noText))
        #expect(error["t"] as? String == "term.error" && error["code"] as? String == "no_text")
        let streaming = try json(.viewState(windowId: 7, state: .streaming, reason: nil, termText: true))
        #expect(streaming["termText"] as? Bool == true)
        #expect(try json(.viewState(windowId: 7, state: .streaming, reason: nil))["termText"] == nil)
    }
}

private final class NoCapture: CaptureHandle { func stop() {} }

/// Views window 7 of `bundleId` and reads its text from `source`.
private final class TerminalBackend: SessionBackend, @unchecked Sendable {
    let bundleId: String
    let source: FakeTerminalSource
    init(bundleId: String, source: FakeTerminalSource) {
        self.bundleId = bundleId
        self.source = source
    }
    func permissions() -> PermissionsStatus { PermissionsStatus(screenRecording: true, accessibility: true) }
    func listWindows() async throws -> [WindowItem] { [] }
    func startCapture(windowId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> CaptureStart {
        .started(NoCapture(), WindowItem(id: windowId, pid: 1, app: "Terminal", title: "zsh", w: 800, h: 600, bundleId: bundleId))
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
    func listMenu(windowId: UInt32) async -> MenuListOutcome { .failed(.menuUnavailable) }
    func terminalTextSource() -> (any TerminalTextSource)? { source }
}

/// D67 through the real server and session.
@Suite(.serialized, .timeLimit(.minutes(1))) struct SessionTerminalTextTests {
    static let owner = "owner@example.com"

    func withSession(bundleId: String, source: FakeTerminalSource,
                     _ body: @escaping @Sendable (_ next: () async throws -> String, _ write: (String) async throws -> Void) async throws -> Void) async throws {
        let hub = SessionHub(owner: OwnerLogin(override: { "" }, query: { Self.owner }),
                             backend: TerminalBackend(bundleId: bundleId, source: source))
        let app = Server.makeApplication(port: 0, webRoot: nil, hub: hub)
        try await app.test(.live) { client in
            var fields = HTTPFields()
            fields[HTTPField.Name(TailscaleIdentity.loginHeader)!] = Self.owner
            try await client.ws("/ws", configuration: WebSocketClientConfiguration(additionalHeaders: fields)) { inbound, outbound, _ in
                var it = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                func next() async throws -> String {
                    while true {
                        guard case .text(let t)? = try await it.next() else { Issue.record("no reply"); return "" }
                        if !t.contains(#""t":"ping""#) { return t }
                    }
                }
                func write(_ s: String) async throws { try await outbound.write(.text(s)) }
                _ = try await next() // hello
                try await body(next, write)
            }
        }
    }

    @Test func terminalWindowStreamsWithTermTextAndSendsItsText() async throws {
        let source = FakeTerminalSource([.text("$ echo hi\nhi\n")])
        try await withSession(bundleId: "com.apple.Terminal", source: source) { next, write in
            try await write(#"{"t":"view.start","windowId":7}"#)
            _ = try await next() // starting
            #expect(try await next().contains(#""termText":true"#))
            try await write(#"{"t":"term.start","windowId":7}"#)
            let text = try await next()
            #expect(text.contains(#""t":"term.text""#) && text.contains(#""rev":1"#) && text.contains(#"hi\n"#))
            try await write(#"{"t":"term.stop"}"#)
            try await write(#"{"t":"term.start","windowId":7}"#)
            #expect(try await next().contains(#""rev":2"#), "a new start resends the text")
        }
    }

    @Test func otherAppsAndOtherWindowsAreNotTerminal() async throws {
        try await withSession(bundleId: "com.apple.TextEdit", source: FakeTerminalSource([.text("x")])) { next, write in
            try await write(#"{"t":"term.start","windowId":7}"#)
            #expect(try await next().contains(#""code":"not_terminal""#), "nothing viewed")
            try await write(#"{"t":"view.start","windowId":7}"#)
            _ = try await next()
            let streaming = try await next()
            #expect(streaming.contains(#""state":"streaming""#) && !streaming.contains("termText"))
            try await write(#"{"t":"term.start","windowId":7}"#)
            let error = try await next()
            #expect(error.contains(#""t":"term.error""#) && error.contains(#""code":"not_terminal""#))
        }
    }

    @Test func readErrorsBecomeTermErrorAndWindowGoneEndsTheView() async throws {
        let source = FakeTerminalSource([.axDenied])
        try await withSession(bundleId: "com.apple.Terminal", source: source) { next, write in
            try await write(#"{"t":"view.start","windowId":7}"#)
            _ = try await next()
            _ = try await next()
            try await write(#"{"t":"term.start","windowId":7}"#)
            #expect(try await next().contains(#""code":"ax_denied""#))
            source.set(.windowGone)
            try await write(#"{"t":"term.start","windowId":7}"#)
            #expect(try await next().contains(#""state":"window_gone""#))
        }
    }
}
