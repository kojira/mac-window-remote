import Foundation
import HummingbirdWebSocket
import NIOCore
import NIOWebSocket
import os

let log = Logger(subsystem: "mac-window-remote", category: "server")

/// What a session needs from the Mac. The real implementation is `MacBackend`; tests use a fake.
protocol SessionBackend: Sendable {
    func permissions() -> PermissionsStatus
    func listWindows() async throws -> [WindowItem]
    /// Starts capturing a window. Events are delivered through `events`.
    func startCapture(windowId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> CaptureStart
    /// Posts one input (D26). Returns an error code on failure.
    func perform(_ action: InputAction) async -> ErrorCode?
    /// Brings the window to the front once if it is not frontmost (D25).
    func focus(windowId: UInt32) async
    /// Posts `leftMouseUp` if a drag holds the button (D26).
    func releaseButton() async
    /// A small JPEG of each window, in request order; nil for a window that is not on screen
    /// or cannot be captured (D33).
    func thumbnails(windowIds: [UInt32]) async -> [(windowId: UInt32, jpeg: Data?)]
    /// Resizes the viewed window to `aspect` on its screen, saving its frame first (D35).
    func fitWindow(windowId: UInt32, aspect: Double) async -> WindowFitOutcome
    /// Puts the window back to its frame before the first fit (D35).
    func restoreWindow(windowId: UInt32) async -> WindowFitOutcome
    /// After ⌘Tab or ⌘F1 (D38): waits up to about a second for the front app's frontmost
    /// pickable window to be another window than `windowId` and returns it, or nil.
    func windowAfterSwitch(from windowId: UInt32) async -> WindowItem?
    /// Called when capture starts or stops (display assertion, menu bar state).
    func viewingChanged(_ window: WindowItem?)
    /// A new answering peer connection that sends the capture track (D22), or nil if WebRTC is
    /// unavailable.
    func makePeer() -> RTCPeer?
    /// Starts, retargets, or (nil) stops the Mac audio tap (D39). False if this Mac cannot tap
    /// audio (macOS before 14.2).
    func setAudio(_ target: AudioTarget?, events: @escaping @Sendable (AudioEvent) -> Void) -> Bool
    /// D57: plays (or stops playing) the viewing device's microphone into BlackHole.
    func setMic(_ on: Bool) -> MicOutcome
    /// The Apps tab list; it becomes the allowlist for `openApp` and `appIcon` (D40).
    func listApps() async -> [AppItem]
    /// The PNG icon of an app in the last list, or nil for an unknown id (D40).
    func appIcon(id: String) async -> Data?
    /// Launches or activates an app of the last list and waits up to 10 s for its front
    /// pickable window (D40).
    func openApp(id: String) async -> AppOpenOutcome
    /// The menu bar of the viewed window's app (D43); pressing goes through `perform`.
    func listMenu(windowId: UInt32) async -> MenuListOutcome
    /// The connected displays with a thumbnail each (D56).
    func listDisplays() async throws -> [DisplayItem]
    /// Starts capturing a whole display (D56).
    func startDisplayCapture(displayId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> DisplayCaptureStart
    /// The Mac pointer as a cursor on the display, clamped to it; nil if the display is gone (D56).
    func displayCursor(displayId: UInt32) async -> CursorState?
    /// Called when a display view starts or stops (display assertion, menu bar state, D56).
    func viewingDisplayChanged(_ display: DisplayItem?)
    /// Turns a sleeping display on when viewing starts (`IOPMAssertionDeclareUserActivity`, #49).
    func declareUserActivity()
    /// D59: the pickable window to view instead of display `displayId`, or nil
    /// (`WindowCatalog.frontWindowId(onDisplay:…)`).
    func frontWindow(onDisplay displayId: UInt32) async -> WindowItem?
}

/// Backends without displays: the test fakes of window-mode features.
extension SessionBackend {
    func listDisplays() async throws -> [DisplayItem] { [] }
    func startDisplayCapture(displayId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> DisplayCaptureStart {
        .displayGone
    }
    func displayCursor(displayId: UInt32) async -> CursorState? { nil }
    func viewingDisplayChanged(_ display: DisplayItem?) {}
    func declareUserActivity() {}
    func frontWindow(onDisplay displayId: UInt32) async -> WindowItem? { nil }
}

/// Backends without a microphone path (D57): the test fakes of other features.
extension SessionBackend {
    func setMic(_ on: Bool) -> MicOutcome { on ? .noDevice : .off }
}

/// What `openApp` found (D40).
enum AppOpenOutcome: Equatable, Sendable {
    case window(WindowItem)
    case failed(ErrorCode)
}

enum CaptureEvent: Sendable {
    case windowGone
    case streamStopped
}

enum CaptureStart {
    case started(any CaptureHandle, WindowItem)
    case windowGone
    case unavailable(reason: String)
}

/// D56: `startDisplayCapture`'s result; `displayGone` means the display is not connected.
enum DisplayCaptureStart {
    case started(any CaptureHandle, DisplayItem)
    case displayGone
    case unavailable(reason: String)
}

protocol CaptureHandle: AnyObject, Sendable {
    func stop()
}

/// Connection state shown in the menu bar.
enum ConnectionStatus: Equatable, Sendable {
    case idle
    case connected
    case viewing(app: String, title: String)
}

/// Owns the single active client and the Tailscale identity check that admits it (D32).
actor SessionHub {
    private var active: Session?
    let backend: any SessionBackend
    let owner: OwnerLogin
    let uploads: UploadStore
    /// The largest file a session accepts (D42, D58); tests use a small one.
    let maxFileBytes: Int
    /// The Mac pasteboard whose new text goes to the device (D51) and that Copy to Mac writes
    /// (D52); nil sends nothing and fails Copy to Mac.
    let pasteboard: (any MacPasteboard)?
    /// One-time download tokens (D47), shared by the session that issues them and the HTTP route.
    private var downloads = DownloadTokenStore()
    private let onStatus: @Sendable (ConnectionStatus) -> Void

    init(owner: OwnerLogin, backend: any SessionBackend, uploads: UploadStore = .standard,
         pasteboard: (any MacPasteboard)? = nil, maxFileBytes: Int = FileUploadReceiver.maxFileBytes,
         onStatus: @escaping @Sendable (ConnectionStatus) -> Void = { _ in }) {
        self.owner = owner
        self.maxFileBytes = maxFileBytes
        self.backend = backend
        self.uploads = uploads
        self.pasteboard = pasteboard
        self.onStatus = onStatus
    }

    /// The identity check for one request (D32). The header value is never logged.
    func admit(login: String?) async -> TailscaleIdentity.Decision {
        TailscaleIdentity.check(header: login, owner: await owner.current())
    }

    /// Makes `session` the active client, closing the previous one with 4002.
    func activate(_ session: Session) async {
        let previous = active
        active = session
        onStatus(.connected)
        if let previous {
            log.info("session replaced")
            await previous.close(code: CloseCode.replaced, reason: "replaced")
            // Stop its capture now, so it cannot release state the new session sets up.
            await previous.teardown()
        }
    }

    /// A one-time token for `GET /download/<token>` (D47).
    func issueDownload(_ plan: DownloadPlan) -> String {
        downloads.issue(plan)
    }

    /// The plan of a token, which then no longer works; nil if unknown, used, or expired.
    func takeDownload(_ token: String) -> DownloadPlan? {
        downloads.take(token)
    }

    func ended(_ session: Session) {
        if active === session {
            active = nil
            onStatus(.idle)
        }
    }

    func statusChanged(_ session: Session, _ status: ConnectionStatus) {
        if active === session { onStatus(status) }
    }

    // MARK: WebSocket handler

    /// `login` is the `Tailscale-User-Login` header of the upgrade request. A rejected client
    /// is closed with 4001 after the upgrade, so the phone can show why (D32).
    func handle(inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter, login: String?) async {
        let decision = await admit(login: login)
        guard decision == .allowed else {
            log.info("connection not allowed reason=\(String(describing: decision), privacy: .public)")
            try? await outbound.close(.unknown(CloseCode.notAllowed), reason: "not_allowed")
            return
        }
        var iterator = inbound.messages(maxSize: Server.maxMessageSize).makeAsyncIterator()
        let session = Session(hub: self, backend: backend, outbound: outbound, uploads: uploads, pasteboard: pasteboard,
                              maxFileBytes: maxFileBytes)
        await activate(session)
        log.info("session started")
        await session.send(.hello(permissions: backend.permissions()))
        await session.run(&iterator)
        await session.teardown()
        ended(session)
        log.info("session ended")
    }
}

/// Set once from any thread; read by a file search between entries (D47).
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Lets the input pipeline, created in `Session.init`, call back into its session.
private final class WeakSession: @unchecked Sendable {
    weak var session: Session?
}

/// One authenticated client connection.
actor Session {
    private weak var hub: SessionHub?
    private let backend: any SessionBackend
    private let outbound: WebSocketOutboundWriter
    private var closed = false

    // Viewing state
    private var viewingWindowId: UInt32? {
        didSet { if viewingWindowId == nil { viewedPid = nil } }
    }
    /// The viewed window's app, once its capture started; App audio taps it (D39).
    private var viewedPid: pid_t? { didSet { applyAudio() } }
    /// The viewed display (D56); nil while a window or nothing is viewed.
    private var viewingDisplayId: UInt32? { didSet { applyAudio() } }
    private var capture: (any CaptureHandle)?
    /// `capture` is of a display (D56), so stopping it reports `viewingDisplayChanged`.
    private var captureIsDisplay = false
    private var retryTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    /// Polls the Mac pasteboard while this session is connected (D51).
    private var clipboardTask: Task<Void, Never>?
    private let pasteboard: (any MacPasteboard)?
    private var thumbsTask: Task<Void, Never>?
    /// The pending `app.open` (D40); a newer one, a view change, or teardown cancels it.
    private var appOpenTask: Task<Void, Never>?
    /// The running file search (D47); a newer search cancels it.
    private var searchTask: Task<Void, Never>?

    // The viewed app's menu bar (D43): the last listing's number, window, and leaf titles.
    private var menuGen = 0
    private var menuWindowId: UInt32?
    private var menuLeaves: [String: [String]] = [:]

    // WebRTC (D22, D27): the one peer connection, numbered by the client.
    private var peer: RTCPeer?
    private var peerNumber: Int?
    private var peerTask: Task<Void, Never>?
    private var peerConnected = false { didSet { applyAudio() } }

    // Mac audio on the phone (D39): the phone's choice and the tap this session runs.
    private var audioMode: AudioMode = .off { didSet { applyAudio() } }
    private var audioApplied: AudioTarget?
    /// D57: the device's microphone plays into BlackHole.
    private var micOn = false

    // Input: Mac-owned cursor, coalesced motion, ordered discrete inputs (D24, D25).
    private let input: InputPipeline

    // Image and file uploads (D36, D42), and files uploaded into a Mac folder (D58).
    private let uploads: UploadStore
    private var images = ImageUploadAssembler()
    private var pastedFiles: FileUploadReceiver
    private var folderFiles: FileUploadReceiver

    static let captureRetryInterval: Duration = .seconds(5)
    static let pingInterval: Duration = .seconds(10)

    init(hub: SessionHub, backend: any SessionBackend, outbound: WebSocketOutboundWriter, uploads: UploadStore,
         pasteboard: (any MacPasteboard)? = nil, maxFileBytes: Int = FileUploadReceiver.maxFileBytes) {
        pastedFiles = FileUploadReceiver(maxBytes: maxFileBytes)
        folderFiles = FileUploadReceiver(maxBytes: maxFileBytes)
        self.hub = hub
        self.backend = backend
        self.outbound = outbound
        self.uploads = uploads
        self.pasteboard = pasteboard
        let ref = WeakSession()
        input = InputPipeline(
            backend: backend,
            onError: { code in await ref.session?.reportInputError(code) },
            onCursor: { cursor, seq in await ref.session?.sendControl(.cursor(u: cursor.u, v: cursor.v, seq: seq)) })
        ref.session = self
    }

    func run(_ iterator: inout WebSocketInboundMessageStream.AsyncIterator) async {
        startBackgroundTasks()
        while true {
            let message: WebSocketMessage?
            do { message = try await iterator.next() } catch { break }
            guard let message else { break }
            switch message {
            case .text(let text):
                do {
                    await handle(try ClientMessage.decode(Data(text.utf8), on: .socket))
                } catch {
                    log.info("bad request: \(String(describing: error), privacy: .public)")
                    await send(.error(code: .badRequest, message: "Bad request"))
                }
            case .binary(let buffer):
                await binaryMessage(Data(buffer: buffer))
            }
        }
    }

    private func startBackgroundTasks() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Session.pingInterval)
                guard !Task.isCancelled else { return }
                await self?.send(.ping)
            }
        }
        if let pasteboard { startClipboardWatch(pasteboard) }
    }

    /// D51: the clipboard at connect is the baseline; each later text copy goes to the device.
    private func startClipboardWatch(_ pasteboard: any PasteboardReading) {
        clipboardTask = Task.detached { [weak self] in
            var watch = MacClipboardWatch(baseline: pasteboard)
            while !Task.isCancelled {
                try? await Task.sleep(for: MacClipboardWatch.pollInterval)
                guard !Task.isCancelled, let self else { return }
                if let message = watch.poll(pasteboard) {
                    log.info("mac clipboard sent")
                    await self.send(message)
                }
            }
        }
    }

    private func reportInputError(_ code: ErrorCode) async {
        let message: String
        switch code {
        case .permissionAccessibility: message = "Mac needs Accessibility permission to control windows."
        case .windowNotFound: message = "Window not found"
        default: message = "Input failed"
        }
        await sendControl(.error(code: code, message: message))
    }

    /// A message from a data channel (D22). Invalid `motion` messages are dropped silently;
    /// invalid `control` messages get `bad_request` on `control` (D28).
    private func dataChannelMessage(_ channel: MessageChannel, _ data: Data) async {
        do {
            let message = try ClientMessage.decode(data, on: channel)
            await handle(message)
        } catch where channel == .motion {
            log.debug("motion dropped: \(String(describing: error), privacy: .public)")
        } catch {
            log.info("bad request on control: \(String(describing: error), privacy: .public)")
            await sendControl(.error(code: .badRequest, message: "Bad request"))
        }
    }

    func handle(_ message: ClientMessage) async {
        switch message {
        case .windowsList:
            guard backend.permissions().screenRecording else {
                await send(.error(code: .permissionScreenRecording,
                                  message: "Screen Recording permission is missing on the Mac."))
                return
            }
            do {
                await send(.windows(try await backend.listWindows()))
            } catch {
                log.error("window list failed: \(String(describing: error), privacy: .public)")
                await send(.error(code: .internal, message: "Could not list windows"))
            }
        case .viewStart(let windowId):
            appOpenTask?.cancel()
            await startViewing(windowId)
        case .displaysList:
            guard backend.permissions().screenRecording else {
                await send(.error(code: .permissionScreenRecording,
                                  message: "Screen Recording permission is missing on the Mac."))
                return
            }
            do {
                await send(.displays(try await backend.listDisplays()))
            } catch {
                log.error("display list failed: \(String(describing: error), privacy: .public)")
                await send(.error(code: .internal, message: "Could not list displays"))
            }
        case .viewStartDisplay(let displayId):
            appOpenTask?.cancel()
            await startViewingDisplay(displayId)
        case .viewFront(let displayId):
            // D59: the page views the answer through its normal pick path (`view.start`).
            await send(.viewFrontResult(displayId: displayId, window: await backend.frontWindow(onDisplay: displayId)))
        case .thumbsRequest(let windowIds):
            sendThumbnails(windowIds)
        case .viewStop:
            appOpenTask?.cancel()
            stopViewing()
            if let id = viewingWindowId { await send(.viewState(windowId: id, state: .stopped, reason: nil)) }
            if let id = viewingDisplayId { await send(.displayViewState(displayId: id, state: .stopped, reason: nil)) }
            viewingWindowId = nil
            viewingDisplayId = nil
            await input.setTarget(nil)
        case .rtcOffer(let pc, let sdp):
            await answer(pc: pc, sdp: sdp)
        case .rtcIce(let pc, let candidate):
            guard pc == peerNumber, let peer else { return }
            // The end of candidates needs no action on the answering side.
            if let candidate { await peer.add(candidate) }
        case .move(let seq, let dx, let dy):
            await input.submitMove(seq: seq, dx: dx, dy: dy)
        case .scroll(let du, let dv):
            await input.submitScroll(du: du, dv: dv)
        case .point(let seq, let u, let v):
            await input.submitPoint(seq: seq, u: u, v: v)
        case .mouse(let button, let down, let clicks, let seq, let u, let v):
            await input.submitMouse(button, down: down, clicks: clicks, seq: seq, u: u, v: v)
        case .click:
            await input.submit(.click)
        case .rightClick:
            await input.submit(.rightClick)
        case .drag(let start):
            await input.submit(start ? .dragStart : .dragEnd)
        case .text(let text):
            await input.submit(.text(text))
        case .key(let name, let mods):
            if InputAction.Kind.isWindowSwitch(name, mods), let windowId = viewingWindowId {
                // The viewer follows the window that ⌘Tab or ⌘F1 brings forward (D38).
                await input.submit(.key(name, mods: mods)) { [weak self] code in
                    if let code {
                        await self?.reportInputError(code)
                    } else {
                        Task { await self?.followWindowSwitch(from: windowId) }
                    }
                }
            } else {
                await input.submit(.key(name, mods: mods))
            }
        case .windowFitPhone(let aspect):
            await resizeViewedWindow { backend, id in await backend.fitWindow(windowId: id, aspect: aspect) }
        case .windowRestore:
            await resizeViewedWindow { backend, id in await backend.restoreWindow(windowId: id) }
        case .audio(let mode):
            audioMode = mode
            log.info("audio mode=\(mode.rawValue, privacy: .public)")
            await sendControl(.audioState(mode: mode))
        case .mic(let on):
            let outcome = backend.setMic(on)
            if case .on = outcome { micOn = true } else { micOn = false }
            log.info("mic on=\(self.micOn, privacy: .public)")
            await sendControl(.micState(outcome))
        case .appsList:
            await send(.apps(await backend.listApps()))
        case .appOpen(let id):
            openApp(id)
        case .menuList:
            await listMenu()
        case .menuPress(let id, let gen):
            await pressMenu(id: id, gen: gen)
        case .filesList(let id, let path, let hidden, let sort):
            await listFiles(id: id, path: path, hidden: hidden, sort: sort)
        case .filesSearch(let id, let base, let query, let hidden):
            searchFiles(id: id, base: base, query: query, hidden: hidden)
        case .downloadRequest(let id, let paths):
            await prepareDownload(id: id, paths: paths)
        case .filesPutCancel(let id):
            folderFiles.cancel(id: id)
        }
    }

    // MARK: Download files from the Mac (D47)

    private static let home = NSHomeDirectory()

    private func listFiles(id: String, path: String, hidden: Bool, sort: FileSort) async {
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<FileListing, FileBrowserError> in
            Result { try FileBrowser.list(path: path, home: Session.home, showHidden: hidden, sort: sort) }
                .mapError { $0 as? FileBrowserError ?? .noAccess }
        }.value
        switch outcome {
        case .success(let listing):
            log.info("files listed count=\(listing.entries.count, privacy: .public) total=\(listing.total, privacy: .public)")
            await send(.files(id: id, listing: listing, places: FileBrowser.places(home: Session.home)))
        case .failure(let error):
            await sendFileError(error, id: id)
        }
    }

    private func searchFiles(id: String, base: String, query: String, hidden: Bool) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            // The walk runs off the actor; a newer search or teardown stops it through the flag.
            let stop = CancelFlag()
            let outcome = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) { () -> Result<FileSearchResult, FileBrowserError> in
                    Result {
                        try FileBrowser.search(base: base, query: query, home: Session.home, showHidden: hidden,
                                               isCancelled: { stop.isSet })
                    }.mapError { $0 as? FileBrowserError ?? .noAccess }
                }.value
            } onCancel: { stop.set() }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let result):
                log.info("files found count=\(result.entries.count, privacy: .public) timedOut=\(result.timedOut, privacy: .public)")
                await self?.send(.filesFound(id: id, result: result))
            case .failure(let error):
                await self?.sendFileError(error, id: id)
            }
        }
    }

    /// Checks the paths and pre-scans sizes, then replies with a one-time URL for exactly them.
    private func prepareDownload(id: String, paths: [String]) async {
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<DownloadPlan, FileBrowserError> in
            Result { try DownloadPlanner.plan(paths: paths, home: Session.home) }
                .mapError { $0 as? FileBrowserError ?? .noAccess }
        }.value
        switch outcome {
        case .success(let plan):
            guard let hub else { return }
            let token = await hub.issueDownload(plan)
            let size: Int64
            switch plan {
            case .file(_, _, let s): size = s
            case .zip(_, _, let total): size = total
            }
            log.info("download ready items=\(paths.count, privacy: .public) bytes=\(size, privacy: .public)")
            await send(.downloadReady(id: id, url: "/download/\(token)", name: plan.fileName, size: size))
        case .failure(let error):
            await sendFileError(error, id: id)
        }
    }

    private func sendFileError(_ error: FileBrowserError, id: String) async {
        let message: String
        switch error {
        case .badPath: message = "Not a valid path"
        case .notFound: message = "Not found"
        case .notADirectory: message = "Not a folder"
        case .noAccess: message = "No access"
        case .tooLarge: message = "Too large to download (max 2 GB, 100,000 files)"
        }
        await send(.error(code: error.code, message: message, id: id))
    }

    // MARK: The viewed app's menu bar (D43)

    private func listMenu() async {
        guard let windowId = viewingWindowId, capture != nil else {
            await send(.error(code: .windowNotFound, message: "Open a window first"))
            return
        }
        switch await backend.listMenu(windowId: windowId) {
        case .listed(let listing):
            guard viewingWindowId == windowId, !closed else { return }
            menuGen += 1
            menuWindowId = windowId
            menuLeaves = listing.leafTitles()
            log.info("menu listed gen=\(self.menuGen, privacy: .public) leaves=\(self.menuLeaves.count, privacy: .public) truncated=\(listing.truncated, privacy: .public)")
            await send(.menu(gen: menuGen, windowId: windowId, listing: listing))
        case .failed(let code):
            let message: String
            switch code {
            case .permissionAccessibility: message = "Mac needs Accessibility permission to control windows."
            case .windowNotFound: message = "Window not found"
            default: message = "This app's menu can't be read"
            }
            await send(.error(code: code, message: message))
        }
    }

    /// Only ids of the last listing for the window still viewed are pressed; the backend checks
    /// the titles along the path again on the live menu bar.
    private func pressMenu(id: String, gen: Int) async {
        guard gen == menuGen, let windowId = viewingWindowId, windowId == menuWindowId,
              let titles = menuLeaves[id], let path = MenuTree.path(id) else {
            await sendMenuError(.menuStale, id: id)
            return
        }
        log.info("menu press gen=\(gen, privacy: .public) depth=\(path.count, privacy: .public)")
        await input.submit(.menuPress(path: path, titles: titles)) { [weak self] code in
            if let code {
                await self?.sendMenuError(code, id: id)
            } else {
                await self?.send(.menuPressed(id: id))
            }
        }
    }

    private func sendMenuError(_ code: ErrorCode, id: String) async {
        let message: String
        switch code {
        case .menuStale: message = "The menu changed; open it again"
        case .menuDisabled: message = "That item is disabled"
        case .permissionAccessibility: message = "Mac needs Accessibility permission to control windows."
        case .windowNotFound: message = "Window not found"
        default: message = "Couldn't run the menu item"
        }
        await send(.error(code: code, message: message, id: id))
    }

    // MARK: App launcher (D40)

    /// Launches or activates the app, then views its front window the way ⌘Tab does (D38).
    private func openApp(_ id: String) {
        appOpenTask?.cancel()
        let backend = self.backend
        appOpenTask = Task { [weak self] in
            let outcome = await backend.openApp(id: id)
            guard !Task.isCancelled else { return }
            await self?.appOpened(id: id, outcome)
        }
    }

    private func appOpened(id: String, _ outcome: AppOpenOutcome) async {
        guard !closed else { return }
        switch outcome {
        case .window(let window):
            log.info("app opened, viewing id=\(window.id, privacy: .public)")
            await send(.viewSwitched(windowId: window.id, app: window.app, title: window.title))
            await startViewing(window.id)
        case .failed(let code):
            let message: String
            switch code {
            case .appNotFound: message = "App not found; refresh the list"
            case .appNoWindow: message = "The app has no window"
            default: message = "Could not open the app"
            }
            await send(.error(code: code, message: message, id: id))
        }
    }

    // MARK: Mac audio on the phone (D39)

    /// Runs the tap only while audio is on, the peer connection is connected, and (App mode) a
    /// window is viewed; anything else stops it, so the Mac is audible again.
    private func applyAudio() {
        // D56: a display has no app, so App plays the whole Mac while a display is viewed.
        let mode = audioMode == .app && viewingDisplayId != nil ? .all : audioMode
        let target = closed ? nil : AudioTarget.desired(mode: mode, peerConnected: peerConnected, viewedPid: viewedPid)
        guard target != audioApplied else { return }
        audioApplied = target
        let ok = backend.setAudio(target) { [weak self] event in
            Task { await self?.audioEvent(event) }
        }
        if !ok {
            audioApplied = nil
            Task { await audioEvent(.unavailable) }
        }
    }

    private func audioEvent(_ event: AudioEvent) async {
        guard !closed, audioMode != .off else { return }
        switch event {
        case .unavailable:
            audioMode = .off
            await sendControl(.error(code: .audioUnavailable, message: "Mac audio is not available on this Mac"))
            await sendControl(.audioState(mode: .off))
        case .silent:
            await sendControl(.error(code: .permissionAudioCapture,
                                     message: "No audio: allow audio capture in System Settings › Privacy & Security"))
        }
    }

    private func stopMic() {
        guard micOn else { return }
        micOn = false
        _ = backend.setMic(false)
    }

    // MARK: Follow ⌘Tab and ⌘F1 (D38)

    /// Switches the view to the window that came forward, the same way as `view.start` (no
    /// renegotiation), and tells the phone first. Nothing happens if the user switched
    /// windows meanwhile or no window came forward.
    private func followWindowSwitch(from windowId: UInt32) async {
        guard let window = await backend.windowAfterSwitch(from: windowId),
              viewingWindowId == windowId, capture != nil, !closed, window.id != windowId else { return }
        log.info("view follows window switch id=\(window.id, privacy: .public)")
        await send(.viewSwitched(windowId: window.id, app: window.app, title: window.title))
        await startViewing(window.id)
    }

    // MARK: Clipboard text and images (D36)

    private func binaryMessage(_ data: Data) async {
        let message: BinaryClientMessage
        do {
            message = try BinaryClientMessage.decode(data)
        } catch let rejection as UploadRejection {
            await sendUploadError(rejection.code, id: rejection.id)
            return
        } catch {
            log.info("bad binary request: \(String(describing: error), privacy: .public)")
            await send(.error(code: .badRequest, message: "Bad request"))
            return
        }
        switch message {
        case .clipboardPaste(let id, let text):
            log.info("clipboard paste received bytes=\(text.utf8.count, privacy: .public)")
            await pasteIntoViewedWindow(text, id: id, path: nil)
        case .clipboardSet(let id, let text):
            log.info("clipboard set received bytes=\(text.utf8.count, privacy: .public)")
            await setMacClipboard(text, id: id)
        case .imageChunk(let id, let size, let offset, let bytes):
            await imageChunk(id: id, size: size, offset: offset, bytes: bytes)
        case .fileChunk(let id, let size, let offset, let bytes, let name):
            await fileChunk(id: id, size: size, offset: offset, bytes: bytes, name: name)
        case .filesPut(let id, let size, let offset, let bytes, let name, let dest):
            await filesPut(id: id, size: size, offset: offset, bytes: bytes, name: name, dest: dest)
        }
    }

    /// An image chunk (D36): assembled in memory (at most 25 MiB), then saved and pasted.
    private func imageChunk(id: String, size: Int, offset: Int, bytes: Data) async {
        if offset == 0, viewingWindowId == nil, viewingDisplayId == nil {
            images.reject(id: id)
            await sendUploadError(.windowNotFound, id: id)
            return
        }
        let url: URL
        switch images.receive(id: id, size: size, offset: offset, bytes: bytes) {
        case .needMore, .ignored:
            return
        case .failed(let code):
            await sendUploadError(code, id: id)
            return
        case .complete(let image, let type):
            do {
                url = try uploads.save(image, type: type)
            } catch {
                log.error("image save failed: \(String(describing: error), privacy: .public)")
                await sendUploadError(.internal, id: id)
                return
            }
            log.info("image saved type=\(type.rawValue, privacy: .public) bytes=\(image.count, privacy: .public)")
        }
        await pasteIntoViewedWindow(url.path, id: id, path: url.path)
    }

    /// A 📎 File chunk (D42): streamed to `<uploads>/<UUID>/<name>`, then its path is pasted.
    private func fileChunk(id: String, size: Int, offset: Int, bytes: Data, name: String) async {
        let step: FileUploadReceiver.Step
        if offset == 0 {
            if viewingWindowId == nil, viewingDisplayId == nil {
                pastedFiles.reject(id: id)
                await sendUploadError(.windowNotFound, id: id)
                return
            }
            let uploads = self.uploads
            step = pastedFiles.start(id: id, size: size, name: name, bytes: bytes) { () throws(UploadFailure) in
                (try uploads.makeFileFolder(), ownsFolder: true)
            }
        } else {
            step = pastedFiles.append(id: id, size: size, offset: offset, bytes: bytes)
        }
        switch step {
        case .needMore, .ignored:
            return
        case .failed(let code):
            log.info("file upload failed code=\(code.rawValue, privacy: .public)")
            await sendUploadError(code, id: id)
        case .complete(let url):
            log.info("file saved bytes=\(size, privacy: .public)")
            await pasteIntoViewedWindow(url.path, id: id, path: url.path)
        }
    }

    /// D58 ⬆︎ Upload here: streamed into the folder `dest` and renamed to a free name there.
    /// Needs no viewed window; replies `result` with the final path.
    private func filesPut(id: String, size: Int, offset: Int, bytes: Data, name: String, dest: String) async {
        let step: FileUploadReceiver.Step
        if offset == 0 {
            step = folderFiles.start(id: id, size: size, name: name, bytes: bytes) { () throws(UploadFailure) in
                (try UploadDestination.resolve(dest), ownsFolder: false)
            }
        } else {
            step = folderFiles.append(id: id, size: size, offset: offset, bytes: bytes)
        }
        switch step {
        case .needMore, .ignored:
            return
        case .failed(let code):
            log.info("files.put failed code=\(code.rawValue, privacy: .public)")
            await sendUploadError(code, id: id)
        case .complete(let url):
            log.info("files.put saved bytes=\(size, privacy: .public)")
            await send(.result(id: id, path: url.path))
        }
    }

    /// Sets the Mac clipboard and sends ⌘V to the viewed window through the ordered input
    /// pipeline (D25), then replies `result` or `error` with the request id.
    private func pasteIntoViewedWindow(_ text: String, id: String, path: String?) async {
        await input.submit(.paste(text)) { [weak self] code in
            if let code {
                await self?.sendUploadError(code, id: id)
            } else {
                await self?.send(.result(id: id, path: path))
            }
        }
    }

    /// D52 Copy to Mac: the text goes on the Mac clipboard only (no ⌘V, no raise, no input
    /// event), recorded as our own change so D51 does not send it back.
    private func setMacClipboard(_ text: String, id: String) async {
        guard let pasteboard else {
            await sendUploadError(.internal, id: id)
            return
        }
        await MainActor.run { pasteboard.writeOwnText(text) }
        await send(.result(id: id, path: nil))
    }

    private func sendUploadError(_ code: ErrorCode, id: String) async {
        let message: String
        switch code {
        case .tooLarge: message = "Too large (max 2 GB)"
        case .notFound: message = "The folder does not exist"
        case .notADirectory: message = "Not a folder"
        case .notWritable, .noAccess: message = "The folder is not writable"
        case .diskFull: message = "The Mac's disk is full"
        case .unsupportedType: message = "Not a supported image (PNG, JPEG, HEIC, GIF, WebP)"
        case .windowNotFound: message = "Open a window first"
        case .permissionAccessibility: message = "Mac needs Accessibility permission to control windows."
        case .badRequest: message = "Bad request"
        default: message = "Could not save the upload"
        }
        await send(.error(code: code, message: message, id: id))
    }

    // MARK: Fit window to the phone (D35)

    private func resizeViewedWindow(_ action: (any SessionBackend, UInt32) async -> WindowFitOutcome) async {
        guard let windowId = viewingWindowId, capture != nil else {
            await sendControl(.error(code: .windowNotFound, message: "Window not found"))
            return
        }
        switch await action(backend, windowId) {
        case .done(let state, let clamped):
            await sendControl(.windowFit(windowId: windowId, state: state, clamped: clamped))
        case .failed(let code):
            let message: String
            switch code {
            case .permissionAccessibility: message = "Mac needs Accessibility permission to control windows."
            case .windowFullscreen: message = "Full-screen windows can't be resized"
            case .windowNotFitted: message = "Window size was already restored"
            case .windowNotFound: message = "Window not found"
            default: message = "This window can't be resized"
            }
            await sendControl(.error(code: code, message: message))
        }
    }

    // MARK: Thumbnails (D33)

    /// A newer request cancels the replies of one still in progress.
    private func sendThumbnails(_ windowIds: [UInt32]) {
        thumbsTask?.cancel()
        let backend = self.backend
        thumbsTask = Task { [weak self] in
            let results: [(windowId: UInt32, jpeg: Data?)]
            if backend.permissions().screenRecording {
                results = await backend.thumbnails(windowIds: windowIds)
            } else {
                results = windowIds.map { ($0, nil) }
            }
            guard !Task.isCancelled else { return }
            for r in results { await self?.send(.thumb(windowId: r.windowId, jpeg: r.jpeg)) }
        }
    }

    // MARK: WebRTC (D22, D27)

    /// Answers `rtc.offer`. A new `pc` replaces the current peer connection; the same `pc`
    /// renegotiates it (an ICE restart).
    private func answer(pc: Int, sdp: String) async {
        if pc != peerNumber || peer == nil {
            closePeer()
            guard let created = backend.makePeer() else {
                await send(.error(code: .rtcFailed, message: "WebRTC is unavailable"))
                return
            }
            peer = created
            peerNumber = pc
            created.setViewingDisplay(captureIsDisplay)
            peerTask = Task { [weak self] in
                for await event in created.events {
                    await self?.peerEvent(event, pc: pc)
                }
            }
            log.info("peer connection created pc=\(pc, privacy: .public)")
        }
        guard let peer else { return }
        do {
            let answer = try await peer.answer(offer: sdp)
            guard pc == peerNumber, !closed else { return }
            await send(.rtcAnswer(pc: pc, sdp: answer))
        } catch {
            log.error("answer failed pc=\(pc, privacy: .public): \(String(describing: error), privacy: .public)")
            if pc == peerNumber { closePeer() }
            await send(.error(code: .rtcFailed, message: "Could not answer the video offer"))
        }
    }

    private func peerEvent(_ event: RTCPeer.Event, pc: Int) async {
        guard pc == peerNumber, !closed else { return }
        switch event {
        case .localCandidate(let candidate):
            await send(.rtcIce(pc: pc, candidate: candidate))
        case .connectionState(let state):
            // D39: audio flows only while connected; a drop stops the tap at once.
            peerConnected = state == .connected
            // A failed or closed peer connection stops capture and releases a held button and
            // the display assertion (D27). The client starts a fresh one and resumes viewing.
            if state == .failed || state == .closed {
                closePeer()
                stopViewing()
                viewingWindowId = nil
                viewingDisplayId = nil
                await input.setTarget(nil)
            }
        case .message(let channel, let data):
            await dataChannelMessage(channel, data)
        }
    }

    private func closePeer() {
        peerConnected = false
        // D57: the mic's track ends with the peer; the device turns it on again on a new one.
        stopMic()
        peerTask?.cancel()
        peerTask = nil
        peer?.close()
        peer = nil
        peerNumber = nil
    }

    // MARK: Capture

    private func startViewing(_ windowId: UInt32) async {
        // A new view.start while already viewing stops the old stream first (D18), and a
        // window change releases a held button (D26).
        stopViewing()
        if viewingWindowId != windowId { await input.setTarget(nil) }
        viewingDisplayId = nil
        viewingWindowId = windowId
        guard backend.permissions().screenRecording else {
            await send(.viewState(windowId: windowId, state: .captureUnavailable, reason: "permission_screen_recording"))
            return
        }
        // #49: a sleeping display turns on, so the capture can start.
        backend.declareUserActivity()
        await send(.viewState(windowId: windowId, state: .starting, reason: nil))
        let result = await backend.startCapture(windowId: windowId) { [weak self] event in
            Task { await self?.captureEvent(event, windowId: windowId) }
        }
        guard viewingWindowId == windowId, !closed else {
            if case .started(let handle, _) = result { handle.stop() }
            return
        }
        switch result {
        case .started(let handle, let window):
            capture = handle
            viewedPid = window.pid
            backend.viewingChanged(window)
            peer?.setViewingDisplay(false)
            await input.setTarget(.window(windowId))
            await hub?.statusChanged(self, .viewing(app: window.app, title: window.title))
            await send(.viewState(windowId: windowId, state: .streaming, reason: nil))
        case .windowGone:
            viewingWindowId = nil
            await input.setTarget(nil)
            await send(.viewState(windowId: windowId, state: .windowGone, reason: nil))
        case .unavailable(let reason):
            await send(.viewState(windowId: windowId, state: .captureUnavailable, reason: reason))
            scheduleRetry(windowId)
        }
    }

    /// D56: like `startViewing`, for a whole display. Input goes to the point without any raise.
    private func startViewingDisplay(_ displayId: UInt32) async {
        stopViewing()
        if viewingDisplayId != displayId { await input.setTarget(nil) }
        viewingWindowId = nil
        viewingDisplayId = displayId
        guard backend.permissions().screenRecording else {
            await send(.displayViewState(displayId: displayId, state: .captureUnavailable, reason: "permission_screen_recording"))
            return
        }
        backend.declareUserActivity()
        await send(.displayViewState(displayId: displayId, state: .starting, reason: nil))
        let result = await backend.startDisplayCapture(displayId: displayId) { [weak self] event in
            Task { await self?.displayCaptureEvent(event, displayId: displayId) }
        }
        guard viewingDisplayId == displayId, !closed else {
            if case .started(let handle, _) = result { handle.stop() }
            return
        }
        switch result {
        case .started(let handle, let display):
            capture = handle
            captureIsDisplay = true
            backend.viewingDisplayChanged(display)
            peer?.setViewingDisplay(true)
            await input.setTarget(.display(displayId))
            await hub?.statusChanged(self, .viewing(app: "Display", title: display.name))
            await send(.displayViewState(displayId: displayId, state: .streaming, reason: nil))
        case .displayGone:
            viewingDisplayId = nil
            await input.setTarget(nil)
            await send(.displayViewState(displayId: displayId, state: .windowGone, reason: nil))
        case .unavailable(let reason):
            await send(.displayViewState(displayId: displayId, state: .captureUnavailable, reason: reason))
            scheduleDisplayRetry(displayId)
        }
    }

    private func displayCaptureEvent(_ event: CaptureEvent, displayId: UInt32) async {
        guard viewingDisplayId == displayId, !closed else { return }
        switch event {
        case .windowGone:
            stopViewing()
            viewingDisplayId = nil
            await input.setTarget(nil)
            await send(.displayViewState(displayId: displayId, state: .windowGone, reason: nil))
        case .streamStopped:
            stopViewing()
            await send(.displayViewState(displayId: displayId, state: .captureUnavailable, reason: "stream_stopped"))
            scheduleDisplayRetry(displayId)
        }
    }

    private func scheduleDisplayRetry(_ displayId: UInt32) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Session.captureRetryInterval)
            guard !Task.isCancelled else { return }
            await self?.retryDisplay(displayId)
        }
    }

    private func retryDisplay(_ displayId: UInt32) async {
        guard viewingDisplayId == displayId, capture == nil, !closed else { return }
        await startViewingDisplay(displayId)
    }

    private func captureEvent(_ event: CaptureEvent, windowId: UInt32) async {
        guard viewingWindowId == windowId, !closed else { return }
        switch event {
        case .windowGone:
            stopViewing()
            viewingWindowId = nil
            await input.setTarget(nil)
            await send(.viewState(windowId: windowId, state: .windowGone, reason: nil))
        case .streamStopped:
            stopViewing()
            await send(.viewState(windowId: windowId, state: .captureUnavailable, reason: "stream_stopped"))
            scheduleRetry(windowId)
        }
    }

    /// While the client stays in the viewer, retry every 5 s (D18).
    private func scheduleRetry(_ windowId: UInt32) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Session.captureRetryInterval)
            guard !Task.isCancelled else { return }
            await self?.retry(windowId)
        }
    }

    private func retry(_ windowId: UInt32) async {
        guard viewingWindowId == windowId, capture == nil, !closed else { return }
        await startViewing(windowId)
    }

    private func stopViewing() {
        retryTask?.cancel()
        retryTask = nil
        if let capture {
            capture.stop()
            self.capture = nil
            if captureIsDisplay { backend.viewingDisplayChanged(nil) } else { backend.viewingChanged(nil) }
            captureIsDisplay = false
            Task { await hub?.statusChanged(self, .connected) }
        }
    }

    // MARK: Output

    func send(_ message: ServerMessage) async {
        guard !closed else { return }
        try? await outbound.write(.text(message.jsonString()))
    }

    /// Input results travel on the `control` data channel (D22).
    func sendControl(_ message: ServerMessage) async {
        guard !closed, let peer else { return }
        peer.sendControl(message.jsonString())
    }

    func close(code: UInt16, reason: String) async {
        guard !closed else { return }
        try? await outbound.close(.unknown(code), reason: reason)
        closed = true
    }

    /// Disconnect stops capture and pending input, and releases a held button (D18, D26).
    func teardown() async {
        closed = true
        stopViewing()
        viewingWindowId = nil
        viewingDisplayId = nil
        pingTask?.cancel()
        clipboardTask?.cancel()
        thumbsTask?.cancel()
        appOpenTask?.cancel()
        searchTask?.cancel()
        // An unfinished file upload leaves no part file behind (D42, D58).
        pastedFiles.abort()
        folderFiles.abort()
        // Replacing or ending the session also closes its peer connection (D22).
        closePeer()
        await input.shutdown()
    }
}
