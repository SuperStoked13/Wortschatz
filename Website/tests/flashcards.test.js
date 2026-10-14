// Karteikarten: the deck model ported from the Mac's FlashcardsTests (turning cards over, sorting
// them into «Weiss ich» / «Lerne ich noch», rounds, taking a sort back, following changes of the
// set, the keys), plus the opening rules, the copy, the swipe and motion helpers and the
// shortcuts of the screen. The screen modules are imported to prove they load under jsc.
import { test, expect, run } from './harness.js';
import * as F from '../src/core/flashcards.js';
import { SWIPE, createSwipeTracker, swipeOffset, swipeLean, armedVerdict } from '../src/screens/flashcards-swipe.js';
import { cardTextSize, cardHeightFor, cubicBezier, turnAt, glideAt, glideTransform, turnTransform, sampledFrames, MOTION, STACK } from '../src/screens/flashcards-card.js';
import { commandFor } from '../src/screens/flashcards-keys.js';
import { shortcutText, backspaceText } from '../src/screens/flashcards-views.js';

const T0 = 1_760_000_000_000;

// Deterministic rng (mulberry32), as in the Mac tests.
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const card = (id, term = 'le mot', definition = 'das Wort', starred = false) => ({ id, term, definition, starred });
const CARDS = [card('a'), card('b'), card('c'), card('d')];
const deckOf = (cards = CARDS, starredOnly = false) => F.newDeck(cards, { starredOnly, now: T0 });
const sameSet = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());

/* ------------------------------------------------------------- starting */

test('a new deck shows the cards with text in the set order, front side up', () => {
  const cards = [card('a'), card('empty', ' ', ''), card('b', '', 'nur Deutsch'), card('a')];
  const deck = deckOf(cards);
  expect(deck.queue).toEqual(['a', 'b']);
  expect(F.currentCardId(deck)).toBe('a');
  expect(F.deckPhase(deck)).toBe('card');
  expect(deck.isFlipped).toBe(false);
  expect([deck.round, F.deckTotal(deck), F.deckStats(deck).remaining]).toEqual([1, 2, 2]);
  expect(F.hasProgress(deck)).toBe(false);
  expect(F.canUndo(deck)).toBe(false);
});

test('starred only takes the starred cards; none starred is an empty deck', () => {
  const cards = [card('a'), card('b', 'x', 'y', true), card('c', 'x', 'y', true)];
  expect(deckOf(cards, true).queue).toEqual(['b', 'c']);
  expect(F.deckPhase(deckOf([card('a')], true))).toBe('empty');
  expect(F.deckPhase(deckOf([]))).toBe('empty');
});

test('shuffled decks contain every card once and replay with the same seed', () => {
  const cards = Array.from({ length: 20 }, (_, i) => card(`c${i}`));
  const one = F.newDeck(cards, { shuffled: true, rng: mulberry32(7), now: T0 });
  const two = F.newDeck(cards, { shuffled: true, rng: mulberry32(7), now: T0 });
  expect(one.queue).toEqual(two.queue);
  expect(sameSet(one.queue, cards.map((c) => c.id))).toBe(true);
  expect(one.queue).not.toEqual(cards.map((c) => c.id));
  expect(one.isShuffled).toBe(true);
});

/* --------------------------------------------------- flipping and sorting */

test('flipping turns the card; sorting moves on with the next card front side up', () => {
  let deck = deckOf();
  deck = F.flipCard(deck, T0 + 1);
  expect(deck.isFlipped).toBe(true);
  deck = F.flipCard(deck, T0 + 2);
  expect(deck.isFlipped).toBe(false);
  deck = F.flipCard(deck, T0 + 3);
  deck = F.sortCard(deck, 'know', T0 + 4);
  expect(F.lastSort(deck)).toEqual({ cardID: 'a', verdict: 'know' });
  expect(F.currentCardId(deck)).toBe('b');
  expect(deck.isFlipped).toBe(false);
  expect([F.knownCount(deck), F.learningCount(deck), F.deckStats(deck).remaining]).toEqual([1, 0, 3]);
  expect(F.upcomingIds(deck)).toEqual(['c', 'd']);
  expect(F.hasProgress(deck) && F.canUndo(deck)).toBe(true);
  expect(deck.updatedAt).toBe(T0 + 4);
});

test('a card can be sorted without turning it over', () => {
  const deck = F.sortCard(deckOf(), 'stillLearning', T0);
  expect(F.learningCount(deck)).toBe(1);
  expect(F.currentCardId(deck)).toBe('b');
});

test('undo brings the last card back front side up, also from the round summary', () => {
  let deck = deckOf([card('a'), card('b')]);
  deck = F.sortCard(deck, 'know', T0);
  deck = F.flipCard(deck, T0);
  deck = F.sortCard(deck, 'stillLearning', T0);
  expect(F.deckPhase(deck)).toBe('roundDone');
  expect(F.lastSort(deck).cardID).toBe('b');
  deck = F.undoSort(deck, T0);
  expect([F.deckPhase(deck), F.currentCardId(deck), deck.isFlipped]).toEqual(['card', 'b', false]);
  expect([F.learningCount(deck), F.knownCount(deck)]).toEqual([0, 1]);
  deck = F.undoSort(deck, T0);
  expect(F.currentCardId(deck)).toBe('a');
  expect(F.lastSort(deck)).toBe(null);
  expect(F.undoSort(deck, T0 + 5)).toBe(deck);
});

/* ------------------------------------------------------------------ rounds */

test('after a round the cards still being learnt come again; known ones stay known', () => {
  let deck = deckOf();
  for (const v of ['know', 'stillLearning', 'know', 'stillLearning']) deck = F.sortCard(deck, v, T0);
  expect(F.deckPhase(deck)).toBe('roundDone');
  expect(F.currentCardId(deck)).toBe(null);
  expect(F.nextRoundAction(deck)).toBe('Weiter mit 2 Karten');
  expect(F.runningDetail(deck)).toBe('Runde 1 geschafft · 2 von 4 gewusst');

  deck = F.startNextRound(deck, { now: T0 });
  expect(deck.round).toBe(2);
  expect(deck.queue).toEqual(['b', 'd']);
  expect(deck.knownEarlier).toEqual(['a', 'c']);
  expect([F.knownCount(deck), F.deckTotal(deck), F.deckStats(deck).remaining]).toEqual([2, 4, 2]);
  expect(F.canUndo(deck)).toBe(false);
  expect(F.runningDetail(deck)).toBe('Runde 2 · 2 von 4 gewusst');

  deck = F.sortCard(F.sortCard(deck, 'know', T0), 'know', T0);
  expect(F.deckPhase(deck)).toBe('finished');
  expect(F.knownCount(deck)).toBe(4);
  expect(F.knownShare(deck)).toBe(1);
  expect(F.isResumable(deck)).toBe(false);
  expect(F.finishedTitle(deck)).toBe('Super, du kennst alle 4 Karten!');
  expect(F.finishedText(deck).startsWith('Geschafft in 2 Runden.')).toBe(true);
});

test('everything known in the first round finishes at once', () => {
  let deck = F.sortCard(deckOf([card('a')]), 'know', T0);
  expect(F.deckPhase(deck)).toBe('finished');
  expect(F.finishedTitle(deck)).toBe('Super, du kennst die Karte!');
  expect(F.finishedText(deck)).toBe('Gleich in der ersten Runde – stark. Teste dich jetzt in «Lernen», damit sie auch als gemeistert zählen.');
  // Nothing happens to a finished deck.
  expect(F.startNextRound(deck, { now: T0 })).toBe(deck);
  expect(deck.round).toBe(1);
  expect(F.sortCard(deck, 'know', T0)).toBe(deck);
  expect(F.flipCard(deck, T0)).toBe(deck);
});

test("the round summary's text counts singular and plural", () => {
  let deck = deckOf([card('a'), card('b')]);
  deck = F.sortCard(F.sortCard(deck, 'stillLearning', T0), 'know', T0);
  expect(F.roundDoneTitle(deck)).toBe('Du machst Fortschritte!');
  expect(F.roundDoneText(deck)).toBe('Du kennst 1 von 2 Karten. Die Karte, die du noch lernst, kommt jetzt nochmal.');
  expect(F.nextRoundAction(deck)).toBe('Weiter mit 1 Karte');

  let none = deckOf([card('a'), card('b')]);
  none = F.sortCard(F.sortCard(none, 'stillLearning', T0), 'stillLearning', T0);
  expect(F.roundDoneTitle(none)).toBe('Bleib dran!');
  expect(F.roundDoneText(none)).toBe('Du kennst 0 von 2 Karten. Die 2 Karten, die du noch lernst, kommen jetzt nochmal.');
});

test('a shuffled deck shuffles the next round too', () => {
  const cards = Array.from({ length: 12 }, (_, i) => card(`c${i}`));
  let deck = F.newDeck(cards, { shuffled: true, rng: mulberry32(3), now: T0 });
  const first = deck.queue.slice();
  for (let i = 0; i < first.length; i++) deck = F.sortCard(deck, 'stillLearning', T0);
  deck = F.startNextRound(deck, { rng: mulberry32(99), now: T0 });
  expect(sameSet(deck.queue, first)).toBe(true);
  expect(deck.queue).not.toEqual(first);
});

/* ----------------------------------------------------------------- options */

test('shuffling on and off reorders only the cards after the current one', () => {
  const cards = Array.from({ length: 10 }, (_, i) => card(`c${i}`));
  const order = cards.map((c) => c.id);
  let deck = F.newDeck(cards, { now: T0 });
  deck = F.sortCard(F.sortCard(deck, 'know', T0), 'stillLearning', T0);
  deck = F.setShuffled(deck, true, { cardOrder: order, rng: mulberry32(5), now: T0 });
  expect(deck.isShuffled).toBe(true);
  expect(deck.queue.slice(0, 3)).toEqual(['c0', 'c1', 'c2']);
  expect(sameSet(deck.queue, order)).toBe(true);
  expect(deck.queue).not.toEqual(order);
  deck = F.setShuffled(deck, false, { cardOrder: order, now: T0 });
  expect(deck.queue).toEqual(order);
  expect(deck.sorts.length).toBe(2);
});

test("shuffling turned off at the round summary puts the next round in the set's order", () => {
  const cards = Array.from({ length: 8 }, (_, i) => card(`c${i}`));
  const order = cards.map((c) => c.id);
  let deck = F.newDeck(cards, { shuffled: true, rng: mulberry32(3), now: T0 });
  for (let i = 0; i < order.length; i++) deck = F.sortCard(deck, 'stillLearning', T0);
  expect(F.deckPhase(deck)).toBe('roundDone');
  deck = F.setShuffled(deck, false, { cardOrder: order, now: T0 });
  deck = F.startNextRound(deck, { cardOrder: order, now: T0 });
  expect(deck.queue).toEqual(order);
});

/* ---------------------------------------------------------- changes of the set */

test('deleted cards leave the deck, new cards join at the end of the round', () => {
  let deck = deckOf();
  deck = F.sortCard(deck, 'know', T0); // a
  deck = F.sortCard(deck, 'stillLearning', T0); // b
  deck = F.flipCard(deck, T0); // c is up, back side
  const set1 = [card('a'), card('c'), card('d'), card('e')];
  const changed = F.syncDeck(deck, set1, T0 + 9);
  expect(changed !== deck).toBe(true);
  deck = changed;
  expect(deck.queue).toEqual(['a', 'c', 'd', 'e']);
  expect(deck.sorts).toEqual([{ cardID: 'a', verdict: 'know' }]);
  expect(F.currentCardId(deck)).toBe('c');
  expect(deck.isFlipped).toBe(true);
  expect(F.isConsistent(deck)).toBe(true);
  expect(deck.updatedAt).toBe(T0 + 9);
  const again = F.syncDeck(deck, set1, T0 + 10);
  expect(again).toBe(deck);
  expect(again.updatedAt).toBe(T0 + 9);

  // The current card deleted: the next one comes up front side first.
  deck = F.syncDeck(deck, [card('a'), card('d'), card('e')], T0);
  expect(F.currentCardId(deck)).toBe('d');
  expect(deck.isFlipped).toBe(false);
});

test('known cards of earlier rounds that are deleted leave the totals', () => {
  let deck = deckOf([card('a'), card('b')]);
  deck = F.sortCard(F.sortCard(deck, 'know', T0), 'stillLearning', T0);
  deck = F.startNextRound(deck, { now: T0 });
  deck = F.syncDeck(deck, [card('b')], T0);
  expect(deck.knownEarlier).toEqual([]);
  expect(F.deckTotal(deck)).toBe(1);
  deck = F.syncDeck(deck, [], T0);
  expect(F.deckPhase(deck)).toBe('empty');
});

test('starred only keeps cards whose star was removed and takes newly starred ones in', () => {
  let deck = deckOf([card('a', 'x', 'y', true), card('b')], true);
  expect(deck.queue).toEqual(['a']);
  deck = F.syncDeck(deck, [card('a'), card('b', 'x', 'y', true)], T0);
  expect(deck.queue).toEqual(['a', 'b']);
});

test('a stored deck is checked before it is used', () => {
  const deck = F.sortCard(deckOf(), 'know', T0);
  expect(F.isConsistent(deck)).toBe(true);
  const decoded = F.parseDeck(JSON.stringify(deck));
  expect(decoded).toEqual(deck);

  // A sort that does not belong to its card.
  const broken = '{"round":1,"queue":["a","b"],"sorts":[{"cardID":"b","verdict":"know"}],"knownEarlier":[],"isFlipped":false,"starredOnly":false,"isShuffled":false,"updatedAt":0}';
  expect(F.parseDeck(broken)).toBe(null);
  expect(F.isConsistent(JSON.parse(broken))).toBe(false);
  const twice = '{"round":2,"queue":["a"],"sorts":[],"knownEarlier":["a"],"isFlipped":false,"starredOnly":false,"isShuffled":false,"updatedAt":0}';
  expect(F.parseDeck(twice)).toBe(null);
  expect(F.isConsistent(JSON.parse(twice))).toBe(false);
});

/* ----------------------------------------------------------------------- keys */

test('Space, Enter and ↑↓ turn the card; ← and → sort; Backspace takes back; Esc leaves', () => {
  const action = (key, repeat = false) => F.keyAction(key, { repeat, phase: 'card' });
  expect(action(' ')).toBe('flip');
  expect(action('Enter')).toBe('flip');
  expect(action('ArrowUp')).toBe('flip');
  expect(action('ArrowDown')).toBe('flip');
  expect(action('ArrowLeft')).toBe('stillLearning');
  expect(action('ArrowRight')).toBe('know');
  expect(action('Backspace')).toBe('undo');
  expect(action('Escape')).toBe('exit');
  expect(action('x')).toBe(null);
  expect(action('1')).toBe(null);
  // A held key is one step.
  expect(action('ArrowRight', true)).toBe(null);
  expect(action(' ', true)).toBe(null);
});

test('Enter continues after a round and starts over at the end', () => {
  const action = (key, phase) => F.keyAction(key, { repeat: false, phase });
  expect(action('Enter', 'roundDone')).toBe('nextRound');
  expect(action('Backspace', 'roundDone')).toBe('undo');
  expect(action('ArrowRight', 'roundDone')).toBe(null);
  expect(action('Enter', 'finished')).toBe('restart');
  expect(action('Backspace', 'finished')).toBe('undo');
  expect(action(' ', 'finished')).toBe(null);
  expect(action('Enter', 'empty')).toBe(null);
  expect(action('Escape', 'empty')).toBe('exit');
  expect(F.keyAction('Escape', { repeat: true, phase: 'card' })).toBe(null);
});

/* ------------------------------------------------------- more edge cases */

test('operations return new decks and never change their input', () => {
  const deck = deckOf();
  const frozen = JSON.stringify(deck);
  F.flipCard(deck, T0 + 1);
  const sorted = F.sortCard(deck, 'stillLearning', T0 + 1);
  F.undoSort(sorted, T0 + 2);
  F.setShuffled(deck, true, { cardOrder: ['a', 'b', 'c', 'd'], rng: mulberry32(1), now: T0 });
  F.syncDeck(deck, [card('a')], T0);
  expect(JSON.stringify(deck)).toBe(frozen);
  let done = F.sortCard(F.sortCard(F.sortCard(sorted, 'know', T0), 'know', T0), 'know', T0);
  const doneJson = JSON.stringify(done);
  F.startNextRound(done, { cardOrder: ['d', 'c', 'b', 'a'], now: T0 });
  expect(JSON.stringify(done)).toBe(doneJson);
});

test('invalid verdicts and empty decks change nothing', () => {
  const deck = deckOf();
  expect(F.sortCard(deck, 'maybe', T0)).toBe(deck);
  const empty = deckOf([]);
  expect(F.flipCard(empty, T0)).toBe(empty);
  expect(F.undoSort(empty, T0)).toBe(empty);
  expect(F.deckPhase(null)).toBe('empty');
  expect(F.deckStats(null).total).toBe(0);
  expect(F.knownShare(empty)).toBe(0);
});

test('the next round in set order puts unknown ids last, as they were', () => {
  expect(F.orderedIds(['x', 'c', 'a', 'y'], ['a', 'b', 'c'])).toEqual(['a', 'c', 'x', 'y']);
  let deck = deckOf([card('b'), card('a')]);
  deck = F.sortCard(F.sortCard(deck, 'stillLearning', T0), 'stillLearning', T0);
  expect(F.startNextRound(deck, { cardOrder: ['a', 'b'], now: T0 }).queue).toEqual(['a', 'b']);
  expect(F.startNextRound(deck, { now: T0 }).queue).toEqual(['b', 'a']);
});

test('shuffling with one card or fewer left after the current one only flips the flag', () => {
  let deck = F.sortCard(deckOf([card('a'), card('b'), card('c')]), 'know', T0);
  const shuffled = F.setShuffled(deck, true, { cardOrder: ['a', 'b', 'c'], rng: mulberry32(2), now: T0 + 1 });
  expect(shuffled.queue).toEqual(['a', 'b', 'c']);
  expect(shuffled.isShuffled).toBe(true);
  expect(F.setShuffled(shuffled, true, { now: T0 })).toBe(shuffled);
});

test('a round done deck that gains a card shows it; the round goes on', () => {
  let deck = deckOf([card('a')]);
  deck = F.sortCard(deck, 'stillLearning', T0);
  expect(F.deckPhase(deck)).toBe('roundDone');
  deck = F.syncDeck(deck, [card('a'), card('n')], T0 + 1);
  expect(F.deckPhase(deck)).toBe('card');
  expect(F.currentCardId(deck)).toBe('n');
  expect(F.deckStats(deck)).toEqual({
    phase: 'card',
    round: 1,
    currentCardId: 'n',
    upcoming: 0,
    total: 2,
    roundSize: 2,
    sorted: 1,
    remaining: 1,
    shown: 2,
    known: 0,
    learning: 1,
    knownInRound: 0,
    canUndo: true,
    hasProgress: true,
  });
});

test('a card emptied on both sides leaves the deck, its sort with it', () => {
  let deck = F.sortCard(deckOf([card('a'), card('b'), card('c')]), 'know', T0);
  deck = F.syncDeck(deck, [card('a', ' ', '\n'), card('b'), card('c')], T0);
  expect(deck.queue).toEqual(['b', 'c']);
  expect(deck.sorts).toEqual([]);
  expect(F.isConsistent(deck)).toBe(true);
});

test('parseDeck keeps exactly the Mac keys, with defaults for the flags', () => {
  const deck = F.parseDeck({ round: 3, queue: ['a'], sorts: [], knownEarlier: ['b'], extra: 1, isFlipped: 'yes' });
  expect(deck).toEqual({ round: 3, queue: ['a'], sorts: [], knownEarlier: ['b'], isFlipped: false, starredOnly: false, isShuffled: false, updatedAt: 0 });
  for (const junk of [null, 1, 'x', '{', [], { round: 1 }, { round: 1.5, queue: [], sorts: [], knownEarlier: [] }, { round: 1, queue: [1], sorts: [], knownEarlier: [] }]) {
    expect(F.parseDeck(junk)).toBe(null);
  }
  expect(F.parseDeck({ round: 0, queue: [], sorts: [], knownEarlier: [] })).toBe(null);
  expect(F.parseDeck({ round: 1, queue: ['a'], sorts: [{ cardID: 'a', verdict: 'know' }, { cardID: 'b', verdict: 'know' }], knownEarlier: [] })).toBe(null);
  expect(F.parseDeck({ round: 1, queue: ['a'], sorts: [{ cardID: 'a', verdict: 'sure' }], knownEarlier: [] })).toBe(null);
});

test('the set page line and the restart question name the subset, the round and the known cards', () => {
  let deck = F.newDeck([card('a', 'x', 'y', true), card('b', 'x', 'y', true), card('c')], { starredOnly: true, now: T0 });
  deck = F.sortCard(deck, 'know', T0);
  expect(F.runningDetail(deck)).toBe('Nur markierte · Runde 1 · 1 von 2 gewusst');
  expect(F.restartMessage(deck)).toBe('Deine Sortierung (Nur markierte · Runde 1 · 1 von 2 gewusst) beginnt von vorne. Dein Lernfortschritt bleibt erhalten.');
  expect(F.cardsLabel(1)).toBe('1 Karte');
  expect(F.cardsLabel(0)).toBe('0 Karten');
  expect(F.verdictTitle('know')).toBe('Weiss ich');
  expect(F.verdictTitle('stillLearning')).toBe('Lerne ich noch');
  const texts = [F.runningDetail, F.nextRoundAction, F.roundDoneTitle, F.roundDoneText, F.finishedTitle, F.finishedText, F.restartMessage].map((fn) => fn(deck)).join(' ');
  expect(texts.includes('ß')).toBe(false);
});

/* ----------------------------------------------------- opening a deck */

const open = (opts) => F.startingDeck({ cards: CARDS, now: T0 + 100, rng: mulberry32(4), ...opts });

test('opening resumes the stored deck, synced, front side up', () => {
  let saved = F.flipCard(F.sortCard(deckOf(), 'know', T0), T0);
  const deck = open({ saved, cards: [...CARDS, card('e')] });
  expect(deck.sorts).toEqual([{ cardID: 'a', verdict: 'know' }]);
  expect(deck.queue).toEqual(['a', 'b', 'c', 'd', 'e']);
  expect(deck.isFlipped).toBe(false);
  // At the round summary too.
  saved = F.sortCard(F.newDeck([card('a')], { now: T0 }), 'stillLearning', T0);
  expect(F.deckPhase(open({ saved, cards: [card('a')] }))).toBe('roundDone');
});

test('opening applies «Mischen» to the resumed deck after its current card', () => {
  const cards = Array.from({ length: 10 }, (_, i) => card(`c${i}`));
  const saved = F.sortCard(F.newDeck(cards, { now: T0 }), 'know', T0);
  const deck = open({ saved, cards, shuffled: true });
  expect(deck.isShuffled).toBe(true);
  expect(deck.queue.slice(0, 2)).toEqual(['c0', 'c1']);
  expect(deck.sorts.length).toBe(1);
});

test('a forced new deck, another subset, or a finished deck starts round 1', () => {
  const saved = F.sortCard(deckOf(), 'know', T0);
  expect(open({ saved, forceNew: true }).sorts).toEqual([]);
  expect(open({ saved, subset: 'all' }).sorts.length).toBe(1);
  const starredCards = [card('a', 'x', 'y', true), card('b')];
  const starredSaved = F.sortCard(F.newDeck(starredCards, { starredOnly: true, now: T0 }), 'stillLearning', T0);
  expect(open({ saved: starredSaved, cards: starredCards, subset: 'all' }).queue).toEqual(['a', 'b']);
  expect(open({ saved: starredSaved, cards: starredCards }).starredOnly).toBe(true);
  expect(open({ saved: starredSaved, cards: starredCards, subset: 'starred' }).sorts.length).toBe(1);
  let finished = deckOf([card('a')]);
  finished = F.sortCard(finished, 'know', T0);
  const fresh = open({ saved: finished, cards: [card('a')] });
  expect([fresh.round, fresh.sorts.length, F.deckPhase(fresh)]).toEqual([1, 0, 'card']);
});

test('a starred-only deck without starred cards becomes one of all cards', () => {
  const deck = open({ subset: 'starred' });
  expect(deck.starredOnly).toBe(false);
  expect(deck.queue).toEqual(['a', 'b', 'c', 'd']);
  expect(F.restartDeck(CARDS, { starredOnly: true, now: T0 }).starredOnly).toBe(false);
  const starred = F.restartDeck([card('a'), card('b', 'x', 'y', true)], { starredOnly: true, shuffled: true, now: T0 });
  expect([starred.starredOnly, starred.isShuffled, starred.queue]).toEqual([true, true, ['b']]);
  expect(F.deckPhase(open({ cards: [] }))).toBe('empty');
});

test('the running deck of the set page has sorted cards and is not finished', () => {
  expect(F.runningDeck(null, CARDS)).toBe(null);
  expect(F.runningDeck(deckOf(), CARDS)).toBe(null);
  const sorted = F.sortCard(deckOf(), 'know', T0);
  expect(F.runningDeck(sorted, CARDS).sorts.length).toBe(1);
  // As the set is now: its card deleted, nothing was sorted any more.
  expect(F.runningDeck(sorted, CARDS.slice(1))).toBe(null);
  let next = F.startNextRound(F.sortCard(F.sortCard(deckOf([card('a'), card('b')]), 'know', T0), 'stillLearning', T0), { now: T0 });
  expect(F.runningDeck(next, [card('a'), card('b')]).round).toBe(2);
  expect(F.runningDeck(F.sortCard(next, 'know', T0), [card('a'), card('b')])).toBe(null);
});

test('the side up follows «Vorderseite» and the flip', () => {
  expect(F.showsTermSide('term', false)).toBe(true);
  expect(F.showsTermSide('term', true)).toBe(false);
  expect(F.showsTermSide('definition', false)).toBe(false);
  expect(F.showsTermSide('definition', true)).toBe(true);
});

/* ---------------------------------------------------------------- swipe */

test('the card follows freely to 170 px, then reluctantly; armed at 110 px', () => {
  expect(swipeOffset(100)).toBe(100);
  expect(swipeOffset(-170)).toBe(-170);
  expect(swipeOffset(220)).toBe(170 + 50 * 0.4);
  expect(swipeOffset(-270)).toBe(-(170 + 100 * 0.4));
  expect(swipeLean(55)).toBe(0.5);
  expect(swipeLean(-500)).toBe(-1);
  expect(armedVerdict(109)).toBe(null);
  expect(armedVerdict(110)).toBe('know');
  expect(armedVerdict(-110)).toBe('stillLearning');
});

test('letting go past the threshold sorts; before it the card springs back', () => {
  const t = createSwipeTracker();
  t.begin(0);
  t.moveTo(60, 100);
  t.moveTo(120, 400); // slow
  expect(t.armed).toBe('know');
  expect(t.end(420)).toBe('know');
  t.begin(0);
  t.moveTo(-40, 200);
  t.moveTo(-60, 400);
  expect(t.end(410)).toBe(null);
  expect(t.end(500)).toBe(null); // not tracking any more
});

test('a quick flick sorts too: velocity over the last 120 ms projected 140 ms ahead', () => {
  const t = createSwipeTracker();
  t.begin(1000);
  t.moveTo(-20, 1010);
  t.moveTo(-60, 1030);
  t.moveTo(-90, 1050); // 1500 px/s over the samples
  expect(t.end(1060)).toBe('stillLearning');
  // The same flick let go late (last sample older than 80 ms) springs back.
  t.begin(1000);
  t.moveTo(-20, 1010);
  t.moveTo(-60, 1030);
  t.moveTo(-90, 1050);
  expect(t.end(1140)).toBe(null);
  // A flick must have travelled 16 px, and in the direction it was moving.
  t.begin(0);
  t.moveTo(10, 5);
  t.moveTo(15, 10);
  expect(t.end(12)).toBe(null);
});

test('wheel deltas add up and the tracker resets', () => {
  const t = createSwipeTracker();
  t.moveBy(50, 0); // not tracking: ignored
  expect(t.travel).toBe(0);
  t.begin(0);
  t.moveBy(40, 10);
  t.moveBy(40, 20);
  expect(t.offset).toBe(80);
  expect(t.isTracking).toBe(true);
  t.reset();
  expect([t.travel, t.isTracking]).toEqual([0, false]);
  expect(SWIPE.wheelGapMs).toBeGreaterThan(119);
  expect(SWIPE.wheelGapMs).toBeLessThan(151);
});

/* --------------------------------------------------------------- motion */

test('card text sizes and the card height follow the Mac', () => {
  expect(cardTextSize('x'.repeat(23))).toEqual({ size: 46, weight: 600 });
  expect(cardTextSize('x'.repeat(24))).toEqual({ size: 36, weight: 600 });
  expect(cardTextSize('x'.repeat(59)).size).toBe(36);
  expect(cardTextSize('x'.repeat(60)).size).toBe(28);
  expect(cardTextSize('x'.repeat(139)).size).toBe(28);
  expect(cardTextSize('x'.repeat(140))).toEqual({ size: 22, weight: 500 });
  expect(cardTextSize('été').size).toBe(46);
  expect(cardHeightFor(720, 1000)).toBe(418);
  expect(cardHeightFor(1000, 1000)).toBe(440);
  expect(cardHeightFor(720, 300)).toBe(300);
  expect(cardHeightFor(300, 1000)).toBe(240);
  expect(cardHeightFor(720, 100)).toBe(240);
  expect(STACK.depth).toBe(18);
});

test('a turn lifts the card halfway and lands flat, with the light gone', () => {
  const flat = turnAt(0);
  expect([flat.showsBack, flat.tilt, flat.lift, flat.sheen]).toEqual([false, 0, 0, 0]);
  const edge = turnAt(90);
  expect(edge.lift).toBe(1);
  expect(edge.showsBack).toBe(false);
  expect(turnAt(91).showsBack).toBe(true);
  const back = turnAt(180);
  expect([back.showsBack, back.tilt, back.lift]).toEqual([true, 0, 0]);
  expect(back.sheen).toBe(0);
  expect(turnAt(360).showsBack).toBe(false);
  expect(turnAt(-90).lift).toBe(1);
  // The streak runs from the lower part toward the top through a half-turn.
  expect(turnAt(10).sheenPosition).toBeGreaterThan(turnAt(170).sheenPosition);
  expect(turnTransform(180)).toBe('translateY(0.00px) scale(1.0000) rotate3d(1, 0.12, 0, 180.00deg)');
  expect(turnTransform(90).startsWith('translateY(-10.00px) scale(1.0450)')).toBe(true);
});

test('a sorted card glides 280 px, drops 24 px, leans 6°, shrinks to 0.94 and fades from a third', () => {
  expect(glideAt(0)).toEqual({ x: 0, y: 0, rotate: 0, scale: 1, opacity: 1 });
  const gone = glideAt(1);
  expect([gone.x, gone.y, gone.rotate, gone.opacity]).toEqual([280, 24, 6, 0]);
  expect(Math.abs(gone.scale - 0.94) < 1e-9).toBe(true);
  expect(glideAt(-1).x).toBe(-280);
  expect(glideAt(-1).rotate).toBe(-6);
  expect(glideAt(0.3).opacity).toBe(1);
  expect(glideAt(0.6).opacity).toBeLessThan(1);
  // Under a swipe it never fades.
  expect(glideAt(0.9, 0).opacity).toBe(1);
  expect(glideTransform(glideAt(0.5))).toBe('translate(140.00px, 6.00px) rotate(3.000deg) scale(0.9700)');
});

test('bezier curves start at 0, end at 1 and follow CSS', () => {
  const ease = cubicBezier(0.25, 0.1, 0.25, 1);
  expect(ease(0)).toBe(0);
  expect(ease(1)).toBe(1);
  expect(Math.abs(ease(0.5) - 0.8024) < 0.001).toBe(true);
  const flip = cubicBezier(...MOTION.flip.curve);
  let last = 0;
  for (let i = 1; i <= 20; i++) {
    const v = flip(i / 20);
    expect(v).toBeGreaterThanOrEqual(last);
    expect(v).toBeLessThanOrEqual(1);
    last = v;
  }
  const frames = sampledFrames(MOTION.glide.curve, (e) => ({ e }), 10);
  expect(frames.length).toBe(11);
  expect([frames[0].offset, frames[0].e, frames[10].offset, frames[10].e]).toEqual([0, 0, 1, 1]);
  expect([MOTION.flip.duration, MOTION.glide.duration, MOTION.glide.delay, MOTION.fling.duration, MOTION.snapBack.duration, MOTION.arrive.duration]).toEqual([620, 500, 60, 420, 360, 480]);
});

/* ------------------------------------------------------------ shortcuts */

test('shortcuts: Ctrl on Windows, ⌘ on Apple, never with Alt (AltGr)', () => {
  const ev = (key, mods = {}) => ({ key, code: `Key${key.toUpperCase()}`, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, ...mods });
  expect(commandFor(ev('k', { ctrlKey: true }))).toBe('options');
  expect(commandFor(ev('R', { ctrlKey: true, shiftKey: true }))).toBe('restart');
  expect(commandFor(ev('r', { ctrlKey: true }))).toBe('speak');
  expect(commandFor(ev('d', { ctrlKey: true }))).toBe('star');
  expect(commandFor(ev('e', { ctrlKey: true }))).toBe('edit');
  expect(commandFor(ev('k', { ctrlKey: true, altKey: true }))).toBe(null);
  expect(commandFor(ev('K', { ctrlKey: true, shiftKey: true }))).toBe(null);
  expect(commandFor(ev('k'))).toBe(null);
  expect(commandFor(ev('k', { metaKey: true }))).toBe(null);
  expect(commandFor(ev('k', { metaKey: true }), true)).toBe('options');
  expect(commandFor(ev('x', { ctrlKey: true }))).toBe(null);
  // Other scripts: the key's position counts.
  expect(commandFor({ key: 'л', code: 'KeyK', ctrlKey: true }, false)).toBe('options');
  expect(shortcutText('K')).toBe('Strg+K');
  expect(shortcutText('R', { shift: true })).toBe('Strg+Umschalt+R');
  expect(shortcutText('R', { apple: true, shift: true })).toBe('⇧⌘R');
  expect(backspaceText(false)).toBe('Rücktaste');
  expect(backspaceText(true)).toBe('⌫');
});

/* ---------------------------------------------------- screen modules load */

test('the screen modules import under jsc', async () => {
  const screen = await import('../src/screens/flashcards.js');
  expect(typeof screen.render).toBe('function');
  const views = await import('../src/screens/flashcards-views.js');
  for (const name of ['createFlashcardsSidebar', 'createActionBar', 'summaryView', 'emptyView', 'openFlashcardsOptions']) expect(typeof views[name]).toBe('function');
  const stage = await import('../src/screens/flashcards-card.js');
  expect(typeof stage.createCardStage).toBe('function');
  const swipe = await import('../src/screens/flashcards-swipe.js');
  expect(typeof swipe.bindSwipe).toBe('function');
  const keys = await import('../src/screens/flashcards-keys.js');
  expect(typeof keys.bindFlashcardKeys).toBe('function');
});

/* ------------------------------------------------- the screen on a fake DOM */

// A small DOM (jsc has none): enough of the tree, attributes, events, selectors, Web
// Animations, timers and frames to run the screen and check its behaviour.
function installFakeDom() {
  const kebab = (k) => String(k).replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
  const saved = {};
  for (const k of ['document', 'window', 'localStorage', 'history', 'location', 'requestAnimationFrame', 'cancelAnimationFrame', 'getComputedStyle', 'matchMedia', 'ResizeObserver', 'setTimeout', 'clearTimeout', 'queueMicrotask', 'performance', 'innerWidth', 'innerHeight', 'scrollY', 'addEventListener', 'removeEventListener', 'scrollTo']) {
    saved[k] = globalThis[k];
  }
  const winListeners = {};
  const animations = [];
  let clock = 1000;
  let frames = [];
  let timers = [];
  let timerId = 0;

  class FText {
    constructor(text) {
      this.nodeType = 3;
      this.data = String(text);
      this.parentNode = null;
    }
    get textContent() {
      return this.data;
    }
    set textContent(v) {
      this.data = String(v);
    }
  }

  // Compound selectors (tag, .class, #id, [attr], [attr="v"], :not(…)), descendant
  // combinators and comma lists.
  function matchCompound(el, sel) {
    let rest = sel.trim();
    const nots = [];
    rest = rest.replace(/:not\(([^)]*)\)/g, (_, inner) => {
      nots.push(inner);
      return '';
    });
    const re = /^([a-z][a-z0-9-]*)|\.([\w-]+)|#([\w-]+)|\[([\w-]+)(?:="([^"]*)")?\]/gi;
    let m;
    while ((m = re.exec(rest))) {
      if (m[1] && el.localName !== m[1].toLowerCase()) return false;
      if (m[2] && !el.classList.contains(m[2])) return false;
      if (m[3] && el.getAttribute('id') !== m[3]) return false;
      if (m[4] && (!el.hasAttribute(m[4]) || (m[5] !== undefined && el.getAttribute(m[4]) !== m[5]))) return false;
    }
    return nots.every((n) => !matchCompound(el, n));
  }

  class FElement {
    constructor(tag) {
      this.nodeType = 1;
      this.localName = String(tag).toLowerCase();
      this.tagName = this.localName.toUpperCase();
      this.childNodes = [];
      this.parentNode = null;
      this.attrs = new Map();
      this.listeners = {};
      const props = new Map();
      this.style = {
        setProperty(name, value) {
          props.set(name, String(value));
        },
        removeProperty(name) {
          props.delete(name);
        },
        getPropertyValue(name) {
          return props.has(name) ? props.get(name) : '';
        },
      };
      const self = this;
      this.dataset = new Proxy(
        {},
        {
          get: (_, k) => (typeof k === 'string' && self.hasAttribute(`data-${kebab(k)}`) ? self.getAttribute(`data-${kebab(k)}`) : undefined),
          set: (_, k, v) => {
            self.setAttribute(`data-${kebab(k)}`, String(v));
            return true;
          },
          deleteProperty: (_, k) => {
            self.removeAttribute(`data-${kebab(k)}`);
            return true;
          },
          has: (_, k) => self.hasAttribute(`data-${kebab(k)}`),
        },
      );
      this.classList = {
        list: () => (self.getAttribute('class') || '').split(/\s+/).filter(Boolean),
        contains: (n) => self.classList.list().includes(n),
        add: (...ns) => self.setAttribute('class', [...new Set([...self.classList.list(), ...ns])].join(' ')),
        remove: (...ns) => self.setAttribute('class', self.classList.list().filter((x) => !ns.includes(x)).join(' ')),
        toggle: (n, force) => {
          const on = force === undefined ? !self.classList.contains(n) : !!force;
          if (on) self.classList.add(n);
          else self.classList.remove(n);
          return on;
        },
      };
      this.value = '';
      this.checked = false;
      this.inert = false;
      this.tabIndex = -1;
      this.offsetWidth = 0;
      this.offsetHeight = 0;
      this.offsetLeft = 0;
      this.offsetTop = 0;
      this.clientWidth = 700;
      this.clientHeight = 0;
      this.scrollHeight = 0;
    }
    get hidden() {
      return this.hasAttribute('hidden');
    }
    set hidden(v) {
      if (v) this.setAttribute('hidden', '');
      else this.removeAttribute('hidden');
    }
    get disabled() {
      return this.hasAttribute('disabled');
    }
    set disabled(v) {
      if (v) this.setAttribute('disabled', '');
      else this.removeAttribute('disabled');
    }
    get autofocus() {
      return this.hasAttribute('autofocus');
    }
    set autofocus(v) {
      if (v) this.setAttribute('autofocus', '');
      else this.removeAttribute('autofocus');
    }
    get className() {
      return this.getAttribute('class') || '';
    }
    set className(v) {
      this.setAttribute('class', v);
    }
    get id() {
      return this.getAttribute('id') || '';
    }
    set id(v) {
      this.setAttribute('id', v);
    }
    set htmlFor(v) {
      this.setAttribute('for', v);
    }
    set innerHTML(v) {
      this.replaceChildren();
    }
    setAttribute(n, v) {
      this.attrs.set(n, String(v));
    }
    getAttribute(n) {
      return this.attrs.has(n) ? this.attrs.get(n) : null;
    }
    hasAttribute(n) {
      return this.attrs.has(n);
    }
    removeAttribute(n) {
      this.attrs.delete(n);
    }
    appendChild(node) {
      if (node.parentNode) node.parentNode.removeChild(node);
      node.parentNode = this;
      this.childNodes.push(node);
      return node;
    }
    append(...nodes) {
      for (const n of nodes) this.appendChild(typeof n === 'string' ? new FText(n) : n);
    }
    prepend(...nodes) {
      for (const n of nodes.reverse()) this.insertBefore(typeof n === 'string' ? new FText(n) : n, this.childNodes[0] || null);
    }
    insertBefore(node, ref) {
      if (node.parentNode) node.parentNode.removeChild(node);
      const i = ref ? this.childNodes.indexOf(ref) : -1;
      node.parentNode = this;
      if (i < 0) this.childNodes.push(node);
      else this.childNodes.splice(i, 0, node);
      return node;
    }
    removeChild(node) {
      const i = this.childNodes.indexOf(node);
      if (i >= 0) this.childNodes.splice(i, 1);
      node.parentNode = null;
      return node;
    }
    remove() {
      if (this.parentNode) this.parentNode.removeChild(this);
    }
    replaceChildren(...nodes) {
      for (const n of this.childNodes) n.parentNode = null;
      this.childNodes = [];
      this.append(...nodes);
    }
    replaceWith(node) {
      const parent = this.parentNode;
      if (!parent) return;
      parent.insertBefore(node, this);
      parent.removeChild(this);
    }
    get children() {
      return this.childNodes.filter((n) => n.nodeType === 1);
    }
    get firstChild() {
      return this.childNodes[0] || null;
    }
    get firstElementChild() {
      return this.children[0] || null;
    }
    get parentElement() {
      return this.parentNode && this.parentNode.nodeType === 1 ? this.parentNode : null;
    }
    get isConnected() {
      let n = this;
      while (n.parentNode) n = n.parentNode;
      return n === globalThis.document.documentElement;
    }
    contains(node) {
      for (let n = node; n; n = n.parentNode) if (n === this) return true;
      return false;
    }
    get textContent() {
      return this.childNodes.map((n) => n.textContent).join('');
    }
    set textContent(v) {
      this.replaceChildren();
      if (v != null && v !== '') this.append(String(v));
    }
    matches(selector) {
      return selector.split(',').some((part) => {
        // Descendant combinators: the last compound here, the others on ancestors in order.
        const compounds = part.trim().split(/\s+/);
        if (!matchCompound(this, compounds.pop())) return false;
        let node = this.parentNode;
        while (compounds.length) {
          while (node && node.nodeType === 1 && !matchCompound(node, compounds[compounds.length - 1])) node = node.parentNode;
          if (!node || node.nodeType !== 1) return false;
          compounds.pop();
          node = node.parentNode;
        }
        return true;
      });
    }
    closest(selector) {
      for (let n = this; n && n.nodeType === 1; n = n.parentNode) if (n.matches(selector)) return n;
      return null;
    }
    querySelectorAll(selector) {
      const out = [];
      const walk = (node) => {
        for (const child of node.children) {
          if (child.matches(selector)) out.push(child);
          walk(child);
        }
      };
      walk(this);
      return out;
    }
    querySelector(selector) {
      return this.querySelectorAll(selector)[0] || null;
    }
    addEventListener(type, fn) {
      (this.listeners[type] = this.listeners[type] || []).push(fn);
    }
    removeEventListener(type, fn) {
      this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn);
    }
    dispatchEvent(props) {
      return fire(this, props);
    }
    click() {
      fire(this, { type: 'click' });
    }
    focus() {
      globalThis.document.activeElement = this;
    }
    blur() {}
    getBoundingClientRect() {
      return { top: 120, bottom: 520, left: 0, right: 700, width: 700, height: 400 };
    }
    getClientRects() {
      return [this.getBoundingClientRect()];
    }
    setPointerCapture() {}
    releasePointerCapture() {}
    animate(keyframes, options) {
      const anim = {
        keyframes,
        options,
        el: this,
        playState: 'running',
        currentTime: 0,
        onfinish: null,
        cancel() {
          this.playState = 'idle';
        },
        finish() {
          if (this.playState !== 'running') return;
          this.playState = 'finished';
          if (typeof this.onfinish === 'function') this.onfinish();
        },
        commitStyles() {
          const last = keyframes[keyframes.length - 1] || {};
          if (last.transform) this.el.style.transform = last.transform;
        },
      };
      animations.push(anim);
      return anim;
    }
  }

  const doc = {
    activeElement: null,
    listeners: {},
    createElement: (tag) => new FElement(tag),
    createElementNS: (_, tag) => new FElement(tag),
    createTextNode: (text) => new FText(text),
    addEventListener(type, fn) {
      (this.listeners[type] = this.listeners[type] || []).push(fn);
    },
    removeEventListener(type, fn) {
      this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn);
    },
    getElementById(id) {
      return doc.documentElement.querySelector(`#${id}`);
    },
    querySelector(sel) {
      return doc.documentElement.querySelector(sel);
    },
  };
  doc.documentElement = new FElement('html');
  doc.body = new FElement('body');
  doc.documentElement.append(doc.body);

  // Bubbles from the target up to the document and the window.
  function fire(target, props) {
    let stopped = false;
    const e = {
      bubbles: true,
      defaultPrevented: false,
      timeStamp: clock,
      ...props,
      target,
      preventDefault() {
        this.defaultPrevented = true;
      },
      stopPropagation() {
        stopped = true;
      },
    };
    const chain = [];
    for (let n = target; n; n = n.parentNode) chain.push(n.listeners || {});
    chain.push(doc.listeners, winListeners);
    for (const listeners of chain) {
      for (const fn of (listeners[e.type] || []).slice()) fn(e);
      if (stopped) break;
    }
    return !e.defaultPrevented;
  }

  Object.assign(globalThis, {
    document: doc,
    window: globalThis,
    innerWidth: 1200,
    innerHeight: 820,
    scrollY: 0,
    scrollTo() {},
    addEventListener(type, fn) {
      (winListeners[type] = winListeners[type] || []).push(fn);
    },
    removeEventListener(type, fn) {
      winListeners[type] = (winListeners[type] || []).filter((f) => f !== fn);
    },
    location: { hash: '' },
    history: {
      state: null,
      replaceState(state, _title, url) {
        this.state = state;
        if (url != null) globalThis.location.hash = String(url);
      },
    },
    requestAnimationFrame(fn) {
      frames.push(fn);
      return frames.length;
    },
    cancelAnimationFrame() {},
    getComputedStyle: () => ({ marginTop: '20px', getPropertyValue: () => '' }),
    matchMedia: (q) => ({ matches: env.reduced && /reduce/.test(q), addEventListener() {}, removeEventListener() {} }),
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    setTimeout(fn, ms = 0) {
      timers.push({ id: ++timerId, at: clock + (Number(ms) || 0), fn });
      return timerId;
    },
    clearTimeout(id) {
      timers = timers.filter((t) => t.id !== id);
    },
    queueMicrotask: (fn) => Promise.resolve().then(fn),
    performance: { now: () => clock },
  });

  const env = {
    doc,
    reduced: false,
    animations,
    // Runs the frames requested so far.
    flushFrames() {
      for (let i = 0; i < 5 && frames.length; i++) {
        const run = frames;
        frames = [];
        for (const fn of run) fn(clock);
      }
    },
    // Moves the clock on and runs the timers that are due.
    advance(ms) {
      const until = clock + ms;
      for (;;) {
        const due = timers.filter((t) => t.at <= until).sort((a, b) => a.at - b.at)[0];
        if (!due) break;
        timers = timers.filter((t) => t !== due);
        clock = Math.max(clock, due.at);
        due.fn();
      }
      clock = until;
    },
    finishAnimations() {
      for (const a of animations.slice()) a.finish();
    },
    key(key, mods = {}) {
      return fire(doc.activeElement || doc.body, { type: 'keydown', key, repeat: false, ...mods });
    },
    fire,
    restore() {
      for (const [k, v] of Object.entries(saved)) {
        if (v === undefined) delete globalThis[k];
        else globalThis[k] = v;
      }
    },
  };
  return env;
}

const textOf = (el) => (el ? el.textContent.replace(/\s+/g, ' ').trim() : null);

test('the screen on a fake DOM: opening, flipping, sorting, rounds, undo, restart, options, keys and swipes', async () => {
  const env = installFakeDom();
  try {
    const { db, memoryStorage } = await import('../src/store/db.js');
    globalThis.localStorage = memoryStorage();
    const { getPref, PREF } = await import('../src/lib/prefs.js');
    const { render } = await import('../src/screens/flashcards.js');
    const set = db.createSet({
      title: 'Französisch 1',
      termLang: 'fr',
      defLang: 'de',
      cards: [
        { term: 'la voiture', definition: 'das Auto' },
        { term: 'le chat', definition: 'die Katze' },
        { term: 'le chien', definition: 'der Hund', starred: true },
      ],
    });
    const [a, b, c] = set.cards.map((x) => x.id);
    globalThis.location.hash = `#/set/${set.id}/flashcards?new=1`;
    const outlet = env.doc.createElement('main');
    env.doc.body.append(outlet);
    const titles = [];
    const navs = [];
    const cleanup = render(outlet, { params: { id: set.id }, query: { new: '1' }, setTitle: (t) => titles.push(t), navigate: (p) => navs.push(p) });
    env.flushFrames();

    // Opening: title, URL without new=1, a stored deck, the first card front side up.
    expect(titles[titles.length - 1]).toBe('Französisch 1 – Karteikarten');
    expect(globalThis.location.hash).toBe(`#/set/${set.id}/flashcards`);
    expect(db.getFlashcards(set.id).queue).toEqual([a, b, c]);
    const current = () => outlet.querySelector('.fc-card.is-current');
    const upText = () => {
      const el = current();
      return textOf(el.querySelector(`.fc-face--${el.dataset.up} .fc-face__text`));
    };
    expect(upText()).toBe('la voiture');
    expect(textOf(current().querySelector('.fc-face--front .fc-face__label'))).toBe('Französisch');
    expect(textOf(current().querySelector('.fc-face--back .fc-face__label'))).toBe('Deutsch');
    expect(textOf(current().querySelector('.fc-face--back .fc-face__hint'))).toBe('␣Vorderseite');
    const primary = outlet.querySelector('.fc-bar__primary');
    expect(textOf(primary.querySelector('.ui-btn__label'))).toBe('Umdrehen');
    expect(env.doc.activeElement).toBe(primary);
    expect(outlet.querySelector('.fc-bar__undo').disabled).toBe(true);
    expect(textOf(outlet.querySelector('.wr-side__progress-value'))).toBe('1 von 3');
    expect(outlet.querySelector('.fc-stack').dataset.count).toBe('2');
    expect(outlet.querySelector('.fc-deck').style.getPropertyValue('--fc-card-h')).toBe('406px');

    // Space turns the card (no sound, an announcement), held keys do nothing.
    env.key(' ', { target: env.doc.body });
    env.doc.activeElement = env.doc.body;
    env.key(' ');
    expect(db.getFlashcards(set.id).isFlipped).toBe(true);
    expect(current().classList.contains('is-turning')).toBe(true);
    env.key(' ', { repeat: true });
    expect(db.getFlashcards(set.id).isFlipped).toBe(true);
    env.finishAnimations();
    expect(current().dataset.up).toBe('back');
    expect(current().classList.contains('is-turning')).toBe(false);
    env.advance(100);
    expect(textOf(outlet.querySelector('.sr-only'))).toBe('Deutsch: das Auto');

    // → «Weiss ich»: the card glides off sealed, the next one rises, focus on the primary.
    env.key('ArrowRight');
    const leaving = outlet.querySelector('.fc-card.is-leaving');
    expect(!!leaving && leaving.classList.contains('is-sealed')).toBe(true);
    expect(leaving.dataset.verdict).toBe('know');
    expect(upText()).toBe('le chat');
    expect(db.getFlashcards(set.id).sorts).toEqual([{ cardID: a, verdict: 'know' }]);
    expect(env.doc.activeElement).toBe(primary);
    expect(textOf(outlet.querySelector('.fc-sort--know .fc-sort__count'))).toBe('1');
    env.advance(100);
    expect(textOf(outlet.querySelector('.sr-only'))).toBe('Weiss ich. Französisch: le chat');

    // ← twice: the round is over, the summary shows, Enter waits for the lock.
    env.doc.activeElement = env.doc.body;
    env.key('ArrowLeft');
    env.key('ArrowLeft');
    let deck = db.getFlashcards(set.id);
    expect(F.deckPhase(deck)).toBe('roundDone');
    expect(outlet.querySelector('.fc-stage').dataset.mode).toBe('summary');
    expect(textOf(outlet.querySelector('.fc-sum__title'))).toBe('Du machst Fortschritte!');
    expect(textOf(outlet.querySelector('.fc-sum__text'))).toBe('Du kennst 1 von 3 Karten. Die 2 Karten, die du noch lernst, kommen jetzt nochmal.');
    expect(textOf(primary.querySelector('.ui-btn__label'))).toBe('Weiter mit 2 Karten');
    expect(outlet.querySelector('.fc-bar__back').hidden).toBe(false);
    expect(outlet.querySelector('.fc-sort--know').hidden).toBe(true);
    env.doc.activeElement = env.doc.body;
    env.key('Enter');
    expect(db.getFlashcards(set.id).round).toBe(1);

    // Backspace from the summary: the last card comes back along its path.
    env.key('Backspace');
    deck = db.getFlashcards(set.id);
    expect([F.deckPhase(deck), F.currentCardId(deck)]).toEqual(['card', c]);
    expect(upText()).toBe('le chien');
    expect(outlet.querySelector('.fc-stage').dataset.mode).toBe('card');
    env.key('ArrowLeft');
    env.advance(400);
    env.doc.activeElement = env.doc.body;
    env.key('Enter');
    deck = db.getFlashcards(set.id);
    expect([deck.round, deck.queue, deck.knownEarlier]).toEqual([2, [b, c], [a]]);
    expect(upText()).toBe('le chat');
    expect(textOf(outlet.querySelector('.wr-side__round'))).toBe('Runde 2');

    // A drag to the right past the threshold sorts the card; a short one springs back.
    const drag = (dx) => {
      const el = current().querySelector('.fc-face__body');
      env.fire(el, { type: 'pointerdown', pointerId: 1, pointerType: 'mouse', button: 0, clientX: 300, clientY: 200, isPrimary: true });
      env.fire(el, { type: 'pointermove', pointerId: 1, pointerType: 'mouse', clientX: 300 + dx / 2, clientY: 200 });
      env.advance(300);
      env.fire(el, { type: 'pointermove', pointerId: 1, pointerType: 'mouse', clientX: 300 + dx, clientY: 200 });
      env.flushFrames();
      env.advance(300);
      env.fire(el, { type: 'pointerup', pointerId: 1, pointerType: 'mouse', clientX: 300 + dx, clientY: 200 });
    };
    drag(60);
    expect(F.deckStats(db.getFlashcards(set.id)).sorted).toBe(0);
    expect(current().classList.contains('is-swiping')).toBe(false);
    drag(150);
    deck = db.getFlashcards(set.id);
    expect(deck.sorts).toEqual([{ cardID: b, verdict: 'know' }]);
    // A click without a drag turns the card.
    const body = current().querySelector('.fc-face__body');
    env.fire(body, { type: 'pointerdown', pointerId: 2, pointerType: 'mouse', button: 0, clientX: 10, clientY: 10, isPrimary: true });
    env.fire(body, { type: 'pointerup', pointerId: 2, pointerType: 'mouse', clientX: 11, clientY: 10 });
    env.fire(body, { type: 'click' });
    expect(db.getFlashcards(set.id).isFlipped).toBe(true);

    // Two fingers sideways on the touchpad: the gesture ends after a pause and sorts the card.
    env.finishAnimations();
    const root = outlet.querySelector('.fc');
    for (let i = 0; i < 6; i++) {
      env.fire(root, { type: 'wheel', deltaX: 30, deltaY: 1, deltaMode: 0, ctrlKey: false });
      env.advance(16);
    }
    env.flushFrames();
    env.advance(200);
    deck = db.getFlashcards(set.id);
    expect(F.deckPhase(deck)).toBe('roundDone');
    expect(deck.sorts[1]).toEqual({ cardID: c, verdict: 'stillLearning' });

    // Ctrl+Shift+R asks first (cards were sorted); confirming starts round 1 again.
    env.advance(400);
    env.key('R', { ctrlKey: true, shiftKey: true, code: 'KeyR' });
    let modal = env.doc.body.querySelector('.ui-modal');
    expect(textOf(modal.querySelector('.ui-modal__title'))).toBe('Karteikarten neu starten?');
    expect(textOf(modal.querySelector('.ui-confirm__message'))).toBe('Deine Sortierung (Runde 2 geschafft · 2 von 3 gewusst) beginnt von vorne. Dein Lernfortschritt bleibt erhalten.');
    // Keys of the screen wait while the dialog is open.
    env.key('ArrowRight');
    const confirm = modal.querySelectorAll('button').find((x) => textOf(x) === 'Neu starten');
    confirm.click();
    await Promise.resolve();
    await Promise.resolve();
    deck = db.getFlashcards(set.id);
    expect([deck.round, deck.sorts.length, deck.queue.length]).toEqual([1, 0, 3]);
    expect(upText()).toBe('la voiture');

    // Options: «Mischen» and «Vorderseite» are global and apply at once.
    env.advance(1000);
    env.doc.activeElement = env.doc.body;
    env.key('k', { ctrlKey: true, code: 'KeyK' });
    modal = env.doc.body.querySelectorAll('.ui-modal').pop();
    expect(textOf(modal.querySelector('.ui-modal__title'))).toBe('Optionen');
    expect(textOf(modal)).toContain('Nur markierte (1)');
    expect(textOf(modal)).toContain('Karteikarten zählen nicht für «Gemeistert». Dafür fragen dich Lernen und Schreiben ab.');
    const shuffle = modal.querySelectorAll('.ui-toggle__input')[0];
    shuffle.checked = true;
    shuffle.dispatchEvent({ type: 'change' });
    expect(getPref(PREF.flashcardsShuffle, false)).toBe(true);
    expect(db.getFlashcards(set.id).isShuffled).toBe(true);
    const defSide = modal.querySelectorAll('.ui-seg__btn').find((x) => textOf(x) === 'Deutsch');
    defSide.click();
    expect(getPref(PREF.flashcardsFront, 'term')).toBe('definition');
    expect(upText()).toBe('das Auto');
    // «Nur markierte» starts over with the starred card.
    const starredToggle = modal.querySelectorAll('.ui-toggle__input')[1];
    starredToggle.checked = true;
    starredToggle.dispatchEvent({ type: 'change' });
    deck = db.getFlashcards(set.id);
    expect([deck.starredOnly, deck.queue]).toEqual([true, [c]]);
    expect(globalThis.location.hash).toBe(`#/set/${set.id}/flashcards?subset=starred`);
    modal.querySelectorAll('button').find((x) => textOf(x) === 'Fertig').click();
    env.advance(400);

    // Ctrl+D stars, the deck follows the set; deleting the card on screen shows the next one.
    env.doc.activeElement = env.doc.body;
    env.key('d', { ctrlKey: true, code: 'KeyD' });
    expect(db.getSet(set.id).cards[2].starred).toBe(false);
    expect(db.getFlashcards(set.id).queue).toEqual([c]);
    db.updateSet(set.id, { cards: db.getSet(set.id).cards.map((x) => (x.id === a ? { ...x, starred: true } : x)) });
    expect(db.getFlashcards(set.id).queue).toEqual([c, a]);
    db.updateSet(set.id, { cards: db.getSet(set.id).cards.filter((x) => x.id !== c) });
    deck = db.getFlashcards(set.id);
    expect(F.currentCardId(deck)).toBe(a);
    expect(upText()).toBe('das Auto');

    // Sorting never records answers, progress or activity.
    expect(db.getProgress(set.id)).toEqual({});
    expect(db.getActivity()).toEqual({});

    // Esc leaves for the set.
    env.key('Escape');
    expect(navs[navs.length - 1]).toBe(`/set/${set.id}`);
    cleanup();
    expect(env.doc.listeners.keydown.length).toBe(1); // only the tooltip/modal helpers of the kit remain
  } finally {
    env.restore();
  }
});

test('the screen on a fake DOM: an empty set and a missing set', async () => {
  const env = installFakeDom();
  try {
    const { db, memoryStorage } = await import('../src/store/db.js');
    globalThis.localStorage = memoryStorage();
    const { setPref, PREF } = await import('../src/lib/prefs.js');
    // «Vorderseite» and «Mischen» are global: the test before changed them.
    setPref(PREF.flashcardsFront, null);
    setPref(PREF.flashcardsShuffle, null);
    const { render } = await import('../src/screens/flashcards.js');
    const set = db.createSet({ title: 'Leer', termLang: 'fr', cards: [] });
    globalThis.location.hash = `#/set/${set.id}/flashcards`;
    const outlet = env.doc.createElement('main');
    env.doc.body.append(outlet);
    const navs = [];
    const cleanup = render(outlet, { params: { id: set.id }, query: {}, setTitle() {}, navigate: (p) => navs.push(p) });
    expect(textOf(outlet.querySelector('.ui-empty__title'))).toBe('Keine Karten zum Umdrehen');
    expect(outlet.querySelector('.fc').classList.contains('wr--solo')).toBe(true);
    expect(outlet.querySelector('.fc-bar').hidden).toBe(true);
    const add = outlet.querySelector('.fc-empty [data-primary="true"]');
    expect(textOf(add.querySelector('.ui-btn__label'))).toBe('Begriffe hinzufügen');
    expect(textOf(add.querySelector('.ui-btn__kbd'))).toBe('↵');
    expect(env.doc.activeElement).toBe(add);
    add.click();
    expect(navs).toEqual([`/set/${set.id}/edit`]);
    // Cards added elsewhere: the deck starts.
    db.updateSet(set.id, { cards: [{ term: 'un', definition: 'eins' }] });
    expect(textOf(outlet.querySelector('.fc-card.is-current .fc-face--front .fc-face__text'))).toBe('un');
    expect(outlet.querySelector('.fc').classList.contains('wr--solo')).toBe(false);
    // The set deleted elsewhere: «Lernset nicht gefunden».
    db.deleteSet(set.id);
    expect(textOf(outlet)).toContain('Lernset nicht gefunden');
    cleanup();

    const outlet2 = env.doc.createElement('main');
    env.doc.body.append(outlet2);
    render(outlet2, { params: { id: 'nope' }, query: {}, setTitle() {}, navigate() {} })();
    expect(textOf(outlet2)).toContain('Lernset nicht gefunden');
  } finally {
    env.restore();
  }
});

test('the screen on a fake DOM: sounds, reduced motion, the end of the deck and «Lernen»', async () => {
  const env = installFakeDom();
  env.reduced = true;
  const played = [];
  try {
    const { renderSound } = await import('../src/lib/sounds.js');
    const lengths = new Map(['know', 'stillLearning', 'undo', 'roundDone', 'finished'].map((name) => [renderSound(name).length, name]));
    globalThis.AudioContext = class {
      constructor() {
        this.sampleRate = 44100;
        this.state = 'running';
        this.destination = {};
      }
      createBuffer(_channels, length) {
        return { length, getChannelData: () => ({ set() {} }) };
      }
      createBufferSource() {
        const source = { connect() {}, start: () => played.push(lengths.get(source.buffer.length) || 'other') };
        return source;
      }
      createGain() {
        return { gain: { value: 1 }, connect() {} };
      }
    };
    const { db, memoryStorage } = await import('../src/store/db.js');
    globalThis.localStorage = memoryStorage();
    const { setPref, PREF } = await import('../src/lib/prefs.js');
    setPref(PREF.flashcardsFront, null);
    setPref(PREF.flashcardsShuffle, null);
    const { render } = await import('../src/screens/flashcards.js');
    const set = db.createSet({ title: 'Zwei', termLang: 'fr', defLang: 'fr', cards: [{ term: 'oui', definition: '' }, { term: 'non', definition: 'nein' }] });
    globalThis.location.hash = `#/set/${set.id}/flashcards`;
    const outlet = env.doc.createElement('main');
    env.doc.body.append(outlet);
    const navs = [];
    const cleanup = render(outlet, { params: { id: set.id }, query: {}, setTitle() {}, navigate: (p) => navs.push(p) });
    env.flushFrames();
    const current = () => outlet.querySelector('.fc-card.is-current');
    // Same languages: «Begriff» / «Definition»; an empty side says «Keine Angabe».
    expect(textOf(current().querySelector('.fc-face--front .fc-face__label'))).toBe('Begriff');
    expect(textOf(current().querySelector('.fc-face--back .fc-face__text'))).toBe('Keine Angabe');
    env.doc.activeElement = env.doc.body;

    // Reduced motion: the sides cross-fade at once, nothing turns; flipping is silent.
    env.key('ArrowDown');
    expect(current().dataset.up).toBe('back');
    expect(current().classList.contains('is-xfade')).toBe(true);
    expect(current().classList.contains('is-turning')).toBe(false);
    expect(played).toEqual([]);
    env.advance(100);
    expect(textOf(outlet.querySelector('.sr-only'))).toBe('Definition: Keine Angabe');

    // «Lerne ich noch» plays its sound; the round's last card plays the round's fanfare instead.
    outlet.querySelector('.fc-sort--learning').click();
    env.doc.activeElement = env.doc.body;
    env.key('ArrowRight');
    expect(played).toEqual(['stillLearning', 'roundDone']);
    expect(outlet.querySelector('.fc-sum').classList.contains('is-arriving')).toBe(false);
    // Backspace takes the last card back with the undo swish, Enter (after the lock) goes on.
    env.key('Backspace');
    expect(played[played.length - 1]).toBe('undo');
    env.key('ArrowRight');
    // The focused primary button keeps Enter (the browser clicks it), unless it comes too early.
    expect(env.doc.activeElement).toBe(outlet.querySelector('.fc-bar__primary'));
    expect(env.key('Enter')).toBe(false);
    env.advance(400);
    expect(env.key('Enter')).toBe(true);
    env.doc.activeElement = env.doc.body;
    env.key('Enter');
    expect(db.getFlashcards(set.id).round).toBe(2);
    env.key('ArrowRight');
    expect(played[played.length - 1]).toBe('finished');
    expect(textOf(outlet.querySelector('.fc-sum__title'))).toBe('Super, du kennst alle 2 Karten!');
    expect(textOf(outlet.querySelector('.fc-sum .wr-eyebrow'))).toBe('Karteikarten');
    expect(outlet.querySelectorAll('.fc-sum .wr-tile').length).toBe(2);
    expect(textOf(outlet.querySelector('.fc-bar__primary .ui-btn__label'))).toBe('Nochmal von vorne');
    expect(outlet.querySelector('.fc-bar__learn').hidden).toBe(false);

    // «Lernen» opens Lernen; «Nochmal von vorne» starts over without asking.
    outlet.querySelector('.fc-bar__learn').click();
    expect(navs).toEqual([`/set/${set.id}/learn`]);
    outlet.querySelector('.fc-bar__primary').click();
    expect(env.doc.body.querySelectorAll('.ui-modal').length).toBe(0);
    const deck = db.getFlashcards(set.id);
    expect([deck.round, deck.sorts.length, deck.knownEarlier.length]).toEqual([1, 0, 0]);
    expect(db.getProgress(set.id)).toEqual({});
    cleanup();
  } finally {
    delete globalThis.AudioContext;
    env.restore();
  }
});

test('the screen on a fake DOM: Space waits out the lock, the tools keep the focus, Enter adds terms', async () => {
  const env = installFakeDom();
  try {
    const { db, memoryStorage } = await import('../src/store/db.js');
    globalThis.localStorage = memoryStorage();
    const { setPref, PREF } = await import('../src/lib/prefs.js');
    setPref(PREF.flashcardsFront, null);
    setPref(PREF.flashcardsShuffle, null);
    const { render } = await import('../src/screens/flashcards.js');
    const set = db.createSet({ title: 'Eins', termLang: 'fr', defLang: 'de', cards: [{ term: 'un', definition: 'eins' }, { term: 'deux', definition: 'zwei' }] });
    globalThis.location.hash = `#/set/${set.id}/flashcards`;
    const outlet = env.doc.createElement('main');
    env.doc.body.append(outlet);
    const cleanup = render(outlet, { params: { id: set.id }, query: {}, setTitle() {}, navigate() {} });
    env.flushFrames();
    const primary = outlet.querySelector('.fc-bar__primary');
    const current = () => outlet.querySelector('.fc-card.is-current');

    // A short window: the card takes what is left above the action bar, measured from the
    // layout (offsetTop), not from the screen that is still sliding in.
    const deckEl = outlet.querySelector('.fc-deck');
    deckEl.offsetTop = 150;
    globalThis.innerHeight = 520;
    env.fire(env.doc.body, { type: 'resize' });
    env.flushFrames();
    expect(deckEl.style.getPropertyValue('--fc-card-h')).toBe(`${520 - 150 - 18 - (20 + 16)}px`);
    globalThis.innerHeight = 820;

    // A mouse press on ★ or 🔊 does not take the focus from the primary button (Space would
    // press the star again instead of turning the card).
    const tools = current().querySelectorAll('.fc-face--front .fc-face__tools button');
    expect(tools.length).toBe(3);
    for (const tool of tools) expect(env.fire(tool, { type: 'mousedown', button: 0 })).toBe(false);
    expect(env.doc.activeElement).toBe(primary);

    // The round's last card: Space on the focused «Weiter mit 1 Karte» does nothing during the
    // lock (the browser would click it), then it is the button's again.
    env.key('ArrowLeft');
    env.key('ArrowRight');
    expect(F.deckPhase(db.getFlashcards(set.id))).toBe('roundDone');
    expect(env.doc.activeElement).toBe(primary);
    expect(env.key(' ')).toBe(false);
    expect(env.key(' ', { repeat: true })).toBe(false);
    env.advance(400);
    expect(env.key(' ')).toBe(true);
    // Keys the screen does not use stay the browser's.
    expect(env.key('x')).toBe(true);
    cleanup();

    // An empty set: Enter (focus anywhere) opens the editor, as «Begriffe hinzufügen».
    const empty = db.createSet({ title: 'Leer', termLang: 'fr', cards: [] });
    const outlet2 = env.doc.createElement('main');
    env.doc.body.append(outlet2);
    const navs = [];
    const cleanup2 = render(outlet2, { params: { id: empty.id }, query: {}, setTitle() {}, navigate: (p) => navs.push(p) });
    env.doc.activeElement = env.doc.body;
    expect(env.key('Enter')).toBe(false);
    expect(navs).toEqual([`/set/${empty.id}/edit`]);
    // The set deleted meanwhile: «Zur Übersicht» has the focus, Enter adds nothing any more.
    db.deleteSet(empty.id);
    expect(textOf(env.doc.activeElement)).toBe('Zur Übersicht');
    env.doc.activeElement = env.doc.body;
    env.advance(400);
    env.key('Enter');
    expect(navs.length).toBe(1);
    cleanup2();
  } finally {
    env.restore();
  }
});

test('the screen on a fake DOM: a starred-only deck whose cards are deleted goes on with all cards', async () => {
  const env = installFakeDom();
  try {
    const { db, memoryStorage } = await import('../src/store/db.js');
    globalThis.localStorage = memoryStorage();
    const { setPref, PREF } = await import('../src/lib/prefs.js');
    setPref(PREF.flashcardsFront, null);
    setPref(PREF.flashcardsShuffle, null);
    const { render } = await import('../src/screens/flashcards.js');
    const set = db.createSet({
      title: 'Stern',
      termLang: 'fr',
      defLang: 'de',
      cards: [
        { term: 'le soleil', definition: 'die Sonne', starred: true },
        { term: 'la lune', definition: 'der Mond' },
        { term: 'la mer', definition: 'das Meer' },
      ],
    });
    const [a, b, c] = set.cards.map((x) => x.id);
    globalThis.location.hash = `#/set/${set.id}/flashcards?new=1&subset=starred`;
    const outlet = env.doc.createElement('main');
    env.doc.body.append(outlet);
    const cleanup = render(outlet, { params: { id: set.id }, query: { new: '1', subset: 'starred' }, setTitle() {}, navigate() {} });
    env.flushFrames();
    expect(db.getFlashcards(set.id).queue).toEqual([a]);
    expect(globalThis.location.hash).toBe(`#/set/${set.id}/flashcards?subset=starred`);

    // Its only card deleted in the editor (another tab): not «Keine Karten zum Umdrehen», but
    // the set's other cards, and a URL that resumes them.
    db.updateSet(set.id, { cards: db.getSet(set.id).cards.filter((x) => x.id !== a) });
    const deck = db.getFlashcards(set.id);
    expect([deck.starredOnly, deck.queue, deck.round]).toEqual([false, [b, c], 1]);
    expect(outlet.querySelector('.fc-empty').hidden).toBe(true);
    expect(textOf(outlet.querySelector('.fc-card.is-current .fc-face--front .fc-face__text'))).toBe('la lune');
    expect(globalThis.location.hash).toBe(`#/set/${set.id}/flashcards`);

    // A press whose release was never heard does not block the next drag.
    const face = () => outlet.querySelector('.fc-card.is-current .fc-face__body');
    env.fire(face(), { type: 'pointerdown', pointerId: 5, pointerType: 'mouse', button: 0, clientX: 300, clientY: 200, isPrimary: true });
    env.fire(face(), { type: 'pointerdown', pointerId: 6, pointerType: 'mouse', button: 0, clientX: 300, clientY: 200, isPrimary: true });
    env.fire(face(), { type: 'pointermove', pointerId: 6, pointerType: 'mouse', clientX: 450, clientY: 200 });
    env.flushFrames();
    env.fire(face(), { type: 'pointerup', pointerId: 6, pointerType: 'mouse', clientX: 450, clientY: 200 });
    expect(db.getFlashcards(set.id).sorts).toEqual([{ cardID: b, verdict: 'know' }]);

    // Every card deleted: now the empty state, with its primary focused.
    db.updateSet(set.id, { cards: [] });
    expect(outlet.querySelector('.fc-empty').hidden).toBe(false);
    expect(env.doc.activeElement).toBe(outlet.querySelector('.fc-empty [data-primary="true"]'));
    cleanup();
  } finally {
    env.restore();
  }
});

await run('flashcards.test.js');
