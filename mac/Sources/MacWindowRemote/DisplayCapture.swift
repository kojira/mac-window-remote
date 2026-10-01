import AppKit
import CoreMedia
import ScreenCaptureKit

/// Display mode (D56): lists connected displays and captures one whole display into the same
/// WebRTC capturer as a window capture (D21).
enum DisplayCatalog {
    /// The live global frame of a connected display, in points (top-left origin); nil when it
    /// is not connected (D56).
    static func frame(_ displayId: UInt32) -> CGRect? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success, ids.contains(displayId) else { return nil }
        return CGDisplayBounds(displayId)
    }

    /// `NSScreen.localizedName` by display id (D56).
    @MainActor static func names() -> [UInt32: String] {
        var names: [UInt32: String] = [:]
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[n.uint32Value] = screen.localizedName
            }
        }
        return names
    }

    static func displays() async throws -> [SCDisplay] {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
    }

    static func item(for display: SCDisplay, names: [UInt32: String]) -> DisplayItem {
        DisplayItem(id: display.displayID, name: names[display.displayID] ?? "Display \(display.displayID)",
                    w: display.frame.width, h: display.frame.height)
    }

    static func list() async throws -> [DisplayItem] {
        let displays = try await displays()
        let names = await MainActor.run { DisplayCatalog.names() }
        var items: [DisplayItem] = []
        for d in displays {
            var item = item(for: d, names: names)
            item.jpeg = await thumbnail(of: d)
            items.append(item)
        }
        return items
    }

    static func thumbnail(of display: SCDisplay) async -> Data? {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let px = WindowThumbnail.pixelSize(points: display.frame.size, scale: CGFloat(filter.pointPixelScale))
        config.width = px.width
        config.height = px.height
        config.showsCursor = false
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return WindowThumbnail.encode(image)
        } catch {
            log.info("display thumbnail failed id=\(display.displayID, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Captures one whole display without the cursor (the phone draws its own, D24), at its pixel
/// size capped like a window (D4). A disconnected display ends the view as `windowGone`, and a
/// resolution change updates the output size.
final class DisplayCaptureSession: NSObject, CaptureHandle, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let displayId: UInt32
    private let filter: SCContentFilter
    private let capturer: WindowVideoCapturer
    private let events: @Sendable (CaptureEvent) -> Void
    private let queue = DispatchQueue(label: "mac-window-remote.display-capture")
    // Touched only on `queue`.
    private var stream: SCStream?
    private var size: CGSize
    private var pollTimer: DispatchSourceTimer?
    private var stopped = false

    init(display: SCDisplay, capturer: WindowVideoCapturer, events: @escaping @Sendable (CaptureEvent) -> Void) {
        displayId = display.displayID
        filter = SCContentFilter(display: display, excludingWindows: [])
        size = display.frame.size
        self.capturer = capturer
        self.events = events
    }

    private func configuration(for size: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let px = CaptureSession.outputPixelSize(points: size, scale: CGFloat(filter.pointPixelScale))
        config.width = px.width
        config.height = px.height
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return config
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration(for: size), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        queue.async {
            self.stream = stream
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + CaptureSession.boundsPollInterval, repeating: CaptureSession.boundsPollInterval)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.pollTimer = timer
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

    private func poll() {
        guard !stopped else { return }
        guard let frame = DisplayCatalog.frame(displayId) else {
            log.info("display gone id=\(self.displayId, privacy: .public)")
            stop()
            events(.windowGone)
            return
        }
        guard frame.size != size else { return }
        size = frame.size
        let config = configuration(for: frame.size)
        let stream = self.stream
        Task { try? await stream?.updateConfiguration(config) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, let pixelBuffer = sampleBuffer.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete
        else { return }
        capturer.deliver(pixelBuffer, presentationTime: sampleBuffer.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.error("display stream stopped id=\(self.displayId, privacy: .public): \(String(describing: error), privacy: .public)")
        queue.async {
            guard !self.stopped else { return }
            self.stop()
            self.events(DisplayCatalog.frame(self.displayId) == nil ? .windowGone : .streamStopped)
        }
    }
}
