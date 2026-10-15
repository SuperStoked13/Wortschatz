// Helpers shared by the editor modules (labels, keys, small DOM utility).
// No DOM access at import time.

import { normalizeBasic, foldScripts } from '../core/text.js';

// "Trennung" choices of the import panel and their parseVocab options.
export const SEPARATORS = [
  { value: 'auto', label: 'Automatisch' },
  { value: 'tab', label: 'Tab', opts: { mode: 'delimiter', delimiter: '\t' } },
  { value: 'comma', label: 'Komma', opts: { mode: 'delimiter', delimiter: ',' } },
  { value: 'semicolon', label: 'Strichpunkt', opts: { mode: 'delimiter', delimiter: ';' } },
  { value: 'dash', label: 'Bindestrich', opts: { mode: 'delimiter', delimiter: '-' } },
  { value: 'lines', label: 'Zeilenweise', opts: { mode: 'lines' } },
  { value: 'custom', label: 'Eigenes…' },
];

export const SKIP_REASONS = {
  heading: 'Überschrift',
  pageNumber: 'Seitenzahl',
  noise: 'Kein Vokabeltext',
  unpaired: 'Ohne Gegenstück',
};

const DELIMITER_NAMES = {
  '\t': 'Tabulator',
  ',': 'Komma',
  ';': 'Strichpunkt',
  '-': 'Bindestrich',
  '=': 'Gleichheitszeichen',
  ':': 'Doppelpunkt',
  '|': 'Senkrechten Strich',
  '→': 'Pfeil',
  '/': 'Schrägstrich',
};

// Parser flags that earn an amber "please check" marker ('duplicate' is shown separately).
const FLAG_TEXT = {
  merged: 'Aus mehreren Zeilen zusammengefügt',
  lowConfidence: 'Unsicher erkannt',
  langMismatch: 'Sprache passt nicht zur Spalte',
  missingTerm: 'Begriff fehlt',
  missingDefinition: 'Definition fehlt',
};

export function hasMarker(flags) {
  return (flags || []).some((f) => FLAG_TEXT[f]);
}

// Tooltip for a flagged card (null when nothing to show).
export function flagTooltip(flags) {
  const parts = (flags || []).map((f) => FLAG_TEXT[f]).filter(Boolean);
  if (!parts.length) return null;
  return `${parts.join(' · ')} – bitte prüfen`;
}

// Case- and whitespace-insensitive key used to find duplicate terms. Like grading it ignores
// Arabic vowel marks and tatweel, full-width punctuation (؟ 。 ！) and spaces between Han.
export function termKey(term) {
  return foldScripts(normalizeBasic(term)).toLowerCase().replace(/[.!?]+$/, '');
}

// Short German description of the detected layout.
export function formatLabel(result) {
  if (!result) return null;
  switch (result.format) {
    case 'blocks':
    case 'alternating':
      return 'Abwechselnde Zeilen';
    case 'columns':
      return 'Zwei Spalten nacheinander';
    case 'delimited': {
      const d = result.delimiter;
      if (d === '  ') return 'Spalten mit Abstand';
      if (d === ' ') return 'Beide Sprachen in einer Zeile';
      const key = d === '\t' ? '\t' : String(d || '').trim();
      const name = DELIMITER_NAMES[key];
      if (name) return `Getrennt durch ${name}`;
      return key ? `Getrennt durch «${key}»` : null;
    }
    default:
      return null;
  }
}

// Title suggestion from a file name ("Unité_3 - Vocabulaire.pdf" -> "Unité 3 - Vocabulaire");
// generic camera/screenshot names yield ''.
export function titleFromFileName(name) {
  const base = String(name || '')
    .replace(/\.[a-z0-9]{1,5}$/i, '')
    .replace(/[_]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!base || base.length < 2) return '';
  if (/^(image|img|screenshot|bildschirmfoto|scan|dsc|pxl|photo|foto|untitled|unbenannt)([\s\d._-]|$)/i.test(base)) return '';
  return base.slice(0, 80);
}

export function isApplePlatform() {
  const nav = globalThis.navigator;
  return !!nav && /Mac|iPhone|iPad|iPod/i.test(`${nav.platform || ''} ${nav.userAgent || ''}`);
}

// replaceChildren() that skips null/false (the native one renders "null").
export function fill(el, ...children) {
  el.replaceChildren(...children.flat(Infinity).filter((c) => c != null && c !== false && c !== ''));
  return el;
}
