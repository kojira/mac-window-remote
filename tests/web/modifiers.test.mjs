// Unit tests for the key panel's modifier state machine and typed character → key name
// (DESIGN.md D13, D34), and combo-key modifier merging (D37). Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';
import { ModifierState, charKeyName, mergeMods } from '../../web/modifiers.js';

test('tap arms, and the next key consumes it once in cmd, ctrl, opt, shift order', () => {
  const m = new ModifierState();
  m.tap('shift');
  m.tap('cmd');
  assert.equal(m.get('cmd'), 'armed');
  assert.deepEqual(m.consume(), ['cmd', 'shift']);
  assert.equal(m.any(), false);
  assert.deepEqual(m.consume(), []);
});

test('tapping an armed modifier turns it off', () => {
  const m = new ModifierState();
  m.tap('ctrl');
  m.tap('ctrl');
  assert.equal(m.get('ctrl'), 'off');
  assert.deepEqual(m.consume(), []);
});

test('a locked modifier stays across keys and text until tapped', () => {
  const m = new ModifierState();
  m.lock('cmd');
  m.tap('shift');
  assert.deepEqual(m.consume(), ['cmd', 'shift']);
  assert.deepEqual(m.consume(), ['cmd']);
  m.disarm();
  assert.equal(m.get('cmd'), 'locked');
  m.tap('cmd');
  assert.equal(m.get('cmd'), 'off');
});

test('sending text disarms armed modifiers but keeps locked ones', () => {
  const m = new ModifierState();
  m.tap('opt');
  m.lock('ctrl');
  m.disarm();
  assert.equal(m.get('opt'), 'off');
  assert.deepEqual(m.consume(), ['ctrl']);
});

test('reset clears locked modifiers; onChange fires only on a change', () => {
  let changes = 0;
  const m = new ModifierState(() => changes++);
  m.lock('cmd');
  m.reset();
  m.reset();
  m.disarm();
  assert.equal(m.any(), false);
  assert.equal(changes, 2);
});

test('charKeyName: a-z, 0-9, ANSI punctuation, and space are keys; anything else is text', () => {
  for (const c of ['a', 'z', '0', '9', '-', '=', '[', ']', '\\', ';', "'", ',', '.', '/', '`']) {
    assert.equal(charKeyName(c), c);
  }
  assert.equal(charKeyName(' '), 'Space');
  for (const t of ['A', 'ab', '', 'あ', '!', '€', null, undefined]) assert.equal(charKeyName(t), null);
});

test('mergeMods: a combo key adds its mods to the active ones, each once, in wire order', () => {
  const m = new ModifierState();
  m.tap('shift');
  assert.deepEqual(mergeMods(m.consume(), ['cmd']), ['cmd', 'shift']); // armed ⇧ + a ⌘ combo key adds shift
  assert.equal(m.get('shift'), 'off');
  m.lock('cmd');
  assert.deepEqual(mergeMods(m.consume(), ['cmd']), ['cmd']); // never a repeated mod
  assert.equal(m.get('cmd'), 'locked');
  assert.deepEqual(mergeMods([], ['cmd']), ['cmd']);
});
