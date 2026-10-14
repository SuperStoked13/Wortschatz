import { test, expect, run } from './harness.js';
import {
  MASTERY_STREAK,
  cardStatus,
  setProgress,
  studyStreak,
  applyAnswer,
  applyOverride,
  normalizeProgress,
} from '../src/core/mastery.js';
import { dateKey } from '../src/lib/time.js';

// Local timestamp `offset` days relative to 11 Oct 2026, 15:00.
const NOW = new Date(2026, 9, 11, 15, 0, 0).getTime();
const day = (offset, base = NOW) => {
  const d = new Date(base);
  d.setHours(12, 0, 0, 0);
  d.setDate(d.getDate() + offset);
  return dateKey(d.getTime());
};

test('MASTERY_STREAK is 2', () => {
  expect(MASTERY_STREAK).toBe(2);
});

test('cardStatus: new without progress', () => {
  expect(cardStatus(undefined)).toBe('new');
  expect(cardStatus(null)).toBe('new');
  expect(cardStatus({ correct: 0, incorrect: 0, streak: 0 })).toBe('new');
  expect(cardStatus('garbage')).toBe('new');
});

test('cardStatus: learning and mastered thresholds', () => {
  expect(cardStatus({ correct: 1, incorrect: 0, streak: 1 })).toBe('learning');
  expect(cardStatus({ correct: 0, incorrect: 3, streak: 0 })).toBe('learning');
  expect(cardStatus({ correct: 2, incorrect: 0, streak: 2 })).toBe('mastered');
  expect(cardStatus({ correct: 9, incorrect: 4, streak: 5 })).toBe('mastered');
  expect(cardStatus({ correct: 9, incorrect: 4, streak: 1 })).toBe('learning');
});

test('applyAnswer from nothing', () => {
  const p = applyAnswer(undefined, true, 1000);
  expect(p).toEqual({ correct: 1, incorrect: 0, streak: 1, streakBefore: 0, lastResult: 'correct', lastAnsweredAt: 1000 });
  const q = applyAnswer(undefined, false, 2000);
  expect(q).toEqual({ correct: 0, incorrect: 1, streak: 0, streakBefore: 0, lastResult: 'incorrect', lastAnsweredAt: 2000 });
});

test('status transitions: new -> learning -> mastered -> miss -> learning -> mastered', () => {
  let p;
  expect(cardStatus(p)).toBe('new');
  p = applyAnswer(p, true, 1);
  expect(cardStatus(p)).toBe('learning');
  p = applyAnswer(p, true, 2);
  expect(p.streak).toBe(2);
  expect(cardStatus(p)).toBe('mastered');
  p = applyAnswer(p, true, 3);
  expect(p.streak).toBe(3);
  expect(cardStatus(p)).toBe('mastered');
  p = applyAnswer(p, false, 4);
  expect(p.streak).toBe(0);
  expect(p.streakBefore).toBe(3);
  expect(cardStatus(p)).toBe('learning');
  p = applyAnswer(p, true, 5);
  expect(cardStatus(p)).toBe('learning');
  p = applyAnswer(p, true, 6);
  expect(cardStatus(p)).toBe('mastered');
  expect(p.correct).toBe(5);
  expect(p.incorrect).toBe(1);
  expect(p.lastAnsweredAt).toBe(6);
});

test('applyAnswer does not mutate its input', () => {
  const prev = { correct: 1, incorrect: 0, streak: 1, streakBefore: 0, lastResult: 'correct', lastAnsweredAt: 5 };
  const snapshot = JSON.stringify(prev);
  applyAnswer(prev, false, 6);
  expect(JSON.stringify(prev)).toBe(snapshot);
});

test('applyOverride restores the streak before the miss', () => {
  let p = applyAnswer(undefined, true, 1);
  p = applyAnswer(p, false, 2);
  expect(p.streakBefore).toBe(1);
  const o = applyOverride(p);
  expect(o.correct).toBe(2);
  expect(o.incorrect).toBe(0);
  expect(o.streak).toBe(2);
  expect(o.lastResult).toBe('correct');
  expect(cardStatus(o)).toBe('mastered');
  expect(o.lastAnsweredAt).toBe(2);
});

test('applyOverride is a no-op unless the last answer was incorrect', () => {
  const p = applyAnswer(undefined, true, 1);
  expect(applyOverride(p)).toEqual(p);
  const twice = applyOverride(applyOverride(applyAnswer(undefined, false, 1)));
  expect(twice.correct).toBe(1);
  expect(twice.incorrect).toBe(0);
  expect(twice.streak).toBe(1);
  expect(applyOverride(undefined)).toEqual(normalizeProgress(undefined));
});

test('normalizeProgress repairs corrupt entries', () => {
  expect(normalizeProgress({ correct: -3, incorrect: 'x', streak: 2.7, lastResult: 'maybe', lastAnsweredAt: NaN })).toEqual({
    correct: 0,
    incorrect: 0,
    streak: 2,
    streakBefore: 0,
    lastResult: null,
    lastAnsweredAt: null,
  });
});

test('setProgress counts statuses of the set cards only', () => {
  const set = { cards: [{ id: 'a' }, { id: 'b' }, { id: 'c' }, { id: 'd' }] };
  const map = {
    a: { correct: 2, incorrect: 0, streak: 2 },
    b: { correct: 1, incorrect: 1, streak: 0 },
    c: { correct: 1, incorrect: 0, streak: 1 },
    orphan: { correct: 5, incorrect: 0, streak: 5 },
  };
  expect(setProgress(set, map)).toEqual({ total: 4, mastered: 1, learning: 2, fresh: 1, percent: 25 });
});

test('setProgress edge cases', () => {
  expect(setProgress(null, null)).toEqual({ total: 0, mastered: 0, learning: 0, fresh: 0, percent: 0 });
  expect(setProgress({ cards: [{ id: 'x' }] }, {})).toEqual({ total: 1, mastered: 0, learning: 0, fresh: 1, percent: 0 });
  const all = setProgress({ cards: [{ id: 'x' }, { id: 'y' }] }, { x: { streak: 2, correct: 2 }, y: { streak: 3, correct: 3 } });
  expect(all.percent).toBe(100);
  expect(all.mastered).toBe(2);
});

test('setProgress percent never rounds to 100 or 0 misleadingly', () => {
  const cards = Array.from({ length: 200 }, (_, i) => ({ id: `c${i}` }));
  const almost = {};
  for (let i = 0; i < 199; i++) almost[`c${i}`] = { correct: 2, streak: 2 };
  expect(setProgress({ cards }, almost).percent).toBe(99);
  expect(setProgress({ cards }, { c0: { correct: 2, streak: 2 } }).percent).toBe(1);
  const three = { cards: [{ id: 'a' }, { id: 'b' }, { id: 'c' }] };
  expect(setProgress(three, { a: { streak: 2, correct: 2 }, b: { streak: 2, correct: 2 } }).percent).toBe(67);
});

test('studyStreak: empty activity', () => {
  expect(studyStreak({}, NOW)).toEqual({ current: 0, today: 0, longest: 0 });
  expect(studyStreak(null, NOW)).toEqual({ current: 0, today: 0, longest: 0 });
});

test('studyStreak: streak ending today', () => {
  const activity = { [day(0)]: 12, [day(-1)]: 3, [day(-2)]: 7 };
  expect(studyStreak(activity, NOW)).toEqual({ current: 3, today: 12, longest: 3 });
});

test('studyStreak: streak ending yesterday still counts', () => {
  const activity = { [day(-1)]: 4, [day(-2)]: 1 };
  expect(studyStreak(activity, NOW)).toEqual({ current: 2, today: 0, longest: 2 });
});

test('studyStreak: broken streak resets current but keeps longest', () => {
  const activity = {
    [day(-2)]: 5,
    [day(-3)]: 5,
    [day(-10)]: 1,
    [day(-11)]: 1,
    [day(-12)]: 1,
    [day(-13)]: 1,
  };
  const s = studyStreak(activity, NOW);
  expect(s.current).toBe(0);
  expect(s.today).toBe(0);
  expect(s.longest).toBe(4);
});

test('studyStreak: zero counts and invalid keys are ignored', () => {
  const activity = { [day(0)]: 2, [day(-1)]: 0, [day(-2)]: 9, 'not-a-date': 4, '2026-02-31': 3 };
  expect(studyStreak(activity, NOW)).toEqual({ current: 1, today: 2, longest: 1 });
});

test('studyStreak: across the end of daylight saving time', () => {
  const base = new Date(2026, 10, 2, 9, 0, 0).getTime(); // 2 Nov 2026
  const activity = {};
  for (let i = 0; i < 14; i++) activity[day(-i, base)] = 1;
  const s = studyStreak(activity, base);
  expect(s.current).toBe(14);
  expect(s.longest).toBe(14);
});

test('studyStreak: across month and year boundaries', () => {
  const base = new Date(2027, 0, 2, 8, 0, 0).getTime(); // 2 Jan 2027
  const activity = { '2027-01-02': 1, '2027-01-01': 1, '2026-12-31': 1, '2026-12-30': 1 };
  expect(studyStreak(activity, base)).toEqual({ current: 4, today: 1, longest: 4 });
});

await run('mastery.test.js');
