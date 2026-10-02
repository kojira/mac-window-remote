// Unit tests for the clipboard/image binary messages (DESIGN.md D36, D52 Copy to Mac). Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  CLIPBOARD_MAX_BYTES, CLIPBOARD_MODES, FILE_MAX_BYTES, FILE_MAX_LABEL, FolderUploader, UPLOAD_BUFFER_BYTES, clipboardMessage,
  encodeBinaryMessage, filesPutMessages, readClipboardForMac, fileChunkMessages, imageChunkMessages, sendChunks, shortPath,
} from '../../web/upload.js';

async function collect(iterable) {
  const out = [];
  for await (const x of iterable) out.push(x);
  return out;
}

function decode(bytes) {
  const n = new DataView(bytes.buffer, bytes.byteOffset).getUint32(0);
  return {
    header: JSON.parse(new TextDecoder().decode(bytes.subarray(4, 4 + n))),
    payload: bytes.subarray(4 + n),
  };
}

test('binary framing is a big-endian header length, the JSON header, then the payload', () => {
  const m = encodeBinaryMessage({ t: 'x', id: 'a' }, new Uint8Array([1, 2]));
  assert.deepEqual([...m.subarray(0, 4)], [0, 0, 0, 18]);
  assert.deepEqual(decode(m), { header: { t: 'x', id: 'a' }, payload: new Uint8Array([1, 2]) });
});

test('clipboard text is UTF-8 up to 1 MiB; empty or larger text is not sent', () => {
  const m = decode(clipboardMessage('c1', 'こんにちは\n'));
  assert.deepEqual(m.header, { t: 'clipboard.paste', id: 'c1' });
  assert.equal(new TextDecoder().decode(m.payload), 'こんにちは\n');
  assert.ok(clipboardMessage('c2', 'a'.repeat(CLIPBOARD_MAX_BYTES)));
  assert.equal(clipboardMessage('c3', 'a'.repeat(CLIPBOARD_MAX_BYTES + 1)), null);
  // 3 bytes per character in UTF-8: the limit is bytes, not characters.
  assert.equal(clipboardMessage('c4', 'あ'.repeat(CLIPBOARD_MAX_BYTES / 2)), null);
  assert.equal(clipboardMessage('c5', ''), null);
});

test('image chunks cover the image exactly, in order', () => {
  const image = new Uint8Array(10).map((_, i) => i);
  const chunks = [...imageChunkMessages('i1', image, 4)];
  assert.deepEqual(chunks.map((c) => [c.offset, c.end]), [[0, 4], [4, 8], [8, 10]]);
  const last = decode(chunks[2].data);
  assert.deepEqual(last.header, { t: 'image.chunk', id: 'i1', size: 10, offset: 8 });
  assert.deepEqual([...last.payload], [8, 9]);
});

test('file chunks (D42) carry the file name on the first chunk only', async () => {
  const bytes = new Uint8Array(10);
  const chunks = (await collect(fileChunkMessages('f1', 'My Report.pdf', bytes, 4))).map((c) => decode(c.data).header);
  assert.deepEqual(chunks, [
    { t: 'file.chunk', id: 'f1', size: 10, offset: 0, name: 'My Report.pdf' },
    { t: 'file.chunk', id: 'f1', size: 10, offset: 4 },
    { t: 'file.chunk', id: 'f1', size: 10, offset: 8 },
  ]);
  // A very long name keeps its end (the extension) and fits the Mac's 1 KiB header limit.
  const long = (await collect(fileChunkMessages('f2', '𠮷'.repeat(500) + '.pdf', bytes)))[0].data;
  assert.ok(new DataView(long.buffer).getUint32(0) <= 1024);
  assert.ok(decode(long).header.name.endsWith('𠮷.pdf'));
});

test('the toast shows only the file name of the path', () => {
  assert.equal(shortPath('/var/folders/xx/T/mac-window-remote/uploads/img-20260101-030405-0a3f.png'),
    '…/img-20260101-030405-0a3f.png');
});

test('Copy to Mac sends clipboard.set with the same 1 MiB UTF-8 limit (D52)', () => {
  const m = decode(clipboardMessage('c1', '行1\n行2', 'copy'));
  assert.deepEqual(m.header, { t: 'clipboard.set', id: 'c1' });
  assert.equal(new TextDecoder().decode(m.payload), '行1\n行2');
  assert.ok(clipboardMessage('c2', 'a'.repeat(CLIPBOARD_MAX_BYTES), 'copy'));
  assert.equal(clipboardMessage('c3', 'a'.repeat(CLIPBOARD_MAX_BYTES + 1), 'copy'), null);
  assert.equal(clipboardMessage('c4', '', 'copy'), null);
});

test('Copy to Mac: success toast, and the fallback sheet reads "Copy to Mac" (D52)', () => {
  assert.equal(CLIPBOARD_MODES.copy.done(5), '📋 Copied to the Mac clipboard');
  assert.equal(CLIPBOARD_MODES.copy.sheetButton, 'Copy to Mac');
  assert.equal(CLIPBOARD_MODES.paste.sheetButton, 'Paste into window');
  assert.equal(CLIPBOARD_MODES.paste.done(5), 'Pasted 5 chars');
  for (const m of Object.values(CLIPBOARD_MODES)) assert.ok(!/iPhone/.test(m.sheetText + m.sheetButton + m.done(1)));
  assert.ok(!/iPhone/.test(CLIPBOARD_MODES.copy.empty));
});

function readHarness(clipboard) {
  const log = { sent: [], sheets: [], toasts: [] };
  const run = (mode) => readClipboardForMac({
    clipboard, mode,
    sendText: (text, m) => log.sent.push([text, m]),
    openSheet: (m) => log.sheets.push(m),
    toast: (t) => log.toasts.push(t),
  });
  return { log, run };
}

test('the clipboard read sends the text in its mode; refused or missing opens the sheet in that mode', async () => {
  const ok = readHarness({ readText: () => Promise.resolve('hello') });
  await ok.run('copy');
  assert.deepEqual(ok.log.sent, [['hello', 'copy']]);
  assert.deepEqual(ok.log.sheets, []);

  const refused = readHarness({ readText: () => Promise.reject(new Error('NotAllowedError')) });
  await refused.run('copy');
  assert.deepEqual(refused.log.sheets, ['copy']);
  assert.deepEqual(refused.log.sent, []);

  const missing = readHarness(null);
  await missing.run('paste');
  assert.deepEqual(missing.log.sheets, ['paste']);

  const empty = readHarness({ readText: () => Promise.resolve('') });
  await empty.run('copy');
  assert.deepEqual(empty.log.toasts, [CLIPBOARD_MODES.copy.empty]);
  assert.deepEqual(empty.log.sent, []);
});

// D58 (and D42's new limit): 2 GB files, read one chunk at a time.
test('the file limit is 2 GB', () => {
  assert.equal(FILE_MAX_BYTES, 2 * 1024 * 1024 * 1024);
  assert.equal(FILE_MAX_LABEL, '2 GB');
});

test('a Blob is read one chunk at a time; files.put carries the name and folder on the first chunk', async () => {
  const blob = new Blob([new Uint8Array(10).map((_, i) => i)]);
  let sliced = 0;
  const spy = { size: blob.size, slice: (a, b) => { sliced += 1; return blob.slice(a, b); } };
  const chunks = await collect(filesPutMessages('p1', 'a b.txt', '/home/x/Docs', spy, 4));
  assert.equal(sliced, 3);
  assert.deepEqual(chunks.map((c) => decode(c.data).header), [
    { t: 'files.put', id: 'p1', size: 10, offset: 0, name: 'a b.txt', dest: '/home/x/Docs' },
    { t: 'files.put', id: 'p1', size: 10, offset: 4 },
    { t: 'files.put', id: 'p1', size: 10, offset: 8 },
  ]);
  assert.deepEqual([...decode(chunks[2].data).payload], [8, 9]);
});

function fakeTransport({ drainPerPoll = Infinity, failAfter = Infinity } = {}) {
  const t = {
    sent: [], json: [], buffered: 0,
    send(bytes) { if (t.sent.length >= failAfter) return false; t.sent.push(decode(bytes)); t.buffered += bytes.length; return true; },
    bufferedFn: () => t.buffered,
    sendJson(m) { t.json.push(m); return true; },
  };
  t.api = { send: (b) => t.send(b), buffered: () => t.buffered, sendJson: (m) => t.sendJson(m) };
  t.sleep = async () => { await new Promise((r) => setTimeout(r, 0)); t.buffered = Math.max(0, t.buffered - drainPerPoll); };
  return t;
}

test('sendChunks keeps the send buffer under the cap and reports progress', async () => {
  const t = fakeTransport({ drainPerPoll: 256 << 10 });
  const progress = [];
  const size = 4 * UPLOAD_BUFFER_BYTES;
  const result = await sendChunks({
    chunks: imageChunkMessages('i1', new Uint8Array(size)), size, transport: t.api,
    onProgress: (n) => progress.push(n), sleep: t.sleep,
  });
  assert.equal(result, 'sent');
  assert.equal(t.sent.length, 8);
  assert.equal(t.buffered, 0);
  assert.ok(progress.every((n, i) => i === 0 || n >= progress[i - 1] - (256 << 10)));
  assert.equal(progress.at(-1), size);
  const cut = fakeTransport({ failAfter: 1 });
  assert.equal(await sendChunks({ chunks: imageChunkMessages('i2', new Uint8Array(10), 4), size: 10, transport: cut.api, sleep: cut.sleep }), 'interrupted');
});

function uploaderHarness(transportOptions) {
  const t = fakeTransport(transportOptions);
  const toasts = [];
  const done = [];
  let n = 0;
  const up = new FolderUploader({
    connect: () => t.api, status: (text, opts) => toasts.push([text, opts?.sticky === true]),
    onDone: (dest) => done.push(dest), nextId: () => `p${(n += 1)}`, sleep: t.sleep, chunkBytes: 4,
  });
  // The Mac answers each file after its last chunk.
  const answer = (code) => new Promise((resolve) => {
    const poll = () => {
      const last = t.sent.at(-1)?.header;
      if (last && up.current?.id === last.id && last.offset + 4 >= last.size) {
        resolve(up.onReply(code ? { t: 'error', id: last.id, code } : { t: 'result', id: last.id, path: `/d/${last.id}` }));
      } else setTimeout(poll, 0);
    };
    poll();
  });
  return { t, toasts, done, up, answer };
}

const fileOf = (name, size) => Object.assign(new Blob([new Uint8Array(size)]), { name });

test('Upload here: files go one after another with per-file progress, then "Uploaded N files" and a refresh', async () => {
  const { t, toasts, done, up, answer } = uploaderHarness();
  const run = up.upload([fileOf('a.txt', 6), fileOf('b.txt', 3), fileOf('c.txt', 4)], '/d', 'Docs');
  assert.equal(up.busy, true);
  await answer();
  await answer();
  await answer();
  await run;
  assert.equal(up.busy, false);
  const firsts = t.sent.filter((m) => m.header.offset === 0).map((m) => m.header);
  assert.deepEqual(firsts.map((h) => [h.id, h.name, h.dest, h.size]), [['p1', 'a.txt', '/d', 6], ['p2', 'b.txt', '/d', 3], ['p3', 'c.txt', '/d', 4]]);
  // Each file's chunks are all sent before the next file starts.
  assert.deepEqual(t.sent.map((m) => m.header.id), ['p1', 'p1', 'p2', 'p3']);
  const progress = toasts.filter(([, sticky]) => sticky).map(([text]) => text);
  assert.ok(progress.includes('Uploading 1/3 · a.txt · 0%'));
  assert.ok(progress.includes('Uploading 2/3 · b.txt · 100%'));
  assert.ok(progress.some((p) => p.startsWith('Uploading 3/3 · c.txt')));
  assert.deepEqual(toasts.at(-1), ['Uploaded 3 files to Docs', false]);
  assert.deepEqual(done, ['/d']);
});

test('Upload here: an error on one file is reported and the others still upload; over 2 GB is skipped', async () => {
  const { toasts, done, up, answer } = uploaderHarness();
  const huge = { name: 'huge.iso', size: FILE_MAX_BYTES + 1, slice() { throw new Error('must not be read'); } };
  const run = up.upload([huge, fileOf('a.txt', 2), fileOf('b.txt', 2)], '/d', 'Docs');
  await answer('disk_full');
  await answer();
  await run;
  assert.deepEqual(toasts.at(-1), ["Uploaded 1 of 3 files to Docs · huge.iso: Too large (max 2 GB)", false]);
  assert.deepEqual(done, ['/d']);
  const { toasts: t2, done: d2, up: u2, answer: a2 } = uploaderHarness();
  const r2 = u2.upload([fileOf('x', 2)], '/ro', 'ro');
  await a2('not_writable');
  await r2;
  assert.deepEqual(t2.at(-1), ['Uploaded 0 of 1 file to ro · x: This folder is not writable', false]);
  assert.deepEqual(d2, [], 'nothing arrived, no refresh');
});

test('Upload here: Cancel stops after the current chunk and tells the Mac to drop the part', async () => {
  const { t, toasts, done, up } = uploaderHarness({ drainPerPoll: 0 });
  t.buffered = UPLOAD_BUFFER_BYTES + 1; // the buffer never drains, so the first chunk waits
  const run = up.upload([fileOf('a.txt', 6), fileOf('b.txt', 6)], '/d', 'Docs');
  await new Promise((r) => setTimeout(r, 0));
  up.cancel();
  await run;
  assert.equal(t.sent.length, 0);
  assert.deepEqual(t.json, [{ t: 'files.put.cancel', id: 'p1' }]);
  assert.deepEqual(toasts.at(-1), ['Upload cancelled — 0 files uploaded to Docs', false]);
  assert.deepEqual(done, []);
});

test('Upload here: a closed socket ends the batch as interrupted', async () => {
  const { t, toasts, up } = uploaderHarness();
  const run = up.upload([fileOf('a.txt', 2), fileOf('b.txt', 2)], '/d', 'Docs');
  await new Promise((r) => setTimeout(r, 0));
  up.abandon();
  await run;
  assert.deepEqual(t.json, []);
  assert.deepEqual(toasts.at(-1), ['Upload interrupted — 0 files uploaded to Docs', false]);
  assert.equal(up.onReply({ t: 'result', id: 'p1' }), false);
});
