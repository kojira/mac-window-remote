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
    /// Performs one input action in order. Returns an error code on failure.
    func perform(_ job: InputJob) async -> ErrorCode?
    /// Called when capture starts or stops (display assertion, menu bar state).
    func viewingChanged(_ window: WindowItem?)
}

enum CaptureEvent: Sendable {
    case frame(FrameHeader, Data)
    case windowGone
    case streamStopped
}

enum CaptureStart {
    case started(any CaptureHandle, WindowItem)
    case windowGone
    case unavailable(reason: String)
}

protocol CaptureHandle: AnyObject, Sendable {
    func ack(frameId: Int)
    func stop()
}

struct InputJob: Sendable {
    enum Kind: Sendable {
        case pointer(PointerAction, u: Double, v: Double)
        case scroll(u: Double, v: Double, du: Double, dv: Double)
        case text(String)
        case key(String)
    }
    let windowId: UInt32
    /// Window frame (points) from the header of the frame the user saw (D7).
    let frameWindow: Rect?
    let kind: Kind
}

/// Connection state shown in the menu bar.
enum ConnectionStatus: Equatable, Sendable {
    case idle
    case connected
    case viewing(app: String, title: String)
}

/// Owns the single active client (D6) and the pairing secret used to authenticate it.
actor SessionHub {
    private var secret: String
    private var active: Session?
    let backend: any SessionBackend
    let authTimeout: Duration
    private let onStatus: @Sendable (ConnectionStatus) -> Void

    init(secret: String, backend: any SessionBackend, authTimeout: Duration = .seconds(5),
         onStatus: @escaping @Sendable (ConnectionStatus) -> Void = { _ in }) {
        self.secret = secret
        self.backend = backend
        self.authTimeout = authTimeout
        self.onStatus = onStatus
    }

    func verify(_ candidate: String) -> Bool {
        PairingSecret.matches(candidate, secret)
    }

    /// Makes `session` the active client, closing the previous one with 4002.
    func activate(_ session: Session) async {
        let previous = active
        active = session
        onStatus(.connected)
        if let previous {
            log.info("session replaced")
            await previous.close(code: CloseCode.replaced, reason: "replaced")
        }
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

    /// Reset pairing: new secret, and the open session is closed with 4001.
    func resetSecret(_ newSecret: String) async {
        secret = newSecret
        if let current = active {
            active = nil
            onStatus(.idle)
            await current.close(code: CloseCode.authFailed, reason: "auth_failed")
        }
    }

    // MARK: WebSocket handler

    func handle(inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async {
        var iterator = inbound.messages(maxSize: Server.maxMessageSize).makeAsyncIterator()
        let timeout = authTimeout
        let timer = Task {
            try await Task.sleep(for: timeout)
            log.info("auth timeout")
            try? await outbound.close(.unknown(CloseCode.protocolError), reason: "protocol_error")
        }
        let first = try? await iterator.next()
        timer.cancel()
        guard case .text(let text)? = first,
              case .auth(let candidate)? = try? ClientMessage.decode(Data(text.utf8))
        else {
            try? await outbound.close(.unknown(CloseCode.protocolError), reason: "protocol_error")
            return
        }
        guard verify(candidate) else {
            log.info("auth failed")
            try? await outbound.close(.unknown(CloseCode.authFailed), reason: "auth_failed")
            return
        }
        let session = Session(hub: self, backend: backend, outbound: outbound)
        await activate(session)
        log.info("session authenticated")
        await session.send(.hello(permissions: backend.permissions()))
        await session.run(&iterator)
        await session.teardown()
        ended(session)
        log.info("session ended")
    }
}

/// One authenticated client connection.
actor Session {
    private weak var hub: SessionHub?
    private let backend: any SessionBackend
    private let outbound: WebSocketOutboundWriter
    private var closed = false

    // Viewing state
    private var viewingWindowId: UInt32?
    private var capture: (any CaptureHandle)?
    private var recentFrames: [FrameHeader] = []
    private var retryTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    // Input runs in order on one consumer (D9).
    private let inputJobs: AsyncStream<InputJob>
    private let inputContinuation: AsyncStream<InputJob>.Continuation
    private var inputTask: Task<Void, Never>?

    static let frameHistory = 16
    static let captureRetryInterval: Duration = .seconds(5)
    static let pingInterval: Duration = .seconds(10)

    init(hub: SessionHub, backend: any SessionBackend, outbound: WebSocketOutboundWriter) {
        self.hub = hub
        self.backend = backend
        self.outbound = outbound
        (inputJobs, inputContinuation) = AsyncStream.makeStream(of: InputJob.self)
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
                    await handle(try ClientMessage.decode(Data(text.utf8)))
                } catch {
                    await send(.error(code: .badRequest, message: "Bad request"))
                }
            case .binary:
                // Image upload arrives in slice 3.
                await send(.error(code: .badRequest, message: "Binary messages are not supported"))
            }
        }
    }

    private func startBackgroundTasks() {
        let jobs = inputJobs
        let backend = backend
        inputTask = Task { [weak self] in
            for await job in jobs {
                if let code = await backend.perform(job) {
                    await self?.reportInputError(code)
                }
            }
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Session.pingInterval)
                guard !Task.isCancelled else { return }
                await self?.send(.ping)
            }
        }
    }

    private func reportInputError(_ code: ErrorCode) async {
        let message: String
        switch code {
        case .permissionAccessibility: message = "Mac needs Accessibility permission to control windows."
        case .staleCoordinates: message = "The window moved; try again."
        case .windowNotFound: message = "Window not found"
        default: message = "Input failed"
        }
        await send(.error(code: code, message: message))
    }

    func handle(_ message: ClientMessage) async {
        switch message {
        case .auth:
            await send(.error(code: .badRequest, message: "Already authenticated"))
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
            await startViewing(windowId)
        case .viewStop:
            stopViewing()
            if let id = viewingWindowId { await send(.viewState(windowId: id, state: .stopped, reason: nil)) }
            viewingWindowId = nil
        case .frameAck(let frameId):
            capture?.ack(frameId: frameId)
        case .pointer(let action, let u, let v, let frameId):
            enqueueInput(.pointer(action, u: u, v: v), frameId: frameId)
        case .scroll(let u, let v, let du, let dv, let frameId):
            enqueueInput(.scroll(u: u, v: v, du: du, dv: dv), frameId: frameId)
        case .text(let text):
            enqueueInput(.text(text), frameId: nil)
        case .key(let name):
            enqueueInput(.key(name), frameId: nil)
        }
    }

    private func enqueueInput(_ kind: InputJob.Kind, frameId: Int?) {
        guard let windowId = viewingWindowId else { return }
        let header = frameId.flatMap { id in recentFrames.last { $0.frameId == id } } ?? recentFrames.last
        inputContinuation.yield(InputJob(windowId: windowId, frameWindow: header?.window, kind: kind))
    }

    // MARK: Capture

    private func startViewing(_ windowId: UInt32) async {
        // A new view.start while already viewing stops the old stream first (D18).
        stopViewing()
        viewingWindowId = windowId
        guard backend.permissions().screenRecording else {
            await send(.viewState(windowId: windowId, state: .captureUnavailable, reason: "permission_screen_recording"))
            return
        }
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
            backend.viewingChanged(window)
            await hub?.statusChanged(self, .viewing(app: window.app, title: window.title))
            await send(.viewState(windowId: windowId, state: .streaming, reason: nil))
        case .windowGone:
            viewingWindowId = nil
            await send(.viewState(windowId: windowId, state: .windowGone, reason: nil))
        case .unavailable(let reason):
            await send(.viewState(windowId: windowId, state: .captureUnavailable, reason: reason))
            scheduleRetry(windowId)
        }
    }

    private func captureEvent(_ event: CaptureEvent, windowId: UInt32) async {
        guard viewingWindowId == windowId, !closed else { return }
        switch event {
        case .frame(let header, let jpeg):
            recentFrames.append(header)
            if recentFrames.count > Self.frameHistory { recentFrames.removeFirst() }
            await sendFrame(header, jpeg)
        case .windowGone:
            stopViewing()
            viewingWindowId = nil
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
            backend.viewingChanged(nil)
            Task { await hub?.statusChanged(self, .connected) }
        }
        recentFrames.removeAll()
    }

    // MARK: Output

    func send(_ message: ServerMessage) async {
        guard !closed else { return }
        try? await outbound.write(.text(message.jsonString()))
    }

    private func sendFrame(_ header: FrameHeader, _ jpeg: Data) async {
        guard !closed, let headerData = try? JSONEncoder().encode(header) else { return }
        let message = BinaryFraming.encode(header: headerData, payload: jpeg)
        log.debug("frame sent id=\(header.frameId, privacy: .public) window=\(header.windowId, privacy: .public) bytes=\(message.count, privacy: .public)")
        try? await outbound.write(.binary(ByteBuffer(bytes: message)))
    }

    func close(code: UInt16, reason: String) async {
        guard !closed else { return }
        try? await outbound.close(.unknown(code), reason: reason)
        closed = true
    }

    /// Disconnect stops capture and pending input (D18).
    func teardown() {
        closed = true
        stopViewing()
        viewingWindowId = nil
        pingTask?.cancel()
        inputContinuation.finish()
        inputTask?.cancel()
    }
}
