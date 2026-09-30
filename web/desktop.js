// Desktop (PC) browser input: mouse and physical keyboard (DESIGN.md D45). The pure functions
// translate DOM events into protocol messages; DesktopKeyboard wires keys and IME to the
// hidden `#key-sink` textarea. The iPhone never takes these paths.

/// KeyboardEvent.code → §4.3 key name. Letters, digits, and punctuation are key positions
/// (US layout), so shortcuts such as ⌘Z work on any layout.
const CODE_KEYS = {
  Enter: 'Enter', NumpadEnter: 'Enter', Tab: 'Tab', Escape: 'Escape', Backspace: 'Backspace',
  Delete: 'Delete', Space: 'Space',
  ArrowLeft: 'ArrowLeft', ArrowRight: 'ArrowRight', ArrowUp: 'ArrowUp', ArrowDown: 'ArrowDown',
  Home: 'Home', End: 'End', PageUp: 'PageUp', PageDown: 'PageDown',
  Minus: '-', Equal: '=', BracketLeft: '[', BracketRight: ']', Backslash: '\\',
  Semicolon: ';', Quote: "'", Comma: ',', Period: '.', Slash: '/', Backquote: '`',
  NumpadDecimal: '.', NumpadSubtract: '-', NumpadDivide: '/', NumpadEqual: '=',
};

export function keyNameForCode(code) {
  if (typeof code !== 'string') return null;
  if (Object.hasOwn(CODE_KEYS, code)) return CODE_KEYS[code];
  let m = /^Key([A-Z])$/.exec(code);
  if (m) return m[1].toLowerCase();
  m = /^(?:Digit|Numpad)([0-9])$/.exec(code);
  if (m) return m[1];
  m = /^F([1-9]|1[0-2])$/.exec(code);
  if (m) return code;
  return null;
}

/// The event's modifiers as wire names, in cmd, ctrl, opt, shift order.
export function modsOf(e) {
  const mods = [];
  if (e.metaKey) mods.push('cmd');
  if (e.ctrlKey) mods.push('ctrl');
  if (e.altKey) mods.push('opt');
  if (e.shiftKey) mods.push('shift');
  return mods;
}

/// One printable character (not a control character), as `key` reports typed text.
const isPrintable = (key) => typeof key === 'string' && [...key].length === 1 && !/^[\u0000-\u001f\u007f]$/.test(key);

/// What a keydown sends: `{t:'text', text}` for a printable character with no modifier but
/// shift (or with AltGr), which respects the keyboard layout; `{t:'key', key, mods}` for
/// everything else we map by position; null for keys that are not forwarded (modifier keys
/// alone, IME composition, unmapped keys).
export function keyMessage(e) {
  // An IME or a dead key composes in the key sink; its result arrives as compositionend.
  if (e.isComposing || e.keyCode === 229 || e.key === 'Dead') return null;
  const altGraph = typeof e.getModifierState === 'function' && e.getModifierState('AltGraph');
  const plain = !e.metaKey && ((!e.ctrlKey && !e.altKey) || altGraph);
  if (plain && isPrintable(e.key)) return { t: 'text', text: e.key };
  const key = keyNameForCode(e.code);
  if (!key) return null;
  return { t: 'key', key, mods: modsOf(e) };
}

/// MouseEvent.button → the Mac button; back/forward buttons are not forwarded.
export function mouseButtonName(button) {
  return { 0: 'left', 1: 'middle', 2: 'right' }[button] ?? null;
}

/// The browser's click count (`detail`) as the Mac's click state: 1 to 3.
export function clickCount(detail) {
  return Number.isInteger(detail) && detail > 1 ? Math.min(detail, 3) : 1;
}

export const WHEEL_LINE_PX = 16;

/// Wheel deltas in CSS px, in the direction the content moves (the trackpad's scroll sign,
/// D26): scrolling down moves content up. `pageHeight` converts page-mode deltas.
export function wheelPixels(e, pageHeight) {
  const unit = e.deltaMode === 1 ? WHEEL_LINE_PX : e.deltaMode === 2 ? pageHeight : 1;
  return { dx: -(e.deltaX || 0) * unit, dy: -(e.deltaY || 0) * unit };
}

/// A point in stage CSS px → window-normalized (u, v), or null outside the video unless
/// `clamp` (a drag keeps going at the edge).
/// Ctrl+wheel (a trackpad pinch, or Ctrl + mouse wheel) → a zoom factor (D49). Wheel-up
/// (negative deltaY) zooms in. Line and page deltas are scaled to pixels first.
export function pinchFactor(e) {
  const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1;
  const dy = Math.max(-100, Math.min(100, e.deltaY * unit));
  return Math.exp(-dy * 0.01);
}

export function stageToWindow(x, y, { tx, ty, scale, width, height }, clamp) {
  const u = (x - tx) / (width * scale);
  const v = (y - ty) / (height * scale);
  const inside = u >= 0 && u <= 1 && v >= 0 && v <= 1;
  if (!inside && !clamp) return null;
  return { u: Math.min(Math.max(u, 0), 1), v: Math.min(Math.max(v, 0), 1) };
}

/// Physical keys for the viewed window (D45). Keys arrive on `sink`, a hidden textarea that
/// holds focus while the viewer is active on a desktop, so an IME can compose into it.
/// isActive(): the viewer is shown with no sheet or text field in use. send(msg): control.
export class DesktopKeyboard {
  constructor({ sink, isActive, send }) {
    this.sink = sink;
    this.isActive = isActive;
    this.send = send;
    this.composing = false;
    this.forwarded = new Set(); // codes whose keydown was forwarded, so their keyup is eaten too
    if (!sink) return;
    window.addEventListener('keydown', (e) => this.onKeyDown(e));
    window.addEventListener('keyup', (e) => this.onKeyUp(e));
    sink.addEventListener('compositionstart', () => this.onCompositionStart());
    sink.addEventListener('compositionend', (e) => this.onCompositionEnd(e));
    // Text inserted without a forwarded keydown (the emoji picker, dictation) is sent as
    // text. Composition input is left to compositionend, so a commit is never sent twice.
    sink.addEventListener('input', (e) => {
      if (this.composing || e.isComposing) return;
      if (/Composition/.test(e.inputType ?? '')) { sink.value = ''; return; }
      const text = sink.value;
      sink.value = '';
      if (text && this.isActive()) this.send({ t: 'text', text });
    });
  }

  /// Keys go to the Mac unless another text field has focus.
  focusedHere() {
    if (typeof document === 'undefined') return true;
    const a = document.activeElement;
    if (!a || a === this.sink) return true;
    return !(a.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(a.tagName));
  }

  onKeyDown(e) {
    if (this.composing || !this.isActive() || !this.focusedHere()) return;
    const msg = keyMessage(e);
    if (!msg) return;
    e.preventDefault();
    this.forwarded.add(e.code);
    this.send(msg);
  }

  onKeyUp(e) {
    if (this.forwarded.delete(e.code)) e.preventDefault();
  }

  onCompositionStart() {
    this.composing = true;
    this.sink?.classList.add('composing');
  }

  /// The committed text goes to the Mac through the text path; the sink is emptied.
  onCompositionEnd(e) {
    this.composing = false;
    this.sink?.classList.remove('composing');
    if (this.sink) this.sink.value = '';
    if (e.data && this.isActive()) this.send({ t: 'text', text: e.data });
  }

  focus() {
    if (this.sink && document.activeElement !== this.sink) this.sink.focus({ preventScroll: true });
  }

  blur() {
    if (this.sink && document.activeElement === this.sink) this.sink.blur();
  }
}
