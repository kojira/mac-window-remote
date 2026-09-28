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

    /// Whether a drag holds the left button (D26).
    private(set) static var leftButtonHeld = false
    private static var lastPoint: CGPoint?

    private static func mouse(_ type: CGEventType, at p: CGPoint, button: CGMouseButton = .left, clickState: Int = 1) {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        e?.post(tap: tap)
        lastPoint = p
    }

    /// `mouseMoved`, or `leftMouseDragged` while a drag holds the button.
    static func move(to p: CGPoint) {
        mouse(leftButtonHeld ? .leftMouseDragged : .mouseMoved, at: p)
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
        guard !leftButtonHeld else { return }
        move(to: p)
        mouse(.leftMouseDown, at: p)
        leftButtonHeld = true
    }

    static func dragEnd(at p: CGPoint) {
        guard leftButtonHeld else { return }
        move(to: p)
        mouse(.leftMouseUp, at: p)
        leftButtonHeld = false
    }

    /// Releases a held button at the last posted point, so it is never left stuck (D26).
    static func releaseButton() {
        guard leftButtonHeld, let p = lastPoint else { leftButtonHeld = false; return }
        mouse(.leftMouseUp, at: p)
        leftButtonHeld = false
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

    static func key(_ name: String) {
        guard let code = KeyMap.keyCode(for: name) else { return }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = []
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
