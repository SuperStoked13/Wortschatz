// Shared text normalisation primitives used by the parser and the grader.
// Pure and DOM-free (runs under jsc).

const APOSTROPHES = /[’‘`´ʼ′ʹ]/g;
const DASHES = /[–—‒‐‑−]/g;
const SPACES = /[\u00A0\u2007\u2009\u200A\u202F\u205F\u3000]/g;
const ZERO_WIDTH = /[\u200B\u200C\u200D\u2060\uFEFF]/g;

// NFC, unify apostrophes/dashes/odd spaces, collapse whitespace (tabs are kept
// only when keepTabs is true — the parser needs them as column separators).
export function normalizeBasic(s, { keepTabs = false } = {}) {
  if (s == null) return '';
  let out = String(s).normalize('NFC').replace(ZERO_WIDTH, '').replace(APOSTROPHES, "'").replace(DASHES, '-').replace(SPACES, ' ');
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
