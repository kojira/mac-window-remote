import Darwin
import Foundation

// Download files from the Mac (DESIGN.md D47): folder listing, file-name search, and the
// selected-path checks. Read only: nothing here creates, changes, or deletes a file.

/// One row of a listing or a search result. `mtime` is milliseconds since 1970; `size` is nil
/// for folders and broken links. `parent` is set on search results only.
struct FileEntry: Encodable, Equatable, Sendable {
    var name: String
    var path: String
    var dir: Bool
    var size: Int64?
    var mtime: Double?
    var link: Bool
    var parent: String?
}

/// The listing order the client asked for (D55). Folders stay first; ties and folders under
/// `size` fall back to the name order; a missing size or date goes last in either direction.
struct FileSort: Equatable, Sendable {
    enum Key: String, Sendable { case name, mtime, size }
    var key: Key
    var descending: Bool

    /// The D47 order, used when a request names no sort.
    static let name = FileSort(key: .name, descending: false)
}

struct FileListing: Equatable, Sendable {
    /// The folder as the client names it (standardized, symlinks kept).
    var path: String
    var entries: [FileEntry]
    /// Entries before the cap (hidden ones not counted unless shown).
    var total: Int
    var truncated: Bool { total > entries.count }
}

struct FileSearchResult: Equatable, Sendable {
    var base: String
    var entries: [FileEntry]
    /// Stopped at `maxSearchResults`.
    var truncated: Bool
    /// Stopped at the time limit.
    var timedOut: Bool
}

/// A quick place of the sheet (Home, Desktop, …, Computer, mounted volumes).
struct FilePlace: Encodable, Equatable, Sendable {
    var name: String
    var path: String
}

enum FileBrowserError: Error, Equatable {
    /// Not absolute (after `~` expansion) or empty.
    case badPath
    case notFound
    case notADirectory
    /// Permission or privacy (TCC) refusal.
    case noAccess
    /// A download over `DownloadPlanner.maxBytes` or `maxFiles`.
    case tooLarge
}

extension FileBrowserError {
    var code: ErrorCode {
        switch self {
        case .badPath: return .badRequest
        case .notFound: return .notFound
        case .notADirectory: return .notADirectory
        case .noAccess: return .noAccess
        case .tooLarge: return .tooLarge
        }
    }
}

enum FileBrowser {
    static let maxEntries = 5000
    static let maxSearchResults = 500
    static let searchTimeLimit: TimeInterval = 5
    /// Not walked when a search starts at `/`.
    static let rootSearchSkips: Set<String> = ["/System", "/private", "/dev"]

    /// `~` and `~/…` become the home folder; the result must be absolute and is standardized
    /// (`.` and `..` removed, no trailing slash). Symlinks are kept.
    static func resolve(_ raw: String, home: String) -> String? {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        guard p.hasPrefix("/") else { return nil }
        let standardized = URL(fileURLWithPath: p).standardized.path
        return standardized.isEmpty ? "/" : standardized
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    /// The canonical path (all symlinks resolved, `/var` → `/private/var`), as the directory
    /// enumerator reports it; `resolvingSymlinksInPath` strips `/private` and would not match.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func errorFromErrno(_ code: Int32) -> FileBrowserError {
        switch code {
        case ENOENT: return .notFound
        case ENOTDIR: return .notADirectory
        default: return .noAccess
        }
    }

    /// The entry at `path`, following a symlink for its type, size, and date (a broken link is
    /// a file without size). Nil if nothing is there.
    static func entry(path: String, name: String) -> FileEntry? {
        var ls = stat()
        guard lstat(path, &ls) == 0 else { return nil }
        let isLink = (ls.st_mode & S_IFMT) == S_IFLNK
        var st = ls
        let followed = !isLink || stat(path, &st) == 0
        let dir = followed && (st.st_mode & S_IFMT) == S_IFDIR
        let mtime = followed ? Double(st.st_mtimespec.tv_sec) * 1000 + Double(st.st_mtimespec.tv_nsec / 1_000_000) : nil
        return FileEntry(name: name, path: path, dir: dir, size: dir || !followed ? nil : Int64(st.st_size),
                         mtime: mtime, link: isLink, parent: nil)
    }

    /// Folders first, then by `sort` (D55); ties by name (localized, case-insensitive).
    static func sorted(_ entries: [FileEntry], by sort: FileSort = .name) -> [FileEntry] {
        func nameAscending(_ a: FileEntry, _ b: FileEntry) -> Bool {
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            return order == .orderedSame ? a.name < b.name : order == .orderedAscending
        }
        // Missing values go last in both directions.
        func byValue(_ x: Double?, _ y: Double?) -> Bool? {
            switch (x, y) {
            case (nil, nil): return nil
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?): return x == y ? nil : (sort.descending ? x > y : x < y)
            }
        }
        return entries.sorted { a, b in
            if a.dir != b.dir { return a.dir }
            switch sort.key {
            case .name:
                return sort.descending ? nameAscending(b, a) : nameAscending(a, b)
            case .mtime:
                return byValue(a.mtime, b.mtime) ?? nameAscending(a, b)
            case .size:
                if a.dir { return nameAscending(a, b) }
                return byValue(a.size.map(Double.init), b.size.map(Double.init)) ?? nameAscending(a, b)
            }
        }
    }

    static func isHidden(_ name: String) -> Bool { name.hasPrefix(".") }

    /// The folder's entries in `sort` order, dot-files left out unless `showHidden`, at most
    /// `limit`: sorted before the cap, so a huge folder sends the first rows of that order.
    /// A symlinked folder is listed through its target.
    static func list(path raw: String, home: String, showHidden: Bool, sort: FileSort = .name,
                     limit: Int = maxEntries) throws -> FileListing {
        guard let path = resolve(raw, home: home) else { throw FileBrowserError.badPath }
        var st = stat()
        guard stat(path, &st) == 0 else { throw errorFromErrno(errno) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw FileBrowserError.notADirectory }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw FileBrowserError.notFound
        } catch {
            throw FileBrowserError.noAccess
        }
        let entries = names.lazy
            .filter { showHidden || !isHidden($0) }
            .compactMap { entry(path: join(path, $0), name: $0) }
        let all = sorted(Array(entries), by: sort)
        return FileListing(path: path, entries: Array(all.prefix(limit)), total: all.count)
    }

    /// File-name search: `query` as a case-insensitive substring of the name, walking `base`
    /// recursively without entering package contents, hidden files and folders (unless
    /// `showHidden`), or, from `/`, `/System`, `/private`, and `/dev`. Stops at `limit`
    /// matches, `timeLimit`, or cancellation. Unreadable folders are skipped.
    static func search(base raw: String, query: String, home: String, showHidden: Bool,
                       limit: Int = maxSearchResults, timeLimit: TimeInterval = searchTimeLimit,
                       isCancelled: () -> Bool = { false }) throws -> FileSearchResult {
        guard let base = resolve(raw, home: home) else { throw FileBrowserError.badPath }
        var st = stat()
        guard stat(base, &st) == 0 else { throw errorFromErrno(errno) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw FileBrowserError.notADirectory }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = FileSearchResult(base: base, entries: [], truncated: false, timedOut: false)
        guard !needle.isEmpty else { return result }
        // The walk reads the target of a symlinked base; result paths keep the base as named.
        let walkRoot = URL(fileURLWithPath: realPath(base))
        let rootPrefix = walkRoot.path == "/" ? "/" : walkRoot.path + "/"
        let displayPrefix = base == "/" ? "/" : base + "/"
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let walker = FileManager.default.enumerator(
            at: walkRoot, includingPropertiesForKeys: [.isDirectoryKey], options: options,
            errorHandler: { _, _ in true }) else { throw FileBrowserError.noAccess }
        let deadline = Date().addingTimeInterval(timeLimit)
        var visited = 0
        while let url = walker.nextObject() as? URL {
            visited += 1
            if visited % 256 == 0 {
                if isCancelled() { break }
                if Date() >= deadline { result.timedOut = true; break }
            }
            let realPath = url.path
            guard realPath.hasPrefix(rootPrefix) else { continue }
            let path = displayPrefix + realPath.dropFirst(rootPrefix.count)
            if base == "/", rootSearchSkips.contains(path) { walker.skipDescendants(); continue }
            let name = url.lastPathComponent
            guard name.range(of: needle, options: .caseInsensitive) != nil,
                  var found = entry(path: path, name: name) else { continue }
            found.parent = (path as NSString).deletingLastPathComponent
            result.entries.append(found)
            if result.entries.count >= limit { result.truncated = true; break }
        }
        return result
    }

    /// Home, Desktop, Documents, Downloads, Computer (`/`), then the mounted volumes in
    /// `volumesDir` (a volume that is a link to `/`, the boot disk, is left out).
    static func places(home: String, volumesDir: String = "/Volumes") -> [FilePlace] {
        var places = [FilePlace(name: "Home", path: home)]
        for folder in ["Desktop", "Documents", "Downloads"] {
            places.append(FilePlace(name: folder, path: join(home, folder)))
        }
        places.append(FilePlace(name: "Computer", path: "/"))
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: volumesDir)) ?? []
        for name in volumes.filter({ !isHidden($0) }).sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            let path = join(volumesDir, name)
            if URL(fileURLWithPath: path).resolvingSymlinksInPath().path == "/" { continue }
            places.append(FilePlace(name: name, path: path))
        }
        return places
    }
}

// MARK: Download plan (D47)

/// One file or folder of a zip, at `archivePath` (relative, `/`-separated, folders end in `/`).
struct ZipSource: Equatable, Sendable {
    var archivePath: String
    /// The file read at stream time; nil for a folder entry.
    var fileURL: URL?
    var size: Int64
    var modified: Date
    var mode: UInt16
}

enum DownloadPlan: Equatable, Sendable {
    /// One file, sent as is.
    case file(URL, name: String, size: Int64)
    /// Several items or any folder, sent as one streamed zip.
    case zip(name: String, sources: [ZipSource], totalBytes: Int64)

    var fileName: String {
        switch self {
        case .file(_, let name, _): return name
        case .zip(let name, _, _): return name
        }
    }
}

enum DownloadPlanner {
    /// The total of a download (files' sizes, before compression).
    static let maxBytes: Int64 = 2 << 30
    /// Files in one zip; bounds the pre-scan and the zip's central directory.
    static let maxFiles = 100_000
    /// Paths in one request.
    static let maxPaths = 1000

    /// Checks the client's absolute paths (standardized, symlinks resolved for reading, must
    /// exist and be readable) and pre-scans folders. One file is sent as is; anything else
    /// becomes a zip whose top level holds each selected item under its name.
    static func plan(paths: [String], home: String, now: Date = Date(),
                     maxBytes: Int64 = maxBytes, maxFiles: Int = maxFiles) throws -> DownloadPlan {
        guard !paths.isEmpty, paths.count <= maxPaths else { throw FileBrowserError.badPath }
        var items: [(name: String, real: URL, dir: Bool, parent: String)] = []
        for raw in paths {
            guard let path = FileBrowser.resolve(raw, home: home), path != "/" else { throw FileBrowserError.badPath }
            let real = URL(fileURLWithPath: FileBrowser.realPath(path))
            var st = stat()
            guard stat(real.path, &st) == 0 else { throw FileBrowser.errorFromErrno(errno) }
            let dir = (st.st_mode & S_IFMT) == S_IFDIR
            guard access(real.path, dir ? R_OK | X_OK : R_OK) == 0 else { throw FileBrowserError.noAccess }
            items.append(((path as NSString).lastPathComponent, real, dir, (path as NSString).deletingLastPathComponent))
        }
        if items.count == 1, let only = items.first, !only.dir {
            let size = (try? only.real.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard size <= maxBytes else { throw FileBrowserError.tooLarge }
            return .file(only.real, name: only.name, size: size)
        }
        var sources: [ZipSource] = []
        var total: Int64 = 0
        var fileCount = 0
        var usedNames: Set<String> = []
        for item in items {
            let top = uniqueName(item.name, used: &usedNames)
            if item.dir {
                try addFolder(item.real, as: top, into: &sources, total: &total, files: &fileCount,
                              maxBytes: maxBytes, maxFiles: maxFiles)
            } else if let source = fileSource(item.real, as: top) {
                total += source.size
                fileCount += 1
                sources.append(source)
            }
            guard total <= maxBytes, fileCount <= maxFiles else { throw FileBrowserError.tooLarge }
        }
        return .zip(name: zipName(items.map { ($0.name, $0.dir, $0.parent) }, now: now), sources: sources, totalBytes: total)
    }

    /// One folder: "<folder>.zip"; several items from one folder other than `/`:
    /// "<that folder>.zip"; otherwise "download-<yyyyMMdd-HHmmss>.zip".
    static func zipName(_ items: [(name: String, dir: Bool, parent: String)], now: Date,
                        timeZone: TimeZone = .current) -> String {
        if items.count == 1, let only = items.first { return only.name + ".zip" }
        let parents = Set(items.map(\.parent))
        if parents.count == 1, let parent = parents.first, parent != "/" {
            return (parent as NSString).lastPathComponent + ".zip"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "download-\(f.string(from: now)).zip"
    }

    /// Two selected items with the same name (from different folders) get "name 2", "name 3".
    private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var n = 2
        while used.contains(candidate) {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            candidate = ext.isEmpty ? "\(name) \(n)" : "\(stem) \(n).\(ext)"
            n += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func fileSource(_ url: URL, as archivePath: String) -> ZipSource? {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, access(url.path, R_OK) == 0 else { return nil }
        return ZipSource(archivePath: archivePath, fileURL: url, size: Int64(st.st_size),
                         modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                         mode: UInt16(st.st_mode & 0o7777))
    }

    /// The folder and everything in it, hidden files included. Symlinked files are read
    /// through the link; symlinked folders are not entered (no loops). Unreadable files and
    /// folders are left out.
    private static func addFolder(_ root: URL, as top: String, into sources: inout [ZipSource], total: inout Int64,
                                  files: inout Int, maxBytes: Int64, maxFiles: Int) throws {
        var st = stat()
        let rootModified = stat(root.path, &st) == 0 ? Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)) : Date()
        sources.append(ZipSource(archivePath: top + "/", fileURL: nil, size: 0, modified: rootModified, mode: 0o755))
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [],
            errorHandler: { _, _ in true }) else { return }
        let prefix = root.path == "/" ? "/" : root.path + "/"
        while let url = walker.nextObject() as? URL {
            let path = url.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = top + "/" + path.dropFirst(prefix.count)
            var ls = stat()
            guard lstat(path, &ls) == 0 else { continue }
            switch ls.st_mode & S_IFMT {
            case S_IFDIR:
                guard access(path, R_OK | X_OK) == 0 else { walker.skipDescendants(); continue }
                sources.append(ZipSource(archivePath: relative + "/", fileURL: nil, size: 0,
                                         modified: Date(timeIntervalSince1970: TimeInterval(ls.st_mtimespec.tv_sec)),
                                         mode: UInt16(ls.st_mode & 0o7777)))
            case S_IFREG, S_IFLNK:
                guard let source = fileSource(url, as: relative) else { continue }
                sources.append(source)
                total += source.size
                files += 1
                guard total <= maxBytes, files <= maxFiles else { throw FileBrowserError.tooLarge }
            default:
                continue
            }
        }
    }
}

// MARK: One-time download tokens (D47)

/// A download plan waits here for its `GET /download/<token>`: each token works once, within
/// `lifetime` seconds.
struct DownloadTokenStore: Sendable {
    static let lifetime: TimeInterval = 60

    private var plans: [String: (plan: DownloadPlan, expires: Date)] = [:]

    mutating func issue(_ plan: DownloadPlan, now: Date = Date()) -> String {
        plans = plans.filter { $0.value.expires > now }
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        plans[token] = (plan, now.addingTimeInterval(Self.lifetime))
        return token
    }

    /// The plan, removed so the token cannot be used again; nil if unknown or expired.
    mutating func take(_ token: String, now: Date = Date()) -> DownloadPlan? {
        guard let entry = plans.removeValue(forKey: token), entry.expires > now else { return nil }
        return entry.plan
    }
}

/// `attachment` with an ASCII fallback `filename` and the exact UTF-8 name in `filename*`
/// (RFC 6266, RFC 5987).
func contentDisposition(fileName: String) -> String {
    let fallback = String(fileName.unicodeScalars.map { s -> Character in
        s.isASCII && s.value >= 0x20 && s.value != 0x7F && s != "\"" && s != "\\" ? Character(s) : "_"
    })
    let attrChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&+-.^_`|~".utf8)
    let encoded = fileName.utf8.map { attrChars.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    return "attachment; filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
}
