import CoreGraphics

/// What a session views (D56): one window (the original mode) or a whole display.
enum ViewTarget: Equatable, Sendable {
    case window(UInt32)
    case display(UInt32)

    var windowId: UInt32? {
        if case .window(let id) = self { return id }
        return nil
    }
}

/// Display-mode geometry (D56). Display frames are global CG coordinates in points (top-left
/// origin of the main display); other displays can sit at negative or offset origins and have
/// their own scale, which input never needs because it works in points.
enum DisplayGeometry {
    /// The Mac pointer `mouse` as a cursor on the display `frame`. A pointer on another display
    /// is clamped to the nearest edge of this one (D56: clamp rather than hide).
    static func cursor(at mouse: CGPoint, in frame: CGRect) -> CursorState {
        guard frame.width > 0, frame.height > 0 else { return CursorState() }
        var c = CursorState(u: 0, v: 0)
        c.apply(dx: Double((mouse.x - frame.minX) / frame.width), dy: Double((mouse.y - frame.minY) / frame.height))
        return c
    }
}

/// The event posts of display-mode input (D56). There is deliberately no raise or activate
/// here: events go to the point, and keys to whatever has focus on the Mac.
protocol DisplayEventPoster: Sendable {
    func move(to p: CGPoint) async
    func click(at p: CGPoint, clickState: Int) async
    func rightClick(at p: CGPoint) async
    func buttonDown(_ button: CGMouseButton, at p: CGPoint, clickState: Int) async
    func buttonUp(_ button: CGMouseButton, at p: CGPoint, clickState: Int) async
    func scroll(at p: CGPoint, dx: Double, dy: Double) async
    func key(_ name: String, mods: [KeyModifier]) async
    func type(_ text: String) async
    /// Puts the text on the Mac clipboard (as our own change, D51) and presses ⌘V.
    func paste(_ text: String) async
}

enum DisplayInput {
    /// Posts one input at the cursor on the display `frame`. `clickState` is the click count
    /// for `.click` (D26). A menu press has no app in display mode (☰ is hidden).
    static func perform(_ action: InputAction, frame: CGRect, clickState: Int,
                        poster: any DisplayEventPoster) async -> ErrorCode? {
        let p = action.cursor.globalPoint(in: frame)
        switch action.kind {
        case .move: await poster.move(to: p)
        case .click: await poster.click(at: p, clickState: clickState)
        case .rightClick: await poster.rightClick(at: p)
        case .dragStart: await poster.buttonDown(.left, at: p, clickState: 1)
        case .dragEnd: await poster.buttonUp(.left, at: p, clickState: 1)
        case .mouseButton(let button, let down, let clicks):
            let cgButton: CGMouseButton = switch button {
            case .left: .left
            case .right: .right
            case .middle: .center
            }
            if down {
                await poster.buttonDown(cgButton, at: p, clickState: clicks)
            } else {
                await poster.buttonUp(cgButton, at: p, clickState: clicks)
            }
        case .scroll(let du, let dv):
            await poster.scroll(at: p, dx: du * frame.width, dy: dv * frame.height)
        case .text(let text): await poster.type(text)
        case .key(let name, let mods): await poster.key(name, mods: mods)
        case .paste(let text): await poster.paste(text)
        case .menuPress: return .menuUnavailable
        }
        return nil
    }
}
