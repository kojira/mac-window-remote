// This device's microphone as a Mac input (DESIGN.md D57): 🎤 turns it on inside the tap
// (getUserMedia needs the gesture on iOS), sends the track on the peer connection's audio
// transceiver, and asks the Mac to play it into BlackHole. Off stops the track, so the
// browser's microphone indicator goes off.

export const MIC_CONSTRAINTS = { audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } };

export const MIC_TOASTS = {
  denied: 'Microphone access was denied. Allow it for this site in the browser settings',
  unavailable: 'This browser cannot use the microphone here',
  failed: 'Could not start the microphone',
  noDevice: 'Install BlackHole on the Mac to use the mic (see README)',
  macFailed: 'The Mac could not open BlackHole',
};

export function micAriaLabel(state) {
  return state === 'off' ? 'Microphone off. Tap to use this device\'s microphone on the Mac'
    : 'Microphone on. Tap to turn it off';
}

/// The 🎤 state: 'off', 'starting' (waiting for permission), or 'on'.
export class MicControl {
  /// getUserMedia(constraints): the browser's, or null when there is none (insecure page).
  /// setTrack(track|null): puts the track on the audio transceiver (replaceTrack).
  /// send(msg): a `control` message; false when not connected.
  /// toast(text), onChange(): UI.
  constructor({ getUserMedia, setTrack, send, toast, onChange = () => {} }) {
    this.getUserMedia = getUserMedia;
    this.setTrack = setTrack;
    this.send = send;
    this.toast = toast;
    this.onChange = onChange;
    this.state = 'off';
    this.track = null;
    this.attempt = 0;
  }

  get on() { return this.state !== 'off'; }

  /// 🎤 tap. getUserMedia is called synchronously, inside the gesture.
  toggle() {
    if (this.on) this.stop(true);
    else return this.start();
  }

  async start() {
    if (!this.getUserMedia) {
      this.toast(MIC_TOASTS.unavailable);
      return;
    }
    const attempt = ++this.attempt;
    this.state = 'starting';
    this.onChange();
    let stream;
    try {
      stream = await this.getUserMedia(MIC_CONSTRAINTS);
    } catch (err) {
      if (attempt !== this.attempt) return;
      this.state = 'off';
      this.onChange();
      const denied = err && (err.name === 'NotAllowedError' || err.name === 'SecurityError');
      this.toast(denied ? MIC_TOASTS.denied : MIC_TOASTS.failed);
      return;
    }
    const track = stream.getAudioTracks()[0];
    if (attempt !== this.attempt || !track) {
      // Turned off while the permission prompt was up.
      for (const t of stream.getTracks()) t.stop();
      if (attempt === this.attempt) { this.state = 'off'; this.onChange(); this.toast(MIC_TOASTS.failed); }
      return;
    }
    this.track = track;
    track.onended = () => { if (this.track === track) this.stop(true); };
    this.state = 'on';
    this.onChange();
    await this.attach();
  }

  /// Puts the track on the current peer connection and tells the Mac (also after a reconnect).
  async attach() {
    if (this.state !== 'on' || !this.track) return;
    try { await this.setTrack(this.track); } catch { /* no transceiver yet; the next connection attaches */ }
    this.send({ t: 'mic', on: true });
  }

  /// Off: the track stops (the browser's indicator goes off). `tell` sends `mic off`.
  stop(tell) {
    this.attempt += 1;
    const track = this.track;
    this.track = null;
    const was = this.state;
    this.state = 'off';
    if (track) {
      track.onended = null;
      track.stop();
      Promise.resolve().then(() => this.setTrack(null)).catch(() => {});
    }
    if (tell && was !== 'off') this.send({ t: 'mic', on: false });
    if (was !== 'off') this.onChange();
  }

  /// A new peer connection is ready.
  onReady() {
    return this.attach();
  }

  /// `mic.state` from the Mac. Errors turn the mic off here too.
  onState(msg) {
    if (!msg || msg.on === true) return;
    if (msg.error === 'no-device') { this.stop(false); this.toast(MIC_TOASTS.noDevice); }
    else if (msg.error) { this.stop(false); this.toast(MIC_TOASTS.macFailed); }
  }
}
