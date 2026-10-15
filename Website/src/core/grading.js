// Answer grading for Write mode (spec §4.10).
//
// grade() decides whether a typed answer matches the stored answer under the
// learner's tolerance options. Both sides run through the same pipeline:
//   normalise → split alternatives (, ; /) → parenthesis variants →
//   abbreviation expansion → strip punctuation → split leading article or
//   reflexive pronoun → compare with progressively more tolerant comparators
//   (exact, case, accents, typo).
// Every tolerance that was needed is reported as a note; for wrong answers the
// most helpful hint is computed. Pure and DOM-free (runs under jsc).

import { normalizeBasic, stripDiacritics, foldUmlauts, foldScripts, stripArabicMarks, hasArabic, hasHan, HAN_RANGE } from './text.js';

export const ARTICLES = Object.freeze({
  fr: Object.freeze(['le', 'la', 'les', "l'", 'un', 'une', 'des', 'du', 'de la', "de l'"]),
  de: Object.freeze(['der', 'die', 'das', 'den', 'dem', 'des', 'ein', 'eine', 'einen', 'einem', 'einer', 'eines']),
  en: Object.freeze(['the', 'a', 'an', 'to']),
  es: Object.freeze(['el', 'la', 'los', 'las', 'un', 'una', 'unos', 'unas']),
  it: Object.freeze(['il', 'lo', 'la', 'i', 'gli', 'le', "l'", 'un', 'uno', 'una', "un'"]),
  ar: Object.freeze(['ال']),
  zh: Object.freeze([]),
});

export const REFLEXIVES = Object.freeze({
  fr: Object.freeze(['se ', "s'"]),
  de: Object.freeze(['sich ']),
  en: Object.freeze(['oneself']),
  es: Object.freeze([]),
  it: Object.freeze([]),
  ar: Object.freeze([]),
  zh: Object.freeze([]),
});

// Articles written onto the word without a space or an apostrophe (الكتاب = ال + كتاب); they
// behave like an elided article ("l'homme").
export const GLUED_ARTICLES = Object.freeze(['ال']);

const WORD_START = '(?<![\\p{L}\\p{N}])';
const WORD_END = '(?![\\p{L}\\p{N}])';
const abbr = (body, canonical, start = WORD_START) =>
  Object.freeze([new RegExp(`${start}(?:${body})${WORD_END}`, 'giu'), canonical]);

// [pattern, canonical expansion]; applied in order, case-insensitive.
export const ABBREVIATIONS = Object.freeze([
  abbr('etw\\.?', 'etwas'),
  abbr('jdn\\.?|jmdn\\.?', 'jemanden'),
  abbr('jdm\\.?|jmdm\\.?', 'jemandem'),
  abbr('jds\\.?|jmds\\.?', 'jemandes'),
  abbr('jd\\.?|jmd\\.?', 'jemand'),
  abbr('s\\.\\s?th\\.?|smth\\.?|sth\\.?', 'something'),
  abbr('s\\.\\s?b\\.?|s\\.\\s?o\\.?|smb\\.?|sb\\.?|someone', 'somebody'),
  abbr('o\\.\\s?s\\.?', 'oneself'),
  abbr('qqch\\.?|qqc\\.?|qch\\.?|qc\\.?', 'quelque chose'),
  abbr('qqn\\.?|qn\\.?', "quelqu'un"),
  abbr('z\\.?\\s?b\\.?', 'zum Beispiel'),
  abbr('usw\\.?', 'und so weiter'),
  abbr('bzw\\.?', 'beziehungsweise'),
  abbr('od\\.?', 'oder'),
  abbr('u\\.', 'und', '(?<![\\p{L}\\p{N}.])'),
]);

export const DEFAULT_TOLERANCE = Object.freeze({
  articles: true,
  abbreviations: true,
  multipleAnswers: true,
  parentheses: true,
  ignoreCase: true,
  ignoreAccents: false,
  typos: false,
});

// 'tones' and 'tonesOnly' are 'accents' and 'accentsOnly' of a Chinese answer (pinyin), 'variant'
// an Arabic letter variant (always accepted), 'pinyin' a Chinese answer typed in pinyin only.
const NOTE_ORDER = [
  'article', 'pronoun', 'abbreviation', 'partial', 'parentheses', 'pinyin', 'case', 'accents', 'tones', 'variant', 'typo', 'order',
];
const HINT_ORDER = ['wrongArticle', 'missingArticle', 'accentsOnly', 'tonesOnly', 'caseOnly', 'typo', 'almost'];

const MAX_PARTS = 24; // more alternatives than this → compare as a single string
const MAX_DIST_LEN = 200; // longer strings skip edit-distance comparisons
const MAX_DIFF_CELLS = 1e6; // LCS table cap for diffChars
const MAX_PAREN_VARIANTS = 64;
const MAX_SLASH_VARIANTS = 16;
const ALMOST_SIMILARITY = 0.75;

// Elided forms and the full articles/pronouns they stand for (l'homme ≡ le homme).
const ELISIONS = {
  fr: { "l'": ['le', 'la'], "s'": ['se'], "de l'": ['de la', 'du'] },
  it: { "l'": ['lo', 'la'], "un'": ['una'] },
};

const ARTICLE_TABLE = buildArticleTable();
const BARE_ARTICLES = new Set(); // articles and reflexive pronouns of every language
const ELIDED_ARTICLES = new Set();
const NOUN_ARTICLES = new Set(); // real articles only (no "to", no pronouns)
for (const entries of Object.values(ARTICLE_TABLE)) {
  for (const e of entries) {
    (e.elided ? ELIDED_ARTICLES : BARE_ARTICLES).add(e.token);
    if (e.kind === 'article' && e.token !== 'to') NOUN_ARTICLES.add(e.token);
  }
}

// Contractions that open a phrase like an article ("jouer au foot/au tennis").
const PHRASE_STARTERS = new Set(['au', 'aux']);
// Contracted article → the preposition it contains ("à la plage/au cinéma").
const CONTRACTED = { au: 'à', aux: 'à', du: 'de', des: 'de' };

// Placeholders for an object or reflexive slot ("an jdn./etw. denken", "sb/sth",
// "qn/qc", "etw./sich ändern"); abbreviations are compared by their expansion.
const SLOT_WORDS = new Set([
  'etwas', 'jemand', 'jemanden', 'jemandem', 'jemandes', 'sich',
  'something', 'somebody', 'oneself',
  'quelque chose', "quelqu'un", 'se', "s'",
]);
const REFLEXIVE_SLOTS = new Set(['sich', 'oneself', 'se', "s'"]);
// French reflexives stand before the verb, object placeholders after it, so in
// "laver qc/se laver" the slash separates two whole verb phrases.
const PREVERBAL_REFLEXIVES = new Set(['se', "s'"]);

// Short pronouns and determiners written as slash lists ("il/elle", "er/sie/es").
const SHORT_FORMS = new Set([
  'je', 'tu', 'il', 'elle', 'on', 'nous', 'vous', 'ils', 'elles', 'me', 'te', 'lui', 'leur', 'eux', 'moi', 'toi',
  'mon', 'ma', 'mes', 'ton', 'ta', 'tes', 'son', 'sa', 'ses', 'ce', 'cet', 'cette', 'ces',
  'ich', 'du', 'er', 'sie', 'es', 'wir', 'ihr', 'mir', 'dir', 'mich', 'dich',
  'he', 'she', 'it', 'we', 'they', 'him', 'her', 'us', 'them', 'his', 'its', 'my', 'your', 'our', 'their',
]);

// Grammar annotations written as their own comma part: plural or suffix
// notation ("der Tisch, -e", "die Mutter, ¨") and gender/number markers
// ("maison, f", "die Eltern, Pl."). Markers are lower case: "Mme, M." and
// "S, M, L" are answers.
const ANNOTATION = /^(?:[-¨~].*|(?:m|f|n|pl|Pl|sg|Sg)\.?|m\.?\/f\.?)$/;
const noteKey = (s) => s.toLowerCase().replace(/[\s.]/g, '');
const GRAMMAR_MARKERS = new Set(['m', 'f', 'n', 'pl', 'sg', 'etc', 'irr', 'ugs', 'fam', 'adj', 'adv']);

function buildArticleTable() {
  const table = {};
  for (const lang of Object.keys(ARTICLES)) {
    const entries = [];
    const add = (raw, kind) => {
      const token = raw.trim().toLowerCase();
      if (token) entries.push({ token, kind, elided: token.endsWith("'") || GLUED_ARTICLES.includes(token) });
    };
    ARTICLES[lang].forEach((a) => add(a, 'article'));
    (REFLEXIVES[lang] || []).forEach((r) => add(r, 'pronoun'));
    entries.sort((x, y) => y.token.length - x.token.length);
    table[lang] = entries;
  }
  return table;
}

// ---------------------------------------------------------------------------
// Small helpers

function toStr(value) {
  if (value == null) return '';
  if (typeof value === 'string') return value;
  try {
    return String(value);
  } catch {
    return '';
  }
}

function countLetters(s) {
  const m = s.match(/\p{L}/gu);
  return m ? m.length : 0;
}

const hasAlnum = (s) => /[\p{L}\p{N}]/u.test(s);

const LIGATURES = /[ßẞœŒæÆ]/;

// ß ≡ ss, œ ≡ oe, æ ≡ ae
function foldLigatures(s) {
  return s
    .replace(/ẞ/g, 'SS')
    .replace(/ß/g, 'ss')
    .replace(/Œ(?=\p{Ll})/gu, 'Oe')
    .replace(/Œ/g, 'OE')
    .replace(/œ/g, 'oe')
    .replace(/Æ(?=\p{Ll})/gu, 'Ae')
    .replace(/Æ/g, 'AE')
    .replace(/æ/g, 'ae');
}

// Normalisation that always applies: whitespace, apostrophes, dashes,
// ligatures, no spaces around apostrophes ("s' appeler"), and the script folds
// (Arabic vowel marks and tatweel, presentation forms, ، ؛ ؟ and full-width
// punctuation, spaces between Han characters), which never produce a note.
function prep(value) {
  return foldLigatures(foldScripts(normalizeBasic(toStr(value)))).replace(/ *' */g, "'");
}

const PUNCT = /[.,!?;:"«»‹›¿¡…~*„“”‚「」『』《》〈〉]/g;
const BRACKETS = /[()[\]{}]/g;

const tidy = (s) => s.replace(/\s+/g, ' ').replace(/ *' */g, "'").trim();
// Comparison text: hyphen ≡ space, punctuation and leftover brackets dropped.
const clean = (s) => tidy(s.replace(/-/g, ' ').replace(PUNCT, '').replace(BRACKETS, ''));
// Exactness key: like clean() but brackets still count.
const keyOf = (s) => tidy(s.replace(/-/g, ' ').replace(PUNCT, ''));

// A capitalised abbreviation ("Etw.") expands capitalised ("Etwas").
function expandAbbreviations(s) {
  let out = s;
  for (const [pattern, canonical] of ABBREVIATIONS) {
    out = out.replace(pattern, (m) => (/^\p{Lu}/u.test(m) ? canonical[0].toUpperCase() + canonical.slice(1) : canonical));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Alternatives: "lieb, nett", "beau/belle", "der/die Angestellte"

// Graded text has ASCII brackets and separators (prep); splitAlternatives reads
// the stored text as written, with full-width brackets, ، ， 、 and ؛ ；.
const OPENERS = new Set(['(', '[', '（', '［', '【']);
const CLOSERS = new Set([')', ']', '）', '］', '】']);
const COMMAS = new Set([',', '،', '，', '、']);
const SEMICOLONS = new Set([';', '؛', '；']);

function bracketsBalanced(s) {
  let depth = 0;
  for (const ch of s) {
    if (OPENERS.has(ch)) depth++;
    else if (CLOSERS.has(ch) && --depth < 0) return false;
  }
  return depth === 0;
}

// Calls visit(ch, i) for every character outside brackets (when balanced).
function scanTopLevel(s, visit) {
  const track = bracketsBalanced(s);
  let depth = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (track && OPENERS.has(ch)) depth++;
    else if (track && CLOSERS.has(ch)) depth--;
    else if (depth === 0 && visit(ch, i) === false) return;
  }
}

// Split on top-level ',' ';' and spaced '/' (never between digits: "1,5 kg").
// With commas = false (a sentence) a comma only cuts after '?', '!' or '…'.
function splitSegments(s, commas = true) {
  const out = [];
  let start = 0;
  scanTopLevel(s, (ch, i) => {
    const prev = s[i - 1] || ' ';
    const next = s[i + 1] || ' ';
    const cut =
      SEMICOLONS.has(ch) ||
      (COMMAS.has(ch) && (commas ? !(/\d/.test(prev) && /\d/.test(next)) : /[?!…؟？！]/.test(prev))) ||
      (ch === '/' && (prev === ' ' || next === ' '));
    if (cut) {
      out.push(s.slice(start, i));
      start = i + 1;
    }
  });
  out.push(s.slice(start));
  return out;
}

// A comma inside a sentence ("Ça va bien, merci.", "Danke, gleichfalls!") does
// not separate answers. A final dot only ends a sentence that starts with a
// capital and ends in a real word, not a list ("ja, nein.") or one ending in an
// abbreviation, marker or article ("jdn. fragen, etw. tun.", "maison, f.", "Herr, der.").
// German (lang 'de') capitalises nouns, so "Mappe, Tasche." is a list of nouns.
// Arabic and Chinese have no capitals: there a final dot is enough. `s` is folded (prep).
function isSentenceLike(s, lang) {
  if (!s.includes(',')) return false;
  const t = s.replace(/[\s"»«”“„)\]」』》〉]+$/u, '');
  if (/(?:[?!…]|\.\.\.)$/.test(t)) return true;
  if (t.endsWith('.') && (hasArabic(t) || hasHan(t))) return true;
  if (!/^[\s"«„“¿¡([]*\p{Lu}/u.test(t)) return false;
  const m = t.match(/([\p{L}']+)\.$/u);
  if (!m) return false;
  const word = m[1].toLowerCase();
  if (countLetters(word) < 2 || GRAMMAR_MARKERS.has(word) || BARE_ARTICLES.has(word)) return false;
  if (expandAbbreviations(`${m[1]}.`) !== `${m[1]}.`) return false;
  return !(lang === 'de' && isGermanNounList(t));
}

// Every comma part is one capitalised word, optionally after an article:
// "Mappe, Tasche.", "Die Mappe, die Tasche." (but not "Guten Tag, Frau Müller.").
function isGermanNounList(t) {
  const parts = t
    .replace(/^[\s"«„“([]+/u, '')
    .replace(/\.$/, '')
    .split(/[,;]/)
    .map((p) => p.trim())
    .filter(Boolean);
  return parts.every((part) => {
    const words = part.split(/\s+/);
    const article = words.length === 2 && ARTICLES.de.includes(words[0].toLowerCase());
    return (words.length === 1 || article) && /^\p{Lu}[\p{L}'-]*$/u.test(words[words.length - 1]);
  });
}

const isBareArticle = (w) => BARE_ARTICLES.has(w.toLowerCase());
function startsPhrase(w) {
  const low = w.toLowerCase();
  if (BARE_ARTICLES.has(low) || PHRASE_STARTERS.has(low)) return true;
  for (const t of ELIDED_ARTICLES) if (low.length > t.length && low.startsWith(t)) return true;
  return false;
}

// The word opens a noun phrase with a real article ("das Haus der Familie").
function opensNounPhrase(w) {
  const low = w.toLowerCase();
  if (NOUN_ARTICLES.has(low)) return true;
  for (const t of NOUN_ARTICLES) if (t.endsWith("'") && low.length > t.length && low.startsWith(t)) return true;
  return false;
}

// Index of the group in the words left of a slash that the article group right
// of it replaces: "faire du vélo/du ski" → 1, "aller à la plage/au cinéma" → 1.
// -1 when the right side is not such a group (pronouns and "to" start whole
// phrases: "aller au lit/se coucher") or the left side is a noun phrase itself
// ("das Haus der Familie/die Wohnung").
function parallelGroupStart(lw, firstRight) {
  const opensGroup = (w) => opensNounPhrase(w) || PHRASE_STARTERS.has(w.toLowerCase());
  if (!opensGroup(firstRight) || opensNounPhrase(lw[0])) return -1;
  for (let j = lw.length - 1; j >= 1; j--) {
    const low = lw[j].toLowerCase();
    // A bare starter needs a word after it; an elided one carries it ("l'école").
    const bare = NOUN_ARTICLES.has(low) || PHRASE_STARTERS.has(low);
    if (!opensGroup(lw[j]) || (bare && j === lw.length - 1)) continue;
    const prep = CONTRACTED[firstRight.toLowerCase()];
    return prep && lw[j - 1].toLowerCase() === prep ? j - 1 : j;
  }
  return -1;
}

const slotWord = (text) => expandAbbreviations(clean(text)).toLowerCase();
const isSlot = (text) => SLOT_WORDS.has(slotWord(text));

// Number of words (0-2) that form a placeholder at the end or the start of words.
function slotSpan(words, atEnd) {
  for (let n = Math.min(2, words.length); n > 0; n--) {
    if (isSlot((atEnd ? words.slice(-n) : words.slice(0, n)).join(' '))) return n;
  }
  return 0;
}

// An unspaced slash separates alternatives when both sides look like words
// (≥ 3 letters), articles, placeholders ("sb/sth") or short pronouns
// ("il/elle") — never for suffix notation like "Lehrer/in".
function isAlternationSlash(seg, i) {
  const left = seg.slice(0, i);
  const right = seg.slice(i + 1);
  const lw = left.match(/[^\s/]*$/)[0];
  const rw = right.match(/^[^\s/]*/)[0];
  if (!lw || !rw || rw[0] === '-') return false;
  if (isSlot(lw) && isSlot(rw)) return true; // "jdn./etw.", "sb/sth", "qn/qc"
  if (SHORT_FORMS.has(lw.toLowerCase()) && SHORT_FORMS.has(rw.toLowerCase())) return true; // "il/elle", "er/sie"
  const rightWords = right.trim().split(' ').length;
  if (rightWords === 1 && /^\p{Lu}/u.test(lw) && /^\p{Ll}/u.test(rw)) return false; // "Lehrer/innen"
  if (isBareArticle(lw) && isBareArticle(rw)) return true; // "le/la", "der/die"
  if (startsPhrase(rw) && rightWords >= 2 && countLetters(lw) >= 2) return true; // "le chat/la chatte"
  // A short object placeholder is a word too ("habiller qn/s'habiller"); "se" is
  // not, it is also a suffix ("gros/se"). Chinese characters are words of any
  // length ("谢谢/多谢", "你/您").
  const wordLike = (w) => countLetters(w) >= 3 || hasHan(w) || (isSlot(w) && !REFLEXIVE_SLOTS.has(slotWord(w)));
  return wordLike(lw) && wordLike(rw);
}

function expandSlashes(seg, depth = 0) {
  let at = -1;
  if (depth < 6) {
    scanTopLevel(seg, (ch, i) => {
      if (ch === '/' && isAlternationSlash(seg, i)) {
        at = i;
        return false;
      }
      return true;
    });
  }
  if (at < 0) return [seg];
  const left = seg.slice(0, at).trim();
  const right = seg.slice(at + 1).trim();
  const lw = left.split(' ');
  const rw = right.split(' ');
  const lastLeft = left.match(/[^\s/]*$/)[0];
  const firstRight = right.match(/^[^\s/]*/)[0];
  // The slash binds the nl words before it and the nr words after it:
  // "der/die Angestellte", "etw. tun/machen", "an jdn./etw. denken".
  const bind = (nl, nr) => {
    const prefix = lw.slice(0, lw.length - nl);
    const suffix = rw.slice(nr);
    return [[...prefix, ...lw.slice(lw.length - nl), ...suffix].join(' '), [...prefix, ...rw.slice(0, nr), ...suffix].join(' ')];
  };
  const nl = slotSpan(lw, true);
  const nr = slotSpan(rw, false);
  const group = parallelGroupStart(lw, firstRight);
  let pieces;
  if (nl && nr) {
    const leftSlot = slotWord(lw.slice(lw.length - nl).join(' '));
    const rightSlot = slotWord(rw.slice(0, nr).join(' '));
    const verbPhrases =
      lw.length > nl && rw.length > nr && PREVERBAL_REFLEXIVES.has(rightSlot) && !REFLEXIVE_SLOTS.has(leftSlot);
    // "laver qc/se laver" | "an jdn./etw. denken", "etw./sich ändern", "to wash sth/oneself"
    pieces = verbPhrases ? [left, right] : bind(nl, nr);
  } else if (isBareArticle(lastLeft) && isBareArticle(firstRight)) {
    pieces = bind(1, 1); // "mit der/dem Lehrer"
  } else if (group > 0) {
    pieces = [left, [...lw.slice(0, group), ...rw].join(' ')]; // "faire du vélo/du ski"
  } else if (lw.length === rw.length || (startsPhrase(firstRight) && !isBareArticle(lastLeft))) {
    pieces = [left, right]; // "beau/belle", "der Lehrer/die Lehrerin"
  } else {
    pieces = bind(1, 1);
  }
  const out = [];
  for (const piece of pieces) {
    for (const x of expandSlashes(piece, depth + 1)) if (out.length < MAX_SLASH_VARIANTS) out.push(x);
  }
  return out;
}

// Splits an answer into alternatives and sets aside the grammar annotations of
// the answer before them ("der Tisch, -e", "maison, f"). The stored answer drops
// every annotation; the learner's answer only drops the stored ones (`allowed`
// note keys), so "der Tisch, -s" for "der Tisch, -e" is still wrong.
function splitInternal(s, commas = true, allowed = null) {
  const alts = [];
  const notes = [];
  const seen = new Set();
  for (const seg of splitSegments(s, commas)) {
    for (const piece of expandSlashes(seg.trim())) {
      const alt = normalizeBasic(piece);
      if (!clean(foldScripts(alt)) || seen.has(alt)) continue;
      const annotation = alts.length > 0 && ANNOTATION.test(alt) && !ANNOTATION.test(alts[alts.length - 1]);
      if (annotation && (!allowed || allowed.has(noteKey(alt)))) {
        notes.push(alt);
        continue;
      }
      seen.add(alt);
      alts.push(alt);
    }
  }
  return { alts, notes };
}

// `lang` (optional) is the language of the answer; see isSentenceLike. The
// alternatives keep their characters as written (vowel marks, full-width brackets).
export function splitAlternatives(expected, lang) {
  try {
    const s = normalizeBasic(toStr(expected));
    return splitInternal(s, !isSentenceLike(foldScripts(s), resolveLang(lang))).alts;
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------
// Parentheses: "(sich) freuen" → "freuen" | "sich freuen"; "marié(e)" → "marié" | "mariée"

function bracketGroups(s) {
  if (!bracketsBalanced(s)) return [];
  const groups = [];
  let depth = 0;
  let start = -1;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (OPENERS.has(ch)) {
      if (depth++ === 0) start = i;
    } else if (CLOSERS.has(ch) && --depth === 0) {
      groups.push({ start, end: i + 1, content: s.slice(start + 1, i) });
    }
  }
  return groups;
}

function parenVariants(alt, optional) {
  const groups = bracketGroups(alt);
  if (!groups.length) return [{ text: alt, omitted: false, lock: false }];
  // With the toggle off, a bracketed leading article/pronoun is required too.
  const lock = !optional && /^[([]/.test(alt);
  const choices = groups.map((g) => {
    const list = [{ text: g.content, omitted: false }];
    if (optional) {
      list.unshift({ text: '', omitted: hasAlnum(g.content) });
      const subs = splitSegments(g.content).flatMap((x) => expandSlashes(x.trim())).filter((x) => clean(x));
      if (subs.length > 1) subs.forEach((x) => list.push({ text: x, omitted: false }));
    }
    return list;
  });
  const total = choices.reduce((n, list) => n * list.length, 1);
  let picks;
  if (total > MAX_PAREN_VARIANTS) {
    picks = [choices.map((list) => list[list.length > 1 ? 1 : 0])];
    if (optional) picks.push(choices.map((list) => list[0]));
  } else {
    picks = [[]];
    for (const list of choices) picks = picks.flatMap((p) => list.map((c) => [...p, c]));
  }
  return picks.map((p) => {
    let text = '';
    let pos = 0;
    groups.forEach((g, k) => {
      text += alt.slice(pos, g.start) + p[k].text;
      pos = g.end;
    });
    text = tidy(text + alt.slice(pos));
    return { text, omitted: p.some((c) => c.omitted), lock };
  });
}

// ---------------------------------------------------------------------------
// Chinese: tone numbers (ni3 hao3) and answers in characters and pinyin

// Tone marks 1–4 (macron, acute, caron, grave); 5 and 0 are the neutral tone.
const TONE_MARKS = ['', '\u0304', '\u0301', '\u030C', '\u0300'];
// A syllable: Latin letters (u: and v stand for ü) directly followed by a digit 0–5.
const TONE_SYLLABLE = /((?:[A-Za-zÜü]|[Uu]:)+)([0-5])/g;

// The vowel that carries the tone mark: a or e, o in "ou", otherwise the last vowel.
function toneVowel(syllable) {
  const low = syllable.toLowerCase();
  for (const v of ['a', 'e']) if (low.includes(v)) return low.indexOf(v);
  if (low.includes('ou')) return low.indexOf('ou');
  let at = -1;
  for (let i = 0; i < low.length; i++) if ('aeiouü'.includes(low[i])) at = i;
  return at;
}

// "ni3 hao3" → "nǐ hǎo", "lv4" → "lǜ", "ma5" → "ma"; syllables without a vowel stay as typed.
function toneMarks(s) {
  if (!/[0-5]/.test(s)) return s;
  return s.replace(TONE_SYLLABLE, (whole, letters, digit) => {
    const syllable = letters.replace(/u:/g, 'ü').replace(/U:/g, 'Ü').replace(/v/g, 'ü').replace(/V/g, 'Ü');
    const at = toneVowel(syllable);
    if (at < 0) return whole;
    const mark = TONE_MARKS[Number(digit)] || '';
    return (syllable.slice(0, at + 1) + mark + syllable.slice(at + 1)).normalize('NFC');
  });
}

const LATIN_LETTER = /[A-Za-z\u00C0-\u024F\u1E00-\u1EFF]/;
const BRACKET = /[()[\]（）［］【】]/;
const TRAILING_GROUP = /^([^()[\]（）［］【】]+?) ?[(（[［【]([^()[\]（）［］【】]+)[)）\]］】]$/;
const isHanPart = (s) => hasHan(s) && !LATIN_LETTER.test(s);
const isLatinPart = (s) => LATIN_LETTER.test(s) && !hasHan(s);

// An answer written in characters and pinyin: «你好 (nǐ hǎo)», «你好（nǐ hǎo）», «你好 nǐ hǎo»
// or «nǐ hǎo 你好» → { han: '你好', latin: 'nǐ hǎo' }; null for anything else.
function hanLatinParts(text) {
  const pair = (a, b) => {
    if (isHanPart(a) && isLatinPart(b)) return { han: a.trim(), latin: b.trim() };
    if (isLatinPart(a) && isHanPart(b)) return { han: b.trim(), latin: a.trim() };
    return null;
  };
  const m = text.match(TRAILING_GROUP);
  if (m) return pair(m[1], m[2]);
  if (BRACKET.test(text)) return null;
  for (let i = text.indexOf(' '); i > 0; i = text.indexOf(' ', i + 1)) {
    const found = pair(text.slice(0, i), text.slice(i + 1));
    if (found) return found;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Articles and reflexive pronouns

function splitArticle(text, lang) {
  const table = lang ? ARTICLE_TABLE[lang] : null;
  if (table) {
    for (const { token, kind, elided } of table) {
      if (text.slice(0, token.length).toLowerCase() !== token) continue;
      const rest = text.slice(token.length);
      if (!elided && rest[0] !== ' ') continue;
      const core = rest.trim();
      if (core && hasAlnum(core)) return { text, article: text.slice(0, token.length), kind, core };
    }
  }
  return { text, article: null, kind: null, core: text };
}

function sameArticle(a, b, lang) {
  const x = a.toLowerCase();
  const y = b.toLowerCase();
  if (x === y) return true;
  const map = ELISIONS[lang];
  return Boolean(map && ((map[x] && map[x].includes(y)) || (map[y] && map[y].includes(x))));
}

// "Herr, der" (dictionary style) → "der Herr"
function mergeLoneArticles(alts, lang) {
  const table = ARTICLE_TABLE[lang];
  if (!table) return alts;
  const loneArticle = (alt) => {
    const low = clean(alt).toLowerCase();
    return table.find((e) => e.kind === 'article' && e.token === low) || null;
  };
  const out = [];
  for (const alt of alts) {
    const low = clean(alt).toLowerCase();
    const entry = loneArticle(alt);
    const prev = out[out.length - 1];
    if (entry && prev && !loneArticle(prev) && !splitArticle(clean(prev), lang).article) {
      out[out.length - 1] = entry.elided ? `${low}${prev}` : `${low} ${prev}`;
    } else {
      out.push(alt);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Comparators

const COMBOS = [
  { c: false, a: false, t: false },
  { c: true, a: false, t: false },
  { c: false, a: true, t: false },
  { c: true, a: true, t: false },
  { c: false, a: false, t: true },
  { c: true, a: false, t: true },
  { c: false, a: true, t: true },
  { c: true, a: true, t: true },
];
// Arabic text adds the letter variants (v, always allowed): each combo is tried right
// after its twin without them, so a hamza difference is a variant, not an accent.
const VARIANT_COMBOS = COMBOS.flatMap((combo) => [combo, { ...combo, v: true }]);
const NON_TYPO = { c: true, a: true, t: false };
const ANY_COMBO = { c: true, a: true, t: true };

// Arabic letter variants: hamza forms and alef wasla → ا, ؤ → و, ئ → ي, ى → ي, ة → ه
// (and a madda or hamza left on another letter).
function foldVariants(s) {
  return s
    .replace(/[أإآٱ]/g, 'ا')
    .replace(/ؤ/g, 'و')
    .replace(/[ئى]/g, 'ي')
    .replace(/ة/g, 'ه')
    .replace(/[\u0653-\u0655]/g, '');
}

function foldForms(s, combo) {
  let base = combo.c ? s.toLowerCase() : s;
  if (combo.v) base = foldVariants(base);
  return combo.a ? [stripDiacritics(base), foldUmlauts(base)] : [base];
}

const HAN_ALL = new RegExp(`[${HAN_RANGE}]`, 'gu');
const hanOf = (s) => (s.match(HAN_ALL) || []).join('');

// Chinese characters earn no typo budget: a wrong character is never a typo.
function typoBudget(s, lang) {
  const n = countLetters(s) - (lang === 'zh' ? Array.from(hanOf(s)).length : 0);
  return n >= 10 ? 2 : n >= 4 ? 1 : 0;
}

// Optimal-string-alignment (restricted Damerau-Levenshtein) distance.
// Returns max + 1 as soon as the distance is known to exceed max.
function editDistance(a, b, max) {
  if (a === b) return 0;
  const x = Array.from(a);
  const y = Array.from(b);
  const n = x.length;
  const m = y.length;
  if (Math.abs(n - m) > max) return max + 1;
  if (!n || !m) return Math.max(n, m);
  if (n > MAX_DIST_LEN || m > MAX_DIST_LEN) return max + 1;
  let prev2 = new Array(m + 1).fill(0);
  let prev = Array.from({ length: m + 1 }, (_, j) => j);
  let cur = new Array(m + 1).fill(0);
  for (let i = 1; i <= n; i++) {
    cur[0] = i;
    let rowMin = i;
    for (let j = 1; j <= m; j++) {
      const cost = x[i - 1] === y[j - 1] ? 0 : 1;
      let v = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
      if (i > 1 && j > 1 && x[i - 1] === y[j - 2] && x[i - 2] === y[j - 1]) v = Math.min(v, prev2[j - 2] + 1);
      cur[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > max) return max + 1;
    [prev2, prev, cur] = [prev, cur, prev2];
  }
  return prev[m];
}

function comboMatches(g, e, combo, lang) {
  const gs = foldForms(g, combo);
  const es = foldForms(e, combo);
  for (let i = 0; i < es.length; i++) {
    if (gs[i] === es[i]) return true;
    if (combo.t) {
      const max = typoBudget(es[i], lang);
      // Chinese: the typo may only be in the pinyin, the characters must be the same.
      const sameHan = lang !== 'zh' || hanOf(gs[i]) === hanOf(es[i]);
      if (max > 0 && sameHan && editDistance(gs[i], es[i], max) <= max) return true;
    }
  }
  return false;
}

// First (least tolerant) permitted comparator under which g matches e.
function findCombo(g, e, allow, lang) {
  for (const combo of hasArabic(g) || hasArabic(e) ? VARIANT_COMBOS : COMBOS) {
    if ((combo.c && !allow.c) || (combo.a && !allow.a) || (combo.t && !allow.t)) continue;
    if (comboMatches(g, e, combo, lang)) return combo;
  }
  return null;
}

// Compares one given form with one expected form, handling articles.
// near: wrong article and the word is only close (hint pass only), e.g.
// "der Strase" for "die Straße"; not a wrongArticle, the word is off too.
function evalPair(g, e, allow, artOk, lang) {
  let best = null;
  let wrongArticle = false;
  let near = false;
  const consider = (combo, art) => {
    if (!combo) return;
    const rank = (combo.c ? 1 : 0) + (combo.a ? 2 : 0) + (combo.v ? 2 : 0) + (combo.t ? 8 : 0) + (art ? 4 : 0);
    if (!best || rank < best.rank) best = { combo, art, rank };
  };
  if (e.article) {
    if (g.article) {
      if (sameArticle(g.article, e.article, lang)) consider(findCombo(g.core, e.core, allow, lang), null);
      else if (findCombo(g.core, e.core, NON_TYPO, lang)) wrongArticle = true; // "la monsieur", "den Herr"
      else if (allow.hintPass && findCombo(g.core, e.core, ANY_COMBO, lang)) near = true;
    } else {
      if (artOk) consider(findCombo(g.text, e.core, allow, lang), e.kind);
      consider(findCombo(g.text, e.text, allow, lang), null); // typo across the space: "lemonsieur"
    }
  } else {
    consider(findCombo(g.text, e.text, allow, lang), null);
    if (g.article) consider(findCombo(g.core, e.text, allow, lang), null); // extra article is ignored
  }
  return { best, wrongArticle, near };
}

// Chinese: spaces do not count (pinyin syllables, characters).
function makeForms(text, tol, lang) {
  const squeeze = (s) => (lang === 'zh' ? s.replace(/ /g, '') : s);
  const rawText = squeeze(clean(text));
  const raw = splitArticle(rawText, lang);
  let exp = null;
  if (tol.abbreviations) {
    const expText = squeeze(clean(expandAbbreviations(text)));
    if (expText !== rawText) exp = splitArticle(expText, lang);
  }
  return { raw, exp };
}

// One expected alternative: its comparison variants and the articles it
// declares, including bracketed ones ("(der) Herr", "Herr (der)").
function prepareAlt(text, tol, lang) {
  const variants = [];
  const seen = new Set();
  const articles = new Set();
  const sources = parenVariants(text, tol.parentheses);
  const table = lang ? ARTICLE_TABLE[lang] : null;
  if (table) {
    for (const g of bracketGroups(text)) {
      const low = clean(g.content).toLowerCase();
      const entry = table.find((e) => e.token === low);
      if (!entry) continue;
      articles.add(low);
      // A trailing bracketed article also reads in front, like the dictionary
      // form "Herr, der": "Herr (der)" → "der Herr" (required when the toggle is off).
      const head = tidy(text.slice(0, g.start));
      if (
        !hasAlnum(text.slice(g.end)) &&
        hasAlnum(head) &&
        !bracketGroups(head).length &&
        !splitArticle(clean(head), lang).article
      ) {
        sources.push({ text: entry.elided ? `${low}${head}` : `${low} ${head}`, omitted: false, lock: !tol.parentheses });
      }
    }
  }
  // Chinese in characters and pinyin: the characters alone (no note, whatever the
  // brackets setting) or the pinyin alone (note 'pinyin').
  const zh = lang === 'zh' ? hanLatinParts(text) : null;
  if (zh) {
    sources.push({ text: zh.han, omitted: false, lock: false });
    const subs = splitSegments(zh.latin).flatMap((x) => expandSlashes(x.trim())).filter((x) => clean(x));
    for (const p of subs.length > 1 ? [zh.latin, ...subs] : [zh.latin]) sources.push({ text: p, omitted: false, lock: false, pinyin: true });
  }
  for (const v of sources) {
    const forms = makeForms(v.text, tol, lang);
    const pinyin = Boolean(v.pinyin);
    const id = `${forms.raw.text}\u0001${v.omitted}\u0001${pinyin}`;
    if (!forms.raw.text || seen.has(id)) continue;
    seen.add(id);
    if (forms.raw.article) articles.add(forms.raw.article.toLowerCase());
    variants.push({ ...forms, omitted: v.omitted, lock: v.lock, pinyin });
  }
  return { variants, articles: [...articles] };
}

// Best match of a given part against one expected alternative.
function matchPart(part, alt, allow, lang) {
  let best = null;
  let wrongArticle = false;
  let near = false;
  const given = part.raw.article;
  // A given article that the alternative contradicts ("den Herr" for "(der) Herr")
  // must not be excused by the variant without the bracketed article.
  const conflict = Boolean(given) && alt.articles.length > 0 && !alt.articles.some((a) => sameArticle(given, a, lang));
  for (const v of alt.variants) {
    if (conflict && !v.raw.article) {
      if (findCombo(part.raw.core, v.raw.core, NON_TYPO, lang)) wrongArticle = true;
      continue;
    }
    const artOk = allow.art && (allow.hintPass || !v.lock);
    const tries = [[part.raw, v.raw, false]];
    if (allow.abbr && (part.exp || v.exp)) tries.push([part.exp || part.raw, v.exp || v.raw, true]);
    for (const [g, e, usedAbbr] of tries) {
      const r = evalPair(g, e, allow, artOk, lang);
      if (r.wrongArticle) wrongArticle = true;
      if (r.near) near = true;
      if (!r.best) continue;
      const rank = r.best.rank + (usedAbbr ? 1 : 0) + (v.omitted ? 3 : 0) + (v.pinyin ? 1 : 0);
      if (!best || rank < best.rank) best = { ...r.best, rank, abbr: usedAbbr, paren: v.omitted, lock: v.lock, pinyin: v.pinyin };
    }
  }
  return { best, wrongArticle, near };
}

// ---------------------------------------------------------------------------
// Whole-answer evaluation

function evaluate(parts, alts, tol, lang) {
  const allow = { c: tol.ignoreCase, a: tol.ignoreAccents, t: tol.typos, art: tol.articles, abbr: tol.abbreviations };
  const results = parts.map((p) => alts.map((alt) => matchPart(p, alt, allow, lang)));
  const edges = results.map((row) => {
    // A wrong article on an otherwise matching word beats a mere typo match elsewhere.
    const blocked = row.some((r) => r.wrongArticle);
    const list = [];
    row.forEach((r, j) => {
      if (r.best && !(blocked && r.best.combo.t)) list.push({ ...r.best, j });
    });
    return list.sort((x, y) => x.rank - y.rank || x.j - y.j);
  });
  const failing = [];
  edges.forEach((list, i) => {
    if (!list.length) failing.push(i);
  });
  if (failing.length) return { correct: false, results, failing };

  // Maximum bipartite matching of given parts to distinct alternatives.
  const partOfAlt = new Array(alts.length).fill(-1);
  const altOfPart = new Array(parts.length).fill(-1);
  const assign = (i, seen) => {
    for (const edge of edges[i]) {
      if (seen.has(edge.j)) continue;
      seen.add(edge.j);
      if (partOfAlt[edge.j] < 0 || assign(partOfAlt[edge.j], seen)) {
        partOfAlt[edge.j] = i;
        altOfPart[i] = edge.j;
        return true;
      }
    }
    return false;
  };
  parts.forEach((_, i) => assign(i, new Set()));
  const covered = partOfAlt.filter((i) => i >= 0).length;
  if (!tol.multipleAnswers && covered < alts.length) return { correct: false, results, failing };

  const notes = new Set();
  const sequence = [];
  edges.forEach((list, i) => {
    const chosen = list.find((edge) => edge.j === altOfPart[i]) || list[0];
    sequence.push(chosen.j);
    if (chosen.art) notes.add(chosen.art);
    if (chosen.abbr) notes.add('abbreviation');
    if (chosen.paren) notes.add('parentheses');
    if (chosen.pinyin) notes.add('pinyin');
    if (chosen.combo.c && lang === 'de') notes.add('case');
    if (chosen.combo.a) notes.add(lang === 'zh' ? 'tones' : 'accents');
    if (chosen.combo.v) notes.add('variant');
    if (chosen.combo.t) notes.add('typo');
  });
  if (covered < alts.length) notes.add('partial');
  else if (sequence.some((j, k) => k > 0 && j < sequence[k - 1])) notes.add('order');
  return { correct: true, notes };
}

function hintFromMatch(best, tol, lang) {
  const { c, a, t } = best.combo;
  if (best.art && (!tol.articles || best.lock)) return 'missingArticle';
  const offA = a && !tol.ignoreAccents;
  const offC = c && !tol.ignoreCase;
  const offT = t && !tol.typos;
  if (!offA && !offC && !offT) return null;
  if (offA && !t) return offC ? 'almost' : lang === 'zh' ? 'tonesOnly' : 'accentsOnly';
  if (offC && !t) return 'caseOnly';
  if (offT) return 'typo';
  return 'almost';
}

const simFold = (s) => stripDiacritics(clean(s).toLowerCase());

function isAlmost(given, target) {
  const a = simFold(given);
  const b = simFold(target);
  const len = Math.max(Array.from(a).length, Array.from(b).length);
  if (!len || len > MAX_DIST_LEN) return false;
  const budget = Math.floor(len * (1 - ALMOST_SIMILARITY));
  return editDistance(a, b, budget) <= budget;
}

function computeHint(failure, alts, altTexts, tol, lang, givenText, expectedText) {
  const { parts, res } = failure;
  const found = new Set();
  const hintAllow = { c: true, a: true, t: true, art: true, abbr: tol.abbreviations, hintPass: true };
  for (const i of res.failing) {
    if (res.results[i].some((r) => r.wrongArticle)) found.add('wrongArticle');
    for (const alt of alts) {
      const r = matchPart(parts[i], alt, hintAllow, lang);
      if (r.wrongArticle) found.add('wrongArticle');
      if (r.near) found.add('almost');
      const h = r.best ? hintFromMatch(r.best, tol, lang) : null;
      if (h) found.add(h);
    }
  }
  for (const h of HINT_ORDER) if (found.has(h)) return h;
  const targets = [expectedText, ...altTexts];
  return targets.some((t) => isAlmost(givenText, t)) ? 'almost' : null;
}

function resolveTolerance(tolerance) {
  let src = tolerance && typeof tolerance === 'object' ? tolerance : {};
  if (src.tolerance && typeof src.tolerance === 'object') src = src.tolerance; // full StudyOptions
  const out = {};
  for (const key of Object.keys(DEFAULT_TOLERANCE)) {
    out[key] = typeof src[key] === 'boolean' ? src[key] : DEFAULT_TOLERANCE[key];
  }
  return out;
}

function resolveLang(lang) {
  const code = typeof lang === 'string' ? lang.trim().toLowerCase().slice(0, 2) : '';
  return ARTICLE_TABLE[code] ? code : null;
}

function sortNotes(set) {
  return NOTE_ORDER.filter((n) => set.has(n));
}

const symbolKey = (s) => s.replace(/\s+/g, '').replace(/\.\.\./g, '…');

function gradeInner(given, expected, tolerance, lang, expectedDisplay) {
  const result = (correct, exact, notes, hint) => ({ correct, exact, notes, hint, expectedDisplay });
  const tol = resolveTolerance(tolerance);
  const L = resolveLang(lang);
  // Chinese: tone numbers are tone marks (ni3 hao3 = nǐ hǎo) on both sides.
  const gPrep = L === 'zh' ? toneMarks(prep(given)) : prep(given);
  const ePrep = L === 'zh' ? toneMarks(prep(expected)) : prep(expected);
  if (!gPrep) return result(false, false, [], null);

  // A sentence is one answer for both sides: its commas are not separators.
  const commas = !isSentenceLike(ePrep, L);
  const { alts: eSegs, notes: eNotes } = splitInternal(ePrep, commas);
  const gSegs = splitInternal(gPrep, commas, new Set(eNotes.map(noteKey))).alts;
  const eKey = eSegs.map(keyOf).join('|');
  if (eKey && gSegs.map(keyOf).join('|') === eKey) return result(true, true, [], null);
  if (!eSegs.length && !hasAlnum(ePrep)) {
    // Only punctuation or symbols ("?", "…", "-"): compare them as typed.
    const ok = symbolKey(gPrep) === symbolKey(ePrep);
    return result(ok, ok, [], null);
  }

  let altTexts = L ? mergeLoneArticles(eSegs, L) : eSegs;
  if (altTexts.length > MAX_PARTS) altTexts = [ePrep];
  const alts = altTexts.map((t) => prepareAlt(t, tol, L)).filter((a) => a.variants.length);
  const givenPart = (t) => makeForms(t, tol, L);
  const parts = (gSegs.length > MAX_PARTS ? [gPrep] : gSegs).map(givenPart).filter((p) => p.raw.text);
  if (!alts.length || !parts.length) return result(false, false, [], null);

  // Read the answer as separate parts first, then as one string, e.g. for
  // "freuen über, auf" against "freuen (über, auf)".
  const readings = [parts];
  if (parts.length > 1) readings.push([givenPart(gPrep)]);
  let failure = null;
  for (const ps of readings) {
    const res = evaluate(ps, alts, tol, L);
    if (res.correct) return result(true, false, sortNotes(res.notes), null);
    if (!failure) failure = { parts: ps, res };
  }
  return result(false, false, [], computeHint(failure, alts, altTexts, tol, L, gPrep, ePrep));
}

export function grade(given, expected, tolerance, lang) {
  const expectedDisplay = toStr(expected);
  try {
    return gradeInner(given, expected, tolerance, lang, expectedDisplay);
  } catch {
    // Safety net: grading must never break a study session.
    const g = normalizeBasic(toStr(given));
    const ok = g !== '' && g === normalizeBasic(expectedDisplay);
    return { correct: ok, exact: ok, notes: [], hint: null, expectedDisplay };
  }
}

// ---------------------------------------------------------------------------
// Character diff for highlighting ('del' = typed but wrong, 'add' = missing)

// A letter with its combining marks (an Arabic vowel mark never stands alone).
const CLUSTER = /\P{M}\p{M}*|\p{M}+/gu;
const clusters = (s) => toStr(s).normalize('NFC').trim().match(CLUSTER) || [];

export function diffChars(given, expected) {
  const a = clusters(given);
  const b = clusters(expected);
  const out = [];
  const push = (type, chars) => {
    if (!chars.length) return;
    const text = chars.join('');
    const last = out[out.length - 1];
    if (last && last.type === type) last.text += text;
    else out.push({ type, text });
  };
  let pre = 0;
  while (pre < a.length && pre < b.length && a[pre] === b[pre]) pre++;
  let suf = 0;
  while (suf < a.length - pre && suf < b.length - pre && a[a.length - 1 - suf] === b[b.length - 1 - suf]) suf++;
  push('same', a.slice(0, pre));
  const x = a.slice(pre, a.length - suf);
  const y = b.slice(pre, b.length - suf);
  const n = x.length;
  const m = y.length;
  if (n && m && (n + 1) * (m + 1) <= MAX_DIFF_CELLS) {
    // dp[i * w + j] = LCS length of x[i:] and y[j:]
    const w = m + 1;
    const dp = new Uint32Array((n + 1) * w);
    for (let i = n - 1; i >= 0; i--) {
      for (let j = m - 1; j >= 0; j--) {
        dp[i * w + j] = x[i] === y[j] ? dp[(i + 1) * w + j + 1] + 1 : Math.max(dp[(i + 1) * w + j], dp[i * w + j + 1]);
      }
    }
    let i = 0;
    let j = 0;
    while (i < n && j < m) {
      if (x[i] === y[j]) {
        push('same', [x[i++]]);
        j++;
      } else if (dp[(i + 1) * w + j] >= dp[i * w + j + 1]) {
        push('del', [x[i++]]);
      } else {
        push('add', [y[j++]]);
      }
    }
    push('del', x.slice(i));
    push('add', y.slice(j));
  } else {
    push('del', x);
    push('add', y);
  }
  push('same', a.slice(a.length - suf));
  return out;
}

const diffCost = (parts) => parts.reduce((n, p) => n + (p.type === 'same' ? 0 : p.text.length), 0);

// diffChars for the answer feedback: both sides get the normalisation that
// grading treats as equal (apostrophes, spaces, ß ≡ ss, œ ≡ oe), so only real
// mistakes are highlighted. A ligature is kept when the learner typed one;
// Arabic vowel marks only show when the learner typed some. `lang` (optional,
// the answer language): Chinese reads tone numbers as marks and diffs against
// the form typed (characters and pinyin, characters or pinyin).
export function diffAnswer(given, expected, lang) {
  let g = normalizeBasic(toStr(given)).replace(/ *' */g, "'");
  let e = normalizeBasic(toStr(expected)).replace(/ *' */g, "'");
  if (!LIGATURES.test(g)) e = foldLigatures(e);
  else if (!LIGATURES.test(e)) g = foldLigatures(g);
  if (hasArabic(e) && stripArabicMarks(g) === g) e = stripArabicMarks(e);
  if (resolveLang(lang) !== 'zh') return diffChars(g, e);
  g = toneMarks(g);
  e = toneMarks(e);
  const parts = hanLatinParts(e);
  let best = diffChars(g, e);
  for (const form of parts ? [parts.han, parts.latin] : []) {
    const d = diffChars(g, form);
    if (diffCost(d) < diffCost(best)) best = d;
  }
  return best;
}
