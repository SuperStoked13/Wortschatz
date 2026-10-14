// Parity fixture for src/core/parser.js → Fixtures/parser.json.
// fn: parseVocab [text, opts?] → the whole result (cards with flags/confidence/lines, format,
// delimiter, termLang, defLang, swapped, skipped, warnings).
//
// Inputs:
//   1. every parseVocab call of tests/parser.test.js: the test source is evaluated with a recording
//      parseVocab and no-op assertions, so programmatically built inputs are captured exactly;
//   2. every tests/fixtures text under an options matrix (auto, lines, swap, orient, term/def
//      language hints, delimiter mode with many separators and card separators);
//   3. thousands of lists synthesised from the fixture pairs in many layouts (delimiters,
//      blank-line patterns, alternating, two-column OCR order, page columns, 3/4-cell rows, inline
//      lists, quoted CSV, bilingual lines, PDF gaps) with decorations (numbering, bullets, headings,
//      page numbers, header rows, URLs, wrapped lines, CRLF/BOM/NBSP, German first, reversed rows,
//      duplicates, missing sides, glued dashes, typographic quotes), plus targeted structures
//      (wrapped terms, number vocabulary, numbered table rows, uneven page columns, OCR columns
//      with misdetected lines, custom card separators);
//   4. hand-picked Unicode and regex edge cases and seeded fuzz text.
// Inputs that are not strings (tests only) are kept as JSON; the Swift test converts them with JS
// String() semantics. Identical (text, options) inputs are recorded once.
//
// No input contains astral LETTERS (e.g. U+1D400, CJK Extension B): JavaScriptCore's regex engine
// misses `\p{L}` matches that start on an astral letter right after a BMP letter the same class
// matched (`/\p{L}-$/u.test('x' + '\u{1D400}-')` is false, the spec says true). The Swift port
// follows the spec there. Astral non-letters (emoji, musical symbols) are covered.
import { parseVocab } from '../../Website/src/core/parser.js';
import { Cases, mulberry32, randInt, pick, chance, fixtureTexts, readText, REPO } from './lib.js';

const cases = new Cases('parser');
const seenInputs = new Set();

function parse(text, opts, withOpts = opts !== undefined) {
  const key = JSON.stringify([typeof text, text === undefined ? null : text, withOpts ? (opts === undefined ? '<undefined>' : opts) : '<none>']);
  if (seenInputs.has(key)) return;
  seenInputs.add(key);
  cases.add('parseVocab', withOpts ? [text, opts] : [text], parseVocab(text, opts));
}

// ---------------------------------------------------------------------------
// 1. tests/parser.test.js, replayed with a recording parseVocab

function replayTests() {
  let src = readText('tests/parser.test.js');
  src = src.replace(/^import .*$/gm, '').replace(/^await run\(.*$/gm, '');
  const tests = [];
  const test = (name, fn) => tests.push({ name, fn });
  const noop = () => {};
  const expect = () => {
    const api = new Proxy({}, { get: (_, k) => (k === 'not' ? api : noop) });
    return api;
  };
  let calls = 0;
  const recording = (...args) => {
    calls++;
    parse(args[0], args[1], args.length > 1);
    return parseVocab(...args);
  };
  const read = (path) => readFile(`${REPO}/tests/${path}`);
  const body = new Function('test', 'expect', 'parseVocab', 'readFile', src);
  body(test, expect, recording, read);
  for (const t of tests) {
    try {
      t.fn();
    } catch (e) {
      // Assertions are no-ops; anything thrown here is a generator bug.
      throw new Error(`replaying "${t.name}" failed: ${e && e.message}`);
    }
  }
  // Guards against a silent no-op replay if the test file changes shape.
  if (tests.length < 50 || calls < 1000) throw new Error(`replayed only ${tests.length} tests / ${calls} calls`);
}

replayTests();

// ---------------------------------------------------------------------------
// 2. Every fixture under an options matrix

const LANG_HINTS = ['fr', 'en', 'es', 'it', 'de', 'other'];
const DELIMITERS = ['\t', ' - ', '-', ' – ', '—', ' = ', '=', ':', ': ', ' : ', ';', ',', '|', ' | ', '->', '→', '  ', ' ', '\n', '::', '/', 'x'];

const OPTION_MATRIX = [
  undefined,
  {},
  { mode: 'auto' },
  { mode: 'lines' },
  { swap: true },
  { orient: false },
  { orient: false, swap: true },
  { mode: 'lines', swap: true },
  { mode: 'lines', termLang: 'fr', defLang: 'de' },
  ...LANG_HINTS.map((termLang) => ({ termLang })),
  ...LANG_HINTS.map((termLang) => ({ termLang, defLang: 'de' })),
  ...LANG_HINTS.map((termLang) => ({ termLang, defLang: 'fr' })),
  { defLang: 'en' },
  { defLang: null },
  { defLang: 'other' },
  { defLang: 'xx' },
  { termLang: 'it', defLang: 'es' },
  { termLang: 'en', defLang: 'en' },
  ...DELIMITERS.map((delimiter) => ({ mode: 'delimiter', delimiter })),
  { mode: 'delimiter' },
  { mode: 'delimiter', delimiter: '' },
  { mode: 'delimiter', delimiter: '\t', cardSeparator: '\n\n' },
  { mode: 'delimiter', delimiter: ' - ', cardSeparator: '\n\n' },
  { mode: 'delimiter', delimiter: '\n', cardSeparator: '\n\n' },
  { mode: 'delimiter', delimiter: '\n', cardSeparator: '\n\n\n' },
  { mode: 'delimiter', delimiter: ' \n ', cardSeparator: ';' },
  { mode: 'delimiter', delimiter: ' - ', cardSeparator: ';' },
  { mode: 'delimiter', delimiter: ',', cardSeparator: ';' },
  { mode: 'delimiter', delimiter: '\t', cardSeparator: '\r\n' },
  { mode: 'delimiter', delimiter: ' - ', cardSeparator: '\r' },
  { mode: 'delimiter', delimiter: ' - ', cardSeparator: '' },
  { mode: 'delimiter', delimiter: '-', swap: true, termLang: 'fr' },
  { mode: 'delimiter', delimiter: '\t', orient: false },
];

const FIXTURES = fixtureTexts();
for (const { text } of FIXTURES) {
  for (const opts of OPTION_MATRIX) parse(text, opts);
}

// ---------------------------------------------------------------------------
// 3. Synthesised lists

// Pair pools by language: the pairs the parser finds in the fixtures plus a few hand-made lists.
const POOLS = new Map();
function addPool(key, pairs) {
  const list = POOLS.get(key) || [];
  for (const [t, d] of pairs) {
    if (t && d && !list.some(([a, b]) => a === t && b === d)) list.push([t, d]);
  }
  POOLS.set(key, list);
}
for (const { text } of FIXTURES) {
  const r = parseVocab(text);
  if (r.termLang === 'other' || r.defLang === 'other') continue;
  addPool(`${r.termLang}-${r.defLang}`, r.cards.filter((c) => !c.flags.length).map((c) => [c.term, c.definition]));
}
addPool('fr-de', [
  ['attendre', 'warten'], ['oublier', 'vergessen'], ['essayer', 'versuchen'], ['chanter', 'singen'], ['danser', 'tanzen'],
  ['grandir', 'wachsen'], ['perdre', 'verlieren'], ['gagner', 'gewinnen'], ['peindre', 'malen'], ['écrire', 'schreiben'],
  ['se mettre en colère', 'wütend werden'], ['avoir lieu', 'stattfinden'], ['faire la grasse matinée', 'ausschlafen'],
  ["s'entendre avec qn", 'sich mit jdm verstehen'], ['se brosser les dents', 'sich die Zähne putzen'],
  ["Comment allez-vous aujourd'hui ?", 'Wie geht es Ihnen heute?'], ["J'ai faim", 'Ich habe Hunger'],
  ['Où habites-tu ?', 'Wo wohnst du?'], ['plein, pleine', 'voll'], ['serein, sereine', 'gelassen'],
  ['la relation mère-fille', 'die Mutter-Tochter-Beziehung'], ['le week-end', 'das Wochenende'], ['là-bas', 'dort'],
  ['intelligent, intelligente', 'intelligent'], ['le sport', 'der Sport'], ['la radio', 'das Radio'],
  ['le monsieur, messieurs', 'der Herr, die Herren'], ['beau, bel, belle', 'schön'], ['le taille-crayon', 'der Spitzer'],
  ['onze', '11'], ['douze', '12'], ['vingt et un', '21'], ['cent', '100'],
]);
addPool('en-de', [
  ['the dog', 'der Hund'], ['the cat', 'die Katze'], ['the house', 'das Haus'], ['homework', 'Hausaufgaben'],
  ['lesson', 'Lektion'], ['newspaper', 'Zeitung'], ['to look for sth', 'etw. suchen'], ['The weather is nice today', 'Das Wetter ist heute schön'],
  ['Thank you very much', 'Vielen Dank'], ['to take care of sb', 'sich um jdn. kümmern'], ['opinion', 'Meinung'], ['source', 'Quelle'],
]);
addPool('es-de', [['el perro', 'der Hund'], ['la casa', 'das Haus'], ['hablar', 'sprechen'], ['¿Qué tal?', "Wie geht's?"], ['el niño', 'das Kind']]);
addPool('it-de', [['il cane', 'der Hund'], ['gli amici', 'die Freunde'], ['la città', 'die Stadt'], ['perché', 'warum'], ['mangiare', 'essen']]);
const POOL_KEYS = [...POOLS.keys()].sort();

const HEADINGS = [
  'Unité 3 - Les animaux', 'Vocabulaire', 'Lektion 4', 'Les couleurs', 'Les couleurs:', 'Adjectifs', 'B) Couleurs et formes',
  'Wortschatz Unité 3', 'Vocabulaire : les animaux', 'Chapitre II', 'LES ANIMAUX', 'A', 'Thème 2', 'Section 1.2', 'Unit 5',
  'Les nombres', 'Kapitel IV', 'Module', 'Glossaire', 'ÉTAPE 3', 'Dossier 1 : la famille',
];
const PAGE_NUMBERS = ['Seite 3', '- 12 -', '12', 'Page 4 / 10', 'p. 7', 's. 12', 'pag. 3', 'página 5', '3 von 9', 'Seite 2 sur 4', '7 -'];
const HEADER_ROWS = [
  'Französisch | Deutsch', 'Begriff - Definition', 'FR\tDE', 'Deutsch - Französisch', 'Wort\tÜbersetzung', 'Französisch\tDeutsch',
  'Englisch - Deutsch', 'FR | DE', 'Vokabel | Bedeutung', 'Question;Answer', 'Spanisch = Deutsch',
];
const NOISE = ['www.example.com', 'https://klett.de/vokabeln', '© Klett 2020', '(c) Cornelsen', '***', '---', '12345', '...', '•', '#'];
const MARKERS = ['1. ', '1) ', '(1) ', 'a) ', '• ', '- ', '* ', '1 - ', '12\t', '▪ ', '> ', '1: ', '+ '];
const DELIMS = [' - ', ' – ', ' — ', '\t', ' = ', '=', ': ', ' : ', ';', ' | ', '|', ' -> ', ' → ', ' => ', ',', '–', '-', ' ', '\t\t', ' ; '];
const EXAMPLES = ['Le chat dort sur le lit.', 'Je travaille dans le jardin.', 'Il fait beau aujourd\'hui.', 'Nomen, m.', 'Nomen, f.', 'Verb', 'Adj.'];

function sample(rng, list, n) {
  const pool = list.slice();
  const out = [];
  while (out.length < n && pool.length) out.push(pool.splice(Math.floor(rng() * pool.length), 1)[0]);
  return out;
}

function decorateQuotes(rng, s) {
  const q = pick(rng, [['"', '"'], ['“', '”'], ['„', '“'], ['«', '»'], ['« ', ' »'], ['‹', '›'], ["'", "'"]]);
  return q[0] + s + q[1];
}

function wrapSide(rng, s) {
  const words = s.split(' ');
  if (words.length < 2) return [s];
  const k = randInt(rng, 1, words.length - 1);
  return [words.slice(0, k).join(' '), words.slice(k).join(' ')];
}

function layoutLines(rng, pairs, layout, style) {
  const lines = [];
  const quote = chance(rng, 0.08);
  const q = (s) => (quote ? decorateQuotes(rng, s) : s);
  const marker = style.markers ? pick(rng, MARKERS) : null;
  const numberLines = style.markers && chance(rng, 0.5);
  switch (layout) {
    case 'delimited': {
      const mixed = chance(rng, 0.15);
      let delim = pick(rng, DELIMS);
      pairs.forEach(([t, d], i) => {
        if (mixed) delim = pick(rng, DELIMS);
        let line = `${q(t)}${delim}${q(d)}`;
        if (marker) line = (numberLines ? `${i + 1}${marker.slice(1)}` : marker) + line;
        if (style.wrap && chance(rng, 0.12)) {
          const [a, b] = wrapSide(rng, d);
          if (b) {
            lines.push(`${q(t)}${delim}${a}${chance(rng, 0.5) ? ',' : ''}`);
            lines.push((chance(rng, 0.5) ? '   ' : '') + b);
            return;
          }
        }
        lines.push(line);
      });
      break;
    }
    case 'alternating':
    case 'blocks': {
      const blank = layout === 'blocks' ? pick(rng, [1, 1, 2, 3, 5]) : 0;
      const irregular = chance(rng, 0.2);
      pairs.forEach(([t, d], i) => {
        const tl = style.wrap && chance(rng, 0.1) ? wrapSide(rng, t) : [t];
        const dl = style.wrap && chance(rng, 0.1) ? wrapSide(rng, d) : [d];
        if (marker && !numberLines) tl[0] = marker + tl[0];
        lines.push(...tl.map(q), ...dl.map(q));
        const gap = irregular ? randInt(rng, 0, 3) : blank;
        if (i < pairs.length - 1) for (let k = 0; k < gap; k++) lines.push(chance(rng, 0.1) ? ' \t ' : '');
      });
      break;
    }
    case 'columns': {
      const pages = chance(rng, 0.3) ? 2 : 1;
      const per = Math.ceil(pairs.length / pages);
      for (let p = 0; p < pages; p++) {
        const chunk = pairs.slice(p * per, (p + 1) * per);
        lines.push(...chunk.map(([t]) => t));
        if (chance(rng, 0.5)) lines.push('');
        const defs = chunk.map(([, d]) => d);
        if (chance(rng, 0.15)) defs.pop();
        lines.push(...defs);
        if (p < pages - 1) lines.push('');
      }
      break;
    }
    case 'inline': {
      const sep = pick(rng, ['; ', ';', ', ']);
      const inner = pick(rng, [' - ', ' = ', '-', ': ', ' – ']);
      const perLine = randInt(rng, 2, 6);
      for (let i = 0; i < pairs.length; i += perLine) {
        lines.push(pairs.slice(i, i + perLine).map(([t, d]) => `${t}${inner}${d}`).join(sep));
      }
      break;
    }
    case 'pageColumns': {
      const sep = pick(rng, ['\t', '        ', '      ', '\t\t']);
      const inner = pick(rng, [' – ', ' - ', '=', ' = ', ': ']);
      const h = Math.ceil(pairs.length / 2);
      for (let i = 0; i < h; i++) {
        const [t, d] = pairs[i];
        const right = pairs[i + h];
        lines.push(right ? `${t}${inner}${d}${sep}${right[0]}${inner}${right[1]}` : `${t}${inner}${d}`);
      }
      break;
    }
    case 'threeCells': {
      const kind = pick(rng, ['example', 'label', 'form', 'klett', 'english']);
      pairs.forEach(([t, d], i) => {
        if (kind === 'example') lines.push(`${t}\t${d}\t${pick(rng, EXAMPLES.slice(0, 3))}`);
        else if (kind === 'label') lines.push(`${t}\t${d}\t${pick(rng, EXAMPLES.slice(3))}`);
        else if (kind === 'form') lines.push(`${t}\t${t}s\t${d}`);
        else if (kind === 'klett') lines.push(`${t}\t${pick(rng, EXAMPLES.slice(0, 3))}\t${d}`);
        else lines.push(`${pick(rng, ['cat', 'dog', 'house', 'cow', 'tree'])}${i}\t${t}\t${d}`);
      });
      break;
    }
    case 'fourCells': {
      for (let i = 0; i < pairs.length; i += 2) {
        const [t, d] = pairs[i];
        const next = pairs[i + 1];
        lines.push(next ? `${t}\t${d}\t${next[0]}\t${next[1]}` : `${t}\t${d}`);
      }
      break;
    }
    case 'csv': {
      const delim = pick(rng, [',', ';']);
      pairs.forEach(([t, d]) => {
        const f = (s) => (s.includes(delim) || s.includes('"') || chance(rng, 0.3) ? `"${s.replace(/"/g, '""')}"` : s);
        lines.push(`${f(t)}${delim}${f(d)}`);
      });
      break;
    }
    case 'quizletComma': {
      pairs.forEach(([t, d]) => lines.push(`${t},${d}`));
      break;
    }
    case 'bilingual': {
      pairs.forEach(([t, d]) => lines.push(`${t} ${d}`));
      break;
    }
    case 'gap': {
      const width = randInt(rng, 24, 40);
      pairs.forEach(([t, d]) => lines.push(`${t}${' '.repeat(Math.max(2, width - t.length))}${d}`));
      break;
    }
    default:
      throw new Error(`unknown layout ${layout}`);
  }
  return lines;
}

const LAYOUTS = [
  'delimited', 'delimited', 'delimited', 'alternating', 'alternating', 'blocks', 'blocks', 'columns', 'inline',
  'pageColumns', 'threeCells', 'fourCells', 'csv', 'quizletComma', 'bilingual', 'gap',
];

function insertAt(rng, lines, item) {
  lines.splice(randInt(rng, 0, lines.length), 0, item);
}

function synthesise(rng) {
  const key = pick(rng, POOL_KEYS);
  const pool = POOLS.get(key);
  const n = randInt(rng, 1, Math.min(pool.length, chance(rng, 0.1) ? 60 : 14));
  let pairs = sample(rng, pool, n);
  const germanFirst = chance(rng, 0.15);
  if (germanFirst) pairs = pairs.map(([t, d]) => [d, t]);
  if (pairs.length > 3 && chance(rng, 0.08)) {
    const i = randInt(rng, 0, pairs.length - 1);
    pairs[i] = [pairs[i][1], pairs[i][0]]; // one reversed row
  }
  if (pairs.length > 2 && chance(rng, 0.08)) pairs.push(pairs[randInt(rng, 0, pairs.length - 1)]); // duplicate
  if (pairs.length > 2 && chance(rng, 0.06)) {
    const i = randInt(rng, 0, pairs.length - 1);
    pairs[i] = chance(rng, 0.5) ? [pairs[i][0], ''] : ['', pairs[i][1]]; // missing side
  }
  const layout = pick(rng, LAYOUTS);
  const style = { markers: chance(rng, 0.15), wrap: chance(rng, 0.2) };
  const lines = layoutLines(rng, pairs, layout, style);
  if (chance(rng, 0.2)) lines.unshift(pick(rng, HEADINGS));
  if (chance(rng, 0.12)) lines.unshift(pick(rng, HEADER_ROWS));
  if (chance(rng, 0.15)) insertAt(rng, lines, pick(rng, HEADINGS));
  if (chance(rng, 0.15)) insertAt(rng, lines, pick(rng, PAGE_NUMBERS));
  if (chance(rng, 0.1)) lines.push(pick(rng, PAGE_NUMBERS));
  if (chance(rng, 0.08)) insertAt(rng, lines, pick(rng, NOISE));
  if (chance(rng, 0.08)) insertAt(rng, lines, '');
  let text = lines.join('\n');
  if (chance(rng, 0.1)) text = text.replace(/\n/g, '\r\n');
  if (chance(rng, 0.05)) text = text.replace(/\n/g, '\r');
  if (chance(rng, 0.08)) text = `\uFEFF${text}`;
  if (chance(rng, 0.08)) text = text.replace(/ - /g, '\u00A0-\u00A0');
  if (chance(rng, 0.06)) text = text.replace(/'/g, '’');
  if (chance(rng, 0.05)) text = text.replace(/ /g, () => (chance(rng, 0.1) ? '  ' : ' '));
  if (chance(rng, 0.05)) text = text.replace(/\n/g, () => (chance(rng, 0.2) ? ' \n' : '\n'));
  if (chance(rng, 0.05)) text = text.normalize('NFD');
  if (chance(rng, 0.1)) text += '\n';
  let opts;
  const r = rng();
  if (r < 0.55) opts = undefined;
  else if (r < 0.65) opts = { termLang: pick(rng, LANG_HINTS), defLang: pick(rng, ['de', 'de', 'fr', 'en']) };
  else if (r < 0.72) opts = { mode: 'lines' };
  else if (r < 0.78) opts = { swap: true };
  else if (r < 0.82) opts = { orient: false };
  else if (r < 0.94) opts = { mode: 'delimiter', delimiter: pick(rng, DELIMITERS), cardSeparator: pick(rng, ['\n', '\n', '\n\n', ';']) };
  else opts = { termLang: key.split('-')[0], defLang: key.split('-')[1] };
  parse(text, opts);
}

{
  const rng = mulberry32(20261012);
  for (let i = 0; i < 2200; i++) synthesise(rng);
}

// Structures that random synthesis rarely produces: wrapped terms before a delimited line, many
// duplicates and unpaired lines (warning lists), unknown first columns of 3-cell rows, number
// vocabulary, numbered table rows, headings between alternating entries, uneven page columns,
// OCR columns with misdetected lines, and the matching explicit delimiter mode.
function special(rng) {
  const pool = POOLS.get(pick(rng, ['fr-de', 'fr-de', 'en-de', 'es-de', 'it-de']));
  const pairs = sample(rng, pool, randInt(rng, 3, Math.min(pool.length, 18)));
  const kind = randInt(rng, 0, 11);
  let lines = [];
  let opts;
  switch (kind) {
    case 0: { // wrapped term before a delimited line
      const delim = pick(rng, [' - ', '\t', ' = ', ': ']);
      pairs.forEach(([t, d]) => {
        if (chance(rng, 0.3)) lines.push(pick(rng, ['la maison de', 'le livre du', 'avoir envie de', 'se souvenir de', 'the house of', 'la chica de']));
        lines.push(`${t}${delim}${d}`);
      });
      break;
    }
    case 1: { // many duplicates
      const dup = pairs.slice(0, randInt(rng, 1, Math.min(6, pairs.length)));
      lines = [...pairs, ...dup, ...dup.map(([t, d]) => [`${t.toUpperCase()} .`, d])].map(([t, d]) => `${t} - ${d}`);
      break;
    }
    case 2: { // many unpaired lines
      pairs.forEach(([t, d]) => {
        lines.push(t, d);
        if (chance(rng, 0.5)) lines.push(pick(rng, pool)[0]);
      });
      break;
    }
    case 3: { // 3-cell rows with an unknown or numeric first column
      pairs.forEach(([t, d], i) => lines.push(`${pick(rng, ['#', '§', 'Nr.', '*'])}${i + 1}\t${t}\t${d}`));
      break;
    }
    case 4: { // number vocabulary
      const nums = [['un', 1], ['deux', 2], ['trois', 3], ['quatre', 4], ['cinq', 5], ['six', 6], ['sept', 7], ['huit', 8], ['neuf', 9], ['dix', 10], ['onze', 11], ['douze', 12]];
      const sel = sample(rng, nums, randInt(rng, 3, 10));
      const style = randInt(rng, 0, 3);
      for (const [w, n] of sel) {
        if (style === 0) lines.push(`${n} - ${w}`);
        else if (style === 1) lines.push(w, String(n));
        else if (style === 2) lines.push(String(n), w);
        else lines.push(`${n}: ${w}`);
      }
      break;
    }
    case 5: { // numbered table rows ("1" / row)
      const fmt = pick(rng, [(t, d) => `${t} - ${d}`, (t, d) => `${t}\t${d}`, (t, d) => `${t}\n${d}`, (t, d) => `${t} ${d}`]);
      pairs.forEach(([t, d], i) => lines.push(String(i + 1), fmt(t, d)));
      break;
    }
    case 6: { // a heading inside an alternating list
      const at = randInt(rng, 1, pairs.length - 1);
      pairs.forEach(([t, d], i) => {
        if (i === at) lines.push(pick(rng, ['Les couleurs', 'Couleurs', 'Adjectifs', 'B) Couleurs et formes', 'Les couleurs:', 'I. Verbes', 'Les nombres', 'Gli animali', 'Los colores']));
        lines.push(t, d);
      });
      break;
    }
    case 7: { // uneven page columns
      const sep = pick(rng, ['\t', '        ']);
      const inner = pick(rng, [' – ', '=', ' - ']);
      const h = randInt(rng, Math.ceil(pairs.length / 2), pairs.length - 1);
      for (let i = 0; i < h; i++) {
        const right = pairs[h + i];
        const left = `${pairs[i][0]}${inner}${pairs[i][1]}`;
        lines.push(right ? (chance(rng, 0.1) ? `${sep}${right[0]}${inner}${right[1]}` : `${left}${sep}${right[0]}${inner}${right[1]}`) : left);
      }
      break;
    }
    case 8: { // OCR columns with a misplaced or cognate line
      const terms = pairs.map(([t]) => t);
      const defs = pairs.map(([, d]) => d);
      if (chance(rng, 0.5)) terms.splice(randInt(rng, 0, terms.length), 0, pick(rng, ['charmant', 'intelligent', 'le sport', 'la radio']));
      if (chance(rng, 0.5)) defs.push(pick(rng, ['charmant', 'Sport', 'Radio']));
      lines = chance(rng, 0.5) ? [...terms, ...defs] : [...terms, '', ...defs];
      break;
    }
    case 9: { // explicit delimiter mode with the delimiter of the list
      const delim = pick(rng, [' - ', '\t', '=', ';', ',', '|', ' : ', ' -> ']);
      pairs.forEach(([t, d]) => lines.push(`${t}${delim}${d}`));
      opts = { mode: 'delimiter', delimiter: chance(rng, 0.5) ? delim : delim.trim() || delim };
      break;
    }
    case 10: { // records separated by a custom card separator
      const sep = pick(rng, [';', ' | ', '\n\n', '#']);
      const delim = pick(rng, [' - ', '\n', ' = ', ',']);
      const text = pairs.map(([t, d]) => `${t}${delim}${d}`).join(sep + (chance(rng, 0.3) ? '\n' : ''));
      parse(text, { mode: 'delimiter', delimiter: delim, cardSeparator: sep });
      return;
    }
    default: { // German written first with a term hint, or two header rows
      if (chance(rng, 0.5)) lines.push(pick(rng, HEADER_ROWS), pick(rng, HEADER_ROWS));
      pairs.forEach(([t, d]) => lines.push(`${d} - ${t}`));
      opts = chance(rng, 0.5) ? { termLang: pick(rng, LANG_HINTS) } : { defLang: pick(rng, ['fr', 'de', 'en', null]) };
    }
  }
  parse(lines.join('\n'), opts);
}

{
  const rng = mulberry32(777);
  for (let i = 0; i < 900; i++) special(rng);
}

// Long lists (performance-sized inputs).
{
  const rng = mulberry32(500);
  const pool = POOLS.get('fr-de');
  for (const layout of ['delimited', 'blocks', 'alternating', 'columns', 'bilingual', 'pageColumns']) {
    const pairs = [];
    while (pairs.length < 220) pairs.push(...sample(rng, pool, Math.min(pool.length, 220 - pairs.length)));
    parse(layoutLines(rng, pairs, layout, { markers: false, wrap: false }).join('\n'));
  }
}

// ---------------------------------------------------------------------------
// 4. Edge cases and fuzz

const EDGE = [
  // Case folding of /iu regexes (long s, Kelvin sign, Latin-1 capitals) and non-u /i.
  'ſeite 3\nle chat - die Katze\nle chien - der Hund',
  'PAGE 4\nle chat - die Katze\nle chien - der Hund',
  'PÁGINA 5\nel perro - der Hund\nla casa - das Haus',
  'Kapitel 3\nle chat - die Katze\nle chien - der Hund',
  'WWW.KLETT.DE\nle chat - die Katze\nle chien - der Hund',
  'ſ\'il te plaît - bitte\nle chat - die Katze',
  'LE CHAT\nDIE KATZE\nLE CHIEN\nDER HUND',
  'UNITÉ 4\nle chat - die Katze\nle chien - der Hund',
  'Unités\nle chat - die Katze\nle chien - der Hund',
  // Greek final sigma, Turkish dotted I, astral letters, emoji, combining marks, zero-width.
  'ΟΔΟΣ - die Strasse\nΣΟΦΙΑ - die Weisheit\nle chat - die Katze',
  'İSTANBUL - Istanbul\nle chat - die Katze\nle chien - der Hund',
  '🐱-b c-🐶\nle chat-die Katze\nle chien-der Hund\n𝄞 - der Notenschlüssel',
  'le chat 🐱 - die Katze\nle chien 🐶 - der Hund\n🐴\nle cheval - das Pferd',
  'e\u0301te\u0301 - der Sommer\nle chat - die Katze',
  'le\u200B chat - die\u2060 Katze\nle chien\uFEFF - der Hund',
  'le chat\u2028die Katze\u2029le chien\u0085der Hund\u000Bla vache\u000Cdie Kuh',
  'le chat\u2003-\u2003die Katze\nle chien\u3000-\u3000der Hund',
  // Quotes, CSV and borders.
  '"le chat","die Katze"\n"le ""bon"" vin","der Wein"\n"unterminated,die Katze',
  '"a\n"b\n"c',
  '| le chat | die Katze |\n|---|---|\n| le chien | der Hund |',
  '« le chat » ; « die Katze »\n« le chien » ; « der Hund »\n« la vache » ; « die Kuh »',
  // Markers and numbering.
  '1.\tle chat\tdie Katze\n2.\tle chien\tder Hund\n3.\tla vache\tdie Kuh',
  '(a) le chat - die Katze\n(b) le chien - der Hund\n(c) la vache - die Kuh',
  '1234\tle chat\n12\tle chien - der Hund\n7)\tla vache\tdie Kuh',
  '1 -  le chat - die Katze\n2 -\tle chien - der Hund\n3- la vache - die Kuh',
  'IV. Les animaux\nle chat\ndie Katze\nle chien\nder Hund',
  // Wrapped lines and joins.
  'le chat - die Katze,\nder Kater\nle chien - der Hund\nla souris - die Maus;\n(f)',
  'le grand-\npère\nder Gross-\nvater\nle chat\ndie Katze',
  'faire la grasse\nmatinée\nausschlafen\n\nle chat\ndie Katze\n\nle chien\nder Hund',
  // Numbers and pages.
  '1\n2\n3\n4\n5',
  'Seite 1 von 3\n- 2 -\npage 3 / 4\np.5\ns. 6',
  '11\nonze\n12\ndouze\n13\ntreize\n14',
  // Header rows and labels.
  'Begriff\tDefinition\nle chat\tdie Katze\nle chien\tder Hund',
  'Spanisch - Deutsch\nel perro - der Hund\nla casa - das Haus',
  'FR DE\nle chat - die Katze\nle chien - der Hund',
  'Wort Wort\nle chat - die Katze',
  // Delimiters at the edges.
  '- die Katze\nle chien -\n= das Pferd\nla vache =',
  ':: :: ::\n;;;\n|||\n===\n - - - ',
  '\t\t\tle chat\t\t\tdie Katze\t\t\t\n\tle chien\t\tder Hund\t',
  // Markers that hold the only letters, codes mixed with names.
  'a) 12\n(b) 3.5\nle chat - die Katze\nle chien - der Hund',
  'FR - Deutsch\nle chat - die Katze\nle chien - der Hund',
  'FR FR\nle chat - die Katze',
  'Begriff Begriff\nle chat - die Katze',
];
for (const text of EDGE) {
  parse(text);
  parse(text, { mode: 'lines' });
  parse(text, { mode: 'delimiter', delimiter: ' - ' });
}

{
  const rng = mulberry32(4242);
  const ALPHABET = [
    'a', 'é', 'ü', 'ö', 'ß', 'ç', 'Der ', 'die ', 'le ', 'la ', 'the ', 'el ', 'il ', '\t', '\n', '\n\n', ' ', '  ', '-', ' - ', '"',
    ',', ';', '|', '=', '1', '12', '.', '–', '—', '\u00A0', '\r', '(', ')', '*', '•', '¿', ':', '→', '->', 'Seite ', 'x', 'Z',
    'chat', 'Katze', 'chien', 'Hund', 'maison', 'Haus', 'vache', 'Kuh', 'school', 'Schule', 'perro', 'cane', '«', '»', '’', "'",
    'É', 'Ü', 'II', 'IV', 'www.', 'http://', '©', '\uFEFF', '\u2028', '\u200B', '𝄞', '🐱', 'Σ', 'ς', 'İ', 'ſ', 'K', 'e\u0301',
    'Vocabulaire', 'Lektion', 'unit', 'jdm ', 'sich ', 'etw ', '?', '!', '…', '/', '<->', '=>', '  \t', '---',
  ];
  const OPTS = [
    undefined, { mode: 'lines' }, { mode: 'delimiter', delimiter: ' - ', cardSeparator: ';' }, { termLang: 'fr' },
    { mode: 'delimiter', delimiter: '\n', cardSeparator: '\n\n' }, { swap: true, defLang: 'fr' },
  ];
  for (let i = 0; i < 700; i++) {
    let s = '';
    const len = randInt(rng, 0, chance(rng, 0.1) ? 600 : 160);
    for (let k = 0; k < len; k++) s += pick(rng, ALPHABET);
    parse(s, pick(rng, OPTS));
  }
  // Word salad from the pools (realistic tokens, random structure).
  const words = [...POOLS.values()].flat(2).flatMap((s) => s.split(' '));
  const SEPS = [' ', ' ', ' ', '\n', '\n', ' - ', '\t', '; ', ', ', '\n\n', ' = '];
  for (let i = 0; i < 500; i++) {
    let s = '';
    const len = randInt(rng, 1, 40);
    for (let k = 0; k < len; k++) s += pick(rng, words) + pick(rng, SEPS);
    parse(s, pick(rng, OPTS));
  }
}

cases.emit();
