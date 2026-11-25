// Unit tests for the Terminal text view (DESIGN.md D67): 📄 visibility, toggle on/off, font
// prefs, size clamp, auto-scroll, Copy all, touches on the layer, ⌘C kept local while text is
// selected, and switching windows turning it off. A small fake DOM stands in for the browser.
// Run: node --test tests/web
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

class FakeElement {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.parent = null;
    this.listeners = {};
    this.attrs = {};
    this.style = {};
    this.hidden = false;
    this.disabled = false;
    this.value = '';
    this.label = '';
    this.className = '';
    this.scrollTop = 0;
    this.scrollHeight = 0;
    this.clientHeight = 0;
  }
  set textContent(v) { for (const c of this.children) c.parent = null; this.children = []; this.label = v; }
  get textContent() { return this.label || this.children.map((c) => c.textContent).join(''); }
  setAttribute(k, v) { this.attrs[k] = v; }
  append(...els) { for (const c of els) { c.parent = this; this.children.push(c); } }
  contains(el) { for (let e = el; e; e = e.parent) if (e === this) return true; return false; }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  dispatch(type, extra = {}) {
    const e = { type, target: this, preventDefault() {}, ...extra };
    for (let el = this; el; el = el.parent) for (const fn of el.listeners[type] ?? []) fn(e);
  }
  click() { this.dispatch('click'); }
}

const store = new Map();
const storage = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)) };
globalThis.document = { createElement: (tag) => new FakeElement(tag) };

const {
  TerminalView, TERM_FONT_KEY, TERM_SIZE_KEY, clampTermSize, fontCss, isAtBottom, isCopyShortcut, parseTermFont, termErrorText,
} = await import('../../web/termview.js');
const { viewerControls, displayTarget } = await import('../../web/displays.js');
const { DesktopKeyboard } = await import('../../web/desktop.js');

function setup({ sendOk = true, clipboard = null, fallbackCopy = () => false, selection = null } = {}) {
  const root = new FakeElement('div');
  const sent = [];
  const toasts = [];
  let exits = 0;
  const sel = { current: selection };
  const view = new TerminalView({
    root, storage, clipboard, fallbackCopy,
    send: (m) => { sent.push(m); return sendOk; },
    toast: (t) => toasts.push(t),
    onExit: () => { exits += 1; },
    getSelection: () => sel.current,
  });
  return { root, view, sent, toasts, sel, exits: () => exits };
}

/// The <pre> scrolled so that it is `fromBottom` px above its end.
function scrollPre(pre, { height = 1000, client = 200, fromBottom = 0 } = {}) {
  pre.scrollHeight = height;
  pre.clientHeight = client;
  pre.scrollTop = height - client - fromBottom;
}

test('📄 is offered only for a window the Mac marked termText, never for a display', () => {
  assert.equal(viewerControls({ id: 7, app: 'Terminal', title: 'zsh' }, { termText: true }).termText, true);
  assert.equal(viewerControls({ id: 7, app: 'Terminal', title: 'zsh' }).termText, false);
  assert.equal(viewerControls({ id: 7, app: 'Terminal', title: 'zsh' }, { termText: false }).termText, false);
  assert.equal(viewerControls(displayTarget({ id: 2, name: 'S' }), { termText: true }).termText, false);
  const html = readFileSync(new URL('../../web/index.html', import.meta.url), 'utf8');
  assert.match(html, /<button id="term-toggle" type="button" aria-label="Text view" title="Text view" aria-pressed="false" hidden>📄<\/button>/);
  const css = readFileSync(new URL('../../web/style.css', import.meta.url), 'utf8');
  assert.match(css, /#bottom-bar\.typing[^{]*#term-toggle \{ display: none; \}/);
  const app = readFileSync(new URL('../../web/app.js', import.meta.url), 'utf8');
  assert.match(app, /termTextWindowId = msg\.termText === true && msg\.windowId === id \? id : null;/);
});

test('the toggle opens with term.start and closes with term.stop; the layer hides', () => {
  const { root, view, sent } = setup();
  assert.equal(root.hidden, true);
  assert.equal(view.isOpen(), false);
  view.open(7);
  assert.equal(root.hidden, false);
  assert.deepEqual(sent, [{ t: 'term.start', windowId: 7 }]);
  assert.equal(view.pre.textContent, 'Loading…');
  view.close();
  assert.equal(root.hidden, true);
  assert.deepEqual(sent.at(-1), { t: 'term.stop' });
  view.close();
  assert.equal(sent.length, 2, 'closing twice sends one stop');
});

test('text for the open window is shown; stale revs and other windows are ignored', () => {
  const { view } = setup();
  view.open(7);
  view.onText({ t: 'term.text', windowId: 7, text: '$ ls\nfile\n', rev: 2 });
  assert.equal(view.pre.textContent, '$ ls\nfile\n');
  view.onText({ t: 'term.text', windowId: 7, text: 'old', rev: 1 });
  view.onText({ t: 'term.text', windowId: 8, text: 'other', rev: 9 });
  assert.equal(view.pre.textContent, '$ ls\nfile\n');
  view.restart(); // a new Mac session counts from 1 again
  view.onText({ t: 'term.text', windowId: 7, text: 'again', rev: 1 });
  assert.equal(view.pre.textContent, 'again');
});

test('font family and size persist, apply to the text, and the size is clamped to 10–28', () => {
  store.clear();
  let { view } = setup();
  assert.equal(view.font, 'menlo');
  assert.equal(view.size, 13);
  view.setFont('sf');
  view.setSize(40);
  assert.equal(store.get(TERM_FONT_KEY), 'sf');
  assert.equal(store.get(TERM_SIZE_KEY), '28');
  assert.equal(view.pre.style.fontFamily, fontCss('sf'));
  assert.equal(view.pre.style.fontSize, '28px');
  assert.equal(view.larger.disabled, true);
  ({ view } = setup());
  assert.equal(view.font, 'sf', 'remembered');
  assert.equal(view.size, 28);
  assert.equal(view.fontSelect.value, 'sf');
  for (let i = 0; i < 30; i++) view.smaller.click();
  assert.equal(view.size, 10);
  assert.equal(view.smaller.disabled, true);
  view.larger.click();
  assert.equal(view.size, 11);
  assert.equal(store.get(TERM_SIZE_KEY), '11');
  view.fontSelect.value = 'courier';
  view.fontSelect.dispatch('change');
  assert.equal(store.get(TERM_FONT_KEY), 'courier');
  assert.deepEqual(view.fontSelect.children.map((o) => o.textContent), ['Menlo', 'SF Mono', 'Courier', 'Monospace']);
  assert.equal(clampTermSize('9'), 10);
  assert.equal(clampTermSize('abc'), 13);
  assert.equal(clampTermSize(16.4), 16);
  assert.equal(parseTermFont('comic'), 'menlo');
  assert.match(fontCss('sf'), /ui-monospace/);
  store.clear();
});

test('auto-scroll: at the bottom (within 40 px) it follows; scrolled up it stays and shows ⇣ New output', () => {
  const { view } = setup();
  view.open(7);
  view.onText({ windowId: 7, text: 'a', rev: 1 });
  // The first text starts at the bottom.
  assert.equal(view.newOutput.hidden, true);
  scrollPre(view.pre, { fromBottom: 30 });
  view.onText({ windowId: 7, text: 'ab', rev: 2 });
  assert.equal(view.pre.scrollTop, view.pre.scrollHeight, 'followed to the end');
  assert.equal(view.newOutput.hidden, true);
  scrollPre(view.pre, { fromBottom: 300 });
  const kept = view.pre.scrollTop;
  view.onText({ windowId: 7, text: 'abc', rev: 3 });
  assert.equal(view.pre.scrollTop, kept, 'the reading position is kept');
  assert.equal(view.newOutput.hidden, false);
  view.newOutput.click();
  assert.equal(view.pre.scrollTop, view.pre.scrollHeight);
  assert.equal(view.newOutput.hidden, true);
  scrollPre(view.pre, { fromBottom: 300 });
  view.bottomButton.click();
  assert.equal(view.pre.scrollTop, view.pre.scrollHeight, '⇣ jumps to the bottom');
  assert.equal(isAtBottom({ scrollHeight: 1000, scrollTop: 760, clientHeight: 200 }), true);
  assert.equal(isAtBottom({ scrollHeight: 1000, scrollTop: 759, clientHeight: 200 }), false);
});

test('new text waits while text is selected in the layer, then shows', () => {
  const { view, sel } = setup();
  view.open(7);
  view.onText({ windowId: 7, text: 'one', rev: 1 });
  const textNode = new FakeElement('#text');
  view.pre.append(textNode);
  sel.current = { isCollapsed: false, rangeCount: 1, anchorNode: textNode };
  assert.equal(view.hasSelection(), true);
  view.onText({ windowId: 7, text: 'two', rev: 2 });
  assert.equal(view.text, 'one', 'the selection is not destroyed');
  assert.equal(view.newOutput.hidden, false);
  sel.current = { isCollapsed: true, rangeCount: 1, anchorNode: textNode };
  view.onSelectionChange();
  assert.equal(view.pre.textContent, 'two');
  // A selection elsewhere on the page does not count.
  sel.current = { isCollapsed: false, rangeCount: 1, anchorNode: new FakeElement('p') };
  assert.equal(view.hasSelection(), false);
});

test('Copy all writes the whole text, falls back to execCommand, and says when there is nothing', async () => {
  const written = [];
  let { view, toasts } = setup({ clipboard: { writeText: (t) => { written.push(t); return Promise.resolve(); } } });
  await view.copyAll();
  assert.deepEqual(toasts, ['Nothing to copy yet']);
  view.open(7);
  view.onText({ windowId: 7, text: '$ ls\nfile', rev: 1 });
  await view.copyButton.dispatch('click');
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(written, ['$ ls\nfile']);
  assert.equal(toasts.at(-1), 'Copied');
  const fallback = [];
  ({ view, toasts } = setup({ clipboard: { writeText: () => Promise.reject(new Error('no')) }, fallbackCopy: (t) => { fallback.push(t); return true; } }));
  view.open(7);
  view.onText({ windowId: 7, text: 'x', rev: 1 });
  await view.copyAll();
  assert.deepEqual(fallback, ['x']);
  assert.deepEqual(toasts, ['Copied']);
});

test('errors show a message and a button back to the video', () => {
  const { view, exits } = setup();
  view.open(7);
  view.onError({ t: 'term.error', windowId: 7, code: 'ax_denied' });
  assert.equal(view.errorBox.hidden, false);
  assert.equal(view.pre.hidden, true);
  assert.equal(view.errorText.textContent, termErrorText('ax_denied'));
  view.errorBox.children[1].click();
  assert.equal(exits(), 1);
  assert.match(termErrorText('not_terminal'), /Terminal windows/);
  assert.match(termErrorText('no_text'), /no readable text/);
  assert.match(termErrorText('ax_denied'), /Accessibility/);
  const offline = setup({ sendOk: false });
  offline.view.open(7);
  assert.equal(offline.view.errorText.textContent, 'Not connected to the Mac');
});

test('the layer is outside the stage, so its touches and clicks never reach the Mac', () => {
  const html = readFileSync(new URL('../../web/index.html', import.meta.url), 'utf8');
  // A sibling right after the stage, not inside it: the stage's touch/mouse handlers do not see it.
  assert.match(html, /<div id="stage">[^\n]*<\/div>\n\s*<div id="term-view" hidden><\/div>/);
  const css = readFileSync(new URL('../../web/style.css', import.meta.url), 'utf8');
  const rule = css.match(/\.term-text \{[^}]*\}/)[0];
  for (const p of ['user-select: text', 'white-space: pre-wrap', 'overflow-wrap: anywhere', 'touch-action: auto', 'overflow: auto']) {
    assert.ok(rule.includes(p), p);
  }
  // A layer event dispatched to it bubbles through the layer, never the stage.
  const { root, view } = setup();
  const stage = new FakeElement('div');
  let stageEvents = 0;
  for (const t of ['touchstart', 'touchend', 'mousedown', 'click']) stage.addEventListener(t, () => { stageEvents += 1; });
  const viewer = new FakeElement('section');
  viewer.append(stage, root);
  view.open(7);
  for (const t of ['touchstart', 'touchend', 'mousedown', 'click']) view.pre.dispatch(t);
  assert.equal(stageEvents, 0);
  const app = readFileSync(new URL('../../web/app.js', import.meta.url), 'utf8');
  assert.match(app, /e\.target\.closest\?\.\('#stage, #text, \.term-text, \.term-font'\)/, 'a click in the text keeps its selection');
});

test('⌘C / Ctrl+C with text selected in the layer stays local; other keys still go to the Mac', () => {
  const sent = [];
  let selected = true;
  globalThis.window ??= { addEventListener() {} };
  const kb = new DesktopKeyboard({
    sink: null, isActive: () => true, send: (m) => sent.push(m),
    keepLocal: (e) => isCopyShortcut(e) && selected,
  });
  let prevented = 0;
  const key = (code, k, mods = {}) => ({ code, key: k, metaKey: false, ctrlKey: false, altKey: false, shiftKey: false,
    preventDefault: () => { prevented += 1; }, ...mods });
  kb.onKeyDown(key('KeyC', 'c', { metaKey: true }));
  kb.onKeyDown(key('KeyC', 'c', { ctrlKey: true }));
  assert.deepEqual(sent, []);
  assert.equal(prevented, 0, 'the browser copies the selection');
  kb.onKeyDown(key('KeyV', 'v', { metaKey: true }));
  kb.onKeyDown(key('KeyA', 'a'));
  assert.deepEqual(sent, [{ t: 'key', key: 'v', mods: ['cmd'] }, { t: 'text', text: 'a' }]);
  selected = false;
  kb.onKeyDown(key('KeyC', 'c', { metaKey: true }));
  assert.deepEqual(sent.at(-1), { t: 'key', key: 'c', mods: ['cmd'] }, 'without a selection ⌘C goes to the Mac');
  assert.equal(isCopyShortcut(key('KeyC', 'c', { metaKey: true, altKey: true })), false);
  const app = readFileSync(new URL('../../web/app.js', import.meta.url), 'utf8');
  assert.match(app, /keepLocal: \(e\) => isCopyShortcut\(e\) && termView\.hasSelection\(\),/);
});

test('switching windows, leaving the viewer, or a non-terminal streaming turns the text view off', () => {
  const app = readFileSync(new URL('../../web/app.js', import.meta.url), 'utf8');
  const body = (name) => app.slice(app.indexOf(`function ${name}(`), app.indexOf('\n}\n', app.indexOf(`function ${name}(`)));
  for (const f of ['enterViewer', 'onViewSwitched', 'showList']) assert.match(body(f), /closeTermView\(\);/, f);
  assert.match(body('closeTermView'), /termTextWindowId = null;\n\s*termView\.close\(\);/);
  assert.match(body('onTermOffer'), /if \(termTextWindowId === null\) termView\.close\(\);\n\s*else termView\.restart\(\);/);
  // The text view state is not stored: it lasts for this page session only.
  assert.doesNotMatch(app, /sessionStorage\.setItem\([^)]*term/i);
});
