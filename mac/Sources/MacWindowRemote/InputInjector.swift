import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Posts CGEvents at the Mac-owned cursor (DESIGN.md D9, amended by D26). Callers serialize
/// discrete inputs; motion may interleave between them.
/// Runs on the main actor because the Text Input Source APIs require the main thread.
@MainActor
enum InputInjector {
    /// Time for an input source switch to take effect before posting, and for posted key
    /// events to be consumed before the previous source is restored.
    static let inputSourceSettle: Duration = .milliseconds(60)

    private static var source: CGEventSource? { CGEventSource(stateID: .hidSystemState) }
    private static let tap = CGEventTapLocation.cghidEventTap

    /// The button a drag (D26) or a desktop mouse (D45) holds down, if any.
    private(set) static var heldButton: CGMouseButton?
    private static var lastPoint: CGPoint?

    private static func mouse(_ type: CGEventType, at p: CGPoint, button: CGMouseButton = .left, clickState: Int = 1) {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        e?.post(tap: tap)
        lastPoint = p
    }

    /// Event types for a button's down, up, and dragged events.
    private static func types(_ button: CGMouseButton) -> (down: CGEventType, up: CGEventType, dragged: CGEventType) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        default: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
    }

    /// `mouseMoved`, or the held button's dragged event.
    static func move(to p: CGPoint) {
        if let held = heldButton {
            mouse(types(held).dragged, at: p, button: held)
        } else {
            mouse(.mouseMoved, at: p)
        }
    }

    /// `clickState` is 2 or 3 for quick successive clicks at one place (D26).
    static func click(at p: CGPoint, clickState: Int) {
        move(to: p)
        mouse(.leftMouseDown, at: p, clickState: clickState)
        mouse(.leftMouseUp, at: p, clickState: clickState)
    }

    static func rightClick(at p: CGPoint) {
        move(to: p)
        mouse(.rightMouseDown, at: p, button: .right)
        mouse(.rightMouseUp, at: p, button: .right)
    }

    static func dragStart(at p: CGPoint) {
        buttonDown(.left, at: p, clickState: 1)
    }

    static func dragEnd(at p: CGPoint) {
        buttonUp(.left, at: p, clickState: 1)
    }

    /// A desktop mouse button goes down (D45). Only one button is held at a time; another
    /// button's down while one is held is ignored.
    static func buttonDown(_ button: CGMouseButton, at p: CGPoint, clickState: Int) {
        guard heldButton == nil else { return }
        move(to: p)
        mouse(types(button).down, at: p, button: button, clickState: clickState)
        heldButton = button
    }

    static func buttonUp(_ button: CGMouseButton, at p: CGPoint, clickState: Int) {
        guard heldButton == button else { return }
        move(to: p)
        mouse(types(button).up, at: p, button: button, clickState: clickState)
        heldButton = nil
    }

    /// Releases a held button at the last posted point, so it is never left stuck (D26).
    static func releaseButton() {
        guard let held = heldButton, let p = lastPoint else { heldButton = nil; return }
        mouse(types(held).up, at: p, button: held)
        heldButton = nil
    }

    /// Deltas in points of finger movement. Content follows the finger: a positive wheel value
    /// moves content down, the same direction as a finger moving down (positive dy).
    static func scroll(at p: CGPoint, dx: Double, dy: Double) {
        move(to: p)
        let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                        wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)
        e?.location = p
        e?.post(tap: tap)
    }

    /// A named key, with modifier keys held around it (D9, D34).
    static func key(_ name: String, mods: [KeyModifier] = []) {
        guard let code = KeyMap.keyCode(for: name) else { return }
        for s in KeyMap.strokes(code, mods: mods) {
            let e = CGEvent(keyboardEventSource: source, virtualKey: s.keyCode, keyDown: s.down)
            e?.flags = s.flags
            e?.post(tap: tap)
        }
    }

    /// Types committed text with the ASCII-capable layout selected, so a Mac IME
    /// (e.g. Japanese kana mode) never reinterprets it, then restores the previous source.
    static func type(_ text: String) async {
        let saved = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        let switched = ascii != nil && saved.map { !CFEqual($0, ascii!) } ?? true
        if switched, let ascii {
            TISSelectInputSource(ascii)
            try? await Task.sleep(for: inputSourceSettle)
        }

        for piece in TextChunker.pieces(text) {
            switch piece {
            case .key(let name):
                key(name)
            case .text(let chunk):
                let units = Array(chunk.utf16)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    e?.flags = []
                    units.withUnsafeBufferPointer { buf in
                        e?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                    }
                    e?.post(tap: tap)
                }
            }
        }
        if switched, let saved {
            try? await Task.sleep(for: inputSourceSettle)
            TISSelectInputSource(saved)
        }
    }
}
