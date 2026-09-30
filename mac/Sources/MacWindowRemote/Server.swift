import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging

/// Hummingbird app: static web client + `/ws` (DESIGN.md D2). Binds to 127.0.0.1 only.
/// Every request must carry the Mac owner's Tailscale login (D32).
enum Server {
    /// Largest client message (and frame) accepted: 1 MiB of clipboard text plus its framing
    /// and header. Images arrive in 256 KiB chunks, so they fit too (D36).
    static let maxMessageSize = BinaryClientMessage.maxClipboardBytes + 64 * 1024

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
        // D40: icons of the Apps tab, only for ids of the list the Mac produced last.
        router.get("/apps/icon/:file") { _, context -> Response in
            let file = context.parameters.get("file") ?? ""
            guard file.hasSuffix(".png"), let png = await hub.backend.appIcon(id: String(file.dropLast(4))) else {
                return Response(status: .notFound)
            }
            return Response(
                status: .ok,
                headers: [.contentType: "image/png", .cacheControl: "private, max-age=86400"],
                body: .init(byteBuffer: ByteBuffer(bytes: png)))
        }
        // D47: a download prepared on the socket; each token works once, for a short time.
        router.get("/download/:token") { _, context -> Response in
            let token = context.parameters.get("token") ?? ""
            guard let plan = await hub.takeDownload(token) else {
                return Response(status: .notFound, headers: [.contentType: "text/plain; charset=utf-8"],
                                body: .init(byteBuffer: ByteBuffer(string: "This download link has expired. Choose Download again.\n")))
            }
            return downloadResponse(plan)
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

extension Server {
    /// One file as is, or a zip streamed as it is built (D47). Read only.
    static func downloadResponse(_ plan: DownloadPlan) -> Response {
        var headers: HTTPFields = [
            .contentDisposition: contentDisposition(fileName: plan.fileName),
            .cacheControl: "no-store",
        ]
        switch plan {
        case .file(let url, _, let size):
            headers[.contentType] = "application/octet-stream"
            return Response(status: .ok, headers: headers, body: ResponseBody(contentLength: Int(size)) { writer in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var remaining = Int(size)
                while remaining > 0 {
                    let chunk = try handle.read(upToCount: min(ZipStreamWriter.readChunk, remaining)) ?? Data()
                    if chunk.isEmpty { break }
                    remaining -= chunk.count
                    try await writer.write(ByteBuffer(bytes: chunk))
                }
                // A file that shrank since the check is padded so the length stays right.
                if remaining > 0 { try await writer.write(ByteBuffer(repeating: 0, count: remaining)) }
                try await writer.finish(nil)
            })
        case .zip(_, let sources, _):
            headers[.contentType] = "application/zip"
            return Response(status: .ok, headers: headers, body: ResponseBody { writer in
                let box = WriterBox(writer)
                let zip = ZipStreamWriter { data in try await box.write(data) }
                for source in sources { try await zip.add(source) }
                try await zip.finish()
                try await box.finish()
            })
        }
    }
}

/// Lets the zip writer's sink write to the response (the writer is `inout` in the closure).
private final class WriterBox: @unchecked Sendable {
    var writer: any ResponseBodyWriter
    init(_ writer: any ResponseBodyWriter) { self.writer = writer }
    func write(_ data: Data) async throws { try await writer.write(ByteBuffer(bytes: data)) }
    func finish() async throws { try await writer.finish(nil) }
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
