// Prüfung (exam): a vocabulary test over a set on one page, graded like a test at school with a
// Swiss grade from 1 to 6 (port of the Mac app's WortschatzCore/Exam.swift and the texts of its
// exam views). Owns the settings (lenient read, snapping to the choices offered), the sheet
// (scope, question count, questions), the marking in two grading passes, the result with its
// grade, and every German text the exam screens show. An exam records nothing: mastery stays
// with Lernen and Schreiben. Pure and DOM-free (runs under jsc); inputs are never mutated.

import { diffAnswer, splitAlternatives } from './grading.js';
import { gradeWithSynonyms } from './synonyms.js';
import { NOTE_LABELS, HINT_LABELS, plural, langName } from '../lib/labels.js';

/* ------------------------------------------------------------------ settings */

// Time limits offered in minutes (0 = none) and numbers of words (0 = all), as on the Mac.
export const MINUTE_CHOICES = Object.freeze([0, 5, 10, 15, 20, 30, 45]);
export const COUNT_CHOICES = Object.freeze([10, 15, 20, 30, 0]);
export const ANSWER_WITH = Object.freeze(['term', 'definition', 'both']);
export const TOLERANCES = Object.freeze(['strict', 'half', 'lenient']);

// "Prüfung einrichten" before anything was changed; kept for every set (PREF.examSettings).
export const DEFAULT_EXAM_SETTINGS = Object.freeze({ minutes: 10, count: 20, answerWith: 'term', tolerance: 'half', starredOnly: false });

// The choice nearest to `value` (the lower one on a tie); 0 ("none", "all") only for 0 or less.
export function nearestChoice(value, choices) {
  const positive = choices.filter((c) => c > 0).sort((a, b) => a - b);
  if (!(value > 0) || !positive.length) return 0;
  return positive.reduce((best, c) => (Math.abs(c - value) < Math.abs(best - value) ? c : best), positive[0]);
}

const isObject = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const finite = (v) => typeof v === 'number' && Number.isFinite(v);

// Lenient read of stored settings (an object or its JSON): every missing or invalid field takes
// its default, numbers snap to the nearest choice offered (so the setup page always has one
// selected), unknown keys (e.g. "examples" of an early Mac version) are dropped.
export function readExamSettings(raw) {
  let src = raw;
  if (typeof src === 'string') {
    try {
      src = JSON.parse(src);
    } catch {
      src = null;
    }
  }
  const o = isObject(src) ? src : {};
  const d = DEFAULT_EXAM_SETTINGS;
  return {
    minutes: finite(o.minutes) ? nearestChoice(o.minutes, MINUTE_CHOICES) : d.minutes,
    count: finite(o.count) ? nearestChoice(o.count, COUNT_CHOICES) : d.count,
    answerWith: ANSWER_WITH.includes(o.answerWith) ? o.answerWith : d.answerWith,
    tolerance: TOLERANCES.includes(o.tolerance) ? o.tolerance : d.tolerance,
    starredOnly: typeof o.starredOnly === 'boolean' ? o.starredOnly : d.starredOnly,
  };
}

// The settings with `patch` applied, read leniently again (what the setup page stores).
export function updateExamSettings(settings, patch) {
  return readExamSettings({ ...readExamSettings(settings), ...(isObject(patch) ? patch : {}) });
}

export function sameExamSettings(a, b) {
  const x = readExamSettings(a);
  const y = readExamSettings(b);
  return Object.keys(x).every((k) => x[k] === y[k]);
}

/* ----------------------------------------------------------------- tolerance */

const TOLERANCE_COPY = {
  strict: { title: 'Streng', points: 0, text: 'Nur ganz richtige Antworten geben einen Punkt.', caption: 'kein Punkt' },
  half: { title: 'Halber Punkt', points: 0.5, text: 'Ein kleiner Fehler kostet einen halben Punkt.', caption: 'je ½ Punkt' },
  lenient: { title: 'Grosszügig', points: 1, text: 'Kleine Fehler kosten nichts.', caption: 'ganzer Punkt' },
};

const toleranceCopy = (t) => TOLERANCE_COPY[t] || TOLERANCE_COPY.half;

// The points of an answer with a small mistake.
export const minorPoints = (tolerance) => toleranceCopy(tolerance).points;
export const toleranceTitle = (tolerance) => toleranceCopy(tolerance).title;
// What a small mistake costs (the setup caption and the results' list header).
export const toleranceText = (tolerance) => toleranceCopy(tolerance).text;
// The «Kleine Fehler» tile's caption on the results.
export const minorCaption = (tolerance) => toleranceCopy(tolerance).caption;

// Which mistakes are small (the setup note, the tooltips).
export const SMALL_MISTAKES_TEXT =
  'Kleine Fehler sind ein Tippfehler, fehlende Akzente, die Grossschreibung deutscher Nomen und ein fehlender Artikel oder ein fehlendes Pronomen. Ein falscher Artikel ist ein Fehler.';

// Notes of an answer that count as a small mistake ('case': a German noun's small first letter).
export const SMALL_MISTAKES = Object.freeze(['article', 'pronoun', 'case', 'accents', 'typo']);

// Forms that are no mistake at all (any capitals are fine outside German, where a noun's small
// first letter is noted as a small mistake).
export const ACCEPTED_FORMS = Object.freeze({
  articles: false,
  abbreviations: true,
  multipleAnswers: true,
  parentheses: true,
  ignoreCase: true,
  ignoreAccents: false,
  typos: false,
});

// The forms that are no mistake plus the small mistakes.
export const SMALL_MISTAKES_ALLOWED = Object.freeze({
  articles: true,
  abbreviations: true,
  multipleAnswers: true,
  parentheses: true,
  ignoreCase: true,
  ignoreAccents: true,
  typos: true,
});

/* --------------------------------------------------------------------- sheet */

// The parts of settings the sheet uses, as given (no snapping: that happens when they are read
// from storage); anything invalid takes its default.
function sheetOptions(settings) {
  const s = isObject(settings) ? settings : {};
  return {
    count: finite(s.count) && s.count > 0 ? Math.floor(s.count) : finite(s.count) ? 0 : DEFAULT_EXAM_SETTINGS.count,
    answerWith: ANSWER_WITH.includes(s.answerWith) ? s.answerWith : DEFAULT_EXAM_SETTINGS.answerWith,
    starredOnly: s.starredOnly === true,
  };
}

const str = (v) => (typeof v === 'string' ? v : v == null ? '' : String(v));
// JS trim, like the Mac's JSCompat.trim.
const trim = (v) => str(v).trim();
export const hasText = (v) => trim(v) !== '';

// The cards an exam can ask: both sides with text, each id once, in set order; only `cardIds`
// when given (a retake of the wrong ones), else only the starred ones when the settings ask for
// them and there are any.
export function examScope(cards, settings, cardIds = null) {
  const seen = new Set();
  let pool = (Array.isArray(cards) ? cards : []).filter((c) => {
    if (!isObject(c) || typeof c.id !== 'string' || !c.id || !hasText(c.term) || !hasText(c.definition) || seen.has(c.id)) return false;
    seen.add(c.id);
    return true;
  });
  if (Array.isArray(cardIds)) {
    const wanted = new Set(cardIds);
    pool = pool.filter((c) => wanted.has(c.id));
  } else if (sheetOptions(settings).starredOnly && pool.some((c) => c.starred === true)) {
    pool = pool.filter((c) => c.starred === true);
  }
  return pool;
}

// How many questions an exam over `available` cards asks.
export function questionCount(settings, available) {
  const { count } = sheetOptions(settings);
  return count > 0 ? Math.min(count, available) : available;
}

// How many questions the next exam asks (a retake asks every card it was given).
export function plannedCount(cards, settings, cardIds = null) {
  const available = examScope(cards, settings, cardIds).length;
  return Array.isArray(cardIds) ? available : questionCount(settings, available);
}

// Usable starred cards (the «Nur markierte (N)» row shows only when there are any).
export function starredCount(cards) {
  return examScope(cards, DEFAULT_EXAM_SETTINGS).filter((c) => c.starred === true).length;
}

// The set has no card with both sides filled in («Nichts zu prüfen»).
export function isEmptyForExam(cards) {
  return examScope(cards, DEFAULT_EXAM_SETTINGS).length === 0;
}

// Integer in [0, n) from the rng, clamped so a misbehaving rng never breaks an index.
function randomIndex(rng, n) {
  const r = Math.floor(rng() * n);
  if (!(r >= 0)) return 0;
  return r > n - 1 ? n - 1 : r;
}

// Fisher–Yates on a copy.
function shuffled(list, rng) {
  const a = list.slice();
  for (let i = a.length - 1; i > 0; i -= 1) {
    const j = randomIndex(rng, i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

/**
 * The exam sheet: `settings.count` cards of the scope (all for 0; a retake is limited too, as on
 * the Mac) in random order, numbered from 1, each asked on the side the settings say ('both': at
 * random per question). ask 'term' shows the definition and expects the term.
 * Returns [{ number, cardId, ask, prompt, expected, promptLang, answerLang }].
 */
export function makeQuestions(cards, settings, { termLang = 'other', defLang = 'other', cardIds = null, rng = Math.random } = {}) {
  const s = sheetOptions(settings);
  const random = typeof rng === 'function' ? rng : Math.random;
  const pool = examScope(cards, s, cardIds);
  const picked = shuffled(pool, random).slice(0, questionCount(s, pool.length));
  return picked.map((card, index) => {
    const ask = s.answerWith === 'both' ? (randomIndex(random, 2) === 0 ? 'term' : 'definition') : s.answerWith;
    const askTerm = ask === 'term';
    return {
      number: index + 1,
      cardId: card.id,
      ask,
      prompt: trim(askTerm ? card.definition : card.term),
      expected: trim(askTerm ? card.term : card.definition),
      promptLang: askTerm ? defLang : termLang,
      answerLang: askTerm ? termLang : defLang,
    };
  });
}

// The card as it was asked (the texts on the sheet, not the set's current ones).
export function questionCard(q) {
  const askTerm = q.ask === 'term';
  return { id: q.cardId, term: askTerm ? q.expected : q.prompt, definition: askTerm ? q.prompt : q.expected };
}

/* ------------------------------------------------------------------- marking */

// The labels of small mistakes, joined ("Artikel fehlte · Akzente"); null without any.
function noteText(notes) {
  const labels = notes.map((n) => NOTE_LABELS[n]).filter(Boolean);
  return labels.length ? labels.join(' · ') : null;
}

const smallOf = (notes) => (Array.isArray(notes) ? notes.filter((n) => SMALL_MISTAKES.includes(n)) : []);

/**
 * Marks one answer. `cards`: the set's cards (an answer that is right for another card with the
 * same prompt counts too). Returns { question, given (trimmed), mark: 'correct'|'minor'|'wrong'|
 * 'blank', points, note (string|null), synonym (bool), matched (the other card's answer|null) }.
 */
export function markAnswer(given, question, cards, tolerance) {
  const answer = trim(given);
  const item = { question, given: answer, mark: 'blank', points: 0, note: null, synonym: false, matched: null };
  if (!hasText(answer)) return item;
  const card = questionCard(question);
  const graded = (allowed) => gradeWithSynonyms(answer, card, cards, question.ask, allowed, question.answerLang);
  const matchedAnswer = (g) => (g.matchedCard ? trim(question.ask === 'term' ? g.matchedCard.term : g.matchedCard.definition) : null);

  const first = graded(ACCEPTED_FORMS);
  if (first.result.correct) {
    const small = smallOf(first.result.notes);
    const synonym = !!first.matchedCard;
    if (!small.length) return { ...item, mark: 'correct', points: 1, synonym, matched: matchedAnswer(first), note: synonym ? NOTE_LABELS.synonym : null };
    return { ...item, mark: 'minor', points: minorPoints(tolerance), synonym, matched: matchedAnswer(first), note: noteText(small) };
  }

  const second = graded(SMALL_MISTAKES_ALLOWED);
  if (second.result.correct) {
    return {
      ...item,
      mark: 'minor',
      points: minorPoints(tolerance),
      synonym: !!second.matchedCard,
      matched: matchedAnswer(second),
      note: noteText(smallOf(second.result.notes)) || NOTE_LABELS.typo,
    };
  }
  // A wrong article is a mistake, not a small one ("Falscher Artikel").
  const hint = second.result.hint;
  return { ...item, mark: 'wrong', note: (hint && HINT_LABELS[hint]) || null };
}

// The typed answer for question `number` (answers: a Map or a plain object by number).
export function answerFor(answers, number) {
  if (!answers) return '';
  const v = answers instanceof Map ? answers.get(number) : answers[number];
  return typeof v === 'string' ? v : '';
}

// Questions with a typed answer (anything but whitespace).
export function answeredCount(questions, answers) {
  return (Array.isArray(questions) ? questions : []).filter((q) => hasText(answerFor(answers, q.number))).length;
}

/* -------------------------------------------------------------------- result */

// The Swiss grade for `points` of `maxPoints`: 1 + 5 × points / maximum, rounded to tenths
// (6 = everything right, 4 = half the points, the pass mark). Computed in tenths in one step:
// 34.5 of 50 is exactly 4.45 and must round up to 4.5.
export function examGrade(points, maxPoints) {
  if (!(maxPoints > 0) || !Number.isFinite(points)) return 1;
  const clamped = Math.min(maxPoints, Math.max(0, points));
  return Math.round(10 + (50 * clamped) / maxPoints) / 10;
}

/**
 * Marks the whole sheet. Returns { items, tolerance, elapsedMs, timedOut, points, maxPoints,
 * grade }; the item list keeps the order of the sheet.
 */
export function evaluateExam(questions, answers, cards, tolerance, { elapsedMs = 0, timedOut = false } = {}) {
  const list = Array.isArray(questions) ? questions : [];
  const items = list.map((q) => markAnswer(answerFor(answers, q.number), q, cards, tolerance));
  const points = items.reduce((sum, it) => sum + it.points, 0);
  const maxPoints = items.length;
  return {
    items,
    tolerance: TOLERANCES.includes(tolerance) ? tolerance : DEFAULT_EXAM_SETTINGS.tolerance,
    elapsedMs: Number.isFinite(elapsedMs) ? Math.max(0, elapsedMs) : 0,
    timedOut: !!timedOut,
    points,
    maxPoints,
    grade: examGrade(points, maxPoints),
  };
}

export function markCount(result, mark) {
  return result.items.filter((it) => it.mark === mark).length;
}

// The cards worth practising: wrong, left blank, or with a small mistake (also under
// «Grosszügig», as on the Mac), each once, in the order of the sheet.
export function cardIdsToPractise(result) {
  const seen = new Set();
  const out = [];
  for (const it of result.items) {
    if (it.mark === 'correct' || seen.has(it.question.cardId)) continue;
    seen.add(it.question.cardId);
    out.push(it.question.cardId);
  }
  return out;
}

// "5.3", "6.0" (Swiss notation, always one decimal).
export function gradeText(grade) {
  const tenths = Math.round(grade * 10);
  return `${Math.trunc(tenths / 10)}.${Math.abs(tenths % 10)}`;
}

// "17.5" or "18" (points, halves where there are any).
export function pointsText(points) {
  const halves = Math.round(points * 2);
  return halves % 2 === 0 ? `${halves / 2}` : `${Math.trunc(halves / 2)}.5`;
}

// 4 and above passes.
export const passes = (grade) => grade >= 4;

// The results' title by grade.
export function verdict(grade) {
  if (grade >= 6) return 'Perfekt!';
  if (grade >= 5.5) return 'Hervorragend!';
  if (grade >= 5) return 'Sehr gut!';
  if (grade >= 4.5) return 'Gut gemacht!';
  if (grade >= 4) return 'Bestanden!';
  return 'Noch nicht genügend';
}

// Colour of the grade circle: green from 5, the accent from 4, amber below.
export function gradeTone(grade) {
  if (grade >= 5) return 'success';
  if (grade >= 4) return 'accent';
  return 'warning';
}

// Confetti from 5.5.
export const celebrates = (grade) => grade >= 5.5;

// "17.5 von 20 Punkten" ("1 Punkt" for a one-question exam).
export function scoreLine(result) {
  return `${pointsText(result.points)} von ${plural(result.maxPoints, 'Punkt', 'Punkten')}`;
}

// "17.5 von 20 Punkten in 8:41" (the time taken, rounded to seconds).
export function resultSubtitle(result) {
  return `${scoreLine(result)} in ${clockText(Math.round(result.elapsedMs / 1000))}`;
}

// What the screen reader hears after handing in: "Note 5.3. 17.5 von 20 Punkten."
export function resultAnnouncement(result) {
  return `Note ${gradeText(result.grade)}. ${scoreLine(result)}.`;
}

export const TIMED_OUT_LINE = 'Die Zeit war um, die Prüfung wurde abgegeben.';

// The mark's label in the results ("Richtig", "Halber Punkt", …).
export function markLabel(item) {
  switch (item.mark) {
    case 'correct':
      return 'Richtig';
    case 'minor':
      if (item.points === 1) return 'Richtig';
      if (item.points === 0.5) return 'Halber Punkt';
      return 'Kleiner Fehler';
    case 'wrong':
      return 'Falsch';
    default:
      return 'Keine Antwort';
  }
}

// The badge of a mark: ✓ green, ½ blue, ✗ red (also a small mistake worth nothing), – grey.
export function markBadge(item) {
  if (item.mark === 'correct' || (item.mark === 'minor' && item.points >= 1)) return 'correct';
  if (item.mark === 'minor' && item.points > 0) return 'half';
  if (item.mark === 'blank') return 'blank';
  return 'wrong';
}

// "1" / "½" / "0" and what a screen reader says for it.
export function itemPointsText(item) {
  if (item.points === 1) return '1';
  if (item.points === 0.5) return '½';
  return '0';
}

export function itemPointsLabel(item) {
  if (item.points === 1) return '1 Punkt';
  if (item.points === 0.5) return 'ein halber Punkt';
  return 'kein Punkt';
}

// "Gesucht war:" when the typed word was right in its own way (a synonym), else "Richtig:".
export function expectedLabel(item) {
  return item.mark === 'correct' || item.matched != null ? 'Gesucht war:' : 'Richtig:';
}

// Whether the results row shows the expected answer under the typed one.
export function showsExpected(item) {
  return item.mark !== 'correct' || item.synonym;
}

// Note chip: info for right answers and small mistakes, a warning with a lightbulb otherwise.
export function noteTone(item) {
  return item.mark === 'correct' || item.mark === 'minor' ? 'info' : 'warning';
}

// Tooltips of «Falsche lernen» and «Falsche prüfen».
export function learnMistakesTooltip(n) {
  return `Die ${plural(n, 'Frage', 'Fragen')} mit Fehlern in Lernen üben`;
}

export function retakeMistakesTooltip(n) {
  return `Eine neue Prüfung nur mit den ${plural(n, 'Frage', 'Fragen')} mit Fehlern`;
}

/**
 * The typed answer's character diff against the closest accepted variant of `expected`
 * (write-card.js closestDiff), or null when a diff would be noise (less than half of the typed
 * letters match: a different word). Parts: [{ type: 'same'|'del'|'add', text }].
 */
export function answerDiff(given, expected, lang) {
  const parts = closestDiff(given, expected, lang);
  const letters = (s) => Array.from(s.replace(/\s/g, '')).length;
  const same = parts.reduce((n, p) => n + (p.type === 'same' ? letters(p.text) : 0), 0);
  const typed = letters(str(given));
  if (typed === 0 || same / typed < 0.5) return null;
  return parts;
}

export function closestDiff(given, expected, lang) {
  const candidates = [str(expected)];
  try {
    for (const alt of splitAlternatives(str(expected), lang)) if (alt && !candidates.includes(alt)) candidates.push(alt);
  } catch {
    /* fall back to the full answer */
  }
  let best = null;
  let bestCost = Infinity;
  for (const target of candidates) {
    const parts = diffAnswer(given, target);
    const cost = parts.reduce((n, p) => n + (p.type === 'same' ? 0 : p.text.length), 0);
    if (cost < bestCost) {
      best = parts;
      bestCost = cost;
    }
  }
  return best || [];
}

// «Falsche lernen» without the shared helper (learn-start.js): the URL contract of Lernen with
// explicit cards, each id encoded and joined by ','; review asks mastered cards again too.
export function learnCardsPath(setId, cardIds, { review = false } = {}) {
  const ids = (Array.isArray(cardIds) ? cardIds : []).map((id) => encodeURIComponent(id)).join(',');
  return `/set/${encodeURIComponent(setId)}/learn?new=1&cards=${ids}${review ? '&review=1' : ''}`;
}

/* ---------------------------------------------------------------------- time */

const two = (n) => (n < 10 ? `0${n}` : `${n}`);

// "8:05", "1:02:05".
export function clockText(seconds) {
  const s = Math.max(0, Math.floor(Number(seconds) || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h > 0 ? `${h}:${two(m)}:${two(s % 60)}` : `${m}:${two(s % 60)}`;
}

// "8 Minuten 5 Sekunden" (screen readers).
export function spokenTime(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  const m = Math.floor(total / 60);
  const s = total % 60;
  if (m === 0) return plural(s, 'Sekunde', 'Sekunden');
  return s === 0 ? plural(m, 'Minute', 'Minuten') : `${plural(m, 'Minute', 'Minuten')} ${plural(s, 'Sekunde', 'Sekunden')}`;
}

/**
 * The status clock at `now` (all times in ms): the time left, rounded up, while a deadline runs
 * (amber in the last minute), else the time taken so far. Also says in how many ms the shown
 * second changes, so the screen redraws exactly then (and checks the deadline).
 * Returns { seconds, countdown, lastMinute, nextChangeMs }.
 */
export function clockState({ startedAt, deadline = null, now }) {
  if (deadline != null) {
    const left = Math.max(0, deadline - now);
    const seconds = Math.ceil(left / 1000);
    const rest = left % 1000;
    return { seconds, countdown: true, lastMinute: seconds <= 60, nextChangeMs: left <= 0 ? 0 : rest === 0 ? 1000 : rest };
  }
  const taken = Math.max(0, now - (startedAt == null ? now : startedAt));
  return { seconds: Math.floor(taken / 1000), countdown: false, lastMinute: false, nextChangeMs: 1000 - (taken % 1000) };
}

// The deadline of an exam started at `startedAt` (null without a time limit).
export function examDeadline(startedAt, minutes) {
  return minutes > 0 ? startedAt + minutes * 60000 : null;
}

// «Noch eine Minute» comes once, on exams longer than two minutes.
export const ONE_MINUTE_TEXT = 'Noch eine Minute';
export const ONE_MINUTE_MS = 60000;
export function warnsBeforeEnd(minutes) {
  return minutes * 60 > 120;
}

export const TIMED_OUT_TOAST = 'Die Zeit ist um. Deine Prüfung wurde abgegeben.';

/* --------------------------------------------------------------- setup texts */

// "Ohne Zeitlimit", "1 Minute", "10 Minuten".
export function minutesText(minutes) {
  return minutes <= 0 ? 'Ohne Zeitlimit' : plural(minutes, 'Minute', 'Minuten');
}

// The time limit menu: "Ohne", "5 Min." …
export function minuteChoiceLabel(minutes) {
  return minutes === 0 ? 'Ohne' : `${minutes} Min.`;
}

// The word counts offered for `available` cards: only sizes below it, plus «Alle».
export function countChoicesFor(available) {
  return COUNT_CHOICES.filter((c) => c === 0 || c < available);
}

export function countChoiceLabel(count, available) {
  return count === 0 ? `Alle ${available}` : String(count);
}

// The selected count: «Alle» when the set has no more words than asked for.
export function countSelection(settings, available) {
  const { count } = sheetOptions(settings);
  return count <= 0 || count >= available ? 0 : count;
}

export function countCaption(planned, available) {
  return planned >= available ? 'Alle Begriffe, in zufälliger Reihenfolge.' : `${planned} von ${available} Begriffen, zufällig ausgewählt.`;
}

// About 30 seconds per word (a suggestion only; nothing is set automatically).
export function suggestedMinutes(planned) {
  return Math.max(1, Math.ceil(planned * 0.5));
}

export function timeCaption(minutes, planned) {
  if (minutes <= 0) return 'So viel Zeit, wie du brauchst. Die Zeit wird trotzdem gemessen.';
  return `Ist die Zeit um, wird abgegeben. Empfohlen: etwa ${plural(suggestedMinutes(planned), 'Minute', 'Minuten')} für ${plural(planned, 'Wort', 'Wörter')}.`;
}

// The setup bar's pill: "20 Wörter · 10 Minuten".
export function setupSummary(planned, minutes) {
  return `${plural(planned, 'Wort', 'Wörter')} · ${minutesText(minutes)}`;
}

export function starredLabel(n) {
  return `Nur markierte (${n})`;
}

export const STARRED_CAPTION = 'Nur die Begriffe mit Stern abfragen.';
export const NOT_MASTERY_NOTE = 'Die Prüfung zählt nicht für «Gemeistert». Was falsch ist, kannst du danach gezielt lernen.';

/* --------------------------------------------------------------- sheet texts */

const isNamed = (lang) => typeof lang === 'string' && lang !== 'other' && lang !== '';

// "20 Fragen · Antworten auf Französisch": the language only when every question is answered in
// the same named language and the set's two sides differ.
export function introText(questions, termLang, defLang) {
  const list = Array.isArray(questions) ? questions : [];
  const count = plural(list.length, 'Frage', 'Fragen');
  const langs = new Set(list.map((q) => q.answerLang));
  if (langs.size !== 1 || termLang === defLang) return count;
  const [lang] = langs;
  return isNamed(lang) ? `${count} · Antworten auf ${langName(lang)}` : count;
}

// The eyebrow over a prompt: its language, or "Definition"/"Begriff" when both sides share one.
export function promptLabel(question, termLang, defLang) {
  if (termLang === defLang || !isNamed(question.promptLang)) return question.ask === 'term' ? 'Definition' : 'Begriff';
  return langName(question.promptLang);
}

export function answerPlaceholder(question, termLang, defLang) {
  if (termLang === defLang || !isNamed(question.answerLang)) return 'Antwort';
  return `Auf ${langName(question.answerLang)} …`;
}

// "12 von 20 beantwortet" (the bar) and its longer form (the status tooltip).
export function answeredText(answered, total) {
  return `${answered} von ${total} beantwortet`;
}

export function answeredTooltip(answered, total) {
  return `${answered} von ${total} Fragen beantwortet`;
}

// «Abgeben» while questions are still open.
export function submitConfirm(open) {
  return {
    title: 'Prüfung abgeben?',
    message: open === 1 ? 'Eine Frage ist noch offen. Sie zählt als falsch.' : `${open} Fragen sind noch offen. Sie zählen als falsch.`,
    confirmLabel: 'Abgeben',
  };
}

// Leaving (or «Neue Prüfung») while an exam with answers runs.
export const LEAVE_CONFIRM = Object.freeze({
  title: 'Prüfung beenden?',
  message: 'Die Prüfung wird nicht bewertet, deine Antworten gehen verloren.',
  confirmLabel: 'Beenden',
});

// "Prüfung gestartet: 20 Fragen, 10 Minuten." / "Prüfung gestartet: 20 Fragen."
export function startAnnouncement(count, minutes) {
  return `Prüfung gestartet: ${plural(count, 'Frage', 'Fragen')}${minutes > 0 ? `, ${minutesText(minutes)}.` : '.'}`;
}
