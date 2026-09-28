// Canvas, zoom/pan transform, and slice 1 gestures (DESIGN.md D7, D14).
const MAX_ZOOM = 8;
const TAP_MAX_MOVE = 10;
const TAP_MAX_MS = 400;
const DOUBLE_TAP_MS = 300;
const DOUBLE_TAP_PX = 20;
const BAR_HIDE_MS = 3000;
const TOP_EDGE_PX = 40;

export class Viewer {
  constructor({ stage, canvas, bar, send, canInput }) {
    this.stage = stage;
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.bar = bar;
    this.send = send;
    this.canInput = canInput;
    this.header = null;
    this.scale = 1; // CSS px per image px
    this.tx = 0;
    this.ty = 0;
    this.touch = null;
    this.lastTap = null;
    this.barTimer = null;
    this.scrollPending = null;
    this.decoding = false;

    stage.addEventListener('touchstart', (e) => this.onTouchStart(e), { passive: false });
    stage.addEventListener('touchmove', (e) => this.onTouchMove(e), { passive: false });
    stage.addEventListener('touchend', (e) => this.onTouchEnd(e), { passive: false });
    stage.addEventListener('touchcancel', () => { this.touch = null; });
    window.addEventListener('resize', () => this.relayout());
    if (window.visualViewport) window.visualViewport.addEventListener('resize', () => this.relayout());
  }

  // ---------- frames ----------

  async onFrame(buffer) {
    const view = new DataView(buffer);
    if (buffer.byteLength < 4) return;
    const len = view.getUint32(0, false);
    let header;
    try {
      header = JSON.parse(new TextDecoder().decode(new Uint8Array(buffer, 4, len)));
    } catch { return; }
    if (header.t !== 'frame') return;
    const jpeg = new Blob([new Uint8Array(buffer, 4 + len)], { type: 'image/jpeg' });
    try {
      const bitmap = await createImageBitmap(jpeg);
      this.draw(header, bitmap);
      bitmap.close && bitmap.close();
    } catch { /* undecodable frame: skip it but still ack */ }
    this.send({ t: 'frame.ack', frameId: header.frameId });
  }

  draw(header, bitmap) {
    const sizeChanged = !this.header || this.header.width !== header.width || this.header.height !== header.height;
    const hadFrame = !!this.header;
    const zoom = hadFrame ? this.scale / this.fitScale() : 1;
    this.header = header;
    if (sizeChanged) {
      this.canvas.width = header.width;
      this.canvas.height = header.height;
    }
    this.ctx.drawImage(bitmap, 0, 0);
    if (!hadFrame) this.fit();
    else if (sizeChanged) { this.scale = this.fitScale() * zoom; this.clampAndApply(); }
  }

  clear() {
    this.header = null;
    this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    this.canvas.width = 0;
    this.canvas.height = 0;
    this.setDimmed(false);
  }

  setDimmed(on) {
    this.stage.parentElement.classList.toggle('dimmed', on);
  }

  // ---------- transform ----------

  fitScale() {
    if (!this.header) return 1;
    const w = this.stage.clientWidth;
    const h = this.stage.clientHeight;
    return Math.min(w / this.header.width, h / this.header.height);
  }

  fit() {
    this.scale = this.fitScale();
    this.clampAndApply();
  }

  relayout() {
    if (!this.header) return;
    this.scale = Math.max(this.scale, this.fitScale());
    this.clampAndApply();
  }

  clampAndApply() {
    if (!this.header) return;
    const fit = this.fitScale();
    this.scale = Math.min(Math.max(this.scale, fit), fit * MAX_ZOOM);
    const sw = this.stage.clientWidth;
    const sh = this.stage.clientHeight;
    const iw = this.header.width * this.scale;
    const ih = this.header.height * this.scale;
    this.tx = iw <= sw ? (sw - iw) / 2 : Math.min(0, Math.max(sw - iw, this.tx));
    this.ty = ih <= sh ? (sh - ih) / 2 : Math.min(0, Math.max(sh - ih, this.ty));
    this.canvas.style.transform = `translate(${this.tx}px, ${this.ty}px) scale(${this.scale})`;
  }

  /// Stage point (CSS px) → content-normalized (u, v), or null outside the window content (D7).
  toNormalized(x, y) {
    const h = this.header;
    if (!h) return null;
    const ix = (x - this.tx) / this.scale;
    const iy = (y - this.ty) / this.scale;
    const u = (ix - h.content.x) / h.content.w;
    const v = (iy - h.content.y) / h.content.h;
    if (!(u >= 0 && u <= 1 && v >= 0 && v <= 1)) return null;
    return { u, v };
  }

  stagePoint(t) {
    const r = this.stage.getBoundingClientRect();
    return { x: t.clientX - r.left, y: t.clientY - r.top };
  }

  // ---------- top bar ----------

  showBar() {
    this.bar.classList.remove('hidden');
    clearTimeout(this.barTimer);
    this.barTimer = setTimeout(() => this.bar.classList.add('hidden'), BAR_HIDE_MS);
  }

  // ---------- gestures ----------

  onTouchStart(e) {
    e.preventDefault();
    const touches = e.touches;
    if (touches.length === 1 && !this.touch) {
      const p = this.stagePoint(touches[0]);
      this.touch = { mode: 'pending', start: p, last: p, t0: performance.now() };
    } else if (touches.length === 2) {
      const a = this.stagePoint(touches[0]);
      const b = this.stagePoint(touches[1]);
      this.touch = {
        mode: 'pinch',
        d0: Math.hypot(a.x - b.x, a.y - b.y) || 1,
        mid0: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 },
        s0: this.scale, tx0: this.tx, ty0: this.ty,
      };
    } else if (this.touch) {
      this.touch.mode = 'done';
    }
  }

  onTouchMove(e) {
    e.preventDefault();
    const t = this.touch;
    if (!t) return;
    if (t.mode === 'pinch' && e.touches.length >= 2) {
      const a = this.stagePoint(e.touches[0]);
      const b = this.stagePoint(e.touches[1]);
      const d = Math.hypot(a.x - b.x, a.y - b.y);
      const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
      const fit = this.fitScale();
      const s = Math.min(Math.max(t.s0 * d / t.d0, fit), fit * MAX_ZOOM);
      // Keep the image point under the initial midpoint under the current midpoint.
      const ix = (t.mid0.x - t.tx0) / t.s0;
      const iy = (t.mid0.y - t.ty0) / t.s0;
      this.scale = s;
      this.tx = mid.x - ix * s;
      this.ty = mid.y - iy * s;
      this.clampAndApply();
      return;
    }
    if (e.touches.length !== 1) return;
    const p = this.stagePoint(e.touches[0]);
    if (t.mode === 'pending') {
      const moved = Math.hypot(p.x - t.start.x, p.y - t.start.y);
      if (moved > TAP_MAX_MOVE) {
        // Drags that start before the hold time scroll the window; later ones are slice 4.
        t.mode = performance.now() - t.t0 < TAP_MAX_MS ? 'scroll' : 'done';
      }
    }
    if (t.mode === 'scroll') {
      this.queueScroll(p.x - t.last.x, p.y - t.last.y, p);
    }
    t.last = p;
  }

  onTouchEnd(e) {
    e.preventDefault();
    const t = this.touch;
    if (!t) return;
    if (e.touches.length > 0) {
      if (t.mode === 'pinch') t.mode = 'done';
      return;
    }
    this.touch = null;
    if (t.mode !== 'pending') return;
    const dt = performance.now() - t.t0;
    if (dt > TAP_MAX_MS) return;
    this.onTap(t.start);
  }

  onTap(p) {
    if (p.y < TOP_EDGE_PX && this.bar.classList.contains('hidden')) {
      this.showBar();
      return;
    }
    const n = this.toNormalized(p.x, p.y);
    if (!n || !this.canInput()) return;
    const now = performance.now();
    const prev = this.lastTap;
    const isDouble = prev && now - prev.t <= DOUBLE_TAP_MS && Math.hypot(p.x - prev.x, p.y - prev.y) <= DOUBLE_TAP_PX;
    this.lastTap = isDouble ? null : { t: now, x: p.x, y: p.y };
    this.send({ t: 'pointer', action: isDouble ? 'doubleClick' : 'click', u: n.u, v: n.v, frameId: this.header.frameId });
  }

  /// One scroll message per animation frame (D14). Deltas are content-normalized.
  queueScroll(dx, dy, p) {
    if (!this.header || !this.canInput()) return;
    const h = this.header;
    const du = dx / this.scale / h.content.w;
    const dv = dy / this.scale / h.content.h;
    if (this.scrollPending) {
      this.scrollPending.du += du;
      this.scrollPending.dv += dv;
      this.scrollPending.p = p;
      return;
    }
    this.scrollPending = { du, dv, p };
    requestAnimationFrame(() => {
      const s = this.scrollPending;
      this.scrollPending = null;
      if (!s || !this.header) return;
      const n = this.toNormalized(s.p.x, s.p.y);
      if (!n) return;
      this.send({ t: 'scroll', u: n.u, v: n.v, du: s.du, dv: s.dv, frameId: this.header.frameId });
    });
  }
}
