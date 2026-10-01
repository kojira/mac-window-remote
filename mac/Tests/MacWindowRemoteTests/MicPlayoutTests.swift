import Foundation
import Testing
@testable import MacWindowRemote

/// D57: the viewing device's microphone plays into BlackHole. Fake device lists and sinks
/// only; nothing here enumerates or opens a Core Audio device.
struct MicPlayoutTests {
    private func device(_ id: UInt32, _ name: String, _ channels: Int) -> AudioOutputDevice {
        AudioOutputDevice(id: id, name: name, outputChannels: channels)
    }

    @Test func picksABlackHoleOutputPreferringTwoChannels() {
        let speakers = device(1, "Built-in Output", 2)
        let bh16 = device(2, "BlackHole 16ch", 16)
        let bh2 = device(3, "BlackHole 2ch", 2)
        #expect(BlackHoleSelection.pick([speakers, bh16, bh2]) == bh2)
        #expect(BlackHoleSelection.pick([speakers, bh16]) == bh16)
        #expect(BlackHoleSelection.pick([bh16, device(4, "BlackHole 64ch", 64)]) == bh16)
        // The prefix is matched at the start, case-sensitively, and needs output channels.
        #expect(BlackHoleSelection.pick([speakers, device(5, "My BlackHole", 2), device(6, "blackhole 2ch", 2)]) == nil)
        #expect(BlackHoleSelection.pick([device(7, "BlackHole 2ch", 0)]) == nil)
        #expect(BlackHoleSelection.pick([]) == nil)
    }

    private final class FakeSink: PlayoutSink {
        var stopped = 0
        func stop() { stopped += 1 }
    }

    private final class Opened: @unchecked Sendable {
        var devices: [AudioOutputDevice] = []
        var sinks: [FakeSink] = []
    }

    @Test func onOpensTheDeviceOnceAndOffStopsIt() {
        let opened = Opened()
        let mic = MicPlayout(listDevices: { [self] in [device(1, "Built-in Output", 2), device(3, "BlackHole 2ch", 2)] },
                             openSink: { d in
                                 opened.devices.append(d)
                                 let sink = FakeSink()
                                 opened.sinks.append(sink)
                                 return sink
                             })
        #expect(mic.set(true) == .on(device: "BlackHole 2ch"))
        #expect(mic.set(true) == .on(device: "BlackHole 2ch"))
        #expect(opened.devices.map(\.id) == [3], "never the default output, and only once")
        #expect(mic.set(false) == .off)
        #expect(opened.sinks.map(\.stopped) == [1])
        #expect(mic.set(false) == .off)
        #expect(opened.sinks.map(\.stopped) == [1])
        #expect(mic.set(true) == .on(device: "BlackHole 2ch"))
        #expect(opened.sinks.count == 2)
    }

    @Test func withoutBlackHoleTheReplyIsNoDevice() {
        let opened = Opened()
        let mic = MicPlayout(listDevices: { [self] in [device(1, "Built-in Output", 2)] },
                             openSink: { d in opened.devices.append(d); return FakeSink() })
        #expect(mic.set(true) == .noDevice)
        #expect(opened.devices.isEmpty)
    }

    @Test func aDeviceThatCannotOpenFails() {
        struct Refused: Error {}
        let mic = MicPlayout(listDevices: { [self] in [device(3, "BlackHole 2ch", 2)] }, openSink: { _ in throw Refused() })
        #expect(mic.set(true) == .failed)
        #expect(mic.set(false) == .off)
    }

    /// The pump pulls exact 10 ms frames and fills buffers of any size, duplicating mono.
    @Test func pumpPullsTenMillisecondFramesIntoAFakeSink() {
        var pulls: [Int] = []
        var next: Int16 = 0
        let pump = PlayoutPump(channels: 2) { buffer, frames in
            pulls.append(frames)
            for i in 0..<frames { buffer[i] = next; next &+= 1 }
        }
        var rendered: [Int16] = []
        for size in [512, 512, 128, 1000] {
            var out = [Int16](repeating: -1, count: size * 2)
            out.withUnsafeMutableBufferPointer { pump.render($0.baseAddress!, frames: size) }
            rendered += out
        }
        #expect(pulls.allSatisfy { $0 == AudioChunker.chunkFrames })
        // 2152 frames need five 480-frame pulls.
        #expect(pulls.count == 5)
        let left = stride(from: 0, to: rendered.count, by: 2).map { rendered[$0] }
        let right = stride(from: 1, to: rendered.count, by: 2).map { rendered[$0] }
        #expect(left == right)
        #expect(left == (0..<2152).map { Int16($0) }, "continuous, nothing dropped or repeated")
    }

    /// Without WebRTC playing (no delegate), the device yields silence.
    @Test func playoutIsSilentUntilWebRTCPlays() {
        let device = TapAudioDevice()
        var samples = [Int16](repeating: 7, count: AudioChunker.chunkFrames)
        samples.withUnsafeMutableBufferPointer { device.pullPlayout($0.baseAddress!, frames: $0.count) }
        #expect(samples.allSatisfy { $0 == 0 })
        device.outputThreadWillChange()
    }

    @Test func micProtocol() throws {
        #expect(try ClientMessage.decode(Data(#"{"t":"mic","on":true}"#.utf8), on: .control) == .mic(on: true))
        #expect(try ClientMessage.decode(Data(#"{"t":"mic","on":false}"#.utf8), on: .control) == .mic(on: false))
        #expect(throws: ProtocolError.invalidValue("on")) { try ClientMessage.decode(Data(#"{"t":"mic"}"#.utf8)) }
        #expect(throws: ProtocolError.malformed) { try ClientMessage.decode(Data(#"{"t":"mic","on":"yes"}"#.utf8)) }
        #expect(throws: ProtocolError.wrongChannel("mic")) {
            try ClientMessage.decode(Data(#"{"t":"mic","on":true}"#.utf8), on: .socket)
        }
        func json(_ outcome: MicOutcome) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(ServerMessage.micState(outcome).jsonString().utf8)) as! [String: Any]
        }
        let on = try json(.on(device: "BlackHole 2ch"))
        #expect(on["t"] as? String == "mic.state" && on["on"] as? Bool == true && on["device"] as? String == "BlackHole 2ch")
        #expect(on["error"] == nil)
        let off = try json(.off)
        #expect(off["on"] as? Bool == false && off["device"] == nil && off["error"] == nil)
        let none = try json(.noDevice)
        #expect(none["on"] as? Bool == false && none["error"] as? String == "no-device")
        #expect(try json(.failed)["error"] as? String == "failed")
    }
}
