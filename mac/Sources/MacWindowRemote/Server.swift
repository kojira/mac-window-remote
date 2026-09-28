import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging

/// Hummingbird app: static web client + `/ws` (DESIGN.md D2). Binds to 127.0.0.1 only.
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
        if let webRoot {
            router.middlewares.add(
                FileMiddleware(webRoot, cacheControl: .init([(MediaType(type: .any), [.noCache])]), searchForIndexHtml: true, logger: logger))
        }
        router.ws("/ws") { _, _ in
            .upgrade([:])
        } onUpgrade: { inbound, outbound, _ in
            await hub.handle(inbound: inbound, outbound: outbound)
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
