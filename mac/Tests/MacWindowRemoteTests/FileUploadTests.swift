import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import HummingbirdWebSocket
import WSClient
import Testing
@testable import MacWindowRemote

/// D58 ⬆︎ Upload here (and the D42 stream): destination checks, Finder-style collision names,
/// streaming into a hidden part file with an atomic rename, part cleanup, the size cap, and
/// `files.put` decoding. Temporary folders only.
@Suite struct FileUploadTests {
    func withFolder(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mwr-put-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            chmod(root.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        try body(URL(fileURLWithPath: try #require(realpath(root.path, nil).map { p in
            defer { free(p) }
            return String(cString: p)
        }), isDirectory: true))
    }

    func contents(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func start(_ r: inout FileUploadReceiver, id: String = "u1", size: Int, name: String = "a.txt",
               bytes: Data, into folder: URL) -> FileUploadReceiver.Step {
        r.start(id: id, size: size, name: name, bytes: bytes) { () throws(UploadFailure) in
            (try UploadDestination.resolve(folder.path), ownsFolder: false)
        }
    }

    @Test func collisionNamesAreFinderStyle() {
        #expect(UploadDestination.collisionName("photo.jpg", attempt: 1) == "photo.jpg")
        #expect(UploadDestination.collisionName("photo.jpg", attempt: 2) == "photo 2.jpg")
        #expect(UploadDestination.collisionName("photo.jpg", attempt: 3) == "photo 3.jpg")
        #expect(UploadDestination.collisionName("archive.tar.gz", attempt: 2) == "archive.tar 2.gz")
        #expect(UploadDestination.collisionName("README", attempt: 2) == "README 2")
    }

    @Test func sanitizerKeepsTheD42Rules() {
        #expect(UploadStore.sanitizedFileName("../../x/../evil.sh") == "evil.sh")
        #expect(UploadStore.sanitizedFileName("..") == "file")
        #expect(UploadStore.sanitizedFileName(".mwr-upload-x.part") == "mwr-upload-x.part")
        #expect(UploadStore.sanitizedFileName("a\u{1}b\tc.txt") == "abc.txt")
    }

    @Test func destinationMustBeAnExistingDirectoryAfterResolvingLinks() throws {
        try withFolder { root in
            let fm = FileManager.default
            let dir = root.appendingPathComponent("dir", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
            let file = root.appendingPathComponent("file.txt")
            try Data([1]).write(to: file)
            let link = root.appendingPathComponent("link")
            try fm.createSymbolicLink(at: link, withDestinationURL: dir)
            let fileLink = root.appendingPathComponent("file-link")
            try fm.createSymbolicLink(at: fileLink, withDestinationURL: file)

            #expect(try UploadDestination.resolve(dir.path).path == dir.path)
            #expect(try UploadDestination.resolve(link.path).path == dir.path)
            #expect(throws: UploadFailure(code: .notFound)) { try UploadDestination.resolve(root.appendingPathComponent("missing").path) }
            #expect(throws: UploadFailure(code: .notADirectory)) { try UploadDestination.resolve(file.path) }
            #expect(throws: UploadFailure(code: .notADirectory)) { try UploadDestination.resolve(fileLink.path) }
            #expect(throws: UploadFailure(code: .badRequest)) { try UploadDestination.resolve("relative/dir") }
            #expect(throws: UploadFailure(code: .badRequest)) { try UploadDestination.resolve("") }
        }
    }

    @Test func streamsIntoAHiddenPartAndRenamesItWithoutOverwriting() throws {
        try withFolder { folder in
            try Data("existing".utf8).write(to: folder.appendingPathComponent("a.txt"))
            var r = FileUploadReceiver()
            #expect(start(&r, size: 6, bytes: Data("abc".utf8), into: folder) == .needMore)
            // While it streams, only a hidden part file is in the folder beside the old file.
            let during = contents(folder)
            #expect(during.count == 2 && during.contains("a.txt"))
            let part = try #require(during.first { $0 != "a.txt" })
            #expect(part.hasPrefix(".mwr-upload-") && part.hasSuffix(".part"))
            #expect(try Data(contentsOf: folder.appendingPathComponent(part)) == Data("abc".utf8))

            let done = r.append(id: "u1", size: 6, offset: 3, bytes: Data("def".utf8))
            #expect(done == .complete(folder.appendingPathComponent("a 2.txt")))
            #expect(contents(folder) == ["a 2.txt", "a.txt"])
            #expect(try Data(contentsOf: folder.appendingPathComponent("a.txt")) == Data("existing".utf8))
            #expect(try Data(contentsOf: folder.appendingPathComponent("a 2.txt")) == Data("abcdef".utf8))

            // A third one gets "a 3.txt".
            #expect(start(&r, id: "u2", size: 1, bytes: Data([7]), into: folder) == .complete(folder.appendingPathComponent("a 3.txt")))
        }
    }

    @Test func aGapACancelOrAnAbortDeletesThePart() throws {
        try withFolder { folder in
            var r = FileUploadReceiver()
            #expect(start(&r, size: 10, bytes: Data([1, 2]), into: folder) == .needMore)
            #expect(r.append(id: "u1", size: 10, offset: 5, bytes: Data([1])) == .failed(.badRequest))
            #expect(contents(folder).isEmpty)
            #expect(r.append(id: "u1", size: 10, offset: 2, bytes: Data([1])) == .ignored)

            #expect(start(&r, id: "u2", size: 10, bytes: Data([1, 2]), into: folder) == .needMore)
            r.cancel(id: "u2")
            #expect(contents(folder).isEmpty)
            #expect(r.append(id: "u2", size: 10, offset: 2, bytes: Data([3])) == .ignored)

            #expect(start(&r, id: "u3", size: 10, bytes: Data([1, 2]), into: folder) == .needMore)
            // A newer upload replaces it.
            #expect(start(&r, id: "u4", size: 10, bytes: Data([1, 2]), into: folder) == .needMore)
            #expect(contents(folder).count == 1)
            r.abort()
            #expect(contents(folder).isEmpty)
            #expect(r.currentId == nil)
        }
    }

    @Test func theSizeCapIsCheckedUpFrontAndWhileWriting() throws {
        try withFolder { folder in
            var r = FileUploadReceiver(maxBytes: 8)
            var asked = false
            let tooBig = r.start(id: "u1", size: 9, name: "big.bin", bytes: Data([1])) { () throws(UploadFailure) in
                asked = true
                return (folder, ownsFolder: false)
            }
            #expect(tooBig == .failed(.tooLarge))
            #expect(!asked)
            #expect(contents(folder).isEmpty)
            #expect(r.append(id: "u1", size: 9, offset: 1, bytes: Data([1])) == .ignored)
            // Exactly the cap is accepted.
            #expect(start(&r, id: "u2", size: 8, name: "ok.bin", bytes: Data(count: 8), into: folder)
                    == .complete(folder.appendingPathComponent("ok.bin")))
            // The real cap is 2 GB.
            #expect(FileUploadReceiver.maxFileBytes == 2 * 1024 * 1024 * 1024)
        }
    }

    @Test func aReadOnlyFolderIsNotWritableAndLeavesNothing() throws {
        try withFolder { folder in
            let ro = folder.appendingPathComponent("ro", isDirectory: true)
            try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: false)
            chmod(ro.path, 0o500)
            defer { chmod(ro.path, 0o700) }
            var r = FileUploadReceiver()
            #expect(start(&r, size: 4, bytes: Data([1]), into: ro) == .failed(.notWritable))
            #expect(contents(ro).isEmpty)
            #expect(start(&r, id: "u2", size: 4, bytes: Data([1]), into: folder.appendingPathComponent("gone")) == .failed(.notFound))
        }
    }

    @Test func errnoMapsToClearCodes() {
        #expect(UploadFailure.posix(ENOENT).code == .notFound)
        #expect(UploadFailure.posix(EACCES).code == .notWritable)
        #expect(UploadFailure.posix(EROFS).code == .notWritable)
        #expect(UploadFailure.posix(ENOSPC).code == .diskFull)
        #expect(UploadFailure.posix(EDQUOT).code == .diskFull)
        #expect(UploadFailure.posix(EFBIG).code == .tooLarge)
        #expect(ErrorCode.notWritable.rawValue == "not_writable" && ErrorCode.diskFull.rawValue == "disk_full")
    }

    @Test func decodesFilesPutAndItsCancel() throws {
        let first = try BinaryClientMessage.decode(BinaryMessageTests.frame(
            #"{"t":"files.put","id":"p1","size":10,"offset":0,"name":"a b.pdf","dest":"/tmp/x y"}"#, Data([1])))
        #expect(first == .filesPut(id: "p1", size: 10, offset: 0, bytes: Data([1]), name: "a b.pdf", dest: "/tmp/x y"))
        let later = try BinaryClientMessage.decode(BinaryMessageTests.frame(
            #"{"t":"files.put","id":"p1","size":10,"offset":1,"name":"x","dest":"/y"}"#, Data([2])))
        #expect(later == .filesPut(id: "p1", size: 10, offset: 1, bytes: Data([2]), name: "", dest: ""))
        #expect(throws: ProtocolError.invalidValue("chunk")) {
            try BinaryClientMessage.decode(BinaryMessageTests.frame(#"{"t":"files.put","id":"p","size":1,"offset":0,"dest":"/"}"#, Data([1, 2])))
        }
        // A long folder path still fits the header.
        let long = "/" + String(repeating: "フォルダ/", count: 200)
        let m = try BinaryClientMessage.decode(BinaryMessageTests.frame(
            #"{"t":"files.put","id":"p2","size":1,"offset":0,"name":"n","dest":"\#(long)"}"#, Data([1])))
        #expect(m == .filesPut(id: "p2", size: 1, offset: 0, bytes: Data([1]), name: "n", dest: long))
        #expect(try ClientMessage.decode(Data(#"{"t":"files.put.cancel","id":"p1"}"#.utf8), on: .socket) == .filesPutCancel(id: "p1"))
    }
}

/// D58 through the real server and session: `files.put` needs no viewed window, saves into
/// the folder under a free name, and a disconnect mid-upload leaves no part file.
@Suite(.serialized) struct SessionFilesPutTests {
    static let owner = "owner@example.com"

    @Test func uploadsIntoTheFolderAndCleansUpOnDisconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwr-put-session-\(UUID().uuidString)")
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: dest.appendingPathComponent("notes.txt"))
        let store = UploadStore(directory: root.appendingPathComponent("uploads"))
        let hub = SessionHub(owner: OwnerLogin(override: { "" }, query: { Self.owner }), backend: StubBackend(),
                             uploads: store, maxFileBytes: 1 << 20)
        let app = Server.makeApplication(port: 0, webRoot: nil, hub: hub)
        let body = Data(repeating: 5, count: 300_000)
        let chunk = BinaryClientMessage.maxChunkBytes
        func header(_ id: String, _ size: Int, _ offset: Int, extra: String = "") -> String {
            #"{"t":"files.put","id":"\#(id)","size":\#(size),"offset":\#(offset)\#(extra)}"#
        }
        let first = #","name":"notes.txt","dest":"\#(dest.path)""#
        try await app.test(.live) { client in
            var fields = HTTPFields()
            fields[HTTPField.Name(TailscaleIdentity.loginHeader)!] = Self.owner
            try await client.ws("/ws", configuration: WebSocketClientConfiguration(additionalHeaders: fields)) { inbound, outbound, _ in
                var it = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                func nextText() async throws -> String? {
                    guard case .text(let t)? = try await it.next() else { return nil }
                    return t
                }
                _ = try await nextText() // hello
                for offset in stride(from: 0, to: body.count, by: chunk) {
                    let part = body[offset..<min(offset + chunk, body.count)]
                    try await outbound.write(.binary(SessionUploadTests.frame(
                        header("p1", body.count, offset, extra: offset == 0 ? first : ""), Data(part))))
                }
                let reply = try #require(try await nextText())
                #expect(reply.contains(#""t":"result""#) && reply.contains(#""id":"p1""#) && reply.contains("notes 2.txt"))
                #expect(try Data(contentsOf: dest.appendingPathComponent("notes 2.txt")) == body)
                #expect(try Data(contentsOf: dest.appendingPathComponent("notes.txt")) == Data("old".utf8))

                // Over the injected cap: too_large before anything is written.
                try await outbound.write(.binary(SessionUploadTests.frame(header("p2", (1 << 20) + 1, 0, extra: first), Data([1]))))
                let big = try #require(try await nextText())
                #expect(big.contains(#""code":"too_large""#) && big.contains(#""id":"p2""#))
                // A missing folder.
                try await outbound.write(.binary(SessionUploadTests.frame(
                    header("p3", 4, 0, extra: #","name":"x","dest":"\#(dest.path)/missing""#), Data([1]))))
                let missing = try #require(try await nextText())
                #expect(missing.contains(#""code":"not_found""#))

                // Half an upload, then the socket closes.
                try await outbound.write(.binary(SessionUploadTests.frame(header("p4", 10, 0, extra: first), Data([1, 2, 3]))))
                try await outbound.write(.text(#"{"t":"windows.list"}"#))
                _ = try await nextText() // the half upload was handled before this reply
                #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).contains { $0.hasSuffix(".part") })
                try await outbound.close(.normalClosure, reason: nil)
            }
        }
        // The session's teardown removed the part.
        for _ in 0..<50 where (try? FileManager.default.contentsOfDirectory(atPath: dest.path))?.contains(where: { $0.hasSuffix(".part") }) == true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted() == ["notes 2.txt", "notes.txt"])
    }

    @Test func cancelDeletesThePart() async throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("mwr-put-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let hub = SessionHub(owner: OwnerLogin(override: { "" }, query: { Self.owner }), backend: StubBackend(),
                             uploads: UploadStore(directory: dest.appendingPathComponent("unused")))
        let app = Server.makeApplication(port: 0, webRoot: nil, hub: hub)
        try await app.test(.live) { client in
            var fields = HTTPFields()
            fields[HTTPField.Name(TailscaleIdentity.loginHeader)!] = Self.owner
            try await client.ws("/ws", configuration: WebSocketClientConfiguration(additionalHeaders: fields)) { inbound, outbound, _ in
                var it = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                _ = try await it.next() // hello
                try await outbound.write(.binary(SessionUploadTests.frame(
                    #"{"t":"files.put","id":"p1","size":10,"offset":0,"name":"a","dest":"\#(dest.path)"}"#, Data([1]))))
                try await outbound.write(.text(#"{"t":"files.put.cancel","id":"p1"}"#))
                try await outbound.write(.text(#"{"t":"windows.list"}"#))
                _ = try await it.next() // handled in order, after the cancel
                #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
                // Later chunks of the cancelled upload are ignored (no reply, no file).
                try await outbound.write(.binary(SessionUploadTests.frame(
                    #"{"t":"files.put","id":"p1","size":10,"offset":1}"#, Data(count: 9))))
                try await outbound.write(.text(#"{"t":"windows.list"}"#))
                guard case .text(let t)? = try await it.next() else { Issue.record("no reply"); return }
                #expect(t.contains(#""t":"windows""#))
                #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
                try await outbound.close(.normalClosure, reason: nil)
            }
        }
    }
}

private final class StubBackend: SessionBackend, @unchecked Sendable {
    func permissions() -> PermissionsStatus { PermissionsStatus(screenRecording: true, accessibility: true) }
    func listWindows() async throws -> [WindowItem] { [] }
    func startCapture(windowId: UInt32, events: @escaping @Sendable (CaptureEvent) -> Void) async -> CaptureStart { .windowGone }
    func perform(_ action: InputAction) async -> ErrorCode? { nil }
    func focus(windowId: UInt32) async {}
    func releaseButton() async {}
    func thumbnails(windowIds: [UInt32]) async -> [(windowId: UInt32, jpeg: Data?)] { [] }
    func viewingChanged(_ window: WindowItem?) {}
    func fitWindow(windowId: UInt32, aspect: Double) async -> WindowFitOutcome { .failed(.windowNotFound) }
    func restoreWindow(windowId: UInt32) async -> WindowFitOutcome { .failed(.windowNotFound) }
    func windowAfterSwitch(from windowId: UInt32) async -> WindowItem? { nil }
    func makePeer() -> RTCPeer? { nil }
    func setAudio(_ target: AudioTarget?, events: @escaping @Sendable (AudioEvent) -> Void) -> Bool { true }
    func listApps() async -> [AppItem] { [] }
    func appIcon(id: String) async -> Data? { nil }
    func openApp(id: String) async -> AppOpenOutcome { .failed(.appNotFound) }
    func listMenu(windowId: UInt32) async -> MenuListOutcome { .failed(.menuUnavailable) }
}
