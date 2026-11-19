import Darwin
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import HummingbirdWebSocket
import WSClient
import Testing
@testable import MacWindowRemote

/// D62: creating, reading, and saving text files for the Files sheet's editor. Everything runs
/// in a fresh temporary folder.
@Suite struct FileEditTests {
    final class Tree {
        let root: String
        init() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("mwr-edit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            root = FileBrowser.realPath(url.path)
        }
        deinit {
            chmod(root, 0o700)
            try? FileManager.default.removeItem(atPath: root)
        }

        func path(_ name: String) -> String { root + "/" + name }

        func file(_ name: String, _ bytes: [UInt8]) throws {
            try Data(bytes).write(to: URL(fileURLWithPath: path(name)))
        }

        func file(_ name: String, _ text: String) throws { try file(name, Array(text.utf8)) }

        func bytes(_ name: String) -> [UInt8]? {
            (try? Data(contentsOf: URL(fileURLWithPath: path(name)))).map { [UInt8]($0) }
        }

        func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root).sorted() }

        func mode(_ name: String) -> mode_t {
            var st = stat()
            stat(path(name), &st)
            return st.st_mode & 0o7777
        }
    }

    private func failure<T>(_ body: () throws(FileEdit.Failure) -> T) -> ErrorCode? {
        do { _ = try body(); return nil } catch { return error.code }
    }

    private func save(_ t: Tree, _ name: String, _ text: String, force: Bool = false, maxBytes: Int = FileEdit.maxTextBytes)
        throws(FileEdit.Failure) -> FileEdit.Saved {
        let read = try FileEdit.read(path: t.path(name))
        return try FileEdit.write(path: t.path(name), text: text, baseMtime: read.mtime, baseSize: read.size,
                                  eol: read.eol, force: force, maxBytes: maxBytes)
    }

    // MARK: create

    @Test func createMakesAnEmptyFile() throws {
        let t = try Tree()
        #expect(try FileEdit.create(dir: t.root, name: "untitled.txt") == t.path("untitled.txt"))
        #expect(t.bytes("untitled.txt") == [])
        #expect(t.mode("untitled.txt") & 0o600 == 0o600)
    }

    @Test func createNeverOverwrites() throws {
        let t = try Tree()
        try t.file("a.txt", "keep")
        #expect(failure { () throws(FileEdit.Failure) in try FileEdit.create(dir: t.root, name: "a.txt") } == .exists)
        #expect(t.bytes("a.txt") == Array("keep".utf8))
        symlink(t.path("missing"), t.path("dangling"))
        #expect(failure { () throws(FileEdit.Failure) in try FileEdit.create(dir: t.root, name: "dangling") } == .exists)
        #expect(!FileManager.default.fileExists(atPath: t.path("missing")))
    }

    @Test func createRefusesInvalidNamesAndBadFolders() throws {
        let t = try Tree()
        for bad in ["", ".", "..", "a/b", "x\0y", String(repeating: "a", count: 256)] {
            #expect(failure { () throws(FileEdit.Failure) in try FileEdit.create(dir: t.root, name: bad) } == .invalidName)
        }
        #expect(failure { () throws(FileEdit.Failure) in try FileEdit.create(dir: "rel", name: "a") } == .badRequest)
        #expect(failure { () throws(FileEdit.Failure) in try FileEdit.create(dir: t.path("nope"), name: "a") } == .notFound)
        chmod(t.root, 0o555)
        #expect(failure { () throws(FileEdit.Failure) in try FileEdit.create(dir: t.root, name: "a") } == .notWritable)
    }

    @Test func createAllowsADotfile() throws {
        let t = try Tree()
        #expect(try FileEdit.create(dir: t.root, name: ".env") == t.path(".env"))
    }

    // MARK: read

    @Test func readReturnsTextAndItsBase() throws {
        let t = try Tree()
        try t.file("a.txt", "héllo\nworld\n")
        let c = try FileEdit.read(path: t.path("a.txt"))
        #expect(c.text == "héllo\nworld\n")
        #expect(c.size == 13)
        #expect(c.eol == .lf)
        var st = stat()
        stat(t.path("a.txt"), &st)
        #expect(c.mtime == FileEdit.millis(st))
        #expect(try FileEdit.read(path: t.path("a.txt")).text == c.text)
    }

    @Test func readAnEmptyFile() throws {
        let t = try Tree()
        try t.file("e.txt", [])
        let c = try FileEdit.read(path: t.path("e.txt"))
        #expect(c.text == "" && c.size == 0 && c.eol == .lf)
    }

    @Test func readRefusesTooLarge() throws {
        let t = try Tree()
        try t.file("a.txt", String(repeating: "x", count: 101))
        #expect(failure { () throws(FileEdit.Failure) in try FileEdit.read(path: t.path("a.txt"), maxBytes: 100) } == .tooLarge)
        #expect(try FileEdit.read(path: t.path("a.txt"), maxBytes: 101).size == 101)
    }

    @Test func readRefusesBinaryAndInvalidUTF8() throws {
        let t = try Tree()
        try t.file("nul.txt", [0x61, 0x00, 0x62])
        try t.file("latin1.txt", [0x63, 0x61, 0x66, 0xE9])
        try t.file("cut.txt", [0xE3, 0x81])
        for name in ["nul.txt", "latin1.txt", "cut.txt"] {
            #expect(failure { () throws(FileEdit.Failure) in try FileEdit.read(path: t.path(name)) } == .notText, "\(name)")
        }
    }

    @Test func readRefusesNonRegularFilesAndMissing() throws {
        let t = try Tree()
        try FileManager.default.createDirectory(atPath: t.path("dir"), withIntermediateDirectories: false)
        #expect(failure { () throws(FileEdit.Failure) in try FileEdit.read(path: t.path("dir")) } == .notText)
        mkfifo(t.path("fifo"), 0o600)
        #expect(failure { () throws(FileEdit.Failure) in try FileEdit.read(path: t.path("fifo")) } == .notText)
        #expect(failure { () throws(FileEdit.Failure) in try FileEdit.read(path: t.path("gone")) } == .notFound)
        #expect(failure { () throws(FileEdit.Failure) in try FileEdit.read(path: "rel") } == .badRequest)
    }

    @Test func readFollowsASymlinkToAFile() throws {
        let t = try Tree()
        try t.file("real.txt", "via link")
        symlink(t.path("real.txt"), t.path("link.txt"))
        #expect(try FileEdit.read(path: t.path("link.txt")).text == "via link")
    }

    @Test func readStripsTheBOMAndDetectsCRLF() throws {
        let t = try Tree()
        try t.file("bom.txt", FileEdit.bom + Array("a\r\nb\r\nc\n".utf8))
        let c = try FileEdit.read(path: t.path("bom.txt"))
        #expect(c.text == "a\nb\nc\n")
        #expect(c.eol == .crlf, "two CRLF, one LF: mostly CRLF")
        try t.file("mixed.txt", "a\r\nb\nc\n")
        #expect(try FileEdit.read(path: t.path("mixed.txt")).eol == .lf, "mostly LF")
        try t.file("tie.txt", "a\r\nb\n")
        #expect(try FileEdit.read(path: t.path("tie.txt")).eol == .lf, "a tie is LF")
    }

    // MARK: write

    @Test func writeReplacesAtomicallyAndReturnsTheNewBase() throws {
        let t = try Tree()
        try t.file("a.txt", "old")
        let saved = try save(t, "a.txt", "new text\n")
        #expect(t.bytes("a.txt") == Array("new text\n".utf8))
        #expect(saved.size == 9)
        let again = try FileEdit.read(path: t.path("a.txt"))
        #expect(again.mtime == saved.mtime && again.size == saved.size)
        #expect(try t.names() == ["a.txt"], "no temporary file is left")
        // The returned base allows the next save without a conflict.
        _ = try FileEdit.write(path: t.path("a.txt"), text: "third", baseMtime: saved.mtime, baseSize: saved.size,
                               eol: .lf, force: false)
        #expect(t.bytes("a.txt") == Array("third".utf8))
    }

    @Test func writeKeepsTheModeAndExtendedAttributes() throws {
        let t = try Tree()
        try t.file("run.sh", "#!/bin/sh\n")
        chmod(t.path("run.sh"), 0o750)
        let value = Array("tag".utf8)
        setxattr(t.path("run.sh"), "com.example.mwr", value, value.count, 0, 0)
        _ = try save(t, "run.sh", "#!/bin/sh\necho hi\n")
        #expect(t.mode("run.sh") == 0o750)
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = getxattr(t.path("run.sh"), "com.example.mwr", &buffer, buffer.count, 0, 0)
        #expect(n == 3 && Array(buffer[0..<3]) == value)
    }

    @Test func writeDetectsAConflictAndForceOverwrites() throws {
        let t = try Tree()
        try t.file("a.txt", "one")
        let read = try FileEdit.read(path: t.path("a.txt"))
        try t.file("a.txt", "changed on the Mac")
        #expect(failure { () throws(FileEdit.Failure) in
            try FileEdit.write(path: t.path("a.txt"), text: "mine", baseMtime: read.mtime, baseSize: read.size, eol: .lf, force: false)
        } == .conflict)
        #expect(t.bytes("a.txt") == Array("changed on the Mac".utf8))
        // Same size, another time.
        try t.file("b.txt", "abc")
        let b = try FileEdit.read(path: t.path("b.txt"))
        #expect(failure { () throws(FileEdit.Failure) in
            try FileEdit.write(path: t.path("b.txt"), text: "x", baseMtime: b.mtime - 1, baseSize: b.size, eol: .lf, force: false)
        } == .conflict)
        _ = try FileEdit.write(path: t.path("a.txt"), text: "mine", baseMtime: read.mtime, baseSize: read.size, eol: .lf, force: true)
        #expect(t.bytes("a.txt") == Array("mine".utf8))
    }

    @Test func writeRoundTripsCRLFAndTheBOM() throws {
        let t = try Tree()
        try t.file("w.txt", FileEdit.bom + Array("a\r\nb\r\n".utf8))
        _ = try save(t, "w.txt", "a\nb\nc\n")
        #expect(t.bytes("w.txt") == FileEdit.bom + Array("a\r\nb\r\nc\r\n".utf8))
        try t.file("u.txt", "x\ny\n")
        _ = try save(t, "u.txt", "x\ny\nz")
        #expect(t.bytes("u.txt") == Array("x\ny\nz".utf8), "LF stays LF, no BOM added")
    }

    @Test func writeIsCapped() throws {
        let t = try Tree()
        try t.file("a.txt", "small")
        #expect(failure { () throws(FileEdit.Failure) in try save(t, "a.txt", String(repeating: "y", count: 11), maxBytes: 10) } == .tooLarge)
        #expect(t.bytes("a.txt") == Array("small".utf8))
        #expect(try t.names() == ["a.txt"])
        // CRLF counts: 5 lines of "a\n" are 10 bytes, 15 with CRLF.
        try t.file("c.txt", "a\r\n")
        #expect(failure { () throws(FileEdit.Failure) in try save(t, "c.txt", "a\na\na\na\na\n", maxBytes: 12) } == .tooLarge)
    }

    @Test func writeErrors() throws {
        let t = try Tree()
        #expect(failure { () throws(FileEdit.Failure) in
            try FileEdit.write(path: t.path("gone.txt"), text: "", baseMtime: 0, baseSize: 0, eol: .lf, force: true)
        } == .notFound)
        try FileManager.default.createDirectory(atPath: t.path("dir"), withIntermediateDirectories: false)
        #expect(failure { () throws(FileEdit.Failure) in
            try FileEdit.write(path: t.path("dir"), text: "", baseMtime: 0, baseSize: 0, eol: .lf, force: true)
        } == .notText)
        try t.file("ro.txt", "x")
        chmod(t.path("ro.txt"), 0o444)
        #expect(failure { () throws(FileEdit.Failure) in try save(t, "ro.txt", "y") } == .notWritable)
        #expect(t.bytes("ro.txt") == Array("x".utf8))
        try t.file("in-ro-dir.txt", "x")
        chmod(t.root, 0o555)
        #expect(failure { () throws(FileEdit.Failure) in try save(t, "in-ro-dir.txt", "y") } == .notWritable)
        chmod(t.root, 0o700)
        #expect(try t.names() == ["dir", "in-ro-dir.txt", "ro.txt"])
    }

    @Test func writeThroughASymlinkReplacesTheTargetAndKeepsTheLink() throws {
        let t = try Tree()
        try t.file("real.txt", "a")
        symlink(t.path("real.txt"), t.path("link.txt"))
        let read = try FileEdit.read(path: t.path("link.txt"))
        _ = try FileEdit.write(path: t.path("link.txt"), text: "b", baseMtime: read.mtime, baseSize: read.size, eol: .lf, force: false)
        #expect(t.bytes("real.txt") == Array("b".utf8))
        var st = stat()
        lstat(t.path("link.txt"), &st)
        #expect(st.st_mode & S_IFMT == S_IFLNK)
    }

    @Test func errnoMapping() {
        #expect(FileEdit.code(forErrno: EACCES) == .notWritable)
        #expect(FileEdit.code(forErrno: EROFS) == .notWritable)
        #expect(FileEdit.code(forErrno: ENOENT) == .notFound)
        #expect(FileEdit.code(forErrno: EEXIST) == .exists)
        #expect(FileEdit.code(forErrno: ENOSPC) == .diskFull)
        #expect(FileEdit.code(forErrno: EIO) == .failed)
    }

    // MARK: protocol

    @Test func createAndReadDecodeAndRepliesEncode() throws {
        #expect(try ClientMessage.decode(Data(#"{"t":"files.create","id":"c1","dir":"/a","name":"untitled.txt"}"#.utf8), on: .socket)
            == .filesCreate(id: "c1", dir: "/a", name: "untitled.txt"))
        #expect(throws: ProtocolError.invalidValue("dir")) {
            try ClientMessage.decode(Data(#"{"t":"files.create","id":"c1","dir":"a","name":"x"}"#.utf8))
        }
        #expect(throws: ProtocolError.invalidValue("name")) {
            try ClientMessage.decode(Data(#"{"t":"files.create","id":"c1","dir":"/a"}"#.utf8))
        }
        #expect(try ClientMessage.decode(Data(#"{"t":"files.read","id":"r1","path":"/a/b.txt"}"#.utf8), on: .socket)
            == .filesRead(id: "r1", path: "/a/b.txt"))
        #expect(throws: ProtocolError.wrongChannel("files.read")) {
            try ClientMessage.decode(Data(#"{"t":"files.read","id":"r1","path":"/a"}"#.utf8), on: .control)
        }

        let created = try object(ServerMessage.filesCreateResult(id: "c1", path: "/a/untitled.txt").jsonString())
        #expect(created as? [String: String] == ["t": "files.create.result", "id": "c1", "path": "/a/untitled.txt"])

        let mtime = 1_700_000_000_123.456_789
        let read = try object(ServerMessage.filesReadResult(id: "r1", path: "/a/b.txt", contents: .init(
            text: "a\n\"b\"", mtime: mtime, size: 7, eol: .crlf)).jsonString())
        #expect(read["t"] as? String == "files.read.result")
        #expect(read["text"] as? String == "a\n\"b\"")
        #expect(read["mtime"] as? Double == mtime, "the base mtime round-trips exactly")
        #expect(read["size"] as? Int == 7 && read["eol"] as? String == "crlf" && read["path"] as? String == "/a/b.txt")

        let written = try object(ServerMessage.filesWriteResult(id: "w1", path: "/a/b.txt", saved: .init(mtime: 5.5, size: 3)).jsonString())
        #expect(written["t"] as? String == "files.write.result" && written["mtime"] as? Double == 5.5 && written["size"] as? Int == 3)
        #expect(ErrorCode.notText.rawValue == "not_text" && ErrorCode.conflict.rawValue == "conflict")
    }

    @Test func writeDecodesFromABinaryMessage() throws {
        let mtime = 1_700_000_000_123.456_789
        let header = #"{"t":"files.write","id":"w1","path":"/a/b.txt","baseMtime":1700000000123.456789,"baseSize":4,"eol":"crlf","force":true}"#
        let msg = try BinaryClientMessage.decode(frame(header, Array("hé\n".utf8)))
        #expect(msg == .filesWrite(FileWriteRequest(id: "w1", path: "/a/b.txt", text: "hé\n", baseMtime: mtime, baseSize: 4,
                                                    eol: .crlf, force: true)))
        // An empty text saves an empty file; eol and force default.
        let empty = try BinaryClientMessage.decode(frame(#"{"t":"files.write","id":"w2","path":"/a","baseMtime":0,"baseSize":0}"#, []))
        #expect(empty == .filesWrite(FileWriteRequest(id: "w2", path: "/a", text: "", baseMtime: 0, baseSize: 0, eol: .lf, force: false)))
        #expect(throws: UploadRejection(id: "w3", code: .tooLarge)) {
            try BinaryClientMessage.decode(frame(#"{"t":"files.write","id":"w3","path":"/a","baseMtime":0,"baseSize":0}"#,
                                                 [UInt8](repeating: 0x61, count: FileEdit.maxTextBytes + 1)))
        }
        #expect(throws: ProtocolError.invalidValue("text")) {
            try BinaryClientMessage.decode(frame(#"{"t":"files.write","id":"w4","path":"/a","baseMtime":0,"baseSize":0}"#, [0xFF]))
        }
        #expect(throws: ProtocolError.invalidValue("path")) {
            try BinaryClientMessage.decode(frame(#"{"t":"files.write","id":"w5","path":"a","baseMtime":0,"baseSize":0}"#, []))
        }
        #expect(throws: ProtocolError.invalidValue("baseMtime")) {
            try BinaryClientMessage.decode(frame(#"{"t":"files.write","id":"w6","path":"/a","baseSize":0}"#, []))
        }
        #expect(throws: ProtocolError.invalidValue("eol")) {
            try BinaryClientMessage.decode(frame(#"{"t":"files.write","id":"w7","path":"/a","baseMtime":0,"baseSize":0,"eol":"cr"}"#, []))
        }
        // The largest save fits the WebSocket frame limit.
        #expect(4 + BinaryClientMessage.maxHeaderBytes + FileEdit.maxTextBytes <= Server.maxMessageSize)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func frame(_ header: String, _ payload: [UInt8]) -> Data {
        let h = Array(header.utf8)
        let n = UInt32(h.count)
        return Data([UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + h + payload)
    }
}

/// D62 through the real server: create, read, then save 1 MiB of text in one binary frame.
@Suite(.serialized) struct SessionFileEditTests {
    static let owner = "owner@example.com"

    @Test func createReadAndWriteOverTheSocket() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwr-edit-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = FileBrowser.realPath(root.path)
        let hub = SessionHub(owner: OwnerLogin(override: { "" }, query: { Self.owner }), backend: StubBackend(),
                             uploads: UploadStore(directory: root.appendingPathComponent("unused")))
        let app = Server.makeApplication(port: 0, webRoot: nil, hub: hub)
        try await app.test(.live) { client in
            var fields = HTTPFields()
            fields[HTTPField.Name(TailscaleIdentity.loginHeader)!] = Self.owner
            try await client.ws("/ws", configuration: WebSocketClientConfiguration(additionalHeaders: fields)) { inbound, outbound, _ in
                var it = inbound.messages(maxSize: 4 << 20).makeAsyncIterator()
                func next() async throws -> [String: Any] {
                    guard case .text(let t)? = try await it.next() else { return [:] }
                    return try #require(try JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any])
                }
                _ = try await next() // hello
                try await outbound.write(.text(#"{"t":"files.create","id":"c1","dir":"\#(dir)","name":"untitled.txt"}"#))
                let created = try await next()
                #expect(created["t"] as? String == "files.create.result" && created["path"] as? String == dir + "/untitled.txt")
                try await outbound.write(.text(#"{"t":"files.create","id":"c2","dir":"\#(dir)","name":"untitled.txt"}"#))
                let exists = try await next()
                #expect(exists["code"] as? String == "exists" && exists["id"] as? String == "c2")

                try await outbound.write(.text(#"{"t":"files.read","id":"r1","path":"\#(dir)/untitled.txt"}"#))
                let read = try await next()
                #expect(read["t"] as? String == "files.read.result" && read["text"] as? String == "" && read["eol"] as? String == "lf")
                let mtime = try #require(read["mtime"] as? Double)

                // 1 MiB of short lines: JSON-escaped it would not fit the frame; binary does.
                let text = String(repeating: "\"a\"\n", count: FileEdit.maxTextBytes / 4)
                let header = #"{"t":"files.write","id":"w1","path":"\#(dir)/untitled.txt","baseMtime":\#(mtime),"baseSize":0,"eol":"lf"}"#
                try await outbound.write(.binary(SessionUploadTests.frame(header, Data(text.utf8))))
                let saved = try await next()
                #expect(saved["t"] as? String == "files.write.result" && saved["size"] as? Int == FileEdit.maxTextBytes)
                #expect(try Data(contentsOf: URL(fileURLWithPath: dir + "/untitled.txt")) == Data(text.utf8))

                // The old base is now a conflict.
                try await outbound.write(.binary(SessionUploadTests.frame(header.replacingOccurrences(of: "w1", with: "w2"), Data("x".utf8))))
                let conflict = try await next()
                #expect(conflict["code"] as? String == "conflict" && conflict["id"] as? String == "w2")
                try await outbound.close(.normalClosure, reason: nil)
            }
        }
    }
}
