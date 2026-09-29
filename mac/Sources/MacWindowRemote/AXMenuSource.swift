import ApplicationServices

/// `MenuSource` over Accessibility for one app (D43). A menu bar item or menu item with a
/// submenu has one `AXMenu` child whose children are the items.
struct AXMenuSource: MenuSource {
    /// Each AX message to the app waits at most this long, so a hung app cannot stall a read.
    static let messagingTimeout: Float = 1

    let app: AXUIElement

    init(pid: pid_t) {
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
    }

    func menuBarItems() -> [AXUIElement]? {
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return nil }
        return children(bar)
    }

    func info(_ element: AXUIElement) -> MenuElementInfo {
        MenuElementInfo(
            title: attribute(element, kAXTitleAttribute) ?? "",
            enabled: attribute(element, kAXEnabledAttribute) ?? true,
            markChar: attribute(element, kAXMenuItemMarkCharAttribute),
            cmdChar: attribute(element, kAXMenuItemCmdCharAttribute),
            cmdModifiers: attribute(element, kAXMenuItemCmdModifiersAttribute),
            cmdVirtualKey: attribute(element, kAXMenuItemCmdVirtualKeyAttribute),
            cmdGlyph: attribute(element, kAXMenuItemCmdGlyphAttribute))
    }

    func submenuItems(_ element: AXUIElement) -> [AXUIElement] {
        guard let menu = children(element).first(where: { attribute($0, kAXRoleAttribute) == kAXMenuRole as String }) else {
            return []
        }
        return children(menu)
    }

    func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
