import CoreGraphics
import Testing
@testable import MacWindowRemote

/// Fit the window to the phone (D35): rect math, screen choice, and saved frames.
@Suite struct WindowFitTests {
    // A 1512×982 primary screen with a 25 pt menu bar and a 70 pt Dock at the bottom, in AX space.
    let visible = CGRect(x: 0, y: 25, width: 1512, height: 887)

    @Test func tallAspectUsesFullHeightAndIsCentered() {
        let r = WindowFit.aspectFit(aspect: 0.5, in: visible)
        #expect(r.size == CGSize(width: 443, height: 887)) // 443.5 rounded down
        #expect(r.origin == CGPoint(x: 534, y: 25)) // (1512 − 443) / 2 = 534.5 → 534
    }

    @Test func wideAspectUsesFullWidthAndIsCentered() {
        let r = WindowFit.aspectFit(aspect: 5, in: visible)
        #expect(r.size == CGSize(width: 1512, height: 302)) // 302.4 rounded down
        #expect(r.origin == CGPoint(x: 0, y: 25 + 292)) // (887 − 302) / 2 = 292.5 → 292
    }

    @Test func fitStaysInsideAVisibleFrameWithANonZeroOrigin() {
        let second = CGRect(x: -1920, y: -1080 + 25, width: 1920, height: 1055)
        let r = WindowFit.aspectFit(aspect: 16.0 / 9.0, in: second)
        #expect(second.contains(r))
        #expect(r.width <= second.width && r.height <= second.height)
        #expect(r.width == r.width.rounded(.down) && r.minX == r.minX.rounded(.down))
        #expect(abs(r.midX - second.midX) <= 1 && abs(r.midY - second.midY) <= 1)
    }

    @Test func appKitToAXConversion() {
        // Primary 982 pt tall. A screen above it in AppKit (y 982…2062) is at negative AX y.
        let above = WindowFit.axRect(fromAppKit: CGRect(x: 0, y: 982, width: 1920, height: 1080), primaryHeight: 982)
        #expect(above == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        // A visible frame that excludes a 70 pt Dock (bottom) and 25 pt menu bar (top).
        let vis = WindowFit.axRect(fromAppKit: CGRect(x: 0, y: 70, width: 1512, height: 887), primaryHeight: 982)
        #expect(vis == CGRect(x: 0, y: 25, width: 1512, height: 887))
    }

    @Test func screenWithTheLargestOverlapWins() {
        let primary = WindowFit.Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: visible)
        let left = WindowFit.Screen(frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
                                    visibleFrame: CGRect(x: -1920, y: -175, width: 1920, height: 1055))
        let screens = [primary, left]
        #expect(WindowFit.screen(for: CGRect(x: -1000, y: 100, width: 800, height: 600), in: screens) == left)
        // Straddling: 300 pt on the left screen, 500 pt on the primary.
        #expect(WindowFit.screen(for: CGRect(x: -300, y: 100, width: 800, height: 600), in: screens) == primary)
        // Off every screen: the primary screen.
        #expect(WindowFit.screen(for: CGRect(x: 5000, y: 5000, width: 100, height: 100), in: screens) == primary)
        #expect(WindowFit.screen(for: .zero, in: []) == nil)
    }

    @Test func clampedSizeIsRecenteredAndATooLargeSideStartsAtTheEdge() {
        // The app kept a 600 pt minimum width.
        #expect(WindowFit.centeredOrigin(size: CGSize(width: 600, height: 887), in: visible) == CGPoint(x: 456, y: 25))
        // Taller than the visible frame: the top stays at the menu bar.
        #expect(WindowFit.centeredOrigin(size: CGSize(width: 400, height: 1000), in: visible) == CGPoint(x: 556, y: 25))
        #expect(WindowFit.isClamped(requested: CGSize(width: 443, height: 887), actual: CGSize(width: 600, height: 887)))
        #expect(!WindowFit.isClamped(requested: CGSize(width: 443, height: 887), actual: CGSize(width: 444, height: 886)))
    }

    @Test func savedFrameBookkeeping() {
        var saved = SavedWindowFrames()
        let original = CGRect(x: 100, y: 80, width: 1280, height: 800)
        let first = saved.rememberBeforeFit(7, current: original)
        #expect(first)
        // A second fit (after rotation) keeps the original frame.
        let second = saved.rememberBeforeFit(7, current: CGRect(x: 534, y: 25, width: 443, height: 887))
        #expect(!second)
        #expect(saved.frame(for: 7) == original)
        #expect(saved.frame(for: 8) == nil)
        // Restore forgets it; the next fit saves the frame at that time.
        saved.forget(7)
        #expect(saved.frame(for: 7) == nil)
        let again = saved.rememberBeforeFit(7, current: .zero)
        #expect(again)
    }
}
