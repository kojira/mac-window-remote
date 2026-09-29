import Foundation

// Image and file uploads (DESIGN.md D12, amended by D36 and D42): type sniffing, chunk
// assembly, file name sanitizing, and the temp directory the uploads are saved in.

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

/// Collects the chunks of one image or file upload (D36, D42). Chunks arrive in order on the
/// WebSocket; a chunk at offset 0 starts a new upload and replaces an unfinished one. After an
/// upload fails, its remaining chunks (already on the way) are ignored.
struct ImageUploadAssembler {
    static let maxImageBytes = 25 << 20
    /// Any file (D42) is at most 100 MiB; it is not sniffed.
    static let maxFileBytes = 100 << 20

    enum Step: Equatable {
        case needMore
        case complete(Data, ImageType)
        /// A file upload (D42) with the name the phone sent (not yet sanitized).
        case completeFile(Data, name: String)
        case failed(ErrorCode)
        /// A chunk of an upload that already failed.
        case ignored
    }

    private var id: String?
    private var size = 0
    private var type: ImageType?
    private var fileName: String?
    private var buffer = Data()
    private var failedId: String?

    /// `fileName` is nil for an image chunk; for a file chunk it is the name at offset 0 and
    /// empty on later chunks.
    mutating func receive(id: String, size: Int, offset: Int, bytes: Data, fileName: String? = nil) -> Step {
        if offset == 0 {
            reset()
            if let fileName {
                guard size <= Self.maxFileBytes else { return fail(id, .tooLarge) }
                self.fileName = fileName
            } else {
                guard size <= Self.maxImageBytes else { return fail(id, .tooLarge) }
                guard let type = ImageType.sniff(bytes) else { return fail(id, .unsupportedType) }
                self.type = type
            }
            self.id = id
            self.size = size
            buffer.reserveCapacity(size)
        } else {
            if id == failedId { return .ignored }
            guard id == self.id, size == self.size, offset == buffer.count,
                  (fileName == nil) == (self.fileName == nil) else {
                reset()
                return fail(id, .badRequest)
            }
        }
        buffer.append(bytes)
        guard buffer.count == size else { return .needMore }
        let data = buffer
        let (type, name) = (self.type, self.fileName)
        reset()
        if let name { return .completeFile(data, name: name) }
        guard let type else { return .needMore }
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
        fileName = nil
        buffer = Data()
    }
}

/// The uploads directory under the per-user `$TMPDIR` (D12): mode 0700, images named
/// `img-YYYYMMDD-HHMMSS-<4 hex>.<ext>`, other files (D42) in `<UUID>/<original name>`,
/// removed after 24 h.
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

    /// A file name longer than this many UTF-8 bytes is shortened (APFS allows 255).
    static let maxFileNameBytes = 200

    /// The name a file upload is saved under (D42): the last path component only, without
    /// control or format characters, leading dots, or surrounding spaces, at most
    /// `maxFileNameBytes` (the extension is kept), and "file" when nothing is left.
    static func sanitizedFileName(_ raw: String) -> String {
        let base = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var name = String(String.UnicodeScalarView(base.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        while true {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            let undotted = String(trimmed.drop(while: { $0 == "." }))
            if undotted == name { break }
            name = undotted
        }
        if name.utf8.count > maxFileNameBytes {
            let ext = (name as NSString).pathExtension
            let suffix = !ext.isEmpty && ext.utf8.count <= 16 ? "." + ext : ""
            var stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
            while stem.utf8.count + suffix.utf8.count > maxFileNameBytes { stem.removeLast() }
            name = stem.trimmingCharacters(in: .whitespaces) + suffix
        }
        return name.isEmpty ? "file" : name
    }

    /// Writes a file upload (D42) as `<UUID>/<sanitized name>` in a new subdirectory (mode
    /// 0700), so names never collide and the pasted path ends with the real name. The bytes are
    /// only written, never opened or interpreted.
    func saveFile(_ data: Data, name: String) throws -> URL {
        try prepareDirectory()
        let fm = FileManager.default
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(Self.sanitizedFileName(name), isDirectory: false)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Deletes what is older than `maxAge` directly in the directory: regular files, and the
    /// `<UUID>` subdirectories of file uploads (D42) with their contents. Nothing outside it is
    /// touched: symbolic links and other subdirectories are skipped. Returns the count.
    @discardableResult
    func removeExpired(now: Date = Date()) -> Int {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var removed = 0
        for url in items {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true,
                  v.isRegularFile == true || (v.isDirectory == true && UUID(uuidString: url.lastPathComponent) != nil),
                  let modified = v.contentModificationDate,
                  now.timeIntervalSince(modified) > Self.maxAge else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
