import AppKit
import ApplicationServices

/// Brings the target window to the front (DESIGN.md D8 steps 1–3, D25). No private APIs.
/// It raises at most once per call and never polls or waits.
enum WindowFocuser {
    enum Outcome: String {
        case alreadyFront = "already_front"
        case raised
    }

    @discardableResult
    static func focus(windowId: UInt32, pid: pid_t, bounds: CGRect) -> Outcome {
        if WindowCatalog.frontmostWindowId() == windowId { return .alreadyFront }
        NSRunningApplication(processIdentifier: pid)?.activate()
        raise(pid: pid, bounds: bounds, title: WindowCatalog.windowName(windowId))
        return .raised
    }

    private static func raise(pid: pid_t, bounds: CGRect, title: String?) {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let matches = windows.filter { w in
            guard let frame = frame(of: w) else { return false }
            return abs(frame.origin.x - bounds.origin.x) <= 1 && abs(frame.origin.y - bounds.origin.y) <= 1
                && abs(frame.width - bounds.width) <= 1 && abs(frame.height - bounds.height) <= 1
        }
        let pick = matches.first { stringAttribute($0, kAXTitleAttribute) == title } ?? matches.first
        guard let window = pick else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let posValue = pos, let sizeValue = size else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &p),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
