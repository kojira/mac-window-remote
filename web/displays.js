// Display mode (DESIGN.md D56): the Displays tab, the viewed target (a window or a display),
// and what the viewer hides for a display. Pure functions plus the list's DOM.

/// A viewed display as a target {id, app, title, display: true}; `app` and `title` let the
/// slots and the bottom bar treat it like a window (D33).
export function displayTarget(d) {
  return { id: d.id, app: 'Display', title: d.name, display: true };
}

export const isDisplay = (target) => !!target && target.display === true;

/// The same window or the same display (their ids can be equal).
export function sameTarget(a, b) {
  return !!a && !!b && a.id === b.id && isDisplay(a) === isDisplay(b);
}

/// `view.start` for a target.
export function viewStartMessage(target) {
  return isDisplay(target) ? { t: 'view.start', displayId: target.id } : { t: 'view.start', windowId: target.id };
}

/// A `view.state` is about this target.
export function viewStateMatches(msg, target) {
  if (!msg || !target) return false;
  return isDisplay(target) ? msg.displayId === target.id && msg.windowId === undefined : msg.windowId === target.id;
}

/// The `displays` message's items as [{id, name, w, h, src}]; malformed items are dropped.
export function decodeDisplays(msg) {
  if (!msg || !Array.isArray(msg.items)) return [];
  return msg.items
    .filter((d) => d && Number.isInteger(d.id) && typeof d.name === 'string')
    .map((d) => ({
      id: d.id,
      name: d.name,
      w: Number.isFinite(d.w) ? d.w : 0,
      h: Number.isFinite(d.h) ? d.h : 0,
      src: typeof d.jpeg === 'string' && d.jpeg.length > 0 ? `data:image/jpeg;base64,${d.jpeg}` : null,
    }));
}

/// Bottom-bar buttons shown for a target: a display has no app menu (☰) and no window to fit
/// (📱) (D43, D35).
export function viewerControls(target) {
  const display = isDisplay(target);
  return { appMenu: !display, fitWindow: !display };
}

/// Fills `container` with one row per display: thumbnail, name, and size in points.
export function renderDisplayList(container, displays, onOpen) {
  container.textContent = '';
  for (const d of displays) {
    const li = document.createElement('li');
    li.className = 'display-row';
    if (d.src) {
      const img = document.createElement('img');
      img.src = d.src;
      img.alt = '';
      li.append(img);
    }
    const name = document.createElement('div');
    name.className = 'app';
    name.textContent = d.name;
    const size = document.createElement('div');
    size.className = 'wtitle';
    size.textContent = `${Math.round(d.w)} × ${Math.round(d.h)}`;
    const text = document.createElement('div');
    text.className = 'display-text';
    text.append(name, size);
    li.append(text);
    li.addEventListener('click', () => onOpen(d));
    container.append(li);
  }
}
