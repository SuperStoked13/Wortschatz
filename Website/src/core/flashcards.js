// Karteikarten deck model, a port of the Mac app's WortschatzCore/Flashcards.swift: per set the
// cards of the round in order, how the ones before the current card were sorted («Weiss ich» →,
// «Lerne ich noch» ←) and the cards known in earlier rounds; rounds repeat the «Lerne ich noch» cards.
// Self-assessment only, never mastery progress. Pure and DOM-free; operations return new decks, and
// the JSON keys are the Mac's (round, queue, sorts[{cardID, verdict}], knownEarlier, isFlipped,
// starredOnly, isShuffled, updatedAt). Also: the opening rules, the key map and the German copy.

import { plural } from '../lib/labels.js';

export const KNOW = 'know';
export const STILL_LEARNING = 'stillLearning';
export const VERDICTS = Object.freeze([KNOW, STILL_LEARNING]);
// Which side of the cards is up first (the global «Vorderseite» option).
export const FRONTS = Object.freeze(['term', 'definition']);

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isText = (v) => typeof v === 'string' && v.trim() !== '';
const isIdList = (v) => Array.isArray(v) && v.every((id) => typeof id === 'string');

/* ------------------------------------------------------------------ cards */

// A card takes part when it has text on at least one side (Lernen needs both).
export function hasText(card) {
  return isObj(card) && (isText(card.term) || isText(card.definition));
}

// Ids of the cards a deck shows, in the set's order: text on one side at least, a non-empty id
// (each once), and only starred cards when `starredOnly`.
export function eligibleIds(cards, starredOnly = false) {
  const seen = new Set();
  const out = [];
  for (const card of Array.isArray(cards) ? cards : []) {
    if (!hasText(card) || (starredOnly && !card.starred)) continue;
    const id = card.id;
    if (typeof id !== 'string' || id === '' || seen.has(id)) continue;
    seen.add(id);
    out.push(id);
  }
  return out;
}

// Fisher–Yates on a copy (the Mac's `shuffled`: r = floor(rng() * (i + 1))).
export function shuffledIds(list, rng = Math.random) {
  const a = list.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const r = Math.floor(rng() * (i + 1));
    const j = Number.isFinite(r) ? Math.min(Math.max(r, 0), i) : i;
    const tmp = a[i];
    a[i] = a[j];
    a[j] = tmp;
  }
  return a;
}

// `ids` in the order of `cardOrder` (the set's card ids); ids it does not know go last, as they were.
export function orderedIds(ids, cardOrder) {
  const position = new Map();
  (Array.isArray(cardOrder) ? cardOrder : []).forEach((id, i) => {
    if (!position.has(id)) position.set(id, i);
  });
  const rank = (id) => (position.has(id) ? position.get(id) : Infinity);
  return ids
    .map((id, i) => ({ id, i }))
    .sort((a, b) => rank(a.id) - rank(b.id) || a.i - b.i)
    .map((x) => x.id);
}

/* ------------------------------------------------------------------- deck */

// A new deck over `cards`: the ones with text (only starred ones when `starredOnly`), in the
// set's order or shuffled, front side up.
export function newDeck(cards, { starredOnly = false, shuffled = false, rng = Math.random, now = Date.now() } = {}) {
  const ids = eligibleIds(cards, starredOnly);
  return {
    round: 1,
    queue: shuffled ? shuffledIds(ids, rng) : ids,
    sorts: [],
    knownEarlier: [],
    isFlipped: false,
    starredOnly: !!starredOnly,
    isShuffled: !!shuffled,
    updatedAt: now,
  };
}

// Whether a stored deck makes sense: every sort belongs to the card at its place, no card twice.
export function isConsistent(deck) {
  if (!isObj(deck) || !Number.isInteger(deck.round) || deck.round < 1) return false;
  if (!isIdList(deck.queue) || !isIdList(deck.knownEarlier) || !Array.isArray(deck.sorts)) return false;
  if (deck.sorts.length > deck.queue.length) return false;
  for (let i = 0; i < deck.sorts.length; i++) {
    const s = deck.sorts[i];
    if (!isObj(s) || s.cardID !== deck.queue[i] || !VERDICTS.includes(s.verdict)) return false;
  }
  const all = [...deck.queue, ...deck.knownEarlier];
  return new Set(all).size === all.length;
}

// A deck read back from storage (a JSON string or a parsed object), with exactly the Mac's keys;
// null when it is not a deck or not consistent (such decks are dropped, like on the Mac).
export function parseDeck(input) {
  let raw = input;
  if (typeof raw === 'string') {
    try {
      raw = JSON.parse(raw);
    } catch {
      return null;
    }
  }
  if (!isObj(raw) || !Number.isInteger(raw.round) || !isIdList(raw.queue) || !isIdList(raw.knownEarlier) || !Array.isArray(raw.sorts)) {
    return null;
  }
  const sorts = [];
  for (const s of raw.sorts) {
    if (!isObj(s) || typeof s.cardID !== 'string' || !VERDICTS.includes(s.verdict)) return null;
    sorts.push({ cardID: s.cardID, verdict: s.verdict });
  }
  const deck = {
    round: raw.round,
    queue: raw.queue.slice(),
    sorts,
    knownEarlier: raw.knownEarlier.slice(),
    isFlipped: raw.isFlipped === true,
    starredOnly: raw.starredOnly === true,
    isShuffled: raw.isShuffled === true,
    updatedAt: typeof raw.updatedAt === 'number' && Number.isFinite(raw.updatedAt) ? raw.updatedAt : 0,
  };
  return isConsistent(deck) ? deck : null;
}

// Same content (updatedAt aside).
export function sameDeck(a, b) {
  if (!isObj(a) || !isObj(b)) return a === b;
  const list = (x, y) => x.length === y.length && x.every((v, i) => v === y[i]);
  return (
    a.round === b.round &&
    a.isFlipped === b.isFlipped &&
    a.starredOnly === b.starredOnly &&
    a.isShuffled === b.isShuffled &&
    list(a.queue, b.queue) &&
    list(a.knownEarlier, b.knownEarlier) &&
    a.sorts.length === b.sorts.length &&
    a.sorts.every((s, i) => s.cardID === b.sorts[i].cardID && s.verdict === b.sorts[i].verdict)
  );
}

/* ---------------------------------------------------------------- reading */

const learningIn = (deck) => deck.sorts.reduce((n, s) => n + (s.verdict === STILL_LEARNING ? 1 : 0), 0);

// 'empty' (no card with text) | 'card' (a card is up) | 'roundDone' (some cards still being
// learnt) | 'finished' (every card known).
export function deckPhase(deck) {
  if (!isObj(deck) || (!deck.queue.length && !deck.knownEarlier.length)) return 'empty';
  if (deck.sorts.length < deck.queue.length) return 'card';
  return learningIn(deck) > 0 ? 'roundDone' : 'finished';
}

// The card on screen (null after the round).
export function currentCardId(deck) {
  return isObj(deck) && deck.sorts.length < deck.queue.length ? deck.queue[deck.sorts.length] : null;
}

// The cards waiting under the current one, next first.
export function upcomingIds(deck) {
  return isObj(deck) ? deck.queue.slice(deck.sorts.length + 1) : [];
}

// All cards of the deck.
export function deckTotal(deck) {
  return isObj(deck) ? deck.knownEarlier.length + deck.queue.length : 0;
}

// "Weiss ich" over all rounds.
export function knownCount(deck) {
  return isObj(deck) ? deck.knownEarlier.length + deck.sorts.length - learningIn(deck) : 0;
}

// "Lerne ich noch" in this round.
export function learningCount(deck) {
  return isObj(deck) ? learningIn(deck) : 0;
}

// "Weiss ich" in this round.
export function knownInRound(deck) {
  return isObj(deck) ? deck.sorts.length - learningIn(deck) : 0;
}

export function canUndo(deck) {
  return isObj(deck) && deck.sorts.length > 0;
}

// Starting over would throw sorting away.
export function hasProgress(deck) {
  return isObj(deck) && (deck.sorts.length > 0 || deck.round > 1);
}

// The deck can be resumed (not finished, not empty).
export function isResumable(deck) {
  const phase = deckPhase(deck);
  return phase === 'card' || phase === 'roundDone';
}

// Share of the deck known, 0…1.
export function knownShare(deck) {
  const total = deckTotal(deck);
  return total > 0 ? knownCount(deck) / total : 0;
}

// The last sort of this round (what "Zurück" takes back), or null.
export function lastSort(deck) {
  if (!canUndo(deck)) return null;
  const s = deck.sorts[deck.sorts.length - 1];
  return { cardID: s.cardID, verdict: s.verdict };
}

// Everything the screen shows about a deck at once. `shown` is the card number on screen
// ("3 von 12": the sorted ones plus the current card).
export function deckStats(deck) {
  const phase = deckPhase(deck);
  const roundSize = isObj(deck) ? deck.queue.length : 0;
  const sorted = isObj(deck) ? deck.sorts.length : 0;
  return {
    phase,
    round: isObj(deck) ? deck.round : 1,
    currentCardId: currentCardId(deck),
    upcoming: upcomingIds(deck).length,
    total: deckTotal(deck),
    roundSize,
    sorted,
    remaining: roundSize - sorted,
    shown: Math.min(sorted + (phase === 'card' ? 1 : 0), roundSize),
    known: knownCount(deck),
    learning: learningCount(deck),
    knownInRound: knownInRound(deck),
    canUndo: canUndo(deck),
    hasProgress: hasProgress(deck),
  };
}

// Whether the term is the side up (`front`: the «Vorderseite» option).
export function showsTermSide(front, showingBack) {
  return (front !== 'definition') !== !!showingBack;
}

/* --------------------------------------------------------------- changing */

// Turns the current card over (only while a card is up).
export function flipCard(deck, now = Date.now()) {
  if (deckPhase(deck) !== 'card') return deck;
  return { ...deck, isFlipped: !deck.isFlipped, updatedAt: now };
}

// Sorts the current card; the next one comes up front side first. A card can be sorted
// without turning it over. Unchanged when no card is up.
export function sortCard(deck, verdict, now = Date.now()) {
  const id = currentCardId(deck);
  if (id == null || !VERDICTS.includes(verdict)) return deck;
  return { ...deck, sorts: [...deck.sorts, { cardID: id, verdict }], isFlipped: false, updatedAt: now };
}

// Takes the last sort of this round back: that card is the current one again, front side up.
// Works from the round summary and the finished screen too, never into the previous round.
export function undoSort(deck, now = Date.now()) {
  if (!canUndo(deck)) return deck;
  return { ...deck, sorts: deck.sorts.slice(0, -1), isFlipped: false, updatedAt: now };
}

// After a round: the "Lerne ich noch" cards again (shuffled, or in the set's order `cardOrder`;
// without it in the order they came), the known ones are put aside.
export function startNextRound(deck, { cardOrder = null, rng = Math.random, now = Date.now() } = {}) {
  if (deckPhase(deck) !== 'roundDone') return deck;
  const known = deck.sorts.filter((s) => s.verdict === KNOW).map((s) => s.cardID);
  const again = deck.sorts.filter((s) => s.verdict === STILL_LEARNING).map((s) => s.cardID);
  let queue = again;
  if (deck.isShuffled) queue = shuffledIds(again, rng);
  else if (Array.isArray(cardOrder)) queue = orderedIds(again, cardOrder);
  return {
    ...deck,
    round: deck.round + 1,
    queue,
    sorts: [],
    knownEarlier: [...deck.knownEarlier, ...known],
    isFlipped: false,
    updatedAt: now,
  };
}

// «Mischen» on or off: only the cards after the current one move (shuffled, or back into the
// set's order `cardOrder`); the current card and the sorted ones stay where they are.
export function setShuffled(deck, shuffled, { cardOrder = [], rng = Math.random, now = Date.now() } = {}) {
  const on = !!shuffled;
  if (!isObj(deck) || on === deck.isShuffled) return deck;
  const next = { ...deck, isShuffled: on, updatedAt: now };
  const start = Math.min(deck.queue.length, deck.sorts.length + 1);
  const rest = deck.queue.slice(start);
  if (rest.length <= 1) return next;
  next.queue = [...deck.queue.slice(0, start), ...(on ? shuffledIds(rest, rng) : orderedIds(rest, cardOrder))];
  return next;
}

// Follows changes of the set: deleted cards (or cards without text now) leave the deck, each sort
// staying with its card; newly eligible cards join at the end of this round (for a starred-only
// deck: newly starred ones; cards that lose their star stay). A new current card comes up front
// side first. Returns the same deck object when nothing changed (updatedAt only moves on a change).
export function syncDeck(deck, cards, now = Date.now()) {
  if (!isObj(deck)) return deck;
  const present = new Set();
  for (const card of Array.isArray(cards) ? cards : []) if (hasText(card)) present.add(card.id);
  const currentId = currentCardId(deck);

  // Drop what is gone; the sorted cards are the queue's head, so they stay its head.
  const queue = [];
  const sorts = [];
  deck.queue.forEach((id, i) => {
    if (!present.has(id)) return;
    queue.push(id);
    if (i < deck.sorts.length) sorts.push(deck.sorts[i]);
  });
  const knownEarlier = deck.knownEarlier.filter((id) => present.has(id));
  const inDeck = new Set([...queue, ...knownEarlier]);
  for (const id of eligibleIds(cards, deck.starredOnly)) if (!inDeck.has(id)) queue.push(id);

  const next = { ...deck, queue, sorts, knownEarlier };
  if (currentCardId(next) !== currentId) next.isFlipped = false;
  if (sameDeck(next, deck)) return deck;
  next.updatedAt = now;
  return next;
}

/* ------------------------------------------------------------- controller */

// The deck a visit opens (FlashcardsController.startingDeck): the stored deck brought up to date
// with the set, front side up and in the current «Mischen» order, unless a new one is asked for
// (`forceNew`), it belongs to another subset or it is finished / empty. Then a new deck; a
// starred-only deck without starred cards becomes one of all cards.
// subset: 'starred' | 'all' | null (null: resume whatever is stored).
export function startingDeck({ cards, saved = null, subset = null, forceNew = false, shuffled = false, rng = Math.random, now = Date.now() } = {}) {
  const starredOnly = subset === 'starred';
  const cardOrder = (Array.isArray(cards) ? cards : []).map((c) => c && c.id);
  if (!forceNew && isObj(saved) && (subset == null || !!saved.starredOnly === starredOnly)) {
    let deck = syncDeck(saved, cards, now);
    if (deck.isFlipped) deck = { ...deck, isFlipped: false };
    // «Mischen» applies to every set, also to a deck started before it was changed.
    deck = setShuffled(deck, shuffled, { cardOrder, rng, now });
    if (isResumable(deck)) return deck;
  }
  return restartDeck(cards, { starredOnly, shuffled, rng, now });
}

// A new deck over the set (all cards, or the starred ones); an empty starred-only deck falls
// back to all cards.
export function restartDeck(cards, { starredOnly = false, shuffled = false, rng = Math.random, now = Date.now() } = {}) {
  const deck = newDeck(cards, { starredOnly, shuffled, rng, now });
  if (deckPhase(deck) !== 'empty' || !starredOnly) return deck;
  return newDeck(cards, { shuffled, rng, now });
}

// The set page's running deck (AppModel.runningFlashcardDeck): the stored deck as the set is now,
// while it is under way (sorted at least one card, not finished); else null.
export function runningDeck(saved, cards) {
  if (!isObj(saved)) return null;
  const deck = syncDeck(saved, cards, saved.updatedAt);
  return isResumable(deck) && hasProgress(deck) ? deck : null;
}

/* ------------------------------------------------------------------- keys */

const FLIP_KEYS = new Set([' ', 'Spacebar', 'Enter', 'ArrowUp', 'ArrowDown', 'Up', 'Down']);

// What a key (KeyboardEvent.key) does in `phase`: 'flip' | 'know' | 'stillLearning' | 'undo' |
// 'nextRound' | 'restart' | 'exit', or null. Held keys (`repeat`) do nothing: one press, one step.
export function keyAction(key, { repeat = false, phase = 'empty' } = {}) {
  if (repeat) return null;
  if (key === 'Escape' || key === 'Esc') return 'exit';
  switch (phase) {
    case 'card':
      if (FLIP_KEYS.has(key)) return 'flip';
      if (key === 'ArrowLeft' || key === 'Left') return STILL_LEARNING;
      if (key === 'ArrowRight' || key === 'Right') return KNOW;
      if (key === 'Backspace') return 'undo';
      return null;
    case 'roundDone':
      if (key === 'Enter') return 'nextRound';
      if (key === 'Backspace') return 'undo';
      return null;
    case 'finished':
      if (key === 'Enter') return 'restart';
      if (key === 'Backspace') return 'undo';
      return null;
    default:
      return null;
  }
}

/* ------------------------------------------------------------------- copy */

// "1 Karte", "12 Karten".
export function cardsLabel(n) {
  return plural(n, 'Karte', 'Karten');
}

export function verdictTitle(verdict) {
  return verdict === KNOW ? 'Weiss ich' : 'Lerne ich noch';
}

// The set page's line under a running deck: "Nur markierte · Runde 2 · 8 von 12 gewusst".
export function runningDetail(deck) {
  const round = deckPhase(deck) === 'roundDone' ? `Runde ${deck.round} geschafft` : `Runde ${deck.round}`;
  const parts = [round, `${knownCount(deck)} von ${deckTotal(deck)} gewusst`];
  if (deck.starredOnly) parts.unshift('Nur markierte');
  return parts.join(' · ');
}

// The Return action after a round: "Weiter mit 4 Karten".
export function nextRoundAction(deck) {
  return `Weiter mit ${cardsLabel(learningCount(deck))}`;
}

export function roundDoneTitle(deck) {
  return knownInRound(deck) === 0 ? 'Bleib dran!' : 'Du machst Fortschritte!';
}

// "Du kennst 8 von 12 Karten. Die 4 Karten, die du noch lernst, kommen jetzt nochmal."
export function roundDoneText(deck) {
  const learning = learningCount(deck);
  const again =
    learning === 1
      ? 'Die Karte, die du noch lernst, kommt jetzt nochmal.'
      : `Die ${learning} Karten, die du noch lernst, kommen jetzt nochmal.`;
  return `Du kennst ${knownCount(deck)} von ${cardsLabel(deckTotal(deck))}. ${again}`;
}

export function finishedTitle(deck) {
  const total = deckTotal(deck);
  return total === 1 ? 'Super, du kennst die Karte!' : `Super, du kennst alle ${total} Karten!`;
}

export function finishedText(deck) {
  const rounds = deck.round === 1 ? 'Gleich in der ersten Runde – stark.' : `Geschafft in ${deck.round} Runden.`;
  return `${rounds} Teste dich jetzt in «Lernen», damit sie auch als gemeistert zählen.`;
}

// The confirmation before starting over.
export function restartMessage(deck) {
  return `Deine Sortierung (${runningDetail(deck)}) beginnt von vorne. Dein Lernfortschritt bleibt erhalten.`;
}
