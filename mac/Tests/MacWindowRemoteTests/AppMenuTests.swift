import Foundation
import Testing
@testable import MacWindowRemote

/// A menu bar made of plain values; `pressed` records what was pressed.
private final class FakeMenu: MenuSource {
    final class Item {
        var info: MenuElementInfo
        var children: [Item]
        var pressOK = true
        init(_ title: String, enabled: Bool = true, mark: String? = nil, char: String? = nil, mods: Int? = nil,
             key: Int? = nil, glyph: Int? = nil, _ children: [Item] = []) {
            info = MenuElementInfo(title: title, enabled: enabled, markChar: mark, cmdChar: char, cmdModifiers: mods,
                                   cmdVirtualKey: key, cmdGlyph: glyph)
            self.children = children
        }
    }
    var bar: [Item]?
    var pressed: [String] = []
    var reads = 0
    init(_ bar: [Item]?) { self.bar = bar }

    func menuBarItems() -> [Item]? { bar }
    func info(_ element: Item) -> MenuElementInfo { reads += 1; return element.info }
    func submenuItems(_ element: Item) -> [Item] { element.children }
    func press(_ element: Item) -> Bool { pressed.append(element.info.title); return element.pressOK }
}

private typealias I = FakeMenu.Item
private func sep() -> I { I("") }

/// The Apple menu, then File and Edit, like a typical app.
private func sampleBar() -> [I] {
    [
        I("Apple", [I("About This Mac")]),
        I("File", [
            I("New", char: "N"),
            I("Open…", char: "O"),
            sep(),
            I("Open Recent", [I("a.txt"), I("b.txt")]),
            sep(), sep(),
            I("Save As…", char: "S", mods: 1),
            I("Close", enabled: false, char: "W"),
            sep(),
        ]),
        I("View", [I("Show Sidebar", mark: "✓", char: "S", mods: 6), I("Mixed", mark: "-")]),
    ]
}

@Suite struct AppMenuTests {
    @Test func treeSkipsTheAppleMenuAndBuildsIdsFromLiveIndices() throws {
        let listing = try #require(MenuTree.build(FakeMenu(sampleBar())))
        #expect(!listing.truncated)
        #expect(listing.menus.map(\.title) == ["File", "View"])
        #expect(listing.menus.map(\.id) == ["1", "2"])
        let file = try #require(listing.menus[0].items)
        // Leading/doubled/trailing separators collapse; separators have no id.
        #expect(file.map { $0.isSeparator ? "—" : $0.title } == ["New", "Open…", "—", "Open Recent", "—", "Save As…", "Close"])
        #expect(file[0].id == "1.0")
        #expect(file[3].id == "1.3")
        #expect(file[3].items?.map(\.id) == ["1.3.0", "1.3.1"])
        #expect(file[5].id == "1.6")
        #expect(file[6].enabled == false)
        #expect(file[0].items == nil)
    }

    @Test func marksAndShortcuts() throws {
        let listing = try #require(MenuTree.build(FakeMenu(sampleBar())))
        let file = try #require(listing.menus[0].items)
        #expect(file[0].shortcut == "⌘N")
        #expect(file[5].shortcut == "⇧⌘S")
        let view = try #require(listing.menus[1].items)
        #expect(view[0].mark == .check)
        #expect(view[0].shortcut == "⌃⌥⌘S")
        #expect(view[1].mark == .mixed)
        #expect(view[1].shortcut == nil)
    }

    @Test func shortcutFormatting() {
        func f(_ char: String? = nil, mods: Int? = nil, key: Int? = nil, glyph: Int? = nil) -> String? {
            MenuShortcut.format(MenuElementInfo(title: "x", cmdChar: char, cmdModifiers: mods, cmdVirtualKey: key, cmdGlyph: glyph))
        }
        #expect(f("q") == "⌘Q")
        #expect(f("z", mods: 1) == "⇧⌘Z")
        #expect(f("f", mods: 4 | 8) == "⌃F")        // no ⌘ bit
        #expect(f("\u{F704}") == "⌘F1")
        #expect(f("\u{F70B}", mods: 2) == "⌥⌘F8")
        #expect(f("\r") == "⌘↩")
        #expect(f("\u{F702}", mods: 4) == "⌃⌘←")
        #expect(f(glyph: 0x17) == "⌘⌫")
        #expect(f(mods: 8, key: 53) == "⎋")
        #expect(f() == nil)
        #expect(f("\u{F8FF}") == nil)               // an unknown private-use key shows nothing
        #expect(f("\u{1}") == nil)
    }

    @Test func encodingOmitsTheIdOfSeparators() throws {
        let listing = try #require(MenuTree.build(FakeMenu([I("Apple"), I("Edit", [I("Undo", char: "Z"), sep(), I("Cut")])])))
        let json = String(decoding: try JSONEncoder().encode(listing.menus), as: UTF8.self)
        #expect(json.contains(#"{"sep":true}"#))
        #expect(json.contains(#""id":"1.0""#))
        #expect(json.contains(#""shortcut":"⌘Z""#))
        let message = ServerMessage.menu(gen: 3, windowId: 7, listing: listing).jsonString()
        #expect(message.hasPrefix(#"{"#) && message.contains(#""t":"menu""#) && message.contains(#""gen":3"#))
    }

    @Test func depthCapLeavesAnEmptySubmenuAndMarksTruncated() throws {
        var deep = I("leaf")
        for i in 0..<6 { deep = I("level\(i)", [deep]) }
        let listing = try #require(MenuTree.build(FakeMenu([I("Apple"), I("Deep", [deep])])))
        #expect(listing.truncated)
        var node = listing.menus[0]
        var depth = 0
        while let child = node.items?.first { node = child; depth += 1 }
        #expect(depth == MenuTree.maxDepth)
        #expect(node.items == [])
    }

    @Test func itemCapStopsReading() throws {
        let many = (0..<400).map { I("item \($0)") }
        let bar = [I("Apple"), I("A", many), I("B", many), I("C", many)]
        let listing = try #require(MenuTree.build(FakeMenu(bar), maxItems: 500))
        #expect(listing.truncated)
        #expect(listing.leafTitles().count == 500)
        #expect(listing.menus.map(\.title) == ["A", "B"])
    }

    @Test func timeBudgetTruncates() throws {
        let source = FakeMenu(sampleBar())
        let listing = try #require(MenuTree.build(source, expired: { source.reads >= 3 }))
        #expect(listing.truncated)
        #expect(MenuTree.build(FakeMenu(nil)) == nil)
    }

    @Test func idParsing() {
        #expect(MenuTree.path("1.3.0") == [1, 3, 0])
        #expect(MenuTree.path("") == nil)
        #expect(MenuTree.path("1..2") == nil)
        #expect(MenuTree.path("-1") == nil)
        #expect(MenuTree.path("1.a") == nil)
        #expect(MenuTree.path("1.2.3.4.5.6") == nil)
        #expect(MenuTree.path("99999") == nil)
    }

    @Test func pressResolvesThePathWithTitles() throws {
        let source = FakeMenu(sampleBar())
        let leaves = try #require(MenuTree.build(source)).leafTitles()
        #expect(leaves["1.6"] == ["File", "Save As…"])
        #expect(leaves["1.3.1"] == ["File", "Open Recent", "b.txt"])
        #expect(leaves["1.3"] == nil)                     // a submenu is not pressable
        #expect(MenuTree.press(source, path: [1, 3, 1], titles: leaves["1.3.1"]!) == nil)
        #expect(source.pressed == ["b.txt"])
    }

    @Test func pressRejectsAChangedMenu() throws {
        let source = FakeMenu(sampleBar())
        let leaves = try #require(MenuTree.build(source)).leafTitles()
        // An item was inserted above: the index now points at another item.
        source.bar![1].children.insert(I("Duplicate"), at: 0)
        #expect(MenuTree.press(source, path: [1, 6], titles: leaves["1.6"]!) == .menuStale)
        // A submenu title changed.
        source.bar![1].children.remove(at: 0)
        source.bar![1].children[3].info.title = "Recent"
        #expect(MenuTree.press(source, path: [1, 3, 0], titles: leaves["1.3.0"]!) == .menuStale)
        // Out of range, the Apple menu, and wrong title count.
        #expect(MenuTree.press(source, path: [1, 40], titles: ["File", "x"]) == .menuStale)
        #expect(MenuTree.press(source, path: [0, 0], titles: ["Apple", "About This Mac"]) == .menuStale)
        #expect(MenuTree.press(source, path: [1, 0], titles: ["File"]) == .menuStale)
        #expect(source.pressed.isEmpty)
    }

    @Test func pressReportsDisabledAndFailure() throws {
        let source = FakeMenu(sampleBar())
        #expect(MenuTree.press(source, path: [1, 7], titles: ["File", "Close"]) == .menuDisabled)
        source.bar![1].children[0].pressOK = false
        #expect(MenuTree.press(source, path: [1, 0], titles: ["File", "New"]) == .menuFailed)
        #expect(MenuTree.press(FakeMenu(nil), path: [1, 0], titles: ["File", "New"]) == .menuFailed)
        #expect(source.pressed == ["New"])
    }

    @Test func menuMessagesDecode() throws {
        #expect(try ClientMessage.decode(Data(#"{"t":"menu.list"}"#.utf8), on: .socket) == .menuList)
        #expect(try ClientMessage.decode(Data(#"{"t":"menu.press","id":"1.3.0","gen":2}"#.utf8), on: .socket)
                == .menuPress(id: "1.3.0", gen: 2))
        for bad in [#"{"t":"menu.press","id":"1.3.0"}"#, #"{"t":"menu.press","id":"/tmp","gen":1}"#,
                    #"{"t":"menu.press","id":"1","gen":0}"#] {
            #expect(throws: ProtocolError.self) { try ClientMessage.decode(Data(bad.utf8)) }
        }
    }
}
