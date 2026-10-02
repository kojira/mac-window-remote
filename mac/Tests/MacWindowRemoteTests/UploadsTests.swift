import Foundation
import Testing
@testable import MacWindowRemote

/// D12/D36: image type sniffing, upload assembly and limits, file names, and cleanup.
@Suite struct UploadsTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1])

    static func ftyp(_ brand: String) -> Data {
        Data([0, 0, 0, 24]) + Data("ftyp".utf8) + Data(brand.utf8)
    }

    @Test func sniffsEachAcceptedType() {
        #expect(ImageType.sniff(Self.png) == .png)
        #expect(ImageType.sniff(Self.jpeg) == .jpeg)
        #expect(ImageType.sniff(Data("GIF89a\u{1}\u{0}".utf8)) == .gif)
        #expect(ImageType.sniff(Data("GIF87a\u{1}\u{0}".utf8)) == .gif)
        #expect(ImageType.sniff(Data("RIFF".utf8) + Data([1, 2, 3, 4]) + Data("WEBPVP8 ".utf8)) == .webp)
        #expect(ImageType.sniff(Self.ftyp("heic")) == .heic)
        #expect(ImageType.sniff(Self.ftyp("heix")) == .heic)
        #expect(ImageType.sniff(Self.ftyp("mif1")) == .heif)
        #expect(ImageType.jpeg.fileExtension == "jpg")
        #expect(ImageType.heic.fileExtension == "heic")
    }

    @Test func rejectsOtherBytes() {
        #expect(ImageType.sniff(Data()) == nil)
        #expect(ImageType.sniff(Data("%PDF-1.7\n".utf8)) == nil)
        #expect(ImageType.sniff(Data("hello, world".utf8)) == nil)
        #expect(ImageType.sniff(Data([0x89, 0x50, 0x4E, 0x47])) == nil) // truncated PNG signature
        #expect(ImageType.sniff(Data("RIFF".utf8) + Data([1, 2, 3, 4]) + Data("WAVE".utf8)) == nil)
        #expect(ImageType.sniff(Self.ftyp("mp42")) == nil) // MP4 video
        #expect(ImageType.sniff(Self.ftyp("qt  ")) == nil)
    }

    @Test func assemblesChunksInOrder() {
        var a = ImageUploadAssembler()
        let image = Self.png + Data(repeating: 7, count: 100)
        #expect(a.receive(id: "i1", size: image.count, offset: 0, bytes: image.prefix(50)) == .needMore)
        #expect(a.receive(id: "i1", size: image.count, offset: 50, bytes: image.dropFirst(50)) == .complete(image, .png))
    }

    @Test func rejectsTooLargeAndUnsupportedAndIgnoresTheRest() {
        var a = ImageUploadAssembler()
        let big = ImageUploadAssembler.maxImageBytes + 1
        #expect(a.receive(id: "i1", size: big, offset: 0, bytes: Self.png) == .failed(.tooLarge))
        #expect(a.receive(id: "i1", size: big, offset: Self.png.count, bytes: Data([1])) == .ignored)
        let text = Data("not an image".utf8)
        #expect(a.receive(id: "i2", size: 20, offset: 0, bytes: text) == .failed(.unsupportedType))
        #expect(a.receive(id: "i2", size: 20, offset: text.count, bytes: Data([1])) == .ignored)
        // Exactly 25 MiB is accepted.
        #expect(a.receive(id: "i3", size: ImageUploadAssembler.maxImageBytes, offset: 0, bytes: Self.png) == .needMore)
    }

    @Test func rejectsAGapOrAnotherUpload() {
        var a = ImageUploadAssembler()
        #expect(a.receive(id: "i1", size: 40, offset: 0, bytes: Self.png) == .needMore)
        #expect(a.receive(id: "i1", size: 40, offset: 20, bytes: Data([1])) == .failed(.badRequest))
        #expect(a.receive(id: "i2", size: 40, offset: 12, bytes: Data([1])) == .failed(.badRequest))
        // A new upload replaces an unfinished one.
        #expect(a.receive(id: "i3", size: 40, offset: 0, bytes: Self.png) == .needMore)
        #expect(a.receive(id: "i4", size: 12, offset: 0, bytes: Self.png) == .complete(Self.png, .png))
    }

    @Test func fileNameFormat() {
        let date = Date(timeIntervalSince1970: 1_767_225_600 + 3 * 3600 + 4 * 60 + 5) // 2026-01-01 03:04:05 UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(UploadStore.fileName(date: date, random: 0x0a3f, fileExtension: "png", timeZone: utc)
                == "img-20260101-030405-0a3f.png")
        #expect(UploadStore.fileName(date: date, random: 0, fileExtension: "jpg", timeZone: utc)
                == "img-20260101-030405-0000.jpg")
    }

    func withStore(_ body: (UploadStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mwr-uploads-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UploadStore(directory: root.appendingPathComponent("uploads", isDirectory: true))
        try store.prepareDirectory()
        try body(store, root)
    }

    @Test func savesWithMode0700AndTheImageName() throws {
        try withStore { store, _ in
            let url = try store.save(Self.png, type: .png)
            #expect(url.deletingLastPathComponent().standardizedFileURL == store.directory.standardizedFileURL)
            #expect(url.lastPathComponent.range(of: #"^img-\d{8}-\d{6}-[0-9a-f]{4}\.png$"#, options: .regularExpression) != nil)
            #expect(try Data(contentsOf: url) == Self.png)
            let mode = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
        }
    }

    @Test func cleanupDeletesOnlyOldFilesInTheDirectory() throws {
        try withStore { store, root in
            let fm = FileManager.default
            let now = Date()
            let old = now.addingTimeInterval(-(UploadStore.maxAge + 60))
            func file(_ url: URL, modified: Date) throws {
                try Data([1]).write(to: url)
                try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
            let oldFile = store.directory.appendingPathComponent("img-old.png")
            let newFile = store.directory.appendingPathComponent("img-new.png")
            let outside = root.appendingPathComponent("outside.png")
            let subdir = store.directory.appendingPathComponent("sub", isDirectory: true)
            let inSubdir = subdir.appendingPathComponent("nested.png")
            let link = store.directory.appendingPathComponent("link.png")
            try file(oldFile, modified: old)
            try file(newFile, modified: now.addingTimeInterval(-3600))
            try file(outside, modified: old)
            try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
            try file(inSubdir, modified: old)
            try fm.createSymbolicLink(at: link, withDestinationURL: outside)

            #expect(store.removeExpired(now: now) == 1)
            #expect(!fm.fileExists(atPath: oldFile.path))
            #expect(fm.fileExists(atPath: newFile.path))
            #expect(fm.fileExists(atPath: outside.path))
            #expect(fm.fileExists(atPath: inSubdir.path))
            #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil)
        }
    }

    @Test func sanitizesFileNames() {
        #expect(UploadStore.sanitizedFileName("report.pdf") == "report.pdf")
        #expect(UploadStore.sanitizedFileName("My Report 2026.pdf") == "My Report 2026.pdf")
        #expect(UploadStore.sanitizedFileName("日本語 資料.docx") == "日本語 資料.docx")
        #expect(UploadStore.sanitizedFileName("../../etc/passwd") == "passwd")
        #expect(UploadStore.sanitizedFileName("C:\\dir\\x.txt") == "x.txt")
        #expect(UploadStore.sanitizedFileName("dir/") == "dir")
        #expect(UploadStore.sanitizedFileName(".hidden") == "hidden")
        #expect(UploadStore.sanitizedFileName(" . .env") == "env")
        #expect(UploadStore.sanitizedFileName("a\u{0}b\nc\u{7F}.txt") == "abc.txt")
        for empty in ["", "/", "..", "...", "\n", " "] { #expect(UploadStore.sanitizedFileName(empty) == "file") }
        let long = UploadStore.sanitizedFileName(String(repeating: "あ", count: 100) + ".pdf")
        #expect(long.utf8.count <= UploadStore.maxFileNameBytes)
        #expect(long.hasSuffix(".pdf") && long.hasPrefix("あ"))
    }

    /// D42: each 📎 File is streamed into its own `<UUID>` folder (mode 0700) under its name.
    @Test func streamsFilesIntoAUniqueSubdirectoryWithTheirName() throws {
        try withStore { store, _ in
            func upload(_ id: String, _ name: String, _ bytes: Data) -> URL? {
                var r = FileUploadReceiver()
                let step = r.start(id: id, size: bytes.count, name: name, bytes: bytes) { () throws(UploadFailure) in
                    (try store.makeFileFolder(), ownsFolder: true)
                }
                guard case .complete(let url) = step else { return nil }
                return url
            }
            let a = try #require(upload("f1", "../report.pdf", Data("one".utf8)))
            let b = try #require(upload("f2", "report.pdf", Data("two".utf8)))
            #expect(a.lastPathComponent == "report.pdf" && b.lastPathComponent == "report.pdf")
            #expect(a != b)
            for url in [a, b] {
                let folder = url.deletingLastPathComponent()
                #expect(folder.deletingLastPathComponent().standardizedFileURL == store.directory.standardizedFileURL)
                #expect(UUID(uuidString: folder.lastPathComponent) != nil)
                let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
                #expect(mode == 0o700)
                #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["report.pdf"])
            }
            #expect(try Data(contentsOf: a) == Data("one".utf8))
            #expect(try Data(contentsOf: b) == Data("two".utf8))
        }
    }

    @Test func cleanupDeletesOldFileUploadSubdirectories() throws {
        try withStore { store, _ in
            let fm = FileManager.default
            let now = Date()
            let old = now.addingTimeInterval(-(UploadStore.maxAge + 60))
            func save(_ name: String) throws -> URL {
                let folder = try store.makeFileFolder()
                let url = folder.appendingPathComponent(name)
                try Data([1]).write(to: url)
                return url
            }
            let oldFile = try save("old.pdf")
            let newFile = try save("new.pdf")
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: oldFile.deletingLastPathComponent().path)
            #expect(store.removeExpired(now: now) == 1)
            #expect(!fm.fileExists(atPath: oldFile.deletingLastPathComponent().path))
            #expect(fm.fileExists(atPath: newFile.path))
        }
    }

    @Test func cleanupOfAMissingDirectoryDoesNothing() {
        let store = UploadStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mwr-missing-\(UUID().uuidString)", isDirectory: true))
        #expect(store.removeExpired() == 0)
    }
}

/// D36: binary WebSocket messages (§4.1 framing).
@Suite struct BinaryMessageTests {
    static func frame(_ header: String, _ payload: Data = Data()) -> Data {
        let h = Data(header.utf8)
        let n = UInt32(h.count)
        return Data([UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) + h + payload
    }

    @Test func decodesClipboardPaste() throws {
        let m = try BinaryClientMessage.decode(Self.frame(#"{"t":"clipboard.paste","id":"c1"}"#, Data("こんにちは\nworld".utf8)))
        #expect(m == .clipboardPaste(id: "c1", text: "こんにちは\nworld"))
    }

    @Test func decodesClipboardSetWithTheSameLimits() throws {
        let m = try BinaryClientMessage.decode(Self.frame(#"{"t":"clipboard.set","id":"s1"}"#, Data("行1\n行2".utf8)))
        #expect(m == .clipboardSet(id: "s1", text: "行1\n行2"))
        let max = Data(repeating: 0x61, count: BinaryClientMessage.maxClipboardBytes)
        #expect(try BinaryClientMessage.decode(Self.frame(#"{"t":"clipboard.set","id":"s2"}"#, max))
                == .clipboardSet(id: "s2", text: String(repeating: "a", count: BinaryClientMessage.maxClipboardBytes)))
        #expect(throws: UploadRejection(id: "s3", code: .tooLarge)) {
            try BinaryClientMessage.decode(Self.frame(#"{"t":"clipboard.set","id":"s3"}"#, max + Data([0x61])))
        }
        #expect(throws: ProtocolError.invalidValue("text")) {
            try BinaryClientMessage.decode(Self.frame(#"{"t":"clipboard.set","id":"s4"}"#))
        }
    }

    @Test func clipboardIsAtMostOneMiB() throws {
        let max = Data(repeating: 0x61, count: BinaryClientMessage.maxClipboardBytes)
        #expect(try BinaryClientMessage.decode(Self.frame(#"{"t":"clipboard.paste","id":"c1"}"#, max))
                == .clipboardPaste(id: "c1", text: String(repeating: "a", count: BinaryClientMessage.maxClipboardBytes)))
        #expect(throws: UploadRejection(id: "c2", code: .tooLarge)) {
            try BinaryClientMessage.decode(Self.frame(#"{"t":"clipboard.paste","id":"c2"}"#, max + Data([0x61])))
        }
        #expect(throws: ProtocolError.invalidValue("text")) {
            try BinaryClientMessage.decode(Self.frame(#"{"t":"clipboard.paste","id":"c3"}"#))
        }
        #expect(throws: ProtocolError.invalidValue("text")) {
            try BinaryClientMessage.decode(Self.frame(#"{"t":"clipboard.paste","id":"c4"}"#, Data([0xFF, 0xFE])))
        }
    }

    @Test func decodesFileChunkWithItsNameOnTheFirstChunk() throws {
        let first = try BinaryClientMessage.decode(Self.frame(#"{"t":"file.chunk","id":"f1","size":10,"offset":0,"name":"a b.pdf"}"#, Data([1])))
        #expect(first == .fileChunk(id: "f1", size: 10, offset: 0, bytes: Data([1]), name: "a b.pdf"))
        let later = try BinaryClientMessage.decode(Self.frame(#"{"t":"file.chunk","id":"f1","size":10,"offset":1,"name":"x"}"#, Data([2])))
        #expect(later == .fileChunk(id: "f1", size: 10, offset: 1, bytes: Data([2]), name: ""))
        #expect(throws: ProtocolError.invalidValue("chunk")) {
            try BinaryClientMessage.decode(Self.frame(#"{"t":"file.chunk","id":"f","size":1,"offset":0}"#, Data([1, 2])))
        }
    }

    @Test func decodesImageChunk() throws {
        let m = try BinaryClientMessage.decode(Self.frame(#"{"t":"image.chunk","id":"i1","size":10,"offset":4}"#, Data([1, 2, 3])))
        #expect(m == .imageChunk(id: "i1", size: 10, offset: 4, bytes: Data([1, 2, 3])))
    }

    @Test func rejectsInvalidImageChunks() {
        func decode(_ header: String, _ payload: Data = Data([1])) throws -> BinaryClientMessage {
            try BinaryClientMessage.decode(Self.frame(header, payload))
        }
        #expect(throws: ProtocolError.invalidValue("size")) { try decode(#"{"t":"image.chunk","id":"i","offset":0}"#) }
        #expect(throws: ProtocolError.invalidValue("size")) { try decode(#"{"t":"image.chunk","id":"i","size":0,"offset":0}"#) }
        #expect(throws: ProtocolError.invalidValue("offset")) { try decode(#"{"t":"image.chunk","id":"i","size":5,"offset":-1}"#) }
        #expect(throws: ProtocolError.invalidValue("chunk")) { try decode(#"{"t":"image.chunk","id":"i","size":5,"offset":5}"#) }
        #expect(throws: ProtocolError.invalidValue("chunk")) { try decode(#"{"t":"image.chunk","id":"i","size":5,"offset":0}"#, Data()) }
        #expect(throws: ProtocolError.invalidValue("chunk")) {
            try decode(#"{"t":"image.chunk","id":"i","size":999999999,"offset":0}"#,
                       Data(count: BinaryClientMessage.maxChunkBytes + 1))
        }
    }

    @Test func rejectsBadFraming() {
        #expect(throws: ProtocolError.malformed) { try BinaryClientMessage.decode(Data([0, 0])) }
        #expect(throws: ProtocolError.malformed) { try BinaryClientMessage.decode(Data([0, 0, 0, 0])) }
        #expect(throws: ProtocolError.malformed) { try BinaryClientMessage.decode(Data([0, 0, 0, 50]) + Data("{}".utf8)) }
        #expect(throws: ProtocolError.malformed) { try BinaryClientMessage.decode(Data([0, 1, 0, 0]) + Data(count: 70000)) }
        #expect(throws: ProtocolError.malformed) { try BinaryClientMessage.decode(Self.frame("not json")) }
        #expect(throws: ProtocolError.invalidValue("id")) { try BinaryClientMessage.decode(Self.frame(#"{"t":"clipboard.paste"}"#, Data([0x61]))) }
        #expect(throws: ProtocolError.unknownType("image")) { try BinaryClientMessage.decode(Self.frame(#"{"t":"image","id":"i"}"#, Data([1]))) }
    }

    @Test func encodesResult() {
        #expect(ServerMessage.result(id: "i1", path: "/var/folders/xx/T/mac-window-remote/uploads/img-20260101-030405-0a3f.png").jsonString()
                .contains(#""path":"\/var\/folders\/xx\/T\/mac-window-remote\/uploads\/img-20260101-030405-0a3f.png""#))
        #expect(ServerMessage.result(id: "c1", path: nil).jsonString().contains(#""t":"result""#))
    }
}
