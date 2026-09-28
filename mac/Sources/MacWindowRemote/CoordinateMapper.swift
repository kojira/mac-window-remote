import CoreGraphics

/// Pure mapping from content-normalized (u, v) to a global point (DESIGN.md D7).
enum CoordinateMapper {
    /// `frameWindow` is the window frame (points) from the header of the frame the user saw.
    /// `currentBounds` is the window's global bounds (points) queried right now.
    /// Returns nil when the point falls outside the current bounds (`stale_coordinates`).
    static func globalPoint(u: Double, v: Double, frameWindow: Rect, currentBounds: CGRect) -> CGPoint? {
        let p = CGPoint(
            x: currentBounds.origin.x + u * frameWindow.w,
            y: currentBounds.origin.y + v * frameWindow.h)
        // A point on the right/bottom edge (u or v == 1) still belongs to the window.
        guard p.x >= currentBounds.minX, p.x <= currentBounds.maxX,
              p.y >= currentBounds.minY, p.y <= currentBounds.maxY else { return nil }
        return p
    }

    /// Scroll deltas in content-normalized units → points.
    static func scrollDelta(du: Double, dv: Double, frameWindow: Rect) -> (dx: Double, dy: Double) {
        (du * frameWindow.w, dv * frameWindow.h)
    }
}
