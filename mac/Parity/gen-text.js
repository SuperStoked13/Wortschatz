// Parity fixture for src/core/text.js → Fixtures/text.json.
// fns: normalizeBasic [s, keepTabs], stripDiacritics [s], foldUmlauts [s], isLetter [ch],
//      foldScripts [s], stripArabicMarks [s], hasArabic [s], hasHan [s]
import {
  normalizeBasic,
  stripDiacritics,
  foldUmlauts,
  isLetter,
  foldScripts,
  stripArabicMarks,
  hasArabic,
  hasHan,
} from '../../Website/src/core/text.js';
import { Cases, mulberry32, fuzzString, randInt, fixtureTexts } from './lib.js';

const cases = new Cases('text');

function all(s) {
  cases.add('normalizeBasic', [s, false], normalizeBasic(s));
  cases.add('normalizeBasic', [s, true], normalizeBasic(s, { keepTabs: true }));
  cases.add('stripDiacritics', [s], stripDiacritics(s));
  cases.add('foldUmlauts', [s], foldUmlauts(s));
}

// 1. Inputs of tests/text.test.js
for (const s of ['  l’homme  ', 'c’est–à–dire', 'la rue \n  ', ' le nom \t  der Name ', 'a\tb', 'é', 'é']) all(s);
cases.add('normalizeBasic', [null, false], normalizeBasic(null));
for (const s of ['séparée', 'garçon', 'Mädchen', 'Straße', 'cœur', 'hübsch', 'Ärger']) all(s);
for (const ch of ['é', "'", 'a', '1', ' ', 'ß', 'Ж', '漢', '😀', 'a1', '1a', '', '́', 'ǅ', 'ʰ']) cases.add('isLetter', [ch], isLetter(ch));

// 2. Every line (and the whole text) of the web test fixtures, incl. the user's 52-pair list
for (const { text } of fixtureTexts()) {
  all(text);
  for (const line of text.split(/\r\n|\r|\n/)) all(line);
}

// 3. Seeded fuzz over the characters the normaliser treats specially
const ALPHABET = [
  // plain
  'a', 'b', 'e', 'o', 'u', 's', 'A', 'E', 'Z', '1', '0', '.', ',', ';', ':', '-', '(', ')', '"', '/', '?', '!',
  // whitespace: space, tab, line terminators, \f \v, JS-only whitespace, NEL (not \s in JS)
  ' ', ' ', ' ', '\t', '\t', '\n', '\r', '\r\n', '\f', '\v', ' ', ' ', '\u0085', ' ', ' ',
  ' ', ' ', ' ',
  // odd spaces (→ ' ')
  ' ', ' ', ' ', ' ', ' ', ' ', '　',
  // zero width (removed)
  '​', '‌', '‍', '⁠', '﻿',
  // apostrophes and dashes
  '’', '‘', '`', '´', 'ʼ', '′', 'ʹ', "'", '–', '—', '‒', '‐', '‑', '−',
  // letters with diacritics, ligatures, sharp s
  'é', 'è', 'ê', 'ë', 'à', 'â', 'ä', 'ö', 'ü', 'Ä', 'Ö', 'Ü', 'É', 'ç', 'Ç', 'ñ', 'ô', 'û', 'î', 'ï', 'œ', 'Œ',
  'æ', 'Æ', 'ø', 'Ø', 'ß', 'ẞ', 'å', 'ı', 'İ', 'ł', 'đ', 'ǅ',
  // decomposed sequences and combining marks (Mn, Mc, Me)
  'é', 'ä', 'ü', 'ô', 'ç', 'ñ', '́', '̀', '̈', '̧',
  '⃝', 'ः', '️',
  // canonical singletons (NFC changes them)
  'Å', 'Ω', 'K',
  // other scripts and symbols
  'α', 'Ω', 'Ж', 'я', '漢', '字', '한', 'ا', '١', '¨', 'ﬁ', '😀', '👍🏽', '❤️', '€', '§', '°', '«', '»', '…',
];

const rng = mulberry32(20261012);
for (let i = 0; i < 1500; i++) {
  const s = fuzzString(rng, ALPHABET, 0, randInt(rng, 1, 24));
  all(s);
}
// Single characters of the alphabet
for (const ch of ALPHABET) {
  all(ch);
  cases.add('isLetter', [ch], isLetter(ch));
}
// isLetter over a sample of code points (letters, marks, digits, symbols of many scripts)
const RANGES = [
  [0x20, 0x24f], [0x370, 0x52f], [0x590, 0x6ff], [0x900, 0x97f], [0xe00, 0xe7f], [0x1e00, 0x1fff], [0x2000, 0x2bff],
  [0x3000, 0x30ff], [0x4e00, 0x4e80], [0xac00, 0xac40], [0xfb00, 0xfb4f], [0xff00, 0xffef],
];
for (const [lo, hi] of RANGES) {
  for (let cp = lo; cp <= hi; cp += 3) cases.add('isLetter', [String.fromCodePoint(cp)], isLetter(String.fromCodePoint(cp)));
}
for (let i = 0; i < 300; i++) {
  const s = fuzzString(rng, ALPHABET, 0, 6);
  cases.add('isLetter', [s], isLetter(s));
}

// 4. Arabic and Chinese script folds (own seed, so the sections above stay as they were)
function scripts(s) {
  cases.add('foldScripts', [s], foldScripts(s));
  cases.add('stripArabicMarks', [s], stripArabicMarks(s));
  cases.add('hasArabic', [s], hasArabic(s));
  cases.add('hasHan', [s], hasHan(s));
}
for (const s of [
  'كِتَابٌ', 'مُدَرِّسَةٌ', 'قُلْ', 'هٰذا', 'عَلَيْهِؐ', 'الرَّحْمَٰنِۖ', 'كتـــاب', 'أب', 'القرآن', 'إسلام', 'اۖٔ', 'آ',
  'ﻛﺘﺎﺏ', 'ﻻ', 'ﻵ', 'ﬁn ² ½ ﻛ', 'ﷲ', 'ﷺ', 'ﱞ', 'كتاب، دفتر؛ قلم؟', '你好（nǐ hǎo），再见！', '谢谢、多谢；再见：好吗？',
  '我是学生。', '【注意】［x］', 'ＡＢＣ１２３～', '「你好」《书》', '你 好', '我 是  学 生', '你好 nǐ hǎo', 'nǐ hǎo 你好',
  '𠀀 𠀁 㐀 丽', '東京 Tokyo', "l'homme", 'Straße', 'cœur', 'garçon, fille', 'a … b', '¿Qué?', '« oui »', 'ﬁ', 'é',
  '', ' ', 'ݐ', '\uFEFF', 'かな', '。、', '‏كتاب‏', '你\u3000好', '你\t好', '你 \u00A0好',
]) {
  scripts(s);
  all(s);
}
const SCRIPT_ALPHABET = [
  'a', 'b', 'n', 'i', 'o', 'ǎ', 'ü', ' ', ' ', '  ', '\t', ',', '.', '(', ')', '?', '!', ';', ':', '-', '1', 'é', 'é',
  // Arabic letters, variants, marks (vowel, Quranic, madda/hamza), tatweel, punctuation, digits
  'ك', 'ت', 'ا', 'ب', 'ل', 'م', 'ة', 'ه', 'ى', 'ي', 'أ', 'إ', 'آ', 'ٱ', 'ؤ', 'ئ', 'ء', 'َ', 'ُ', 'ِ', 'ً', 'ٌ', 'ٍ', 'ّ', 'ْ',
  'ٰ', 'ٓ', 'ٔ', 'ٕ', 'ٖ', 'ؐ', 'ۖ', 'ۜ', '۟', 'ۭ', 'ـ', '،', '؛', '؟', '٣', '۴', 'ݐ', 'ࢠ',
  // presentation forms (letters, ligatures, marks)
  'ﻛ', 'ﺘ', 'ﺎ', 'ﺏ', 'ﻻ', 'ﻵ', 'ﷲ', 'ﱞ', 'ﹰ', 'ﹼ', 'ﭐ', 'ﷺ',
  // Han, CJK punctuation, full-width forms
  '你', '好', '学', '生', '㐀', '丽', '𠀀', '，', '、', '。', '；', '：', '！', '？', '（', '）', '［', '］', '【', '】',
  '「', '」', '《', '》', 'Ａ', 'ａ', '１', '～', '｟', '　',
  // bidi controls
  '\u200E', '\u200F', '\u061C', '\u202A', '\u202B', '\u202C', '\u202D', '\u202E', '\u2066', '\u2067', '\u2068', '\u2069',
];
const srng = mulberry32(20261015);
for (let i = 0; i < 2500; i++) {
  const s = fuzzString(srng, SCRIPT_ALPHABET, 0, randInt(srng, 1, 16));
  scripts(s);
  if (i % 3 === 0) all(s);
}
for (const ch of SCRIPT_ALPHABET) scripts(ch);
// Every line of the Arabic and Chinese fixtures
for (const { name, text } of fixtureTexts()) {
  if (!/arabic|chinese/.test(name)) continue;
  scripts(text);
  for (const line of text.split(/\r\n|\r|\n/)) scripts(line);
}

cases.emit();
