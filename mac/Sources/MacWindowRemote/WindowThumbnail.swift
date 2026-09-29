import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// A small JPEG of one window for the phone's quick-switch slots (DESIGN.md D33).
enum WindowThumbnail {
    static let maxLongEdge: CGFloat = 160
    static let jpegQuality = 0.6

    /// Pixel size with the long edge at most `maxLongEdge`, never upscaled.
    static func pixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let w = points.width * scale
        let h = points.height * scale
        let f = min(1, maxLongEdge / max(w, h, 1))
        return (max(1, Int(w * f)), max(1, Int(h * f)))
    }

    /// nil if the screenshot or the encode fails.
    static func jpeg(of window: SCWindow) async -> Data? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let px = pixelSize(points: window.frame.size, scale: CGFloat(filter.pointPixelScale))
        config.width = px.width
        config.height = px.height
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            log.info("thumbnail failed id=\(window.windowID, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        return encode(image)
    }

    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
