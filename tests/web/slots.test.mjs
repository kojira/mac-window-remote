// Unit tests for quick-switch slot resolution and `thumb` decoding (DESIGN.md D33).
// Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';
import { parseSlots, resolveSlot, decodeThumb, decodeViewSwitched } from '../../web/slots.js';

const W = (id, app, title) => ({ id, pid: 1, app, title, w: 800, h: 600 });
const slot = (windowId, app, title) => ({ windowId, app, title });

test('an empty slot resolves to empty', () => {
  assert.deepEqual(resolveSlot(null, [W(1, 'A', 'x')]), { state: 'empty' });
});

test('rule 1: the same windowId wins even if the title changed', () => {
  const list = [W(5, 'Editor', 'Other'), W(7, 'Editor', 'Renamed')];
  assert.equal(resolveSlot(slot(7, 'Editor', 'Notes'), list).window.id, 7);
});

test('rule 2: else the same app and title', () => {
  const list = [W(20, 'Editor', 'Scratch'), W(21, 'Editor', 'Notes'), W(22, 'Terminal', 'Notes')];
  assert.equal(resolveSlot(slot(7, 'Editor', 'Notes'), list).window.id, 21);
});

test('rule 3: else the only window of the same app', () => {
  const list = [W(30, 'Editor', 'Untitled'), W(31, 'Terminal', 'zsh')];
  assert.equal(resolveSlot(slot(7, 'Editor', 'Notes'), list).window.id, 30);
});

test('rule 4: else unavailable (app gone, or several windows none matching)', () => {
  assert.deepEqual(resolveSlot(slot(7, 'Editor', 'Notes'), [W(31, 'Terminal', 'zsh')]), { state: 'unavailable' });
  const two = [W(30, 'Editor', 'A'), W(32, 'Editor', 'B')];
  assert.deepEqual(resolveSlot(slot(7, 'Editor', 'Notes'), two), { state: 'unavailable' });
});

test('before the first window list a slot is used as stored', () => {
  assert.deepEqual(resolveSlot(slot(7, 'Editor', 'Notes'), null),
    { state: 'window', window: { id: 7, app: 'Editor', title: 'Notes' } });
});

test('stored slots: always three, unreadable entries are empty', () => {
  assert.deepEqual(parseSlots(null), [null, null, null]);
  assert.deepEqual(parseSlots('not json'), [null, null, null]);
  assert.deepEqual(parseSlots(JSON.stringify([{ windowId: 7, app: 'A', title: 't' }, { windowId: '7' }, null, { windowId: 9, app: 'B', title: '' }])),
    [{ windowId: 7, app: 'A', title: 't' }, null, null]);
});

test('thumb decode: jpeg, missing marker, malformed', () => {
  assert.deepEqual(decodeThumb({ t: 'thumb', windowId: 7, jpeg: '/9j/' }), { windowId: 7, src: 'data:image/jpeg;base64,/9j/' });
  assert.deepEqual(decodeThumb({ t: 'thumb', windowId: 7, missing: true }), { windowId: 7, src: null });
  assert.equal(decodeThumb({ t: 'thumb', windowId: 7 }), null);
  assert.equal(decodeThumb({ t: 'thumb', windowId: '7', jpeg: '/9j/' }), null);
});

test('view.switched decodes to the viewed window (D38)', () => {
  assert.deepEqual(decodeViewSwitched({ t: 'view.switched', windowId: 42, app: 'Editor', title: 'Notes' }),
    { id: 42, app: 'Editor', title: 'Notes' });
  assert.deepEqual(decodeViewSwitched({ t: 'view.switched', windowId: 42 }), { id: 42, app: '', title: '' });
  assert.equal(decodeViewSwitched({ t: 'view.switched', windowId: '42' }), null);
  assert.equal(decodeViewSwitched({ t: 'view.switched' }), null);
});
