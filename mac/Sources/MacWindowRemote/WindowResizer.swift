import AppKit
import ApplicationServices

/// Fits the viewed window to the phone's aspect ratio and restores it, with the Accessibility
/// API (DESIGN.md D35). Keeps the frame each window had before its first fit.
final class WindowResizer: @unchecked Sendable {
    private let lock = NSLock()
    private var saved = SavedWindowFrames()

    func fit(windowId: UInt32, pid: pid_t, aspect: Double) async -> WindowFitOutcome {
        let window: AXUIElement
        switch Self.resizableWindow(windowId: windowId, pid: pid) {
        case .success(let w): window = w
        case .failure(let failure): return .failed(failure.code)
        }
        guard let current = WindowFocuser.frame(of: window) else { return .failed(.windowNotResizable) }
        let screens = await MainActor.run { Self.screens() }
        guard let screen = WindowFit.screen(for: current, in: screens) else { return .failed(.windowNotResizable) }
        let visible = screen.visibleFrame
        let target = WindowFit.aspectFit(aspect: aspect, in: visible)
        let savedNow = lock.withLock { saved.rememberBeforeFit(windowId, current: current) }

        Self.setPosition(window, target.origin)
        guard Self.setSize(window, target.size) else {
            Self.setPosition(window, current.origin)
            if savedNow { lock.withLock { saved.forget(windowId) } }
            return .failed(.windowNotResizable)
        }
        // Center the size the app actually took; this also corrects a position the window
        // server constrained while the window still had its old size.
        let actual = Self.size(of: window) ?? target.size
        Self.setPosition(window, WindowFit.centeredOrigin(size: actual, in: visible))
        let clamped = WindowFit.isClamped(requested: target.size, actual: actual)
        log.info("window fit id=\(windowId, privacy: .public) clamped=\(clamped, privacy: .public)")
        return .done(.fitted, clamped: clamped)
    }

    func restore(windowId: UInt32, pid: pid_t) async -> WindowFitOutcome {
        guard let frame = lock.withLock({ saved.frame(for: windowId) }) else { return .failed(.windowNotFitted) }
        let window: AXUIElement
        switch Self.resizableWindow(windowId: windowId, pid: pid) {
        case .success(let w): window = w
        case .failure(let failure): return .failed(failure.code)
        }
        Self.setPosition(window, frame.origin)
        guard Self.setSize(window, frame.size) else { return .failed(.windowNotResizable) }
        // Some apps move the window when its size changes.
        Self.setPosition(window, frame.origin)
        let actual = Self.size(of: window) ?? frame.size
        lock.withLock { saved.forget(windowId) }
        let clamped = WindowFit.isClamped(requested: frame.size, actual: actual)
        log.info("window restore id=\(windowId, privacy: .public) clamped=\(clamped, privacy: .public)")
        return .done(.restored, clamped: clamped)
    }

    // MARK: AX

    private struct Failure: Error { let code: ErrorCode }

    /// The AX window for `windowId`, if it is not full screen and its size is settable.
    private static func resizableWindow(windowId: UInt32, pid: pid_t) -> Result<AXUIElement, Failure> {
        guard let bounds = WindowCatalog.currentBounds(windowId) else { return .failure(Failure(code: .windowNotFound)) }
        guard let window = WindowFocuser.axWindow(pid: pid, bounds: bounds, title: WindowCatalog.windowName(windowId))
        else { return .failure(Failure(code: .windowNotResizable)) }
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           (fullScreen as? Bool) == true {
            return .failure(Failure(code: .windowFullscreen))
        }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return .failure(Failure(code: .windowNotResizable)) }
        return .success(window)
    }

    @discardableResult
    private static func setPosition(_ window: AXUIElement, _ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    private static func setSize(_ window: AXUIElement, _ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    private static func size(of window: AXUIElement) -> CGSize? {
        WindowFocuser.frame(of: window)?.size
    }

    /// Every screen in AX/CG global coordinates; the primary screen first.
    @MainActor
    private static func screens() -> [WindowFit.Screen] {
        let all = NSScreen.screens
        guard let primaryHeight = all.first?.frame.height else { return [] }
        return all.map {
            WindowFit.Screen(frame: WindowFit.axRect(fromAppKit: $0.frame, primaryHeight: primaryHeight),
                             visibleFrame: WindowFit.axRect(fromAppKit: $0.visibleFrame, primaryHeight: primaryHeight))
        }
    }
}

enum WindowFitState: String, Codable, Sendable {
    case fitted, restored
}

enum WindowFitOutcome: Equatable, Sendable {
    case done(WindowFitState, clamped: Bool)
    case failed(ErrorCode)
}
