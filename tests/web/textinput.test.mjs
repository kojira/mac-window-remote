// Unit tests for the iPhone text field (DESIGN.md D10, D53): a one-row textarea that grows with
// its wrapped text up to a cap, shrinks after send, and keeps D10's Return/Backspace rules.
// A small fake DOM stands in for the browser. Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';

const LINE = 20; // px, the stylesheet's line-height
const PAD = 11; // px, top and bottom padding
const BORDER = 1;

class FakeClassList {
  constructor() { this.set = new Set(); }
  add(c) { this.set.add(c); }
  remove(c) { this.set.delete(c); }
  contains(c) { return this.set.has(c); }
  toggle(c, on = !this.set.has(c)) { if (on) this.set.add(c); else this.set.delete(c); return on; }
}

/// A textarea whose content height is `lines` wrapped lines; scrollHeight includes the padding.
class FakeTextarea {
  constructor() {
    this.tagName = 'TEXTAREA';
    this.value = '';
    this.lines = 1;
    this.style = {};
    this.scrollTop = 0;
    this.listeners = {};
    this.selectionEnd = 0;
  }
  get scrollHeight() { return this.lines * LINE + 2 * PAD; }
  setSelectionRange(a, b) { this.selectionEnd = b; }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  dispatch(type, extra = {}) {
    const e = { type, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, ...extra };
    for (const fn of this.listeners[type] ?? []) fn(e);
    return e;
  }
  focus() { globalThis.document.activeElement = this; this.dispatch('focus'); }
  blur() { globalThis.document.activeElement = null; this.dispatch('blur'); }
}

globalThis.document = { activeElement: null };
globalThis.window = { innerHeight: 800, visualViewport: undefined };
globalThis.getComputedStyle = () => ({
  paddingTop: `${PAD}px`, paddingBottom: `${PAD}px`,
  borderTopWidth: `${BORDER}px`, borderBottomWidth: `${BORDER}px`, lineHeight: `${LINE}px`,
});
const { TextInput } = await import('../../web/input.js');
const { ModifierState } = await import('../../web/modifiers.js');

function setup({ viewport = 800, sendOk = true } = {}) {
  window.innerHeight = viewport;
  const field = new FakeTextarea();
  const bar = { classList: new FakeClassList() };
  const sent = [];
  const modifiers = new ModifierState();
  const ti = new TextInput({
    field, bar, dock: { style: {}, classList: new FakeClassList() }, modifiers,
    send: (m) => { sent.push(m); return sendOk; },
  });
  /// Types text that wraps to `lines` lines, with the caret at the end.
  const type = (text, lines) => {
    field.value = text;
    field.lines = lines;
    field.selectionEnd = text.length;
    field.dispatch('input', { isComposing: false });
  };
  return { field, bar, sent, modifiers, ti, type };
}

const px = (lines) => `${lines * LINE + 2 * PAD + 2 * BORDER}px`;

test('the field grows with wrapped lines while typing', () => {
  const { field, type } = setup();
  field.focus();
  assert.equal(field.style.height, '', 'empty: the stylesheet\'s one-line height');
  type('hello', 1);
  assert.equal(field.style.height, px(1));
  assert.equal(field.style.overflowY, 'hidden');
  type('a long line that wraps', 3);
  assert.equal(field.style.height, px(3));
  assert.equal(field.style.overflowY, 'hidden');  type('', 1);
  assert.equal(field.style.height, '', 'cleared by hand: back to one line');
});

test('the height stops at 8 lines, then the field scrolls with the caret line in view', () => {
  const { field, type } = setup({ viewport: 2000 });
  field.focus();
  type('x'.repeat(400), 12);
  assert.equal(field.style.height, px(8));
  assert.equal(field.style.overflowY, 'auto');
  assert.equal(field.scrollTop, field.scrollHeight, 'caret at the end: scrolled to the last line');
});

test('on a short viewport the cap is 40% of its height', () => {
  const { field, type } = setup({ viewport: 300 });
  field.focus();
  type('x'.repeat(400), 12);
  assert.equal(field.style.height, '120px');
  assert.equal(field.style.overflowY, 'auto');
});

test('the visual viewport height sets the cap when the iOS keyboard is up', () => {
  window.visualViewport = { height: 250, offsetTop: 0, addEventListener() {} };
  try {
    const { field, type } = setup({ viewport: 800 });
    field.focus();
    type('x'.repeat(400), 12);
    assert.equal(field.style.height, '100px');
  } finally { window.visualViewport = undefined; }
});

test('Return sends the text, clears the field, and shrinks it to one line', () => {
  const { field, sent, type } = setup();
  field.focus();
  type('three lines of text', 3);
  const e = field.dispatch('keydown', { key: 'Enter', isComposing: false });
  assert.ok(e.defaultPrevented, 'no newline is inserted');
  assert.deepEqual(sent, [{ t: 'text', text: 'three lines of text' }]);
  assert.equal(field.value, '');
  assert.equal(field.style.height, '');
});

test('when the send fails the text stays and the height is unchanged', () => {
  const { field, type } = setup({ sendOk: false });
  field.focus();
  type('kept', 2);
  field.dispatch('keydown', { key: 'Enter', isComposing: false });
  assert.equal(field.value, 'kept');
  assert.equal(field.style.height, px(2));
});

test('Return on an empty field sends key Enter, without a newline', () => {
  const { field, sent } = setup();
  field.focus();
  const e = field.dispatch('keydown', { key: 'Enter', isComposing: false });
  assert.ok(e.defaultPrevented);
  assert.deepEqual(sent, [{ t: 'key', key: 'Enter', mods: [] }]);
});

test('Return while composing (IME) sends nothing and is left to the IME', () => {
  const { field, sent, type } = setup();
  field.focus();
  type('かんじ', 1);
  for (const extra of [{ isComposing: true }, { isComposing: false, keyCode: 229 }]) {
    const e = field.dispatch('keydown', { key: 'Enter', ...extra });
    assert.ok(!e.defaultPrevented);
  }
  assert.deepEqual(sent, []);
  assert.equal(field.value, 'かんじ');
});

test('Backspace on an empty field sends key Backspace; with text it edits locally', () => {
  const { field, sent, type } = setup();
  field.focus();
  const e = field.dispatch('keydown', { key: 'Backspace', isComposing: false });
  assert.ok(e.defaultPrevented);
  assert.deepEqual(sent, [{ t: 'key', key: 'Backspace', mods: [] }]);
  type('ab', 1);
  const e2 = field.dispatch('keydown', { key: 'Backspace', isComposing: false });
  assert.ok(!e2.defaultPrevented);
  assert.equal(sent.length, 1);
});

test('a pasted line break is dropped, as in the one-line field', () => {
  const { field, sent, type } = setup();
  field.focus();
  type('one\ntwo', 2);
  assert.equal(field.value, 'onetwo');
  assert.equal(field.selectionEnd, 6);
  assert.deepEqual(sent, []);
});

test('blur shrinks the hidden field back to its one-line height', () => {
  const { field, type } = setup();
  field.focus();
  type('x'.repeat(100), 4);
  field.blur();
  assert.equal(field.style.height, '');
});

test('show() gives the typing layout without focusing the field (D54)', () => {
  const { field, bar, ti } = setup();
  ti.show();
  assert.ok(bar.classList.contains('typing'));
  assert.equal(document.activeElement, null, 'not focused: the iOS keyboard stays down');
  assert.equal(ti.isFocused(), false);
});

test('blurring the field keeps the typing layout while shown; without show() it drops it (D54)', () => {
  const { field, bar, ti } = setup();
  field.focus();
  field.blur();
  assert.ok(!bar.classList.contains('typing'), 'not shown: focus alone sets the layout');
  ti.show();
  field.focus();
  field.blur();
  assert.ok(bar.classList.contains('typing'), 'shown: the layout stays after the keyboard hides');
});

test('hide() blurs the field and restores the normal bar (D54)', () => {
  const { field, bar, ti, type } = setup();
  ti.show();
  field.focus();
  type('x'.repeat(100), 4);
  ti.hide();
  assert.equal(document.activeElement, null);
  assert.ok(!bar.classList.contains('typing'));
  assert.equal(field.style.height, '');
});
