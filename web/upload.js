// Clipboard text and image uploads to the Mac (DESIGN.md D36): binary WebSocket framing
// (§4.1) and the size limits. Pure functions; app.js does the sending.

/// Clipboard text is at most 1 MiB of UTF-8 (D11).
export const CLIPBOARD_MAX_BYTES = 1 << 20;
/// Images are at most 25 MiB (D12).
export const IMAGE_MAX_BYTES = 25 << 20;
/// Images are sent in chunks of this size, so the WebSocket never carries a huge message.
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

/// The `clipboard.paste` message, or null when the text is empty or over 1 MiB of UTF-8.
export function clipboardMessage(id, text) {
  const bytes = new TextEncoder().encode(text);
  if (bytes.length === 0 || bytes.length > CLIPBOARD_MAX_BYTES) return null;
  return encodeBinaryMessage({ t: 'clipboard.paste', id }, bytes);
}

/// The `image.chunk` messages of an image, in order.
export function* imageChunkMessages(id, bytes, chunkBytes = IMAGE_CHUNK_BYTES) {
  for (let offset = 0; offset < bytes.length; offset += chunkBytes) {
    const chunk = bytes.subarray(offset, Math.min(offset + chunkBytes, bytes.length));
    yield { offset, end: offset + chunk.length, data: encodeBinaryMessage({ t: 'image.chunk', id, size: bytes.length, offset }, chunk) };
  }
}

/// "/var/folders/…/uploads/img-20260101-030405-0a3f.png" → "…/img-20260101-030405-0a3f.png".
export function shortPath(path) {
  const i = path.lastIndexOf('/');
  return i < 0 ? path : '…' + path.slice(i);
}
