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
  focus() { FakeElement.focused = this; }
  blur() { if (FakeElement.focused === this) FakeElement.focused = null; }
  setSelectionRange(start, end) { this.selection = [start, end]; }
  dispatch(type, extra = {}) {
    const e = { type, target: this, ...extra };
    for (let el = this; el; el = el.parent) for (const fn of el.listeners[type] ?? []) fn(e);
  }
}

globalThis.document = { createElement: (tag) => new FakeElement(tag) };
const {
  FileSheet, breadcrumbs, compareEntries, decodeFiles, formatSize, parentPath, selectionSummary, sortEntries,
  SORT_STORAGE_KEY, renameNameError, renameSelectionEnd,
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

function setup(storage = fakeStorage(), { uploader = null, confirm = () => true } = {}) {
  const root = new FakeElement('div');
  root.hidden = true;
  const sent = [];
  const downloads = [];
  const toasts = [];
  const binary = [];
  const confirms = [];
  let connected = true;
  const sheet = new FileSheet({
    root,
    send: (m) => { if (connected) sent.push(m); return connected; },
    download: (url, name) => downloads.push([url, name]),
    storage,
    uploader,
    toast: (t) => toasts.push(t),
    sendBinary: (b) => { if (connected) binary.push(b); return connected; },
    confirm: (text) => { confirms.push(text); return confirm(text); },
    viewport: null,
  });
  const last = () => sent[sent.length - 1];
  const rows = () => sheet.list.children.filter((c) => c.className.startsWith('files-row'));
  const notes = () => sheet.list.children.filter((c) => c.className === 'menu-message').map((c) => c.label);
  const rowNamed = (name) => rows().find((r) => r.children[1].children[1].children[0].label === name);
  const reply = (entries = LISTING, extra = {}) => sheet.onFiles({
    t: 'files', id: last().id, path: HOME, entries, total: entries.length, truncated: false, places: PLACES, ...extra,
  });
  return {
    storage, root, sheet, sent, downloads, toasts, binary, confirms, last, rows, notes, rowNamed, reply,
    disconnect: () => { connected = false; },
  };
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
  sheet.navigate('/');
  sheet.onFiles({ t: 'files', id: last().id, path: '/', entries: [], places: PLACES });
  assert.equal(sheet.uploadButton.disabled, true, 'the Computer root');
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

// D61: ✏️ Rename for exactly one selected file or folder.

test('rename: the stem is pre-selected; names the Mac refuses are caught on the device', () => {
  assert.equal(renameSelectionEnd('report.final.pdf', false), 12);
  assert.equal(renameSelectionEnd('README', false), 6);
  assert.equal(renameSelectionEnd('.zshrc', false), 6);
  assert.equal(renameSelectionEnd('Photos.library', true), 14, 'a folder: the whole name');
  for (const bad of ['', '/', 'a/b', '.', '..']) assert.equal(renameNameError(bad), 'Invalid name', bad);
  for (const ok of ['.env', 'a..b', ' x ']) assert.equal(renameNameError(ok), '', ok);
});

test('rename: the button shows only with exactly one item selected, file or folder', () => {
  const { sheet, reply, rowNamed } = setup();
  sheet.open();
  reply();
  assert.equal(sheet.bar.hidden, true);
  rowNamed('a.txt').children[0].dispatch('change');
  assert.equal(sheet.renameButton.hidden, false);
  assert.equal(sheet.renameButton.label, '✏️ Rename');
  assert.equal(sheet.bar.children.indexOf(sheet.renameButton) + 1, sheet.bar.children.indexOf(sheet.downloadButton), 'next to Download');
  rowNamed('b.bin').children[0].dispatch('change');
  assert.equal(sheet.renameButton.hidden, true, 'two selected');
  rowNamed('a.txt').children[0].dispatch('change');
  rowNamed('b.bin').children[0].dispatch('change');
  rowNamed('Docs').children[0].dispatch('change');
  assert.equal(sheet.renameButton.hidden, false, 'one folder');
});

test('rename: the tap opens the editor focused with the stem selected; Esc and Cancel close it without sending', () => {
  const { sheet, sent, reply, rowNamed } = setup();
  sheet.open();
  reply();
  rowNamed('a.txt').children[0].dispatch('change');
  const before = sent.length;
  sheet.renameButton.dispatch('click');
  assert.equal(sheet.renameForm.hidden, false);
  assert.equal(sheet.downloadButton.hidden, true);
  assert.equal(sheet.renameButton.hidden, true);
  assert.equal(sheet.renameInput.value, 'a.txt');
  assert.equal(FakeElement.focused, sheet.renameInput, 'focused within the tap (iOS keyboard)');
  assert.deepEqual(sheet.renameInput.selection, [0, 1]);
  sheet.renameInput.dispatch('keydown', { key: 'Escape' });
  assert.equal(sheet.renameForm.hidden, true);
  assert.equal(sheet.downloadButton.hidden, false);
  assert.equal(sent.length, before);
  sheet.renameButton.dispatch('click');
  sheet.renameCancel.dispatch('click');
  assert.equal(sheet.renameForm.hidden, true);
  // A folder: the whole name.
  rowNamed('a.txt').children[0].dispatch('change');
  rowNamed('Docs').children[0].dispatch('change');
  sheet.renameButton.dispatch('click');
  assert.deepEqual(sheet.renameInput.selection, [0, 4]);
  assert.equal(sent.length, before);
});

test('rename: invalid names show an inline error and send nothing; an unchanged name just closes', () => {
  const { sheet, sent, reply, rowNamed } = setup();
  sheet.open();
  reply();
  rowNamed('a.txt').children[0].dispatch('change');
  sheet.renameButton.dispatch('click');
  const before = sent.length;
  for (const bad of ['', '/', 'x/y', '.', '..']) {
    sheet.renameInput.value = bad;
    sheet.renameSubmit.dispatch('click');
    assert.equal(sheet.renameError.label, 'Invalid name', bad);
    assert.equal(sheet.renameForm.hidden, false);
  }
  sheet.renameInput.dispatch('input');
  assert.equal(sheet.renameError.label, '', 'typing clears the error');
  sheet.renameInput.value = 'a.txt';
  sheet.renameInput.dispatch('keydown', { key: 'Enter' });
  assert.equal(sheet.renameForm.hidden, true);
  assert.equal(sent.length, before);
});

test('rename: Return sends files.rename; success toasts, clears the selection and lists again in the current sort', () => {
  const { sheet, last, reply, rowNamed, toasts } = setup();
  sheet.open();
  reply();
  rowNamed('a.txt').children[0].dispatch('change');
  sheet.renameButton.dispatch('click');
  sheet.renameInput.value = 'notes.md';
  sheet.renameInput.dispatch('keydown', { key: 'Enter', isComposing: true });
  assert.equal(last().t, 'files.list', 'Return while composing (IME) does not submit');
  sheet.renameInput.dispatch('keydown', { key: 'Enter' });
  const req = last();
  assert.deepEqual(req, { t: 'files.rename', id: req.id, path: `${HOME}/a.txt`, name: 'notes.md' });
  assert.equal(sheet.renameSubmit.label, 'Renaming…');
  assert.equal(sheet.renameSubmit.disabled, true);
  assert.equal(sheet.onRenamed({ t: 'files.rename.result', id: 'other', path: `${HOME}/a.txt`, newPath: `${HOME}/x` }), false);
  assert.equal(sheet.onRenamed({ t: 'files.rename.result', id: req.id, path: `${HOME}/a.txt`, newPath: `${HOME}/notes.md` }), true);
  assert.deepEqual(toasts, ['Renamed to notes.md']);
  assert.equal(sheet.selected.size, 0);
  assert.equal(sheet.bar.hidden, true);
  assert.equal(sheet.renameForm.hidden, true);
  assert.deepEqual(last(), { t: 'files.list', id: last().id, path: HOME, hidden: false, sort: 'mtime', desc: true });
});

test('rename: from search results the search runs again', () => {
  const { sheet, last, reply, rows, toasts } = setup();
  sheet.open();
  reply();
  sheet.query.value = 'rep';
  sheet.search();
  const q = last();
  sheet.onFound({ t: 'files.found', id: q.id, base: HOME, truncated: false, timedOut: false, entries: [
    { name: 'report.pdf', path: `${HOME}/Docs/report.pdf`, dir: false, size: 10, mtime: 0, link: false, parent: `${HOME}/Docs` },
  ] });
  rows()[0].children[0].dispatch('change');
  sheet.renameButton.dispatch('click');
  assert.deepEqual(sheet.renameInput.selection, [0, 6]);
  sheet.renameInput.value = 'report-2024.pdf';
  sheet.renameSubmit.dispatch('click');
  const req = last();
  assert.deepEqual(req, { t: 'files.rename', id: req.id, path: `${HOME}/Docs/report.pdf`, name: 'report-2024.pdf' });
  sheet.onRenamed({ t: 'files.rename.result', id: req.id, path: req.path, newPath: `${HOME}/Docs/report-2024.pdf` });
  assert.deepEqual(toasts, ['Renamed to report-2024.pdf']);
  assert.deepEqual(last(), { t: 'files.search', id: last().id, base: HOME, q: 'rep', hidden: false });
});

test('rename: Mac errors show their text in the editor, which stays open', () => {
  const { sheet, last, reply, rowNamed } = setup();
  sheet.open();
  reply();
  rowNamed('a.txt').children[0].dispatch('change');
  sheet.renameButton.dispatch('click');
  const cases = {
    exists: 'That name is already used',
    not_writable: "Can't rename here",
    not_found: 'It no longer exists',
    invalid_name: 'Invalid name',
  };
  for (const [code, text] of Object.entries(cases)) {
    sheet.renameInput.value = `n-${code}`;
    sheet.renameSubmit.dispatch('click');
    assert.equal(sheet.onError({ t: 'error', id: last().id, code, message: 'x' }), true);
    assert.equal(sheet.renameError.label, text, code);
    assert.equal(sheet.renameForm.hidden, false);
    assert.equal(sheet.renameSubmit.disabled, false);
  }
});

test('rename: not connected keeps the editor open with the reason', () => {
  const { sheet, reply, rowNamed, disconnect } = setup();
  sheet.open();
  reply();
  rowNamed('a.txt').children[0].dispatch('change');
  sheet.renameButton.dispatch('click');
  sheet.renameInput.value = 'b.txt';
  disconnect();
  sheet.renameSubmit.dispatch('click');
  assert.equal(sheet.renameError.label, 'Not connected to the Mac');
  assert.equal(sheet.renameSubmit.disabled, false);
});

// D62: ＋ New file (the shared name editor in create mode) and ✏️ Edit (the text editor).

/// [header, text] of a `files.write` binary message.
function decodeWrite(bytes) {
  const n = new DataView(bytes.buffer, bytes.byteOffset).getUint32(0);
  const header = JSON.parse(new TextDecoder().decode(bytes.subarray(4, 4 + n)));
  return [header, new TextDecoder().decode(bytes.subarray(4 + n))];
}

/// Opens a.txt in the editor and answers the read.
function openEditor(ctx, { text = 'hello\n', mtime = 1700000000123.4567, size = 6, eol = 'lf' } = {}) {
  const { sheet, last, reply, rowNamed } = ctx;
  sheet.open();
  reply();
  rowNamed('a.txt').children[0].dispatch('change');
  sheet.editButton.dispatch('click');
  const req = last();
  assert.deepEqual(req, { t: 'files.read', id: req.id, path: `${HOME}/a.txt` });
  assert.equal(sheet.editor.onRead({ t: 'files.read.result', id: req.id, path: req.path, text, mtime, size, eol }), true);
  return req;
}

const type = (editor, text) => { editor.text.value = text; editor.text.dispatch('input'); };

test('New file: next to Upload here, enabled under the same conditions', () => {
  const { sheet, last, reply } = setup(fakeStorage(), { uploader: fakeUploader() });
  sheet.open();
  assert.equal(sheet.sortBar.children.indexOf(sheet.newFileButton) + 1, sheet.sortBar.children.indexOf(sheet.uploadButton));
  assert.equal(sheet.newFileButton.label, '＋ New file');
  assert.equal(sheet.newFileButton.disabled, true, 'loading');
  reply();
  assert.equal(sheet.newFileButton.disabled, false);
  sheet.query.value = 'a';
  sheet.search();
  assert.equal(sheet.newFileButton.disabled, true, 'search results');
  sheet.clearSearch();
  sheet.navigate('/');
  sheet.onFiles({ t: 'files', id: last().id, path: '/', entries: [], places: PLACES });
  assert.equal(sheet.newFileButton.disabled, true, 'the Computer root');
  sheet.newFileButton.dispatch('click');
  assert.equal(sheet.renameForm.hidden, true, 'a disabled tap does nothing');
});

test('New file: the shared name editor starts at untitled.txt with "untitled" selected; Create sends files.create', () => {
  const { sheet, sent, last, reply, toasts } = setup(fakeStorage(), { uploader: fakeUploader() });
  sheet.open();
  reply();
  sheet.newFileButton.dispatch('click');
  assert.equal(sheet.renameForm.hidden, false);
  assert.equal(sheet.bar.hidden, false, 'the bar shows without a selection');
  assert.equal(sheet.renameInput.value, 'untitled.txt');
  assert.deepEqual(sheet.renameInput.selection, [0, 8]);
  assert.equal(FakeElement.focused, sheet.renameInput, 'focused within the tap (iOS keyboard)');
  assert.equal(sheet.renameSubmit.label, 'Create');
  assert.equal(sheet.renameButton.hidden, true);
  // The same device checks as rename.
  const before = sent.length;
  sheet.renameInput.value = 'a/b';
  sheet.renameSubmit.dispatch('click');
  assert.equal(sheet.renameError.label, 'Invalid name');
  assert.equal(sent.length, before);
  // Esc cancels.
  sheet.renameInput.dispatch('keydown', { key: 'Escape' });
  assert.equal(sheet.renameForm.hidden, true);

  sheet.newFileButton.dispatch('click');
  sheet.renameInput.value = 'notes.md';
  sheet.renameInput.dispatch('keydown', { key: 'Enter' });
  const req = last();
  assert.deepEqual(req, { t: 'files.create', id: req.id, dir: HOME, name: 'notes.md' });
  assert.equal(sheet.renameSubmit.label, 'Creating…');
  // Taken: the editor stays open with the reason.
  assert.equal(sheet.onError({ t: 'error', id: req.id, code: 'exists', message: 'x' }), true);
  assert.equal(sheet.renameError.label, 'That name is already used');
  assert.equal(sheet.renameForm.hidden, false);
  sheet.renameInput.value = 'notes2.md';
  sheet.renameSubmit.dispatch('click');
  const req2 = last();
  assert.equal(sheet.onCreated({ t: 'files.create.result', id: 'other', path: `${HOME}/x` }), false);
  assert.equal(sheet.onCreated({ t: 'files.create.result', id: req2.id, path: `${HOME}/notes2.md` }), true);
  assert.equal(sheet.renameForm.hidden, true);
  // Listed again, and the new file opens in the editor.
  assert.deepEqual(sent.at(-2), { t: 'files.list', id: sent.at(-2).id, path: HOME, hidden: false, sort: 'mtime', desc: true });
  assert.deepEqual(last(), { t: 'files.read', id: last().id, path: `${HOME}/notes2.md` });
  assert.equal(sheet.editor.isOpen, true);
  assert.equal(sheet.editor.title.label, 'notes2.md');
  assert.deepEqual(toasts, []);
});

test('Edit: shown only with exactly one file selected, next to Rename; Download stays', () => {
  const { sheet, reply, rowNamed } = setup();
  sheet.open();
  reply();
  rowNamed('a.txt').children[0].dispatch('change');
  assert.equal(sheet.editButton.hidden, false);
  assert.equal(sheet.editButton.label, '✏️ Edit');
  assert.equal(sheet.bar.children.indexOf(sheet.editButton) + 1, sheet.bar.children.indexOf(sheet.renameButton));
  assert.equal(sheet.downloadButton.hidden, false);
  rowNamed('b.bin').children[0].dispatch('change');
  assert.equal(sheet.editButton.hidden, true, 'two selected');
  rowNamed('a.txt').children[0].dispatch('change');
  rowNamed('b.bin').children[0].dispatch('change');
  rowNamed('Docs').children[0].dispatch('change');
  assert.equal(sheet.editButton.hidden, true, 'a folder');
  assert.equal(sheet.renameButton.hidden, false);
});

test('Edit: the editor shows the name, a plain monospace textarea, and the unsaved marker', () => {
  const ctx = setup();
  openEditor(ctx);
  const { editor } = ctx.sheet;
  assert.equal(editor.isOpen, true);
  assert.equal(editor.title.label, 'a.txt');
  assert.equal(editor.text.tag, 'textarea');
  assert.equal(editor.text.attrs.autocapitalize, 'off');
  assert.equal(editor.text.attrs.autocorrect, 'off');
  assert.equal(editor.text.spellcheck, false);
  assert.equal(editor.text.value, 'hello\n');
  assert.equal(editor.marker.label, '');
  type(editor, 'hello world\n');
  assert.equal(editor.marker.label, ' •');
  type(editor, 'hello\n');
  assert.equal(editor.marker.label, '', 'back to the saved text');
});

test('Edit: Close and Esc confirm "Discard changes?" only with unsaved changes', () => {
  let answer = false;
  const ctx = setup(fakeStorage(), { confirm: () => answer });
  openEditor(ctx);
  const { editor } = ctx.sheet;
  editor.closeButton.dispatch('click');
  assert.equal(editor.isOpen, false, 'nothing changed: closes at once');
  assert.deepEqual(ctx.confirms, []);
  openEditor(ctx);
  type(editor, 'changed');
  editor.closeButton.dispatch('click');
  assert.deepEqual(ctx.confirms, ['Discard changes?']);
  assert.equal(editor.isOpen, true, 'declined');
  answer = true;
  editor.text.dispatch('keydown', { key: 'Escape' });
  assert.deepEqual(ctx.confirms, ['Discard changes?', 'Discard changes?']);
  assert.equal(editor.isOpen, false);
  // A tap on the backdrop asks too.
  answer = false;
  openEditor(ctx);
  type(editor, 'changed');
  ctx.root.dispatch('click');
  assert.equal(editor.isOpen, true);
  assert.equal(ctx.sheet.isOpen, true);
});

test('Edit: Save sends files.write with the base; the reply clears the marker, toasts, and is the next base', () => {
  const ctx = setup();
  openEditor(ctx, { eol: 'crlf' });
  const { editor } = ctx.sheet;
  type(editor, 'héllo\n');
  editor.saveButton.dispatch('click');
  const [h, text] = decodeWrite(ctx.binary[0]);
  assert.deepEqual(h, { t: 'files.write', id: h.id, path: `${HOME}/a.txt`, baseMtime: 1700000000123.4567, baseSize: 6, eol: 'crlf' });
  assert.equal(text, 'héllo\n');
  assert.equal(editor.saveButton.label, 'Saving…');
  assert.equal(editor.saveButton.disabled, true);
  assert.equal(editor.onWritten({ t: 'files.write.result', id: h.id, path: h.path, mtime: 42.5, size: 8 }), true);
  assert.equal(editor.marker.label, '');
  assert.deepEqual(ctx.toasts, ['Saved']);
  type(editor, 'again');
  editor.saveButton.dispatch('click');
  const [h2] = decodeWrite(ctx.binary[1]);
  assert.equal(h2.baseMtime, 42.5);
  assert.equal(h2.baseSize, 8);
  // After a save, closing lists the folder again.
  editor.onWritten({ t: 'files.write.result', id: h2.id, path: h2.path, mtime: 43, size: 5 });
  const before = ctx.sent.length;
  editor.closeButton.dispatch('click');
  assert.equal(ctx.sent.length, before + 1);
  assert.equal(ctx.last().t, 'files.list');
});

test('Edit: a conflict asks "Changed on the Mac. Overwrite?"; OK resends with force', () => {
  let answer = false;
  const ctx = setup(fakeStorage(), { confirm: () => answer });
  openEditor(ctx);
  const { editor } = ctx.sheet;
  type(editor, 'mine');
  editor.saveButton.dispatch('click');
  let [h] = decodeWrite(ctx.binary[0]);
  assert.equal(ctx.sheet.onError({ t: 'error', id: h.id, code: 'conflict', message: 'x' }), true);
  assert.deepEqual(ctx.confirms, ['Changed on the Mac. Overwrite?']);
  assert.equal(ctx.binary.length, 1, 'declined: not sent');
  assert.equal(editor.marker.label, ' •', 'still unsaved');
  answer = true;
  editor.saveButton.dispatch('click');
  [h] = decodeWrite(ctx.binary[1]);
  ctx.sheet.onError({ t: 'error', id: h.id, code: 'conflict', message: 'x' });
  const [forced, text] = decodeWrite(ctx.binary[2]);
  assert.equal(forced.force, true);
  assert.equal(text, 'mine');
  assert.equal(h.force, undefined);
});

test('Edit: ⌘S and Ctrl+S save; other keys do not', () => {
  const ctx = setup();
  openEditor(ctx);
  const { editor } = ctx.sheet;
  type(editor, 'x');
  let prevented = 0;
  const key = (extra) => editor.text.dispatch('keydown', { preventDefault: () => { prevented += 1; }, ...extra });
  key({ key: 's' });
  assert.equal(ctx.binary.length, 0);
  key({ key: 's', metaKey: true });
  assert.equal(ctx.binary.length, 1);
  assert.equal(prevented, 1, 'the browser\'s Save Page is stopped');
  const [h] = decodeWrite(ctx.binary[0]);
  editor.onWritten({ t: 'files.write.result', id: h.id, path: h.path, mtime: 1, size: 1 });
  type(editor, 'y');
  key({ key: 's', ctrlKey: true });
  assert.equal(ctx.binary.length, 2);
});

test('Edit: error texts for read and save', () => {
  const read = {
    too_large: 'Too large to edit (over 1 MB)',
    not_text: "Can't edit this file (not text)",
    not_found: 'It no longer exists',
  };
  for (const [code, text] of Object.entries(read)) {
    const ctx = setup();
    ctx.sheet.open();
    ctx.reply();
    ctx.rowNamed('a.txt').children[0].dispatch('change');
    ctx.sheet.editButton.dispatch('click');
    assert.equal(ctx.sheet.onError({ t: 'error', id: ctx.last().id, code, message: 'x' }), true);
    assert.deepEqual(ctx.toasts, [text], code);
    assert.equal(ctx.sheet.editor.isOpen, false, 'nothing loaded: closed');
  }
  const save = { not_writable: "Can't save here", not_found: 'It no longer exists', too_large: 'Too large to edit (over 1 MB)' };
  for (const [code, text] of Object.entries(save)) {
    const ctx = setup();
    openEditor(ctx);
    type(ctx.sheet.editor, 'x');
    ctx.sheet.editor.saveButton.dispatch('click');
    const [h] = decodeWrite(ctx.binary[0]);
    ctx.sheet.onError({ t: 'error', id: h.id, code, message: 'x' });
    assert.deepEqual(ctx.toasts, [text], code);
    assert.equal(ctx.sheet.editor.isOpen, true, 'the text stays');
    assert.equal(ctx.sheet.editor.saveButton.disabled, false);
  }
});

test('Edit: over 1 MiB (counting CRLF) is refused on the device; a lost connection keeps the text', async () => {
  const { savedByteLength, EDIT_MAX_BYTES } = await import('../../web/fileeditor.js');
  assert.equal(savedByteLength('a\nb\n', 'lf'), 4);
  assert.equal(savedByteLength('a\nb\n', 'crlf'), 6);
  assert.equal(savedByteLength('é', 'lf'), 2);
  const ctx = setup();
  openEditor(ctx, { eol: 'crlf' });
  const { editor } = ctx.sheet;
  type(editor, '\n'.repeat(EDIT_MAX_BYTES / 2 + 1));
  editor.saveButton.dispatch('click');
  assert.equal(ctx.binary.length, 0);
  assert.deepEqual(ctx.toasts, ['Too large to edit (over 1 MB)']);
  type(editor, 'ok');
  editor.saveButton.dispatch('click');
  editor.abandon();
  assert.equal(ctx.toasts.at(-1), 'Not saved — connection lost');
  assert.equal(editor.isOpen, true);
  assert.equal(editor.saveButton.disabled, false);
  assert.equal(editor.text.value, 'ok');
});

test('Edit: the editor follows the visual viewport (iOS keyboard)', async () => {
  const { FileEditor } = await import('../../web/fileeditor.js');
  const listeners = {};
  const viewport = { height: 800, offsetTop: 0, addEventListener: (t, fn) => { listeners[t] = fn; } };
  const parent = new FakeElement('div');
  const sent = [];
  const editor = new FileEditor({
    parent, send: (m) => { sent.push(m); return true; }, sendBinary: () => true, nextId: () => 'e1',
    toast: () => {}, confirm: () => true, viewport,
  });
  editor.open('/x/a.txt', 'a.txt');
  assert.equal(editor.root.style.height, '800px');
  viewport.height = 420;
  viewport.offsetTop = 30;
  listeners.resize();
  assert.equal(editor.root.style.height, '420px');
  assert.equal(editor.root.style.top, '30px');
});
