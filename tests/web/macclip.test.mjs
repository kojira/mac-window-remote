// Unit tests for text copied on the Mac reaching this device (DESIGN.md D51): writeText
// success → toast; refusal → banner; tap → copy; a newer copy replaces the banner.
// A small fake DOM and a fake clipboard stand in for the browser. Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';
import { MacClipboard, PREVIEW_CHARS, copyWithTextarea, previewText } from '../../web/macclip.js';

class FakeElement {
  constructor() { this.hidden = false; this.textContent = ''; this.listeners = {}; }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  click() { for (const fn of this.listeners.click ?? []) fn({ type: 'click' }); }
}

/// writeText resolves or rejects per `allow`; `written` records successful writes.
function fakeClipboard(allow) {
  const c = { allow, written: [], calls: 0 };
  c.writeText = (text) => {
    c.calls += 1;
    if (typeof c.allow === 'function' ? c.allow(text) : c.allow) { c.written.push(text); return Promise.resolve(); }
    return Promise.reject(new DOMException('NotAllowedError'));
  };
  return c;
}

function setup(clipboard, fallbackCopy = () => false) {
  const root = new FakeElement();
  root.hidden = true;
  const label = new FakeElement();
  const close = new FakeElement();
  const toasts = [];
  const mc = new MacClipboard({ root, label, close, clipboard, toast: (t) => toasts.push(t), fallbackCopy });
  return { mc, root, label, close, toasts };
}

test('a focused desktop browser copies at once and shows a toast, no banner', async () => {
  const clip = fakeClipboard(true);
  const { mc, root, toasts } = setup(clip);
  await mc.onMessage({ t: 'clipboard.mac', seq: 1, text: 'hello' });
  assert.deepEqual(clip.written, ['hello']);
  assert.deepEqual(toasts, ['📋 Copied from the Mac']);
  assert.equal(root.hidden, true);
});

test('a refused write (iOS without a tap, or unfocused) shows the banner; a tap copies and hides it', async () => {
  const clip = fakeClipboard(false);
  const { mc, root, label, toasts } = setup(clip);
  await mc.onMessage({ t: 'clipboard.mac', seq: 1, text: 'line one\nline two' });
  assert.equal(root.hidden, false);
  assert.equal(label.textContent, '📋 Copied on the Mac: “line one line two” — Tap to copy here');
  assert.deepEqual(toasts, []);
  clip.allow = true; // inside the tap, the browser allows it
  await mc.copyPending();
  assert.deepEqual(clip.written, ['line one\nline two']);
  assert.equal(root.hidden, true);
  assert.deepEqual(toasts, ['Copied']);
});

test('the tap falls back to textarea + execCommand when writeText still fails', async () => {
  const clip = fakeClipboard(false);
  const copied = [];
  const { mc, root, toasts } = setup(clip, (t) => { copied.push(t); return true; });
  await mc.onMessage({ t: 'clipboard.mac', seq: 1, text: 'x' });
  await mc.copyPending();
  assert.deepEqual(copied, ['x']);
  assert.equal(root.hidden, true);
  assert.deepEqual(toasts, ['Copied']);
});

test('without the Clipboard API the banner shows and the tap uses the fallback', async () => {
  const copied = [];
  const { mc, root, label } = setup(null, (t) => { copied.push(t); return true; });
  await mc.onMessage({ t: 'clipboard.mac', seq: 1, text: 'abc' });
  assert.equal(root.hidden, false);
  label.click();
  await Promise.resolve();
  assert.deepEqual(copied, ['abc']);
  assert.equal(root.hidden, true);
});

test('when every copy fails the banner stays and says so', async () => {
  const { mc, root, toasts } = setup(fakeClipboard(false), () => false);
  await mc.onMessage({ t: 'clipboard.mac', seq: 1, text: 'abc' });
  await mc.copyPending();
  assert.equal(root.hidden, false);
  assert.deepEqual(toasts, ['Could not copy on this device']);
});

test('a newer copy replaces the banner, and the tap copies the newer text', async () => {
  const clip = fakeClipboard(false);
  const { mc, label } = setup(clip);
  await mc.onMessage({ t: 'clipboard.mac', seq: 1, text: 'old' });
  await mc.onMessage({ t: 'clipboard.mac', seq: 2, text: 'new' });
  assert.match(label.textContent, /“new”/);
  clip.allow = true;
  await mc.copyPending();
  assert.deepEqual(clip.written, ['new']);
});

test('an older refused write does not bring the banner back after a newer copy succeeded', async () => {
  let rejectOld;
  const clip = { written: [], writeText: (t) => (t === 'old' ? new Promise((_, r) => { rejectOld = r; }) : (clip.written.push(t), Promise.resolve())) };
  const { mc, root } = setup(clip);
  const first = mc.onMessage({ t: 'clipboard.mac', seq: 1, text: 'old' });
  await mc.onMessage({ t: 'clipboard.mac', seq: 2, text: 'new' });
  rejectOld(new Error('denied'));
  await first;
  assert.equal(root.hidden, true);
});

test('✕ dismisses the banner', async () => {
  const { mc, root, close } = setup(fakeClipboard(false));
  await mc.onMessage({ t: 'clipboard.mac', seq: 1, text: 'abc' });
  close.click();
  assert.equal(root.hidden, true);
  assert.equal(mc.pending, null);
});

test('a copy over 1 MiB is reported as too large, without a banner', async () => {
  const clip = fakeClipboard(true);
  const { mc, root, toasts } = setup(clip);
  await mc.onMessage({ t: 'clipboard.mac', seq: 1, truncated: true });
  assert.equal(clip.calls, 0);
  assert.equal(root.hidden, true);
  assert.match(toasts[0], /too large/);
});

test('the preview is the first 40 characters on one line', () => {
  assert.equal(previewText('  a\n\tb  '), 'a b');
  const long = '日'.repeat(PREVIEW_CHARS + 5);
  assert.equal(previewText(long), `${'日'.repeat(PREVIEW_CHARS)}…`);
  assert.equal(previewText('x'.repeat(PREVIEW_CHARS)), 'x'.repeat(PREVIEW_CHARS));
});

test('the textarea fallback selects the text, runs copy, and removes the textarea', () => {
  const appended = [];
  const area = { style: {}, setAttribute() {}, select() { this.selected = true; }, remove() { this.removed = true; } };
  const doc = {
    createElement: () => area,
    body: { append: (el) => appended.push(el) },
    execCommand: (cmd) => cmd === 'copy' && area.selected && area.value === 'hi',
  };
  assert.equal(copyWithTextarea('hi', doc), true);
  assert.equal(appended[0], area);
  assert.equal(area.removed, true);
});
