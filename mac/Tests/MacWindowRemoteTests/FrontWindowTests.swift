import CoreGraphics
import Foundation
import Testing
@testable import MacWindowRemote

/// D59: in display mode, the window "View the front window" opens.
@Suite struct FrontWindowTests {
    typealias E = WindowCatalog.OrderEntry
    /// The viewed display, and a second display to its left.
    static let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let other = CGRect(x: -1920, y: 0, width: 1920, height: 1080)

    static func e(_ id: UInt32, pid: pid_t, layer: Int = 0, on frame: CGRect = display,
                  w: CGFloat = 800, h: CGFloat = 600) -> E {
        E(id: id, pid: pid, layer: layer, size: CGSize(width: w, height: h), origin: CGPoint(x: frame.minX + 50, y: frame.minY + 50))
    }

    static func pick(_ frontPid: pid_t?, _ order: [E], _ pickable: Set<UInt32>) -> UInt32? {
        WindowCatalog.frontWindowId(onDisplay: display, frontPid: frontPid, order: order, pickable: pickable)
    }

    @Test func theFrontAppsWindowOnThisDisplay() {
        // Window 2 of another app is above, but the front app's (pid 20) window 3 wins.
        let order = [Self.e(1, pid: 20, layer: 25), Self.e(2, pid: 10), Self.e(3, pid: 20), Self.e(4, pid: 20)]
        #expect(Self.pick(20, order, [1, 2, 3, 4]) == 3)
    }

    @Test func frontAppOnAnotherDisplayFallsBackToTheTopmostHere() {
        let order = [Self.e(5, pid: 20, on: Self.other), Self.e(6, pid: 30, layer: 3), Self.e(7, pid: 10), Self.e(8, pid: 20)]
        #expect(Self.pick(20, order, [5, 6, 7, 8]) == 7)
        // No front app known: the topmost window here.
        #expect(Self.pick(nil, order, [5, 6, 7, 8]) == 7)
    }

    @Test func aWindowCountsForTheDisplayItsCentreIsOn() {
        // Mostly on the other display; its top-left corner is on this one, its centre is not.
        let straddling = E(id: 9, pid: 20, layer: 0, size: CGSize(width: 1000, height: 600), origin: CGPoint(x: -900, y: 10))
        #expect(Self.pick(20, [straddling], [9]) == nil)
        let mostlyHere = E(id: 9, pid: 20, layer: 0, size: CGSize(width: 1000, height: 600), origin: CGPoint(x: -400, y: 10))
        #expect(Self.pick(20, [mostlyHere], [9]) == 9)
    }

    @Test func noWindowOnThisDisplay() {
        #expect(Self.pick(20, [], []) == nil)
        let order = [Self.e(5, pid: 20, on: Self.other), Self.e(6, pid: 10, layer: 25), Self.e(7, pid: 10, w: 30, h: 30)]
        #expect(Self.pick(20, order, [5, 6, 7]) == nil, "other display, not layer 0, too small")
    }

    @Test func onlyWindowsTheListCouldShow() {
        // Window 1 is ours (or another window the list excludes): not in `pickable`.
        let order = [Self.e(1, pid: 99), Self.e(2, pid: 10)]
        #expect(Self.pick(99, order, [2]) == 2)
        #expect(Self.pick(99, order, []) == nil)
    }

    @Test func decodesAndEncodesTheFrontMessages() throws {
        #expect(try ClientMessage.decode(Data(#"{"t":"view.front","displayId":69733378}"#.utf8), on: .socket)
                == .viewFront(displayId: 69733378))
        #expect(throws: ProtocolError.invalidValue("displayId")) { try ClientMessage.decode(Data(#"{"t":"view.front"}"#.utf8)) }
        #expect(throws: ProtocolError.wrongChannel("view.front")) {
            try ClientMessage.decode(Data(#"{"t":"view.front","displayId":1}"#.utf8), on: .control)
        }
        func object(_ m: ServerMessage) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(m.jsonString().utf8)) as! [String: Any]
        }
        let found = try object(.viewFrontResult(displayId: 2, window: WindowItem(id: 7, pid: 1, app: "Editor", title: "Notes", w: 800, h: 600)))
        #expect(found["t"] as? String == "view.front.result" && found["displayId"] as? Int == 2)
        #expect(found["windowId"] as? Int == 7 && found["app"] as? String == "Editor" && found["title"] as? String == "Notes")
        let none = try object(.viewFrontResult(displayId: 2, window: nil))
        #expect(none["t"] as? String == "view.front.result" && none["displayId"] as? Int == 2 && none["windowId"] == nil)
    }
}
