// State machine and socket (DESIGN.md D6, D16, D18, §3, §4).
import { Viewer } from './viewer.js';
import { TextInput } from './input.js';

const SECRET_KEY = 'mwr.secret';
const WINDOW_KEY = 'mwr.windowId';
const TITLE_KEY = 'mwr.windowTitle';
const BACKOFF_MS = [500, 1000, 2000, 5000];
const DEAD_AFTER_MS = 15000;

const $ = (id) => document.getElementById(id);
const screens = { pair: $('pair'), list: $('list'), viewer: $('viewer') };

let socket = null;
let authed = false;
let permissions = { screenRecording: true, accessibility: true };
let backoffIndex = 0;
let reconnectTimer = null;
let deadTimer = null;
let replaced = false;
let screen = null;

// ---------- pairing ----------

function takePairingFragment() {
  const m = location.hash.match(/(?:^#|&)pair=([^&]+)/);
  if (!m) return;
  localStorage.setItem(SECRET_KEY, decodeURIComponent(m[1]));
  history.replaceState(null, '', location.pathname + location.search);
}

function secret() { return localStorage.getItem(SECRET_KEY); }

function showPair(errorText) {
  closeSocket();
  show('pair');
  const err = $('pair-error');
  err.textContent = errorText || '';
  err.hidden = !errorText;
}

$('pair-form').addEventListener('submit', (e) => {
  e.preventDefault();
  const code = $('pair-code').value.trim();
  if (!code) return;
  localStorage.setItem(SECRET_KEY, code);
  $('pair-code').value = '';
  $('pair-code').blur();
  connect();
});

// ---------- screens ----------

function show(name) {
  screen = name;
  for (const [k, el] of Object.entries(screens)) el.hidden = k !== name;
  if (name !== 'viewer') textInput.blur();
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
    li.addEventListener('click', () => openWindow(w.id, `${w.app} — ${w.title || '(untitled)'}`));
    ul.append(li);
  }
}

function showList() {
  sessionStorage.removeItem(WINDOW_KEY);
  sessionStorage.removeItem(TITLE_KEY);
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

$('refresh').addEventListener('click', refreshList);
$('back').addEventListener('click', () => {
  send({ t: 'view.stop' });
  showList();
});

function openWindow(id, title) {
  sessionStorage.setItem(WINDOW_KEY, String(id));
  sessionStorage.setItem(TITLE_KEY, title);
  $('viewer-title').textContent = title;
  viewer.clear();
  show('viewer');
  viewer.showBar();
  overlay('');
  send({ t: 'view.start', windowId: id });
}

function viewingWindowId() {
  const v = sessionStorage.getItem(WINDOW_KEY);
  return v ? Number(v) : null;
}

function overlay(text) {
  const o = $('viewer-overlay');
  o.textContent = text || '';
  o.hidden = !text;
}

// ---------- socket ----------

function wsURL() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${proto}//${location.host}/ws`;
}

function connect() {
  clearTimeout(reconnectTimer);
  if (!secret()) { showPair(); return; }
  if (document.hidden) return;
  closeSocket();
  replaced = false;
  authed = false;
  setConnDots('wait');
  if (screen === null || screen === 'pair') show(viewingWindowId() ? 'viewer' : 'list');
  if (screen === 'viewer') {
    $('viewer-title').textContent = sessionStorage.getItem(TITLE_KEY) || '';
  }
  const ws = new WebSocket(wsURL());
  ws.binaryType = 'arraybuffer';
  socket = ws;
  ws.onopen = () => {
    ws.send(JSON.stringify({ t: 'auth', secret: secret(), client: 'web/0.1' }));
    armDeadTimer();
  };
  ws.onmessage = (ev) => {
    if (ws !== socket) return;
    armDeadTimer();
    if (typeof ev.data === 'string') {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      onMessage(msg);
    } else {
      viewer.onFrame(ev.data);
    }
  };
  ws.onclose = (ev) => {
    if (ws !== socket) return;
    socket = null;
    authed = false;
    clearTimeout(deadTimer);
    setConnDots('off');
    viewer.endInput();
    onClosed(ev.code);
  };
}

function closeSocket() {
  clearTimeout(deadTimer);
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
    localStorage.removeItem(SECRET_KEY);
    showPair('Pairing code was rejected. Pair again from the Mac menu.');
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
      if (screen === 'viewer' && viewingWindowId() != null) {
        overlay('');
        viewer.setDimmed(false);
        if (!permissions.screenRecording) {
          overlay('Screen Recording permission is missing on the Mac. Open the Mac menu bar app → Setup.');
        }
        send({ t: 'view.start', windowId: viewingWindowId() });
      } else {
        show('list');
        listMessage('');
        refreshList();
      }
      break;
    case 'windows':
      renderWindows(msg.items || []);
      break;
    case 'view.state':
      onViewState(msg);
      break;
    case 'error':
      onError(msg);
      break;
    case 'cursor':
      viewer.onCursor(msg);
      break;
    case 'ping':
      break;
  }
}

function onViewState(msg) {
  if (screen !== 'viewer' || msg.windowId !== viewingWindowId()) return;
  switch (msg.state) {
    case 'starting':
      break;
    case 'streaming':
      overlay('');
      viewer.setDimmed(false);
      break;
    case 'window_gone':
      showList();
      toast('Window closed');
      break;
    case 'capture_unavailable':
      viewer.setDimmed(true);
      overlay(msg.reason === 'permission_screen_recording'
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
    default:
      toast(msg.message || msg.code);
  }
}

// Frames stop when nobody is watching (D15): close when hidden, reconnect when visible.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    clearTimeout(reconnectTimer);
    closeSocket();
    setConnDots('off');
  } else if (!replaced && secret()) {
    if (screen === 'viewer') {
      viewer.setDimmed(true);
      overlay('Reconnecting…');
    }
    backoffIndex = 0;
    connect();
  }
});

// ---------- wiring ----------

const viewer = new Viewer({
  stage: $('stage'),
  canvas: $('canvas'),
  cursor: $('cursor'),
  dragBadge: $('drag-badge'),
  bar: $('viewer-bar'),
  send,
  canInput: () => screen === 'viewer' && authed,
});
$('fit').addEventListener('click', () => viewer.fit());

const textInput = new TextInput({
  field: $('text'),
  button: $('keyboard'),
  bar: $('bottom-bar'),
  send,
});

takePairingFragment();
if (secret()) connect(); else showPair();
