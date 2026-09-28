import Testing
@testable import MacWindowRemote

@Suite struct TextChunkerTests {
    func texts(_ s: String) -> [String] {
        TextChunker.pieces(s).compactMap { if case .text(let t) = $0 { t } else { nil } }
    }

    @Test func chunksAreAtMostTwentyUTF16AndRejoinExactly() {
        let s = String(repeating: "日本語テキスト", count: 10)
        let chunks = texts(s)
        #expect(chunks.allSatisfy { $0.utf16.count <= TextChunker.maxUTF16 })
        #expect(chunks.joined() == s)
    }

    @Test func emojiAndZWJSequencesAreNeverSplit() {
        let family = "👨‍👩‍👧‍👦" // 11 UTF-16 units
        let s = String(repeating: "a", count: 15) + family + "🇯🇵" + family
        let chunks = texts(s)
        #expect(chunks.joined() == s)
        #expect(chunks.allSatisfy { $0.utf16.count <= TextChunker.maxUTF16 })
        // Grapheme clusters of the whole text equal the clusters of the chunks, in order,
        // so no chunk boundary falls inside a cluster.
        let clustersOfChunks: [Character] = chunks.flatMap { Array($0) }
        #expect(clustersOfChunks == Array(s))
    }

    @Test func combiningMarksStayWithTheirBase() {
        let e = "e\u{0301}" // é as base + combining acute
        let s = String(repeating: "x", count: 19) + e + "z"
        let chunks = texts(s)
        #expect(chunks.joined() == s)
        #expect(chunks.first == String(repeating: "x", count: 19))
        #expect(chunks[1].hasPrefix(e))
    }

    @Test func newlineAndTabBecomeKeys() {
        #expect(TextChunker.pieces("a\nb\tc") == [.text("a"), .key("Enter"), .text("b"), .key("Tab"), .text("c")])
        #expect(TextChunker.pieces("a\r\nb") == [.text("a"), .key("Enter"), .text("b")])
    }
}
