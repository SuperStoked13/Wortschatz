// Sound synthesis (src/lib/sounds.js, port of the Mac app's SoundEffects.swift) and prefs.
import { test, expect, run } from './harness.js';
import { SOUNDS, SAMPLE_RATE, renderSound, studyStepSound, soundEffectsEnabled, setSoundEffectsEnabled } from '../src/lib/sounds.js';
import { getPref, setPref, onPrefChange } from '../src/lib/prefs.js';

test('every sound renders, stays in range and ends in silence', () => {
  expect(SOUNDS).toEqual(['correct', 'wrong', 'streak', 'roundDone', 'finished', 'dailyStreak', 'know', 'stillLearning', 'undo']);
  for (const name of SOUNDS) {
    const s = renderSound(name);
    expect(s.length).toBeGreaterThan(SAMPLE_RATE * 0.2);
    let peak = 0;
    for (const v of s) peak = Math.max(peak, Math.abs(v));
    expect(peak).toBeGreaterThan(0.01);
    expect(peak).toBeLessThanOrEqual(1);
    expect(Math.abs(s[s.length - 1])).toBeLessThan(1e-6);
  }
});

test('lengths follow the longest note (7 × decay) or swish, plus 20 ms', () => {
  // correct: second note at 0.075 s with decay 0.13 → 0.075 + 0.91 + 0.02.
  expect(renderSound('correct').length).toBe(Math.floor((0.075 + 0.13 * 7 + 0.02) * SAMPLE_RATE));
  // undo: only a 0.2 s swish.
  expect(renderSound('undo').length).toBe(Math.floor((0.2 + 0.02) * SAMPLE_RATE));
});

test('the noise is the same every time', () => {
  const a = renderSound('know');
  const b = renderSound('know');
  expect(Array.from(a.slice(1000, 1010))).toEqual(Array.from(b.slice(1000, 1010)));
});

test('unknown sounds throw', () => {
  expect(() => renderSound('boing')).toThrow();
});

test('study steps: fanfares first, then the answer; «Weiss ich nicht» is quiet', () => {
  expect(studyStepSound({ finished: true, roundDone: true, answer: 'correct' })).toBe('finished');
  expect(studyStepSound({ roundDone: true, answer: 'wrong' })).toBe('roundDone');
  expect(studyStepSound({ answer: 'correct' })).toBe('correct');
  expect(studyStepSound({ answer: 'correct', milestone: true })).toBe('streak');
  expect(studyStepSound({ answer: 'wrong' })).toBe('wrong');
  expect(studyStepSound({ answer: 'dontKnow' })).toBe(null);
  expect(studyStepSound({})).toBe(null);
});

test('prefs fall back to memory without localStorage; sound effects default on', () => {
  expect(getPref('nope', 'x')).toBe('x');
  expect(soundEffectsEnabled()).toBe(true);
  const seen = [];
  const off = onPrefChange((name, value) => seen.push([name, value]));
  setSoundEffectsEnabled(false);
  expect(soundEffectsEnabled()).toBe(false);
  setPref('soundEffects', null);
  expect(soundEffectsEnabled()).toBe(true);
  off();
  setPref('other', 1);
  expect(seen).toEqual([['soundEffects', false], ['soundEffects', null]]);
});

await run('sounds.test.js');
