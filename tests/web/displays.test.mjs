// Unit tests for display mode (DESIGN.md D56): the Displays tab, a display in the slots, the
// hidden ☰ and 📱, and the click path to `view.start {displayId}`.
// A small fake DOM stands in for the browser. Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';

class FakeElement {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.parent = null;
    this.listeners = {};
    this.attrs = {};
    this.hidden = false;
    this.label = '';
    this.className = '';
    const classes = new Set();
    this.classList = {
      add: (c) => classes.add(c),
      remove: (c) => classes.delete(c),
      contains: (c) => classes.has(c),
      toggle: (c, on = !classes.has(c)) => (on ? classes.add(c) : classes.delete(c), on),
    };
  }
  set textContent(v) { if (v === '') { for (const c of this.children) c.parent = null; this.children = []; } this.label = v; }
  get textContent() { return this.label || this.children.map((c) => c.textContent).join(''); }
  setAttribute(k, v) { this.attrs[k] = v; }
  append(...els) { for (const c of els) { c.parent = this; this.children.push(c); } }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  dispatch(type, extra = {}) {
    const e = { type, target: this, preventDefault() {}, ...extra };
    for (let el = this; el; el = el.parent) for (const fn of el.listeners[type] ?? []) fn(e);
  }
}

const store = new Map();
globalThis.document = { createElement: (tag) => new FakeElement(tag) };
globalThis.localStorage = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)) };

const {
  decodeDisplays, displayTarget, isDisplay, renderDisplayList, sameTarget, viewStartMessage, viewStateMatches, viewerControls,
} = await import('../../web/displays.js');
const { parseSlots, resolveSlot } = await import('../../web/slots.js');
const { SlotBar } = await import('../../web/slotbar.js');
const { parseListTab } = await import('../../web/apps.js');

const MSG = { t: 'displays', items: [
  { id: 1, name: 'Built-in Retina Display', w: 1512, h: 982, jpeg: '/9j/' },
  { id: 69733378, name: 'Studio Display', w: 2560, h: 1440 },
  { id: 'x', name: 'bad' }, null,
] };

test('displays decode with thumbnails; malformed items are dropped', () => {
  assert.deepEqual(decodeDisplays(MSG), [
    { id: 1, name: 'Built-in Retina Display', w: 1512, h: 982, src: 'data:image/jpeg;base64,/9j/' },
    { id: 69733378, name: 'Studio Display', w: 2560, h: 1440, src: null },
  ]);
  assert.deepEqual(decodeDisplays({ t: 'displays' }), []);
});

test('the Displays tab is a stored list tab', () => {
  assert.equal(parseListTab('displays'), 'displays');
  assert.equal(parseListTab('apps'), 'apps');
  assert.equal(parseListTab('x'), 'windows');
});

test('the Displays tab renders a row per display, and a click starts viewing it', () => {
  const list = new FakeElement('ul');
  const sent = [];
  renderDisplayList(list, decodeDisplays(MSG), (d) => sent.push(viewStartMessage(displayTarget(d))));
  assert.equal(list.children.length, 2);
  const [first, second] = list.children;
  assert.equal(first.children[0].tag, 'img');
  assert.equal(first.children[0].src, 'data:image/jpeg;base64,/9j/');
  assert.equal(first.textContent, 'Built-in Retina Display1512 × 982');
  assert.equal(second.children[0].tag, 'div', 'no thumbnail, no image');
  second.dispatch('click');
  assert.deepEqual(sent, [{ t: 'view.start', displayId: 69733378 }]);
});

test('a display target: view.start, view.state matching, and the window path unchanged', () => {
  const d = displayTarget({ id: 2, name: 'Studio' });
  assert.deepEqual(d, { id: 2, app: 'Display', title: 'Studio', display: true });
  assert.ok(isDisplay(d));
  assert.deepEqual(viewStartMessage({ id: 2, app: 'A', title: 't' }), { t: 'view.start', windowId: 2 });
  assert.ok(viewStateMatches({ t: 'view.state', displayId: 2, state: 'streaming' }, d));
  assert.ok(!viewStateMatches({ t: 'view.state', windowId: 2, state: 'streaming' }, d));
  assert.ok(viewStateMatches({ t: 'view.state', windowId: 2, state: 'window_gone' }, { id: 2, app: 'A', title: 't' }));
  assert.ok(!viewStateMatches({ t: 'view.state', displayId: 2 }, { id: 2, app: 'A', title: 't' }));
  assert.ok(!sameTarget(d, { id: 2, app: 'A', title: 't' }));
});

test('☰ and 📱 are hidden for a display and shown for a window', () => {
  assert.deepEqual(viewerControls(displayTarget({ id: 2, name: 'S' })), { appMenu: false, fitWindow: false });
  assert.deepEqual(viewerControls({ id: 7, app: 'A', title: 't' }), { appMenu: true, fitWindow: true });
  assert.deepEqual(viewerControls(null), { appMenu: true, fitWindow: true });
});

test('a display slot is stored, resolves by id then name, and is unavailable when unplugged', () => {
  const slot = { windowId: 5, app: 'Display', title: 'Studio', display: true };
  assert.deepEqual(parseSlots(JSON.stringify([slot])), [slot, null, null]);
  const displays = [{ id: 9, name: 'Studio' }];
  assert.deepEqual(resolveSlot(slot, [], displays), { state: 'window', window: { id: 9, app: 'Display', title: 'Studio', display: true } });
  assert.deepEqual(resolveSlot(slot, [], []), { state: 'unavailable' });
  assert.equal(resolveSlot(slot, [], null).window.display, true);
  // A window with the display's id is not the display.
  assert.equal(resolveSlot(slot, [{ id: 5, app: 'Display', title: 'Studio' }], [{ id: 5, name: 'Studio' }]).window.display, true);
});

test('SlotBar assigns the viewed display, shows its thumbnail, and switches to it', () => {
  store.clear();
  globalThis.performance ??= { now: () => 0 };
  let current = displayTarget({ id: 2, name: 'Studio' });
  const switched = [];
  const bar = new SlotBar({ container: new FakeElement('div'), menu: new FakeElement('div'), current: () => current,
    onSwitch: (t) => switched.push(t), onChange: () => {} });
  bar.tap(0); // empty: assign the current display
  assert.deepEqual(JSON.parse(store.get('mwr.slots'))[0], { windowId: 2, app: 'Display', title: 'Studio', display: true });
  assert.ok(bar.hasDisplaySlot());
  assert.deepEqual(bar.windowIds(), [], 'no window thumbnails are requested for a display');
  bar.setDisplays([{ id: 2, name: 'Studio', src: 'data:image/jpeg;base64,AA' }]);
  assert.equal(bar.buttons[0].children[0].src, 'data:image/jpeg;base64,AA');
  assert.ok(bar.buttons[0].classList.contains('current'));
  current = { id: 2, app: 'Editor', title: 'Notes' }; // a window with the same id
  bar.render();
  assert.ok(!bar.buttons[0].classList.contains('current'));
  bar.tap(0);
  assert.deepEqual(switched, [{ id: 2, app: 'Display', title: 'Studio', display: true }]);
});
