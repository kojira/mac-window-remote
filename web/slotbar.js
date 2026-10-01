// Quick-switch slot buttons in the viewer's bottom bar and their long-press menu (DESIGN.md D33).
import { SLOT_COUNT, SLOTS_KEY, parseSlots, resolveSlot, decodeThumb } from './slots.js';
import { isDisplay, sameTarget } from './displays.js';

const LONG_PRESS_MS = 500;

export class SlotBar {
  /// current(): the viewed window {id, app, title} or display (D56), or null.
  /// onSwitch(target): view another window or display.
  /// onChange(): slots were assigned or cleared (request thumbnails now).
  constructor({ container, menu, current, onSwitch, onChange }) {
    this.menu = menu;
    this.current = current;
    this.onSwitch = onSwitch;
    this.onChange = onChange;
    this.slots = parseSlots(localStorage.getItem(SLOTS_KEY));
    this.windows = null; // the latest window list; null until the first one arrives
    this.displays = null; // the latest display list (D56); null until the first one arrives
    this.thumbs = new Map(); // windowId → data URL, in memory only
    this.displayThumbs = new Map(); // displayId → data URL from the display list (D56)
    this.menuIndex = null;
    this.buttons = [];
    for (let i = 0; i < SLOT_COUNT; i++) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'slot';
      this.wirePress(b, i);
      container.append(b);
      this.buttons.push(b);
    }
    menu.addEventListener('click', (e) => {
      const act = e.target.dataset && e.target.dataset.act;
      // The lift that ends a long-press can land on the menu's backdrop; it must not close it.
      if (!act && performance.now() - this.menuOpenedAt < LONG_PRESS_MS) return;
      const i = this.menuIndex;
      this.closeMenu();
      if (act === 'assign') this.assignCurrent(i);
      else if (act === 'clear') this.set(i, null);
    });
    this.render();
  }

  /// Tap acts on the slot; holding it opens the menu instead.
  wirePress(button, i) {
    let timer = null;
    let longPressed = false;
    const cancel = () => clearTimeout(timer);
    button.addEventListener('pointerdown', () => {
      longPressed = false;
      cancel();
      timer = setTimeout(() => { longPressed = true; this.openMenu(i); }, LONG_PRESS_MS);
    });
    button.addEventListener('pointerup', cancel);
    button.addEventListener('pointercancel', cancel);
    button.addEventListener('pointerleave', cancel);
    button.addEventListener('contextmenu', (e) => e.preventDefault());
    button.addEventListener('click', () => {
      if (longPressed) { longPressed = false; return; }
      this.tap(i);
    });
  }

  tap(i) {
    const r = this.resolve(this.slots[i]);
    if (r.state === 'empty') this.assignCurrent(i);
    else if (r.state === 'unavailable') this.openMenu(i);
    else if (!sameTarget(r.window, this.current())) this.onSwitch(r.window);
  }

  resolve(slot) {
    return resolveSlot(slot, this.windows, this.displays);
  }

  assignCurrent(i) {
    const w = this.current();
    if (!w) return;
    const slot = { windowId: w.id, app: w.app, title: w.title };
    if (isDisplay(w)) slot.display = true;
    this.set(i, slot);
  }

  set(i, slot) {
    this.slots[i] = slot;
    this.save();
    this.render();
    this.onChange();
  }

  save() {
    localStorage.setItem(SLOTS_KEY, JSON.stringify(this.slots));
  }

  /// A new window list: re-resolve, and remember each found window's current id and title.
  setWindows(windows) {
    this.windows = windows;
    let changed = false;
    this.slots = this.slots.map((s) => {
      if (s?.display === true) return s;
      const r = resolveSlot(s, windows);
      if (r.state !== 'window' || (r.window.id === s.windowId && r.window.title === s.title)) return s;
      changed = true;
      return { windowId: r.window.id, app: r.window.app, title: r.window.title };
    });
    if (changed) this.save();
    this.render();
  }

  /// A new display list (D56): re-resolve display slots and keep their thumbnails.
  setDisplays(displays) {
    this.displays = displays;
    this.displayThumbs = new Map(displays.filter((d) => d.src).map((d) => [d.id, d.src]));
    let changed = false;
    this.slots = this.slots.map((s) => {
      if (s?.display !== true) return s;
      const r = resolveSlot(s, null, displays);
      if (r.state !== 'window' || (r.window.id === s.windowId && r.window.title === s.title)) return s;
      changed = true;
      return { windowId: r.window.id, app: s.app, title: r.window.title, display: true };
    });
    if (changed) this.save();
    this.render();
  }

  hasDisplaySlot() {
    return this.slots.some((s) => s?.display === true);
  }

  /// Window ids of the slots that resolve to a window, for `thumbs.request`.
  windowIds() {
    const ids = [];
    for (const s of this.slots) {
      if (s?.display === true) continue;
      const r = resolveSlot(s, this.windows);
      if (r.state === 'window' && !ids.includes(r.window.id)) ids.push(r.window.id);
    }
    return ids;
  }

  onThumb(msg) {
    const t = decodeThumb(msg);
    if (!t) return;
    if (t.src) this.thumbs.set(t.windowId, t.src); else this.thumbs.delete(t.windowId);
    this.render();
  }

  render() {
    const current = this.current();
    this.slots.forEach((s, i) => {
      const b = this.buttons[i];
      const r = this.resolve(s);
      b.textContent = '';
      b.classList.toggle('empty', r.state === 'empty');
      b.classList.toggle('unavailable', r.state === 'unavailable');
      b.classList.toggle('current', r.state === 'window' && sameTarget(r.window, current));
      if (r.state === 'empty') {
        b.textContent = '+';
        b.setAttribute('aria-label', 'Empty slot: assign the current window');
        return;
      }
      b.setAttribute('aria-label', `${s.app} — ${s.title || '(untitled)'}`);
      const src = r.state === 'window' && (isDisplay(r.window) ? this.displayThumbs : this.thumbs).get(r.window.id);
      if (src) {
        const img = document.createElement('img');
        img.src = src;
        img.alt = '';
        b.append(img);
      } else {
        const label = document.createElement('span');
        label.textContent = s.app;
        b.append(label);
      }
    });
  }

  openMenu(i) {
    this.menuIndex = i;
    this.menuOpenedAt = performance.now();
    this.menu.hidden = false;
  }

  closeMenu() {
    this.menuIndex = null;
    this.menu.hidden = true;
  }
}
