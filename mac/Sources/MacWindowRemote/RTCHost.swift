import Foundation
import WebRTC

/// The app-wide WebRTC state (DESIGN.md D20, D21): one factory, one screen-cast video source fed
/// by `WindowVideoCapturer`, and one video track that every peer connection sends.
final class RTCHost: @unchecked Sendable {
    let factory: RTCPeerConnectionFactory
    let capturer: WindowVideoCapturer
    let track: RTCVideoTrack

    /// Call once at launch, before the first `RTCHost` (D20).
    static func initialize() { RTCInitializeSSL() }

    init() {
        factory = RTCPeerConnectionFactory(encoderFactory: ScreenH264EncoderFactory(),
                                           decoderFactory: RTCDefaultVideoDecoderFactory())
        let source = factory.videoSource(forScreenCast: true)
        capturer = WindowVideoCapturer(delegate: source)
        track = factory.videoTrack(with: source, trackId: "window")
    }

    /// Creates the answering peer connection for a phone's offer (D22).
    func makePeer() -> RTCPeer? {
        let config = RTCConfiguration()
        // D27: no STUN or TURN; host candidates only.
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        let peer = RTCPeer(host: self)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: config, constraints: constraints, delegate: peer) else {
            return nil
        }
        peer.connection = connection
        return peer
    }

    /// The H.264 entries of the sender capabilities, for `setCodecPreferences` (D21).
    var h264Capabilities: [RTCRtpCodecCapability] {
        factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs.filter { $0.name == kRTCVideoCodecH264Name }
    }
}

/// Offers only H.264 and encodes at level 5.2 whatever level was negotiated (D21): the stock
/// encoder takes its VideoToolbox level from `profile-level-id`, and the usual offered level 3.1
/// fails with `kVTParameterErr` above about 1280×720.
final class ScreenH264EncoderFactory: NSObject, RTCVideoEncoderFactory {
    static let profiles = ["42e01f", "640c1f"]

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        Self.profiles.map {
            RTCVideoCodecInfo(name: kRTCVideoCodecH264Name, parameters: [
                "profile-level-id": $0, "packetization-mode": "1", "level-asymmetry-allowed": "1",
            ])
        }
    }

    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        var parameters = info.parameters
        if let id = parameters["profile-level-id"] {
            parameters["profile-level-id"] = Self.level52(id)
        }
        return RTCVideoEncoderH264(codecInfo: RTCVideoCodecInfo(name: info.name, parameters: parameters))
    }

    /// `profile-level-id` with the level byte replaced by 5.2 (0x34), profile kept.
    static func level52(_ profileLevelId: String) -> String {
        guard profileLevelId.count == 6 else { return profileLevelId }
        return String(profileLevelId.prefix(4)) + "34"
    }
}

/// One peer connection to the phone: signaling, the `motion` and `control` data channels, and
/// state (D22, D27). Delegate callbacks arrive on WebRTC's signaling thread and are forwarded,
/// in order, through `events`.
final class RTCPeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case localCandidate(LocalCandidate?)
        case connectionState(RTCPeerConnectionState)
        case message(MessageChannel, Data)
    }

    enum Failure: Error {
        case noVideoTransceiver
        case sdp(String)
    }

    static let statsInterval: TimeInterval = 5

    private unowned let host: RTCHost
    fileprivate(set) var connection: RTCPeerConnection!
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let lock = NSLock()
    private var control: RTCDataChannel?
    private var motion: RTCDataChannel?
    private var statsTimer: DispatchSourceTimer?
    private var lastBytesSent: (bytes: Double, time: TimeInterval)?

    fileprivate init(host: RTCHost) {
        self.host = host
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    /// Applies the phone's offer, sends the shared track on its video transceiver, and returns
    /// the answer SDP (D22 step 3). A later offer on the same peer is a renegotiation, such as
    /// an ICE restart.
    func answer(offer sdp: String) async throws -> String {
        try await setRemote(RTCSessionDescription(type: .offer, sdp: sdp))
        guard let transceiver = connection.transceivers.first(where: { $0.mediaType == .video }) else {
            throw Failure.noVideoTransceiver
        }
        if transceiver.sender.track == nil {
            var error: NSError?
            transceiver.setDirection(.sendOnly, error: &error)
            if let error { throw error }
            transceiver.sender.track = host.track
            // Swift imports `setCodecPreferences:error:` and the deprecated non-throwing variant
            // under one name and picks the latter; the answer's codec list shows the effect.
            transceiver.setCodecPreferences(host.h264Capabilities)
        }
        let answer = try await createAnswer()
        try await setLocal(answer)
        applySenderParameters(transceiver.sender)
        return answer.sdp
    }

    /// D21: keep resolution (text stays sharp) and cap bitrate and frame rate.
    private func applySenderParameters(_ sender: RTCRtpSender) {
        let parameters = sender.parameters
        parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = 8_000_000
            encoding.maxFramerate = 30
        }
        sender.parameters = parameters
    }

    func add(_ candidate: RemoteCandidate) async {
        let ice = RTCIceCandidate(sdp: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex ?? 0, sdpMid: candidate.sdpMid)
        do {
            try await connection.add(ice)
        } catch {
            log.info("remote candidate rejected \(Self.describe(candidate.sdp), privacy: .public)")
        }
    }

    /// Sends one JSON message on `control` if it is open (D22).
    @discardableResult
    func sendControl(_ json: String) -> Bool {
        lock.lock()
        let channel = control
        lock.unlock()
        guard let channel, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: Data(json.utf8), isBinary: false))
    }

    func close() {
        stopStats()
        connection.close()
        continuation.finish()
    }

    // MARK: Signaling helpers

    private func setRemote(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            connection.setRemoteDescription(description) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    private func setLocal(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            connection.setLocalDescription(description) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    private func createAnswer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { c in
            connection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? Failure.sdp("no answer")) }
            }
        }
    }

    /// Candidate type and protocol only; addresses are never logged (D27).
    static func describe(_ candidate: String) -> String {
        let fields = candidate.split(separator: " ")
        let proto = fields.count > 2 ? String(fields[2]).lowercased() : "?"
        let type = fields.firstIndex(of: "typ").flatMap { $0 + 1 < fields.count ? String(fields[$0 + 1]) : nil } ?? "?"
        return "type=\(type) protocol=\(proto)"
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { continuation.yield(.localCandidate(nil)) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        log.debug("local candidate \(Self.describe(candidate.sdp), privacy: .public)")
        continuation.yield(.localCandidate(
            LocalCandidate(sdp: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        log.info("peer connection state=\(Self.name(newState), privacy: .public)")
        if newState == .connected { startStats() } else { stopStats() }
        continuation.yield(.connectionState(newState))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChangeLocalCandidate local: RTCIceCandidate,
                        remoteCandidate remote: RTCIceCandidate, lastReceivedMs: Int32, changeReason reason: String) {
        log.info("selected pair local \(Self.describe(local.sdp), privacy: .public) remote \(Self.describe(remote.sdp), privacy: .public)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        lock.lock()
        switch dataChannel.label {
        case "motion": motion = dataChannel
        case "control": control = dataChannel
        default:
            lock.unlock()
            log.info("unknown data channel ignored")
            return
        }
        lock.unlock()
        dataChannel.delegate = self
        log.info("data channel label=\(dataChannel.label, privacy: .public)")
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        log.debug("data channel label=\(dataChannel.label, privacy: .public) state=\(dataChannel.readyState.rawValue, privacy: .public)")
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let channel: MessageChannel = dataChannel.label == "motion" ? .motion : .control
        // A binary message is not JSON; decoding rejects it like any malformed message.
        continuation.yield(.message(channel, buffer.isBinary ? Data() : buffer.data))
    }

    // MARK: Stats (D30 items 1 and 3)

    private func startStats() {
        stopStats()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.statsInterval, repeating: Self.statsInterval)
        timer.setEventHandler { [weak self] in self?.logStats() }
        timer.resume()
        lock.lock()
        statsTimer = timer
        lastBytesSent = nil
        lock.unlock()
    }

    private func stopStats() {
        lock.lock()
        statsTimer?.cancel()
        statsTimer = nil
        lock.unlock()
    }

    /// Logs the video codec, encoder, size, frame rate, and outbound bitrate.
    private func logStats() {
        connection.statistics { [weak self] report in
            guard let self else { return }
            let stats = report.statistics.values
            guard let outbound = stats.first(where: {
                $0.type == "outbound-rtp" && ($0.values["kind"] as? String) == "video"
            }) else { return }
            let v = outbound.values
            let codec = (v["codecId"] as? String).flatMap { report.statistics[$0]?.values["mimeType"] as? String } ?? "?"
            let bytes = (v["bytesSent"] as? NSNumber)?.doubleValue ?? 0
            let now = ProcessInfo.processInfo.systemUptime
            self.lock.lock()
            let last = self.lastBytesSent
            self.lastBytesSent = (bytes, now)
            self.lock.unlock()
            let kbps = last.map { ($0.time < now) ? (bytes - $0.bytes) * 8 / 1000 / (now - $0.time) : 0 } ?? 0
            let encoder = v["encoderImplementation"] as? String ?? "?"
            let width = (v["frameWidth"] as? NSNumber)?.intValue ?? 0
            let height = (v["frameHeight"] as? NSNumber)?.intValue ?? 0
            let fps = (v["framesPerSecond"] as? NSNumber)?.doubleValue ?? 0
            let frames = (v["framesEncoded"] as? NSNumber)?.intValue ?? 0
            let limit = v["qualityLimitationReason"] as? String ?? "?"
            log.info("video stats codec=\(codec, privacy: .public) encoder=\(encoder, privacy: .public) size=\(width, privacy: .public)x\(height, privacy: .public) fps=\(fps, privacy: .public) framesEncoded=\(frames, privacy: .public) kbps=\(Int(kbps), privacy: .public) limitation=\(limit, privacy: .public)")
        }
    }

    static func name(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .failed: return "failed"
        case .closed: return "closed"
        @unknown default: return "unknown"
        }
    }
}
