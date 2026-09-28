import Carbon.HIToolbox

/// Key name → `kVK_*` virtual key code (DESIGN.md §4.3).
/// Slice 1 only sends Return and Backspace from the phone, plus Tab for `\t` inside text.
/// The full §4.3 table arrives with the key bar in slice 4.
enum KeyMap {
    private static let table: [String: Int] = [
        "Enter": kVK_Return,
        "Tab": kVK_Tab,
        "Backspace": kVK_Delete,
    ]

    static func keyCode(for name: String) -> CGKeyCode? {
        table[name].map { CGKeyCode($0) }
    }
}
