// Special characters per language for the on-screen character bar.

export const SPECIAL_CHARS = {
  fr: ['é', 'è', 'ê', 'ë', 'à', 'â', 'ç', 'î', 'ï', 'ô', 'û', 'ù', 'ü', 'œ', 'æ'],
  de: ['ä', 'ö', 'ü', 'Ä', 'Ö', 'Ü'],
  es: ['á', 'é', 'í', 'ó', 'ú', 'ñ', 'ü', '¿', '¡'],
  it: ['à', 'è', 'é', 'ì', 'ò', 'ù'],
  en: [],
  // Arabic needs an Arabic keyboard (vowel marks never count); pinyin tones can be typed as
  // numbers (ni3), so only ü.
  ar: [],
  zh: ['ü'],
  other: [],
};

export function charsFor(lang) {
  return SPECIAL_CHARS[lang] || [];
}

// Inserts text at the caret of an <input>/<textarea>, keeps focus and fires an
// `input` event so listeners see the change. Browser only.
export function insertAtCaret(field, text) {
  if (!field || text == null) return;
  const value = String(field.value ?? '');
  const start = typeof field.selectionStart === 'number' ? field.selectionStart : value.length;
  const end = typeof field.selectionEnd === 'number' ? field.selectionEnd : value.length;
  if (typeof field.setRangeText === 'function') {
    field.setRangeText(String(text), start, end, 'end');
  } else {
    field.value = value.slice(0, start) + text + value.slice(end);
    const caret = start + String(text).length;
    if (typeof field.setSelectionRange === 'function') field.setSelectionRange(caret, caret);
  }
  if (typeof field.focus === 'function') field.focus({ preventScroll: true });
  if (typeof field.dispatchEvent === 'function' && typeof Event === 'function') {
    field.dispatchEvent(new Event('input', { bubbles: true }));
  }
}
