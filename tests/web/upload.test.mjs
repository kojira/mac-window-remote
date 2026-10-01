// Unit tests for the clipboard/image binary messages (DESIGN.md D36, D52 Copy to Mac). Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  CLIPBOARD_MAX_BYTES, CLIPBOARD_MODES, clipboardMessage, encodeBinaryMessage, readClipboardForMac, fileChunkMessages, imageChunkMessages, shortPath,
} from '../../web/upload.js';

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

test('file chunks (D42) carry the file name on the first chunk only', () => {
  const bytes = new Uint8Array(10);
  const chunks = [...fileChunkMessages('f1', 'My Report.pdf', bytes, 4)].map((c) => decode(c.data).header);
  assert.deepEqual(chunks, [
    { t: 'file.chunk', id: 'f1', size: 10, offset: 0, name: 'My Report.pdf' },
    { t: 'file.chunk', id: 'f1', size: 10, offset: 4 },
    { t: 'file.chunk', id: 'f1', size: 10, offset: 8 },
  ]);
  // A very long name keeps its end (the extension) and fits the Mac's 1 KiB header limit.
  const long = [...fileChunkMessages('f2', '𠮷'.repeat(500) + '.pdf', bytes)][0].data;
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
