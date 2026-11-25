// The Terminal text view (DESIGN.md D67): 📄 shows the viewed Terminal.app window's text, read
// on the Mac through Accessibility, as selectable, wrapped text over the stage. The layer is a
// sibling of the stage, so the stage's touch and mouse handlers never see its events: taps do
// not click on the Mac, and long-press selection, the copy menu and scrolling stay native.
import { copyWithTextarea } from './macclip.js';

export const TERM_FONT_KEY = 'mwr.termFont';
export const TERM_SIZE_KEY = 'mwr.termSize';
export const MIN_SIZE = 10;
export const MAX_SIZE = 28;
export const DEFAULT_SIZE = 13;
/// Within this many px of the end counts as "at the bottom" for auto-scroll.
export const BOTTOM_SLACK = 40;

/// The font choices: id (stored), label, CSS font-family.
export const TERM_FONTS = [
  { id: 'menlo', label: 'Menlo', css: 'Menlo, monospace' },
  { id: 'sf', label: 'SF Mono', css: 'ui-monospace, "SF Mono", SFMono-Regular, monospace' },
  { id: 'courier', label: 'Courier', css: 'Courier, "Courier New", monospace' },
  { id: 'mono', label: 'Monospace', css: 'monospace' },
];

/// A stored font id, or the default (Menlo) for anything else.
export function parseTermFont(value) {
  return TERM_FONTS.some((f) => f.id === value) ? value : TERM_FONTS[0].id;
}

export function fontCss(id) {
  return (TERM_FONTS.find((f) => f.id === id) ?? TERM_FONTS[0]).css;
}

/// A font size in px, an integer clamped to 10–28; the default for anything unreadable.
export function clampTermSize(value) {
  const n = typeof value === 'number' ? value : Number.parseInt(value, 10);
  if (!Number.isFinite(n)) return DEFAULT_SIZE;
  return Math.min(MAX_SIZE, Math.max(MIN_SIZE, Math.round(n)));
}

/// The element is scrolled to within `slack` px of its end.
export function isAtBottom(el, slack = BOTTOM_SLACK) {
  return el.scrollHeight - el.scrollTop - el.clientHeight <= slack;
}

/// ⌘C or Ctrl+C (no ⌥), the copy shortcut of a desktop browser.
export function isCopyShortcut(e) {
  return !!e && (e.metaKey || e.ctrlKey) && !e.altKey && e.code === 'KeyC';
}

/// The page's text for a `term.error` code.
export function termErrorText(code) {
  switch (code) {
    case 'not_terminal': return 'Text view is only available for Terminal windows.';
    case 'ax_denied': return 'Mac needs Accessibility permission to read the Terminal text.';
    case 'no_text': return 'This Terminal window has no readable text.';
    default: return 'The Terminal text can\u2019t be read.';
  }
}

const el = (tag, className, text) => {
  const e = document.createElement(tag);
  if (className) e.className = className;
  if (text != null) e.textContent = text;
  return e;
};

const button = (className, text, label) => {
  const b = el('button', className, text);
  b.type = 'button';
  if (label) { b.setAttribute('aria-label', label); b.title = label; }
  return b;
};

/// The text layer in `root` (hidden when closed). send(msg): the WebSocket. onExit(): back to
/// the video (the error's button). getSelection(): the document's selection, or null.
export class TerminalView {
  constructor({ root, send, toast, onExit, storage = globalThis.localStorage, clipboard = null,
    getSelection = () => globalThis.getSelection?.() ?? null, fallbackCopy = copyWithTextarea }) {
    this.root = root;
    this.send = send;
    this.toast = toast;
    this.onExit = onExit;
    this.storage = storage;
    this.clipboard = clipboard;
    this.getSelection = getSelection;
    this.fallbackCopy = fallbackCopy;
    this.windowId = null;
    this.rev = 0;
    this.text = '';
    this.pending = null; // newer text held while the user has a selection in the layer

    const bar = el('div', 'term-toolbar');
    this.fontSelect = el('select', 'term-font');
    this.fontSelect.setAttribute('aria-label', 'Font');
    for (const f of TERM_FONTS) {
      const o = el('option', null, f.label);
      o.value = f.id;
      this.fontSelect.append(o);
    }
    this.fontSelect.addEventListener('change', () => this.setFont(this.fontSelect.value));
    this.smaller = button('term-smaller', 'A\u2212', 'Smaller text');
    this.smaller.addEventListener('click', () => this.setSize(this.size - 1));
    this.larger = button('term-larger', 'A+', 'Larger text');
    this.larger.addEventListener('click', () => this.setSize(this.size + 1));
    this.copyButton = button('term-copy', 'Copy all');
    this.copyButton.addEventListener('click', () => this.copyAll());
    this.bottomButton = button('term-bottom', '\u21e3', 'Jump to the bottom');
    this.bottomButton.addEventListener('click', () => this.scrollToBottom());
    bar.append(this.fontSelect, this.smaller, this.larger, this.copyButton, this.bottomButton);

    this.pre = el('pre', 'term-text');
    this.pre.addEventListener('scroll', () => { if (isAtBottom(this.pre)) this.newOutput.hidden = true; });

    this.newOutput = button('term-new', '\u21e3 New output');
    this.newOutput.hidden = true;
    this.newOutput.addEventListener('click', () => this.scrollToBottom());

    this.errorBox = el('div', 'term-error');
    this.errorBox.hidden = true;
    this.errorText = el('p');
    const back = button('term-back', 'Back to video');
    back.addEventListener('click', () => this.onExit());
    this.errorBox.append(this.errorText, back);

    root.append(bar, this.pre, this.newOutput, this.errorBox);
    root.hidden = true;

    this.font = parseTermFont(storage?.getItem(TERM_FONT_KEY));
    this.size = clampTermSize(storage?.getItem(TERM_SIZE_KEY));
    this.applyFont();
  }

  isOpen() { return this.windowId !== null; }

  /// Shows the layer for `windowId` and asks the Mac for its text.
  open(windowId) {
    this.windowId = windowId;
    this.rev = 0;
    this.text = '';
    this.pending = null;
    this.pre.textContent = 'Loading\u2026';
    this.newOutput.hidden = true;
    this.errorBox.hidden = true;
    this.pre.hidden = false;
    this.root.hidden = false;
    if (!this.send({ t: 'term.start', windowId })) this.showError('Not connected to the Mac');
  }

  /// The view restarted on the Mac (a reconnect): ask again for the open window's text.
  restart() {
    if (!this.isOpen()) return;
    this.rev = 0; // a new session on the Mac counts from 1 again
    this.send({ t: 'term.start', windowId: this.windowId });
  }

  /// Hides the layer and stops the Mac's reads. The video and its zoom are untouched.
  close() {
    if (!this.isOpen()) return;
    this.windowId = null;
    this.pending = null;
    this.root.hidden = true;
    this.send({ t: 'term.stop' });
  }

  /// A `term.text` message. A newer text replaces the shown one, keeping the scroll position
  /// unless the user was at the bottom; while text is selected in the layer it waits.
  onText(msg) {
    if (!this.isOpen() || msg?.windowId !== this.windowId || typeof msg.text !== 'string') return;
    if (!Number.isInteger(msg.rev) || msg.rev <= this.rev) return;
    this.rev = msg.rev;
    this.errorBox.hidden = true;
    this.pre.hidden = false;
    if (this.hasSelection()) {
      this.pending = msg.text;
      this.newOutput.hidden = false;
      return;
    }
    this.show(msg.text);
  }

  /// The selection changed: held text is shown once nothing is selected in the layer.
  onSelectionChange() {
    if (this.pending !== null && !this.hasSelection()) {
      const text = this.pending;
      this.pending = null;
      this.show(text);
    }
  }

  show(text) {
    // The first text of an open starts at the bottom, like the terminal.
    const atBottom = this.text === '' || isAtBottom(this.pre);
    this.text = text;
    this.pre.textContent = text;
    if (atBottom) this.scrollToBottom();
    else this.newOutput.hidden = false;
  }

  /// A `term.error` for the open window.
  onError(msg) {
    if (!this.isOpen() || (msg?.windowId != null && msg.windowId !== this.windowId)) return;
    this.showError(termErrorText(msg?.code));
  }

  showError(text) {
    this.errorText.textContent = text;
    this.errorBox.hidden = false;
    this.pre.hidden = true;
    this.newOutput.hidden = true;
  }

  scrollToBottom() {
    this.pre.scrollTop = this.pre.scrollHeight;
    this.newOutput.hidden = true;
  }

  /// Text is selected inside the layer's text (a desktop ⌘C then copies it here, D67).
  hasSelection() {
    const s = this.getSelection();
    if (!s || s.isCollapsed || !s.rangeCount) return false;
    const node = s.anchorNode;
    return !!node && (node === this.pre || this.pre.contains?.(node) === true);
  }

  setFont(id) {
    this.font = parseTermFont(id);
    this.storage?.setItem(TERM_FONT_KEY, this.font);
    this.applyFont();
  }

  setSize(px) {
    this.size = clampTermSize(px);
    this.storage?.setItem(TERM_SIZE_KEY, String(this.size));
    this.applyFont();
  }

  applyFont() {
    this.fontSelect.value = this.font;
    this.pre.style.fontFamily = fontCss(this.font);
    this.pre.style.fontSize = `${this.size}px`;
    this.smaller.disabled = this.size <= MIN_SIZE;
    this.larger.disabled = this.size >= MAX_SIZE;
  }

  /// Copies the whole text inside the tap (iOS needs the user gesture).
  copyAll() {
    const text = this.pending ?? this.text;
    if (!text) { this.toast('Nothing to copy yet'); return Promise.resolve(); }
    const done = () => this.toast('Copied');
    const fallback = () => { if (this.fallbackCopy(text)) done(); else this.toast('Could not copy on this device'); };
    if (!this.clipboard?.writeText) { fallback(); return Promise.resolve(); }
    let attempt;
    try { attempt = Promise.resolve(this.clipboard.writeText(text)); } catch (e) { attempt = Promise.reject(e); }
    return attempt.then(done, fallback);
  }
}
