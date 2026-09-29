import CoreGraphics
import Testing
@testable import MacWindowRemote

/// The Mac-owned cursor (D24) and click counting (D26).
@Suite struct CursorStateTests {
    let bounds = CGRect(x: 100, y: 80, width: 1280, height: 800)

    @Test func startsAtCenter() {
        #expect(CursorState().globalPoint(in: bounds) == CGPoint(x: 740, y: 480))
    }

    @Test func appliesDeltas() {
        var c = CursorState()
        c.apply(dx: 0.1, dy: -0.25)
        #expect(c == CursorState(u: 0.6, v: 0.25))
        c.apply(dx: -0.2, dy: 0.05)
        #expect(abs(c.u - 0.4) < 1e-12 && abs(c.v - 0.3) < 1e-12)
    }

    @Test func clampsAtEveryEdge() {
        var c = CursorState()
        c.apply(dx: -0.9, dy: 0)
        #expect(c.u == 0)
        c.apply(dx: 2, dy: 0)
        #expect(c.u == 1)
        c.apply(dx: 0, dy: -0.8)
        #expect(c.v == 0)
        c.apply(dx: 0, dy: 1.7)
        #expect(c.v == 1)
        // Moving back after hitting an edge moves right away (no accumulated overshoot).
        c.apply(dx: -0.1, dy: -0.1)
        #expect(abs(c.u - 0.9) < 1e-12 && abs(c.v - 0.9) < 1e-12)
    }

    @Test func edgesMapInsideTheWindow() {
        #expect(CursorState(u: 0, v: 0).globalPoint(in: bounds) == CGPoint(x: 100, y: 80))
        #expect(CursorState(u: 1, v: 1).globalPoint(in: bounds) == CGPoint(x: 1379, y: 879))
    }

    @Test func movedWindowKeepsTheRelativePlace() {
        let c = CursorState(u: 0.25, v: 0.5)
        #expect(c.globalPoint(in: bounds) == CGPoint(x: 420, y: 480))
        let moved = CGRect(x: 400, y: 300, width: 1280, height: 800)
        #expect(c.globalPoint(in: moved) == CGPoint(x: 720, y: 700))
        let resized = CGRect(x: 100, y: 80, width: 640, height: 400)
        #expect(c.globalPoint(in: resized) == CGPoint(x: 260, y: 280))
    }

    @Test func clickCountTiming() {
        var counter = ClickCounter()
        let p = CGPoint(x: 10, y: 10)
        #expect(counter.register(at: p, time: 0, interval: 0.5) == 1)
        #expect(counter.register(at: p, time: 0.3, interval: 0.5) == 2)
        #expect(counter.register(at: p, time: 0.6, interval: 0.5) == 3)
        // Too late: starts over.
        #expect(counter.register(at: p, time: 1.2, interval: 0.5) == 1)
    }

    @Test func clickCountDistance() {
        var counter = ClickCounter()
        #expect(counter.register(at: CGPoint(x: 10, y: 10), time: 0, interval: 0.5) == 1)
        #expect(counter.register(at: CGPoint(x: 13, y: 10), time: 0.1, interval: 0.5) == 2)
        #expect(counter.register(at: CGPoint(x: 20, y: 10), time: 0.2, interval: 0.5) == 1)
        counter.reset()
        #expect(counter.register(at: CGPoint(x: 20, y: 10), time: 0.3, interval: 0.5) == 1)
    }
}
