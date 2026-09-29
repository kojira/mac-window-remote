// WebRTC video and input channels (DESIGN.md D22, D27). The phone offers; signaling runs over
// the authenticated WebSocket. No ICE servers: host candidates over the tailnet only.

const CONNECT_TIMEOUT_MS = 10000;
const DISCONNECT_GRACE_MS = 3000;

/// Which data channel carries an input message (D22).
const MOTION_TYPES = new Set(['move', 'scroll']);

export class VideoLink {
  /// signal(msg): send a WebSocket message; returns false if the socket is not ready.
  /// onStatus(status): 'connecting' | 'reconnecting' | 'connected' | 'failed'.
  /// onReady(): a new peer connection is connected and `control` is open.
  /// onControl(msg): a JSON message from the Mac on `control`.
  /// onAudioTrack(track): the Mac audio track of a newly connected peer connection (D39).
  constructor({ video, signal, onStatus, onReady, onControl, onAudioTrack }) {
    this.video = video;
    this.onAudioTrack = onAudioTrack;
    this.signal = signal;
    this.onStatus = onStatus;
    this.onReady = onReady;
    this.onControl = onControl;
    this.pc = null;
    this.pcNumber = 0; // never reused, so late messages for an old connection are ignored
    this.retried = false; // one fresh retry after a failure (D27)
  }

  /// Starts a fresh peer connection (after `hello`, a failure, or Retry).
  start() {
    this.close();
    const number = ++this.pcNumber;
    const pc = new RTCPeerConnection({ iceServers: [], bundlePolicy: 'max-bundle' });
    this.pc = pc;
    this.ready = false;
    this.remoteSet = false;
    this.pendingIce = [];
    this.transceiver = pc.addTransceiver('video', { direction: 'recvonly' });
    // D39: Mac audio; played by a separate <audio> element, never by the muted <video>.
    this.audioTransceiver = pc.addTransceiver('audio', { direction: 'recvonly' });
    this.motion = pc.createDataChannel('motion', { ordered: false, maxRetransmits: 0 });
    this.control = pc.createDataChannel('control');
    this.control.onmessage = (e) => {
      if (pc !== this.pc || typeof e.data !== 'string') return;
      let msg;
      try { msg = JSON.parse(e.data); } catch { return; }
      this.onControl(msg);
    };
    this.control.onopen = () => this.checkReady(pc);
    pc.onicecandidate = (e) => {
      if (pc !== this.pc) return;
      const c = e.candidate;
      if (c && c.candidate) {
        this.signal({ t: 'rtc.ice', pc: number, candidate: c.candidate, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex });
      } else {
        this.signal({ t: 'rtc.ice', pc: number, candidate: null });
      }
    };
    pc.onconnectionstatechange = () => this.onConnectionState(pc);
    this.setStatus('connecting');
    this.armConnectTimer(pc);
    this.offer(pc, false);
  }

  async offer(pc, iceRestart) {
    try {
      const offer = await pc.createOffer({ iceRestart });
      if (pc !== this.pc) return;
      await pc.setLocalDescription(offer);
      if (pc !== this.pc) return;
      this.signal({ t: 'rtc.offer', pc: this.pcNumber, sdp: pc.localDescription.sdp });
    } catch {
      if (pc === this.pc) this.fail();
    }
  }

  /// `rtc.answer` and `rtc.ice` from the Mac.
  async onSignal(msg) {
    const pc = this.pc;
    if (!pc || msg.pc !== this.pcNumber) return;
    try {
      if (msg.t === 'rtc.answer') {
        await pc.setRemoteDescription({ type: 'answer', sdp: msg.sdp });
        if (pc !== this.pc) return;
        this.remoteSet = true;
        for (const c of this.pendingIce.splice(0)) await this.addIce(pc, c);
      } else if (msg.t === 'rtc.ice') {
        // Candidates can arrive before the answer; they wait for it.
        if (this.remoteSet) await this.addIce(pc, msg); else this.pendingIce.push(msg);
      }
    } catch {
      if (pc === this.pc) this.fail();
    }
  }

  async addIce(pc, msg) {
    try {
      if (msg.candidate == null) await pc.addIceCandidate();
      else await pc.addIceCandidate({ candidate: msg.candidate, sdpMid: msg.sdpMid, sdpMLineIndex: msg.sdpMLineIndex });
    } catch { /* one unusable candidate does not fail the connection */ }
  }

  onConnectionState(pc) {
    if (pc !== this.pc) return;
    clearTimeout(this.graceTimer);
    switch (pc.connectionState) {
      case 'connected':
        clearTimeout(this.connectTimer);
        this.retried = false;
        this.setStatus('connected');
        this.checkReady(pc);
        break;
      case 'disconnected':
        // Wait for ICE to recover by itself, then restart ICE (D27).
        this.setStatus('reconnecting');
        this.graceTimer = setTimeout(() => {
          if (pc !== this.pc || pc.connectionState !== 'disconnected') return;
          this.armConnectTimer(pc);
          this.offer(pc, true);
        }, DISCONNECT_GRACE_MS);
        break;
      case 'failed':
        this.fail();
        break;
    }
  }

  armConnectTimer(pc) {
    clearTimeout(this.connectTimer);
    this.connectTimer = setTimeout(() => {
      if (pc === this.pc && pc.connectionState !== 'connected') this.fail();
    }, CONNECT_TIMEOUT_MS);
  }

  checkReady(pc) {
    if (pc !== this.pc || this.ready) return;
    if (pc.connectionState !== 'connected' || this.control.readyState !== 'open') return;
    this.ready = true;
    // Attached only now, so the last image stays visible while a new connection is set up.
    this.video.srcObject = new MediaStream([this.transceiver.receiver.track]);
    this.video.play().catch(() => { /* muted inline video; iOS allows autoplay */ });
    this.onAudioTrack(this.audioTransceiver.receiver.track);
    this.onReady();
  }

  /// `failed`, 10 s without connecting, or `rtc_failed`: one fresh peer connection, then stop
  /// and show the error with Retry (D27). There is no JPEG fallback.
  fail() {
    if (!this.retried) {
      this.retried = true;
      this.start();
      return;
    }
    this.close();
    this.setStatus('failed');
  }

  /// Retry button: a fresh peer connection with a fresh retry budget.
  retry() {
    this.retried = false;
    this.start();
  }

  /// An input message on the channel that carries it; false if that channel is not open.
  send(msg) {
    const channel = MOTION_TYPES.has(msg.t) ? this.motion : this.control;
    if (!this.pc || !channel || channel.readyState !== 'open') return false;
    channel.send(JSON.stringify(msg));
    return true;
  }

  canSend() {
    return !!this.pc && this.ready && this.control.readyState === 'open';
  }

  close() {
    clearTimeout(this.connectTimer);
    clearTimeout(this.graceTimer);
    const pc = this.pc;
    this.pc = null;
    this.ready = false;
    if (pc) pc.close();
  }

  setStatus(status) {
    this.status = status;
    this.onStatus(status);
  }
}
