// Pure helpers for Write mode: question texts per direction, grading of the answer
// and the copy step, resumability of a stored session (incl. a pending "Nicht ganz"
// screen and the results of a finished one) and list rows for the summary/results
// screens. DOM-free.

import { langName } from '../lib/labels.js';
import { grade } from '../core/grading.js';
import { gradeWithSynonyms } from '../core/synonyms.js';
import { isFinished } from '../core/session.js';

export const NAMED_SUBSETS = ['all', 'starred', 'learning', 'missed'];

export const hasText = (v) => typeof v === 'string' && v.trim() !== '';

export function parseSubset(value) {
  return NAMED_SUBSETS.includes(value) ? value : null;
}

// A card can be asked only when both sides have text.
export function isUsableCard(card) {
  return !!card && hasText(card.term) && hasText(card.definition);
}

// Everything the question card shows for question `q` ({ qid, cardId, ask }) of `card`.
// ask === 'term': the definition is shown and the term typed (and vice versa).
export function questionInfo(set, card, q) {
  if (!q || !card) return null;
  const askTerm = q.ask === 'term';
  const promptLang = askTerm ? set.defLang : set.termLang;
  const answerLang = askTerm ? set.termLang : set.defLang;
  const sameLang = set.termLang === set.defLang;
  return {
    qid: q.qid,
    cardId: card.id,
    ask: askTerm ? 'term' : 'definition',
    prompt: askTerm ? card.definition : card.term,
    expected: askTerm ? card.term : card.definition,
    promptLang,
    answerLang,
    promptLabel: sameLang || promptLang === 'other' ? (askTerm ? 'Definition' : 'Begriff') : langName(promptLang),
    placeholder: sameLang || answerLang === 'other' ? 'Antwort eingeben' : `Antwort auf ${langName(answerLang)} eingeben`,
    // Phones: the long placeholder would be cut off in the field.
    placeholderShort: sameLang || answerLang === 'other' ? 'Antwort eingeben' : `Auf ${langName(answerLang)} …`,
    starred: !!card.starred,
  };
}

// Grades the main answer of question `info`. An answer that is right for another card
// with the same prompt counts too (the learner cannot tell such cards apart).
// Returns { result: GradeResult, matchedCard: Card | null }.
export function gradeQuestion(set, info, given, tolerance) {
  const cards = set && Array.isArray(set.cards) ? set.cards : [];
  const card = cards.find((c) => c && c.id === info.cardId);
  if (!card) return { result: grade(given, info.expected, tolerance, info.answerLang), matchedCard: null };
  return gradeWithSynonyms(given, card, cards, info.ask, tolerance, info.answerLang);
}

// The copy step after a miss needs the asked card's answer itself (no synonyms).
export function copyAccepted(value, info, tolerance) {
  if (!info || !hasText(value)) return false;
  return grade(value, info.expected, tolerance, info.answerLang).correct === true;
}

const MAX_GIVEN = 1000;
const hasOwn = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);

// The "Nicht ganz" screen that was open when the page was left: `feedback`
// ({ qid, given, dontKnow }, stored next to the session) is valid while its question
// was missed in the running round and not counted as correct since.
// Returns the cleaned record or null.
export function pendingFeedback(session, feedback) {
  if (!session || typeof session !== 'object' || !feedback || typeof feedback !== 'object') return null;
  const { qid } = feedback;
  const questions = session.questions && typeof session.questions === 'object' ? session.questions : {};
  if (typeof qid !== 'string' || !hasOwn(questions, qid)) return null;
  if (Array.isArray(session.done) && session.done.includes(qid)) return null;
  if (Array.isArray(session.queue) && session.queue.includes(qid)) return null;
  const answered = Array.isArray(session.roundAnswered) ? session.roundAnswered.filter((a) => a && a.qid === qid) : [];
  if (!answered.length || answered[answered.length - 1].correct !== false) return null;
  return {
    qid,
    given: typeof feedback.given === 'string' ? feedback.given.slice(0, MAX_GIVEN) : '',
    dontKnow: feedback.dontKnow === true,
  };
}

// A finished session is shown again (results instead of a fresh start) when the
// page is reloaded or reached with Back in the history entry it ran in: `marker` is
// the startedAt stamp that entry carries. A new visit starts fresh.
export function canShowResults(saved, { forceNew = false, subset = null, marker = null } = {}) {
  return (
    !forceNew &&
    !!saved &&
    typeof saved === 'object' &&
    saved.finishedAt != null &&
    Array.isArray(saved.order) &&
    saved.order.length > 0 &&
    typeof marker === 'number' &&
    marker === saved.startedAt &&
    (subset == null || saved.subset === subset)
  );
}

// Study time for the results tile, short enough for one line: '42 Sek.', '2:47'
// (minutes) or '1:02:47' (hours); the label names the unit.
export function compactDuration(ms) {
  const total = Math.max(0, Math.round((Number(ms) || 0) / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const ss = String(total % 60).padStart(2, '0');
  if (h > 0) return { value: `${h}:${String(m).padStart(2, '0')}:${ss}`, label: 'Zeit (Std.)' };
  if (m > 0) return { value: `${m}:${ss}`, label: 'Zeit (Min.)' };
  return { value: `${total} Sek.`, label: 'Zeit' };
}

// A stored session is resumed unless a fresh one was requested, it is finished or
// empty, or a different named subset was asked for.
export function canResume(saved, { forceNew = false, subset = null } = {}) {
  return (
    !forceNew &&
    !!saved &&
    typeof saved === 'object' &&
    saved.finishedAt == null &&
    Array.isArray(saved.order) &&
    saved.order.length > 0 &&
    !isFinished(saved) &&
    (subset == null || saved.subset === subset)
  );
}

export function hasAnswers(session) {
  return (Array.isArray(session.rounds) && session.rounds.length > 0) || (Array.isArray(session.roundAnswered) && session.roundAnswered.length > 0);
}

// Column count for the special-character keys on phones: the fewest rows with at
// most `perRow` keys each, balanced (15 French keys: 8 + 7, or 5 + 5 + 5 for 7).
export function charColumns(count, perRow) {
  const n = Math.max(0, Math.floor(Number(count) || 0));
  const max = Math.max(1, Math.floor(Number(perRow) || 0));
  if (n === 0) return 1;
  return Math.ceil(n / Math.ceil(n / max));
}

// Rows for term lists: items [{ cardId, ...extra }] -> [{ term, definition, termLang, defLang, ...extra }]
export function termRows(set, cards, items) {
  const rows = [];
  for (const item of items) {
    const card = cards.get(item.cardId);
    if (card) rows.push({ ...item, term: card.term, definition: card.definition, termLang: set.termLang, defLang: set.defLang });
  }
  return rows;
}
