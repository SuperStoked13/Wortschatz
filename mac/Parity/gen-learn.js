// Parity fixture for src/core/learn.js (Learn mode) → Fixtures/learn.json.
//
// fns:
//   scenario          [cards, options, create, actions] → snapshots: one after createLearn, then one
//                     after every action.
//   restore           [raw, cards, seed, progress, actions] → snapshots: one of the stored state `raw`
//                     as the engine reads it (tick(raw, null) is copyState(raw)), then one after every
//                     action; `cards` are the set's cards.
//   buildChoices      [cards, card, ask, seed, n] → the options (n null = the default).
//   stageFromProgress [progress] → the stage.
//
// snapshot = {state, current, counts, checkpoint, isRoundOver, isFinished, finalStats, matches}
//   with matches = matchesProgress(state, tracked progress). After 'answer', 'override' and 'tick'
//   the snapshot is lite: `stateLite` instead of `state` (every queued question reduced to its
//   qid; the options are recorded by the full snapshots and by `current`), and checkpoint and
//   finalStats only when the round is over. 'write' and 'reset' do not touch the session and
//   record {matches} only.
// create   = {seed, now, subset?, progress?}: the engine rng is mulberry32(seed), created once per
//   case and shared by createLearn, nextRound and removeCard (restore: mulberry32(seed)); an action
//   may carry its own `seed` for a fresh mulberry32.
// Tracked progress = what db.recordAnswer / db.overrideLastAnswer would store. It starts as the
//   progress argument (an object, else {}); 'answer' applies applyAnswer(entry of the current card,
//   correct, T0); 'override' applies applyOverride when that entry's lastResult is 'incorrect' (as
//   db.overrideLastAnswer does); 'write' is an answer given elsewhere (Write mode); 'reset' is
//   db.resetProgress (no cardIds) or db.resetCardProgress; 'sync' with `progress` replaces it.
// actions  = {op:'answer', correct, now} | {op:'override', now}
//          | {op:'nextRound', now, seed?, cards?} | {op:'removeCard', cardId, now, cards?, seed?}
//          | {op:'tick', now} | {op:'sync', now, progress?} | {op:'write', cardId, correct}
//          | {op:'reset', cardIds?}
//   now = epoch ms, or null for "not a number" (the clock is left alone).
//   cards (nextRound/removeCard): an array becomes the set's cards from then on (removeCard: the
//   refill source); 'set' (removeCard) refills from the current set cards; null is handed to the
//   JS as is (nextRound: keep every card; removeCard: no refill).
//
// Cards are handed to the JS as they are (junk included). The Swift test converts them at the
// typed API boundary: scenario cards keep string sides only (createLearn never asks a card with a
// non-string side, and edited card lists below only use strings); buildChoices cards use JS
// `String(v)` (answerSide's toStr), because its distractors come from every card with an id.
//
// Junk deliberately avoided (documented divergences of the typed Swift port, see LearnEngine.swift):
// fractional counts, numbers beyond 2^53, ids differing only in Unicode normalisation, nested
// arrays/objects as subset card ids, and non-string sides in card lists handed to nextRound or
// removeCard after creation.
import {
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
  stageFromProgress,
} from '../../Website/src/core/learn.js';
import { applyAnswer, applyOverride } from '../../Website/src/core/mastery.js';
import { parseVocab } from '../../Website/src/core/parser.js';
import { Cases, mulberry32, randInt, pick, chance, readText } from './lib.js';

const cases = new Cases('learn');

const T0 = 1760000000000;
const SEC = 1000;
const MIN = 60 * SEC;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const OPTS = { answerWith: 'term' };

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const clone = (v) => JSON.parse(JSON.stringify(v));

// ---------------------------------------------------------------------------
// Recording

// lite: after 'answer', 'override' and 'tick' the queue only loses or gains questions whose
// options were recorded before (or show up in `current` later), so `stateLite` keeps the state
// with each queued question reduced to its qid, and checkpoint/finalStats (pure functions of the
// state) are recorded only once the round is over. Every other snapshot is full.
function snap(s, progress, lite = false) {
  const state = tick(s, null);
  const over = isRoundOver(s);
  if (lite) state.queue = state.queue.map((q) => q.qid);
  const out = {
    [lite ? 'stateLite' : 'state']: state,
    current: current(s),
    counts: counts(s),
    isRoundOver: over,
    isFinished: isFinished(s),
    matches: matchesProgress(s, progress),
  };
  if (!lite || over) {
    out.checkpoint = checkpoint(s);
    out.finalStats = finalStats(s);
  }
  return out;
}

// Never pass `undefined` as now: the JS would fall back to Date.now() (not deterministic).
function checkNow(a) {
  if (a.op !== 'write' && a.op !== 'reset' && a.now === undefined) throw new Error(`action without an explicit now: ${JSON.stringify(a)}`);
}

class Run {
  constructor(cards, options, create, raw) {
    if (raw !== undefined) {
      // restore
      this.raw = raw;
      this.seed = create.seed;
      this.rng = mulberry32(create.seed);
      this.progress = isObj(create.progress) ? clone(create.progress) : {};
      this.initialProgress = create.progress === undefined ? {} : create.progress;
      this.cards = cards;
      this.cards0 = cards;
      this.s = tick(raw, null);
      this.t = typeof this.s.updatedAt === 'number' ? this.s.updatedAt : T0;
      this.snaps = [snap(raw, this.progress)];
    } else {
      this.args = [cards, options, create];
      this.cards = cards;
      this.rng = mulberry32(create.seed);
      const opts = { rng: this.rng, now: create.now };
      if ('subset' in create) opts.subset = create.subset;
      if ('progress' in create) opts.progress = create.progress;
      this.progress = isObj(create.progress) ? clone(create.progress) : {};
      this.s = createLearn(cards, options, opts);
      this.t = typeof create.now === 'number' ? create.now : T0;
      this.snaps = [snap(this.s, this.progress)];
    }
    this.actions = [];
  }

  apply(a) {
    switch (a.op) {
      case 'answer': {
        const q = current(this.s);
        if (q) this.progress[q.cardId] = applyAnswer(this.progress[q.cardId], a.correct, T0);
        return answer(this.s, a.correct, a.now);
      }
      case 'override': {
        const l = tick(this.s, null).last;
        if (l && !l.correct) {
          const prev = this.progress[l.cardId];
          if (prev && prev.lastResult === 'incorrect') this.progress[l.cardId] = applyOverride(prev);
        }
        return override(this.s, a.now);
      }
      case 'nextRound': {
        let cards = this.cards;
        if ('cards' in a) {
          cards = a.cards;
          if (Array.isArray(a.cards)) this.cards = a.cards;
        }
        return nextRound(this.s, cards, 'seed' in a ? mulberry32(a.seed) : this.rng, a.now);
      }
      case 'removeCard': {
        if (!('cards' in a)) return removeCard(this.s, a.cardId, a.now);
        let cards = a.cards;
        if (cards === 'set') cards = this.cards;
        else if (Array.isArray(cards)) this.cards = cards;
        return removeCard(this.s, a.cardId, a.now, { cards, rng: 'seed' in a ? mulberry32(a.seed) : this.rng });
      }
      case 'tick':
        return tick(this.s, a.now);
      case 'sync': {
        if ('progress' in a) this.progress = isObj(a.progress) ? clone(a.progress) : {};
        return syncProgress(this.s, 'progress' in a ? a.progress : this.progress, a.now);
      }
      case 'write':
        this.progress[a.cardId] = applyAnswer(this.progress[a.cardId], a.correct, T0);
        return this.s;
      case 'reset':
        if (Array.isArray(a.cardIds)) for (const id of a.cardIds) delete this.progress[id];
        else this.progress = {};
        return this.s;
      default:
        throw new Error(`unknown op ${a.op}`);
    }
  }

  do(a) {
    checkNow(a);
    this.s = this.apply(a);
    this.actions.push(a);
    if (a.op === 'write' || a.op === 'reset') this.snaps.push({ matches: matchesProgress(this.s, this.progress) });
    else this.snaps.push(snap(this.s, this.progress, a.op === 'answer' || a.op === 'override' || a.op === 'tick'));
    return this.s;
  }

  emit() {
    if (this.raw !== undefined) cases.add('restore', [this.raw, this.cards0, this.seed, this.initialProgress, this.actions], this.snaps);
    else cases.add('scenario', [...this.args, this.actions], this.snaps);
  }
}

function scenario(cards, options, create, actions = []) {
  const run = new Run(cards, options, create);
  for (const a of actions) run.do(a);
  return run;
}

const ans = (correct, now) => ({ op: 'answer', correct, now });
const ov = (now) => ({ op: 'override', now });
const nr = (now, extra = {}) => ({ op: 'nextRound', now, ...extra });
const rm = (cardId, now, extra = {}) => ({ op: 'removeCard', cardId, now, ...extra });
const tk = (now) => ({ op: 'tick', now });
const sy = (now, extra = {}) => ({ op: 'sync', now, ...extra });
const wr = (cardId, correct) => ({ op: 'write', cardId, correct });
const rs = (cardIds) => (cardIds === undefined ? { op: 'reset' } : { op: 'reset', cardIds });

// Answers every remaining question of the round; decide(question, state) → boolean.
function playRound(run, decide, startAt = run.t) {
  let t = startAt;
  let guard = 0;
  while (!isRoundOver(run.s)) {
    if (guard++ > 200) throw new Error('round did not end');
    t += 5 * SEC;
    run.do(ans(decide(current(run.s), run.s), t));
  }
  run.t = t;
  return run;
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

// What db.recordAnswer stores for a sequence of answers.
function recorded(...results) {
  return results.reduce((p, ok) => applyAnswer(p, ok, T0), undefined);
}

// The user's 52-pair list (tests/fixtures/user-example.txt), parsed like the web editor does.
const USER = parseVocab(readText('tests/fixtures/user-example.txt')).cards.map((c, i) => ({
  id: `u${i + 1}`,
  term: c.term,
  definition: c.definition,
  starred: i % 5 === 0,
}));

// Synonyms and shared alternatives (tests/learn.test.js).
const WORD_LIST = [
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
].map(([term, definition], i) => ({ id: `w${i + 1}`, term, definition }));

// ---------------------------------------------------------------------------
// 1. The scenarios of tests/learn.test.js

const at = (seed) => ({ seed, now: T0 });

// creation
scenario(makeCards(10), OPTS, at(1)).emit();
for (const seed of [42, 7]) scenario(makeCards(12), OPTS, at(seed)).emit();
scenario(makeCards(10), { answerWith: 'term', learn: { roundSize: 3, mc: false, written: true, retype: true } }, at(1)).emit();
for (const bad of [0, -2, 'x', null, 4.8]) scenario(makeCards(10), { learn: { roundSize: bad } }, at(1)).emit();
scenario(makeCards(10), { learn: { mc: false, written: false } }, at(1)).emit();
scenario(makeCards(10), undefined, at(1)).emit();
scenario(makeCards(10), { answerWith: 'bogus' }, at(1)).emit();
scenario(makeCards(10), { answerWith: 'definition' }, at(1)).emit();
scenario(
  [
    { id: 'a', term: 'la rue', definition: 'die Strasse' },
    { id: 'b', term: '  ', definition: 'leer' },
    { id: 'c', term: 'le nom', definition: '' },
    { id: 'a', term: 'dup', definition: 'Duplikat' },
    null,
    'card',
    { term: 'ohne id', definition: 'x' },
    { id: 'd', term: 'calme', definition: 'ruhig' },
  ],
  OPTS,
  at(1),
).emit();
scenario(null, OPTS, { seed: 1, now: T0 }).emit();

// stages from progress
{
  const progress = { c1: progressEntry(2), c2: progressEntry(1), c3: progressEntry(0, 1, 1, 'incorrect'), c4: progressEntry(5, 6, 1) };
  scenario(makeCards(6), OPTS, { ...at(3), progress }).emit();
  scenario(makeCards(10), { answerWith: 'term', learn: { roundSize: 4 } }, { ...at(11), progress: { c8: progressEntry(1), c9: progressEntry(1) } }).emit();
  const all = { c1: progressEntry(2), c2: progressEntry(3), c3: progressEntry(2) };
  scenario(makeCards(3), OPTS, { ...at(1), progress: all }, [ans(true, T0 + SEC), nr(T0 + SEC, { seed: 1 })]).emit();
  scenario(makeCards(2).map((c) => ({ ...c, starred: false })), OPTS, { ...at(1), subset: 'starred' }, [ov(T0 + SEC), rm('c1', T0 + SEC), nr(T0 + SEC, { seed: 1 })]).emit();
}

// subsets
{
  const cards = makeCards(7);
  scenario(cards, OPTS, { ...at(5), subset: 'starred' }).emit();
  scenario(cards, OPTS, { ...at(5), subset: { cardIds: ['c5', 'x9', 'c2'] } }).emit();
  const progress = { c1: progressEntry(2), c2: progressEntry(0, 1, 1, 'incorrect'), c3: progressEntry(1) };
  scenario(cards, OPTS, { ...at(5), subset: 'learning', progress }).emit();
  scenario(cards, OPTS, { ...at(5), subset: 'missed', progress }).emit();
  scenario(cards, OPTS, { ...at(5), subset: 'whatever' }).emit();
}

// a new card: mc, then written, then mastered
{
  const cards = makeCards(6);
  const run = scenario(cards, OPTS, at(2), [ans(true, T0 + 10 * SEC)]);
  playRound(run, () => true, T0 + 10 * SEC);
  run.do(nr(T0 + MIN, { seed: 3 }));
  playRound(run, () => true, T0 + MIN);
  run.emit();
}

// a wrong written answer sends the card back to multiple choice
{
  const cards = makeCards(5);
  const progress = Object.fromEntries(cards.map((c) => [c.id, progressEntry(1)]));
  const run = scenario(cards, OPTS, { ...at(4), progress });
  const id = current(run.s).cardId;
  run.do(ans(false, T0 + 10 * SEC));
  playRound(run, (q) => q.cardId !== id || q.type === 'mc', T0 + 10 * SEC);
  run.do(nr(T0 + MIN, { seed: 5 }));
  run.do(ans(true, T0 + MIN + 5 * SEC));
  run.emit();
}

// a wrong answer is re-queued once
{
  const run = scenario(makeCards(4), OPTS, at(6), [ans(false, T0 + 10 * SEC), ans(true, T0 + 20 * SEC), ans(true, T0 + 30 * SEC), ans(true, T0 + 40 * SEC), ans(false, T0 + 50 * SEC), ans(true, T0 + MIN)]);
  run.emit();
}

// retries reset in the next round
{
  const cards = makeCards(3);
  const run = scenario(cards, OPTS, at(7));
  const id = current(run.s).cardId;
  playRound(run, (q) => q.cardId !== id, T0);
  run.do(nr(T0 + MIN, { seed: 8 }));
  while (current(run.s).cardId !== id) run.do(ans(true, T0 + MIN + SEC));
  run.do(ans(false, T0 + MIN + 2 * SEC));
  run.emit();
}

scenario(makeCards(3), OPTS, at(1), [ans(false, T0 + SEC), nr(T0 + MIN, { seed: 1 })]).emit();

// rounds
{
  const cards = makeCards(8);
  const progress = { c2: progressEntry(1), c4: progressEntry(1), c6: progressEntry(1), c8: progressEntry(1) };
  const opts = { answerWith: 'term', learn: { roundSize: 3 } };
  const a = scenario(cards, opts, { ...at(4), progress });
  playRound(a, () => true, T0);
  a.do(nr(T0 + MIN, { seed: 5 }));
  a.emit();
  const b = scenario(cards, opts, { ...at(4), progress });
  const ones = b.s.order.filter((id) => progress[id]);
  const keep = ones[1];
  playRound(b, (q) => q.cardId !== keep, T0);
  b.do(nr(T0 + MIN, { seed: 5 }));
  b.emit();
}
for (let seed = 1; seed <= 30; seed++) scenario(makeCards(10), OPTS, at(seed)).emit();

// 20 cards, roundSize 7, all correct: six rounds
{
  const cards = makeCards(20);
  const run = scenario(cards, OPTS, at(8));
  let t = T0;
  for (let i = 0; i < 6; i++) {
    playRound(run, () => true, t);
    t += MIN;
    if (i < 5) run.do(nr(t, { seed: 100 + i }));
  }
  run.do(nr(t + MIN, { seed: 1 }));
  run.emit();
}

// 20 cards with random mistakes and overrides until finished (the invariants test)
for (let seed = 1; seed <= 6; seed++) {
  const rng = mulberry32(seed);
  const run = new Run(makeCards(20), { answerWith: seed % 3 === 0 ? 'both' : 'term' }, { seed: 1000 + seed, now: T0 });
  let t = T0;
  for (let rounds = 0; !isFinished(run.s) && rounds < 100; rounds++) {
    while (!isRoundOver(run.s)) {
      t += 4 * SEC;
      run.do(ans(rng() < 0.7, t));
      if (!run.s.last.correct && rng() < 0.15) run.do(ov(t + SEC));
    }
    run.do(nr(t + SEC));
  }
  run.do(nr(t + 2 * SEC));
  run.emit();
}

// finishing
{
  const cards = makeCards(2);
  const run = scenario(cards, OPTS, at(9));
  playRound(run, () => true, T0);
  run.do(nr(T0 + MIN, { seed: 1 }));
  run.do(ans(true, T0 + MIN + 5 * SEC));
  run.do(ans(true, T0 + MIN + 10 * SEC));
  run.do(nr(T0 + 2 * MIN, { seed: 1 }));
  run.do(nr(T0 + 3 * MIN, { seed: 1 }));
  run.emit();
}

// checkpoint, counts, finalStats
scenario(makeCards(3), OPTS, at(6), [ans(true, T0 + SEC), ans(false, T0 + 2 * SEC), ans(true, T0 + 3 * SEC), ans(true, T0 + 4 * SEC)]).emit();
{
  const progress = { c1: progressEntry(0, 0, 2, 'incorrect'), c2: progressEntry(2) };
  const run = scenario(makeCards(5), OPTS, { ...at(12), progress });
  const id = run.s.queue.find((q) => q.cardId !== 'c1').cardId;
  while (current(run.s).cardId !== id) run.do(ans(true, T0 + SEC));
  run.do(ans(false, T0 + 2 * SEC));
  run.emit();
}
{
  const cards = makeCards(3);
  const run = scenario(cards, OPTS, at(13));
  const [a, b, c] = run.s.queue.map((q) => q.cardId);
  playRound(run, planned({ [a]: [false, false], [b]: [false, true], [c]: [true] }), T0);
  run.do(nr(T0 + MIN, { seed: 1 }));
  playRound(run, () => true, T0 + MIN);
  run.do(nr(T0 + 2 * MIN, { seed: 1 }));
  playRound(run, () => true, T0 + 2 * MIN);
  run.emit();
}
{
  const run = scenario(makeCards(12), { answerWith: 'term', learn: { roundSize: 12 } }, at(14));
  playRound(run, () => false, T0);
  run.emit();
}

// question types & flags
{
  const solo = [{ id: 'solo', term: 'le soleil', definition: 'die Sonne' }];
  scenario(solo, OPTS, at(1), [ans(false, T0 + SEC), ans(true, T0 + 2 * SEC), nr(T0 + 20 * SEC, { seed: 2 }), ans(true, T0 + 30 * SEC), tk(T0 + 60 * SEC)]).emit();
  scenario([{ id: 'a', term: 'laid', definition: 'hässlich' }, { id: 'b', term: 'moche', definition: 'hässlich' }], OPTS, at(1)).emit();
  const same = [
    { id: 'a', term: 'le visage', definition: 'das Gesicht' },
    { id: 'b', term: 'la figure', definition: 'das Gesicht' },
  ];
  scenario(same, { answerWith: 'definition' }, at(1)).emit();
  scenario([...same, { id: 'c', term: 'le nez', definition: 'die Nase' }], { answerWith: 'definition' }, at(1)).emit();
  scenario(makeCards(6).map((c) => ({ ...c, starred: c.id === 'c5' })), OPTS, { ...at(2), subset: 'starred' }).emit();
  for (let seed = 1; seed <= 60; seed += 3) scenario(WORD_LIST, { answerWith: 'both', learn: { roundSize: 10 } }, at(seed)).emit();

  const cards = makeCards(5);
  const mcOnly = { answerWith: 'term', learn: { mc: true, written: false } };
  const m = scenario(cards, mcOnly, { ...at(3), progress: { c1: progressEntry(1) } });
  playRound(m, () => true, T0);
  m.do(nr(T0 + MIN, { seed: 4 }));
  playRound(m, () => true, T0 + MIN);
  m.emit();
  scenario([cards[0]], mcOnly, { ...at(1), progress: { c1: progressEntry(1) } }).emit();
  const w = scenario(cards, { answerWith: 'term', learn: { mc: false, written: true } }, at(5), [ans(false, T0 + SEC)]);
  playRound(w, () => true, T0 + SEC);
  w.do(nr(T0 + MIN, { seed: 6 }));
  w.emit();
  scenario(makeCards(6), { answerWith: 'term', learn: { mc: true, written: true } }, { ...at(7), progress: { c1: progressEntry(1), c2: progressEntry(1), c3: progressEntry(0, 0, 1) } }).emit();
  scenario(makeCards(6), { answerWith: 'definition' }, at(8)).emit();
  for (let seed = 1; seed <= 40; seed += 4) scenario(makeCards(8), { answerWith: 'both' }, at(seed), [ans(false, T0 + SEC)]).emit();
}

// override
{
  const a = scenario(makeCards(5), OPTS, at(3), [ans(false, T0 + 10 * SEC), ov(T0 + 15 * SEC)]);
  a.emit();
  scenario(makeCards(4), OPTS, at(4), [ans(false, T0 + SEC), ov(T0 + 2 * SEC), ov(T0 + 3 * SEC), ov(T0 + 4 * SEC)]).emit();
  const progress = { c1: progressEntry(2), c2: progressEntry(2), c3: progressEntry(1) };
  scenario(makeCards(3), OPTS, { ...at(5), progress }, [ans(false, T0 + 10 * SEC), ov(T0 + 20 * SEC)]).emit();
  const n = scenario(makeCards(3), OPTS, at(6), [ov(T0 + SEC), ans(true, T0 + SEC), ov(T0 + 2 * SEC)]);
  playRound(n, () => false, T0 + 2 * SEC);
  n.do(nr(T0 + MIN, { seed: 7 }));
  n.do(ov(T0 + MIN + SEC));
  n.emit();
  const r = scenario(makeCards(3), OPTS, at(8));
  const id = current(r.s).cardId;
  playRound(r, (q) => q.cardId !== id, T0);
  r.do(ov(T0 + MIN));
  r.emit();
}

// removeCard
{
  const s1 = scenario(makeCards(6), OPTS, at(2), [ans(false, T0 + 10 * SEC), ans(true, T0 + 20 * SEC)]);
  const [a, b] = createLearn(makeCards(6), OPTS, { rng: mulberry32(2), now: T0 }).queue.map((q) => q.cardId);
  s1.do(rm(a, T0 + 30 * SEC));
  s1.do(rm(b, T0 + 40 * SEC));
  s1.do(rm('nope', T0 + MIN));
  s1.emit();
  const s2 = scenario(makeCards(4), OPTS, at(3), [ans(true, T0 + SEC)]);
  s2.do(rm(current(s2.s).cardId, T0 + 2 * SEC));
  s2.emit();
  const s3 = scenario(makeCards(3), OPTS, at(4));
  const [x, y] = s3.s.queue.map((q) => q.cardId);
  s3.do(rm(x, T0 + SEC));
  s3.do(rm(y, T0 + 2 * SEC));
  s3.do(ans(false, T0 + 3 * SEC));
  s3.emit();
  scenario(makeCards(3), OPTS, { ...at(5), progress: { c1: progressEntry(2), c2: progressEntry(2) } }, [rm('c3', T0 + 5 * SEC)]).emit();
  scenario(makeCards(2), { answerWith: 'term', learn: { roundSize: 1 } }, { ...at(6), progress: { c1: progressEntry(1) } }, [
    ans(true, T0 + SEC),
    nr(T0 + 2 * SEC, { seed: 7 }),
    rm('c2', T0 + 3 * SEC),
    nr(T0 + 4 * SEC, { seed: 8 }),
  ]).emit();
  const s4 = scenario(makeCards(4), OPTS, at(9));
  playRound(s4, () => true, T0);
  const gone = s4.s.order[0];
  s4.do(nr(T0 + MIN, { seed: 10, cards: makeCards(4).filter((c) => c.id !== gone) }));
  s4.emit();
}

// time
{
  const t1 = T0 + 30 * SEC + 5 * MIN + 2 * HOUR;
  scenario(makeCards(2), OPTS, at(1), [tk(T0 + 30 * SEC), tk(T0 + 30 * SEC + 5 * MIN), tk(t1), tk(t1 + 10 * SEC), tk(t1), tk(null)]).emit();
}

// JSON round trip: the step function of the test, played until finished
{
  const cards = makeCards(12);
  const run = new Run(cards, { answerWith: 'both', learn: { roundSize: 5 } }, { seed: 11, now: T0 });
  const decide = mulberry32(99);
  const outcomes = Array.from({ length: 300 }, () => decide() < 0.6);
  let k = 0;
  let t = T0;
  for (let guard = 0; !isFinished(run.s) && guard < 1000; guard++) {
    t += 7 * SEC;
    if (isRoundOver(run.s)) run.do(nr(t, { seed: t }));
    else {
      run.do(ans(outcomes[k++ % outcomes.length], t));
      if (k % 9 === 0) run.do(ov(t));
    }
  }
  run.emit();
}

// removed options are refilled
{
  const cards = makeCards(10);
  const base = createLearn(cards, OPTS, { rng: mulberry32(21), now: T0 });
  const head = base.queue[0];
  const gone = head.choices.find((c) => c.cardId !== head.cardId).cardId;
  scenario(cards, OPTS, at(21), [rm(gone, T0 + SEC, { cards: cards.filter((c) => c.id !== gone), seed: 22 })]).emit();
  scenario(cards, OPTS, at(21), [rm(gone, T0 + SEC)]).emit();

  const five = makeCards(5);
  const b5 = createLearn(five, OPTS, { rng: mulberry32(23), now: T0 });
  const out5 = b5.queue[0].choices.find((c) => c.cardId !== b5.queue[0].cardId).cardId;
  const emptied = five.map((c) => (c.id === out5 ? { ...c, definition: ' ' } : c));
  for (let seed = 1; seed <= 20; seed++) scenario(five, OPTS, at(23), [rm(out5, T0 + SEC, { cards: emptied, seed })]).emit();
  const four = makeCards(4);
  const b4 = createLearn(four, OPTS, { rng: mulberry32(24), now: T0 });
  const out4 = b4.queue[0].choices.find((c) => c.cardId !== b4.queue[0].cardId).cardId;
  scenario(four, OPTS, at(24), [rm(out4, T0 + SEC, { cards: four.filter((c) => c.id !== out4), seed: 25 })]).emit();

  const names = [
    { id: 'a', term: 'le nom', definition: 'der Name' },
    { id: 'b', term: 'le prénom', definition: 'der Vorname' },
    { id: 'c', term: 'le nom de famille', definition: 'der Nachname' },
    { id: 'd', term: 'la rue', definition: 'die Strasse' },
    { id: 'e', term: 'le nom', definition: 'der Name' },
    { id: 'f', term: 'le patronyme', definition: 'der Nachname' },
    { id: 'g', term: 'la ville', definition: 'die Stadt' },
  ];
  for (let seed = 1; seed <= 30; seed++) {
    const s = createLearn(names, OPTS, { subset: { cardIds: ['c'] }, rng: mulberry32(seed), now: T0 });
    const q = s.queue[0];
    const goneId = q.choices.find((x) => x.cardId !== 'c').cardId;
    // The test widens the scope so that the option's card is part of the session.
    const raw = clone({ ...s, order: [...s.order, goneId], stage: { ...s.stage, [goneId]: 0 } });
    const run = new Run(names, null, { seed: seed + 100 }, raw);
    run.do(rm(goneId, T0 + SEC, { cards: names.filter((x) => x.id !== goneId) }));
    run.emit();
  }
}

// shared progress (Write mode, other windows)
{
  // Learn follows answers given in Write mode.
  const cards = makeCards(6);
  const run = scenario(cards, OPTS, { ...at(31), progress: { c6: recorded(true) } });
  const first = current(run.s);
  run.do(ans(true, T0 + SEC));
  run.do(wr(first.cardId, false));
  run.do(sy(T0 + 2 * SEC));
  const mcQ = run.s.queue.find((q) => q.type === 'mc');
  run.do(wr(mcQ.cardId, true));
  run.do(wr('c6', false));
  const done = run.s.queue.find((q) => q.type === 'mc' && q.cardId !== mcQ.cardId);
  run.do(wr(done.cardId, true));
  run.do(wr(done.cardId, true));
  run.do(sy(T0 + 3 * SEC));
  run.do(sy(T0 + 4 * SEC));
  playRound(run, () => true, T0 + 5 * SEC);
  run.emit();

  // A card mastered before the session but missed elsewhere is studied again.
  const r2 = scenario(makeCards(4), OPTS, { ...at(32), progress: { c1: recorded(true, true) } }, [wr('c1', false), sy(T0 + SEC)]);
  playRound(r2, () => true, T0 + SEC);
  r2.do(nr(T0 + MIN, { seed: 33 }));
  r2.emit();

  // Everything mastered elsewhere finishes the session.
  const three = makeCards(3);
  const all = Object.fromEntries(three.map((c) => [c.id, recorded(true, true)]));
  scenario(three, OPTS, at(34), [ans(true, T0 + SEC), sy(T0 + 2 * SEC, { progress: all }), nr(T0 + 3 * SEC, { seed: 35 }), sy(T0 + 4 * SEC, { progress: {} })]).emit();
  const r3 = scenario(three, { answerWith: 'term', learn: { roundSize: 2 } }, at(36));
  playRound(r3, () => true, T0);
  r3.do(nr(T0 + MIN, { seed: 37 }));
  r3.do(sy(T0 + 2 * MIN, { progress: all }));
  r3.emit();

  // A reset elsewhere makes the cards new again; overrides stay in step.
  scenario(makeCards(4), OPTS, at(38), [ans(false, T0 + SEC), ov(T0 + 2 * SEC), sy(T0 + 3 * SEC, { progress: {} }), sy(T0 + 4 * SEC, { progress: null })]).emit();
  scenario(makeCards(4), OPTS, at(38), [ans(false, T0 + SEC), ov(T0 + 2 * SEC), rs(), sy(T0 + 3 * SEC)]).emit();

  // The question type flags.
  const four = makeCards(4);
  const w = new Run(four, { answerWith: 'term', learn: { mc: false, written: true } }, { seed: 39, now: T0 });
  w.do(sy(T0 + SEC, { progress: { [current(w.s).cardId]: recorded(true) } }));
  w.emit();
  const m = new Run(four, { answerWith: 'term', learn: { mc: true, written: false } }, { seed: 40, now: T0 });
  m.do(sy(T0 + SEC, { progress: { [current(m.s).cardId]: recorded(true) } }));
  m.emit();
  const f = new Run(four, OPTS, { seed: 41, now: T0 });
  f.do(sy(T0 + SEC, { progress: { c1: recorded(true), c2: recorded(true, true), c3: recorded(false) } }));
  f.do(rm(f.s.queue[0].cardId, T0 + SEC, { cards: 'set', seed: 1 }));
  f.emit();
  for (const junk of ['junk', 5, [], null]) scenario(four, OPTS, at(42), [sy(T0 + SEC, { progress: junk })]).emit();
}

// The user's 52-pair list: a full session with mistakes, both directions.
for (const [seed, answerWith, roundSize] of [
  [52, 'term', 7],
  [54, 'both', 15],
]) {
  const d = mulberry32(seed * 7);
  const run = new Run(USER, { answerWith, learn: { roundSize } }, { seed, now: T0 });
  let t = T0;
  for (let guard = 0; !isFinished(run.s) && guard < 600; guard++) {
    t += 6 * SEC;
    if (isRoundOver(run.s)) run.do(nr(t));
    else {
      run.do(ans(d() < 0.75, t));
      if (!run.s.last.correct && d() < 0.1) run.do(ov(t));
    }
  }
  run.do(nr(t + SEC));
  run.emit();
}
scenario(USER, OPTS, { ...at(55), subset: 'starred' }).emit();
scenario(USER, { answerWith: 'both', learn: { roundSize: 50 } }, at(56)).emit();

// ---------------------------------------------------------------------------
// 2. buildChoices and stageFromProgress

function choicesCase(cards, card, ask, seed, n = null) {
  const args = [cards, card, ask, seed, n];
  cases.add('buildChoices', args, buildChoices(cards, card, ask, mulberry32(seed), n === null ? undefined : n));
}

{
  const ten = makeCards(10);
  for (let seed = 1; seed <= 50; seed++) choicesCase(ten, ten[seed % 10], 'term', seed);
  for (let seed = 1; seed <= 10; seed++) choicesCase(makeCards(6), makeCards(6)[2], 'definition', seed);
  const syn = [
    { id: 'laid', term: 'laid, laide', definition: 'hässlich' },
    { id: 'moche', term: 'moche', definition: 'hässlich' },
    { id: 'brave', term: 'brave', definition: 'lieb' },
    { id: 'gentil', term: 'gentil, gentille', definition: 'lieb, nett' },
    { id: 'calme', term: 'calme', definition: 'ruhig' },
    { id: 'sage', term: 'sage', definition: 'brav, artig' },
    { id: 'bete', term: 'bête', definition: 'dumm' },
  ];
  for (let seed = 1; seed <= 40; seed++) {
    for (const card of syn) choicesCase(syn, card, seed % 2 ? 'term' : 'definition', seed);
  }
  const normal = [
    { id: 'a', term: "l'homme", definition: 'der Mann' },
    { id: 'b', term: 'L’Homme', definition: 'Mensch' },
    { id: 'c', term: "  l'homme ", definition: 'Typ' },
    { id: 'd', term: "L'HOMME", definition: 'Kerl' },
    { id: 'e', term: 'la femme', definition: 'die Frau' },
    { id: 'f', term: 'le  garçon', definition: 'der Junge' },
  ];
  for (let seed = 1; seed <= 20; seed++) choicesCase(normal, normal[0], 'term', seed);
  const empties = [
    { id: 'a', term: 'le chien', definition: 'der Hund' },
    { id: 'b', term: 'le chat', definition: 'die Katze' },
    { id: 'c', term: 'Le Chat', definition: 'der Kater' },
    { id: 'd', term: '', definition: 'leer' },
    { id: 'e', term: '   ', definition: 'Leerzeichen' },
    { id: 'f', term: null, definition: 'null' },
  ];
  for (let seed = 1; seed <= 15; seed++) choicesCase(empties, empties[0], 'term', seed);
  const alts = [
    { id: 'a', term: 'laid, laide', definition: 'hässlich' },
    { id: 'b', term: 'laid', definition: 'unschön' },
    { id: 'c', term: 'laide, moche', definition: 'unansehnlich' },
    { id: 'd', term: 'joli, jolie', definition: 'hübsch' },
    { id: 'e', term: 'beau, belle', definition: 'schön' },
  ];
  for (let seed = 1; seed <= 15; seed++) choicesCase(alts, alts[0], 'term', seed);
  for (const n of [1, 2, 3, 4, 5, 30]) choicesCase(makeCards(n), makeCards(n)[0], 'term', n);
  for (const n of [2, 3, 1, 0, -1, 'x', 2.5, null]) choicesCase(ten, ten[0], 'term', 1, n);
  choicesCase(null, ten[0], 'term', 1);
  choicesCase(ten, { id: 'x', term: '', definition: 'y' }, 'term', 1);
  choicesCase(ten, ten[0], 'bogus', 1);
  choicesCase([...ten, null, 'x', { term: 'no id' }, { id: 5, term: 'cinq', definition: 'fünf' }, { id: '', term: 'vide' }], ten[0], 'term', 1);
  choicesCase([{ id: 1, term: 1, definition: 'eins' }, { id: 2, term: true, definition: 'wahr' }, { id: 3, term: 'trois', definition: 'drei' }], { id: 3, term: 'trois', definition: 'drei' }, 'term', 3);
  for (let seed = 1; seed <= 40; seed++) choicesCase(USER, USER[(seed * 7) % USER.length], seed % 3 ? 'term' : 'definition', seed);
  for (let seed = 1; seed <= 30; seed++) choicesCase(WORD_LIST, WORD_LIST[seed % WORD_LIST.length], seed % 2 ? 'term' : 'definition', seed);
}

for (const p of [
  undefined,
  null,
  {},
  progressEntry(0, 0, 1),
  progressEntry(1),
  progressEntry(2),
  progressEntry(7, 9, 2),
  { streak: -3 },
  { streak: 'x' },
  { streak: 1.9 },
  { streak: 2.5 },
  'junk',
  5,
  [],
  { streak: 1e300 },
]) {
  cases.add('stageFromProgress', [p === undefined ? null : p], stageFromProgress(p));
}

// ---------------------------------------------------------------------------
// 3. Seeded fuzz: decks, options, subsets, progress and random action sequences

const BLANKS = ['', ' ', '  ', '\t', '\n', ' ', '　', '﻿'];
// Not whitespace for JS `trim()`: NEL, zero-width space, word joiner.
const TEXTY = ['\u0085', '​', '⁠', 'x', 'é', ' a ', 'l’été', 'L’ÉTÉ', "l'été"];
const PAIRS = USER.map((c) => [c.term, c.definition]).concat(WORD_LIST.map((c) => [c.term, c.definition]));

// A deck of `n` cards from the user's list with typical noise: duplicate texts (also in other
// case or with other apostrophes), shared alternatives, synonyms (same prompt), blank sides,
// duplicate, missing and numeric ids, junk entries. `strings` keeps every side a string.
function fuzzCards(d, n, strings = false) {
  const cards = [];
  for (let i = 1; i <= n; i++) {
    const [term, definition] = pick(d, PAIRS);
    const c = { id: `c${i}`, term, definition, starred: i % 3 === 1 };
    const r = d();
    if (r < 0.06) c.term = pick(d, BLANKS);
    else if (r < 0.1) c.definition = pick(d, BLANKS);
    else if (r < 0.14) c[chance(d, 0.5) ? 'term' : 'definition'] = pick(d, TEXTY);
    else if (r < 0.2 && cards.length) {
      // Same answer text as an earlier card (maybe in another case).
      const other = pick(d, cards);
      if (typeof other.term === 'string') c.term = chance(d, 0.5) ? other.term.toUpperCase() : other.term;
    } else if (r < 0.26 && cards.length) {
      // Same prompt as an earlier card: a synonym.
      const other = pick(d, cards);
      if (typeof other.definition === 'string') c.definition = other.definition;
    } else if (r < 0.3 && cards.length) {
      // Shares an alternative with an earlier card.
      const other = pick(d, cards);
      if (typeof other.term === 'string') c.term = `${other.term}, ${pick(d, PAIRS)[0]}`;
    } else if (!strings && r < 0.32) c[chance(d, 0.5) ? 'term' : 'definition'] = pick(d, [5, null, true]);
    else if (r < 0.35) c.id = pick(d, [i * 100, -i]);
    else if (r < 0.37) {
      if (chance(d, 0.5)) delete c.id;
      else c.id = pick(d, [null, '']);
    } else if (r < 0.41) c.id = `c${randInt(d, 1, i)}`;
    if (chance(d, 0.1)) c.starred = pick(d, ['yes', 1, null, false, true]);
    cards.push(c);
    if (!strings && chance(d, 0.03)) cards.push(pick(d, [null, 'x', 7, [], {}, { id: 'junk' }]));
  }
  return cards;
}

// The ids createLearn sees (String(raw.id) of the entries with an id).
function cardIdsOf(cards) {
  if (!Array.isArray(cards)) return [];
  return [...new Set(cards.filter((c) => isObj(c) && c.id != null && c.id !== '').map((c) => String(c.id)))];
}

// The set after an edit: a card deleted, a side emptied or changed, a card added. String sides
// only (see the header comment).
function editCards(d, cards) {
  const out = cards.filter((c) => isObj(c) && c.id != null && c.id !== '').map((c) => ({
    ...c,
    term: typeof c.term === 'string' ? c.term : '',
    definition: typeof c.definition === 'string' ? c.definition : '',
  }));
  const edits = randInt(d, 1, 3);
  for (let k = 0; k < edits && out.length; k++) {
    const i = randInt(d, 0, out.length - 1);
    const r = d();
    if (r < 0.4) out.splice(i, 1);
    else if (r < 0.6) out[i] = { ...out[i], [chance(d, 0.5) ? 'term' : 'definition']: pick(d, ['', ' ']) };
    else if (r < 0.85) {
      const [term, definition] = pick(d, PAIRS);
      out[i] = { ...out[i], term, definition };
    } else {
      const [term, definition] = pick(d, PAIRS);
      out.push({ id: `n${randInt(d, 1, 99)}`, term, definition });
    }
  }
  return out;
}

const PROGRESS = [
  () => recorded(true, true),
  () => recorded(true, true, true),
  () => recorded(true),
  () => recorded(false),
  () => recorded(true, false),
  () => recorded(false, true),
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
  if (d() < 0.05) return pick(d, [null, 'x', [], 5]);
  const p = {};
  for (const id of ids) if (chance(d, 0.6)) p[id] = pick(d, PROGRESS)();
  if (chance(d, 0.3)) p.ghost = PROGRESS[0]();
  return p;
}

const SMALL_GAPS = [1, 250, 2 * SEC, 3 * SEC, 4 * SEC, 5 * SEC, 7 * SEC, 8 * SEC, 10 * SEC, 12 * SEC, 15 * SEC, 20 * SEC, 30 * SEC];
const SPECIAL_GAPS = [0, 0.5, 1500.25, MIN, 2 * MIN, 299999, 5 * MIN, 5 * MIN + 1, 6 * MIN, 20 * MIN, 2 * HOUR, DAY, -10 * SEC, -1];

function advance(d, t) {
  return t + (chance(d, 0.85) ? pick(d, SMALL_GAPS) : pick(d, SPECIAL_GAPS));
}

function pickCardId(d, s, ids) {
  const r = d();
  const st = tick(s, null);
  const cur = current(st);
  if (r < 0.3 && cur) return cur.cardId;
  if (r < 0.45 && cur && cur.choices) return pick(d, cur.choices).cardId;
  if (r < 0.6 && st.queue.length) return pick(d, st.queue).cardId;
  if (r < 0.75 && st.order.length) return pick(d, st.order);
  if (r < 0.93 && ids.length) return pick(d, ids);
  return pick(d, ['nope', '', 'c', 'ghost']);
}

function randomAction(d, run, t, ids, pCorrect) {
  const now = chance(d, 0.03) ? null : t;
  const s = run.s;
  const r = d();
  if (!isRoundOver(s)) {
    if (r < 0.7) return ans(d() < pCorrect, now);
    if (r < 0.78) return ov(now);
    if (r < 0.8) return tk(now);
    if (r < 0.86) {
      const extra = d();
      if (extra < 0.4) return rm(pickCardId(d, s, ids), now);
      if (extra < 0.7) return rm(pickCardId(d, s, ids), now, { cards: 'set' });
      if (extra < 0.9) return rm(pickCardId(d, s, ids), now, { cards: editCards(d, run.cards), seed: randInt(d, 0, 0xffffffff) });
      return rm(pickCardId(d, s, ids), now, { cards: null });
    }
    if (r < 0.9) return wr(pickCardId(d, s, ids), d() < 0.6);
    if (r < 0.95) return sy(now);
    if (r < 0.97) return sy(now, { progress: fuzzProgress(d, ids) });
    if (r < 0.98) return rs(chance(d, 0.5) ? undefined : [pickCardId(d, s, ids)]);
    return nr(now);
  }
  if (r < 0.5) return nr(now);
  if (r < 0.58) return nr(now, { cards: editCards(d, run.cards) });
  if (r < 0.6) return nr(now, { cards: null, seed: randInt(d, 0, 0xffffffff) });
  if (r < 0.7) return ov(now);
  if (r < 0.75) return tk(now);
  if (r < 0.82) return rm(pickCardId(d, s, ids), now, chance(d, 0.5) ? { cards: 'set' } : {});
  if (r < 0.88) return wr(pickCardId(d, s, ids), d() < 0.6);
  if (r < 0.95) return sy(now);
  return ans(d() < 0.5, now);
}

// Plays random actions; stops a few actions after the session finished, or after maxSteps.
function play(d, run, ids, maxSteps, pCorrect) {
  let t = run.t;
  let extra = -1;
  for (let i = 0; i < maxSteps; i++) {
    t = advance(d, t);
    run.do(randomAction(d, run, t, ids, pCorrect));
    if (isFinished(run.s)) {
      if (extra === -1) extra = randInt(d, 0, 3);
      if (extra-- === 0) break;
    }
  }
}

const ANSWER_WITH = ['term', 'definition', 'both', 'bogus', undefined];
const LEARN = [
  undefined,
  { roundSize: 3 },
  { roundSize: 1 },
  { roundSize: 5, mc: false },
  { roundSize: 4, written: false },
  { mc: false, written: false },
  { roundSize: 0, retype: true },
  'x',
];
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
];

// 3a. Matrix: every answerWith × learn options × subset, each with a fuzzed deck and a short play.
{
  const d = mulberry32(20261012);
  let seed = 1000;
  for (const answerWith of ANSWER_WITH) {
    for (const learn of LEARN) {
      for (const subset of SUBSETS) {
        if (d() < 0.45) continue;
        const cards = fuzzCards(d, randInt(d, 0, 9));
        const options = {};
        if (answerWith !== undefined) options.answerWith = answerWith;
        if (learn !== undefined) options.learn = learn;
        const create = { seed: seed++, now: chance(d, 0.05) ? null : T0 + randInt(d, 0, 1000) * 7.5 };
        if (subset !== undefined) create.subset = subset;
        if (subset === 'learning' || subset === 'missed' || chance(d, 0.35)) create.progress = fuzzProgress(d, cardIdsOf(cards));
        const run = new Run(cards, options, create);
        play(d, run, cardIdsOf(cards), randInt(d, 2, 14), 0.3 + d() * 0.6);
        run.emit();
      }
    }
  }
}

// 3b. Odd option objects.
{
  const d = mulberry32(77);
  for (const options of [null, 'x', [], 5, {}, { answerWith: 'both' }, { learn: null }, { learn: { roundSize: '3' } }, { answerWith: 'definition', learn: { mc: 0 } }]) {
    const cards = makeCards(randInt(d, 2, 6));
    const run = new Run(cards, options, { seed: randInt(d, 1, 999), now: T0 });
    play(d, run, cardIdsOf(cards), 8, 0.5);
    run.emit();
  }
}

// 3c. Long random plays until the session is finished (and closed).
{
  const d = mulberry32(424242);
  for (let k = 0; k < 75; k++) {
    const n = randInt(d, 1, 9);
    const cards = chance(d, 0.4) ? makeCards(n) : fuzzCards(d, n, chance(d, 0.5));
    const options = { answerWith: pick(d, ['term', 'definition', 'both']), learn: pick(d, [{ roundSize: randInt(d, 1, 8) }, { roundSize: 7, written: false }, { roundSize: 3, mc: false }, {}]) };
    const create = { seed: randInt(d, 0, 0xffffffff), now: T0 + randInt(d, 0, 100) * MIN };
    if (chance(d, 0.3)) {
      create.subset = pick(d, ['starred', 'learning', 'missed', { cardIds: ['c1', 'c2', 'c4', 'c6', 'c9'] }]);
      create.progress = fuzzProgress(d, cardIdsOf(cards));
    } else if (chance(d, 0.3)) create.progress = fuzzProgress(d, cardIdsOf(cards));
    const run = new Run(cards, options, create);
    play(d, run, cardIdsOf(cards), 90, 0.25 + d() * 0.65);
    run.emit();
  }
}

// ---------------------------------------------------------------------------
// 4. Restored states: stored JSON (valid, partial or corrupt) read by the engine, then played on

const JUNK = ['x', 5, -3, 0, null, true, false, [], {}, '7', 2.5];

function mutate(d, raw) {
  const keys = Object.keys(raw);
  const order = Array.isArray(raw.order) ? raw.order : [];
  const anyId = () => (order.length ? pick(d, order) : 'ghost');
  const list = (key) => {
    if (!Array.isArray(raw[key])) raw[key] = [];
    return raw[key];
  };
  const map = (key) => {
    if (!isObj(raw[key])) raw[key] = {};
    return raw[key];
  };
  switch (randInt(d, 0, 21)) {
    case 0:
      if (keys.length) delete raw[pick(d, keys)];
      break;
    case 1:
      if (keys.length) raw[pick(d, keys)] = pick(d, JUNK);
      break;
    case 2: {
      const l = list('order');
      const r = d();
      if (r < 0.3) l.push(pick(d, ['ghost', 5, null, '', anyId()]));
      else if (r < 0.5 && l.length) l.push(l[0]);
      else if (r < 0.7) l.reverse();
      else if (r < 0.8) l.length = Math.max(0, l.length - 1);
      else raw.order = pick(d, JUNK);
      break;
    }
    case 3:
      map('stage')[anyId()] = pick(d, [-1, 0, 1, 2, 3, 1.5, 'x', null, true, 7]);
      break;
    case 4:
      list(pick(d, ['active', 'initiallyMastered'])).push(pick(d, ['ghost', anyId(), null, 5]));
      break;
    case 5:
      map(pick(d, ['seen', 'retried']))[pick(d, [anyId(), 'ghost'])] = pick(d, [true, false, 1, 'yes', null]);
      break;
    case 6:
      map('misses')[pick(d, [anyId(), 'ghost'])] = pick(d, [-2, 'x', null, true, 0, 1, 3]);
      break;
    case 7:
      list('queue').push(
        pick(d, [
          null,
          'junk',
          [],
          { cardId: 'ghost', type: 'mc' },
          { cardId: anyId() },
          { cardId: anyId(), type: 'mc', choices: [{ cardId: anyId(), text: 'x' }] },
          { qid: '', cardId: anyId(), type: 'mc', ask: 'definition', choices: [{ cardId: anyId(), text: 'a' }, { cardId: 'zz', text: 5 }, null, { cardId: '' }] },
          { qid: 'q', cardId: anyId(), type: 'written', retryChoices: [{ cardId: anyId(), text: 'a' }, { cardId: 'zz', text: 'b' }, { cardId: 'zz', text: 'c' }] },
          { cardId: 5, type: 'written' },
        ]),
      );
      break;
    case 8: {
      const q = list('queue');
      if (q.length) {
        const r = d();
        if (r < 0.3) q.shift();
        else if (r < 0.5) q.reverse();
        else if (r < 0.7 && isObj(q[0])) q[0].type = pick(d, ['mc', 'written', 'x']);
        else if (isObj(q[0])) delete q[0][pick(d, ['qid', 'choices', 'retryChoices', 'ask'])];
      }
      break;
    }
    case 9:
      list('roundLog').push(pick(d, [null, 'x', { cardId: 'ghost', correct: true }, { cardId: anyId(), correct: 'yes', stageAfter: 9 }, { qid: 5, cardId: anyId(), type: 'mc', correct: true, stageAfter: 1 }, { cardId: anyId(), correct: false }]));
      break;
    case 10:
      list('rounds').push(
        pick(d, [
          null,
          'x',
          [],
          {},
          { round: 2.5, answered: -3, correct: 'x', cardIds: 'x' },
          { round: -1, answered: 3, correct: 5, cardIds: [anyId(), anyId(), 'ghost', 7] },
          { round: typeof raw.round === 'number' ? raw.round : 1, answered: 2, correct: 1, cardIds: [anyId()] },
        ]),
      );
      break;
    case 11:
      raw.last = pick(d, [null, 'x', {}, { cardId: 'ghost' }, { cardId: anyId(), correct: false, stageBefore: 1, type: 'mc', ask: 'definition' }, { qid: 3, cardId: anyId(), correct: false, stageBefore: 'x' }]);
      break;
    case 12:
      raw.learn = pick(d, [{ roundSize: 'x' }, { roundSize: 0.5 }, { mc: false, written: false }, null, 'x', [], { roundSize: 2, mc: false }, { roundSize: 3.9, written: false }]);
      break;
    case 13:
      raw.subset = pick(d, ['starred', 'bogus', { cardIds: ['c1', 5, null, ''] }, null, [], { cardIds: 'x' }]);
      break;
    case 14:
      raw.round = pick(d, [0, -2, 2.5, '3', 7, 2]);
      break;
    case 15:
      raw[pick(d, ['startedAt', 'updatedAt'])] = pick(d, ['x', null, -5, 0, T0 + 1, true]);
      break;
    case 16:
      raw.finishedAt = pick(d, ['x', T0, null, 0, true]);
      break;
    case 17:
      raw[pick(d, ['elapsedMs', 'answered', 'correct'])] = pick(d, [-50, 'x', 12345.5, null, 0, 3, 100]);
      break;
    case 18:
      raw.answerWith = pick(d, ['both', 'definition', 'x', null]);
      break;
    case 19:
      // A stuck state: the round's questions fell out of the queue.
      raw.queue = [];
      if (chance(d, 0.5)) raw.roundLog = [];
      break;
    case 20:
      if (Array.isArray(raw.rounds) && raw.rounds.length) {
        const r = raw.rounds[raw.rounds.length - 1];
        if (isObj(r)) r.round = raw.round;
      }
      break;
    default:
      raw.feedback = { qid: 'x', cardId: anyId(), type: 'mc' };
      break;
  }
}

function restore(d, raw, cards, seed, progress, steps, pCorrect) {
  const run = new Run(cards, null, { seed, progress }, raw);
  const ids = cardIdsOf(cards).concat(['nope']);
  let t = run.t;
  for (let i = 0; i < steps; i++) {
    t = advance(d, t);
    run.do(randomAction(d, run, t, ids, pCorrect));
  }
  run.emit();
}

// 4a. The partial and stuck states of the JS test, and junk.
{
  const d = mulberry32(5);
  const partial = {
    order: ['a', 'b', 'a'],
    stage: { a: 1, b: 7 },
    active: ['a', 'ghost'],
    queue: [{ cardId: 'a', type: 'mc', choices: [{ cardId: 'a', text: 'x' }] }, { cardId: 'ghost', type: 'mc' }, 'junk'],
    misses: { a: -3, ghost: 2 },
  };
  const ab = [
    { id: 'a', term: 'oui', definition: 'ja' },
    { id: 'b', term: 'non', definition: 'nein' },
  ];
  restore(d, partial, ab, 1, {}, 2, 1);
  const stuck = { order: ['a'], stage: { a: 0 }, active: [], queue: [], round: 1 };
  restore(d, stuck, [{ id: 'a', term: 'oui', definition: 'ja' }], 1, {}, 3, 0.5);
  for (const raw of [null, 'x', 5, [], {}, { order: 'x' }, { order: [1, 2, 3], stage: [2, 2, 2] }]) restore(d, raw, makeCards(3), 1, {}, 3, 0.5);
}

// 4b. Round trip of real states (unchanged), then corrupted copies of them.
{
  const d = mulberry32(31337);
  for (let k = 0; k < 200; k++) {
    const n = randInt(d, 1, 9);
    const cards = chance(d, 0.6) ? makeCards(n) : fuzzCards(d, n, true);
    const options = { answerWith: pick(d, ['term', 'definition', 'both']), learn: { roundSize: randInt(d, 1, 6), mc: chance(d, 0.85), written: chance(d, 0.85) } };
    const create = { seed: randInt(d, 0, 0xffffffff), now: T0 };
    if (chance(d, 0.3)) create.progress = fuzzProgress(d, cardIdsOf(cards));
    const base = new Run(cards, options, create);
    play(d, base, cardIdsOf(cards), randInt(d, 0, 30), 0.55);
    const raw = clone(base.s);
    if (k % 5 !== 0) {
      const mutations = randInt(d, 1, 4);
      for (let m = 0; m < mutations; m++) mutate(d, raw);
    }
    restore(d, raw, base.cards, randInt(d, 0, 0xffffffff), chance(d, 0.5) ? clone(base.progress) : fuzzProgress(d, cardIdsOf(cards)), randInt(d, 0, 8), 0.5);
  }
}

cases.emit();
