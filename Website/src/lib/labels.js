// Shared German UI labels (Swiss spelling: "ss", never the sharp s). Pure.

export const LANGS = {
  fr: { name: 'Französisch', short: 'FR', bcp47: 'fr-FR' },
  en: { name: 'Englisch', short: 'EN', bcp47: 'en-GB' },
  es: { name: 'Spanisch', short: 'ES', bcp47: 'es-ES' },
  it: { name: 'Italienisch', short: 'IT', bcp47: 'it-IT' },
  // Written right to left (rtl: only Arabic has it).
  ar: { name: 'Arabisch', short: 'AR', bcp47: 'ar', rtl: true },
  zh: { name: 'Chinesisch', short: 'ZH', bcp47: 'zh-CN' },
  de: { name: 'Deutsch', short: 'DE', bcp47: 'de-CH' },
  other: { name: 'Andere', short: '—', bcp47: '' },
};

// Display order for language pickers.
export const LANG_ORDER = ['fr', 'en', 'es', 'it', 'ar', 'zh', 'de', 'other'];

export const STATUS = { new: 'Neu', learning: 'Am Lernen', mastered: 'Gemeistert' };

export const NOTE_LABELS = {
  article: 'Artikel fehlte',
  pronoun: 'Pronomen fehlte',
  abbreviation: 'Abkürzung',
  partial: 'Teilantwort',
  parentheses: 'Klammerinhalt weggelassen',
  pinyin: 'Nur Pinyin',
  case: 'Gross-/Kleinschreibung',
  accents: 'Akzente',
  tones: 'Töne',
  variant: 'Schreibvariante',
  typo: 'Tippfehler',
  order: 'Reihenfolge',
  // The answer of another card with the same prompt (core/synonyms.js).
  synonym: 'Anderes Wort mit gleicher Bedeutung',
};

export const HINT_LABELS = {
  wrongArticle: 'Falscher Artikel',
  missingArticle: 'Artikel fehlt',
  accentsOnly: 'Nur die Akzente stimmen nicht',
  tonesOnly: 'Nur die Töne fehlen',
  caseOnly: 'Nur Gross-/Kleinschreibung falsch',
  typo: 'Fast – ein kleiner Tippfehler',
  almost: 'Knapp daneben',
};

// plural(3, 'Begriff', 'Begriffe') -> '3 Begriffe'
export function plural(n, one, other) {
  return `${n} ${n === 1 ? one : other}`;
}

export function langName(code) {
  return (LANGS[code] || LANGS.other).name;
}

export function langShort(code) {
  return (LANGS[code] || LANGS.other).short;
}

// The BCP 47 tag of a language code (null for «Andere» and unknown codes).
export function bcp47(code) {
  const l = Object.prototype.hasOwnProperty.call(LANGS, code) ? LANGS[code] : null;
  return (l && l.bcp47) || null;
}

// Attributes for the innermost element showing card text: its language and direction. Arabic
// is right to left, «Andere» and unknown codes follow the text (auto), other languages need no
// dir (null; h() leaves null attributes out). The layout around it stays left to right.
export function textAttrs(code) {
  const l = Object.prototype.hasOwnProperty.call(LANGS, code) ? LANGS[code] : null;
  return { lang: bcp47(code), dir: l && l.rtl ? 'rtl' : !l || code === 'other' ? 'auto' : null };
}

// Attributes for an answer or edit field: the direction follows what is typed (an empty field
// keeps its German placeholder left to right).
export function fieldAttrs(code) {
  return { lang: bcp47(code), dir: 'auto' };
}

// 'FR → DE'
export function langPair(termLang, defLang) {
  return `${langShort(termLang)} → ${langShort(defLang)}`;
}
