import Foundation

// The viewed app's menu bar on the phone (DESIGN.md D43). The tree is read and pressed through
// `MenuSource`, so the rules here (separators, caps, shortcuts, title-verified press) are tested
// against a fake; `AXMenuSource` is the Accessibility implementation.

/// What one menu bar item or menu item says about itself.
struct MenuElementInfo: Equatable, Sendable {
    var title: String = ""
    var enabled: Bool = true
    /// `AXMenuItemMarkChar`: "✓" when checked, "-" when mixed.
    var markChar: String?
    /// `AXMenuItemCmdChar`, `AXMenuItemCmdModifiers`, `AXMenuItemCmdVirtualKey`, `AXMenuItemCmdGlyph`.
    var cmdChar: String?
    var cmdModifiers: Int?
    var cmdVirtualKey: Int?
    var cmdGlyph: Int?
}

/// One app's menu bar, read or pressed element by element.
protocol MenuSource {
    associatedtype Element
    /// The menu bar's items, the Apple menu first; nil when the app has no readable menu bar.
    func menuBarItems() -> [Element]?
    func info(_ element: Element) -> MenuElementInfo
    /// The items of the element's submenu; empty when it has none (or it is not populated yet).
    func submenuItems(_ element: Element) -> [Element]
    /// AXPress; false on failure.
    func press(_ element: Element) -> Bool
}

enum MenuMark: String, Codable, Equatable, Sendable {
    case check, mixed
}

/// One row of the tree sent to the phone. `path` holds indices into the live menu bar
/// (`path[0]` ≥ 1, the Apple menu is omitted); a separator has no id.
struct MenuNode: Equatable, Sendable {
    var path: [Int]
    var title: String = ""
    var enabled = true
    var mark: MenuMark?
    var shortcut: String?
    /// nil for a leaf; the submenu's rows otherwise (empty past the depth cap or when unpopulated).
    var items: [MenuNode]?
    var isSeparator = false

    var id: String { MenuTree.id(path) }

    static func separator() -> MenuNode { MenuNode(path: [], isSeparator: true) }
}

extension MenuNode: Encodable {
    private enum Keys: String, CodingKey { case id, title, enabled, mark, shortcut, items, sep }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        if isSeparator {
            try c.encode(true, forKey: .sep)
            return
        }
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(mark, forKey: .mark)
        try c.encodeIfPresent(shortcut, forKey: .shortcut)
        try c.encodeIfPresent(items, forKey: .items)
    }
}

/// The top-level menus of one read; `truncated` when a cap or the time budget cut it short.
struct MenuListing: Equatable, Sendable {
    var menus: [MenuNode]
    var truncated: Bool

    /// Every leaf's id → the titles along its path, which a press must find again (D43).
    func leafTitles() -> [String: [String]] {
        var result: [String: [String]] = [:]
        func walk(_ nodes: [MenuNode], _ titles: [String]) {
            for node in nodes where !node.isSeparator {
                let here = titles + [node.title]
                if let items = node.items { walk(items, here) } else { result[node.id] = here }
            }
        }
        walk(menus, [])
        return result
    }
}

/// The result of `menu.list` in the backend.
enum MenuListOutcome: Equatable, Sendable {
    case listed(MenuListing)
    case failed(ErrorCode)
}

enum MenuTree {
    /// Submenus below a top-level menu are followed this deep.
    static let maxDepth = 4
    /// Rows (separators excluded) in one listing.
    static let maxItems = 500

    static func id(_ path: [Int]) -> String { path.map(String.init).joined(separator: ".") }

    /// "1.4.2" → [1, 4, 2]; nil unless every part is a small non-negative integer.
    static func path(_ id: String) -> [Int]? {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= maxDepth + 1 else { return nil }
        var path: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 4, p.allSatisfy(\.isASCII), let i = Int(p), i >= 0 else { return nil }
            path.append(i)
        }
        return path
    }

    /// Reads the menu bar into a tree, without the Apple menu. `expired` is checked before
    /// each element, so a slow app yields a truncated listing instead of a hang.
    static func build<S: MenuSource>(_ source: S, maxDepth: Int = maxDepth, maxItems: Int = maxItems,
                                     expired: () -> Bool = { false }) -> MenuListing? {
        guard let bar = source.menuBarItems() else { return nil }
        var count = 0
        var truncated = false

        func rows(_ elements: [S.Element], path: [Int], depth: Int) -> [MenuNode] {
            var result: [MenuNode] = []
            for (i, element) in elements.enumerated() {
                guard count < maxItems, !expired() else { truncated = true; break }
                let info = source.info(element)
                let children = source.submenuItems(element)
                if info.title.isEmpty && children.isEmpty {
                    // No leading or doubled separators.
                    if let last = result.last, !last.isSeparator { result.append(.separator()) }
                    continue
                }
                count += 1
                var node = MenuNode(path: path + [i], title: info.title, enabled: info.enabled,
                                    mark: mark(info.markChar), shortcut: MenuShortcut.format(info))
                if !children.isEmpty {
                    node.shortcut = nil
                    node.mark = nil
                    if depth < maxDepth {
                        node.items = rows(children, path: node.path, depth: depth + 1)
                    } else {
                        node.items = []
                        truncated = true
                    }
                }
                result.append(node)
            }
            if result.last?.isSeparator == true { result.removeLast() }
            return result
        }

        var menus: [MenuNode] = []
        // Index 0 is the Apple menu (D43: omitted).
        for (i, element) in bar.enumerated() where i > 0 {
            guard count < maxItems, !expired() else { truncated = true; break }
            let info = source.info(element)
            guard !info.title.isEmpty else { continue }
            let items = rows(source.submenuItems(element), path: [i], depth: 1)
            menus.append(MenuNode(path: [i], title: info.title, enabled: info.enabled, items: items))
        }
        return MenuListing(menus: menus, truncated: truncated)
    }

    static func mark(_ char: String?) -> MenuMark? {
        switch char {
        case "✓", "✔", "√": return .check
        case "-", "–", "—", "−": return .mixed
        default: return nil
        }
    }

    enum PressFailure: Error, Equatable {
        /// The menu bar no longer has this item under the listed titles.
        case stale
        case disabled
        case failed
    }

    /// Finds the element at `path` in the live menu bar, checking the title at every step
    /// against `titles` (what was listed), so a changed menu cannot press another item.
    static func resolve<S: MenuSource>(_ source: S, path: [Int], titles: [String]) -> Result<S.Element, PressFailure> {
        guard !path.isEmpty, path.count == titles.count, path[0] >= 1 else { return .failure(.stale) }
        guard var level = source.menuBarItems() else { return .failure(.failed) }
        for (depth, index) in path.enumerated() {
            guard index < level.count else { return .failure(.stale) }
            let element = level[index]
            let info = source.info(element)
            guard info.title == titles[depth] else { return .failure(.stale) }
            let children = source.submenuItems(element)
            if depth == path.count - 1 {
                guard children.isEmpty else { return .failure(.stale) }
                guard info.enabled else { return .failure(.disabled) }
                return .success(element)
            }
            level = children
        }
        return .failure(.stale)
    }

    /// Resolves and presses; nil on success, else the error code for the phone.
    static func press<S: MenuSource>(_ source: S, path: [Int], titles: [String]) -> ErrorCode? {
        switch resolve(source, path: path, titles: titles) {
        case .failure(.stale): return .menuStale
        case .failure(.disabled): return .menuDisabled
        case .failure(.failed): return .menuFailed
        case .success(let element): return source.press(element) ? nil : .menuFailed
        }
    }
}

/// The shortcut text shown right-aligned in a menu row, e.g. "⌃⌥⇧⌘S".
enum MenuShortcut {
    // AXMenuItemCmdModifiers bits; 0 means ⌘ alone.
    static let shiftBit = 1, optionBit = 2, controlBit = 4, noCommandBit = 8

    static func format(_ info: MenuElementInfo) -> String? {
        guard let key = keyText(info) else { return nil }
        let m = info.cmdModifiers ?? 0
        var s = ""
        if m & controlBit != 0 { s += "⌃" }
        if m & optionBit != 0 { s += "⌥" }
        if m & shiftBit != 0 { s += "⇧" }
        if m & noCommandBit == 0 { s += "⌘" }
        return s + key
    }

    private static func keyText(_ info: MenuElementInfo) -> String? {
        if let c = info.cmdChar, !c.isEmpty {
            if let named = charNames[c] { return named }
            if let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1,
               (0xF704...0xF70F).contains(scalar.value) {
                return "F\(scalar.value - 0xF704 + 1)"
            }
            if let scalar = c.unicodeScalars.first, scalar.value < 0x20 || (0xF700...0xF8FF).contains(scalar.value) {
                return nil
            }
            return c.uppercased()
        }
        if let g = info.cmdGlyph, let named = glyphNames[g] { return named }
        if let k = info.cmdVirtualKey, let named = virtualKeyNames[k] { return named }
        return nil
    }

    private static let charNames: [String: String] = [
        "\r": "↩", "\u{3}": "⌤", "\t": "⇥", " ": "Space", "\u{8}": "⌫", "\u{7F}": "⌫", "\u{1B}": "⎋",
        "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "\u{F728}": "⌦",
        "\u{F729}": "↖", "\u{F72B}": "↘", "\u{F72C}": "⇞", "\u{F72D}": "⇟",
    ]
    /// Carbon menu glyphs (`kMenu…Glyph`), the common ones.
    private static let glyphNames: [Int: String] = [
        0x02: "⇥", 0x04: "⌤", 0x09: "Space", 0x0A: "⌦", 0x0B: "↩", 0x17: "⌫", 0x1B: "⎋",
        0x62: "⇞", 0x64: "←", 0x65: "→", 0x66: "↖", 0x68: "↑", 0x69: "↘", 0x6A: "↓", 0x6B: "⇟",
        0x6F: "F1", 0x70: "F2", 0x71: "F3", 0x72: "F4", 0x73: "F5", 0x74: "F6", 0x75: "F7",
        0x76: "F8", 0x77: "F9", 0x78: "F10", 0x79: "F11", 0x7A: "F12",
    ]
    /// kVK_* codes, the common non-character keys.
    private static let virtualKeyNames: [Int: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
