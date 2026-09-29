// Quick-switch slots: storage, resolution against the window list, and `thumb` decoding
// (DESIGN.md D33). Pure functions, no DOM.

export const SLOT_COUNT = 3;
export const SLOTS_KEY = 'mwr.slots';

const isSlot = (s) => !!s && Number.isInteger(s.windowId) && typeof s.app === 'string' && typeof s.title === 'string';

/// Slots from their stored JSON; anything unreadable is an empty slot.
export function parseSlots(json) {
  let stored;
  try { stored = JSON.parse(json); } catch { stored = null; }
  const slots = [];
  for (let i = 0; i < SLOT_COUNT; i++) {
    const s = Array.isArray(stored) ? stored[i] : null;
    slots.push(isSlot(s) ? { windowId: s.windowId, app: s.app, title: s.title } : null);
  }
  return slots;
}

/// Finds a slot's window in the latest window list (D33 rules 1–4).
/// Returns {state: 'empty'} | {state: 'window', window} | {state: 'unavailable'}.
/// Before the first list (`windows` null) an assigned slot is used as stored.
export function resolveSlot(slot, windows) {
  if (!slot) return { state: 'empty' };
  if (!windows) return { state: 'window', window: { id: slot.windowId, app: slot.app, title: slot.title } };
  const byId = windows.find((w) => w.id === slot.windowId);
  if (byId) return { state: 'window', window: byId };
  const sameApp = windows.filter((w) => w.app === slot.app);
  const byTitle = sameApp.find((w) => w.title === slot.title);
  if (byTitle) return { state: 'window', window: byTitle };
  if (sameApp.length === 1) return { state: 'window', window: sameApp[0] };
  return { state: 'unavailable' };
}

/// A `thumb` message as {windowId, src}: `src` is a data URL, or null for the missing marker.
/// Returns null for a malformed message.
export function decodeThumb(msg) {
  if (!msg || !Number.isInteger(msg.windowId)) return null;
  if (typeof msg.jpeg === 'string' && msg.jpeg.length > 0) {
    return { windowId: msg.windowId, src: `data:image/jpeg;base64,${msg.jpeg}` };
  }
  if (msg.missing === true) return { windowId: msg.windowId, src: null };
  return null;
}

/// A `view.switched` message (D38) as the viewed window {id, app, title}, or null if malformed.
export function decodeViewSwitched(msg) {
  if (!msg || !Number.isInteger(msg.windowId)) return null;
  return {
    id: msg.windowId,
    app: typeof msg.app === 'string' ? msg.app : '',
    title: typeof msg.title === 'string' ? msg.title : '',
  };
}
