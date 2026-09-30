import Foundation
import Testing
@testable import MacWindowRemote

/// D47: folder listing, file-name search, the download plan, one-time tokens, and the
/// Content-Disposition header. Everything runs in a fresh temporary folder.
@Suite struct FileBrowserTests {
    /// A temporary tree; `home` stands in for the home folder.
    final class Tree {
        let root: String
        init() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("mwr-files-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // /var → /private/var: use the real path, as the server does after resolving.
            root = FileBrowser.realPath(url.path)
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }

        func file(_ relative: String, _ contents: String = "x") throws {
            let path = root + "/" + relative
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        }

        func dir(_ relative: String) throws {
            try FileManager.default.createDirectory(atPath: root + "/" + relative, withIntermediateDirectories: true)
        }
    }

    // MARK: Paths

    @Test func resolvesTildeAndStandardizes() {
        #expect(FileBrowser.resolve("~", home: "/home/u") == "/home/u")
        #expect(FileBrowser.resolve("~/Desktop/", home: "/home/u") == "/home/u/Desktop")
        #expect(FileBrowser.resolve("/a/b/../c/./d", home: "/h") == "/a/c/d")
        #expect(FileBrowser.resolve("/", home: "/h") == "/")
        #expect(FileBrowser.resolve("relative/path", home: "/h") == nil)
        #expect(FileBrowser.resolve("~other", home: "/h") == nil)
        #expect(FileBrowser.resolve("", home: "/h") == nil)
    }

    // MARK: Listing

    @Test func listsFoldersFirstThenNamesCaseInsensitively() throws {
        let t = try Tree()
        try t.file("b.txt", "12345")
        try t.file("A.txt")
        try t.file("c.txt")
        try t.dir("zeta")
        try t.dir("Beta")
        let listing = try FileBrowser.list(path: t.root, home: "/h", showHidden: false)
        #expect(listing.entries.map(\.name) == ["Beta", "zeta", "A.txt", "b.txt", "c.txt"])
        #expect(listing.entries[0].dir && listing.entries[0].size == nil)
        #expect(listing.entries[3].size == 5)
        #expect(listing.entries[3].path == t.root + "/b.txt")
        #expect(listing.entries[3].mtime != nil)
        #expect(!listing.truncated)
    }

    @Test func hidesDotFilesUnlessShown() throws {
        let t = try Tree()
        try t.file(".secret")
        try t.dir(".cache")
        try t.file("visible")
        #expect(try FileBrowser.list(path: t.root, home: "/h", showHidden: false).entries.map(\.name) == ["visible"])
        #expect(try FileBrowser.list(path: t.root, home: "/h", showHidden: true).entries.map(\.name) == [".cache", ".secret", "visible"])
    }

    @Test func capsTheListingAndReportsTheTotal() throws {
        let t = try Tree()
        for i in 0..<12 { try t.file(String(format: "f%02d", i)) }
        let listing = try FileBrowser.list(path: t.root, home: "/h", showHidden: false, limit: 10)
        #expect(listing.entries.count == 10)
        #expect(listing.total == 12)
        #expect(listing.truncated)
        #expect(listing.entries.last?.name == "f09")
    }

    @Test func followsSymlinksAndReportsErrors() throws {
        let t = try Tree()
        try t.file("real/inside.txt")
        try FileManager.default.createSymbolicLink(atPath: t.root + "/link", withDestinationPath: t.root + "/real")
        try FileManager.default.createSymbolicLink(atPath: t.root + "/broken", withDestinationPath: t.root + "/missing")
        let top = try FileBrowser.list(path: t.root, home: "/h", showHidden: false)
        let link = try #require(top.entries.first { $0.name == "link" })
        #expect(link.dir && link.link)
        let broken = try #require(top.entries.first { $0.name == "broken" })
        #expect(!broken.dir && broken.link && broken.size == nil)
        let through = try FileBrowser.list(path: t.root + "/link", home: "/h", showHidden: false)
        #expect(through.path == t.root + "/link")
        #expect(through.entries.map(\.path) == [t.root + "/link/inside.txt"])
        #expect(throws: FileBrowserError.notFound) { try FileBrowser.list(path: t.root + "/nope", home: "/h", showHidden: false) }
        #expect(throws: FileBrowserError.notADirectory) { try FileBrowser.list(path: t.root + "/real/inside.txt", home: "/h", showHidden: false) }
        #expect(throws: FileBrowserError.badPath) { try FileBrowser.list(path: "real", home: "/h", showHidden: false) }
    }

    @Test func unreadableFolderIsNoAccess() throws {
        let t = try Tree()
        try t.dir("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: t.root + "/locked")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: t.root + "/locked") }
        #expect(throws: FileBrowserError.noAccess) { try FileBrowser.list(path: t.root + "/locked", home: "/h", showHidden: false) }
    }

    @Test func placesStartAtHomeAndListVolumes() throws {
        let t = try Tree()
        try t.dir("Volumes/Backup")
        try t.dir("Volumes/.hidden")
        try FileManager.default.createSymbolicLink(atPath: t.root + "/Volumes/Macintosh HD", withDestinationPath: "/")
        let places = FileBrowser.places(home: "/home/u", volumesDir: t.root + "/Volumes")
        #expect(places.map(\.name) == ["Home", "Desktop", "Documents", "Downloads", "Computer", "Backup"])
        #expect(places[1].path == "/home/u/Desktop")
        #expect(places[4].path == "/")
    }

    // MARK: Search

    @Test func searchFindsNameSubstringsCaseInsensitively() throws {
        let t = try Tree()
        try t.file("Report-2024.pdf")
        try t.file("sub/deeper/annual REPORT.txt")
        try t.file("sub/other.txt")
        try t.dir("reports")
        let r = try FileBrowser.search(base: t.root, query: "report", home: "/h", showHidden: false)
        #expect(Set(r.entries.map(\.name)) == ["Report-2024.pdf", "annual REPORT.txt", "reports"])
        let deep = try #require(r.entries.first { $0.name == "annual REPORT.txt" })
        #expect(deep.parent == t.root + "/sub/deeper")
        #expect(deep.path == t.root + "/sub/deeper/annual REPORT.txt")
        #expect(!r.truncated && !r.timedOut)
    }

    @Test func searchUsesTheBasePathWithTilde() throws {
        let t = try Tree()
        try t.file("a/match.txt")
        try t.file("b/match.txt")
        let r = try FileBrowser.search(base: "~/a", query: "match", home: t.root, showHidden: false)
        #expect(r.base == t.root + "/a")
        #expect(r.entries.map(\.path) == [t.root + "/a/match.txt"])
    }

    @Test func searchSkipsHiddenAndPackageContents() throws {
        let t = try Tree()
        try t.file(".hidden/match-in-hidden.txt")
        try t.file(".match-dot")
        try t.file("Thing.app/Contents/match-in-package.txt")
        try t.file("visible/match.txt")
        let r = try FileBrowser.search(base: t.root, query: "match", home: "/h", showHidden: false)
        #expect(r.entries.map(\.name) == ["match.txt"])
        let shown = try FileBrowser.search(base: t.root, query: "match", home: "/h", showHidden: true)
        #expect(Set(shown.entries.map(\.name)) == ["match-in-hidden.txt", ".match-dot", "match.txt"])
    }

    @Test func searchStopsAtTheCap() throws {
        let t = try Tree()
        for i in 0..<8 { try t.file("hit\(i).txt") }
        let r = try FileBrowser.search(base: t.root, query: "HIT", home: "/h", showHidden: false, limit: 5)
        #expect(r.entries.count == 5)
        #expect(r.truncated)
    }

    @Test func searchFromRootSkipsSystemFolders() {
        #expect(FileBrowser.rootSearchSkips == ["/System", "/private", "/dev"])
    }

    // MARK: Download plan

    @Test func oneFileIsSentAsIs() throws {
        let t = try Tree()
        try t.file("My Report.pdf", "hello")
        let plan = try DownloadPlanner.plan(paths: [t.root + "/My Report.pdf"], home: "/h")
        #expect(plan == .file(URL(fileURLWithPath: t.root + "/My Report.pdf"), name: "My Report.pdf", size: 5))
    }

    @Test func foldersAndSeveralItemsBecomeOneZip() throws {
        let t = try Tree()
        try t.file("Project/a.txt", "aa")
        try t.file("Project/sub/b.txt", "bbb")
        try t.file("Project/.env", "c")
        try t.file("loose.txt", "dddd")
        guard case .zip(let name, let sources, let total) = try DownloadPlanner.plan(paths: [t.root + "/Project"], home: "/h") else {
            Issue.record("not a zip"); return
        }
        #expect(name == "Project.zip")
        #expect(total == 6)
        #expect(Set(sources.map(\.archivePath)) == ["Project/", "Project/a.txt", "Project/sub/", "Project/sub/b.txt", "Project/.env"])
        guard case .zip(let name2, let sources2, _) = try DownloadPlanner.plan(
            paths: [t.root + "/loose.txt", t.root + "/Project/a.txt"], home: "/h") else { Issue.record("not a zip"); return }
        #expect(name2.hasPrefix("download-") && name2.hasSuffix(".zip"))
        #expect(sources2.map(\.archivePath) == ["loose.txt", "a.txt"])
        guard case .zip(let name3, _, _) = try DownloadPlanner.plan(
            paths: [t.root + "/Project/a.txt", t.root + "/Project/sub"], home: "/h") else { Issue.record("not a zip"); return }
        #expect(name3 == "Project.zip")
    }

    @Test func zipNames() {
        let now = Date(timeIntervalSince1970: 0)
        let utc = TimeZone(identifier: "UTC")!
        #expect(DownloadPlanner.zipName([("Photos", true, "/x")], now: now) == "Photos.zip")
        #expect(DownloadPlanner.zipName([("a", false, "/x/Docs"), ("b", true, "/x/Docs")], now: now) == "Docs.zip")
        #expect(DownloadPlanner.zipName([("a", false, "/x"), ("b", false, "/y")], now: now, timeZone: utc) == "download-19700101-000000.zip")
        #expect(DownloadPlanner.zipName([("a", false, "/"), ("b", false, "/")], now: now, timeZone: utc) == "download-19700101-000000.zip")
    }

    @Test func downloadChecksPathsAndTheSizeCap() throws {
        let t = try Tree()
        try t.file("big.bin", String(repeating: "x", count: 100))
        try t.file("dir/small.bin", "x")
        #expect(throws: FileBrowserError.tooLarge) {
            try DownloadPlanner.plan(paths: [t.root + "/big.bin"], home: "/h", maxBytes: 99)
        }
        #expect(throws: FileBrowserError.tooLarge) {
            try DownloadPlanner.plan(paths: [t.root + "/big.bin", t.root + "/dir"], home: "/h", maxBytes: 100)
        }
        #expect(throws: FileBrowserError.tooLarge) {
            try DownloadPlanner.plan(paths: [t.root + "/dir"], home: "/h", maxFiles: 0)
        }
        #expect(throws: FileBrowserError.notFound) { try DownloadPlanner.plan(paths: [t.root + "/gone"], home: "/h") }
        #expect(throws: FileBrowserError.badPath) { try DownloadPlanner.plan(paths: ["relative"], home: "/h") }
        #expect(throws: FileBrowserError.badPath) { try DownloadPlanner.plan(paths: ["/"], home: "/h") }
        #expect(throws: FileBrowserError.badPath) { try DownloadPlanner.plan(paths: [], home: "/h") }
    }

    @Test func downloadReadsThroughASymlink() throws {
        let t = try Tree()
        try t.file("target.txt", "abc")
        try FileManager.default.createSymbolicLink(atPath: t.root + "/alias.txt", withDestinationPath: t.root + "/target.txt")
        let plan = try DownloadPlanner.plan(paths: [t.root + "/alias.txt"], home: "/h")
        #expect(plan == .file(URL(fileURLWithPath: t.root + "/target.txt"), name: "alias.txt", size: 3))
    }

    // MARK: Tokens

    @Test func tokenWorksOnceAndExpires() {
        var store = DownloadTokenStore()
        let plan = DownloadPlan.file(URL(fileURLWithPath: "/tmp/x"), name: "x", size: 1)
        let now = Date(timeIntervalSince1970: 1000)
        let a = store.issue(plan, now: now)
        #expect(a.count == 48)
        #expect(store.take(a, now: now.addingTimeInterval(5)) == plan)
        #expect(store.take(a, now: now.addingTimeInterval(6)) == nil)
        let b = store.issue(plan, now: now)
        #expect(b != a)
        #expect(store.take(b, now: now.addingTimeInterval(DownloadTokenStore.lifetime + 1)) == nil)
        #expect(store.take("unknown", now: now) == nil)
    }

    // MARK: Content-Disposition

    @Test func contentDispositionEncodesUTF8Names() {
        #expect(contentDisposition(fileName: "report.pdf") == #"attachment; filename="report.pdf"; filename*=UTF-8''report.pdf"#)
        #expect(contentDisposition(fileName: "My Report.pdf") == #"attachment; filename="My Report.pdf"; filename*=UTF-8''My%20Report.pdf"#)
        #expect(contentDisposition(fileName: "資料 \"a\".zip")
                == #"attachment; filename="__ _a_.zip"; filename*=UTF-8''%E8%B3%87%E6%96%99%20%22a%22.zip"#)
        #expect(contentDisposition(fileName: "a;b%c'd.txt") == #"attachment; filename="a;b%c'd.txt"; filename*=UTF-8''a%3Bb%25c%27d.txt"#)
    }
}
