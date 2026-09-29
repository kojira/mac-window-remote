// iPhone text input: compose on the phone, send on Return (DESIGN.md D10, D34).
// Active key-panel modifiers apply to Return, Backspace, and single typed characters.
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
      this.onFocusChange(true);
    });
    field.addEventListener('blur', () => {
      bar.classList.remove('typing');
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

    // Keep the bottom bar (and the key panel above it) above the iOS keyboard.
    const vv = window.visualViewport;
    if (vv) {
      const place = () => {
        const covered = window.innerHeight - vv.height - vv.offsetTop;
        dock.style.transform = covered > 0 ? `translateY(${-covered}px)` : '';
        dock.classList.toggle('keyboard-up', covered > 0);
      };
      vv.addEventListener('resize', place);
      vv.addEventListener('scroll', place);
    }
  }

  sendKey(key) {
    this.send({ t: 'key', key, mods: this.modifiers.consume() });
  }

  /// Inside a tap handler, so iOS shows the keyboard.
  focus() { this.field.focus(); }

  blur() { this.field.blur(); }

  isFocused() { return document.activeElement === this.field; }
}
