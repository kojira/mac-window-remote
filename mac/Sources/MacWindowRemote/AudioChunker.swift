import AVFoundation
import CoreAudio

/// Turns the process tap's Float32 audio (any channel count, interleaved or not, any sample
/// rate) into what `TapAudioDevice` delivers: mono, 48 kHz, Int16, in 10 ms chunks of exactly
/// 480 frames (D39). Used on one thread at a time (the tap's IO thread).
final class AudioChunker {
    static let sampleRate = 48_000.0
    static let chunkFrames = 480

    let sourceRate: Double
    let channels: Int
    let interleaved: Bool

    private var mono: [Float] = []
    private var pending = [Int16](repeating: 0, count: AudioChunker.chunkFrames)
    private var pendingCount = 0
    private let converter: AVAudioConverter?
    private let converterInput: AVAudioFormat
    private let converterOutput: AVAudioFormat
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?

    /// Nil unless the format is linear PCM Float32 with at least one channel.
    init?(format f: AudioStreamBasicDescription) {
        guard f.mFormatID == kAudioFormatLinearPCM, f.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              f.mBitsPerChannel == 32, f.mChannelsPerFrame > 0, f.mSampleRate > 0 else { return nil }
        sourceRate = f.mSampleRate
        channels = Int(f.mChannelsPerFrame)
        interleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)
        else { return nil }
        converterInput = input
        converterOutput = output
        converter = sourceRate == Self.sampleRate ? nil : AVAudioConverter(from: input, to: output)
        if sourceRate != Self.sampleRate, converter == nil { return nil }
    }

    /// Reads one tap buffer list and calls `emit` once per complete 480-frame chunk. The tap's
    /// streams are the last buffers of the list (an aggregate lists its sub-device inputs
    /// first). Returns true if any sample was not exactly zero.
    @discardableResult
    func append(_ list: UnsafePointer<AudioBufferList>, emit: (UnsafePointer<Int16>) -> Void) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let needed = interleaved ? 1 : channels
        guard buffers.count >= needed else { return false }
        let first = buffers.count - needed
        var frames = Int.max
        for b in first..<buffers.count {
            guard buffers[b].mData != nil else { return false }
            frames = min(frames, Int(buffers[b].mDataByteSize) / (interleaved ? 4 * channels : 4))
        }
        guard frames > 0 else { return false }
        if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
        var heard = false
        mono.withUnsafeMutableBufferPointer { out in
            let scale = 1 / Float(channels)
            if interleaved {
                let p = buffers[first].mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += p[i * channels + c] }
                    out[i] = sum * scale
                }
            } else {
                for i in 0..<frames { out[i] = 0 }
                for b in first..<buffers.count {
                    let p = buffers[b].mData!.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames { out[i] += p[i] }
                }
                for i in 0..<frames { out[i] *= scale }
            }
            for i in 0..<frames where out[i] != 0 {
                heard = true
                break
            }
        }
        if let converter {
            resample(frames: frames, converter: converter, emit: emit)
        } else {
            mono.withUnsafeBufferPointer { push(UnsafeBufferPointer(rebasing: $0[0..<frames]), emit: emit) }
        }
        return heard
    }

    private func resample(frames: Int, converter: AVAudioConverter, emit: (UnsafePointer<Int16>) -> Void) {
        if inputBuffer.map({ Int($0.frameCapacity) < frames }) ?? true {
            inputBuffer = AVAudioPCMBuffer(pcmFormat: converterInput, frameCapacity: AVAudioFrameCount(frames))
        }
        let outCapacity = Int((Double(frames) * Self.sampleRate / sourceRate).rounded(.up)) + 64
        if outputBuffer.map({ Int($0.frameCapacity) < outCapacity }) ?? true {
            outputBuffer = AVAudioPCMBuffer(pcmFormat: converterOutput, frameCapacity: AVAudioFrameCount(outCapacity))
        }
        guard let input = inputBuffer, let output = outputBuffer, let dst = input.floatChannelData?[0] else { return }
        mono.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: frames)
        }
        input.frameLength = AVAudioFrameCount(frames)
        output.frameLength = 0
        var supplied = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard let out = output.floatChannelData?[0], output.frameLength > 0 else { return }
        push(UnsafeBufferPointer(start: out, count: Int(output.frameLength)), emit: emit)
    }

    private func push(_ samples: UnsafeBufferPointer<Float>, emit: (UnsafePointer<Int16>) -> Void) {
        pending.withUnsafeMutableBufferPointer { chunk in
            for x in samples {
                chunk[pendingCount] = Int16((max(-1, min(1, x)) * 32767).rounded())
                pendingCount += 1
                if pendingCount == Self.chunkFrames {
                    emit(chunk.baseAddress!)
                    pendingCount = 0
                }
            }
        }
    }
}
