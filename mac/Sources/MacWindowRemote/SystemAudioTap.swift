import AppKit
import CoreAudio
import os

/// What `SystemAudioTap` taps (D39).
enum AudioTarget: Equatable, Sendable {
    /// The app that owns the viewed window, with its helper processes.
    case app(pid: pid_t)
    /// Every process except this app.
    case wholeMac

    /// The tap the session wants: none while audio is off, the peer is not connected, or
    /// (in App mode) no window is viewed.
    static func desired(mode: AudioMode, peerConnected: Bool, viewedPid: pid_t?) -> AudioTarget? {
        guard peerConnected else { return nil }
        switch mode {
        case .off: return nil
        case .all: return .wholeMac
        case .app: return viewedPid.map { .app(pid: $0) }
        }
    }
}

enum AudioEvent: Sendable {
    /// The tap could not be created (macOS before 14.2, or Core Audio refused).
    case unavailable
    /// Only exact zeros for a while although a tapped process plays audio: most likely the
    /// System Audio Recording permission is missing.
    case silent
}

/// A Core Audio process tap in a private aggregate device, read by an IOProc that feeds
/// `TapAudioDevice` (D39). The tap mutes what it taps on the Mac (`mutedWhenTapped`) only
/// while the IOProc reads it; stopping (or this process exiting) makes the Mac audible again.
/// All Core Audio calls run on one serial queue.
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    private let device: TapAudioDevice
    private let queue = DispatchQueue(label: "mac-window-remote.audio-tap")

    // State, on `queue` only.
    private var target: AudioTarget?
    private var events: (@Sendable (AudioEvent) -> Void)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedObjects: [AudioObjectID] = []
    /// The description the tap was created with; App mode rewrites its process list.
    private var tapDescription: CATapDescription?
    private var listening = false
    private var silenceTimer: DispatchSourceTimer?
    private var silentChecks = 0
    private var silenceReported = false
    private var everHeard = false
    /// Set by the IO thread when a buffer had a non-zero sample; read and cleared by the
    /// silence check.
    private let heard = OSAllocatedUnfairLock(initialState: false)

    /// Only zeros since the tap started while a tapped process plays, for this many one-second
    /// checks, is reported once (D39).
    static let silentChecksBeforeReport = 4

    init(device: TapAudioDevice) {
        self.device = device
    }

    /// Starts, retargets, or (nil) stops the tap. Calls are applied in order.
    func setTarget(_ newTarget: AudioTarget?, events: @escaping @Sendable (AudioEvent) -> Void) {
        queue.async { [self] in
            self.events = events
            guard newTarget != target || (newTarget != nil && tapID == kAudioObjectUnknown) else { return }
            let previous = target
            target = newTarget
            guard let newTarget else {
                stop()
                stopListening()
                log.info("audio tap stopped")
                return
            }
            startListening()
            if case .app = newTarget, case .app = previous, tapID != kAudioObjectUnknown {
                retarget()
            } else {
                stop()
                start(newTarget)
            }
        }
    }

    // MARK: Build and tear down

    private func description(for target: AudioTarget) -> CATapDescription? {
        let description: CATapDescription
        switch target {
        case .wholeMac:
            let own = Self.processObject(pid: getpid())
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        case .app(let pid):
            let objects = appObjects(pid: pid)
            tappedObjects = objects
            // An app that has not used audio yet has no process object; the process list
            // listener starts the tap when it appears.
            guard !objects.isEmpty else { return nil }
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        description.name = "Mac Window Remote"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        tapDescription = description
        return description
    }

    private func start(_ target: AudioTarget) {
        guard let description = description(for: target) else {
            log.info("audio tap waiting for the app's audio process")
            return
        }
        do {
            try build(description)
            log.info("audio tap started target=\(Self.name(target), privacy: .public)")
        } catch {
            log.error("audio tap failed: \(String(describing: error), privacy: .public)")
            stop()
            stopListening()
            self.target = nil
            events?(.unavailable)
        }
    }

    private struct CoreAudioError: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) status=\(status)" }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw CoreAudioError(step: step, status: status) }
    }

    private func build(_ description: CATapDescription) throws {
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")
        guard let tapUID: CFString = Self.readObject(tapID, kAudioTapPropertyUID),
              var format: AudioStreamBasicDescription = Self.read(tapID, kAudioTapPropertyFormat) else {
            throw CoreAudioError(step: "read tap", status: -1)
        }
        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mac Window Remote Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        // The default output device clocks the aggregate, unless it also has inputs (a headset):
        // then the aggregate holds the tap alone, so no microphone is ever opened.
        if let output = Self.defaultOutputDevice(), !Self.hasInput(output),
           let outputUID: CFString = Self.readObject(output, kAudioDevicePropertyDeviceUID) {
            composition[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "create aggregate")
        // The IOProc runs at the aggregate's rate (its clock is the output device).
        if let rate: Float64 = Self.read(aggregateID, kAudioDevicePropertyNominalSampleRate), rate > 0 {
            format.mSampleRate = rate
        }
        guard let chunker = AudioChunker(format: format) else {
            throw CoreAudioError(step: "tap format \(format.mFormatID) \(format.mBitsPerChannel)", status: -1)
        }
        let device = self.device
        let heard = self.heard
        device.inputThreadWillChange()
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, _, _ in
            if chunker.append(input, emit: { device.deliver($0) }) {
                heard.withLock { $0 = true }
            }
        }, "create IOProc")
        try check(AudioDeviceStart(aggregateID, procID), "start")
        startSilenceCheck()
    }

    /// App mode: the viewed app or its helpers changed; rewrite the tap's process list in place,
    /// without a gap. Falls back to a rebuild.
    private func retarget() {
        guard case .app(let pid) = target else { return }
        let objects = appObjects(pid: pid)
        guard objects != tappedObjects else { return }
        guard !objects.isEmpty, let description = tapDescription else {
            stop()
            if let target { start(target) }
            return
        }
        description.processes = objects
        var address = Self.address(kAudioTapPropertyDescription)
        // The property's data is the description object reference itself.
        var ref = Unmanaged.passUnretained(description).toOpaque()
        let status = withExtendedLifetime(description) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &ref)
        }
        if status == noErr {
            tappedObjects = objects
            silentChecks = 0
            log.info("audio tap retargeted processes=\(objects.count, privacy: .public)")
        } else {
            log.info("audio tap retarget failed status=\(status, privacy: .public); rebuilding")
            stop()
            if let target { start(target) }
        }
    }

    private func stop() {
        silenceTimer?.cancel()
        silenceTimer = nil
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedObjects = []
        tapDescription = nil
    }

    // MARK: Listeners: new or exited processes, output device changes

    private lazy var processListListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self, case .app = self.target else { return }
        if self.tapID == kAudioObjectUnknown {
            if let target = self.target { self.start(target) }
        } else {
            self.retarget()
        }
    }

    private lazy var outputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self, let target = self.target, self.tapID != kAudioObjectUnknown else { return }
        log.info("audio output device changed; rebuilding the tap")
        self.stop()
        self.start(target)
    }

    private func startListening() {
        guard !listening else { return }
        listening = true
        var processes = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processes, queue, processListListener)
        var output = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &output, queue, outputListener)
    }

    private func stopListening() {
        guard listening else { return }
        listening = false
        var processes = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processes, queue, processListListener)
        var output = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &output, queue, outputListener)
    }

    // MARK: Silence check (D39)

    private func startSilenceCheck() {
        silenceTimer?.cancel()
        silentChecks = 0
        silenceReported = false
        everHeard = false
        heard.withLock { $0 = false }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkSilence() }
        timer.resume()
        silenceTimer = timer
    }

    private func checkSilence() {
        let wasHeard = heard.withLock { value in
            defer { value = false }
            return value
        }
        if wasHeard { everHeard = true }
        // Real audio seen once means the grant is there; a silent-but-running stream later is
        // just silence.
        guard !everHeard, anyTappedProcessPlays() else {
            silentChecks = 0
            return
        }
        silentChecks += 1
        if silentChecks >= Self.silentChecksBeforeReport, !silenceReported {
            silenceReported = true
            log.info("audio tap silent while a tapped process plays")
            events?(.silent)
        }
    }

    private func anyTappedProcessPlays() -> Bool {
        let ownPid = getpid()
        let candidates: [AudioObjectID]
        switch target {
        case .app: candidates = tappedObjects
        case .wholeMac: candidates = Self.processObjects().filter { (Self.read($0, kAudioProcessPropertyPID) as pid_t?) != ownPid }
        case nil: return false
        }
        return candidates.contains { (Self.read($0, kAudioProcessPropertyIsRunningOutput) as UInt32?) ?? 0 != 0 }
    }

    // MARK: Process objects

    private func appObjects(pid: pid_t) -> [AudioObjectID] {
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let processes = Self.processObjects().compactMap { object -> AudioProcessSelection.Process? in
            guard let pid: pid_t = Self.read(object, kAudioProcessPropertyPID) else { return nil }
            let bid: CFString? = Self.readObject(object, kAudioProcessPropertyBundleID)
            return AudioProcessSelection.Process(object: object, pid: pid, bundleID: (bid as String?) ?? "")
        }
        return AudioProcessSelection.objects(bundleID: bundleID, pid: pid, ownPid: getpid(), in: processes)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        guard let device: AudioObjectID = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        // Unknown counts as having inputs.
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return true }
        return size > 0
    }

    // MARK: Property helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// A fixed-size property value (numbers, ids, formats).
    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        return value.move()
    }

    /// A CoreFoundation or Objective-C object property (returned +1 by Core Audio).
    private static func readObject<T: AnyObject>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
        var ref: UnsafeMutableRawPointer?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ref).takeRetainedValue() as? T
    }

    private static func name(_ target: AudioTarget) -> String {
        switch target {
        case .app: return "app"
        case .wholeMac: return "all"
        }
    }
}
