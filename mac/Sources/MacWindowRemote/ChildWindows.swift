import CoreGraphics

/// The viewed app's child windows that the capture shows together with the viewed window
/// (DESIGN.md D44): its floating windows (plug-in editors, palettes) and the normal windows it
/// opened while the viewed window was viewed (Settings, dialogs). Pure selection and change
/// logic, plus the CG window-list readers.
enum ChildWindows {
    /// Floating and utility window levels: above normal windows (0), below the status bar,
    /// menus, and pop-ups (25 and up).
    static let floatingLayers = 1..<25
    /// Smaller windows (tool tips, drag handles) are left out.
    static let minimumSize: CGFloat = 60

    /// One window from `CGWindowListCopyWindowInfo`, front to back.
    struct Entry: Equatable {
        var id: UInt32
        var pid: pid_t
        var layer: Int
        /// Global bounds in points (top-left origin), as `kCGWindowBounds`.
        var frame: CGRect
    }

    /// What the capture shows: the viewed window's bounds, the child windows included (front
    /// to back), and the captured area in global points. Without children `rect` is `frame`.
    struct Composition: Equatable {
        var childIds: [UInt32]
        var frame: CGRect
        var rect: CGRect

        static func plain(_ frame: CGRect) -> Composition { Composition(childIds: [], frame: frame, rect: frame) }
    }

    /// The composition for viewed window `viewedId` of `pid` at `frame`. `preexisting` holds
    /// every window id the app had when viewing started. A standalone child is another
    /// on-screen window of `pid`, at least 60 × 60 pt, on `frame`'s display, that is either at a
    /// floating layer or a normal (layer 0) window not in `preexisting`. An overlay is another
    /// window of `pid` at layer 0..<25, at least 8 × 8 pt, in front of the viewed window or a
    /// standalone child with at least 80 % of its area inside that window's frame and at most
    /// half its area (e.g. the title-bar buttons Logic Pro draws in their own small windows;
    /// not a cascaded document window). The captured area is the
    /// union of `frame` and the children's frames, clamped to that display. When `frame` is not
    /// wholly on one of `displays`, or there are no children, it is the plain window.
    static func composition(viewedId: UInt32, pid: pid_t, frame: CGRect, preexisting: Set<UInt32>,
                            entries: [Entry], displays: [CGRect]) -> Composition {
        guard let display = displays.first(where: { $0.contains(frame) }) else { return .plain(frame) }
        let standalone = entries.filter { e in
            let onDisplay = e.frame.intersection(display)
            let kind = floatingLayers.contains(e.layer) || (e.layer == 0 && !preexisting.contains(e.id))
            return e.id != viewedId && e.pid == pid && kind
                && e.frame.width >= minimumSize && e.frame.height >= minimumSize
                && !onDisplay.isNull && onDisplay.width > 0 && onDisplay.height > 0
        }
        // The windows an overlay can sit on, with their front-to-back positions (the viewed
        // window counts as behind everything when it is not in the list).
        let standaloneIds = Set(standalone.map(\.id))
        let hosts = [(entries.firstIndex { $0.id == viewedId } ?? entries.count, frame)]
            + entries.indices.filter { standaloneIds.contains(entries[$0].id) }.map { ($0, entries[$0].frame) }
        let children = entries.indices.filter { i in
            let e = entries[i]
            if standaloneIds.contains(e.id) { return true }
            guard e.id != viewedId, e.pid == pid, overlayLayers.contains(e.layer),
                  e.frame.width >= overlayMinimumSize, e.frame.height >= overlayMinimumSize else { return false }
            return hosts.contains { index, host in index > i && isMostlyInside(e.frame, host) }
        }.map { entries[$0] }
        guard !children.isEmpty else { return .plain(frame) }
        let union = children.reduce(frame) { $0.union($1.frame) }.intersection(display)
        return Composition(childIds: children.map(\.id), frame: frame, rect: union)
    }

    /// Layers and minimum size of overlay windows (D44).
    static let overlayLayers = 0..<25
    static let overlayMinimumSize: CGFloat = 8
    /// The share of an overlay's area that must lie inside the window it sits on.
    static let overlayContainment: CGFloat = 0.8
    /// An overlay is at most this share of the window it sits on.
    static let overlayMaximumShare: CGFloat = 0.5

    private static func isMostlyInside(_ overlay: CGRect, _ host: CGRect) -> Bool {
        let inside = overlay.intersection(host)
        guard !inside.isNull else { return false }
        let area = overlay.width * overlay.height
        return inside.width * inside.height >= overlayContainment * area
            && area <= overlayMaximumShare * host.width * host.height
    }

    enum Change: Equatable {
        case none
        /// Only the output size changes (`updateConfiguration`, as D4).
        case configuration
        /// The content filter is rebuilt: the set of children changed, or the captured area
        /// moved or resized while children are shown.
        case filter
    }

    static func change(from old: Composition, to new: Composition) -> Change {
        if Set(old.childIds) != Set(new.childIds) { return .filter }
        if !new.childIds.isEmpty { return differs(old.rect, new.rect) ? .filter : .none }
        let resized = abs(new.frame.width - old.frame.width) >= 1 || abs(new.frame.height - old.frame.height) >= 1
        return resized ? .configuration : .none
    }

    private static func differs(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) >= 1 || abs(a.minY - b.minY) >= 1
            || abs(a.width - b.width) >= 1 || abs(a.height - b.height) >= 1
    }

    /// The included window under global point `point`: the frontmost of `entries` (front to
    /// back, as `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`) that is the viewed window or
    /// one of `childIds` and contains the point; nil when none does. Other windows (other apps,
    /// transparent overlays, system windows) are skipped, as the video shows only the included
    /// ones.
    static func hit(_ point: CGPoint, viewedId: UInt32, childIds: [UInt32], entries: [Entry]) -> Entry? {
        entries.first { ($0.id == viewedId || childIds.contains($0.id)) && $0.frame.contains(point) }
    }

    /// The window to focus before a click at `point` (D25, D44): the included window under the
    /// point, so a click on a child never raises the viewed window above it; the viewed window
    /// (at `viewedFrame`, layer 0) when no included window is there.
    static func focusTarget(at point: CGPoint, viewedId: UInt32, viewedFrame: CGRect, pid: pid_t,
                            childIds: [UInt32], entries: [Entry]) -> Entry {
        hit(point, viewedId: viewedId, childIds: childIds, entries: entries)
            ?? Entry(id: viewedId, pid: pid, layer: 0, frame: viewedFrame)
    }

    /// App window layers (normal through utility panels). The Dock (20) and higher system
    /// levels are left out: their transparent full-screen windows lie in front of every app
    /// window without taking clicks.
    static let appLayers = 0..<20

    enum ClickFocus: Equatable {
        /// The viewed app's own window (or overlay) is topmost at the point: the click is
        /// posted as is, with no raise or re-ordering, so it handles key and front itself.
        case post
        /// Another app's window covers the point: raise this included window first (D25).
        case raise(Entry)
    }

    /// What to do before a click at `point` (D44): `post` when the frontmost app-layer window
    /// containing the point belongs to `pid`; otherwise `raise` the `focusTarget`.
    static func clickFocus(at point: CGPoint, viewedId: UInt32, viewedFrame: CGRect, pid: pid_t,
                           childIds: [UInt32], entries: [Entry]) -> ClickFocus {
        if let top = entries.first(where: { appLayers.contains($0.layer) && $0.frame.contains(point) }), top.pid == pid {
            return .post
        }
        return .raise(focusTarget(at: point, viewedId: viewedId, viewedFrame: viewedFrame, pid: pid,
                                  childIds: childIds, entries: entries))
    }

    /// The window keys, text, and menu items go to (D25, D44): an adopted normal child that is
    /// the frontmost normal window stays in front; otherwise the viewed window.
    static func keyTarget(viewedId: UInt32, childIds: [UInt32], entries: [Entry]) -> UInt32 {
        guard let front = entries.first(where: { $0.layer == 0 }), childIds.contains(front.id) else { return viewedId }
        return front.id
    }

    /// The on-screen windows, front to back.
    static func onScreenEntries() -> [Entry] {
        entries(CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID))
    }

    /// Every window id of `pid`, on screen or not (minimized, hidden, other Spaces).
    static func allWindowIds(of pid: pid_t) -> Set<UInt32> {
        Set(entries(CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)).filter { $0.pid == pid }.map(\.id))
    }

    private static func entries(_ list: CFArray?) -> [Entry] {
        guard let info = list as? [[String: Any]] else { return [] }
        return info.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? UInt32,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as! CFDictionary?,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return Entry(id: id, pid: pid, layer: layer, frame: bounds)
        }
    }

    /// Global frames (points) of the active displays.
    static func displayFrames() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}
