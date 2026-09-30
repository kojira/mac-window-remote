// The key panel above the bottom bar (DESIGN.md D34): special keys, one-shot modifiers,
// an fn layer with F1–F12, and a text key that opens the iOS keyboard. The normal layer's
// third row is one-tap ⌘F1 and ⌘W (D37, D48), space, ⏎, and ⋯, a menu with 📋 Paste and 🖼 Image
// (D36), 📎 File (D42), ⬇︎ Download (D47), and ⌘Q (D41).

import { mergeMods } from './modifiers.js';

const LONG_PRESS_MS = 500;
const REPEAT_DELAY_MS = 400;
const REPEAT_INTERVAL_MS = 66; // about 15 per second
const PRESSED_MIN_MS = 120;

// {label, key} sends a key (with `mods` added to the active modifiers, D37); {label, mod} is a
// modifier; fn and text are special.
const NORMAL = [
  { label: 'esc', key: 'Escape' }, { label: '⇧', mod: 'shift' }, { label: 'tab', key: 'Tab' },
  { label: 'fn', fn: true }, { label: '↑', key: 'ArrowUp', repeat: true }, { label: 'text', text: true },
  { label: '⌃', mod: 'ctrl' }, { label: '⌘', mod: 'cmd' }, { label: '⌥', mod: 'opt' },
  { label: '←', key: 'ArrowLeft', repeat: true }, { label: '↓', key: 'ArrowDown', repeat: true },
  { label: '→', key: 'ArrowRight', repeat: true },
  { label: '⌘F1', key: 'F1', mods: ['cmd'], combo: true }, { label: '⌘W', key: 'w', mods: ['cmd'], combo: true },
  { label: 'space', key: 'Space', repeat: true, wide: true }, { label: '⏎', key: 'Enter', repeat: true },
  { label: '⋯', more: true },
];
// The ⋯ menu (D41), top to bottom. ⌘Q is here, not in the row, so a stray tap cannot quit the app.
const MORE_MENU = [
  { label: '📋 Paste', action: 'paste' }, { label: '🖼 Image', action: 'image' },
  { label: '📎 File', action: 'file' }, { label: '⬇︎ Download', action: 'download' },
  { label: '⌘Q', key: 'q', mods: ['cmd'], combo: true },
];
const FN = [
  ...Array.from({ length: 12 }, (_, i) => ({ label: `F${i + 1}`, key: `F${i + 1}` })),
  { label: 'fn', fn: true }, { label: 'Home', key: 'Home' }, { label: 'End', key: 'End' },
  { label: 'PgUp', key: 'PageUp', repeat: true }, { label: 'PgDn', key: 'PageDown', repeat: true },
  { label: '⌦', key: 'Delete', repeat: true },
];

export class KeyPanel {
  /// sendKey(name, mods): send a `key` message. modifiers: a ModifierState.
  /// textInput: the TextInput (focus/blur of the iOS keyboard field).
  /// onLayout(change): runs change(), which opens, closes, or resizes the panel, and re-fits
  /// the stage around it. onAction('paste' | 'image' | 'file' | 'download') runs inside the tap (a user gesture),
  /// as the clipboard read and the file picker require (D36).
  constructor({ panel, toggle, viewerEl, modifiers, textInput, sendKey, onLayout, onAction }) {
    this.panel = panel;
    this.toggleButton = toggle;
    this.viewerEl = viewerEl;
    this.modifiers = modifiers;
    this.textInput = textInput;
    this.sendKey = sendKey;
    this.onLayout = onLayout;
    this.onAction = onAction;
    this.fnLayer = false;
    this.modButtons = [];
    this.textButton = null;
    this.repeatTimer = null;
    this.menu = null;
    this.moreButton = null;

    toggle.addEventListener('click', () => (this.isOpen() ? this.close() : this.open()));
    modifiers.onChange = () => this.renderModifiers();
    textInput.onFocusChange = (focused) => this.textButton?.classList.toggle('active', focused);
    // A held key must not keep repeating into a later connection.
    document.addEventListener('visibilitychange', () => { this.stopRepeat(); this.closeMenu(); });
    // A touch outside the ⋯ menu closes it and still goes where it was aimed (the trackpad
    // keeps working). Touches on ⋯ itself toggle the menu from its own handler.
    const outside = (e) => {
      if (this.menu && !this.menu.contains(e.target) && !this.moreButton?.contains(e.target)) this.closeMenu();
    };
    document.addEventListener('touchstart', outside, { capture: true, passive: true });
    document.addEventListener('mousedown', outside, true);
    this.render();
  }

  isOpen() { return !this.panel.hidden; }

  open() {
    this.toggleButton.classList.add('active');
    this.panel.hidden = false;
    this.layoutChanged();
  }

  /// Also hides the iOS keyboard and clears modifiers and the fn layer.
  close() {
    if (!this.isOpen()) return;
    this.stopRepeat();
    this.closeMenu();
    this.panel.hidden = true;
    this.toggleButton.classList.remove('active');
    this.textInput.blur();
    this.modifiers.reset();
    if (this.fnLayer) { this.fnLayer = false; this.render(); }
    this.layoutChanged();
  }

  layoutChanged() {
    this.onLayout(() => {
      this.viewerEl.classList.toggle('panel-open', this.isOpen());
      this.viewerEl.classList.toggle('fn-layer', this.isOpen() && this.fnLayer);
    });
  }

  render() {
    this.stopRepeat();
    this.closeMenu();
    this.panel.textContent = '';
    this.modButtons = [];
    this.textButton = null;
    this.moreButton = null;
    for (const spec of this.fnLayer ? FN : NORMAL) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'key';
      b.textContent = spec.label;
      if (spec.wide) b.classList.add('wide');
      if (spec.combo) b.classList.add('combo');
      if (spec.text) this.wireText(b);
      else if (spec.more) { b.classList.add('more'); this.moreButton = b; this.wireTap(b, () => this.toggleMenu()); }
      else this.wirePress(b, spec);
      if (spec.mod) { b.dataset.mod = spec.mod; this.modButtons.push(b); }
      if (spec.fn) b.classList.toggle('active', this.fnLayer);
      this.panel.append(b);
    }
    this.renderModifiers();
  }

  renderModifiers() {
    for (const b of this.modButtons) {
      const s = this.modifiers.get(b.dataset.mod);
      b.classList.toggle('active', s !== 'off');
      b.classList.toggle('locked', s === 'locked');
    }
  }

  /// The text key toggles the iOS keyboard. The touch never takes focus from the field, and
  /// focus() runs in touchend, a user gesture, so iOS shows the keyboard.
  wireText(b) {
    const toggle = () => {
      if (this.textInput.isFocused()) this.textInput.blur(); else this.textInput.focus();
    };
    b.addEventListener('touchstart', (e) => e.preventDefault(), { passive: false });
    b.addEventListener('touchend', (e) => { e.preventDefault(); toggle(); });
    b.addEventListener('mousedown', (e) => e.preventDefault());
    b.addEventListener('click', toggle); // no touch: mouse or keyboard
    b.classList.toggle('active', this.textInput.isFocused());
    this.textButton = b;
  }

  isMenuOpen() { return this.menu !== null; }

  /// The ⋯ menu (D41): a popover above the ⋯ key, inside the panel so it moves with it.
  toggleMenu() {
    if (this.menu) { this.closeMenu(); return; }
    const menu = document.createElement('div');
    menu.className = 'key-menu';
    for (const spec of MORE_MENU) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'key';
      b.textContent = spec.label;
      if (spec.combo) b.classList.add('combo');
      // The action runs before the menu closes, still inside the item's touchend.
      this.wireTap(b, () => {
        if (spec.action) this.onAction(spec.action); else this.press(spec);
        this.closeMenu();
      });
      menu.append(b);
    }
    this.menu = menu;
    this.moreButton?.classList.add('active');
    this.panel.append(menu);
  }

  closeMenu() {
    if (!this.menu) return;
    this.menu.remove();
    this.menu = null;
    this.moreButton?.classList.remove('active');
  }

  /// ⋯ and its menu items act on touchend (a user gesture, unlike a touch pointerdown, which
  /// the clipboard read and the file picker require, D36) and never take focus from the text
  /// field.
  wireTap(b, run) {
    let touched = false;
    b.addEventListener('touchstart', (e) => { e.preventDefault(); touched = true; b.classList.add('pressed'); }, { passive: false });
    b.addEventListener('touchend', (e) => {
      e.preventDefault();
      setTimeout(() => b.classList.remove('pressed'), PRESSED_MIN_MS);
      if (touched) run();
      touched = false;
    });
    b.addEventListener('touchcancel', () => { touched = false; b.classList.remove('pressed'); });
    b.addEventListener('mousedown', (e) => e.preventDefault());
    b.addEventListener('click', run); // no touch: mouse or keyboard
  }

  /// Other keys act on press and never take focus, so the iOS keyboard stays open.
  wirePress(b, spec) {
    let longTimer = null;
    let longPressed = false;
    let pressedAt = 0;
    b.addEventListener('touchstart', (e) => e.preventDefault(), { passive: false });
    b.addEventListener('mousedown', (e) => e.preventDefault());
    b.addEventListener('contextmenu', (e) => e.preventDefault());
    b.addEventListener('pointerdown', () => {
      pressedAt = performance.now();
      b.classList.add('pressed');
      if (spec.mod) {
        longPressed = false;
        longTimer = setTimeout(() => { longPressed = true; this.modifiers.lock(spec.mod); }, LONG_PRESS_MS);
      } else if (spec.fn) {
        this.fnLayer = !this.fnLayer;
        this.render();
        this.layoutChanged();
      } else {
        this.press(spec);
      }
    });
    const release = (e) => {
      const left = PRESSED_MIN_MS - (performance.now() - pressedAt);
      setTimeout(() => b.classList.remove('pressed'), Math.max(0, left));
      if (spec.mod) {
        clearTimeout(longTimer);
        if (e.type === 'pointerup' && !longPressed) this.modifiers.tap(spec.mod);
      } else {
        this.stopRepeat();
      }
    };
    b.addEventListener('pointerup', release);
    b.addEventListener('pointercancel', release);
  }

  /// Sends the key with the active modifiers plus its own (a combo key, D37); repeat keys
  /// repeat with the same modifiers.
  press(spec) {
    this.stopRepeat();
    const mods = mergeMods(this.modifiers.consume(), spec.mods ?? []);
    this.sendKey(spec.key, mods);
    if (!spec.repeat) return;
    this.repeatTimer = setTimeout(() => {
      this.repeatTimer = setInterval(() => this.sendKey(spec.key, mods), REPEAT_INTERVAL_MS);
    }, REPEAT_DELAY_MS);
  }

  stopRepeat() {
    // A timer id is either the delay timeout or the interval; clearing both is safe.
    clearTimeout(this.repeatTimer);
    clearInterval(this.repeatTimer);
    this.repeatTimer = null;
  }
}
