import CoreGraphics
import Testing
@testable import MacWindowRemote

/// D44: the viewed app's floating windows and the windows it opened while viewed are shown
/// with the viewed window; the capture changes only when that set or area changes.
@Suite struct ChildWindowsTests {
    typealias E = ChildWindows.Entry
    static let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    static let viewed = CGRect(x: 100, y: 100, width: 800, height: 600)

    static func e(_ id: UInt32, pid: pid_t = 20, layer: Int = 3,
                  _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 300, _ h: CGFloat = 200) -> E {
        E(id: id, pid: pid, layer: layer, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    func compose(_ entries: [E], preexisting: Set<UInt32> = [1], frame: CGRect = viewed) -> ChildWindows.Composition {
        ChildWindows.composition(viewedId: 1, pid: 20, frame: frame, preexisting: preexisting,
                                 entries: entries, displays: [Self.display, Self.second])
    }

    @Test func floatingWindowOfTheAppOnTheWindowIsIncluded() {
        let c = compose([Self.e(5, 200, 200), Self.e(1, layer: 0, 100, 100, 800, 600)])
        #expect(c.childIds == [5])
        #expect(c.rect == Self.viewed)
    }

    @Test func otherLayersPidsTinyWindowsAndTheViewedWindowAreNot() {
        let c = compose([
            Self.e(2, layer: 25, 200, 200),          // status item / menu level
            Self.e(3, layer: 101, 200, 200),         // pop-up menu
            Self.e(4, layer: -20, 200, 200),         // below normal windows
            Self.e(5, pid: 30, 200, 200),            // another app's floating panel
            Self.e(6, 1000, 200, 40, 300),           // a thin strip under 60 pt, not over W
            Self.e(1, layer: 0, 100, 100, 800, 600), // the viewed window itself
        ])
        #expect(c == .plain(Self.viewed))
    }

    @Test func titleBarButtonOverlaysInFrontOfIncludedWindowsAreIncluded() {
        // As Logic Pro: the buttons are small same-app windows over each window's top-left.
        let c = compose([Self.e(13, 410, 402, 66, 20),                  // over the Settings panel
                         Self.e(5, 400, 400, 450, 250),                 // Settings panel
                         Self.e(14, layer: 0, 110, 104, 66, 20),        // over the viewed window
                         Self.e(1, layer: 0, 100, 100, 800, 600)], preexisting: [1, 14])
        #expect(c.childIds == [13, 5, 14])
    }

    @Test func overlaysNeedContainmentBeingInFrontAndEightPoints() {
        let c = compose([
            Self.e(20, pid: 30, 110, 104, 66, 20),         // another app's
            Self.e(21, 110, 104, 6, 20),                   // under 8 pt
            Self.e(22, 90, 104, 66, 20),                   // 10 of 66 pt outside: 85 % inside
            Self.e(23, 70, 104, 66, 20),                   // 30 of 66 pt outside: 55 % inside
            Self.e(24, layer: 25, 110, 104, 66, 20),       // menu level
            Self.e(26, layer: 0, 120, 120, 800, 580),      // a pre-existing cascaded document
            Self.e(1, layer: 0, 100, 100, 800, 600),
            Self.e(25, layer: 0, 120, 104, 66, 20),        // behind the viewed window
        ], preexisting: [1, 25, 26])
        #expect(c.childIds == [22])
    }

    @Test func noChildrenKeepsThePlainWindow() {
        #expect(compose([]) == .plain(Self.viewed))
    }

    @Test func aFloatingWindowAwayFromTheWindowWidensTheAreaToTheUnion() {
        let c = compose([Self.e(5, 1000, 50, 400, 300)])
        #expect(c.childIds == [5])
        #expect(c.rect == CGRect(x: 100, y: 50, width: 1300, height: 650))
    }

    @Test func theAreaIsClampedToTheWindowsDisplay() {
        // Hangs off the right edge onto the second display.
        let c = compose([Self.e(5, 1300, 300, 400, 300)])
        #expect(c.rect == CGRect(x: 100, y: 100, width: 1412, height: 600))
        // Wholly on the other display: not a child.
        #expect(compose([Self.e(6, 1600, 100)]) == .plain(Self.viewed))
    }

    @Test func aWindowSpanningDisplaysStaysPlain() {
        let spanning = CGRect(x: 1300, y: 100, width: 800, height: 600)
        #expect(compose([Self.e(5, 1400, 200)], frame: spanning) == .plain(spanning))
    }

    @Test func aNormalWindowOpenedWhileViewingIsAdoptedButPreexistingOnesAreNot() {
        // 7 existed when viewing started (another document); 8 opened later (Settings).
        let entries = [Self.e(8, layer: 0, 950, 100, 400, 500), Self.e(7, layer: 0, 120, 120, 800, 600)]
        let c = compose(entries, preexisting: [1, 7])
        #expect(c.childIds == [8])
        #expect(c.rect == CGRect(x: 100, y: 100, width: 1250, height: 600))
    }

    @Test func anAdoptedWindowStaysWhileOpenEvenBehindTheViewedWindowAndLeavesWhenClosed() {
        // The viewed window was raised above it: still on screen, still a child.
        let behind = [Self.e(1, layer: 0, 100, 100, 800, 600), Self.e(8, layer: 0, 300, 300, 400, 300)]
        let open = compose(behind, preexisting: [1])
        #expect(open.childIds == [8])
        // Closed: gone from the list, so the capture goes back to the plain window.
        let closed = compose([Self.e(1, layer: 0, 100, 100, 800, 600)], preexisting: [1])
        #expect(closed == .plain(Self.viewed))
        #expect(ChildWindows.change(from: open, to: closed) == .filter)
    }

    // MARK: Change detection

    @Test func plainWindowResizeIsAConfigurationChangeAndAMoveIsNothing() {
        let a = ChildWindows.Composition.plain(Self.viewed)
        #expect(ChildWindows.change(from: a, to: a) == .none)
        #expect(ChildWindows.change(from: a, to: .plain(Self.viewed.offsetBy(dx: 40, dy: 0))) == .none)
        let bigger = CGRect(x: 100, y: 100, width: 900, height: 600)
        #expect(ChildWindows.change(from: a, to: .plain(bigger)) == .configuration)
    }

    @Test func aChildAppearingOrLeavingOrTheAreaMovingRebuildsTheFilter() {
        let plain = compose([])
        let one = compose([Self.e(5, 200, 200)])
        #expect(ChildWindows.change(from: plain, to: one) == .filter)
        #expect(ChildWindows.change(from: one, to: plain) == .filter)
        #expect(ChildWindows.change(from: one, to: compose([Self.e(5, 250, 200)])) == .none) // inside W
        let moved = compose([Self.e(5, 200, 200)], frame: Self.viewed.offsetBy(dx: 10, dy: 0))
        #expect(ChildWindows.change(from: one, to: moved) == .filter)
        let away = compose([Self.e(5, 1000, 50, 400, 300)])
        #expect(ChildWindows.change(from: away, to: compose([Self.e(5, 1010, 50, 400, 300)])) == .filter)
        // The same children in another front-to-back order is no change.
        let ab = compose([Self.e(5, 200, 200), Self.e(6, 300, 300)])
        let ba = compose([Self.e(6, 300, 300), Self.e(5, 200, 200)])
        #expect(ChildWindows.change(from: ab, to: ba) == .none)
    }

    // MARK: Input focus

    func target(_ x: CGFloat, _ y: CGFloat, _ ids: [UInt32], _ entries: [E]) -> UInt32 {
        ChildWindows.focusTarget(at: CGPoint(x: x, y: y), viewedId: 1, viewedFrame: Self.viewed, pid: 20,
                                 childIds: ids, entries: entries).id
    }

    @Test func aClickFocusesTheIncludedWindowUnderItInFrontToBackOrder() {
        let entries = [Self.e(5, 150, 150, 100, 100),                 // floating child
                       Self.e(8, layer: 0, 950, 100, 400, 500),       // adopted child
                       Self.e(1, layer: 0, 100, 100, 800, 600),
                       Self.e(9, pid: 30, layer: 0, 0, 0, 1512, 982)] // another app behind
        let ids: [UInt32] = [5, 8]
        #expect(target(1000, 200, ids, entries) == 8)
        #expect(target(160, 160, ids, entries) == 5)   // the floating child, not the viewed window
        #expect(target(500, 500, ids, entries) == 1)
        #expect(target(1000, 800, ids, entries) == 1)  // no included window there
    }

    @Test func fullScreenSystemOverlaysInFrontDoNotHideTheChildUnderAClick() {
        // As in the real list: the Dock and Notification Center have transparent full-screen
        // windows (layers 20, 21) in front of every app window.
        let entries = [Self.e(134, pid: 40, layer: 21, 0, 0, 1512, 982),
                       Self.e(28, pid: 41, layer: 20, 0, 0, 1512, 982),
                       Self.e(5, 300, 300, 400, 300),                 // Settings panel over W
                       Self.e(1, layer: 0, 100, 100, 800, 600)]
        let hit = ChildWindows.focusTarget(at: CGPoint(x: 350, y: 310), viewedId: 1, viewedFrame: Self.viewed,
                                           pid: 20, childIds: [5], entries: entries)
        #expect(hit == Self.e(5, 300, 300, 400, 300))
        #expect(target(150, 150, [5], entries) == 1)
    }

    @Test func aChildBehindTheViewedWindowIsNotTheTargetWhereTheViewedWindowCoversIt() {
        let entries = [Self.e(1, layer: 0, 100, 100, 800, 600), Self.e(8, layer: 0, 300, 300, 800, 300)]
        #expect(target(400, 400, [8], entries) == 1)   // W is in front there
        #expect(target(1000, 400, [8], entries) == 8)  // only the child is there
    }

    func clickFocus(_ x: CGFloat, _ y: CGFloat, _ ids: [UInt32], _ entries: [E]) -> ChildWindows.ClickFocus {
        ChildWindows.clickFocus(at: CGPoint(x: x, y: y), viewedId: 1, viewedFrame: Self.viewed, pid: 20,
                                childIds: ids, entries: entries)
    }

    @Test func aClickOnTheAppsOwnTopmostWindowIsPostedWithoutRaising() {
        let entries = [Self.e(134, pid: 40, layer: 21, 0, 0, 1512, 982),  // Notification Center
                       Self.e(28, pid: 41, layer: 20, 0, 0, 1512, 982),   // Dock
                       Self.e(13, 410, 402, 66, 20),                      // close-button overlay
                       Self.e(5, 400, 400, 450, 250),                     // Settings panel
                       Self.e(1, layer: 0, 100, 100, 800, 600)]
        #expect(clickFocus(420, 410, [13, 5], entries) == .post)          // on the overlay
        #expect(clickFocus(600, 500, [13, 5], entries) == .post)          // on the panel
        #expect(clickFocus(150, 150, [13, 5], entries) == .post)          // on the viewed window
    }

    @Test func aClickUnderAnotherAppsWindowRaisesTheIncludedWindowUnderIt() {
        let entries = [Self.e(9, pid: 30, layer: 0, 500, 450, 300, 200),  // another app's window
                       Self.e(5, 400, 400, 450, 250),
                       Self.e(1, layer: 0, 100, 100, 800, 600)]
        #expect(clickFocus(600, 500, [5], entries) == .raise(Self.e(5, 400, 400, 450, 250)))
        #expect(clickFocus(150, 150, [5], entries) == .post)
    }

    @Test func keysGoToAnAdoptedWindowOnlyWhileItIsTheFrontNormalWindow() {
        let childFront = [Self.e(5, 150, 150), Self.e(8, layer: 0, 950, 100), Self.e(1, layer: 0, 100, 100, 800, 600)]
        #expect(ChildWindows.keyTarget(viewedId: 1, childIds: [5, 8], entries: childFront) == 8)
        let viewedFront = [Self.e(1, layer: 0, 100, 100, 800, 600), Self.e(8, layer: 0, 950, 100)]
        #expect(ChildWindows.keyTarget(viewedId: 1, childIds: [8], entries: viewedFront) == 1)
        let otherFront = [Self.e(9, pid: 30, layer: 0, 0, 0), Self.e(1, layer: 0, 100, 100, 800, 600)]
        #expect(ChildWindows.keyTarget(viewedId: 1, childIds: [8], entries: otherFront) == 1)
    }
}
