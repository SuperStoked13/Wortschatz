// Word classes ("Wortart") for multiple-choice options (since 23.11.2026).
//
// Wrong options should look like the right one: they come from cards of the same word class
// (noun, verb, adjective/adverb, expression, number) and among those from the most similar ones
// (learn.js ranks them with `optionRanker`).
//
// The class of a card comes from cues on both of its sides. A side gives one class and a strength:
// 2 (strong) for articles ("le", "der", "the"), "to", "se", "sich", gender marks (", f.", "(in)"),
// French feminine forms ("amusant, amusante", "marié(e)"), sentence punctuation and numbers;
// 1 (weak) for German capitalisation and lowercase, endings ("-ung", "-lich", "-tion", "-ous",
// French "-er") and long texts. Both sides agreeing or only one having a cue gives the class; with
// different classes the stronger cue wins, equal strengths leave the class open ('').
// Many cues hold in one language only ("-er" is a French verb but an English noun), so each side's
// language is detected over the whole list (`sideProfile`, detectColumn).
//
// Pure and DOM-free (runs under jsc). No regular expressions and integer arithmetic only, so the
// Swift and C# ports follow it step by step.

import { normalizeBasic, foldScripts, isLetter } from './text.js';
import { detectColumn } from './langdetect.js';

export const NOUN = 'noun';
export const VERB = 'verb';
export const ADJ = 'adj';
export const PHRASE = 'phrase';
export const NUMBER = 'number';

const ARTICLES = {
  fr: ['le', 'la', 'les', 'un', 'une', 'des', 'du'],
  de: ['der', 'die', 'das', 'ein', 'eine'],
  en: ['the', 'a', 'an'],
  es: ['el', 'la', 'los', 'las', 'un', 'una', 'unos', 'unas'],
  it: ['il', 'lo', 'la', 'i', 'gli', 'le', 'un', 'uno', 'una'],
};
// A side of another language: the articles that are no other common word.
const SAFE_ARTICLES = ['le', 'la', 'les', 'une', 'der', 'das', 'the', 'el', 'los', 'las', 'lo', 'gli', 'una', 'uno'];
// First words that make a verb: "to go", "se lever", "sich freuen".
const VERB_LEADS = ['to', 'se', 'sich'];
// Placeholders for objects: "etw. vorschlagen", "to propose sth", "donner qc à qn".
const OBJECTS = [
  'etw', 'etw.', 'jmdn', 'jmdn.', 'jmdm', 'jmdm.', 'jmds', 'jmds.', 'jdn', 'jdn.', 'jdm', 'jdm.', 'jds', 'jds.',
  'jemanden', 'jemandem', 'sth', 'sth.', 'sb', 'sb.', "sb's", 'qc', 'qc.', 'qn', 'qn.', 'qch', 'qch.', 'qqch',
  'qqch.', 'qqn', 'qqn.',
];
// Gender marks after a comma: "l'oreille, f.", "l'œil, m. les yeux".
const GENDER_MARKS = ['m', 'm.', 'f', 'f.', 'n', 'n.', 'pl', 'pl.', 'm.pl.', 'f.pl.', 'm/f', 'm./f.'];
const GENDER_PARENS = ['(m)', '(m.)', '(f)', '(f.)', '(n)', '(n.)', '(pl)', '(pl.)', '(in)'];
// French feminine endings in brackets or after a comma: "marié(e)", "grand, e", "heureux, -euse".
const FEMININE_ENDINGS = ['e', 'ne', 'le', 'se', 'te', 've', 'ère', 'euse', 'ive', 'elle', 'enne', 'ienne', 'trice'];

// German: words after the verb ("Lust haben auf"), first words of adverbial phrases ("im Inland"),
// words with a verb ending that are no verbs, noun and adjective endings.
const DE_PARTICLES = ['an', 'auf', 'aus', 'bei', 'für', 'gegen', 'in', 'mit', 'nach', 'um', 'von', 'vor', 'zu', 'über'];
const DE_PREPOSITIONS = [
  'als', 'am', 'an', 'ans', 'auf', 'aus', 'bei', 'beim', 'durch', 'für', 'gegen', 'im', 'in', 'ins', 'mit', 'nach',
  'ohne', 'pro', 'um', 'unter', 'vom', 'von', 'vor', 'zu', 'zum', 'zur', 'über',
];
const DE_NOT_VERBS = [
  'modern', 'intern', 'extern', 'gestern', 'morgen', 'golden', 'offen', 'eigen', 'trocken', 'verschieden', 'zufrieden',
  'oben', 'unten', 'innen', 'aussen', 'hinten', 'vorne', 'neben', 'gegen', 'eben', 'selten', 'wegen',
];
const DE_NOUN_ENDINGS = ['ung', 'heit', 'keit', 'schaft', 'tion', 'tät', 'ismus', 'nis', 'ment', 'ling'];
const DE_ADJ_ENDINGS = ['ig', 'lich', 'isch', 'bar', 'sam', 'haft', 'los', 'voll'];
const EN_NOUN_ENDINGS = ['tion', 'sion', 'ment', 'ness', 'ity', 'ism', 'ship', 'ance', 'ence', 'hood', 'dom'];
const EN_ADJ_ENDINGS = ['ous', 'ful', 'less', 'ive', 'able', 'ible', 'al', 'ic', 'ish', 'ly'];
const FR_NOUN_ENDINGS = ['tion', 'sion', 'isme'];
const FR_ADJ_ENDINGS = ['eux', 'euse', 'if', 'ive', 'able', 'ible', 'ique', 'ment'];
// French words with an infinitive ending that are no verbs.
const FR_NOT_VERBS = [
  'hier', 'cher', 'fier', 'amer', 'super', 'premier', 'dernier', 'entier', 'léger', 'étranger', 'autre', 'libre',
  'propre', 'pauvre', 'rare', 'sombre', 'célèbre', 'contre', 'entre', 'notre', 'votre', 'quatre', 'noir', 'soir',
  'mer', 'hiver', 'plaisir', 'désir', 'avenir', 'loisir',
];
// Spanish and Italian adjectives and adverbs.
const ROMANCE_ADJ_ENDINGS = ['oso', 'osa', 'mente'];

const NONE = { cls: '', strength: 0 };

// ---------------------------------------------------------------------------
// Small helpers (code points, like Swift's unicode scalars)

const chars = (s) => Array.from(s);
const words = (s) => s.split(' ').filter((w) => w !== '');
const isDigit = (ch) => ch >= '0' && ch <= '9';
const endsWithAny = (word, endings, minLength) =>
  chars(word).length >= minLength && endings.some((e) => word.endsWith(e) && chars(word).length > chars(e).length);
const isUpper = (ch) => ch !== undefined && ch.toLowerCase() !== ch;
const isLower = (ch) => ch !== undefined && isLetter(ch) && ch.toLowerCase() === ch;

// The text without bracketed parts ("(verabschiedetes) Gesetz" → "Gesetz") or, with `keep`, without
// only the brackets ("(sich) freuen" → "sich freuen"); single spaces.
function brackets(s, keep) {
  let out = '';
  let depth = 0;
  for (const ch of chars(s)) {
    if (ch === '(' || ch === '[') depth++;
    else if ((ch === ')' || ch === ']') && depth > 0) depth--;
    else if (keep || depth === 0) out += ch;
  }
  return words(out).join(' ');
}

// The pieces between commas and semicolons, trimmed.
function segments(s) {
  const out = [''];
  for (const ch of chars(s)) {
    if (ch === ',' || ch === ';') out.push('');
    else out[out.length - 1] += ch;
  }
  return out.map((x) => words(x).join(' '));
}

// The article a text starts with ("le", "l'", "der/die") or ''. `list`: lowercase words.
function articleOf(list, lang) {
  if (list.length === 0) return '';
  const first = list[0];
  if ((lang === 'fr' || lang === 'it' || !ARTICLES[lang]) && first.startsWith("l'") && chars(first).length > 2) return "l'";
  if (list.length < 2) return '';
  const known = ARTICLES[lang] || SAFE_ARTICLES;
  return first.split('/').every((part) => known.includes(part)) ? first : '';
}

// ---------------------------------------------------------------------------
// Sides

// What a side of the list says about its texts: the language (detectColumn) and how it uses capitals.
// German: `wordCaps` – nouns are capitalised (a fifth of the texts or more have a capitalised word),
// so a word in lowercase is no noun; `capsNoun` – texts start with capitals and with lowercase
// letters alike, so a text starting with a capital is a noun (not so where every text is
// capitalised). Other languages: `capsRare` – few texts start with a capital, so one that does is a
// name ("Noël", "Congress").
export function sideProfile(texts) {
  const list = (Array.isArray(texts) ? texts : []).map((t) => normalizeBasic(t)).filter((t) => t !== '');
  const lang = detectColumn(list).lang;
  let upper = 0;
  let lower = 0;
  let capitalised = 0;
  for (const t of list) {
    const first = chars(t)[0];
    if (isUpper(first)) upper++;
    else if (isLower(first)) lower++;
    if (words(t).some((w) => isUpper(chars(w)[0]))) capitalised++;
  }
  const letters = upper + lower;
  const german = lang === 'de' && letters > 0;
  return {
    lang,
    wordCaps: german && capitalised * 5 >= list.length,
    capsNoun: german && upper * 10 >= letters && lower * 10 >= letters,
    capsRare: lang !== 'de' && letters > 0 && upper * 4 <= letters,
  };
}

const UNKNOWN_SIDE = { lang: 'unknown', wordCaps: false, capsNoun: false, capsRare: false };

// ---------------------------------------------------------------------------
// Texts

// The parts of a text the cues look at: the whole text in lowercase, its comma pieces, the first
// piece's words without brackets (`cut`, lowercase, `caps`: which start with a capital) and with
// the bracketed words (`keep`).
function parse(text) {
  const base = foldScripts(normalizeBasic(text));
  const segs = segments(base);
  const main = segs[0];
  const cut = words(brackets(main, false) || brackets(main, true));
  return {
    low: base.toLowerCase(),
    segs: segs.map((x) => x.toLowerCase()),
    cut: cut.map((w) => w.toLowerCase()),
    caps: cut.map((w) => isUpper(chars(w)[0])),
    keep: words(brackets(main, true).toLowerCase()),
  };
}

// Only digits and separators: "1474", "1914-1918", "3,5".
function isNumber(low) {
  const list = chars(low);
  if (!list.length || !isDigit(list[0])) return false;
  return list.every((ch) => isDigit(ch) || " .,:/'-+%".includes(ch));
}

// A sentence or exclamation: "Achtung!", "Wie geht's?", "C'est mon tour." (not "etw. tun bei etw.").
function isSentence(p) {
  const list = chars(p.low);
  const first = list[0];
  const last = list[list.length - 1];
  if (first === '¿' || first === '¡' || last === '!' || last === '?') return true;
  if ((last !== '.' && last !== '…') || !p.low.includes(' ')) return false;
  return !OBJECTS.includes(words(p.low).pop());
}

// "amusant, amusante", "grand, e", "heureux, -euse", "marié(e)": French, Spanish or Italian adjective.
function isFeminineForm(p) {
  for (const w of words(p.segs[0])) {
    for (const e of FEMININE_ENDINGS) if (w.endsWith(`(${e})`) && chars(w).length > chars(e).length + 2) return true;
  }
  if (p.segs.length < 2 || p.cut.length !== 1) return false;
  const a = p.segs[0];
  let b = p.segs[1];
  if (b.startsWith('-')) b = b.slice(1);
  if (FEMININE_ENDINGS.includes(b)) return true;
  if (words(b).length !== 1 || a === b) return false;
  const x = chars(a);
  const y = chars(b);
  let common = 0;
  while (common < x.length && common < y.length && x[common] === y[common]) common++;
  return common >= 3 && common >= x.length - 2 && y.length >= x.length;
}

// The words of the first piece without placeholders ("etw.", "sth"): `list` (lowercase), `caps`
// (which start with a capital) and whether there were placeholders.
function content(p) {
  const list = [];
  const caps = [];
  for (let i = 0; i < p.cut.length; i++) {
    if (OBJECTS.includes(p.cut[i])) continue;
    list.push(p.cut[i]);
    caps.push(p.caps[i]);
  }
  return { list, caps, objects: list.length !== p.cut.length };
}

// German verb or verb phrase on a side with capitalised nouns: the last word (before particles,
// "Lust haben auf") in lowercase with a verb ending – "essen", "Schmerzen haben", "eine Wahl
// abhalten". Strength 2 with placeholders or an article in front, otherwise 1; 0 = no verb.
function germanVerb(p, side) {
  const c = content(p);
  if (!side.wordCaps || !c.list.length) return 0;
  let v = c.list.length - 1;
  if (v >= 1 && DE_PARTICLES.includes(c.list[v])) v--;
  const verb = c.list[v];
  if (c.caps[v] || DE_NOT_VERBS.includes(verb)) return 0;
  if (!endsWithAny(verb, ['en', 'ern', 'eln'], 4) && !verb.endsWith('tun') && verb !== 'sein') return 0;
  return c.objects || (v >= 1 && ARTICLES.de.includes(c.list[0])) ? 2 : 1;
}

// Cues of one language (weak ones and the language's own strong ones), then a name ("Noël") or a
// long text without other cues.
function languageCues(p, side) {
  const { list, caps, objects } = content(p);
  if (!list.length) return NONE;
  const last = list[list.length - 1];
  const single = list.length === 1;
  const capital = caps[0];
  switch (side.lang) {
    case 'de': {
      const verb = germanVerb(p, side);
      if (verb) return { cls: VERB, strength: verb };
      // The noun comes last, before particles: "gemeinsame Reaktion auf etw.".
      let h = list.length - 1;
      if (h >= 1 && DE_PARTICLES.includes(list[h])) h--;
      if (endsWithAny(list[h], DE_NOUN_ENDINGS, 5)) return { cls: NOUN, strength: 2 };
      if (capital) {
        if (side.capsNoun) return { cls: NOUN, strength: 2 };
        break;
      }
      if (!side.wordCaps) break;
      // Lowercase: an adverbial phrase ("im Inland"), an adjective with a noun ("gemeinsame Politik")
      // or an adjective, adverb ("unbedingt erforderlich").
      if (!single && DE_PREPOSITIONS.includes(list[0])) return { cls: ADJ, strength: 1 };
      if (caps[h]) return { cls: NOUN, strength: 1 };
      return { cls: ADJ, strength: endsWithAny(list[h], DE_ADJ_ENDINGS, 4) ? 2 : 1 };
    }
    case 'en':
      if (endsWithAny(last, EN_NOUN_ENDINGS, 5)) return { cls: NOUN, strength: 1 };
      if (single && endsWithAny(last, EN_ADJ_ENDINGS, 5)) return { cls: ADJ, strength: 1 };
      break;
    case 'fr': {
      const first = list[0];
      const n = chars(first).length;
      const infinitive =
        !FR_NOT_VERBS.includes(first) &&
        ((n >= 5 && (first.endsWith('er') || first.endsWith('ir'))) || (n >= 4 && (first.endsWith('oir') || first.endsWith('re'))));
      if (infinitive) return { cls: VERB, strength: 1 };
      if (single && endsWithAny(last, FR_NOUN_ENDINGS, 5)) return { cls: NOUN, strength: 1 };
      if (single && endsWithAny(last, FR_ADJ_ENDINGS, 4)) return { cls: ADJ, strength: 1 };
      break;
    }
    case 'es':
      if (single && (last.endsWith('arse') || last.endsWith('erse') || last.endsWith('irse'))) return { cls: VERB, strength: 2 };
      if (single && endsWithAny(last, ['ar', 'er', 'ir'], 4)) return { cls: VERB, strength: 1 };
      if (single && endsWithAny(last, ROMANCE_ADJ_ENDINGS, 4)) return { cls: ADJ, strength: 1 };
      break;
    case 'it':
      if (single && (last.endsWith('arsi') || last.endsWith('ersi') || last.endsWith('irsi'))) return { cls: VERB, strength: 2 };
      if (single && endsWithAny(last, ['are', 'ere', 'ire'], 5)) return { cls: VERB, strength: 1 };
      if (single && endsWithAny(last, ROMANCE_ADJ_ENDINGS, 4)) return { cls: ADJ, strength: 1 };
      break;
    default:
      break;
  }
  if (side.capsRare && capital) return { cls: NOUN, strength: 1 };
  if (list.length >= 5) return { cls: PHRASE, strength: 1 };
  return NONE;
}

// The class one side of a card points to, with its strength: { cls, strength } (cls '' = no cue).
export function textClass(text, side = UNKNOWN_SIDE) {
  const p = parse(text);
  if (!p.cut.length) return NONE;
  if (isNumber(p.low)) return { cls: NUMBER, strength: 2 };
  if (p.segs.slice(1).some((x) => GENDER_MARKS.includes(x) || x.startsWith('m. ') || x.startsWith('f. '))) {
    return { cls: NOUN, strength: 2 };
  }
  if (GENDER_PARENS.some((x) => p.low.includes(x))) return { cls: NOUN, strength: 2 };
  if (isSentence(p)) return { cls: PHRASE, strength: 2 };
  const first = p.keep[0];
  if (p.keep.length >= 2 && VERB_LEADS.includes(first)) return { cls: VERB, strength: 2 };
  if ((side.lang === 'fr' || side.lang === 'unknown') && first.startsWith("s'") && chars(first).length > 2) {
    return { cls: VERB, strength: 2 };
  }
  if (side.lang === 'de' && p.cut.length >= 2) {
    const verb = germanVerb(p, side);
    if (verb) return { cls: VERB, strength: verb };
  }
  if (articleOf(p.cut, side.lang)) return { cls: NOUN, strength: 2 };
  const romance = side.lang === 'fr' || side.lang === 'es' || side.lang === 'it' || side.lang === 'unknown';
  if (romance && isFeminineForm(p)) return { cls: ADJ, strength: 2 };
  return languageCues(p, side);
}

// The class of a card from both sides ('' when open). `term`, `definition`: textClass results.
// Different strong classes make a class of their own ("number/phrase": a year and an event).
export function combineClasses(term, definition) {
  if (!term.cls) return definition.cls;
  if (!definition.cls || term.cls === definition.cls) return term.cls;
  if (term.strength !== definition.strength) return term.strength > definition.strength ? term.cls : definition.cls;
  return term.strength === 2 ? `${term.cls}/${definition.cls}` : '';
}

// What the options of a side are compared by: the article, the rest without it ("head"), its words
// and length in code points.
export function optionShape(text, side = UNKNOWN_SIDE) {
  const p = parse(text);
  const article = articleOf(p.cut, side.lang);
  let rest = p.cut;
  if (article === "l'") rest = [p.cut[0].slice(2), ...p.cut.slice(1)];
  else if (article) rest = p.cut.slice(1);
  const head = rest.join(' ');
  return { article, head, words: rest.length, length: chars(head).length };
}

// Similarity points of two option shapes: the same article, as many words, a similar length, the
// same first two and last three letters (0–4).
export function shapePoints(a, b) {
  let points = 0;
  if (a.article && a.article === b.article) points++;
  if (a.words === b.words) points++;
  if (Math.abs(a.length - b.length) <= Math.max(2, Math.floor(a.length / 5))) points++;
  const x = chars(a.head);
  const y = chars(b.head);
  if (x.length >= 2 && y.length >= 2 && x[0] === y[0] && x[1] === y[1]) points++;
  if (x.length >= 3 && y.length >= 3 && x.slice(-3).join('') === y.slice(-3).join('')) points++;
  return points;
}

// Points for cards close together in the set (sets are mostly ordered by topic): 3 up to 3 apart,
// 2 up to 10, 1 up to 25.
export function nearPoints(distance) {
  if (distance <= 3) return 3;
  if (distance <= 10) return 2;
  if (distance <= 25) return 1;
  return 0;
}

// ---------------------------------------------------------------------------
// Cards of a list

// Results per text and side, computed once (a round compares every card with every card of the set).
const LIMIT = 50000;
const profileMemo = new Map();
const classMemo = new Map();
const shapeMemo = new Map();

function memo(map, key, compute) {
  if (map.has(key)) return map.get(key);
  const value = compute();
  if (map.size >= LIMIT) map.clear();
  map.set(key, value);
  return value;
}

const sideKey = (side) => `${side.lang}|${side.wordCaps ? 1 : 0}${side.capsNoun ? 1 : 0}${side.capsRare ? 1 : 0}|`;

// A memo key for a list of texts (each with its length, so no two lists share one).
const listKey = (texts) => texts.map((t) => `${t.length}:${t}`).join('');

// The profiles of both sides of `list` (cards with string sides): { term, definition }.
export function listProfiles(list) {
  const term = list.map((c) => c.term);
  const definition = list.map((c) => c.definition);
  return {
    term: memo(profileMemo, listKey(term), () => sideProfile(term)),
    definition: memo(profileMemo, listKey(definition), () => sideProfile(definition)),
  };
}

// The word class of a card ('' when open). `sides`: listProfiles of its list.
export function cardClass(card, sides) {
  const term = memo(classMemo, sideKey(sides.term) + card.term, () => textClass(card.term, sides.term));
  const definition = memo(classMemo, sideKey(sides.definition) + card.definition, () => textClass(card.definition, sides.definition));
  return combineClasses(term, definition);
}

// optionShape, computed once per text and side.
export function shapeOf(text, side) {
  return memo(shapeMemo, sideKey(side) + text, () => optionShape(text, side));
}
