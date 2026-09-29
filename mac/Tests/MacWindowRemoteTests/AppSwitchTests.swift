import CoreGraphics
import Foundation
import Testing
@testable import MacWindowRemote

/// D38: after ⌘Tab or ⌘F1 the view follows the front app's frontmost pickable window.
@Suite struct AppSwitchTests {
    typealias E = WindowCatalog.OrderEntry
    static func e(_ id: UInt32, pid: pid_t, layer: Int = 0, w: CGFloat = 800, h: CGFloat = 600) -> E {
        E(id: id, pid: pid, layer: layer, size: CGSize(width: w, height: h))
    }

    @Test func picksTheFirstPickableLayerZeroWindowOfTheApp() {
        let order = [
            Self.e(1, pid: 20, layer: 25),       // the app's menu bar item / panel above
            Self.e(2, pid: 10),                  // another app's window in front
            Self.e(3, pid: 20, w: 40, h: 600),   // a tiny helper strip
            Self.e(4, pid: 20),                  // not in the window list (e.g. untitled helper)
            Self.e(5, pid: 20),                  // the app's frontmost normal window
            Self.e(6, pid: 20),
        ]
        #expect(WindowCatalog.frontWindowId(of: 20, order: order, pickable: [1, 2, 3, 5, 6]) == 5)
    }

    @Test func noWindowWhenTheAppHasNone() {
        let order = [Self.e(2, pid: 10), Self.e(9, pid: 30, layer: -2147483624)]
        #expect(WindowCatalog.frontWindowId(of: 30, order: order, pickable: [2, 9]) == nil)
        #expect(WindowCatalog.frontWindowId(of: 20, order: order, pickable: [2, 9]) == nil)
    }

    @Test func switchedWindowWithinTheSameApp() {
        // ⌘F1: the front app stays (pid 20); its window 6 came in front of the viewed 5.
        let before = [Self.e(5, pid: 20), Self.e(6, pid: 20), Self.e(2, pid: 10)]
        let after = [Self.e(6, pid: 20), Self.e(5, pid: 20), Self.e(2, pid: 10)]
        #expect(WindowCatalog.switchedWindowId(from: 5, frontPid: 20, order: before, pickable: [2, 5, 6]) == nil)
        #expect(WindowCatalog.switchedWindowId(from: 5, frontPid: 20, order: after, pickable: [2, 5, 6]) == 6)
    }

    @Test func switchedWindowOfAnotherApp() {
        // ⌘Tab: app 10 is front but the window order has not caught up yet, then it has.
        let lagging = [Self.e(5, pid: 20), Self.e(2, pid: 10)]
        let after = [Self.e(2, pid: 10), Self.e(5, pid: 20)]
        #expect(WindowCatalog.switchedWindowId(from: 5, frontPid: 10, order: lagging, pickable: [2, 5]) == 2)
        #expect(WindowCatalog.switchedWindowId(from: 5, frontPid: 10, order: after, pickable: [2, 5]) == 2)
        // Not switched yet (the viewed app is still front), or the front app has no window.
        #expect(WindowCatalog.switchedWindowId(from: 5, frontPid: 20, order: lagging, pickable: [2, 5]) == nil)
        #expect(WindowCatalog.switchedWindowId(from: 5, frontPid: 30, order: after, pickable: [2, 5]) == nil)
    }

    @Test func windowSwitchKeys() {
        for key in ["Tab", "F1", "`"] {
            #expect(InputAction.Kind.isWindowSwitch(key, [.cmd]))
            #expect(InputAction.Kind.isWindowSwitch(key, [.cmd, .shift]))
            #expect(!InputAction.Kind.isWindowSwitch(key, []))
            #expect(!InputAction.Kind.isWindowSwitch(key, [.ctrl]))
        }
        #expect(!InputAction.Kind.isWindowSwitch("F2", [.cmd]))
        #expect(!InputAction.Kind.isWindowSwitch("c", [.cmd]))
    }

    @Test func encodesViewSwitched() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(ServerMessage.viewSwitched(windowId: 42, app: "Editor", title: "Notes").jsonString().utf8)) as! [String: Any]
        #expect(object["t"] as? String == "view.switched")
        #expect(object["windowId"] as? Int == 42)
        #expect(object["app"] as? String == "Editor" && object["title"] as? String == "Notes")
    }
}
