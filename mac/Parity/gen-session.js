// Parity fixture for src/core/session.js (Write mode) → Fixtures/session.json.
//
// fns:
//   scenario [cards, options, create, actions] → snapshots: one after createSession, then one
//            after every action.
//   restore  [raw, seed, actions] → snapshots: one of the stored state `raw` as the engine reads
//            it (tick(raw, null) is copyState(raw)), then one after every action.
// snapshot = {state, current, counters, roundSummary, isRoundOver, isFinished, finalStats}
// create   = {seed, now, subset?, progress?}: the engine rng is mulberry32(seed), created once
//            per case and shared by createSession and every nextRound (restore: mulberry32(seed)
//            for every nextRound); an action may carry its own `seed` for a fresh mulberry32.
// actions  = {op:'answer', correct, now} | {op:'override', qid, now} | {op:'nextRound', now, seed?}
//          | {op:'removeCard', cardId, now} | {op:'tick', now};
//            now = epoch ms, or null for "not a number" (the clock is left alone).
// cards, options, subset, progress and raw are handed to the JS as they are (junk included). The
// Swift test converts them at the typed API boundary the way createSession reads them, and raw
// states go through WriteSession.copyState(JSONValue).
//
// Junk deliberately avoided (documented divergences of the typed Swift port, see
// WriteSession.swift): fractional counts, numbers beyond 2^53, ids differing only in Unicode
// normalisation, nested arrays/objects as subset card ids, non-empty arrays as progress maps,
// and qids missing from `order` in unshuffled states.
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
} from '../../Website/src/core/session.js';
import { Cases, mulberry32, randInt, pick, chance } from './lib.js';

const cases = new Cases('session');

const T0 = 1760000000000;
const SEC = 1000;
const MIN = 60 * SEC;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const ORDERED = { answerWith: 'term', shuffle: false };

// ---------------------------------------------------------------------------
// Recording

function snap(s) {
  return {
    state: tick(s, null),
    current: current(s),
    counters: counters(s),
    roundSummary: roundSummary(s),
    isRoundOver: isRoundOver(s),
    isFinished: isFinished(s),
    finalStats: finalStats(s),
  };
}

function apply(s, a, rng) {
  switch (a.op) {
    case 'answer':
      return answer(s, a.correct, a.now);
    case 'override':
      return override(s, a.qid, a.now);
    case 'nextRound':
      return nextRound(s, 'seed' in a ? mulberry32(a.seed) : rng, a.now);
    case 'removeCard':
      return removeCard(s, a.cardId, a.now);
    case 'tick':
      return tick(s, a.now);
    default:
      throw new Error(`unknown op ${a.op}`);
  }
}

// Never pass `undefined` as now: the JS would fall back to Date.now() (not deterministic).
function checkNow(a) {
  if (a.now === undefined) throw new Error(`action without an explicit now: ${JSON.stringify(a)}`);
}

class Run {
  constructor(cards, options, create) {
    this.args = [cards, options, create];
    this.rng = mulberry32(create.seed);
    const opts = { rng: this.rng, now: create.now };
    if ('subset' in create) opts.subset = create.subset;
    if ('progress' in create) opts.progress = create.progress;
    this.s = createSession(cards, options, opts);
    this.t = typeof create.now === 'number' ? create.now : T0;
    this.actions = [];
    this.snaps = [snap(this.s)];
  }

  do(a) {
    checkNow(a);
    this.s = apply(this.s, a, this.rng);
    this.actions.push(a);
    this.snaps.push(snap(this.s));
    return this.s;
  }

  emit() {
    cases.add('scenario', [...this.args, this.actions], this.snaps);
  }
}

class RestoreRun {
  constructor(raw, seed) {
    this.raw = raw;
    this.seed = seed;
    this.rng = mulberry32(seed);
    this.s = tick(raw, null);
    this.t = typeof this.s.updatedAt === 'number' ? this.s.updatedAt : T0;
    this.actions = [];
    this.snaps = [snap(raw)];
  }

  do(a) {
    checkNow(a);
    this.s = apply(this.s, a, this.rng);
    this.actions.push(a);
    this.snaps.push(snap(this.s));
    return this.s;
  }

  emit() {
    cases.add('restore', [this.raw, this.seed, this.actions], this.snaps);
  }
}

function scenario(cards, options, create, actions) {
  const run = new Run(cards, options, create);
  for (const a of actions) run.do(a);
  run.emit();
  return run;
}

const ans = (correct, now) => ({ op: 'answer', correct, now });
const nr = (now, seed) => (seed === undefined ? { op: 'nextRound', now } : { op: 'nextRound', now, seed });
const ov = (qid, now) => ({ op: 'override', qid, now });
const rm = (cardId, now) => ({ op: 'removeCard', cardId, now });
const tk = (now) => ({ op: 'tick', now });
// Answers with each result, 10 s apart (answerSeq of tests/session.test.js).
const seq = (results, startAt = T0) => results.map((r, i) => ans(r, startAt + (i + 1) * 10 * SEC));

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

// ---------------------------------------------------------------------------
// 1. Every scenario of tests/session.test.js

const at = { seed: 1, now: T0 };

// creation
scenario(makeCards(4), ORDERED, at, []);
scenario(makeCards(3), { answerWith: 'definition', shuffle: false }, at, []);
scenario(makeCards(3), { answerWith: 'both', shuffle: false }, at, []);
for (const seed of [42, 7]) scenario(makeCards(20), { answerWith: 'term', shuffle: true }, { seed, now: T0 }, []);
scenario(makeCards(6), ORDERED, at, []);
for (let n = 2; n <= 6; n++) {
  for (let seed = 1; seed <= 30; seed++) {
    scenario(makeCards(n), { answerWith: 'both', shuffle: true }, { seed, now: T0 }, []);
  }
}
scenario(makeCards(3), null, { seed: 3, now: T0 }, []);
scenario(makeCards(3), { answerWith: 'bogus', shuffle: false }, at, []);
scenario(
  [
    { id: 'a', term: 'la rue', definition: 'die Strasse' },
    { id: 'b', term: '  ', definition: 'leer' },
    { id: 'c', term: 'le nom', definition: '' },
    { id: 'a', term: 'dup', definition: 'Duplikat' },
    null,
    { term: 'ohne id', definition: 'x' },
    { id: 'd', term: 'calme', definition: 'ruhig' },
  ],
  ORDERED,
  at,
  [],
);
scenario(null, ORDERED, at, []);

// subsets
scenario(makeCards(7), ORDERED, { ...at, subset: 'starred' }, []);
const learningProgress = {
  c1: progressEntry(2, 2, 0, 'correct'),
  c2: progressEntry(1, 1, 1, 'correct'),
  c3: progressEntry(0, 0, 1, 'incorrect'),
  c5: progressEntry(3, 4, 1, 'correct'),
};
scenario(makeCards(5), ORDERED, { ...at, subset: 'learning', progress: learningProgress }, []);
scenario(makeCards(2), ORDERED, { ...at, subset: 'learning' }, []);
scenario(makeCards(6), ORDERED, { ...at, subset: { cardIds: ['c5', 'x9', 'c2', 'c5'] } }, []);
scenario(makeCards(6), { answerWith: 'both', shuffle: false }, { ...at, subset: { cardIds: ['c3'] } }, []);
const missedProgress = { c2: progressEntry(0, 1, 1, 'incorrect'), c3: progressEntry(1, 1, 1, 'correct') };
scenario(makeCards(4), ORDERED, { ...at, subset: 'missed', progress: missedProgress }, []);
scenario(makeCards(2), ORDERED, { ...at, subset: 'whatever' }, []);
scenario(
  makeCards(2).map((c) => ({ ...c, starred: false })),
  ORDERED,
  { ...at, subset: 'starred' },
  [ans(true, T0 + SEC), nr(T0 + SEC, 1), tk(T0 + 2 * SEC), ov('c1:t', T0 + 3 * SEC), rm('c1', T0 + 4 * SEC)],
);
scenario(makeCards(3), ORDERED, { ...at, subset: { cardIds: [] } }, []);

// answering & counters
scenario(makeCards(4), ORDERED, at, [...seq([true, false, true, false]), ans(true, T0 + 50 * SEC)]);
scenario(makeCards(4), ORDERED, at, [
  ans(true, T0 + SEC),
  ans(false, T0 + 2 * SEC),
  ans(false, T0 + 3 * SEC),
  ans(true, T0 + 4 * SEC),
  nr(T0 + 5 * SEC, 1),
  ans(false, T0 + 6 * SEC),
  ans(true, T0 + 7 * SEC),
  nr(T0 + 8 * SEC, 1),
  ans(true, T0 + 9 * SEC),
]);
scenario(makeCards(4), { answerWith: 'definition', shuffle: false }, at, seq([true, false, true, false]));
scenario(makeCards(4), ORDERED, at, seq([false]));

// rounds
scenario(makeCards(5), ORDERED, at, [...seq([true, false, true, false, false]), nr(T0 + MIN, 9)]);
scenario(makeCards(12), { answerWith: 'term', shuffle: true }, { seed: 5, now: T0 }, [
  ...seq([false, true, true, false, true, false, false, true, true, true, false, true]),
  nr(T0 + MIN, 77),
]);
for (let seed = 1; seed <= 20; seed++) {
  scenario(makeCards(4), { answerWith: 'both', shuffle: true }, { seed, now: T0 }, [
    ...seq(new Array(8).fill(false)),
    nr(T0 + MIN, seed + 1000),
  ]);
}
scenario(makeCards(3), ORDERED, at, [...seq([false]), nr(T0 + MIN, 1)]);
scenario(makeCards(4), ORDERED, at, [
  ...seq([true, false, false, true], T0),
  nr(T0 + MIN, 1),
  ...seq([true, false], T0 + MIN),
  nr(T0 + 2 * MIN, 1),
  ans(true, T0 + 2 * MIN + 5 * SEC),
  nr(T0 + 3 * MIN, 1),
  nr(T0 + 4 * MIN, 1),
]);
scenario(makeCards(3), ORDERED, at, [...seq([true, true, true]), nr(T0 + MIN, 1)]);

// override
scenario(makeCards(3), ORDERED, at, [
  ...seq([false, false]),
  ov('c2:t', T0 + 25 * SEC),
  ov('c2:t', T0 + 26 * SEC),
  ans(true, T0 + 30 * SEC),
  nr(T0 + MIN, 1),
]);
scenario(makeCards(2), ORDERED, at, [
  ...seq([false, true]),
  nr(T0 + MIN, 1),
  ans(false, T0 + MIN + 5 * SEC),
  ov('c1:t', T0 + MIN + 8 * SEC),
]);
scenario(makeCards(4), ORDERED, at, [...seq([true, false, true, false]), ov('c4:t', T0 + MIN), nr(T0 + 2 * MIN, 1)]);
scenario(makeCards(3), ORDERED, at, [...seq([true, true, false]), ov('c3:t', T0 + MIN), nr(T0 + 2 * MIN, 1)]);
scenario(makeCards(4), ORDERED, at, [
  ...seq([false, true, false, true]),
  nr(T0 + MIN, 1),
  ov('c3:t', T0 + MIN + SEC),
  ov('c1:t', T0 + MIN + 2 * SEC),
  nr(T0 + 2 * MIN, 1),
]);
const noopBase = [
  ...seq([true, false]),
  ov('c1:t', T0 + MIN),
  ov('c3:t', T0 + MIN),
  ov('zz:t', T0 + MIN),
  ov('', T0 + MIN),
  ...seq([true, true], T0 + 20 * SEC),
  nr(T0 + MIN, 1),
  ans(false, T0 + MIN + SEC),
  nr(T0 + 2 * MIN, 1),
];
scenario(makeCards(4), ORDERED, at, [...noopBase, ov('c2:t', T0 + 2 * MIN + SEC)]);
scenario(makeCards(4), ORDERED, at, [...noopBase, ans(false, T0 + 2 * MIN + SEC), ov('c2:t', T0 + 2 * MIN + 2 * SEC)]);

// final stats
scenario(makeCards(5), ORDERED, at, [
  ...seq([false, true, false, false, true]),
  nr(T0 + MIN, 1),
  ...seq([true, false, false], T0 + MIN),
  nr(T0 + 2 * MIN, 1),
  ...seq([true, false], T0 + 2 * MIN),
  nr(T0 + 3 * MIN, 1),
  ans(true, T0 + 3 * MIN + 10 * SEC),
]);
{
  const both12 = createSession(makeCards(12), { answerWith: 'both', shuffle: false }, { now: T0 });
  scenario(makeCards(12), { answerWith: 'both', shuffle: false }, at, seq(both12.order.map((q) => q.endsWith(':d') && q !== 'c12:d')));
}

// removeCard
scenario(makeCards(4), { answerWith: 'both', shuffle: false }, at, [...seq([true, false, true]), rm('c2', T0 + MIN)]);
scenario(makeCards(4), { answerWith: 'both', shuffle: false }, at, [...seq([true, false, true]), rm('nope', T0 + MIN)]);
scenario(makeCards(3), ORDERED, at, [...seq([false]), rm('c2', T0 + MIN)]);
scenario(makeCards(4), ORDERED, at, [
  ...seq([true, false, false, true]),
  nr(T0 + MIN, 1),
  ...seq([true, false], T0 + MIN),
  nr(T0 + 2 * MIN, 1),
  rm('c2', T0 + 2 * MIN + SEC),
  rm('c3', T0 + 2 * MIN + 2 * SEC),
]);
scenario(makeCards(2), ORDERED, at, [...seq([false]), rm('c1', T0 + MIN), rm('c2', T0 + MIN)]);

// time
{
  const t1 = T0 + 30 * SEC + 5 * MIN + 2 * HOUR;
  scenario(makeCards(2), ORDERED, at, [
    tk(T0 + 30 * SEC),
    tk(T0 + 30 * SEC + 5 * MIN),
    tk(t1),
    tk(t1 + 10 * SEC),
    tk(t1),
    tk(null),
  ]);
}
scenario(makeCards(2), ORDERED, at, [ans(true, T0 + 12 * SEC), ans(true, T0 + 20 * SEC), tk(T0 + 60 * SEC)]);

// JSON round trip: the step function of the test, played until finished.
{
  const decide = mulberry32(99);
  const outcomes = Array.from({ length: 200 }, () => decide() < 0.55);
  const run = new Run(makeCards(8), { answerWith: 'both', shuffle: true }, { seed: 11, now: T0 });
  let k = 0;
  let t = T0;
  for (let guard = 0; !isFinished(run.s) && guard < 500; guard++) {
    t += 7 * SEC;
    run.do(isRoundOver(run.s) ? nr(t, t) : ans(outcomes[k++ % outcomes.length], t));
  }
  run.do(nr(t + 7 * SEC, t + 7 * SEC));
  run.emit();
}

// Immutability test: every operation on the same mid-round state.
{
  const base = seq([true, false, true, false]);
  const probe = new Run(makeCards(5), { answerWith: 'both', shuffle: true }, { seed: 3, now: T0 });
  for (const a of base) probe.do(a);
  const qid = probe.s.roundAnswered[1].qid;
  const cardId = probe.s.questions[qid].cardId;
  for (const extra of [
    [ans(true, T0 + MIN)],
    [ans(false, T0 + MIN)],
    [ov(qid, T0 + MIN)],
    [rm(cardId, T0 + MIN)],
    [tk(T0 + MIN)],
    [...new Array(6).fill(ans(false, T0 + 2 * MIN)), nr(T0 + 3 * MIN, 5)],
  ]) {
    scenario(makeCards(5), { answerWith: 'both', shuffle: true }, { seed: 3, now: T0 }, [...base, ...extra]);
  }
}

// Simulation: random play until finished (the test's loop, with its own decision rng).
for (let seed = 1; seed <= 16; seed++) {
  const d = mulberry32(seed + 5000);
  const answerWith = ['term', 'definition', 'both'][seed % 3];
  const shuffle = seed % 2 === 0;
  const run = new Run(makeCards(2 + (seed % 6)), { answerWith, shuffle }, { seed, now: T0 });
  let t = T0;
  for (let guard = 0; !isFinished(run.s) && guard < 2000; guard++) {
    t += 3 * SEC;
    if (isRoundOver(run.s)) {
      run.do(nr(t));
      continue;
    }
    run.do(ans(d() < 0.6, t));
    const last = run.s.roundAnswered[run.s.roundAnswered.length - 1];
    if (d() < 0.1 && !last.correct) run.do(ov(last.qid, t));
  }
  run.do(nr(t + SEC));
  run.emit();
}

// ---------------------------------------------------------------------------
// 2. Seeded fuzz: decks, options, subsets and random action sequences

const BLANKS = ['', ' ', '  ', '\t', '\n', '\r\n', ' ', '　', '﻿', ' ', '   '];
// Not whitespace for JS `trim()`: NEL, zero-width space, word joiner.
const TEXTY = ['\u0085', '​', '⁠', 'x', 'é', ' a ', 'l’été'];
const NON_STRINGS = [5, 0, null, true, false, {}, ['x']];

function fuzzCards(d, n) {
  const cards = [];
  for (let i = 1; i <= n; i++) {
    const c = { id: `c${i}`, term: `terme ${i}`, definition: `Begriff ${i}`, starred: i % 3 === 1 };
    const r = d();
    if (r < 0.05) c.term = pick(d, BLANKS);
    else if (r < 0.1) c.definition = pick(d, BLANKS);
    else if (r < 0.13) c[chance(d, 0.5) ? 'term' : 'definition'] = pick(d, TEXTY);
    else if (r < 0.16) c[chance(d, 0.5) ? 'term' : 'definition'] = pick(d, NON_STRINGS);
    else if (r < 0.2) c.id = pick(d, [i * 100, i + 0.5, true, -i]);
    else if (r < 0.23) {
      if (chance(d, 0.5)) delete c.id;
      else c.id = pick(d, [null, '']);
    } else if (r < 0.28) c.id = `c${randInt(d, 1, i)}`;
    if (chance(d, 0.12)) {
      if (chance(d, 0.25)) delete c.starred;
      else c.starred = pick(d, ['yes', 1, null, false, true]);
    }
    if (chance(d, 0.05)) delete c.term;
    cards.push(c);
    if (chance(d, 0.04)) cards.push(pick(d, [null, 'x', 7, [], {}, { id: 'junk' }]));
  }
  return cards;
}

// The ids createSession sees (String(raw.id) of the usable entries).
function cardIdsOf(cards) {
  if (!Array.isArray(cards)) return [];
  return cards.filter((c) => c && typeof c === 'object' && c.id != null && c.id !== '').map((c) => String(c.id));
}

const PROGRESS = [
  () => ({ correct: 2, incorrect: 0, streak: 2, streakBefore: 1, lastResult: 'correct', lastAnsweredAt: T0 - 1000 }),
  () => ({ correct: 4, incorrect: 1, streak: 3, streakBefore: 2, lastResult: 'correct', lastAnsweredAt: T0 - 5000 }),
  () => ({ correct: 1, incorrect: 1, streak: 1, streakBefore: 0, lastResult: 'correct', lastAnsweredAt: T0 - 2000 }),
  () => ({ correct: 0, incorrect: 1, streak: 0, streakBefore: 0, lastResult: 'incorrect', lastAnsweredAt: T0 - 3000 }),
  () => ({ correct: 3, incorrect: 2, streak: 0, streakBefore: 2, lastResult: 'incorrect', lastAnsweredAt: T0 - 4000 }),
  () => ({ correct: 0, incorrect: 0, streak: 0, streakBefore: 0, lastResult: null, lastAnsweredAt: null }),
  () => ({ lastResult: 'incorrect' }),
  () => ({ lastResult: 'INCORRECT', incorrect: 2 }),
  () => ({ streak: 2 }),
  () => ({ streak: '2', correct: 1 }),
  () => ({ streak: 2.7, lastResult: 'correct' }),
  () => ({ streak: -4, correct: -1, incorrect: 3, lastResult: 'incorrect' }),
  () => 'x',
  () => null,
  () => 5,
  () => [],
];

function fuzzProgress(d, ids) {
  const r = d();
  if (r < 0.05) return pick(d, [null, 'x', [], 5]);
  const p = {};
  for (const id of ids) if (chance(d, 0.75)) p[id] = pick(d, PROGRESS)();
  if (chance(d, 0.3)) p.ghost = PROGRESS[0]();
  return p;
}

const SMALL_GAPS = [1, 250, 2 * SEC, 3 * SEC, 4 * SEC, 5 * SEC, 7 * SEC, 8 * SEC, 10 * SEC, 12 * SEC, 15 * SEC, 20 * SEC, 30 * SEC];
const SPECIAL_GAPS = [0, 0.5, 1500.25, MIN, 2 * MIN, 299999, 5 * MIN, 5 * MIN + 1, 6 * MIN, 20 * MIN, 2 * HOUR, DAY, 3 * DAY, -10 * SEC, -1];

function advance(d, t) {
  return t + (chance(d, 0.8) ? pick(d, SMALL_GAPS) : pick(d, SPECIAL_GAPS));
}

function pickQid(d, s, ids) {
  const r = d();
  const ra = s.roundAnswered;
  const wrong = ra.filter((a) => !a.correct);
  const last = s.rounds[s.rounds.length - 1];
  if (r < 0.35 && ra.length) return ra[ra.length - 1].qid;
  if (r < 0.55 && wrong.length) return pick(d, wrong).qid;
  if (r < 0.62 && ra.length) return pick(d, ra).qid;
  if (r < 0.8 && last && last.incorrectQids.length) return pick(d, last.incorrectQids);
  if (r < 0.9 && s.order.length) return pick(d, s.order);
  if (r < 0.96 && ids.length) return `${pick(d, ids)}:${chance(d, 0.5) ? 't' : 'd'}`;
  return pick(d, ['zz:t', '', 'c1', ':t', 'c1:x']);
}

function pickCardId(d, s, ids) {
  const r = d();
  const cur = current(s);
  if (r < 0.3 && cur) return cur.cardId;
  const last = s.rounds[s.rounds.length - 1];
  const missed = s.roundAnswered.filter((a) => !a.correct).map((a) => a.qid).concat(last ? last.incorrectQids : []);
  if (r < 0.5 && missed.length) return s.questions[pick(d, missed)].cardId;
  if (r < 0.65 && s.done.length) return s.questions[pick(d, s.done)].cardId;
  if (r < 0.92 && ids.length) return pick(d, ids);
  return pick(d, ['nope', '', 'c', 'c1:t']);
}

function randomAction(d, s, t, ids, pCorrect) {
  const now = chance(d, 0.03) ? null : t;
  const r = d();
  if (!isRoundOver(s)) {
    if (r < 0.74) return ans(d() < pCorrect, now);
    if (r < 0.84) return ov(pickQid(d, s, ids), now);
    if (r < 0.89) return tk(now);
    if (r < 0.94) return rm(pickCardId(d, s, ids), now);
    return nr(now);
  }
  if (r < 0.55) return chance(d, 0.15) ? nr(now, randInt(d, 0, 0xffffffff)) : nr(now);
  if (r < 0.77) return ov(pickQid(d, s, ids), now);
  if (r < 0.85) return tk(now);
  if (r < 0.93) return rm(pickCardId(d, s, ids), now);
  return ans(d() < 0.5, now);
}

// Plays random actions; stops a few actions after the session finished, or after maxSteps.
function play(d, run, ids, maxSteps, pCorrect) {
  let t = run.t;
  let extra = -1;
  for (let i = 0; i < maxSteps; i++) {
    t = advance(d, t);
    run.do(randomAction(d, run.s, t, ids, pCorrect));
    if (isFinished(run.s)) {
      if (extra === -1) extra = randInt(d, 0, 3);
      if (extra-- === 0) break;
    }
  }
}

const ANSWER_WITH = ['term', 'definition', 'both', 'bogus', undefined];
const SHUFFLES = [true, false, undefined];
const SUBSETS = [
  'all',
  'starred',
  'learning',
  'missed',
  'whatever',
  null,
  undefined,
  { cardIds: ['c2', 'c5', 'x9', 'c2'] },
  { cardIds: [] },
  { cardIds: 'c1' },
  [],
  { cardIds: [null, '', 5, 'c3', true, 100, 'c1'] },
  { cardIds: ['c1'] },
];

// 2a. Matrix: every answerWith × shuffle × subset, each with a fuzzed deck and a short random play.
{
  const d = mulberry32(20261012);
  let seed = 1000;
  for (const answerWith of ANSWER_WITH) {
    for (const shuffle of SHUFFLES) {
      for (const subset of SUBSETS) {
        const n = randInt(d, 0, 7);
        const cards = fuzzCards(d, n);
        const options = {};
        if (answerWith !== undefined) options.answerWith = answerWith;
        if (shuffle !== undefined) options.shuffle = shuffle;
        else if (chance(d, 0.5)) options.shuffle = pick(d, [0, null, 'false', 1]);
        const create = { seed: seed++, now: chance(d, 0.05) ? null : T0 + randInt(d, 0, 1000) * 7.5 };
        if (subset !== undefined) create.subset = subset;
        if (subset === 'learning' || subset === 'missed' || chance(d, 0.3)) {
          create.progress = fuzzProgress(d, cardIdsOf(cards));
        }
        const run = new Run(cards, options, create);
        play(d, run, cardIdsOf(cards), randInt(d, 2, 10), 0.3 + d() * 0.6);
        run.emit();
      }
    }
  }
}

// 2b. Odd option objects.
{
  const d = mulberry32(77);
  for (const options of [null, 'x', [], 5, {}, { answerWith: 'both' }, { shuffle: false }, { answerWith: 'definition', shuffle: 0 }]) {
    const cards = makeCards(randInt(d, 2, 5));
    const run = new Run(cards, options, { seed: randInt(d, 1, 999), now: T0 });
    play(d, run, cardIdsOf(cards), 6, 0.5);
    run.emit();
  }
}

// 2c. Long random plays until the session is finished (and closed).
{
  const d = mulberry32(424242);
  for (let k = 0; k < 110; k++) {
    const n = randInt(d, 1, 6);
    const cards = chance(d, 0.6) ? makeCards(n) : fuzzCards(d, n);
    const options = { answerWith: pick(d, ['term', 'definition', 'both']), shuffle: chance(d, 0.6) };
    const create = { seed: randInt(d, 0, 0xffffffff), now: T0 + randInt(d, 0, 100) * MIN };
    if (chance(d, 0.25)) {
      create.subset = pick(d, ['starred', 'learning', 'missed', { cardIds: ['c1', 'c2', 'c4', 'c6'] }]);
      create.progress = fuzzProgress(d, cardIdsOf(cards));
    }
    const run = new Run(cards, options, create);
    play(d, run, cardIdsOf(cards), 120, 0.15 + d() * 0.7);
    run.emit();
  }
}

// ---------------------------------------------------------------------------
// 3. Restored states: stored JSON (valid, partial or corrupt) read by the engine, then played on

const JUNK = ['x', 5, -3, 0, null, true, false, [], {}, '7'];

function mutate(d, raw) {
  const keys = Object.keys(raw);
  const qkeys = raw.questions && typeof raw.questions === 'object' ? Object.keys(raw.questions) : [];
  const anyQid = () => (qkeys.length ? pick(d, qkeys) : 'ghost:t');
  const list = (key) => {
    if (!Array.isArray(raw[key])) raw[key] = [];
    return raw[key];
  };
  const map = (key) => {
    if (!raw[key] || typeof raw[key] !== 'object' || Array.isArray(raw[key])) raw[key] = {};
    return raw[key];
  };
  switch (randInt(d, 0, 19)) {
    case 0:
      if (keys.length) delete raw[pick(d, keys)];
      break;
    case 1:
      if (keys.length) raw[pick(d, keys)] = pick(d, JUNK);
      break;
    case 2:
      map('questions')[`j${randInt(d, 0, 9)}:t`] = pick(d, [
        null,
        'x',
        [],
        { cardId: null },
        { ask: 'term' },
        { cardId: 5, ask: 'x' },
        { cardId: 'c9', ask: 'definition' },
        { cardId: true },
        { cardId: [1, 2] },
        { cardId: {} },
        { qid: 'other', cardId: 'c1', ask: 'definition' },
      ]);
      break;
    case 3:
      if (qkeys.length) delete raw.questions[pick(d, qkeys)];
      break;
    case 4: {
      const key = pick(d, ['order', 'queue', 'done']);
      const l = list(key);
      const r = d();
      if (r < 0.3) l.push(pick(d, ['ghost:t', 5, null, anyQid(), anyQid()]));
      else if (r < 0.5 && l.length) l.push(l[0]);
      else if (r < 0.7) l.reverse();
      else if (r < 0.85) l.length = 0;
      else raw[key] = pick(d, JUNK);
      break;
    }
    case 5:
      list('queue').unshift(anyQid());
      break;
    case 6:
      list('roundAnswered').push(
        pick(d, [null, 'x', [], { qid: 'ghost:t', correct: true }, { qid: anyQid(), correct: 'yes' }, { qid: anyQid() }, { qid: anyQid(), correct: false }]),
      );
      break;
    case 7:
      list('rounds').push(
        pick(d, [
          null,
          'x',
          [],
          {},
          { round: 2.5, total: -3, correct: 'x', incorrectQids: 'x' },
          { round: -1, total: 3, correct: 1, incorrectQids: [anyQid(), anyQid(), 'ghost:t', 7] },
          { round: typeof raw.round === 'number' ? raw.round : 1, total: 2, correct: 1, incorrectQids: [anyQid()] },
          { round: (typeof raw.round === 'number' ? raw.round : 1) - 1, total: 4, correct: 3, incorrectQids: [anyQid()] },
        ]),
      );
      break;
    case 8: {
      const m = map(pick(d, ['attempts', 'misses']));
      m[chance(d, 0.7) ? anyQid() : 'ghost:t'] = pick(d, [-2, 'x', null, true, 1000000, 0, 1, 2, 3]);
      break;
    }
    case 9:
      map('firstTry')[chance(d, 0.8) ? anyQid() : 'ghost:t'] = pick(d, ['yes', 1, null, false, true]);
      break;
    case 10:
      raw.setOptions = pick(d, [
        { answerWith: 'bogus' },
        { shuffle: 0 },
        null,
        'x',
        [],
        { answerWith: 'both', shuffle: false },
        { answerWith: 'definition', shuffle: true },
      ]);
      break;
    case 11:
      raw.subset = pick(d, ['starred', 'bogus', { cardIds: ['c1', 5, null, ''] }, null, [], { cardIds: 'x' }]);
      break;
    case 12:
      raw.round = pick(d, [0, -2, 2.5, '3', 7, 1000000, 2]);
      break;
    case 13:
      raw[pick(d, ['startedAt', 'updatedAt'])] = pick(d, ['x', null, -5, 0, T0 + 1, true]);
      break;
    case 14:
      raw.finishedAt = pick(d, ['x', T0, null, 0, -1, true]);
      break;
    case 15:
      raw.elapsedMs = pick(d, [-50, 'x', 12345.5, null, 0]);
      break;
    case 16:
      // Array-shaped maps: Object.keys of an array are its indices.
      raw.questions = [{ cardId: 'c1', ask: 'term' }, { cardId: 'c2' }, null, { cardId: 'c1', ask: 'definition' }];
      raw.order = ['0', '1', '3', '2', 0];
      raw.attempts = [2, 1, 'x', 4];
      raw.misses = [1, 0, 3];
      raw.firstTry = [false, true, null, 'x'];
      if (chance(d, 0.5)) raw.done = ['1'];
      break;
    case 17:
      // A stuck state: open questions fell out of the queue.
      raw.queue = [];
      if (chance(d, 0.5)) raw.roundAnswered = [];
      break;
    case 18:
      if (Array.isArray(raw.rounds) && raw.rounds.length) {
        const r = raw.rounds[raw.rounds.length - 1];
        if (r && typeof r === 'object') r.round = raw.round;
      }
      break;
    default:
      // Questions answered in the round but not done any more (inconsistent bookkeeping).
      if (Array.isArray(raw.done) && raw.done.length) raw.done.splice(randInt(d, 0, raw.done.length - 1), 1);
      break;
  }
}

// An unshuffled state must rank every question (see the header comment).
function rankAll(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return raw;
  const rep = tick(raw, null);
  if (rep.setOptions.shuffle) return raw;
  const missing = Object.keys(rep.questions).filter((q) => !rep.order.includes(q));
  if (missing.length === 0) return raw;
  if (!Array.isArray(raw.order)) raw.order = [];
  raw.order.push(...missing);
  return raw;
}

function restore(d, raw, seed, steps, pCorrect) {
  const run = new RestoreRun(rankAll(raw), seed);
  const ids = [...new Set(Object.values(run.s.questions).map((q) => q.cardId))].concat(['nope']);
  let t = run.t;
  for (let i = 0; i < steps; i++) {
    t = advance(d, t);
    run.do(randomAction(d, run.s, t, ids, pCorrect));
  }
  run.emit();
}

// 3a. The partial and stuck states of the JS test.
{
  const d = mulberry32(5);
  restore(d, { questions: { 'a:t': { cardId: 'a', ask: 'term' } }, order: ['a:t', 'ghost:t'], queue: ['a:t'] }, 1, 3, 1);
  restore(d, { questions: { 'a:t': { cardId: 'a', ask: 'term' } }, order: ['a:t'], queue: [], round: 1 }, 1, 4, 0.5);
  for (const raw of [null, 'x', 5, [], {}, { questions: 'x' }, { questions: [] }]) restore(d, raw, 1, 2, 0.5);
}

// 3b. Hand-edited states where a card has three or more questions: separateSiblings has to move
// items to earlier slots. Every question is missed once, then the next rounds are shuffled.
{
  const d = mulberry32(333);
  for (let k = 0; k < 40; k++) {
    const questions = {};
    const order = [];
    const n = randInt(d, 3, 8);
    for (let i = 0; i < n; i++) {
      const qid = `q${i}`;
      questions[qid] = { qid, cardId: pick(d, k % 2 ? ['a', 'a', 'b'] : ['a', 'b', 'c']), ask: pick(d, ['term', 'definition']) };
      order.push(qid);
    }
    const raw = { v: 1, setOptions: { answerWith: 'both', shuffle: true }, subset: 'all', questions, order, queue: order.slice(), round: 1, startedAt: T0, updatedAt: T0 };
    const run = new RestoreRun(raw, randInt(d, 0, 0xffffffff));
    let t = T0;
    for (let round = 0; round < 3; round++) {
      while (!isRoundOver(run.s)) run.do(ans(chance(d, 0.15), (t += 5 * SEC)));
      run.do(nr((t += 5 * SEC)));
    }
    run.emit();
  }
}

// 3c. Inconsistent bookkeeping (older or hand-edited states), built from real states at the end
// of round 1: the guards and clamps of override and removeCard.
{
  const d = mulberry32(4711);
  for (let k = 0; k < 90; k++) {
    const variant = k % 6;
    const options = { answerWith: pick(d, ['term', 'definition', 'both']), shuffle: chance(d, 0.5) };
    const base = new Run(makeCards(randInt(d, 2, 5)), options, { seed: randInt(d, 0, 0xffffffff), now: T0 });
    let t = T0;
    while (!isRoundOver(base.s)) base.do(ans(chance(d, 0.4), (t += 5 * SEC)));
    // Round 1 needs a miss (variant 4: two): turn the first answers into misses if needed.
    let raw = JSON.parse(JSON.stringify(base.s));
    const need = variant === 4 ? 2 : 1;
    for (const a of raw.roundAnswered) {
      if (raw.roundAnswered.filter((x) => !x.correct).length >= need) break;
      if (!a.correct) continue;
      a.correct = false;
      raw.done = raw.done.filter((x) => x !== a.qid);
      raw.misses[a.qid] = 1;
      raw.firstTry[a.qid] = false;
      raw.finishedAt = null;
    }
    if (variant >= 2 && variant <= 4) raw = nextRound(raw, mulberry32(k), (t += 5 * SEC));
    raw = JSON.parse(JSON.stringify(raw));
    const wrong = raw.roundAnswered.filter((a) => !a.correct).map((a) => a.qid);
    const actions = [];
    const now = () => (t += randInt(d, 1, 20) * SEC);
    switch (variant) {
      case 0: {
        // The round is recorded as closed although its misses are still open.
        const total = raw.roundAnswered.length;
        raw.rounds.push({ round: raw.round, total, correct: chance(d, 0.5) ? total : total - wrong.length, incorrectQids: wrong.slice() });
        for (const q of wrong) actions.push(ov(q, now()));
        actions.push(nr(now()), ov(wrong[0], now()));
        break;
      }
      case 1:
        // Misses were never counted.
        for (const q of wrong) {
          if (chance(d, 0.5)) delete raw.misses[q];
          else raw.misses[q] = 0;
        }
        for (const q of wrong) actions.push(ov(q, now()));
        actions.push(nr(now()));
        break;
      case 2: {
        // The closed round already counts every answer as correct.
        const last = raw.rounds[raw.rounds.length - 1];
        last.correct = last.total + randInt(d, 0, 2);
        for (const q of last.incorrectQids.slice(0, 2)) actions.push(ov(q, now()));
        actions.push(ans(true, now()), nr(now()));
        break;
      }
      case 3: {
        // Closed-round tallies that do not fit the questions asked.
        const r0 = raw.rounds[0];
        r0.total = randInt(d, 0, 4);
        r0.correct = randInt(d, 0, 3);
        const ids = [...new Set(Object.values(raw.questions).map((q) => q.cardId))];
        actions.push(rm(pick(d, ids), now()), rm(pick(d, ids), now()), nr(now()));
        break;
      }
      case 4: {
        // Round 2 ends while a miss of round 1 is still open (it fell out of the queue).
        const dropped = raw.queue.pop();
        for (let i = 0; i < raw.queue.length; i++) actions.push(ans(chance(d, 0.5), now()));
        actions.push(ov(dropped, now()), nr(now()));
        break;
      }
      default: {
        // A missed question is listed as done.
        raw.done.push(wrong[0]);
        actions.push(ov(wrong[0], now()));
        for (const q of wrong.slice(1)) actions.push(ov(q, now()));
        actions.push(nr(now()), ov(wrong[0], now()));
        break;
      }
    }
    const run = new RestoreRun(rankAll(raw), randInt(d, 0, 0xffffffff));
    for (const a of actions) run.do(a);
    run.emit();
  }
}

// 3d. Round trip of real states (unchanged), then corrupted copies of them.
{
  const d = mulberry32(31337);
  for (let k = 0; k < 170; k++) {
    const n = randInt(d, 1, 6);
    const cards = chance(d, 0.7) ? makeCards(n) : fuzzCards(d, n);
    const options = { answerWith: pick(d, ['term', 'definition', 'both']), shuffle: chance(d, 0.6) };
    const base = new Run(cards, options, { seed: randInt(d, 0, 0xffffffff), now: T0 });
    play(d, base, cardIdsOf(cards), randInt(d, 0, 25), 0.55);
    const raw = JSON.parse(JSON.stringify(base.s));
    if (k % 6 !== 0) {
      const mutations = randInt(d, 1, 4);
      for (let m = 0; m < mutations; m++) mutate(d, raw);
    }
    restore(d, raw, randInt(d, 0, 0xffffffff), randInt(d, 0, 6), 0.5);
  }
}

cases.emit();
