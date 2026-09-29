// The Apps tab of the window list (DESIGN.md D40): `apps` decoding and the grid. The Mac
// keeps the allowlist; the phone only sends back the ids it got here.

export const LIST_TAB_KEY = 'mwr.listTab';
/// The Mac gives up after 10 s; the phone stops waiting a little later on its own.
export const APP_OPEN_TIMEOUT_MS = 12000;

/// The `apps` message's items as [{id, name, running}]; malformed items are dropped.
export function decodeApps(msg) {
  if (!msg || !Array.isArray(msg.items)) return [];
  return msg.items
    .filter((a) => a && typeof a.id === 'string' && /^[0-9a-f]{1,64}$/.test(a.id) && typeof a.name === 'string')
    .map((a) => ({ id: a.id, name: a.name, running: a.running === true }));
}

/// The stored tab, 'windows' unless 'apps'.
export function parseListTab(value) {
  return value === 'apps' ? 'apps' : 'windows';
}

export function iconURL(id) {
  return `apps/icon/${id}.png`;
}

/// Fills `container` with one button per app: icon, name, and a dot when running.
export function renderAppGrid(container, apps, onOpen) {
  container.textContent = '';
  for (const a of apps) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'app-tile';
    b.setAttribute('aria-label', a.running ? `${a.name} (running)` : a.name);
    const img = document.createElement('img');
    img.src = iconURL(a.id);
    img.alt = '';
    img.loading = 'lazy';
    const name = document.createElement('span');
    name.className = 'app-name';
    name.textContent = a.name;
    const dot = document.createElement('span');
    dot.className = a.running ? 'run-dot on' : 'run-dot';
    b.append(img, name, dot);
    b.addEventListener('click', () => onOpen(a));
    container.append(b);
  }
}
