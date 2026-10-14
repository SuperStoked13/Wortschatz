// Shared German UI labels (Swiss spelling: "ss", never the sharp s). Pure.

export const LANGS = {
  fr: { name: 'Französisch', short: 'FR', bcp47: 'fr-FR' },
  en: { name: 'Englisch', short: 'EN', bcp47: 'en-GB' },
  es: { name: 'Spanisch', short: 'ES', bcp47: 'es-ES' },
  it: { name: 'Italienisch', short: 'IT', bcp47: 'it-IT' },
  de: { name: 'Deutsch', short: 'DE', bcp47: 'de-CH' },
  other: { name: 'Andere', short: '—', bcp47: '' },
};

// Display order for language pickers.
export const LANG_ORDER = ['fr', 'en', 'es', 'it', 'de', 'other'];

export const STATUS = { new: 'Neu', learning: 'Am Lernen', mastered: 'Gemeistert' };

export const NOTE_LABELS = {
  article: 'Artikel fehlte',
  pronoun: 'Pronomen fehlte',
  abbreviation: 'Abkürzung',
  partial: 'Teilantwort',
  parentheses: 'Klammerinhalt weggelassen',
  case: 'Gross-/Kleinschreibung',
  accents: 'Akzente',
  typo: 'Tippfehler',
  order: 'Reihenfolge',
  // The answer of another card with the same prompt (core/synonyms.js).
  synonym: 'Anderes Wort mit gleicher Bedeutung',
};

export const HINT_LABELS = {
  wrongArticle: 'Falscher Artikel',
  missingArticle: 'Artikel fehlt',
  accentsOnly: 'Nur die Akzente stimmen nicht',
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

// 'FR → DE'
export function langPair(termLang, defLang) {
  return `${langShort(termLang)} → ${langShort(defLang)}`;
}
