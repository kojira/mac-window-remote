import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox

/// Captures one window with ScreenCaptureKit and delivers JPEG frames with
/// one-frame-in-flight flow control (DESIGN.md D3, D4).
final class CaptureSession: NSObject, CaptureHandle, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let maxLongEdge: CGFloat = 2560
    static let jpegQuality: CGFloat = 0.7
    static let boundsPollInterval: TimeInterval = 0.5

    let windowId: UInt32
    private let filter: SCContentFilter
    private let events: @Sendable (CaptureEvent) -> Void
    private var stream: SCStream?

    // All state below is touched only on `queue`.
    private let queue = DispatchQueue(label: "mac-window-remote.capture")
    private var latest: CMSampleBuffer?
    private var inFlightFrameId: Int?
    private var nextFrameId = 1
    private var configuredSize: CGSize
    private var pollTimer: DispatchSourceTimer?
    private var stopped = false

    init(window: SCWindow, events: @escaping @Sendable (CaptureEvent) -> Void) {
        windowId = window.windowID
        filter = SCContentFilter(desktopIndependentWindow: window)
        self.events = events
        configuredSize = window.frame.size
    }

    static func outputPixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        var w = points.width * scale
        var h = points.height * scale
        let longEdge = max(w, h)
        if longEdge > maxLongEdge {
            let f = maxLongEdge / longEdge
            w *= f
            h *= f
        }
        return (max(1, Int(w.rounded())), max(1, Int(h.rounded())))
    }

    private func configuration(for size: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let px = Self.outputPixelSize(points: size, scale: CGFloat(filter.pointPixelScale))
        config.width = px.width
        config.height = px.height
        config.showsCursor = true
        config.ignoreShadowsSingleWindow = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return config
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration(for: configuredSize), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        queue.async { self.startBoundsPolling() }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.pollTimer?.cancel()
            self.pollTimer = nil
            self.latest = nil
            let stream = self.stream
            self.stream = nil
            Task { try? await stream?.stopCapture() }
        }
    }

    // MARK: Flow control

    func ack(frameId: Int) {
        queue.async {
            guard frameId == self.inFlightFrameId else { return }
            self.inFlightFrameId = nil
            self.sendLatestIfIdle()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, Self.isComplete(sampleBuffer) else { return }
        latest = sampleBuffer
        sendLatestIfIdle()
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

    private func sendLatestIfIdle() {
        guard inFlightFrameId == nil, !stopped, let sample = latest else { return }
        latest = nil
        guard let encoded = encode(sample) else { return }
        inFlightFrameId = encoded.header.frameId
        events(.frame(encoded.header, encoded.jpeg))
    }

    private func encode(_ sample: CMSampleBuffer) -> (header: FrameHeader, jpeg: Data)? {
        guard let pixelBuffer = sample.imageBuffer,
              let bounds = WindowCatalog.currentBounds(windowId) else { return nil }
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard let image = cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        let width = image.width
        let height = image.height
        let content = Self.contentRect(sample, imageWidth: width, imageHeight: height)
        let frameId = nextFrameId
        nextFrameId += 1
        let header = FrameHeader(
            frameId: frameId, windowId: windowId, width: width, height: height,
            content: content,
            window: Rect(x: bounds.origin.x, y: bounds.origin.y, w: bounds.width, h: bounds.height))
        return (header, data as Data)
    }

    /// The window content rect inside the image in px. `contentRect` is in points in the
    /// surface, so it is multiplied by the frame's point-to-pixel `scaleFactor`
    /// (see DESIGN.md D7 implementation note).
    static func contentRect(_ sample: CMSampleBuffer, imageWidth: Int, imageHeight: Int) -> Rect {
        let full = Rect(x: 0, y: 0, w: Double(imageWidth), h: Double(imageHeight))
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rectDict = info[.contentRect] as! CFDictionary?,
              let rect = CGRect(dictionaryRepresentation: rectDict),
              let scale = info[.scaleFactor] as? CGFloat
        else { return full }
        return clampedContentRect(pointsRect: rect, scaleFactor: scale, imageWidth: imageWidth, imageHeight: imageHeight)
    }

    static func clampedContentRect(pointsRect: CGRect, scaleFactor: CGFloat, imageWidth: Int, imageHeight: Int) -> Rect {
        let full = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let px = CGRect(x: pointsRect.origin.x * scaleFactor, y: pointsRect.origin.y * scaleFactor,
                        width: pointsRect.width * scaleFactor, height: pointsRect.height * scaleFactor)
        let r = px.intersection(full)
        guard !r.isNull, r.width >= 1, r.height >= 1 else {
            return Rect(x: 0, y: 0, w: Double(imageWidth), h: Double(imageHeight))
        }
        return Rect(x: r.origin.x, y: r.origin.y, w: r.width, h: r.height)
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
