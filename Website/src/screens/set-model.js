// DOM-free helpers of the set page (src/screens/set.js): the difficult cards behind
// «Nur schwierige (N)» and the term filter «Schwierig» (Mac SetSummary.difficultCardIDs),
// and the page's keyboard commands (Mac menu «Lernset»: ⌘L, ⇧⌘L, ⌘E → Ctrl).

import { commandKey } from '../lib/shortcuts.js';

// From this many wrong answers (in total) a card counts as difficult.
export const DIFFICULT_MISTAKES = 4;

// How often `cardId` was answered wrong (all time).
export function mistakesOf(progress, cardId) {
  const entry = progress && Object.prototype.hasOwnProperty.call(progress, cardId) ? progress[cardId] : null;
  const n = entry ? Number(entry.incorrect) : 0;
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
}

// The cards answered wrong at least DIFFICULT_MISTAKES times: most mistakes first, then in
// card order. Returns the card objects (not copies).
export function difficultCards(cards, progress) {
  const list = Array.isArray(cards) ? cards : [];
  return list
    .map((card, position) => ({ card, position, mistakes: card ? mistakesOf(progress, card.id) : 0 }))
    .filter((entry) => entry.mistakes >= DIFFICULT_MISTAKES)
    .sort((a, b) => b.mistakes - a.mistakes || a.position - b.position)
    .map((entry) => entry.card);
}

// The set page's shortcut for a keydown: 'learn' (Ctrl+L: Lernen / Weiterlernen), 'write'
// (Ctrl+Shift+L: Schreiben) or 'edit' (Ctrl+E: Bearbeiten); null for anything else.
export function setPageCommand(e) {
  if (commandKey(e, 'l')) return 'learn';
  if (commandKey(e, 'l', { shift: true })) return 'write';
  if (commandKey(e, 'e')) return 'edit';
  return null;
}
