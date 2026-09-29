import CoreGraphics
import Foundation
import Testing
@testable import MacWindowRemote

/// D38: after ⌘Tab the view follows the front app's frontmost pickable window.
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

    @Test func onlyCmdTabIsAnAppSwitch() {
        #expect(InputAction.Kind.isAppSwitch("Tab", [.cmd]))
        #expect(InputAction.Kind.isAppSwitch("Tab", [.cmd, .shift]))
        #expect(!InputAction.Kind.isAppSwitch("Tab", []))
        #expect(!InputAction.Kind.isAppSwitch("Tab", [.ctrl]))
        #expect(!InputAction.Kind.isAppSwitch("F1", [.cmd]))
    }

    @Test func encodesViewSwitched() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(ServerMessage.viewSwitched(windowId: 42, app: "Editor", title: "Notes").jsonString().utf8)) as! [String: Any]
        #expect(object["t"] as? String == "view.switched")
        #expect(object["windowId"] as? Int == 42)
        #expect(object["app"] as? String == "Editor" && object["title"] as? String == "Notes")
    }
}
