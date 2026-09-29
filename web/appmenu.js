// ☰: the viewed app's menu bar as a drill-down sheet (DESIGN.md D43). The Mac sends the tree
// with opaque ids; the phone only sends back an id and the listing's `gen`.

/// The `menu` message as {gen, windowId, truncated, menus}; null if malformed. Rows are
/// {sep: true} or {id, title, enabled, mark, shortcut, items}; malformed rows are dropped.
export function decodeMenu(msg) {
  if (!msg || !Number.isInteger(msg.gen) || !Number.isInteger(msg.windowId) || !Array.isArray(msg.menus)) return null;
  return { gen: msg.gen, windowId: msg.windowId, truncated: msg.truncated === true, menus: decodeRows(msg.menus, 0) };
}

const ID_RE = /^\d{1,4}(\.\d{1,4}){0,4}$/;

function decodeRows(rows, depth) {
  if (!Array.isArray(rows) || depth > 5) return [];
  const out = [];
  for (const r of rows) {
    if (!r || typeof r !== 'object') continue;
    if (r.sep === true) { out.push({ sep: true }); continue; }
    if (typeof r.id !== 'string' || !ID_RE.test(r.id) || typeof r.title !== 'string') continue;
    out.push({
      id: r.id,
      title: r.title,
      enabled: r.enabled !== false,
      mark: r.mark === 'check' || r.mark === 'mixed' ? r.mark : null,
      shortcut: typeof r.shortcut === 'string' ? r.shortcut : '',
      items: Array.isArray(r.items) ? decodeRows(r.items, depth + 1) : null,
    });
  }
  return out;
}

const MARKS = { check: '✓', mixed: '–' };

/// The full-height sheet: a header with ‹ (back), the title, and ✕, and one list level at a time.
export class MenuSheet {
  /// root: the backdrop element (hidden when closed); onPress(item, gen): run a leaf.
  constructor({ root, onPress }) {
    this.root = root;
    this.onPress = onPress;
    this.menu = null;
    this.stack = []; // the rows' parents from the root down
    this.appName = '';

    const sheet = document.createElement('div');
    sheet.className = 'menu-panel';
    const header = document.createElement('div');
    header.className = 'menu-header';
    this.back = document.createElement('button');
    this.back.type = 'button';
    this.back.className = 'menu-back';
    this.back.textContent = '‹';
    this.back.setAttribute('aria-label', 'Back');
    this.back.addEventListener('click', () => { this.stack.pop(); this.render(); });
    this.title = document.createElement('span');
    this.title.className = 'menu-title';
    const close = document.createElement('button');
    close.type = 'button';
    close.className = 'menu-close';
    close.textContent = '✕';
    close.setAttribute('aria-label', 'Close');
    close.addEventListener('click', () => this.close());
    header.append(this.back, this.title, close);
    this.list = document.createElement('div');
    this.list.className = 'menu-list';
    sheet.append(header, this.list);
    root.append(sheet);
    this.panel = sheet;
    // A tap on the backdrop, outside the panel, closes the sheet.
    root.addEventListener('click', (e) => { if (e.target === root) this.close(); });
  }

  get isOpen() { return !this.root.hidden; }

  /// Opens in the loading state for the viewed app.
  open(appName) {
    this.appName = appName || 'Menu';
    this.menu = null;
    this.stack = [];
    this.message = 'Loading…';
    this.root.hidden = false;
    this.render();
  }

  close() {
    this.root.hidden = true;
    this.menu = null;
    this.stack = [];
    this.list.textContent = '';
  }

  /// A decoded `menu` for the open sheet.
  setMenu(menu) {
    if (!this.isOpen) return;
    this.menu = menu;
    this.stack = [];
    this.message = menu.menus.length === 0 ? 'This app has no menus' : '';
    this.render();
  }

  showError(text) {
    if (!this.isOpen) return;
    this.menu = null;
    this.stack = [];
    this.message = text;
    this.render();
  }

  render() {
    const parent = this.stack[this.stack.length - 1];
    this.back.hidden = !parent;
    this.title.textContent = parent ? parent.title : this.appName;
    this.list.textContent = '';
    if (!this.menu) {
      const p = document.createElement('p');
      p.className = 'menu-message';
      p.textContent = this.message;
      this.list.append(p);
      return;
    }
    const rows = parent ? parent.items : this.menu.menus;
    if (rows.length === 0) {
      const p = document.createElement('p');
      p.className = 'menu-message';
      p.textContent = 'Empty (this menu fills in only when opened on the Mac)';
      this.list.append(p);
    }
    for (const r of rows) this.list.append(r.sep ? this.separator() : this.row(r));
    if (!parent && this.menu.truncated) {
      const p = document.createElement('p');
      p.className = 'menu-message';
      p.textContent = 'Some items are not shown';
      this.list.append(p);
    }
  }

  separator() {
    const d = document.createElement('div');
    d.className = 'menu-sep';
    return d;
  }

  row(item) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = item.enabled ? 'menu-row' : 'menu-row disabled';
    b.disabled = !item.enabled;
    const mark = document.createElement('span');
    mark.className = 'menu-mark';
    mark.textContent = item.mark ? MARKS[item.mark] : '';
    const title = document.createElement('span');
    title.className = 'menu-item-title';
    title.textContent = item.title;
    const right = document.createElement('span');
    right.className = 'menu-right';
    right.textContent = item.items ? '›' : item.shortcut;
    b.append(mark, title, right);
    b.addEventListener('click', () => {
      if (!item.enabled) return;
      if (item.items) {
        this.stack.push(item);
        this.render();
        return;
      }
      const gen = this.menu.gen;
      this.close();
      this.onPress(item, gen);
    });
    return b;
  }
}
