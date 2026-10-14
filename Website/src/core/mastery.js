// Card mastery status, set progress and study-streak computations.
// Pure and DOM-free (runs under jsc).

import { dateKey } from '../lib/time.js';

// A card counts as mastered after this many correct answers in a row
// (across rounds and sessions).
export const MASTERY_STREAK = 2;

const DATE_KEY_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

function count(v) {
  return typeof v === 'number' && Number.isFinite(v) && v > 0 ? Math.floor(v) : 0;
}

function isObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

// Returns a complete, well-typed CardProgress for any input (missing or
// partially corrupt entries become a fresh record).
export function normalizeProgress(p) {
  const src = isObject(p) ? p : {};
  const lastResult = src.lastResult === 'correct' || src.lastResult === 'incorrect' ? src.lastResult : null;
  const at = src.lastAnsweredAt;
  return {
    correct: count(src.correct),
    incorrect: count(src.incorrect),
    streak: count(src.streak),
    streakBefore: count(src.streakBefore),
    lastResult,
    lastAnsweredAt: typeof at === 'number' && Number.isFinite(at) ? at : null,
  };
}

export function cardStatus(progress) {
  if (!isObject(progress)) return 'new';
  if (count(progress.streak) >= MASTERY_STREAK) return 'mastered';
  if (count(progress.correct) + count(progress.incorrect) > 0) return 'learning';
  return 'new';
}

export function setProgress(set, progressMap) {
  const cards = set && Array.isArray(set.cards) ? set.cards : [];
  const map = isObject(progressMap) ? progressMap : {};
  let mastered = 0;
  let learning = 0;
  let fresh = 0;
  for (const card of cards) {
    const id = card && card.id;
    const entry = typeof id === 'string' && Object.prototype.hasOwnProperty.call(map, id) ? map[id] : undefined;
    const status = cardStatus(entry);
    if (status === 'mastered') mastered++;
    else if (status === 'learning') learning++;
    else fresh++;
  }
  const total = cards.length;
  let percent = total ? Math.round((mastered / total) * 100) : 0;
  // Never show 100 % before everything is mastered, nor 0 % once something is.
  if (mastered < total) percent = Math.min(percent, 99);
  if (mastered > 0) percent = Math.max(percent, 1);
  return { total, mastered, learning, fresh, percent };
}

// Day number (days since epoch) of a valid 'YYYY-MM-DD' key, else null.
function dayNumber(key) {
  const m = DATE_KEY_RE.exec(key);
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]) - 1;
  const d = Number(m[3]);
  const utc = Date.UTC(y, mo, d);
  const check = new Date(utc);
  if (check.getUTCFullYear() !== y || check.getUTCMonth() !== mo || check.getUTCDate() !== d) return null;
  return Math.round(utc / 86400000);
}

export function studyStreak(activity, now = Date.now()) {
  const counts = isObject(activity) ? activity : {};
  const answered = (key) => Object.prototype.hasOwnProperty.call(counts, key) && count(counts[key]) > 0;

  const todayKey = dateKey(now);
  const today = answered(todayKey) ? count(counts[todayKey]) : 0;

  // Walk back day by day in local time; noon avoids DST edge cases.
  const cursor = new Date(now);
  cursor.setHours(12, 0, 0, 0);
  if (!today) cursor.setDate(cursor.getDate() - 1);
  let current = 0;
  while (answered(dateKey(cursor.getTime()))) {
    current++;
    cursor.setDate(cursor.getDate() - 1);
  }

  const days = [];
  for (const key of Object.keys(counts)) {
    if (!answered(key)) continue;
    const n = dayNumber(key);
    if (n !== null) days.push(n);
  }
  days.sort((a, b) => a - b);
  let longest = 0;
  let run = 0;
  let prev = null;
  for (const d of days) {
    if (d === prev) continue;
    run = prev !== null && d === prev + 1 ? run + 1 : 1;
    prev = d;
    if (run > longest) longest = run;
  }

  return { current, today, longest: Math.max(longest, current) };
}

export function applyAnswer(prev, correct, at = Date.now()) {
  const p = normalizeProgress(prev);
  const time = typeof at === 'number' && Number.isFinite(at) ? at : Date.now();
  if (correct) {
    return {
      correct: p.correct + 1,
      incorrect: p.incorrect,
      streak: p.streak + 1,
      streakBefore: p.streak,
      lastResult: 'correct',
      lastAnsweredAt: time,
    };
  }
  return {
    correct: p.correct,
    incorrect: p.incorrect + 1,
    streak: 0,
    streakBefore: p.streak,
    lastResult: 'incorrect',
    lastAnsweredAt: time,
  };
}

// "Ich hatte recht": turns the last (incorrect) answer into a correct one.
// Anything else is returned unchanged, so a second override is a no-op.
export function applyOverride(prev) {
  const p = normalizeProgress(prev);
  if (p.lastResult !== 'incorrect') return p;
  return {
    ...p,
    correct: p.correct + 1,
    incorrect: Math.max(0, p.incorrect - 1),
    streak: p.streakBefore + 1,
    lastResult: 'correct',
  };
}
