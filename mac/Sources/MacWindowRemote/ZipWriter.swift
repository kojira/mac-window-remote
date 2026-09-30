import Foundation
import zlib

// A streaming zip writer for downloads (DESIGN.md D47). Entries are written one after another
// with data descriptors (sizes and CRC after the data), so nothing is buffered beyond one read
// chunk and no temporary archive is made. ZIP64 records are added only where a size, offset, or
// entry count needs them. File names are UTF-8 (flag bit 11).

enum ZipMath {
    /// A 32-bit zip field at this value means "see the ZIP64 record".
    static let limit32: UInt64 = 0xFFFF_FFFF
    static let limit16 = 0xFFFF

    /// A local header announces ZIP64 (8-byte data descriptor sizes) when the file may reach
    /// the 32-bit limit. Deflate can grow incompressible data by a few bytes per 16 KiB block,
    /// so a margin keeps the decision safe.
    static func localNeedsZip64(expectedSize: UInt64, threshold: UInt64 = limit32) -> Bool {
        expectedSize >= threshold - min(threshold, expectedSize / 1024 + 1024)
    }

    /// A central directory entry needs the ZIP64 extra field when a size or its offset does not
    /// fit in 32 bits.
    static func entryNeedsZip64(compressed: UInt64, uncompressed: UInt64, offset: UInt64,
                                threshold: UInt64 = limit32) -> Bool {
        compressed >= threshold || uncompressed >= threshold || offset >= threshold
    }

    /// The end of the archive needs the ZIP64 end records when the count, the directory's size,
    /// or its offset does not fit.
    static func endNeedsZip64(entries: Int, directorySize: UInt64, directoryOffset: UInt64,
                              threshold: UInt64 = limit32, entryThreshold: Int = limit16) -> Bool {
        entries >= entryThreshold || directorySize >= threshold || directoryOffset >= threshold
    }

    /// Types that are compressed already: stored, not deflated.
    static let storedExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "lz", "lzma", "z",
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif",
        "mp3", "m4a", "aac", "ogg", "opus", "flac",
        "mp4", "m4v", "mov", "avi", "mkv", "webm",
        "dmg", "pkg", "ipa", "apk", "jar", "xip",
        "docx", "xlsx", "pptx", "odt", "ods", "odp", "epub",
    ]

    static func shouldStore(name: String) -> Bool {
        storedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// MS-DOS date and time in local time (years before 1980 are clamped).
    static func dosDateTime(_ date: Date, timeZone: TimeZone = .current) -> (date: UInt16, time: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, c.year ?? 1980))
        let d = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        let t = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        return (d, t)
    }
}

/// Raw deflate (no zlib header) over chunks.
final class RawDeflater {
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
    private var finished = false

    init?() {
        stream.initialize(to: z_stream())
        let status = deflateInit2_(stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            stream.deallocate()
            return nil
        }
    }

    deinit {
        deflateEnd(stream)
        stream.deallocate()
    }

    /// Compresses `input`; with `final`, also flushes the end of the stream.
    func deflate(_ input: Data, final: Bool) -> Data {
        guard !finished else { return Data() }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.pointee.avail_in = uInt(raw.count)
            while true {
                let status = chunk.withUnsafeMutableBufferPointer { out -> Int32 in
                    stream.pointee.next_out = out.baseAddress
                    stream.pointee.avail_out = uInt(out.count)
                    let status = zlib.deflate(stream, final ? Z_FINISH : Z_NO_FLUSH)
                    output.append(out.baseAddress!, count: out.count - Int(stream.pointee.avail_out))
                    return status
                }
                if final ? status == Z_STREAM_END : stream.pointee.avail_out != 0 { break }
                if status != Z_OK && status != Z_BUF_ERROR { break }
            }
            stream.pointee.next_in = nil
        }
        if final { finished = true }
        return output
    }
}

/// Writes a zip to `sink` as it goes. Call `add` for each entry, then `finish`.
final class ZipStreamWriter {
    private struct CentralEntry {
        var name: [UInt8]
        var method: UInt16
        var dosDate: UInt16
        var dosTime: UInt16
        var crc: UInt32
        var compressed: UInt64
        var uncompressed: UInt64
        var offset: UInt64
        var externalAttributes: UInt32
        var isDirectory: Bool
    }

    static let readChunk = 256 * 1024

    private let sink: (Data) async throws -> Void
    private let threshold: UInt64
    private let entryThreshold: Int
    private var offset: UInt64 = 0
    private var entries: [CentralEntry] = []

    /// `threshold` and `entryThreshold` are the ZIP64 limits; tests lower them to exercise
    /// ZIP64 on small archives.
    init(threshold: UInt64 = ZipMath.limit32, entryThreshold: Int = ZipMath.limit16,
         sink: @escaping (Data) async throws -> Void) {
        self.threshold = threshold
        self.entryThreshold = entryThreshold
        self.sink = sink
    }

    private func emit(_ data: Data) async throws {
        offset += UInt64(data.count)
        try await sink(data)
    }

    /// Adds a folder entry (`archivePath` ends in `/`) or a file read from `fileURL`, at most
    /// `source.size` bytes (the size the download was checked against). A file that cannot be
    /// opened is written empty.
    func add(_ source: ZipSource) async throws {
        let isDirectory = source.fileURL == nil
        let name = Array(source.archivePath.utf8)
        let store = isDirectory || ZipMath.shouldStore(name: source.archivePath)
        let method: UInt16 = store ? 0 : 8
        let zip64Local = !isDirectory && ZipMath.localNeedsZip64(expectedSize: UInt64(max(0, source.size)), threshold: threshold)
        let (dosDate, dosTime) = ZipMath.dosDateTime(source.modified)
        let headerOffset = offset

        var header = ByteWriter()
        header.u32(0x0403_4B50)
        header.u16(zip64Local ? 45 : 20)
        header.u16(isDirectory ? 1 << 11 : 1 << 11 | 1 << 3)
        header.u16(method)
        header.u16(dosTime)
        header.u16(dosDate)
        header.u32(0) // CRC, sizes: in the data descriptor
        header.u32(zip64Local ? 0xFFFF_FFFF : 0)
        header.u32(zip64Local ? 0xFFFF_FFFF : 0)
        header.u16(UInt16(name.count))
        header.u16(zip64Local ? 20 : 0)
        header.bytes(name)
        if zip64Local {
            header.u16(0x0001)
            header.u16(16)
            header.u64(0)
            header.u64(0)
        }
        try await emit(header.data)

        var crc: UInt32 = 0
        var compressed: UInt64 = 0
        var uncompressed: UInt64 = 0
        if let url = source.fileURL {
            let deflater = store ? nil : RawDeflater()
            let handle = try? FileHandle(forReadingFrom: url)
            defer { try? handle?.close() }
            var remaining = UInt64(max(0, source.size))
            while remaining > 0, let handle {
                let chunk = (try? handle.read(upToCount: Int(min(UInt64(Self.readChunk), remaining)))) ?? Data()
                if chunk.isEmpty { break }
                remaining -= UInt64(chunk.count)
                uncompressed += UInt64(chunk.count)
                crc = chunk.withUnsafeBytes { UInt32(zlib.crc32(uLong(crc), $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
                let out = deflater?.deflate(chunk, final: false) ?? chunk
                compressed += UInt64(out.count)
                if !out.isEmpty { try await emit(out) }
            }
            if let deflater {
                let tail = deflater.deflate(Data(), final: true)
                compressed += UInt64(tail.count)
                if !tail.isEmpty { try await emit(tail) }
            }
            var descriptor = ByteWriter()
            descriptor.u32(0x0807_4B50)
            descriptor.u32(crc)
            if zip64Local {
                descriptor.u64(compressed)
                descriptor.u64(uncompressed)
            } else {
                descriptor.u32(UInt32(truncatingIfNeeded: compressed))
                descriptor.u32(UInt32(truncatingIfNeeded: uncompressed))
            }
            try await emit(descriptor.data)
        }
        let type: UInt32 = isDirectory ? 0o040000 : 0o100000
        let attributes = (type | UInt32(source.mode & 0o7777)) << 16 | (isDirectory ? 0x10 : 0)
        entries.append(CentralEntry(name: name, method: method, dosDate: dosDate, dosTime: dosTime, crc: crc,
                                    compressed: compressed, uncompressed: uncompressed, offset: headerOffset,
                                    externalAttributes: attributes, isDirectory: isDirectory))
    }

    /// Writes the central directory and the end records.
    func finish() async throws {
        let directoryOffset = offset
        var directory = ByteWriter()
        for e in entries {
            let zip64 = ZipMath.entryNeedsZip64(compressed: e.compressed, uncompressed: e.uncompressed,
                                                offset: e.offset, threshold: threshold)
            directory.u32(0x0201_4B50)
            directory.u16(3 << 8 | 45) // made by Unix, spec 4.5
            directory.u16(zip64 ? 45 : 20)
            directory.u16(e.isDirectory ? 1 << 11 : 1 << 11 | 1 << 3)
            directory.u16(e.method)
            directory.u16(e.dosTime)
            directory.u16(e.dosDate)
            directory.u32(e.crc)
            directory.u32(zip64 ? 0xFFFF_FFFF : UInt32(e.compressed))
            directory.u32(zip64 ? 0xFFFF_FFFF : UInt32(e.uncompressed))
            directory.u16(UInt16(e.name.count))
            directory.u16(zip64 ? 28 : 0)
            directory.u16(0) // comment
            directory.u16(0) // disk
            directory.u16(0) // internal attributes
            directory.u32(e.externalAttributes)
            directory.u32(zip64 ? 0xFFFF_FFFF : UInt32(e.offset))
            directory.bytes(e.name)
            if zip64 {
                directory.u16(0x0001)
                directory.u16(24)
                directory.u64(e.uncompressed)
                directory.u64(e.compressed)
                directory.u64(e.offset)
            }
        }
        let directorySize = UInt64(directory.data.count)
        try await emit(directory.data)

        var end = ByteWriter()
        let zip64End = ZipMath.endNeedsZip64(entries: entries.count, directorySize: directorySize, directoryOffset: directoryOffset,
                                             threshold: threshold, entryThreshold: entryThreshold)
        if zip64End {
            let recordOffset = offset
            end.u32(0x0606_4B50)
            end.u64(44)
            end.u16(3 << 8 | 45)
            end.u16(45)
            end.u32(0)
            end.u32(0)
            end.u64(UInt64(entries.count))
            end.u64(UInt64(entries.count))
            end.u64(directorySize)
            end.u64(directoryOffset)
            end.u32(0x0706_4B50)
            end.u32(0)
            end.u64(recordOffset)
            end.u32(1)
        }
        end.u32(0x0605_4B50)
        end.u16(0)
        end.u16(0)
        end.u16(zip64End ? 0xFFFF : UInt16(entries.count))
        end.u16(zip64End ? 0xFFFF : UInt16(entries.count))
        end.u32(zip64End ? 0xFFFF_FFFF : UInt32(directorySize))
        end.u32(zip64End ? 0xFFFF_FFFF : UInt32(directoryOffset))
        end.u16(0)
        try await emit(end.data)
    }
}

/// Little-endian fields.
private struct ByteWriter {
    var data = Data()
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
}
