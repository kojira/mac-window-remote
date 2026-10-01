// iPhone text input: compose on the phone, send on Return (DESIGN.md D10, D34).
// Active key-panel modifiers apply to Return, Backspace, and single typed characters.
// The field is a textarea that wraps and grows with its text, up to a cap (D53).
import { charKeyName } from './modifiers.js';

export class TextInput {
  /// dock: the key panel and bottom bar, kept above the iOS keyboard.
  /// modifiers: the key panel's ModifierState. onFocusChange(focused) is set by the panel.
  constructor({ field, bar, dock, modifiers, send }) {
    this.field = field;
    this.bar = bar;
    this.modifiers = modifiers;
    this.send = send;
    this.onFocusChange = () => {};

    field.addEventListener('focus', () => {
      bar.classList.add('typing');
      this.fitHeight();
      this.onFocusChange(true);
    });
    field.addEventListener('blur', () => {
      bar.classList.remove('typing');
      this.fitHeight();
      this.onFocusChange(false);
    });

    field.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        // Enter that confirms an IME conversion is not a send (Safari reports keyCode 229).
        if (e.isComposing || e.keyCode === 229) return;
        e.preventDefault();
        const text = field.value;
        if (text.length > 0) {
          if (this.send({ t: 'text', text })) {
            field.value = '';
            this.fitHeight();
            this.modifiers.disarm();
          }
        } else {
          this.sendKey('Enter');
        }
      } else if (e.key === 'Backspace' && field.value === '' && !e.isComposing) {
        e.preventDefault();
        this.sendKey('Backspace');
      }
    });

    field.addEventListener('beforeinput', (e) => {
      // Backspace in an empty field, for keyboards that do not report keydown.
      if (e.inputType === 'deleteContentBackward' && field.value === '') {
        e.preventDefault();
        this.sendKey('Backspace');
        return;
      }
      // D34: with a modifier active, one typed key character is a shortcut, not text.
      if (e.inputType === 'insertText' && this.modifiers.any()) {
        const name = charKeyName(e.data);
        if (name) {
          e.preventDefault();
          this.sendKey(name);
        }
      }
    });

    field.addEventListener('input', (e) => {
      // D53: like the one-line field it replaces, the text has no line breaks (a pasted one
      // is dropped); Return sends instead.
      if (!e.isComposing && /[\r\n]/.test(field.value)) {
        const caret = field.value.slice(0, field.selectionEnd).replace(/[\r\n]/g, '').length;
        field.value = field.value.replace(/[\r\n]/g, '');
        field.setSelectionRange?.(caret, caret);
      }
      this.fitHeight();
    });

    // Keep the bottom bar (and the key panel above it) above the iOS keyboard.
    const vv = window.visualViewport;
    if (vv) {
      const place = () => {
        const covered = window.innerHeight - vv.height - vv.offsetTop;
        dock.style.transform = covered > 0 ? `translateY(${-covered}px)` : '';
        dock.classList.toggle('keyboard-up', covered > 0);
        this.fitHeight();
      };
      vv.addEventListener('resize', place);
      vv.addEventListener('scroll', place);
    }
  }

  /// D53: the field is as tall as its wrapped text, at most 8 lines or 40% of the visible
  /// viewport; past that it scrolls, and the browser keeps the caret line in view.
  fitHeight() {
    const f = this.field;
    // Hidden (not typing) or empty, the field is one line high: the stylesheet's height.
    if (!this.bar.classList.contains('typing') || f.value === '') {
      f.style.height = '';
      f.style.overflowY = '';
      return;
    }
    const cs = getComputedStyle(f);
    const px = (v) => parseFloat(v) || 0;
    const frame = px(cs.paddingTop) + px(cs.paddingBottom) + px(cs.borderTopWidth) + px(cs.borderBottomWidth);
    const line = px(cs.lineHeight) || 20;
    const viewport = window.visualViewport?.height ?? window.innerHeight;
    const cap = Math.max(line + frame, Math.min(8 * line + frame, 0.4 * viewport));
    const top = f.scrollTop;
    f.style.height = 'auto';
    const needed = f.scrollHeight + px(cs.borderTopWidth) + px(cs.borderBottomWidth);
    f.style.height = `${Math.min(needed, cap)}px`;
    f.style.overflowY = needed > cap ? 'auto' : 'hidden';
    // Typing at the end keeps the last line in view; elsewhere the scroll stays where it was.
    f.scrollTop = f.selectionEnd === f.value.length ? f.scrollHeight : top;
  }

  sendKey(key) {
    this.send({ t: 'key', key, mods: this.modifiers.consume() });
  }

  /// Inside a tap handler, so iOS shows the keyboard.
  focus() { this.field.focus(); }

  blur() { this.field.blur(); }

  isFocused() { return document.activeElement === this.field; }
}
