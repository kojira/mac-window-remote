import AppKit
import ScreenCaptureKit

/// The real `SessionBackend`: ScreenCaptureKit, WebRTC, AX focus, CGEvent input.
final class MacBackend: SessionBackend, @unchecked Sendable {
    private let rtc: RTCHost
    private let onViewing: @Sendable (WindowItem?) -> Void
    private let lock = NSLock()
    private var viewing: WindowItem?
    /// The viewed display (D56), for the display assertion alongside `viewing`.
    private var viewingDisplay: DisplayItem?
    private let displayAssertion = DisplayAssertion()
    private let resizer = WindowResizer()
    /// The latest capture, whose composite the input maps to (D44).
    private weak var capture: CaptureSession?

    init(rtc: RTCHost, onViewing: @escaping @Sendable (WindowItem?) -> Void) {
        self.rtc = rtc
        self.onViewing = onViewing
    }

    func makePeer() -> RTCPeer? { rtc.makePeer() }

    /// Created on first use, so nothing touches Core Audio until the phone asks for audio (D39).
    private lazy var audioTap: AnyObject? = {
        if #available(macOS 14.2, *) { return SystemAudioTap(device: rtc.audioDevice) }
        return nil
    }()

    func setAudio(_ target: AudioTarget?, events: @escaping @Sendable (AudioEvent) -> Void) -> Bool {
        guard #available(macOS 14.2, *) else { return target == nil }
        let tap = lock.withLock { audioTap as? SystemAudioTap }
        tap?.setTarget(target, events: events)
        return tap != nil
    }

    /// D57: Core Audio is touched only when the device turns the mic on.
    private lazy var mic: MicPlayout = { [rtc] in
        MicPlayout(listDevices: CoreAudioDevices.outputDevices,
                   openSink: { try BlackHoleSink(device: $0, audioDevice: rtc.audioDevice) })
    }()

    func setMic(_ on: Bool) -> MicOutcome {
        let mic = lock.withLock { self.mic }
        return mic.set(on)
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
        let capture = CaptureSession(window: window, capturer: rtc.capturer, events: events)
        do {
            try await capture.start()
        } catch {
            log.error("capture start failed id=\(windowId, privacy: .public): \(String(describing: error), privacy: .public)")
            return .unavailable(reason: "stream_stopped")
        }
        lock.withLock { self.capture = capture }
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

    func fitWindow(windowId: UInt32, aspect: Double) async -> WindowFitOutcome {
        guard Permissions.accessibility else { return .failed(.permissionAccessibility) }
        guard let pid = pid(for: windowId) else { return .failed(.windowNotFound) }
        return await resizer.fit(windowId: windowId, pid: pid, aspect: aspect)
    }

    func restoreWindow(windowId: UInt32) async -> WindowFitOutcome {
        guard Permissions.accessibility else { return .failed(.permissionAccessibility) }
        guard let pid = pid(for: windowId) else { return .failed(.windowNotFound) }
        return await resizer.restore(windowId: windowId, pid: pid)
    }

    /// How long the view waits for ⌘Tab or ⌘F1 to bring another window forward, and how often
    /// it checks (D38).
    static let windowSwitchTimeout: Duration = .seconds(1)
    static let windowSwitchPoll: Duration = .milliseconds(25)

    func windowAfterSwitch(from windowId: UInt32) async -> WindowItem? {
        guard pid(for: windowId) != nil else { return nil }
        let windows = (try? await WindowCatalog.shareableWindows()) ?? []
        let pickable = Set(windows.map(\.windowID))
        let deadline = ContinuousClock.now + Self.windowSwitchTimeout
        while ContinuousClock.now < deadline {
            if let front = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier }),
               let id = WindowCatalog.switchedWindowId(from: windowId, frontPid: front,
                                                       order: WindowCatalog.onScreenOrder(), pickable: pickable),
               let window = windows.first(where: { $0.windowID == id }) {
                return WindowCatalog.item(for: window)
            }
            try? await Task.sleep(for: Self.windowSwitchPoll)
        }
        log.info("window switch not followed reason=timeout")
        return nil
    }

    // MARK: App launcher (D40)

    private let apps = AppCatalog()

    func listApps() async -> [AppItem] {
        await MainActor.run { apps.list() }
    }

    func appIcon(id: String) async -> Data? {
        await MainActor.run { apps.icon(for: id) }
    }

    /// How long `openApp` waits for the app's window, and how often it looks (D40).
    static let appWindowTimeout: Duration = .seconds(10)
    static let appWindowPoll: Duration = .milliseconds(250)

    func openApp(id: String) async -> AppOpenOutcome {
        // Only bundles from the list this Mac produced are ever opened.
        guard let url = apps.url(for: id) else { return .failed(.appNotFound) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let pid: pid_t
        do {
            pid = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration).processIdentifier
        } catch {
            log.error("app open failed: \(String(describing: error), privacy: .public)")
            return .failed(.appLaunchFailed)
        }
        log.info("app opened pid=\(pid, privacy: .public)")
        let deadline = ContinuousClock.now + Self.appWindowTimeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let windows = (try? await WindowCatalog.shareableWindows()) ?? []
            let pickable = Set(windows.map(\.windowID))
            if let windowId = WindowCatalog.frontWindowId(of: pid, order: WindowCatalog.onScreenOrder(), pickable: pickable),
               let window = windows.first(where: { $0.windowID == windowId }) {
                return .window(WindowCatalog.item(for: window))
            }
            try? await Task.sleep(for: Self.appWindowPoll)
        }
        log.info("app open found no window")
        return .failed(.appNoWindow)
    }

    // MARK: The viewed app's menu bar (D43)

    /// A slow app's menu is cut off after this long; the listing is marked truncated.
    static let menuReadBudget: Duration = .seconds(3)

    func listMenu(windowId: UInt32) async -> MenuListOutcome {
        guard Permissions.accessibility else { return .failed(.permissionAccessibility) }
        guard let pid = pid(for: windowId) else { return .failed(.windowNotFound) }
        let deadline = ContinuousClock.now + Self.menuReadBudget
        guard let listing = MenuTree.build(AXMenuSource(pid: pid), expired: { ContinuousClock.now >= deadline }) else {
            return .failed(.menuUnavailable)
        }
        return .listed(listing)
    }

    func viewingChanged(_ window: WindowItem?) {
        let any = lock.withLock {
            viewing = window
            return window != nil || viewingDisplay != nil
        }
        if any { displayAssertion.hold() } else { displayAssertion.release() }
        onViewing(window)
    }

    // MARK: Display mode (D56)

    func listDisplays() async throws -> [DisplayItem] { try await DisplayCatalog.list() }

    func startDisplayCapture(displayId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> DisplayCaptureStart {
        let displays: [SCDisplay]
        do {
            displays = try await DisplayCatalog.displays()
        } catch {
            log.error("shareable content failed: \(String(describing: error), privacy: .public)")
            return .unavailable(reason: Permissions.screenRecording ? "stream_stopped" : "permission_screen_recording")
        }
        guard let display = displays.first(where: { $0.displayID == displayId }) else { return .displayGone }
        let capture = DisplayCaptureSession(display: display, capturer: rtc.capturer, events: events)
        do {
            try await capture.start()
        } catch {
            log.error("display capture start failed id=\(displayId, privacy: .public): \(String(describing: error), privacy: .public)")
            return .unavailable(reason: "stream_stopped")
        }
        log.info("display capture started id=\(displayId, privacy: .public)")
        let names = await MainActor.run { DisplayCatalog.names() }
        return .started(capture, DisplayCatalog.item(for: display, names: names))
    }

    func displayCursor(displayId: UInt32) async -> CursorState? {
        guard let frame = DisplayCatalog.frame(displayId) else { return nil }
        // CGEvent locations are global CG coordinates, like the display frame.
        guard let mouse = CGEvent(source: nil)?.location else { return nil }
        return DisplayGeometry.cursor(at: mouse, in: frame)
    }

    func viewingDisplayChanged(_ display: DisplayItem?) {
        let any = lock.withLock {
            viewingDisplay = display
            return display != nil || viewing != nil
        }
        if any { displayAssertion.hold() } else { displayAssertion.release() }
    }

    func declareUserActivity() {
        displayAssertion.declareUserActivity()
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
        let windowId: UInt32
        switch action.target {
        case .window(let id): windowId = id
        case .display(let displayId): return await performOnDisplay(action, displayId: displayId)
        }
        guard let windowBounds = WindowCatalog.currentBounds(windowId), let pid = pid(for: windowId) else {
            log.info("input rejected kind=\(kind, privacy: .public) reason=window_not_found")
            return .windowNotFound
        }
        // With child windows the video is the composite area, so the cursor maps to it (D44).
        let composite = lock.withLock { capture?.windowId == windowId ? capture?.composite : nil }
        let bounds = composite?.rect ?? windowBounds
        let p = action.cursor.globalPoint(in: bounds)
        if case .move = action.kind {
            // A plain cursor move never needs focus (D25).
            await InputInjector.move(to: p)
            return nil
        }
        // Everything else needs the window in front: raise once if it is not (D25). With child
        // windows, a click on the app's own topmost window is posted without any raise; one
        // under another app's window focuses the included window under it (never raising the
        // viewed window over a child), and keys go to an adopted child in front (D44).
        var focus = WindowFocuser.Outcome.alreadyFront
        switch action.kind {
        case .dragEnd, .mouseButton(_, false, _): break
        default:
            var target: ChildWindows.Entry? = ChildWindows.Entry(id: windowId, pid: pid, layer: 0, frame: windowBounds)
            var isClick = false
            if let composite {
                let entries = ChildWindows.onScreenEntries()
                switch action.kind {
                case .click, .rightClick, .dragStart, .mouseButton(_, true, _):
                    isClick = true
                    switch ChildWindows.clickFocus(at: p, viewedId: windowId, viewedFrame: windowBounds,
                                                   pid: pid, childIds: composite.childIds, entries: entries) {
                    case .post: target = nil
                    case .raise(let entry): target = entry
                    }
                default:
                    let id = ChildWindows.keyTarget(viewedId: windowId, childIds: composite.childIds,
                                                    entries: entries)
                    if id != windowId, let childBounds = WindowCatalog.currentBounds(id) {
                        target = ChildWindows.Entry(id: id, pid: pid, layer: 0, frame: childBounds)
                    }
                }
            }
            if let target {
                focus = WindowFocuser.focus(windowId: target.id, pid: pid, bounds: target.frame, layer: target.layer)
            } else {
                focus = await MainActor.run { WindowFocuser.activateApp(pid: pid) }
            }
            if isClick {
                let targetId = target.map { String($0.id) } ?? "topmost"
                log.notice("click target id=\(targetId, privacy: .public) viewed=\(windowId, privacy: .public) layer=\(target?.layer ?? -1, privacy: .public) focus=\(focus.rawValue, privacy: .public)")
            }
        }
        switch action.kind {
        case .move:
            break
        case .click, .rightClick, .dragStart:
            if focus != .alreadyFront { try? await Task.sleep(for: Self.clickAfterRaise) }
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
        case .mouseButton(let button, let down, let clicks):
            // D45: the browser counts clicks, so the Mac's own counter restarts.
            clickCounter.reset()
            let cgButton: CGMouseButton = switch button {
            case .left: .left
            case .right: .right
            case .middle: .center
            }
            if down {
                if focus != .alreadyFront { try? await Task.sleep(for: Self.clickAfterRaise) }
                await InputInjector.buttonDown(cgButton, at: p, clickState: clicks)
            } else {
                await InputInjector.buttonUp(cgButton, at: p, clickState: clicks)
            }
        case .scroll(let du, let dv):
            await InputInjector.scroll(at: p, dx: du * bounds.width, dy: dv * bounds.height)
        case .text(let text):
            await InputInjector.type(text)
        case .key(let name, let mods):
            // ⌘Tab and ⌘F1 switch away from the front window, so the raised window must be
            // in front first, as before a click (D38).
            if focus == .raised, InputAction.Kind.isWindowSwitch(name, mods) {
                try? await Task.sleep(for: Self.clickAfterRaise)
            }
            await InputInjector.key(name, mods: mods)
        case .menuPress(let path, let titles):
            // The app is in front before its menu item runs, as before a click (D25, D43).
            if focus == .raised { try? await Task.sleep(for: Self.clickAfterRaise) }
            if let code = MenuTree.press(AXMenuSource(pid: pid), path: path, titles: titles) {
                log.info("menu press failed code=\(code.rawValue, privacy: .public)")
                return code
            }
        case .paste(let text):
            // The raised window needs to be in front before ⌘V, as before a click (D25).
            if focus == .raised { try? await Task.sleep(for: Self.clickAfterRaise) }
            // Recorded as our own change, so D51 does not send it back to the device.
            await MainActor.run { SystemPasteboard.shared.writeOwnText(text) }
            await InputInjector.key("v", mods: [.cmd])
        }
        if case .scroll = action.kind { return nil }
        let total = ContinuousClock.now - started
        log.info("input posted kind=\(kind, privacy: .public) focus=\(focus.rawValue, privacy: .public) performMs=\(total.milliseconds, privacy: .public) sinceReceiptMs=\((ContinuousClock.now - action.received).milliseconds, privacy: .public)")
        return nil
    }
}

extension MacBackend {
    /// D56: no raise or activate; the events go to the point, keys to the focused app.
    private func performOnDisplay(_ action: InputAction, displayId: UInt32) async -> ErrorCode? {
        guard let frame = DisplayCatalog.frame(displayId) else {
            log.info("input rejected kind=\(action.kind.logName, privacy: .public) reason=display_not_found")
            return .windowNotFound
        }
        var clicks = 1
        switch action.kind {
        case .click:
            clicks = clickCounter.register(at: action.cursor.globalPoint(in: frame),
                                           time: ProcessInfo.processInfo.systemUptime,
                                           interval: NSEvent.doubleClickInterval)
        case .move, .scroll: break
        default: clickCounter.reset()
        }
        return await DisplayInput.perform(action, frame: frame, clickState: clicks, poster: InjectorPoster())
    }
}

/// `DisplayEventPoster` over `InputInjector` (D56).
struct InjectorPoster: DisplayEventPoster {
    func move(to p: CGPoint) async { await InputInjector.move(to: p) }
    func click(at p: CGPoint, clickState: Int) async { await InputInjector.click(at: p, clickState: clickState) }
    func rightClick(at p: CGPoint) async { await InputInjector.rightClick(at: p) }
    func buttonDown(_ button: CGMouseButton, at p: CGPoint, clickState: Int) async {
        await InputInjector.buttonDown(button, at: p, clickState: clickState)
    }
    func buttonUp(_ button: CGMouseButton, at p: CGPoint, clickState: Int) async {
        await InputInjector.buttonUp(button, at: p, clickState: clickState)
    }
    func scroll(at p: CGPoint, dx: Double, dy: Double) async { await InputInjector.scroll(at: p, dx: dx, dy: dy) }
    func key(_ name: String, mods: [KeyModifier]) async { await InputInjector.key(name, mods: mods) }
    func type(_ text: String) async { await InputInjector.type(text) }
    func paste(_ text: String) async {
        await MainActor.run { SystemPasteboard.shared.writeOwnText(text) }
        await InputInjector.key("v", mods: [.cmd])
    }
}

extension Duration {
    var milliseconds: Int {
        let c = components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }
}
