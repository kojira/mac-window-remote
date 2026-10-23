import ApplicationServices

/// A tap on a window's title-bar button presses it over Accessibility instead of posting a
/// click (D44): Logic Pro draws those buttons in separate tiny windows that ignore a
/// synthetic click. The buttons of the app's AX windows are matched by frame first, then
/// the element at the point.
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

    enum Kind: String, CaseIterable {
        case close, minimize, zoom, fullScreen

        var attribute: String {
            switch self {
            case .close: kAXCloseButtonAttribute
            case .minimize: kAXMinimizeButtonAttribute
            case .zoom: kAXZoomButtonAttribute
            case .fullScreen: kAXFullScreenButtonAttribute
            }
        }
    }

    struct Candidate: Equatable {
        var kind: Kind
        var frame: CGRect
    }

    /// A button frame counts this much larger on each side, for a fingertip just off it.
    static let hitSlop: CGFloat = 3

    /// The index of the button whose frame (inflated by `hitSlop`) contains `p`; the smallest
    /// such frame when several do.
    static func hit(_ candidates: [Candidate], at p: CGPoint) -> Int? {
        candidates.indices
            .filter { candidates[$0].frame.insetBy(dx: -hitSlop, dy: -hitSlop).contains(p) }
            .min { area(candidates[$0].frame) < area(candidates[$1].frame) }
    }

    /// Whether `p` lies in the top 40 pt of `frame` (its title-bar band), for diagnostics.
    static func isNearTop(_ p: CGPoint, of frame: CGRect) -> Bool {
        p.x >= frame.minX - hitSlop && p.x <= frame.maxX + hitSlop
            && p.y >= frame.minY - hitSlop && p.y <= frame.minY + 40
    }

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    /// Each AX message waits at most this long, so a hung app cannot stall input.
    static let messagingTimeout: Float = 0.3

    enum Result: String {
        case pressed
        case failed
    }

    /// The title-bar button of one of `pid`'s AX windows (`kAXCloseButtonAttribute` etc.)
    /// under `p`. Logs the window and button counts and the hit; with no hit, also the frames of
    /// each window whose title-bar band holds `p` (numbers only, no titles).
    static func windowButton(at p: CGPoint, pid: pid_t) -> (element: AXUIElement, kind: Kind)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        var candidates: [Candidate] = []
        var elements: [AXUIElement] = []
        var perWindow: [(frame: CGRect?, buttons: [Candidate])] = []
        for window in windows {
            AXUIElementSetMessagingTimeout(window, messagingTimeout)
            var buttons: [Candidate] = []
            for kind in Kind.allCases {
                guard let button: AXUIElement = attribute(window, kind.attribute) else { continue }
                AXUIElementSetMessagingTimeout(button, messagingTimeout)
                guard let frame = WindowFocuser.frame(of: button) else { continue }
                buttons.append(Candidate(kind: kind, frame: frame))
                elements.append(button)
            }
            candidates += buttons
            perWindow.append((WindowFocuser.frame(of: window), buttons))
        }
        let index = hit(candidates, at: p)
        let hitName = index.map { candidates[$0].kind.rawValue } ?? "none"
        log.notice("title-buttons windows=\(windows.count, privacy: .public) buttons=\(candidates.count, privacy: .public) hit=\(hitName, privacy: .public) point=\(describe(p), privacy: .public)")
        if let index { return (elements[index], candidates[index].kind) }
        for (frame, buttons) in perWindow {
            guard let frame, isNearTop(p, of: frame) else { continue }
            let list = buttons.map { "\($0.kind.rawValue)=\(describe($0.frame))" }.joined(separator: " ")
            log.notice("title-buttons near-top window=\(describe(frame), privacy: .public) buttons=[\(list, privacy: .public)]")
        }
        return nil
    }

    private static func describe(_ p: CGPoint) -> String { "\(Int(p.x.rounded())),\(Int(p.y.rounded()))" }

    private static func describe(_ r: CGRect) -> String {
        "\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),\(Int(r.width.rounded()))x\(Int(r.height.rounded()))"
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
