import CoreGraphics
import Testing
@testable import MacWindowRemote

@Suite struct CoordinateMapperTests {
    let window = Rect(x: 100, y: 80, w: 1280, h: 800)
    let bounds = CGRect(x: 100, y: 80, width: 1280, height: 800)

    @Test func identity() {
        #expect(CoordinateMapper.globalPoint(u: 0, v: 0, frameWindow: window, currentBounds: bounds) == CGPoint(x: 100, y: 80))
        #expect(CoordinateMapper.globalPoint(u: 0.5, v: 0.25, frameWindow: window, currentBounds: bounds) == CGPoint(x: 740, y: 280))
        #expect(CoordinateMapper.globalPoint(u: 1, v: 1, frameWindow: window, currentBounds: bounds) == CGPoint(x: 1380, y: 880))
    }

    /// A Retina frame (2 px per point) reports its content rect in points; the content rect
    /// in px must cover the whole 2x image, so (u, v) stays independent of the scale.
    @Test func retinaScale() {
        let r = CaptureSession.contentRectPx(
            pointsRect: CGRect(x: 0, y: 0, width: 1280, height: 800), scaleFactor: 2, contentScale: 1,
            imageWidth: 2560, imageHeight: 1600)
        #expect(r == Rect(x: 0, y: 0, w: 2560, h: 1600))
        let u = (1280 - r.x) / r.w
        #expect(CoordinateMapper.globalPoint(u: u, v: 0.5, frameWindow: window, currentBounds: bounds) == CGPoint(x: 740, y: 480))
    }

    @Test func contentLetterboxInImage() {
        // Content occupies the top-left 1000x700 px of a 1280x800 image during a resize.
        let r = CaptureSession.contentRectPx(
            pointsRect: CGRect(x: 0, y: 0, width: 500, height: 350), scaleFactor: 2, contentScale: 1,
            imageWidth: 1280, imageHeight: 800)
        #expect(r == Rect(x: 0, y: 0, w: 1000, h: 700))
    }

    @Test func contentRectWithCappedOutput() {
        // A 1600x1000 pt window on a 2x display is capped to 2560x1600 px (contentScale 0.8).
        let r = CaptureSession.contentRectPx(
            pointsRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), scaleFactor: 2, contentScale: 0.8,
            imageWidth: 2560, imageHeight: 1600)
        #expect(r == Rect(x: 0, y: 0, w: 2560, h: 1600))
    }

    @Test func movedWindowUsesCurrentOrigin() {
        let moved = CGRect(x: 400, y: 300, width: 1280, height: 800)
        #expect(CoordinateMapper.globalPoint(u: 0.5, v: 0.5, frameWindow: window, currentBounds: moved) == CGPoint(x: 1040, y: 700))
    }

    @Test func resizedWindowUsesSeenSizeAnchoredTopLeft() {
        // The user saw a 1280x800 frame; the window has since grown to 1600x1000.
        let grown = CGRect(x: 100, y: 80, width: 1600, height: 1000)
        #expect(CoordinateMapper.globalPoint(u: 0.5, v: 0.5, frameWindow: window, currentBounds: grown) == CGPoint(x: 740, y: 480))
    }

    @Test func outsideCurrentBoundsIsRejected() {
        // The window shrank to 600x400 after the frame; a tap at the right half is stale.
        let shrunk = CGRect(x: 100, y: 80, width: 600, height: 400)
        #expect(CoordinateMapper.globalPoint(u: 0.75, v: 0.25, frameWindow: window, currentBounds: shrunk) == nil)
        #expect(CoordinateMapper.globalPoint(u: 0.25, v: 0.9, frameWindow: window, currentBounds: shrunk) == nil)
        #expect(CoordinateMapper.globalPoint(u: 0.25, v: 0.25, frameWindow: window, currentBounds: shrunk) != nil)
    }

    @Test func scrollDeltaInPoints() {
        let d = CoordinateMapper.scrollDelta(du: 0.1, dv: -0.05, frameWindow: window)
        #expect(d.dx == 128)
        #expect(d.dy == -40)
    }
}
