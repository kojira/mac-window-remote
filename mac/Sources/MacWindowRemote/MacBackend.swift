import AppKit
import ScreenCaptureKit

/// The real `SessionBackend`: ScreenCaptureKit, WebRTC, AX focus, CGEvent input.
final class MacBackend: SessionBackend, @unchecked Sendable {
    private let rtc: RTCHost
    private let onViewing: @Sendable (WindowItem?) -> Void
    private let lock = NSLock()
    private var viewing: WindowItem?
    private let displayAssertion = DisplayAssertion()

    init(rtc: RTCHost, onViewing: @escaping @Sendable (WindowItem?) -> Void) {
        self.rtc = rtc
        self.onViewing = onViewing
    }

    func makePeer() -> RTCPeer? { rtc.makePeer() }

    func permissions() -> PermissionsStatus { Permissions.status }

    func listWindows() async throws -> [WindowItem] { try await WindowCatalog.list() }

    func startCapture(windowId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> CaptureStart {
        let windows: [SCWindow]
        do {
            windows = try await WindowCatalog.shareableWindows()
        } catch {
            log.error("shareable content failed: \(String(describing: error), privacy: .public)")
            return .unavailable(reason: Permissions.screenRecording ? "stream_stopped" : "permission_screen_recording")
        }
        guard let window = windows.first(where: { $0.windowID == windowId }) else { return .windowGone }
        let capture = CaptureSession(window: window, capturer: rtc.capturer, events: events)
        do {
            try await capture.start()
        } catch {
            log.error("capture start failed id=\(windowId, privacy: .public): \(String(describing: error), privacy: .public)")
            return .unavailable(reason: "stream_stopped")
        }
        log.info("capture started id=\(windowId, privacy: .public)")
        return .started(capture, WindowCatalog.item(for: window))
    }

    func thumbnails(windowIds: [UInt32]) async -> [(windowId: UInt32, jpeg: Data?)] {
        // Minimized windows and other Spaces are not in the on-screen list, so they get none.
        let windows = (try? await WindowCatalog.shareableWindows()) ?? []
        var results: [(windowId: UInt32, jpeg: Data?)] = []
        for id in windowIds {
            guard !Task.isCancelled else { break }
            guard let window = windows.first(where: { $0.windowID == id }) else {
                results.append((id, nil))
                continue
            }
            results.append((id, await WindowThumbnail.jpeg(of: window)))
        }
        return results
    }

    func viewingChanged(_ window: WindowItem?) {
        lock.lock()
        viewing = window
        lock.unlock()
        if window != nil { displayAssertion.hold() } else { displayAssertion.release() }
        onViewing(window)
    }

    private func pid(for windowId: UInt32) -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return viewing?.id == windowId ? viewing?.pid : nil
    }

    /// Time for the window server to put a just-raised window in front before the first
    /// click (D25). The only focus-related delay.
    static let clickAfterRaise: Duration = .milliseconds(80)

    func focus(windowId: UInt32) async {
        guard Permissions.accessibility,
              let bounds = WindowCatalog.currentBounds(windowId), let pid = pid(for: windowId) else { return }
        let outcome = WindowFocuser.focus(windowId: windowId, pid: pid, bounds: bounds)
        log.info("focus id=\(windowId, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) reason=view_start")
    }

    func releaseButton() async {
        await InputInjector.releaseButton()
    }

    private var clickCounter = ClickCounter()

    func perform(_ action: InputAction) async -> ErrorCode? {
        let started = ContinuousClock.now
        let kind = action.kind.logName
        guard Permissions.accessibility else {
            log.info("input rejected kind=\(kind, privacy: .public) reason=permission_accessibility")
            return .permissionAccessibility
        }
        guard let bounds = WindowCatalog.currentBounds(action.windowId), let pid = pid(for: action.windowId) else {
            log.info("input rejected kind=\(kind, privacy: .public) reason=window_not_found")
            return .windowNotFound
        }
        let p = action.cursor.globalPoint(in: bounds)
        if case .move = action.kind {
            // A plain cursor move never needs focus (D25).
            await InputInjector.move(to: p)
            return nil
        }
        // Everything else needs the window in front: raise once if it is not (D25).
        var focus = WindowFocuser.Outcome.alreadyFront
        if case .dragEnd = action.kind {} else {
            focus = WindowFocuser.focus(windowId: action.windowId, pid: pid, bounds: bounds)
        }
        switch action.kind {
        case .move:
            break
        case .click, .rightClick, .dragStart:
            if focus == .raised { try? await Task.sleep(for: Self.clickAfterRaise) }
            switch action.kind {
            case .click:
                let count = clickCounter.register(at: p, time: ProcessInfo.processInfo.systemUptime,
                                                  interval: NSEvent.doubleClickInterval)
                await InputInjector.click(at: p, clickState: count)
            case .rightClick:
                clickCounter.reset()
                await InputInjector.rightClick(at: p)
            default:
                clickCounter.reset()
                await InputInjector.dragStart(at: p)
            }
        case .dragEnd:
            await InputInjector.dragEnd(at: p)
        case .scroll(let du, let dv):
            await InputInjector.scroll(at: p, dx: du * bounds.width, dy: dv * bounds.height)
        case .text(let text):
            await InputInjector.type(text)
        case .key(let name, let mods):
            await InputInjector.key(name, mods: mods)
        }
        if case .scroll = action.kind { return nil }
        let total = ContinuousClock.now - started
        log.info("input posted kind=\(kind, privacy: .public) focus=\(focus.rawValue, privacy: .public) performMs=\(total.milliseconds, privacy: .public) sinceReceiptMs=\((ContinuousClock.now - action.received).milliseconds, privacy: .public)")
        return nil
    }
}

extension Duration {
    var milliseconds: Int {
        let c = components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }
}
