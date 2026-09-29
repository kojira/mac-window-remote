// One-shot and locked modifiers for the key panel, and typed character → key name
// (DESIGN.md D13, D34, §4.3). Pure logic, no DOM.

/// Wire names in the order the Mac presses them.
export const MODIFIERS = ['cmd', 'ctrl', 'opt', 'shift'];

/// ANSI punctuation keys (§4.3); each character is its own key name.
const PUNCTUATION = new Set(['-', '=', '[', ']', '\\', ';', "'", ',', '.', '/', '`']);

/// The §4.3 key name for one typed character, or null if it is not a single key.
export function charKeyName(text) {
  if (typeof text !== 'string' || text.length !== 1) return null;
  if (/^[a-z0-9]$/.test(text) || PUNCTUATION.has(text)) return text;
  if (text === ' ') return 'Space';
  return null;
}

/// The active modifiers plus a combo key's own (D37), each once, in cmd, ctrl, opt, shift order
/// (the Mac rejects a repeated mod).
export function mergeMods(active, extra) {
  return MODIFIERS.filter((m) => active.includes(m) || extra.includes(m));
}

/// Each modifier is 'off', 'armed' (applies to the next key once), or 'locked' (until tapped).
export class ModifierState {
  constructor(onChange = () => {}) {
    this.onChange = onChange;
    this.state = Object.fromEntries(MODIFIERS.map((m) => [m, 'off']));
  }

  /// Tap: off → armed; armed or locked → off.
  tap(mod) {
    this.set(mod, this.state[mod] === 'off' ? 'armed' : 'off');
  }

  /// Long press: locked until tapped again.
  lock(mod) {
    this.set(mod, 'locked');
  }

  get(mod) { return this.state[mod]; }

  any() { return MODIFIERS.some((m) => this.state[m] !== 'off'); }

  /// The active modifiers for a key being sent now; armed ones disarm, locked ones stay.
  consume() {
    const mods = MODIFIERS.filter((m) => this.state[m] !== 'off');
    this.disarm();
    return mods;
  }

  /// Plain text was sent: armed modifiers disarm, locked ones stay.
  disarm() {
    let changed = false;
    for (const m of MODIFIERS) {
      if (this.state[m] === 'armed') { this.state[m] = 'off'; changed = true; }
    }
    if (changed) this.onChange();
  }

  /// Everything off (the panel closed).
  reset() {
    if (!this.any()) return;
    for (const m of MODIFIERS) this.state[m] = 'off';
    this.onChange();
  }

  set(mod, value) {
    if (!MODIFIERS.includes(mod) || this.state[mod] === value) return;
    this.state[mod] = value;
    this.onChange();
  }
}
