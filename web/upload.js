// Clipboard text, image, and file uploads to the Mac (DESIGN.md D36, D42, D52): binary WebSocket framing
// (§4.1) and the size limits. Pure functions; app.js does the sending.

/// Clipboard text is at most 1 MiB of UTF-8 (D11).
export const CLIPBOARD_MAX_BYTES = 1 << 20;
/// Images are at most 25 MiB (D12).
export const IMAGE_MAX_BYTES = 25 << 20;
/// Any file (D42) is at most 100 MiB.
export const FILE_MAX_BYTES = 100 << 20;
/// Images and files are sent in chunks of this size, so the WebSocket never carries a huge message.
export const IMAGE_CHUNK_BYTES = 256 << 10;

/// `[uint32 BE headerLength][header JSON][payload]` (§4.1).
export function encodeBinaryMessage(header, payload) {
  const h = new TextEncoder().encode(JSON.stringify(header));
  const out = new Uint8Array(4 + h.length + payload.length);
  new DataView(out.buffer).setUint32(0, h.length);
  out.set(h, 4);
  out.set(payload, 4 + h.length);
  return out;
}

/// 📋 Paste (D36) pastes this device's clipboard text into the window; 📋 Copy to Mac (D52) only
/// puts it on the Mac clipboard. Each has its message type, fallback sheet text, and toasts.
export const CLIPBOARD_MODES = {
  paste: {
    t: 'clipboard.paste',
    sheetText: 'then paste it into the window.',
    sheetButton: 'Paste into window',
    empty: 'The iPhone clipboard has no text',
    done: (chars) => `Pasted ${chars} chars`,
  },
  copy: {
    t: 'clipboard.set',
    sheetText: 'then copy it to the Mac.',
    sheetButton: 'Copy to Mac',
    empty: "This device's clipboard has no text",
    done: () => '📋 Copied to the Mac clipboard',
  },
};

/// The `clipboard.paste` (or, for mode 'copy', `clipboard.set`) message, or null when the text
/// is empty or over 1 MiB of UTF-8.
export function clipboardMessage(id, text, mode = 'paste') {
  const bytes = new TextEncoder().encode(text);
  if (bytes.length === 0 || bytes.length > CLIPBOARD_MAX_BYTES) return null;
  return encodeBinaryMessage({ t: CLIPBOARD_MODES[mode].t, id }, bytes);
}

/// Runs inside the tap (iOS allows the clipboard read only then and shows its Paste callout).
/// clipboard: navigator.clipboard or null. sendText(text, mode) sends it; without readText, or
/// when it is refused, openSheet(mode) opens the fallback sheet (D5).
export function readClipboardForMac({ clipboard, mode, sendText, openSheet, toast }) {
  if (!clipboard?.readText) { openSheet(mode); return Promise.resolve(); }
  return clipboard.readText().then((text) => {
    if (!text) { toast(CLIPBOARD_MODES[mode].empty); return; }
    sendText(text, mode);
  }, () => openSheet(mode));
}

/// The `image.chunk` messages of an image, in order.
export function* imageChunkMessages(id, bytes, chunkBytes = IMAGE_CHUNK_BYTES) {
  yield* chunkMessages({ t: 'image.chunk', id }, bytes, chunkBytes);
}

/// The `file.chunk` messages of any file (D42), in order; the first one carries the file name
/// (the Mac sanitizes it). Only its last 200 code points are sent, so the header stays under
/// the Mac's 1 KiB limit and the extension is kept.
export function* fileChunkMessages(id, name, bytes, chunkBytes = IMAGE_CHUNK_BYTES) {
  yield* chunkMessages({ t: 'file.chunk', id }, bytes, chunkBytes, Array.from(name).slice(-FILE_NAME_MAX_CHARS).join(''));
}

const FILE_NAME_MAX_CHARS = 200;

function* chunkMessages(base, bytes, chunkBytes, name) {
  for (let offset = 0; offset < bytes.length; offset += chunkBytes) {
    const chunk = bytes.subarray(offset, Math.min(offset + chunkBytes, bytes.length));
    const header = { ...base, size: bytes.length, offset };
    if (name != null && offset === 0) header.name = name;
    yield { offset, end: offset + chunk.length, data: encodeBinaryMessage(header, chunk) };
  }
}

/// "/var/folders/…/uploads/img-20260101-030405-0a3f.png" → "…/img-20260101-030405-0a3f.png".
export function shortPath(path) {
  const i = path.lastIndexOf('/');
  return i < 0 ? path : '…' + path.slice(i);
}
