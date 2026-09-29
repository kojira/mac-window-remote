import Foundation

// Image uploads (DESIGN.md D12, amended by D36): type sniffing, chunk assembly, and the temp
// directory the images are saved in.

/// An accepted image type, sniffed from the magic bytes (D12).
enum ImageType: String, Equatable, Sendable {
    case png, jpeg, heic, heif, gif, webp

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }

    /// HEIF brands that hold HEVC images (`.heic`); other HEIF brands are `.heif`.
    private static let heicBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis"]
    private static let heifBrands: Set<String> = ["mif1", "msf1", "heif"]

    /// The type of `data` from its first bytes, or nil for anything else.
    static func sniff(_ data: Data) -> ImageType? {
        let b = [UInt8](data.prefix(12))
        func ascii(_ range: Range<Int>) -> String? {
            guard b.count >= range.upperBound else { return nil }
            return String(bytes: b[range], encoding: .ascii)
        }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if let sig = ascii(0..<6), sig == "GIF87a" || sig == "GIF89a" { return .gif }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WEBP" { return .webp }
        if ascii(4..<8) == "ftyp", let brand = ascii(8..<12) {
            if heicBrands.contains(brand) { return .heic }
            if heifBrands.contains(brand) { return .heif }
        }
        return nil
    }
}

/// Collects the chunks of one image upload (D36). Chunks arrive in order on the WebSocket; a
/// chunk at offset 0 starts a new upload and replaces an unfinished one. After an upload
/// fails, its remaining chunks (already on the way) are ignored.
struct ImageUploadAssembler {
    static let maxImageBytes = 25 << 20

    enum Step: Equatable {
        case needMore
        case complete(Data, ImageType)
        case failed(ErrorCode)
        /// A chunk of an upload that already failed.
        case ignored
    }

    private var id: String?
    private var size = 0
    private var type: ImageType?
    private var buffer = Data()
    private var failedId: String?

    mutating func receive(id: String, size: Int, offset: Int, bytes: Data) -> Step {
        if offset == 0 {
            reset()
            guard size <= Self.maxImageBytes else { return fail(id, .tooLarge) }
            guard let type = ImageType.sniff(bytes) else { return fail(id, .unsupportedType) }
            self.id = id
            self.size = size
            self.type = type
            buffer.reserveCapacity(size)
        } else {
            if id == failedId { return .ignored }
            guard id == self.id, size == self.size, offset == buffer.count else {
                reset()
                return fail(id, .badRequest)
            }
        }
        buffer.append(bytes)
        guard buffer.count == size, let type else { return .needMore }
        let data = buffer
        reset()
        return .complete(data, type)
    }

    /// Stops the upload `id` (for example when no window is viewed); its later chunks are ignored.
    mutating func reject(id: String) {
        reset()
        failedId = id
    }

    private mutating func fail(_ id: String, _ code: ErrorCode) -> Step {
        failedId = id
        return .failed(code)
    }

    private mutating func reset() {
        id = nil
        size = 0
        type = nil
        buffer = Data()
    }
}

/// The uploads directory under the per-user `$TMPDIR` (D12): mode 0700, files named
/// `img-YYYYMMDD-HHMMSS-<4 hex>.<ext>`, removed after 24 h.
struct UploadStore: Sendable {
    let directory: URL

    static let maxAge: TimeInterval = 24 * 60 * 60

    static var standard: UploadStore {
        UploadStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-window-remote", isDirectory: true)
            .appendingPathComponent("uploads", isDirectory: true))
    }

    /// Creates the directory (and its parent) with mode 0700, and resets the mode if it exists.
    func prepareDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// `img-YYYYMMDD-HHMMSS-<4 hex>.<ext>` in local time; no spaces, so the path never needs quoting.
    static func fileName(date: Date, random: UInt16, fileExtension: String, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "img-\(f.string(from: date))-\(String(format: "%04x", random)).\(fileExtension)"
    }

    /// Writes the image under a new name and returns its URL. Never overwrites a file.
    func save(_ data: Data, type: ImageType, now: Date = Date()) throws -> URL {
        try prepareDirectory()
        var attempts = 0
        while true {
            let name = Self.fileName(date: now, random: UInt16.random(in: 0...UInt16.max), fileExtension: type.fileExtension)
            let url = directory.appendingPathComponent(name, isDirectory: false)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists where attempts < 16 {
                attempts += 1
            }
        }
    }

    /// Deletes regular files directly in the directory that are older than `maxAge`. Nothing
    /// outside it is touched: subdirectories and symbolic links are skipped. Returns the count.
    @discardableResult
    func removeExpired(now: Date = Date()) -> Int {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var removed = 0
        for url in items {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true, v.isSymbolicLink != true,
                  let modified = v.contentModificationDate,
                  now.timeIntervalSince(modified) > Self.maxAge else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
