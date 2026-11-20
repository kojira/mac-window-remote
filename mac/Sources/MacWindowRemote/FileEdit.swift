import Darwin
import Foundation

/// D62: the ⬇︎⬆︎ Files sheet's plain-text editor. Creates a new empty file, reads a UTF-8 text
/// file of at most 1 MiB, and saves it back atomically with its line endings, BOM, and mode.
/// A symlink to a regular file is followed for reading and writing: saving replaces the target
/// file, and the link stays.
enum FileEdit {
    /// Why a create, read, or write failed; `code` goes to the client.
    struct Failure: Error, Equatable {
        let code: ErrorCode
    }

    /// Text files are edited up to 1 MiB, the D36 clipboard text limit (and the WebSocket frame).
    static let maxTextBytes = BinaryClientMessage.maxClipboardBytes

    /// The page always edits with "\n"; the file's own style is restored on save.
    enum LineEnding: String, Sendable, Equatable {
        case lf, crlf
    }

    /// A file as the editor gets it: `text` without BOM and with "\n" line endings, `mtime` in
    /// milliseconds since 1970 (with the sub-millisecond part), `size` in bytes on disk.
    struct Contents: Equatable, Sendable {
        let text: String
        let mtime: Double
        let size: Int64
        let eol: LineEnding
    }

    /// The file after a save; the page's new base for the conflict check.
    struct Saved: Equatable, Sendable {
        let mtime: Double
        let size: Int64
    }

    static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// EACCES/EPERM/EROFS → not_writable, ENOENT/ENOTDIR → not_found, EEXIST → exists,
    /// ENOSPC/EDQUOT → disk_full, else failed.
    static func code(forErrno err: Int32) -> ErrorCode {
        switch err {
        case EACCES, EPERM, EROFS: return .notWritable
        case ENOENT, ENOTDIR: return .notFound
        case EEXIST: return .exists
        case ENOSPC, EDQUOT: return .diskFull
        default: return .failed
        }
    }

    /// Creates the empty file `name` (the D61 rename rules) in the folder `dir` and returns its
    /// path. An existing item of that name (also a broken symlink) is `exists`; nothing is
    /// overwritten.
    static func create(dir raw: String, name: String) throws(Failure) -> String {
        guard raw.hasPrefix("/"), let dir = FileBrowser.resolve(raw, home: "/") else { throw Failure(code: .badRequest) }
        guard FileRename.isValidName(name) else { throw Failure(code: .invalidName) }
        let path = FileBrowser.join(dir, name)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw Failure(code: code(forErrno: errno)) }
        close(fd)
        return path
    }

    /// Reads the text file at `path`. Not a regular file, a NUL byte, or invalid UTF-8 is
    /// `not_text`; over `maxBytes` is `too_large`.
    static func read(path raw: String, maxBytes: Int = maxTextBytes) throws(Failure) -> Contents {
        guard raw.hasPrefix("/"), let path = FileBrowser.resolve(raw, home: "/") else { throw Failure(code: .badRequest) }
        // O_NONBLOCK: a FIFO opens at once and is then refused as not a regular file.
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            let err = errno
            throw Failure(code: err == EACCES || err == EPERM ? .noAccess : code(forErrno: err))
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Failure(code: code(forErrno: errno)) }
        guard st.st_mode & S_IFMT == S_IFREG else { throw Failure(code: .notText) }
        guard st.st_size <= maxBytes else { throw Failure(code: .tooLarge) }
        let bytes = try readAll(fd, limit: maxBytes)
        let (text, eol) = try decodeText(bytes)
        return Contents(text: text, mtime: millis(st), size: Int64(st.st_size), eol: eol)
    }

    /// Saves `text` ("\n" line endings) over the file at `path`. Unless `force`, the file must
    /// still have `baseMtime` and `baseSize`, else `conflict`. The bytes go to a temporary file
    /// in the same folder (with the original's mode, extended attributes, and ACL), which is
    /// then renamed over the original. A BOM is kept if the file has one.
    static func write(path raw: String, text: String, baseMtime: Double, baseSize: Int64, eol: LineEnding,
                      force: Bool, maxBytes: Int = maxTextBytes) throws(Failure) -> Saved {
        guard raw.hasPrefix("/"), let link = FileBrowser.resolve(raw, home: "/") else { throw Failure(code: .badRequest) }
        guard let resolved = realpath(link, nil) else { throw Failure(code: code(forErrno: errno)) }
        let path = String(cString: resolved)
        free(resolved)
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure(code: code(forErrno: errno)) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Failure(code: code(forErrno: errno)) }
        guard st.st_mode & S_IFMT == S_IFREG else { throw Failure(code: .notText) }
        if !force, millis(st) != baseMtime || Int64(st.st_size) != baseSize { throw Failure(code: .conflict) }
        // A read-only file is not replaced, even in a writable folder.
        guard access(path, W_OK) == 0 else { throw Failure(code: code(forErrno: errno)) }

        var head = [UInt8](repeating: 0, count: 3)
        let hasBOM = pread(fd, &head, 3, 0) == 3 && head == bom
        let bytes = encodeText(text, eol: eol, bom: hasBOM)
        guard bytes.count <= maxBytes else { throw Failure(code: .tooLarge) }

        let dir = (path as NSString).deletingLastPathComponent
        let temp = FileBrowser.join(dir, ".mwr-edit-\(UUID().uuidString).tmp")
        let out = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard out >= 0 else { throw Failure(code: code(forErrno: errno)) }
        var committed = false
        defer { if !committed { unlink(temp) } }
        var failure: Int32 = 0
        // Best effort: a volume without extended attributes or ACLs still saves the text.
        _ = fcopyfile(fd, out, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
        if fchmod(out, st.st_mode & 0o7777) != 0 { failure = errno }
        if failure == 0 { failure = writeAll(out, bytes) }
        if failure == 0, fsync(out) != 0 { failure = errno }
        if close(out) != 0, failure == 0 { failure = errno }
        guard failure == 0 else { throw Failure(code: code(forErrno: failure)) }
        guard rename(temp, path) == 0 else { throw Failure(code: code(forErrno: errno)) }
        committed = true

        var after = stat()
        guard stat(path, &after) == 0 else { throw Failure(code: code(forErrno: errno)) }
        return Saved(mtime: millis(after), size: Int64(after.st_size))
    }

    /// The modification time in milliseconds, with the sub-millisecond part, so the page's base
    /// round-trips through JSON and compares equal.
    static func millis(_ st: stat) -> Double {
        Double(st.st_mtimespec.tv_sec) * 1000 + Double(st.st_mtimespec.tv_nsec) / 1_000_000
    }

    /// Strict UTF-8 (no replacement characters); nil if invalid.
    static func utf8String<C: Collection>(_ bytes: C) -> String? where C.Element == UInt8 {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: break loop
            case .error: return nil
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The editor's text of a file's bytes: without a BOM, with "\n" line endings, and the
    /// file's style — CRLF if most line endings are CRLF, else LF.
    static func decodeText(_ bytes: [UInt8]) throws(Failure) -> (String, LineEnding) {
        let body = bytes.starts(with: bom) ? bytes.dropFirst(3) : bytes[...]
        guard !body.contains(0), let raw = utf8String(body) else { throw Failure(code: .notText) }
        var crlf = 0
        var lf = 0
        var previous: UInt8 = 0
        for b in body {
            if b == 0x0A { if previous == 0x0D { crlf += 1 } else { lf += 1 } }
            previous = b
        }
        return (raw.replacingOccurrences(of: "\r\n", with: "\n"), crlf > lf ? .crlf : .lf)
    }

    /// The bytes saved for the editor's text: "\n" becomes "\r\n" for CRLF, and the BOM leads.
    static func encodeText(_ text: String, eol: LineEnding, bom keepBOM: Bool) -> [UInt8] {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        if eol == .crlf { body = body.replacingOccurrences(of: "\n", with: "\r\n") }
        return (keepBOM ? bom : []) + Array(body.utf8)
    }

    private static func readAll(_ fd: Int32, limit: Int) throws(Failure) -> [UInt8] {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure(code: .failed)
            }
            if n == 0 { return bytes }
            bytes += buffer[0..<n]
            // The file grew past the limit after it was checked.
            if bytes.count > limit { throw Failure(code: .tooLarge) }
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Int32 {
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, $0.count - done) }
            if n < 0 {
                if errno == EINTR { continue }
                return errno
            }
            done += n
        }
        return 0
    }
}
