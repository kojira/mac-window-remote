import Darwin
import Foundation

// Image and file uploads (DESIGN.md D12, amended by D36, D42, and D58): type sniffing, chunk
// assembly, streaming files to disk, file name sanitizing, and the temp uploads directory.

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
/// chunk at offset 0 starts a new upload and replaces an unfinished one. After an upload fails,
/// its remaining chunks (already on the way) are ignored. Files (D42, D58) are streamed to disk
/// by `FileUploadReceiver` instead.
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
            self.type = type
            self.id = id
            self.size = size
            buffer.reserveCapacity(size)
        } else {
            if id == failedId { return .ignored }
            guard id == self.id, size == self.size, offset == buffer.count else {
                reset()
                return fail(id, .badRequest)
            }
        }
        buffer.append(bytes)
        guard buffer.count == size, let type = self.type else { return .needMore }
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

/// Why a streamed file upload (D42, D58) stopped; `code` is sent to the device.
struct UploadFailure: Error, Equatable {
    let code: ErrorCode

    /// The error code for an `errno` of open, write, or rename.
    static func posix(_ err: Int32) -> UploadFailure {
        switch err {
        case ENOENT, ENOTDIR: return UploadFailure(code: .notFound)
        case EACCES, EPERM, EROFS: return UploadFailure(code: .notWritable)
        case ENOSPC, EDQUOT: return UploadFailure(code: .diskFull)
        case EFBIG: return UploadFailure(code: .tooLarge)
        default: return UploadFailure(code: .internal)
        }
    }
}

/// D58: the folder a file is uploaded into. It must be given as an absolute path and exist as
/// a directory after resolving symlinks; whether it is writable is left to the actual open.
enum UploadDestination {
    static func resolve(_ path: String) throws(UploadFailure) -> URL {
        guard path.hasPrefix("/"), path.utf8.count <= ClientMessage.maxPathBytes else {
            throw UploadFailure(code: .badRequest)
        }
        guard let resolved = realpath(path, nil) else {
            throw errno == EACCES ? UploadFailure(code: .noAccess) : UploadFailure(code: .notFound)
        }
        defer { free(resolved) }
        let real = String(cString: resolved)
        var st = stat()
        guard stat(real, &st) == 0 else { throw UploadFailure(code: .notFound) }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw UploadFailure(code: .notADirectory) }
        return URL(fileURLWithPath: real, isDirectory: true)
    }

    /// The Finder-style name for the `n`th try: "name.ext", then "name 2.ext", "name 3.ext", ….
    static func collisionName(_ name: String, attempt n: Int) -> String {
        guard n > 1 else { return name }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "\(name) \(n)" }
        return "\((name as NSString).deletingPathExtension) \(n).\(ext)"
    }

    static let maxCollisionAttempts = 10_000
}

/// One file being written straight to disk (D42, D58): a hidden `.mwr-upload-<UUID>.part` in
/// its folder, renamed atomically to its final name when every byte has arrived. Never
/// overwrites a file and never holds the file in memory.
final class PartFile {
    let folder: URL
    let name: String
    let size: Int
    let partURL: URL
    /// D42: the `<UUID>` folder was made for this upload and is removed with a discarded part.
    let ownsFolder: Bool
    private var fd: Int32
    private(set) var written = 0

    init(folder: URL, name: String, size: Int, ownsFolder: Bool) throws(UploadFailure) {
        self.folder = folder
        self.name = name
        self.size = size
        self.ownsFolder = ownsFolder
        partURL = folder.appendingPathComponent(".mwr-upload-\(UUID().uuidString).part", isDirectory: false)
        fd = open(partURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            let err = errno
            if ownsFolder { rmdir(folder.path) }
            throw UploadFailure.posix(err)
        }
    }

    deinit { if fd >= 0 { close(fd) } }

    func write(_ data: Data) throws(UploadFailure) {
        var failure: Int32 = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var done = 0
            while done < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + done, raw.count - done)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                done += n
            }
        }
        if failure != 0 { throw UploadFailure.posix(failure) }
        written += data.count
    }

    /// Closes the part and renames it to the first free Finder-style name; returns the URL.
    func commit() throws(UploadFailure) -> URL {
        let closed = close(fd)
        fd = -1
        if closed != 0 { throw UploadFailure.posix(errno) }
        for n in 1...UploadDestination.maxCollisionAttempts {
            let target = folder.appendingPathComponent(UploadDestination.collisionName(name, attempt: n), isDirectory: false)
            if renamex_np(partURL.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            if errno != EEXIST { throw UploadFailure.posix(errno) }
        }
        throw UploadFailure(code: .internal)
    }

    /// Closes and deletes the part (and an owned, now empty, folder).
    func discard() {
        if fd >= 0 { close(fd) }
        fd = -1
        unlink(partURL.path)
        if ownsFolder { rmdir(folder.path) }
    }
}

/// Streams the chunks of one file upload at a time to a `PartFile` (D42, D58). A chunk at
/// offset 0 starts a new upload and discards an unfinished one. After a failure the rest of
/// that upload's chunks are ignored. Every failure, cancel, or `abort` deletes the part.
struct FileUploadReceiver {
    /// Any file is at most 2 GB (2 × 1024³ bytes).
    static let maxFileBytes = 2 * 1024 * 1024 * 1024

    enum Step: Equatable {
        case needMore
        case complete(URL)
        case failed(ErrorCode)
        /// A chunk of an upload that already failed, was cancelled, or is not known.
        case ignored
    }

    let maxBytes: Int
    private var id: String?
    private var part: PartFile?
    private var failedId: String?

    init(maxBytes: Int = FileUploadReceiver.maxFileBytes) {
        self.maxBytes = maxBytes
    }

    /// The upload in progress, if any.
    var currentId: String? { id }

    /// The chunk at offset 0. The declared `size` is checked before anything is created;
    /// `folder` is called only then and returns the folder (and whether this upload owns it).
    mutating func start(id: String, size: Int, name: String, bytes: Data,
                        folder: () throws(UploadFailure) -> (URL, ownsFolder: Bool)) -> Step {
        abort()
        guard size <= maxBytes else { return fail(id, .tooLarge) }
        do {
            let (url, owns) = try folder()
            part = try PartFile(folder: url, name: UploadStore.sanitizedFileName(name), size: size, ownsFolder: owns)
        } catch {
            return fail(id, error.code)
        }
        self.id = id
        return write(bytes)
    }

    /// A later chunk.
    mutating func append(id: String, size: Int, offset: Int, bytes: Data) -> Step {
        if id == failedId { return .ignored }
        guard id == self.id, let part, size == part.size, offset == part.written else {
            abort()
            return fail(id, .badRequest)
        }
        return write(bytes)
    }

    /// Stops the upload `id` (a cancel from the device); its later chunks are ignored.
    mutating func cancel(id: String) {
        guard id == self.id else { return }
        abort()
        failedId = id
    }

    /// Stops the upload `id` before it starts (for example when no window is viewed).
    mutating func reject(id: String) {
        abort()
        failedId = id
    }

    /// Deletes the unfinished part, if any (a newer upload, disconnect, or session end).
    mutating func abort() {
        part?.discard()
        part = nil
        id = nil
    }

    private mutating func write(_ bytes: Data) -> Step {
        guard let part, let id else { return .ignored }
        // The declared size was checked, but the bytes written are capped too.
        guard part.written + bytes.count <= min(part.size, maxBytes) else {
            let code: ErrorCode = part.written + bytes.count > maxBytes ? .tooLarge : .badRequest
            abort()
            return fail(id, code)
        }
        do {
            if !bytes.isEmpty { try part.write(bytes) }
            guard part.written == part.size else { return .needMore }
            let url = try part.commit()
            self.part = nil
            self.id = nil
            return .complete(url)
        } catch {
            abort()
            return fail(id, error.code)
        }
    }

    private mutating func fail(_ id: String, _ code: ErrorCode) -> Step {
        failedId = id
        return .failed(code)
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

    /// A new `<UUID>` subdirectory (mode 0700) for one file upload (D42), so names never
    /// collide and the pasted path ends with the real name. The file is streamed into it.
    func makeFileFolder() throws(UploadFailure) -> URL {
        let fm = FileManager.default
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try prepareDirectory()
            try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw UploadFailure(code: .internal)
        }
        return folder
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
