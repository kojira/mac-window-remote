import CoreGraphics
import Testing
@testable import MacWindowRemote

/// Capture output size (D4, D21): the H.264 encoder needs even sizes for 4:2:0.
@Suite struct CaptureSizeTests {
    @Test func retinaWindowKeepsFullResolution() {
        let px = CaptureSession.outputPixelSize(points: CGSize(width: 1280, height: 800), scale: 2)
        #expect(px.width == 2560 && px.height == 1600)
    }

    @Test func longEdgeIsCappedAndSizesAreEven() {
        let px = CaptureSession.outputPixelSize(points: CGSize(width: 1728, height: 1117), scale: 2)
        #expect(px.width == 2560)
        #expect(px.height == 1654) // 2234 × 2560/3456 = 1654.8, rounded down to even
    }

    @Test func oddSizesRoundDownToEven() {
        let px = CaptureSession.outputPixelSize(points: CGSize(width: 801, height: 601), scale: 1)
        #expect(px.width == 800 && px.height == 600)
    }
}
