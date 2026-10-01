import AppKit

// Text copied on the Mac goes to the viewing device (DESIGN.md D51). While a session is
// connected it polls the pasteboard's change count; only a change is read, and only as text.

/// The Mac pasteboard as the clipboard watch sees it. `SystemPasteboard` is the real one;
/// tests use a fake, so no test reads or writes the real clipboard.
protocol PasteboardReading: Sendable {
    /// Changes whenever any app (or our own D36 paste) sets the pasteboard. Reading it does not
    /// read the contents.
    var changeCount: Int { get }
    /// The change count our own D36 paste produced last, or nil; that change is not sent back.
    var ownWriteChangeCount: Int? { get }
    /// The current item's types, e.g. `public.utf8-plain-text`, `org.nspasteboard.ConcealedType`.
    var types: [String] { get }
    /// The current item as `.string`, or nil if it has no text.
    func string() -> String?
}

/// Decides what a pasteboard change sends (D51): nothing before the first change after
/// connect, nothing for our own paste or for concealed/transient items (password managers),
/// text up to 1 MiB of UTF-8, and a `truncated` flag without text above that.
struct MacClipboardWatch {
    /// The D11 limit for clipboard text.
    static let maxBytes = BinaryClientMessage.maxClipboardBytes
    /// Marker types from nspasteboard.org that password managers set on secrets.
    static let skippedTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
    static let pollInterval: Duration = .milliseconds(500)

    private var lastChangeCount: Int
    private var seq = 0

    /// The clipboard as it is at connect is the baseline and is never sent.
    init(baseline pasteboard: any PasteboardReading) {
        lastChangeCount = pasteboard.changeCount
    }

    /// One poll: the `clipboard.mac` message for a new copy, or nil.
    mutating func poll(_ pasteboard: any PasteboardReading) -> ServerMessage? {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return nil }
        lastChangeCount = count
        if pasteboard.ownWriteChangeCount == count { return nil }
        if !Self.skippedTypes.isDisjoint(with: pasteboard.types) { return nil }
        guard let text = pasteboard.string(), !text.isEmpty else { return nil }
        // Changed again while reading: the next poll reads the newer item.
        guard pasteboard.changeCount == count else { return nil }
        seq += 1
        if text.utf8.count > Self.maxBytes { return .clipboardMac(seq: seq, text: nil) }
        return .clipboardMac(seq: seq, text: text)
    }
}

/// `NSPasteboard.general`. The D36 paste writes through `setForPaste`, which records the
/// resulting change count under the same lock the change count is read with, so the watch
/// never sees our write without also seeing that it is ours.
final class SystemPasteboard: PasteboardReading, @unchecked Sendable {
    static let shared = SystemPasteboard()

    private let lock = NSLock()
    private var ownWrite: Int?

    var changeCount: Int { lock.withLock { NSPasteboard.general.changeCount } }
    var ownWriteChangeCount: Int? { lock.withLock { ownWrite } }
    var types: [String] { (NSPasteboard.general.types ?? []).map(\.rawValue) }
    func string() -> String? { NSPasteboard.general.string(forType: .string) }

    /// Sets the pasteboard to `text` for a D36 paste and remembers the change as ours.
    func setForPaste(_ text: String) {
        lock.withLock {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            ownWrite = pasteboard.changeCount
        }
    }
}
