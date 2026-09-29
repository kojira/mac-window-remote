import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging

/// Hummingbird app: static web client + `/ws` (DESIGN.md D2). Binds to 127.0.0.1 only.
/// Every request must carry the Mac owner's Tailscale login (D32).
enum Server {
    /// Largest client message accepted. Slice 1 only has small JSON text messages;
    /// image upload (slice 3) raises this to 26 MiB.
    static let maxMessageSize = 1 << 20

    static func webRoot() -> String? {
        if let dev = ProcessInfo.processInfo.environment["MWR_WEB_ROOT"], !dev.isEmpty { return dev }
        return Bundle.main.resourceURL?.appendingPathComponent("web").path
    }

    static func makeApplication(port: Int, webRoot: String?, hub: SessionHub) -> some ApplicationProtocol {
        var logger = Logging.Logger(label: "mac-window-remote.http")
        logger.logLevel = .warning

        let router = Router(context: BasicWebSocketRequestContext.self)
        router.middlewares.add(TailscaleIdentityMiddleware(hub: hub))
        if let webRoot {
            router.middlewares.add(
                FileMiddleware(webRoot, cacheControl: .init([(MediaType(type: .any), [.noCache])]), searchForIndexHtml: true, logger: logger))
        }
        router.ws("/ws") { _, _ in
            .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            let login = context.request.headers[HTTPField.Name(TailscaleIdentity.loginHeader)!]
            await hub.handle(inbound: inbound, outbound: outbound, login: login)
        }

        return Application(
            router: router,
            server: .http1WebSocketUpgrade(
                webSocketRouter: router,
                configuration: .init(ws: .init(
                    maxFrameSize: maxMessageSize,
                    autoPing: .enabled(timePeriod: .seconds(10))))),
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: nil),
            logger: logger)
    }
}

/// 403 for HTTP requests that are not from the Mac owner (D32). `/ws` is let through: its
/// handler checks the same header and closes with 4001, which the phone can show, whereas a
/// refused upgrade reaches the page only as an unexplained error.
struct TailscaleIdentityMiddleware<Context: RequestContext>: RouterMiddleware {
    let hub: SessionHub

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if request.uri.path == "/ws" { return try await next(request, context) }
        let login = request.headers[HTTPField.Name(TailscaleIdentity.loginHeader)!]
        let decision = await hub.admit(login: login)
        guard decision == .allowed else {
            log.info("http request not allowed reason=\(String(describing: decision), privacy: .public)")
            return Response(
                status: .forbidden,
                headers: [.contentType: "text/plain; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string: TailscaleIdentity.notAllowedMessage + "\n")))
        }
        return try await next(request, context)
    }
}
