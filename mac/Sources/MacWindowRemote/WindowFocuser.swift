import AppKit
import ApplicationServices

/// Brings the target window to the front (DESIGN.md D8 steps 1–3, D25). No private APIs.
/// It raises at most once per call and never polls or waits.
enum WindowFocuser {
    enum Outcome: String {
        case alreadyFront = "already_front"
        case raised
    }

    /// `layer` is the window's CG layer. A normal window (0) is in front when it is the
    /// frontmost layer-0 window (D8 step 1). A floating child (D44) never is, so it counts as
    /// in front when its app is frontmost and the window is the app's focused (key) window.
    @discardableResult
    static func focus(windowId: UInt32, pid: pid_t, bounds: CGRect, layer: Int = 0) -> Outcome {
        if layer == 0 {
            if WindowCatalog.frontmostWindowId() == windowId { return .alreadyFront }
        } else if isFocusedWindowOfFrontmostApp(pid: pid, bounds: bounds) {
            return .alreadyFront
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
        raise(pid: pid, bounds: bounds, title: WindowCatalog.windowName(windowId))
        return .raised
    }

    private static func raise(pid: pid_t, bounds: CGRect, title: String?) {
        guard let window = axWindow(pid: pid, bounds: bounds, title: title) else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private static func isFocusedWindowOfFrontmostApp(pid: pid_t, bounds: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var frontmost: CFTypeRef?
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &frontmost) == .success,
              (frontmost as? Bool) == true,
              AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID(),
              let frame = frame(of: value as! AXUIElement) else { return false }
        return matches(frame, bounds)
    }

    private static func matches(_ frame: CGRect, _ bounds: CGRect) -> Bool {
        abs(frame.origin.x - bounds.origin.x) <= 1 && abs(frame.origin.y - bounds.origin.y) <= 1
            && abs(frame.width - bounds.width) <= 1 && abs(frame.height - bounds.height) <= 1
    }

    /// The app's AX window whose frame matches the CG `bounds` (within 1 pt), preferring the
    /// one with the same title (D8, D35).
    static func axWindow(pid: pid_t, bounds: CGRect, title: String?) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        let found = windows.filter { w in
            guard let frame = frame(of: w) else { return false }
            return matches(frame, bounds)
        }
        return found.first { stringAttribute($0, kAXTitleAttribute) == title } ?? found.first
    }

    static func frame(of element: AXUIElement) -> CGRect? {
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
