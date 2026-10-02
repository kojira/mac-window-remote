// Clipboard text, image, and file uploads to the Mac (DESIGN.md D36, D42, D52, D58): binary
// WebSocket framing (§4.1), the size limits, the chunk sender with its send-buffer cap, and the
// D58 ⬆︎ Upload here queue. app.js owns the socket.

/// Clipboard text is at most 1 MiB of UTF-8 (D11).
export const CLIPBOARD_MAX_BYTES = 1 << 20;
/// Images are at most 25 MiB (D12).
export const IMAGE_MAX_BYTES = 25 << 20;
/// Any file (D42, D58) is at most 2 GB (2 × 1024³ bytes).
export const FILE_MAX_BYTES = 2 * 1024 ** 3;
export const FILE_MAX_LABEL = '2 GB';
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
/// (the Mac sanitizes it). Only its last 200 code points are sent, so the header stays small and
/// the extension is kept. `source` is a Blob (read one chunk at a time, so a 2 GB file is never
/// held in memory) or a Uint8Array.
export function fileChunkMessages(id, name, source, chunkBytes = IMAGE_CHUNK_BYTES) {
  return blobChunkMessages({ t: 'file.chunk', id }, source, chunkBytes, { name: shortName(name) });
}

/// D58: the `files.put` messages of a file uploaded into the Mac folder `dest`; the first one
/// carries the name and the folder.
export function filesPutMessages(id, name, dest, source, chunkBytes = IMAGE_CHUNK_BYTES) {
  return blobChunkMessages({ t: 'files.put', id }, source, chunkBytes, { name: shortName(name), dest });
}

const FILE_NAME_MAX_CHARS = 200;
const shortName = (name) => Array.from(name).slice(-FILE_NAME_MAX_CHARS).join('');

function* chunkMessages(base, bytes, chunkBytes, name) {
  for (let offset = 0; offset < bytes.length; offset += chunkBytes) {
    const chunk = bytes.subarray(offset, Math.min(offset + chunkBytes, bytes.length));
    const header = { ...base, size: bytes.length, offset };
    if (name != null && offset === 0) header.name = name;
    yield { offset, end: offset + chunk.length, data: encodeBinaryMessage(header, chunk) };
  }
}

async function* blobChunkMessages(base, source, chunkBytes, first) {
  const size = source.length ?? source.size;
  for (let offset = 0; offset < size; offset += chunkBytes) {
    const end = Math.min(offset + chunkBytes, size);
    const chunk = source instanceof Uint8Array
      ? source.subarray(offset, end) : new Uint8Array(await source.slice(offset, end).arrayBuffer());
    const header = { ...base, size, offset, ...(offset === 0 ? first : {}) };
    yield { offset, end, data: encodeBinaryMessage(header, chunk) };
  }
}

/// While sending, at most this much waits in the socket's send buffer, so the socket's pong
/// answers the Mac's 10 s ping in time and input is not stuck behind an upload (D36).
export const UPLOAD_BUFFER_BYTES = 512 << 10;
const PROGRESS_POLL_MS = 50;
const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms));

/// Sends `chunks` ({offset, end, data}, sync or async iterable) of a `size`-byte upload.
/// transport.send(bytes) is false once the socket is gone; transport.buffered() is its
/// bufferedAmount, or null when it closed. onProgress(sentBytes) while the buffer drains.
/// Returns 'sent', 'cancelled', or 'interrupted'.
export async function sendChunks({ chunks, size, transport, isCancelled = () => false, onProgress = () => {}, sleep = sleepMs }) {
  for await (const chunk of chunks) {
    for (let b = transport.buffered(); b != null && b > UPLOAD_BUFFER_BYTES && !isCancelled(); b = transport.buffered()) {
      onProgress(chunk.offset - b);
      await sleep(PROGRESS_POLL_MS);
    }
    if (isCancelled()) return 'cancelled';
    if (!transport.send(chunk.data)) return 'interrupted';
    onProgress(chunk.end - (transport.buffered() ?? 0));
  }
  for (let b = transport.buffered(); b != null && b > 0 && !isCancelled(); b = transport.buffered()) {
    onProgress(size - b);
    await sleep(PROGRESS_POLL_MS);
  }
  if (isCancelled()) return 'cancelled';
  onProgress(size);
  return 'sent';
}

/// Error codes of `files.put` (D58) as shown on the device.
export const PUT_ERROR_TEXT = {
  too_large: `Too large (max ${FILE_MAX_LABEL})`,
  not_found: 'The folder no longer exists',
  not_a_directory: 'Not a folder',
  not_writable: 'This folder is not writable',
  no_access: 'This folder is not writable',
  disk_full: "The Mac's disk is full",
};

/// D58 ⬆︎ Upload here: sends files one after another into one Mac folder over `files.put`,
/// waiting for each file's `result` or `error` before the next one.
/// connect() returns the transport of the current socket, {send(bytes), buffered(),
/// sendJson(msg)}, taken once per batch so a reconnect never carries a half batch over.
/// status(text, {sticky}) shows the progress and the outcome (a toast); onDone(dest) runs after
/// the batch if any file arrived (the sheet lists the folder again).
export class FolderUploader {
  constructor({ connect, status, onDone = () => {}, nextId, sleep = sleepMs, chunkBytes = IMAGE_CHUNK_BYTES }) {
    this.connect = connect;
    this.status = status;
    this.onDone = onDone;
    this.nextId = nextId;
    this.sleep = sleep;
    this.chunkBytes = chunkBytes;
    this.current = null; // {id, settle}
    this.run = null;     // {cancelled}
  }

  get busy() { return this.run != null; }

  /// Uploads `files` (File objects) into the folder `dest`, named `folderName` in the toasts.
  async upload(files, dest, folderName) {
    if (this.run) return;
    const run = { cancelled: false };
    this.run = run;
    const transport = this.connect();
    const list = [...files];
    let uploaded = 0;
    const problems = [];
    try {
      for (let i = 0; i < list.length && !run.cancelled; i += 1) {
        const file = list[i];
        if (file.size > FILE_MAX_BYTES) { problems.push(`${file.name}: ${PUT_ERROR_TEXT.too_large}`); continue; }
        if (file.size === 0) { problems.push(`${file.name}: empty (or a folder)`); continue; }
        const label = (pct) => `Uploading ${i + 1}/${list.length} · ${file.name} · ${pct}%`;
        const id = this.nextId();
        const reply = new Promise((resolve) => { this.current = { id, settle: resolve }; });
        this.status(label(0), { sticky: true });
        let outcome;
        try {
          outcome = await sendChunks({
            chunks: filesPutMessages(id, file.name, dest, file, this.chunkBytes),
            size: file.size,
            transport,
            isCancelled: () => run.cancelled,
            onProgress: (sent) => this.status(label(Math.max(0, Math.min(100, Math.floor((sent / file.size) * 100)))), { sticky: true }),
            sleep: this.sleep,
          });
        } catch {
          // The file could not be read (it changed or went away): drop its part on the Mac.
          transport.sendJson({ t: 'files.put.cancel', id });
          problems.push(`${file.name}: could not be read`);
          continue;
        }
        if (outcome === 'cancelled') {
          if (!run.interrupted) transport.sendJson({ t: 'files.put.cancel', id });
          break;
        }
        if (outcome === 'interrupted') { run.interrupted = true; break; }
        const msg = await reply;
        if (msg == null) { if (!run.cancelled) run.interrupted = true; break; }
        if (msg.t === 'result') uploaded += 1;
        else problems.push(`${file.name}: ${PUT_ERROR_TEXT[msg.code] ?? msg.message ?? msg.code}`);
      }
    } finally {
      this.current = null;
      this.run = null;
    }
    const files_ = (n) => `${n} file${n === 1 ? '' : 's'}`;
    let text;
    if (run.interrupted) text = `Upload interrupted — ${files_(uploaded)} uploaded to ${folderName}`;
    else if (run.cancelled) text = `Upload cancelled — ${files_(uploaded)} uploaded to ${folderName}`;
    else if (problems.length === 0) text = `Uploaded ${files_(uploaded)} to ${folderName}`;
    else text = `Uploaded ${uploaded} of ${files_(list.length)} to ${folderName} · ${problems[0]}`;
    this.status(text);
    if (uploaded > 0) this.onDone(dest);
  }

  /// A `result` or `error` for the file being uploaded; true if it was.
  onReply(msg) {
    if (!this.current || msg?.id !== this.current.id) return false;
    this.current.settle(msg);
    this.current = null;
    return true;
  }

  /// Stops after the current chunk; the Mac deletes the partial file.
  cancel() {
    if (!this.run) return;
    this.run.cancelled = true;
    this.current?.settle(null);
  }

  /// The socket closed: no reply will come.
  abandon() {
    if (!this.run) return;
    this.run.interrupted = true;
    this.run.cancelled = true;
    this.current?.settle(null);
  }
}

/// "/var/folders/…/uploads/img-20260101-030405-0a3f.png" → "…/img-20260101-030405-0a3f.png".
export function shortPath(path) {
  const i = path.lastIndexOf('/');
  return i < 0 ? path : '…' + path.slice(i);
}
