import { test, expect, run } from './harness.js';
import { itemsToLines, deskewItems, estimateSlope } from '../src/import/layout.js';
import { ocrLangsFor, ocrDataToText, imageScaleFor, fixGermanUmlauts } from '../src/import/ocr.js';
import { detectFileKind, ACCEPT } from '../src/import/files.js';
import { parseVocab } from '../src/core/parser.js';

// Geometry used by the helpers: 6 px per character, 12 px glyph height,
// 16 px line pitch (baseline to baseline).
const CW = 6;
const H = 12;
const PITCH = 16;

// One item per word, separated by a normal space (like OCR word boxes).
function words(x, y, text, { cw = CW, h = H } = {}) {
  const out = [];
  let cx = x;
  for (const w of text.split(' ')) {
    out.push({ str: w, x: cx, y, w: w.length * cw, h });
    cx += (w.length + 1) * cw;
  }
  return out;
}

// One item per cell (like pdf.js text runs).
function run_(x, y, text, { cw = CW, h = H } = {}) {
  return { str: text, x, y, w: text.length * cw, h };
}

// A table: rows of cells at the given column x positions.
function table(rows, xs, { y0 = 100, pitch = PITCH, perWord = false } = {}) {
  const items = [];
  rows.forEach((cells, r) => {
    cells.forEach((text, c) => {
      if (!text) return;
      const y = y0 + r * pitch;
      if (perWord) items.push(...words(xs[c], y, text));
      else items.push(run_(xs[c], y, text));
    });
  });
  return items;
}

// Deterministic shuffle (LCG) for "out of order" tests.
function shuffled(list, seed = 7) {
  const a = list.slice();
  let s = seed;
  for (let i = a.length - 1; i > 0; i--) {
    s = (s * 1103515245 + 12345) % 2147483648;
    const j = s % (i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

const PAIRS = [
  ['le monsieur, messieurs', 'der Herr'],
  ["l'homme", 'der Mann'],
  ['la femme', 'die Frau'],
  ["l'enfant", 'das Kind'],
  ['le garçon', 'der Junge'],
  ['la fille', 'das Mädchen'],
];

const MORE = [
  ['appeler', 'nennen'],
  ["s'appeler", 'heissen'],
  ['le nom', 'der Name'],
  ['le prénom', 'der Vorname'],
  ['la rue', 'die Strasse'],
];

// ---------------------------------------------------------------------------
// Basics

test('empty and invalid input yields no lines', () => {
  expect(itemsToLines([])).toEqual([]);
  expect(itemsToLines(null)).toEqual([]);
  expect(itemsToLines(undefined)).toEqual([]);
  expect(itemsToLines([null, { str: '   ', x: 0, y: 0 }, { str: 'x', x: NaN, y: 1 }, { x: 1, y: 1 }])).toEqual([]);
});

test('null options fall back to defaults', () => {
  expect(itemsToLines(words(10, 10, 'der Herr'), null)).toEqual(['der Herr']);
});

test('words on one baseline become one line with single spaces', () => {
  expect(itemsToLines(words(10, 50, 'le monsieur, messieurs'))).toEqual(['le monsieur, messieurs']);
});

test('fragments without a gap are joined without a space', () => {
  const items = [run_(10, 20, 'das Fr'), { str: 'äulein', x: 10 + 6 * CW, y: 20, w: 6 * CW, h: H }];
  expect(itemsToLines(items)).toEqual(['das Fräulein']);
});

test('trailing and leading spaces inside items mark word boundaries', () => {
  const items = [
    { str: 'der ', x: 10, y: 20, w: 4 * CW, h: H },
    { str: 'Herr', x: 10 + 4 * CW, y: 20, w: 4 * CW, h: H },
    { str: ' und', x: 10 + 8 * CW, y: 20, w: 4 * CW, h: H },
  ];
  expect(itemsToLines(items)).toEqual(['der Herr und']);
});

test('rows are grouped by y despite small jitter', () => {
  const items = [
    { str: 'le', x: 10, y: 101.5, w: 2 * CW, h: H },
    { str: 'monsieur', x: 10 + 3 * CW, y: 98.5, w: 8 * CW, h: H },
    { str: 'der', x: 10, y: 117.2, w: 3 * CW, h: H },
    { str: 'Herr', x: 10 + 4 * CW, y: 114.6, w: 4 * CW, h: H },
  ];
  expect(itemsToLines(items)).toEqual(['le monsieur', 'der Herr']);
});

test('items out of order are put back in reading order', () => {
  const items = [];
  PAIRS.forEach(([t, d], i) => {
    items.push(...words(20, 100 + i * 2 * PITCH, t));
    items.push(...words(20, 100 + (i * 2 + 1) * PITCH, d));
  });
  const expected = PAIRS.flat();
  expect(itemsToLines(items)).toEqual(expected);
  expect(itemsToLines(shuffled(items))).toEqual(expected);
  expect(itemsToLines(shuffled(items, 99))).toEqual(expected);
});

test('missing widths and heights are estimated', () => {
  const items = [
    { str: 'le nom', x: 10, y: 20 },
    { str: 'der Name', x: 300, y: 20 },
    { str: 'la rue', x: 10, y: 40 },
    { str: 'die Strasse', x: 300, y: 40 },
  ];
  expect(itemsToLines(items)).toEqual(['le nom\tder Name', 'la rue\tdie Strasse']);
});

test('invisible characters and odd spaces are cleaned', () => {
  const items = [{ str: 'la\u00A0mademoiselle\u00AD', x: 0, y: 0, w: 16 * CW, h: H }];
  expect(itemsToLines(items)).toEqual(['la mademoiselle']);
});

// ---------------------------------------------------------------------------
// Columns

test('a wide horizontal gap becomes a tab', () => {
  const items = [...words(10, 20, 'le nom'), ...words(200, 20, 'der Name')];
  expect(itemsToLines(items)).toEqual(['le nom\tder Name']);
});

test('gapFactor controls when a gap counts as a column break', () => {
  const items = [...words(10, 20, 'le nom'), ...words(10 + 9 * CW, 20, 'der Name')];
  // 3-character gap: > 2.2 × char width → tab; with gapFactor 4 it is a space.
  expect(itemsToLines(items)).toEqual(['le nom\tder Name']);
  expect(itemsToLines(items, { gapFactor: 4 })).toEqual(['le nom der Name']);
});

test('two-column vocabulary table → term<TAB>definition rows', () => {
  const rows = [...PAIRS, ...MORE];
  const lines = itemsToLines(table(rows, [40, 260], { perWord: true }));
  expect(lines).toEqual(rows.map(([t, d]) => `${t}\t${d}`));
});

test('two-column table from shuffled pdf runs', () => {
  const rows = [...PAIRS, ...MORE];
  const lines = itemsToLines(shuffled(table(rows, [40, 260])));
  expect(lines).toEqual(rows.map(([t, d]) => `${t}\t${d}`));
});

test('two-column table with y jitter per cell', () => {
  const items = table(PAIRS, [40, 260]).map((it, i) => ({ ...it, y: it.y + ((i % 3) - 1) * 2.5 }));
  expect(itemsToLines(items)).toEqual(PAIRS.map(([t, d]) => `${t}\t${d}`));
});

test('four-column table → left pairs first, then right pairs', () => {
  const rows = PAIRS.map((p, i) => [...p, ...(MORE[i] || [])]);
  const lines = itemsToLines(shuffled(table(rows, [30, 190, 360, 520], { perWord: true })));
  expect(lines).toEqual([...PAIRS.map(([t, d]) => `${t}\t${d}`), '', ...MORE.map(([t, d]) => `${t}\t${d}`)]);
});

test('four-column table where the right half is longer', () => {
  const right = [...MORE, ['calme', 'ruhig'], ['sage', 'brav, artig'], ['bête', 'dumm']];
  const rows = right.map((p, i) => [...(PAIRS[i] || ['', '']), ...p]);
  const lines = itemsToLines(table(rows, [30, 190, 360, 520]));
  expect(lines).toEqual([...PAIRS.map(([t, d]) => `${t}\t${d}`), '', ...right.map(([t, d]) => `${t}\t${d}`)]);
});

test('a heading spanning the table does not break column detection', () => {
  const items = [...words(30, 60, 'Unité 3 – Les personnes et les adjectifs du caractère'), ...table(PAIRS, [30, 260])];
  const lines = itemsToLines(items);
  expect(lines[0]).toBe('Unité 3 – Les personnes et les adjectifs du caractère');
  expect(lines.slice(-PAIRS.length)).toEqual(PAIRS.map(([t, d]) => `${t}\t${d}`));
});

test('a numbering column is dropped', () => {
  const rows = PAIRS.map(([t, d], i) => [`${i + 1}.`, t, d]);
  expect(itemsToLines(table(rows, [20, 60, 280]))).toEqual(PAIRS.map(([t, d]) => `${t}\t${d}`));
});

test('a numbered single-column list keeps only the text', () => {
  const rows = PAIRS.slice(0, 4).map(([t], i) => [`${i + 1})`, t]);
  expect(itemsToLines(table(rows, [20, 60]))).toEqual(PAIRS.slice(0, 4).map(([t]) => t));
});

test('an example-sentence column between term and translation is dropped', () => {
  const rows = [
    ['le monsieur', 'Le monsieur parle avec sa voisine.', 'der Herr'],
    ['la femme', 'La femme de Paul est très gentille.', 'die Frau'],
    ['le garçon', 'Le garçon joue au foot avec ses amis.', 'der Junge'],
    ['la fille', 'La fille de mes voisins a dix ans.', 'das Mädchen'],
  ];
  expect(itemsToLines(table(rows, [20, 160, 420]))).toEqual(rows.map(([t, , d]) => `${t}\t${d}`));
});

test('monospace columns inside one item are split at runs of spaces', () => {
  const items = [run_(10, 20, 'le nom          der Name'), run_(10, 36, 'la rue          die Strasse'), run_(10, 52, 'le prénom       der Vorname')];
  expect(itemsToLines(items)).toEqual(['le nom\tder Name', 'la rue\tdie Strasse', 'le prénom\tder Vorname']);
});

test('fake-bold duplicates are removed', () => {
  const items = [run_(10, 20, 'der Herr'), run_(10.4, 20, 'der Herr'), run_(200, 20, 'le monsieur')];
  expect(itemsToLines(items)).toEqual(['der Herr\tle monsieur']);
});

// ---------------------------------------------------------------------------
// Wrapped cells

test('wrapped definitions are merged into their row', () => {
  const items = [
    ...words(30, 100, 'le nom de famille'),
    ...words(260, 100, 'der Familienname,'),
    ...words(260, 116, 'der Nachname'),
    ...words(30, 132, 'le prénom'),
    ...words(260, 132, 'der Vorname'),
    ...words(30, 148, "l'adresse"),
    ...words(260, 148, 'die Adresse,'),
    ...words(260, 164, 'die Anschrift'),
    ...words(30, 180, 'la rue'),
    ...words(260, 180, 'die Strasse'),
  ];
  expect(itemsToLines(items)).toEqual([
    'le nom de famille\tder Familienname, der Nachname',
    'le prénom\tder Vorname',
    "l'adresse\tdie Adresse, die Anschrift",
    'la rue\tdie Strasse',
  ]);
});

test('a wrapped term ending with a comma is merged', () => {
  const items = [
    ...words(30, 100, 'le monsieur,'),
    ...words(260, 100, 'der Herr'),
    ...words(30, 116, 'messieurs'),
    ...words(30, 132, 'la femme'),
    ...words(260, 132, 'die Frau'),
    ...words(30, 148, 'la dame'),
    ...words(260, 148, 'die Dame'),
  ];
  expect(itemsToLines(items)).toEqual(['le monsieur, messieurs\tder Herr', 'la femme\tdie Frau', 'la dame\tdie Dame']);
});

test('a wrapped lowercase term is merged when rows are spaced wider than lines', () => {
  const items = [
    ...words(30, 100, 'le numéro de la'),
    ...words(260, 100, 'die Hausnummer'),
    ...words(30, 115, 'maison'),
    ...words(30, 140, 'la rue'),
    ...words(260, 140, 'die Strasse'),
    ...words(30, 165, 'la personne'),
    ...words(260, 165, 'die Person'),
  ];
  expect(itemsToLines(items)).toEqual(['le numéro de la maison\tdie Hausnummer', 'la rue\tdie Strasse', 'la personne\tdie Person']);
});

test('a section heading inside a table stays a separate line', () => {
  const items = [
    ...table(PAIRS.slice(0, 3), [30, 260], { y0: 100 }),
    ...words(30, 100 + 2 * PITCH + 3 * PITCH, 'Les adjectifs'),
    ...table(MORE.slice(0, 3), [30, 260], { y0: 100 + 6 * PITCH }),
  ];
  expect(itemsToLines(items)).toEqual([
    ...PAIRS.slice(0, 3).map(([t, d]) => `${t}\t${d}`),
    '',
    'Les adjectifs',
    ...MORE.slice(0, 3).map(([t, d]) => `${t}\t${d}`),
  ]);
});

// ---------------------------------------------------------------------------
// Paragraphs and page columns

test('paragraph gaps become blank lines (stacked term / definition list)', () => {
  const items = [];
  let y = 80;
  for (const [t, d] of PAIRS) {
    items.push(...words(40, y, t));
    items.push(...words(40, y + PITCH, d));
    y += PITCH * 5;
  }
  const lines = itemsToLines(shuffled(items));
  const expected = [];
  PAIRS.forEach(([t, d], i) => {
    if (i) expected.push('');
    expected.push(t, d);
  });
  expect(lines).toEqual(expected);
});

test('three evenly but widely spaced rows are not paragraphs', () => {
  const items = table(PAIRS.slice(0, 3), [20, 300], { pitch: 50 });
  expect(itemsToLines(items)).toEqual(PAIRS.slice(0, 3).map(([t, d]) => `${t}\t${d}`));
});

test('three rows with one wide gap get one blank line', () => {
  const items = [...words(40, 100, 'le nom'), ...words(40, 116, 'der Name'), ...words(40, 180, 'la rue')];
  expect(itemsToLines(items)).toEqual(['le nom', 'der Name', '', 'la rue']);
});

test('two lines far apart are separate paragraphs', () => {
  const items = [...words(40, 100, 'Vocabulaire'), ...words(40, 100 + 4 * PITCH, 'le nom')];
  expect(itemsToLines(items)).toEqual(['Vocabulaire', '', 'le nom']);
});

test('whitespace-only and empty pdf items are ignored', () => {
  const items = [
    run_(40, 100, 'le nom'),
    { str: ' ', x: 40 + 6 * CW, y: 100, w: 140, h: H },
    { str: '', x: 0, y: 100, w: 0, h: 0, hasEOL: true },
    run_(260, 100, 'der Name'),
    run_(40, 116, 'la rue'),
    run_(260, 116, 'die Strasse'),
  ];
  expect(itemsToLines(items)).toEqual(['le nom\tder Name', 'la rue\tdie Strasse']);
});

test('a normal line pitch never creates blank lines', () => {
  const items = [];
  PAIRS.flat().forEach((text, i) => items.push(...words(40, 100 + i * PITCH, text)));
  expect(itemsToLines(items)).not.toContain('');
});

test('uniform double spacing is not treated as paragraphs', () => {
  const items = [];
  PAIRS.flat().forEach((text, i) => items.push(...words(40, 100 + i * PITCH * 2, text)));
  expect(itemsToLines(items)).toEqual(PAIRS.flat());
});

test('stacked pairs in two page columns are read column by column', () => {
  const items = [];
  const left = PAIRS.slice(0, 4);
  const right = MORE.slice(0, 4);
  [left, right].forEach((list, col) => {
    let y = 100;
    for (const [t, d] of list) {
      items.push(...words(col ? 320 : 40, y, t));
      items.push(...words(col ? 320 : 40, y + PITCH, d));
      y += PITCH * 4;
    }
  });
  const expected = [];
  [left, right].forEach((list, col) => {
    if (col) expected.push('');
    list.forEach(([t, d], i) => {
      if (i) expected.push('');
      expected.push(t, d);
    });
  });
  expect(itemsToLines(items)).toEqual(expected);
});

test('unaligned text columns are read column by column', () => {
  const items = [];
  const left = PAIRS.flat();
  const right = MORE.flat();
  // Same leading, but the right column is shifted by half a line.
  left.forEach((text, i) => items.push(...words(40, 100 + i * PITCH, text)));
  right.forEach((text, i) => items.push(...words(330, 108 + i * PITCH, text)));
  expect(itemsToLines(items)).toEqual([...left, '', ...right]);
});

test('indented definitions in a single column keep the row order', () => {
  const items = [];
  let y = 100;
  for (const [t, d] of PAIRS) {
    items.push(...words(40, y, t));
    items.push(...words(120, y + PITCH, d));
    y += PITCH * 3;
  }
  const expected = [];
  PAIRS.forEach(([t, d], i) => {
    if (i) expected.push('');
    expected.push(t, d);
  });
  expect(itemsToLines(items)).toEqual(expected);
});

test('a lonely right-aligned page number does not create a column', () => {
  const items = [];
  PAIRS.flat().forEach((text, i) => items.push(...words(40, 100 + i * PITCH, text)));
  items.push(...words(500, 100 + 14 * PITCH, '12'));
  const lines = itemsToLines(items);
  expect(lines.slice(0, 12)).toEqual(PAIRS.flat());
  expect(lines[lines.length - 1]).toBe('12');
});

test('a larger heading font does not split or merge rows', () => {
  const items = [
    ...words(40, 60, 'Vocabulaire', { cw: 12, h: 24 }),
    ...table(PAIRS.slice(0, 4), [40, 260], { y0: 100 }),
  ];
  expect(itemsToLines(items)).toEqual(['Vocabulaire', '', ...PAIRS.slice(0, 4).map(([t, d]) => `${t}\t${d}`)]);
});

test('yTolerance controls row grouping', () => {
  const items = [run_(10, 100, 'le nom'), run_(200, 104, 'der Name'), run_(10, 118, 'la rue'), run_(200, 122, 'die Strasse')];
  expect(itemsToLines(items)).toEqual(['le nom\tder Name', 'la rue\tdie Strasse']);
  expect(itemsToLines(items, { yTolerance: 0.2 })).toEqual(['le nom', 'der Name', 'la rue', 'die Strasse']);
});

// ---------------------------------------------------------------------------
// Skew

test('estimateSlope uses the median of long baselines', () => {
  const segs = [
    { x0: 0, y0: 100, x1: 400, y1: 108 },
    { x0: 0, y0: 200, x1: 400, y1: 208.4 },
    { x0: 0, y0: 300, x1: 400, y1: 307.6 },
    { x0: 0, y0: 10, x1: 10, y1: 30 }, // too short
  ];
  expect(Math.abs(estimateSlope(segs) - 0.02) < 1e-9).toBe(true);
  expect(estimateSlope([])).toBe(0);
  expect(estimateSlope(null)).toBe(0);
});

test('deskewItems straightens rotated rows', () => {
  const slope = 0.06; // ≈ 3.4° — too much for plain row grouping
  const flat = table(PAIRS, [40, 400], { perWord: true, pitch: 24 });
  const skewed = flat.map((it) => ({ ...it, y: it.y + it.x * slope }));
  expect(itemsToLines(skewed)).not.toEqual(PAIRS.map(([t, d]) => `${t}\t${d}`));
  expect(itemsToLines(deskewItems(skewed, slope))).toEqual(PAIRS.map(([t, d]) => `${t}\t${d}`));
});

test('deskewItems is a no-op for tiny or invalid slopes', () => {
  const items = words(10, 10, 'la rue');
  expect(deskewItems(items, 0)).toEqual(items);
  expect(deskewItems(items, NaN)).toEqual(items);
  expect(deskewItems(null, 0.1)).toEqual([]);
});

// ---------------------------------------------------------------------------
// Pure helpers of the browser adapters

test('ocrLangsFor maps the learned language to tesseract models', () => {
  expect(ocrLangsFor('fr')).toEqual(['fra', 'deu']);
  expect(ocrLangsFor('en')).toEqual(['eng', 'deu']);
  expect(ocrLangsFor('es')).toEqual(['spa', 'deu']);
  expect(ocrLangsFor('it')).toEqual(['ita', 'deu']);
  expect(ocrLangsFor('de')).toEqual(['deu']);
  expect(ocrLangsFor('other')).toEqual(['eng', 'deu']);
  expect(ocrLangsFor(undefined)).toEqual(['fra', 'deu']);
});

// Synthetic tesseract.js word: box from (x, baseline - 22) to (x + width, baseline + 4).
function tessWord(text, x, baseline, { slope = 0, conf = 90 } = {}) {
  const w = text.length * 11;
  const yb = baseline + slope * x;
  return {
    text,
    confidence: conf,
    bbox: { x0: x, y0: yb - 22, x1: x + w, y1: yb + 4 },
    baseline: { x0: x, y0: yb, x1: x + w, y1: yb + slope * w, has_baseline: true },
  };
}

function tessTable(rows, { slope = 0, bars = false } = {}) {
  const words = [];
  const lines = [];
  rows.forEach(([t, d], r) => {
    const base = 120 + r * 40;
    let x = 60;
    for (const part of t.split(' ')) {
      words.push(tessWord(part, x, base, { slope }));
      x += (part.length + 1) * 11;
    }
    if (bars) words.push(tessWord('|', 420, base, { slope, conf: 20 }));
    x = 520;
    for (const part of d.split(' ')) {
      words.push(tessWord(part, x, base, { slope }));
      x += (part.length + 1) * 11;
    }
    lines.push({ baseline: { x0: 60, y0: base + slope * 60, x1: 900, y1: base + slope * 900, has_baseline: true } });
  });
  return { text: 'plain fallback', words, lines };
}

test('ocrDataToText rebuilds a two-column table from word boxes', () => {
  expect(ocrDataToText(tessTable(PAIRS))).toBe(PAIRS.map(([t, d]) => `${t}\t${d}`).join('\n'));
});

test('ocrDataToText drops table rules and straightens skewed photos', () => {
  const data = tessTable(PAIRS, { slope: 0.05, bars: true });
  expect(ocrDataToText(data)).toBe(PAIRS.map(([t, d]) => `${t}\t${d}`).join('\n'));
});

test('ocrDataToText strips border bars glued to words', () => {
  const data = tessTable([['la rue', 'die Strasse'], ['le nom', 'der Name']]);
  data.words[0].text = '|la';
  data.words[0].bbox.x0 -= 11;
  expect(ocrDataToText(data)).toBe('la rue\tdie Strasse\nle nom\tder Name');
});

test('ocrDataToText reads the nested blocks result shape', () => {
  const flat = tessTable(PAIRS.slice(0, 3));
  const data = { text: 'x', blocks: [{ paragraphs: [{ lines: [{ baseline: flat.lines[0].baseline, words: flat.words }] }] }] };
  expect(ocrDataToText(data)).toBe(
    PAIRS.slice(0, 3)
      .map(([t, d]) => `${t}\t${d}`)
      .join('\n'),
  );
});

test('ocrDataToText falls back to the plain text', () => {
  expect(ocrDataToText({ text: '  le nom\nder Name \n', words: [] })).toBe('le nom\nder Name');
  expect(ocrDataToText(null)).toBe('');
  expect(ocrDataToText({})).toBe('');
});

test('imageScaleFor upscales small images and limits large ones', () => {
  expect(imageScaleFor(600, 400)).toBe(2);
  expect(imageScaleFor(1199, 900)).toBe(2);
  expect(imageScaleFor(1600, 1200)).toBe(1);
  expect(Math.round(imageScaleFor(3024, 4032) * 4032)).toBe(3000);
  expect(Math.round(imageScaleFor(4032, 3024) * 4032)).toBe(3000);
  // Very tall screenshot: width is kept legible, pixel budget respected.
  const s = imageScaleFor(1170, 8000);
  expect(s > 1).toBe(true);
  expect(1170 * 8000 * s * s <= 12e6 + 1).toBe(true);
  expect(imageScaleFor(0, 100)).toBe(1);
});

test('detectFileKind uses MIME type and extension', () => {
  expect(detectFileKind({ name: 'vokabeln.txt', type: 'text/plain' })).toBe('text');
  expect(detectFileKind({ name: 'export.csv', type: 'application/vnd.ms-excel' })).toBe('text');
  expect(detectFileKind({ name: 'liste.TSV', type: '' })).toBe('text');
  expect(detectFileKind({ name: 'README', type: '' })).toBe('text');
  expect(detectFileKind({ name: 'notes.md', type: 'text/markdown' })).toBe('text');
  expect(detectFileKind({ name: 'unite3.pdf', type: '' })).toBe('pdf');
  expect(detectFileKind({ name: 'scan', type: 'application/pdf' })).toBe('pdf');
  expect(detectFileKind({ name: 'IMG_0412.HEIC', type: '' })).toBe('image');
  expect(detectFileKind({ name: 'foto.jpg', type: 'image/jpeg' })).toBe('image');
  expect(detectFileKind({ name: 'image.png', type: 'image/png' })).toBe('image');
  expect(detectFileKind({ name: 'bild.webp', type: '' })).toBe('image');
  expect(detectFileKind({ name: 'logo.svg', type: 'image/svg+xml' })).toBe(null);
  expect(detectFileKind({ name: 'brief.docx', type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' })).toBe(null);
  expect(detectFileKind({ name: 'text.rtf', type: 'text/rtf' })).toBe(null);
  expect(detectFileKind({ name: 'seite.html', type: 'text/html' })).toBe(null);
  expect(detectFileKind(null)).toBe(null);
});

test('ACCEPT lists every supported family', () => {
  for (const part of ['.txt', '.csv', '.tsv', '.pdf', 'image/*', '.heic']) expect(ACCEPT).toContain(part);
});

// ---------------------------------------------------------------------------
// Review regressions

const ROWS_22 = [
  ['avoir lieu', 'stattfinden'],
  ['le chat', 'die Katze'],
  ['le chien', 'der Hund'],
  ['manger', 'essen'],
  ['boire', 'trinken'],
];

test('a row whose term and definition both wrap stays one entry', () => {
  // Continuation line 14 below its row; table rows 22 apart.
  const items = [run_(50, 100, "s'entendre bien avec"), run_(260, 100, 'sich mit jdm gut'), run_(50, 114, 'qn'), run_(260, 114, 'verstehen')];
  ROWS_22.forEach(([t, d], i) => items.push(run_(50, 136 + i * 22, t), run_(260, 136 + i * 22, d)));
  const lines = itemsToLines(items);
  expect(lines).toEqual(["s'entendre bien avec qn\tsich mit jdm gut verstehen", ...ROWS_22.map(([t, d]) => `${t}\t${d}`)]);
  const cards = parseVocab(lines.join('\n')).cards;
  expect(cards[0].term).toBe("s'entendre bien avec qn");
  expect(cards[0].definition).toBe('sich mit jdm gut verstehen');
  expect(cards).toHaveLength(6);
});

test('lowercase rows at a slightly uneven pitch are not merged', () => {
  const verbs = [
    ['manger', 'essen'],
    ['boire', 'trinken'],
    ['dormir', 'schlafen'],
    ['parler', 'sprechen'],
    ['lire', 'lesen'],
    ['écrire', 'schreiben'],
  ];
  const ys = [100, 122, 141, 163, 185, 207];
  const items = verbs.flatMap(([t, d], i) => [run_(50, ys[i], t), run_(260, ys[i], d)]);
  expect(itemsToLines(items)).toEqual(verbs.map(([t, d]) => `${t}\t${d}`));
});

test('two page columns of "term – definition" entries become one card per entry', () => {
  const left = PAIRS.concat(MORE.slice(0, 2));
  const right = MORE.slice(2).concat([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la vache', 'die Kuh'],
    ['le cheval', 'das Pferd'],
  ]);
  const items = [];
  left.forEach(([t, d], i) => items.push(run_(50, 100 + i * PITCH, `${t} – ${d}`)));
  right.forEach(([t, d], i) => items.push(run_(320, 100 + i * PITCH, `${t} – ${d}`)));
  const lines = itemsToLines(items);
  expect(lines[0]).toBe(`${left[0][0]} – ${left[0][1]}\t${right[0][0]} – ${right[0][1]}`);
  const r = parseVocab(lines.join('\n'));
  expect(r.cards.map((c) => [c.term, c.definition])).toEqual([...left, ...right]);
  expect(r.cards.filter((c) => c.flags.length)).toEqual([]);
});

test('a right page column that ends early still gives one card per entry, left column first', () => {
  const left = PAIRS.concat(MORE.slice(0, 4));
  const right = [
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la vache', 'die Kuh'],
    ['le cheval', 'das Pferd'],
    ['la souris', 'die Maus'],
    ['le cochon', 'das Schwein'],
  ];
  for (const k of [6, 5, 3, 1]) {
    const items = [];
    left.forEach(([t, d], i) => items.push(run_(50, 100 + i * PITCH, `${t} – ${d}`)));
    right.slice(0, k).forEach(([t, d], i) => items.push(run_(320, 100 + i * PITCH, `${t} – ${d}`)));
    const r = parseVocab(itemsToLines(items).join('\n'));
    const got = r.cards.map((c) => [c.term, c.definition]);
    expect(`${k}: ${JSON.stringify(got)}`).toBe(`${k}: ${JSON.stringify([...left, ...right.slice(0, k)])}`);
    expect(r.cards.filter((c) => c.flags.length)).toEqual([]);
  }
});

test('fixGermanUmlauts restores umlauts read as circumflexes in German cells only', () => {
  expect(
    fixGermanUmlauts(['le chat\tdie Katze', 'beau\tschôn', 'le rôle\tdie Rolle', 'vert\tgrûn', 'fatigué\tmûde', 'à côté de\tneben', 'la porte\tdie Tûr']),
  ).toEqual(['le chat\tdie Katze', 'beau\tschön', 'le rôle\tdie Rolle', 'vert\tgrün', 'fatigué\tmüde', 'à côté de\tneben', 'la porte\tdie Tür']);
  // Without columns only clearly German lines change.
  expect(fixGermanUmlauts(['tôt', 'früh', 'le rôle', 'die Rolle', 'beau', 'schôn', 'la porte', 'die Tûr', 'brûler', 'brennen'])).toEqual([
    'tôt',
    'früh',
    'le rôle',
    'die Rolle',
    'beau',
    'schön',
    'la porte',
    'die Tür',
    'brûler',
    'brennen',
  ]);
  expect(fixGermanUmlauts(['LA PORTE\tDIE TÛR', 'le chat\tdie Katze', 'le chien\tder Hund'])).toEqual([
    'LA PORTE\tDIE TÜR',
    'le chat\tdie Katze',
    'le chien\tder Hund',
  ]);
  expect(fixGermanUmlauts(['le château\tdas Schloss', 'le gâteau\tder Kuchen', 'âgé\talt'])).toEqual([
    'le château\tdas Schloss',
    'le gâteau\tder Kuchen',
    'âgé\talt',
  ]);
  expect(fixGermanUmlauts(null)).toEqual([]);
});

test('ocrDataToText restores German umlauts misread by OCR', () => {
  const rows = [
    ['beau, belle', 'schôn'],
    ['le rôle', 'die Rolle'],
    ['la porte', 'die Tûr'],
    ['fatigué', 'mûde'],
  ];
  expect(ocrDataToText(tessTable(rows))).toBe('beau, belle\tschön\nle rôle\tdie Rolle\nla porte\tdie Tür\nfatigué\tmüde');
  expect(ocrDataToText({ text: 'die Tûr\nla porte\n', words: [] })).toBe('die Tür\nla porte');
});

await run('layout.test.js');
