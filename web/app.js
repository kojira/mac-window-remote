// State machine, socket, and video link (DESIGN.md D16, D18, D22, D27, D32, D33, §3, §4).
import { Viewer } from './viewer.js';
import { VideoLink } from './rtc.js';
import { TextInput } from './input.js';
import { SlotBar } from './slotbar.js';
import { ModifierState } from './modifiers.js';
import { KeyPanel } from './keypanel.js';

/// The viewed window {id, app, title} (D33: slots store the app and title too).
const WINDOW_KEY = 'mwr.window';
/// While the viewer is visible, the window list and slot thumbnails refresh this often (D33).
const THUMBS_REFRESH_MS = 10000;
const BACKOFF_MS = [500, 1000, 2000, 5000];
const DEAD_AFTER_MS = 15000;

const $ = (id) => document.getElementById(id);
const screens = { denied: $('denied'), list: $('list'), viewer: $('viewer') };

let socket = null;
let authed = false;
let permissions = { screenRecording: true, accessibility: true };
let backoffIndex = 0;
let reconnectTimer = null;
let deadTimer = null;
let replaced = false;
let screen = null;
let viewOverlay = ''; // what the Mac reported for the view; the video link's state goes on top

const VIDEO_FAILED = 'Could not connect video over the tailnet. Check that Tailscale is on for both devices.';

// ---------- access (D32) ----------

// The Mac admits only its owner's Tailscale login; it closes other connections with 4001.
let denied = false;

function showDenied() {
  denied = true;
  closeSocket();
  show('denied');
}

$('denied-retry').addEventListener('click', () => {
  denied = false;
  backoffIndex = 0;
  connect();
});

// ---------- screens ----------

function show(name) {
  screen = name;
  for (const [k, el] of Object.entries(screens)) el.hidden = k !== name;
  if (name !== 'viewer') { keyPanel.close(); textInput.blur(); }
}

function setConnDots(state) {
  for (const d of document.querySelectorAll('[data-conn]')) {
    d.classList.toggle('on', state === 'on');
    d.classList.toggle('wait', state === 'wait');
  }
}

let toastTimer = null;
export function toast(text) {
  const t = $('toast');
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 3000);
}

function listMessage(text) {
  const m = $('list-message');
  m.textContent = text || '';
  m.hidden = !text;
}

function renderWindows(items) {
  const ul = $('windows');
  ul.textContent = '';
  if (!permissions.screenRecording) return;
  if (items.length === 0) {
    listMessage('No windows on screen (minimized windows and other Spaces are not shown).');
    return;
  }
  listMessage('');
  for (const w of items) {
    const li = document.createElement('li');
    const app = document.createElement('div');
    app.className = 'app';
    app.textContent = w.app;
    const title = document.createElement('div');
    title.className = 'wtitle';
    title.textContent = w.title || '(untitled)';
    li.append(app, title);
    li.addEventListener('click', () => openWindow(w));
    ul.append(li);
  }
}

function showList() {
  sessionStorage.removeItem(WINDOW_KEY);
  slotBar.closeMenu();
  slotBar.render();
  viewer.clear();
  show('list');
  refreshList();
}

function refreshList() {
  if (!permissions.screenRecording) {
    $('windows').textContent = '';
    listMessage('Screen Recording permission is missing on the Mac. Open the Mac menu bar app → Setup.');
    return;
  }
  send({ t: 'windows.list' });
}

$('refresh').addEventListener('click', () => {
  if (link.status === 'failed') link.retry(); else refreshList();
});
$('retry').addEventListener('click', () => link.retry());
$('back').addEventListener('click', () => {
  send({ t: 'view.stop' });
  showList();
});

/// From the list, or a quick-switch slot while viewing (D33): the peer connection stays.
function openWindow(w) {
  sessionStorage.setItem(WINDOW_KEY, JSON.stringify({ id: w.id, app: w.app, title: w.title }));
  viewer.clear();
  show('viewer');
  slotBar.render();
  viewMessage('');
  send({ t: 'view.start', windowId: w.id });
  refreshSlots();
}

/// The viewed window {id, app, title}, or null.
function viewingWindow() {
  try {
    const w = JSON.parse(sessionStorage.getItem(WINDOW_KEY));
    return w && Number.isInteger(w.id) ? w : null;
  } catch { return null; }
}

function viewingWindowId() {
  return viewingWindow()?.id ?? null;
}

// ---------- quick-switch slots (D33) ----------

/// A fresh window list re-resolves the slots; its reply requests the thumbnails.
function refreshSlots() {
  if (screen === 'viewer') send({ t: 'windows.list' });
}

function requestThumbs() {
  const ids = slotBar.windowIds();
  if (screen === 'viewer' && ids.length > 0) send({ t: 'thumbs.request', windowIds: ids });
}

setInterval(() => { if (!document.hidden) refreshSlots(); }, THUMBS_REFRESH_MS);

function overlay(text, { retry = false } = {}) {
  $('viewer-overlay-text').textContent = text || '';
  $('retry').hidden = !retry;
  $('viewer-overlay').hidden = !text;
}

/// The viewer overlay: the video link state first (D27), then the view state (D18).
function viewMessage(text) {
  viewOverlay = text || '';
  showVideoStatus(link.status);
}

function showVideoStatus(status) {
  if (screen === 'list') {
    if (status === 'failed') listMessage(VIDEO_FAILED + ' Tap Refresh to retry.');
    else if (status !== 'connected') listMessage('Connecting…');
    return;
  }
  if (screen !== 'viewer') return;
  switch (status) {
    case 'connecting': overlay('Connecting video…'); break;
    case 'reconnecting': overlay('Reconnecting…'); break;
    case 'failed': overlay(VIDEO_FAILED, { retry: true }); break;
    default: overlay(viewOverlay);
  }
}

// ---------- socket ----------

function wsURL() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${proto}//${location.host}/ws`;
}

function connect() {
  clearTimeout(reconnectTimer);
  if (document.hidden) return;
  closeSocket();
  replaced = false;
  authed = false;
  setConnDots('wait');
  if (screen === null || screen === 'denied') show(viewingWindowId() ? 'viewer' : 'list');
  const ws = new WebSocket(wsURL());
  socket = ws;
  ws.onopen = () => armDeadTimer();
  ws.onmessage = (ev) => {
    if (ws !== socket) return;
    armDeadTimer();
    if (typeof ev.data !== 'string') return;
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    onMessage(msg);
  };
  ws.onclose = (ev) => {
    if (ws !== socket) return;
    socket = null;
    authed = false;
    clearTimeout(deadTimer);
    setConnDots('off');
    link.close();
    viewer.endInput();
    onClosed(ev.code);
  };
}

function closeSocket() {
  clearTimeout(deadTimer);
  link.close();
  if (socket) {
    const s = socket;
    socket = null;
    try { s.close(); } catch { /* already closed */ }
  }
}

function armDeadTimer() {
  clearTimeout(deadTimer);
  deadTimer = setTimeout(() => {
    // 15 s of silence: treat the connection as dead (D18).
    const s = socket;
    closeSocket();
    if (s) onClosed(0);
  }, DEAD_AFTER_MS);
}

function onClosed(code) {
  if (code === 4001) {
    showDenied();
    return;
  }
  if (code === 4002) {
    replaced = true;
    showReplaced();
    return;
  }
  if (document.hidden) return;
  if (screen === 'viewer') {
    viewer.setDimmed(true);
    overlay('Reconnecting…');
  } else if (screen === 'list') {
    listMessage('Reconnecting…');
  }
  const delay = BACKOFF_MS[Math.min(backoffIndex, BACKOFF_MS.length - 1)];
  backoffIndex++;
  reconnectTimer = setTimeout(connect, delay);
}

function showReplaced() {
  const text = 'Opened on another device/tab';
  if (screen === 'viewer') {
    viewer.setDimmed(true);
    overlay(text);
  } else {
    show('list');
    $('windows').textContent = '';
    listMessage(text);
  }
}

/// A WebSocket message: auth, window list, viewing, and signaling (D22).
export function send(msg) {
  if (!socket || !authed || socket.readyState !== WebSocket.OPEN) return false;
  socket.send(JSON.stringify(msg));
  return true;
}

function onMessage(msg) {
  switch (msg.t) {
    case 'hello':
      authed = true;
      backoffIndex = 0;
      permissions = msg.permissions || permissions;
      setConnDots('on');
      if (!(screen === 'viewer' && viewingWindowId() != null)) show('list');
      // Video and input need the peer connection; the list and viewing continue once it is
      // connected (D22 step 5).
      link.start();
      break;
    case 'rtc.answer':
    case 'rtc.ice':
      link.onSignal(msg);
      break;
    case 'windows':
      renderWindows(msg.items || []);
      slotBar.setWindows(msg.items || []);
      requestThumbs();
      break;
    case 'thumb':
      slotBar.onThumb(msg);
      break;
    case 'view.state':
      onViewState(msg);
      break;
    case 'error':
      onError(msg);
      break;
    case 'ping':
      break;
  }
}

/// The peer connection is connected and `control` is open: resume the viewer or the list.
function onVideoReady() {
  if (screen === 'viewer' && viewingWindowId() != null) {
    viewer.clear();
    viewer.setDimmed(false);
    viewMessage(permissions.screenRecording ? ''
      : 'Screen Recording permission is missing on the Mac. Open the Mac menu bar app → Setup.');
    send({ t: 'view.start', windowId: viewingWindowId() });
    refreshSlots();
  } else {
    show('list');
    listMessage('');
    refreshList();
  }
}

/// Messages from the Mac on the `control` data channel (D22, D28).
function onControl(msg) {
  switch (msg.t) {
    case 'cursor':
      viewer.onCursor(msg);
      break;
    case 'error':
      onError(msg);
      break;
  }
}

function onViewState(msg) {
  if (screen !== 'viewer' || msg.windowId !== viewingWindowId()) return;
  switch (msg.state) {
    case 'starting':
      break;
    case 'streaming':
      viewMessage('');
      viewer.setDimmed(false);
      viewer.awaitFirstFrame();
      break;
    case 'window_gone':
      showList();
      toast('Window closed');
      break;
    case 'capture_unavailable':
      viewer.setDimmed(true);
      viewMessage(msg.reason === 'permission_screen_recording'
        ? 'Screen Recording permission is missing on the Mac. Open the Mac menu bar app → Setup.'
        : 'Mac screen unavailable (locked or asleep?) — retrying');
      break;
  }
}

function onError(msg) {
  switch (msg.code) {
    case 'permission_accessibility':
      toast('Mac needs Accessibility permission to control windows.');
      return;
    case 'permission_screen_recording':
      permissions.screenRecording = false;
      if (screen === 'list') refreshList();
      return;
    case 'rtc_failed':
      link.fail();
      return;
    default:
      toast(msg.message || msg.code);
  }
}

// Capture stops when nobody is watching (D15): close when hidden, reconnect when visible.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    clearTimeout(reconnectTimer);
    closeSocket();
    setConnDots('off');
  } else if (!replaced && !denied) {
    if (screen === 'viewer') {
      viewer.setDimmed(true);
      overlay('Reconnecting…');
    }
    backoffIndex = 0;
    connect();
  }
});

// ---------- wiring ----------

const link = new VideoLink({
  video: $('video'),
  signal: send,
  onStatus: showVideoStatus,
  onReady: onVideoReady,
  onControl,
});

/// Input messages go on the data channels (D22).
const sendInput = (msg) => link.send(msg);

const viewer = new Viewer({
  stage: $('stage'),
  video: $('video'),
  cursor: $('cursor'),
  dragBadge: $('drag-badge'),
  send: sendInput,
  canInput: () => screen === 'viewer' && authed && link.canSend(),
});
$('fit').addEventListener('click', () => viewer.fit());

const slotBar = new SlotBar({
  container: $('slots'),
  menu: $('slot-menu'),
  current: () => (screen === 'viewer' ? viewingWindow() : null),
  onSwitch: (w) => openWindow(w),
  onChange: requestThumbs,
});

const modifiers = new ModifierState();

const textInput = new TextInput({
  field: $('text'),
  bar: $('bottom-bar'),
  dock: $('dock'),
  modifiers,
  send: sendInput,
});

const keyPanel = new KeyPanel({
  panel: $('key-panel'),
  toggle: $('keyboard'),
  viewerEl: $('viewer'),
  modifiers,
  textInput,
  sendKey: (key, mods) => sendInput({ t: 'key', key, mods }),
  onLayout: (change) => viewer.keepZoom(change),
});

// Earlier versions paired with a stored secret; it is no longer used.
localStorage.removeItem('mwr.secret');
connect();
