// Video, zoom/pan transform, trackpad input, and the cursor overlay (DESIGN.md D21, D23, D24).
// The window arrives as a WebRTC video track (rtc.js); the overlay uses the video's intrinsic
// size, and the cursor is in window-normalized coordinates, so no frame header is needed.
import { GestureRecognizer, LONG_PRESS_MS } from './gestures.js';
import { clickCount, mouseButtonName, stageToWindow, wheelPixels } from './desktop.js';

const MAX_ZOOM = 8;
/// A thumb-sized swipe covers a useful distance of the window (D24).
const SENSITIVITY = 1.5;

const clamp01 = (x) => Math.min(Math.max(x, 0), 1);
const clamp1 = (x) => Math.min(Math.max(x, -1), 1);

export class Viewer {
  /// onMouse(): a desktop mouse button was pressed on the stage (D45).
  constructor({ stage, video, cursor, dragBadge, send, canInput, onMouse = () => {} }) {
    this.stage = stage;
    this.video = video;
    this.cursorEl = cursor;
    this.dragBadge = dragBadge;
    this.send = send;
    this.canInput = canInput;
    this.onMouse = onMouse;
    this.mouseMode = false; // the last pointer on the stage was a mouse (D45)
    this.mouseHeld = null; // the button name a desktop mouse holds on the Mac
    this.pendingPoint = null;
    this.size = null; // {width, height}: the video's intrinsic size, while a frame is shown
    this.scale = 1; // CSS px per video px
    this.tx = 0;
    this.ty = 0;
    this.gestures = new GestureRecognizer();
    this.longPressTimer = null;
    this.nextSeq = 1; // never reset, so a late confirmation cannot match a newer move
    this.resetCursor();

    stage.addEventListener('touchstart', (e) => this.onTouch(e, 'start'), { passive: false });
    stage.addEventListener('touchmove', (e) => this.onTouch(e, 'move'), { passive: false });
    stage.addEventListener('touchend', (e) => this.onTouch(e, 'end'), { passive: false });
    stage.addEventListener('touchcancel', (e) => this.onTouch(e, 'cancel'), { passive: false });
    // D45: a desktop mouse. Touch stays on the touch handlers above.
    stage.addEventListener('pointerdown', (e) => this.onPointer(e));
    stage.addEventListener('pointermove', (e) => this.onPointer(e));
    stage.addEventListener('mousedown', (e) => this.onMouseButton(e, true));
    window.addEventListener('mouseup', (e) => this.onMouseButton(e, false));
    stage.addEventListener('wheel', (e) => this.onWheel(e), { passive: false });
    stage.addEventListener('contextmenu', (e) => e.preventDefault());
    video.addEventListener('resize', () => this.onVideoSize());
    video.addEventListener('loadedmetadata', () => this.onVideoSize());
    window.addEventListener('resize', () => this.relayout());
    if (window.visualViewport) window.visualViewport.addEventListener('resize', () => this.relayout());
  }

  // ---------- video ----------

  /// The first frame after `clear()`, or a window resize on the Mac (D21: the encoder
  /// follows the capture size and the video's intrinsic size changes).
  onVideoSize() {
    const width = this.video.videoWidth;
    const height = this.video.videoHeight;
    if (!width || !height || this.waitingForFrame) return;
    const hadFrame = !!this.size;
    if (hadFrame && this.size.width === width && this.size.height === height) return;
    const zoom = hadFrame ? this.scale / this.fitScale() : 1;
    this.size = { width, height };
    this.video.style.width = `${width}px`;
    this.video.style.height = `${height}px`;
    this.video.classList.remove('waiting');
    if (!hadFrame || this.fitAtNextSize) this.fit();
    else { this.scale = this.fitScale() * zoom; this.clampAndApply(); }
    this.fitAtNextSize = false;
  }

  /// The Mac resized the window (D35): fit now, and fit again when the new size arrives.
  fitResized() {
    this.fitAtNextSize = true;
    this.fit();
  }

  /// Leaving the viewer or switching windows: forget the image, the cursor, and any drag.
  /// The track keeps playing; the video stays invisible until the next window's first frame.
  /// It is made transparent rather than hidden, so `requestVideoFrameCallback` still fires.
  clear() {
    this.size = null;
    this.video.classList.add('waiting');
    this.setDimmed(false);
    this.resetCursor();
    this.endInput();
    this.waitingForFrame = true;
    this.frameToken = null;
    this.fitAtNextSize = false;
  }

  /// The Mac started streaming the selected window: show the next frame that arrives, so a
  /// late frame of the previous window is never shown as this one.
  awaitFirstFrame() {
    const token = (this.frameToken = {});
    const shown = () => {
      if (this.frameToken !== token) return;
      this.waitingForFrame = false;
      this.onVideoSize();
    };
    if (this.video.requestVideoFrameCallback) this.video.requestVideoFrameCallback(shown);
    else shown();
  }

  /// The socket or peer connection closed: the Mac releases a held button by itself (D26), and
  /// the next session sends its own cursor, so the old one is forgotten.
  endInput() {
    this.cursorBase = null;
    this.cursorEl.hidden = true;
    this.gestures.releaseDragLock();
    this.gestures.touchCancel();
    clearTimeout(this.longPressTimer);
    this.dragBadge.hidden = true;
    this.pendingMove = null;
    this.pendingScroll = null;
    this.pendingPoint = null;
    this.mouseHeld = null;
    this.sentMoves = [];
  }

  setDimmed(on) {
    this.stage.parentElement.classList.toggle('dimmed', on);
  }

  // ---------- transform ----------

  fitScale() {
    if (!this.size) return 1;
    const w = this.stage.clientWidth;
    const h = this.stage.clientHeight;
    return Math.min(w / this.size.width, h / this.size.height);
  }

  fit() {
    this.scale = this.fitScale();
    this.clampAndApply();
  }

  /// The stage size changes in change() (the key panel, D34): keep the zoom relative to fit.
  keepZoom(change) {
    const zoom = this.size ? this.scale / this.fitScale() : 1;
    change();
    if (!this.size) return;
    this.scale = this.fitScale() * zoom;
    this.clampAndApply();
  }

  relayout() {
    if (!this.size) return;
    this.scale = Math.max(this.scale, this.fitScale());
    this.clampAndApply();
  }

  clampAndApply() {
    if (!this.size) return;
    const fit = this.fitScale();
    this.scale = Math.min(Math.max(this.scale, fit), fit * MAX_ZOOM);
    const sw = this.stage.clientWidth;
    const sh = this.stage.clientHeight;
    const iw = this.size.width * this.scale;
    const ih = this.size.height * this.scale;
    this.tx = iw <= sw ? (sw - iw) / 2 : Math.min(0, Math.max(sw - iw, this.tx));
    this.ty = ih <= sh ? (sh - ih) / 2 : Math.min(0, Math.max(sh - ih, this.ty));
    this.video.style.transform = `translate(${this.tx}px, ${this.ty}px) scale(${this.scale})`;
    this.placeCursor();
  }

  stagePoints(touchList) {
    const r = this.stage.getBoundingClientRect();
    return [...touchList].map((t) => ({ id: t.identifier, x: t.clientX - r.left, y: t.clientY - r.top }));
  }

  // ---------- gestures (D23) ----------

  onTouch(e, phase) {
    e.preventDefault();
    this.mouseMode = false;
    const now = performance.now();
    const touches = this.stagePoints(e.touches);
    let intents;
    switch (phase) {
      case 'start':
        intents = this.gestures.touchStart(touches, now);
        clearTimeout(this.longPressTimer);
        if (touches.length === 1) {
          this.longPressTimer = setTimeout(() => this.handle(this.gestures.tick(performance.now())), LONG_PRESS_MS + 5);
        }
        break;
      case 'move':
        intents = this.gestures.touchMove(touches, now);
        break;
      case 'end':
        intents = this.gestures.touchEnd(touches, now);
        if (touches.length === 0) clearTimeout(this.longPressTimer);
        break;
      default:
        this.gestures.touchCancel();
        clearTimeout(this.longPressTimer);
        intents = [];
    }
    this.handle(intents);
  }

  handle(intents) {
    for (const i of intents) {
      switch (i.type) {
        case 'move': this.queueMove(i.dx, i.dy); break;
        case 'scroll': this.queueScroll(i.dx, i.dy); break;
        case 'click': this.sendInput({ t: 'click' }); break;
        case 'rightClick': this.sendInput({ t: 'rightClick' }); break;
        case 'dragStart':
          if (!this.size || !this.canInput()) { this.gestures.releaseDragLock(); break; }
          if (navigator.vibrate) navigator.vibrate(15);
          this.dragBadge.hidden = false;
          this.sendInput({ t: 'drag', state: 'start' });
          break;
        case 'dragEnd':
          this.dragBadge.hidden = true;
          this.sendInput({ t: 'drag', state: 'end' });
          break;
        case 'zoom': this.zoomBy(i); break;
        case 'pan':
          this.tx += i.dx;
          this.ty += i.dy;
          this.clampAndApply();
          break;
      }
    }
  }

  sendInput(msg) {
    if (!this.size || !this.canInput()) return;
    this.flushMotion();
    this.send(msg);
  }

  /// Pinch: zoom by the distance change around the midpoint, and follow the midpoint.
  zoomBy({ factor, x, y, dx, dy }) {
    if (!this.size) return;
    const ix = (x - dx - this.tx) / this.scale;
    const iy = (y - dy - this.ty) / this.scale;
    const fit = this.fitScale();
    this.scale = Math.min(Math.max(this.scale * factor, fit), fit * MAX_ZOOM);
    this.tx = x - ix * this.scale;
    this.ty = y - iy * this.scale;
    this.clampAndApply();
  }

  // ---------- desktop mouse (D45) ----------

  /// Where the video is on the stage, for stageToWindow.
  videoRect() {
    return { tx: this.tx, ty: this.ty, scale: this.scale, width: this.size.width, height: this.size.height };
  }

  /// A mouse event → window-normalized (u, v), or null outside the video. While a button is
  /// held the point is clamped to the edge, so a drag continues.
  mousePoint(e) {
    if (!this.size) return null;
    const r = this.stage.getBoundingClientRect();
    return stageToWindow(e.clientX - r.left, e.clientY - r.top, this.videoRect(), this.mouseHeld !== null);
  }

  /// Mouse movement: the Mac cursor goes to the point under the mouse, at most once per frame.
  onPointer(e) {
    if (e.pointerType !== 'mouse') return;
    if (!this.mouseMode) {
      this.mouseMode = true;
      this.placeCursor();
    }
    if (e.type === 'pointerdown') this.stage.setPointerCapture?.(e.pointerId);
    if (!this.canInput()) return;
    const p = this.mousePoint(e);
    if (!p) return;
    const first = !this.pendingPoint;
    this.pendingPoint = p;
    if (first) requestAnimationFrame(() => this.flushMotion());
  }

  /// Buttons use mouse events: their `detail` is the click count the Mac needs for a
  /// double-click. Only one button is held at a time.
  onMouseButton(e, down) {
    if (!this.mouseMode) return;
    const button = mouseButtonName(e.button);
    if (down) {
      e.preventDefault(); // no text selection or focus change; the key sink keeps focus
      this.onMouse();
    }
    if (!button || !this.size || !this.canInput()) return;
    if (down ? this.mouseHeld !== null : this.mouseHeld !== button) return;
    const p = this.mousePoint(e);
    if (!p) return;
    this.pendingPoint = null;
    this.flushMotion();
    const msg = { t: 'mouse', button, state: down ? 'down' : 'up', clicks: clickCount(e.detail), seq: this.nextSeq++, u: p.u, v: p.v };
    if (this.send(msg)) this.mouseHeld = down ? button : null;
  }

  /// The wheel scrolls the Mac window like the two-finger scroll (D26). Ctrl+wheel (a laptop
  /// trackpad pinch) is swallowed so the page does not zoom.
  onWheel(e) {
    e.preventDefault();
    if (e.ctrlKey || !this.size) return;
    const { dx, dy } = wheelPixels(e, this.stage.clientHeight);
    this.queueScroll(dx, dy);
  }

  // ---------- relative cursor (D24) ----------

  resetCursor() {
    this.cursorBase = null; // {u, v, seq} as confirmed by the Mac
    this.sentMoves = []; // [{seq, dx, dy}] sent after cursorBase.seq
    this.pendingMove = null;
    this.pendingScroll = null;
    this.cursorEl.hidden = true;
  }

  /// Size of the window on screen, in CSS px at the current zoom (D24).
  contentCss() {
    return { w: this.size.width * this.scale, h: this.size.height * this.scale };
  }

  /// At most one `move` per animation frame, carrying the sum since the last send.
  queueMove(dx, dy) {
    if (!this.size || !this.canInput() || !this.cursorBase) return;
    const size = this.contentCss();
    const du = dx * SENSITIVITY / size.w;
    const dv = dy * SENSITIVITY / size.h;
    if (this.pendingMove) { this.pendingMove.dx += du; this.pendingMove.dy += dv; return; }
    this.pendingMove = { dx: du, dy: dv };
    requestAnimationFrame(() => this.flushMotion());
  }

  /// Scroll deltas are normalized like moves, without the sensitivity factor (D26).
  queueScroll(dx, dy) {
    if (!this.size || !this.canInput()) return;
    const size = this.contentCss();
    if (this.pendingScroll) { this.pendingScroll.du += dx / size.w; this.pendingScroll.dv += dy / size.h; return; }
    this.pendingScroll = { du: dx / size.w, dv: dy / size.h };
    requestAnimationFrame(() => this.flushMotion());
  }

  flushMotion() {
    const m = this.pendingMove;
    const s = this.pendingScroll;
    const p = this.pendingPoint;
    this.pendingMove = null;
    this.pendingScroll = null;
    this.pendingPoint = null;
    if (p && this.size && this.canInput()) this.send({ t: 'point', seq: this.nextSeq++, u: p.u, v: p.v });
    if (m && this.cursorBase) {
      const move = { seq: this.nextSeq++, dx: clamp1(m.dx), dy: clamp1(m.dy) };
      if (this.send({ t: 'move', ...move })) {
        this.sentMoves.push(move);
        this.placeCursor();
      }
    }
    if (s) this.send({ t: 'scroll', du: clamp1(s.du), dv: clamp1(s.dv) });
  }

  /// The Mac's confirmed cursor: re-base the prediction on it (D24).
  onCursor({ u, v, seq }) {
    this.cursorBase = { u, v, seq };
    this.sentMoves = this.sentMoves.filter((m) => m.seq > seq);
    this.placeCursor();
  }

  predictedCursor() {
    let { u, v } = this.cursorBase;
    for (const m of this.sentMoves) { u = clamp01(u + m.dx); v = clamp01(v + m.dy); }
    return { u, v };
  }

  /// The arrow is the phone's pointer; a desktop mouse shows its own cursor (D45).
  placeCursor() {
    if (!this.cursorBase || !this.size || this.mouseMode) { this.cursorEl.hidden = true; return; }
    const { u, v } = this.predictedCursor();
    const x = this.tx + u * this.size.width * this.scale;
    const y = this.ty + v * this.size.height * this.scale;
    this.cursorEl.style.transform = `translate(${x}px, ${y}px)`;
    this.cursorEl.hidden = false;
  }
}
