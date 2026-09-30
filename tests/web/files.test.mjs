// Unit tests for ⬇︎ Download (DESIGN.md D47): the file sheet's listing, selection bar,
// search with its base path, errors, and the one-time download URL.
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
    this.checked = false;
    this.value = '';
    this.label = '';
    this.className = '';
    this.style = {};
  }
  set textContent(v) { if (v === '') { for (const c of this.children) c.parent = null; this.children = []; } this.label = v; }
  get textContent() { return this.label || this.children.map((c) => c.textContent).join(''); }
  setAttribute(k, v) { this.attrs[k] = v; }
  append(...els) { for (const c of els) { c.parent = this; this.children.push(c); } }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  dispatch(type, extra = {}) {
    const e = { type, target: this, ...extra };
    for (let el = this; el; el = el.parent) for (const fn of el.listeners[type] ?? []) fn(e);
  }
}

globalThis.document = { createElement: (tag) => new FakeElement(tag) };
const {
  FileSheet, breadcrumbs, decodeFiles, formatSize, parentPath, selectionSummary,
} = await import('../../web/files.js');

const HOME = '/home/u';
const PLACES = [{ name: 'Home', path: HOME }, { name: 'Desktop', path: `${HOME}/Desktop` }, { name: 'Computer', path: '/' }];
const LISTING = [
  { name: 'Docs', path: `${HOME}/Docs`, dir: true, size: null, mtime: 0, link: false },
  { name: 'a.txt', path: `${HOME}/a.txt`, dir: false, size: 2048, mtime: 0, link: false },
  { name: 'b.bin', path: `${HOME}/b.bin`, dir: false, size: 1000, mtime: 0, link: false },
];

function setup() {
  const root = new FakeElement('div');
  root.hidden = true;
  const sent = [];
  const downloads = [];
  let connected = true;
  const sheet = new FileSheet({
    root,
    send: (m) => { if (connected) sent.push(m); return connected; },
    download: (url, name) => downloads.push([url, name]),
  });
  const last = () => sent[sent.length - 1];
  const rows = () => sheet.list.children.filter((c) => c.className.startsWith('files-row'));
  const notes = () => sheet.list.children.filter((c) => c.className === 'menu-message').map((c) => c.label);
  const rowNamed = (name) => rows().find((r) => r.children[1].children[1].children[0].label === name);
  const reply = (entries = LISTING, extra = {}) => sheet.onFiles({
    t: 'files', id: last().id, path: HOME, entries, total: entries.length, truncated: false, places: PLACES, ...extra,
  });
  return { root, sheet, sent, downloads, last, rows, notes, rowNamed, reply, disconnect: () => { connected = false; } };
}

test('helpers: sizes, parent paths, breadcrumbs, and the selection summary', () => {
  assert.equal(formatSize(0), '0 B');
  assert.equal(formatSize(1536), '1.5 KB');
  assert.equal(formatSize(5 * 1024 * 1024), '5.0 MB');
  assert.equal(formatSize(300 * 1024 * 1024), '300 MB');
  assert.equal(parentPath('/a/b'), '/a');
  assert.equal(parentPath('/a'), '/');
  assert.equal(parentPath('/'), null);
  assert.deepEqual(breadcrumbs('/home/u').map((c) => c.path), ['/', '/home', '/home/u']);
  assert.equal(selectionSummary([]), '');
  assert.equal(selectionSummary([LISTING[1], LISTING[2]]), '2 selected · 3.0 KB');
  assert.equal(selectionSummary([LISTING[0], LISTING[1]]), '2 selected · 2.0 KB + folders');
  assert.equal(decodeFiles({ id: 'x' }), null);
  assert.deepEqual(decodeFiles({ id: 'x', path: '/', entries: [{ name: 'bad', path: 'rel' }, null] }).entries, []);
});

test('opens at home with a files.list request, then shows places, crumbs and rows (folders as sent)', () => {
  const { root, sheet, sent, rows, reply, rowNamed } = setup();
  sheet.open();
  assert.equal(root.hidden, false);
  assert.deepEqual(sent[0], { t: 'files.list', id: sent[0].id, path: '~', hidden: false });
  assert.equal(sheet.list.children[0].label, 'Loading…');
  assert.equal(reply(), true);
  assert.deepEqual(sheet.placesBar.children.map((b) => b.label), ['Home', 'Desktop', 'Computer']);
  assert.ok(sheet.placesBar.children[0].className.includes('active'));
  assert.deepEqual(sheet.crumbs.children.map((b) => b.label), ['/', 'home', 'u']);
  assert.equal(rows().length, 3);
  const docs = rowNamed('Docs');
  assert.equal(docs.children[1].children[0].label, '📁');
  assert.equal(rowNamed('a.txt').children[1].children[1].children[1].label.split(' · ')[0], '2.0 KB');
  assert.equal(sheet.base.value, HOME, 'Search in: follows the current folder');
  assert.equal(sheet.bar.hidden, true);
  // A stale reply (another id) is ignored.
  assert.equal(sheet.onFiles({ t: 'files', id: 'old', path: '/', entries: [] }), false);
});

test('a folder row opens it; ‹ and a breadcrumb go up', () => {
  const { sheet, last, reply, rowNamed } = setup();
  sheet.open();
  reply();
  rowNamed('Docs').children[1].dispatch('click');
  assert.deepEqual(last(), { t: 'files.list', id: last().id, path: `${HOME}/Docs`, hidden: false });
  sheet.onFiles({ t: 'files', id: last().id, path: `${HOME}/Docs`, entries: [], places: PLACES });
  assert.deepEqual(sheet.list.children.map((c) => c.label), ['Empty folder']);
  sheet.up.dispatch('click');
  assert.equal(last().path, HOME);
  sheet.crumbs.children[0].dispatch('click');
  assert.equal(last().path, '/');
});

test('checkboxes and file rows select; the sticky bar shows N selected · size and downloads exactly those paths', () => {
  const { sheet, last, reply, rowNamed, downloads } = setup();
  sheet.open();
  reply();
  rowNamed('a.txt').children[0].dispatch('change');
  rowNamed('b.bin').children[1].dispatch('click');
  assert.equal(sheet.bar.hidden, false);
  assert.equal(sheet.summary.label, '2 selected · 3.0 KB');
  assert.ok(rowNamed('a.txt').children[0].checked);
  rowNamed('Docs').children[0].dispatch('change');
  assert.equal(sheet.summary.label, '3 selected · 3.0 KB + folders');
  rowNamed('b.bin').children[0].dispatch('change');
  assert.equal(sheet.summary.label, '2 selected · 2.0 KB + folders');
  sheet.downloadButton.dispatch('click');
  const req = last();
  assert.deepEqual(req, { t: 'download.request', id: req.id, paths: [`${HOME}/a.txt`, `${HOME}/Docs`] });
  assert.equal(sheet.downloadButton.disabled, true);
  assert.equal(sheet.downloadButton.label, 'Preparing…');
  // Only a same-origin /download/ URL for this request starts a download.
  assert.equal(sheet.onReady({ t: 'download.ready', id: req.id, url: 'https://evil.example/x', name: 'x' }), false);
  assert.equal(sheet.onReady({ t: 'download.ready', id: req.id, url: '/download/abc', name: 'u.zip', size: 10 }), true);
  assert.deepEqual(downloads, [['/download/abc', 'u.zip']]);
  assert.equal(sheet.bar.hidden, true, 'the selection clears after the download starts');
});

test('a too-large download shows the reason in the bar and keeps the selection', () => {
  const { sheet, last, reply, rowNamed } = setup();
  sheet.open();
  reply();
  rowNamed('Docs').children[0].dispatch('change');
  sheet.downloadButton.dispatch('click');
  assert.equal(sheet.onError({ t: 'error', id: last().id, code: 'too_large', message: 'x' }), true);
  assert.match(sheet.summary.label, /max 2 GB/);
  assert.equal(sheet.downloadButton.disabled, false);
});

test('an unreadable folder shows No access; the hidden toggle re-lists with hidden: true', () => {
  const { sheet, last, notes } = setup();
  sheet.open();
  assert.equal(sheet.onError({ t: 'error', id: last().id, code: 'no_access', message: 'No access' }), true);
  assert.deepEqual(notes(), ['No access']);
  sheet.hiddenToggle.dispatch('click');
  assert.equal(last().t, 'files.list');
  assert.equal(last().hidden, true);
  assert.equal(sheet.hiddenToggle.attrs['aria-pressed'], 'true');
  assert.equal(sheet.onError({ t: 'error', id: 'someone-else', code: 'no_access' }), false);
});

test('a capped listing says how many are shown', () => {
  const { sheet, reply, notes } = setup();
  sheet.open();
  reply(LISTING, { total: 12345, truncated: true });
  assert.deepEqual(notes(), ['Showing the first 3 of 12,345 items. Use Search to find the rest.']);
});

test('search: current folder by default, "/" and an edited ~ base; results show their parent and are selectable', () => {
  const { sheet, last, reply, rows, notes } = setup();
  sheet.open();
  reply();
  sheet.query.value = 'rep';
  sheet.query.dispatch('keydown', { key: 'Enter' });
  let q = last();
  assert.deepEqual(q, { t: 'files.search', id: q.id, base: HOME, q: 'rep', hidden: false });
  assert.deepEqual(notes(), [`Searching in ${HOME}…`]);
  sheet.onFound({ t: 'files.found', id: q.id, base: HOME, truncated: true, timedOut: false, entries: [
    { name: 'report.pdf', path: `${HOME}/Docs/report.pdf`, dir: false, size: 10, mtime: 0, link: false, parent: `${HOME}/Docs` },
  ] });
  assert.equal(rows().length, 1);
  assert.ok(rows()[0].children[1].children[1].children[1].label.startsWith(`${HOME}/Docs · 10 B`));
  assert.deepEqual(notes(), [`1 found in ${HOME}`, 'Stopped at 500 matches. Type more of the name.']);
  rows()[0].children[0].dispatch('change');
  assert.equal(sheet.summary.label, '1 selected · 10 B');

  // Quick pick "/" and a typed ~ path.
  const pickRoot = sheet.base.parent.children[3];
  pickRoot.dispatch('click');
  sheet.search();
  assert.equal(last().base, '/');
  sheet.base.value = '~/Projects';
  sheet.base.dispatch('input');
  sheet.search();
  q = last();
  assert.equal(q.base, '~/Projects');
  sheet.onFound({ t: 'files.found', id: q.id, base: `${HOME}/Projects`, entries: [], truncated: false, timedOut: true });
  assert.deepEqual(notes(), [`No names match in ${HOME}/Projects`, 'Stopped after 5 seconds. Search in a smaller folder.']);
  // An edited base stays when the folder changes; "current folder" follows it again.
  sheet.navigate(`${HOME}/Docs`);
  sheet.onFiles({ t: 'files', id: last().id, path: `${HOME}/Docs`, entries: [], places: PLACES });
  assert.equal(sheet.base.value, '~/Projects');
  sheet.base.parent.children[2].dispatch('click');
  assert.equal(sheet.base.value, `${HOME}/Docs`);
  // Clearing the field returns to the listing.
  sheet.query.value = 'x';
  sheet.search();
  sheet.query.value = '';
  sheet.query.dispatch('input');
  assert.equal(sheet.found, null);
  assert.deepEqual(notes(), ['Empty folder']);
});

test('not connected: the sheet says so instead of loading forever', () => {
  const { sheet, disconnect, notes } = setup();
  disconnect();
  sheet.open();
  assert.deepEqual(notes(), ['Not connected to the Mac']);
});
