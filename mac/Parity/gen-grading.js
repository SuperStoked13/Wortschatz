// Parity fixture for src/core/grading.js → Fixtures/grading.json.
//
// fns:
//   grade             [given, expected, tolerance, lang]   → GradeResult (tolerance and lang as passed to JS,
//                                                             including odd values: null, StudyOptions, 'DE', 42)
//   gradeMatrix       [given, expected, lang, masks]       → [[correct, exact, notes, hint]], one per tolerance
//                                                             mask (bit b = DEFAULT_TOLERANCE key b, in key order);
//                                                             expectedDisplay is checked by the grade cases
//   splitAlternatives [expected, lang]                     → [string]
//   diffChars         [given, expected]                    → [{type, text}]
//   diffAnswer        [given, expected, lang]              → [{type, text}] (lang null: none)
//   constants         [name]                               → ARTICLES | REFLEXIVES | GLUED_ARTICLES |
//                                                             DEFAULT_TOLERANCE |
//                                                             ABBREVIATIONS ([source, flags, canonical])
//
// Inputs: every call with literal arguments in tests/grading.test.js and every string literal in it, plus
// every card side of every tests/fixtures list (parsed with parseVocab). For each stored answer many
// given answers are derived (exact, article removed/changed, reflexive removed, case, accents, umlaut
// transliteration, ß/ss, ligatures, seeded typos and swaps, abbreviation forms, single and reordered
// alternatives, brackets kept/dropped, punctuation, spacing, empty, garbage, other cards' answers) and
// graded under the default, all-on, all-off and single-toggle tolerances in the answer's language
// (and sometimes none or a wrong one). Arabic and Chinese answers also get their script variants
// (vowel marks, tatweel, letter variants, presentation forms, characters or pinyin alone, tone
// numbers, spaces, full-width punctuation).
import {
  grade,
  splitAlternatives,
  diffChars,
  diffAnswer,
  ARTICLES,
  REFLEXIVES,
  GLUED_ARTICLES,
  ABBREVIATIONS,
  DEFAULT_TOLERANCE,
} from '../../Website/src/core/grading.js';
import { stripDiacritics, foldUmlauts, stripArabicMarks, hasArabic, hasHan } from '../../Website/src/core/text.js';
import { parseVocab } from '../../Website/src/core/parser.js';
import { Cases, mulberry32, pick, randInt, chance, fuzzString, fixtureTexts, readText } from './lib.js';

const cases = new Cases('grading');
const rng = mulberry32(0x6a7ad1);

// JSON (and Swift strings) cannot carry lone surrogates: such cases are left to the unit tests.
const LONE_SURROGATE = /\\u[dD][89a-fA-F]/;
const record = cases.add.bind(cases);
cases.add = (fn, args, out) => {
  if (!LONE_SURROGATE.test(JSON.stringify(args))) record(fn, args, out);
};

// ---------------------------------------------------------------------------
// Tolerance masks

const KEYS = Object.keys(DEFAULT_TOLERANCE);
const maskOf = (tol) => KEYS.reduce((m, k, b) => m | (tol[k] ? 1 << b : 0), 0);
const tolOf = (mask) => Object.fromEntries(KEYS.map((k, b) => [k, Boolean(mask & (1 << b))]));
const DEFAULT_MASK = maskOf(DEFAULT_TOLERANCE);
const ALL_ON_MASK = (1 << KEYS.length) - 1;
const STANDARD = [DEFAULT_MASK, ALL_ON_MASK, 0, ...KEYS.map((_, b) => DEFAULT_MASK ^ (1 << b))];

function gradeMatrix(given, expected, lang, masks) {
  const results = masks.map((m) => grade(given, expected, tolOf(m), lang));
  cases.add('gradeMatrix', [given, expected, lang, masks], results.map((r) => [r.correct, r.exact, r.notes, r.hint]));
  // Every 25th one also in full (expectedDisplay, JSON shape).
  if (++matrixCount % 25 === 0) cases.add('grade', [given, expected, tolOf(masks[1] ?? masks[0]), lang], grade(given, expected, tolOf(masks[1] ?? masks[0]), lang));
}
let matrixCount = 0;

// Default + two other standard combos, sometimes a random one.
function someMasks() {
  const masks = [DEFAULT_MASK];
  while (masks.length < 3) {
    const m = pick(rng, STANDARD);
    if (!masks.includes(m)) masks.push(m);
  }
  if (chance(rng, 0.25)) {
    const m = randInt(rng, 0, ALL_ON_MASK);
    if (!masks.includes(m)) masks.push(m);
  }
  return masks;
}

// ---------------------------------------------------------------------------
// Constants

cases.add('constants', ['ARTICLES'], ARTICLES);
cases.add('constants', ['REFLEXIVES'], REFLEXIVES);
cases.add('constants', ['GLUED_ARTICLES'], GLUED_ARTICLES);
cases.add('constants', ['DEFAULT_TOLERANCE'], DEFAULT_TOLERANCE);
cases.add('constants', ['ABBREVIATIONS'], ABBREVIATIONS.map(([re, canonical]) => [re.source, re.flags, canonical]));

// ---------------------------------------------------------------------------
// 1. tests/grading.test.js: calls with literal arguments, and every string literal

const TEST_SRC = readText('tests/grading.test.js');
globalThis.ALL_OFF = tolOf(0);
globalThis.ALL_ON = tolOf(ALL_ON_MASK);
globalThis.DEFAULT_TOLERANCE = DEFAULT_TOLERANCE;

// Argument source texts of every `name(...)` call (strings and nested brackets skipped).
function extractCalls(src, names) {
  const out = [];
  const re = new RegExp(`(?<![\\w.])(${names.join('|')})\\(`, 'g');
  let m;
  while ((m = re.exec(src))) {
    const start = m.index + m[0].length;
    let depth = 1;
    let quote = null;
    let i = start;
    for (; i < src.length; i++) {
      const ch = src[i];
      if (quote) {
        if (ch === '\\') i++;
        else if (ch === quote) quote = null;
        continue;
      }
      if (ch === "'" || ch === '"' || ch === '`') quote = ch;
      else if (ch === '(' || ch === '[' || ch === '{') depth++;
      else if (ch === ')' || ch === ']' || ch === '}') {
        depth--;
        if (depth === 0) break;
      }
    }
    out.push({ name: m[1], args: src.slice(start, i) });
  }
  return out;
}

const isJsonPrimitive = (v) => v === null || v === undefined || typeof v === 'string' || typeof v === 'boolean' || (typeof v === 'number' && Number.isFinite(v));
const isPlainData = (v) =>
  isJsonPrimitive(v) ||
  (Array.isArray(v) && v.every(isPlainData)) ||
  (typeof v === 'object' && Object.getPrototypeOf(v) === Object.prototype && Object.values(v).every(isPlainData));

function evalArgs(text) {
  try {
    const args = (0, eval)(`[${text}]`);
    return args.every(isPlainData) ? args : null;
  } catch {
    return null;
  }
}

const TEST_PAIRS = []; // [given, expected, lang] of the test calls
for (const call of extractCalls(TEST_SRC, ['accepts', 'rejects', 'exactMatch', 'grade', 'splitAlternatives', 'diffChars', 'diffAnswer'])) {
  const args = evalArgs(call.args);
  if (!args) continue;
  if (call.name === 'splitAlternatives') {
    cases.add('splitAlternatives', [args[0] ?? null, args[1] ?? null], splitAlternatives(args[0], args[1]));
  } else if (call.name === 'diffChars') {
    cases.add('diffChars', [args[0] ?? null, args[1] ?? null], diffChars(args[0], args[1]));
  } else if (call.name === 'diffAnswer') {
    cases.add('diffAnswer', [args[0] ?? null, args[1] ?? null, args[2] ?? null], diffAnswer(args[0], args[1], args[2]));
  } else {
    // accepts/rejects/exactMatch(given, expected, lang, tol) and grade(given, expected, tol, lang)
    const [given, expected] = args;
    const lang = call.name === 'grade' ? args[3] : args[2];
    const tol = call.name === 'grade' ? args[2] : args[3];
    cases.add('grade', [given ?? null, expected ?? null, tol ?? null, lang ?? null], grade(given, expected, tol, lang));
    if (typeof given === 'string' && typeof expected === 'string' && (lang == null || typeof lang === 'string')) {
      TEST_PAIRS.push([given, expected, lang ?? null]);
    }
  }
}
for (const [given, expected, lang] of TEST_PAIRS) gradeMatrix(given, expected, lang, STANDARD);

// Odd tolerance and lang values (resolveTolerance / resolveLang).
for (const tol of [null, 5, 'x', [], { articles: 1 }, { typos: 'yes' }, {}, { answerWith: 'term', tolerance: { articles: false } },
  { tolerance: { typos: true, ignoreAccents: true } }, { tolerance: 'x', articles: false }, { tolerance: [] }]) {
  for (const [given, expected, lang] of [['Herr', 'der Herr', 'de'], ['bete', 'bête', 'fr'], ['verheiratat', 'verheiratet', 'de'],
    ['lieb', 'lieb, nett', 'de'], ['freuen', '(sich) freuen', 'de'], ['etwas machen', 'etw. machen', 'de']]) {
    cases.add('grade', [given, expected, tol, lang], grade(given, expected, tol, lang));
  }
}
for (const lang of [null, 42, true, '', 'DE', 'De', ' de ', 'de-CH', 'fr_CH', 'FR', 'en-GB', 'es', 'it', 'zz', 'other', 'xx', 'd', 'İt', ' fr']) {
  for (const [given, expected] of [['Herr', 'der Herr'], ['homme', "l'homme"], ['appear', 'to appear'], ['perro', 'el perro'],
    ['amico', "l'amico"], ['Mappe', 'Mappe, Tasche.'], ['der mann', 'der Mann']]) {
    cases.add('grade', [given, expected, null, lang], grade(given, expected, null, lang));
  }
  cases.add('splitAlternatives', ['Mappe, Tasche.', lang], splitAlternatives('Mappe, Tasche.', lang));
}
// Non-string answers (JS String(value)).
for (const [given, expected] of [[42, 42], ['42', 42], [42, '42'], [-1.5, '-1.5'], [true, 'true'], [null, 'Herr'], ['Herr', null], [null, null], [0, '0'], [1e21, '1e+21']]) {
  cases.add('grade', [given, expected, null, 'de'], grade(given, expected, null, 'de'));
  cases.add('splitAlternatives', [expected, null], splitAlternatives(expected));
  cases.add('diffChars', [given, expected], diffChars(given, expected));
  cases.add('diffAnswer', [given, expected, null], diffAnswer(given, expected));
}

// Every string literal of the test file.
const TEST_STRINGS = [];
{
  const seen = new Set();
  const re = /'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"/g;
  let m;
  while ((m = re.exec(TEST_SRC))) {
    let s;
    try {
      s = (0, eval)(m[0]);
    } catch {
      continue;
    }
    if (typeof s !== 'string' || s.length > 120 || seen.has(s)) continue;
    seen.add(s);
    TEST_STRINGS.push(s);
  }
}

// ---------------------------------------------------------------------------
// 2. Card sides of every fixture list

const SETS = fixtureTexts().map(({ name, text }) => {
  const r = parseVocab(text);
  return { name, termLang: r.termLang, defLang: r.defLang, cards: r.cards.map((c) => ({ term: c.term, definition: c.definition })) };
});

// ---------------------------------------------------------------------------
// Given-answer variants

const LANGS = ['fr', 'de', 'en', 'es', 'it', 'ar', 'zh'];
const LETTERS = Array.from('abcdefghijklmnopqrstuvwxyzäöüéèàçêßœ');
const GARBAGE = Array.from("abcxyz éäöüßœ'’-–/,;.()[]?!… 12 «»\"*~");
const ABBR_PAIRS = [
  ['etwas', 'etw.'], ['etwas', 'etw'], ['etwas', 'Etw.'], ['jemanden', 'jdn.'], ['jemanden', 'jmdn.'], ['jemandem', 'jdm.'],
  ['jemandes', 'jds.'], ['jemand', 'jd.'], ['something', 'sth'], ['something', 's.th.'], ['something', 'smth'],
  ['somebody', 'sb'], ['somebody', 's.o.'], ['somebody', 's. b.'], ['someone', 'sb'], ['oneself', 'o.s.'],
  ['quelque chose', 'qc'], ['quelque chose', 'qqch'], ['quelque chose', 'qch.'], ["quelqu'un", 'qn'], ["quelqu'un", 'qqn'],
  ['zum Beispiel', 'z.B.'], ['zum Beispiel', 'zB'], ['zum Beispiel', 'z. B.'], ['und so weiter', 'usw.'],
  ['beziehungsweise', 'bzw.'], ['oder', 'od.'], ['und', 'u.'],
];

const cps = (s) => Array.from(s);
const replaceFirst = (s, a, b) => {
  const i = s.indexOf(a);
  return i < 0 ? s : s.slice(0, i) + b + s.slice(i + a.length);
};
const ucFirst = (s) => (s ? s[0].toUpperCase() + s.slice(1) : s);
const toggleCase = (s) => cps(s).map((c) => (c === c.toLowerCase() ? c.toUpperCase() : c.toLowerCase())).join('');

function typo(s) {
  const a = cps(s);
  if (!a.length) return s;
  const i = randInt(rng, 0, a.length - 1);
  switch (randInt(rng, 0, 3)) {
    case 0: a[i] = pick(rng, LETTERS); break; // substitution
    case 1: a.splice(i, 1); break; // deletion
    case 2: a.splice(i, 0, pick(rng, LETTERS)); break; // insertion
    default: if (i + 1 < a.length) [a[i], a[i + 1]] = [a[i + 1], a[i]]; // transposition
  }
  return a.join('');
}

function swapLetters(s) {
  const a = cps(s);
  const idx = [];
  for (let i = 0; i + 1 < a.length; i++) if (/\p{L}/u.test(a[i]) && /\p{L}/u.test(a[i + 1]) && a[i] !== a[i + 1]) idx.push(i);
  if (!idx.length) return s;
  const i = pick(rng, idx);
  [a[i], a[i + 1]] = [a[i + 1], a[i]];
  return a.join('');
}

// The words of `s` after an article/pronoun of `lang` (or of any language).
function articleSplit(s, lang) {
  const tokens = [...(ARTICLES[lang] || []), ...(REFLEXIVES[lang] || []).map((r) => r.trim())]
    .concat(...LANGS.map((l) => ARTICLES[l]))
    .sort((x, y) => y.length - x.length);
  const low = s.toLowerCase();
  for (const t of tokens) {
    if (!low.startsWith(t)) continue;
    const rest = s.slice(t.length);
    if (t.endsWith("'") || GLUED_ARTICLES.includes(t) || rest[0] === ' ') return { article: s.slice(0, t.length), core: rest.trim() };
  }
  return null;
}

// Arabic and Chinese answers: the forms grading folds or accepts (none for other text).
const TONE_NUMBERS = { 'ā': 'a1', 'á': 'a2', 'ǎ': 'a3', 'à': 'a4', 'ē': 'e1', 'é': 'e2', 'ě': 'e3', 'è': 'e4', 'ī': 'i1', 'í': 'i2', 'ǐ': 'i3', 'ì': 'i4', 'ō': 'o1', 'ó': 'o2', 'ǒ': 'o3', 'ò': 'o4', 'ū': 'u1', 'ú': 'u2', 'ǔ': 'u3', 'ù': 'u4', 'ǖ': 'v1', 'ǘ': 'v2', 'ǚ': 'v3', 'ǜ': 'v4', 'ü': 'v' };
function scriptVariants(expected) {
  const out = [];
  if (hasArabic(expected)) {
    const bare = stripArabicMarks(expected);
    out.push(bare);
    out.push(bare.replace(/[أإآٱ]/g, 'ا'));
    out.push(bare.replace(/ة/g, 'ه').replace(/ى/g, 'ي'));
    out.push(bare.replace(/ؤ/g, 'و').replace(/ئ/g, 'ي'));
    out.push(bare.replace(/^ال/, ''));
    out.push(`ال${bare}`);
    out.push(bare.replace(/(\p{L})(\p{L})/u, '$1ـ$2'));
    out.push(expected.replace(/،/g, ',').replace(/؟/g, ''));
    out.push(`\u200F${expected}\u200F`);
    out.push(bare.replace(/ا/g, 'ﺍ').replace(/ب/g, 'ﺏ'));
  }
  if (hasHan(expected)) {
    const han = (expected.match(/[\u3400-\u9FFF\uF900-\uFAFF]+/gu) || []).join('');
    const latin = expected.replace(/[\u3400-\u9FFF\uF900-\uFAFF（）()]+/gu, ' ').replace(/\s+/g, ' ').trim();
    out.push(han);
    out.push(Array.from(han).join(' '));
    if (latin) {
      out.push(latin);
      out.push(latin.replace(/ /g, ''));
      out.push(stripDiacritics(latin));
      // Tone numbers after each syllable's vowel run: nǐ hǎo → ni3 hao3 (roughly; the grader decides).
      out.push(latin.replace(/\p{L}+/gu, (w) => {
        let tone = '';
        const plain = Array.from(w).map((c) => {
          const t = TONE_NUMBERS[c];
          if (!t) return c;
          if (t.length > 1) tone = t[1];
          return t[0];
        }).join('');
        return plain + tone;
      }));
      out.push(`${han}（${latin}）`);
      out.push(`${latin} ${han}`);
    }
    out.push(expected.replace(/,/g, '，').replace(/\(/g, '（').replace(/\)/g, '）'));
    out.push(`${expected}。`);
    out.push(`「${expected}」`);
  }
  return out;
}

function variants(expected, lang, others, rich) {
  const out = new Set([expected]);
  const add = (v) => {
    if (typeof v === 'string' && v.length <= 400) out.add(v);
  };
  const alts = splitAlternatives(expected, lang);
  const words = expected.split(' ');

  // alternatives: single, reordered, other separators
  alts.forEach(add);
  if (alts.length > 1) {
    add([...alts].reverse().join(', '));
    add(alts.join('; '));
    add(alts.join(' / '));
    add(alts.join('/'));
    add(alts.join(','));
    add(`${alts[0]}, ${alts[0]}`);
    add(`${alts[alts.length - 1]}, ${alts[0]}`);
  }
  // articles and pronouns
  for (const alt of [expected, ...alts.slice(0, 3)]) {
    const sp = articleSplit(alt, lang);
    if (!sp) continue;
    add(sp.core);
    add(sp.core.toLowerCase());
    const pool = (ARTICLES[lang] || []).length ? ARTICLES[lang] : ARTICLES.de;
    const others = pool.filter((a) => a.toLowerCase() !== sp.article.toLowerCase());
    const other = others.length ? pick(rng, others) : pick(rng, ARTICLES.de);
    add(other.endsWith("'") || GLUED_ARTICLES.includes(other) ? other + sp.core : `${other} ${sp.core}`);
    add(sp.article.endsWith("'") ? `${sp.article.slice(0, -1)}e ${sp.core}` : `${sp.article}${sp.core}`);
    add(`${sp.article.toUpperCase()} ${sp.core}`);
  }
  if (words.length > 1) add(words.slice(1).join(' '));
  if (words.length > 2) add(words.slice(0, -1).join(' '));
  add(expected.replace(/^(?:se |s'|sich |to |oneself )/i, ''));
  // case
  add(expected.toLowerCase());
  add(expected.toUpperCase());
  add(ucFirst(expected));
  add(toggleCase(expected));
  // accents, umlauts, ß/ss, ligatures, NFD
  add(stripDiacritics(expected));
  add(foldUmlauts(expected));
  add(expected.replace(/ss/g, 'ß'));
  add(expected.replace(/ß/g, 'ss'));
  add(expected.replace(/oe/g, 'œ').replace(/ae/g, 'æ'));
  add(expected.replace(/œ/g, 'oe').replace(/Œ/g, 'Oe'));
  add(expected.normalize('NFD'));
  add(stripDiacritics(expected).toLowerCase());
  // typos
  add(typo(expected));
  add(typo(typo(expected)));
  add(swapLetters(expected));
  if (rich) {
    add(typo(expected));
    add(typo(stripDiacritics(expected)));
    for (const alt of alts.slice(0, 2)) add(typo(alt));
  }
  // abbreviations
  for (const [long, short] of ABBR_PAIRS) {
    if (expected.includes(long)) add(replaceFirst(expected, long, short));
    if (expected.includes(short)) add(replaceFirst(expected, short, long));
  }
  // brackets
  if (/[()[\]]/.test(expected)) {
    add(expected.replace(/[()[\]]/g, ''));
    add(expected.replace(/\([^()]*\)|\[[^[\]]*\]/g, '').replace(/\s+/g, ' ').trim());
    const inner = expected.match(/\(([^()]*)\)/);
    if (inner) add(inner[1]);
  }
  // punctuation and spacing
  add(`${expected}.`);
  add(`${expected}!`);
  add(`${expected} ?`);
  add(`${expected}…`);
  add(expected.replace(/[.!?…]+$/, ''));
  add(`  ${expected.replace(/ /g, '  ')}  `);
  add(expected.replace(/ /g, '\t'));
  add(expected.replace(/ /g, ' '));
  add(expected.replace(/'/g, "' "));
  add(expected.replace(/'/g, '’'));
  add(expected.replace(/-/g, ' '));
  add(expected.replace(/ /g, '-'));
  add(expected.replace(/,/g, ''));
  add(`«${expected}»`);
  // empty, garbage, other cards
  if (rich) {
    add('');
    add('   ');
    add(fuzzString(rng, GARBAGE, 1, 12));
  }
  for (const o of others) add(o);
  scriptVariants(expected).forEach(add);
  return [...out];
}

// Also derive a couple of combined variants (two transformations).
function combined(list) {
  const out = [];
  for (let k = 0; k < 3 && list.length > 2; k++) {
    const v = pick(rng, list);
    out.push(chance(rng, 0.5) ? stripDiacritics(v).toLowerCase() : typo(v.toLowerCase()));
  }
  return out;
}

function langsFor(lang) {
  const list = [lang];
  if (chance(rng, 0.2)) list.push(null);
  if (chance(rng, 0.1)) list.push(pick(rng, LANGS.filter((l) => l !== lang)));
  return list;
}

const diffPairs = [];
const graded = new Set();
function gradeAll(expected, lang, others, rich, masks = someMasks) {
  const key = JSON.stringify([expected, lang]);
  if (graded.has(key)) return;
  graded.add(key);
  let vs = variants(expected, lang, others, rich);
  for (const v of combined(vs)) if (!vs.includes(v)) vs.push(v);
  if (!rich && vs.length > 14) {
    // A seeded sample (always with the exact answer).
    const rest = vs.slice(1);
    for (let i = rest.length - 1; i > 0; i--) {
      const j = Math.floor(rng() * (i + 1));
      [rest[i], rest[j]] = [rest[j], rest[i]];
    }
    vs = [vs[0], ...rest.slice(0, 13)];
  }
  for (const L of langsFor(lang)) {
    cases.add('splitAlternatives', [expected, L], splitAlternatives(expected, L));
    for (const given of vs) {
      gradeMatrix(given, expected, L, rich ? masks() : [DEFAULT_MASK, pick(rng, STANDARD)]);
      if (chance(rng, 0.07)) diffPairs.push([given, expected, L]);
    }
  }
}

// Fixture cards, both sides, with answers of other cards of the same set as distractors.
for (const set of SETS) {
  const n = set.cards.length;
  set.cards.forEach((card, i) => {
    for (const side of ['term', 'definition']) {
      const lang = side === 'term' ? set.termLang : set.defLang;
      const others = [set.cards[(i + 1) % n][side], set.cards[(i + 7) % n][side], pick(rng, set.cards)[side]];
      gradeAll(card[side], lang, others, true);
    }
  });
}

// Curated stored answers with the features the fixture lists rarely have: reflexives, brackets,
// slashes, abbreviations, annotations, sentences, ligatures, elision, all five article languages.
const CURATED = {
  fr: [
    'se laver', "s'habiller", 'se souvenir de qc', '(se) promener', "s'asseoir", 'se lever tôt', 'se coucher',
    'se rendre compte de qc', "s'occuper de qn", 'se moquer de qn/qc', 'avoir besoin de qc', 'faire attention à qn/qc',
    'marié(e)', 'le/la journaliste', "l'étudiant(e)", 'un(e) ami(e)', 'beau/bel/belle', 'le cœur', "l'œil (les yeux)",
    'la sœur', 'le bœuf', "l'œuvre (f)", 'ex æquo', 'le château, -x', "l'hôpital, m", 'jouer au foot/au tennis',
    'aller à la plage/au cinéma', 'faire du vélo/du ski', 'Ça va bien, merci.', 'Comment ça va?', 'Excusez-moi, Madame.',
    "Je m'appelle Paul.", "s'il te plaît", "s'il vous plaît", "quelqu'un", 'quelque chose', 'penser à qn/qc',
    'demander qc à qn', 'parler (de)', 'le pain (du pain)', "de l'eau", 'des pommes', "aujourd'hui", "c'est-à-dire",
    'grand-mère', 'il/elle', 'ils/elles', 'mon/ma/mes', 'laver qc/se laver', 'les gens, pl.', 'la maison, f',
    "l'homme/la femme", 'la (petite) fille', '(le) monsieur', 'homme (l\')', 'Œuvres complètes', 'le garçon',
  ],
  de: [
    'sich freuen (auf/über)', '(sich) waschen', 'sich erinnern an etw.', 'sich ändern', 'etw. tun/machen', 'jdm. helfen',
    'jdn. fragen', 'an jdn./etw. denken', 'die Strasse', 'die Straße', 'der Fuss, ¨-e', 'das Mädchen, -', 'die Mutter, ¨',
    'der Tisch, -e', 'die Eltern (Pl.)', 'das Auto, -s', 'der/die Angestellte', 'der Lehrer/die Lehrerin', 'Lehrer/in',
    'z.B.', 'usw.', 'bzw.', 'Guten Tag, Frau Müller.', "Wie geht's?", 'Danke, gleichfalls!', 'Mappe, Tasche.',
    'Herr, der', 'Frau (Dame)', 'hübsch, schön', 'gross, groß', 'das Fräulein', 'die Schönheit', 'weh tun', 'Rad fahren',
    'Auf Wiedersehen!', 'der Ärger', 'die Übung', 'das Öl', 'äussern', 'heissen', 'der Fussball', 'die Grösse',
    'teilnehmen (an)', 'Angst haben (vor)', 'sich etw. leisten', 'jds. Freund', 'jd.', 'ein/e', 'jede/r', 'er/sie/es',
    'Herr (der)', '(der) Herr', 'mit der/dem Lehrer', 'etw./sich ändern', 'Herr u. Frau', 'ja od. nein', 'die Güte',
  ],
  en: [
    'to look for sth', 'to look after sb/oneself', 'to wash oneself', 'to think of sb/sth', 'the house', 'an apple',
    'a car', 'to be afraid of sb/sth', 'to get up', 'to give up', 'e-mail', 'to help s.o.', 'to play the piano/the guitar',
    'to go to bed/to sleep', 'colour (BE)/color (AE)', 'mother-in-law', 'Can you help me, please?', 'Thank you!',
    "I'm fine.", "don't", 'appear (to)', 'to do sth', 'to tell s.th.', 'he/she', 'S, M, L',
  ],
  es: [
    'el perro', 'la casa', 'los niños', 'las flores', 'un libro', 'una mesa', 'unos amigos', 'llamarse', '¿Qué tal?',
    '¡Hola!', 'el niño/la niña', 'el año', 'mañana', 'el corazón', 'pequeño, pequeña', 'unas casas',
  ],
  it: [
    'il cane', 'lo studente', "l'amico", "un'amica", 'gli amici', 'le ragazze', 'i ragazzi', 'la casa', 'uno zaino',
    'una mela', 'chiamarsi', 'perché', 'la città', 'il caffè', 'buongiorno, buonasera', "l'acqua (f)",
  ],
  ar: [
    'كِتَابٌ', 'الكتاب', 'المَدْرَسَةُ', 'مدرسة', 'مستشفى', 'أب', 'إسلام', 'القرآن', 'ٱسم', 'مسؤول', 'رئيس',
    'كتاب، دفتر', 'كتاب؛ قلم', 'هل؟', 'كيف حالك، يا أحمد؟', 'مرحبا، أنا طالب.', 'كتـــاب', 'ﻛﺘﺎﺏ', '\u200Fكتاب\u200F',
    'كتاب، ال', '(ال)كتاب', 'الرَّحْمَٰنِ', 'هٰذَا', 'كتاب/دفتر', 'مدرسة كبيرة', 'الشَّمْسُ', 'لا', 'ﻻ',
  ],
  zh: [
    '你好 (nǐ hǎo)', '你好（nǐ hǎo）', '你好 nǐ hǎo', 'nǐ hǎo 你好', '谢谢 (xiè xie)', '再见（zài jiàn）', '你好',
    '中国 (zhōng guó)', '你好 (nǐ hǎo, ní hǎo)', '谢谢，多谢', '谢谢、多谢', '谢谢；多谢', '谢谢/多谢', '你/您',
    '你好，我是学生。', '你好，你叫什么名字？', '《红楼梦》', '「你好」', '女 (nǚ)', '绿 (lǜ)', '妈 (ma1)', '你好 (ni3 hao3)',
    '我是学生', '你 好', 'mā', 'lǜ', '你好 (问候)', 'nǐ hǎo (你好)', '3个', 'MP3',
  ],
};
for (const [lang, list] of Object.entries(CURATED)) {
  list.forEach((s, i) => gradeAll(s, lang, [list[(i + 3) % list.length], pick(rng, list)], true, () => [DEFAULT_MASK, pick(rng, STANDARD.slice(1))]));
}

// String literals of the test file as stored answers (lighter: fewer tolerances).
for (const s of TEST_STRINGS) {
  const picked = pick(rng, ['de', 'fr', 'en', 'de', 'fr', null]);
  const lang = hasArabic(s) ? 'ar' : hasHan(s) ? 'zh' : picked;
  gradeAll(s, lang, [pick(rng, TEST_STRINGS)], false);
  cases.add('splitAlternatives', [s, null], splitAlternatives(s));
  cases.add('splitAlternatives', [s, 'de'], splitAlternatives(s, 'de'));
}

// ---------------------------------------------------------------------------
// 3. Limits and edge shapes

{
  const many = (n) => Array.from({ length: n }, (_, i) => `wort${i}`).join(', ');
  for (const n of [23, 24, 25, 30]) {
    const stored = many(n);
    for (const given of ['wort5', stored, many(n - 1), 'wort5, wort1', `${stored}, wort5`, 'wort99']) {
      gradeMatrix(given, stored, 'de', STANDARD);
    }
    cases.add('splitAlternatives', [stored, 'de'], splitAlternatives(stored, 'de'));
  }
  for (const len of [9, 10, 198, 199, 200, 201, 260]) {
    const word = Array.from({ length: len }, (_, i) => LETTERS[(i * 7) % 26]).join('');
    for (const given of [word, typo(word), typo(typo(word)), word.slice(1), `${word}x`, word.toUpperCase(), `le ${word}`]) {
      gradeMatrix(given, word, 'fr', STANDARD);
      gradeMatrix(given, `le ${word}`, 'fr', [DEFAULT_MASK, ALL_ON_MASK]);
    }
  }
  const parens = '(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)';
  for (const given of ['abcdefghij', 'a', 'acegi', '', 'abc', '(a)(b)']) gradeMatrix(given, parens, 'de', STANDARD);
  const slashes = 'aaa/bbb/ccc/ddd/eee/fff/ggg/hhh/iii/jjj/kkk/lll/mmm/nnn/ooo/ppp/qqq/rrr';
  for (const given of ['aaa', 'rrr', 'qqq, ppp', slashes]) gradeMatrix(given, slashes, 'de', STANDARD);
  cases.add('splitAlternatives', [slashes, null], splitAlternatives(slashes));
  for (const s of ['((((((((a))))))))', ')))(((', '(a', 'a)', '[a]', '{a}', '(a]', '[(a)]', '(le) (la) (les) chat', 'x (der)', 'Herr (der) (die)']) {
    for (const given of ['a', 'chat', 'der x', 'x', 'die Herr', 'der Herr']) gradeMatrix(given, s, 'de', [DEFAULT_MASK, 0, ALL_ON_MASK]);
    cases.add('splitAlternatives', [s, null], splitAlternatives(s));
  }
}

// ---------------------------------------------------------------------------
// 4. Seeded fuzz over the characters the grader treats specially

const FUZZ = [
  'a', 'e', 'i', 'o', 'u', 'r', 's', 't', 'n', 'l', 'd', 'h', 'c', 'g', 'b', 'q', 'z', 'w', 'j', 'm',
  'A', 'E', 'S', 'D', 'L', 'Z', 'Q', 'U', 'O', 'I',
  ' ', ' ', ' ', ' ', '  ', '\t', ' ', ',', ', ', ';', '/', ' / ', '.', '..', '...', '!', '?', '…', '-', '–',
  "'", '’', "' ", '(', ')', '[', ']', '{', '}', '"', '«', '»', '„', '“', '¿', '¡', '~', '*', '¨', '1', '5', ',5',
  'é', 'è', 'ê', 'à', 'ç', 'ä', 'ö', 'ü', 'Ä', 'Ü', 'ß', 'ẞ', 'œ', 'Œ', 'æ', 'Æ', 'ſ', 'İ', 'ı', 'Σ', 'σ', 'ς',
  'é', '́', 'ͅ', 'ǅ', '😀', '漢', 'K', 'Å',
  'le ', 'la ', "l'", 'les ', 'de la ', "de l'", 'du ', 'au ', 'un ', 'une ', 'der ', 'die ', 'das ', 'den ', 'ein ',
  'the ', 'to ', 'an ', 'el ', 'los ', 'il ', 'lo ', 'gli ', "un'", 'se ', "s'", 'sich ', 'oneself',
  'etw.', 'etw', 'jdn.', 'jdm.', 'jd.', 'sth', 'sb', 's.o.', 's. th.', 'o.s.', 'qc', 'qn', 'qqch', 'qqn', 'z.B.', 'zB',
  'usw.', 'bzw.', 'od.', 'u.', 'u.a.', 'Etw.', 'SB',
  'il/elle', 'er/sie', 'Lehrer/in', 'm', 'f', 'pl.', 'Pl.', 'm./f.', ', -e', ', ¨', ', f',
  'chat', 'Herr', 'maison', 'Haus', 'freuen', 'gross', 'groß', 'Straße', 'cœur',
  // Arabic and Chinese
  'كتاب', 'ال', 'الكتاب', 'مدرسة', 'مدرسه', 'أ', 'ا', 'إ', 'آ', 'ٱ', 'ؤ', 'ئ', 'ى', 'ي', 'ة', 'ه', 'ـ', 'َ', 'ِ', 'ٌ', 'ّ',
  'ٰ', 'ٔ', '،', '؛', '؟', 'ﻛ', 'ﻻ', '\u200F', '\u061C',
  '你', '好', '你好', '谢谢', ' (nǐ hǎo)', '（', '）', '，', '、', '；', '。', '！', '？', '「', '」', '《', '》', '【', '】',
  'nǐ', 'hǎo', 'ni3', 'hao3', 'lv4', 'nu:3', 'ma5', 'xie4', 'ü', '𠀀',
];

for (let k = 0; k < 2200; k++) {
  const expected = fuzzString(rng, FUZZ, 1, randInt(rng, 2, 9));
  const lang = pick(rng, ['fr', 'de', 'en', 'es', 'it', null, 'de', 'fr', 'ar', 'zh']);
  const givens = [
    expected,
    chance(rng, 0.5) ? typo(expected) : fuzzString(rng, FUZZ, 1, 6),
    pick(rng, [expected.toLowerCase(), stripDiacritics(expected), expected.replace(/[()[\]]/g, ''), splitAlternatives(expected, lang)[0] || '', expected.split(' ').slice(1).join(' ')]),
  ];
  for (const given of new Set(givens)) gradeMatrix(given, expected, lang, [DEFAULT_MASK, pick(rng, STANDARD)]);
  cases.add('splitAlternatives', [expected, lang], splitAlternatives(expected, lang));
  if (chance(rng, 0.3)) diffPairs.push([givens[1], expected, lang]);
}

// ---------------------------------------------------------------------------
// 5. diffChars / diffAnswer

for (const [given, expected, lang] of diffPairs) {
  cases.add('diffChars', [given, expected], diffChars(given, expected));
  cases.add('diffAnswer', [given, expected, null], diffAnswer(given, expected));
  if (lang === 'zh' || hasHan(expected)) cases.add('diffAnswer', [given, expected, 'zh'], diffAnswer(given, expected, 'zh'));
}
const userCards = SETS.find((s) => s.name === 'user-example.txt').cards;
const words = userCards.flatMap((c) => [c.term, c.definition]);
for (let i = 0; i < words.length; i++) {
  const a = words[i];
  const b = words[(i + 5) % words.length];
  cases.add('diffChars', [a, b], diffChars(a, b));
  cases.add('diffAnswer', [a, b, null], diffAnswer(a, b));
}
for (const [a, b] of [
  ['x' + 'a'.repeat(3000), 'y' + 'b'.repeat(3000)],
  ['x' + 'a'.repeat(998), 'y' + 'b'.repeat(998)],
  ['x' + 'a'.repeat(999), 'y' + 'b'.repeat(999)],
  ['ab'.repeat(40), 'ba'.repeat(40)],
  ['  a  ', 'a'],
  [' a ', 'a'],
  ['Straß', 'Straße'],
  ['Strasse', 'Straße'],
  ['Œuvre', 'oeuvre'],
  ['ẞ', 'ß'],
  ['ß́', 'sś'],
  ["l '  homme", 'l’homme'],
  ['كتاب', 'كِتَابٌ'],
  ['كتب', 'كِتَابٌ'],
  ['كِتاب', 'كِتَابٌ'],
  ['كتاب', 'كتـاب'],
  ['q', 'q́'],
  ['́', 'á'],
  ['ni hao', '你好 (nǐ hǎo)'],
  ['ni3 hao', '你好（nǐ hǎo）'],
  ['你们', '你好 (nǐ hǎo)'],
  ['nǐ hǎo', 'nǐ hǎo 你好'],
  ['xie4xie', '谢谢 (xiè xie)'],
  ['𠀀a', '𠀁a'],
]) {
  cases.add('diffChars', [a, b], diffChars(a, b));
  cases.add('diffAnswer', [a, b, null], diffAnswer(a, b));
  cases.add('diffAnswer', [a, b, 'zh'], diffAnswer(a, b, 'zh'));
  cases.add('diffAnswer', [a, b, 'ar'], diffAnswer(a, b, 'ar'));
}

cases.emit();
