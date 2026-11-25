import { test, expect, run } from './harness.js';
import {
  DEFAULT_LEARN,
  stageFromProgress,
  solvedFromProgress,
  createLearn,
  current,
  answer,
  override,
  isRoundOver,
  checkpoint,
  nextRound,
  isFinished,
  counts,
  buildChoices,
  removeCard,
  finalStats,
  tick,
  matchesProgress,
  syncProgress,
  isReviewQuestion,
  reviewStats,
  MIN_GAP,
  MAX_WAIT,
  MAX_REPEATS,
  MAX_LEARNING,
  RECHECK_GAP,
  RECHECK_WAIT,
  RECHECK_MIN_CARDS,
} from '../src/core/learn.js';
import { applyAnswer, applyOverride, cardStatus } from '../src/core/mastery.js';
import { reviewLine } from '../src/screens/learn-model.js';
import { answerSide, findSynonymCards } from '../src/core/synonyms.js';
import { normalizeBasic } from '../src/core/text.js';

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
const DAY_MS = 24 * 60 * MIN;
const OPTS = { answerWith: 'term' };

function makeCards(n) {
  return Array.from({ length: n }, (_, i) => ({
    id: `c${i + 1}`,
    term: `terme ${i + 1}`,
    definition: `Begriff ${i + 1}`,
    starred: i % 3 === 0,
  }));
}

function progressEntry(streak, correct = streak, incorrect = 0, lastResult = streak > 0 ? 'correct' : 'incorrect') {
  return { correct, incorrect, streak, streakBefore: 0, lastResult, lastAnsweredAt: T0 - 1000 };
}

const snapshot = (s) => JSON.stringify(s);
const sorted = (list) => [...list].sort();
const textKey = (t) => normalizeBasic(t).toLowerCase();

function deepFreeze(o) {
  if (o && typeof o === 'object' && !Object.isFrozen(o)) {
    Object.freeze(o);
    for (const k of Object.keys(o)) deepFreeze(o[k]);
  }
  return o;
}

// Answers every remaining question of the round; decide(question, state) → boolean.
function playRound(state, decide, startAt = T0) {
  let s = state;
  let t = startAt;
  let guard = 0;
  while (!isRoundOver(s)) {
    if (guard++ > 100) throw new Error('round did not end');
    t += 5 * SEC;
    s = answer(s, decide(current(s), s), t);
  }
  return s;
}

// decide() from a per-card plan of results, consumed in order.
function planned(plan) {
  const left = {};
  for (const k of Object.keys(plan)) left[k] = plan[k].slice();
  return (q) => {
    const list = left[q.cardId];
    if (!list || !list.length) throw new Error(`no planned answer for ${q.cardId}`);
    return list.shift();
  };
}

// Question ids: "<round>.<kind>[.<n>]:<cardId>", kind 1 = learning, 3 = repetition, 4 = recheck.
const QID = /^(\d+)\.([134])(?:\.(\d+))?:(.*)$/;
const kindOf = (qid) => Number(QID.exec(qid)[2]);
const isRecheck = (qid) => kindOf(qid) === 4;

// What nextPick sees when the question at the front of the queue is asked (equal to the plan as
// long as every answer went as planned): open = cards still to learn + repetition questions and
// rechecks still to ask, fresh = learning cards not asked yet in this session, inFlight =
// learning cards asked before.
function situation(s) {
  const learning = s.order.filter((id) => s.stage[id] < 2);
  const queued = (re) => s.queue.filter((q) => re(q.qid)).length;
  const reviews = s.review ? s.review.due.filter((id) => s.stage[id] >= 2).length + queued((qid) => kindOf(qid) === 3) : 0;
  const rechecks = s.recheck ? s.recheck.due.filter((id) => s.stage[id] >= 2).length + queued(isRecheck) : 0;
  const asked = (id) => Object.prototype.hasOwnProperty.call(s.lastAt, id);
  return {
    open: learning.length + reviews + rechecks,
    learning: learning.length,
    fresh: learning.filter((id) => !asked(id)).length,
    reviews,
    inFlight: learning.filter(asked).length,
    // Learning cards asked before and the number of other questions since their last answer.
    waits: learning.filter(asked).map((id) => ({ id, wait: s.clock - s.lastAt[id] - 1 })),
  };
}

// Plays a session to its end (nextRound between rounds); decide(question, state) → boolean,
// overrideIf(state) → whether to correct the wrong answer just given. Returns the final state and
// a log entry per answer: the question, the situation before it, `wait` (other questions since the
// card's last answer, null for its first) and `repeatsBefore`.
function playSession(state, cards, decide, { seed = 1, start = T0, max = 5000, overrideIf = null } = {}) {
  const rng = mulberry32(seed);
  let s = state;
  let t = start;
  const log = [];
  while (!isFinished(s)) {
    if (log.length > max) throw new Error('session did not end');
    t += 3 * SEC;
    if (isRoundOver(s)) {
      s = nextRound(s, cards, rng, t);
      continue;
    }
    const q = current(s);
    const before = situation(s);
    const asked = Object.prototype.hasOwnProperty.call(s.lastAt, q.cardId);
    const ok = decide(q, s) === true;
    const entry = { ...q, round: s.round, clock: s.clock, wait: asked ? s.clock - s.lastAt[q.cardId] - 1 : null, repeatsBefore: s.repeats, stageBefore: s.stage[q.cardId], solvedBefore: !!s.solved[q.cardId], correct: ok, ...before };
    s = answer(s, ok, t);
    if (!ok && overrideIf && overrideIf(s)) {
      s = override(s, t + 1);
      entry.overridden = true;
    }
    log.push(entry);
  }
  return { s: nextRound(s, cards, rng, t + MIN), log };
}

// A stored state with a hand-made spacing situation; nextRound plans its next round. Cards not in
// `stage` are new (stage 0), cards not in `lastAt` were not asked in this session.
function planFrom(cards, { stage = {}, lastAt = {}, clock = 0, repeats = 0, roundSize = 7, seed = 1, extra = {} } = {}) {
  const order = cards.map((c) => c.id);
  const raw = {
    v: 1,
    order,
    stage: Object.fromEntries(order.map((id) => [id, stage[id] || 0])),
    learn: { roundSize },
    clock,
    lastAt,
    repeats,
    queue: [],
    roundLog: [],
    answered: clock,
    correct: clock,
    ...extra,
  };
  return nextRound(raw, cards, mulberry32(seed), T0);
}

// Waits of n cards asked before: lastAt so that card i has waited waits[i] other questions at `clock`.
const lastAtFor = (ids, waits, clock) => Object.fromEntries(ids.map((id, i) => [id, clock - 1 - waits[i]]));

function checkChoices(q, cards) {
  const card = cards.find((c) => c.id === q.cardId);
  const correct = q.choices.filter((c) => c.cardId === q.cardId);
  expect(correct).toHaveLength(1);
  expect(correct[0].text).toBe(answerSide(card, q.ask));
  expect(new Set(q.choices.map((c) => c.cardId)).size).toBe(q.choices.length);
  expect(new Set(q.choices.map((c) => textKey(c.text))).size).toBe(q.choices.length);
  for (const c of q.choices) {
    const owner = cards.find((x) => x.id === c.cardId);
    expect(c.text).toBe(answerSide(owner, q.ask));
  }
}

// ---------- constants & stages ----------

test('DEFAULT_LEARN matches the spec', () => {
  expect(DEFAULT_LEARN).toEqual({ roundSize: 7, mc: true, written: true, retype: false });
});

test('stageFromProgress: min(streak, 2), robust to junk', () => {
  expect(stageFromProgress(undefined)).toBe(0);
  expect(stageFromProgress(null)).toBe(0);
  expect(stageFromProgress({})).toBe(0);
  expect(stageFromProgress(progressEntry(0, 0, 1))).toBe(0);
  expect(stageFromProgress(progressEntry(1))).toBe(1);
  expect(stageFromProgress(progressEntry(2))).toBe(2);
  expect(stageFromProgress(progressEntry(7, 9, 2))).toBe(2);
  expect(stageFromProgress({ streak: -3 })).toBe(0);
  expect(stageFromProgress({ streak: 'x' })).toBe(0);
  expect(stageFromProgress({ streak: NaN })).toBe(0);
  expect(stageFromProgress({ streak: 1.9 })).toBe(1);
  expect(stageFromProgress('junk')).toBe(0);
});

// ---------- createLearn ----------

test('createLearn: state shape for a set of new cards', () => {
  const cards = makeCards(10);
  const s = createLearn(cards, OPTS, { rng: mulberry32(1), now: T0 });
  expect(s.v).toBe(1);
  expect(s.subset).toBe('all');
  expect(s.answerWith).toBe('term');
  expect(s.learn).toEqual({ roundSize: 7, mc: true, written: true });
  expect(sorted(s.order)).toEqual(sorted(cards.map((c) => c.id)));
  expect(Object.values(s.stage)).toEqual(new Array(10).fill(0));
  expect(s.initiallyMastered).toEqual([]);
  expect(s.round).toBe(1);
  // The round's questions are planned at once: seven new cards, in session order.
  expect(s.queue).toHaveLength(7);
  expect(s.queue.map((q) => q.cardId)).toEqual(s.order.slice(0, 7));
  for (const q of s.queue) {
    expect(q.qid).toBe(`1.1:${q.cardId}`);
    expect(q.type).toBe('mc');
    expect(q.ask).toBe('term');
    expect(q.choices).toHaveLength(4);
    expect(q.retryChoices).toHaveLength(4);
    checkChoices(q, cards);
  }
  // Spacing: nothing answered yet.
  expect(s.clock).toBe(0);
  expect(s.lastAt).toEqual({});
  expect(s.repeats).toBe(0);
  // Fields of the engine before spacing (1.4) are gone; the options are opt-in.
  for (const key of ['active', 'retried', 'review', 'recheck']) expect(key in s).toBe(false);
  expect(Object.keys(s)).toEqual(['v', 'subset', 'answerWith', 'learn', 'order', 'stage', 'initiallyMastered', 'seen', 'solved', 'round', 'queue', 'clock', 'lastAt', 'repeats', 'roundLog', 'rounds', 'answered', 'correct', 'misses', 'last', 'startedAt', 'updatedAt', 'finishedAt', 'elapsedMs']);
  expect(s.solved).toEqual({});
  expect(s.roundLog).toEqual([]);
  expect(s.rounds).toEqual([]);
  expect(s.answered).toBe(0);
  expect(s.correct).toBe(0);
  expect(s.misses).toEqual({});
  expect(s.last).toBe(null);
  expect(s.startedAt).toBe(T0);
  expect(s.updatedAt).toBe(T0);
  expect(s.finishedAt).toBe(null);
  expect(s.elapsedMs).toBe(0);
  expect(counts(s)).toEqual({ fresh: 10, learning: 0, mastered: 0, total: 10, progress: 0 });
  expect(isFinished(s)).toBe(false);
  expect(isRoundOver(s)).toBe(false);
  // current() is the front of the queue, without internal fields.
  const q = current(s);
  expect(q).toEqual({ qid: s.queue[0].qid, cardId: s.queue[0].cardId, type: 'mc', ask: 'term', choices: s.queue[0].choices });
});

test('createLearn: deterministic per seed, order shuffled once', () => {
  const cards = makeCards(12);
  const a = createLearn(cards, OPTS, { rng: mulberry32(42), now: T0 });
  const b = createLearn(cards, OPTS, { rng: mulberry32(42), now: T0 });
  const c = createLearn(cards, OPTS, { rng: mulberry32(7), now: T0 });
  expect(snapshot(a)).toBe(snapshot(b));
  expect(a.order).not.toEqual(c.order);
  expect(a.order).not.toEqual(cards.map((x) => x.id));
  expect(sorted(a.order)).toEqual(sorted(cards.map((x) => x.id)));
});

test('createLearn: learn options are normalised; retype is a UI option only', () => {
  const cards = makeCards(10);
  const s = createLearn(cards, { answerWith: 'term', learn: { roundSize: 3, mc: false, written: true, retype: true } }, { rng: mulberry32(1), now: T0 });
  expect(s.learn).toEqual({ roundSize: 3, mc: false, written: true });
  expect(s.queue).toHaveLength(3);
  expect(s.queue.every((q) => q.type === 'written' && q.choices === undefined && q.retryChoices === undefined)).toBe(true);
  for (const bad of [0, -2, 'x', NaN, Infinity, null]) {
    const t = createLearn(cards, { learn: { roundSize: bad } }, { rng: mulberry32(1), now: T0 });
    expect(t.learn.roundSize).toBe(7);
  }
  expect(createLearn(cards, { learn: { roundSize: 4.8 } }, { rng: mulberry32(1), now: T0 }).learn.roundSize).toBe(4);
  expect(createLearn(cards, { learn: { mc: false, written: false } }, { rng: mulberry32(1), now: T0 }).learn).toEqual({ roundSize: 7, mc: true, written: true });
  const d = createLearn(cards, undefined, { rng: mulberry32(1), now: T0 });
  expect(d.answerWith).toBe('term');
  expect(d.learn).toEqual({ roundSize: 7, mc: true, written: true });
  expect(createLearn(cards, { answerWith: 'bogus' }, { rng: mulberry32(1), now: T0 }).answerWith).toBe('term');
  expect(createLearn(cards, { answerWith: 'definition' }, { rng: mulberry32(1), now: T0 }).answerWith).toBe('definition');
  const u = createLearn(makeCards(2), OPTS);
  expect(typeof u.startedAt).toBe('number');
});

test('createLearn: skips cards with an empty side, duplicate ids and junk', () => {
  const cards = [
    { id: 'a', term: 'la rue', definition: 'die Strasse' },
    { id: 'b', term: '  ', definition: 'leer' },
    { id: 'c', term: 'le nom', definition: '' },
    { id: 'a', term: 'dup', definition: 'Duplikat' },
    null,
    'card',
    { term: 'ohne id', definition: 'x' },
    { id: 'd', term: 'calme', definition: 'ruhig' },
  ];
  const s = createLearn(cards, OPTS, { rng: mulberry32(1), now: T0 });
  expect(sorted(s.order)).toEqual(['a', 'd']);
  // Two open cards: each comes back after one other question (a d a d).
  expect(s.queue.map((q) => q.cardId)).toEqual([...s.order, ...s.order]);
  // Only askable cards serve as options: "la rue" vs "calme".
  for (const q of s.queue) {
    if (q.type === 'mc') expect(sorted(q.choices.map((c) => c.cardId))).toEqual(['a', 'd']);
    expect(sorted(q.retryChoices.map((c) => c.cardId))).toEqual(['a', 'd']);
  }
  const empty = createLearn(null, OPTS, { now: T0 });
  expect(empty.order).toEqual([]);
  expect(isFinished(empty)).toBe(true);
});

test('stage initialisation from progress: mastered cards are counted but not asked', () => {
  const cards = makeCards(6);
  const progress = {
    c1: progressEntry(2), // mastered
    c2: progressEntry(1), // familiar → written
    c3: progressEntry(0, 1, 1, 'incorrect'), // reset after a right answer → written, not fresh
    c4: progressEntry(5, 6, 1), // mastered
    c6: progressEntry(0, 0, 2, 'incorrect'), // never right → mc, not fresh
  };
  const s = createLearn(cards, OPTS, { progress, rng: mulberry32(3), now: T0 });
  expect(s.stage).toEqual({ ...Object.fromEntries(s.order.map((id) => [id, 0])), c1: 2, c2: 1, c4: 2 });
  expect(s.solved).toEqual({ c1: true, c2: true, c3: true, c4: true });
  expect(sorted(s.initiallyMastered)).toEqual(['c1', 'c4']);
  expect(s.initiallyMastered).toEqual(s.order.filter((id) => id === 'c1' || id === 'c4'));
  expect(sorted([...new Set(s.queue.map((q) => q.cardId))])).toEqual(['c2', 'c3', 'c5', 'c6']);
  expect(s.queue[0].cardId).toBe('c2'); // stage-1 cards first
  expect(s.queue.some((q) => q.cardId === 'c1' || q.cardId === 'c4')).toBe(false);
  // Every card's first question follows its stage.
  const byCard = {};
  for (const q of s.queue) if (!byCard[q.cardId]) byCard[q.cardId] = q;
  expect(byCard.c2.type).toBe('written');
  expect(byCard.c2.choices).toBe(undefined);
  expect(byCard.c3.type).toBe('written');
  expect(byCard.c3.retryChoices).toHaveLength(4);
  expect(byCard.c5.type).toBe('mc');
  expect(byCard.c6.type).toBe('mc');
  // Planned as if every answer were right: c2 is mastered with one question, the others need two.
  expect(s.queue.filter((q) => q.cardId === 'c2')).toHaveLength(1);
  expect(counts(s)).toEqual({ fresh: 1, learning: 3, mastered: 2, total: 6, progress: 2 / 6 });
  expect(isFinished(s)).toBe(false);
});

test('new cards come stage-1 cards first, then stage-0 cards in order', () => {
  const cards = makeCards(10);
  const progress = { c8: progressEntry(1), c9: progressEntry(1) };
  const s = createLearn(cards, { answerWith: 'term', learn: { roundSize: 4 } }, { progress, rng: mulberry32(11), now: T0 });
  const ones = s.order.filter((id) => id === 'c8' || id === 'c9');
  const zeros = s.order.filter((id) => id !== 'c8' && id !== 'c9');
  expect(s.queue.map((q) => q.cardId)).toEqual([...ones, ...zeros.slice(0, 2)]);
  expect(s.queue.map((q) => q.type)).toEqual(['written', 'written', 'mc', 'mc']);
});

test('everything already mastered at start: nothing asked, finished, all counted', () => {
  const cards = makeCards(3);
  const progress = { c1: progressEntry(2), c2: progressEntry(3), c3: progressEntry(2) };
  const s = createLearn(cards, OPTS, { progress, rng: mulberry32(1), now: T0 });
  expect(s.queue).toEqual([]);
  expect(current(s)).toBe(null);
  expect(isRoundOver(s)).toBe(true);
  expect(isFinished(s)).toBe(true);
  expect(s.finishedAt).toBe(T0);
  expect(s.initiallyMastered).toHaveLength(3);
  expect(counts(s)).toEqual({ fresh: 0, learning: 0, mastered: 3, total: 3, progress: 1 });
  expect(finalStats(s)).toEqual({ total: 3, mastered: 3, alreadyMastered: 3, rounds: 0, answered: 0, accuracy: 0, elapsedMs: 0, hardest: [] });
  expect(snapshot(answer(s, true, T0 + SEC))).toBe(snapshot(s));
  expect(snapshot(nextRound(s, cards, mulberry32(1), T0 + SEC))).toBe(snapshot(s));
});

test('empty scope: zero cards, finished, every API safe', () => {
  const cards = makeCards(2).map((c) => ({ ...c, starred: false }));
  const s = createLearn(cards, OPTS, { subset: 'starred', rng: mulberry32(1), now: T0 });
  expect(s.order).toEqual([]);
  expect(isFinished(s)).toBe(true);
  expect(s.finishedAt).toBe(T0);
  expect(current(s)).toBe(null);
  expect(counts(s)).toEqual({ fresh: 0, learning: 0, mastered: 0, total: 0, progress: 0 });
  expect(checkpoint(s)).toEqual({ round: 1, answered: 0, correct: 0, items: [], counts: { fresh: 0, learning: 0, mastered: 0, total: 0 } });
  expect(snapshot(override(s, T0 + SEC))).toBe(snapshot(s));
  expect(snapshot(removeCard(s, 'c1', T0 + SEC))).toBe(snapshot(s));
  expect(snapshot(nextRound(s, cards, mulberry32(1), T0 + SEC))).toBe(snapshot(s));
  expect(finalStats(s).rounds).toBe(0);
});

test('subsets: starred, cardIds, learning, missed and unknown', () => {
  const cards = makeCards(7); // starred: c1, c4, c7
  const rng = () => mulberry32(5);
  expect(sorted(createLearn(cards, OPTS, { subset: 'starred', rng: rng(), now: T0 }).order)).toEqual(['c1', 'c4', 'c7']);
  const ids = createLearn(cards, OPTS, { subset: { cardIds: ['c5', 'x9', 'c2'] }, rng: rng(), now: T0 });
  expect(sorted(ids.order)).toEqual(['c2', 'c5']);
  expect(ids.subset).toEqual({ cardIds: ['c5', 'x9', 'c2'] });
  const progress = { c1: progressEntry(2), c2: progressEntry(0, 1, 1, 'incorrect'), c3: progressEntry(1) };
  const learning = createLearn(cards, OPTS, { subset: 'learning', progress, rng: rng(), now: T0 });
  expect(learning.order).not.toContain('c1');
  expect(learning.order).toHaveLength(6);
  expect(learning.initiallyMastered).toEqual([]);
  expect(createLearn(cards, OPTS, { subset: 'missed', progress, rng: rng(), now: T0 }).order).toEqual(['c2']);
  const all = createLearn(cards, OPTS, { subset: 'whatever', rng: rng(), now: T0 });
  expect(all.subset).toBe('all');
  expect(all.order).toHaveLength(7);
});

// ---------- answering ----------

test('a new card is asked multiple choice, then written, and is mastered after both are correct', () => {
  const cards = makeCards(6);
  let s = createLearn(cards, OPTS, { rng: mulberry32(2), now: T0 });
  const id = current(s).cardId;
  expect(current(s).type).toBe('mc');
  s = answer(s, true, T0 + 10 * SEC);
  expect(s.stage[id]).toBe(1);
  expect(s.roundLog).toEqual([{ qid: `1.1:${id}`, cardId: id, type: 'mc', ask: 'term', correct: true, stageAfter: 1 }]);
  expect(s.last).toEqual({ qid: `1.1:${id}`, cardId: id, type: 'mc', ask: 'term', correct: true, stageBefore: 0 });
  expect(s.clock).toBe(1);
  expect(s.lastAt).toEqual({ [id]: 0 });
  // Six open cards: it comes back after the five others (min(10, open - 1)), written.
  expect(s.queue.map((q) => q.cardId)).toEqual([...s.order.slice(1), id]);
  const again = s.queue[5];
  expect(again.qid).toBe(`1.1.2:${id}`);
  expect(again.type).toBe('written');
  expect(again.choices).toBe(undefined);
  s = playRound(s, () => true, T0 + 10 * SEC);
  expect(s.stage[id]).toBe(2);
  expect(s.roundLog[6]).toEqual({ qid: `1.1.2:${id}`, cardId: id, type: 'written', ask: 'term', correct: true, stageAfter: 2 });
  expect(counts(s)).toEqual({ fresh: 0, learning: 5, mastered: 1, total: 6, progress: 1 / 6 });
  s = nextRound(s, cards, mulberry32(3), T0 + MIN);
  expect(s.round).toBe(2);
  // The other five come back written, the one asked longest ago first.
  expect(s.queue.map((q) => q.cardId)).toEqual(s.order.slice(1));
  for (const q of s.queue) {
    expect(q.type).toBe('written');
    expect(q.choices).toBe(undefined);
    expect(q.qid).toBe(`2.1:${q.cardId}`);
  }
  s = playRound(s, () => true, T0 + MIN);
  expect(isFinished(s)).toBe(true);
  expect(s.answered).toBe(12);
  expect(counts(s)).toEqual({ fresh: 0, learning: 0, mastered: 6, total: 6, progress: 1 });
});

test('a wrong written answer resets the stage but stays written (multiple choice only once)', () => {
  const cards = makeCards(5);
  const progress = Object.fromEntries(cards.map((c) => [c.id, progressEntry(1)]));
  let s = createLearn(cards, OPTS, { progress, rng: mulberry32(4), now: T0 });
  // Planned as if every answer were right: one written question per card masters it.
  expect(s.queue.map((q) => q.cardId)).toEqual(s.order);
  expect(s.queue.every((q) => q.type === 'written')).toBe(true);
  const id = current(s).cardId;
  s = answer(s, false, T0 + 10 * SEC);
  expect(s.stage[id]).toBe(0);
  expect(s.last).toEqual({ qid: `1.1:${id}`, cardId: id, type: 'written', ask: 'term', correct: false, stageBefore: 1 });
  // No retry at the end of the round.
  expect(s.queue.some((q) => q.cardId === id)).toBe(false);
  s = playRound(s, () => true, T0 + 10 * SEC);
  expect(checkpoint(s).items.find((it) => it.cardId === id)).toEqual({ cardId: id, stage: 0, results: [false] });
  s = nextRound(s, cards, mulberry32(5), T0 + MIN);
  // The only open card, answered right before: written twice (nothing else to wait for).
  expect(s.solved[id]).toBe(true);
  expect(s.queue.map((q) => [q.qid, q.type])).toEqual([
    [`2.1:${id}`, 'written'],
    [`2.1.2:${id}`, 'written'],
  ]);
  s = answer(s, true, T0 + MIN + 5 * SEC);
  expect(s.stage[id]).toBe(1);
  expect(isFinished(s)).toBe(false);
  s = answer(s, true, T0 + MIN + 10 * SEC);
  expect(isFinished(s)).toBe(true);
});

test('multiple choice only until a card was answered right once', () => {
  const cards = makeCards(2);
  const opts = { answerWith: 'term', learn: { roundSize: 4 } };
  const types = (st, id) => st.queue.filter((q) => q.cardId === id).map((q) => q.type);
  let s = createLearn(cards, opts, { rng: mulberry32(12), now: T0 });
  const [a, b] = s.order;
  expect(s.queue.map((q) => [q.cardId, q.type])).toEqual([[a, 'mc'], [b, 'mc'], [a, 'written'], [b, 'written']]);
  // A multiple-choice miss: the card's later question is multiple choice again.
  s = answer(s, false, T0 + SEC);
  expect(s.solved).toEqual({});
  expect(types(s, a)).toEqual(['mc']);
  checkChoices(s.queue.find((q) => q.cardId === a), cards);
  // Right once: written from then on.
  s = answer(s, true, T0 + 2 * SEC);
  expect(s.solved).toEqual({ [b]: true });
  expect(types(s, b)).toEqual(['written']);
  s = answer(s, true, T0 + 3 * SEC);
  expect(s.solved).toEqual({ [a]: true, [b]: true });
  // A written miss resets the stage, but the card stays written.
  expect(current(s)).toEqual({ qid: `1.1.2:${b}`, cardId: b, type: 'written', ask: 'term' });
  s = answer(s, false, T0 + 4 * SEC);
  expect(s.stage[b]).toBe(0);
  expect(s.solved).toEqual({ [a]: true, [b]: true });
  expect(isRoundOver(s)).toBe(true);
  s = nextRound(s, cards, mulberry32(13), T0 + MIN);
  expect(types(s, b)).toEqual(['written', 'written']);
  expect(s.queue.every((q) => q.type === 'written')).toBe(true);
  const { log } = playSession(s, cards, () => true, { seed: 14 });
  expect(log.every((e) => e.type === 'written')).toBe(true);

  // "Ich hatte recht" after a multiple-choice miss counts as right.
  let o = createLearn(cards, opts, { rng: mulberry32(12), now: T0 });
  o = answer(o, false, T0 + SEC);
  o = override(o, T0 + 2 * SEC);
  expect(o.solved).toEqual({ [a]: true });
  expect(types(o, a)).toEqual(['written']);

  // Answered right elsewhere (Write mode) and then wrong: still stage 0, but written.
  let w = createLearn(cards, opts, { rng: mulberry32(12), now: T0 });
  const elsewhere = { [a]: progressEntry(0, 1, 1, 'incorrect') };
  expect(solvedFromProgress(elsewhere[a])).toBe(true);
  expect(solvedFromProgress(progressEntry(0, 0, 3, 'incorrect'))).toBe(false);
  expect(solvedFromProgress(undefined)).toBe(false);
  expect(matchesProgress(w, elsewhere)).toBe(false);
  w = syncProgress(w, elsewhere, T0 + SEC);
  expect(w.stage[a]).toBe(0);
  expect(w.solved).toEqual({ [a]: true });
  expect(types(w, a)).toEqual(['written', 'written']);
  expect(types(w, b)).toEqual(['mc', 'written']);
  expect(matchesProgress(w, elsewhere)).toBe(true);
  // Progress reset: multiple choice again, with the options the questions kept.
  const before = w;
  w = syncProgress(w, {}, T0 + 2 * SEC);
  expect(w.solved).toEqual({});
  expect(types(w, a)).toEqual(['mc', 'mc']);
  w.queue.forEach((q, i) => {
    if (q.cardId === a) expect(q.choices).toEqual(before.queue[i].retryChoices);
  });
});

test('a wrong answer is not retried at the end of the round; the card comes back after the gap', () => {
  const cards = makeCards(20);
  let s = createLearn(cards, OPTS, { rng: mulberry32(6), now: T0 });
  const id = current(s).cardId;
  s = answer(s, false, T0 + SEC);
  expect(s.misses).toEqual({ [id]: 1 });
  expect(s.queue.map((q) => q.cardId)).toEqual(s.order.slice(1, 7));
  const r = playRound(s, () => true, T0 + SEC);
  expect(r.roundLog.filter((e) => e.cardId === id)).toHaveLength(1);
  // Answering past the end of the round changes nothing.
  expect(snapshot(answer(r, true, T0 + MIN))).toBe(snapshot(r));
  const { log } = playSession(s, cards, () => true, { seed: 7 });
  const back = log.find((e) => e.cardId === id);
  expect(back.wait).toBeGreaterThanOrEqual(MIN_GAP);
  expect(back.wait).toBeLessThanOrEqual(MAX_WAIT);
  expect(back.round).toBeGreaterThan(1);
  expect(back.qid).toBe(`${back.round}.1:${id}`);
  expect(back.type).toBe('mc');
});

test('nextRound is a no-op while the round is still running', () => {
  const cards = makeCards(3);
  let s = createLearn(cards, OPTS, { rng: mulberry32(1), now: T0 });
  s = answer(s, false, T0 + SEC);
  const after = nextRound(s, cards, mulberry32(1), T0 + MIN);
  expect(snapshot(after)).toBe(snapshot(s));
  expect(after).not.toBe(s);
});

// ---------- rounds ----------

test('nextRound: mastered cards leave, then new cards come, stage-1 cards before stage-0 cards in order', () => {
  const cards = makeCards(8);
  const progress = { c2: progressEntry(1), c4: progressEntry(1), c6: progressEntry(1), c8: progressEntry(1) };
  const opts = { answerWith: 'term', learn: { roundSize: 3 } };
  let s = createLearn(cards, opts, { progress, rng: mulberry32(4), now: T0 });
  const ones = s.order.filter((id) => progress[id]);
  const zeros = s.order.filter((id) => !progress[id]);
  expect(s.queue.map((q) => q.cardId)).toEqual(ones.slice(0, 3));
  expect(s.queue.every((q) => q.type === 'written')).toBe(true);
  s = playRound(s, () => true, T0);
  expect(ones.slice(0, 3).every((id) => s.stage[id] === 2)).toBe(true);
  s = nextRound(s, cards, mulberry32(5), T0 + MIN);
  expect(s.round).toBe(2);
  expect(s.rounds).toEqual([{ round: 1, answered: 3, correct: 3, cardIds: ones.slice(0, 3) }]);
  expect(s.queue.map((q) => q.cardId)).toEqual([ones[3], zeros[0], zeros[1]]);
  const types = Object.fromEntries(s.queue.map((q) => [q.cardId, q.type]));
  expect(types).toEqual({ [ones[3]]: 'written', [zeros[0]]: 'mc', [zeros[1]]: 'mc' });
});

test('nextRound: a missed card stays open and comes back once it waited its gap', () => {
  const cards = makeCards(8);
  const progress = { c2: progressEntry(1), c4: progressEntry(1), c6: progressEntry(1), c8: progressEntry(1) };
  let s = createLearn(cards, { answerWith: 'term', learn: { roundSize: 3 } }, { progress, rng: mulberry32(4), now: T0 });
  const ones = s.order.filter((id) => progress[id]);
  const zeros = s.order.filter((id) => !progress[id]);
  const keep = ones[1];
  s = playRound(s, (q) => q.cardId !== keep, T0);
  expect(s.stage[keep]).toBe(0);
  expect(s.lastAt[keep]).toBe(1);
  s = nextRound(s, cards, mulberry32(5), T0 + MIN);
  expect(s.rounds[0]).toEqual({ round: 1, answered: 3, correct: 2, cardIds: ones.slice(0, 3) });
  // Six cards open: keep waits for five other questions, new cards come meanwhile.
  expect(s.queue.map((q) => q.cardId)).toEqual([ones[3], zeros[0], zeros[1]]);
  const { log } = playSession(s, cards, () => true, { seed: 6 });
  const back = log.find((e) => e.cardId === keep);
  expect(back.wait).toBeGreaterThanOrEqual(Math.min(MIN_GAP, back.open - 1));
  // Answered right before (progress): written, also after the miss.
  expect(back.type).toBe('written');
  expect(log.filter((e) => e.cardId === keep).map((e) => e.type)).toEqual(['written', 'written']);
});

test('the session order is shuffled once; new cards follow it', () => {
  const cards = makeCards(10);
  let differs = 0;
  for (let seed = 1; seed <= 30; seed++) {
    const s = createLearn(cards, OPTS, { rng: mulberry32(seed), now: T0 });
    expect(s.queue.map((q) => q.cardId)).toEqual(s.order.slice(0, 7));
    if (s.order.join() !== cards.map((c) => c.id).join()) differs++;
  }
  expect(differs).toBeGreaterThan(25);
});

test('20 cards with roundSize 7, all answers correct: every card twice, multiple choice then written', () => {
  const cards = makeCards(20);
  const s0 = createLearn(cards, OPTS, { rng: mulberry32(8), now: T0 });
  const { s, log } = playSession(s0, cards, () => true, { seed: 100 });
  expect(log).toHaveLength(40);
  // New cards in session order.
  expect(log.filter((e) => e.wait === null).map((e) => e.cardId)).toEqual(s0.order);
  for (const id of s0.order) {
    const mine = log.filter((e) => e.cardId === id);
    expect(mine.map((e) => e.type)).toEqual(['mc', 'written']);
    expect(mine[1].wait).toBeGreaterThanOrEqual(Math.min(MIN_GAP, mine[1].open - 1));
    expect(mine[1].wait).toBeLessThanOrEqual(MAX_WAIT + 1);
  }
  expect(s.rounds.map((r) => r.round)).toEqual([1, 2, 3, 4, 5, 6]);
  expect(s.rounds.map((r) => r.answered)).toEqual([7, 7, 7, 7, 7, 5]);
  expect(s.rounds.map((r) => r.correct)).toEqual([7, 7, 7, 7, 7, 5]);
  // A round's cards in the order of their first answer in it.
  for (const r of s.rounds) expect(r.cardIds).toEqual([...new Set(log.filter((e) => e.round === r.round).map((e) => e.cardId))]);
  const stats = finalStats(s);
  expect(stats.total).toBe(20);
  expect(stats.mastered).toBe(20);
  expect(stats.rounds).toBe(6);
  expect(stats.answered).toBe(40);
  expect(stats.accuracy).toBe(1);
  expect(stats.hardest).toEqual([]);
});

test('20 cards with roundSize 7 and random mistakes: invariants hold until finished', () => {
  for (let seed = 1; seed <= 25; seed++) {
    const rng = mulberry32(seed);
    const cards = makeCards(20);
    let s = createLearn(cards, { answerWith: seed % 3 === 0 ? 'both' : 'term' }, { rng, now: T0 });
    let t = T0;
    let rounds = 0;
    while (!isFinished(s)) {
      if (rounds++ > 200) throw new Error(`seed ${seed}: did not finish`);
      expect(s.queue.length).toBeGreaterThan(0);
      expect(s.queue.length).toBeLessThanOrEqual(7);
      // Question ids: this round, learning, a card's n-th question in the round gets ".n".
      const nth = {};
      for (const q of s.queue) {
        nth[q.cardId] = (nth[q.cardId] || 0) + 1;
        const m = QID.exec(q.qid);
        expect([Number(m[1]), m[2], m[3], m[4]]).toEqual([s.round, '1', nth[q.cardId] > 1 ? String(nth[q.cardId]) : undefined, q.cardId]);
      }
      while (!isRoundOver(s)) {
        t += 4 * SEC;
        const q = current(s);
        expect(s.stage[q.cardId]).toBeLessThan(2);
        // Multiple choice only until the card was answered right once.
        expect(q.type).toBe(s.stage[q.cardId] === 0 && !s.solved[q.cardId] ? 'mc' : 'written');
        if (q.type === 'mc') checkChoices(q, cards);
        const before = s;
        s = answer(s, rng() < 0.7, t);
        expect(s.clock).toBe(before.clock + 1);
        expect(s.lastAt[q.cardId]).toBe(before.clock);
        expect(s.repeats).toBe(q.cardId in before.lastAt ? before.repeats + 1 : 0);
        if (!s.last.correct && rng() < 0.15) s = override(s, t + SEC);
        expect(!!s.solved[q.cardId]).toBe(!!before.solved[q.cardId] || s.last.correct);
        // Queued questions of the card follow its stage at once.
        for (const x of s.queue) {
          if (x.cardId === q.cardId) expect(x.type).toBe(s.stage[q.cardId] === 0 && !s.solved[q.cardId] ? 'mc' : 'written');
        }
      }
      expect(s.clock).toBe(s.answered);
      const missSum = Object.values(s.misses).reduce((a, b) => a + b, 0);
      expect(missSum).toBe(s.answered - s.correct);
      s = nextRound(s, cards, rng, t + SEC);
    }
    s = nextRound(s, cards, rng, t + 2 * SEC);
    expect(counts(s)).toEqual({ fresh: 0, learning: 0, mastered: 20, total: 20, progress: 1 });
    expect(s.rounds.map((r) => r.round)).toEqual(s.rounds.map((_, i) => i + 1));
    expect(s.rounds.reduce((n, r) => n + r.answered, 0)).toBe(s.answered);
    expect(s.rounds.reduce((n, r) => n + r.correct, 0)).toBe(s.correct);
    expect(finalStats(s).rounds).toBe(s.rounds.length);
    expect(s.finishedAt).not.toBe(null);
  }
});

test('finishing: finishedAt on the last answer, nextRound closes the final round once', () => {
  const cards = makeCards(2);
  let s = createLearn(cards, { answerWith: 'term', learn: { roundSize: 3 } }, { rng: mulberry32(9), now: T0 });
  const [a, b] = s.order;
  // Two open cards: each comes back after one other question.
  expect(s.queue.map((q) => q.qid)).toEqual([`1.1:${a}`, `1.1:${b}`, `1.1.2:${a}`]);
  s = playRound(s, () => true, T0);
  expect(isFinished(s)).toBe(false);
  s = nextRound(s, cards, mulberry32(1), T0 + MIN);
  expect(s.queue.map((q) => q.qid)).toEqual([`2.1:${b}`]);
  s = answer(s, true, T0 + MIN + 10 * SEC);
  expect(isFinished(s)).toBe(true);
  expect(isRoundOver(s)).toBe(true);
  expect(s.finishedAt).toBe(T0 + MIN + 10 * SEC);
  expect(finalStats(s).rounds).toBe(2);
  const closed = nextRound(s, cards, mulberry32(1), T0 + 2 * MIN);
  expect(closed.round).toBe(2);
  expect(closed.rounds.map((r) => [r.round, r.answered, r.correct])).toEqual([
    [1, 3, 3],
    [2, 1, 1],
  ]);
  expect(closed.finishedAt).toBe(T0 + MIN + 10 * SEC);
  // The final round's checkpoint is still available.
  expect(checkpoint(closed).round).toBe(2);
  expect(checkpoint(closed).answered).toBe(1);
  expect(snapshot(nextRound(closed, cards, mulberry32(1), T0 + 3 * MIN))).toBe(snapshot(closed));
  expect(finalStats(closed).rounds).toBe(2);
});

// ---------- spacing (Abstand) and the mix ----------

test('spacing constants', () => {
  expect([MIN_GAP, MAX_WAIT, MAX_REPEATS, MAX_LEARNING, RECHECK_GAP, RECHECK_WAIT, RECHECK_MIN_CARDS]).toEqual([10, 15, 3, 10, 30, 50, 60]);
});

test('spacing: with 11 or more open cards a card comes back after at least 10 other questions', () => {
  const cards = makeCards(20);
  // c1 was asked before and has waited `wait` questions; the 19 others are new.
  let came = 0;
  for (let wait = 0; wait <= MAX_WAIT; wait++) {
    for (let seed = 1; seed <= 20; seed++) {
      const s = planFrom(cards, { stage: { c1: 1 }, lastAt: lastAtFor(['c1'], [wait], 30), clock: 30, seed });
      const at = s.queue.findIndex((q) => q.cardId === 'c1');
      if (at >= 0) came++;
      // Never before it waited MIN_GAP other questions (the ones planned before it count too).
      expect(at === -1 || wait + at >= MIN_GAP).toBe(true);
    }
  }
  expect(came).toBeGreaterThan(100);
  // Played sessions, every answer right (the plan is what happens) or with mistakes.
  let many = 0;
  for (const [n, seed, p] of [[12, 1, 1], [20, 2, 1], [35, 3, 1], [30, 4, 0.7], [30, 5, 0.5]]) {
    const d = mulberry32(seed + 50);
    const { log } = playSession(createLearn(makeCards(n), OPTS, { rng: mulberry32(seed), now: T0 }), makeCards(n), () => d() < p, { seed });
    const again = log.filter((e) => e.wait !== null);
    many += again.filter((e) => e.open > MIN_GAP).length;
    for (const e of again) {
      if (e.open > MIN_GAP) expect(e.wait).toBeGreaterThanOrEqual(MIN_GAP);
      if (p === 1) expect(e.wait).toBeGreaterThanOrEqual(e.open - 1 < MIN_GAP ? e.open - 1 : MIN_GAP);
    }
  }
  expect(many).toBeGreaterThan(50);
});

test('spacing: with fewer open cards the gap shrinks to open - 1', () => {
  // Three new cards: a b c a b c (two others in between), two cards alternate, one comes again at once.
  for (const n of [1, 2, 3]) {
    const s = createLearn(makeCards(n), OPTS, { rng: mulberry32(n), now: T0 });
    expect(s.queue.map((q) => q.cardId)).toEqual([...s.order, ...s.order]);
  }
  // Four cards asked before, nothing new: each comes as soon as it waited (open - 1); as cards
  // are mastered fewer are open, so the gaps shrink.
  const four = makeCards(4);
  const s4 = planFrom(four, { stage: { c1: 1, c2: 1, c3: 1, c4: 1 }, lastAt: { c1: 6, c2: 7, c3: 8, c4: 9 }, clock: 10 });
  expect(s4.queue.map((q) => q.qid)).toEqual(['1.1:c1', '1.1:c2', '1.1:c3', '1.1:c4']);
  // c1 waited only 2 of the 3 needed: the others come first.
  const s5 = planFrom(four, { stage: { c1: 1, c2: 1, c3: 1, c4: 1 }, lastAt: { c4: 6, c1: 7, c2: 8, c3: 9 }, clock: 10 });
  expect(s5.queue.map((q) => q.cardId)).toEqual(['c4', 'c1', 'c2', 'c3']);
  // Five new cards, all answers right: every card again after exactly four others.
  const { log } = playSession(createLearn(makeCards(5), OPTS, { rng: mulberry32(4), now: T0 }), makeCards(5), () => true);
  expect(log.filter((e) => e.wait !== null).map((e) => e.wait)).toEqual([4, 4, 4, 4, 4]);
});

test('spacing: no card may come yet and nothing is new: the one waiting longest comes early', () => {
  // Only possible with a repaired state (two cards answered at the same place).
  const cards = makeCards(3);
  const s = planFrom(cards, { stage: { c1: 1, c2: 1, c3: 1 }, lastAt: { c1: 9, c2: 9, c3: 8 }, clock: 10, roundSize: 1 });
  // c3 waited 1, c1 and c2 0 of the 2 needed.
  expect(s.queue.map((q) => q.cardId)).toEqual(['c3']);
  const t = planFrom(cards, { stage: { c1: 1, c2: 1, c3: 1 }, lastAt: { c1: 9, c2: 9, c3: 9 }, clock: 10, roundSize: 1 });
  // A tie goes to the card earlier in the session order.
  expect(t.queue.map((q) => q.cardId)).toEqual(['c1']);
});

test('spacing: a waiting card comes for sure once it waited 15, the longest overdue first', () => {
  const cards = makeCards(20);
  // c1 and c2 asked before (c2 waited longer), all others new: no new card comes first.
  for (let seed = 1; seed <= 20; seed++) {
    const s = planFrom(cards, { stage: { c1: 1, c2: 1 }, lastAt: lastAtFor(['c1', 'c2'], [MAX_WAIT, MAX_WAIT + 1], 40), clock: 40, seed });
    expect(s.queue.slice(0, 2).map((q) => q.cardId)).toEqual(['c2', 'c1']);
    expect(s.queue.slice(2).every((q) => q.qid === `1.1:${q.cardId}` && q.cardId !== 'c1' && q.cardId !== 'c2')).toBe(true);
  }
  // In between, the chance grows with every question it waits: (wait - 9) in 6.
  for (let wait = MIN_GAP; wait < MAX_WAIT; wait++) {
    let hits = 0;
    for (let seed = 1; seed <= 300; seed++) {
      const s = planFrom(cards, { stage: { c1: 1 }, lastAt: lastAtFor(['c1'], [wait], 40), clock: 40, seed, roundSize: 1 });
      if (s.queue[0].cardId === 'c1') hits++;
    }
    const want = (300 * (wait - MIN_GAP + 1)) / (MAX_WAIT - MIN_GAP + 1);
    expect(Math.abs(hits - want)).toBeLessThan(35);
  }
  // Played sessions, every answer right: once a card waited 15 it is asked (the longest overdue
  // first), unless a new card has to come after three repeats. So no card waits more than 16.
  let checked = 0;
  for (const [n, seed] of [[25, 1], [40, 2], [40, 3], [60, 4], [60, 5], [60, 6]]) {
    const { log } = playSession(createLearn(makeCards(n), OPTS, { rng: mulberry32(seed), now: T0 }), makeCards(n), () => true, { seed });
    for (const e of log) {
      expect(e.wait === null || e.wait <= MAX_WAIT + 1).toBe(true);
      const overdue = e.waits.filter((w) => w.wait >= MAX_WAIT);
      if (!overdue.length) continue;
      checked++;
      if (e.wait === null) expect(e.repeatsBefore).toBeGreaterThanOrEqual(e.inFlight >= MAX_LEARNING ? 2 * MAX_REPEATS : MAX_REPEATS);
      else expect(e.wait).toBe(Math.max(...overdue.map((w) => w.wait)));
    }
  }
  expect(checked).toBeGreaterThan(10);
});

test('mix: at most 3 repeats in a row while there are new cards', () => {
  const cards = makeCards(20);
  const four = ['c1', 'c2', 'c3', 'c4'];
  const base = { stage: Object.fromEntries(four.map((id) => [id, 1])), lastAt: lastAtFor(four, [18, 17, 16, 15], 40), clock: 40 };
  // Four overdue cards: after three of them a new card comes first (c5: the first new one).
  expect(planFrom(cards, base).queue.slice(0, 5).map((q) => q.cardId)).toEqual(['c1', 'c2', 'c3', 'c5', 'c4']);
  // Three repeats before this round: a new card right away.
  expect(planFrom(cards, { ...base, repeats: MAX_REPEATS }).queue.slice(0, 5).map((q) => q.cardId)).toEqual(['c5', 'c1', 'c2', 'c3', 'c6']);
  // Without new cards repeats go on.
  const old = cards.slice(0, 4);
  expect(planFrom(old, { ...base, repeats: MAX_REPEATS }).queue.map((q) => q.cardId)).toEqual(four);
  // Played sessions, also with mistakes: the runs of repeats while new cards are waiting.
  for (const [p, seed] of [[1, 1], [1, 2], [0.8, 3], [0.6, 4]]) {
    const d = mulberry32(seed + 70);
    const { log } = playSession(createLearn(makeCards(30), OPTS, { rng: mulberry32(seed), now: T0 }), makeCards(30), () => d() < p, { seed });
    let run = 0;
    let longest = 0;
    for (const e of log) {
      run = e.wait === null ? 0 : run + 1;
      expect(run).toBe(e.wait === null ? 0 : e.repeatsBefore + 1);
      if (e.fresh > 0) {
        expect(run).toBeLessThanOrEqual(e.inFlight >= MAX_LEARNING ? 2 * MAX_REPEATS : MAX_REPEATS);
        if (e.inFlight < MAX_LEARNING) longest = Math.max(longest, run);
      }
    }
    expect(longest).toBe(MAX_REPEATS);
  }
});

test('mix: while 10 cards are being learned a new card comes only after 6 repeats', () => {
  const cards = makeCards(20);
  const ten = cards.slice(0, 10).map((c) => c.id);
  const stage = Object.fromEntries(ten.map((id) => [id, 1]));
  const base = { stage, lastAt: lastAtFor(ten, [19, 18, 17, 16, 15, 14, 13, 12, 11, 10], 40), clock: 40 };
  // Full: after three repeats still a card being learned (the most overdue) …
  expect(planFrom(cards, { ...base, repeats: MAX_REPEATS }).queue[0].cardId).toBe('c1');
  expect(planFrom(cards, { ...base, repeats: 2 * MAX_REPEATS - 1 }).queue[0].cardId).toBe('c1');
  // … after six a new one.
  expect(planFrom(cards, { ...base, repeats: 2 * MAX_REPEATS }).queue[0].cardId).toBe('c11');
  // A card that may come comes for sure (no chance for a new card); the one furthest past the gap.
  const ready = { stage, lastAt: lastAtFor(ten, [11, 14, 12, 10, 13, 11, 14, 12, 10, 13], 40), clock: 40 };
  for (let seed = 1; seed <= 20; seed++) expect(planFrom(cards, { ...ready, seed, roundSize: 1 }).queue[0].cardId).toBe('c2');
  // With nine being learned the usual limit holds: after three repeats a new card.
  const nine = ten.slice(0, 9);
  const notFull = { stage: Object.fromEntries(nine.map((id) => [id, 1])), lastAt: lastAtFor(nine, [19, 18, 17, 16, 15, 14, 13, 12, 11], 40), clock: 40 };
  expect(planFrom(cards, { ...notFull, repeats: MAX_REPEATS }).queue[0].cardId).toBe('c10');
  // Played: every answer wrong for a while. With 10 or more cards being learned a new card comes
  // only after six repeats (or when no card may come yet).
  const n = 40;
  let full = 0;
  const { s, log } = playSession(createLearn(makeCards(n), OPTS, { rng: mulberry32(9), now: T0 }), makeCards(n), (q, st) => st.answered >= 150, { seed: 9 });
  for (const e of log.slice(0, 150)) {
    if (e.inFlight < MAX_LEARNING) continue;
    full++;
    if (e.wait !== null) continue;
    const anyReady = e.waits.some((w) => w.wait >= Math.min(MIN_GAP, e.open - 1));
    if (anyReady) expect(e.repeatsBefore).toBeGreaterThanOrEqual(2 * MAX_REPEATS);
  }
  expect(full).toBeGreaterThan(100);
  // Fewer new cards started than without the limit (one in four).
  expect(log.slice(0, 150).filter((e) => e.wait === null).length).toBeLessThan(150 / (MAX_REPEATS + 1));
  expect(isFinished(s)).toBe(true);
});

test("a wrong answer: the card's later question in the round is asked as multiple choice at its place", () => {
  const cards = makeCards(3);
  let s = createLearn(cards, OPTS, { rng: mulberry32(5), now: T0 });
  const [a, b, c] = s.order;
  const plan = s.queue.map((q) => ({ ...q }));
  expect(plan.map((q) => q.qid)).toEqual([`1.1:${a}`, `1.1:${b}`, `1.1:${c}`, `1.1.2:${a}`, `1.1.2:${b}`, `1.1.2:${c}`]);
  expect(plan.map((q) => q.type)).toEqual(['mc', 'mc', 'mc', 'written', 'written', 'written']);
  s = answer(s, false, T0 + SEC);
  expect(s.queue.map((q) => q.qid)).toEqual(plan.slice(1).map((q) => q.qid));
  expect(s.queue[2]).toEqual({ qid: `1.1.2:${a}`, cardId: a, type: 'mc', ask: 'term', choices: plan[3].retryChoices, retryChoices: plan[3].retryChoices });
  checkChoices(s.queue[2], cards);
  // "Ich hatte recht": back to written.
  expect(override(s, T0 + 2 * SEC).queue[2]).toEqual(plan[3]);
  // Right the second time: stage 1, so the card comes once more in a later round.
  s = answer(s, true, T0 + 3 * SEC);
  s = answer(s, true, T0 + 4 * SEC);
  s = answer(s, true, T0 + 5 * SEC);
  expect(s.stage[a]).toBe(1);
  s = playRound(s, () => true, T0 + 5 * SEC);
  expect([s.stage[b], s.stage[c]]).toEqual([2, 2]);
  expect(isFinished(s)).toBe(false);
  s = nextRound(s, cards, mulberry32(6), T0 + MIN);
  expect(s.queue.map((q) => [q.qid, q.type])).toEqual([[`2.1:${a}`, 'written']]);
});

test('question ids: <round>.<kind>:<card>, a later question of the card in the round <round>.<kind>.<n>:<card>', () => {
  const s = createLearn([{ id: 'solo', term: 'le soleil', definition: 'die Sonne' }], OPTS, { rng: mulberry32(1), now: T0 });
  expect(s.queue.map((q) => q.qid)).toEqual(['1.1:solo', '1.1.2:solo']);
  // Card ids may contain anything, also ':' and '.'.
  const odd = [
    { id: 'a:b', term: 'un', definition: 'eins' },
    { id: '1.2', term: 'deux', definition: 'zwei' },
  ];
  const t = createLearn(odd, OPTS, { rng: mulberry32(1), now: T0 });
  expect(sorted(t.queue.map((q) => q.qid))).toEqual(sorted(['1.1:a:b', '1.1:1.2', '1.1.2:a:b', '1.1.2:1.2']));
  // In whole sessions: the round, the kind and the card's number in the round. The plan masters a
  // card with two right answers, so a card has at most two questions in a round.
  let most = 0;
  for (const n of [2, 9]) {
    const cards = makeCards(n);
    const d = mulberry32(3);
    const { log } = playSession(createLearn(cards, OPTS, { rng: mulberry32(2), now: T0 }), cards, () => d() < 0.5, { seed: 2 });
    const nth = {};
    for (const e of log) {
      const key = `${e.round}/${e.cardId}`;
      nth[key] = (nth[key] || 0) + 1;
      expect(e.qid).toBe(nth[key] > 1 ? `${e.round}.1.${nth[key]}:${e.cardId}` : `${e.round}.1:${e.cardId}`);
      most = Math.max(most, nth[key]);
    }
  }
  expect(most).toBe(2);
});

// ---------- checkpoint, counts, finalStats ----------

test('checkpoint: per-card results in asked order and counts', () => {
  const cards = makeCards(3);
  let s = createLearn(cards, OPTS, { rng: mulberry32(6), now: T0 });
  const [x, y, z] = s.order;
  expect(s.queue.map((q) => q.cardId)).toEqual([x, y, z, x, y, z]);
  s = answer(s, true, T0 + SEC);
  s = answer(s, false, T0 + 2 * SEC);
  expect(checkpoint(s)).toEqual({
    round: 1,
    answered: 2,
    correct: 1,
    items: [
      { cardId: x, stage: 1, results: [true] },
      { cardId: y, stage: 0, results: [false] },
    ],
    counts: { fresh: 1, learning: 2, mastered: 0, total: 3 },
  });
  s = answer(s, true, T0 + 3 * SEC); // z
  s = answer(s, true, T0 + 4 * SEC); // x again: mastered
  expect(current(s)).toEqual({ ...current(s), qid: `1.1.2:${y}`, type: 'mc' }); // y again, multiple choice now
  s = answer(s, true, T0 + 5 * SEC);
  expect(checkpoint(s)).toEqual({
    round: 1,
    answered: 5,
    correct: 4,
    items: [
      { cardId: x, stage: 2, results: [true, true] },
      { cardId: y, stage: 1, results: [false, true] },
      { cardId: z, stage: 1, results: [true] },
    ],
    counts: { fresh: 0, learning: 2, mastered: 1, total: 3 },
  });
});

test('counts: fresh means never answered (in this session or before)', () => {
  const cards = makeCards(5);
  const progress = { c1: progressEntry(0, 0, 2, 'incorrect'), c2: progressEntry(2) };
  let s = createLearn(cards, OPTS, { progress, rng: mulberry32(12), now: T0 });
  expect(counts(s)).toEqual({ fresh: 3, learning: 1, mastered: 1, total: 5, progress: 0.2 });
  // A fresh card answered wrong is no longer fresh, although its stage stays 0.
  const id = s.queue.find((q) => q.cardId !== 'c1').cardId;
  while (current(s).cardId !== id) s = answer(s, true, T0 + SEC);
  const before = counts(s);
  s = answer(s, false, T0 + 2 * SEC);
  expect(s.stage[id]).toBe(0);
  expect(counts(s).fresh).toBe(before.fresh - 1);
  expect(counts(s).learning).toBe(before.learning + 1);
  expect(counts(null)).toEqual({ fresh: 0, learning: 0, mastered: 0, total: 0, progress: 0 });
});

test('finalStats: accuracy, rounds, answered and hardest cards', () => {
  const cards = makeCards(3);
  let s = createLearn(cards, OPTS, { rng: mulberry32(13), now: T0 });
  const [a, b, c] = s.order;
  expect(s.queue.map((q) => q.cardId)).toEqual([a, b, c, a, b, c]);
  s = playRound(s, planned({ [a]: [false, false], [b]: [false, true], [c]: [true, true] }), T0);
  expect([s.stage[a], s.stage[b], s.stage[c]]).toEqual([0, 1, 2]);
  s = nextRound(s, cards, mulberry32(1), T0 + MIN);
  // a waited longest, b is mastered by one more answer, then a again.
  expect(s.queue.map((q) => q.cardId)).toEqual([a, b, a]);
  s = playRound(s, () => true, T0 + MIN);
  expect(isFinished(s)).toBe(true);
  const stats = finalStats(s);
  expect(stats.total).toBe(3);
  expect(stats.mastered).toBe(3);
  expect(stats.rounds).toBe(2);
  expect(stats.answered).toBe(9);
  expect(stats.accuracy).toBe(6 / 9);
  expect(stats.hardest).toEqual([
    { cardId: a, misses: 2 },
    { cardId: b, misses: 1 },
  ]);
  expect(stats.elapsedMs).toBe(s.elapsedMs);
  expect(stats.elapsedMs).toBeGreaterThan(0);
});

test('finalStats: hardest ties keep the session order, every missed card', () => {
  const cards = makeCards(12);
  // 11 questions: 11 new cards (the first one may come back only after 10 others).
  let s = createLearn(cards, { answerWith: 'term', learn: { roundSize: 11 } }, { rng: mulberry32(14), now: T0 });
  expect(s.queue.map((q) => q.cardId)).toEqual(s.order.slice(0, 11));
  s = playRound(s, () => false, T0);
  const stats = finalStats(s);
  expect(stats.hardest).toHaveLength(11);
  expect(stats.hardest).toEqual(s.order.slice(0, 11).map((cardId) => ({ cardId, misses: 1 })));
  expect(stats.answered).toBe(11);
  expect(stats.accuracy).toBe(0);
  expect(stats.rounds).toBe(1);
  expect(stats.mastered).toBe(0);
});

// ---------- buildChoices ----------

test('buildChoices: exactly one correct option, no duplicates, 4 options', () => {
  const cards = makeCards(10);
  for (let seed = 1; seed <= 50; seed++) {
    const card = cards[seed % 10];
    const choices = buildChoices(cards, card, 'term', mulberry32(seed));
    expect(choices).toHaveLength(4);
    checkChoices({ cardId: card.id, ask: 'term', choices }, cards);
  }
});

test('buildChoices: ask definition uses the definitions', () => {
  const cards = makeCards(6);
  const choices = buildChoices(cards, cards[2], 'definition', mulberry32(3));
  expect(choices).toHaveLength(4);
  expect(choices.every((c) => c.text.startsWith('Begriff '))).toBe(true);
  expect(choices.filter((c) => c.cardId === 'c3')).toEqual([{ cardId: 'c3', text: 'Begriff 3' }]);
});

test('buildChoices: synonym cards (same prompt) are never offered', () => {
  const cards = [
    { id: 'laid', term: 'laid, laide', definition: 'hässlich' },
    { id: 'moche', term: 'moche', definition: 'hässlich' },
    { id: 'brave', term: 'brave', definition: 'lieb' },
    { id: 'gentil', term: 'gentil, gentille', definition: 'lieb, nett' },
    { id: 'calme', term: 'calme', definition: 'ruhig' },
    { id: 'sage', term: 'sage', definition: 'brav, artig' },
    { id: 'bete', term: 'bête', definition: 'dumm' },
  ];
  const byId = Object.fromEntries(cards.map((c) => [c.id, c]));
  const forbidden = { laid: 'moche', moche: 'laid', brave: 'gentil', gentil: 'brave' };
  for (let seed = 1; seed <= 200; seed++) {
    for (const id of Object.keys(forbidden)) {
      const ids = buildChoices(cards, byId[id], 'term', mulberry32(seed)).map((c) => c.cardId);
      expect(ids).toHaveLength(4);
      expect(ids).not.toContain(forbidden[id]);
    }
  }
  // Asking the definition: "hässlich" is the correct text of both, so it is offered once.
  for (let seed = 1; seed <= 50; seed++) {
    const choices = buildChoices(cards, byId.moche, 'definition', mulberry32(seed));
    expect(choices.filter((c) => textKey(c.text) === 'hässlich')).toEqual([{ cardId: 'moche', text: 'hässlich' }]);
  }
});

test('buildChoices: texts equal to the correct one after normalisation are excluded', () => {
  const cards = [
    { id: 'a', term: "l'homme", definition: 'der Mann' },
    { id: 'b', term: 'L’Homme', definition: 'Mensch' },
    { id: 'c', term: "  l'homme ", definition: 'Typ' },
    { id: 'd', term: "L'HOMME", definition: 'Kerl' },
    { id: 'e', term: 'la femme', definition: 'die Frau' },
    { id: 'f', term: 'le  garçon', definition: 'der Junge' },
  ];
  for (let seed = 1; seed <= 40; seed++) {
    const choices = buildChoices(cards, cards[0], 'term', mulberry32(seed));
    expect(sorted(choices.map((c) => c.cardId))).toEqual(['a', 'e', 'f']);
  }
});

test('buildChoices: empty texts and duplicate distractors are excluded', () => {
  const cards = [
    { id: 'a', term: 'le chien', definition: 'der Hund' },
    { id: 'b', term: 'le chat', definition: 'die Katze' },
    { id: 'c', term: 'Le Chat', definition: 'der Kater' },
    { id: 'd', term: '', definition: 'leer' },
    { id: 'e', term: '   ', definition: 'Leerzeichen' },
    { id: 'f', term: null, definition: 'null' },
  ];
  for (let seed = 1; seed <= 30; seed++) {
    const choices = buildChoices(cards, cards[0], 'term', mulberry32(seed));
    expect(choices).toHaveLength(2);
    expect(choices.filter((c) => c.cardId === 'a')).toHaveLength(1);
    expect(textKey(choices.find((c) => c.cardId !== 'a').text)).toBe('le chat');
  }
});

test('buildChoices: options that share an alternative with the answer are excluded', () => {
  const cards = [
    { id: 'a', term: 'laid, laide', definition: 'hässlich' },
    { id: 'b', term: 'laid', definition: 'unschön' },
    { id: 'c', term: 'laide, moche', definition: 'unansehnlich' },
    { id: 'd', term: 'joli, jolie', definition: 'hübsch' },
    { id: 'e', term: 'beau, belle', definition: 'schön' },
  ];
  for (let seed = 1; seed <= 30; seed++) {
    const ids = sorted(buildChoices(cards, cards[0], 'term', mulberry32(seed)).map((c) => c.cardId));
    expect(ids).toEqual(['a', 'd', 'e']);
  }
});

test('buildChoices: small sets give 1–4 options, n limits the count', () => {
  const sizes = [
    [1, 1],
    [2, 2],
    [3, 3],
    [4, 4],
    [5, 4],
    [30, 4],
  ];
  for (const [n, want] of sizes) {
    const cards = makeCards(n);
    expect(buildChoices(cards, cards[0], 'term', mulberry32(n))).toHaveLength(want);
  }
  const cards = makeCards(10);
  expect(buildChoices(cards, cards[0], 'term', mulberry32(1), 2)).toHaveLength(2);
  expect(buildChoices(cards, cards[0], 'term', mulberry32(1), 3)).toHaveLength(3);
  expect(buildChoices(cards, cards[0], 'term', mulberry32(1), 1)).toEqual([{ cardId: 'c1', text: 'terme 1' }]);
  expect(buildChoices(cards, cards[0], 'term', mulberry32(1), 0)).toHaveLength(4);
  expect(buildChoices(cards, cards[0], 'term', mulberry32(1), 'x')).toHaveLength(4);
});

test('buildChoices: the correct option position is uniform', () => {
  const cards = makeCards(10);
  const N = 4000;
  const hits = [0, 0, 0, 0];
  for (let seed = 1; seed <= N; seed++) {
    const choices = buildChoices(cards, cards[seed % 10], 'term', mulberry32(seed));
    hits[choices.findIndex((c) => c.cardId === cards[seed % 10].id)]++;
  }
  for (const h of hits) {
    expect(h).toBeGreaterThan(N * 0.22);
    expect(h).toBeLessThan(N * 0.28);
  }
  // Three options (3-card set): uniform over three slots.
  const three = makeCards(3);
  const h3 = [0, 0, 0];
  for (let seed = 1; seed <= 3000; seed++) {
    h3[buildChoices(three, three[0], 'term', mulberry32(seed)).findIndex((c) => c.cardId === 'c1')]++;
  }
  for (const h of h3) {
    expect(h).toBeGreaterThan(850);
    expect(h).toBeLessThan(1150);
  }
});

test('questions: the correct option position is uniform over many sessions', () => {
  const cards = makeCards(12);
  const hits = [0, 0, 0, 0];
  let total = 0;
  for (let seed = 1; seed <= 400; seed++) {
    const s = createLearn(cards, OPTS, { rng: mulberry32(seed), now: T0 });
    for (const q of s.queue) {
      hits[q.choices.findIndex((c) => c.cardId === q.cardId)]++;
      total++;
    }
  }
  for (const h of hits) {
    expect(h / total).toBeGreaterThan(0.22);
    expect(h / total).toBeLessThan(0.28);
  }
});

test('buildChoices: distractors vary with the rng and cover the pool', () => {
  const cards = makeCards(8);
  const seen = new Set();
  for (let seed = 1; seed <= 100; seed++) {
    for (const c of buildChoices(cards, cards[0], 'term', mulberry32(seed))) seen.add(c.cardId);
  }
  expect(sorted([...seen])).toEqual(sorted(cards.map((c) => c.id)));
  expect(snapshot(buildChoices(cards, cards[0], 'term', mulberry32(5)))).toBe(snapshot(buildChoices(cards, cards[0], 'term', mulberry32(5))));
});

// French–German cards of four word classes (wordclass.js).
const MIXED = [
  { id: 'corps', term: 'le corps', definition: 'der Körper' },
  { id: 'tete', term: 'la tête', definition: 'der Kopf' },
  { id: 'nez', term: 'le nez', definition: 'die Nase' },
  { id: 'bouche', term: 'la bouche', definition: 'der Mund' },
  { id: 'dent', term: 'la dent', definition: 'der Zahn' },
  { id: 'manger', term: 'manger', definition: 'essen' },
  { id: 'boire', term: 'boire', definition: 'trinken' },
  { id: 'dormir', term: 'dormir', definition: 'schlafen' },
  { id: 'lever', term: 'se lever', definition: 'aufstehen' },
  { id: 'lent', term: 'lent, lente', definition: 'langsam' },
  { id: 'rapide', term: 'rapide', definition: 'schnell' },
  { id: 'beau', term: 'beau, belle', definition: 'schön' },
  { id: 'gentil', term: 'gentil, gentille', definition: 'nett' },
  { id: 'noel', term: 'Joyeux Noël!', definition: 'Frohe Weihnachten!' },
  { id: 'merci', term: 'Merci beaucoup!', definition: 'Vielen Dank!' },
];
const MIXED_CLASS = {
  corps: 'noun', tete: 'noun', nez: 'noun', bouche: 'noun', dent: 'noun',
  manger: 'verb', boire: 'verb', dormir: 'verb', lever: 'verb',
  lent: 'adj', rapide: 'adj', beau: 'adj', gentil: 'adj',
  noel: 'phrase', merci: 'phrase',
};

test('buildChoices: wrong options are of the same word class while there are enough', () => {
  for (let seed = 1; seed <= 60; seed++) {
    for (const card of MIXED) {
      const ask = seed % 2 ? 'term' : 'definition';
      const choices = buildChoices(MIXED, card, ask, mulberry32(seed));
      expect(choices).toHaveLength(4);
      const others = choices.filter((c) => c.cardId !== card.id).map((c) => MIXED_CLASS[c.cardId]);
      const want = MIXED_CLASS[card.id];
      // Only two expressions: the other one, then cards of other classes.
      if (want === 'phrase') expect(others.filter((x) => x === 'phrase')).toHaveLength(1);
      else expect(others).toEqual([want, want, want]);
    }
  }
});

test('buildChoices: the most alike options come most often, but they take turns', () => {
  const cards = makeCards(40);
  const card = cards[19];
  const seen = {};
  let near = 0;
  let total = 0;
  for (let seed = 1; seed <= 300; seed++) {
    for (const c of buildChoices(cards, card, 'term', mulberry32(seed))) {
      if (c.cardId === card.id) continue;
      seen[c.cardId] = (seen[c.cardId] || 0) + 1;
      const at = cards.findIndex((x) => x.id === c.cardId);
      if (Math.abs(at - 19) <= 3) near++;
      total++;
    }
  }
  // Mostly the neighbours in the set (6 of 39 cards), yet more than three different options.
  expect(near / total).toBeGreaterThan(0.6);
  expect(Object.keys(seen).length).toBeGreaterThan(6);
  // The options of one question stay in random order: the closest is not always first.
  const firsts = new Set();
  for (let seed = 1; seed <= 40; seed++) firsts.add(buildChoices(cards, card, 'term', mulberry32(seed)).find((c) => c.cardId !== card.id).cardId);
  expect(firsts.size).toBeGreaterThan(3);
});

test('buildChoices: odd input never throws', () => {
  const cards = makeCards(4);
  expect(buildChoices(null, cards[0], 'term', mulberry32(1))).toEqual([{ cardId: 'c1', text: 'terme 1' }]);
  expect(buildChoices(cards, null, 'term', mulberry32(1))).toEqual([]);
  expect(buildChoices(cards, { id: 'x', term: '', definition: 'y' }, 'term', mulberry32(1))).toEqual([]);
  expect(buildChoices(cards, cards[0], 'term', () => 1)).toHaveLength(4);
  expect(buildChoices(cards, cards[0], 'term', () => NaN)).toHaveLength(4);
  expect(buildChoices(cards, cards[0], 'bogus', mulberry32(1)).every((c) => c.text.startsWith('terme'))).toBe(true);
  expect(buildChoices([...cards, null, 'x', { term: 'no id' }], cards[0], 'term', mulberry32(1))).toHaveLength(4);
});

// ---------- question types & flags ----------

test('a 1-card set is written-only and asked again right away', () => {
  const cards = [{ id: 'solo', term: 'le soleil', definition: 'die Sonne' }];
  let s = createLearn(cards, OPTS, { rng: mulberry32(1), now: T0 });
  expect(current(s)).toEqual({ qid: '1.1:solo', cardId: 'solo', type: 'written', ask: 'term' });
  expect(s.queue.map((q) => q.qid)).toEqual(['1.1:solo', '1.1.2:solo']);
  expect(s.queue.every((q) => q.retryChoices === undefined)).toBe(true);
  s = answer(s, false, T0 + SEC);
  expect(current(s)).toEqual({ qid: '1.1.2:solo', cardId: 'solo', type: 'written', ask: 'term' });
  s = answer(s, true, T0 + 2 * SEC);
  expect(s.stage.solo).toBe(1);
  s = nextRound(s, cards, mulberry32(2), T0 + 3 * SEC);
  expect(current(s)).toEqual({ qid: '2.1:solo', cardId: 'solo', type: 'written', ask: 'term' });
  expect(s.queue).toHaveLength(1);
});

test('multiple choice falls back to written without a valid distractor', () => {
  // Synonyms: both cards show "hässlich", so neither answer can be a distractor for the other.
  const syn = [
    { id: 'a', term: 'laid', definition: 'hässlich' },
    { id: 'b', term: 'moche', definition: 'hässlich' },
  ];
  const s = createLearn(syn, OPTS, { rng: mulberry32(1), now: T0 });
  expect(s.queue.map((q) => q.type)).toEqual(['written', 'written', 'written', 'written']);
  // Same answer text on both cards (distinct prompts): fewer than 2 distinct answers.
  const same = [
    { id: 'a', term: 'le visage', definition: 'das Gesicht' },
    { id: 'b', term: 'la figure', definition: 'das Gesicht' },
  ];
  expect(createLearn(same, { answerWith: 'definition' }, { rng: mulberry32(1), now: T0 }).queue.map((q) => q.type)).toEqual(['written', 'written', 'written', 'written']);
  // A third card with its own answer makes multiple choice possible again (2 options each).
  const three = [...same, { id: 'c', term: 'le nez', definition: 'die Nase' }];
  const s3 = createLearn(three, { answerWith: 'definition' }, { rng: mulberry32(1), now: T0 });
  expect(s3.queue.map((q) => q.type)).toEqual(['mc', 'mc', 'mc', 'written', 'written', 'written']);
  for (const q of s3.queue) {
    expect(q.retryChoices).toHaveLength(2);
    checkChoices({ ...q, choices: q.retryChoices }, three);
    if (q.type === 'mc') {
      expect(q.choices).toHaveLength(2);
      checkChoices(q, three);
    }
  }
});

test('options come from the whole set, not only from the scope', () => {
  const cards = makeCards(6).map((c) => ({ ...c, starred: c.id === 'c5' }));
  const s = createLearn(cards, OPTS, { subset: 'starred', rng: mulberry32(2), now: T0 });
  expect(s.order).toEqual(['c5']);
  expect(current(s).type).toBe('mc');
  expect(current(s).choices).toHaveLength(4);
  checkChoices(current(s), cards);
});

test('no question ever offers a synonym card (user word list)', () => {
  const pairs = [
    ['laid, laide', 'hässlich'],
    ['moche', 'hässlich'],
    ['le visage', 'das Gesicht'],
    ['la figure', 'das Gesicht'],
    ['brave', 'lieb'],
    ['gentil, gentille', 'lieb, nett'],
    ['la femme', 'die Frau'],
    ['la mademoiselle, mesdemoiselles', 'das Fräulein, die Frau'],
    ['calme', 'ruhig'],
    ['bête', 'dumm'],
  ];
  const cards = pairs.map(([term, definition], i) => ({ id: `w${i + 1}`, term, definition }));
  for (let seed = 1; seed <= 60; seed++) {
    const s = createLearn(cards, { answerWith: 'both', learn: { roundSize: 10 } }, { rng: mulberry32(seed), now: T0 });
    for (const q of s.queue) {
      const card = cards.find((c) => c.id === q.cardId);
      const syn = findSynonymCards(cards, card, q.ask).map((c) => c.id);
      for (const list of [q.choices || [], q.retryChoices || []]) {
        for (const c of list) expect(syn).not.toContain(c.cardId);
      }
      if (q.choices) checkChoices(q, cards);
    }
  }
});

test('flag mc only: stage 1 is asked as multiple choice, mastered after two correct', () => {
  const cards = makeCards(5);
  const opts = { answerWith: 'term', learn: { mc: true, written: false } };
  let s = createLearn(cards, opts, { progress: { c1: progressEntry(1) }, rng: mulberry32(3), now: T0 });
  expect(s.queue.every((q) => q.type === 'mc')).toBe(true);
  const id = current(s).cardId;
  s = playRound(s, () => true, T0);
  s = nextRound(s, cards, mulberry32(4), T0 + MIN);
  expect(s.queue.every((q) => q.type === 'mc' && q.choices.length === 4)).toBe(true);
  s = playRound(s, () => true, T0 + MIN);
  expect(s.stage[id]).toBe(2);
  expect(isFinished(s)).toBe(true);
  // A stage-1 card without valid distractors is still asked (written).
  const solo = createLearn([cards[0]], opts, { progress: { c1: progressEntry(1) }, rng: mulberry32(1), now: T0 });
  expect(current(solo).type).toBe('written');
});

test('flag written only: every question is written, also after a wrong answer', () => {
  const cards = makeCards(5);
  let s = createLearn(cards, { answerWith: 'term', learn: { mc: false, written: true } }, { rng: mulberry32(5), now: T0 });
  for (const q of s.queue) {
    expect(q.type).toBe('written');
    expect(q.choices).toBe(undefined);
    expect(q.retryChoices).toBe(undefined);
  }
  s = answer(s, false, T0 + SEC);
  expect(s.queue.every((q) => q.type === 'written')).toBe(true);
  s = playRound(s, () => true, T0 + SEC);
  s = nextRound(s, cards, mulberry32(6), T0 + MIN);
  expect(s.queue.every((q) => q.type === 'written')).toBe(true);
});

test('both flags (default): stage 0 multiple choice, stage 1 written', () => {
  const cards = makeCards(6);
  const progress = { c1: progressEntry(1), c2: progressEntry(1), c3: progressEntry(0, 0, 1) };
  const s = createLearn(cards, { answerWith: 'term', learn: { mc: true, written: true } }, { progress, rng: mulberry32(7), now: T0 });
  // The n-th question of a card in the round is planned at stage + n - 1.
  const nth = {};
  for (const q of s.queue) {
    nth[q.cardId] = (nth[q.cardId] || 0) + 1;
    expect(q.type).toBe(s.stage[q.cardId] + nth[q.cardId] - 1 === 1 ? 'written' : 'mc');
  }
});

test('answerWith definition: the definition is asked, options are definitions', () => {
  const cards = makeCards(6);
  const s = createLearn(cards, { answerWith: 'definition' }, { rng: mulberry32(8), now: T0 });
  expect(s.queue.filter((q) => q.type === 'mc')).toHaveLength(6);
  for (const q of s.queue) {
    expect(q.ask).toBe('definition');
    expect(q.retryChoices.every((c) => c.text.startsWith('Begriff '))).toBe(true);
    if (q.type !== 'mc') continue;
    expect(q.choices.every((c) => c.text.startsWith('Begriff '))).toBe(true);
    checkChoices(q, cards);
  }
});

test("answerWith 'both': ask is picked per question, options follow it", () => {
  const cards = makeCards(8);
  const asks = { term: 0, definition: 0 };
  let mixed = 0;
  for (let seed = 1; seed <= 40; seed++) {
    const s = createLearn(cards, { answerWith: 'both' }, { rng: mulberry32(seed), now: T0 });
    expect(s.answerWith).toBe('both');
    const local = new Set();
    for (const q of s.queue) {
      asks[q.ask]++;
      local.add(q.ask);
      checkChoices(q, cards);
      for (const c of q.retryChoices) expect(c.text).toBe(answerSide(cards.find((x) => x.id === c.cardId), q.ask));
    }
    if (local.size === 2) mixed++;
  }
  expect(asks.term).toBeGreaterThan(100);
  expect(asks.definition).toBeGreaterThan(100);
  expect(mixed).toBeGreaterThan(30);
  // A card's later question in the round has its own ask; after a wrong answer it is multiple
  // choice with options for that ask.
  const three = makeCards(3);
  let otherAsk = 0;
  for (let seed = 1; seed <= 20; seed++) {
    let s = createLearn(three, { answerWith: 'both' }, { rng: mulberry32(seed), now: T0 });
    const first = current(s);
    s = answer(s, false, T0 + SEC);
    const later = s.queue.find((q) => q.cardId === first.cardId);
    expect(later.qid).toBe(`1.1.2:${first.cardId}`);
    expect(later.type).toBe('mc');
    checkChoices(later, three);
    if (later.ask !== first.ask) otherAsk++;
  }
  expect(otherAsk).toBeGreaterThan(3);
});

// ---------- override ----------

test("override: a wrong multiple-choice answer becomes correct; the card's later question follows", () => {
  const cards = makeCards(5);
  let s = createLearn(cards, OPTS, { rng: mulberry32(3), now: T0 });
  const id = current(s).cardId;
  const planned = s.queue.find((q) => q.qid === `1.1.2:${id}`);
  expect(planned.type).toBe('written');
  s = answer(s, false, T0 + 10 * SEC);
  expect(s.queue).toHaveLength(6);
  // Wrong: its later question in this round turns multiple choice, with the options kept for it.
  expect(s.queue.find((q) => q.cardId === id)).toEqual({ ...planned, type: 'mc', choices: planned.retryChoices });
  const o = override(s, T0 + 15 * SEC);
  expect(o.stage[id]).toBe(1);
  expect(o.queue).toHaveLength(6);
  expect(o.queue.find((q) => q.cardId === id)).toEqual(planned);
  expect(o.answered).toBe(1);
  expect(o.correct).toBe(1);
  expect(o.misses[id]).toBe(0);
  expect(o.roundLog).toEqual([{ qid: `1.1:${id}`, cardId: id, type: 'mc', ask: 'term', correct: true, stageAfter: 1 }]);
  expect(o.last).toEqual({ qid: `1.1:${id}`, cardId: id, type: 'mc', ask: 'term', correct: true, stageBefore: 0 });
  expect(o.updatedAt).toBe(T0 + 15 * SEC);
  // The spacing stays: the answer was given at the same place.
  expect(o.lastAt).toEqual(s.lastAt);
  expect(o.clock).toBe(1);
  expect(counts(o)).toEqual({ fresh: 4, learning: 1, mastered: 0, total: 5, progress: 0 });
  expect(checkpoint(o).correct).toBe(1);
});

test('override is idempotent', () => {
  const cards = makeCards(4);
  let s = createLearn(cards, OPTS, { rng: mulberry32(4), now: T0 });
  s = answer(s, false, T0 + SEC);
  const once = override(s, T0 + 2 * SEC);
  const twice = override(once, T0 + 3 * SEC);
  expect(snapshot(twice)).toBe(snapshot(once));
  expect(snapshot(override(twice, T0 + 4 * SEC))).toBe(snapshot(once));
});

test('override of a wrong written answer masters the card and can finish the session', () => {
  const cards = makeCards(3);
  const progress = { c1: progressEntry(2), c2: progressEntry(2), c3: progressEntry(1) };
  let s = createLearn(cards, OPTS, { progress, rng: mulberry32(5), now: T0 });
  expect(current(s)).toEqual({ qid: '1.1:c3', cardId: 'c3', type: 'written', ask: 'term' });
  expect(s.queue).toHaveLength(1);
  s = answer(s, false, T0 + 10 * SEC);
  expect(s.stage.c3).toBe(0);
  expect(isRoundOver(s)).toBe(true);
  expect(isFinished(s)).toBe(false);
  const o = override(s, T0 + 20 * SEC);
  expect(o.stage.c3).toBe(2);
  expect(o.queue).toEqual([]);
  expect(isFinished(o)).toBe(true);
  expect(o.finishedAt).toBe(T0 + 20 * SEC);
  expect(finalStats(o)).toEqual({ total: 3, mastered: 3, alreadyMastered: 2, rounds: 1, answered: 1, accuracy: 1, elapsedMs: 20 * SEC, hardest: [] });
});

test('override is a no-op without a wrong last answer and after nextRound', () => {
  const cards = makeCards(3);
  let s = createLearn(cards, OPTS, { rng: mulberry32(6), now: T0 });
  expect(snapshot(override(s, T0 + SEC))).toBe(snapshot(s)); // nothing answered
  s = answer(s, true, T0 + SEC);
  expect(snapshot(override(s, T0 + 2 * SEC))).toBe(snapshot(s)); // last was correct
  s = playRound(s, () => false, T0 + 2 * SEC);
  expect(s.last.correct).toBe(false);
  const n = nextRound(s, cards, mulberry32(7), T0 + MIN);
  expect(n.last).toBe(null);
  expect(snapshot(override(n, T0 + MIN + SEC))).toBe(snapshot(n));
});

test("override of a card's later answer corrects only that answer", () => {
  const cards = makeCards(3);
  let s = createLearn(cards, OPTS, { rng: mulberry32(8), now: T0 });
  const id = current(s).cardId;
  s = answer(s, false, T0 + SEC); // wrong
  s = answer(s, true, T0 + 2 * SEC);
  s = answer(s, true, T0 + 3 * SEC);
  expect(current(s)).toEqual({ ...current(s), qid: `1.1.2:${id}`, type: 'mc' });
  s = answer(s, false, T0 + 4 * SEC); // its second question, wrong again
  expect(s.misses[id]).toBe(2);
  const o = override(s, T0 + MIN);
  expect(o.stage[id]).toBe(1);
  expect(o.misses[id]).toBe(1);
  expect(o.roundLog.filter((e) => e.cardId === id).map((e) => [e.correct, e.stageAfter])).toEqual([
    [false, 0],
    [true, 1],
  ]);
  expect(checkpoint(o).items.find((it) => it.cardId === id)).toEqual({ cardId: id, stage: 1, results: [false, true] });
});

// ---------- removeCard ----------

test('removeCard mid-round removes the card everywhere', () => {
  const cards = makeCards(6);
  let s = createLearn(cards, OPTS, { rng: mulberry32(2), now: T0 });
  const [a, b] = s.queue.map((q) => q.cardId);
  expect(s.queue.map((q) => q.cardId)).toEqual([...s.order, a]);
  s = answer(s, false, T0 + 10 * SEC); // a wrong
  s = answer(s, true, T0 + 20 * SEC); // b correct
  const r = removeCard(s, a, T0 + 30 * SEC);
  expect(r.order).not.toContain(a);
  expect(r.order).toHaveLength(5);
  expect(r.stage[a]).toBe(undefined);
  expect(r.lastAt).toEqual({ [b]: 1 });
  expect(r.clock).toBe(2);
  expect(r.queue.some((q) => q.cardId === a)).toBe(false);
  expect(r.queue).toHaveLength(4);
  for (const q of r.queue) {
    expect(q.choices.map((c) => c.cardId)).not.toContain(a);
    expect((q.retryChoices || []).map((c) => c.cardId)).not.toContain(a);
  }
  expect(r.misses[a]).toBe(undefined);
  expect(r.roundLog.map((e) => e.cardId)).toEqual([b]);
  expect(r.answered).toBe(1);
  expect(r.correct).toBe(1);
  expect(r.last.cardId).toBe(b);
  expect(counts(r).total).toBe(5);
  expect(checkpoint(r).items.map((it) => it.cardId)).toEqual([b]);
  // Removing the last answered card clears `last`.
  expect(removeCard(r, b, T0 + 40 * SEC).last).toBe(null);
  // Unknown card: nothing changes.
  expect(snapshot(removeCard(s, 'nope', T0 + MIN))).toBe(snapshot(s));
});

test('removeCard of the current question moves on to the next one', () => {
  const cards = makeCards(4);
  let s = createLearn(cards, OPTS, { rng: mulberry32(3), now: T0 });
  const [, second, third] = s.queue.map((q) => q.cardId);
  s = answer(s, true, T0 + SEC);
  expect(current(s).cardId).toBe(second);
  const rest = s.queue.filter((q) => q.cardId !== second).map((q) => q.qid);
  s = removeCard(s, second, T0 + 2 * SEC);
  expect(current(s).cardId).toBe(third);
  expect(s.queue.map((q) => q.qid)).toEqual(rest);
});

test('removeCard drops its option from other questions (mc becomes written below two)', () => {
  const cards = makeCards(3);
  let s = createLearn(cards, OPTS, { rng: mulberry32(4), now: T0 });
  const [x, y, z] = s.order;
  expect(s.queue.map((q) => q.cardId)).toEqual([x, y, z, x, y, z]);
  for (const q of s.queue) {
    expect(q.retryChoices).toHaveLength(3);
    if (q.type === 'mc') expect(q.choices).toHaveLength(3);
  }
  s = removeCard(s, x, T0 + SEC);
  expect(s.queue.map((q) => q.cardId)).toEqual([y, z, y, z]);
  expect(s.queue.map((q) => q.type)).toEqual(['mc', 'mc', 'written', 'written']);
  for (const q of s.queue) {
    expect(q.retryChoices).toHaveLength(2);
    if (q.type === 'mc') expect(q.choices).toHaveLength(2);
  }
  s = removeCard(s, y, T0 + 2 * SEC);
  expect(s.queue.map((q) => q.qid)).toEqual([`1.1:${z}`, `1.1.2:${z}`]);
  expect(current(s)).toEqual({ qid: `1.1:${z}`, cardId: z, type: 'written', ask: 'term' });
  expect(s.queue.every((q) => q.retryChoices === undefined)).toBe(true);
  s = answer(s, false, T0 + 3 * SEC);
  expect(current(s).type).toBe('written');
});

test('removeCard of the last open card finishes the session', () => {
  const cards = makeCards(3);
  const progress = { c1: progressEntry(2), c2: progressEntry(2) };
  let s = createLearn(cards, OPTS, { progress, rng: mulberry32(5), now: T0 });
  expect(s.queue.map((q) => q.qid)).toEqual(['1.1:c3', '1.1.2:c3']);
  s = removeCard(s, 'c3', T0 + 5 * SEC);
  expect(isFinished(s)).toBe(true);
  expect(s.finishedAt).toBe(T0 + 5 * SEC);
  expect(s.round).toBe(1);
  expect(counts(s)).toEqual({ fresh: 0, learning: 0, mastered: 2, total: 2, progress: 1 });

  // A round that lost every card before any answer: the session ends with the last closed round.
  const two = makeCards(2);
  let t = createLearn(two, { answerWith: 'term', learn: { roundSize: 1 } }, { progress: { c1: progressEntry(1) }, rng: mulberry32(6), now: T0 });
  expect(t.queue.map((q) => q.cardId)).toEqual(['c1']);
  t = answer(t, true, T0 + SEC);
  t = nextRound(t, two, mulberry32(7), T0 + 2 * SEC);
  expect(t.round).toBe(2);
  expect(t.queue.map((q) => q.cardId)).toEqual(['c2']);
  t = removeCard(t, 'c2', T0 + 3 * SEC);
  expect(isFinished(t)).toBe(true);
  expect(t.round).toBe(1);
  expect(finalStats(t).rounds).toBe(1);
  expect(checkpoint(t).round).toBe(1);
});

test('nextRound drops scope cards that are missing from cards', () => {
  const cards = makeCards(4);
  let s = createLearn(cards, { answerWith: 'term', learn: { roundSize: 4 } }, { rng: mulberry32(9), now: T0 });
  s = playRound(s, () => true, T0);
  const gone = s.order[0];
  const left = cards.filter((c) => c.id !== gone);
  s = nextRound(s, left, mulberry32(10), T0 + MIN);
  expect(s.order).not.toContain(gone);
  expect(s.lastAt[gone]).toBe(undefined);
  expect(s.queue.map((q) => q.cardId)).toEqual(s.order);
  for (const q of s.queue) expect(q.type).toBe('written');
  expect(s.rounds[0].cardIds).not.toContain(gone);
  expect(counts(s).total).toBe(3);
});

// ---------- time ----------

test('tick accumulates active time and ignores gaps longer than 5 minutes', () => {
  let s = createLearn(makeCards(2), OPTS, { rng: mulberry32(1), now: T0 });
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
  expect(tick(s, NaN).elapsedMs).toBe(s.elapsedMs);
});

test('answers advance the clock and it stops once finished', () => {
  const cards = [{ id: 'solo', term: 'le soleil', definition: 'die Sonne' }];
  let s = createLearn(cards, { answerWith: 'term', learn: { roundSize: 1 } }, { rng: mulberry32(1), now: T0 });
  s = answer(s, true, T0 + 12 * SEC);
  expect(s.elapsedMs).toBe(12 * SEC);
  expect(s.updatedAt).toBe(T0 + 12 * SEC);
  s = nextRound(s, cards, mulberry32(2), T0 + 20 * SEC);
  expect(s.elapsedMs).toBe(20 * SEC);
  s = answer(s, true, T0 + 30 * SEC);
  expect(isFinished(s)).toBe(true);
  expect(s.elapsedMs).toBe(30 * SEC);
  const later = tick(s, T0 + 60 * SEC);
  expect(later.elapsedMs).toBe(30 * SEC);
  expect(finalStats(later).elapsedMs).toBe(30 * SEC);
});

// ---------- serialisation & immutability ----------

test('state survives a JSON round-trip and continues identically', () => {
  const cards = makeCards(12);
  let s = createLearn(cards, { answerWith: 'both', learn: { roundSize: 5 } }, { rng: mulberry32(11), now: T0 });
  const decide = mulberry32(99);
  const outcomes = Array.from({ length: 300 }, () => decide() < 0.6);
  let k = 0;
  let t = T0;
  const step = (state) => {
    t += 7 * SEC;
    if (isRoundOver(state)) return nextRound(state, cards, mulberry32(t), t);
    const next = answer(state, outcomes[k++ % outcomes.length], t);
    return k % 9 === 0 ? override(next, t) : next;
  };
  for (let i = 0; i < 17; i++) s = step(s);
  const restored = JSON.parse(JSON.stringify(s));
  expect(restored).toEqual(s);

  const tStart = t;
  const kStart = k;
  let a = s;
  let guard = 0;
  while (!isFinished(a) && guard++ < 1000) a = step(a);
  t = tStart;
  k = kStart;
  let b = restored;
  guard = 0;
  while (!isFinished(b) && guard++ < 1000) b = step(b);
  expect(isFinished(a)).toBe(true);
  expect(snapshot(b)).toBe(snapshot(a));
  expect(finalStats(b)).toEqual(finalStats(a));
});

test('a resumed session shows the same question and options', () => {
  const cards = makeCards(9);
  let s = createLearn(cards, OPTS, { rng: mulberry32(21), now: T0 });
  s = answer(s, false, T0 + SEC);
  s = answer(s, true, T0 + 2 * SEC);
  const resumed = JSON.parse(JSON.stringify(s));
  expect(current(resumed)).toEqual(current(s));
  expect(resumed.queue).toEqual(s.queue);
  // Including the multiple-choice retry built from a stored option list.
  let x = s;
  let y = resumed;
  while (!isRoundOver(x)) {
    expect(current(y)).toEqual(current(x));
    x = answer(x, true, T0 + MIN);
    y = answer(y, true, T0 + MIN);
  }
  expect(snapshot(y)).toBe(snapshot(x));
});

test('functions never mutate their input state', () => {
  const cards = deepFreeze(makeCards(6));
  let s = createLearn(cards, deepFreeze({ answerWith: 'both', learn: { roundSize: 4 } }), { progress: deepFreeze({ c1: progressEntry(1) }), rng: mulberry32(3), now: T0 });
  s = answer(s, false, T0 + SEC);
  s = answer(s, true, T0 + 2 * SEC);
  const frozen = deepFreeze(JSON.parse(JSON.stringify(s)));
  const before = snapshot(frozen);
  const results = [
    answer(frozen, true, T0 + MIN),
    answer(frozen, false, T0 + MIN),
    override(frozen, T0 + MIN),
    removeCard(frozen, frozen.queue[0].cardId, T0 + MIN),
    tick(frozen, T0 + MIN),
    nextRound(frozen, cards, mulberry32(1), T0 + MIN),
  ];
  current(frozen);
  counts(frozen);
  checkpoint(frozen);
  finalStats(frozen);
  isRoundOver(frozen);
  isFinished(frozen);
  buildChoices(cards, cards[0], 'term', mulberry32(1));
  expect(snapshot(frozen)).toBe(before);
  for (const r of results) expect(r).not.toBe(frozen);

  // Finish the round, then nextRound on a frozen state too.
  let e = frozen;
  while (!isRoundOver(e)) e = answer(e, false, T0 + 2 * MIN);
  const endFrozen = deepFreeze(JSON.parse(JSON.stringify(e)));
  const endBefore = snapshot(endFrozen);
  const n = nextRound(endFrozen, cards, mulberry32(5), T0 + 3 * MIN);
  expect(n.round).toBe(2);
  expect(snapshot(endFrozen)).toBe(endBefore);
  // Mutating a returned question does not leak into the state.
  const q = current(n);
  q.cardId = 'changed';
  if (q.choices) q.choices[0].text = 'changed';
  expect(current(n).cardId).not.toBe('changed');
  if (current(n).choices) expect(current(n).choices[0].text).not.toBe('changed');
});

test('defensive: a corrupt or partial state does not crash the engine', () => {
  expect(current(null)).toBe(null);
  expect(isFinished(undefined)).toBe(true);
  expect(isRoundOver('junk')).toBe(true);
  expect(checkpoint(42).items).toEqual([]);
  expect(finalStats({}).total).toBe(0);
  const partial = {
    order: ['a', 'b', 'a'],
    stage: { a: 1, b: 7 },
    active: ['a', 'ghost'],
    queue: [{ cardId: 'a', type: 'mc', choices: [{ cardId: 'a', text: 'x' }] }, { cardId: 'ghost', type: 'mc' }, 'junk'],
    misses: { a: -3, ghost: 2 },
  };
  expect(current(partial)).toEqual({ qid: '1.q0:a', cardId: 'a', type: 'written', ask: 'term' });
  const s = answer(partial, true, T0);
  expect(s.order).toEqual(['a', 'b']);
  expect(s.stage).toEqual({ a: 2, b: 2 });
  expect(s.misses).toEqual({ a: 0 });
  expect(isFinished(s)).toBe(true);
  expect(s.finishedAt).toBe(T0);
  expect('active' in s).toBe(false);
  expect([s.clock, s.lastAt, s.repeats]).toEqual([1, { a: 0 }, 0]);
  // An open card that fell out of the queue is planned again by nextRound.
  const stuck = { order: ['a'], stage: { a: 0 }, active: [], queue: [], round: 1 };
  expect(isRoundOver(stuck)).toBe(true);
  const refilled = nextRound(stuck, [{ id: 'a', term: 'oui', definition: 'ja' }], mulberry32(1), T0);
  expect(refilled.round).toBe(1);
  expect(refilled.rounds).toEqual([]);
  expect(refilled.queue.map((q) => q.qid)).toEqual(['1.1:a', '1.1.2:a']);
  expect(current(refilled)).toEqual({ qid: '1.1:a', cardId: 'a', type: 'written', ask: 'term' });
  // Junk spacing fields are repaired: the answer count stands in for the clock, bad entries go.
  for (const clock of [-3, 'x', 2.5, null, NaN]) expect(tick({ order: ['a'], answered: 4, clock }, NaN).clock).toBe(4);
  expect(tick({ order: ['a'], answered: 4.7 }, NaN).clock).toBe(4);
  expect(tick({ order: ['a'], answered: 4, clock: 9 }, NaN).clock).toBe(9);
  const junk = tick({ order: ['a', 'b', 'c', 'd'], lastAt: { a: 3, b: -1, c: 'x', d: 1.5, ghost: 2 }, repeats: -2 }, NaN);
  expect(junk.lastAt).toEqual({ a: 3 });
  expect(junk.repeats).toBe(0);
  for (const lastAt of [null, 'x', [3], 5]) expect(tick({ order: ['a'], lastAt }, NaN).lastAt).toEqual({});
  for (const repeats of [1.5, 'x', null]) expect(tick({ order: ['a'], repeats }, NaN).repeats).toBe(0);
  expect(tick({ order: ['a'], repeats: 4 }, NaN).repeats).toBe(4);
});

// ---------- removed options are refilled ----------

test('removeCard with the set cards refills a lost option in place', () => {
  const cards = makeCards(10);
  const s = createLearn(cards, OPTS, { rng: mulberry32(21), now: T0 });
  expect(s.queue.every((q) => q.type === 'mc' && q.choices.length === 4 && q.retryChoices.length === 4)).toBe(true);
  const head = s.queue[0];
  const slot = head.choices.findIndex((c) => c.cardId !== head.cardId);
  const gone = head.choices[slot].cardId;
  const left = cards.filter((c) => c.id !== gone);
  const r = removeCard(s, gone, T0 + SEC, { cards: left, rng: mulberry32(22) });
  const q = r.queue.find((x) => x.qid === head.qid);
  expect(q.choices).toHaveLength(4);
  // The other options keep their places; the lost slot holds another valid option.
  q.choices.forEach((c, i) => {
    if (i !== slot) expect(c).toEqual(head.choices[i]);
  });
  expect(q.choices[slot].cardId).not.toBe(gone);
  checkChoices(q, left);
  for (const x of r.queue) {
    expect(x.choices).toHaveLength(4);
    expect(x.retryChoices).toHaveLength(4);
    expect(x.choices.map((c) => c.cardId)).not.toContain(gone);
    expect(x.retryChoices.map((c) => c.cardId)).not.toContain(gone);
    checkChoices(x, left);
    checkChoices({ ...x, choices: x.retryChoices }, left);
  }
  // Without the cards the option is only dropped (as before).
  expect(removeCard(s, gone, T0 + SEC).queue.find((x) => x.qid === head.qid).choices).toHaveLength(3);
});

test('removeCard refill: never the removed or an emptied card, never a duplicate; none left → fewer options', () => {
  const cards = makeCards(5);
  const s = createLearn(cards, OPTS, { rng: mulberry32(23), now: T0 });
  // The card is still in the set but its definition was emptied: it cannot be an option either.
  const q0 = s.queue[0];
  const gone = q0.choices.find((c) => c.cardId !== q0.cardId).cardId;
  const emptied = cards.map((c) => (c.id === gone ? { ...c, definition: ' ' } : c));
  for (let seed = 1; seed <= 20; seed++) {
    const r = removeCard(s, gone, T0 + SEC, { cards: emptied, rng: mulberry32(seed) });
    expect(r.queue.length).toBeGreaterThan(0);
    for (const q of r.queue) {
      for (const list of [q.choices, q.retryChoices].filter(Boolean)) {
        const ids = list.map((c) => c.cardId);
        expect(ids).not.toContain(gone);
        expect(new Set(ids).size).toBe(ids.length);
        // Five cards minus the removed one leave exactly four possible options.
        expect(ids).toHaveLength(4);
        expect(sorted(ids)).toEqual(sorted(cards.filter((c) => c.id !== gone).map((c) => c.id)));
      }
    }
  }
  // Four cards: every option is in use, so removing one leaves three.
  const four = makeCards(4);
  const t = createLearn(four, OPTS, { rng: mulberry32(24), now: T0 });
  const out = t.queue[0].choices.find((c) => c.cardId !== t.queue[0].cardId).cardId;
  const r = removeCard(t, out, T0 + SEC, { cards: four.filter((c) => c.id !== out), rng: mulberry32(25) });
  expect(r.queue.every((q) => q.retryChoices.length === 3 && (q.type !== 'mc' || q.choices.length === 3))).toBe(true);
});

test('removeCard refill skips synonyms and texts equal to a remaining option', () => {
  const cards = [
    { id: 'a', term: 'le nom', definition: 'der Name' },
    { id: 'b', term: 'le prénom', definition: 'der Vorname' },
    { id: 'c', term: 'le nom de famille', definition: 'der Nachname' },
    { id: 'd', term: 'la rue', definition: 'die Strasse' },
    { id: 'e', term: 'le nom', definition: 'der Name' }, // duplicate text of a
    { id: 'f', term: 'le patronyme', definition: 'der Nachname' }, // synonym of c (same prompt)
    { id: 'g', term: 'la ville', definition: 'die Stadt' },
  ];
  for (let seed = 1; seed <= 30; seed++) {
    const s = createLearn(cards, OPTS, { subset: { cardIds: ['c'] }, rng: mulberry32(seed), now: T0 });
    const q = s.queue[0];
    const slot = q.choices.findIndex((x) => x.cardId !== 'c');
    const gone = q.choices[slot].cardId;
    const left = cards.filter((x) => x.id !== gone);
    const r = removeCard({ ...s, order: [...s.order, gone], stage: { ...s.stage, [gone]: 0 } }, gone, T0 + SEC, { cards: left, rng: mulberry32(seed + 100) });
    const ids = r.queue[0].choices.map((x) => x.cardId);
    expect(ids).not.toContain('f');
    const texts = r.queue[0].choices.map((x) => textKey(x.text));
    expect(new Set(texts).size).toBe(texts.length);
  }
});

// ---------- shared progress (Write mode, other tabs) ----------

// What db.recordAnswer stores for a sequence of answers.
function recorded(...results) {
  return results.reduce((p, ok) => applyAnswer(p, ok, T0), undefined);
}

test('matchesProgress / syncProgress: Learn follows answers given in Write mode', () => {
  const cards = makeCards(6);
  const progress = { c5: recorded(true), c6: recorded(true) }; // familiar → written
  let s = createLearn(cards, OPTS, { progress, rng: mulberry32(31), now: T0 });
  expect(matchesProgress(s, progress)).toBe(true);
  const ones = s.order.filter((id) => id === 'c5' || id === 'c6');
  const zeros = s.order.filter((id) => !ones.includes(id));
  expect(s.queue.map((q) => q.cardId)).toEqual([...ones, ...zeros, zeros[0]]);
  const first = current(s);
  s = answer(s, true, T0 + SEC);
  progress[first.cardId] = applyAnswer(progress[first.cardId], true, T0); // what Learn records itself
  expect(matchesProgress(s, progress)).toBe(true);
  expect(s.stage[first.cardId]).toBe(2);

  // Write: the card Learn just mastered is answered wrong → learned again (in a later round).
  progress[first.cardId] = applyAnswer(progress[first.cardId], false, T0);
  expect(matchesProgress(s, progress)).toBe(false);
  let r = syncProgress(s, progress, T0 + 2 * SEC);
  expect(r.stage[first.cardId]).toBe(0);
  expect(counts(r).mastered).toBe(0);
  expect(r.queue).toEqual(s.queue);

  // Write: a queued multiple choice card is answered right → its questions become written.
  const mcQ = r.queue.find((q) => q.type === 'mc');
  expect(mcQ.cardId).toBe(zeros[0]);
  progress[mcQ.cardId] = recorded(true);
  // Write: a queued written card (stage 1) is answered wrong → stage 0, but it stays written (it
  // was answered right before).
  const wQ = r.queue.find((q) => q.cardId === ones[1]);
  expect(wQ.type).toBe('written');
  progress[ones[1]] = applyAnswer(progress[ones[1]], false, T0);
  // Write: another queued card is mastered → it leaves the round.
  const done = r.queue.find((q) => q.type === 'mc' && q.cardId !== mcQ.cardId);
  progress[done.cardId] = recorded(true, true);
  r = syncProgress(r, progress, T0 + 3 * SEC);
  expect(matchesProgress(r, progress)).toBe(true);
  const nowMc = r.queue.find((q) => q.qid === mcQ.qid);
  expect(nowMc).toEqual({ qid: mcQ.qid, cardId: mcQ.cardId, type: 'written', ask: mcQ.ask, retryChoices: mcQ.retryChoices });
  expect(r.queue.filter((q) => q.cardId === mcQ.cardId).map((q) => q.type)).toEqual(['written', 'written']);
  const nowW = r.queue.find((q) => q.qid === wQ.qid);
  expect(r.stage[ones[1]]).toBe(0);
  expect(nowW).toEqual(wQ);
  expect(r.queue.some((q) => q.cardId === done.cardId)).toBe(false);
  expect(r.stage[done.cardId]).toBe(2);
  expect(counts(r).mastered).toBe(1);
  // Nothing else changed, and a second sync is a no-op.
  expect(r.answered).toBe(1);
  expect(r.roundLog).toEqual(s.roundLog);
  expect([r.clock, r.lastAt, r.repeats]).toEqual([s.clock, s.lastAt, s.repeats]);
  expect(snapshot(syncProgress(r, progress, T0 + 4 * SEC))).toBe(snapshot(r));

  // From here on Learn's own answers keep both in step.
  while (!isRoundOver(r)) {
    const q = current(r);
    r = answer(r, true, T0 + 5 * SEC);
    progress[q.cardId] = applyAnswer(progress[q.cardId], true, T0);
    expect(matchesProgress(r, progress)).toBe(true);
  }
});

test('syncProgress: a card mastered before the session but missed elsewhere is studied again', () => {
  const cards = makeCards(4);
  const progress = { c1: recorded(true, true) };
  let s = createLearn(cards, OPTS, { progress, rng: mulberry32(32), now: T0 });
  expect(s.initiallyMastered).toEqual(['c1']);
  expect(s.queue.some((q) => q.cardId === 'c1')).toBe(false);
  progress.c1 = applyAnswer(progress.c1, false, T0);
  s = syncProgress(s, progress, T0 + SEC);
  expect(s.stage.c1).toBe(0);
  expect(s.initiallyMastered).toEqual([]);
  expect(s.queue.some((q) => q.cardId === 'c1')).toBe(false); // not in this round
  expect(counts(s)).toEqual({ fresh: 3, learning: 1, mastered: 0, total: 4, progress: 0 });
  s = playRound(s, () => true, T0 + SEC);
  s = nextRound(s, cards, mulberry32(33), T0 + MIN);
  const q = s.queue.find((x) => x.cardId === 'c1');
  expect(q.type).toBe('written'); // answered right before: no multiple choice
  expect(finalStats(s).alreadyMastered).toBe(0);
});

test('syncProgress: everything mastered elsewhere finishes the session', () => {
  const cards = makeCards(3);
  let s = createLearn(cards, OPTS, { rng: mulberry32(34), now: T0 });
  s = answer(s, true, T0 + SEC);
  const all = Object.fromEntries(cards.map((c) => [c.id, recorded(true, true)]));
  const r = syncProgress(s, all, T0 + 2 * SEC);
  expect(isFinished(r)).toBe(true);
  expect(r.finishedAt).toBe(T0 + 2 * SEC);
  expect(r.queue).toEqual([]);
  expect(r.round).toBe(1);
  const closed = nextRound(r, cards, mulberry32(35), T0 + 3 * SEC);
  expect(closed.rounds).toHaveLength(1);
  expect(finalStats(closed).rounds).toBe(1);

  // At the start of a round (no answers in it yet) the session ends with the last closed round.
  let t = createLearn(cards, { answerWith: 'term', learn: { roundSize: 2 } }, { rng: mulberry32(36), now: T0 });
  t = playRound(t, () => true, T0);
  t = nextRound(t, cards, mulberry32(37), T0 + MIN);
  expect(t.round).toBe(2);
  t = syncProgress(t, all, T0 + 2 * MIN);
  expect(isFinished(t)).toBe(true);
  expect(t.round).toBe(1);
  expect(finalStats(t).rounds).toBe(1);

  // A finished session keeps its result, whatever the progress says later.
  expect(matchesProgress(closed, {})).toBe(true);
  expect(snapshot(syncProgress(closed, {}, T0 + 4 * SEC))).toBe(snapshot(closed));
});

test('syncProgress: a reset elsewhere makes the cards new again; overrides stay in step', () => {
  const cards = makeCards(4);
  const progress = {};
  let s = createLearn(cards, OPTS, { rng: mulberry32(38), now: T0 });
  const q = current(s);
  s = answer(s, false, T0 + SEC);
  progress[q.cardId] = recorded(false);
  expect(matchesProgress(s, progress)).toBe(true);
  // "Ich hatte recht" in Learn = override in both.
  s = override(s, T0 + 2 * SEC);
  progress[q.cardId] = applyOverride(progress[q.cardId]);
  expect(matchesProgress(s, progress)).toBe(true);
  expect(s.queue.filter((x) => x.cardId === q.cardId).map((x) => x.type)).toEqual(['written']);
  // The progress is reset in another tab: its questions are multiple choice again.
  const r = syncProgress(s, {}, T0 + 3 * SEC);
  expect(counts(r)).toEqual({ fresh: 4, learning: 0, mastered: 0, total: 4, progress: 0 });
  expect(r.queue.filter((x) => x.cardId === q.cardId).map((x) => x.type)).toEqual(['mc']);
  expect(r.queue.filter((x) => QID.exec(x.qid)[3] === undefined).every((x) => x.type === 'mc')).toBe(true);
  expect(matchesProgress(r, null)).toBe(true);
});

test('syncProgress follows the question type flags and never mutates its input', () => {
  const cards = deepFreeze(makeCards(4));
  const writtenOnly = { answerWith: 'term', learn: { mc: false, written: true } };
  let s = createLearn(cards, writtenOnly, { rng: mulberry32(39), now: T0 });
  const id = current(s).cardId;
  s = syncProgress(s, { [id]: recorded(true) }, T0 + SEC);
  expect(s.queue.every((q) => q.type === 'written' && q.choices === undefined)).toBe(true);
  const mcOnly = { answerWith: 'term', learn: { mc: true, written: false } };
  let m = createLearn(cards, mcOnly, { rng: mulberry32(40), now: T0 });
  m = syncProgress(m, { [current(m).cardId]: recorded(true) }, T0 + SEC);
  expect(m.queue.every((q) => q.type === 'mc')).toBe(true);

  const frozen = deepFreeze(JSON.parse(JSON.stringify(createLearn(cards, OPTS, { rng: mulberry32(41), now: T0 }))));
  const before = snapshot(frozen);
  const progress = deepFreeze({ c1: recorded(true), c2: recorded(true, true), c3: recorded(false) });
  syncProgress(frozen, progress, T0 + SEC);
  matchesProgress(frozen, progress);
  removeCard(frozen, frozen.queue[0].cardId, T0 + SEC, { cards, rng: mulberry32(1) });
  expect(snapshot(frozen)).toBe(before);
  // Junk input never throws.
  expect(matchesProgress(null, null)).toBe(true);
  expect(syncProgress('junk', 'junk', T0).order).toEqual([]);
});

// ---------- repetition questions (Wiederholungsfragen) ----------
// Ported from the Mac app's LearnReviewTests: cards mastered before the session are asked once
// more, mixed into the rounds; a miss sends them back to "Am Lernen". Without the option every
// session stays exactly what it was (see the tests above).

// Mastered progress for `cards`, the first one answered longest ago.
function masteredProgress(cards) {
  const p = {};
  cards.forEach((c, i) => {
    p[c.id] = { correct: 2, incorrect: 0, streak: 2, streakBefore: 1, lastResult: 'correct', lastAnsweredAt: T0 - 100000 + i };
  });
  return p;
}

function createReview(cards, { progress = {}, roundSize = 7, review = true, seed = 3, learn = {} } = {}) {
  return createLearn(cards, { answerWith: 'term', learn: { roundSize, ...learn } }, { progress, rng: mulberry32(seed), now: T0, review });
}

// Answers the round's questions, one second apart; decide(question) says whether it is right.
function playAll(state, decide, start = T0) {
  let s = state;
  let t = start;
  let guard = 0;
  for (let q = current(s); q; q = current(s)) {
    if (guard++ > 200) throw new Error('round did not end');
    t += SEC;
    s = answer(s, decide(q), t);
  }
  return s;
}

const reviewIds = (s) => s.queue.filter((q) => isReviewQuestion(q.qid)).map((q) => q.cardId);

test('repetition questions are recognised by their id', () => {
  expect(isReviewQuestion('1.3:c1')).toBe(true);
  expect(isReviewQuestion('12.3:a:b')).toBe(true);
  expect(isReviewQuestion('2.3.2:c1')).toBe(true);
  for (const qid of ['1.1:c1', '1.2:c1', '1.4:c1', '1.1.2:c1', '.3:c1', 'x.3:c1', '1.q3:c1', '13', '1.33:c1', '1.3.:c1', '', null, undefined, 3]) {
    expect(isReviewQuestion(qid)).toBe(false);
  }
});

test('review: without the option nothing changes (no key, no repetition, no stats)', () => {
  const cards = makeCards(9);
  const progress = masteredProgress(cards.slice(0, 4));
  progress.c5 = { correct: 1, incorrect: 0, streak: 1, streakBefore: 0, lastResult: 'correct', lastAnsweredAt: T0 - 5 };
  const plain = createLearn(cards, { answerWith: 'term', learn: { roundSize: 7 } }, { progress, rng: mulberry32(3), now: T0 });
  const off = createReview(cards, { progress, review: false });
  expect(off).toEqual(plain);
  expect('review' in off).toBe(false);
  expect(reviewIds(off)).toEqual([]);
  expect(reviewStats(off)).toBe(null);
  expect(JSON.stringify(off).includes('"review"')).toBe(false);
  // Later steps never add it either.
  let s = playAll(off, () => true);
  s = nextRound(s, cards, mulberry32(4), T0 + MIN);
  expect('review' in s).toBe(false);
});

test('review: with nothing mastered the session is the plain one, rng draw for rng draw', () => {
  const cards = makeCards(8);
  const progress = { c2: progressEntry(1) };
  const plain = createLearn(cards, OPTS, { progress, rng: mulberry32(5), now: T0 });
  const on = createLearn(cards, OPTS, { progress, rng: mulberry32(5), now: T0, review: true });
  const { review, ...rest } = on;
  expect(rest).toEqual(plain);
  expect(review).toEqual({ due: [], results: {} });
  expect(reviewStats(on)).toEqual({ asked: 0, kept: 0, left: 0 });
});

test('review: everything mastered without the option is finished at once', () => {
  const cards = makeCards(5);
  const s = createReview(cards, { progress: masteredProgress(cards), review: false });
  expect(isFinished(s)).toBe(true);
  expect(s.queue).toEqual([]);
});

test('review: repetition questions come among the new cards, the most overdue first', () => {
  const cards = makeCards(10);
  const mastered = ['c1', 'c2', 'c3', 'c4', 'c5', 'c6'];
  const s = createReview(cards, { progress: masteredProgress(cards.slice(0, 6)) });
  const reviews = s.queue.filter((q) => isReviewQuestion(q.qid));
  expect(reviews.length).toBeGreaterThan(0);
  // c1 was answered longest ago: the most overdue come first, the rest wait in `due`.
  expect(reviews.map((q) => q.cardId)).toEqual(mastered.slice(0, reviews.length));
  expect(s.review.due).toEqual(mastered.slice(reviews.length));
  expect(s.queue).toHaveLength(7);
  // The other questions: the new cards in session order.
  const learn = s.queue.filter((q) => !isReviewQuestion(q.qid));
  const fresh = s.order.filter((id) => !mastered.includes(id));
  expect(learn.filter((q) => q.qid === `1.1:${q.cardId}`).map((q) => q.cardId)).toEqual(fresh.slice(0, learn.filter((q) => q.qid === `1.1:${q.cardId}`).length));
  // Mastered cards are asked written, with options ready in case they are learned again.
  for (const q of reviews) {
    expect(q.type).toBe('written');
    expect(Array.isArray(q.retryChoices)).toBe(true);
    expect(q.qid).toBe(`1.3:${q.cardId}`);
  }
  expect(isFinished(s)).toBe(false);
  expect(reviewStats(s)).toEqual({ asked: 0, kept: 0, left: 6 });
});

test('review: about every third new question is a repetition question while there are new cards too', () => {
  const cards = makeCards(40);
  const progress = masteredProgress(cards.slice(0, 20));
  let reviews = 0;
  let total = 0;
  for (let seed = 1; seed <= 60; seed++) {
    // The first round: 20 new and 20 mastered cards, nothing may come back yet.
    const s = createReview(cards, { progress, seed });
    for (const q of s.queue) {
      total++;
      if (isReviewQuestion(q.qid)) reviews++;
      else expect(q.qid).toBe(`1.1:${q.cardId}`);
    }
  }
  expect(reviews / total).toBeGreaterThan(0.25);
  expect(reviews / total).toBeLessThan(0.42);
});

test('review: a whole round of repetition when everything is mastered', () => {
  const cards = makeCards(10);
  const s = createReview(cards, { progress: masteredProgress(cards), roundSize: 7 });
  expect(isFinished(s)).toBe(false);
  expect(s.finishedAt).toBe(null);
  expect(s.queue).toHaveLength(7);
  expect(s.queue.every((q) => isReviewQuestion(q.qid))).toBe(true);
  expect(isReviewQuestion(current(s).qid)).toBe(true);
  expect(s.review.due).toHaveLength(3);
});

test('review: the session ends once every mastered card was asked again', () => {
  const cards = makeCards(10);
  let s = createReview(cards, { progress: masteredProgress(cards), roundSize: 7 });
  s = playAll(s, () => true);
  expect(isRoundOver(s)).toBe(true);
  expect(isFinished(s)).toBe(false);
  s = nextRound(s, cards, mulberry32(4), T0 + MIN);
  expect(s.round).toBe(2);
  expect(s.queue).toHaveLength(3);
  s = playAll(s, () => true, T0 + MIN);
  expect(isFinished(s)).toBe(true);
  expect(s.finishedAt).not.toBe(null);
  expect(reviewStats(s)).toEqual({ asked: 10, kept: 10, left: 0 });
  const stats = finalStats(s);
  expect(stats.mastered).toBe(10);
  expect(stats.alreadyMastered).toBe(10);
  // nextRound closes the last round once and keeps the result.
  const closed = nextRound(s, cards, mulberry32(5), T0 + 2 * MIN);
  expect(closed.rounds).toHaveLength(2);
  expect(closed.finishedAt).toBe(s.finishedAt);
});

test('review: a missed repetition question sends the card back to learning', () => {
  const cards = makeCards(6);
  const progress = masteredProgress(cards);
  let s = createReview(cards, { progress, roundSize: 5 });
  const first = current(s);
  expect(isReviewQuestion(first.qid)).toBe(true);
  s = answer(s, false, T0 + SEC);
  expect(s.stage[first.cardId]).toBe(0);
  expect(s.initiallyMastered).not.toContain(first.cardId);
  expect(s.review.results[first.cardId]).toBe(false);
  // No retry at the end of the round: it is learned again once it waited its gap.
  expect(s.queue.some((q) => q.cardId === first.cardId)).toBe(false);
  expect(counts(s).mastered).toBe(5);
  // What the store records for it: no longer mastered.
  const stored = applyAnswer(progress[first.cardId], false, T0 + SEC);
  expect(cardStatus(stored)).toBe('learning');
  expect(reviewStats(s)).toEqual({ asked: 1, kept: 0, left: 5 });
  const { s: end, log } = playSession(s, cards, () => true, { seed: 9 });
  const again = log.filter((e) => e.cardId === first.cardId);
  // Answered right before: written, no multiple choice.
  expect(again.map((e) => [kindOf(e.qid), e.type])).toEqual([
    [1, 'written'],
    [1, 'written'],
  ]);
  expect(again[0].wait).toBeGreaterThanOrEqual(Math.min(MIN_GAP, again[0].open - 1));
  expect(reviewStats(end)).toEqual({ asked: 6, kept: 5, left: 0 });
});

test('review: a missed card is learned again until it is mastered', () => {
  const cards = makeCards(4);
  let s = createReview(cards, { progress: masteredProgress(cards), roundSize: 7 });
  expect(s.queue.map((q) => q.qid)).toEqual(['1.3:c1', '1.3:c2', '1.3:c3', '1.3:c4']);
  const missed = current(s).cardId;
  let first = true;
  s = playAll(s, () => {
    const ok = !first;
    first = false;
    return ok;
  });
  expect(s.stage[missed]).toBe(0);
  expect(isFinished(s)).toBe(false);
  s = nextRound(s, cards, mulberry32(9), T0 + MIN);
  // The only open card: learned from the start, written twice (answered right before).
  expect(s.queue.map((q) => [q.qid, q.type])).toEqual([
    [`2.1:${missed}`, 'written'],
    [`2.1.2:${missed}`, 'written'],
  ]);
  s = playAll(s, () => true, T0 + MIN);
  expect(isFinished(s)).toBe(true);
  expect(finalStats(s).alreadyMastered).toBe(3);
  expect(reviewLine(reviewStats(s))).toBe('4 gemeisterte Begriffe wiederholt, 1 davon ist wieder am Lernen.');
});

test('review: "Ich hatte recht" keeps the card mastered', () => {
  const cards = makeCards(4);
  let s = createReview(cards, { progress: masteredProgress(cards), roundSize: 7 });
  const q = current(s);
  s = answer(s, false, T0 + SEC);
  s = override(s, T0 + 2 * SEC);
  expect(s.stage[q.cardId]).toBe(2);
  expect(s.initiallyMastered).toContain(q.cardId);
  expect(s.initiallyMastered).toEqual(s.order.filter((id) => s.initiallyMastered.includes(id)));
  expect(s.review.results[q.cardId]).toBe(true);
  expect(s.queue.some((x) => x.cardId === q.cardId)).toBe(false);
  // Idempotent.
  expect(snapshot(override(s, T0 + 3 * SEC))).toBe(snapshot(s));
});

test('review: only the first answer of a repetition question counts', () => {
  const cards = makeCards(3);
  let s = createReview(cards, { progress: masteredProgress(cards), roundSize: 7 });
  const q = current(s);
  s = answer(s, false, T0 + SEC);
  s = playAll(s, () => true, T0 + SEC);
  s = nextRound(s, cards, mulberry32(4), T0 + MIN);
  // Learned again with ordinary questions.
  expect(s.queue.map((x) => x.qid)).toEqual([`2.1:${q.cardId}`, `2.1.2:${q.cardId}`]);
  // Overriding a wrong answer to one of them leaves the result alone.
  let t = answer(s, false, T0 + MIN + SEC);
  t = override(t, T0 + MIN + 2 * SEC);
  expect(t.stage[q.cardId]).toBe(1);
  expect(t.review.results[q.cardId]).toBe(false);
  expect(t.initiallyMastered).not.toContain(q.cardId);
  // Right answers to them do not either.
  s = playAll(s, () => true, T0 + MIN);
  expect(isFinished(s)).toBe(true);
  expect(s.review.results[q.cardId]).toBe(false);
  expect(reviewStats(s)).toEqual({ asked: 3, kept: 2, left: 0 });
});

test('review: a deleted card leaves the repetition', () => {
  const cards = makeCards(10);
  let s = createReview(cards, { progress: masteredProgress(cards.slice(0, 6)) });
  s = removeCard(s, 'c3', T0 + SEC, { cards: cards.filter((c) => c.id !== 'c3') });
  expect(s.review.due).toEqual(['c4', 'c5', 'c6']);
  s = removeCard(s, 'c1', T0 + 2 * SEC);
  expect(s.queue.some((q) => q.cardId === 'c1')).toBe(false);
  expect(reviewStats(s).left).toBe(4);
  // A result goes with its card.
  let t = createReview(cards, { progress: masteredProgress(cards), roundSize: 5 });
  const q = current(t);
  t = answer(t, true, T0 + SEC);
  expect(t.review.results).toEqual({ [q.cardId]: true });
  t = removeCard(t, q.cardId, T0 + 2 * SEC);
  expect(t.review.results).toEqual({});
});

test('review: a card missed elsewhere is learned instead of repeated', () => {
  const cards = makeCards(8);
  const progress = masteredProgress(cards.slice(0, 6));
  let s = createReview(cards, { progress });
  // c5 is answered wrong in Schreiben: no longer mastered.
  progress.c5 = applyAnswer(progress.c5, false, T0 + 500);
  s = syncProgress(s, progress, T0 + 600);
  expect(s.review.due).not.toContain('c5');
  expect(s.queue.some((q) => q.cardId === 'c5' && isReviewQuestion(q.qid))).toBe(false);
  const { s: end, log } = playSession(s, cards, () => true, { seed: 5 });
  const c5 = log.filter((e) => e.cardId === 'c5');
  expect(c5.map((e) => [kindOf(e.qid), e.type])).toEqual([
    [1, 'written'],
    [1, 'written'],
  ]);
  expect('c5' in end.review.results).toBe(false);
  expect(reviewStats(end)).toEqual({ asked: 5, kept: 5, left: 0 });
});

test('review: a queued repetition question of a card missed elsewhere becomes an ordinary question', () => {
  const cards = makeCards(8);
  const progress = masteredProgress(cards.slice(0, 6));
  let s = createReview(cards, { progress });
  const queued = reviewIds(s);
  expect(queued.length).toBeGreaterThan(1);
  const [id] = queued;
  const qid = s.queue.find((q) => q.cardId === id).qid;
  progress[id] = applyAnswer(progress[id], false, T0 + 500);
  s = syncProgress(s, progress, T0 + 600);
  const q = s.queue.find((x) => x.cardId === id);
  // Same place in the round, no longer a repetition; still written (answered right before).
  expect(q.qid).toBe(qid.replace('.3:', '.1:'));
  expect(q.type).toBe('written');
  expect(q.choices).toBe(undefined);
  expect(s.initiallyMastered).not.toContain(id);
  expect(reviewStats(s).left).toBe(5);
  s = playAll(s, () => true, T0 + 600);
  expect(id in s.review.results).toBe(false);
  const n = queued.length - 1;
  expect(reviewStats(s)).toEqual({ asked: n, kept: n, left: 5 - n });
});

test('review: resuming and reconciling keep the repetition questions and the missed card', () => {
  const cards = makeCards(8);
  const progress = masteredProgress(cards.slice(0, 5));
  let s = createReview(cards, { progress });
  // Answer the round as Learn does: the store records every answer.
  let t = T0;
  let missed = null;
  while (!isRoundOver(s)) {
    const q = current(s);
    const ok = !(isReviewQuestion(q.qid) && missed == null);
    if (!ok) missed = q.cardId;
    t += SEC;
    s = answer(s, ok, t);
    progress[q.cardId] = applyAnswer(progress[q.cardId], ok, t);
    expect(matchesProgress(s, progress)).toBe(true);
  }
  expect(s.review.results[missed]).toBe(false);
  expect(s.stage[missed]).toBe(0); // it comes back after the gap, not in this round
  const asked = reviewStats(s).asked;
  // A reload: the stored JSON continues identically, nothing to reconcile.
  const stored = JSON.parse(JSON.stringify(s));
  expect(matchesProgress(stored, progress)).toBe(true);
  expect(snapshot(syncProgress(stored, progress, t + SEC))).toBe(snapshot(tick(stored, NaN)));
  const a = nextRound(s, cards, mulberry32(6), t + MIN);
  const b = nextRound(stored, cards, mulberry32(6), t + MIN);
  expect(snapshot(b)).toBe(snapshot(a));
  expect(b.order).toContain(missed);
  expect(b.queue.filter((q) => q.cardId === missed).every((q) => kindOf(q.qid) === 1)).toBe(true);
  expect(reviewStats(b)).toEqual({ asked, kept: asked - 1, left: 5 - asked });
});

test('review: the repetition survives storage; junk is dropped on repair', () => {
  const cards = makeCards(8);
  let s = createReview(cards, { progress: masteredProgress(cards.slice(0, 5)) });
  s = answer(s, true, T0 + SEC);
  const json = JSON.parse(JSON.stringify(s));
  expect(Array.isArray(json.review.due)).toBe(true);
  expect(json).toEqual(s);
  expect(tick(json, NaN)).toEqual(s);
  // Unknown cards and junk are dropped on repair.
  const repaired = tick({ ...json, review: { due: ['c4', 'zz', 7, 'c4'], results: { c1: true, zz: false, c2: 'x' } } }, NaN);
  expect(repaired.review).toEqual({ due: ['c4'], results: { c1: true } });
  const empty = tick({ ...json, review: {} }, NaN);
  expect(empty.review).toEqual({ due: [], results: {} });
  // Anything but an object means a session without repetition questions.
  for (const junk of [null, [], 'x', 3, true]) expect('review' in tick({ ...json, review: junk }, NaN)).toBe(false);
});

test('review: written off asks repetition questions as multiple choice; options come from the set', () => {
  const cards = makeCards(6);
  const s = createReview(cards, { progress: masteredProgress(cards), roundSize: 4, learn: { written: false } });
  expect(s.queue).toHaveLength(4);
  for (const q of s.queue) {
    expect(isReviewQuestion(q.qid)).toBe(true);
    expect(q.type).toBe('mc');
    checkChoices(q, cards);
  }
});

test('review: a session over chosen cards ("Falsche lernen") repeats the mastered ones among them', () => {
  const cards = makeCards(8);
  const progress = { ...masteredProgress(cards.slice(0, 4)), c6: progressEntry(1) };
  const s = createLearn(cards, OPTS, { subset: { cardIds: ['c2', 'c6', 'c7'] }, progress, rng: mulberry32(12), now: T0, review: true });
  expect(sorted(s.order)).toEqual(['c2', 'c6', 'c7']);
  expect(s.initiallyMastered).toEqual(['c2']);
  expect(reviewIds(s)).toEqual(['c2']);
  expect(sorted([...new Set(s.queue.filter((q) => !isReviewQuestion(q.qid)).map((q) => q.cardId))])).toEqual(['c6', 'c7']);
  // All mastered: still a session (the exam found them wrong), not the finished state.
  const all = createLearn(cards, OPTS, { subset: { cardIds: ['c1', 'c3'] }, progress, rng: mulberry32(12), now: T0, review: true });
  expect(isFinished(all)).toBe(false);
  expect(sorted(reviewIds(all))).toEqual(['c1', 'c3']);
});

test('review: functions never mutate a review state', () => {
  const cards = deepFreeze(makeCards(6));
  const progress = masteredProgress(cards.slice(0, 4));
  let s = createReview(cards, { progress, roundSize: 4 });
  s = answer(s, false, T0 + SEC);
  const frozen = deepFreeze(JSON.parse(JSON.stringify(s)));
  const before = snapshot(frozen);
  answer(frozen, true, T0 + 2 * SEC);
  override(frozen, T0 + 2 * SEC);
  reviewStats(frozen);
  syncProgress(frozen, deepFreeze({}), T0 + 2 * SEC);
  removeCard(frozen, frozen.order[0], T0 + 2 * SEC, { cards, rng: mulberry32(1) });
  nextRound(playAll(frozen, () => true, T0 + 2 * SEC), cards, mulberry32(2), T0 + MIN);
  expect(snapshot(frozen)).toBe(before);
});

// ---------- rechecks (Nachkontrolle) ----------
// Opt-in, only in sessions with more than 60 cards: a card answered wrong in the session is asked
// once more 30–50 questions after it was mastered; wrong again, it is learned again.

function createRecheck(n, { seed = 1, progress = {}, review = false, answerWith = 'term' } = {}) {
  const cards = makeCards(n);
  return { cards, s: createLearn(cards, { answerWith }, { progress, rng: mulberry32(seed), now: T0, recheck: true, review }) };
}

// decide() with the planned results for some cards (consumed in order); every other answer right.
function scripted(plan) {
  const left = {};
  for (const k of Object.keys(plan)) left[k] = plan[k].slice();
  return (q) => (left[q.cardId] && left[q.cardId].length ? left[q.cardId].shift() : true);
}

// Plays (with nextRound between rounds) until stop(question, state) holds for the current question;
// keeps the progress the store would record. Returns { s, progress, t }.
function playUntil(state, cards, stop, decide = () => true, { seed = 1, start = T0 } = {}) {
  const rng = mulberry32(seed);
  const progress = {};
  let s = state;
  let t = start;
  for (let guard = 0; ; guard++) {
    if (guard > 3000 || isFinished(s)) throw new Error('playUntil: never stopped');
    t += SEC;
    if (isRoundOver(s)) {
      s = nextRound(s, cards, rng, t);
      continue;
    }
    const q = current(s);
    if (stop(q, s)) return { s, progress, t };
    const ok = decide(q, s) === true;
    s = answer(s, ok, t);
    progress[q.cardId] = applyAnswer(progress[q.cardId], ok, t);
  }
}

test('recheck: opt-in and only in sessions with more than 60 cards', () => {
  const cards = makeCards(61);
  expect('recheck' in createLearn(cards, OPTS, { rng: mulberry32(1), now: T0 })).toBe(false);
  expect(createLearn(cards, OPTS, { rng: mulberry32(1), now: T0, recheck: true }).recheck).toEqual({ due: [] });
  for (const recheck of ['yes', 1, {}]) expect('recheck' in createLearn(cards, OPTS, { rng: mulberry32(1), now: T0, recheck })).toBe(false);
  expect('recheck' in createLearn(makeCards(60), OPTS, { rng: mulberry32(1), now: T0, recheck: true })).toBe(false);
  // The cards in scope count, not the cards of the set.
  expect('recheck' in createLearn(cards, OPTS, { subset: 'starred', rng: mulberry32(1), now: T0, recheck: true })).toBe(false);
  // Otherwise the same session, rng draw for rng draw …
  const plain = createLearn(cards, OPTS, { rng: mulberry32(2), now: T0 });
  const on = createLearn(cards, OPTS, { rng: mulberry32(2), now: T0, recheck: true });
  const { recheck, ...rest } = on;
  expect(rest).toEqual(plain);
  // … and without mistakes nothing is rechecked.
  const a = playSession(plain, cards, () => true, { seed: 3 });
  const b = playSession(on, cards, () => true, { seed: 3 });
  expect(b.log.map((e) => e.qid)).toEqual(a.log.map((e) => e.qid));
  expect(b.s.recheck).toEqual({ due: [] });
  expect('recheck' in a.s).toBe(false);
});

test('recheck: a card answered wrong is asked once more 30–50 questions after it was mastered', () => {
  const { cards, s: s0 } = createRecheck(70);
  const x = s0.order[0];
  let waiting = 0;
  let rechecked = false;
  const decide = scripted({ [x]: [false] });
  const { s, log } = playSession(
    s0,
    cards,
    (q, st) => {
      if (q.cardId === x && isRecheck(q.qid)) rechecked = true;
      if (st.stage[x] === 2 && !rechecked) {
        // Mastered and waiting for its recheck: due, or queued.
        expect(st.recheck.due.includes(x) || st.queue.some((y) => y.cardId === x && isRecheck(y.qid))).toBe(true);
        expect(isFinished(st)).toBe(false);
        waiting++;
      }
      return decide(q);
    },
    { seed: 2 },
  );
  const mine = log.filter((e) => e.cardId === x);
  expect(mine.map((e) => [kindOf(e.qid), e.type, e.correct])).toEqual([
    [1, 'mc', false],
    [1, 'mc', true],
    [1, 'written', true],
    [4, 'written', true],
  ]);
  const check = mine[3];
  expect(check.qid).toBe(`${check.round}.4:${x}`);
  expect(check.stageBefore).toBe(2);
  expect(check.wait).toBeGreaterThanOrEqual(RECHECK_GAP);
  expect(check.wait).toBeLessThanOrEqual(RECHECK_WAIT);
  expect(waiting).toBeGreaterThanOrEqual(RECHECK_GAP);
  // Only that card is rechecked; the session ends normally.
  expect(log.filter((e) => isRecheck(e.qid)).map((e) => e.cardId)).toEqual([x]);
  expect(isFinished(s)).toBe(true);
  expect(s.recheck).toEqual({ due: [] });
  expect(s.stage[x]).toBe(2);
  expect(finalStats(s).hardest).toEqual([{ cardId: x, misses: 1 }]);
  // A recheck is no repetition question.
  expect(isReviewQuestion(check.qid)).toBe(false);
  expect(reviewStats(s)).toBe(null);
});

test('recheck: wrong again → learned again → after mastering it a new recheck', () => {
  const { cards, s: s0 } = createRecheck(70, { seed: 4 });
  const x = s0.order[1];
  const { s, log } = playSession(s0, cards, scripted({ [x]: [false, true, true, false] }), { seed: 5 });
  const mine = log.filter((e) => e.cardId === x);
  expect(mine.map((e) => [kindOf(e.qid), e.type, e.correct])).toEqual([
    [1, 'mc', false],
    [1, 'mc', true],
    [1, 'written', true],
    [4, 'written', false],
    [1, 'written', true], // answered right before: no multiple choice after the wrong recheck
    [1, 'written', true],
    [4, 'written', true],
  ]);
  expect(mine[3].wait).toBeGreaterThanOrEqual(RECHECK_GAP);
  expect(mine[3].wait).toBeLessThanOrEqual(RECHECK_WAIT);
  // The second recheck: after the gap, or fewer when fewer cards are open.
  expect(mine[6].wait).toBeGreaterThanOrEqual(Math.min(RECHECK_GAP, mine[6].open - 1));
  // The learning questions after the wrong recheck keep the usual gap.
  expect(mine[4].wait).toBeGreaterThanOrEqual(Math.min(MIN_GAP, mine[4].open - 1));
  expect(s.misses[x]).toBe(2);
  expect(isFinished(s)).toBe(true);
});

test('recheck: at the end of the session a recheck that would come within 10 questions is dropped', () => {
  const { cards, s: s0 } = createRecheck(65, { seed: 7 });
  const x = s0.order[64]; // the last new card
  const { s, log } = playSession(s0, cards, scripted({ [x]: [false] }), { seed: 8 });
  const mine = log.filter((e) => e.cardId === x);
  // Missed, then mastered as the session's last answer: its recheck would come at once, so it goes.
  expect(mine.map((e) => kindOf(e.qid))).toEqual([1, 1, 1]);
  expect(log[log.length - 1]).toBe(mine[2]);
  expect(isFinished(s)).toBe(true);
  expect(s.recheck).toEqual({ due: [] });
  expect(s.misses[x]).toBe(1);
  // The session ends with that answer.
  const { s: before, t } = playUntil(s0, cards, (q, st) => q.cardId === x && st.stage[x] === 1, scripted({ [x]: [false] }), { seed: 8 });
  expect(counts(before).mastered).toBe(64);
  const done = answer(before, true, t + SEC);
  expect(done.recheck).toEqual({ due: [] });
  expect(isFinished(done)).toBe(true);
  expect(done.finishedAt).toBe(t + SEC);
});

// Everything mastered, rechecks of c2…c(k+1) queued, c1 mastered `wait` questions ago and waiting
// for its recheck. syncProgress with matching progress changes nothing but checks for the end.
function lateRecheck(k, { wait = 0, extraQueue = [], stage = {}, review = undefined } = {}) {
  const cards = makeCards(k + 1);
  const order = cards.map((c) => c.id);
  const clock = 100;
  const raw = {
    v: 1,
    order,
    stage: Object.fromEntries(order.map((id) => [id, stage[id] === undefined ? 2 : stage[id]])),
    seen: Object.fromEntries(order.map((id) => [id, true])),
    clock,
    answered: clock,
    correct: clock - k - 1,
    lastAt: Object.fromEntries(order.map((id, i) => [id, i === 0 ? clock - 1 - wait : clock - 40 - i])),
    misses: Object.fromEntries(order.map((id) => [id, 1])),
    queue: [...order.slice(1).map((id) => ({ qid: `9.4:${id}`, cardId: id, type: 'written', ask: 'term' })), ...extraQueue],
    roundLog: [{ qid: '9.1:c1', cardId: 'c1', type: 'written', ask: 'term', correct: true, stageAfter: 2 }],
    round: 9,
    recheck: { due: ['c1'] },
    updatedAt: T0,
    startedAt: T0,
  };
  if (review) raw.review = review;
  const progress = Object.fromEntries(order.map((id) => [id, stage[id] === 1 ? recorded(true) : recorded(true, true)]));
  return { raw, cards, sync: (r = raw) => syncProgress(r, progress, T0 + SEC) };
}

test('recheck: dropped only when it would come within 10 questions of mastering, at the end', () => {
  // Nine rechecks still ahead: c1's would come 9 questions after its answer → dropped.
  const nine = lateRecheck(9);
  expect(nine.sync().recheck).toEqual({ due: [] });
  // Ten ahead: it waits long enough → kept, the session is not finished.
  const kept = lateRecheck(10).sync();
  expect(kept.recheck).toEqual({ due: ['c1'] });
  expect(isFinished(kept)).toBe(false);
  // Answered longer ago: kept too.
  expect(lateRecheck(5, { wait: 5 }).sync().recheck).toEqual({ due: ['c1'] });
  expect(lateRecheck(5, { wait: 4 }).sync().recheck).toEqual({ due: [] });
  // Without a known last answer it counts as overdue.
  const unknown = lateRecheck(0);
  delete unknown.raw.lastAt.c1;
  expect(unknown.sync().recheck).toEqual({ due: ['c1'] });
  // Not at the end: a card still to learn, a learning question or a repetition question queued.
  expect(lateRecheck(3, { stage: { c3: 1 } }).sync().recheck).toEqual({ due: ['c1'] });
  expect(lateRecheck(3, { extraQueue: [{ qid: '9.1:c2', cardId: 'c2', type: 'written', ask: 'term' }] }).sync().recheck).toEqual({ due: ['c1'] });
  expect(lateRecheck(3, { review: { due: ['c2'], results: {} } }).sync().recheck).toEqual({ due: ['c1'] });
  // nextRound drops it before it checks for the end (nothing queued: nothing ahead).
  const last = lateRecheck(0);
  const n = nextRound({ ...last.raw, queue: [] }, last.cards, mulberry32(1), T0 + SEC);
  expect(n.recheck).toEqual({ due: [] });
  expect(isFinished(n)).toBe(true);
  expect(n.queue).toEqual([]);
  const later = lateRecheck(0, { wait: MIN_GAP });
  const m = nextRound({ ...later.raw, queue: [] }, later.cards, mulberry32(1), T0 + SEC);
  expect(m.queue.map((q) => q.qid)).toEqual(['10.4:c1']);
  expect(isFinished(m)).toBe(false);
  // A read (isFinished) does not drop it.
  expect(isFinished(nine.raw)).toBe(false);
});

test('recheck: the gap is at least 10, also with few cards open and at the end of a planned round', () => {
  // c1 mastered 5 questions ago and waiting for its recheck, c2 new: c2 twice, then nothing else
  // is left in the plan, but the recheck would come after only 7 – the round ends instead.
  const cards = makeCards(2);
  for (let seed = 1; seed <= 40; seed++) {
    const s = planFrom(cards, { stage: { c1: 2 }, lastAt: { c1: 4 }, clock: 10, seed, extra: { recheck: { due: ['c1'] }, misses: { c1: 1 } } });
    expect(s.queue.map((q) => q.qid)).toEqual(['1.1:c2', '1.1.2:c2']);
    expect(s.recheck.due).toEqual(['c1']);
    // Both right: everything mastered, the recheck could only come right away – dropped, finished.
    const done = nextRound(answer(answer(s, true, T0 + SEC), true, T0 + 2 * SEC), cards, mulberry32(seed), T0 + 3 * SEC);
    expect(done.recheck.due).toEqual([]);
    expect(isFinished(done)).toBe(true);
    // c2 wrong at first: it is learned again, and the recheck waits until it has waited 10.
    let w = answer(s, false, T0 + SEC);
    while (!isFinished(w)) {
      if (isRoundOver(w)) w = nextRound(w, cards, mulberry32(seed), T0 + 3 * SEC);
      else {
        const q = current(w);
        if (isRecheck(q.qid)) expect(w.clock - w.lastAt.c1 - 1).toBeGreaterThanOrEqual(MIN_GAP);
        w = answer(w, true, T0 + 2 * SEC);
      }
    }
  }
  // 12 cards (c1 mastered, 11 new): min = max(10, min(30, 11)) = 11. After 10 it may not come,
  // after 11 with a chance of 1 in 40.
  const twelve = makeCards(12);
  const extra = { recheck: { due: ['c1'] }, misses: { c1: 1 } };
  let came = 0;
  for (let seed = 1; seed <= 200; seed++) {
    const s10 = planFrom(twelve, { stage: { c1: 2 }, lastAt: { c1: 30 - 1 - 10 }, clock: 30, seed, roundSize: 1, extra });
    expect(s10.queue[0].cardId).not.toBe('c1');
    const s11 = planFrom(twelve, { stage: { c1: 2 }, lastAt: { c1: 30 - 1 - 11 }, clock: 30, seed, roundSize: 1, extra });
    if (s11.queue[0].cardId === 'c1') came++;
  }
  expect(came).toBeGreaterThan(0);
  expect(came).toBeLessThan(20);
  // Three mastered cards waiting, nothing else (the end): c1, mastered 3 questions ago, is dropped
  // by nextRound; the two others have waited 10 and come.
  const three = makeCards(3);
  const all = { stage: { c1: 2, c2: 2, c3: 2 }, clock: 20, extra: { recheck: { due: ['c1', 'c2', 'c3'] }, misses: { c1: 1, c2: 1, c3: 1 } } };
  const end = planFrom(three, { ...all, lastAt: lastAtFor(['c1', 'c2', 'c3'], [3, 10, 12], 20) });
  expect(end.queue.map((q) => q.qid)).toEqual(['1.4:c3', '1.4:c2']);
  expect(end.recheck).toEqual({ due: [] });
});

test('spacing: waiting rechecks do not stretch the gap of the learning cards; repetition questions do', () => {
  // Three cards to learn (asked before) and ten mastered cards waiting for their recheck.
  const cards = makeCards(13);
  const learn = ['c1', 'c2', 'c3'];
  const mastered = cards.slice(3).map((c) => c.id);
  const base = {
    stage: { c1: 1, c2: 1, c3: 1, ...Object.fromEntries(mastered.map((id) => [id, 2])) },
    lastAt: { ...lastAtFor(learn, [2, 1, 0], 40), ...lastAtFor(mastered, mastered.map(() => 5), 40) },
    clock: 40,
    roundSize: 3,
  };
  const rechecks = { recheck: { due: mastered }, misses: Object.fromEntries(mastered.map((id) => [id, 1])) };
  // The gap is min(10, 3 - 1) = 2: c1 comes at once, then c2 and c3.
  for (let seed = 1; seed <= 10; seed++) expect(planFrom(cards, { ...base, seed, extra: rechecks }).queue.map((q) => q.qid)).toEqual(['1.1:c1', '1.1:c2', '1.1:c3']);
  // Ten repetition questions instead: 13 to learn or repeat, the gap is 10, so they come first.
  const r = planFrom(cards, { ...base, extra: { review: { due: mastered, results: {} } } });
  expect(r.queue.map((q) => q.qid)).toEqual(mastered.slice(0, 3).map((id) => `1.3:${id}`));
});

test('spacing: nothing may come and nothing is new: a learning card early, a recheck only without one', () => {
  // c1 and c2 answered at the same place (repaired state): neither may come; c3 waits for its
  // recheck (not ready either) and has waited longest – still c1 comes.
  const cards = makeCards(3);
  const s = planFrom(cards, { stage: { c1: 1, c2: 1, c3: 2 }, lastAt: { c1: 9, c2: 9, c3: 4 }, clock: 10, roundSize: 1, extra: { recheck: { due: ['c3'] }, misses: { c3: 1 } } });
  expect(s.queue.map((q) => q.qid)).toEqual(['1.1:c1']);
  // Only rechecks waiting, none ready, after the repetition question: a recheck that has waited
  // MIN_GAP questions comes (c2, 10 at its turn), one that has waited fewer never comes early – the
  // round ends there (c2 last asked at 3, then 9 at its turn).
  const plan = (c2) =>
    planFrom(cards, {
      stage: { c1: 2, c2: 2, c3: 2 },
      lastAt: { c1: 9, c2 },
      clock: 12,
      roundSize: 3,
      extra: { recheck: { due: ['c1', 'c2'] }, misses: { c1: 1, c2: 1 }, review: { due: ['c3'], results: {} } },
    });
  expect(plan(2).queue.map((q) => q.qid)).toEqual(['1.3:c3', '1.4:c2']);
  expect(plan(2).recheck.due).toEqual(['c1']);
  expect(plan(3).queue.map((q) => q.qid)).toEqual(['1.3:c3']);
  expect(plan(3).recheck.due).toEqual(['c1', 'c2']);
});

test('spacing: rechecks at the end come after MIN_GAP even when their wait is not reached', () => {
  // Every card mastered, 35 rechecks waiting 15 questions: their wait would be 30 with so many open,
  // but nothing else is left, so they come (none sooner than MIN_GAP).
  const cards = makeCards(40);
  const ids = cards.slice(0, 35).map((c) => c.id);
  const stage = Object.fromEntries(cards.map((c) => [c.id, 2]));
  const lastAt = Object.fromEntries(ids.map((id) => [id, 4]));
  const misses = Object.fromEntries(ids.map((id) => [id, 1]));
  const s = planFrom(cards, { stage, lastAt, clock: 20, roundSize: 7, extra: { recheck: { due: ids }, misses } });
  expect(s.queue).toHaveLength(7);
  expect(s.queue.every((q) => isRecheck(q.qid))).toBe(true);
});

test('recheck: "Ich hatte recht"', () => {
  const { cards, s: s0 } = createRecheck(70, { seed: 6 });
  const [x, y] = s0.order;
  // A wrong recheck answer overridden: still mastered, rechecked, no further recheck.
  let { s } = playUntil(s0, cards, (q) => q.cardId === x && isRecheck(q.qid), scripted({ [x]: [false] }), { seed: 1 });
  s = answer(s, false, T0 + DAY_MS);
  expect(s.stage[x]).toBe(0);
  expect(s.misses[x]).toBe(2);
  s = override(s, T0 + DAY_MS + SEC);
  expect(s.stage[x]).toBe(2);
  expect(s.misses[x]).toBe(1);
  expect(s.recheck.due).not.toContain(x);
  expect(s.queue.some((q) => q.cardId === x)).toBe(false);
  const rest = playSession(s, cards, () => true, { seed: 2, start: T0 + DAY_MS + MIN });
  expect(rest.log.some((e) => e.cardId === x)).toBe(false);
  expect(isFinished(rest.s)).toBe(true);
  // The answer that masters a card missed before, overridden: the recheck is noted.
  ({ s } = playUntil(s0, cards, (q, st) => q.cardId === x && st.stage[x] === 1, scripted({ [x]: [false] }), { seed: 1 }));
  s = answer(s, false, T0 + DAY_MS);
  expect(s.recheck.due).not.toContain(x);
  s = override(s, T0 + DAY_MS + SEC);
  expect(s.stage[x]).toBe(2);
  expect(s.misses[x]).toBe(1);
  expect(s.recheck.due).toEqual([x]);
  // A miss overridden right away leaves nothing to recheck.
  const first = playUntil(s0, cards, (q) => q.cardId === y, () => true, { seed: 1 });
  s = override(answer(first.s, false, T0 + DAY_MS), T0 + DAY_MS + SEC);
  expect(s.misses[y]).toBe(0);
  const done = playSession(s, cards, () => true, { seed: 3, start: T0 + DAY_MS + MIN });
  expect(done.log.some((e) => isRecheck(e.qid))).toBe(false);
  expect(done.s.recheck).toEqual({ due: [] });
});

test('recheck: removeCard and syncProgress', () => {
  const { cards, s: s0 } = createRecheck(70, { seed: 9 });
  const x = s0.order[0];
  const waitingFor = playUntil(s0, cards, (q, st) => st.recheck.due.includes(x), scripted({ [x]: [false] }), { seed: 1 });
  let s = waitingFor.s;
  expect(s.stage[x]).toBe(2);
  // Deleted: it leaves the rechecks.
  const r = removeCard(s, x, T0 + DAY_MS, { cards: cards.filter((c) => c.id !== x), rng: mulberry32(1) });
  expect(r.recheck).toEqual({ due: [] });
  expect(r.order).not.toContain(x);
  // Missed elsewhere: it leaves the rechecks and is learned again (a miss of this session is
  // still counted, so after mastering it again it is rechecked).
  const progress = { ...waitingFor.progress };
  progress[x] = applyAnswer(progress[x], false, T0);
  expect(matchesProgress(s, waitingFor.progress)).toBe(true);
  s = syncProgress(s, progress, T0 + DAY_MS);
  expect(s.stage[x]).toBe(0);
  expect(s.recheck.due).not.toContain(x);
  const after = playSession(s, cards, () => true, { seed: 2, start: T0 + DAY_MS });
  expect(after.log.filter((e) => e.cardId === x).map((e) => kindOf(e.qid))).toEqual([1, 1, 4]);
  // A queued recheck of a card missed elsewhere becomes an ordinary question at its place.
  const queued = playUntil(s0, cards, (q, st) => st.queue.some((y) => y.cardId === x && isRecheck(y.qid)), scripted({ [x]: [false] }), { seed: 1 });
  const qBefore = queued.s.queue.find((y) => y.cardId === x);
  const p2 = { ...queued.progress, [x]: applyAnswer(queued.progress[x], false, T0) };
  const synced = syncProgress(queued.s, p2, T0 + DAY_MS);
  const qAfter = synced.queue.find((y) => y.cardId === x);
  expect(qAfter.qid).toBe(qBefore.qid.replace('.4', '.1'));
  expect(qAfter.type).toBe('written');
  expect(synced.queue.map((y) => y.cardId)).toEqual(queued.s.queue.map((y) => y.cardId));
  // Mastered elsewhere without a miss in this session: nothing to recheck.
  expect(syncProgress(s0, { [x]: recorded(true, true) }, T0).recheck).toEqual({ due: [] });
});

test('recheck: survives storage; junk is dropped on repair', () => {
  const { cards, s: s0 } = createRecheck(70, { seed: 9 });
  const x = s0.order[0];
  const { s } = playUntil(s0, cards, (q, st) => st.recheck.due.includes(x), scripted({ [x]: [false] }), { seed: 1 });
  const json = JSON.parse(JSON.stringify(s));
  expect(json).toEqual(s);
  expect(tick(json, NaN)).toEqual(s);
  const repaired = tick({ ...json, recheck: { due: [x, 'zz', 7, x, null] } }, NaN);
  expect(repaired.recheck).toEqual({ due: [x] });
  expect(tick({ ...json, recheck: {} }, NaN).recheck).toEqual({ due: [] });
  for (const junk of [null, [], 'x', 3, true]) expect('recheck' in tick({ ...json, recheck: junk }, NaN)).toBe(false);
  // Recheck questions are recognised by their kind (4) when the state is read.
  const q = { qid: `3.4:${x}`, cardId: x, type: 'written', ask: 'term' };
  const withQ = tick({ ...json, queue: [q, ...json.queue], recheck: { due: [] } }, NaN);
  expect(isFinished({ ...withQ, order: [x], stage: { [x]: 2 } })).toBe(false);
  expect(isFinished({ ...withQ, order: [x], stage: { [x]: 2 }, queue: [] })).toBe(true);
});

test('recheck: functions never mutate a recheck state', () => {
  const { cards, s: s0 } = createRecheck(70, { seed: 9 });
  const x = s0.order[0];
  const { s } = playUntil(s0, cards, (q, st) => st.queue.some((y) => y.cardId === x && isRecheck(y.qid)), scripted({ [x]: [false] }), { seed: 1 });
  const frozen = deepFreeze(JSON.parse(JSON.stringify(s)));
  const before = snapshot(frozen);
  answer(frozen, false, T0 + DAY_MS);
  override(answer(frozen, false, T0 + DAY_MS), T0 + DAY_MS);
  syncProgress(frozen, deepFreeze({}), T0 + DAY_MS);
  removeCard(frozen, x, T0 + DAY_MS, { cards, rng: mulberry32(1) });
  nextRound(playAll(frozen, () => false, T0 + DAY_MS), cards, mulberry32(2), T0 + DAY_MS);
  expect(snapshot(frozen)).toBe(before);
});

// ---------- stored sessions and determinism ----------

// A session stored by 1.3 (before spacing): `active` batch, `retried`, a retry "1.2:c1" queued at
// the end of the round, no clock or lastAt. 5 cards, roundSize 3, c2 familiar; c1 answered wrong,
// c3 right.
const OLD_STATE = {
  v: 1,
  subset: 'all',
  answerWith: 'term',
  learn: { roundSize: 3, mc: true, written: true },
  order: ['c3', 'c2', 'c1', 'c5', 'c4'],
  stage: { c3: 1, c2: 1, c1: 0, c5: 0, c4: 0 },
  initiallyMastered: [],
  seen: { c2: true, c1: true, c3: true },
  active: ['c2', 'c3', 'c1'],
  round: 1,
  queue: [
    { qid: '1.1:c2', cardId: 'c2', type: 'written', ask: 'term', retryChoices: [{ cardId: 'c2', text: 'terme 2' }, { cardId: 'c5', text: 'terme 5' }, { cardId: 'c1', text: 'terme 1' }, { cardId: 'c4', text: 'terme 4' }] },
    { qid: '1.2:c1', cardId: 'c1', type: 'mc', ask: 'term', choices: [{ cardId: 'c1', text: 'terme 1' }, { cardId: 'c2', text: 'terme 2' }, { cardId: 'c3', text: 'terme 3' }, { cardId: 'c4', text: 'terme 4' }] },
  ],
  retried: { c1: true },
  roundLog: [
    { qid: '1.1:c1', cardId: 'c1', type: 'mc', ask: 'term', correct: false, stageAfter: 0 },
    { qid: '1.1:c3', cardId: 'c3', type: 'mc', ask: 'term', correct: true, stageAfter: 1 },
  ],
  rounds: [],
  answered: 2,
  correct: 1,
  misses: { c1: 1 },
  last: { qid: '1.1:c3', cardId: 'c3', type: 'mc', ask: 'term', correct: true, stageBefore: 0 },
  startedAt: 1760000000000,
  updatedAt: 1760000002000,
  finishedAt: null,
  elapsedMs: 2000,
};

test('stored sessions from before spacing (active, retried, no clock) run on', () => {
  const cards = makeCards(5);
  const old = JSON.parse(JSON.stringify(OLD_STATE));
  expect(current(old)).toEqual({ qid: '1.1:c2', cardId: 'c2', type: 'written', ask: 'term' });
  const read = tick(old, NaN);
  expect('active' in read).toBe(false);
  expect('retried' in read).toBe(false);
  // The answer count stands in for the clock; nobody has a last answer yet.
  expect([read.clock, read.lastAt, read.repeats]).toEqual([2, {}, 0]);
  expect(read.queue).toEqual(old.queue);
  expect(matchesProgress(old, { c2: recorded(true), c3: recorded(true), c1: recorded(false) })).toBe(true);
  let s = answer(old, true, T0 + 3 * SEC);
  expect(s.stage.c2).toBe(2);
  expect([s.clock, s.lastAt]).toEqual([3, { c2: 2 }]);
  // The old retry is asked as an ordinary question.
  expect(current(s)).toEqual({ qid: '1.2:c1', cardId: 'c1', type: 'mc', ask: 'term', choices: old.queue[1].choices });
  expect(isReviewQuestion('1.2:c1')).toBe(false);
  s = answer(s, true, T0 + 4 * SEC);
  expect(s.stage.c1).toBe(1);
  expect(isRoundOver(s)).toBe(true);
  s = nextRound(s, cards, mulberry32(1), T0 + 5 * SEC);
  expect(s.round).toBe(2);
  expect(s.rounds).toEqual([{ round: 1, answered: 4, correct: 3, cardIds: ['c1', 'c3', 'c2'] }]);
  for (const q of s.queue) expect(QID.exec(q.qid).slice(1, 3)).toEqual(['2', '1']);
  const { s: end, log } = playSession(s, cards, () => true, { seed: 2 });
  expect(isFinished(end)).toBe(true);
  expect(end.answered).toBe(end.clock);
  expect(end.rounds.reduce((n, r) => n + r.answered, 0)).toBe(end.answered);
  expect(counts(end)).toEqual({ fresh: 0, learning: 0, mastered: 5, total: 5, progress: 1 });
  expect(log.length).toBe(end.answered - 4);
  // A stored session that is between two rounds plans the next one with the new rules.
  const between = { ...JSON.parse(JSON.stringify(OLD_STATE)), queue: [] };
  const n = nextRound(between, cards, mulberry32(3), T0 + MIN);
  expect(n.round).toBe(2);
  expect(n.queue.length).toBeGreaterThan(0);
  expect(n.queue.every((q) => kindOf(q.qid) === 1 && q.qid.startsWith('2.'))).toBe(true);
});

test('determinism: the same seed gives the same session, also with repetition questions and rechecks', () => {
  const cards = makeCards(70);
  const progress = masteredProgress(cards.slice(0, 10));
  const run = (seed) => {
    const d = mulberry32(seed + 1000);
    const s = createLearn(cards, { answerWith: 'both' }, { progress, rng: mulberry32(seed), now: T0, review: true, recheck: true });
    return playSession(s, cards, () => d() < 0.75, { seed, overrideIf: () => d() < 0.1 });
  };
  const a = run(1);
  expect(snapshot(run(1))).toBe(snapshot(a));
  const c = run(2);
  expect(snapshot(c.log.map((e) => e.qid))).not.toBe(snapshot(a.log.map((e) => e.qid)));
  for (const r of [a, c]) {
    expect(isFinished(r.s)).toBe(true);
    const nth = {};
    const seenIds = new Set();
    for (const e of r.log) {
      const [, round, kind, n, id] = QID.exec(e.qid);
      expect(Number(round)).toBe(e.round);
      expect(id).toBe(e.cardId);
      const key = `${e.round}/${e.cardId}`;
      nth[key] = (nth[key] || 0) + 1;
      expect(n === undefined ? 1 : Number(n)).toBe(nth[key]);
      // Multiple choice only until the card was answered right once (here or before the session).
      expect(e.type).toBe(e.stageBefore === 0 && !e.solvedBefore ? 'mc' : 'written');
      // Repetition questions: once per card mastered before, as its first question.
      if (kind === '3') expect(e.stageBefore === 2 && !seenIds.has(id) && progress[id] !== undefined).toBe(true);
      // Rechecks: mastered cards; learning questions: cards not mastered.
      if (kind === '4') expect(e.stageBefore).toBe(2);
      if (kind === '1') expect(e.stageBefore).toBeLessThan(2);
      seenIds.add(id);
    }
    expect(r.log.filter((e) => kindOf(e.qid) === 3)).toHaveLength(10);
    expect(reviewStats(r.s).asked).toBe(10);
    expect(reviewStats(r.s).left).toBe(0);
    // Every card with a miss left in the session ended with a recheck, the others without one –
    // unless its recheck was dropped at the end (mastered fewer than 10 questions before).
    const rechecked = r.log.filter((e) => isRecheck(e.qid));
    expect(rechecked.length).toBeGreaterThan(5);
    for (const id of r.s.order) {
      const last = r.log.filter((e) => e.cardId === id).pop();
      const missed = (r.s.misses[id] || 0) > 0;
      if (kindOf(last.qid) === 4) expect(missed).toBe(true);
      else if (missed) {
        const after = r.log.slice(r.log.indexOf(last) + 1);
        // Dropped at a moment when everything was mastered and only rechecks were queued (they
        // may still be answered wrong, so the session can go on for a while).
        expect(after.length < MIN_GAP || after.some((x) => x.learning === 0 && x.reviews === 0)).toBe(true);
      }
    }
    // Rechecks wait at least 10 questions, also at the end of the session (then they are dropped).
    for (const e of rechecked) expect(e.wait).toBeGreaterThanOrEqual(MIN_GAP);
  }
});

test('buildChoices: Arabic and Chinese spellings that grading treats as equal are no wrong options', () => {
  const cards = [
    { id: 'kitab', term: 'كِتَابٌ', definition: 'Buch' },
    { id: 'kitab2', term: 'كتاب', definition: 'Band' },
    { id: 'daftar', term: 'دفتر', definition: 'Heft' },
    { id: 'both', term: 'قلم، دَفْتَر', definition: 'Stift' },
    { id: 'bait', term: 'بيت', definition: 'Haus' },
    { id: 'madrasa', term: 'مدرسة', definition: 'Schule' },
    { id: 'nihao', term: '你好！', definition: 'Hallo' },
    { id: 'nihao2', term: '你 好!', definition: 'Guten Tag' },
    { id: 'xiexie', term: '谢谢，多谢', definition: 'Danke' },
    { id: 'duoxie', term: '多谢', definition: 'Vielen Dank' },
  ];
  const byId = Object.fromEntries(cards.map((c) => [c.id, c]));
  // Never together: the same text without vowel marks, with ASCII instead of full-width
  // punctuation or with spaces between characters, or a shared alternative (، ，).
  const apart = [['kitab', 'kitab2'], ['daftar', 'both'], ['nihao', 'nihao2'], ['xiexie', 'duoxie']];
  for (let seed = 1; seed <= 120; seed++) {
    for (const [a, b] of apart) {
      for (const [x, y] of [[a, b], [b, a]]) {
        const ids = buildChoices(cards, byId[x], 'term', mulberry32(seed)).map((c) => c.cardId);
        expect(ids).toHaveLength(4);
        expect(ids).not.toContain(y);
      }
    }
  }
});

await run('learn.test.js');
