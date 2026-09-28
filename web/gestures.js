// Trackpad gesture recognizer (DESIGN.md D23). Pure: it consumes touch points and
// timestamps and returns intents; viewer.js wires DOM events and a long-press timer to it.
//
// Touch points are {id, x, y} in CSS px; every call gets all fingers currently down.
// Intents:
//   {type: 'move', dx, dy}                 1-finger movement, CSS px
//   {type: 'click', x, y}                  1-finger tap; (x, y) is where the finger was
//   {type: 'dragStart'} / {type: 'dragEnd'} drag lock begins (long-press) / is released (tap)
//   {type: 'rightClick'}                   2-finger tap
//   {type: 'scroll', dx, dy}               2-finger movement of the midpoint, CSS px
//   {type: 'zoom', factor, x, y, dx, dy}   pinch: the midpoint moved by (dx, dy) to (x, y), and
//                                          the finger distance changed by `factor`
//   {type: 'pan', dx, dy}                  3-finger movement of the centroid, CSS px

export const TAP_SLOP = 8;
export const TAP_MAX_MS = 250;
export const LONG_PRESS_MS = 450;
export const PINCH_START = 12;

const byId = (touches) => [...touches].sort((a, b) => a.id - b.id);
const distance = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
function centroid(touches) {
  let x = 0;
  let y = 0;
  for (const t of touches) { x += t.x; y += t.y; }
  return { x: x / touches.length, y: y / touches.length };
}

export class GestureRecognizer {
  constructor() {
    this.dragLock = false;
    this.g = null;
  }

  touchStart(touches, t) {
    if (!this.g) {
      this.g = {
        kind: 1, phase: 'pending', t0: t, moved: false,
        starts: new Map(), last: null, mid: null, dist: 0, dist0: 0,
      };
    }
    const g = this.g;
    for (const p of touches) if (!g.starts.has(p.id)) g.starts.set(p.id, { x: p.x, y: p.y });
    const count = Math.min(touches.length, 3);
    // Adding a finger upgrades the gesture; it never downgrades (D23).
    // Classification of the new kind starts fresh from where the fingers are now.
    if (count > g.kind) {
      g.kind = count;
      g.phase = count === 3 ? 'pan' : 'pending';
      g.moved = false;
      g.starts = new Map(touches.map((p) => [p.id, { x: p.x, y: p.y }]));
      if (count === 2) g.dist0 = distance(...byId(touches).slice(0, 2));
    }
    this.rebase(touches);
    return [];
  }

  touchMove(touches, t) {
    const g = this.g;
    if (!g) return [];
    for (const p of touches) {
      const s = g.starts.get(p.id);
      if (s && distance(p, s) >= TAP_SLOP) g.moved = true;
    }
    // After a finger lifts, the remaining ones do nothing until all lift.
    if (touches.length < g.kind) return [];
    const out = [];
    if (g.kind === 1) {
      const p = touches[0];
      if (g.phase === 'pending' && g.moved) g.phase = 'moving';
      if (g.phase !== 'pending') {
        const dx = p.x - g.last.x;
        const dy = p.y - g.last.y;
        if (dx || dy) out.push({ type: 'move', dx, dy });
        g.last = { x: p.x, y: p.y };
      }
    } else if (g.kind === 2) {
      const [a, b] = byId(touches);
      const d = distance(a, b);
      const mid = centroid([a, b]);
      if (g.phase === 'pending') {
        if (Math.abs(d - g.dist0) >= PINCH_START) g.phase = 'pinch';
        else if (g.moved) g.phase = 'scroll';
      }
      const dx = mid.x - g.mid.x;
      const dy = mid.y - g.mid.y;
      if (g.phase === 'scroll') {
        if (dx || dy) out.push({ type: 'scroll', dx, dy });
      } else if (g.phase === 'pinch') {
        out.push({ type: 'zoom', factor: g.dist > 0 ? d / g.dist : 1, x: mid.x, y: mid.y, dx, dy });
      }
      if (g.phase !== 'pending') { g.mid = mid; g.dist = d; }
    } else {
      const mid = centroid(touches);
      const dx = mid.x - g.mid.x;
      const dy = mid.y - g.mid.y;
      if (dx || dy) out.push({ type: 'pan', dx, dy });
      g.mid = mid;
    }
    return out;
  }

  /// `touches` are the fingers still down.
  touchEnd(touches, t) {
    const g = this.g;
    if (!g) return [];
    if (touches.length > 0) {
      this.rebase(touches);
      return [];
    }
    this.g = null;
    const elapsed = t - g.t0;
    if (g.kind === 1 && g.phase === 'pending' && !g.moved) {
      if (elapsed >= LONG_PRESS_MS) return this.startDragLock();
      if (elapsed <= TAP_MAX_MS) {
        if (this.dragLock) {
          this.dragLock = false;
          return [{ type: 'dragEnd' }];
        }
        const s = g.starts.values().next().value;
        return [{ type: 'click', x: s.x, y: s.y }];
      }
    } else if (g.kind === 2 && g.phase === 'pending' && !g.moved && elapsed <= TAP_MAX_MS) {
      return [{ type: 'rightClick' }];
    }
    return [];
  }

  /// Aborts the current gesture without intents (touchcancel). A drag lock stays.
  touchCancel() {
    this.g = null;
  }

  /// Called by a timer LONG_PRESS_MS after a touch starts.
  tick(t) {
    const g = this.g;
    if (!g || g.kind !== 1 || g.phase !== 'pending' || g.moved || t - g.t0 < LONG_PRESS_MS) return [];
    g.phase = 'held';
    return this.startDragLock();
  }

  /// Forgets the drag lock without an intent (the Mac releases the button on disconnect).
  releaseDragLock() {
    this.dragLock = false;
  }

  startDragLock() {
    if (this.dragLock) return [];
    this.dragLock = true;
    return [{ type: 'dragStart' }];
  }

  /// Re-anchors movement tracking after the finger count changed, so nothing jumps.
  rebase(touches) {
    const g = this.g;
    const sorted = byId(touches);
    if (sorted.length > 0) g.last = { x: sorted[0].x, y: sorted[0].y };
    if (g.kind === 1 && g.phase === 'pending' && sorted.length > 0) {
      // Movement while pending is measured from the start, so none is lost when it begins.
      const s = g.starts.get(sorted[0].id);
      if (s) g.last = { x: s.x, y: s.y };
    }
    if (g.kind === 2 && sorted.length >= 2) {
      g.mid = centroid(sorted.slice(0, 2));
      g.dist = distance(sorted[0], sorted[1]);
    } else if (g.kind === 3 && sorted.length > 0) {
      g.mid = centroid(sorted);
    }
  }
}
