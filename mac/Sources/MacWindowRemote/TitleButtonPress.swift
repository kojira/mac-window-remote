import ApplicationServices

/// A tap on a window's title-bar button presses it over Accessibility instead of posting a
/// click (D44): Logic Pro draws those buttons in separate tiny windows that ignore a
/// synthetic click.
enum TitleButtonPress {
    enum Decision: Equatable {
        case press
        case click
    }

    static let buttonSubroles: Set<String> = [
        kAXCloseButtonSubrole as String, kAXMinimizeButtonSubrole as String,
        kAXZoomButtonSubrole as String, kAXFullScreenButtonSubrole as String,
    ]

    /// Presses when the element at the point, or its parent, is a title-bar button.
    static func decision(subrole: String?, parentSubrole: String?) -> Decision {
        if let subrole, buttonSubroles.contains(subrole) { return .press }
        if let parentSubrole, buttonSubroles.contains(parentSubrole) { return .press }
        return .click
    }

    /// Each AX message waits at most this long, so a hung app cannot stall input.
    static let messagingTimeout: Float = 0.3

    enum Result: String {
        case pressed
        case failed
    }

    /// The title-bar button of `pid` at the global point `p` and its subrole, if there is one.
    static func button(at p: CGPoint, pid: pid_t) -> (element: AXUIElement, subrole: String)? {
        guard let element = element(at: p, pid: pid) else { return nil }
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        if decision(subrole: subrole, parentSubrole: nil) == .press, let subrole { return (element, subrole) }
        guard let parent: AXUIElement = attribute(element, kAXParentAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(parent, messagingTimeout)
        let parentSubrole: String? = attribute(parent, kAXSubroleAttribute)
        if decision(subrole: nil, parentSubrole: parentSubrole) == .press, let parentSubrole {
            return (parent, parentSubrole)
        }
        return nil
    }

    static func press(_ element: AXUIElement) -> Result {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success ? .pressed : .failed
    }

    /// The app's element at the point; else the system-wide one when it belongs to `pid`.
    /// The system-wide query is skipped when the app timed out (it would wait on the same
    /// app), and its timeout is left alone: setting it would change the process-wide default.
    private static func element(at p: CGPoint, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var found: AXUIElement?
        let appResult = AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &found)
        if appResult == .success, let found {
            AXUIElementSetMessagingTimeout(found, messagingTimeout)
            return found
        }
        if appResult == .cannotComplete { return nil }
        let system = AXUIElementCreateSystemWide()
        var systemFound: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &systemFound) == .success,
              let systemFound else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(systemFound, &owner) == .success, owner == pid else { return nil }
        AXUIElementSetMessagingTimeout(systemFound, messagingTimeout)
        return systemFound
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
