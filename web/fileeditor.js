// D62: a plain-text editor over the ⬇︎⬆︎ Files sheet. `files.read` loads a UTF-8 text file of
// at most 1 MiB; Save sends `files.write` as a binary message (header + raw UTF-8, so 1 MiB of
// text fits the WebSocket frame) with the base mtime/size the Mac checks for a conflict. The
// page always edits with "\n"; the Mac restores the file's line endings and BOM.
import { CLIPBOARD_MAX_BYTES, encodeBinaryMessage } from './upload.js';

/// The same 1 MiB as clipboard text (D36) and the Mac's FileEdit.maxTextBytes.
export const EDIT_MAX_BYTES = CLIPBOARD_MAX_BYTES;

/// D62: the texts for a failed `files.create`, `files.read`, or `files.write`.
export const EDIT_ERROR_TEXT = {
  too_large: 'Too large to edit (over 1 MB)',
  not_text: "Can't edit this file (not text)",
  not_writable: "Can't save here",
  not_found: 'It no longer exists',
  exists: 'That name is already used',
  invalid_name: 'Invalid name',
  bad_request: 'Invalid name',
  no_access: 'No access',
  disk_full: "The Mac's disk is full",
};

export const editErrorText = (msg) => EDIT_ERROR_TEXT[msg.code] ?? msg.message ?? msg.code;

/// The bytes the Mac would write for `text` with `eol` (BOM aside): "\n" becomes "\r\n" for CRLF.
export function savedByteLength(text, eol) {
  const bytes = new TextEncoder().encode(text).length;
  return eol === 'crlf' ? bytes + (text.match(/\n/g)?.length ?? 0) : bytes;
}

/// The `files.write` binary message.
export function fileWriteMessage({ id, path, text, baseMtime, baseSize, eol, force }) {
  const header = { t: 'files.write', id, path, baseMtime, baseSize, eol };
  if (force) header.force = true;
  return encodeBinaryMessage(header, new TextEncoder().encode(text));
}

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

export class FileEditor {
  /// parent: the Files sheet's panel. send(msg) / sendBinary(bytes): false if not connected.
  /// nextId(): a request id. toast(text). confirm(text) → boolean. onClosed(saved): the editor
  /// closed; `saved` if the file was saved at least once (the listing is stale).
  constructor({ parent, send, sendBinary, nextId, toast, confirm, viewport = globalThis.window?.visualViewport }) {
    this.send = send;
    this.sendBinary = sendBinary;
    this.nextId = nextId;
    this.toast = toast;
    this.confirm = confirm;
    this.onClosed = () => {};
    this.path = null;
    this.name = '';
    this.base = null;      // {mtime, size, eol} of the file as last read or saved
    this.savedText = '';   // the text the file has on the Mac
    this.readId = null;
    this.writeId = null;
    this.saved = false;

    this.root = el('div', 'files-editor');
    this.root.hidden = true;
    this.root.setAttribute('role', 'dialog');
    const header = el('div', 'files-editor-header');
    this.closeButton = button('files-editor-close', 'Close', () => this.requestClose());
    this.title = el('span', 'files-editor-title');
    this.marker = el('span', 'files-editor-dirty', '');
    this.marker.setAttribute('aria-label', 'Unsaved changes');
    const titleRow = el('span', 'files-editor-name');
    titleRow.append(this.title, this.marker);
    this.saveButton = button('files-editor-save primary', 'Save', () => this.save());
    header.append(this.closeButton, titleRow, this.saveButton);
    this.text = el('textarea', 'files-editor-text');
    for (const [k, v] of [['autocapitalize', 'off'], ['autocorrect', 'off'], ['autocomplete', 'off'], ['aria-label', 'File text']]) {
      this.text.setAttribute(k, v);
    }
    this.text.spellcheck = false;
    this.text.addEventListener('input', () => this.renderState());
    this.message = el('p', 'files-editor-message');
    this.root.append(header, this.text, this.message);
    // ⌘S / Ctrl+S saves and Esc closes, wherever the focus is in the editor.
    this.root.addEventListener('keydown', (e) => {
      if (e.isComposing) return;
      if ((e.metaKey || e.ctrlKey) && !e.altKey && (e.key === 's' || e.key === 'S')) {
        e.preventDefault?.();
        this.save();
      } else if (e.key === 'Escape') {
        e.preventDefault?.();
        this.requestClose();
      }
    });
    parent.append(this.root);

    // iOS: the keyboard shrinks the visual viewport, not the layout; the editor follows it so
    // the line being typed is not hidden (as the bottom bar does, D10).
    this.viewport = viewport;
    if (viewport) {
      const fit = () => this.fitViewport();
      viewport.addEventListener('resize', fit);
      viewport.addEventListener('scroll', fit);
    }
  }

  get isOpen() { return !this.root.hidden; }
  get dirty() { return this.base != null && this.text.value !== this.savedText; }

  fitViewport() {
    if (!this.viewport || !this.isOpen) return;
    this.root.style.top = `${this.viewport.offsetTop}px`;
    this.root.style.height = `${this.viewport.height}px`;
  }

  /// Opens the editor on `path` and asks the Mac for its text.
  open(path, name) {
    this.path = path;
    this.name = name;
    this.base = null;
    this.savedText = '';
    this.saved = false;
    this.writeId = null;
    this.text.value = '';
    this.root.hidden = false;
    this.fitViewport();
    this.readId = this.nextId();
    if (!this.send({ t: 'files.read', id: this.readId, path })) {
      this.readId = null;
      this.message.textContent = 'Not connected to the Mac';
    } else {
      this.message.textContent = 'Loading…';
    }
    this.renderState();
  }

  /// A `files.read.result`; true if it was for this editor.
  onRead(msg) {
    if (!msg || msg.id !== this.readId || typeof msg.text !== 'string') return false;
    this.readId = null;
    this.base = { mtime: msg.mtime, size: msg.size, eol: msg.eol === 'crlf' ? 'crlf' : 'lf' };
    this.savedText = msg.text;
    this.text.value = msg.text;
    this.message.textContent = '';
    this.renderState();
    // A desktop browser types at once; iOS shows the keyboard only on a tap in the text.
    this.text.focus?.();
    this.text.setSelectionRange?.(0, 0);
    return true;
  }

  /// Saves the text; `force` overwrites a file that changed on the Mac.
  save(force = false) {
    if (!this.base || this.writeId) return;
    const text = this.text.value;
    if (savedByteLength(text, this.base.eol) > EDIT_MAX_BYTES) { this.toast(EDIT_ERROR_TEXT.too_large); return; }
    const id = this.nextId();
    const message = fileWriteMessage({
      id, path: this.path, text, baseMtime: this.base.mtime, baseSize: this.base.size, eol: this.base.eol, force,
    });
    if (!this.sendBinary(message)) { this.toast('Not connected to the Mac'); return; }
    this.writeId = id;
    this.writingText = text;
    this.renderState();
  }

  /// A `files.write.result`; true if it was for this editor.
  onWritten(msg) {
    if (!msg || msg.id !== this.writeId) return false;
    this.writeId = null;
    this.base = { ...this.base, mtime: msg.mtime, size: msg.size };
    this.savedText = this.writingText;
    this.saved = true;
    this.toast('Saved');
    this.renderState();
    return true;
  }

  /// An `error` for this editor's read or write; true if it was.
  onError(msg) {
    if (!msg || msg.id == null) return false;
    if (msg.id === this.readId) {
      // Nothing was loaded, so there is nothing to keep.
      this.readId = null;
      this.toast(editErrorText(msg));
      this.close();
      return true;
    }
    if (msg.id !== this.writeId) return false;
    this.writeId = null;
    this.renderState();
    if (msg.code === 'conflict') {
      if (this.confirm('Changed on the Mac. Overwrite?')) this.save(true);
    } else {
      this.toast(editErrorText(msg));
    }
    return true;
  }

  /// The socket closed: no reply will come. A save in flight is reported as not saved (the
  /// text stays, so Save can be pressed again); a load in flight closes the editor.
  abandon() {
    if (this.writeId) {
      this.writeId = null;
      this.toast('Not saved — connection lost');
      this.renderState();
    }
    if (this.readId) {
      this.readId = null;
      this.toast('Not connected to the Mac');
      this.close();
    }
  }

  /// Close (or Esc): unsaved changes are discarded only after a confirm.
  requestClose() {
    if (!this.isOpen) return true;
    if (this.dirty && !this.confirm('Discard changes?')) return false;
    this.close();
    return true;
  }

  close() {
    if (!this.isOpen) return;
    this.root.hidden = true;
    this.readId = this.writeId = null;
    this.text.blur?.();
    this.text.value = '';
    this.base = null;
    const saved = this.saved;
    this.saved = false;
    this.onClosed(saved);
  }

  renderState() {
    this.title.textContent = this.name;
    this.marker.textContent = this.dirty ? ' •' : '';
    this.text.disabled = this.base == null;
    this.saveButton.disabled = this.base == null || this.writeId != null;
    this.saveButton.textContent = this.writeId ? 'Saving…' : 'Save';
  }
}
