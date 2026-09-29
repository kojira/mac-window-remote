import AppKit

/// One app in the phone's Apps tab (DESIGN.md D40).
struct AppItem: Codable, Equatable, Sendable {
    /// Opaque token for the bundle path; the phone sends it back, never a path.
    var id: String
    var name: String
    var running: Bool
}

/// The Apps tab list: the Dock's persistent apps, then other running regular apps (D40). The
/// last produced list is the allowlist for launching and for icons.
final class AppCatalog: @unchecked Sendable {
    /// A running regular app, as the list needs it.
    struct RunningApp: Equatable {
        var bundleURL: URL
        var pid: pid_t
    }

    private let lock = NSLock()
    /// id → bundle URL of the list produced last.
    private var allowed: [String: URL] = [:]
    private var icons: [String: Data] = [:]

    // MARK: Pure parts

    /// Bundle URLs of the Dock's `persistent-apps` tiles, in Dock order: tiles without a
    /// `file://` `_CFURLString`, bundles that do not exist, and repeats are skipped.
    static func dockAppURLs(persistentApps: Any?, exists: (URL) -> Bool) -> [URL] {
        guard let tiles = persistentApps as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var urls: [URL] = []
        for tile in tiles {
            guard let tileData = tile["tile-data"] as? [String: Any],
                  let fileData = tileData["file-data"] as? [String: Any],
                  let string = fileData["_CFURLString"] as? String,
                  let url = URL(string: string), url.isFileURL else { continue }
            let standardized = url.standardizedFileURL
            guard seen.insert(key(standardized)).inserted, exists(standardized) else { continue }
            urls.append(standardized)
        }
        return urls
    }

    /// The Dock's apps followed by the running apps not in the Dock, each once.
    static func merge(dock: [URL], running: [URL]) -> [URL] {
        var seen = Set(dock.map(key))
        var urls = dock
        for url in running.map(\.standardizedFileURL) where seen.insert(key(url)).inserted {
            urls.append(url)
        }
        return urls
    }

    /// Stable opaque id of a bundle path: 64-bit FNV-1a of its UTF-8 bytes, in hex.
    static func id(for url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key(url).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// Bundle paths compare without a trailing slash (the Dock stores `…/Safari.app/`).
    private static func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func displayName(of url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Builds the list and makes it the allowlist.
    func makeList(dock: [URL], running: [URL], name: (URL) -> String) -> [AppItem] {
        let runningKeys = Set(running.map(Self.key))
        var map: [String: URL] = [:]
        var items: [AppItem] = []
        for url in Self.merge(dock: dock, running: running) {
            let id = Self.id(for: url)
            guard map[id] == nil else { continue }
            map[id] = url
            items.append(AppItem(id: id, name: name(url), running: runningKeys.contains(Self.key(url))))
        }
        lock.withLock {
            allowed = map
            icons = icons.filter { map[$0.key] != nil }
        }
        return items
    }

    /// The bundle URL of an id in the last list, or nil (never launch anything else).
    func url(for id: String) -> URL? {
        lock.withLock { allowed[id] }
    }

    // MARK: Mac

    /// Reads the Dock and the running apps, and makes the list.
    func list() -> [AppItem] {
        let dockValue = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString)
        let dock = Self.dockAppURLs(persistentApps: dockValue) { FileManager.default.fileExists(atPath: $0.path) }
        return makeList(dock: dock, running: Self.runningApps().map(\.bundleURL), name: Self.displayName(of:))
    }

    /// Running regular apps with a bundle, in launch order, except this app.
    static func runningApps() -> [RunningApp] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != own,
                  let url = app.bundleURL else { return nil }
            return RunningApp(bundleURL: url.standardizedFileURL, pid: app.processIdentifier)
        }
    }

    static let iconPixels = 128

    /// The PNG icon of an allowed id, drawn at 128 px and cached; nil for an unknown id.
    func icon(for id: String) -> Data? {
        guard let url = url(for: id) else { return nil }
        if let cached = lock.withLock({ icons[id] }) { return cached }
        guard let png = Self.renderIcon(NSWorkspace.shared.icon(forFile: url.path)) else { return nil }
        lock.withLock { icons[id] = png }
        return png
    }

    private static func renderIcon(_ image: NSImage) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: iconPixels, pixelsHigh: iconPixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: iconPixels, height: iconPixels)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: iconPixels, height: iconPixels))
        context.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }
}
