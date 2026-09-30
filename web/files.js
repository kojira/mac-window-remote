// ⬇︎ Download (DESIGN.md D47): a full-height file browser over the whole Mac filesystem.
// Listing and search go over the socket (`files.list`, `files.search`); the Download button
// asks for a one-time URL for exactly the selected paths (`download.request`) and then
// navigates an <a download> to it, so iOS Safari and desktop browsers save the file.

/// "1.5 MB"-style sizes, 1024-based like the 2 GB download cap.
export function formatSize(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return '';
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = bytes / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
  return `${v < 10 ? v.toFixed(1) : Math.round(v)} ${units[i]}`;
}

/// "2024-03-05 14:07" in local time; '' when unknown.
export function formatDate(ms) {
  if (!Number.isFinite(ms)) return '';
  const d = new Date(ms);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

function decodeEntry(e) {
  if (!e || typeof e.name !== 'string' || typeof e.path !== 'string' || !e.path.startsWith('/')) return null;
  return {
    name: e.name,
    path: e.path,
    dir: e.dir === true,
    size: Number.isFinite(e.size) ? e.size : null,
    mtime: Number.isFinite(e.mtime) ? e.mtime : null,
    link: e.link === true,
    parent: typeof e.parent === 'string' ? e.parent : null,
  };
}

const decodeEntries = (list) => (Array.isArray(list) ? list.map(decodeEntry).filter(Boolean) : []);

/// The `files` message; null if malformed.
export function decodeFiles(msg) {
  if (!msg || typeof msg.id !== 'string' || typeof msg.path !== 'string') return null;
  const places = Array.isArray(msg.places)
    ? msg.places.filter((p) => p && typeof p.name === 'string' && typeof p.path === 'string') : [];
  const entries = decodeEntries(msg.entries);
  return {
    id: msg.id, path: msg.path, entries, places,
    total: Number.isInteger(msg.total) ? msg.total : entries.length, truncated: msg.truncated === true,
  };
}

/// The `files.found` message; null if malformed.
export function decodeFound(msg) {
  if (!msg || typeof msg.id !== 'string' || typeof msg.base !== 'string') return null;
  return {
    id: msg.id, base: msg.base, entries: decodeEntries(msg.entries),
    truncated: msg.truncated === true, timedOut: msg.timedOut === true,
  };
}

/// "/a/b" → "/a"; "/a" → "/"; "/" → null.
export function parentPath(path) {
  if (path === '/' || !path.startsWith('/')) return null;
  const i = path.lastIndexOf('/');
  return i <= 0 ? '/' : path.slice(0, i);
}

/// "/a/b" → [{name: '/', path: '/'}, {name: 'a', path: '/a'}, {name: 'b', path: '/a/b'}].
export function breadcrumbs(path) {
  const crumbs = [{ name: '/', path: '/' }];
  let at = '';
  for (const part of path.split('/').filter(Boolean)) {
    at += `/${part}`;
    crumbs.push({ name: part, path: at });
  }
  return crumbs;
}

/// "3 selected · 12 KB" (folders' sizes are counted on the Mac when downloading).
export function selectionSummary(items) {
  const n = items.length;
  if (n === 0) return '';
  const bytes = items.reduce((sum, e) => sum + (e.dir ? 0 : e.size ?? 0), 0);
  const folders = items.some((e) => e.dir);
  return `${n} selected · ${formatSize(bytes)}${folders ? ' + folders' : ''}`;
}

const ERROR_TEXT = {
  no_access: 'No access',
  not_found: 'Not found',
  not_a_directory: 'Not a folder',
  too_large: 'Too large to download (max 2 GB, 100,000 files). Select fewer items.',
  bad_request: 'Not a valid path',
};

function el(tag, className, text) {
  const e = document.createElement(tag);
  if (className) e.className = className;
  if (text != null) e.textContent = text;
  return e;
}

function button(className, text, onClick, label) {
  const b = el('button', className, text);
  b.type = 'button';
  if (label) b.setAttribute('aria-label', label);
  b.addEventListener('click', onClick);
  return b;
}

export class FileSheet {
  /// root: the backdrop element (hidden when closed). send(msg): a socket message, false if not
  /// connected. download(url, name): start the browser download.
  constructor({ root, send, download }) {
    this.root = root;
    this.send = send;
    this.download = download;
    this.counter = 0;
    this.path = '';
    this.listing = null;   // decoded `files` of `path`
    this.found = null;     // decoded `files.found` while searching
    this.places = [];
    this.message = '';
    this.showHidden = false;
    this.selected = new Map(); // path → entry
    this.listId = null;
    this.searchId = null;
    this.downloadId = null;
    this.baseFollows = true; // "Search in:" tracks the current folder until edited

    const panel = el('div', 'menu-panel files-panel');
    const header = el('div', 'menu-header');
    this.up = button('menu-back', '‹', () => this.goUp(), 'Up');
    this.crumbs = el('div', 'files-crumbs');
    header.append(this.up, this.crumbs, button('menu-close', '✕', () => this.close(), 'Close'));

    this.placesBar = el('div', 'files-places');

    const searchRow = el('div', 'files-search');
    this.query = el('input', 'files-query');
    this.query.type = 'search';
    this.query.placeholder = 'Search file names';
    this.query.setAttribute('enterkeyhint', 'search');
    this.query.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault?.(); this.search(); } });
    this.query.addEventListener('input', () => { if (this.query.value.trim() === '') this.clearSearch(); });
    this.hiddenToggle = button('files-hidden', 'Hidden', () => this.toggleHidden(), 'Show hidden files');
    searchRow.append(this.query, button('files-go', 'Search', () => this.search()), this.hiddenToggle);

    const baseRow = el('div', 'files-base');
    this.base = el('input', 'files-base-input');
    this.base.setAttribute('autocapitalize', 'off');
    this.base.setAttribute('autocorrect', 'off');
    this.base.spellcheck = false;
    this.base.addEventListener('input', () => { this.baseFollows = false; });
    this.base.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault?.(); this.search(); } });
    baseRow.append(el('span', 'files-base-label', 'Search in:'), this.base,
      button('files-pick', 'current folder', () => { this.baseFollows = true; this.base.value = this.path; }),
      button('files-pick', '/', () => { this.baseFollows = false; this.base.value = '/'; }));

    this.list = el('div', 'menu-list files-list');

    this.bar = el('div', 'files-bar');
    this.summary = el('span', 'files-summary');
    this.downloadButton = button('files-download primary', 'Download', () => this.requestDownload());
    this.bar.append(this.summary, this.downloadButton);

    panel.append(header, this.placesBar, searchRow, baseRow, this.list, this.bar);
    root.append(panel);
    this.panel = panel;
    root.addEventListener('click', (e) => { if (e.target === root) this.close(); });
  }

  get isOpen() { return !this.root.hidden; }

  nextId() {
    this.counter += 1;
    return `f${this.counter}`;
  }

  /// Opens at the home folder, or where it was last time.
  open() {
    this.root.hidden = false;
    this.selected.clear();
    this.found = null;
    this.query.value = '';
    this.navigate(this.path || '~');
  }

  close() {
    this.root.hidden = true;
    this.listId = this.searchId = this.downloadId = null;
    this.list.textContent = '';
  }

  navigate(path) {
    this.found = null;
    this.searchId = null;
    this.query.value = '';
    this.listId = this.nextId();
    if (path.startsWith('/')) this.path = path;
    this.listing = null;
    this.message = 'Loading…';
    if (!this.send({ t: 'files.list', id: this.listId, path, hidden: this.showHidden })) {
      this.listId = null;
      this.message = 'Not connected to the Mac';
    }
    this.render();
  }

  goUp() {
    const up = parentPath(this.path);
    if (up) this.navigate(up);
  }

  toggleHidden() {
    this.showHidden = !this.showHidden;
    if (this.found) this.search(); else this.navigate(this.path || '~');
  }

  search() {
    const q = this.query.value.trim();
    if (!q) { this.clearSearch(); return; }
    const base = this.base.value.trim() || this.path || '~';
    this.searchId = this.nextId();
    this.found = { id: this.searchId, base, entries: [], truncated: false, timedOut: false, pending: true };
    if (!this.send({ t: 'files.search', id: this.searchId, base, q, hidden: this.showHidden })) {
      this.searchId = null;
      this.found = { ...this.found, pending: false, error: 'Not connected to the Mac' };
    }
    this.render();
  }

  clearSearch() {
    if (!this.found) return;
    this.found = null;
    this.searchId = null;
    this.render();
  }

  /// A `files` reply; true if it was for this sheet.
  onFiles(msg) {
    const files = decodeFiles(msg);
    if (!files || files.id !== this.listId) return false;
    this.listId = null;
    this.path = files.path;
    this.listing = files;
    this.places = files.places;
    this.message = '';
    if (this.baseFollows) this.base.value = files.path;
    this.render();
    return true;
  }

  /// A `files.found` reply; true if it was for this sheet.
  onFound(msg) {
    const found = decodeFound(msg);
    if (!found || found.id !== this.searchId) return false;
    this.searchId = null;
    this.found = found;
    this.render();
    return true;
  }

  /// A `download.ready` reply; true if it was for this sheet.
  onReady(msg) {
    if (!msg || msg.id !== this.downloadId || typeof msg.url !== 'string' || !msg.url.startsWith('/download/')) return false;
    this.downloadId = null;
    this.download(msg.url, typeof msg.name === 'string' ? msg.name : '');
    this.selected.clear();
    this.render();
    return true;
  }

  /// An `error` for one of this sheet's requests; true if it was.
  onError(msg) {
    if (!msg || msg.id == null) return false;
    const text = ERROR_TEXT[msg.code] ?? msg.message ?? msg.code;
    if (msg.id === this.listId) {
      this.listId = null;
      this.listing = null;
      this.message = text;
    } else if (msg.id === this.searchId) {
      this.searchId = null;
      this.found = { ...this.found, pending: false, error: text };
    } else if (msg.id === this.downloadId) {
      this.downloadId = null;
      this.barError = text;
    } else {
      return false;
    }
    this.render();
    return true;
  }

  requestDownload() {
    if (this.selected.size === 0 || this.downloadId) return;
    this.barError = '';
    this.downloadId = this.nextId();
    if (!this.send({ t: 'download.request', id: this.downloadId, paths: [...this.selected.keys()] })) {
      this.downloadId = null;
      this.barError = 'Not connected to the Mac';
    }
    this.renderBar();
  }

  toggle(entry) {
    if (this.selected.has(entry.path)) this.selected.delete(entry.path);
    else this.selected.set(entry.path, entry);
    this.barError = '';
    this.render();
  }

  render() {
    this.up.disabled = !parentPath(this.path);
    this.crumbs.textContent = '';
    for (const c of breadcrumbs(this.path || '/')) {
      this.crumbs.append(button('files-crumb', c.name, () => this.navigate(c.path)));
    }
    this.placesBar.textContent = '';
    for (const p of this.places) {
      const b = button(p.path === this.path ? 'files-place active' : 'files-place', p.name, () => this.navigate(p.path));
      this.placesBar.append(b);
    }
    this.hiddenToggle.className = this.showHidden ? 'files-hidden active' : 'files-hidden';
    this.hiddenToggle.setAttribute('aria-pressed', String(this.showHidden));
    this.list.textContent = '';
    if (this.found) this.renderFound(); else this.renderListing();
    this.renderBar();
  }

  note(text) { this.list.append(el('p', 'menu-message', text)); }

  renderListing() {
    if (!this.listing) { this.note(this.message); return; }
    if (this.listing.entries.length === 0) this.note('Empty folder');
    for (const e of this.listing.entries) this.list.append(this.row(e, false));
    if (this.listing.truncated) {
      this.note(`Showing the first ${this.listing.entries.length.toLocaleString('en-US')} of `
        + `${this.listing.total.toLocaleString('en-US')} items. Use Search to find the rest.`);
    }
  }

  renderFound() {
    const f = this.found;
    if (f.pending) { this.note(`Searching in ${f.base}…`); return; }
    if (f.error) { this.note(f.error); return; }
    this.note(f.entries.length === 0 ? `No names match in ${f.base}` : `${f.entries.length} found in ${f.base}`);
    for (const e of f.entries) this.list.append(this.row(e, true));
    if (f.truncated) this.note('Stopped at 500 matches. Type more of the name.');
    else if (f.timedOut) this.note('Stopped after 5 seconds. Search in a smaller folder.');
  }

  row(entry, withParent) {
    const selected = this.selected.has(entry.path);
    const r = el('div', selected ? 'files-row selected' : 'files-row');
    const check = el('input', 'files-check');
    check.type = 'checkbox';
    check.checked = selected;
    check.setAttribute('aria-label', `Select ${entry.name}`);
    check.addEventListener('change', () => this.toggle(entry));
    const open = el('button', 'files-open');
    open.type = 'button';
    open.append(el('span', 'files-icon', entry.dir ? '📁' : entry.link ? '🔗' : '📄'));
    const text = el('span', 'files-text');
    text.append(el('span', 'files-name', entry.name));
    const meta = [entry.dir ? '' : formatSize(entry.size ?? NaN), formatDate(entry.mtime ?? NaN)].filter(Boolean).join(' · ');
    text.append(el('span', 'files-meta', withParent && entry.parent ? `${entry.parent}${meta ? ` · ${meta}` : ''}` : meta));
    open.append(text);
    if (entry.dir) open.append(el('span', 'menu-right', '›'));
    // A folder opens; a file (touch or mouse) toggles its selection like its checkbox.
    open.addEventListener('click', () => (entry.dir ? this.navigate(entry.path) : this.toggle(entry)));
    r.append(check, open);
    return r;
  }

  renderBar() {
    const items = [...this.selected.values()];
    this.bar.hidden = items.length === 0 && !this.barError;
    this.summary.textContent = this.barError || selectionSummary(items);
    this.downloadButton.disabled = items.length === 0 || this.downloadId != null;
    this.downloadButton.textContent = this.downloadId ? 'Preparing…' : 'Download';
  }
}

/// Navigates an <a download> to `url` (same origin, so the owner check of D32 applies).
export function startDownload(url, name) {
  const a = document.createElement('a');
  a.href = url;
  a.download = name || '';
  a.rel = 'noopener';
  a.style.display = 'none';
  document.body.append(a);
  a.click();
  a.remove();
}
