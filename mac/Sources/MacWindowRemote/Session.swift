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
            // Stop its capture now, so it cannot release state the new session sets up.
            await previous.teardown()
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
            await current.teardown()
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
    private var viewingWindowId: UInt32?
    private var capture: (any CaptureHandle)?
    private var retryTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    // Input: Mac-owned cursor, coalesced motion, ordered discrete inputs (D24, D25).
    private let input: InputPipeline

    static let captureRetryInterval: Duration = .seconds(5)
    static let pingInterval: Duration = .seconds(10)

    init(hub: SessionHub, backend: any SessionBackend, outbound: WebSocketOutboundWriter) {
        self.hub = hub
        self.backend = backend
        self.outbound = outbound
        let ref = WeakSession()
        input = InputPipeline(
            backend: backend,
            onError: { code in await ref.session?.reportInputError(code) },
            onCursor: { cursor, seq in await ref.session?.send(.cursor(u: cursor.u, v: cursor.v, seq: seq)) })
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
                let data = Data(text.utf8)
                do {
                    await handle(try ClientMessage.decode(data))
                } catch where ClientMessage.isMotion(data) {
                    // Invalid motion is dropped silently (D28).
                    log.debug("motion dropped: \(String(describing: error), privacy: .public)")
                } catch {
                    log.info("bad request: \(String(describing: error), privacy: .public)")
                    await send(.error(code: .badRequest, message: "Bad request"))
                }
            case .binary:
                // Image upload arrives in slice 3.
                await send(.error(code: .badRequest, message: "Binary messages are not supported"))
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
    }

    private func reportInputError(_ code: ErrorCode) async {
        let message: String
        switch code {
        case .permissionAccessibility: message = "Mac needs Accessibility permission to control windows."
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
            await input.setTarget(nil)
        case .frameAck(let frameId):
            capture?.ack(frameId: frameId)
        case .move(let seq, let dx, let dy):
            await input.submitMove(seq: seq, dx: dx, dy: dy)
        case .scroll(let du, let dv):
            await input.submitScroll(du: du, dv: dv)
        case .click:
            await input.submit(.click)
        case .rightClick:
            await input.submit(.rightClick)
        case .drag(let start):
            await input.submit(start ? .dragStart : .dragEnd)
        case .text(let text):
            await input.submit(.text(text))
        case .key(let name):
            await input.submit(.key(name))
        }
    }

    // MARK: Capture

    private func startViewing(_ windowId: UInt32) async {
        // A new view.start while already viewing stops the old stream first (D18), and a
        // window change releases a held button (D26).
        stopViewing()
        if viewingWindowId != windowId { await input.setTarget(nil) }
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
            await input.setTarget(windowId)
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

    private func captureEvent(_ event: CaptureEvent, windowId: UInt32) async {
        guard viewingWindowId == windowId, !closed else { return }
        switch event {
        case .frame(let header, let jpeg):
            await sendFrame(header, jpeg)
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
            backend.viewingChanged(nil)
            Task { await hub?.statusChanged(self, .connected) }
        }
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

    /// Disconnect stops capture and pending input, and releases a held button (D18, D26).
    func teardown() async {
        closed = true
        stopViewing()
        viewingWindowId = nil
        pingTask?.cancel()
        await input.shutdown()
    }
}
