/// Splits committed text for CGEvent Unicode injection (DESIGN.md D9).
/// Chunks never split a grapheme cluster and hold at most `maxUTF16` UTF-16 units.
/// `\n` and `\t` become separate key pieces.
enum TextPiece: Equatable {
    case text(String)
    case key(String)
}

enum TextChunker {
    static let maxUTF16 = 20

    static func pieces(_ text: String) -> [TextPiece] {
        var out: [TextPiece] = []
        var current = ""
        func flush() {
            if !current.isEmpty { out.append(.text(current)); current = "" }
        }
        for ch in text {
            if ch == "\n" || ch == "\r\n" || ch == "\r" {
                flush(); out.append(.key("Enter")); continue
            }
            if ch == "\t" {
                flush(); out.append(.key("Tab")); continue
            }
            let s = String(ch)
            if current.utf16.count + s.utf16.count > maxUTF16 { flush() }
            // A single cluster longer than the limit cannot be typed intact; it is sent alone.
            current += s
            if current.utf16.count >= maxUTF16 { flush() }
        }
        flush()
        return out
    }
}
