// Unit tests for ⬇︎ Download (DESIGN.md D47): the file sheet's listing, selection bar,
// search with its base path, errors, and the one-time download URL; D55: the sort.
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
  FileSheet, breadcrumbs, compareEntries, decodeFiles, formatSize, parentPath, selectionSummary, sortEntries,
  SORT_STORAGE_KEY,
} = await import('../../web/files.js');

const HOME = '/home/u';
const PLACES = [{ name: 'Home', path: HOME }, { name: 'Desktop', path: `${HOME}/Desktop` }, { name: 'Computer', path: '/' }];
const LISTING = [
  { name: 'Docs', path: `${HOME}/Docs`, dir: true, size: null, mtime: 0, link: false },
  { name: 'a.txt', path: `${HOME}/a.txt`, dir: false, size: 2048, mtime: 0, link: false },
  { name: 'b.bin', path: `${HOME}/b.bin`, dir: false, size: 1000, mtime: 0, link: false },
];

function fakeStorage(initial = {}) {
  const data = { ...initial };
  return { data, getItem: (k) => (k in data ? data[k] : null), setItem: (k, v) => { data[k] = String(v); } };
}

function setup(storage = fakeStorage(), { uploader = null } = {}) {
  const root = new FakeElement('div');
  root.hidden = true;
  const sent = [];
  const downloads = [];
  let connected = true;
  const sheet = new FileSheet({
    root,
    send: (m) => { if (connected) sent.push(m); return connected; },
    download: (url, name) => downloads.push([url, name]),
    storage,
    uploader,
  });
  const last = () => sent[sent.length - 1];
  const rows = () => sheet.list.children.filter((c) => c.className.startsWith('files-row'));
  const notes = () => sheet.list.children.filter((c) => c.className === 'menu-message').map((c) => c.label);
  const rowNamed = (name) => rows().find((r) => r.children[1].children[1].children[0].label === name);
  const reply = (entries = LISTING, extra = {}) => sheet.onFiles({
    t: 'files', id: last().id, path: HOME, entries, total: entries.length, truncated: false, places: PLACES, ...extra,
  });
  return { storage, root, sheet, sent, downloads, last, rows, notes, rowNamed, reply, disconnect: () => { connected = false; } };
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
  assert.deepEqual(sent[0], { t: 'files.list', id: sent[0].id, path: '~', hidden: false, sort: 'mtime', desc: true });
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
  assert.deepEqual(last(), { t: 'files.list', id: last().id, path: `${HOME}/Docs`, hidden: false, sort: 'mtime', desc: true });
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

// D55: sorting the list.
const E = (name, { dir = false, size = null, mtime = null } = {}) => ({ name, path: `/x/${name}`, dir, size, mtime });
const names = (entries, sort) => sortEntries(entries, sort).map((e) => e.name);
const SORTABLE = [
  E('b.txt', { size: 10, mtime: 300 }),
  E('A.txt', { size: 30, mtime: 100 }),
  E('c.txt', { size: 20, mtime: 200 }),
  E('zdir', { dir: true, mtime: 50 }),
  E('Adir', { dir: true, mtime: 500 }),
];

test('sort: every key in both directions, folders on top', () => {
  assert.deepEqual(names(SORTABLE, { key: 'name', desc: false }), ['Adir', 'zdir', 'A.txt', 'b.txt', 'c.txt']);
  assert.deepEqual(names(SORTABLE, { key: 'name', desc: true }), ['zdir', 'Adir', 'c.txt', 'b.txt', 'A.txt']);
  assert.deepEqual(names(SORTABLE, { key: 'mtime', desc: true }), ['Adir', 'zdir', 'b.txt', 'c.txt', 'A.txt']);
  assert.deepEqual(names(SORTABLE, { key: 'mtime', desc: false }), ['zdir', 'Adir', 'A.txt', 'c.txt', 'b.txt']);
  // Folders have no size: by name in both directions.
  assert.deepEqual(names(SORTABLE, { key: 'size', desc: true }), ['Adir', 'zdir', 'A.txt', 'c.txt', 'b.txt']);
  assert.deepEqual(names(SORTABLE, { key: 'size', desc: false }), ['Adir', 'zdir', 'b.txt', 'c.txt', 'A.txt']);
});

test('sort: ties by case-insensitive name; a missing size or date goes last either way', () => {
  const rows = [E('b', { size: 5, mtime: 9 }), E('none'), E('A', { size: 5, mtime: 9 }), E('c', { size: 7, mtime: 1 })];
  assert.deepEqual(names(rows, { key: 'size', desc: true }), ['c', 'A', 'b', 'none']);
  assert.deepEqual(names(rows, { key: 'size', desc: false }), ['A', 'b', 'c', 'none']);
  assert.deepEqual(names(rows, { key: 'mtime', desc: true }), ['A', 'b', 'c', 'none']);
  assert.deepEqual(names(rows, { key: 'mtime', desc: false }), ['c', 'A', 'b', 'none']);
  assert.equal(compareEntries({ key: 'name', desc: false })(E('a'), E('B')) < 0, true);
});

test('sort control: defaults to Modified ↓, tapping toggles or switches, and the choice is remembered', () => {
  const { sheet, sent, reply, rows, storage } = setup();
  const labels = () => sheet.sortButtons && Object.values(sheet.sortButtons).map((b) => b.label);
  const rowNames = () => rows().map((r) => r.children[1].children[1].children[0].label);
  sheet.open();
  reply(SORTABLE);
  assert.deepEqual(labels(), ['Name', 'Modified ↓', 'Size']);
  assert.deepEqual(rowNames(), ['Adir', 'zdir', 'b.txt', 'c.txt', 'A.txt']);
  const before = sent.length;
  sheet.sortButtons.mtime.dispatch('click');
  assert.deepEqual(labels(), ['Name', 'Modified ↑', 'Size']);
  assert.deepEqual(rowNames(), ['zdir', 'Adir', 'A.txt', 'c.txt', 'b.txt']);
  assert.equal(sent.length, before, 'a complete listing is re-sorted without asking the Mac');
  sheet.sortButtons.name.dispatch('click');
  assert.deepEqual(labels(), ['Name ↑', 'Modified', 'Size']);
  sheet.sortButtons.size.dispatch('click');
  assert.deepEqual(labels(), ['Name', 'Modified', 'Size ↓']);
  assert.equal(sheet.sortButtons.size.attrs['aria-pressed'], 'true');
  assert.deepEqual(JSON.parse(storage.data[SORT_STORAGE_KEY]), { key: 'size', desc: true });
  // Reopening (a new sheet with the same storage) keeps it, and the request carries it.
  const again = setup(storage);
  again.sheet.open();
  assert.deepEqual([again.last().sort, again.last().desc], ['size', true]);
  // A malformed stored value falls back to Modified ↓.
  const bad = setup(fakeStorage({ [SORT_STORAGE_KEY]: '{"key":"kind"}' }));
  bad.sheet.open();
  assert.deepEqual([bad.last().sort, bad.last().desc], ['mtime', true]);
});

test('sort: a capped listing is asked for again in the new order; search results use the same order', () => {
  const { sheet, sent, reply, last, rows } = setup();
  sheet.open();
  reply(SORTABLE, { total: 9000, truncated: true });
  const before = sent.length;
  sheet.sortButtons.size.dispatch('click');
  assert.equal(sent.length, before + 1);
  assert.deepEqual(last(), { t: 'files.list', id: last().id, path: HOME, hidden: false, sort: 'size', desc: true });
  reply(SORTABLE);
  sheet.query.value = 'txt';
  sheet.search();
  sheet.onFound({ t: 'files.found', id: last().id, base: HOME, entries: SORTABLE.filter((e) => !e.dir) });
  const found = () => rows().map((r) => r.children[1].children[1].children[0].label);
  assert.deepEqual(found(), ['A.txt', 'c.txt', 'b.txt']);
  const searches = sent.length;
  sheet.sortButtons.name.dispatch('click');
  assert.deepEqual(found(), ['A.txt', 'b.txt', 'c.txt']);
  assert.equal(sent.length, searches, 'search results are re-sorted on the device');
});

// D58: ⬆︎ Upload here.
function fakeUploader() {
  const u = {
    busy: false, calls: [], cancels: 0, finish: null,
    upload(files, dest, name) {
      u.calls.push({ files, dest, name });
      u.busy = true;
      return new Promise((resolve) => { u.finish = () => { u.busy = false; resolve(); }; });
    },
    cancel() { u.cancels += 1; },
  };
  return u;
}

const dragEvent = (files, types = ['Files']) => {
  const e = { dataTransfer: { types, files, dropEffect: '' }, prevented: false };
  e.preventDefault = () => { e.prevented = true; };
  return e;
};

test('Upload here: enabled for a listed folder, disabled while loading, after an error, and on search results', () => {
  const uploader = fakeUploader();
  const { sheet, last, reply } = setup(fakeStorage(), { uploader });
  sheet.open();
  assert.equal(sheet.uploadButton.disabled, true, 'loading');
  reply();
  assert.equal(sheet.uploadButton.disabled, false);
  assert.equal(sheet.uploadButton.label, '⬆︎ Upload here');
  assert.equal(sheet.uploadButton.attrs['aria-label'], 'Upload files to Home');
  // The picker takes several files and has no type filter.
  assert.equal(sheet.filePicker.type, 'file');
  assert.equal(sheet.filePicker.multiple, true);
  assert.equal(sheet.filePicker.attrs.accept, undefined);
  sheet.query.value = 'a';
  sheet.search();
  assert.equal(sheet.uploadButton.disabled, true, 'search results');
  sheet.query.value = '';
  sheet.clearSearch();
  assert.equal(sheet.uploadButton.disabled, false);
  sheet.navigate('/nope');
  sheet.onError({ t: 'error', id: last().id, code: 'not_found' });
  assert.equal(sheet.uploadButton.disabled, true, 'no folder after an error');
  // Without an uploader the button is hidden.
  const plain = setup();
  plain.sheet.open();
  plain.reply();
  assert.equal(plain.sheet.uploadButton.hidden, true);
});

test('Upload here: the tap opens the picker; picked files go to the folder shown; the button cancels while busy', async () => {
  const uploader = fakeUploader();
  const { sheet, reply } = setup(fakeStorage(), { uploader });
  sheet.open();
  reply();
  let clicked = 0;
  sheet.filePicker.click = () => { clicked += 1; };
  sheet.uploadButton.dispatch('click');
  assert.equal(clicked, 1);
  const files = [{ name: 'a.txt', size: 1 }, { name: 'b.txt', size: 2 }];
  sheet.filePicker.files = files;
  sheet.filePicker.dispatch('change');
  assert.deepEqual(uploader.calls, [{ files, dest: HOME, name: 'Home' }]);
  assert.equal(sheet.uploadButton.label, 'Cancel upload');
  assert.equal(sheet.uploadButton.disabled, false);
  sheet.uploadButton.dispatch('click');
  assert.equal(uploader.cancels, 1);
  assert.equal(clicked, 1, 'no picker while busy');
  uploader.finish();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(sheet.uploadButton.label, '⬆︎ Upload here');
});

test('Upload here: dropping files on the list uploads them; the list is highlighted while dragging', () => {
  const uploader = fakeUploader();
  const { sheet, reply, last } = setup(fakeStorage(), { uploader });
  sheet.open();
  reply();
  const files = [{ name: 'x.bin', size: 3 }];
  const enter = dragEvent(files);
  sheet.list.dispatch('dragenter', enter);
  assert.ok(enter.prevented);
  assert.ok(sheet.list.className.includes('drop'));
  const over = dragEvent(files);
  sheet.list.dispatch('dragover', over);
  assert.ok(over.prevented);
  assert.equal(over.dataTransfer.dropEffect, 'copy');
  sheet.list.dispatch('drop', dragEvent(files));
  assert.ok(!sheet.list.className.includes('drop'));
  assert.deepEqual(uploader.calls, [{ files, dest: HOME, name: 'Home' }]);
  // Text being dragged is not a drop target; a drop on search results does nothing.
  const text = dragEvent([], ['text/plain']);
  sheet.list.dispatch('dragover', text);
  assert.ok(!text.prevented);
  uploader.busy = false;
  sheet.query.value = 'a';
  sheet.search();
  sheet.onFound({ t: 'files.found', id: last().id, base: HOME, entries: [] });
  sheet.list.dispatch('drop', dragEvent(files));
  assert.equal(uploader.calls.length, 1);
});

test('Upload here: after the upload, the folder is listed again in the current sort', () => {
  const uploader = fakeUploader();
  const { sheet, sent, reply } = setup(fakeStorage(), { uploader });
  sheet.open();
  reply();
  const before = sent.length;
  sheet.refreshAfterUpload(HOME);
  assert.equal(sent.length, before + 1);
  assert.deepEqual(sent.at(-1), { t: 'files.list', id: sent.at(-1).id, path: HOME, hidden: false, sort: 'mtime', desc: true });
  // Not when another folder is shown or the sheet is closed.
  sheet.refreshAfterUpload('/elsewhere');
  sheet.close();
  sheet.refreshAfterUpload(HOME);
  assert.equal(sent.length, before + 1);
});
