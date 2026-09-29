import CoreMedia
import WebRTC

/// Feeds ScreenCaptureKit samples into the WebRTC video source (DESIGN.md D21). One capturer
/// lives for the app's lifetime; each `CaptureSession` delivers to it while it runs, so a
/// window change needs no renegotiation.
final class WindowVideoCapturer: RTCVideoCapturer, @unchecked Sendable {
    func deliver(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let timeStampNs = Int64(CMTimeGetSeconds(presentationTime) * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
                                  rotation: ._0, timeStampNs: timeStampNs)
        delegate?.capturer(self, didCapture: frame)
    }
}
