// Unit tests for the 🔊 audio mode on the phone (DESIGN.md D39). Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  AudioMode, parseAudioMode, nextAudioMode, audioButtonLabel, decodeAudioState,
} from '../../web/audio.js';

test('the stored mode is off, app, or all; anything else is off', () => {
  assert.equal(parseAudioMode('app'), 'app');
  assert.equal(parseAudioMode('all'), 'all');
  assert.equal(parseAudioMode('off'), 'off');
  assert.equal(parseAudioMode(null), 'off');
  assert.equal(parseAudioMode('mac'), 'off');
});

test('🔊 cycles Off → App → All → Off, and each mode has its own label', () => {
  assert.equal(nextAudioMode('off'), 'app');
  assert.equal(nextAudioMode('app'), 'all');
  assert.equal(nextAudioMode('all'), 'off');
  assert.deepEqual(['off', 'app', 'all'].map((m) => audioButtonLabel(m).text), ['Off', 'App', 'All']);
  assert.equal(audioButtonLabel('off').icon, '🔇');
});

test('audio.state decoding', () => {
  assert.equal(decodeAudioState({ t: 'audio.state', mode: 'all' }), 'all');
  assert.equal(decodeAudioState({ t: 'audio.state', mode: 'loud' }), null);
  assert.equal(decodeAudioState(null), null);
});

test('fast taps keep the newest mode until its reply arrives', () => {
  const m = new AudioMode('off');
  assert.equal(m.cycle(), 'app');
  assert.equal(m.cycle(), 'all');
  // The reply to "app" must not move the button back.
  assert.equal(m.onState({ mode: 'app' }), false);
  assert.equal(m.mode, 'all');
  assert.equal(m.onState({ mode: 'all' }), false);
  assert.equal(m.mode, 'all');
});

test('the Mac turning audio off (unavailable) is taken when nothing newer is pending', () => {
  const m = new AudioMode('all');
  assert.equal(m.resend(), 'all');
  assert.equal(m.onState({ mode: 'all' }), false);
  // After a failure the Mac sends off by itself.
  assert.equal(m.onState({ mode: 'off' }), true);
  assert.equal(m.mode, 'off');
});

test('a request that could not be sent does not hold back later replies', () => {
  const m = new AudioMode('app');
  m.cycle();
  m.unsent();
  assert.equal(m.mode, 'all');
  // The next connection re-sends the current mode.
  assert.equal(m.resend(), 'all');
  assert.equal(m.onState({ mode: 'all' }), false);
  assert.equal(m.onState({ mode: 'off' }), true);
});

test('desktop: a play() that stays pending after a click does not leave 🔊 stuck (D46)', async () => {
  const { AudioOutput } = await import('../../web/audio.js');
  globalThis.MediaStream ??= class { constructor() { this.t = []; } getTracks() { return this.t; } addTrack(x) { this.t.push(x); } removeTrack(x) { this.t = this.t.filter((y) => y !== x); } };
  const saved = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
  Object.defineProperty(globalThis, 'navigator', { value: { userActivation: { hasBeenActive: true } }, configurable: true });
  try {
    const element = { srcObject: null, play: () => new Promise(() => {}), pause() {} };
    const out = new AudioOutput(element);
    let changes = 0;
    out.onChange = () => { changes += 1; };
    out.setTrack({ id: 'a' });
    assert.equal(element.srcObject, out.stream);
    out.play();
    assert.equal(out.blocked('app'), true);
    await new Promise((r) => setTimeout(r, 900));
    assert.equal(out.blocked('app'), false);
    assert.equal(changes, 1);
  } finally {
    if (saved) Object.defineProperty(globalThis, 'navigator', saved); else delete globalThis.navigator;
  }
});
