// Unit tests for the key panel's third row and ⋯ menu (DESIGN.md D41): space and ⏎ are keys
// with modifiers and repeat; 📋 Paste, 🖼 Image, 📎 File (D42), and ⌘Q run from the menu items' touchend.
// A small fake DOM stands in for the browser. Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';

class FakeElement {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.parent = null;
    this.listeners = {};
    this.dataset = {};
    this.hidden = false;
    this.label = '';
    const classes = new Set();
    this.classList = {
      add: (c) => classes.add(c),
      remove: (c) => classes.delete(c),
      contains: (c) => classes.has(c),
      toggle: (c, on = !classes.has(c)) => (on ? classes.add(c) : classes.delete(c), on),
    };
  }
  set className(v) { for (const c of v.split(' ')) this.classList.add(c); }
  set textContent(v) { if (v === '') { for (const c of this.children) c.parent = null; this.children = []; } else this.label = v; }
  get textContent() { return this.label; }
  append(child) { child.parent = this; this.children.push(child); }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); this.parent = null; }
  contains(el) { for (let e = el; e; e = e.parent) if (e === this) return true; return false; }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  dispatch(type, extra = {}) {
    const e = { type, target: this, preventDefault() {}, ...extra };
    for (let el = this; el; el = el.parent) for (const fn of el.listeners[type] ?? []) fn(e);
    return e;
  }
}

const docListeners = {};
globalThis.document = {
  createElement: (tag) => new FakeElement(tag),
  addEventListener: (type, fn) => (docListeners[type] ??= []).push(fn),
};
const { KeyPanel } = await import('../../web/keypanel.js');
const { ModifierState } = await import('../../web/modifiers.js');

function setup() {
  const panel = new FakeElement('div');
  panel.hidden = true;
  const sent = [];
  const actions = [];
  const modifiers = new ModifierState();
  const kp = new KeyPanel({
    panel,
    toggle: new FakeElement('button'),
    viewerEl: new FakeElement('div'),
    modifiers,
    textInput: { isFocused: () => false, focus() {}, blur() {} },
    sendKey: (key, mods) => sent.push([key, mods]),
    onLayout: (change) => change(),
    onAction: (a) => actions.push(a),
  });
  kp.open();
  const key = (label) => panel.children.find((b) => b.label === label);
  const item = (label) => kp.menu.children.find((b) => b.label === label);
  const tap = (b) => { b.dispatch('touchstart'); b.dispatch('touchend'); };
  const touchOutside = (target) => { for (const fn of docListeners.touchstart ?? []) fn({ target }); };
  return { panel, kp, sent, actions, modifiers, key, item, tap, touchOutside };
}

test('the third row is ⌘F1, ⌘W, space (wide), ⏎, ⋯; Paste and Image are not in the row', () => {
  const { panel } = setup();
  const labels = panel.children.map((b) => b.label);
  assert.deepEqual(labels.slice(12), ['⌘F1', '⌘W', 'space', '⏎', '⋯']);
  assert.ok(panel.children[14].classList.contains('wide'));
  assert.ok(!labels.includes('📋 Paste') && !labels.includes('🖼 Image'));
});

test('space and ⏎ send Space and Enter with the active modifiers, then repeat while held', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  const { key, sent, modifiers } = setup();
  modifiers.tap('shift');
  key('⏎').dispatch('pointerdown');
  key('⏎').dispatch('pointerup');
  modifiers.tap('cmd');
  key('space').dispatch('pointerdown');
  t.mock.timers.tick(400);
  t.mock.timers.tick(66);
  t.mock.timers.tick(66);
  key('space').dispatch('pointerup');
  t.mock.timers.tick(1000);
  assert.deepEqual(sent, [['Enter', ['shift']], ['Space', ['cmd']], ['Space', ['cmd']], ['Space', ['cmd']]]);
});

test('⋯ opens a menu with 📋 Paste, 🖼 Image, 📎 File, ⬇︎ Download, ⌘Q; ⋯ again closes it', () => {
  const { kp, key, tap } = setup();
  tap(key('⋯'));
  assert.deepEqual(kp.menu.children.map((b) => b.label), ['📋 Paste', '🖼 Image', '📎 File', '⬇︎ Download', '⌘Q']);
  assert.ok(key('⋯').classList.contains('active'));
  tap(key('⋯'));
  assert.equal(kp.isMenuOpen(), false);
  assert.ok(!key('⋯').classList.contains('active'));
});

test('Paste and Image run inside the menu item touchend, then the menu closes', () => {
  const { kp, key, item, tap, actions } = setup();
  tap(key('⋯'));
  const paste = item('📋 Paste');
  paste.dispatch('touchstart');
  assert.deepEqual(actions, [], 'nothing runs on touchstart');
  paste.dispatch('touchend');
  assert.deepEqual(actions, ['paste']);
  assert.equal(kp.isMenuOpen(), false);
  tap(key('⋯'));
  tap(item('🖼 Image'));
  assert.deepEqual(actions, ['paste', 'image']);
  assert.equal(kp.isMenuOpen(), false);
});

test('📎 File runs its action (the file picker) on the item touchend, not touchstart (D42)', () => {
  const { kp, key, item, tap, actions } = setup();
  tap(key('⋯'));
  const file = item('📎 File');
  file.dispatch('touchstart');
  assert.deepEqual(actions, []);
  file.dispatch('touchend');
  assert.deepEqual(actions, ['file']);
  assert.equal(kp.isMenuOpen(), false);
});

test('⬇︎ Download runs the download action from the menu (D47)', () => {
  const { kp, key, item, tap, actions } = setup();
  tap(key('⋯'));
  tap(item('⬇︎ Download'));
  assert.deepEqual(actions, ['download']);
  assert.equal(kp.isMenuOpen(), false);
});

test('⌘Q in the menu sends q with cmd merged with the active modifiers', () => {
  const { key, item, tap, sent, modifiers } = setup();
  modifiers.lock('cmd');
  modifiers.tap('shift');
  tap(key('⋯'));
  tap(item('⌘Q'));
  assert.deepEqual(sent, [['q', ['cmd', 'shift']]]);
  assert.equal(modifiers.get('cmd'), 'locked');
  assert.equal(modifiers.get('shift'), 'off');
});

test('a touch outside closes the menu without running anything; closing the panel closes it', () => {
  const { kp, panel, key, tap, touchOutside, actions, sent } = setup();
  tap(key('⋯'));
  touchOutside(new FakeElement('div'));
  assert.equal(kp.isMenuOpen(), false);
  tap(key('⋯'));
  kp.close();
  assert.equal(kp.isMenuOpen(), false);
  assert.equal(panel.children.some((c) => c.classList.contains('key-menu')), false);
  assert.deepEqual(actions, []);
  assert.deepEqual(sent, []);
});
