import AudioToolbox
import CoreAudio
import Foundation
import os

/// An output-capable Core Audio device, as `BlackHoleSelection` sees it (D57).
struct AudioOutputDevice: Equatable, Sendable {
    let id: AudioObjectID
    let name: String
    let outputChannels: Int
}

/// Picks the virtual device that the viewing device's microphone plays into (D57): the first
/// device whose name starts with "BlackHole" and that has output channels, preferring a
/// 2-channel one when there are several.
enum BlackHoleSelection {
    static let namePrefix = "BlackHole"

    static func pick(_ devices: [AudioOutputDevice]) -> AudioOutputDevice? {
        let candidates = devices.filter { $0.name.hasPrefix(namePrefix) && $0.outputChannels > 0 }
        return candidates.first { $0.outputChannels == 2 } ?? candidates.first
    }
}

/// What `mic {on}` did on the Mac (D57); sent back as `mic.state`.
enum MicOutcome: Equatable, Sendable {
    /// The phone's audio plays into this device.
    case on(device: String)
    case off
    /// No BlackHole output device is installed.
    case noDevice
    /// The device was found but could not be opened.
    case failed
}

/// A running playout into an output device; `stop()` ends it for good.
protocol PlayoutSink: AnyObject {
    func stop()
}

/// Turns the viewing device's microphone into a Mac input (D57): while on, the audio WebRTC
/// receives is played into the BlackHole output device, never into the default output.
/// Device listing and opening are injected, so tests use fakes and never touch Core Audio.
final class MicPlayout: @unchecked Sendable {
    private let listDevices: () -> [AudioOutputDevice]
    private let openSink: (AudioOutputDevice) throws -> any PlayoutSink
    private let queue = DispatchQueue(label: "mac-window-remote.mic-playout")
    // On `queue` only.
    private var sink: (any PlayoutSink)?
    private var device: AudioOutputDevice?

    init(listDevices: @escaping () -> [AudioOutputDevice],
         openSink: @escaping (AudioOutputDevice) throws -> any PlayoutSink) {
        self.listDevices = listDevices
        self.openSink = openSink
    }

    /// Starts (once) or stops playout. Calls are applied in order.
    func set(_ on: Bool) -> MicOutcome {
        queue.sync {
            guard on else {
                stop()
                return .off
            }
            if let device, sink != nil { return .on(device: device.name) }
            guard let picked = BlackHoleSelection.pick(listDevices()) else {
                log.info("mic playout: no BlackHole device")
                return .noDevice
            }
            do {
                sink = try openSink(picked)
                device = picked
                log.info("mic playout started device=\(picked.name, privacy: .public)")
                return .on(device: picked.name)
            } catch {
                log.error("mic playout failed: \(String(describing: error), privacy: .public)")
                return .failed
            }
        }
    }

    private func stop() {
        guard let sink else { return }
        sink.stop()
        self.sink = nil
        device = nil
        log.info("mic playout stopped")
    }
}

/// Fills output buffers of any size from WebRTC's 10 ms mono frames (D57): each pull asks
/// `pull` for exactly `AudioChunker.chunkFrames` frames, keeps what is left for the next
/// render, and copies the mono sample into every output channel. Allocation-free while
/// rendering, so it can run on a real-time IO thread.
final class PlayoutPump {
    static let chunkFrames = AudioChunker.chunkFrames
    let channels: Int
    private let pull: (UnsafeMutablePointer<Int16>, Int) -> Void
    private let chunk: UnsafeMutablePointer<Int16>
    /// Frames of `chunk` not yet rendered; they are its last `remaining` frames.
    private var remaining = 0

    init(channels: Int, pull: @escaping (UnsafeMutablePointer<Int16>, Int) -> Void) {
        self.channels = channels
        self.pull = pull
        chunk = .allocate(capacity: Self.chunkFrames)
        chunk.initialize(repeating: 0, count: Self.chunkFrames)
    }

    deinit { chunk.deallocate() }

    /// Writes `frames` interleaved frames of `channels` Int16 samples to `output`.
    func render(_ output: UnsafeMutablePointer<Int16>, frames: Int) {
        var written = 0
        while written < frames {
            if remaining == 0 {
                pull(chunk, Self.chunkFrames)
                remaining = Self.chunkFrames
            }
            let n = min(remaining, frames - written)
            let start = Self.chunkFrames - remaining
            for i in 0..<n {
                let sample = chunk[start + i]
                let base = (written + i) * channels
                for c in 0..<channels { output[base + c] = sample }
            }
            remaining -= n
            written += n
        }
    }
}

/// The real sink (D57): a HAL output AudioUnit bound to the BlackHole device. Its input is
/// 48 kHz Int16 stereo; the unit converts to the device's own rate and format. Input (the
/// device's microphone side) stays disabled, as it is by default for this unit.
final class BlackHoleSink: PlayoutSink {
    private let pump: PlayoutPump
    private var unit: AudioUnit?

    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) status=\(status)" }
    }

    init(device: AudioOutputDevice, audioDevice: TapAudioDevice) throws {
        pump = PlayoutPump(channels: 2) { buffer, frames in audioDevice.pullPlayout(buffer, frames: frames) }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw Failure(step: "find", status: -1) }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "new")
        guard let unit = created else { throw Failure(step: "new", status: -1) }
        self.unit = unit
        do {
            var deviceID = device.id
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)), "device")
            var format = AudioStreamBasicDescription(
                mSampleRate: AudioChunker.sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                mBitsPerChannel: 16, mReserved: 0)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                           &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "format")
            var callback = AURenderCallbackStruct(inputProc: blackHoleRender,
                                                  inputProcRefCon: Unmanaged.passUnretained(pump).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                           &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "callback")
            try check(AudioUnitInitialize(unit), "initialize")
            // A new IO thread pulls playout data from now on.
            audioDevice.outputThreadWillChange()
            try check(AudioOutputUnitStart(unit), "start")
        } catch {
            stop()
            throw error
        }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw Failure(step: step, status: status) }
    }

    func stop() {
        guard let unit else { return }
        self.unit = nil
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    deinit { stop() }
}

/// The HAL output unit's render callback: one interleaved Int16 stereo buffer.
private func blackHoleRender(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                             _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let data else { return noErr }
    let pump = Unmanaged<PlayoutPump>.fromOpaque(refCon).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(data)
    guard let first = buffers.first, let raw = first.mData else { return noErr }
    let capacity = Int(first.mDataByteSize) / (2 * pump.channels)
    pump.render(raw.assumingMemoryBound(to: Int16.self), frames: min(Int(frames), capacity))
    return noErr
}

/// Lists Core Audio devices with output channels (D57). Only called by the app when the
/// viewing device turns the mic on; tests use fake lists.
enum CoreAudioDevices {
    static func outputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = outputChannels(id)
            guard channels > 0, let name = name(id) else { return nil }
            return AudioOutputDevice(id: id, name: name, outputChannels: channels)
        }
    }

    private static func name(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
        var ref: UnsafeMutableRawPointer?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return Unmanaged<CFString>.fromOpaque(ref).takeRetainedValue() as String
    }

    private static func outputChannels(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
