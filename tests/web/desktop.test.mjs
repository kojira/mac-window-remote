// Unit tests for desktop mouse and keyboard translation (DESIGN.md D45). Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DesktopKeyboard, clickCount, keyMessage, keyNameForCode, modsOf, mouseButtonName, stageToWindow,
  wheelPixels, WHEEL_LINE_PX,
} from '../../web/desktop.js';

const key = (code, k, mods = {}) => ({ code, key: k, metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...mods });

test('codes map to §4.3 key names by US position', () => {
  assert.equal(keyNameForCode('KeyA'), 'a');
  assert.equal(keyNameForCode('KeyZ'), 'z');
  assert.equal(keyNameForCode('Digit0'), '0');
  assert.equal(keyNameForCode('Numpad7'), '7');
  assert.equal(keyNameForCode('F1'), 'F1');
  assert.equal(keyNameForCode('F12'), 'F12');
  assert.equal(keyNameForCode('F13'), null);
  for (const [code, name] of [['Minus', '-'], ['Equal', '='], ['BracketLeft', '['], ['BracketRight', ']'],
    ['Backslash', '\\'], ['Semicolon', ';'], ['Quote', "'"], ['Comma', ','], ['Period', '.'], ['Slash', '/'],
    ['Backquote', '`']]) assert.equal(keyNameForCode(code), name);
  for (const k of ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End', 'PageUp', 'PageDown',
    'Delete', 'Backspace', 'Tab', 'Escape', 'Enter', 'Space']) assert.equal(keyNameForCode(k), k);
  assert.equal(keyNameForCode('NumpadEnter'), 'Enter');
  assert.equal(keyNameForCode('ShiftLeft'), null);
  assert.equal(keyNameForCode('MetaLeft'), null);
  assert.equal(keyNameForCode('IntlYen'), null);
});

test('modifiers come from the event in cmd, ctrl, opt, shift order', () => {
  assert.deepEqual(modsOf({ shiftKey: true, metaKey: true, altKey: true, ctrlKey: true }), ['cmd', 'ctrl', 'opt', 'shift']);
  assert.deepEqual(modsOf({}), []);
});

test('printable characters without modifiers other than shift are text (layout respected)', () => {
  assert.deepEqual(keyMessage(key('KeyA', 'a')), { t: 'text', text: 'a' });
  assert.deepEqual(keyMessage(key('KeyA', 'A', { shiftKey: true })), { t: 'text', text: 'A' });
  // A French AZERTY "a" is at the Q position; the character, not the position, is sent.
  assert.deepEqual(keyMessage(key('KeyQ', 'a')), { t: 'text', text: 'a' });
  assert.deepEqual(keyMessage(key('Digit2', '@', { shiftKey: true })), { t: 'text', text: '@' });
  assert.deepEqual(keyMessage(key('Space', ' ')), { t: 'text', text: ' ' });
  // AltGr characters are text too.
  const altGr = { ...key('KeyQ', '@', { ctrlKey: true, altKey: true }), getModifierState: (m) => m === 'AltGraph' };
  assert.deepEqual(keyMessage(altGr), { t: 'text', text: '@' });
});

test('shortcuts and named keys are key combos by code', () => {
  assert.deepEqual(keyMessage(key('KeyC', 'c', { metaKey: true })), { t: 'key', key: 'c', mods: ['cmd'] });
  assert.deepEqual(keyMessage(key('KeyZ', 'Z', { metaKey: true, shiftKey: true })), { t: 'key', key: 'z', mods: ['cmd', 'shift'] });
  assert.deepEqual(keyMessage(key('KeyC', 'c', { ctrlKey: true })), { t: 'key', key: 'c', mods: ['ctrl'] });
  // Option+letter on a Mac browser types a character (å); it is still sent as ⌥ + the key.
  assert.deepEqual(keyMessage(key('KeyA', 'å', { altKey: true })), { t: 'key', key: 'a', mods: ['opt'] });
  assert.deepEqual(keyMessage(key('Enter', 'Enter')), { t: 'key', key: 'Enter', mods: [] });
  assert.deepEqual(keyMessage(key('Tab', 'Tab', { shiftKey: true })), { t: 'key', key: 'Tab', mods: ['shift'] });
  assert.deepEqual(keyMessage(key('ArrowLeft', 'ArrowLeft', { altKey: true })), { t: 'key', key: 'ArrowLeft', mods: ['opt'] });
  assert.deepEqual(keyMessage(key('F5', 'F5')), { t: 'key', key: 'F5', mods: [] });
  assert.deepEqual(keyMessage(key('Backspace', 'Backspace')), { t: 'key', key: 'Backspace', mods: [] });
  assert.deepEqual(keyMessage(key('Escape', 'Escape')), { t: 'key', key: 'Escape', mods: [] });
});

test('modifier keys alone, unmapped keys, and IME composition are not forwarded', () => {
  assert.equal(keyMessage(key('ShiftLeft', 'Shift', { shiftKey: true })), null);
  assert.equal(keyMessage(key('MetaLeft', 'Meta', { metaKey: true })), null);
  assert.equal(keyMessage(key('F13', 'F13')), null);
  assert.equal(keyMessage({ ...key('KeyK', 'k'), isComposing: true }), null);
  assert.equal(keyMessage({ ...key('KeyK', 'Process'), keyCode: 229 }), null);
  assert.equal(keyMessage(key('Quote', 'Dead')), null);
});

/// A DesktopKeyboard without DOM wiring, fed events directly.
function keyboard() {
  const sent = [];
  const kb = new DesktopKeyboard({ sink: null, isActive: () => true, send: (m) => { sent.push(m); return true; } });
  return { kb, sent };
}
const ev = (e) => ({ ...e, prevented: false, preventDefault() { this.prevented = true; } });

test('keys are forwarded with preventDefault, and their keyup is eaten', () => {
  const { kb, sent } = keyboard();
  const down = ev(key('KeyS', 's', { metaKey: true }));
  kb.onKeyDown(down);
  assert.equal(down.prevented, true);
  const up = ev(key('KeyS', 's'));
  kb.onKeyUp(up);
  assert.equal(up.prevented, true);
  const shift = ev(key('ShiftLeft', 'Shift', { shiftKey: true }));
  kb.onKeyDown(shift);
  assert.equal(shift.prevented, false);
  assert.deepEqual(sent, [{ t: 'key', key: 's', mods: ['cmd'] }]);
});

test('during IME composition nothing is forwarded; the committed text is sent once', () => {
  const { kb, sent } = keyboard();
  kb.onCompositionStart();
  kb.onKeyDown(ev(key('KeyN', 'n')));
  kb.onKeyDown(ev(key('Enter', 'Enter')));
  assert.deepEqual(sent, []);
  kb.onCompositionEnd({ data: '日本語' });
  kb.onKeyDown(ev(key('Enter', 'Enter')));
  assert.deepEqual(sent, [{ t: 'text', text: '日本語' }, { t: 'key', key: 'Enter', mods: [] }]);
  kb.onCompositionStart();
  kb.onCompositionEnd({ data: '' });
  assert.equal(sent.length, 2);
});

test('nothing is forwarded while inactive (a sheet, menu, or text field is in use)', () => {
  const sent = [];
  const kb = new DesktopKeyboard({ sink: null, isActive: () => false, send: (m) => sent.push(m) });
  const down = ev(key('KeyA', 'a'));
  kb.onKeyDown(down);
  kb.onCompositionEnd({ data: 'あ' });
  assert.equal(down.prevented, false);
  assert.deepEqual(sent, []);
});

test('mouse buttons and click counts', () => {
  assert.equal(mouseButtonName(0), 'left');
  assert.equal(mouseButtonName(1), 'middle');
  assert.equal(mouseButtonName(2), 'right');
  assert.equal(mouseButtonName(3), null);
  assert.equal(clickCount(1), 1);
  assert.equal(clickCount(2), 2);
  assert.equal(clickCount(5), 3);
  assert.equal(clickCount(0), 1);
  assert.equal(clickCount(undefined), 1);
});

test('wheel deltas: pixels, lines, and pages, both axes, content follows the scroll', () => {
  assert.deepEqual(wheelPixels({ deltaMode: 0, deltaX: 10, deltaY: -30 }, 500), { dx: -10, dy: 30 });
  assert.deepEqual(wheelPixels({ deltaMode: 1, deltaX: 0, deltaY: 3 }, 500), { dx: -0, dy: -3 * WHEEL_LINE_PX });
  assert.deepEqual(wheelPixels({ deltaMode: 2, deltaX: 1, deltaY: 0 }, 500), { dx: -500, dy: -0 });
});

test('stage points map to window coordinates through the zoom and offset', () => {
  const rect = { tx: 100, ty: 50, scale: 0.5, width: 800, height: 600 };
  assert.deepEqual(stageToWindow(100, 50, rect, false), { u: 0, v: 0 });
  assert.deepEqual(stageToWindow(300, 200, rect, false), { u: 0.5, v: 0.5 });
  assert.deepEqual(stageToWindow(500, 350, rect, false), { u: 1, v: 1 });
  assert.equal(stageToWindow(99, 200, rect, false), null);
  assert.deepEqual(stageToWindow(0, 400, rect, true), { u: 0, v: 1 });
});
