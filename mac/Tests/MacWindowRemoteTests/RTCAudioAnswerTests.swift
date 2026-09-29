import Foundation
import Testing
import WebRTC
@testable import MacWindowRemote

/// D39: the answer sends the tap's audio track on the phone's recvonly audio transceiver.
/// SDP only; both factories use `TapAudioDevice`, so no real audio device is opened.
@Suite(.serialized) struct RTCAudioAnswerTests {
    private final class NoDelegate: NSObject, RTCPeerConnectionDelegate {
        func peerConnection(_ p: RTCPeerConnection, didChange s: RTCSignalingState) {}
        func peerConnection(_ p: RTCPeerConnection, didAdd s: RTCMediaStream) {}
        func peerConnection(_ p: RTCPeerConnection, didRemove s: RTCMediaStream) {}
        func peerConnectionShouldNegotiate(_ p: RTCPeerConnection) {}
        func peerConnection(_ p: RTCPeerConnection, didChange s: RTCIceConnectionState) {}
        func peerConnection(_ p: RTCPeerConnection, didChange s: RTCIceGatheringState) {}
        func peerConnection(_ p: RTCPeerConnection, didGenerate c: RTCIceCandidate) {}
        func peerConnection(_ p: RTCPeerConnection, didRemove c: [RTCIceCandidate]) {}
        func peerConnection(_ p: RTCPeerConnection, didOpen d: RTCDataChannel) {}
    }

    @Test func answerSendsOpusAudioOnlyToThePhone() async throws {
        RTCHost.initialize()
        let host = RTCHost()
        let phoneFactory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory(), audioDevice: TapAudioDevice())
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let delegate = NoDelegate()
        let phone = try #require(phoneFactory.peerConnection(with: config, constraints: constraints, delegate: delegate))
        defer { phone.close() }
        let recvOnly = RTCRtpTransceiverInit()
        recvOnly.direction = .recvOnly
        phone.addTransceiver(of: .video, init: recvOnly)
        phone.addTransceiver(of: .audio, init: recvOnly)
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            phone.offer(for: constraints) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error!) }
            }
        }
        let peer = try #require(host.makePeer())
        defer { peer.close() }
        let answer = try await peer.answer(offer: offer.sdp)
        let audio = try #require(answer.components(separatedBy: "m=").first { $0.hasPrefix("audio") })
        #expect(audio.contains("a=sendonly"))
        #expect(audio.lowercased().contains("opus/48000"))
        let video = try #require(answer.components(separatedBy: "m=").first { $0.hasPrefix("video") })
        #expect(video.contains("a=sendonly") && video.contains("H264"))
        // A rebuilt tap notifies the ADM on its own thread; this must return, and a chunk while
        // WebRTC is not recording (not connected) is dropped.
        host.audioDevice.inputThreadWillChange()
        #expect(!host.audioDevice.isRecording && !host.audioDevice.isPlaying)
        let silence = [Int16](repeating: 0, count: AudioChunker.chunkFrames)
        silence.withUnsafeBufferPointer { host.audioDevice.deliver($0.baseAddress!) }
    }
}
