import Darwin
import Foundation
import Testing
@testable import MacWindowRemote

/// D61: renaming one file or folder in place. Everything runs in a fresh temporary folder.
@Suite struct FileRenameTests {
    final class Tree {
        let root: String
        init() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("mwr-rename-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            root = FileBrowser.realPath(url.path)
        }
        deinit {
            chmod(root, 0o700)
            try? FileManager.default.removeItem(atPath: root)
        }

        func path(_ name: String) -> String { root + "/" + name }

        func file(_ name: String, _ contents: String = "x") throws {
            try Data(contents.utf8).write(to: URL(fileURLWithPath: path(name)))
        }

        func read(_ name: String) -> String? {
            (try? Data(contentsOf: URL(fileURLWithPath: path(name)))).map { String(decoding: $0, as: UTF8.self) }
        }

        /// The names in the folder as stored (case preserved).
        func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root).sorted() }
    }

    private func failure(_ body: () throws(FileRename.Failure) -> String) -> ErrorCode? {
        do { _ = try body(); return nil } catch { return error.code }
    }

    @Test func renamesAFileInPlace() throws {
        let t = try Tree()
        try t.file("a.txt", "hello")
        let newPath = try FileRename.rename(path: t.path("a.txt"), to: "b.md")
        #expect(newPath == t.path("b.md"))
        #expect(try t.names() == ["b.md"])
        #expect(t.read("b.md") == "hello")
    }

    @Test func renamesAFolderWithItsContents() throws {
        let t = try Tree()
        try FileManager.default.createDirectory(atPath: t.path("Old"), withIntermediateDirectories: false)
        try t.file("Old/inner.txt", "in")
        #expect(try FileRename.rename(path: t.path("Old"), to: "New") == t.path("New"))
        #expect(try t.names() == ["New"])
        #expect(t.read("New/inner.txt") == "in")
    }

    @Test func anExistingNameIsNeverOverwritten() throws {
        let t = try Tree()
        try t.file("a.txt", "A")
        try t.file("b.txt", "B")
        #expect(failure { () throws(FileRename.Failure) in try FileRename.rename(path: t.path("a.txt"), to: "b.txt") } == .exists)
        #expect(t.read("a.txt") == "A")
        #expect(t.read("b.txt") == "B")
        // An existing folder is not replaced either.
        try FileManager.default.createDirectory(atPath: t.path("D"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: t.path("E"), withIntermediateDirectories: false)
        #expect(failure { () throws(FileRename.Failure) in try FileRename.rename(path: t.path("D"), to: "E") } == .exists)
        #expect(try t.names() == ["D", "E", "a.txt", "b.txt"])
    }

    @Test func aCaseOnlyRenameWorks() throws {
        let t = try Tree()
        try t.file("a.txt", "same")
        #expect(try FileRename.rename(path: t.path("a.txt"), to: "A.txt") == t.path("A.txt"))
        #expect(try t.names() == ["A.txt"])
        #expect(t.read("A.txt") == "same")
    }

    @Test func aCaseOnlyNameOfAnotherItemIsStillExists() throws {
        let t = try Tree()
        try t.file("a.txt", "A")
        try t.file("b.txt", "B")
        // A hard link shares the inode but is not a case variant: no replace.
        #expect(link(t.path("a.txt"), t.path("c.txt")) == 0)
        #expect(failure { () throws(FileRename.Failure) in try FileRename.rename(path: t.path("a.txt"), to: "c.txt") } == .exists)
        #expect(failure { () throws(FileRename.Failure) in try FileRename.rename(path: t.path("a.txt"), to: "B.txt") } == .exists)
        #expect(t.read("b.txt") == "B")
    }

    @Test func invalidNamesAreRefused() throws {
        let t = try Tree()
        try t.file("a.txt")
        for name in ["", ".", "..", "x/y", "/", "a\0b", String(repeating: "あ", count: 86)] {
            #expect(failure { () throws(FileRename.Failure) in try FileRename.rename(path: t.path("a.txt"), to: name) } == .invalidName, "\(name)")
        }
        #expect(try t.names() == ["a.txt"])
        #expect(FileRename.isValidName(String(repeating: "x", count: 255)))
        #expect(!FileRename.isValidName(String(repeating: "x", count: 256)))
        // A leading dot is kept: renaming to a dotfile is allowed.
        #expect(try FileRename.rename(path: t.path("a.txt"), to: ".hidden") == t.path(".hidden"))
        #expect(try t.names() == [".hidden"])
    }

    @Test func aMissingSourceIsNotFoundAndARelativePathIsABadRequest() throws {
        let t = try Tree()
        #expect(failure { () throws(FileRename.Failure) in try FileRename.rename(path: t.path("gone.txt"), to: "x.txt") } == .notFound)
        #expect(failure { () throws(FileRename.Failure) in try FileRename.rename(path: "rel/a.txt", to: "x.txt") } == .badRequest)
        #expect(failure { () throws(FileRename.Failure) in try FileRename.rename(path: "/", to: "x") } == .badRequest)
    }

    @Test func aSymlinkItselfIsRenamedNotItsTarget() throws {
        let t = try Tree()
        try t.file("target.txt", "T")
        try FileManager.default.createSymbolicLink(atPath: t.path("link"), withDestinationPath: "target.txt")
        #expect(try FileRename.rename(path: t.path("link"), to: "link2") == t.path("link2"))
        #expect(try t.names() == ["link2", "target.txt"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: t.path("link2")) == "target.txt")
        // A broken link (lstat finds it) is renamed too.
        try FileManager.default.removeItem(atPath: t.path("target.txt"))
        #expect(try FileRename.rename(path: t.path("link2"), to: "link3") == t.path("link3"))
    }

    @Test func aReadOnlyFolderIsNotWritable() throws {
        let t = try Tree()
        try t.file("a.txt", "A")
        chmod(t.root, 0o555)
        defer { chmod(t.root, 0o700) }
        #expect(failure { () throws(FileRename.Failure) in try FileRename.rename(path: t.path("a.txt"), to: "b.txt") } == .notWritable)
        #expect(t.read("a.txt") == "A")
    }

    @Test func errnoMapping() {
        #expect(FileRename.code(forErrno: EACCES) == .notWritable)
        #expect(FileRename.code(forErrno: EPERM) == .notWritable)
        #expect(FileRename.code(forErrno: EROFS) == .notWritable)
        #expect(FileRename.code(forErrno: ENOENT) == .notFound)
        #expect(FileRename.code(forErrno: EEXIST) == .exists)
        #expect(FileRename.code(forErrno: ENOTEMPTY) == .exists)
        #expect(FileRename.code(forErrno: EXDEV) == .failed)
        #expect(FileRename.code(forErrno: EIO) == .failed)
    }

    @Test func wire() throws {
        let msg = try ClientMessage.decode(Data(#"{"t":"files.rename","id":"r1","path":"/a/b.txt","name":"c.txt"}"#.utf8), on: .socket)
        #expect(msg == .filesRename(id: "r1", path: "/a/b.txt", name: "c.txt"))
        #expect(throws: ProtocolError.invalidValue("path")) {
            try ClientMessage.decode(Data(#"{"t":"files.rename","id":"r1","path":"a","name":"c"}"#.utf8))
        }
        #expect(throws: ProtocolError.invalidValue("name")) {
            try ClientMessage.decode(Data(#"{"t":"files.rename","id":"r1","path":"/a"}"#.utf8))
        }
        #expect(throws: ProtocolError.wrongChannel("files.rename")) {
            try ClientMessage.decode(Data(#"{"t":"files.rename","id":"r1","path":"/a","name":"c"}"#.utf8), on: .control)
        }
        let json = ServerMessage.filesRenameResult(id: "r1", path: "/a/b", newPath: "/a/c").jsonString()
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(obj == ["t": "files.rename.result", "id": "r1", "path": "/a/b", "newPath": "/a/c"])
        #expect(ErrorCode.exists.rawValue == "exists" && ErrorCode.invalidName.rawValue == "invalid_name")
    }
}
