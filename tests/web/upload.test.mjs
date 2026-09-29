// Unit tests for the clipboard/image binary messages (DESIGN.md D36). Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  CLIPBOARD_MAX_BYTES, clipboardMessage, encodeBinaryMessage, imageChunkMessages, shortPath,
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

test('the toast shows only the file name of the path', () => {
  assert.equal(shortPath('/var/folders/xx/T/mac-window-remote/uploads/img-20260101-030405-0a3f.png'),
    '…/img-20260101-030405-0a3f.png');
});
