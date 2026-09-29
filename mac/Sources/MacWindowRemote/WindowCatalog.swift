import AppKit
import ScreenCaptureKit

/// Lists pickable windows (DESIGN.md §3 Windows) and looks up live CG bounds (D4, D7).
enum WindowCatalog {
    static let minimumSize: CGFloat = 50

    static func shareableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPid = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { w in
            guard let app = w.owningApplication else { return false }
            return w.windowLayer == 0 && w.isOnScreen
                && app.processID != ownPid
                && w.frame.width >= minimumSize && w.frame.height >= minimumSize
        }
    }

    static func item(for w: SCWindow) -> WindowItem {
        WindowItem(
            id: w.windowID,
            pid: w.owningApplication?.processID ?? 0,
            app: w.owningApplication?.applicationName ?? "",
            title: w.title ?? "",
            w: w.frame.width,
            h: w.frame.height)
    }

    static func list() async throws -> [WindowItem] {
        try await shareableWindows().map(item(for:)).sorted {
            let a = $0.app.localizedStandardCompare($1.app)
            if a != .orderedSame { return a == .orderedAscending }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// The window's current global bounds in points (top-left origin), or nil if the id is gone.
    static func currentBounds(_ windowId: UInt32) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowId)) as? [[String: Any]],
              let entry = info.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowId }),
              let boundsDict = entry[kCGWindowBounds as String] as! CFDictionary?,
              let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else { return nil }
        return bounds
    }

    /// Window id of the frontmost normal (layer 0) on-screen window.
    static func frontmostWindowId() -> UInt32? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let first = info.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
        return first?[kCGWindowNumber as String] as? UInt32
    }

    /// One entry of the on-screen window list, front to back (`CGWindowListCopyWindowInfo`).
    struct OrderEntry: Equatable {
        var id: UInt32
        var pid: pid_t
        var layer: Int
        var size: CGSize
    }

    /// The on-screen windows, front to back.
    static func onScreenOrder() -> [OrderEntry] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? UInt32,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as! CFDictionary?,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return OrderEntry(id: id, pid: pid, layer: layer, size: bounds.size)
        }
    }

    /// The frontmost window of app `pid` that the window list would show (D38): the first
    /// layer-0 window of that app, at least `minimumSize` in both dimensions, that is among
    /// the pickable window ids `pickable`.
    static func frontWindowId(of pid: pid_t, order: [OrderEntry], pickable: Set<UInt32>) -> UInt32? {
        order.first { e in
            e.pid == pid && e.layer == 0 && pickable.contains(e.id)
                && e.size.width >= minimumSize && e.size.height >= minimumSize
        }?.id
    }

    static func windowName(_ windowId: UInt32) -> String? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowId)) as? [[String: Any]]
        else { return nil }
        return info.first?[kCGWindowName as String] as? String
    }
}
