import Foundation
import Testing
@testable import MacWindowRemote

/// D40: the Apps tab list from the Dock's `persistent-apps` and the running apps, and the
/// id allowlist that gates launching and icons.
@Suite struct AppCatalogTests {
    static func tile(_ url: String?) -> [String: Any] {
        var fileData: [String: Any] = ["_CFURLStringType": 15]
        if let url { fileData["_CFURLString"] = url }
        return ["tile-data": ["file-data": fileData, "file-label": "x"], "tile-type": "file-tile"]
    }

    static let safari = URL(fileURLWithPath: "/Applications/Safari.app")
    static let notes = URL(fileURLWithPath: "/System/Applications/Notes.app")
    static let music = URL(fileURLWithPath: "/System/Applications/Music.app")
    static let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    @Test func dockAppsInOrderSkippingMissingMalformedAndRepeats() {
        let plist: [[String: Any]] = [
            Self.tile("file:///Applications/Safari.app/"),
            Self.tile("file:///Applications/Gone.app/"),          // deleted bundle
            Self.tile(nil),                                       // no URL
            ["tile-type": "spacer-tile", "tile-data": [String: Any]()],
            Self.tile("https://example.com/"),                    // not a file URL
            Self.tile("file:///System/Applications/Notes.app/"),
            Self.tile("file:///Applications/Safari.app"),          // same bundle again
        ]
        let exists: (URL) -> Bool = { !$0.path.contains("Gone") }
        let urls = AppCatalog.dockAppURLs(persistentApps: plist, exists: exists)
        #expect(urls.map(\.path) == [Self.safari.path, Self.notes.path])
        #expect(AppCatalog.dockAppURLs(persistentApps: "not an array", exists: exists).isEmpty)
        #expect(AppCatalog.dockAppURLs(persistentApps: nil, exists: exists).isEmpty)
    }

    @Test func runningAppsFollowTheDockWithoutRepeats() {
        let merged = AppCatalog.merge(dock: [Self.safari, Self.notes], running: [Self.terminal, Self.notes, Self.music])
        #expect(merged.map(\.path) == [Self.safari.path, Self.notes.path, Self.terminal.path, Self.music.path])
    }

    @Test func listMarksRunningAppsAndIdsAreStable() {
        let catalog = AppCatalog()
        let items = catalog.makeList(dock: [Self.safari, Self.notes], running: [Self.notes, Self.terminal]) {
            AppCatalog.displayName(of: $0)
        }
        #expect(items.map(\.name) == ["Safari", "Notes", "Terminal"])
        #expect(items.map(\.running) == [false, true, true])
        #expect(Set(items.map(\.id)).count == 3)
        // The id does not depend on the Dock's trailing slash.
        #expect(AppCatalog.id(for: URL(string: "file:///Applications/Safari.app/")!) == AppCatalog.id(for: Self.safari))
        #expect(items[0].id == AppCatalog.id(for: Self.safari))
    }

    @Test func onlyIdsOfTheLastListResolve() {
        let catalog = AppCatalog()
        let first = catalog.makeList(dock: [Self.safari], running: [Self.music]) { _ in "" }
        #expect(catalog.url(for: first[0].id)?.path == Self.safari.path)
        #expect(catalog.url(for: first[1].id)?.path == Self.music.path)
        #expect(catalog.url(for: "0123456789abcdef") == nil)
        #expect(catalog.url(for: "/Applications/Safari.app") == nil)
        #expect(catalog.icon(for: "0123456789abcdef") == nil)
        // Music quit and is not in the Dock: its id is no longer allowed.
        _ = catalog.makeList(dock: [Self.safari], running: []) { _ in "" }
        #expect(catalog.url(for: first[1].id) == nil)
        #expect(catalog.url(for: first[0].id) != nil)
    }

    @Test func protocolMessages() throws {
        #expect(try ClientMessage.decode(Data(#"{"t":"apps.list"}"#.utf8), on: .socket) == .appsList)
        #expect(try ClientMessage.decode(Data(#"{"t":"app.open","id":"00ab"}"#.utf8), on: .socket) == .appOpen(id: "00ab"))
        #expect(throws: ProtocolError.invalidValue("id")) { try ClientMessage.decode(Data(#"{"t":"app.open"}"#.utf8)) }
        #expect(throws: ProtocolError.invalidValue("id")) { try ClientMessage.decode(Data(#"{"t":"app.open","id":""}"#.utf8)) }
        #expect(throws: ProtocolError.wrongChannel("app.open")) {
            try ClientMessage.decode(Data(#"{"t":"app.open","id":"00ab"}"#.utf8), on: .control)
        }
        let json = ServerMessage.apps([AppItem(id: "00ab", name: "Notes", running: true)]).jsonString()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["t"] as? String == "apps")
        let items = try #require(object["items"] as? [[String: Any]])
        #expect(items.first?["id"] as? String == "00ab")
        #expect(items.first?["name"] as? String == "Notes")
        #expect(items.first?["running"] as? Bool == true)
    }
}
