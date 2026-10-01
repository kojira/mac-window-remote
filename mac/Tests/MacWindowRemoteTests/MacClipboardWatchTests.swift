import Foundation
import Testing
@testable import MacWindowRemote

/// A pasteboard in memory; `copy` is another app copying, `pasteFromDevice` is our D36 paste.
private final class FakePasteboard: PasteboardReading, @unchecked Sendable {
    var changeCount = 10
    var ownWriteChangeCount: Int?
    var types: [String] = ["public.utf8-plain-text"]
    var text: String? = "before connect"
    func string() -> String? { text }

    func copy(_ text: String?, types: [String] = ["public.utf8-plain-text"]) {
        changeCount += 1
        self.text = text
        self.types = types
    }

    func pasteFromDevice(_ text: String) {
        copy(text)
        ownWriteChangeCount = changeCount
    }
}

@Suite struct MacClipboardWatchTests {
    func json(_ m: ServerMessage?) throws -> [String: Any] {
        let m = try #require(m)
        return try JSONSerialization.jsonObject(with: Data(m.jsonString().utf8)) as! [String: Any]
    }

    @Test func clipboardAtConnectIsNotSent() {
        let pb = FakePasteboard()
        var watch = MacClipboardWatch(baseline: pb)
        #expect(watch.poll(pb) == nil)
        #expect(watch.poll(pb) == nil)
    }

    @Test func aNewCopyIsSentOnceWithRisingSeq() throws {
        let pb = FakePasteboard()
        var watch = MacClipboardWatch(baseline: pb)
        pb.copy("こんにちは")
        let first = try json(watch.poll(pb))
        #expect(first["t"] as? String == "clipboard.mac")
        #expect(first["seq"] as? Int == 1)
        #expect(first["text"] as? String == "こんにちは")
        #expect(first["truncated"] == nil)
        #expect(watch.poll(pb) == nil)
        pb.copy("next")
        #expect(try json(watch.poll(pb))["seq"] as? Int == 2)
    }

    @Test func ownPasteIsNotSentBack() throws {
        let pb = FakePasteboard()
        var watch = MacClipboardWatch(baseline: pb)
        pb.pasteFromDevice("from the device")
        #expect(watch.poll(pb) == nil)
        pb.copy("copied on the Mac")
        #expect(try json(watch.poll(pb))["text"] as? String == "copied on the Mac")
    }

    @Test func concealedTransientAndNonTextAreSkipped() throws {
        let pb = FakePasteboard()
        var watch = MacClipboardWatch(baseline: pb)
        pb.copy("secret", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        #expect(watch.poll(pb) == nil)
        pb.copy("otp", types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"])
        #expect(watch.poll(pb) == nil)
        pb.copy(nil, types: ["public.png"])
        #expect(watch.poll(pb) == nil)
        pb.copy("")
        #expect(watch.poll(pb) == nil)
        pb.copy("ok")
        #expect(try json(watch.poll(pb))["seq"] as? Int == 1)
    }

    @Test func textOverOneMiBIsFlaggedWithoutText() throws {
        let pb = FakePasteboard()
        var watch = MacClipboardWatch(baseline: pb)
        pb.copy(String(repeating: "a", count: MacClipboardWatch.maxBytes))
        #expect(try json(watch.poll(pb))["text"] as? String != nil)
        pb.copy(String(repeating: "a", count: MacClipboardWatch.maxBytes + 1))
        let big = try json(watch.poll(pb))
        #expect(big["truncated"] as? Bool == true)
        #expect(big["text"] == nil)
        #expect(big["seq"] as? Int == 2)
    }

    @Test func encodesClipboardMac() throws {
        let small = try json(.clipboardMac(seq: 3, text: "hi"))
        #expect(small["t"] as? String == "clipboard.mac" && small["seq"] as? Int == 3)
        #expect(small["text"] as? String == "hi" && small["truncated"] == nil)
        let big = try json(.clipboardMac(seq: 4, text: nil))
        #expect(big["truncated"] as? Bool == true && big["text"] == nil && big["seq"] as? Int == 4)
    }
}
