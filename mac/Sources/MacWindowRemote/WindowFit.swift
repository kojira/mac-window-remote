import CoreGraphics

/// Rect math for fitting a window to the phone's aspect ratio (DESIGN.md D35). All rects are
/// in the AX/CG global space: top-left origin of the primary screen, y grows downward.
enum WindowFit {
    /// The phone sends width / height of its visible video area; anything outside is rejected.
    static let aspectRange: ClosedRange<Double> = 0.2...5

    /// A screen's frame and visible frame (no menu bar, no Dock).
    struct Screen: Equatable {
        var frame: CGRect
        var visibleFrame: CGRect
    }

    /// AppKit global rect (bottom-left origin of the primary screen) → AX/CG global rect.
    static func axRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The screen with the largest intersection with `window`; the first (primary) screen if
    /// none intersects; nil when there are no screens.
    static func screen(for window: CGRect, in screens: [Screen]) -> Screen? {
        var best: (screen: Screen, area: CGFloat)?
        for s in screens {
            let i = s.frame.intersection(window)
            let area = i.isNull ? 0 : i.width * i.height
            if area > 0, area > (best?.area ?? 0) { best = (s, area) }
        }
        return best?.screen ?? screens.first
    }

    /// The largest rect with `aspect` (width / height) inside `visible`, whole points,
    /// centered.
    static func aspectFit(aspect: Double, in visible: CGRect) -> CGRect {
        var w = visible.width
        var h = (w / aspect).rounded(.down)
        if h > visible.height {
            h = visible.height
            w = (h * aspect).rounded(.down)
        }
        w = min(w.rounded(.down), visible.width)
        h = min(h.rounded(.down), visible.height)
        let size = CGSize(width: w, height: h)
        return CGRect(origin: centeredOrigin(size: size, in: visible), size: size)
    }

    /// Centers `size` in `visible` (whole points). A side larger than the visible frame
    /// starts at its top or left edge, so the title bar stays reachable.
    static func centeredOrigin(size: CGSize, in visible: CGRect) -> CGPoint {
        func axis(_ length: CGFloat, _ start: CGFloat, _ available: CGFloat) -> CGFloat {
            length >= available ? start : start + ((available - length) / 2).rounded(.down)
        }
        return CGPoint(x: axis(size.width, visible.minX, visible.width),
                       y: axis(size.height, visible.minY, visible.height))
    }

    /// The app did not take the requested size (minimum/maximum size, fixed width).
    static func isClamped(requested: CGSize, actual: CGSize) -> Bool {
        abs(requested.width - actual.width) > 1 || abs(requested.height - actual.height) > 1
    }
}

/// Frames of fitted windows before their first fit, keyed by window id (D35). In memory for
/// the process lifetime.
struct SavedWindowFrames {
    private var frames: [UInt32: CGRect] = [:]

    /// Before a fit: saves `current` unless the window already has a saved frame, so repeated
    /// fits keep the original. Returns true when it saved.
    mutating func rememberBeforeFit(_ windowId: UInt32, current: CGRect) -> Bool {
        guard frames[windowId] == nil else { return false }
        frames[windowId] = current
        return true
    }

    func frame(for windowId: UInt32) -> CGRect? { frames[windowId] }

    mutating func forget(_ windowId: UInt32) { frames[windowId] = nil }
}
