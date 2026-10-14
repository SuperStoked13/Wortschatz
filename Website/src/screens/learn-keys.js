// Global keyboard routing for Learn mode. Enter submits / continues exactly as in Write mode
// (held keys and presses right after a transition are swallowed, a focused button handles
// Enter itself unless the screen owns it: an option highlighted by typing or the arrows). The
// study shortcuts (Alt+Enter, Ctrl+Enter, Esc, Ctrl+K/R/D/E, Ctrl+Shift+R) are shared with
// Write (write-keys.js). Every other key a multiple choice question may use — printable
// characters (AltGr ones too), Backspace (Ctrl/Alt: a word) and the arrows — goes to
// onKey(event, { own, kind, … }). Nothing happens while a dialog is open.

import { hasOpenModal } from '../ui/components.js';
import { routeStudyCommand, isTypedKey } from './write-keys.js';

const CONTROLS = 'button, a[href], input, textarea, select, [contenteditable="true"]';
const TEXT_ENTRY = 'input, textarea, select, [contenteditable="true"]';
const ARROWS = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right' };

/**
 * ownInput() -> the written answer <input> (Enter there is ours, not the browser's)
 * isLocked() -> true shortly after a transition
 * onEnter()  -> primary action of the current step
 * onLockedEnter() -> Enter inside the lock (a correct answer may then move on when it ends)
 * ownsEnter(control) -> true when Enter belongs to the screen even on the focused `control`
 * onKey(event, { own, kind: 'char' | 'delete' | 'arrow', word, direction }) -> keys outside
 *   other text fields; `own` is true when the written answer field has focus
 * onCommand(command, event) -> a study shortcut (write-keys.js studyCommand)
 * Returns an unbind function.
 */
export function bindLearnKeys({ ownInput, isLocked, onEnter, onLockedEnter, ownsEnter, onKey, onCommand }) {
  function onKeydown(e) {
    if (e.defaultPrevented || hasOpenModal()) return;
    if (e.isComposing || e.keyCode === 229) return;
    if (routeStudyCommand(e, onCommand)) return;
    const target = e.target;
    const input = ownInput();
    const own = !!input && target === input;
    const closest = (selector) => (!own && target && target.closest ? target.closest(selector) : null);

    if (e.key === 'Enter') {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.repeat) {
        e.preventDefault();
        return;
      }
      if (isLocked()) {
        e.preventDefault();
        if (typeof onLockedEnter === 'function') onLockedEnter();
        return;
      }
      // The focused button/link handles Enter itself (unless the screen owns Enter there).
      const control = closest(CONTROLS);
      if (control && !(typeof ownsEnter === 'function' && ownsEnter(control))) return;
      e.preventDefault();
      onEnter();
      return;
    }

    // Text fields keep their own editing keys (the answer field included).
    if (own || closest(TEXT_ENTRY)) {
      if (own && isTypedKey(e)) onKey(e, { own, kind: 'char' });
      return;
    }
    if (e.key === 'Backspace') {
      if (e.metaKey) return;
      onKey(e, { own, kind: 'delete', word: !!(e.ctrlKey || e.altKey) });
      return;
    }
    if (ARROWS[e.key]) {
      if (e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;
      onKey(e, { own, kind: 'arrow', direction: ARROWS[e.key] });
      return;
    }
    if (isTypedKey(e)) onKey(e, { own, kind: 'char' });
  }

  document.addEventListener('keydown', onKeydown);
  return () => document.removeEventListener('keydown', onKeydown);
}
