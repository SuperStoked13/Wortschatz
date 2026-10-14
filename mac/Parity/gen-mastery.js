// Parity fixture for src/core/mastery.js → Fixtures/mastery.json. Run with TZ=Europe/Zurich.
// fns: normalizeProgress [p], cardStatus [p], setProgress [set, map], studyStreak [activity, now],
//      applyAnswer [prev, correct, at], applyOverride [prev],
//      sequence [ops] → progress and status after each op (op: {correct, at} | {override: true})
// Inputs may be any JSON (garbage included): Swift decodes progress with CardProgress(json:)
// (nil for non-objects), sets with VocabSet(json:), activities as [String: Int].
import {
  MASTERY_STREAK,
  normalizeProgress,
  cardStatus,
  setProgress,
  studyStreak,
  applyAnswer,
  applyOverride,
} from '../../Website/src/core/mastery.js';
import { dateKey } from '../../Website/src/lib/time.js';
import { Cases, mulberry32, randInt, pick, chance } from './lib.js';

const cases = new Cases('mastery');
cases.add('MASTERY_STREAK', [], MASTERY_STREAK);

// 1. Inputs of tests/mastery.test.js
const NOW = new Date(2026, 9, 11, 15, 0, 0).getTime();
const day = (offset, base = NOW) => {
  const d = new Date(base);
  d.setHours(12, 0, 0, 0);
  d.setDate(d.getDate() + offset);
  return dateKey(d.getTime());
};
const testProgress = [
  undefined, null, { correct: 0, incorrect: 0, streak: 0 }, 'garbage', { correct: 1, incorrect: 0, streak: 1 },
  { correct: 0, incorrect: 3, streak: 0 }, { correct: 2, incorrect: 0, streak: 2 }, { correct: 9, incorrect: 4, streak: 5 },
  { correct: 9, incorrect: 4, streak: 1 }, { correct: 1, incorrect: 0, streak: 1, streakBefore: 0, lastResult: 'correct', lastAnsweredAt: 5 },
  { correct: -3, incorrect: 'x', streak: 2.7, lastResult: 'maybe', lastAnsweredAt: NaN },
];
for (const p of testProgress) {
  const arg = p === undefined ? null : p;
  cases.add('normalizeProgress', [arg], normalizeProgress(p));
  cases.add('cardStatus', [arg], cardStatus(p));
  cases.add('applyOverride', [arg], applyOverride(p));
  cases.add('applyAnswer', [arg, true, 1000], applyAnswer(p, true, 1000));
  cases.add('applyAnswer', [arg, false, 2000], applyAnswer(p, false, 2000));
}
const testSets = [
  [{ cards: [{ id: 'a' }, { id: 'b' }, { id: 'c' }, { id: 'd' }] }, {
    a: { correct: 2, incorrect: 0, streak: 2 }, b: { correct: 1, incorrect: 1, streak: 0 },
    c: { correct: 1, incorrect: 0, streak: 1 }, orphan: { correct: 5, incorrect: 0, streak: 5 },
  }],
  [null, null],
  [{ cards: [{ id: 'x' }] }, {}],
  [{ cards: [{ id: 'x' }, { id: 'y' }] }, { x: { streak: 2, correct: 2 }, y: { streak: 3, correct: 3 } }],
  [{ cards: [{ id: 'a' }, { id: 'b' }, { id: 'c' }] }, { a: { streak: 2, correct: 2 }, b: { streak: 2, correct: 2 } }],
];
const cards200 = Array.from({ length: 200 }, (_, i) => ({ id: `c${i}` }));
const almost = {};
for (let i = 0; i < 199; i++) almost[`c${i}`] = { correct: 2, streak: 2 };
testSets.push([{ cards: cards200 }, almost], [{ cards: cards200 }, { c0: { correct: 2, streak: 2 } }]);
for (const [set, map] of testSets) cases.add('setProgress', [set, map], setProgress(set, map));

const streakTests = [
  [{}, NOW], [null, NOW], [{ [day(0)]: 12, [day(-1)]: 3, [day(-2)]: 7 }, NOW], [{ [day(-1)]: 4, [day(-2)]: 1 }, NOW],
  [{ [day(-2)]: 5, [day(-3)]: 5, [day(-10)]: 1, [day(-11)]: 1, [day(-12)]: 1, [day(-13)]: 1 }, NOW],
  [{ [day(0)]: 2, [day(-1)]: 0, [day(-2)]: 9, 'not-a-date': 4, '2026-02-31': 3 }, NOW],
  [{ '2027-01-02': 1, '2027-01-01': 1, '2026-12-31': 1, '2026-12-30': 1 }, new Date(2027, 0, 2, 8, 0, 0).getTime()],
];
const dstBase = new Date(2026, 10, 2, 9, 0, 0).getTime();
const dstActivity = {};
for (let i = 0; i < 14; i++) dstActivity[day(-i, dstBase)] = 1;
streakTests.push([dstActivity, dstBase]);
for (const [activity, now] of streakTests) cases.add('studyStreak', [activity, now], studyStreak(activity, now));

// 2. Seeded fuzz
const rng = mulberry32(11102026);
const NUMS = [0, 1, 2, 3, 5, 7, 10, -1, -3, 2.7, 0.5, 1.9999, 123456, -0.5, 99];
function fuzzValue() {
  return pick(rng, [
    pick(rng, NUMS), pick(rng, NUMS), pick(rng, NUMS), 'x', '5', true, false, null, undefined, [], {},
  ]);
}
function fuzzProgress() {
  const r = rng();
  if (r < 0.05) return pick(rng, [null, 'garbage', 5, true, [], [1, 2]]);
  const p = {};
  for (const key of ['correct', 'incorrect', 'streak', 'streakBefore']) {
    if (chance(rng, 0.85)) {
      const v = chance(rng, 0.8) ? randInt(rng, 0, 6) : fuzzValue();
      if (v !== undefined) p[key] = v;
    }
  }
  if (chance(rng, 0.8)) p.lastResult = pick(rng, ['correct', 'incorrect', 'correct', 'incorrect', 'maybe', null, 3, '']);
  if (chance(rng, 0.7)) p.lastAnsweredAt = pick(rng, [1760000000000 + randInt(rng, 0, 1e9), 0, -5, 1.5, 'x', null, true]);
  return p;
}
for (let i = 0; i < 1500; i++) {
  const p = fuzzProgress();
  cases.add('normalizeProgress', [p], normalizeProgress(p));
  cases.add('cardStatus', [p], cardStatus(p));
  cases.add('applyOverride', [p], applyOverride(p));
  const at = 1760000000000 + randInt(rng, 0, 1e10);
  const correct = chance(rng, 0.5);
  cases.add('applyAnswer', [p, correct, at], applyAnswer(p, correct, at));
}

// Answer/override sequences
for (let i = 0; i < 300; i++) {
  const ops = [];
  let t = 1760000000000 + randInt(rng, 0, 1e9);
  const n = randInt(rng, 1, 14);
  for (let k = 0; k < n; k++) {
    t += randInt(rng, 1000, 1e7);
    ops.push(chance(rng, 0.25) ? { override: true } : { correct: chance(rng, 0.6), at: t });
  }
  let p;
  const out = [];
  for (const op of ops) {
    p = op.override ? applyOverride(p) : applyAnswer(p, op.correct, op.at);
    out.push({ progress: p, status: cardStatus(p) });
  }
  cases.add('sequence', [ops], out);
}

// setProgress: random sets and maps
for (let i = 0; i < 500; i++) {
  const n = randInt(rng, 0, 40);
  const cards = [];
  for (let k = 0; k < n; k++) cards.push(chance(rng, 0.97) ? { id: `c${randInt(rng, 0, 50)}`, term: `t${k}` } : { term: 'no id' });
  const map = {};
  const m = randInt(rng, 0, 45);
  for (let k = 0; k < m; k++) map[`c${randInt(rng, 0, 55)}`] = fuzzProgress();
  const set = chance(rng, 0.95) ? { id: `s${i}`, cards } : pick(rng, [null, {}, { cards: 'x' }]);
  const mapArg = chance(rng, 0.95) ? map : pick(rng, [null, 'x', []]);
  cases.add('setProgress', [set, mapArg], setProgress(set, mapArg));
}

// studyStreak: runs of days with gaps around random "now" values (incl. DST days and midnight)
const lastSunday = (y, m) => {
  const d = new Date(y, m, 0);
  return d.getDate() - d.getDay();
};
const BAD_KEYS = ['not-a-date', '2026-02-31', '2026-13-01', '2026-00-10', '0099-01-01', '2024-02-29', '2023-02-29', ' 2026-01-01', '2026-1-01', '20260101', '2100-02-29', '2000-02-29'];
for (let i = 0; i < 800; i++) {
  const y = randInt(rng, 2015, 2035);
  let now;
  if (chance(rng, 0.3)) {
    const m = pick(rng, [3, 10]);
    now = new Date(y, m - 1, lastSunday(y, m) + randInt(rng, -1, 2), randInt(rng, 0, 23), randInt(rng, 0, 59), randInt(rng, 0, 59)).getTime();
  } else {
    now = new Date(y, randInt(rng, 0, 11), randInt(rng, 1, 28), pick(rng, [0, 0, 1, 12, 23, 23, randInt(rng, 0, 23)]), randInt(rng, 0, 59)).getTime();
  }
  const activity = {};
  let offset = randInt(rng, -3, 1);
  const runs = randInt(rng, 0, 5);
  for (let r = 0; r < runs; r++) {
    const len = randInt(rng, 1, 20);
    for (let k = 0; k < len; k++) activity[day(offset - k, now)] = chance(rng, 0.9) ? randInt(rng, 1, 40) : pick(rng, [0, -2]);
    offset -= len + randInt(rng, 1, 6);
  }
  if (chance(rng, 0.3)) activity[pick(rng, BAD_KEYS)] = randInt(rng, 1, 5);
  cases.add('studyStreak', [activity, now], studyStreak(activity, now));
}

cases.emit();
