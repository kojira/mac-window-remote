import CoreAudio
import Testing
@testable import MacWindowRemote

/// D39: the tap's audio conversion, the App mode's process selection, and when the tap runs.
/// Nothing here touches a real audio device.
@Suite struct AudioTests {
    static func format(rate: Double, channels: UInt32, interleaved: Bool) -> AudioStreamBasicDescription {
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        let bytesPerFrame = interleaved ? 4 * channels : 4
        return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                           mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
                                           mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    /// Feeds `buffers` (one array per AudioBuffer) and returns the emitted chunks.
    static func feed(_ chunker: AudioChunker, _ buffers: [[Float]], channelsPerBuffer: UInt32) -> (chunks: [[Int16]], heard: Bool) {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { free(list.unsafeMutablePointer) }
        var storage = buffers.map { b -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, b.count))
            p.initialize(from: b, count: b.count)
            return p
        }
        defer { storage.forEach { $0.deallocate() }; storage.removeAll() }
        for (i, b) in buffers.enumerated() {
            list[i] = AudioBuffer(mNumberChannels: channelsPerBuffer, mDataByteSize: UInt32(b.count * 4), mData: storage[i])
        }
        var chunks: [[Int16]] = []
        let heard = chunker.append(list.unsafePointer) { chunks.append(Array(UnsafeBufferPointer(start: $0, count: AudioChunker.chunkFrames))) }
        return (chunks, heard)
    }

    @Test func interleavedStereoIsDownmixedAndChunkedBy480() throws {
        let chunker = try #require(AudioChunker(format: Self.format(rate: 48_000, channels: 2, interleaved: true)))
        // 700 frames: L = 0.5, R = -0.25 → mono 0.125.
        let frames = [Float](repeating: 0, count: 1400).enumerated().map { $0.offset % 2 == 0 ? Float(0.5) : Float(-0.25) }
        let first = Self.feed(chunker, [frames], channelsPerBuffer: 2)
        #expect(first.heard)
        #expect(first.chunks.count == 1)
        #expect(first.chunks[0].allSatisfy { $0 == Int16((0.125 * 32767).rounded()) })
        // 220 frames were kept; 260 more complete the second chunk.
        let second = Self.feed(chunker, [[Float](repeating: 0, count: 520)], channelsPerBuffer: 2)
        #expect(!second.heard)
        #expect(second.chunks.count == 1)
        #expect(second.chunks[0].prefix(220).allSatisfy { $0 == 4096 })
        #expect(second.chunks[0].suffix(260).allSatisfy { $0 == 0 })
    }

    @Test func nonInterleavedChannelsAreTheLastBuffersAndClipped() throws {
        let chunker = try #require(AudioChunker(format: Self.format(rate: 48_000, channels: 2, interleaved: false)))
        // An aggregate lists sub-device inputs first; the tap's two channels are the last buffers.
        let other = [Float](repeating: 0.9, count: 480)
        let left = [Float](repeating: 1.5, count: 480)
        let right = [Float](repeating: 1.5, count: 480)
        let out = Self.feed(chunker, [other, left, right], channelsPerBuffer: 1)
        #expect(out.chunks.count == 1)
        #expect(out.chunks[0].allSatisfy { $0 == 32767 })
    }

    @Test func otherRatesAreResampledTo48k() throws {
        let chunker = try #require(AudioChunker(format: Self.format(rate: 44_100, channels: 2, interleaved: true)))
        // One second of a 441 Hz tone at 44.1 kHz (100 samples per period).
        var chunks: [[Int16]] = []
        for block in 0..<100 {
            var buffer = [Float](repeating: 0, count: 441 * 2)
            for i in 0..<441 {
                let x = Float(sin(2 * Double.pi * 441 * Double(block * 441 + i) / 44_100)) * 0.5
                buffer[2 * i] = x
                buffer[2 * i + 1] = x
            }
            chunks += Self.feed(chunker, [buffer], channelsPerBuffer: 2).chunks
        }
        // About 48 000 output frames (the converter keeps a few in its filter).
        #expect((97...100).contains(chunks.count))
        let samples = chunks.flatMap { $0 }
        // Same pitch: 441 Hz at 48 kHz is about 108.8 samples per period; count rising zero
        // crossings in the steady middle part.
        let middle = Array(samples[4800..<(4800 + 48_000 / 2)])
        var crossings = 0
        for i in 1..<middle.count where middle[i - 1] < 0 && middle[i] >= 0 { crossings += 1 }
        #expect((219...222).contains(crossings))
        #expect(samples.map { abs(Int($0)) }.max().map { (15_500...16_900).contains($0) } == true)
    }

    @Test func rejectsNonFloatFormats() {
        var f = Self.format(rate: 48_000, channels: 2, interleaved: true)
        f.mFormatFlags = kAudioFormatFlagIsSignedInteger
        f.mBitsPerChannel = 16
        #expect(AudioChunker(format: f) == nil)
    }

    typealias P = AudioProcessSelection.Process

    @Test func appModeTapsTheAppAndItsHelpersByBundlePrefix() {
        let processes = [
            P(object: 10, pid: 100, bundleID: "com.google.Chrome"),
            P(object: 11, pid: 101, bundleID: "com.google.Chrome.helper"),
            P(object: 12, pid: 102, bundleID: "com.google.Chrome.helper.Renderer"),
            P(object: 13, pid: 103, bundleID: "com.google.ChromeCanary"),
            P(object: 14, pid: 104, bundleID: "com.apple.WebKit.GPU"),
            P(object: 15, pid: 105, bundleID: "io.github.kojira.mac-window-remote"),
        ]
        #expect(AudioProcessSelection.objects(bundleID: "com.google.Chrome", pid: 100, ownPid: 105, in: processes) == [10, 11, 12])
    }

    @Test func appModeIncludesTheWindowPidAndWebKitForSafariOnly() {
        let processes = [
            P(object: 20, pid: 200, bundleID: "com.apple.Safari"),
            P(object: 21, pid: 201, bundleID: "com.apple.WebKit.GPU"),
            P(object: 22, pid: 202, bundleID: "com.apple.WebKit.WebContent"),
            P(object: 23, pid: 300, bundleID: ""),
        ]
        #expect(AudioProcessSelection.objects(bundleID: "com.apple.Safari", pid: 200, ownPid: 1, in: processes) == [20, 21])
        #expect(AudioProcessSelection.objects(bundleID: "com.apple.mail", pid: 999, ownPid: 1, in: processes) == [])
        // An app without a bundle ID: its own pid only.
        #expect(AudioProcessSelection.objects(bundleID: nil, pid: 300, ownPid: 1, in: processes) == [23])
        // Never our own process, even if it is the window's.
        #expect(AudioProcessSelection.objects(bundleID: "com.apple.Safari", pid: 200, ownPid: 200, in: processes) == [21])
    }

    @Test func tapRunsOnlyWhileOnAndConnected() {
        #expect(AudioTarget.desired(mode: .off, peerConnected: true, viewedPid: 5) == nil)
        #expect(AudioTarget.desired(mode: .all, peerConnected: false, viewedPid: 5) == nil)
        #expect(AudioTarget.desired(mode: .app, peerConnected: false, viewedPid: 5) == nil)
        #expect(AudioTarget.desired(mode: .all, peerConnected: true, viewedPid: nil) == .wholeMac)
        #expect(AudioTarget.desired(mode: .app, peerConnected: true, viewedPid: 5) == .app(pid: 5))
        #expect(AudioTarget.desired(mode: .app, peerConnected: true, viewedPid: nil) == nil)
    }
}
