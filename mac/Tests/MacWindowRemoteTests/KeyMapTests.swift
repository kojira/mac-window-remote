import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import MacWindowRemote

@Suite struct KeyMapTests {
    /// §4.3 / D34: every key name the phone can send maps to its virtual key.
    @Test func coversEveryKeyName() {
        var names = ["Enter", "Tab", "Escape", "Backspace", "Delete", "Space",
                     "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
                     "Home", "End", "PageUp", "PageDown"]
        names += (1...12).map { "F\($0)" }
        names += "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init)
        names += ["-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`"]
        #expect(KeyMap.names == Set(names))
        #expect(KeyMap.keyCode(for: "Delete") == CGKeyCode(kVK_ForwardDelete))
        #expect(KeyMap.keyCode(for: "Backspace") == CGKeyCode(kVK_Delete))
        #expect(KeyMap.keyCode(for: "F12") == CGKeyCode(kVK_F12))
        #expect(KeyMap.keyCode(for: "PageDown") == CGKeyCode(kVK_PageDown))
        #expect(KeyMap.keyCode(for: "c") == CGKeyCode(kVK_ANSI_C))
        #expect(KeyMap.keyCode(for: "`") == CGKeyCode(kVK_ANSI_Grave))
        #expect(KeyMap.keyCode(for: "C") == nil)
    }

    /// D9: modifier downs with cumulative flags, the key with all flags, modifier ups reversed.
    @Test func comboEventOrder() {
        let c = CGKeyCode(kVK_ANSI_C)
        let cmd = CGKeyCode(kVK_Command), shift = CGKeyCode(kVK_Shift)
        #expect(KeyMap.strokes(c, mods: [.cmd, .shift]) == [
            KeyStroke(keyCode: cmd, down: true, flags: .maskCommand),
            KeyStroke(keyCode: shift, down: true, flags: [.maskCommand, .maskShift]),
            KeyStroke(keyCode: c, down: true, flags: [.maskCommand, .maskShift]),
            KeyStroke(keyCode: c, down: false, flags: [.maskCommand, .maskShift]),
            KeyStroke(keyCode: shift, down: false, flags: .maskCommand),
            KeyStroke(keyCode: cmd, down: false, flags: []),
        ])
        #expect(KeyMap.strokes(c, mods: []) == [
            KeyStroke(keyCode: c, down: true, flags: []),
            KeyStroke(keyCode: c, down: false, flags: []),
        ])
    }
}
