// Parity fixture for src/import/layout.js → Fixtures/layout.json.
// fns: itemsToLines [items, opts?], estimateSlope [segments, opts?], deskewItems [items, slope]
//
// Inputs: every input of tests/layout.test.js (same helpers and geometry) plus seeded synthetic
// pages: 2/3/4-column tables (per word or per run, y/x jitter, shuffled, wrapped cells, headings,
// page numbers, fake bold, missing sizes), stacked pairs, paragraphs, two page columns,
// unaligned columns, monospace runs, skewed photos (raw and deskewed), option variations, odd
// items and random soup. deskewItems only gets well-formed {str,x,y,w,h} items (its output keeps
// every input key, the Swift TextItem has exactly these five).
import { itemsToLines, estimateSlope, deskewItems } from '../../Website/src/import/layout.js';
import { Cases, mulberry32, randInt, pick, chance, readText } from './lib.js';

const cases = new Cases('layout');

function lines(items, opts) {
  if (opts === undefined) cases.add('itemsToLines', [items], itemsToLines(items));
  else cases.add('itemsToLines', [items, opts], itemsToLines(items, opts));
}

function slope(segments, opts) {
  if (opts === undefined) cases.add('estimateSlope', [segments], estimateSlope(segments));
  else cases.add('estimateSlope', [segments, opts], estimateSlope(segments, opts));
}

function deskew(items, s) {
  const out = deskewItems(items, s);
  cases.add('deskewItems', [items, s], out);
  return out;
}

// ---------------------------------------------------------------------------
// 1. tests/layout.test.js (helpers copied verbatim)

const CW = 6;
const H = 12;
const PITCH = 16;

function words(x, y, text, { cw = CW, h = H } = {}) {
  const out = [];
  let cx = x;
  for (const w of text.split(' ')) {
    out.push({ str: w, x: cx, y, w: w.length * cw, h });
    cx += (w.length + 1) * cw;
  }
  return out;
}

function run_(x, y, text, { cw = CW, h = H } = {}) {
  return { str: text, x, y, w: text.length * cw, h };
}

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

const ROWS_22 = [
  ['avoir lieu', 'stattfinden'],
  ['le chat', 'die Katze'],
  ['le chien', 'der Hund'],
  ['manger', 'essen'],
  ['boire', 'trinken'],
];

{
  lines([]);
  lines(null);
  lines(undefined);
  lines([null, { str: '   ', x: 0, y: 0 }, { str: 'x', x: NaN, y: 1 }, { x: 1, y: 1 }]);
  lines(words(10, 10, 'der Herr'), null);
  lines(words(10, 50, 'le monsieur, messieurs'));
  lines([run_(10, 20, 'das Fr'), { str: 'äulein', x: 10 + 6 * CW, y: 20, w: 6 * CW, h: H }]);
  lines([
    { str: 'der ', x: 10, y: 20, w: 4 * CW, h: H },
    { str: 'Herr', x: 10 + 4 * CW, y: 20, w: 4 * CW, h: H },
    { str: ' und', x: 10 + 8 * CW, y: 20, w: 4 * CW, h: H },
  ]);
  lines([
    { str: 'le', x: 10, y: 101.5, w: 2 * CW, h: H },
    { str: 'monsieur', x: 10 + 3 * CW, y: 98.5, w: 8 * CW, h: H },
    { str: 'der', x: 10, y: 117.2, w: 3 * CW, h: H },
    { str: 'Herr', x: 10 + 4 * CW, y: 114.6, w: 4 * CW, h: H },
  ]);
  {
    const items = [];
    PAIRS.forEach(([t, d], i) => {
      items.push(...words(20, 100 + i * 2 * PITCH, t));
      items.push(...words(20, 100 + (i * 2 + 1) * PITCH, d));
    });
    lines(items);
    lines(shuffled(items));
    lines(shuffled(items, 99));
  }
  lines([
    { str: 'le nom', x: 10, y: 20 },
    { str: 'der Name', x: 300, y: 20 },
    { str: 'la rue', x: 10, y: 40 },
    { str: 'die Strasse', x: 300, y: 40 },
  ]);
  lines([{ str: 'la mademoiselle­', x: 0, y: 0, w: 16 * CW, h: H }]);
  lines([...words(10, 20, 'le nom'), ...words(200, 20, 'der Name')]);
  {
    const items = [...words(10, 20, 'le nom'), ...words(10 + 9 * CW, 20, 'der Name')];
    lines(items);
    lines(items, { gapFactor: 4 });
  }
  const rows = [...PAIRS, ...MORE];
  lines(table(rows, [40, 260], { perWord: true }));
  lines(shuffled(table(rows, [40, 260])));
  lines(table(PAIRS, [40, 260]).map((it, i) => ({ ...it, y: it.y + ((i % 3) - 1) * 2.5 })));
  lines(shuffled(table(PAIRS.map((p, i) => [...p, ...(MORE[i] || [])]), [30, 190, 360, 520], { perWord: true })));
  {
    const right = [...MORE, ['calme', 'ruhig'], ['sage', 'brav, artig'], ['bête', 'dumm']];
    lines(table(right.map((p, i) => [...(PAIRS[i] || ['', '']), ...p]), [30, 190, 360, 520]));
  }
  lines([...words(30, 60, 'Unité 3 – Les personnes et les adjectifs du caractère'), ...table(PAIRS, [30, 260])]);
  lines(table(PAIRS.map(([t, d], i) => [`${i + 1}.`, t, d]), [20, 60, 280]));
  lines(table(PAIRS.slice(0, 4).map(([t], i) => [`${i + 1})`, t]), [20, 60]));
  lines(table([
    ['le monsieur', 'Le monsieur parle avec sa voisine.', 'der Herr'],
    ['la femme', 'La femme de Paul est très gentille.', 'die Frau'],
    ['le garçon', 'Le garçon joue au foot avec ses amis.', 'der Junge'],
    ['la fille', 'La fille de mes voisins a dix ans.', 'das Mädchen'],
  ], [20, 160, 420]));
  lines([run_(10, 20, 'le nom          der Name'), run_(10, 36, 'la rue          die Strasse'), run_(10, 52, 'le prénom       der Vorname')]);
  lines([run_(10, 20, 'der Herr'), run_(10.4, 20, 'der Herr'), run_(200, 20, 'le monsieur')]);
  lines([
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
  ]);
  lines([
    ...words(30, 100, 'le monsieur,'),
    ...words(260, 100, 'der Herr'),
    ...words(30, 116, 'messieurs'),
    ...words(30, 132, 'la femme'),
    ...words(260, 132, 'die Frau'),
    ...words(30, 148, 'la dame'),
    ...words(260, 148, 'die Dame'),
  ]);
  lines([
    ...words(30, 100, 'le numéro de la'),
    ...words(260, 100, 'die Hausnummer'),
    ...words(30, 115, 'maison'),
    ...words(30, 140, 'la rue'),
    ...words(260, 140, 'die Strasse'),
    ...words(30, 165, 'la personne'),
    ...words(260, 165, 'die Person'),
  ]);
  lines([
    ...table(PAIRS.slice(0, 3), [30, 260], { y0: 100 }),
    ...words(30, 100 + 2 * PITCH + 3 * PITCH, 'Les adjectifs'),
    ...table(MORE.slice(0, 3), [30, 260], { y0: 100 + 6 * PITCH }),
  ]);
  {
    const items = [];
    let y = 80;
    for (const [t, d] of PAIRS) {
      items.push(...words(40, y, t));
      items.push(...words(40, y + PITCH, d));
      y += PITCH * 5;
    }
    lines(shuffled(items));
  }
  lines(table(PAIRS.slice(0, 3), [20, 300], { pitch: 50 }));
  lines([...words(40, 100, 'le nom'), ...words(40, 116, 'der Name'), ...words(40, 180, 'la rue')]);
  lines([...words(40, 100, 'Vocabulaire'), ...words(40, 100 + 4 * PITCH, 'le nom')]);
  lines([
    run_(40, 100, 'le nom'),
    { str: ' ', x: 40 + 6 * CW, y: 100, w: 140, h: H },
    { str: '', x: 0, y: 100, w: 0, h: 0, hasEOL: true },
    run_(260, 100, 'der Name'),
    run_(40, 116, 'la rue'),
    run_(260, 116, 'die Strasse'),
  ]);
  {
    const items = [];
    PAIRS.flat().forEach((text, i) => items.push(...words(40, 100 + i * PITCH, text)));
    lines(items);
    const page = items.concat(words(500, 100 + 14 * PITCH, '12'));
    lines(page);
  }
  {
    const items = [];
    PAIRS.flat().forEach((text, i) => items.push(...words(40, 100 + i * PITCH * 2, text)));
    lines(items);
  }
  {
    const items = [];
    [PAIRS.slice(0, 4), MORE.slice(0, 4)].forEach((list, col) => {
      let y = 100;
      for (const [t, d] of list) {
        items.push(...words(col ? 320 : 40, y, t));
        items.push(...words(col ? 320 : 40, y + PITCH, d));
        y += PITCH * 4;
      }
    });
    lines(items);
  }
  {
    const items = [];
    PAIRS.flat().forEach((text, i) => items.push(...words(40, 100 + i * PITCH, text)));
    MORE.flat().forEach((text, i) => items.push(...words(330, 108 + i * PITCH, text)));
    lines(items);
  }
  {
    const items = [];
    let y = 100;
    for (const [t, d] of PAIRS) {
      items.push(...words(40, y, t));
      items.push(...words(120, y + PITCH, d));
      y += PITCH * 3;
    }
    lines(items);
  }
  lines([...words(40, 60, 'Vocabulaire', { cw: 12, h: 24 }), ...table(PAIRS.slice(0, 4), [40, 260], { y0: 100 })]);
  {
    const items = [run_(10, 100, 'le nom'), run_(200, 104, 'der Name'), run_(10, 118, 'la rue'), run_(200, 122, 'die Strasse')];
    lines(items);
    lines(items, { yTolerance: 0.2 });
  }
  {
    const segs = [
      { x0: 0, y0: 100, x1: 400, y1: 108 },
      { x0: 0, y0: 200, x1: 400, y1: 208.4 },
      { x0: 0, y0: 300, x1: 400, y1: 307.6 },
      { x0: 0, y0: 10, x1: 10, y1: 30 },
    ];
    slope(segs);
    slope([]);
    slope(null);
    slope(segs, { minWidth: 5 });
    slope(segs, {});
  }
  {
    const s = 0.06;
    const flat = table(PAIRS, [40, 400], { perWord: true, pitch: 24 });
    const skewed = flat.map((it) => ({ ...it, y: it.y + it.x * s }));
    lines(skewed);
    lines(deskew(skewed, s));
  }
  {
    const items = words(10, 10, 'la rue');
    deskew(items, 0);
    deskew(items, NaN);
    deskew(null, 0.1);
  }
  {
    const items = [run_(50, 100, "s'entendre bien avec"), run_(260, 100, 'sich mit jdm gut'), run_(50, 114, 'qn'), run_(260, 114, 'verstehen')];
    ROWS_22.forEach(([t, d], i) => items.push(run_(50, 136 + i * 22, t), run_(260, 136 + i * 22, d)));
    lines(items);
  }
  {
    const verbs = [['manger', 'essen'], ['boire', 'trinken'], ['dormir', 'schlafen'], ['parler', 'sprechen'], ['lire', 'lesen'], ['écrire', 'schreiben']];
    const ys = [100, 122, 141, 163, 185, 207];
    lines(verbs.flatMap(([t, d], i) => [run_(50, ys[i], t), run_(260, ys[i], d)]));
  }
  {
    const left = PAIRS.concat(MORE.slice(0, 2));
    const right = MORE.slice(2).concat([['le chat', 'die Katze'], ['le chien', 'der Hund'], ['la vache', 'die Kuh'], ['le cheval', 'das Pferd']]);
    const items = [];
    left.forEach(([t, d], i) => items.push(run_(50, 100 + i * PITCH, `${t} – ${d}`)));
    right.forEach(([t, d], i) => items.push(run_(320, 100 + i * PITCH, `${t} – ${d}`)));
    lines(items);
  }
  {
    const left = PAIRS.concat(MORE.slice(0, 4));
    const right = [['le chat', 'die Katze'], ['le chien', 'der Hund'], ['la vache', 'die Kuh'], ['le cheval', 'das Pferd'], ['la souris', 'die Maus'], ['le cochon', 'das Schwein']];
    for (const k of [6, 5, 3, 1]) {
      const items = [];
      left.forEach(([t, d], i) => items.push(run_(50, 100 + i * PITCH, `${t} – ${d}`)));
      right.slice(0, k).forEach(([t, d], i) => items.push(run_(320, 100 + i * PITCH, `${t} – ${d}`)));
      lines(items);
    }
  }
}

// ---------------------------------------------------------------------------
// 2. Vocabulary for synthetic pages (pairs from the web test fixtures)

const VOCAB = [...PAIRS, ...MORE, ...ROWS_22];
{
  const table = [
    ['quizlet-export.txt', '\t'],
    ['dash-hyphen.txt', ' - '],
    ['equals.txt', ' = '],
    ['semicolon.txt', ';'],
    ['german-first.txt', ' - '],
    ['english-german.txt', ' - '],
    ['italian.txt', ' = '],
    ['spanish.txt', /\s–\s/],
    ['four-cells.tsv', '\t'],
  ];
  for (const [file, delim] of table) {
    for (const line of readText(`tests/fixtures/${file}`).split(/\r?\n/)) {
      const cells = line.split(delim).map((c) => c.trim()).filter(Boolean);
      for (let i = 0; i + 1 < cells.length; i += 2) VOCAB.push([cells[i], cells[i + 1]]);
    }
  }
  const user = readText('tests/fixtures/user-example.txt').split(/\r?\n/).filter((l) => l.trim());
  for (let i = 0; i + 1 < user.length; i += 2) VOCAB.push([user[i].trim(), user[i + 1].trim()]);
}
const HEADINGS = ['Vocabulaire', 'Unité 3 – Les personnes', 'Wortschatz', 'Lektion 4', 'Les adjectifs du caractère',
  'Chapter 2: Family', 'Vocabolario', 'A. Les verbes', 'Seite 12', 'Les nombres'];
const SENTENCES = ['Le monsieur parle avec sa voisine.', 'La femme de Paul est très gentille.',
  'Le garçon joue au foot avec ses amis.', 'Nous allons au marché demain matin.', 'Il fait beau aujourd’hui à Paris.',
  'Elle ne trouve plus ses clés.', 'Der Hund schläft im Garten.', 'Ich habe keine Zeit, sorry.'];

const r2 = (v) => Math.round(v * 100) / 100;

// ---------------------------------------------------------------------------
// 3. Synthetic pages

const rng = mulberry32(0x5eed1a7);

function geometry() {
  const cw = pick(rng, [4, 5, 5.5, 6, 6, 6.5, 7, 8]);
  return {
    cw,
    h: r2(cw * (1.6 + rng() * 0.6)),
    perWord: chance(rng, 0.5),
    jitterY: chance(rng, 0.4) ? rng() * 3 : 0,
    jitterX: chance(rng, 0.2) ? rng() * 2 : 0,
    dropW: chance(rng, 0.1) ? 0.4 : 0,
    dropH: chance(rng, 0.1) ? 0.4 : 0,
    bold: chance(rng, 0.08) ? 0.15 : 0,
  };
}

function jitter(g, amount) {
  return amount ? (rng() * 2 - 1) * amount : 0;
}

function item(g, str, x, y, w, h) {
  const it = { str, x: r2(x), y: r2(y) };
  if (!(g.dropW && rng() < g.dropW)) it.w = r2(w);
  if (!(g.dropH && rng() < g.dropH)) it.h = r2(h);
  return it;
}

// One text cell at (x, y): per word (OCR boxes) or as one run (pdf text), with jitter.
function put(items, g, x, y, text) {
  const cw = g.cw;
  const h = g.h;
  const yy = y + jitter(g, g.jitterY);
  if (g.perWord) {
    let cx = x + jitter(g, g.jitterX);
    for (const w of text.split(' ')) {
      if (w) items.push(item(g, w, cx, yy + jitter(g, g.jitterY / 3), w.length * cw, h));
      cx += (w.length + 1) * cw;
    }
  } else {
    items.push(item(g, text, x + jitter(g, g.jitterX), yy, text.length * cw, h));
  }
  if (g.bold && rng() < g.bold) items.push(item(g, text, x + 0.3, yy, text.length * cw, h));
}

function vocab(n) {
  const start = randInt(rng, 0, VOCAB.length - 1);
  const out = [];
  for (let i = 0; i < n; i++) out.push(VOCAB[(start + i * randInt(rng, 1, 3)) % VOCAB.length]);
  return out;
}

function maybeShuffle(items) {
  if (!chance(rng, 0.3)) return items;
  const a = items.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

function decorate(items, g, top, bottom, right) {
  if (chance(rng, 0.25)) put(items, { ...g, cw: g.cw * 1.6, h: g.h * 1.8, perWord: true }, 40, top - g.h * 3, pick(rng, HEADINGS));
  if (chance(rng, 0.15)) put(items, { ...g, perWord: false }, right, bottom + g.h * 4, String(randInt(rng, 1, 240)));
}

// Splits a text at a random space (for wrapped cells), often right after a comma.
function wrapText(text) {
  const spaces = [];
  const afterComma = [];
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== ' ') continue;
    spaces.push(i);
    if (text[i - 1] === ',') afterComma.push(i);
  }
  if (!spaces.length) return null;
  const at = afterComma.length && chance(rng, 0.6) ? pick(rng, afterComma) : pick(rng, spaces);
  return [text.slice(0, at), text.slice(at + 1)];
}

// Two-column (or 2k-column) table with optional wrapped cells, numbering and section headings.
function tablePage() {
  const g = geometry();
  const groups = chance(rng, 0.25) ? 2 : 1;
  const n = randInt(rng, 2, chance(rng, 0.15) ? 30 : 12);
  const pitch = r2(g.h * (1.2 + rng() * 1.4));
  const colGap = randInt(rng, 120, 260);
  const groupGap = randInt(rng, 260, 400);
  const numbered = chance(rng, 0.15);
  const x0 = randInt(rng, 20, 60);
  const items = [];
  let maxY = 100;
  for (let gi = 0; gi < groups; gi++) {
    const list = vocab(gi === 0 ? n : randInt(rng, 1, n + 3));
    const xa = x0 + gi * groupGap + (numbered ? 30 : 0);
    let y = 100;
    list.forEach(([t, d], i) => {
      if (numbered && gi === 0) put(items, g, x0, y, `${i + 1}.`);
      if (chance(rng, 0.06)) {
        put(items, g, xa, y, pick(rng, HEADINGS));
        y += pitch * (1 + randInt(rng, 0, 2));
      }
      const wrapA = chance(rng, 0.15) ? wrapText(t) : null;
      const wrapB = chance(rng, 0.15) ? wrapText(d) : null;
      put(items, g, xa, y, wrapA ? wrapA[0] : t);
      put(items, g, xa + colGap, y, wrapB ? wrapB[0] : d);
      if (wrapA || wrapB) {
        const step = r2(pitch * (0.6 + rng() * 0.5));
        if (wrapA) put(items, g, xa, y + step, wrapA[1]);
        if (wrapB) put(items, g, xa + colGap, y + step, wrapB[1]);
        y += step;
      }
      y += pitch * (chance(rng, 0.05) ? 3 : 1) + jitter(g, chance(rng, 0.2) ? pitch * 0.15 : 0);
    });
    maxY = Math.max(maxY, y);
  }
  decorate(items, g, 100, maxY, x0 + groups * groupGap + colGap);
  lines(maybeShuffle(items));
}

// term | example sentence | translation (the sentence column is dropped)
function sentencePage() {
  const g = geometry();
  const items = [];
  const list = vocab(randInt(rng, 2, 8));
  const pitch = g.h * 1.6;
  list.forEach(([t, d], i) => {
    const y = 100 + i * pitch;
    put(items, g, 20, y, t);
    put(items, g, 170, y, pick(rng, SENTENCES));
    put(items, g, 170 + randInt(rng, 230, 300), y, d);
  });
  lines(maybeShuffle(items));
}

// Stacked "term / definition / gap" pairs in one or two page columns, or indented definitions.
function stackedPage() {
  const g = geometry();
  const items = [];
  const columns = chance(rng, 0.4) ? 2 : 1;
  const pitch = r2(g.h * (1.2 + rng() * 0.4));
  const indent = chance(rng, 0.2) ? randInt(rng, 20, 80) : 0;
  const gap = pick(rng, [1, 2, 3, 4, 5]);
  let maxY = 100;
  for (let c = 0; c < columns; c++) {
    let y = 100 + (c && chance(rng, 0.3) ? pitch / 2 : 0);
    for (const [t, d] of vocab(randInt(rng, 2, 10))) {
      put(items, g, 40 + c * 300, y, t);
      put(items, g, 40 + c * 300 + indent, y + pitch, d);
      y += pitch * (1 + gap) + jitter(g, chance(rng, 0.3) ? pitch * 0.4 : 0);
    }
    maxY = Math.max(maxY, y);
  }
  decorate(items, g, 100, maxY, 520);
  lines(maybeShuffle(items));
}

// Plain lines (one column or two unaligned text columns), random paragraph gaps.
function flowPage() {
  const g = geometry();
  const items = [];
  const columns = chance(rng, 0.35) ? 2 : 1;
  const pitch = r2(g.h * (1.1 + rng() * 1.2));
  for (let c = 0; c < columns; c++) {
    let y = 100 + (c ? r2(pitch * rng()) : 0);
    const n = randInt(rng, 1, 16);
    for (let i = 0; i < n; i++) {
      const [t, d] = pick(rng, VOCAB);
      put(items, g, 40 + c * randInt(rng, 260, 340), y, chance(rng, 0.5) ? t : d);
      y += pitch * (chance(rng, 0.12) ? randInt(rng, 2, 5) : 1);
    }
  }
  lines(maybeShuffle(items));
}

// "term – definition" entries in two page columns (the right one may end early).
function entryColumnsPage() {
  const g = { ...geometry(), perWord: chance(rng, 0.3) };
  const items = [];
  const pitch = r2(g.h * (1.2 + rng() * 0.5));
  const left = vocab(randInt(rng, 2, 12));
  const right = vocab(randInt(rng, 1, left.length));
  const sep = pick(rng, [' – ', ' - ', ' = ', ': ', ' — ']);
  left.forEach(([t, d], i) => put(items, g, 50, 100 + i * pitch, `${t}${sep}${d}`));
  right.forEach(([t, d], i) => put(items, g, randInt(rng, 300, 360), 100 + i * pitch, `${t}${sep}${d}`));
  lines(maybeShuffle(items));
}

// Monospace text: one run per row, columns separated by runs of spaces or tabs.
function monospacePage() {
  const items = [];
  const cw = pick(rng, [5, 6, 7]);
  const h = cw * 2;
  const width = randInt(rng, 14, 30);
  const n = randInt(rng, 2, 10);
  for (let i = 0; i < n; i++) {
    const [t, d] = pick(rng, VOCAB);
    const pad = Math.max(1, width - t.length);
    const text = chance(rng, 0.2) ? `${t}\t${d}` : `${t}${' '.repeat(pick(rng, [1, 2, 3, pad, pad]))}${d}`;
    items.push({ str: chance(rng, 0.2) ? `  ${text} ` : text, x: 10, y: 100 + i * (h + 4), w: text.length * cw, h });
  }
  lines(items, chance(rng, 0.3) ? { gapFactor: r2(0.5 + rng() * 4) } : undefined);
}

// Random soup: words anywhere, odd items, odd strings.
function soupPage() {
  const items = [];
  const n = randInt(rng, 0, 30);
  const odd = ['­', '​', ' ', ' ', '　', '\t', '  ', '   ', '﻿', ' ', '•', '1.', '(a)', 'a)', '–', '-', '*',
    '12', '(3)', 'B.', '…', '😀', 'ß', 'œ', 'L’', "l'", 'à', 'Über', 'ſich', 'K', 'DER', 'avec', 'und', 'de la', 'avec,'];
  for (let i = 0; i < n; i++) {
    const [t, d] = pick(rng, VOCAB);
    let str = chance(rng, 0.3) ? pick(rng, odd) : chance(rng, 0.5) ? t : d;
    if (chance(rng, 0.2)) str = pick(rng, odd) + str + pick(rng, odd);
    const it = { str, x: r2(rng() * 600), y: r2(80 + rng() * 400) };
    if (chance(rng, 0.8)) it.w = r2(str.length * (2 + rng() * 8));
    if (chance(rng, 0.8)) it.h = r2(6 + rng() * 18);
    if (chance(rng, 0.05)) it.w = -5;
    if (chance(rng, 0.05)) it.h = 0;
    items.push(it);
  }
  if (chance(rng, 0.3)) items.push(null, { str: null, x: 1, y: 1 }, { x: 3, y: 4 }, {}, { str: 'x', x: 'a', y: 2 });
  if (chance(rng, 0.2)) items.push({ str: 42, x: '120', y: ' 200.5px', w: '12', h: 'abc' }, { str: true, x: 300, y: '1e2' });
  lines(items, chance(rng, 0.2) ? pick(rng, [null, {}, { yTolerance: '0.3' }, { gapFactor: 'x' }, 'opts', 7]) : undefined);
}

// A skewed photo of a table: raw, deskewed with the true slope and with the estimated one.
function skewedPage() {
  const g = { ...geometry(), dropW: 0, dropH: 0, bold: 0 };
  const items = [];
  const list = vocab(randInt(rng, 2, 10));
  const pitch = r2(g.h * (1.6 + rng()));
  list.forEach(([t, d], i) => {
    put(items, g, 40, 100 + i * pitch, t);
    put(items, g, 40 + randInt(rng, 200, 360), 100 + i * pitch, d);
  });
  const s = r2((rng() * 2 - 1) * 0.12 * 1000) / 1000;
  const skewed = items.map((it) => ({ str: it.str, x: it.x, y: r2(it.y + it.x * s), w: it.w, h: it.h }));
  lines(skewed);
  lines(deskew(skewed, s));
  const segs = list.map((_, i) => {
    const y = 100 + i * pitch;
    const x1 = randInt(rng, 200, 600);
    return { x0: 40, y0: r2(y + 40 * s + jitter(g, 1)), x1, y1: r2(y + x1 * s + jitter(g, 1)) };
  });
  segs.push({ x0: 10, y0: 10, x1: 20, y1: 30 });
  slope(segs);
  const est = estimateSlope(segs);
  lines(deskew(skewed, est));
}

const FAMILIES = [
  [tablePage, 1100],
  [sentencePage, 150],
  [stackedPage, 450],
  [flowPage, 450],
  [entryColumnsPage, 400],
  [monospacePage, 200],
  [soupPage, 400],
  [skewedPage, 250],
];
for (const [family, n] of FAMILIES) for (let i = 0; i < n; i++) family();

// Option variations on a few fixed pages
{
  const pages = [
    table([...PAIRS, ...MORE], [40, 260], { perWord: true }),
    [run_(10, 100, 'le nom'), run_(200, 104, 'der Name'), run_(10, 118, 'la rue'), run_(200, 122, 'die Strasse')],
    [...words(10, 20, 'le nom'), ...words(10 + 9 * CW, 20, 'der Name')],
  ];
  const opts = [{ yTolerance: 0 }, { yTolerance: 0.01 }, { yTolerance: 0.2 }, { yTolerance: 1 }, { yTolerance: 2.5 },
    { yTolerance: -1 }, { gapFactor: 0 }, { gapFactor: 0.3 }, { gapFactor: 1 }, { gapFactor: 3 }, { gapFactor: 4 },
    { gapFactor: 10 }, { yTolerance: '0.2', gapFactor: '4' }, { yTolerance: 'abc' }, { yTolerance: null }, {}, null,
    [], 'x', 3, { yTolerance: 0.3, gapFactor: 1.5 }];
  for (const page of pages) for (const o of opts) lines(page, o);
}

// estimateSlope: random segment sets (short, steep, invalid and string coordinates)
for (let i = 0; i < 700; i++) {
  const n = randInt(rng, 0, 12);
  const s = (rng() * 2 - 1) * 0.5;
  const segs = [];
  for (let j = 0; j < n; j++) {
    const x0 = r2(rng() * 300);
    const x1 = r2(x0 + rng() * 500 - 50);
    const y0 = r2(50 + rng() * 600);
    const seg = { x0, y0, x1, y1: r2(y0 + (x1 - x0) * (chance(rng, 0.8) ? s : (rng() * 2 - 1))) };
    if (chance(rng, 0.05)) seg.y1 = null;
    if (chance(rng, 0.03)) seg.x0 = String(seg.x0);
    segs.push(chance(rng, 0.03) ? null : seg);
  }
  slope(segs, chance(rng, 0.3) ? { minWidth: pick(rng, [0, 5, 20, 40, 100, 250, -1]) } : undefined);
}

// deskewItems: slopes around the thresholds
{
  const base = table(PAIRS, [40, 300], { perWord: true, pitch: 20 });
  for (const s of [0, 1e-5, -1e-5, 1e-4, -1e-4, 0.0001001, 0.001, -0.02, 0.05, 0.1, -0.3, 0.5, -0.5, 0.5000001, 0.6, -2, 1, null]) {
    deskew(base, s);
  }
  for (let i = 0; i < 120; i++) {
    const items = [];
    const n = randInt(rng, 0, 12);
    for (let j = 0; j < n; j++) {
      items.push({ str: pick(rng, VOCAB)[0], x: r2(rng() * 600 - 50), y: r2(rng() * 800 - 50), w: r2(rng() * 120), h: r2(rng() * 20) });
    }
    deskew(items, r2((rng() * 2 - 1) * 0.6 * 1000) / 1000);
  }
}

cases.emit();
