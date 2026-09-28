import AppKit
import ScreenCaptureKit

/// The real `SessionBackend`: ScreenCaptureKit, AX focus, CGEvent input.
final class MacBackend: SessionBackend, @unchecked Sendable {
    private let onViewing: @Sendable (WindowItem?) -> Void
    private let lock = NSLock()
    private var viewing: WindowItem?
    private let displayAssertion = DisplayAssertion()

    init(onViewing: @escaping @Sendable (WindowItem?) -> Void) {
        self.onViewing = onViewing
    }

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
        let capture = CaptureSession(window: window, events: events)
        do {
            try await capture.start()
        } catch {
            log.error("capture start failed id=\(windowId, privacy: .public): \(String(describing: error), privacy: .public)")
            return .unavailable(reason: "stream_stopped")
        }
        log.info("capture started id=\(windowId, privacy: .public)")
        return .started(capture, WindowCatalog.item(for: window))
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

    func perform(_ job: InputJob) async -> ErrorCode? {
        let started = ContinuousClock.now
        let kind = job.kind.logName
        guard Permissions.accessibility else {
            log.info("input rejected kind=\(kind, privacy: .public) reason=permission_accessibility")
            return .permissionAccessibility
        }
        guard let bounds = WindowCatalog.currentBounds(job.windowId), let pid = pid(for: job.windowId) else {
            log.info("input rejected kind=\(kind, privacy: .public) reason=window_not_found")
            return .windowNotFound
        }
        // Resolve the target point before focusing, so a stale tap clicks nothing.
        var point: CGPoint?
        switch job.kind {
        case .pointer(_, let u, let v), .scroll(let u, let v, _, _):
            guard let frameWindow = job.frameWindow,
                  let p = CoordinateMapper.globalPoint(u: u, v: v, frameWindow: frameWindow, currentBounds: bounds)
            else {
                log.info("input rejected kind=\(kind, privacy: .public) reason=stale_coordinates hasFrame=\(job.frameWindow != nil, privacy: .public)")
                return .staleCoordinates
            }
            point = p
            // Window-relative points only.
            log.debug("input mapped kind=\(kind, privacy: .public) rel=(\(Int(p.x - bounds.minX), privacy: .public),\(Int(p.y - bounds.minY), privacy: .public)) window=\(Int(bounds.width), privacy: .public)x\(Int(bounds.height), privacy: .public)")
        case .text, .key:
            break
        }
        let focusStarted = ContinuousClock.now
        let focus = await WindowFocuser.focus(windowId: job.windowId, pid: pid, bounds: bounds)
        let focusTime = ContinuousClock.now - focusStarted
        switch job.kind {
        case .pointer(let action, _, _):
            await InputInjector.click(at: point!, count: action == .doubleClick ? 2 : 1)
        case .scroll(_, _, let du, let dv):
            let d = CoordinateMapper.scrollDelta(du: du, dv: dv, frameWindow: job.frameWindow!)
            await InputInjector.scroll(at: point!, dx: d.dx, dy: d.dy)
        case .text(let text):
            await InputInjector.type(text)
        case .key(let name):
            await InputInjector.key(name)
        }
        let total = ContinuousClock.now - started
        log.info("input posted kind=\(kind, privacy: .public) focus=\(focus.rawValue, privacy: .public) focusMs=\(focusTime.milliseconds, privacy: .public) performMs=\(total.milliseconds, privacy: .public) sinceReceiptMs=\((ContinuousClock.now - job.received).milliseconds, privacy: .public)")
        return nil
    }
}

extension InputJob.Kind {
    /// Log label; never includes typed text.
    var logName: String {
        switch self {
        case .pointer(let action, _, _): return "pointer.\(action.rawValue)"
        case .scroll: return "scroll"
        case .text: return "text"
        case .key: return "key"
        }
    }
}

extension Duration {
    var milliseconds: Int {
        let c = components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }
}
