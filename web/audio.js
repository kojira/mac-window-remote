// Mac audio on the iPhone (DESIGN.md D39): the 🔊 mode (Off → App → All), stored on the phone,
// and the separate <audio> element that plays the Mac's audio track.

export const AUDIO_KEY = 'mwr.audio';
export const AUDIO_MODES = ['off', 'app', 'all'];

/// The stored mode; anything unreadable is off.
export function parseAudioMode(stored) {
  return AUDIO_MODES.includes(stored) ? stored : 'off';
}

/// 🔊 cycles Off → App → All → Off.
export function nextAudioMode(mode) {
  return AUDIO_MODES[(AUDIO_MODES.indexOf(parseAudioMode(mode)) + 1) % AUDIO_MODES.length];
}

/// The 🔊 button's icon and the mode under it.
export function audioButtonLabel(mode) {
  switch (mode) {
    case 'app': return { icon: '🔊', text: 'App' };
    case 'all': return { icon: '🔊', text: 'All' };
    default: return { icon: '🔇', text: 'Off' };
  }
}

export function audioAriaLabel(mode) {
  switch (mode) {
    case 'app': return 'Audio: this app. Tap for the whole Mac';
    case 'all': return 'Audio: whole Mac. Tap to turn off';
    default: return 'Audio off. Tap to hear this app';
  }
}

/// The mode in an `audio.state` message from the Mac, or null if malformed.
export function decodeAudioState(msg) {
  return msg && AUDIO_MODES.includes(msg.mode) ? msg.mode : null;
}

/// The phone's audio mode and the Mac's replies. Every `audio` sent gets one `audio.state`;
/// the phone takes the Mac's mode only when no newer request is still unanswered, so fast
/// taps do not flicker back to an older echo.
export class AudioMode {
  constructor(stored) {
    this.mode = parseAudioMode(stored);
    this.unanswered = 0;
  }

  /// 🔊: the next mode, to be sent.
  cycle() {
    this.mode = nextAudioMode(this.mode);
    this.unanswered += 1;
    return this.mode;
  }

  /// A new peer connection: the mode is sent again, and older replies no longer come.
  resend() {
    this.unanswered = 1;
    return this.mode;
  }

  /// The request could not be sent (no connection); the next connection sends the mode.
  unsent() {
    this.unanswered = Math.max(0, this.unanswered - 1);
  }

  /// `audio.state`: returns true if the mode changed.
  onState(msg) {
    const server = decodeAudioState(msg);
    if (server === null) return false;
    this.unanswered = Math.max(0, this.unanswered - 1);
    if (this.unanswered > 0 || server === this.mode) return false;
    this.mode = server;
    return true;
  }
}

/// The <audio> element and its one MediaStream. The stream is kept for the page's life and
/// only its track is swapped per peer connection, so the element stays unlocked by the first
/// tap (iOS lets an element that played after a user gesture play again without one).
export class AudioOutput {
  constructor(element) {
    this.element = element;
    this.stream = new MediaStream();
    element.srcObject = this.stream;
    this.unlocked = false;
    this.onChange = () => {};
  }

  /// The receiver track of a new peer connection.
  setTrack(track) {
    for (const t of this.stream.getTracks()) this.stream.removeTrack(t);
    if (track) this.stream.addTrack(track);
  }

  /// Starts playback. Inside a tap this unlocks the element; elsewhere it works only once
  /// unlocked. Calls onChange when that is known.
  play() {
    if (navigator.audioSession) {
      try { navigator.audioSession.type = 'playback'; } catch { /* older Safari */ }
    }
    let p;
    try { p = this.element.play(); } catch { p = Promise.reject(new Error('play')); }
    Promise.resolve(p).then(() => {
      this.unlocked = true;
      this.onChange();
    }, () => {
      this.unlocked = false;
      this.onChange();
    });
  }

  pause() {
    this.element.pause();
  }

  /// True while the mode is on but iOS has not let the element play yet ("tap to enable").
  blocked(mode) {
    return mode !== 'off' && !this.unlocked;
  }
}
