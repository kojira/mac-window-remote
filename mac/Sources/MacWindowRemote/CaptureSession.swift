import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures one window with ScreenCaptureKit and delivers each complete NV12 frame to the
/// WebRTC capturer (DESIGN.md D4, D21).
final class CaptureSession: NSObject, CaptureHandle, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let maxLongEdge: CGFloat = 2560
    static let boundsPollInterval: TimeInterval = 0.5

    let windowId: UInt32
    private let filter: SCContentFilter
    private let capturer: WindowVideoCapturer
    private let events: @Sendable (CaptureEvent) -> Void
    private var stream: SCStream?

    // All state below is touched only on `queue`.
    private let queue = DispatchQueue(label: "mac-window-remote.capture")
    private var configuredSize: CGSize
    private var pollTimer: DispatchSourceTimer?
    private var stopped = false

    init(window: SCWindow, capturer: WindowVideoCapturer, events: @escaping @Sendable (CaptureEvent) -> Void) {
        windowId = window.windowID
        filter = SCContentFilter(desktopIndependentWindow: window)
        self.capturer = capturer
        self.events = events
        configuredSize = window.frame.size
    }

    /// Window points × scale, long edge capped at 2560 px, rounded down to even sizes for 4:2:0
    /// (D4, D21).
    static func outputPixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        var w = points.width * scale
        var h = points.height * scale
        let longEdge = max(w, h)
        if longEdge > maxLongEdge {
            let f = maxLongEdge / longEdge
            w *= f
            h *= f
        }
        func even(_ x: CGFloat) -> Int { max(2, Int(x) & ~1) }
        return (even(w), even(h))
    }

    private func configuration(for size: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let px = Self.outputPixelSize(points: size, scale: CGFloat(filter.pointPixelScale))
        config.width = px.width
        config.height = px.height
        // The phone draws its own cursor overlay (D21, D24).
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        // WebRTC drops frames itself when bandwidth is short (D21).
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        // VideoToolbox encodes NV12 without a BGRA → YUV conversion.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return config
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration(for: configuredSize), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        queue.async {
            self.stream = stream
            self.startBoundsPolling()
        }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.pollTimer?.cancel()
            self.pollTimer = nil
            let stream = self.stream
            self.stream = nil
            Task { try? await stream?.stopCapture() }
        }
    }

    // MARK: Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, Self.isComplete(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        capturer.deliver(pixelBuffer, presentationTime: sampleBuffer.presentationTimeStamp)
    }

    /// Idle frames (window unchanged) and other non-complete statuses are skipped.
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }

    // MARK: Resize / window gone (D4)

    private func startBoundsPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.boundsPollInterval, repeating: Self.boundsPollInterval)
        timer.setEventHandler { [weak self] in self?.pollBounds() }
        timer.resume()
        pollTimer = timer
    }

    private func pollBounds() {
        guard !stopped else { return }
        guard let bounds = WindowCatalog.currentBounds(windowId) else {
            log.info("window gone id=\(self.windowId, privacy: .public)")
            stop()
            events(.windowGone)
            return
        }
        if abs(bounds.width - configuredSize.width) >= 1 || abs(bounds.height - configuredSize.height) >= 1 {
            configuredSize = bounds.size
            let config = configuration(for: bounds.size)
            let stream = self.stream
            Task { try? await stream?.updateConfiguration(config) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.error("stream stopped id=\(self.windowId, privacy: .public): \(String(describing: error), privacy: .public)")
        queue.async {
            guard !self.stopped else { return }
            self.stop()
            self.events(.streamStopped)
        }
    }
}
