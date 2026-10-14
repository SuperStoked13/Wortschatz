import { test, expect, run } from './harness.js';
import {
  DEFAULT_LEARN,
  stageFromProgress,
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
  reviewsPerRound,
  reviewStats,
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
  expect(s.active).toEqual(s.order.slice(0, 7));
  expect(s.round).toBe(1);
  expect(s.queue).toHaveLength(7);
  expect(sorted(s.queue.map((q) => q.cardId))).toEqual(sorted(s.active));
  for (const q of s.queue) {
    expect(q.qid).toBe(`1.1:${q.cardId}`);
    expect(q.type).toBe('mc');
    expect(q.ask).toBe('term');
    expect(q.choices).toHaveLength(4);
    checkChoices(q, cards);
  }
  expect(s.retried).toEqual({});
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
  expect(s.active).toHaveLength(3);
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
  // Only askable cards serve as options: "la rue" vs "calme".
  for (const q of s.queue) expect(sorted(q.choices.map((c) => c.cardId))).toEqual(['a', 'd']);
  const empty = createLearn(null, OPTS, { now: T0 });
  expect(empty.order).toEqual([]);
  expect(isFinished(empty)).toBe(true);
});

test('stage initialisation from progress: mastered cards are counted but not asked', () => {
  const cards = makeCards(6);
  const progress = {
    c1: progressEntry(2), // mastered
    c2: progressEntry(1), // familiar → written
    c3: progressEntry(0, 1, 1, 'incorrect'), // reset → mc, but not fresh
    c4: progressEntry(5, 6, 1), // mastered
  };
  const s = createLearn(cards, OPTS, { progress, rng: mulberry32(3), now: T0 });
  expect(s.stage).toEqual({ ...Object.fromEntries(s.order.map((id) => [id, 0])), c1: 2, c2: 1, c4: 2 });
  expect(sorted(s.initiallyMastered)).toEqual(['c1', 'c4']);
  expect(s.initiallyMastered).toEqual(s.order.filter((id) => id === 'c1' || id === 'c4'));
  expect(sorted(s.active)).toEqual(['c2', 'c3', 'c5', 'c6']);
  expect(s.active[0]).toBe('c2'); // stage-1 cards first
  expect(s.queue.some((q) => q.cardId === 'c1' || q.cardId === 'c4')).toBe(false);
  const byCard = Object.fromEntries(s.queue.map((q) => [q.cardId, q]));
  expect(byCard.c2.type).toBe('written');
  expect(byCard.c2.choices).toBe(undefined);
  expect(byCard.c3.type).toBe('mc');
  expect(byCard.c5.type).toBe('mc');
  expect(counts(s)).toEqual({ fresh: 2, learning: 2, mastered: 2, total: 6, progress: 2 / 6 });
  expect(isFinished(s)).toBe(false);
});

test('the first batch takes stage-1 cards first, then stage-0 cards in order', () => {
  const cards = makeCards(10);
  const progress = { c8: progressEntry(1), c9: progressEntry(1) };
  const s = createLearn(cards, { answerWith: 'term', learn: { roundSize: 4 } }, { progress, rng: mulberry32(11), now: T0 });
  const ones = s.order.filter((id) => id === 'c8' || id === 'c9');
  const zeros = s.order.filter((id) => id !== 'c8' && id !== 'c9');
  expect(s.active).toEqual([...ones, ...zeros.slice(0, 2)]);
});

test('everything already mastered at start: nothing asked, finished, all counted', () => {
  const cards = makeCards(3);
  const progress = { c1: progressEntry(2), c2: progressEntry(3), c3: progressEntry(2) };
  const s = createLearn(cards, OPTS, { progress, rng: mulberry32(1), now: T0 });
  expect(s.active).toEqual([]);
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
  // One question per card per round: no second question for it now.
  expect(s.queue.some((q) => q.cardId === id)).toBe(false);
  s = playRound(s, () => true, T0 + 10 * SEC);
  expect(Object.values(s.stage).every((st) => st === 1)).toBe(true);
  expect(counts(s)).toEqual({ fresh: 0, learning: 6, mastered: 0, total: 6, progress: 0 });
  s = nextRound(s, cards, mulberry32(3), T0 + MIN);
  expect(s.round).toBe(2);
  expect(s.queue).toHaveLength(6);
  for (const q of s.queue) {
    expect(q.type).toBe('written');
    expect(q.choices).toBe(undefined);
    expect(q.qid).toBe(`2.1:${q.cardId}`);
  }
  s = playRound(s, () => true, T0 + MIN);
  expect(s.stage[id]).toBe(2);
  expect(s.roundLog.find((e) => e.cardId === id)).toEqual({ qid: `2.1:${id}`, cardId: id, type: 'written', ask: 'term', correct: true, stageAfter: 2 });
  expect(isFinished(s)).toBe(true);
  expect(counts(s)).toEqual({ fresh: 0, learning: 0, mastered: 6, total: 6, progress: 1 });
});

test('a wrong written answer sends the card back to multiple choice', () => {
  const cards = makeCards(5);
  const progress = Object.fromEntries(cards.map((c) => [c.id, progressEntry(1)]));
  let s = createLearn(cards, OPTS, { progress, rng: mulberry32(4), now: T0 });
  expect(s.queue.every((q) => q.type === 'written')).toBe(true);
  const id = current(s).cardId;
  s = answer(s, false, T0 + 10 * SEC);
  expect(s.stage[id]).toBe(0);
  expect(s.last).toEqual({ qid: `1.1:${id}`, cardId: id, type: 'written', ask: 'term', correct: false, stageBefore: 1 });
  const retry = s.queue[s.queue.length - 1];
  expect(retry.cardId).toBe(id);
  expect(retry.qid).toBe(`1.2:${id}`);
  expect(retry.type).toBe('mc');
  expect(retry.ask).toBe('term');
  checkChoices(retry, cards);
  s = playRound(s, (q) => q.cardId !== id || q.type === 'mc', T0 + 10 * SEC);
  // The retry (multiple choice) was answered correctly → stage 1 again.
  expect(s.stage[id]).toBe(1);
  expect(checkpoint(s).items.find((it) => it.cardId === id)).toEqual({ cardId: id, stage: 1, results: [false, true] });
  s = nextRound(s, cards, mulberry32(5), T0 + MIN);
  expect(s.active).toEqual([id]);
  expect(s.queue).toHaveLength(1);
  expect(current(s).type).toBe('written');
  s = answer(s, true, T0 + MIN + 5 * SEC);
  expect(isFinished(s)).toBe(true);
});

test('a wrong answer is re-queued once at the end of the same round', () => {
  const cards = makeCards(4);
  let s = createLearn(cards, OPTS, { rng: mulberry32(6), now: T0 });
  const [id, ...rest] = s.queue.map((q) => q.cardId);
  s = answer(s, false, T0 + 10 * SEC);
  expect(s.queue.map((q) => q.cardId)).toEqual([...rest, id]);
  expect(s.retried).toEqual({ [id]: true });
  expect(s.misses).toEqual({ [id]: 1 });
  s = answer(s, true, T0 + 20 * SEC);
  s = answer(s, true, T0 + 30 * SEC);
  s = answer(s, true, T0 + 40 * SEC);
  expect(current(s).cardId).toBe(id);
  expect(current(s).qid).toBe(`1.2:${id}`);
  expect(current(s).type).toBe('mc');
  // Wrong again: no further retry in this round.
  s = answer(s, false, T0 + 50 * SEC);
  expect(s.queue).toEqual([]);
  expect(isRoundOver(s)).toBe(true);
  expect(s.stage[id]).toBe(0);
  expect(s.misses[id]).toBe(2);
  expect(s.roundLog.filter((e) => e.cardId === id).map((e) => e.correct)).toEqual([false, false]);
  // Answering past the end of the round changes nothing.
  expect(snapshot(answer(s, true, T0 + MIN))).toBe(snapshot(s));
});

test('retries reset in the next round', () => {
  const cards = makeCards(3);
  let s = createLearn(cards, OPTS, { rng: mulberry32(7), now: T0 });
  const id = current(s).cardId;
  s = playRound(s, (q) => q.cardId !== id, T0);
  expect(s.retried).toEqual({ [id]: true });
  s = nextRound(s, cards, mulberry32(8), T0 + MIN);
  expect(s.retried).toEqual({});
  expect(s.active[0]).toBe(id);
  const q = s.queue.find((x) => x.cardId === id);
  expect(q.type).toBe('mc');
  expect(q.qid).toBe(`2.1:${id}`);
  while (current(s).cardId !== id) s = answer(s, true, T0 + MIN + SEC);
  s = answer(s, false, T0 + MIN + 2 * SEC);
  expect(s.queue[s.queue.length - 1].qid).toBe(`2.2:${id}`);
  expect(s.retried).toEqual({ [id]: true });
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

test('nextRound: mastered cards leave, then stage-1 cards refill before stage-0 cards in order', () => {
  const cards = makeCards(8);
  const progress = { c2: progressEntry(1), c4: progressEntry(1), c6: progressEntry(1), c8: progressEntry(1) };
  const opts = { answerWith: 'term', learn: { roundSize: 3 } };
  let s = createLearn(cards, opts, { progress, rng: mulberry32(4), now: T0 });
  const ones = s.order.filter((id) => progress[id]);
  const zeros = s.order.filter((id) => !progress[id]);
  expect(s.active).toEqual(ones.slice(0, 3));
  expect(s.queue.every((q) => q.type === 'written')).toBe(true);
  s = playRound(s, () => true, T0);
  expect(ones.slice(0, 3).every((id) => s.stage[id] === 2)).toBe(true);
  s = nextRound(s, cards, mulberry32(5), T0 + MIN);
  expect(s.round).toBe(2);
  expect(s.rounds).toEqual([{ round: 1, answered: 3, correct: 3, cardIds: ones.slice(0, 3) }]);
  expect(s.active).toEqual([ones[3], zeros[0], zeros[1]]);
  const types = Object.fromEntries(s.queue.map((q) => [q.cardId, q.type]));
  expect(types).toEqual({ [ones[3]]: 'written', [zeros[0]]: 'mc', [zeros[1]]: 'mc' });
});

test('nextRound: the batch keeps its unmastered cards', () => {
  const cards = makeCards(8);
  const progress = { c2: progressEntry(1), c4: progressEntry(1), c6: progressEntry(1), c8: progressEntry(1) };
  let s = createLearn(cards, { answerWith: 'term', learn: { roundSize: 3 } }, { progress, rng: mulberry32(4), now: T0 });
  const ones = s.order.filter((id) => progress[id]);
  const zeros = s.order.filter((id) => !progress[id]);
  const keep = ones[1];
  s = playRound(s, (q) => q.cardId !== keep, T0); // keep: wrong, retry wrong
  expect(s.stage[keep]).toBe(0);
  s = nextRound(s, cards, mulberry32(5), T0 + MIN);
  expect(s.active).toEqual([keep, ones[3], zeros[0]]);
  expect(s.rounds[0]).toEqual({ round: 1, answered: 4, correct: 2, cardIds: ones.slice(0, 3) });
  expect(s.queue.find((q) => q.cardId === keep).type).toBe('mc');
});

test('each round asks one question per batch card in shuffled order', () => {
  const cards = makeCards(10);
  let differs = 0;
  for (let seed = 1; seed <= 30; seed++) {
    const s = createLearn(cards, OPTS, { rng: mulberry32(seed), now: T0 });
    const asked = s.queue.map((q) => q.cardId);
    expect(asked).toHaveLength(s.active.length);
    expect(sorted(asked)).toEqual(sorted(s.active));
    if (asked.join() !== s.active.join()) differs++;
  }
  expect(differs).toBeGreaterThan(20);
});

test('20 cards with roundSize 7, all answers correct: six rounds to finish', () => {
  const cards = makeCards(20);
  let s = createLearn(cards, OPTS, { rng: mulberry32(8), now: T0 });
  const order = s.order.slice();
  const plan = [
    { active: order.slice(0, 7), type: 'mc', after: { fresh: 13, learning: 7, mastered: 0 } },
    { active: order.slice(0, 7), type: 'written', after: { fresh: 13, learning: 0, mastered: 7 } },
    { active: order.slice(7, 14), type: 'mc', after: { fresh: 6, learning: 7, mastered: 7 } },
    { active: order.slice(7, 14), type: 'written', after: { fresh: 6, learning: 0, mastered: 14 } },
    { active: order.slice(14), type: 'mc', after: { fresh: 0, learning: 6, mastered: 14 } },
    { active: order.slice(14), type: 'written', after: { fresh: 0, learning: 0, mastered: 20 } },
  ];
  let t = T0;
  plan.forEach((p, i) => {
    expect(s.round).toBe(i + 1);
    expect(s.active).toEqual(p.active);
    expect(sorted(s.queue.map((q) => q.cardId))).toEqual(sorted(p.active));
    expect(s.queue.every((q) => q.type === p.type)).toBe(true);
    s = playRound(s, () => true, t);
    t += MIN;
    const c = counts(s);
    expect({ fresh: c.fresh, learning: c.learning, mastered: c.mastered }).toEqual(p.after);
    if (i < plan.length - 1) {
      expect(isFinished(s)).toBe(false);
      s = nextRound(s, cards, mulberry32(100 + i), t);
    }
  });
  expect(isFinished(s)).toBe(true);
  s = nextRound(s, cards, mulberry32(1), t + MIN);
  expect(s.rounds.map((r) => r.round)).toEqual([1, 2, 3, 4, 5, 6]);
  expect(s.rounds.map((r) => r.answered)).toEqual([7, 7, 7, 7, 6, 6]);
  expect(s.rounds.map((r) => r.cardIds)).toEqual(plan.map((p) => p.active));
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
      if (rounds++ > 100) throw new Error(`seed ${seed}: did not finish`);
      expect(s.active.length).toBeLessThanOrEqual(7);
      expect(s.queue.length).toBe(s.active.length);
      for (const q of s.queue) {
        expect(s.active).toContain(q.cardId);
        expect(s.stage[q.cardId]).toBeLessThan(2);
        expect(q.type).toBe(s.stage[q.cardId] === 0 ? 'mc' : 'written');
      }
      const asked = {};
      while (!isRoundOver(s)) {
        t += 4 * SEC;
        const q = current(s);
        asked[q.cardId] = (asked[q.cardId] || 0) + 1;
        if (q.type === 'mc') checkChoices(q, cards);
        s = answer(s, rng() < 0.7, t);
        if (!s.last.correct && rng() < 0.15) s = override(s, t + SEC);
      }
      for (const k of Object.keys(asked)) expect(asked[k]).toBeLessThanOrEqual(2);
      expect(s.roundLog.length).toBe(Object.values(asked).reduce((a, b) => a + b, 0));
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
  let s = createLearn(cards, OPTS, { rng: mulberry32(9), now: T0 });
  s = playRound(s, () => true, T0); // both stage 1
  s = nextRound(s, cards, mulberry32(1), T0 + MIN);
  s = answer(s, true, T0 + MIN + 5 * SEC);
  expect(isFinished(s)).toBe(false);
  s = answer(s, true, T0 + MIN + 10 * SEC);
  expect(isFinished(s)).toBe(true);
  expect(isRoundOver(s)).toBe(true);
  expect(s.finishedAt).toBe(T0 + MIN + 10 * SEC);
  expect(finalStats(s).rounds).toBe(2);
  const closed = nextRound(s, cards, mulberry32(1), T0 + 2 * MIN);
  expect(closed.round).toBe(2);
  expect(closed.rounds.map((r) => [r.round, r.answered, r.correct])).toEqual([
    [1, 2, 2],
    [2, 2, 2],
  ]);
  expect(closed.finishedAt).toBe(T0 + MIN + 10 * SEC);
  // The final round's checkpoint is still available.
  expect(checkpoint(closed).round).toBe(2);
  expect(checkpoint(closed).answered).toBe(2);
  expect(snapshot(nextRound(closed, cards, mulberry32(1), T0 + 3 * MIN))).toBe(snapshot(closed));
  expect(finalStats(closed).rounds).toBe(2);
});

// ---------- checkpoint, counts, finalStats ----------

test('checkpoint: per-card results in asked order and counts', () => {
  const cards = makeCards(3);
  let s = createLearn(cards, OPTS, { rng: mulberry32(6), now: T0 });
  const [x, y, z] = s.queue.map((q) => q.cardId);
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
  s = answer(s, true, T0 + 4 * SEC); // y retry
  expect(checkpoint(s)).toEqual({
    round: 1,
    answered: 4,
    correct: 3,
    items: [
      { cardId: x, stage: 1, results: [true] },
      { cardId: y, stage: 1, results: [false, true] },
      { cardId: z, stage: 1, results: [true] },
    ],
    counts: { fresh: 0, learning: 3, mastered: 0, total: 3 },
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
  const [a, b, c] = s.queue.map((q) => q.cardId);
  s = playRound(s, planned({ [a]: [false, false], [b]: [false, true], [c]: [true] }), T0);
  s = nextRound(s, cards, mulberry32(1), T0 + MIN);
  expect(sorted(s.active)).toEqual(sorted([a, b, c]));
  s = playRound(s, () => true, T0 + MIN); // a → 1, b → 2, c → 2
  s = nextRound(s, cards, mulberry32(1), T0 + 2 * MIN);
  expect(s.active).toEqual([a]);
  s = playRound(s, () => true, T0 + 2 * MIN);
  expect(isFinished(s)).toBe(true);
  const stats = finalStats(s);
  expect(stats.total).toBe(3);
  expect(stats.mastered).toBe(3);
  expect(stats.rounds).toBe(3);
  expect(stats.answered).toBe(9);
  expect(stats.accuracy).toBe(6 / 9);
  expect(stats.hardest).toEqual([
    { cardId: a, misses: 2 },
    { cardId: b, misses: 1 },
  ]);
  expect(stats.elapsedMs).toBe(s.elapsedMs);
  expect(stats.elapsedMs).toBeGreaterThan(0);
});

test('finalStats: hardest ties keep the session order, max 10', () => {
  const cards = makeCards(12);
  let s = createLearn(cards, { answerWith: 'term', learn: { roundSize: 12 } }, { rng: mulberry32(14), now: T0 });
  s = playRound(s, () => false, T0);
  const stats = finalStats(s);
  expect(stats.hardest).toHaveLength(10);
  expect(stats.hardest).toEqual(s.order.slice(0, 10).map((cardId) => ({ cardId, misses: 2 })));
  expect(stats.answered).toBe(24);
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

test('a 1-card set is written-only, its retry too', () => {
  const cards = [{ id: 'solo', term: 'le soleil', definition: 'die Sonne' }];
  let s = createLearn(cards, OPTS, { rng: mulberry32(1), now: T0 });
  expect(current(s)).toEqual({ qid: '1.1:solo', cardId: 'solo', type: 'written', ask: 'term' });
  expect(s.queue[0].retryChoices).toBe(undefined);
  s = answer(s, false, T0 + SEC);
  expect(current(s)).toEqual({ qid: '1.2:solo', cardId: 'solo', type: 'written', ask: 'term' });
});

test('multiple choice falls back to written without a valid distractor', () => {
  // Synonyms: both cards show "hässlich", so neither answer can be a distractor for the other.
  const syn = [
    { id: 'a', term: 'laid', definition: 'hässlich' },
    { id: 'b', term: 'moche', definition: 'hässlich' },
  ];
  const s = createLearn(syn, OPTS, { rng: mulberry32(1), now: T0 });
  expect(s.queue.map((q) => q.type)).toEqual(['written', 'written']);
  // Same answer text on both cards (distinct prompts): fewer than 2 distinct answers.
  const same = [
    { id: 'a', term: 'le visage', definition: 'das Gesicht' },
    { id: 'b', term: 'la figure', definition: 'das Gesicht' },
  ];
  expect(createLearn(same, { answerWith: 'definition' }, { rng: mulberry32(1), now: T0 }).queue.map((q) => q.type)).toEqual(['written', 'written']);
  // A third card with its own answer makes multiple choice possible again (2 options each).
  const three = [...same, { id: 'c', term: 'le nez', definition: 'die Nase' }];
  const s3 = createLearn(three, { answerWith: 'definition' }, { rng: mulberry32(1), now: T0 });
  for (const q of s3.queue) {
    expect(q.type).toBe('mc');
    expect(q.choices).toHaveLength(2);
    checkChoices(q, three);
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

test('flag written only: every question is written, retries too', () => {
  const cards = makeCards(5);
  let s = createLearn(cards, { answerWith: 'term', learn: { mc: false, written: true } }, { rng: mulberry32(5), now: T0 });
  for (const q of s.queue) {
    expect(q.type).toBe('written');
    expect(q.choices).toBe(undefined);
    expect(q.retryChoices).toBe(undefined);
  }
  s = answer(s, false, T0 + SEC);
  expect(s.queue[s.queue.length - 1].type).toBe('written');
  s = playRound(s, () => true, T0 + SEC);
  s = nextRound(s, cards, mulberry32(6), T0 + MIN);
  expect(s.queue.every((q) => q.type === 'written')).toBe(true);
});

test('both flags (default): stage 0 multiple choice, stage 1 written', () => {
  const cards = makeCards(6);
  const progress = { c1: progressEntry(1), c2: progressEntry(1), c3: progressEntry(0, 0, 1) };
  const s = createLearn(cards, { answerWith: 'term', learn: { mc: true, written: true } }, { progress, rng: mulberry32(7), now: T0 });
  for (const q of s.queue) expect(q.type).toBe(s.stage[q.cardId] === 1 ? 'written' : 'mc');
});

test('answerWith definition: the definition is asked, options are definitions', () => {
  const cards = makeCards(6);
  const s = createLearn(cards, { answerWith: 'definition' }, { rng: mulberry32(8), now: T0 });
  for (const q of s.queue) {
    expect(q.ask).toBe('definition');
    expect(q.choices.every((c) => c.text.startsWith('Begriff '))).toBe(true);
    checkChoices(q, cards);
  }
});

test("answerWith 'both': ask is picked per question, options and retry follow it", () => {
  const cards = makeCards(8);
  const asks = { term: 0, definition: 0 };
  let mixed = 0;
  for (let seed = 1; seed <= 40; seed++) {
    let s = createLearn(cards, { answerWith: 'both' }, { rng: mulberry32(seed), now: T0 });
    expect(s.answerWith).toBe('both');
    const local = new Set();
    for (const q of s.queue) {
      asks[q.ask]++;
      local.add(q.ask);
      checkChoices(q, cards);
      for (const c of q.retryChoices) expect(c.text).toBe(answerSide(cards.find((x) => x.id === c.cardId), q.ask));
    }
    if (local.size === 2) mixed++;
    const first = current(s);
    s = answer(s, false, T0 + SEC);
    const retry = s.queue[s.queue.length - 1];
    expect(retry.cardId).toBe(first.cardId);
    expect(retry.ask).toBe(first.ask);
    checkChoices(retry, cards);
  }
  expect(asks.term).toBeGreaterThan(100);
  expect(asks.definition).toBeGreaterThan(100);
  expect(mixed).toBeGreaterThan(30);
});

// ---------- override ----------

test('override: a wrong multiple-choice answer becomes correct and its retry is dropped', () => {
  const cards = makeCards(5);
  let s = createLearn(cards, OPTS, { rng: mulberry32(3), now: T0 });
  const id = current(s).cardId;
  s = answer(s, false, T0 + 10 * SEC);
  expect(s.queue).toHaveLength(5);
  const o = override(s, T0 + 15 * SEC);
  expect(o.stage[id]).toBe(1);
  expect(o.queue).toHaveLength(4);
  expect(o.queue.some((q) => q.cardId === id)).toBe(false);
  expect(o.retried).toEqual({});
  expect(o.answered).toBe(1);
  expect(o.correct).toBe(1);
  expect(o.misses[id]).toBe(0);
  expect(o.roundLog).toEqual([{ qid: `1.1:${id}`, cardId: id, type: 'mc', ask: 'term', correct: true, stageAfter: 1 }]);
  expect(o.last).toEqual({ qid: `1.1:${id}`, cardId: id, type: 'mc', ask: 'term', correct: true, stageBefore: 0 });
  expect(o.updatedAt).toBe(T0 + 15 * SEC);
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
  s = answer(s, false, T0 + 10 * SEC);
  expect(s.stage.c3).toBe(0);
  expect(current(s).type).toBe('mc'); // retry
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

test('override of a retry answer keeps the retry flag', () => {
  const cards = makeCards(3);
  let s = createLearn(cards, OPTS, { rng: mulberry32(8), now: T0 });
  const id = current(s).cardId;
  s = playRound(s, (q) => q.cardId !== id, T0); // main wrong, retry wrong
  expect(s.last.qid).toBe(`1.2:${id}`);
  const o = override(s, T0 + MIN);
  expect(o.stage[id]).toBe(1);
  expect(o.retried).toEqual({ [id]: true });
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
  s = answer(s, false, T0 + 10 * SEC); // a wrong → retry queued
  s = answer(s, true, T0 + 20 * SEC); // b correct
  const r = removeCard(s, a, T0 + 30 * SEC);
  expect(r.order).not.toContain(a);
  expect(r.order).toHaveLength(5);
  expect(r.stage[a]).toBe(undefined);
  expect(r.active).not.toContain(a);
  expect(r.queue.some((q) => q.cardId === a)).toBe(false);
  expect(r.queue).toHaveLength(4);
  for (const q of r.queue) {
    expect(q.choices.map((c) => c.cardId)).not.toContain(a);
    expect((q.retryChoices || []).map((c) => c.cardId)).not.toContain(a);
  }
  expect(r.retried).toEqual({});
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
  s = removeCard(s, second, T0 + 2 * SEC);
  expect(current(s).cardId).toBe(third);
  expect(s.queue).toHaveLength(2);
});

test('removeCard drops its option from other questions (mc becomes written below two)', () => {
  const cards = makeCards(3);
  let s = createLearn(cards, OPTS, { rng: mulberry32(4), now: T0 });
  expect(s.queue.every((q) => q.choices.length === 3)).toBe(true);
  const [x, y, z] = s.queue.map((q) => q.cardId);
  s = removeCard(s, x, T0 + SEC);
  expect(s.queue.every((q) => q.type === 'mc' && q.choices.length === 2)).toBe(true);
  s = removeCard(s, y, T0 + 2 * SEC);
  expect(s.queue).toHaveLength(1);
  expect(current(s)).toEqual({ qid: `1.1:${z}`, cardId: z, type: 'written', ask: 'term' });
  expect(s.queue[0].retryChoices).toBe(undefined);
  s = answer(s, false, T0 + 3 * SEC);
  expect(current(s).type).toBe('written');
});

test('removeCard of the last open card finishes the session', () => {
  const cards = makeCards(3);
  const progress = { c1: progressEntry(2), c2: progressEntry(2) };
  let s = createLearn(cards, OPTS, { progress, rng: mulberry32(5), now: T0 });
  expect(s.active).toEqual(['c3']);
  s = removeCard(s, 'c3', T0 + 5 * SEC);
  expect(isFinished(s)).toBe(true);
  expect(s.finishedAt).toBe(T0 + 5 * SEC);
  expect(s.round).toBe(1);
  expect(counts(s)).toEqual({ fresh: 0, learning: 0, mastered: 2, total: 2, progress: 1 });

  // A round that lost every card before any answer: the session ends with the last closed round.
  const two = makeCards(2);
  let t = createLearn(two, { answerWith: 'term', learn: { roundSize: 1 } }, { progress: { c1: progressEntry(1) }, rng: mulberry32(6), now: T0 });
  expect(t.active).toEqual(['c1']);
  t = answer(t, true, T0 + SEC);
  t = nextRound(t, two, mulberry32(7), T0 + 2 * SEC);
  expect(t.round).toBe(2);
  expect(t.active).toEqual(['c2']);
  t = removeCard(t, 'c2', T0 + 3 * SEC);
  expect(isFinished(t)).toBe(true);
  expect(t.round).toBe(1);
  expect(finalStats(t).rounds).toBe(1);
  expect(checkpoint(t).round).toBe(1);
});

test('nextRound drops scope cards that are missing from cards', () => {
  const cards = makeCards(4);
  let s = createLearn(cards, OPTS, { rng: mulberry32(9), now: T0 });
  s = playRound(s, () => true, T0);
  const gone = s.order[0];
  const left = cards.filter((c) => c.id !== gone);
  s = nextRound(s, left, mulberry32(10), T0 + MIN);
  expect(s.order).not.toContain(gone);
  expect(s.active).not.toContain(gone);
  expect(s.queue).toHaveLength(3);
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
  let s = createLearn(cards, OPTS, { rng: mulberry32(1), now: T0 });
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
  // An open card that fell out of the batch is picked up again by nextRound.
  const stuck = { order: ['a'], stage: { a: 0 }, active: [], queue: [], round: 1 };
  expect(isRoundOver(stuck)).toBe(true);
  const refilled = nextRound(stuck, [{ id: 'a', term: 'oui', definition: 'ja' }], mulberry32(1), T0);
  expect(refilled.round).toBe(1);
  expect(refilled.rounds).toEqual([]);
  expect(refilled.active).toEqual(['a']);
  expect(current(refilled)).toEqual({ qid: '1.1:a', cardId: 'a', type: 'written', ask: 'term' });
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
    for (const q of r.queue) {
      const ids = q.choices.map((c) => c.cardId);
      expect(ids).not.toContain(gone);
      expect(new Set(ids).size).toBe(ids.length);
      // Five cards minus the removed one leave exactly four possible options.
      expect(ids).toHaveLength(4);
      expect(sorted(ids)).toEqual(sorted(cards.filter((c) => c.id !== gone).map((c) => c.id)));
    }
  }
  // Four cards: every option is in use, so removing one leaves three.
  const four = makeCards(4);
  const t = createLearn(four, OPTS, { rng: mulberry32(24), now: T0 });
  const out = t.queue[0].choices.find((c) => c.cardId !== t.queue[0].cardId).cardId;
  const r = removeCard(t, out, T0 + SEC, { cards: four.filter((c) => c.id !== out), rng: mulberry32(25) });
  expect(r.queue.every((q) => q.choices.length === 3)).toBe(true);
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
  const progress = { c6: recorded(true) }; // familiar → written
  let s = createLearn(cards, OPTS, { progress, rng: mulberry32(31), now: T0 });
  expect(matchesProgress(s, progress)).toBe(true);
  const first = current(s);
  s = answer(s, true, T0 + SEC);
  progress[first.cardId] = recorded(true); // what Learn records itself
  expect(matchesProgress(s, progress)).toBe(true);
  expect(s.stage[first.cardId]).toBe(1);

  // Write: the card Learn just got right is answered wrong → back to multiple choice.
  progress[first.cardId] = applyAnswer(progress[first.cardId], false, T0);
  expect(matchesProgress(s, progress)).toBe(false);
  let r = syncProgress(s, progress, T0 + 2 * SEC);
  expect(r.stage[first.cardId]).toBe(0);
  expect(counts(r).learning).toBe(counts(s).learning);

  // Write: a queued multiple choice card is answered right → its question becomes written.
  const mcQ = r.queue.find((q) => q.type === 'mc');
  progress[mcQ.cardId] = recorded(true);
  // Write: a queued written card (stage 1) is answered wrong → its question becomes multiple choice.
  const wQ = r.queue.find((q) => q.cardId === 'c6');
  expect(wQ.type).toBe('written');
  progress.c6 = applyAnswer(progress.c6, false, T0);
  // Write: another queued card is mastered → it leaves the round and the batch.
  const done = r.queue.find((q) => q.type === 'mc' && q.cardId !== mcQ.cardId);
  progress[done.cardId] = recorded(true, true);
  r = syncProgress(r, progress, T0 + 3 * SEC);
  expect(matchesProgress(r, progress)).toBe(true);
  const nowMc = r.queue.find((q) => q.qid === mcQ.qid);
  expect(nowMc).toEqual({ qid: mcQ.qid, cardId: mcQ.cardId, type: 'written', ask: mcQ.ask, retryChoices: mcQ.retryChoices });
  const nowW = r.queue.find((q) => q.qid === wQ.qid);
  expect(nowW.type).toBe('mc');
  expect(nowW.choices).toEqual(wQ.retryChoices);
  checkChoices(nowW, cards);
  expect(r.queue.some((q) => q.cardId === done.cardId)).toBe(false);
  expect(r.active).not.toContain(done.cardId);
  expect(r.stage[done.cardId]).toBe(2);
  expect(counts(r).mastered).toBe(1);
  // Nothing else changed, and a second sync is a no-op.
  expect(r.answered).toBe(1);
  expect(r.roundLog).toEqual(s.roundLog);
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
  expect(s.active).not.toContain('c1');
  progress.c1 = applyAnswer(progress.c1, false, T0);
  s = syncProgress(s, progress, T0 + SEC);
  expect(s.stage.c1).toBe(0);
  expect(s.initiallyMastered).toEqual([]);
  expect(s.queue.some((q) => q.cardId === 'c1')).toBe(false); // not in this round
  expect(counts(s)).toEqual({ fresh: 3, learning: 1, mastered: 0, total: 4, progress: 0 });
  s = playRound(s, () => true, T0 + SEC);
  s = nextRound(s, cards, mulberry32(33), T0 + MIN);
  const q = s.queue.find((x) => x.cardId === 'c1');
  expect(q.type).toBe('mc');
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
  // The progress is reset in another tab.
  const r = syncProgress(s, {}, T0 + 3 * SEC);
  expect(counts(r)).toEqual({ fresh: 4, learning: 0, mastered: 0, total: 4, progress: 0 });
  expect(r.queue.every((x) => x.type === 'mc')).toBe(true);
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

test('repetition questions are recognised by their id; reviewsPerRound is max(1, roundSize / 3)', () => {
  expect(isReviewQuestion('1.3:c1')).toBe(true);
  expect(isReviewQuestion('12.3:a:b')).toBe(true);
  for (const qid of ['1.1:c1', '1.2:c1', '.3:c1', 'x.3:c1', '1.q3:c1', '13', '1.33:c1', '', null, undefined, 3]) {
    expect(isReviewQuestion(qid)).toBe(false);
  }
  expect(reviewsPerRound(7)).toBe(2);
  expect(reviewsPerRound(5)).toBe(1);
  expect(reviewsPerRound(1)).toBe(1);
  expect(reviewsPerRound(15)).toBe(5);
  expect(reviewsPerRound(undefined)).toBe(1);
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

test('review: a few repetition questions join each round, the most overdue first', () => {
  const cards = makeCards(10);
  // c1…c6 mastered (c1 answered longest ago), c7…c10 new.
  const s = createReview(cards, { progress: masteredProgress(cards.slice(0, 6)) });
  expect(s.review.due).toEqual(['c3', 'c4', 'c5', 'c6']);
  const reviews = s.queue.filter((q) => isReviewQuestion(q.qid));
  expect(sorted(reviews.map((q) => q.cardId))).toEqual(['c1', 'c2']);
  expect(s.queue).toHaveLength(4 + 2);
  // Mastered cards are asked written, with options ready for a retry.
  for (const q of reviews) {
    expect(q.type).toBe('written');
    expect(Array.isArray(q.retryChoices)).toBe(true);
    expect(q.qid).toBe(`1.3:${q.cardId}`);
  }
  expect(isFinished(s)).toBe(false);
  expect(reviewStats(s)).toEqual({ asked: 0, kept: 0, left: 6 });
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
  // Asked once more at the end of the round, as multiple choice.
  const retry = s.queue[s.queue.length - 1];
  expect(retry.cardId).toBe(first.cardId);
  expect(retry.qid).toBe(`1.2:${first.cardId}`);
  expect(isReviewQuestion(retry.qid)).toBe(false);
  expect(retry.type).toBe('mc');
  expect(counts(s).mastered).toBe(5);
  // What the store records for it: no longer mastered.
  const stored = applyAnswer(progress[first.cardId], false, T0 + SEC);
  expect(cardStatus(stored)).toBe('learning');
  expect(reviewStats(s)).toEqual({ asked: 1, kept: 0, left: 5 });
});

test('review: a missed card is learned again until it is mastered', () => {
  const cards = makeCards(4);
  let s = createReview(cards, { progress: masteredProgress(cards), roundSize: 7 });
  const missed = current(s).cardId;
  let first = true;
  s = playAll(s, () => {
    const ok = !first;
    first = false;
    return ok;
  });
  // The retry was right: stage 1, so the card comes back in the next round, written.
  expect(s.stage[missed]).toBe(1);
  expect(isFinished(s)).toBe(false);
  s = nextRound(s, cards, mulberry32(9), T0 + MIN);
  expect(s.active).toEqual([missed]);
  expect(s.queue.map((q) => q.cardId)).toEqual([missed]);
  expect(isReviewQuestion(s.queue[0].qid)).toBe(false);
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
  expect(s.review.results[q.cardId]).toBe(false);
  expect(reviewStats(s).kept).toBe(2);
  // Overriding the retry (not the repetition question) leaves the result alone.
  let t = createReview(cards, { progress: masteredProgress(cards), roundSize: 7, seed: 8 });
  const r = current(t);
  t = answer(t, false, T0 + SEC);
  while (current(t).cardId !== r.cardId) t = answer(t, true, T0 + 2 * SEC);
  expect(isReviewQuestion(current(t).qid)).toBe(false);
  t = answer(t, false, T0 + 3 * SEC);
  t = override(t, T0 + 4 * SEC);
  expect(t.review.results[r.cardId]).toBe(false);
  expect(t.initiallyMastered).not.toContain(r.cardId);
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
  s = playAll(s, () => true, T0 + 600);
  s = nextRound(s, cards, mulberry32(5), T0 + MIN);
  expect(s.active).toContain('c5');
  expect(s.review.due).not.toContain('c5');
  expect(s.queue.some((q) => q.cardId === 'c5' && isReviewQuestion(q.qid))).toBe(false);
});

test('review: a queued repetition question of a card missed elsewhere becomes an ordinary question', () => {
  const cards = makeCards(8);
  const progress = masteredProgress(cards.slice(0, 6));
  let s = createReview(cards, { progress });
  const [id] = reviewIds(s);
  const qid = s.queue.find((q) => q.cardId === id).qid;
  progress[id] = applyAnswer(progress[id], false, T0 + 500);
  s = syncProgress(s, progress, T0 + 600);
  const q = s.queue.find((x) => x.cardId === id);
  // Same place in the round, asked as multiple choice now, no longer a repetition.
  expect(q.qid).toBe(qid.replace('.3:', '.1:'));
  expect(q.type).toBe('mc');
  checkChoices(q, cards);
  expect(s.initiallyMastered).not.toContain(id);
  expect(reviewStats(s).left).toBe(5);
  s = playAll(s, () => true, T0 + 600);
  expect(id in s.review.results).toBe(false);
  expect(reviewStats(s)).toEqual({ asked: 1, kept: 1, left: 4 });
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
  expect(s.stage[missed]).toBe(1); // missed, then right in the retry
  // A reload: the stored JSON continues identically, nothing to reconcile.
  const stored = JSON.parse(JSON.stringify(s));
  expect(matchesProgress(stored, progress)).toBe(true);
  expect(snapshot(syncProgress(stored, progress, t + SEC))).toBe(snapshot(tick(stored, NaN)));
  const a = nextRound(s, cards, mulberry32(6), t + MIN);
  const b = nextRound(stored, cards, mulberry32(6), t + MIN);
  expect(snapshot(b)).toBe(snapshot(a));
  expect(reviewIds(b)).toHaveLength(2);
  expect(b.active).toContain(missed);
  expect(reviewStats(b)).toEqual({ asked: 2, kept: 1, left: 3 });
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
  expect(sorted(s.active)).toEqual(['c6', 'c7']);
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

await run('learn.test.js');
