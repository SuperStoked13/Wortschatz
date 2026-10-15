// Synonym-aware grading for Write mode.
//
// Cards whose prompts share a meaning ("hässlich" → "laid, laide" and
// "hässlich" → "moche", or "lieb" → "brave" and "lieb, nett" → "gentil,
// gentille") look the same to the learner, who cannot know which card is
// meant. An answer that is correct for such a sibling card is therefore
// accepted with the note 'synonym'; expectedDisplay stays the asked card's
// answer so the feedback shows what was meant. Pure and DOM-free (runs under jsc).

import { grade, splitAlternatives } from './grading.js';
import { normalizeBasic, foldScripts } from './text.js';

function toStr(value) {
  if (value == null) return '';
  if (typeof value === 'string') return value;
  try {
    return String(value);
  } catch {
    return '';
  }
}

const field = (card, key) => (card && typeof card === 'object' ? toStr(card[key]) : '');

// `ask` is the side the learner types (spec §4.11): 'term' → prompt is the definition.
export function promptSide(card, ask) {
  return field(card, ask === 'term' ? 'definition' : 'term');
}

export function answerSide(card, ask) {
  return field(card, ask === 'term' ? 'term' : 'definition');
}

// Comparison key: case, ß/ss, ligatures, hyphens and punctuation do not matter, nor
// Arabic vowel marks or full-width punctuation (foldScripts).
function keyOf(text) {
  return foldScripts(normalizeBasic(text))
    .toLowerCase()
    .replace(/ß/g, 'ss')
    .replace(/œ/g, 'oe')
    .replace(/æ/g, 'ae')
    .replace(/-/g, ' ')
    .replace(/[.,!?;:"«»‹›¿¡…~*„“”‚()[\]{}「」『』《》〈〉]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

// The whole prompt and each of its alternatives ("lieb, nett" → lieb nett | lieb | nett).
function promptKeys(text) {
  const keys = new Set([keyOf(text)]);
  for (const alt of splitAlternatives(text)) keys.add(keyOf(alt));
  keys.delete('');
  return keys;
}

const sameCard = (a, b) => a === b || (a && b && a.id != null && a.id === b.id);

// Other cards whose prompt side shares at least one alternative with this card's.
export function findSynonymCards(cards, card, ask) {
  if (!Array.isArray(cards) || !card || typeof card !== 'object') return [];
  const keys = promptKeys(promptSide(card, ask));
  if (!keys.size) return [];
  return cards.filter((other) => {
    if (!other || typeof other !== 'object' || sameCard(other, card)) return false;
    if (!normalizeBasic(answerSide(other, ask))) return false;
    for (const k of promptKeys(promptSide(other, ask))) if (keys.has(k)) return true;
    return false;
  });
}

// Completeness notes describe the other card's answer, not the asked one.
const SIBLING_ONLY_NOTES = new Set(['partial', 'order']);
const quality = (r) => (r.exact ? 0 : 1 + r.notes.length);

// Grades against the asked card first, then against its synonym cards.
// Returns { result: GradeResult, matchedCard: Card | null } (matchedCard = the
// synonym card whose answer was accepted).
export function gradeWithSynonyms(given, card, cards, ask, tolerance, answerLang) {
  const result = grade(given, answerSide(card, ask), tolerance, answerLang);
  if (result.correct) return { result, matchedCard: null };
  let best = null;
  for (const other of findSynonymCards(cards, card, ask)) {
    const r = grade(given, answerSide(other, ask), tolerance, answerLang);
    if (r.correct && (!best || quality(r) < quality(best.r))) best = { r, other };
  }
  if (!best) return { result, matchedCard: null };
  return {
    result: {
      correct: true,
      exact: false,
      notes: ['synonym', ...best.r.notes.filter((n) => !SIBLING_ONLY_NOTES.has(n))],
      hint: null,
      expectedDisplay: result.expectedDisplay,
    },
    matchedCard: best.other,
  };
}
