import Darwin
import Foundation

/// D61: renames one file or folder in place from the ⬇︎⬆︎ Files sheet. The new name stays in
/// the same folder and never replaces another item.
enum FileRename {
    /// Why a rename failed; `code` goes to the client.
    struct Failure: Error, Equatable {
        let code: ErrorCode
    }

    static let maxNameBytes = 255

    /// A single path component: no "/", no NUL, not "." or "..", 1–255 UTF-8 bytes. Leading dots
    /// are kept (a dotfile is allowed).
    static func isValidName(_ name: String) -> Bool {
        let bytes = name.utf8.count
        return bytes >= 1 && bytes <= maxNameBytes && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }

    /// EACCES/EPERM/EROFS → not_writable, ENOENT → not_found, EEXIST/ENOTEMPTY → exists, else failed.
    static func code(forErrno err: Int32) -> ErrorCode {
        switch err {
        case EACCES, EPERM, EROFS: return .notWritable
        case ENOENT: return .notFound
        case EEXIST, ENOTEMPTY: return .exists
        default: return .failed
        }
    }

    /// Renames the item at the absolute `path` (a symlink itself, not its target) to `name` in
    /// the same folder, and returns the new path. A case-only change on a case-insensitive
    /// volume names the same file, so it is allowed.
    static func rename(path raw: String, to name: String) throws(Failure) -> String {
        guard raw.hasPrefix("/"), let path = FileBrowser.resolve(raw, home: "/"), path != "/" else {
            throw Failure(code: .badRequest)
        }
        guard isValidName(name) else { throw Failure(code: .invalidName) }
        var source = stat()
        guard lstat(path, &source) == 0 else { throw Failure(code: code(forErrno: errno)) }
        let oldName = (path as NSString).lastPathComponent
        let target = FileBrowser.join((path as NSString).deletingLastPathComponent, name)
        if renamex_np(path, target, UInt32(RENAME_EXCL)) == 0 { return target }
        let err = errno
        guard err == EEXIST, isSameItem(source, at: target), oldName.caseInsensitiveCompare(name) == .orderedSame else {
            throw Failure(code: code(forErrno: err))
        }
        // The destination is this very item under another case (APFS case-insensitive).
        guard Darwin.rename(path, target) == 0 else { throw Failure(code: code(forErrno: errno)) }
        return target
    }

    private static func isSameItem(_ source: stat, at path: String) -> Bool {
        var other = stat()
        return lstat(path, &other) == 0 && other.st_dev == source.st_dev && other.st_ino == source.st_ino
    }
}
