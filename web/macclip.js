// Text copied on the Mac reaches this device's clipboard (DESIGN.md D51). The Mac sends
// `{t:'clipboard.mac', seq, text | truncated}`; a desktop browser with focus takes it at once,
// otherwise (iOS Safari needs a tap, or the page is not focused) a banner offers the copy.

export const PREVIEW_CHARS = 40;

/// The banner's quoted preview: the first 40 characters on one line, with … when cut.
export function previewText(text) {
  const oneLine = text.replace(/\s+/g, ' ').trim();
  const chars = [...oneLine];
  return chars.length > PREVIEW_CHARS ? `${chars.slice(0, PREVIEW_CHARS).join('')}…` : oneLine;
}

/// Copies with a selected textarea and execCommand('copy'); must run inside a user gesture.
export function copyWithTextarea(text, doc = document) {
  const area = doc.createElement('textarea');
  area.value = text;
  area.setAttribute('readonly', '');
  area.style.position = 'fixed';
  area.style.top = '0';
  area.style.left = '0';
  area.style.opacity = '0';
  doc.body.append(area);
  area.select();
  area.setSelectionRange?.(0, text.length);
  let ok = false;
  try { ok = doc.execCommand('copy'); } catch { ok = false; }
  area.remove();
  return ok;
}

/// The banner above the bottom bar: `root` holds `label` (tap to copy) and `close` (✕).
/// clipboard: navigator.clipboard or null. fallbackCopy(text) → bool runs in the tap.
export class MacClipboard {
  constructor({ root, label, close, clipboard, toast, fallbackCopy = copyWithTextarea }) {
    this.root = root;
    this.label = label;
    this.clipboard = clipboard;
    this.toast = toast;
    this.fallbackCopy = fallbackCopy;
    this.pending = null; // the text the banner offers
    this.latest = 0; // the newest message; an older copy's late result does not touch the banner
    label.addEventListener('click', () => this.copyPending());
    close.addEventListener('click', () => this.hide());
  }

  /// A `clipboard.mac` message: try to copy now; if the browser refuses, show the banner.
  onMessage(msg) {
    const n = ++this.latest;
    if (msg.truncated || typeof msg.text !== 'string') {
      this.hide();
      this.toast('📋 Copied on the Mac, but too large to send (max 1 MiB)');
      return Promise.resolve();
    }
    const text = msg.text;
    if (!this.clipboard?.writeText) { this.show(text); return Promise.resolve(); }
    let attempt;
    try { attempt = Promise.resolve(this.clipboard.writeText(text)); } catch (e) { attempt = Promise.reject(e); }
    return attempt.then(() => {
      if (n !== this.latest) return;
      this.hide();
      this.toast('📋 Copied from the Mac');
    }, () => {
      if (n === this.latest) this.show(text);
    });
  }

  show(text) {
    this.pending = text;
    this.label.textContent = `📋 Copied on the Mac: “${previewText(text)}” — Tap to copy here`;
    this.root.hidden = false;
  }

  hide() {
    this.pending = null;
    this.root.hidden = true;
  }

  /// The tap on the banner: a user gesture, which iOS requires for writing the clipboard.
  copyPending() {
    const text = this.pending;
    if (text == null) return Promise.resolve();
    const n = this.latest;
    const done = () => { if (n === this.latest && this.pending === text) this.hide(); this.toast('Copied'); };
    const fallback = () => {
      if (this.fallbackCopy(text)) done();
      else this.toast('Could not copy on this device');
    };
    if (!this.clipboard?.writeText) { fallback(); return Promise.resolve(); }
    let attempt;
    try { attempt = Promise.resolve(this.clipboard.writeText(text)); } catch (e) { attempt = Promise.reject(e); }
    return attempt.then(done, fallback);
  }
}
