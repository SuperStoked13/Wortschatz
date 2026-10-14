// Keyboard routing for Karteikarten (the Mac's FlashcardDeck.action(for:) plus the study menu).
// Space, Enter, ↑ and ↓ turn the card, ← «Lerne ich noch», → «Weiss ich», Backspace takes the last
// card back, Enter continues after a round, starts over at the end and adds terms to an empty set,
// Esc leaves; Ctrl (⌘ on Apple) + K Optionen, + Shift + R Neu starten, + R Vorlesen, + D Markieren,
// + E Bearbeiten. Held keys never step twice, Space and Enter wait out the lock after a transition,
// nothing happens under a dialog or in a text field, and a focused button keeps Space and Enter.

import { hasOpenModal } from '../ui/components.js';
import { keyAction } from '../core/flashcards.js';

const CONTROLS = 'button, a[href], input, textarea, select, [contenteditable="true"]';
const TEXT_ENTRY = 'input, textarea, select, [contenteditable="true"]';

// The study-menu command of a key press: 'options' | 'restart' | 'speak' | 'star' | 'edit' | null.
// Ctrl (or ⌘ on Apple) without Alt: Ctrl+Alt is AltGr on Swiss and German keyboards.
export function commandFor(e, apple = false) {
  if (!e || e.altKey) return null;
  const mod = apple ? e.metaKey || e.ctrlKey : e.ctrlKey && !e.metaKey;
  if (!mod) return null;
  const key = String(e.key || '').toLowerCase();
  const code = String(e.code || '');
  // Other scripts (e.g. a Cyrillic layout) fall back to the key's position.
  const is = (letter) => key === letter || (!/^[a-z]$/.test(key) && code === `Key${letter.toUpperCase()}`);
  if (is('r')) return e.shiftKey ? 'restart' : 'speak';
  if (e.shiftKey) return null;
  if (is('k')) return 'options';
  if (is('d')) return 'star';
  if (is('e')) return 'edit';
  return null;
}

/**
 * phase() -> the deck phase; isLocked() -> true shortly after a transition (Enter waits);
 * onAction(action) -> a key of core keyAction(), or 'add' (Enter on an empty set: «Begriffe
 * hinzufügen», the Mac's Return button there); onCommand(command) -> a commandFor() command.
 * Returns an unbind function.
 */
export function bindFlashcardKeys({ phase, isLocked, onAction, onCommand, apple = false }) {
  function onKeydown(e) {
    if (e.defaultPrevented || hasOpenModal()) return;
    if (e.isComposing || e.keyCode === 229) return;
    const target = e.target;
    if (target && target.closest && target.closest(TEXT_ENTRY)) return;

    const command = commandFor(e, apple);
    if (command) {
      // Never the browser's reload, bookmark or search field on this screen.
      e.preventDefault();
      if (!e.repeat) onCommand(command);
      return;
    }
    if (e.ctrlKey || e.metaKey || e.altKey) return;

    const confirmKey = e.key === 'Enter' || e.key === ' ' || e.key === 'Spacebar';
    if (confirmKey && target && target.closest && target.closest(CONTROLS)) {
      // The focused button handles the key itself, in every phase (Space on «Weiter mit N
      // Karten» too); held or too early it does nothing, so the press that ended a round never
      // also skips its summary.
      if (e.repeat || isLocked()) e.preventDefault();
      return;
    }
    const current = phase();
    const action = keyAction(e.key, { phase: current }) || (current === 'empty' && e.key === 'Enter' ? 'add' : null);
    if (!action) return;
    e.preventDefault();
    if (e.repeat) return;
    if (confirmKey && isLocked()) return;
    onAction(action);
  }

  document.addEventListener('keydown', onKeydown);
  return () => document.removeEventListener('keydown', onKeydown);
}
