// iPhone text input: compose on the phone, send on Return (DESIGN.md D10, §3 bottom bar).
export class TextInput {
  constructor({ field, button, bar, send }) {
    this.field = field;
    this.bar = bar;
    this.send = send;

    // Focus inside the tap handler so iOS shows the keyboard.
    button.addEventListener('click', () => {
      bar.classList.add('typing');
      field.focus();
    });
    field.addEventListener('blur', () => bar.classList.remove('typing'));

    field.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        // Enter that confirms an IME conversion is not a send (Safari reports keyCode 229).
        if (e.isComposing || e.keyCode === 229) return;
        e.preventDefault();
        const text = field.value;
        if (text.length > 0) {
          if (this.send({ t: 'text', text })) field.value = '';
        } else {
          this.send({ t: 'key', key: 'Enter' });
        }
      } else if (e.key === 'Backspace' && field.value === '' && !e.isComposing) {
        e.preventDefault();
        this.send({ t: 'key', key: 'Backspace' });
      }
    });

    // Backspace in an empty field, for keyboards that do not report keydown.
    field.addEventListener('beforeinput', (e) => {
      if (e.inputType === 'deleteContentBackward' && field.value === '') {
        e.preventDefault();
        this.send({ t: 'key', key: 'Backspace' });
      }
    });

    // Keep the bottom bar above the iOS keyboard.
    const vv = window.visualViewport;
    if (vv) {
      const place = () => {
        const covered = window.innerHeight - vv.height - vv.offsetTop;
        bar.style.transform = covered > 0 ? `translateY(${-covered}px)` : '';
        bar.classList.toggle('keyboard-up', covered > 0);
      };
      vv.addEventListener('resize', place);
      vv.addEventListener('scroll', place);
    }
  }

  blur() { this.field.blur(); }
}
