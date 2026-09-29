// Unit tests for the clipboard/image binary messages (DESIGN.md D36). Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  CLIPBOARD_MAX_BYTES, clipboardMessage, encodeBinaryMessage, fileChunkMessages, imageChunkMessages, shortPath,
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
