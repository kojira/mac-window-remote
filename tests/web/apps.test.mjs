// Unit tests for the Apps tab's `apps` decoding and stored tab (DESIGN.md D40).
// Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';
import { decodeApps, parseListTab, iconURL } from '../../web/apps.js';

test('apps keep the Mac order and the running flag', () => {
  const msg = { t: 'apps', items: [
    { id: '00aa', name: 'Safari', running: true },
    { id: '00bb', name: 'Notes', running: false },
    { id: '00cc', name: 'Music' },
  ] };
  assert.deepEqual(decodeApps(msg), [
    { id: '00aa', name: 'Safari', running: true },
    { id: '00bb', name: 'Notes', running: false },
    { id: '00cc', name: 'Music', running: false },
  ]);
});

test('malformed apps are dropped; ids that are not hex never reach a URL', () => {
  const msg = { t: 'apps', items: [null, { id: 5, name: 'X' }, { id: '../x', name: 'Y' }, { id: 'ab', name: 3 },
    { id: '0f', name: 'Ok' }] };
  assert.deepEqual(decodeApps(msg), [{ id: '0f', name: 'Ok', running: false }]);
  assert.deepEqual(decodeApps({ t: 'apps' }), []);
  assert.deepEqual(decodeApps(null), []);
});

test('the list tab defaults to windows', () => {
  assert.equal(parseListTab('apps'), 'apps');
  assert.equal(parseListTab('windows'), 'windows');
  assert.equal(parseListTab(null), 'windows');
  assert.equal(parseListTab('other'), 'windows');
});

test('icon URL is relative to the page', () => {
  assert.equal(iconURL('00aa'), 'apps/icon/00aa.png');
});
