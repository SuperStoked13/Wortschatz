import { test, expect, run } from './harness.js';
import {
  createSession,
  current,
  answer,
  override,
  isRoundOver,
  roundSummary,
  nextRound,
  isFinished,
  counters,
  finalStats,
  removeCard,
  tick,
} from '../src/core/session.js';

// ---------- helpers ----------

// Small seeded PRNG so shuffles are reproducible.
function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const T0 = 1760000000000;
const SEC = 1000;
const MIN = 60 * SEC;
const ORDERED = { answerWith: 'term', shuffle: false };

function makeCards(n) {
  return Array.from({ length: n }, (_, i) => ({
    id: `c${i + 1}`,
    term: `terme ${i + 1}`,
    definition: `Begriff ${i + 1}`,
    starred: i % 3 === 0,
  }));
}

function progressEntry(streak, correct, incorrect, lastResult) {
  return { correct, incorrect, streak, streakBefore: 0, lastResult, lastAnsweredAt: T0 - 1000 };
}

// Answers the current question with each value in `results` (true/false), 10 s apart.
function answerSeq(state, results, startAt = T0) {
  let s = state;
  results.forEach((r, i) => {
    s = answer(s, r, startAt + (i + 1) * 10 * SEC);
  });
  return s;
}

function deepFreeze(o) {
  if (o && typeof o === 'object' && !Object.isFrozen(o)) {
    Object.freeze(o);
    for (const k of Object.keys(o)) deepFreeze(o[k]);
  }
  return o;
}

const snapshot = (s) => JSON.stringify(s);
const cardsOf = (s, qids) => qids.map((q) => s.questions[q].cardId);

function hasAdjacentSiblings(state, qids) {
  for (let i = 1; i < qids.length; i++) {
    if (state.questions[qids[i]].cardId === state.questions[qids[i - 1]].cardId) return true;
  }
  return false;
}

// ---------- creation ----------

test('createSession answerWith term: one question per card, user types the term', () => {
  const s = createSession(makeCards(4), ORDERED, { now: T0 });
  expect(s.v).toBe(1);
  expect(s.setOptions).toEqual({ answerWith: 'term', shuffle: false });
  expect(s.subset).toBe('all');
  expect(s.order).toEqual(['c1:t', 'c2:t', 'c3:t', 'c4:t']);
  expect(s.queue).toEqual(s.order);
  expect(s.questions['c2:t']).toEqual({ qid: 'c2:t', cardId: 'c2', ask: 'term' });
  expect(s.round).toBe(1);
  expect(s.roundAnswered).toEqual([]);
  expect(s.rounds).toEqual([]);
  expect(s.done).toEqual([]);
  expect(s.attempts).toEqual({ 'c1:t': 0, 'c2:t': 0, 'c3:t': 0, 'c4:t': 0 });
  expect(s.misses['c3:t']).toBe(0);
  expect(s.firstTry).toEqual({});
  expect(s.startedAt).toBe(T0);
  expect(s.updatedAt).toBe(T0);
  expect(s.finishedAt).toBe(null);
  expect(s.elapsedMs).toBe(0);
  expect(isFinished(s)).toBe(false);
  expect(isRoundOver(s)).toBe(false);
});

test('createSession answerWith definition: user types the definition', () => {
  const s = createSession(makeCards(3), { answerWith: 'definition', shuffle: false }, { now: T0 });
  expect(s.order).toEqual(['c1:d', 'c2:d', 'c3:d']);
  expect(s.questions['c1:d']).toEqual({ qid: 'c1:d', cardId: 'c1', ask: 'definition' });
  expect(current(s)).toEqual({ qid: 'c1:d', cardId: 'c1', ask: 'definition' });
});

test('createSession answerWith both: two questions per card, unshuffled terms first', () => {
  const s = createSession(makeCards(3), { answerWith: 'both', shuffle: false }, { now: T0 });
  expect(s.order).toEqual(['c1:t', 'c2:t', 'c3:t', 'c1:d', 'c2:d', 'c3:d']);
  expect(Object.keys(s.questions).length).toBe(6);
  expect(s.questions['c3:d'].ask).toBe('definition');
  expect(s.questions['c3:t'].ask).toBe('term');
  expect(counters(s).total).toBe(6);
});

test('createSession shuffle is deterministic per seed and a permutation', () => {
  const cards = makeCards(20);
  const opts = { answerWith: 'term', shuffle: true };
  const a = createSession(cards, opts, { rng: mulberry32(42), now: T0 });
  const b = createSession(cards, opts, { rng: mulberry32(42), now: T0 });
  const c = createSession(cards, opts, { rng: mulberry32(7), now: T0 });
  const plain = createSession(cards, ORDERED, { now: T0 });
  expect(a.order).toEqual(b.order);
  expect(a.order).not.toEqual(plain.order);
  expect(a.order).not.toEqual(c.order);
  expect([...a.order].sort()).toEqual([...plain.order].sort());
  expect(a.queue).toEqual(a.order);
  expect(a.setOptions.shuffle).toBe(true);
});

test('createSession shuffle off keeps the card order', () => {
  const cards = makeCards(6);
  const s = createSession(cards, ORDERED, { rng: mulberry32(1), now: T0 });
  expect(cardsOf(s, s.order)).toEqual(cards.map((c) => c.id));
});

test('createSession with both + shuffle never asks a card twice in a row', () => {
  for (let n = 2; n <= 6; n++) {
    for (let seed = 1; seed <= 100; seed++) {
      const s = createSession(makeCards(n), { answerWith: 'both', shuffle: true }, { rng: mulberry32(seed), now: T0 });
      expect(s.order).toHaveLength(2 * n);
      if (hasAdjacentSiblings(s, s.order)) throw new Error(`adjacent siblings for n=${n} seed=${seed}: ${s.order}`);
    }
  }
});

test('createSession defaults: missing or invalid options', () => {
  const s = createSession(makeCards(3), undefined, { rng: mulberry32(3), now: T0 });
  expect(s.setOptions).toEqual({ answerWith: 'term', shuffle: true });
  const t = createSession(makeCards(3), { answerWith: 'bogus', shuffle: false }, { now: T0 });
  expect(t.setOptions.answerWith).toBe('term');
  expect(t.order).toEqual(['c1:t', 'c2:t', 'c3:t']);
  const u = createSession(makeCards(2), ORDERED);
  expect(typeof u.startedAt).toBe('number');
  expect(u.order).toHaveLength(2);
});

test('createSession skips cards with an empty side, duplicate ids and junk', () => {
  const cards = [
    { id: 'a', term: 'la rue', definition: 'die Strasse' },
    { id: 'b', term: '  ', definition: 'leer' },
    { id: 'c', term: 'le nom', definition: '' },
    { id: 'a', term: 'dup', definition: 'Duplikat' },
    null,
    { term: 'ohne id', definition: 'x' },
    { id: 'd', term: 'calme', definition: 'ruhig' },
  ];
  const s = createSession(cards, ORDERED, { now: T0 });
  expect(s.order).toEqual(['a:t', 'd:t']);
  expect(createSession(null, ORDERED, { now: T0 }).order).toEqual([]);
});

// ---------- subsets ----------

test('subset starred', () => {
  const cards = makeCards(7); // starred: c1, c4, c7
  const s = createSession(cards, ORDERED, { subset: 'starred', now: T0 });
  expect(s.subset).toBe('starred');
  expect(s.order).toEqual(['c1:t', 'c4:t', 'c7:t']);
});

test('subset learning excludes mastered cards (streak >= 2)', () => {
  const progress = {
    c1: progressEntry(2, 2, 0, 'correct'), // mastered
    c2: progressEntry(1, 1, 1, 'correct'), // learning
    c3: progressEntry(0, 0, 1, 'incorrect'), // learning
    c5: progressEntry(3, 4, 1, 'correct'), // mastered
  };
  const s = createSession(makeCards(5), ORDERED, { subset: 'learning', progress, now: T0 });
  expect(s.order).toEqual(['c2:t', 'c3:t', 'c4:t']);
  const none = createSession(makeCards(2), ORDERED, { subset: 'learning', now: T0 });
  expect(none.order).toEqual(['c1:t', 'c2:t']);
});

test('subset cardIds keeps the set order and ignores unknown ids', () => {
  const s = createSession(makeCards(6), ORDERED, { subset: { cardIds: ['c5', 'x9', 'c2', 'c5'] }, now: T0 });
  expect(s.order).toEqual(['c2:t', 'c5:t']);
  expect(s.subset).toEqual({ cardIds: ['c5', 'x9', 'c2', 'c5'] });
  const both = createSession(makeCards(6), { answerWith: 'both', shuffle: false }, { subset: { cardIds: ['c3'] }, now: T0 });
  expect(both.order).toEqual(['c3:t', 'c3:d']);
});

test('subset missed uses the last result in progress; unknown subset falls back to all', () => {
  const progress = { c2: progressEntry(0, 1, 1, 'incorrect'), c3: progressEntry(1, 1, 1, 'correct') };
  const s = createSession(makeCards(4), ORDERED, { subset: 'missed', progress, now: T0 });
  expect(s.order).toEqual(['c2:t']);
  const all = createSession(makeCards(2), ORDERED, { subset: 'whatever', now: T0 });
  expect(all.subset).toBe('all');
  expect(all.order).toEqual(['c1:t', 'c2:t']);
});

test('empty subset: zero questions, finished, every API safe', () => {
  const cards = makeCards(2).map((c) => ({ ...c, starred: false }));
  const s = createSession(cards, ORDERED, { subset: 'starred', now: T0 });
  expect(s.order).toEqual([]);
  expect(s.questions).toEqual({});
  expect(isFinished(s)).toBe(true);
  expect(isRoundOver(s)).toBe(true);
  expect(s.finishedAt).toBe(T0);
  expect(current(s)).toBe(null);
  expect(counters(s)).toEqual({ remaining: 0, correct: 0, incorrect: 0, total: 0, round: 1, progress: 0 });
  expect(roundSummary(s)).toEqual({ round: 1, total: 0, correct: 0, incorrect: 0, items: [] });
  expect(snapshot(answer(s, true, T0 + SEC))).toBe(snapshot(s));
  expect(snapshot(nextRound(s, mulberry32(1), T0 + SEC))).toBe(snapshot(s));
  expect(finalStats(s)).toEqual({ total: 0, firstTryCorrect: 0, accuracy: 0, rounds: 0, elapsedMs: 0, hardest: [], missedCardIds: [] });
  expect(createSession(makeCards(3), ORDERED, { subset: { cardIds: [] }, now: T0 }).order).toEqual([]);
});

// ---------- answering & counters ----------

test('answering flow: queue advances, misses are not retried in the same round', () => {
  let s = createSession(makeCards(4), ORDERED, { now: T0 });
  expect(current(s)).toEqual({ qid: 'c1:t', cardId: 'c1', ask: 'term' });

  s = answer(s, true, T0 + 10 * SEC);
  expect(s.done).toEqual(['c1:t']);
  expect(s.queue).toEqual(['c2:t', 'c3:t', 'c4:t']);
  expect(s.roundAnswered).toEqual([{ qid: 'c1:t', correct: true }]);
  expect(s.attempts['c1:t']).toBe(1);
  expect(s.firstTry['c1:t']).toBe(true);

  s = answer(s, false, T0 + 20 * SEC);
  expect(s.done).toEqual(['c1:t']);
  expect(s.misses['c2:t']).toBe(1);
  expect(s.firstTry['c2:t']).toBe(false);
  expect(current(s).qid).toBe('c3:t');

  s = answer(s, true, T0 + 30 * SEC);
  s = answer(s, false, T0 + 40 * SEC);
  expect(s.queue).toEqual([]);
  expect(current(s)).toBe(null);
  expect(isRoundOver(s)).toBe(true);
  expect(isFinished(s)).toBe(false);
  expect(s.finishedAt).toBe(null);
  expect(s.roundAnswered.map((a) => a.qid)).toEqual(['c1:t', 'c2:t', 'c3:t', 'c4:t']);
  // Answering past the end of the round changes nothing.
  expect(snapshot(answer(s, true, T0 + 50 * SEC))).toBe(snapshot(s));
});

test('counters follow Quizlet semantics at every step', () => {
  let s = createSession(makeCards(4), ORDERED, { now: T0 });
  expect(counters(s)).toEqual({ remaining: 4, correct: 0, incorrect: 0, total: 4, round: 1, progress: 0 });
  s = answer(s, true, T0 + SEC);
  expect(counters(s)).toEqual({ remaining: 3, correct: 1, incorrect: 0, total: 4, round: 1, progress: 0.25 });
  s = answer(s, false, T0 + 2 * SEC);
  expect(counters(s)).toEqual({ remaining: 2, correct: 1, incorrect: 1, total: 4, round: 1, progress: 0.25 });
  s = answer(s, false, T0 + 3 * SEC);
  expect(counters(s)).toEqual({ remaining: 1, correct: 1, incorrect: 2, total: 4, round: 1, progress: 0.25 });
  s = answer(s, true, T0 + 4 * SEC);
  expect(counters(s)).toEqual({ remaining: 0, correct: 2, incorrect: 2, total: 4, round: 1, progress: 0.5 });
  s = nextRound(s, mulberry32(1), T0 + 5 * SEC);
  // New round: incorrect resets, correct stays overall.
  expect(counters(s)).toEqual({ remaining: 2, correct: 2, incorrect: 0, total: 4, round: 2, progress: 0.5 });
  s = answer(s, false, T0 + 6 * SEC);
  expect(counters(s)).toEqual({ remaining: 1, correct: 2, incorrect: 1, total: 4, round: 2, progress: 0.5 });
  s = answer(s, true, T0 + 7 * SEC);
  expect(counters(s)).toEqual({ remaining: 0, correct: 3, incorrect: 1, total: 4, round: 2, progress: 0.75 });
  s = nextRound(s, mulberry32(1), T0 + 8 * SEC);
  expect(counters(s)).toEqual({ remaining: 1, correct: 3, incorrect: 0, total: 4, round: 3, progress: 0.75 });
  s = answer(s, true, T0 + 9 * SEC);
  expect(counters(s)).toEqual({ remaining: 0, correct: 4, incorrect: 0, total: 4, round: 3, progress: 1 });
});

test('roundSummary lists the round answers in order', () => {
  let s = createSession(makeCards(4), { answerWith: 'definition', shuffle: false }, { now: T0 });
  s = answerSeq(s, [true, false, true, false]);
  expect(roundSummary(s)).toEqual({
    round: 1,
    total: 4,
    correct: 2,
    incorrect: 2,
    items: [
      { qid: 'c1:d', cardId: 'c1', ask: 'definition', correct: true },
      { qid: 'c2:d', cardId: 'c2', ask: 'definition', correct: false },
      { qid: 'c3:d', cardId: 'c3', ask: 'definition', correct: true },
      { qid: 'c4:d', cardId: 'c4', ask: 'definition', correct: false },
    ],
  });
  // Mid-round the total still counts the questions not yet answered.
  const mid = answerSeq(createSession(makeCards(4), ORDERED, { now: T0 }), [false]);
  expect(roundSummary(mid)).toEqual({
    round: 1,
    total: 4,
    correct: 0,
    incorrect: 1,
    items: [{ qid: 'c1:t', cardId: 'c1', ask: 'term', correct: false }],
  });
});

// ---------- rounds ----------

test('nextRound: closes the round, next queue = missed questions only', () => {
  let s = createSession(makeCards(5), ORDERED, { now: T0 });
  s = answerSeq(s, [true, false, true, false, false]);
  s = nextRound(s, mulberry32(9), T0 + MIN);
  expect(s.rounds).toEqual([{ round: 1, total: 5, correct: 2, incorrectQids: ['c2:t', 'c4:t', 'c5:t'] }]);
  expect(s.round).toBe(2);
  expect(s.queue).toEqual(['c2:t', 'c4:t', 'c5:t']);
  expect(s.roundAnswered).toEqual([]);
  expect(current(s).qid).toBe('c2:t');
  expect(roundSummary(s)).toEqual({ round: 2, total: 3, correct: 0, incorrect: 0, items: [] });
});

test('nextRound with shuffle: queue is a permutation of the missed questions', () => {
  const cards = makeCards(12);
  let s = createSession(cards, { answerWith: 'term', shuffle: true }, { rng: mulberry32(5), now: T0 });
  const pattern = [false, true, true, false, true, false, false, true, true, true, false, true];
  s = answerSeq(s, pattern);
  const missed = s.roundAnswered.filter((a) => !a.correct).map((a) => a.qid);
  const a = nextRound(s, mulberry32(77), T0 + MIN);
  const b = nextRound(s, mulberry32(77), T0 + MIN);
  expect(a.queue).toEqual(b.queue);
  expect([...a.queue].sort()).toEqual([...missed].sort());
  expect(a.queue).toHaveLength(5);
});

test('nextRound in both-mode keeps a card’s two questions apart when possible', () => {
  for (let seed = 1; seed <= 60; seed++) {
    let s = createSession(makeCards(4), { answerWith: 'both', shuffle: true }, { rng: mulberry32(seed), now: T0 });
    s = answerSeq(s, new Array(8).fill(false));
    s = nextRound(s, mulberry32(seed + 1000), T0 + MIN);
    expect(s.queue).toHaveLength(8);
    if (hasAdjacentSiblings(s, s.queue)) throw new Error(`adjacent siblings in round 2, seed ${seed}: ${s.queue}`);
  }
});

test('nextRound is a no-op while the round is still running', () => {
  let s = createSession(makeCards(3), ORDERED, { now: T0 });
  s = answerSeq(s, [false]);
  const after = nextRound(s, mulberry32(1), T0 + MIN);
  expect(snapshot(after)).toBe(snapshot(s));
  expect(after).not.toBe(s);
});

test('multi-round session runs until every question was answered correctly once', () => {
  let s = createSession(makeCards(4), ORDERED, { now: T0 });
  s = answerSeq(s, [true, false, false, true], T0); // round 1: c2, c3 missed
  expect(isFinished(s)).toBe(false);
  s = nextRound(s, mulberry32(1), T0 + MIN);
  expect(s.queue).toEqual(['c2:t', 'c3:t']);
  s = answerSeq(s, [true, false], T0 + MIN); // round 2: c3 missed again
  s = nextRound(s, mulberry32(1), T0 + 2 * MIN);
  expect(s.round).toBe(3);
  expect(s.queue).toEqual(['c3:t']);
  s = answer(s, true, T0 + 2 * MIN + 5 * SEC);
  expect(isRoundOver(s)).toBe(true);
  expect(isFinished(s)).toBe(true);
  expect(s.finishedAt).toBe(T0 + 2 * MIN + 5 * SEC);
  expect([...s.done].sort()).toEqual(['c1:t', 'c2:t', 'c3:t', 'c4:t']);
  expect(s.misses).toEqual({ 'c1:t': 0, 'c2:t': 1, 'c3:t': 2, 'c4:t': 0 });
  expect(s.attempts).toEqual({ 'c1:t': 1, 'c2:t': 2, 'c3:t': 3, 'c4:t': 1 });

  // Closing the final round records it but does not start another one.
  const closed = nextRound(s, mulberry32(1), T0 + 3 * MIN);
  expect(closed.round).toBe(3);
  expect(closed.rounds).toEqual([
    { round: 1, total: 4, correct: 2, incorrectQids: ['c2:t', 'c3:t'] },
    { round: 2, total: 2, correct: 1, incorrectQids: ['c3:t'] },
    { round: 3, total: 1, correct: 1, incorrectQids: [] },
  ]);
  expect(closed.finishedAt).toBe(T0 + 2 * MIN + 5 * SEC);
  expect(roundSummary(closed).items).toEqual([{ qid: 'c3:t', cardId: 'c3', ask: 'term', correct: true }]);
  expect(snapshot(nextRound(closed, mulberry32(1), T0 + 4 * MIN))).toBe(snapshot(closed));
  expect(finalStats(closed).rounds).toBe(3);
  expect(finalStats(s).rounds).toBe(3);
});

test('a perfect first round finishes immediately', () => {
  let s = createSession(makeCards(3), ORDERED, { now: T0 });
  s = answerSeq(s, [true, true, true]);
  expect(isFinished(s)).toBe(true);
  expect(s.finishedAt).toBe(T0 + 30 * SEC);
  const closed = nextRound(s, mulberry32(1), T0 + MIN);
  expect(closed.round).toBe(1);
  expect(closed.rounds).toEqual([{ round: 1, total: 3, correct: 3, incorrectQids: [] }]);
  expect(finalStats(closed).accuracy).toBe(1);
});

// ---------- override ----------

test('override in-round on a first attempt: counts as correct, fixes firstTry, idempotent', () => {
  let s = createSession(makeCards(3), ORDERED, { now: T0 });
  s = answerSeq(s, [false, false]); // c1, c2 missed; c3 pending
  expect(counters(s)).toEqual({ remaining: 1, correct: 0, incorrect: 2, total: 3, round: 1, progress: 0 });
  const o = override(s, 'c2:t', T0 + 25 * SEC);
  expect(o.roundAnswered).toEqual([
    { qid: 'c1:t', correct: false },
    { qid: 'c2:t', correct: true },
  ]);
  expect(o.done).toEqual(['c2:t']);
  expect(o.misses['c2:t']).toBe(0);
  expect(o.attempts['c2:t']).toBe(1);
  expect(o.firstTry['c2:t']).toBe(true);
  expect(counters(o)).toEqual({ remaining: 1, correct: 1, incorrect: 1, total: 3, round: 1, progress: 1 / 3 });
  expect(current(o).qid).toBe('c3:t');
  // Idempotent.
  const twice = override(o, 'c2:t', T0 + 26 * SEC);
  expect(twice.done).toEqual(['c2:t']);
  expect(twice.misses['c2:t']).toBe(0);
  expect(counters(twice)).toEqual(counters(o));
  // The overridden question is not part of the next round.
  let r = answer(o, true, T0 + 30 * SEC);
  r = nextRound(r, mulberry32(1), T0 + MIN);
  expect(r.queue).toEqual(['c1:t']);
  expect(r.rounds[0]).toEqual({ round: 1, total: 3, correct: 2, incorrectQids: ['c1:t'] });
});

test('override of a later-round answer keeps firstTry false', () => {
  let s = createSession(makeCards(2), ORDERED, { now: T0 });
  s = answerSeq(s, [false, true]);
  s = nextRound(s, mulberry32(1), T0 + MIN);
  s = answer(s, false, T0 + MIN + 5 * SEC); // c1 missed again in round 2
  expect(s.misses['c1:t']).toBe(2);
  const o = override(s, 'c1:t', T0 + MIN + 8 * SEC);
  expect(o.misses['c1:t']).toBe(1);
  expect(o.attempts['c1:t']).toBe(2);
  expect(o.firstTry['c1:t']).toBe(false);
  expect(isFinished(o)).toBe(true);
  expect(o.finishedAt).toBe(T0 + MIN + 8 * SEC);
  expect(counters(o)).toEqual({ remaining: 0, correct: 2, incorrect: 0, total: 2, round: 2, progress: 1 });
  expect(finalStats(o).firstTryCorrect).toBe(1);
});

test('override while the round summary is showing removes the miss from the next round', () => {
  let s = createSession(makeCards(4), ORDERED, { now: T0 });
  s = answerSeq(s, [true, false, true, false]);
  expect(isRoundOver(s)).toBe(true);
  s = override(s, 'c4:t', T0 + MIN);
  expect(roundSummary(s).correct).toBe(3);
  expect(roundSummary(s).incorrect).toBe(1);
  expect(counters(s).incorrect).toBe(1);
  s = nextRound(s, mulberry32(1), T0 + 2 * MIN);
  expect(s.queue).toEqual(['c2:t']);
  expect(s.rounds[0]).toEqual({ round: 1, total: 4, correct: 3, incorrectQids: ['c2:t'] });
});

test('override of the last miss during the summary finishes the session', () => {
  let s = createSession(makeCards(3), ORDERED, { now: T0 });
  s = answerSeq(s, [true, true, false]);
  expect(isFinished(s)).toBe(false);
  s = override(s, 'c3:t', T0 + MIN);
  expect(isFinished(s)).toBe(true);
  expect(s.finishedAt).toBe(T0 + MIN);
  const closed = nextRound(s, mulberry32(1), T0 + 2 * MIN);
  expect(closed.round).toBe(1);
  expect(closed.rounds).toEqual([{ round: 1, total: 3, correct: 3, incorrectQids: [] }]);
});

test('override right after nextRound applies to the just-closed round', () => {
  let s = createSession(makeCards(4), ORDERED, { now: T0 });
  s = answerSeq(s, [false, true, false, true]);
  s = nextRound(s, mulberry32(1), T0 + MIN);
  expect(s.queue).toEqual(['c1:t', 'c3:t']);
  s = override(s, 'c3:t', T0 + MIN + SEC);
  expect(s.round).toBe(2);
  expect(s.queue).toEqual(['c1:t']);
  expect(s.rounds).toEqual([{ round: 1, total: 4, correct: 3, incorrectQids: ['c1:t'] }]);
  expect(s.firstTry['c3:t']).toBe(true);
  expect(s.done).toContain('c3:t');
  expect(counters(s)).toEqual({ remaining: 1, correct: 3, incorrect: 0, total: 4, round: 2, progress: 0.75 });

  // Overriding the remaining miss leaves the new round empty: the session ends with round 1.
  const f = override(s, 'c1:t', T0 + MIN + 2 * SEC);
  expect(isFinished(f)).toBe(true);
  expect(f.round).toBe(1);
  expect(f.queue).toEqual([]);
  expect(f.rounds).toEqual([{ round: 1, total: 4, correct: 4, incorrectQids: [] }]);
  expect(f.finishedAt).toBe(T0 + MIN + 2 * SEC);
  expect(finalStats(f).rounds).toBe(1);
  expect(finalStats(f).accuracy).toBe(1);
  expect(snapshot(nextRound(f, mulberry32(1), T0 + 2 * MIN))).toBe(snapshot(f));
});

test('override is a no-op for correct, unanswered, unknown or older answers', () => {
  let s = createSession(makeCards(4), ORDERED, { now: T0 });
  s = answerSeq(s, [true, false]);
  expect(snapshot(override(s, 'c1:t', T0 + MIN))).toBe(snapshot(s)); // answered correctly
  expect(snapshot(override(s, 'c3:t', T0 + MIN))).toBe(snapshot(s)); // not answered yet
  expect(snapshot(override(s, 'zz:t', T0 + MIN))).toBe(snapshot(s)); // unknown
  expect(snapshot(override(s, undefined, T0 + MIN))).toBe(snapshot(s));

  // A miss from two rounds ago cannot be overridden once it was asked again.
  let r = answerSeq(s, [true, true], T0 + 20 * SEC);
  r = nextRound(r, mulberry32(1), T0 + MIN);
  r = answer(r, false, T0 + MIN + SEC); // c2 missed again in round 2
  r = nextRound(r, mulberry32(1), T0 + 2 * MIN);
  const before = snapshot(r);
  const o = override(r, 'c2:t', T0 + 2 * MIN + SEC); // allowed: miss of the just-closed round 2
  expect(o.done).toContain('c2:t');
  expect(snapshot(r)).toBe(before);
  const answered = answer(r, false, T0 + 2 * MIN + SEC); // round 3 miss
  const o3 = override(answered, 'c2:t', T0 + 2 * MIN + 2 * SEC);
  expect(o3.roundAnswered).toEqual([{ qid: 'c2:t', correct: true }]);
  expect(o3.rounds[1]).toEqual({ round: 2, total: 1, correct: 0, incorrectQids: ['c2:t'] });
});

// ---------- final stats ----------

test('finalStats: accuracy, hardest ordering and missed cards', () => {
  let s = createSession(makeCards(5), ORDERED, { now: T0 });
  s = answerSeq(s, [false, true, false, false, true]); // c1, c3, c4 missed
  s = nextRound(s, mulberry32(1), T0 + MIN);
  s = answerSeq(s, [true, false, false], T0 + MIN); // c3, c4 missed
  s = nextRound(s, mulberry32(1), T0 + 2 * MIN);
  s = answerSeq(s, [true, false], T0 + 2 * MIN); // c4 missed
  s = nextRound(s, mulberry32(1), T0 + 3 * MIN);
  s = answer(s, true, T0 + 3 * MIN + 10 * SEC);
  expect(isFinished(s)).toBe(true);
  const stats = finalStats(s);
  expect(stats.total).toBe(5);
  expect(stats.firstTryCorrect).toBe(2);
  expect(stats.accuracy).toBe(0.4);
  expect(stats.rounds).toBe(4);
  expect(stats.hardest).toEqual([
    { cardId: 'c4', misses: 3 },
    { cardId: 'c3', misses: 2 },
    { cardId: 'c1', misses: 1 },
  ]);
  expect(stats.missedCardIds).toEqual(['c1', 'c3', 'c4']);
  expect(stats.elapsedMs).toBe(s.elapsedMs);
  expect(stats.elapsedMs).toBeGreaterThan(0);
});

test('finalStats: both directions add up per card, ties keep order, max 10', () => {
  let s = createSession(makeCards(12), { answerWith: 'both', shuffle: false }, { now: T0 });
  // Round 1: every term question missed, every definition question correct except c12:d.
  const results = s.order.map((qid) => qid.endsWith(':d') && qid !== 'c12:d');
  s = answerSeq(s, results);
  const stats = finalStats(s);
  expect(stats.total).toBe(24);
  expect(stats.firstTryCorrect).toBe(11);
  expect(stats.accuracy).toBe(11 / 24);
  expect(stats.hardest).toHaveLength(10);
  expect(stats.hardest[0]).toEqual({ cardId: 'c12', misses: 2 });
  expect(stats.hardest.slice(1).map((h) => h.cardId)).toEqual(['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7', 'c8', 'c9']);
  expect(stats.missedCardIds).toHaveLength(12);
  expect(stats.missedCardIds[0]).toBe('c1');
});

// ---------- removeCard ----------

test('removeCard mid-round removes all its questions everywhere', () => {
  let s = createSession(makeCards(4), { answerWith: 'both', shuffle: false }, { now: T0 });
  s = answerSeq(s, [true, false, true]); // c1:t ok, c2:t miss, c3:t ok; current c4:t
  const r = removeCard(s, 'c2', T0 + MIN);
  expect(Object.keys(r.questions).some((q) => q.startsWith('c2:'))).toBe(false);
  expect(r.order).toEqual(['c1:t', 'c3:t', 'c4:t', 'c1:d', 'c3:d', 'c4:d']);
  expect(r.queue).toEqual(['c4:t', 'c1:d', 'c3:d', 'c4:d']);
  expect(r.roundAnswered).toEqual([
    { qid: 'c1:t', correct: true },
    { qid: 'c3:t', correct: true },
  ]);
  expect(r.attempts['c2:t']).toBe(undefined);
  expect(r.misses['c2:t']).toBe(undefined);
  expect(r.firstTry['c2:t']).toBe(undefined);
  expect(counters(r)).toEqual({ remaining: 4, correct: 2, incorrect: 0, total: 6, round: 1, progress: 2 / 6 });
  expect(finalStats(r).missedCardIds).toEqual([]);
  // Unknown card: nothing changes.
  expect(snapshot(removeCard(s, 'nope', T0 + MIN))).toBe(snapshot(s));
});

test('removeCard of the current question moves on to the next one', () => {
  let s = createSession(makeCards(3), ORDERED, { now: T0 });
  s = answerSeq(s, [false]);
  expect(current(s).cardId).toBe('c2');
  s = removeCard(s, 'c2', T0 + MIN);
  expect(current(s).cardId).toBe('c3');
  expect(counters(s)).toEqual({ remaining: 1, correct: 0, incorrect: 1, total: 2, round: 1, progress: 0 });
});

test('removeCard adjusts closed rounds and can finish the session', () => {
  let s = createSession(makeCards(4), ORDERED, { now: T0 });
  s = answerSeq(s, [true, false, false, true]); // c2, c3 missed
  s = nextRound(s, mulberry32(1), T0 + MIN);
  s = answerSeq(s, [true, false], T0 + MIN); // c3 missed again
  s = nextRound(s, mulberry32(1), T0 + 2 * MIN);
  expect(s.round).toBe(3);
  expect(s.queue).toEqual(['c3:t']);

  // Removing a done card changes the tallies of the rounds it took part in.
  const a = removeCard(s, 'c2', T0 + 2 * MIN + SEC);
  expect(a.rounds).toEqual([
    { round: 1, total: 3, correct: 2, incorrectQids: ['c3:t'] },
    { round: 2, total: 1, correct: 0, incorrectQids: ['c3:t'] },
  ]);
  expect(a.round).toBe(3);
  expect(isFinished(a)).toBe(false);

  // Removing the only open card ends the session; empty rounds are dropped.
  const b = removeCard(a, 'c3', T0 + 2 * MIN + 2 * SEC);
  expect(b.rounds).toEqual([{ round: 1, total: 2, correct: 2, incorrectQids: [] }]);
  expect(b.round).toBe(1);
  expect(b.queue).toEqual([]);
  expect(isFinished(b)).toBe(true);
  expect(b.finishedAt).toBe(T0 + 2 * MIN + 2 * SEC);
  expect(finalStats(b)).toEqual({
    total: 2,
    firstTryCorrect: 2,
    accuracy: 1,
    rounds: 1,
    elapsedMs: b.elapsedMs,
    hardest: [],
    missedCardIds: [],
  });
});

test('removeCard of every card leaves an empty finished session', () => {
  let s = createSession(makeCards(2), ORDERED, { now: T0 });
  s = answerSeq(s, [false]);
  s = removeCard(s, 'c1', T0 + MIN);
  s = removeCard(s, 'c2', T0 + MIN);
  expect(s.order).toEqual([]);
  expect(isFinished(s)).toBe(true);
  expect(s.finishedAt).toBe(T0 + MIN);
  expect(counters(s).total).toBe(0);
  expect(finalStats(s).rounds).toBe(0);
});

// ---------- time ----------

test('tick accumulates active time and ignores gaps longer than 5 minutes', () => {
  let s = createSession(makeCards(2), ORDERED, { now: T0 });
  s = tick(s, T0 + 30 * SEC);
  expect(s.elapsedMs).toBe(30 * SEC);
  s = tick(s, T0 + 30 * SEC + 5 * MIN); // exactly 5 minutes still counts
  expect(s.elapsedMs).toBe(30 * SEC + 5 * MIN);
  s = tick(s, T0 + 30 * SEC + 5 * MIN + 2 * 60 * MIN); // two hours away
  expect(s.elapsedMs).toBe(30 * SEC + 5 * MIN);
  expect(s.updatedAt).toBe(T0 + 30 * SEC + 5 * MIN + 2 * 60 * MIN);
  s = tick(s, s.updatedAt + 10 * SEC);
  expect(s.elapsedMs).toBe(40 * SEC + 5 * MIN);
  const back = tick(s, s.updatedAt - 10 * SEC); // clock went backwards
  expect(back.elapsedMs).toBe(s.elapsedMs);
});

test('answers advance the clock and it stops once finished', () => {
  let s = createSession(makeCards(2), ORDERED, { now: T0 });
  s = answer(s, true, T0 + 12 * SEC);
  expect(s.elapsedMs).toBe(12 * SEC);
  expect(s.updatedAt).toBe(T0 + 12 * SEC);
  s = answer(s, true, T0 + 20 * SEC);
  expect(s.elapsedMs).toBe(20 * SEC);
  expect(isFinished(s)).toBe(true);
  const later = tick(s, T0 + 60 * SEC);
  expect(later.elapsedMs).toBe(20 * SEC);
  expect(finalStats(later).elapsedMs).toBe(20 * SEC);
});

// ---------- serialisation & immutability ----------

test('state survives a JSON round-trip and continues identically', () => {
  const opts = { answerWith: 'both', shuffle: true };
  let s = createSession(makeCards(8), opts, { rng: mulberry32(11), now: T0 });
  const decide = mulberry32(99);
  const outcomes = Array.from({ length: 200 }, () => decide() < 0.55);
  let k = 0;
  let t = T0;
  const step = (state) => {
    t += 7 * SEC;
    if (isRoundOver(state)) return nextRound(state, mulberry32(t), t);
    return answer(state, outcomes[k++ % outcomes.length], t);
  };
  for (let i = 0; i < 10; i++) s = step(s);
  const restored = JSON.parse(JSON.stringify(s));
  expect(restored).toEqual(s);

  const tStart = t;
  const kStart = k;
  let a = s;
  let guard = 0;
  while (!isFinished(a) && guard++ < 500) a = step(a);
  t = tStart;
  k = kStart;
  let b = restored;
  guard = 0;
  while (!isFinished(b) && guard++ < 500) b = step(b);
  expect(isFinished(a)).toBe(true);
  expect(snapshot(b)).toBe(snapshot(a));
  expect(finalStats(b)).toEqual(finalStats(a));
});

test('functions never mutate their input state', () => {
  let s = createSession(makeCards(5), { answerWith: 'both', shuffle: true }, { rng: mulberry32(3), now: T0 });
  s = answerSeq(s, [true, false, true, false]);
  const frozen = deepFreeze(JSON.parse(JSON.stringify(s)));
  const before = snapshot(frozen);
  const qid = frozen.roundAnswered[1].qid;
  const results = [
    answer(frozen, true, T0 + MIN),
    answer(frozen, false, T0 + MIN),
    override(frozen, qid, T0 + MIN),
    removeCard(frozen, frozen.questions[qid].cardId, T0 + MIN),
    tick(frozen, T0 + MIN),
  ];
  current(frozen);
  counters(frozen);
  roundSummary(frozen);
  finalStats(frozen);
  isRoundOver(frozen);
  isFinished(frozen);
  expect(snapshot(frozen)).toBe(before);
  for (const r of results) expect(r).not.toBe(frozen);

  // Finish the round, then check nextRound on a frozen state too.
  let e = frozen;
  while (!isRoundOver(e)) e = answer(e, false, T0 + 2 * MIN);
  const endFrozen = deepFreeze(JSON.parse(JSON.stringify(e)));
  const endBefore = snapshot(endFrozen);
  const n = nextRound(endFrozen, mulberry32(5), T0 + 3 * MIN);
  expect(n.round).toBe(2);
  expect(snapshot(endFrozen)).toBe(endBefore);
  // Mutating a returned question does not leak into the state.
  const q = current(n);
  q.cardId = 'changed';
  expect(current(n).cardId).not.toBe('changed');
});

test('defensive: a corrupt or partial state does not crash the engine', () => {
  const partial = { questions: { 'a:t': { cardId: 'a', ask: 'term' } }, order: ['a:t', 'ghost:t'], queue: ['a:t'] };
  expect(current(partial)).toEqual({ qid: 'a:t', cardId: 'a', ask: 'term' });
  const s = answer(partial, true, T0);
  expect(isFinished(s)).toBe(true);
  expect(counters(s)).toEqual({ remaining: 0, correct: 1, incorrect: 0, total: 1, round: 1, progress: 1 });
  expect(counters(null).total).toBe(0);
  expect(isFinished(undefined)).toBe(true);
  // An open question that fell out of the queue is picked up again by nextRound.
  const stuck = { questions: { 'a:t': { cardId: 'a', ask: 'term' } }, order: ['a:t'], queue: [], round: 1 };
  expect(isRoundOver(stuck)).toBe(true);
  const refilled = nextRound(stuck, mulberry32(1), T0);
  expect(refilled.queue).toEqual(['a:t']);
  expect(refilled.round).toBe(1);
  expect(refilled.rounds).toEqual([]);
});

// ---------- simulation ----------

test('simulation: invariants hold for random play until finished', () => {
  for (let seed = 1; seed <= 40; seed++) {
    const rng = mulberry32(seed);
    const answerWith = ['term', 'definition', 'both'][seed % 3];
    const shuffle = seed % 2 === 0;
    const n = 3 + (seed % 9);
    let s = createSession(makeCards(n), { answerWith, shuffle }, { rng, now: T0 });
    const total = s.order.length;
    let t = T0;
    let expectedQueue = null;
    let guard = 0;
    while (!isFinished(s)) {
      if (guard++ > 2000) throw new Error(`seed ${seed}: did not finish`);
      t += 3 * SEC;
      if (isRoundOver(s)) {
        const missed = s.roundAnswered.filter((a) => !a.correct).map((a) => a.qid);
        s = nextRound(s, rng, t);
        expect([...s.queue].sort()).toEqual([...missed].sort());
        expectedQueue = s.queue.slice();
        continue;
      }
      if (expectedQueue && s.roundAnswered.length === 0) expect(s.queue).toEqual(expectedQueue);
      const before = counters(s);
      s = answer(s, rng() < 0.6, t);
      const after = counters(s);
      expect(after.remaining).toBe(before.remaining - 1);
      if (rng() < 0.1 && !s.roundAnswered[s.roundAnswered.length - 1].correct) {
        s = override(s, s.roundAnswered[s.roundAnswered.length - 1].qid, t);
      }
    }
    s = nextRound(s, rng, t + SEC);
    // Every question done exactly once; attempt bookkeeping is consistent.
    expect(s.done.length).toBe(total);
    expect([...s.done].sort()).toEqual([...s.order].sort());
    for (const qid of s.order) {
      // One correct (or overridden) answer per question; every other attempt was a miss.
      expect(s.attempts[qid]).toBe(s.misses[qid] + 1);
      expect(s.firstTry[qid]).toBe(s.attempts[qid] === 1);
    }
    // Rounds are numbered 1..k; their correct answers add up to the number of questions.
    expect(s.rounds.map((r) => r.round)).toEqual(s.rounds.map((_, i) => i + 1));
    expect(s.rounds.reduce((sum, r) => sum + r.correct, 0)).toBe(total);
    expect(s.rounds[0].total).toBe(total);
    for (let i = 1; i < s.rounds.length; i++) expect(s.rounds[i].total).toBe(s.rounds[i - 1].incorrectQids.length);
    expect(finalStats(s).rounds).toBe(s.rounds.length);
    expect(counters(s).progress).toBe(1);
  }
});

await run('session.test.js');
