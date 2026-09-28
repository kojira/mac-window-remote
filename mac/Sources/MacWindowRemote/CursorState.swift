import CoreGraphics

/// The Mac-owned cursor for the viewed window (DESIGN.md D24), in window-normalized
/// coordinates. The client sends relative deltas; clamping keeps every position valid.
struct CursorState: Equatable {
    var u = 0.5
    var v = 0.5

    mutating func apply(dx: Double, dy: Double) {
        u = min(max(u + dx, 0), 1)
        v = min(max(v + dy, 0), 1)
    }

    /// Global point (CG coordinates, top-left origin) in the window's current bounds.
    /// The right and bottom edges map 1 pt inside, because the point at `maxX`/`maxY`
    /// already belongs to whatever is next to the window.
    func globalPoint(in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(bounds.minX + u * bounds.width, max(bounds.minX, bounds.maxX - 1)),
            y: min(bounds.minY + v * bounds.height, max(bounds.minY, bounds.maxY - 1)))
    }
}

/// Click count for quick successive clicks at one place (D26): a click within the system
/// double-click interval and 4 pt of the previous one continues the count (2, then 3, …).
struct ClickCounter {
    static let maxDistance: CGFloat = 4

    private var last: (time: Double, point: CGPoint, count: Int)?

    mutating func register(at point: CGPoint, time: Double, interval: Double) -> Int {
        var count = 1
        if let last, time - last.time <= interval,
           hypot(point.x - last.point.x, point.y - last.point.y) <= Self.maxDistance {
            count = last.count + 1
        }
        last = (time, point, count)
        return count
    }

    mutating func reset() { last = nil }
}
