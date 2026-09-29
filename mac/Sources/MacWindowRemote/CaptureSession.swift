import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures one window with ScreenCaptureKit and delivers each complete NV12 frame to the
/// WebRTC capturer (DESIGN.md D4, D21). The app's child windows (floating windows and windows
/// it opened while viewed) are shown with it (D44).
final class CaptureSession: NSObject, CaptureHandle, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let maxLongEdge: CGFloat = 2560
    static let boundsPollInterval: TimeInterval = 0.5

    let windowId: UInt32
    private let pid: pid_t
    /// Every window id the app had when this capture started; later ones are children (D44).
    private let preexisting: Set<UInt32>
    private let windowFilter: SCContentFilter
    private let capturer: WindowVideoCapturer
    private let events: @Sendable (CaptureEvent) -> Void
    private var stream: SCStream?

    // All state below is touched only on `queue`.
    private let queue = DispatchQueue(label: "mac-window-remote.capture")
    private var filter: SCContentFilter
    /// The viewed window's bounds, the child windows the filter includes, and the captured
    /// area (D44).
    private var composition: ChildWindows.Composition
    /// `composition` with children, for input mapping from other threads (D44); nil while the
    /// capture is the plain window or stopped.
    private let shownLock = NSLock()
    private var shownComposite: ChildWindows.Composition?
    private var updatingFilter = false
    private var pollTimer: DispatchSourceTimer?
    private var stopped = false

    init(window: SCWindow, capturer: WindowVideoCapturer, events: @escaping @Sendable (CaptureEvent) -> Void) {
        windowId = window.windowID
        pid = window.owningApplication?.processID ?? 0
        preexisting = ChildWindows.allWindowIds(of: pid)
        windowFilter = SCContentFilter(desktopIndependentWindow: window)
        filter = windowFilter
        self.capturer = capturer
        self.events = events
        composition = .plain(window.frame)
    }

    /// The composite the video shows now, when it has child windows (D44); nil for the plain
    /// window, whose live bounds the input maps to as before.
    var composite: ChildWindows.Composition? {
        shownLock.withLock { shownComposite }
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

    /// `sourceRect` is the viewed window's area on its display when floating windows are
    /// composited (D44); nil for the plain window capture.
    private func configuration(for size: CGSize, filter: SCContentFilter, sourceRect: CGRect? = nil) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let px = Self.outputPixelSize(points: size, scale: CGFloat(filter.pointPixelScale))
        config.width = px.width
        config.height = px.height
        // The phone draws its own cursor overlay (D21, D24).
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        if let sourceRect {
            config.sourceRect = sourceRect
            config.ignoreShadowsDisplay = true
        }
        // WebRTC drops frames itself when bandwidth is short (D21).
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        // VideoToolbox encodes NV12 without a BGRA → YUV conversion.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return config
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration(for: composition.frame.size, filter: filter),
                              delegate: self)
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
            self.shownLock.withLock { self.shownComposite = nil }
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
        guard !stopped, !updatingFilter else { return }
        guard let bounds = WindowCatalog.currentBounds(windowId) else {
            log.info("window gone id=\(self.windowId, privacy: .public)")
            stop()
            events(.windowGone)
            return
        }
        let next = ChildWindows.composition(viewedId: windowId, pid: pid, frame: bounds, preexisting: preexisting,
                                            entries: ChildWindows.onScreenEntries(),
                                            displays: ChildWindows.displayFrames())
        switch ChildWindows.change(from: composition, to: next) {
        case .none:
            break
        case .configuration:
            composition = next
            let config = configuration(for: bounds.size, filter: filter)
            let stream = self.stream
            Task { try? await stream?.updateConfiguration(config) }
        case .filter:
            updatingFilter = true
            Task { await self.applyFilter(for: next) }
        }
    }

    /// Switches the stream between the plain window filter and a display filter of the viewed
    /// window plus its child windows, cropped to the composite area (D44).
    private func applyFilter(for next: ChildWindows.Composition) async {
        var newFilter = windowFilter
        var shown = ChildWindows.Composition.plain(next.frame)
        var sourceRect: CGRect?
        if !next.childIds.isEmpty,
           let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
           let display = content.displays.first(where: { $0.frame.contains(next.frame) }),
           let viewed = content.windows.first(where: { $0.windowID == windowId }) {
            let children = content.windows.filter { next.childIds.contains($0.windowID) }
            if !children.isEmpty {
                newFilter = SCContentFilter(display: display, including: [viewed] + children)
                sourceRect = next.rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                shown = next
            }
        }
        let config = configuration(for: shown.rect.size, filter: newFilter, sourceRect: sourceRect)
        let (stream, current) = queue.sync { (self.stream, self.filter) }
        var applied = false
        do {
            // A child ScreenCaptureKit does not list keeps the plain window filter; it is not
            // swapped for itself on every poll.
            if newFilter !== current { try await stream?.updateContentFilter(newFilter) }
            try await stream?.updateConfiguration(config)
            applied = true
        } catch {
            log.error("capture filter update failed id=\(self.windowId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        queue.async {
            self.updatingFilter = false
            guard applied, !self.stopped else { return }
            self.filter = newFilter
            // A fallback to the plain window keeps no children, so the next poll tries again.
            self.composition = shown
            self.shownLock.withLock { self.shownComposite = shown.childIds.isEmpty ? nil : shown }
            log.info("capture children id=\(self.windowId, privacy: .public) count=\(shown.childIds.count, privacy: .public)")
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
