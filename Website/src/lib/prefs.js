// App preferences that are not part of the library and never go into a backup, like the
// Mac app's UserDefaults: sound effects, flashcard and exam settings, voices, the day the
// Lernserie was last celebrated. Raw localStorage under 'wortschatz:v1:pref:<name>' (JSON),
// with an in-memory fallback when storage is blocked. Safe to import anywhere.

const PREFIX = 'wortschatz:v1:pref:';

// Every preference in one place (the Mac key names).
export const PREF = Object.freeze({
  soundEffects: 'soundEffects', // boolean, default true
  flashcardsFront: 'flashcards.front', // 'term' | 'definition', default 'term'
  flashcardsShuffle: 'flashcards.shuffle', // boolean, default false
  examSettings: 'exam.settings', // ExamSettings JSON (src/core/exam.js)
  learnReview: 'learn.review', // boolean, default false (Wiederholungsfragen)
  streakCelebrated: 'dailyStreakCelebrated', // 'YYYY-MM-DD'
  voices: 'voices', // { [lang]: voiceURI }
});

const memory = new Map();
const listeners = new Set();

function storage() {
  try {
    return typeof globalThis.localStorage === 'object' ? globalThis.localStorage : null;
  } catch {
    return null;
  }
}

// The stored value, or `fallback` when there is none or it cannot be read.
export function getPref(name, fallback = null) {
  const key = PREFIX + name;
  let raw = null;
  try {
    const s = storage();
    raw = s ? s.getItem(key) : null;
  } catch {
    raw = null;
  }
  if (raw == null) return memory.has(key) ? memory.get(key) : fallback;
  try {
    const value = JSON.parse(raw);
    return value === null || value === undefined ? fallback : value;
  } catch {
    return fallback;
  }
}

// Stores `value` (null removes it) and tells the listeners. Never throws.
export function setPref(name, value) {
  const key = PREFIX + name;
  if (value === null || value === undefined) memory.delete(key);
  else memory.set(key, value);
  try {
    const s = storage();
    if (s) {
      if (value === null || value === undefined) s.removeItem(key);
      else s.setItem(key, JSON.stringify(value));
    }
  } catch {
    /* storage full or blocked: the memory copy lasts until the app closes */
  }
  for (const fn of [...listeners]) {
    try {
      fn(name, value);
    } catch {
      /* a broken listener must not stop the others */
    }
  }
}

// fn(name, value) after every setPref; returns `off`.
export function onPrefChange(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
