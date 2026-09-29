import Carbon.HIToolbox
import CoreGraphics

/// Key name → `kVK_*` virtual key code (DESIGN.md §4.3, D34). Letters, digits, and
/// punctuation use ANSI key positions.
enum KeyMap {
    private static let table: [String: Int] = [
        "Enter": kVK_Return,
        "Tab": kVK_Tab,
        "Escape": kVK_Escape,
        "Backspace": kVK_Delete,
        "Delete": kVK_ForwardDelete,
        "Space": kVK_Space,
        "ArrowLeft": kVK_LeftArrow,
        "ArrowRight": kVK_RightArrow,
        "ArrowUp": kVK_UpArrow,
        "ArrowDown": kVK_DownArrow,
        "Home": kVK_Home,
        "End": kVK_End,
        "PageUp": kVK_PageUp,
        "PageDown": kVK_PageDown,
        "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4,
        "F5": kVK_F5, "F6": kVK_F6, "F7": kVK_F7, "F8": kVK_F8,
        "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "F12": kVK_F12,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
    ]

    /// Every accepted key name.
    static var names: Set<String> { Set(table.keys) }

    static func keyCode(for name: String) -> CGKeyCode? {
        table[name].map { CGKeyCode($0) }
    }
}

/// A modifier in a `key` message's `mods` (§4.3, D34). Case order is the order the
/// modifier keys go down.
enum KeyModifier: String, CaseIterable, Sendable {
    case cmd, ctrl, opt, shift

    var keyCode: CGKeyCode {
        switch self {
        case .cmd: return CGKeyCode(kVK_Command)
        case .ctrl: return CGKeyCode(kVK_Control)
        case .opt: return CGKeyCode(kVK_Option)
        case .shift: return CGKeyCode(kVK_Shift)
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .cmd: return .maskCommand
        case .ctrl: return .maskControl
        case .opt: return .maskAlternate
        case .shift: return .maskShift
        }
    }
}

/// One keyboard event of a key combo.
struct KeyStroke: Equatable {
    var keyCode: CGKeyCode
    var down: Bool
    var flags: CGEventFlags

    static func == (a: KeyStroke, b: KeyStroke) -> Bool {
        a.keyCode == b.keyCode && a.down == b.down && a.flags.rawValue == b.flags.rawValue
    }
}

extension KeyMap {
    /// The events for `code` with `mods` (D9): modifier downs with cumulative flags, the key
    /// down and up with all flags, then modifier ups in reverse order.
    static func strokes(_ code: CGKeyCode, mods: [KeyModifier]) -> [KeyStroke] {
        var out: [KeyStroke] = []
        var flags: CGEventFlags = []
        for m in mods {
            flags.insert(m.flag)
            out.append(KeyStroke(keyCode: m.keyCode, down: true, flags: flags))
        }
        out.append(KeyStroke(keyCode: code, down: true, flags: flags))
        out.append(KeyStroke(keyCode: code, down: false, flags: flags))
        for m in mods.reversed() {
            flags.remove(m.flag)
            out.append(KeyStroke(keyCode: m.keyCode, down: false, flags: flags))
        }
        return out
    }
}
