// The answer streak of the study screens (src/screens/answer-streak.js): the counting
// rules of the Mac app's AnswerStreak.swift, its milestones and texts.
import { test, expect, run } from './harness.js';
import {
  STREAK_MILESTONE_STEP,
  STREAK_VISIBLE_FROM,
  STREAK_START,
  isStreakMilestone,
  recordStreak,
  overrideStreak,
  streakVisible,
  streakLabel,
  streakTitle,
  bestStreakText,
} from '../src/screens/answer-streak.js';

const answers = (list, from = STREAK_START) => list.reduce((s, ok) => recordStreak(s, ok), from);

test('Correct answers count up, a miss resets to zero and best keeps the longest run', () => {
  let s = answers([true, true, true]);
  expect(s.current).toBe(3);
  expect(s.best).toBe(3);
  s = recordStreak(s, false);
  expect(s.current).toBe(0);
  expect(s.best).toBe(3);
  s = answers([true, true], s);
  expect(s.current).toBe(2);
  expect(s.best).toBe(3);
  s = answers([true, true], s);
  expect(s.best).toBe(4);
});

test('«Ich hatte recht» gives back the run the miss ended, plus one', () => {
  let s = answers([true, true, true, true, false]);
  expect(s.current).toBe(0);
  s = overrideStreak(s);
  expect(s.current).toBe(5);
  expect(s.milestone).toBe(true);
  expect(s.best).toBe(5);
  // Without a run before the miss it is one in a row.
  expect(overrideStreak(recordStreak(STREAK_START, false)).current).toBe(1);
  // A correct answer forgets the ended run.
  s = answers([true, true, false, true]);
  expect(overrideStreak(s).current).toBe(1);
});

test('A milestone every five, only when the count just grew', () => {
  expect(STREAK_MILESTONE_STEP).toBe(5);
  expect([0, 1, 4, 5, 6, 10, 15, 21].map(isStreakMilestone)).toEqual([false, false, false, true, false, true, true, false]);
  const four = answers([true, true, true, true]);
  expect(four.milestone).toBe(false);
  const five = recordStreak(four, true);
  expect(five.milestone).toBe(true);
  expect(recordStreak(five, true).milestone).toBe(false);
  // A miss never reaches a milestone.
  expect(recordStreak(five, false).milestone).toBe(false);
});

test('Records are new frozen objects; the input stays as it was', () => {
  const s = answers([true]);
  const next = recordStreak(s, true);
  expect(s.current).toBe(1);
  expect(next.current).toBe(2);
  expect(Object.isFrozen(next)).toBe(true);
  expect(Object.isFrozen(STREAK_START)).toBe(true);
  // Garbage in: a fresh streak.
  expect(recordStreak(null, true)).toEqual({ current: 1, best: 1, milestone: false, endedByMiss: 0 });
});

test('The flame shows from three in a row; texts say «N richtig in Folge»', () => {
  expect(STREAK_VISIBLE_FROM).toBe(3);
  expect([0, 2, 3, 12].map(streakVisible)).toEqual([false, false, true, true]);
  expect(streakLabel(7)).toBe('7 richtig in Folge');
  expect(streakTitle(10)).toBe('10 richtig in Folge!');
  expect(bestStreakText(2)).toBe(null);
  expect(bestStreakText(3)).toBe('Beste Serie: 3 richtig in Folge');
  expect([streakLabel(5), streakTitle(5), bestStreakText(5)].join(' ').includes('ß')).toBe(false);
});

await run('answer-streak.test.js');
