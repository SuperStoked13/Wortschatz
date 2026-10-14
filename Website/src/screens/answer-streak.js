// Correct answers in a row on a study screen (Lernen, Schreiben): the flame next to the
// question with a milestone every five (port of the Mac app's AnswerStreak.swift). It lives as
// long as the screen, so every visit starts at zero and nothing is stored; the daily
// Lernserie is the streak that lasts. Pure functions over a small immutable record; the
// screens keep the record in their context and draw it with attachStreakBadge (write-views.js).

// A milestone every this many correct answers in a row (5, 10, 15 …).
export const STREAK_MILESTONE_STEP = 5;
// The badge shows the flame from this many on.
export const STREAK_VISIBLE_FROM = 3;

// current: answers in a row now; best: the longest run of this visit; milestone: the last
// change reached a milestone (its sound is the streak fanfare, its title «N richtig in Folge!»);
// endedByMiss: the run the last miss ended, given back by «Ich hatte recht».
export const STREAK_START = Object.freeze({ current: 0, best: 0, milestone: false, endedByMiss: 0 });

const count = (v) => (Number.isInteger(v) && v > 0 ? v : 0);

function normalize(streak) {
  const s = streak && typeof streak === 'object' ? streak : STREAK_START;
  return { current: count(s.current), best: count(s.best), milestone: !!s.milestone, endedByMiss: count(s.endedByMiss) };
}

export function isStreakMilestone(n) {
  return count(n) > 0 && n % STREAK_MILESTONE_STEP === 0;
}

function settle(s, grew) {
  return Object.freeze({ ...s, best: Math.max(s.best, s.current), milestone: grew && isStreakMilestone(s.current) });
}

// An answer was recorded: correct → one more; wrong or «Weiss ich nicht» → back to 0,
// remembering the run that ended. (Copy steps are no answers and never come here.)
export function recordStreak(streak, correct) {
  const s = normalize(streak);
  if (correct) return settle({ ...s, current: s.current + 1, endedByMiss: 0 }, true);
  return settle({ ...s, current: 0, endedByMiss: s.current }, false);
}

// «Ich hatte recht» / «Als richtig zählen»: the miss counts as correct, so the run it ended
// goes on.
export function overrideStreak(streak) {
  const s = normalize(streak);
  return settle({ ...s, current: s.endedByMiss + 1, endedByMiss: 0 }, true);
}

// Whether the badge shows a count.
export function streakVisible(n) {
  return count(n) >= STREAK_VISIBLE_FROM;
}

// The badge's tooltip and accessible label: «7 richtig in Folge».
export function streakLabel(n) {
  return `${count(n)} richtig in Folge`;
}

// The title of a correct answer that reached a milestone, instead of the praise.
export function streakTitle(n) {
  return `${count(n)} richtig in Folge!`;
}

// The Learn finish screen's line, from three in a row on; null below.
export function bestStreakText(best) {
  return streakVisible(best) ? `Beste Serie: ${count(best)} richtig in Folge` : null;
}
