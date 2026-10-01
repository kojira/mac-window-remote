// Unit tests for 🎤, this device's microphone as a Mac input (DESIGN.md D57). Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { MicControl, MIC_CONSTRAINTS, MIC_TOASTS } from '../../web/mic.js';

class FakeTrack {
  constructor() { this.stopped = false; this.onended = null; }
  stop() { this.stopped = true; }
}

function setup({ deny = null } = {}) {
  const calls = { gum: [], tracks: [], sent: [], toasts: [], changes: [] };
  let resolveGum;
  const track = new FakeTrack();
  const mic = new MicControl({
    getUserMedia: (c) => {
      calls.gum.push(c);
      if (deny) return Promise.reject(Object.assign(new Error('x'), { name: deny }));
      return new Promise((r) => { resolveGum = () => r({ getAudioTracks: () => [track], getTracks: () => [track] }); });
    },
    setTrack: async (t) => { calls.tracks.push(t); },
    send: (m) => { calls.sent.push(m); return true; },
    toast: (t) => calls.toasts.push(t),
    onChange: () => calls.changes.push(mic.state),
  });
  return { mic, calls, track, grant: () => resolveGum() };
}

const tick = () => new Promise((r) => setTimeout(r, 0));

test('🎤 on asks for the mic with echo cancellation, then sends the track and mic on', async () => {
  const { mic, calls, track, grant } = setup();
  const started = mic.toggle();
  // getUserMedia is called inside the tap, before any await.
  assert.equal(calls.gum.length, 1);
  assert.deepEqual(calls.gum[0], MIC_CONSTRAINTS);
  assert.deepEqual(MIC_CONSTRAINTS.audio, { echoCancellation: true, noiseSuppression: true, autoGainControl: true });
  assert.equal(mic.state, 'starting');
  grant();
  await started;
  assert.equal(mic.state, 'on');
  assert.deepEqual(calls.tracks, [track]);
  assert.deepEqual(calls.sent, [{ t: 'mic', on: true }]);
  assert.deepEqual(calls.changes, ['starting', 'on']);
});

test('🎤 off stops the track, removes it from the sender, and sends mic off', async () => {
  const { mic, calls, track, grant } = setup();
  const started = mic.toggle();
  grant();
  await started;
  mic.toggle();
  await tick();
  assert.equal(mic.state, 'off');
  assert.ok(track.stopped, 'the browser\'s mic indicator goes off');
  assert.deepEqual(calls.tracks, [track, null]);
  assert.deepEqual(calls.sent.at(-1), { t: 'mic', on: false });
});

test('a denied permission shows a toast and stays off', async () => {
  const { mic, calls } = setup({ deny: 'NotAllowedError' });
  await mic.toggle();
  assert.equal(mic.state, 'off');
  assert.deepEqual(calls.toasts, [MIC_TOASTS.denied]);
  assert.deepEqual(calls.sent, []);
});

test('the Mac without BlackHole turns the mic off with the install hint', async () => {
  const { mic, calls, track, grant } = setup();
  const started = mic.toggle();
  grant();
  await started;
  mic.onState({ t: 'mic.state', on: false, error: 'no-device' });
  assert.equal(mic.state, 'off');
  assert.ok(track.stopped);
  assert.deepEqual(calls.toasts, ['Install BlackHole on the Mac to use the mic (see README)']);
  // The Mac already knows; no mic off is sent back.
  assert.deepEqual(calls.sent, [{ t: 'mic', on: true }]);
});

test('mic.state on keeps the mic on; a new connection attaches it again', async () => {
  const { mic, calls, track, grant } = setup();
  const started = mic.toggle();
  grant();
  await started;
  mic.onState({ t: 'mic.state', on: true, device: 'BlackHole 2ch' });
  assert.equal(mic.state, 'on');
  await mic.onReady();
  assert.deepEqual(calls.tracks, [track, track]);
  assert.deepEqual(calls.sent, [{ t: 'mic', on: true }, { t: 'mic', on: true }]);
});

test('turning off while the permission prompt is up stops the late track', async () => {
  const { mic, calls, track, grant } = setup();
  const started = mic.toggle();
  mic.toggle();
  grant();
  await started;
  assert.equal(mic.state, 'off');
  assert.ok(track.stopped);
  assert.deepEqual(calls.tracks, []);
});

test('🎤 sits next to 🔊, is highlighted while on, and is hidden while typing', () => {
  const html = readFileSync(new URL('../../web/index.html', import.meta.url), 'utf8');
  const css = readFileSync(new URL('../../web/style.css', import.meta.url), 'utf8');
  assert.match(html, /id="audio-mode"[^\n]*\n\s*<button id="mic"/);
  assert.match(css, /#bottom-bar\.typing[^{]*#mic[^{]*\{ display: none; \}/);
  assert.match(css, /#mic\.on[^{]*\{ background: #0a84ff; \}/);
});
