import AppKit
import ApplicationServices

/// Brings the target window to the front before input (DESIGN.md D8). No private APIs.
enum WindowFocuser {
    static let pollInterval: UInt64 = 20_000_000
    static let maxWait: UInt64 = 300_000_000

    enum Outcome: String {
        case alreadyFront = "already_front"
        case raised
        case timedOut = "timed_out"
    }

    @discardableResult
    static func focus(windowId: UInt32, pid: pid_t, bounds: CGRect) async -> Outcome {
        if WindowCatalog.frontmostWindowId() == windowId { return .alreadyFront }

        NSRunningApplication(processIdentifier: pid)?.activate()
        raise(pid: pid, bounds: bounds, title: WindowCatalog.windowName(windowId))

        var waited: UInt64 = 0
        while waited < maxWait {
            try? await Task.sleep(nanoseconds: pollInterval)
            waited += pollInterval
            if WindowCatalog.frontmostWindowId() == windowId { return .raised }
        }
        return .timedOut
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
