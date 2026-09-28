import CoreGraphics
import Testing
@testable import MacWindowRemote

/// The window content rect inside a JPEG frame (D7 implementation note); the phone uses it
/// to place the cursor overlay on the image.
@Suite struct ContentRectTests {
    @Test func retinaScale() {
        let r = CaptureSession.contentRectPx(
            pointsRect: CGRect(x: 0, y: 0, width: 1280, height: 800), scaleFactor: 2, contentScale: 1,
            imageWidth: 2560, imageHeight: 1600)
        #expect(r == Rect(x: 0, y: 0, w: 2560, h: 1600))
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
}
