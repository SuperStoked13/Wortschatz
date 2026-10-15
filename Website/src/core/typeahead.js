// Typing on a multiple-choice question (port of the Mac app's LearnTypeAhead.swift and the
// typing keys of LearnFlowReducer.swift): instead of a digit or a click the learner starts
// typing the answer ("la vo…"); the one option those letters start is highlighted, so Enter
// chooses it. The letters must leave no doubt: an article alone never picks anything ("la"
// starts many words), at least TYPE_AHEAD_MIN_LETTERS letters after it are needed, and exactly
// one option may match. Case, accents and the kind of apostrophe do not matter; an option can
// also be started without its article ("voi" → la voiture) or at one of its alternatives
// ("laide" in "laid, laide"). Arrow keys move a highlight over the 2-column grid instead.
// Arabic: vowel marks, tatweel, hamza forms, ة/ه and ى/ي do not matter and «ال» is a glued
// article («كت» → الكتاب). Chinese: spaces do not matter and the pinyin of «你好 (nǐ hǎo)» or
// «你好 nǐ hǎo» starts it too («ni»).
// DOM-free: the Learn screen feeds keys into typingKey() and draws the result.

import { ARTICLES, REFLEXIVES, GLUED_ARTICLES } from './grading.js';
import { foldScripts, hasHan } from './text.js';

// The most characters kept while typing on a multiple-choice question.
export const TYPE_AHEAD_MAX = 80;
// Letters needed after the article before the typed letters pick an option.
export const TYPE_AHEAD_MIN_LETTERS = 2;

// Nothing typed, nothing highlighted. `rejections` grows with every Enter that could not pick
// an option (the hint shakes).
export const TYPING_IDLE = Object.freeze({ typed: '', highlighted: null, rejections: 0 });

const NO_MATCH = Object.freeze({ selected: null, matching: Object.freeze([]), ranges: Object.freeze({}), isActive: false, hasEnoughLetters: false });

const APOSTROPHES = new Set(['’', '‘', '`', '´', 'ʼ', '′']);
const BREAKS = new Set([',', ';', '/']);
const COMPLETE_AT = new Set([',', ';', '/', '(']);
const OPENERS = new Set(['(', '[']);
const LATIN_RE = /^[a-z]$/;
// A "character" as the Mac counts them (Swift Character): a base code point and the combining
// marks after it.
const CHAR_RE = /\P{M}\p{M}*|\p{M}+/gu;
const WHITESPACE_RE = /^[\s\u0085]+$/u;
const ALNUM_RE = /^[\p{L}\p{N}]$/u;

const isWhitespace = (ch) => WHITESPACE_RE.test(ch);
const isHan = (ch) => typeof ch === 'string' && ch !== '' && hasHan(ch);
const characters = (text) => String(text == null ? '' : text).match(CHAR_RE) || [];

// One character folded for comparison: lower case, no accents, one kind of apostrophe. The
// Mac's case folding turns ß into ss. Arabic: the script folds (vowel marks and tatweel go,
// presentation forms, ، ؛ and full-width punctuation become plain), hamza goes with the
// accents (أ → ا), ٱ → ا, ة → ه, ى → ي.
function foldChar(ch) {
  if (APOSTROPHES.has(ch)) return "'";
  return foldScripts(ch)
    .toLowerCase()
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .replace(/ß/g, 'ss')
    .replace(/ٱ/g, 'ا')
    .replace(/ة/g, 'ه')
    .replace(/ى/g, 'ي');
}

// A text folded for type-ahead comparison (TypeAheadText): lower case, no accents, one kind of
// apostrophe, single spaces, no leading space, a trailing space kept ("la " means the article
// is done). No spaces between two Han characters, none at all with noSpaces (Chinese).
// origin/originEnd map every folded character to the UTF-16 range of the original character it
// came from, for underlining the typed part.
function foldText(text, noSpaces = false) {
  const chars = [];
  const origin = [];
  const originEnd = [];
  let pending = null; // the whitespace before the next character, once something came before it
  let offset = 0;
  for (const ch of characters(text)) {
    const start = offset;
    offset += ch.length;
    if (isWhitespace(ch)) {
      if (chars.length && !noSpaces) pending = { start, end: offset };
      continue;
    }
    const folded = foldChar(ch);
    // Nothing to compare (tatweel, a lone mark): a space before it waits for the next character.
    if (!folded) continue;
    if (pending) {
      if (!(isHan(chars[chars.length - 1]) && isHan(folded))) {
        chars.push(' ');
        origin.push(pending.start);
        originEnd.push(pending.end);
      }
      pending = null;
    }
    for (const f of folded) {
      chars.push(f);
      origin.push(start);
      originEnd.push(offset);
    }
  }
  if (pending) {
    chars.push(' ');
    origin.push(pending.start);
    originEnd.push(pending.end);
  }
  return { chars, origin, originEnd };
}

function startsWithAt(chars, at, seq) {
  if (at + seq.length > chars.length) return false;
  for (let i = 0; i < seq.length; i++) if (chars[at + i] !== seq[i]) return false;
  return true;
}

const sameChars = (a, b) => a.length === b.length && a.every((c, i) => c === b[i]);

// The original [start, end) of `length` folded characters from `start` ([0, 0] for none).
function range(t, start, length) {
  if (!(length > 0) || start >= t.origin.length) return [0, 0];
  const end = Math.min(start + length, t.origin.length) - 1;
  return [t.origin[start], t.originEnd[end]];
}

// Whether the option ends at folded position `end`, or an alternative or a note in brackets
// starts there ("le pain" in "le pain (frais)").
function isComplete(t, end) {
  let i = end;
  while (i < t.chars.length && t.chars[i] === ' ') i++;
  return i >= t.chars.length || COMPLETE_AT.has(t.chars[i]);
}

// The position after a leading article or pronoun at `start` ("la " or "l'"), null if none
// starts there or nothing follows it.
function articleEnd(chars, start, prefixes) {
  for (const prefix of prefixes) {
    if (startsWithAt(chars, start, prefix) && chars.length > start + prefix.length) return start + prefix.length;
  }
  return null;
}

// Whether the letters are only an article or pronoun, possibly unfinished by its space
// ("la", "la ", "l'").
function isArticle(chars, prefixes) {
  let n = chars.length;
  while (n > 0 && chars[n - 1] === ' ') n--;
  const trimmed = chars.slice(0, n);
  return prefixes.some((p) => sameChars(p, trimmed) || (p[p.length - 1] === ' ' && sameChars(p.slice(0, -1), trimmed)));
}

// Where typing may start: the option itself and each alternative ("laid, laide"), and the word
// after their leading article or pronoun ("la voiture" → "voiture"). An option with Chinese
// characters also starts after a bracket and where pinyin follows the characters ("你好 (nǐ hǎo)",
// "你好 nǐ hǎo" → "ni").
function starts(t, prefixes) {
  const alternatives = [0];
  const chinese = t.chars.some(isHan);
  let lastHan = false; // the last letter before i is a Han character
  t.chars.forEach((ch, i) => {
    const pinyin = chinese && lastHan && LATIN_RE.test(ch);
    if (ch !== ' ') lastHan = isHan(ch);
    if (pinyin && alternatives[alternatives.length - 1] !== i) alternatives.push(i);
    if (!BREAKS.has(ch) && !(chinese && OPENERS.has(ch))) return;
    let j = i + 1;
    while (j < t.chars.length && t.chars[j] === ' ') j++;
    if (j < t.chars.length) alternatives.push(j);
  });
  const all = [];
  for (const start of alternatives) {
    all.push(start);
    const end = articleEnd(t.chars, start, prefixes);
    if (end != null) all.push(end);
  }
  return all;
}

const prefixCache = new Map();

// Leading articles and reflexive pronouns of `lang` (every language for null) as they start a
// lower-case text: "la ", "l'", "se ", "to ", "ال" …, longest first (ExtendedSynonyms.articlePrefixes).
export function articlePrefixes(lang = null) {
  const langs = lang == null ? Object.keys(ARTICLES) : [lang];
  const set = new Set();
  for (const l of langs) {
    for (const article of ARTICLES[l] || []) {
      set.add(article.endsWith("'") || GLUED_ARTICLES.includes(article) ? article : `${article} `);
    }
    for (const pronoun of REFLEXIVES[l] || []) if (pronoun.endsWith(' ') || pronoun.endsWith("'")) set.add(pronoun);
  }
  return [...set].sort((a, b) => (a.length !== b.length ? b.length - a.length : a < b ? -1 : a > b ? 1 : 0));
}

function foldedPrefixes(lang) {
  const key = lang == null ? '\u0000' : String(lang);
  if (!prefixCache.has(key)) prefixCache.set(key, articlePrefixes(lang).map((p) => foldText(p).chars));
  return prefixCache.get(key);
}

// Chinese: spaces do not count, in the letters typed and in the options.
const noSpaces = (lang) => lang === 'zh';

/**
 * Which of `choices` (texts) the letters `typed` start, and the one they pick. `lang` is the
 * language of the options (its articles); null allows the articles of every language.
 * Returns { selected: index|null, matching: [index…] (the options the letters start, in order),
 * ranges: { [index]: [start, end] } (the typed part of each matching option, UTF-16 offsets),
 * isActive (letters are typed), hasEnoughLetters }.
 */
export function typeAhead(typed, choices, lang = null) {
  const input = foldText(typed, noSpaces(lang));
  if (!input.chars.some((c) => c !== ' ')) return NO_MATCH;
  const prefixes = foldedPrefixes(lang);

  // The letters after a leading article ("la vo" → "vo"); none for an article alone.
  const contentStart = articleEnd(input.chars, 0, prefixes);
  const articleOnly = contentStart == null && isArticle(input.chars, prefixes);
  const content = articleOnly ? [] : input.chars.slice(contentStart == null ? 0 : contentStart);
  const letters = content.filter((c) => ALNUM_RE.test(c)).length;

  const strong = [];
  const weak = [];
  (Array.isArray(choices) ? choices : []).forEach((choice, index) => {
    const option = foldText(choice, noSpaces(lang));
    const from = starts(option, prefixes);
    // The whole input from the start of the option, an alternative or a word after an article.
    const start = from.find((s) => startsWithAt(option.chars, s, input.chars));
    if (start != null) {
      strong.push({ index, range: range(option, start, input.chars.length), complete: isComplete(option, start + input.chars.length) });
      return;
    }
    // Another article than the option's ("le voi" for "la voiture"): the content alone.
    if (contentStart != null && content.length) {
      const s = from.find((p) => startsWithAt(option.chars, p, content));
      if (s != null) weak.push({ index, range: range(option, s, content.length), complete: isComplete(option, s + content.length) });
    }
  });
  // Options that match with the typed article win over those matching only after it.
  const matches = strong.length ? strong : weak;
  const complete = matches.filter((m) => m.complete);
  const enough = letters >= TYPE_AHEAD_MIN_LETTERS || (letters >= 1 && matches.length === 1 && matches[0].complete);

  let selected = null;
  if (enough) {
    if (matches.length === 1) selected = matches[0].index;
    // "le pain" picks "le pain", not "le pain de mie".
    else if (complete.length === 1) selected = complete[0].index;
  }
  const ranges = {};
  for (const m of matches) ranges[m.index] = m.range;
  return { selected, matching: matches.map((m) => m.index), ranges, isActive: true, hasEnoughLetters: enough };
}

/* ------------------------------------------------------------------ keys */

/**
 * The digit 0–9 a key types, ASCII or Arabic-Indic (٠–٩, ۰–۹: an Arabic keyboard chooses like
 * 1–4 and 0); null for anything else. The screen sends it as { kind: 'digit', n }.
 */
export function digitValue(text) {
  const s = String(text == null ? '' : text);
  if (/^[0-9]$/.test(s)) return Number(s);
  const code = s.length === 1 ? s.charCodeAt(0) : -1;
  if (code >= 0x660 && code <= 0x669) return code - 0x660;
  if (code >= 0x6f0 && code <= 0x6f9) return code - 0x6f0;
  return null;
}

/**
 * Arrow keys over the grid of `count` options laid out in `columns` columns (2 on wide
 * screens): the first press lands on option 1; a move off the grid stays put; ↓ from the row
 * above a lone last option goes to it.
 * direction: 'up' | 'down' | 'left' | 'right'. Returns the new index.
 */
export function moveHighlight(highlighted, direction, count, columns = 2) {
  if (!(count > 0)) return null;
  const cols = Math.max(1, Math.floor(Number(columns) || 2));
  if (highlighted == null || !(highlighted >= 0 && highlighted < count)) return 0;
  const h = highlighted;
  if (direction === 'left') return h % cols > 0 ? h - 1 : h;
  if (direction === 'right') return h % cols < cols - 1 && h + 1 < count ? h + 1 : h;
  if (direction === 'up') return h >= cols ? h - cols : h;
  if (direction === 'down') {
    if (h + cols < count) return h + cols;
    if (Math.floor(h / cols) < Math.floor((count - 1) / cols)) return count - 1;
    return h;
  }
  return h;
}

const charCount = (s) => characters(s).length;

// ⌫ removes the last letter, ⌥⌫ / Ctrl+⌫ the last word ("la voi" → "la "; spaces after the
// word go with it). Only spaces left count as nothing typed.
function deleteTyped(typed, word) {
  const list = characters(typed);
  const lastIsSpace = () => isWhitespace(list[list.length - 1]);
  if (word) {
    while (list.length && lastIsSpace()) list.pop();
    while (list.length && !lastIsSpace()) list.pop();
  } else {
    list.pop();
  }
  const out = list.join('');
  return /\S/u.test(out) ? out : '';
}

const choiceText = (choices, i) => {
  const c = choices[i];
  return typeof c === 'string' ? c : c && typeof c.text === 'string' ? c.text : '';
};

const texts = (choices) => (Array.isArray(choices) ? choices.map((_, i) => choiceText(choices, i)) : []);

// The letters changed: the one option they pick is highlighted (an arrow highlight gives way).
function retype(state, typed, list, lang) {
  const match = typeAhead(typed, list, lang);
  const next = { ...state, typed, highlighted: match.selected };
  const announce =
    match.selected != null && match.selected !== state.highlighted
      ? `Antwort ${match.selected + 1}: ${list[match.selected]}. Eingabetaste wählt sie.`
      : null;
  return { state: next, action: null, announce };
}

/**
 * One key on a multiple-choice question (the typing part of LearnFlowReducer).
 * state: { typed, highlighted, rejections } (TYPING_IDLE for a new question)
 * key: { kind: 'char', text } | { kind: 'delete', word } | { kind: 'escape' } |
 *      { kind: 'arrow', direction } | { kind: 'return' } | { kind: 'digit', n }
 * context: { choices (texts or { text }), lang, columns, repeat (a held key) }
 * Returns { state, action, announce }, where action is null or
 *   { type: 'choose', index } | { type: 'dontKnow' } | { type: 'leave' } | { type: 'reject' }.
 * Repeats never do anything but delete (a held ⌫ keeps deleting). The input lock of the
 * screen is the caller's business (digits and Enter wait for it, typing does not).
 */
export function typingKey(state, key, { choices = [], lang = null, columns = 2, repeat = false } = {}) {
  const s = { ...TYPING_IDLE, ...(state || {}) };
  const same = { state: s, action: null, announce: null };
  if (!key || (repeat && key.kind !== 'delete')) return same;
  const list = texts(choices);
  switch (key.kind) {
    case 'char': {
      const text = String(key.text == null ? '' : key.text);
      if (!text) return same;
      // A first space types nothing.
      if (!s.typed && !/\S/u.test(text)) return same;
      if (charCount(s.typed) + charCount(text) > TYPE_AHEAD_MAX) return same;
      return retype(s, s.typed + text, list, lang);
    }
    case 'delete': {
      // ⌫ on nothing typed does nothing (and never leaves the question).
      if (!s.typed) return same;
      return retype(s, deleteTyped(s.typed, !!key.word), list, lang);
    }
    case 'escape': {
      // Letters typed go first; with nothing typed esc leaves.
      if (s.typed) return { state: { ...s, typed: '', highlighted: null }, action: null, announce: 'Eingabe gelöscht' };
      return { state: s, action: { type: 'leave' }, announce: null };
    }
    case 'arrow': {
      // The arrows take over from typing.
      const next = moveHighlight(s.highlighted, key.direction, list.length, columns);
      if (next == null || next === s.highlighted) return { state: { ...s, typed: '' }, action: null, announce: null };
      return { state: { ...s, typed: '', highlighted: next }, action: null, announce: `Antwort ${next + 1}: ${list[next]}` };
    }
    case 'return': {
      if (s.highlighted != null && s.highlighted < list.length) {
        return { state: { ...s, typed: '', highlighted: null }, action: { type: 'choose', index: s.highlighted }, announce: null };
      }
      if (!s.typed) return same;
      // Typed letters that pick no option yet: Enter cannot guess.
      return {
        state: { ...s, rejections: s.rejections + 1 },
        action: { type: 'reject' },
        announce: `Keine eindeutige Antwort – tippe weiter oder wähle mit 1 bis ${list.length}.`,
      };
    }
    case 'digit': {
      const d = digitValue(key.n);
      const n = d == null ? Number(key.n) : d;
      if (n === 0) return { state: { ...s, typed: '', highlighted: null }, action: { type: 'dontKnow' }, announce: null };
      if (Number.isInteger(n) && n >= 1 && n <= list.length) {
        return { state: { ...s, typed: '', highlighted: null }, action: { type: 'choose', index: n - 1 }, announce: null };
      }
      return same;
    }
    default:
      return same;
  }
}

/**
 * How option `index` is drawn while choosing: 'highlighted' (Enter chooses it), 'filtered'
 * (the letters typed do not start it; only while some option matches) or 'idle'.
 * match: typeAhead() of the typed letters.
 */
export function optionState(state, index, match) {
  const s = state || TYPING_IDLE;
  if (s.highlighted === index) return 'highlighted';
  if (!s.typed || !match || !match.isActive || !match.matching.length) return 'idle';
  return match.matching.includes(index) ? 'idle' : 'filtered';
}

// The label of the primary button while choosing: «Auswählen» once an option is highlighted.
export function returnLabel(state) {
  return state && state.highlighted != null ? 'Auswählen' : null;
}

/**
 * The hint under the tiles while letters are typed: what Enter does with them.
 * Returns { kind: 'pick' | 'more' | 'none', text } — 'pick': "wählt «X»" (after the ↩ key),
 * 'more': "Weiter tippen …", 'none': "Keine Antwort passt" (the letters show in red).
 */
export function typingHint(match, choices) {
  const list = texts(choices);
  if (match && match.selected != null && match.selected < list.length) return { kind: 'pick', text: `wählt «${list[match.selected]}»` };
  if (!match || !match.matching.length) return { kind: 'none', text: 'Keine Antwort passt' };
  return { kind: 'more', text: 'Weiter tippen …' };
}

// How to correct the letters, with the key names of the platform.
export function correctionHint(apple = false) {
  return apple ? '⌫ korrigiert · esc löscht' : 'Rücktaste korrigiert · Esc löscht';
}
