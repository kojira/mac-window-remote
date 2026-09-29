// Unit tests for the trackpad gesture state machine (DESIGN.md D23, D30 item 10).
// Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';
import { GestureRecognizer, LONG_PRESS_MS, TAP_MAX_MS } from '../../web/gestures.js';

const P = (id, x, y) => ({ id, x, y });
const types = (intents) => intents.map((i) => i.type);

test('one-finger tap clicks on lift', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 100, 100)], 0);
  assert.deepEqual(g.touchMove([P(1, 103, 102)], 50), []);
  assert.deepEqual(g.touchEnd([], 120), [{ type: 'click', x: 100, y: 100 }]);
});

test('a slow still touch that lifts before the long-press is not a click', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 100, 100)], 0);
  assert.deepEqual(g.touchEnd([], TAP_MAX_MS + 50), []);
});

test('one-finger move sends relative moves including the slop distance, and no click', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 100, 100)], 0);
  assert.deepEqual(g.touchMove([P(1, 104, 100)], 10), []);
  assert.deepEqual(g.touchMove([P(1, 110, 100)], 20), [{ type: 'move', dx: 10, dy: 0 }]);
  assert.deepEqual(g.touchMove([P(1, 110, 90)], 30), [{ type: 'move', dx: 0, dy: -10 }]);
  assert.deepEqual(g.touchEnd([], 100), []);
});

test('long-press starts a drag lock; moves continue; a tap releases it', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 100, 100)], 0);
  assert.deepEqual(g.tick(LONG_PRESS_MS - 1), []);
  assert.deepEqual(types(g.tick(LONG_PRESS_MS)), ['dragStart']);
  assert.equal(g.dragLock, true);
  assert.deepEqual(g.touchMove([P(1, 120, 100)], 500), [{ type: 'move', dx: 20, dy: 0 }]);
  assert.deepEqual(g.touchEnd([], 600), []);
  assert.equal(g.dragLock, true);
  // A later move keeps dragging (the server posts drags while the lock is held).
  g.touchStart([P(2, 50, 50)], 1000);
  assert.deepEqual(g.touchMove([P(2, 50, 70)], 1010), [{ type: 'move', dx: 0, dy: 20 }]);
  g.touchEnd([], 1020);
  // Two-finger scroll keeps the lock.
  g.touchStart([P(3, 0, 0), P(4, 50, 0)], 2000);
  assert.deepEqual(types(g.touchMove([P(3, 0, 20), P(4, 50, 20)], 2010)), ['scroll']);
  g.touchEnd([], 2020);
  assert.equal(g.dragLock, true);
  // Tap releases instead of clicking.
  g.touchStart([P(5, 10, 10)], 3000);
  assert.deepEqual(g.touchEnd([], 3100), [{ type: 'dragEnd' }]);
  assert.equal(g.dragLock, false);
});

test('long-press recognized at lift when the timer did not fire', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 100, 100)], 0);
  assert.deepEqual(types(g.touchEnd([], LONG_PRESS_MS + 10)), ['dragStart']);
});

test('moving before the long-press time prevents the drag lock', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 100, 100)], 0);
  g.touchMove([P(1, 120, 100)], 100);
  assert.deepEqual(g.tick(LONG_PRESS_MS), []);
  assert.equal(g.dragLock, false);
});

test('two-finger tap right-clicks', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 100, 100)], 0);
  g.touchStart([P(1, 100, 100), P(2, 160, 100)], 20);
  assert.deepEqual(g.touchEnd([P(2, 160, 100)], 100), []);
  assert.deepEqual(g.touchEnd([], 110), [{ type: 'rightClick' }]);
});

test('two-finger parallel move scrolls both axes', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 100, 100), P(2, 160, 100)], 0);
  assert.deepEqual(g.touchMove([P(1, 105, 110), P(2, 165, 110)], 10), [{ type: 'scroll', dx: 5, dy: 10 }]);
  assert.deepEqual(g.touchMove([P(1, 100, 115), P(2, 160, 115)], 20), [{ type: 'scroll', dx: -5, dy: 5 }]);
  assert.deepEqual(g.touchEnd([], 30), []);
});

test('finger distance change classifies a pinch, which stays a pinch', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 100, 100), P(2, 160, 100)], 0);
  const z = g.touchMove([P(1, 90, 100), P(2, 170, 100)], 10);
  assert.deepEqual(types(z), ['zoom']);
  // Parallel movement afterwards is still zoom/pan of the view, never a scroll.
  const z2 = g.touchMove([P(1, 90, 130), P(2, 170, 130)], 20);
  assert.deepEqual(z2, [{ type: 'zoom', factor: 1, x: 130, y: 130, dx: 0, dy: 30 }]);
  assert.deepEqual(g.touchEnd([], 30), []);
});

test('scroll stays a scroll when the distance later changes', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 100, 100), P(2, 160, 100)], 0);
  assert.deepEqual(types(g.touchMove([P(1, 100, 110), P(2, 160, 110)], 10)), ['scroll']);
  assert.deepEqual(types(g.touchMove([P(1, 80, 120), P(2, 180, 120)], 20)), ['scroll']);
});

test('three-finger move pans the view', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 0, 0), P(2, 30, 0), P(3, 60, 0)], 0);
  assert.deepEqual(g.touchMove([P(1, 0, 9), P(2, 30, 9), P(3, 60, 9)], 10), [{ type: 'pan', dx: 0, dy: 9 }]);
  assert.deepEqual(g.touchEnd([], 20), []);
});

test('adding a finger upgrades and cancels the pending tap', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 100, 100)], 0);
  g.touchStart([P(1, 100, 100), P(2, 150, 100)], 30);
  // Two-finger move now scrolls instead of moving the cursor.
  assert.deepEqual(types(g.touchMove([P(1, 100, 120), P(2, 150, 120)], 40)), ['scroll']);
  g.touchStart([P(1, 100, 120), P(2, 150, 120), P(3, 200, 120)], 50);
  assert.deepEqual(types(g.touchMove([P(1, 110, 120), P(2, 160, 120), P(3, 210, 120)], 60)), ['pan']);
  assert.deepEqual(g.touchEnd([], 70), []);
});

test('lifting a finger never downgrades the gesture', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 100, 100), P(2, 160, 100)], 0);
  g.touchMove([P(1, 100, 120), P(2, 160, 120)], 10);
  assert.deepEqual(g.touchEnd([P(1, 100, 120)], 20), []);
  // The remaining finger does not move the cursor.
  assert.deepEqual(g.touchMove([P(1, 100, 160)], 30), []);
  assert.deepEqual(g.touchEnd([], 40), []);
  // Nor after a 3-finger pan down to 2.
  g.touchStart([P(1, 0, 0), P(2, 30, 0), P(3, 60, 0)], 100);
  g.touchEnd([P(1, 0, 0), P(2, 30, 0)], 110);
  assert.deepEqual(g.touchMove([P(1, 0, 30), P(2, 30, 30)], 120), []);
  assert.deepEqual(g.touchEnd([], 130), []);
});

test('the long-press timer does nothing once a second finger lands', () => {
  const g = new GestureRecognizer();
  g.touchStart([P(1, 100, 100)], 0);
  g.touchStart([P(1, 100, 100), P(2, 150, 100)], 100);
  assert.deepEqual(g.tick(LONG_PRESS_MS), []);
  assert.equal(g.dragLock, false);
});
