import AudioToolbox
import Foundation
import WebRTC
import WebRTCAudioDevice

/// The factory's audio device (D39). It never opens a microphone or a speaker: recording is
/// fed by `SystemAudioTap` through `deliver`, and playout is only pulled by `BlackHoleSink`
/// while the viewing device's mic is on (D57), so the Mac never plays WebRTC audio on its
/// speakers. Without it WebRTC's default macOS device would open the microphone as soon as
/// an audio track is sent.
final class TapAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var delegate: (any RTCAudioDeviceDelegate)?
    private var initialized = false
    private var recordingInitialized = false
    private var recording = false
    private var playoutInitialized = false
    private var playing = false

    var deviceInputSampleRate: Double { AudioChunker.sampleRate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { AudioChunker.sampleRate }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { 0 }

    var isInitialized: Bool { lock.withLock { initialized } }
    var isPlayoutInitialized: Bool { lock.withLock { playoutInitialized } }
    var isPlaying: Bool { lock.withLock { playing } }
    var isRecordingInitialized: Bool { lock.withLock { recordingInitialized } }
    var isRecording: Bool { lock.withLock { recording } }

    func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
        lock.withLock {
            self.delegate = delegate
            initialized = true
        }
        return true
    }

    func terminateDevice() -> Bool {
        lock.withLock {
            delegate = nil
            initialized = false
            recording = false
            recordingInitialized = false
            playing = false
            playoutInitialized = false
        }
        return true
    }

    // Playout: WebRTC only marks it started; `pullPlayout` reads it when a sink asks (D57).
    func initializePlayout() -> Bool { lock.withLock { playoutInitialized = true }; return true }
    func startPlayout() -> Bool { lock.withLock { playing = true }; return true }
    func stopPlayout() -> Bool { lock.withLock { playing = false }; return true }

    func initializeRecording() -> Bool { lock.withLock { recordingInitialized = true }; return true }
    func startRecording() -> Bool { lock.withLock { recording = true }; return true }
    func stopRecording() -> Bool { lock.withLock { recording = false }; return true }

    /// One 10 ms chunk of mono 48 kHz audio, from the tap's IO thread. Dropped unless WebRTC
    /// is recording (a connected peer with the audio track attached).
    func deliver(_ samples: UnsafePointer<Int16>) {
        let delegate: (any RTCAudioDeviceDelegate)? = lock.withLock { recording ? self.delegate : nil }
        guard let delegate else { return }
        let frames = AudioChunker.chunkFrames
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(frames * 2), mData: UnsafeMutableRawPointer(mutating: samples)))
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        _ = delegate.deliverRecordedData(&flags, &time, 1, UInt32(frames), &list, nil, nil)
    }

    /// D57: fills `frames` mono 48 kHz samples with the received audio, or silence unless
    /// WebRTC is playing. Called from the sink's IO thread.
    func pullPlayout(_ samples: UnsafeMutablePointer<Int16>, frames: Int) {
        let delegate: (any RTCAudioDeviceDelegate)? = lock.withLock { playing ? self.delegate : nil }
        guard let delegate else {
            samples.update(repeating: 0, count: frames)
            return
        }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(frames * 2), mData: UnsafeMutableRawPointer(samples)))
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        if delegate.getPlayoutData(&flags, &time, 0, UInt32(frames), &list) != noErr {
            samples.update(repeating: 0, count: frames)
        }
    }

    /// D57: playout is pulled from a new thread after this (a new sink).
    func outputThreadWillChange() {
        let delegate = lock.withLock { self.delegate }
        guard let delegate else { return }
        delegate.dispatchSync { delegate.notifyAudioOutputInterrupted() }
    }

    /// Deliveries may come from a new thread after this (a rebuilt tap has a new IO thread).
    func inputThreadWillChange() {
        let delegate = lock.withLock { self.delegate }
        guard let delegate else { return }
        delegate.dispatchSync { delegate.notifyAudioInputInterrupted() }
    }
}
