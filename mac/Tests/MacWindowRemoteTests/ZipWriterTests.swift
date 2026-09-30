import Foundation
import Testing
@testable import MacWindowRemote

/// D47: the streaming zip writer. Archives are written to a temporary folder and checked with
/// /usr/bin/unzip.
@Suite struct ZipWriterTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mwr-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    static func unzip(_ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Writes the plan's sources as a zip into `dir/out.zip` and returns its bytes.
    static func write(_ sources: [ZipSource], to dir: URL, threshold: UInt64 = ZipMath.limit32,
                      entryThreshold: Int = ZipMath.limit16) async throws -> URL {
        var out = Data()
        let zip = ZipStreamWriter(threshold: threshold, entryThreshold: entryThreshold) { out.append($0) }
        for s in sources { try await zip.add(s) }
        try await zip.finish()
        let url = dir.appendingPathComponent("out.zip")
        try out.write(to: url)
        return url
    }

    static func plannedSources(_ dir: URL) throws -> [ZipSource] {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("Folder/sub"), withIntermediateDirectories: true)
        let text = String(repeating: "compress me please ", count: 5000)
        try Data(text.utf8).write(to: dir.appendingPathComponent("Folder/notes.txt"))
        try Data((0..<70000).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) }).write(to: dir.appendingPathComponent("Folder/sub/photo.jpg"))
        try Data("日本語".utf8).write(to: dir.appendingPathComponent("Folder/sub/名前.txt"))
        try Data().write(to: dir.appendingPathComponent("Folder/empty.txt"))
        guard case .zip(_, let sources, _) = try DownloadPlanner.plan(paths: [dir.appendingPathComponent("Folder").path], home: "/h") else {
            throw CocoaError(.featureUnsupported)
        }
        return sources
    }

    @Test func roundTripsThroughUnzip() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sources = try Self.plannedSources(dir)
        let zip = try await Self.write(sources, to: dir)
        let test = try Self.unzip(["-t", zip.path])
        #expect(test.status == 0, "\(test.output)")
        let listing = try Self.unzip(["-Z", "-v", zip.path])
        // Text is deflated, the JPEG and folders stored.
        #expect(listing.output.contains("Folder/notes.txt"))
        let extracted = dir.appendingPathComponent("x")
        let x = try Self.unzip(["-q", zip.path, "-d", extracted.path])
        #expect(x.status == 0, "\(x.output)")
        for relative in ["Folder/notes.txt", "Folder/sub/photo.jpg", "Folder/sub/名前.txt", "Folder/empty.txt"] {
            let a = try Data(contentsOf: dir.appendingPathComponent(relative))
            let b = try Data(contentsOf: extracted.appendingPathComponent(relative))
            #expect(a == b, "\(relative)")
        }
        // Deflate made the repetitive text much smaller.
        let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int ?? 0
        #expect(size < 70000 + 20000)
    }

    @Test func zip64RecordsWhenThresholdsAreCrossed() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sources = try Self.plannedSources(dir)
        // Tiny thresholds force every ZIP64 record on a small archive; unzip must still accept it.
        let zip = try await Self.write(sources, to: dir, threshold: 1024, entryThreshold: 2)
        let test = try Self.unzip(["-t", zip.path])
        #expect(test.status == 0, "\(test.output)")
        let bytes = try Data(contentsOf: zip)
        #expect(bytes.range(of: Data([0x50, 0x4B, 0x06, 0x06])) != nil) // ZIP64 end record
        #expect(bytes.range(of: Data([0x50, 0x4B, 0x06, 0x07])) != nil) // ZIP64 locator
    }

    @Test func zip64ThresholdMath() {
        let limit = ZipMath.limit32
        #expect(!ZipMath.localNeedsZip64(expectedSize: 1 << 30))
        #expect(!ZipMath.localNeedsZip64(expectedSize: 3_000_000_000))
        #expect(ZipMath.localNeedsZip64(expectedSize: limit - 1000))
        #expect(ZipMath.localNeedsZip64(expectedSize: limit + 1))
        #expect(!ZipMath.entryNeedsZip64(compressed: limit - 1, uncompressed: limit - 1, offset: limit - 1))
        #expect(ZipMath.entryNeedsZip64(compressed: 10, uncompressed: limit, offset: 0))
        #expect(ZipMath.entryNeedsZip64(compressed: 10, uncompressed: 10, offset: limit))
        #expect(!ZipMath.endNeedsZip64(entries: 65534, directorySize: 1, directoryOffset: limit - 1))
        #expect(ZipMath.endNeedsZip64(entries: 65535, directorySize: 1, directoryOffset: 1))
        #expect(ZipMath.endNeedsZip64(entries: 1, directorySize: 1, directoryOffset: limit))
        // The 2 GB download cap stays below the 32-bit limit for a single entry.
        #expect(!ZipMath.localNeedsZip64(expectedSize: UInt64(DownloadPlanner.maxBytes)))
    }

    @Test func storesCompressedTypesAndDeflatesOthers() {
        #expect(ZipMath.shouldStore(name: "a/b/photo.JPG"))
        #expect(ZipMath.shouldStore(name: "movie.mov"))
        #expect(ZipMath.shouldStore(name: "archive.zip"))
        #expect(ZipMath.shouldStore(name: "doc.docx"))
        #expect(!ZipMath.shouldStore(name: "notes.txt"))
        #expect(!ZipMath.shouldStore(name: "Makefile"))
        #expect(!ZipMath.shouldStore(name: "image.bmp"))
    }

    @Test func dosDateTime() {
        let utc = TimeZone(identifier: "UTC")!
        // 2024-03-05 14:07:09 UTC
        let (d, t) = ZipMath.dosDateTime(Date(timeIntervalSince1970: 1_709_647_629), timeZone: utc)
        #expect(d == UInt16((2024 - 1980) << 9 | 3 << 5 | 5))
        #expect(t == UInt16(14 << 11 | 7 << 5 | 4))
        #expect(ZipMath.dosDateTime(Date(timeIntervalSince1970: 0), timeZone: utc).date == UInt16(0 << 9 | 1 << 5 | 1))
    }
}
