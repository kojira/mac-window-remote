// State machine, socket, and video link (DESIGN.md D16, D18, D22, D27, D32, D33, §3, §4).
import { Viewer } from './viewer.js';
import { VideoLink } from './rtc.js';
import { TextInput } from './input.js';
import { DesktopKeyboard } from './desktop.js';
import { SlotBar } from './slotbar.js';
import { decodeViewSwitched } from './slots.js';
import { ModifierState } from './modifiers.js';
import { KeyPanel } from './keypanel.js';
import { MenuSheet, decodeMenu } from './appmenu.js';
import { FileSheet, startDownload } from './files.js';
import { APP_OPEN_TIMEOUT_MS, LIST_TAB_KEY, decodeApps, parseListTab, renderAppGrid } from './apps.js';
import {
  decodeDisplays, displayTarget, isDisplay, renderDisplayList, viewStartMessage, viewStateMatches, viewerControls,
} from './displays.js';
import { MacClipboard } from './macclip.js';
import { AUDIO_KEY, AudioMode, AudioOutput, audioAriaLabel, audioButtonLabel } from './audio.js';
import { MicControl, micAriaLabel } from './mic.js';
import {
  CLIPBOARD_MODES, FILE_MAX_BYTES, IMAGE_MAX_BYTES, clipboardMessage, fileChunkMessages, imageChunkMessages,
  readClipboardForMac, shortPath,
} from './upload.js';

/// The viewed window {id, app, title} (D33: slots store the app and title too), or a display
/// {id, app, title, display: true} (D56).
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
  if (name !== 'viewer') { keyPanel.close(); textInput.blur(); closePasteSheet(); menuSheet.close(); fileSheet.close(); desktopKeys.blur(); }
  renderFitWindow();
}

function setConnDots(state) {
  for (const d of document.querySelectorAll('[data-conn]')) {
    d.classList.toggle('on', state === 'on');
    d.classList.toggle('wait', state === 'wait');
  }
}

let toastTimer = null;
/// A sticky toast (upload progress) stays until the next toast replaces it.
export function toast(text, { sticky = false } = {}) {
  const t = $('toast');
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  if (!sticky) toastTimer = setTimeout(() => { t.hidden = true; }, 3000);
}

function listMessage(text) {
  const m = $('list-message');
  m.textContent = text || '';
  m.hidden = !text;
}

function renderWindows(items) {
  const ul = $('windows');
  ul.textContent = '';
  if (!permissions.screenRecording || listTab !== 'windows') return;
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
  if (listTab === 'apps') {
    send({ t: 'apps.list' });
    return;
  }
  if (!permissions.screenRecording) {
    $('windows').textContent = '';
    $('displays').textContent = '';
    listMessage('Screen Recording permission is missing on the Mac. Open the Mac menu bar app → Setup.');
    return;
  }
  send({ t: listTab === 'displays' ? 'displays.list' : 'windows.list' });
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
/// `w` is a window or a display target (D56).
function openWindow(w) {
  enterViewer(w);
  send(viewStartMessage(w));
  refreshSlots();
}

/// Shows the viewer for window `w` {id, app, title} or a display target (D56); the caller or
/// the Mac starts the view.
function enterViewer(w) {
  const stored = { id: w.id, app: w.app, title: w.title };
  if (isDisplay(w)) stored.display = true;
  sessionStorage.setItem(WINDOW_KEY, JSON.stringify(stored));
  viewer.clear();
  show('viewer');
  focusKeySink();
  slotBar.render();
  renderFitWindow();
  viewMessage('');
}

// ---------- Windows | Apps (D40) ----------

let listTab = parseListTab(sessionStorage.getItem(LIST_TAB_KEY));
/// The app being opened {id, name, timer}, or null.
let appOpening = null;

function setListTab(tab) {
  listTab = tab;
  sessionStorage.setItem(LIST_TAB_KEY, tab);
  for (const b of document.querySelectorAll('#list-tabs [data-tab]')) {
    b.setAttribute('aria-selected', String(b.dataset.tab === tab));
  }
  $('windows').hidden = tab !== 'windows';
  $('apps').hidden = tab !== 'apps';
  $('displays').hidden = tab !== 'displays';
  if (tab !== 'windows') $('windows').textContent = '';
  if (tab !== 'apps') $('apps').textContent = '';
  if (tab !== 'displays') $('displays').textContent = '';
  listMessage('');
  clearAppOpening();
  if (screen === 'list') refreshList();
}

for (const b of document.querySelectorAll('#list-tabs [data-tab]')) {
  b.addEventListener('click', () => { if (b.dataset.tab !== listTab) setListTab(b.dataset.tab); });
}

function renderApps(msg) {
  if (listTab !== 'apps') return;
  const apps = decodeApps(msg);
  renderAppGrid($('apps'), apps, openApp);
  listMessage(apps.length === 0 ? 'No apps in the Dock.' : '');
}

// ---------- Displays (D56) ----------

function onDisplays(msg) {
  const displays = decodeDisplays(msg);
  slotBar.setDisplays(displays);
  if (screen !== 'list' || listTab !== 'displays' || !permissions.screenRecording) return;
  renderDisplayList($('displays'), displays, (d) => openWindow(displayTarget(d)));
  listMessage(displays.length === 0 ? 'No displays found.' : '');
}

/// The Mac launches or activates the app and answers `view.switched` for its front window, or
/// an error (D40).
function openApp(a) {
  if (!send({ t: 'app.open', id: a.id })) { toast('Not connected to the Mac'); return; }
  clearAppOpening();
  const timer = setTimeout(() => {
    if (appOpening?.id !== a.id) return;
    clearAppOpening();
    toast(`${a.name} has no window`);
  }, APP_OPEN_TIMEOUT_MS);
  appOpening = { id: a.id, name: a.name, timer };
  const o = $('app-opening');
  o.textContent = `Opening ${a.name}…`;
  o.hidden = false;
}

function clearAppOpening() {
  if (appOpening) clearTimeout(appOpening.timer);
  appOpening = null;
  $('app-opening').hidden = true;
}

/// An `error` for the pending `app.open`; true if it was one.
function onAppOpenError(msg) {
  if (!['app_no_window', 'app_not_found', 'app_launch_failed'].includes(msg.code)) return false;
  if (!appOpening || msg.id !== appOpening.id) return true;
  const name = appOpening.name;
  clearAppOpening();
  if (msg.code === 'app_no_window') toast(`${name} has no window`);
  else if (msg.code === 'app_not_found') { toast(`${name} is no longer available`); refreshList(); }
  else toast(`Could not open ${name}`);
  return true;
}

/// The Mac switched the view to the window that ⌘Tab or ⌘F1 brought forward (D38). Its `view.state`
/// for the new id follows, so this only makes that window the viewed one.
function onViewSwitched(msg) {
  const w = decodeViewSwitched(msg);
  if (w && screen === 'list') {
    // D40: the app opened from the Apps tab has a window; the Mac already views it.
    if (appOpening) {
      clearAppOpening();
      enterViewer(w);
      refreshSlots();
    } else {
      send({ t: 'view.stop' });
    }
    return;
  }
  if (!w || screen !== 'viewer' || w.id === viewingWindowId()) return;
  menuSheet.close();
  sessionStorage.setItem(WINDOW_KEY, JSON.stringify(w));
  viewer.clear();
  slotBar.render();
  renderFitWindow();
  viewMessage('');
  refreshSlots();
}

// ---------- fit the Mac window to the phone (D35) ----------

/// windowId → true while the Mac window is fitted; in memory only.
const fittedWindows = new Map();

function renderFitWindow() {
  // D56: a display has no app menu and no window to fit.
  const controls = viewerControls(viewingTarget());
  $('app-menu').hidden = !controls.appMenu;
  $('fit-window').hidden = !controls.fitWindow;
  const b = $('fit-window');
  const on = fittedWindows.get(viewingWindowId()) === true;
  b.classList.toggle('active', on);
  b.setAttribute('aria-pressed', String(on));
  b.setAttribute('aria-label', on ? 'Restore window size' : 'Fit window to phone');
}

$('fit-window').addEventListener('click', () => {
  const id = viewingWindowId();
  if (id == null) return;
  if (fittedWindows.get(id)) {
    link.send({ t: 'window.restore' });
    return;
  }
  // The visible video area: above the bottom bar and the key panel, inside the safe area.
  const stage = $('stage');
  if (!stage.clientWidth || !stage.clientHeight) return;
  link.send({ t: 'window.fitPhone', aspect: stage.clientWidth / stage.clientHeight });
});

function onWindowFit(msg) {
  if (!Number.isInteger(msg.windowId)) return;
  if (msg.state === 'fitted') fittedWindows.set(msg.windowId, true);
  else fittedWindows.delete(msg.windowId);
  if (msg.windowId !== viewingWindowId()) return;
  renderFitWindow();
  viewer.fitResized();
  if (msg.clamped) toast(msg.state === 'fitted' ? 'The app limits this window\'s size' : 'The app limited the restored size');
}

/// The viewed window or display (D56), or null.
function viewingTarget() {
  try {
    const w = JSON.parse(sessionStorage.getItem(WINDOW_KEY));
    return w && Number.isInteger(w.id) ? w : null;
  } catch { return null; }
}

/// The viewed window {id, app, title}, or null (also while a display is viewed).
function viewingWindow() {
  const t = viewingTarget();
  return isDisplay(t) ? null : t;
}

function viewingWindowId() {
  return viewingWindow()?.id ?? null;
}

// ---------- Mac audio on the iPhone (D39) ----------

const audioMode = new AudioMode(localStorage.getItem(AUDIO_KEY));
const audioOutput = new AudioOutput($('audio'));
audioOutput.onChange = renderAudio;

function renderAudio() {
  const b = $('audio-mode');
  const mode = audioMode.mode;
  const label = audioButtonLabel(mode);
  b.querySelector('.icon').textContent = label.icon;
  b.querySelector('.mode').textContent = label.text;
  b.classList.toggle('on', mode !== 'off');
  b.classList.toggle('blocked', audioOutput.blocked(mode));
  b.setAttribute('aria-label', audioAriaLabel(mode) + (audioOutput.blocked(mode) ? ' (tap to enable sound)' : ''));
}

/// Plays or pauses the <audio> element for the current mode. Inside a tap this also unlocks it.
function applyAudioOutput() {
  if (audioMode.mode === 'off') audioOutput.pause(); else audioOutput.play();
  renderAudio();
}

function storeAudioMode() {
  localStorage.setItem(AUDIO_KEY, audioMode.mode);
}

$('audio-mode').addEventListener('click', () => {
  // A tap while the sound is blocked only enables it; otherwise it cycles the mode.
  if (!audioOutput.blocked(audioMode.mode)) {
    audioMode.cycle();
    storeAudioMode();
    if (!link.send({ t: 'audio', mode: audioMode.mode })) audioMode.unsent();
  }
  applyAudioOutput();
});

// While audio is on but iOS has not let it play (after a reload, or a play() refused after a
// reconnect), the next touch anywhere starts it: touchend is a user gesture.
function unlockAudioOnTouch() {
  const unlock = () => {
    if (audioOutput.blocked(audioMode.mode)) audioOutput.play();
  };
  document.addEventListener('touchend', unlock, true);
  document.addEventListener('click', unlock, true);
}

/// A new peer connection is ready: its audio track goes to the element, and the Mac gets the
/// mode again (it does not keep it).
function onAudioReady(track) {
  audioOutput.setTrack(track);
  if (audioMode.mode !== 'off') audioOutput.play();
  renderAudio();
}

function onAudioState(msg) {
  if (audioMode.onState(msg)) {
    storeAudioMode();
    applyAudioOutput();
  }
}

// ---------- this device's microphone on the Mac (D57) ----------

const mic = new MicControl({
  getUserMedia: navigator.mediaDevices?.getUserMedia ? (c) => navigator.mediaDevices.getUserMedia(c) : null,
  setTrack: (track) => link.setMicTrack(track),
  send: (msg) => link.send(msg),
  toast,
  onChange: renderMic,
});

function renderMic() {
  const b = $('mic');
  b.classList.toggle('on', mic.state === 'on');
  b.classList.toggle('starting', mic.state === 'starting');
  b.setAttribute('aria-pressed', String(mic.on));
  b.setAttribute('aria-label', micAriaLabel(mic.state));
  // iOS keeps recording only in a play-and-record session.
  audioOutput.sessionType = mic.on ? 'play-and-record' : 'playback';
  if (navigator.audioSession) {
    try { navigator.audioSession.type = audioOutput.sessionType; } catch { /* older Safari */ }
  }
}

$('mic').addEventListener('click', () => mic.toggle());

// ---------- quick-switch slots (D33) ----------

/// A fresh window list re-resolves the slots; its reply requests the thumbnails. A display in
/// a slot (D56) needs the display list, whose thumbnails come with it.
function refreshSlots() {
  if (screen !== 'viewer') return;
  send({ t: 'windows.list' });
  if (slotBar.hasDisplaySlot()) send({ t: 'displays.list' });
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
  if (screen === null || screen === 'denied') show(viewingTarget() ? 'viewer' : 'list');
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
    abandonUploads();
    clearAppOpening();
    onClosed(ev.code);
  };
}

/// The socket closed: no reply will come for requests sent on it. An image that is still
/// waiting for the connection (after the camera hid the page) keeps waiting.
function abandonUploads() {
  if (imageUpload?.sending) { imageUpload.cancelled = true; imageUpload = null; }
  if (pendingUploads.size > 0) toast('Upload interrupted — try again');
  pendingUploads.clear();
}

function closeSocket() {
  clearTimeout(deadTimer);
  link.close();
  abandonUploads();
  clearAppOpening();
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
      if (!(screen === 'viewer' && viewingTarget() != null)) show('list');
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
    case 'apps':
      renderApps(msg);
      break;
    case 'displays':
      onDisplays(msg);
      break;
    case 'view.state':
      onViewState(msg);
      break;
    case 'view.switched':
      onViewSwitched(msg);
      break;
    case 'result':
      onUploadReply(msg);
      break;
    case 'menu':
      onMenu(msg);
      break;
    case 'menu.pressed':
      pendingMenuPresses.delete(msg.id);
      break;
    case 'files':
      fileSheet.onFiles(msg);
      break;
    case 'files.found':
      fileSheet.onFound(msg);
      break;
    case 'download.ready':
      fileSheet.onReady(msg);
      break;
    case 'clipboard.mac':
      macClipboard.onMessage(msg);
      break;
    case 'error':
      if (msg.id != null && pendingUploads.has(msg.id)) onUploadReply(msg);
      else if (fileSheet.onError(msg)) break;
      else if (onMenuError(msg)) break;
      else if (!onAppOpenError(msg)) onError(msg);
      break;
    case 'ping':
      break;
  }
}

/// The peer connection is connected and `control` is open: resume the viewer or the list.
function onVideoReady() {
  if (!link.send({ t: 'audio', mode: audioMode.resend() })) audioMode.unsent();
  mic.onReady();
  if (screen === 'viewer' && viewingTarget() != null) {
    viewer.clear();
    viewer.setDimmed(false);
    viewMessage(permissions.screenRecording ? ''
      : 'Screen Recording permission is missing on the Mac. Open the Mac menu bar app → Setup.');
    send(viewStartMessage(viewingTarget()));
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
    case 'window.fit':
      onWindowFit(msg);
      break;
    case 'audio.state':
      onAudioState(msg);
      break;
    case 'mic.state':
      mic.onState(msg);
      break;
    case 'error':
      onError(msg);
      break;
  }
}

function onViewState(msg) {
  const target = viewingTarget();
  if (screen !== 'viewer' || !viewStateMatches(msg, target)) return;
  switch (msg.state) {
    case 'starting':
      break;
    case 'streaming':
      viewMessage('');
      viewer.setDimmed(false);
      viewer.awaitFirstFrame();
      break;
    case 'window_gone':
      // D56: a disconnected display ends the view the same way as a closed window.
      showList();
      toast(isDisplay(target) ? 'Display disconnected' : 'Window closed');
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
    case 'audio_unavailable':
    case 'permission_audio_capture':
      toast(msg.message || 'No audio from the Mac');
      return;
    case 'window_not_fitted':
      // The Mac no longer has the original frame (e.g. it restarted): forget ours too.
      fittedWindows.delete(viewingWindowId());
      renderFitWindow();
      toast(msg.message || 'Window size was already restored');
      return;
    default:
      toast(msg.message || msg.code);
  }
}

// ---------- ☰ the viewed app's menu bar (D43) ----------

/// Pressed menu items waiting for `menu.pressed` or an error: id → title.
const pendingMenuPresses = new Map();

$('app-menu').addEventListener('click', () => {
  const w = viewingWindow();
  if (screen !== 'viewer' || !w) return;
  keyPanel.close();
  menuSheet.open(w.app);
  if (!send({ t: 'menu.list' })) menuSheet.showError('Not connected to the Mac');
});

function onMenu(msg) {
  const menu = decodeMenu(msg);
  if (!menu || menu.windowId !== viewingWindowId()) return;
  menuSheet.setMenu(menu);
}

function pressMenuItem(item, gen) {
  if (!send({ t: 'menu.press', id: item.id, gen })) { toast('Not connected to the Mac'); return; }
  pendingMenuPresses.set(item.id, item.title);
}

/// An error for `menu.list` (while the sheet is open) or a pending `menu.press`; true if it was.
function onMenuError(msg) {
  if (msg.id != null && pendingMenuPresses.has(msg.id)) {
    const title = pendingMenuPresses.get(msg.id);
    pendingMenuPresses.delete(msg.id);
    toast(`Couldn't run ${title}`);
    return true;
  }
  if (msg.id == null && menuSheet.isOpen
      && ['menu_unavailable', 'permission_accessibility', 'window_not_found'].includes(msg.code)) {
    menuSheet.showError(msg.message || "This app's menu can't be read");
    return true;
  }
  return false;
}

// ---------- paste the iPhone clipboard or an image into the window (D36) ----------

/// Upload/paste requests waiting for the Mac's `result` or `error`: id → {kind, chars}.
const pendingUploads = new Map();
let uploadCounter = 0;
/// The image upload in progress, or null; a newer pick cancels it.
let imageUpload = null;
/// While sending an image, at most this much waits in the socket's send buffer, so the
/// socket's pong answers the Mac's 10 s ping in time even on a slow link.
const UPLOAD_BUFFER_BYTES = 512 << 10;
/// Taking a photo can hide the page and reconnect; the picked image waits this long for it.
const UPLOAD_CONNECT_WAIT_MS = 10000;
const PROGRESS_POLL_MS = 50;

function nextUploadId(prefix) {
  uploadCounter += 1;
  return `${prefix}${uploadCounter}`;
}

/// A binary WebSocket message; false if the socket is not ready.
function sendBinary(bytes) {
  if (!socket || !authed || socket.readyState !== WebSocket.OPEN) return false;
  socket.send(bytes);
  return true;
}

function canUpload() {
  if (screen !== 'viewer' || viewingTarget() == null) { toast('Open a window first'); return false; }
  if (!socket || !authed || socket.readyState !== WebSocket.OPEN) { toast('Not connected to the Mac'); return false; }
  return true;
}

/// 📋 Paste (D36) and 📋 Copy to Mac (D52): the clipboard read runs inside the tap.
function clipboardToMac(mode) {
  if (!canUpload()) return;
  readClipboardForMac({ clipboard: navigator.clipboard ?? null, mode, sendText: sendClipboardText, openSheet: openPasteSheet, toast });
}

/// Returns true if the text was sent.
function sendClipboardText(text, mode) {
  if (!canUpload()) return false;
  const id = nextUploadId('c');
  const message = clipboardMessage(id, text, mode);
  if (!message) {
    toast(text ? 'Text too large (max 1 MiB)' : 'Nothing to paste');
    return false;
  }
  pendingUploads.set(id, { kind: 'clipboard', mode, chars: [...text].length });
  if (!sendBinary(message)) { pendingUploads.delete(id); toast('Not connected to the Mac'); return false; }
  return true;
}

/// The fallback sheet's mode ('paste' or 'copy') while it is open.
let pasteSheetMode = 'paste';

function openPasteSheet(mode) {
  pasteSheetMode = mode;
  $('paste-sheet-action').textContent = CLIPBOARD_MODES[mode].sheetText;
  $('paste-send').textContent = CLIPBOARD_MODES[mode].sheetButton;
  const sheet = $('paste-sheet');
  $('paste-text').value = '';
  sheet.hidden = false;
  $('paste-text').focus();
}

function closePasteSheet() {
  $('paste-sheet').hidden = true;
  $('paste-text').blur();
}

$('paste-send').addEventListener('click', () => {
  const text = $('paste-text').value;
  if (!text) { toast('Long-press the box and choose Paste'); return; }
  if (sendClipboardText(text, pasteSheetMode)) closePasteSheet();
});
$('paste-cancel').addEventListener('click', closePasteSheet);

/// 🖼: the file picker (photo library, camera, Files) must open inside the tap.
function pickImage() {
  if (!canUpload()) return;
  const input = $('image-file');
  input.value = '';
  input.click();
}

$('image-file').addEventListener('change', () => {
  const file = $('image-file').files?.[0];
  if (file) uploadImage(file);
});

/// 📎 (D42): any file, no accept filter, so iOS offers Files, Photo Library, and Take Photo.
/// Like 🖼, the picker must open inside the tap.
function pickFile() {
  if (!canUpload()) return;
  const input = $('any-file');
  input.value = '';
  input.click();
}

$('any-file').addEventListener('change', () => {
  const file = $('any-file').files?.[0];
  if (file) uploadImage(file, { asFile: true });
});

/// Sends an image (D36) or, with asFile, any file under its own name (D42). Both share the
/// chunked upload, the progress toast, and "a newer pick cancels the older one".
async function uploadImage(file, { asFile = false } = {}) {
  const what = asFile ? 'File' : 'Image';
  if (file.size > (asFile ? FILE_MAX_BYTES : IMAGE_MAX_BYTES)) { toast(`${what} too large (max ${asFile ? 100 : 25} MiB)`); return; }
  if (file.size === 0) { toast(`The ${what.toLowerCase()} is empty`); return; }
  if (imageUpload) imageUpload.cancelled = true;
  const upload = { cancelled: false };
  imageUpload = upload;
  let bytes;
  try { bytes = new Uint8Array(await file.arrayBuffer()); } catch { toast(`Could not read the ${what.toLowerCase()}`); return; }
  // The page may have been hidden (camera) and be reconnecting: wait until viewing resumes.
  // `view.start` goes out when the video link is ready, and the Mac handles it before chunks.
  const deadline = performance.now() + UPLOAD_CONNECT_WAIT_MS;
  while (!(authed && link.canSend()) && performance.now() < deadline && !upload.cancelled) {
    await new Promise((r) => setTimeout(r, 200));
  }
  if (upload.cancelled) return;
  const ws = socket;
  if (!canUpload()) { imageUpload = null; return; }
  const id = nextUploadId(asFile ? 'f' : 'i');
  upload.sending = true;
  pendingUploads.set(id, { kind: asFile ? 'file' : 'image' });
  const showProgress = bytes.length > 2 * UPLOAD_BUFFER_BYTES;
  const progress = (sent) => {
    if (showProgress) toast(`Uploading… ${Math.max(0, Math.floor((sent / bytes.length) * 100))}%`, { sticky: true });
  };
  progress(0);
  for (const chunk of (asFile ? fileChunkMessages(id, file.name, bytes) : imageChunkMessages(id, bytes))) {
    // Keep the send buffer small, so input and pings are never stuck behind the image.
    while (ws === socket && ws.readyState === WebSocket.OPEN && ws.bufferedAmount > UPLOAD_BUFFER_BYTES && !upload.cancelled) {
      progress(chunk.offset - ws.bufferedAmount);
      await new Promise((r) => setTimeout(r, PROGRESS_POLL_MS));
    }
    if (upload.cancelled) { pendingUploads.delete(id); return; }
    if (ws !== socket || !sendBinary(chunk.data)) {
      pendingUploads.delete(id);
      imageUpload = null;
      toast('Upload interrupted — try again');
      return;
    }
  }
  while (ws === socket && ws.readyState === WebSocket.OPEN && ws.bufferedAmount > 0 && !upload.cancelled) {
    progress(bytes.length - ws.bufferedAmount);
    await new Promise((r) => setTimeout(r, PROGRESS_POLL_MS));
  }
  if (showProgress && !upload.cancelled && pendingUploads.has(id)) toast('Pasting…', { sticky: true });
  if (imageUpload === upload) imageUpload = null;
}

/// `result` or `error` for a clipboard, image, or file request (D36, D42).
function onUploadReply(msg) {
  const pending = pendingUploads.get(msg.id);
  if (!pending) return;
  pendingUploads.delete(msg.id);
  if (msg.t === 'result') {
    if (pending.kind === 'image' || pending.kind === 'file') toast(`Pasted path: ${shortPath(msg.path || '')}`);
    else toast(CLIPBOARD_MODES[pending.mode].done(pending.chars));
    return;
  }
  switch (msg.code) {
    case 'too_large':
      toast({ image: 'Image too large (max 25 MiB)', file: 'File too large (max 100 MiB)' }[pending.kind] ?? 'Text too large (max 1 MiB)');
      break;
    case 'unsupported_type':
      toast('Not a supported image (PNG, JPEG, HEIC, GIF, WebP)');
      break;
    case 'window_not_found':
      toast('Open a window first');
      break;
    default:
      toast(msg.message || msg.code);
  }
}

// Capture stops when nobody is watching (D15): close when hidden, reconnect when visible.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    // D57: the connection closes (D15), so the microphone is released too.
    mic.stop(false);
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
  onAudioTrack: onAudioReady,
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
  onMouse: () => { mouseUsed = true; textInput.blur(); focusKeySink(); },
});
$('fit').addEventListener('click', () => viewer.fit());

const slotBar = new SlotBar({
  container: $('slots'),
  menu: $('slot-menu'),
  current: () => (screen === 'viewer' ? viewingTarget() : null),
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
  onAction: (action) => ({ paste: () => clipboardToMac('paste'), copy: () => clipboardToMac('copy'), image: pickImage, file: pickFile, download: openFiles }[action]?.()),
});

// Text copied on the Mac goes to this device's clipboard (D51).
const macClipboard = new MacClipboard({
  root: $('mac-clip'),
  label: $('mac-clip-copy'),
  close: $('mac-clip-close'),
  clipboard: navigator.clipboard ?? null,
  toast,
});

const menuSheet = new MenuSheet({ root: $('menu-sheet'), onPress: pressMenuItem });

// ⬇︎ Download (D47): browse and search the Mac's files, then save the selection.
const fileSheet = new FileSheet({ root: $('files-sheet'), send, download: startDownload });

function openFiles() {
  keyPanel.close();
  textInput.blur();
  fileSheet.open();
}

// ---------- desktop keyboard (D45) ----------

/// A mouse was pressed on the stage; with a fine pointer, this is a desktop browser.
let mouseUsed = false;
const finePointer = window.matchMedia?.('(pointer: fine)');
const isDesktop = () => mouseUsed || !!finePointer?.matches;

/// Physical keys go to the Mac while the viewer is shown and no sheet, menu, or text field is
/// in use. The iPhone never gets here: its pointer is coarse and it sends no mouse events.
const desktopKeys = new DesktopKeyboard({
  sink: $('key-sink'),
  isActive: () => screen === 'viewer' && isDesktop() && $('paste-sheet').hidden && $('menu-sheet').hidden && $('files-sheet').hidden
    && $('slot-menu').hidden && !keyPanel.isMenuOpen() && !textInput.isFocused(),
  send: sendInput,
});

function focusKeySink() {
  if (desktopKeys.isActive()) desktopKeys.focus();
}

// A click on a bottom-bar or panel button gives focus back to the key sink, so an IME keeps
// composing there.
$('viewer').addEventListener('click', (e) => {
  if (e.target.closest?.('#stage, #text')) return;
  setTimeout(focusKeySink, 0);
});

setListTab(listTab);
// Earlier versions paired with a stored secret; it is no longer used.
localStorage.removeItem('mwr.secret');
renderAudio();
renderMic();
unlockAudioOnTouch();
connect();
