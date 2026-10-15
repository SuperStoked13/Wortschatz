// Global keyboard routing for Write mode, and the study shortcuts both study screens share
// (Lernen imports them too): Enter submits / continues, any printable key continues after a
// correct answer, Alt+Enter «Weiss ich nicht», Ctrl+Enter «Ich hatte recht», Esc back to the
// set, Ctrl+K Optionen, Ctrl+R Vorlesen, Ctrl+D Markieren, Ctrl+E Karte bearbeiten,
// Ctrl+Shift+R Neu starten (the Mac app's Lernen menu, ⌘ → Ctrl, ⌥ → Alt). Held keys and
// presses right after a transition are swallowed, so a single press never triggers two steps.

import { hasOpenModal, hasOpenOverlay } from '../ui/components.js';
import { commandLetter, isComposingKey } from '../lib/shortcuts.js';

const CONTROLS = 'button, a[href], input, textarea, select, [contenteditable="true"]';

// After Enter moved to another screen its Enter-bound buttons wait this long (the Mac app's
// KeyActionGate, as long as the input lock).
export const ENTER_SETTLE_MS = 280;

/**
 * The study command of a keydown, or null:
 * 'dontKnow' (Alt+Enter), 'override' (Ctrl/⌘+Enter), 'exit' (Esc), 'options' (Ctrl/⌘+K),
 * 'speak' (Ctrl/⌘+R), 'star' (Ctrl/⌘+D), 'edit' (Ctrl/⌘+E), 'restart' (Ctrl/⌘+Shift+R).
 * Ctrl+Alt is never a command: it is AltGr on Swiss and German keyboards. On a non-Latin layout
 * (Arabic) the letter comes from the key's position.
 */
export function studyCommand(e) {
  if (!e || typeof e.key !== 'string') return null;
  const mod = !!(e.ctrlKey || e.metaKey);
  const alt = !!e.altKey;
  const shift = !!e.shiftKey;
  if (e.key === 'Enter') {
    if (alt && !mod && !shift) return 'dontKnow';
    if (mod && !alt && !shift) return 'override';
    return null;
  }
  if (e.key === 'Escape' || e.key === 'Esc') return !mod && !alt && !shift ? 'exit' : null;
  if (!mod || alt) return null;
  const key = commandLetter(e);
  if (shift) return key === 'r' ? 'restart' : null;
  return { k: 'options', r: 'speak', d: 'star', e: 'edit' }[key] || null;
}

// [Apple, elsewhere] for the key hints, and the aria-keyshortcuts values.
const SHORTCUTS = {
  dontKnow: { apple: '⌥↵', other: 'Alt+↵', aria: ['Alt+Enter', 'Alt+Enter'] },
  override: { apple: '⌘↵', other: 'Strg+↵', aria: ['Meta+Enter', 'Control+Enter'] },
  options: { apple: '⌘K', other: 'Strg+K', aria: ['Meta+K', 'Control+K'] },
  speak: { apple: '⌘R', other: 'Strg+R', aria: ['Meta+R', 'Control+R'] },
  star: { apple: '⌘D', other: 'Strg+D', aria: ['Meta+D', 'Control+D'] },
  edit: { apple: '⌘E', other: 'Strg+E', aria: ['Meta+E', 'Control+E'] },
  restart: { apple: '⇧⌘R', other: 'Strg+Umschalt+R', aria: ['Shift+Meta+R', 'Control+Shift+R'] },
  exit: { apple: 'Esc', other: 'Esc', aria: ['Escape', 'Escape'] },
};

// The key of a command as the key hints show it: «Alt+↵», «Strg+K» (⌥↵, ⌘K on Apple).
export function shortcutText(command, apple = false) {
  const s = SHORTCUTS[command];
  return s ? (apple ? s.apple : s.other) : '';
}

// The aria-keyshortcuts value of a command.
export function shortcutAria(command, apple = false) {
  const s = SHORTCUTS[command];
  return s ? s.aria[apple ? 0 : 1] : '';
}

// A key that types several letters at once, e.g. «لا» (lam-alef) on the Arabic keyboard. Named
// keys («Enter», «Process», «Dead») are ASCII words and never match.
const LETTER_KEY = /^\p{L}[\p{L}\p{M}]*$/u;

/**
 * A key that types a character: one code point (or a non-Latin letter key with more), no
 * Ctrl/⌘ — except Ctrl+Alt, which is AltGr on Windows (@ # € …); Alt alone types characters
 * on a Mac (⌥ + key).
 */
export function isTypedKey(e) {
  if (!e || typeof e.key !== 'string') return false;
  if ([...e.key].length !== 1 && !(/[^\x00-\x7f]/.test(e.key) && LETTER_KEY.test(e.key))) return false;
  if (e.metaKey) return false;
  const altGraph = typeof e.getModifierState === 'function' && e.getModifierState('AltGraph');
  return !e.ctrlKey || !!e.altKey || !!altGraph;
}

/**
 * The keydown that hands a key to an input method while nothing is composed yet (keyCode 229,
 * e.g. the first Pinyin letter): «any key continues» takes it like a typed character, but leaves
 * it to the input method. Never a held key.
 */
export function startsComposition(e) {
  return !!e && !e.isComposing && e.keyCode === 229 && !e.repeat;
}

/**
 * After Enter moved to another screen (the set page, the editor), a quick second press meant
 * for this one must not also press the new screen's Enter-bound button: Enter is swallowed for
 * `ms` (KeyActionGate). Clicks are never held back.
 */
export function settleEnter(ms = ENTER_SETTLE_MS) {
  if (typeof window === 'undefined' || typeof window.addEventListener !== 'function') return;
  const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
  const until = now() + ms;
  const swallow = (e) => {
    if (now() >= until) {
      window.removeEventListener('keydown', swallow, true);
      return;
    }
    // An input method's Enter confirms its composition (Pinyin) and stays with it.
    if (e.key === 'Enter' && !isComposingKey(e)) {
      e.preventDefault();
      e.stopPropagation();
    }
  };
  window.addEventListener('keydown', swallow, true);
  setTimeout(() => window.removeEventListener('keydown', swallow, true), ms + 20);
}

/**
 * Enter or Space on a focused link or [data-leaves] control inside `root` (a keyboard
 * activation: the click has detail 0, as has click()) moves to another screen: Enter waits
 * there for a moment (settleEnter). A mouse click is never held back. Returns `off`.
 */
export function settleOnLeave(root) {
  const onClick = (e) => {
    if (!e || e.detail !== 0) return;
    const t = e.target && e.target.closest ? e.target.closest('a[href], [data-leaves="true"]') : null;
    if (t) settleEnter();
  };
  root.addEventListener('click', onClick);
  return () => root.removeEventListener('click', onClick);
}

/**
 * Routes a keydown to a study command: every handled combination is preventDefault-ed (Ctrl+R
 * would reload the page in a browser, Ctrl+D bookmark it); a held key or an open dialog,
 * menu or popup does nothing. Returns true when the key was a command.
 */
export function routeStudyCommand(e, onCommand) {
  const command = studyCommand(e);
  if (!command) return false;
  // Esc closes a menu or tooltip first (they listen themselves).
  if (command === 'exit' && hasOpenOverlay()) return true;
  e.preventDefault();
  if (!e.repeat && typeof onCommand === 'function') onCommand(command, e);
  return true;
}

/**
 * ownInput() -> the answer <input> (Enter there is ours, not the browser's)
 * isLocked() -> true shortly after a transition
 * onEnter()  -> primary action of the current step
 * onLockedEnter() -> Enter inside the lock (a correct answer may then move on when it ends)
 * canContinueOnKey() / onContinueKey() -> "any key continues" (correct-answer feedback)
 * onCommand(command, event) -> a study shortcut (see studyCommand)
 * Returns an unbind function.
 */
export function bindWriteKeys({ ownInput, isLocked, onEnter, onLockedEnter, canContinueOnKey, onContinueKey, onCommand }) {
  function onKeydown(e) {
    if (e.defaultPrevented || hasOpenModal()) return;
    const target = e.target;
    const own = target === ownInput();
    if (isComposingKey(e)) {
      // The first key of an input method's composition (Pinyin) in the locked answer field also
      // continues; it is not prevented, so the composition starts in the next question's field.
      if (startsComposition(e) && own && canContinueOnKey()) onContinueKey();
      return;
    }
    if (routeStudyCommand(e, onCommand)) return;
    const control = !own && target && target.closest ? target.closest(CONTROLS) : null;

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
      if (control) return; // the focused button/link handles Enter itself
      e.preventDefault();
      onEnter();
      return;
    }

    // The character itself then lands in the next question's (still focused) input. A held
    // key never moves on (it may still be repeating from the answer typed before).
    if (!control && isTypedKey(e) && canContinueOnKey()) {
      if (e.repeat) {
        e.preventDefault();
        return;
      }
      if (e.key === ' ') e.preventDefault();
      onContinueKey();
    }
  }

  document.addEventListener('keydown', onKeydown);
  return () => document.removeEventListener('keydown', onKeydown);
}
