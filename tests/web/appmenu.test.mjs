// Unit tests for the ☰ menu sheet (DESIGN.md D43): `menu` decoding, rows with separators,
// disabled items, marks and shortcuts, drill-down and back, and pressing a leaf.
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
    this.disabled = false;
    this.label = '';
    this.className = '';
  }
  set textContent(v) { if (v === '') { for (const c of this.children) c.parent = null; this.children = []; } this.label = v; }
  get textContent() { return this.label || this.children.map((c) => c.textContent).join(''); }
  setAttribute(k, v) { this.attrs[k] = v; }
  append(...els) { for (const c of els) { c.parent = this; this.children.push(c); } }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  dispatch(type) {
    const e = { type, target: this };
    for (let el = this; el; el = el.parent) for (const fn of el.listeners[type] ?? []) fn(e);
  }
}

globalThis.document = { createElement: (tag) => new FakeElement(tag) };
const { decodeMenu, MenuSheet } = await import('../../web/appmenu.js');

const MSG = {
  t: 'menu', gen: 4, windowId: 7, truncated: false,
  menus: [
    { id: '1', title: 'File', enabled: true, items: [
      { id: '1.0', title: 'New', enabled: true, shortcut: '⌘N' },
      { sep: true },
      { id: '1.2', title: 'Open Recent', enabled: true, items: [{ id: '1.2.0', title: 'a.txt', enabled: true }] },
      { id: '1.3', title: 'Close', enabled: false, shortcut: '⌘W' },
    ] },
    { id: '2', title: 'View', enabled: true, items: [
      { id: '2.0', title: 'Sidebar', enabled: true, mark: 'check', shortcut: '⌃⌘S' },
      { id: '2.1', title: 'Mixed', enabled: true, mark: 'mixed' },
    ] },
  ],
};

function setup() {
  const root = new FakeElement('div');
  root.hidden = true;
  const pressed = [];
  const sheet = new MenuSheet({ root, onPress: (item, gen) => pressed.push([item.id, item.title, gen]) });
  const rows = () => sheet.list.children;
  const row = (title) => rows().find((r) => r.children[1]?.label === title);
  return { root, sheet, pressed, rows, row };
}

test('decoding keeps rows and drops malformed ones; ids are never paths', () => {
  const m = decodeMenu(MSG);
  assert.equal(m.gen, 4);
  assert.deepEqual(m.menus[0].items[1], { sep: true });
  assert.equal(m.menus[0].items[3].enabled, false);
  assert.equal(m.menus[1].items[0].mark, 'check');
  const bad = decodeMenu({ gen: 1, windowId: 1, menus: [null, { id: '../x', title: 'X' }, { id: '1', title: 5 },
    { id: '3', title: 'Ok', mark: 'weird' }] });
  assert.deepEqual(bad.menus, [{ id: '3', title: 'Ok', enabled: true, mark: null, shortcut: '', items: null }]);
  assert.equal(decodeMenu({ gen: 1, menus: [] }), null);
  assert.equal(decodeMenu(null), null);
});

test('opens loading, then lists the top-level menus under the app name', () => {
  const { root, sheet, rows } = setup();
  sheet.open('TextEdit');
  assert.equal(root.hidden, false);
  assert.equal(sheet.title.textContent, 'TextEdit');
  assert.equal(sheet.back.hidden, true);
  assert.equal(rows()[0].textContent, 'Loading…');
  sheet.setMenu(decodeMenu(MSG));
  assert.deepEqual(rows().map((r) => r.children[1].label), ['File', 'View']);
  assert.ok(rows().every((r) => r.children[2].label === '›'));
});

test('drilling in shows separators, disabled rows, shortcuts, and marks; ‹ goes back', () => {
  const { sheet, rows, row, pressed } = setup();
  sheet.open('TextEdit');
  sheet.setMenu(decodeMenu(MSG));
  row('File').dispatch('click');
  assert.equal(sheet.title.textContent, 'File');
  assert.equal(sheet.back.hidden, false);
  assert.deepEqual(rows().map((r) => r.className), ['menu-row', 'menu-sep', 'menu-row', 'menu-row disabled']);
  assert.equal(row('New').children[2].label, '⌘N');
  assert.equal(row('Close').disabled, true);
  row('Close').dispatch('click');
  assert.deepEqual(pressed, []);
  row('Open Recent').dispatch('click');
  assert.equal(sheet.title.textContent, 'Open Recent');
  sheet.back.dispatch('click');
  sheet.back.dispatch('click');
  assert.equal(sheet.title.textContent, 'TextEdit');
  row('View').dispatch('click');
  assert.equal(row('Sidebar').children[0].label, '✓');
  assert.equal(row('Sidebar').children[2].label, '⌃⌘S');
  assert.equal(row('Mixed').children[0].label, '–');
});

test('a leaf closes the sheet and is pressed with the listing gen', () => {
  const { root, sheet, row, pressed } = setup();
  sheet.open('TextEdit');
  sheet.setMenu(decodeMenu(MSG));
  row('File').dispatch('click');
  row('Open Recent').dispatch('click');
  row('a.txt').dispatch('click');
  assert.equal(root.hidden, true);
  assert.deepEqual(pressed, [['1.2.0', 'a.txt', 4]]);
});

test('✕ and a tap on the backdrop close; a tap inside the panel does not', () => {
  const { root, sheet } = setup();
  sheet.open('X');
  sheet.panel.dispatch('click');
  assert.equal(root.hidden, false);
  root.dispatch('click');
  assert.equal(root.hidden, true);
  sheet.open('X');
  sheet.title.parent.children[2].dispatch('click');
  assert.equal(root.hidden, true);
  // A late reply does not reopen it.
  sheet.setMenu(decodeMenu(MSG));
  assert.equal(root.hidden, true);
});

test('errors and empty menus show a message', () => {
  const { sheet, rows, row } = setup();
  sheet.open('X');
  sheet.showError("This app's menu can't be read");
  assert.equal(rows()[0].textContent, "This app's menu can't be read");
  sheet.open('X');
  sheet.setMenu(decodeMenu({ gen: 1, windowId: 1, truncated: true, menus: [{ id: '1', title: 'Window', items: [] }] }));
  assert.equal(rows()[rows().length - 1].textContent, 'Some items are not shown');
  row('Window').dispatch('click');
  assert.match(rows()[0].textContent, /only when opened/);
});
