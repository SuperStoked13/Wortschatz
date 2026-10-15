// Shared text normalisation primitives used by the parser and the grader.
// Pure and DOM-free (runs under jsc).

const APOSTROPHES = /[’‘`´ʼ′ʹ]/g;
const DASHES = /[–—‒‐‑−]/g;
const SPACES = /[\u00A0\u2007\u2009\u200A\u202F\u205F\u3000]/g;
const ZERO_WIDTH = /[\u200B\u200C\u200D\u2060\uFEFF]/g;
// Bidi controls (LRM, RLM, ALM, embeddings, overrides, isolates) copied along with Arabic text.
const BIDI_CONTROLS = /[\u200E\u200F\u061C\u202A-\u202E\u2066-\u2069]/g;

// NFC, unify apostrophes/dashes/odd spaces, collapse whitespace (tabs are kept
// only when keepTabs is true — the parser needs them as column separators).
export function normalizeBasic(s, { keepTabs = false } = {}) {
  if (s == null) return '';
  let out = String(s)
    .normalize('NFC')
    .replace(ZERO_WIDTH, '')
    .replace(BIDI_CONTROLS, '')
    .replace(APOSTROPHES, "'")
    .replace(DASHES, '-')
    .replace(SPACES, ' ');
  if (keepTabs) {
    out = out.replace(/[ \f\v\r\n]+/g, ' ').replace(/ *\t */g, '\t');
  } else {
    out = out.replace(/\s+/g, ' ');
  }
  return out.trim();
}

// Remove diacritics: é→e, ç→c, ä→a. Ligatures and ß are expanded.
export function stripDiacritics(s) {
  return String(s)
    .replace(/ß/g, 'ss')
    .replace(/ẞ/g, 'SS')
    .replace(/œ/g, 'oe')
    .replace(/Œ/g, 'OE')
    .replace(/æ/g, 'ae')
    .replace(/Æ/g, 'AE')
    .replace(/ø/g, 'o')
    .replace(/Ø/g, 'O')
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .normalize('NFC');
}

// German-style transliteration: ä→ae, ö→oe, ü→ue, then strip remaining diacritics.
export function foldUmlauts(s) {
  return stripDiacritics(
    String(s)
      .replace(/ä/g, 'ae')
      .replace(/ö/g, 'oe')
      .replace(/ü/g, 'ue')
      .replace(/Ä/g, 'Ae')
      .replace(/Ö/g, 'Oe')
      .replace(/Ü/g, 'Ue'),
  );
}

export function isLetter(ch) {
  return /\p{L}/u.test(ch);
}

// ---------------------------------------------------------------------------
// Arabic and Chinese script folds: for comparing only, never applied to stored text.

// Script ranges as explicit code points (Swift has no Script property): bodies of a
// character class for a RegExp with the 'u' flag.
export const ARABIC_RANGE = '\\u0600-\\u06FF\\u0750-\\u077F\\u08A0-\\u08FF\\uFB50-\\uFDFF\\uFE70-\\uFEFE';
export const HAN_RANGE = '\\u3400-\\u4DBF\\u4E00-\\u9FFF\\uF900-\\uFAFF\\u{20000}-\\u{2FA1F}';

const ARABIC_RE = new RegExp(`[${ARABIC_RANGE}]`, 'u');
const HAN_RE = new RegExp(`[${HAN_RANGE}]`, 'u');
const HAN_SPACES = new RegExp(`([${HAN_RANGE}]) +(?=[${HAN_RANGE}])`, 'gu');
// Every character foldScripts changes lies at or above U+0600.
const FOLDABLE = /[^\u0000-\u05FF]/;
const PRESENTATION_FORMS = /[\uFB50-\uFDFF\uFE70-\uFEFE]/g;
// Vowel marks (harakat, shadda, sukun, tanwin, superscript alef), Quranic marks and tatweel.
// Madda and hamza (U+0653–U+0655) stay: they make letter variants (core/grading.js).
const ARABIC_MARKS = /[\u0610-\u061A\u064B-\u0652\u0656-\u065F\u0670\u06D6-\u06DC\u06DF-\u06E8\u06EA-\u06ED\u0640]/g;
const SCRIPT_PUNCT = { '،': ',', '؛': ';', '؟': '?', '、': ',', '。': '.', '【': '[', '】': ']' };
const SCRIPT_PUNCT_RE = /[،؛؟、。【】\uFF01-\uFF5E]/g;

// Whether the text contains a character of the Arabic script.
export function hasArabic(s) {
  return ARABIC_RE.test(String(s ?? ''));
}

// Whether the text contains a Han character (Chinese).
export function hasHan(s) {
  return HAN_RE.test(String(s ?? ''));
}

// Arabic vowel marks, Quranic marks and tatweel removed: كِتَابٌ → كتاب.
export function stripArabicMarks(s) {
  return String(s ?? '').replace(ARABIC_MARKS, '').normalize('NFC');
}

// What Arabic and Chinese text treats as the same, folded away (NFC result): presentation
// forms → plain letters (NFKC of those characters only), vowel marks, Quranic marks and
// tatweel removed, ، ؛ ؟ and full-width/CJK punctuation → ASCII (，→, （→( 、→, 。→. 【→[),
// no spaces between two Han characters. Latin text only gets NFC.
export function foldScripts(s) {
  const out = String(s ?? '').normalize('NFC');
  if (!FOLDABLE.test(out)) return out;
  return out
    .replace(PRESENTATION_FORMS, (ch) => ch.normalize('NFKC'))
    .replace(ARABIC_MARKS, '')
    .normalize('NFC')
    .replace(SCRIPT_PUNCT_RE, (ch) => SCRIPT_PUNCT[ch] || String.fromCharCode(ch.charCodeAt(0) - 0xfee0))
    .replace(HAN_SPACES, '$1');
}
