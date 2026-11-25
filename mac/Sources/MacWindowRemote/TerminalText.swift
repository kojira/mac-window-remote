import Foundation

// The Terminal text view (DESIGN.md D67). While the page shows 📄, the session reads the text of
// the viewed Terminal window's selected tab about once a second (and soon after typing into it)
// and sends it when it changed. Reading goes through `TerminalTextSource`, so the rules here
// (the app gate, the cap, change detection, the schedule) are tested against a fake;
// `AXTerminalTextSource` is the Accessibility implementation, which only reads attributes.

/// What one read of a terminal window found.
enum TerminalTextRead: Equatable, Sendable {
    /// The selected tab's text, scrollback included.
    case text(String)
    /// The window has no readable terminal text (no AX window or text area, or no value).
    case noText
    /// Accessibility permission is missing.
    case axDenied
    /// The window no longer exists.
    case windowGone
}

/// Reads the text of a terminal window. Implementations read only: they post no input and
/// change no selection or focus.
protocol TerminalTextSource: Sendable {
    func read(windowId: UInt32, pid: pid_t) -> TerminalTextRead
}

/// `term.error` codes (D67).
enum TerminalTextError: String, Codable, Equatable, Sendable {
    /// The viewed window is not a supported terminal app, or no window is viewed.
    case notTerminal = "not_terminal"
    case noText = "no_text"
    case axDenied = "ax_denied"
}

enum TerminalText {
    /// The apps whose windows offer the text view. Only Terminal.app for now.
    static let supportedBundleIds: Set<String> = ["com.apple.Terminal"]
    static let maxLines = 2000
    static let maxBytes = 512 << 10

    static func isSupported(bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return supportedBundleIds.contains(bundleId)
    }

    /// The last `maxLines` lines of `text`, then at most its last `maxBytes` bytes of UTF-8,
    /// cut at a line start when a line break is in the kept part (else at a character).
    static func cap(_ text: String, maxLines: Int = maxLines, maxBytes: Int = maxBytes) -> String {
        let bytes = Array(text.utf8)
        let newline = UInt8(ascii: "\n")
        var start = 0
        var breaks = 0
        var i = bytes.count
        while i > 0 {
            i -= 1
            if bytes[i] == newline {
                breaks += 1
                if breaks == maxLines { start = i + 1; break }
            }
        }
        if bytes.count - start > maxBytes {
            start = bytes.count - maxBytes
            if let line = bytes[start...].firstIndex(of: newline) {
                start = line + 1
            } else {
                // No line break kept: cut at a character boundary (skip UTF-8 continuation bytes).
                while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
            }
        }
        if start == 0 { return text }
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    /// FNV-1a over the UTF-8 bytes: a cheap, stable fingerprint for change detection.
    static func hash(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }
}

/// Turns reads into what the session sends: the capped text with a rising `rev` only when it
/// changed, an error, or window gone.
struct TerminalTextWatch {
    enum Outcome: Equatable {
        case send(text: String, rev: Int)
        case unchanged
        case error(TerminalTextError)
        case windowGone
    }

    /// Counts sent texts per session; it never goes back, so the page can drop a stale one.
    private(set) var rev = 0
    private var lastHash: UInt64?

    /// A new `term.start`: the next read is sent even if it is the same text.
    mutating func reset() { lastHash = nil }

    mutating func receive(_ read: TerminalTextRead) -> Outcome {
        switch read {
        case .axDenied: return .error(.axDenied)
        case .noText: return .error(.noText)
        case .windowGone: return .windowGone
        case .text(let raw):
            let text = TerminalText.cap(raw)
            let hash = TerminalText.hash(text)
            guard hash != lastHash else { return .unchanged }
            lastHash = hash
            rev += 1
            return .send(text: text, rev: rev)
        }
    }
}

/// How often the text view reads: every `poll`, and `debounce` after an input (D67).
struct TerminalPollTiming: Sendable {
    var poll: Duration = .seconds(1)
    var debounce: Duration = .milliseconds(150)
}

/// When the next read is due: `poll` after the previous read started, and `debounce` after the
/// last input to the window if that is sooner. Pure over the instants it is given.
struct TerminalPollSchedule<Instant: InstantProtocol> where Instant.Duration == Duration {
    let timing: TerminalPollTiming
    private(set) var nextPoll: Instant
    /// Due `debounce` after the latest input; a newer input moves it later.
    private(set) var nudge: Instant?

    /// The first read is due at once.
    init(timing: TerminalPollTiming, start: Instant) {
        self.timing = timing
        nextPoll = start
    }

    var nextDeadline: Instant {
        guard let nudge else { return nextPoll }
        return min(nudge, nextPoll)
    }

    mutating func inputArrived(at now: Instant) {
        nudge = now.advanced(by: timing.debounce)
    }

    /// A read that started at `start` is done. It covers a nudge that was due by then; a later
    /// input (during the read) keeps its nudge.
    mutating func didRead(startedAt start: Instant) {
        nextPoll = start.advanced(by: timing.poll)
        if let nudge, nudge <= start { self.nudge = nil }
    }
}

/// The AX tree as the text-area search sees it; tests use a fake tree.
protocol TerminalTextTree {
    associatedtype Element
    func role(_ element: Element) -> String?
    func children(_ element: Element) -> [Element]
    /// `AXValue` as a string, or nil.
    func stringValue(_ element: Element) -> String?
}

enum TerminalTextArea {
    /// How deep and how wide the search goes below the window, so a large window cannot stall a read.
    static let maxDepth = 8
    static let maxElements = 400

    /// The window's terminal text: the first `AXTextArea` (breadth first) whose parent is an
    /// `AXScrollArea`. In Terminal.app that is the selected tab's text view; other tabs are not
    /// in the window's tree. nil when there is none or it has no string value.
    static func text<Tree: TerminalTextTree>(in window: Tree.Element, tree: Tree) -> String? {
        var level: [(element: Tree.Element, parentRole: String?)] = [(window, nil)]
        var visited = 0
        for _ in 0...maxDepth {
            var next: [(element: Tree.Element, parentRole: String?)] = []
            for (element, parentRole) in level {
                visited += 1
                if visited > maxElements { return nil }
                let role = tree.role(element)
                if role == "AXTextArea", parentRole == "AXScrollArea" { return tree.stringValue(element) }
                for child in tree.children(element) { next.append((child, role)) }
            }
            if next.isEmpty { return nil }
            level = next
        }
        return nil
    }
}

/// Polls one terminal window while the text view is on (D67): reads at once, then every
/// `timing.poll`, and `timing.debounce` after the latest input. `onOutcome` gets every read's
/// outcome except `unchanged`, with the generation `start` returned, so the caller can drop a
/// late outcome of an earlier start. One poller serves a whole session, so `rev` keeps rising
/// across starts. `clock` is injected so tests drive time.
actor TerminalTextPoller<C: Clock> where C.Duration == Duration {
    private let source: any TerminalTextSource
    private let clock: C
    private let timing: TerminalPollTiming
    private let onOutcome: @Sendable (_ gen: Int, _ windowId: UInt32, TerminalTextWatch.Outcome) async -> Void
    private var watch = TerminalTextWatch()
    private var schedule: TerminalPollSchedule<C.Instant>?
    private var target: (windowId: UInt32, pid: pid_t)?
    private var gen = 0
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?

    init(source: any TerminalTextSource, clock: C, timing: TerminalPollTiming = .init(),
         onOutcome: @escaping @Sendable (_ gen: Int, _ windowId: UInt32, TerminalTextWatch.Outcome) async -> Void) {
        self.source = source
        self.clock = clock
        self.timing = timing
        self.onOutcome = onOutcome
    }

    var isRunning: Bool { target != nil }

    /// Starts (or restarts) polling `windowId`; the first read is sent even if unchanged.
    /// Returns this start's generation.
    @discardableResult
    func start(windowId: UInt32, pid: pid_t) -> Int {
        stop()
        target = (windowId, pid)
        watch.reset()
        schedule = TerminalPollSchedule(timing: timing, start: clock.now)
        let gen = self.gen
        loop = Task { await self.run(gen: gen) }
        return gen
    }

    func stop() {
        end()
        loop?.cancel()
        loop = nil
    }

    /// Stops the start `gen` only; a newer start keeps running.
    func stop(gen: Int) {
        if gen == self.gen, target != nil { stop() }
    }

    /// A key or text went to the polled window: read again soon.
    func inputArrived() {
        guard target != nil else { return }
        schedule?.inputArrived(at: clock.now)
        sleeper?.cancel()
    }

    /// Ends the current start without cancelling the loop's task, which may still deliver its
    /// last outcome (a cancelled task's socket write would fail).
    private func end() {
        gen += 1
        target = nil
        schedule = nil
        sleeper?.cancel()
        sleeper = nil
    }

    private func run(gen: Int) async {
        while gen == self.gen, let deadline = schedule?.nextDeadline {
            if clock.now < deadline {
                let clock = self.clock
                let nap = Task { _ = try? await clock.sleep(until: deadline, tolerance: nil) }
                sleeper = nap
                await nap.value
                continue
            }
            guard let target else { return }
            schedule?.didRead(startedAt: clock.now)
            let outcome = watch.receive(source.read(windowId: target.windowId, pid: target.pid))
            guard gen == self.gen else { return }
            switch outcome {
            case .unchanged:
                continue
            case .send:
                await onOutcome(gen, target.windowId, outcome)
            case .error, .windowGone:
                // The page shows the error; polling ends until the next `term.start`.
                end()
                await onOutcome(gen, target.windowId, outcome)
                return
            }
        }
    }
}
