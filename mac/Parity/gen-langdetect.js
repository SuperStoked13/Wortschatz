// Parity fixture for src/core/langdetect.js → Fixtures/langdetect.json.
// fns: scoreLanguages [text], detectLanguage [text], detectColumn [lines]
//
// Inputs: every string literal of tests/langdetect.test.js and tests/parser.test.js (plus their
// lines and cells), every line / cell / column of every tests/fixtures file, every lexicon word of
// the module (plain, capitalised, upper case, with articles), cognates, mixed lines, odd input
// (non-strings, astral letters, Object.prototype keys, > 4000 UTF-16 units), seeded word salads and
// Arabic / Chinese / pinyin text and columns.
import { SUPPORTED, scoreLanguages, detectLanguage, detectColumn } from '../../Website/src/core/langdetect.js';
import { Cases, mulberry32, randInt, pick, chance, fixtureTexts, readText } from './lib.js';

const cases = new Cases('langdetect');

// ---------------------------------------------------------------------------
// Recording (deduplicated: every distinct input is recorded once per fn)

const seenText = new Set();
function text(s) {
  const key = `${typeof s}:${JSON.stringify(s)}`;
  if (seenText.has(key)) return;
  seenText.add(key);
  cases.add('scoreLanguages', [s], scoreLanguages(s));
  cases.add('detectLanguage', [s], detectLanguage(s));
}

const seenColumn = new Set();
function column(lines) {
  const key = JSON.stringify(lines === undefined ? null : lines);
  if (seenColumn.has(key)) return;
  seenColumn.add(key);
  cases.add('detectColumn', [lines], detectColumn(lines));
}

const lines = (s) => s.split(/\r\n|\r|\n/);
const nonEmptyLines = (s) => lines(s).filter((l) => l.trim());

// Cells of one line, split at the first delimiter that occurs (like the web tests do per fixture).
const DELIMITERS = ['\t', ' = ', ' - ', ' – ', ' — ', ';', ' : ', /\s{2,}/, '|', ','];
function cellsOf(line) {
  for (const d of DELIMITERS) {
    const parts = line.split(d);
    if (parts.length > 1) return parts;
  }
  return [line];
}

// Every line and cell of a multi-line text, plus its left / right / alternating columns.
function textBlock(s) {
  text(s);
  const all = nonEmptyLines(s);
  for (const line of lines(s)) {
    text(line);
    for (const cell of cellsOf(line)) {
      text(cell);
      text(cell.trim());
    }
  }
  if (all.length < 2) return;
  const rows = all.map(cellsOf);
  column(rows.map((r) => r[0]));
  column(rows.filter((r) => r.length > 1).map((r) => r[1]));
  column(rows.flatMap((r) => r.filter((_, i) => i % 2 === 0)));
  column(rows.flatMap((r) => r.filter((_, i) => i % 2 === 1)));
  column(all.filter((_, i) => i % 2 === 0));
  column(all.filter((_, i) => i % 2 === 1));
  column(all);
  for (let i = 0; i < all.length; i += 8) column(all.slice(i, i + 8));
}

// ---------------------------------------------------------------------------
// String literals of a JS source file (comments, regex literals and templates with
// substitutions are skipped; escapes are decoded with eval).

function stringLiterals(src) {
  const out = [];
  const n = src.length;
  let prev = '';
  let i = 0;
  while (i < n) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '/') {
      while (i < n && src[i] !== '\n') i++;
      continue;
    }
    if (c === '/' && src[i + 1] === '*') {
      i = src.indexOf('*/', i + 2) + 2;
      continue;
    }
    if (c === "'" || c === '"' || c === '`') {
      let j = i + 1;
      let substitution = false;
      while (j < n && src[j] !== c) {
        if (src[j] === '\\') {
          j += 2;
          continue;
        }
        if (c === '`' && src[j] === '$' && src[j + 1] === '{') {
          substitution = true;
          let depth = 0;
          do {
            if (src[j] === '{') depth++;
            else if (src[j] === '}') depth--;
            j++;
          } while (j < n && depth > 0);
          continue;
        }
        j++;
      }
      if (!substitution) out.push((0, eval)(src.slice(i, j + 1)));
      i = j + 1;
      prev = 'x';
      continue;
    }
    if (c === '/' && (prev === '' || '(,=:[!&|?{};'.includes(prev))) {
      // Regex literal
      let j = i + 1;
      let inClass = false;
      while (j < n) {
        if (src[j] === '\\') j += 2;
        else if (src[j] === '[') (inClass = true), j++;
        else if (src[j] === ']') (inClass = false), j++;
        else if (src[j] === '/' && !inClass) break;
        else j++;
      }
      j++;
      while (j < n && /[a-z]/.test(src[j])) j++;
      i = j;
      prev = 'x';
      continue;
    }
    if (!/\s/.test(c)) prev = c;
    i++;
  }
  return out;
}

// ---------------------------------------------------------------------------
// 1. tests/langdetect.test.js: every literal, plus the columns the tests build

for (const s of stringLiterals(readText('tests/langdetect.test.js'))) textBlock(s);
for (const input of ['', '   ', '123 - 456', '!!!', null, undefined, 42, {}, [], '\t\n', '12 / 40', '  12 - 13 !! ']) text(input);

const readFixture = (name) => readText(`tests/fixtures/${name}`);
{
  const user = nonEmptyLines(readFixture('user-example.txt'));
  column(user.filter((_, i) => i % 2 === 0));
  column(user.filter((_, i) => i % 2 === 1));
  for (const l of user) text(l);

  column(['la rana', 'el paraguas', 'estrecho', 'la vela', 'el martillo', 'la calabaza', 'mudarse', 'la niebla',
    'limpiar', 'sin embargo', 'la rodilla', 'el cepillo de dientes', 'charlar', 'la carnicería']);
  column(['la rana', "l'ombrello", 'stretto', 'la candela', 'il martello', 'la zucca', 'traslocare', 'la nebbia',
    'pulire', 'tuttavia', 'il ginocchio', 'lo spazzolino', 'chiacchierare', 'la macelleria']);
  column(['le chat', 'le chien', 'la souris', 'the cat', 'le lapin', 'la vache', 'le cheval', 'brave', 'sage']);
  column(['der Hund', 'still', 'die Katze', 'charmant', 'lieb', 'ruhig']);
  column(['le chat']);
  column(['le chat', 'le chien', 'la maison', 'les enfants', "l'école", 'la rue']);
  column([]);
  column(['', '  ', '42']);
  column(null);
  column(undefined);
  column('le chat');
  column([null, 'die Katze', undefined, 7]);
  column(42);
  column({});
  column([{}, ['le', 'chat'], true, 'der Hund']);

  const table = [
    ['quizlet-export.txt', '\t'],
    ['dash-hyphen.txt', ' - '],
    ['dash-en-em.txt', /\s[–—]\s/],
    ['equals.txt', ' = '],
    ['semicolon.txt', ';'],
    ['german-first.txt', ' - '],
    ['english-german.txt', ' - '],
    ['pdf-columns.txt', /\s{2,}/],
    ['numbered.txt', /\s–\s/],
    ['spanish.txt', /\s–\s/],
    ['italian.txt', ' = '],
    ['four-cells.tsv', '\t'],
  ];
  for (const [file, delim] of table) {
    const rows = nonEmptyLines(readFixture(file)).map((l) => l.split(delim));
    column(rows.flatMap((r) => r.filter((_, i) => i % 2 === 0)));
    column(rows.flatMap((r) => r.filter((_, i) => i % 2 === 1)));
    for (const r of rows) for (const cell of r) text(cell);
  }
  const ocr = nonEmptyLines(readFixture('two-column-ocr.txt'));
  column(ocr.slice(0, 8));
  column(ocr.slice(8));
  const alt = nonEmptyLines(readFixture('alternating.txt'));
  column(alt.filter((_, i) => i % 2 === 0));
  column(alt.filter((_, i) => i % 2 === 1));
}

// 2. tests/parser.test.js: every literal with its lines, cells and columns
for (const s of stringLiterals(readText('tests/parser.test.js'))) textBlock(s);

// 3. Every tests/fixtures file: whole text, lines, cells, columns
for (const { text: s } of fixtureTexts()) textBlock(s);

// ---------------------------------------------------------------------------
// 4. The module's own lexicon (all template literals of langdetect.js), single words in many forms

const LEXICON = [];
{
  const src = readText('src/core/langdetect.js');
  const re = /`([^`]*)`/g;
  let m;
  while ((m = re.exec(src))) for (const w of m[1].split(/\s+/)) if (w) LEXICON.push(w);
}
const cap = (w) => w.charAt(0).toUpperCase() + w.slice(1);
const ARTICLES = ['le', 'la', 'les', "l'", 'un', 'une', 'des', 'du', 'se', "s'", 'der', 'die', 'das', 'den', 'dem',
  'ein', 'eine', 'einen', 'sich', 'the', 'a', 'an', 'to', 'el', 'los', 'las', 'una', 'unos', 'lo', 'il', 'gli', 'i',
  'uno', "un'", 'zum', 'im', 'kein', 'mein', 'jeder'];
LEXICON.forEach((w, i) => {
  text(w);
  text(cap(w));
  if (i % 3 === 0) text(w.toUpperCase());
  if (i % 2 === 0) text(`${ARTICLES[i % ARTICLES.length]} ${i % 4 === 0 ? cap(w) : w}`);
  if (i % 5 === 0) text(`${w}, ${LEXICON[(i * 7) % LEXICON.length]}`);
  if (i % 7 === 0) text(`${w}'`);
});

// 5. Cognates, held-out words, mixed lines and odd input
const COGNATES = ['question', 'nation', 'important', 'intelligent', 'charme', 'table', 'hotel', 'Hotel', 'radio',
  'taxi', 'piano', 'animal', 'normal', 'possible', 'excellent', 'information', 'restaurant', 'Restaurant', 'chocolat',
  'Schokolade', 'chocolate', 'cioccolato', 'université', 'Universität', 'university', 'universidad', 'università',
  'musique', 'Musik', 'music', 'música', 'musica', 'famille', 'Familie', 'family', 'familia', 'famiglia', 'banane',
  'Banane', 'banana', 'orange', 'Orange', 'naranja', 'arancia', 'problème', 'Problem', 'problem', 'problema',
  'police', 'Polizei', 'policía', 'polizia', 'théâtre', 'Theater', 'theatre', 'teatro', 'chance', 'Chance',
  'idée', 'Idee', 'idea', 'garage', 'Garage', 'sport', 'Sport', 'film', 'Film', 'parc', 'Park', 'park', 'parque',
  'parco', 'tomate', 'Tomate', 'tomato', 'pomodoro', 'café', 'Kaffee', 'coffee', 'caffè', 'nature', 'Natur',
  'natura', 'naturaleza', 'courage', 'Mut', 'brave', 'sage', 'calme', 'still', 'charmant', 'lieb', 'ruhig',
  'personne', 'Person', 'person', 'persona', 'adresse', 'Adresse', 'address', 'dirección', 'indirizzo', 'boss',
  'Boss', 'bus', 'Bus', 'autobús', 'autobus', 'ok', 'OK', 'pizza', 'Pizza', 'pasta', 'Pasta', 'tapas', 'fiesta'];
for (const w of COGNATES) {
  text(w);
  text(`le ${w}`);
  text(`der ${cap(w)}`);
  text(`the ${w}`);
}
const HELD_OUT = ['la grenouille', "l'épicerie", 'étroit', 'le bouleau', 'la pieuvre', "s'évanouir", 'le tournevis',
  'die Wäscheklammer', 'verschwommen', 'der Regenschirm', 'das Eichhörnchen', 'die Glühbirne', 'umziehen',
  'the umbrella', 'to faint', 'the hedgehog', 'the screwdriver', 'la rana', 'el paraguas', "l'ombrello", 'stretto',
  'vereinte', 'verneinte', 'beweinte', 'meinte', 'weinte', 'vereint', 'gemeint', 'erscheint', 'vereinigt', 'peinte',
  'atteinte', 'éteinte', 'teinte', 'enceinte', 'pleines', 'klein', 'Schwein', 'allein', 'mein', 'Bein', 'Wein'];
const MIXED = [
  'le chat - die Katze', 'die Katze - le chat', 'the cat, el gato', 'il cane; der Hund', 'la maison (das Haus)',
  "s'appeler | heissen", 'to look for sth / etw. suchen', 'der Herr: le monsieur', 'le monsieur, messieurs',
  'ressembler à qn - jdm ähneln', 'se ressembler – sich ähnlich sein', 'la femme = die Frau', '1. le chat – die Katze',
  '- le chat', '  -  die Katze', 'le chat -die Katze', 'le chat- die Katze', 'Le Chat Die Katze', 'LA FEMME DIE FRAU',
  'der grosse Hund', 'die schöne Frau', 'das kleine Mädchen', 'ein Mann', 'eine Frau, ein Kind', 'mein Hund',
  'zum Bahnhof', 'im Garten', 'Im Garten', 'Garten im', 'die, Frau', 'die (Frau)', 'die - Frau', 'die / Frau',
  'jeder Mensch', 'keiner Frau', 'Paris', 'Berlin Zürich', 'Monsieur Dupont', 'Herr Müller', 'Mr Smith',
  "aujourd'hui", "quelqu'un", "jusqu'à", "l'homme l'enfant", "d'accord", "c'est", "qu'est-ce que c'est",
  "don't", "isn't", "can't", "won't", "un'amica", "dell'acqua", "all'una", "l'", "s'", "'", "''", "l''",
  '¿Qué tal?', '¡Hola!', '¿¡', 'ñandú', 'Ñ', 'ß', 'Straße', 'STRASSE', 'strasse', 'Fuß', 'Fuss', 'heißen',
  'ẞ', 'GROẞ', 'œuvre', 'Œuvre', 'cœur', 'CŒUR', 'Ça va', 'ÇA VA', 'École', 'ÉCOLE', 'à côté', 'À CÔTÉ',
  'Größe', 'GRÖSSE', 'Äpfel', 'ÄPFEL', 'Übung', 'Ölfass', 'perché', 'PERCHÉ', 'città', 'CITTÀ', 'più', 'perciò',
  'éééééé', 'ä ä ä ä ä ä', 'ç ç ç ç ç', 'ñ ñ ñ ñ', 'ìòìòìò', 'é è ê ë à â î ï ô û ù ç œ ä ö ü ß ñ á í ó ú ì ò ¿ ¡',
];
for (const s of [...HELD_OUT, ...MIXED]) text(s);
const ODD = [
  null, undefined, 0, 1, -1, 3.5, true, false, {}, { a: 1 }, [], ['le', 'chat'], [null, 'Katze'], [['a', 'b'], 'c'],
  '', ' ', '\t', '\n', '\r\n', ' ', '​', '﻿', '123', '12 / 40', '1.', '- -', '...', '!!!', '“”', '«»',
  'a', 'A', 'b', 'x', 'X', 'y', 'z', 'k', 'w', 'é', 'É', 'ü', 'Ü', 'aa', 'Ab', 'AB', 'ab', 'xyz', 'XYZ', 'Xyz', 'qwrtz',
  'constructor', 'Constructor', 'CONSTRUCTOR', 'le Constructor', 'la constructor', ', Constructor', 'x, Constructor',
  'hasOwnProperty', 'toString', 'valueOf', '__proto__', 'prototype', 'Prototype', 'isPrototypeOf', 'length', 'Length',
  'αβγ', 'Ἀθῆναι', 'ΟΔΟΣ', 'Οδός', 'Москва', 'привет мир', '東京', '日本語の文', '서울', 'مرحبا', 'שלום', 'नमस्ते', 'ไทย',
  '𝐀𝐁𝐂', '𝐀bc', 'a𝐁c', '𐐀𐐨𐐩', '𐐀bc', '𝓁𝑒 𝒸𝒽𝒶𝓉', 'İstanbul', 'istanbul', 'İ', 'ı', 'ǅemal', 'ǅ', 'Ǆ', 'ǆ', 'ﬁn', 'ﬁ',
  'ŉ', 'ǰ', 'ΐ', 'Σ', 'σς', 'été', 'café', 'q́', 'äpfel', 'Äpfel', 'ñ', 'K', 'Å',
  '😀', 'le 😀 chat', 'die 👍🏽 Katze', 'a😀b', '👨‍👩‍👧', 'x́́', '́', 'l’homme', 'l‘homme', 'l`homme', 'l´homme',
  'c’est–à–dire', 'le chat — die Katze', 'le chat', 'der Hund', 'die​Katze', 'TheHouse', 'theHouse', 'tHE',
  'McDonald', 'iPhone', 'eBay', 'O’Neill', "O'Neill", 'D’Artagnan', 'Jean-Luc', 'jean-luc', 'Saint-Étienne',
];
for (const s of ODD) text(s);
for (const s of ODD) column([s]);
column(ODD);

// Long input: > 4000 UTF-16 units (normalizeBasic(...).slice(0, 4000)), astral letters at the cut
{
  const user = readFixture('user-example.txt');
  text(user + user + user);
  text('le chat '.repeat(600));
  text('a'.repeat(3999) + '𝐀 le chat');
  text('a'.repeat(3998) + '𝐀𝐀 die Katze');
  text(`${'die Katze, '.repeat(363)}x𝐀`);
  text(`${'é'.repeat(3999)} ß`);
  text(`${' '.repeat(5000)}le chat`);
  text(`le chat${' '.repeat(5000)}die Katze`);
  text('Mädchen '.repeat(700));
}

// ---------------------------------------------------------------------------
// 6. Seeded word salads

const rng = mulberry32(0x1a96de7);
const POOL = [...LEXICON, ...HELD_OUT.flatMap((s) => s.split(' ')), ...COGNATES];
const LETTERS = 'abcdefghijklmnopqrstuvwxyzéèêëàâîïôûùçœäöüßñáíóúìò'.split('');
const SEPARATORS = [' ', ' ', ' ', ' ', ', ', ' - ', '; ', ' / ', ' (', ') ', ': ', ' | ', '-', "'", '’', ' – ', '. ',
  '! ', '? ', ' ¿', ' ¡', '\t', '  ', ' 1. ', ' 2) ', '\n', ' = ', ' & '];

function randomWord() {
  const r = rng();
  if (r < 0.75) return pick(rng, POOL);
  if (r < 0.92) {
    let w = '';
    const n = randInt(rng, 1, 9);
    for (let i = 0; i < n; i++) w += pick(rng, LETTERS);
    return w;
  }
  return pick(rng, ['𝐀', 'Ж', 'α', 'ǅ', 'İ', 'ẞ', 'Ω', '😀', '12', 'x2', "l'", "s'", "d'", 'constructor', 'K']);
}

function styled(w) {
  const r = rng();
  if (r < 0.2) return cap(w);
  if (r < 0.25) return w.toUpperCase();
  return w;
}

function salad(maxWords) {
  const n = randInt(rng, 1, maxWords);
  let s = chance(rng, 0.15) ? pick(rng, ['- ', '  ', '(', '1. ', '* ', '']) : '';
  if (chance(rng, 0.35)) s += `${pick(rng, ARTICLES)} `;
  for (let i = 0; i < n; i++) {
    if (i) s += pick(rng, SEPARATORS);
    if (i && chance(rng, 0.15)) s += `${pick(rng, ARTICLES)} `;
    s += styled(randomWord());
  }
  return s;
}

for (let i = 0; i < 3500; i++) text(salad(i < 2500 ? 4 : 12));

// Columns: random salads, single-language lexicon columns, two-language mixtures (near ties)
const BY_LANG = {};
const LATIN = ['fr', 'de', 'en', 'es', 'it'];
{
  const src = readText('src/core/langdetect.js');
  for (const block of ['FUNCTION_WORDS', 'VOCAB_WORDS']) {
    const start = src.indexOf(`const ${block} = {`);
    const end = src.indexOf('};', start);
    const re = /(\w+): `([^`]*)`/g;
    re.lastIndex = start;
    let m;
    while ((m = re.exec(src)) && m.index < end) {
      BY_LANG[m[1]] = (BY_LANG[m[1]] || []).concat(m[2].split(/\s+/).filter(Boolean));
    }
  }
}
for (let i = 0; i < 400; i++) {
  const n = randInt(rng, 1, 14);
  const col = [];
  for (let j = 0; j < n; j++) col.push(chance(rng, 0.08) ? pick(rng, ['', '42', null, ' - ']) : salad(3));
  column(col);
}
for (let i = 0; i < 300; i++) {
  // The lexicon salads cover the five Latin languages (BY_LANG has no Arabic or Chinese words).
  const [a, b] = [pick(rng, LATIN), pick(rng, LATIN)];
  const n = randInt(rng, 1, 12);
  const col = [];
  for (let j = 0; j < n; j++) {
    const lang = j % 2 === 0 ? a : b;
    let w = pick(rng, BY_LANG[lang]);
    if (chance(rng, 0.3)) w = `${pick(rng, ARTICLES)} ${w}`;
    if (chance(rng, 0.2)) w = cap(w);
    col.push(w);
  }
  column(col);
}

// ---------------------------------------------------------------------------
// 7. Arabic and Chinese: script runs glued to Latin letters, harakat / tatweel / presentation
//    forms (also at the 4000-unit cut), pinyin with carons, macrons and other accents, and
//    columns mixing script languages with Latin ones (votes only with evidence, near ties).
{
  const rng2 = mulberry32(0x5c7a);
  const AR_WORDS = ['كتاب', 'الكتاب', 'مدرسة', 'مَدْرَسَةٌ', 'الْكِتَابُ', 'كـتـاب', 'ﻛﺘﺎﺏ', 'سيارة', 'عربية', 'مرحبا', 'السلامة',
    'المعلّم', 'شكرًا', 'أخ', 'إلى', 'ٱلله', 'ب\u0654ت', 'آب', 'قرآن', 'ۖ', 'ـ', '١٢', '؟', '،', '؛'];
  const ZH_WORDS = ['你好', '谢谢', '再见', '学生', '朋友', '中国', '书', '水', '我是学生。', '你好，朋友', '对不起', '「书」', '《书》',
    '々', '〇', 'の', 'カタカナ', '，', '。', '！'];
  const PINYIN = ['nǐ', 'hǎo', 'nǐ hǎo', 'shuǐ', 'lǎoshī', 'duìbuqǐ', 'Běijīng', 'lǜ', 'lǚ', 'nǚ', 'lüè', 'Ǎ', 'NǏ', 'māma', 'kāfēi',
    'hē', 'zàijiàn', 'xièxie', 'shì', 'péngyou', 'xuésheng', 'ni3', 'hao3', 'ni3 hao3', 'xiexie', "wǎn'ān", 'Zhōngguó', 'ěr'];
  const LATIN_WORDS = ['le chat', 'die Katze', 'Buch', 'das Buch', 'the house', 'el niño', 'la città', 'Hallo', 'danke', 'CD', 'x'];
  const JOIN = ['', ' ', ' ', ', ', ' - ', '\t', '/', ' (', ') ', '：', '、', ' ، ', '\u200F', "'"];
  const POOL2 = [...AR_WORDS, ...ZH_WORDS, ...PINYIN, ...LATIN_WORDS];
  for (const w of POOL2) {
    text(w);
    text(`${w} ${w}`);
    text(`le ${w}`);
    text(`${w}Hallo`);
    text(`Hallo${w}`);
    text(`${w}'s`);
  }
  for (let i = 0; i < 1500; i++) {
    let s = '';
    const n = randInt(rng2, 1, 6);
    for (let k = 0; k < n; k++) s += (k ? pick(rng2, JOIN) : '') + pick(rng2, POOL2);
    text(s);
  }
  // Long input: marks removed before the 4000-unit cut, script runs on both sides of it.
  text('مَدْرَسَةٌ '.repeat(500));
  text(`${'a'.repeat(3996)}الكتاب`);
  text(`${'ـ'.repeat(4500)}كتاب`);
  text(`${'你好 '.repeat(1333)}朋友`);
  text(`${'le chat '.repeat(499)}nǐ hǎo`);
  // Columns: pure script columns, mixed with Latin, single evidence lines, near ties.
  const lineOf = (pool) => {
    let s = pick(rng2, pool);
    if (chance(rng2, 0.3)) s += pick(rng2, JOIN) + pick(rng2, pool);
    return s;
  };
  for (let i = 0; i < 500; i++) {
    const n = randInt(rng2, 1, 12);
    const mix = randInt(rng2, 0, 5);
    const col = [];
    for (let k = 0; k < n; k++) {
      const pools = [AR_WORDS, ZH_WORDS, PINYIN, LATIN_WORDS];
      if (mix === 0) col.push(lineOf(AR_WORDS));
      else if (mix === 1) col.push(lineOf(ZH_WORDS));
      else if (mix === 2) col.push(lineOf(PINYIN));
      else if (mix === 3) col.push(lineOf(k % 2 ? LATIN_WORDS : pick(rng2, [AR_WORDS, ZH_WORDS])));
      else if (mix === 4) col.push(lineOf(pick(rng2, pools)));
      else col.push(chance(rng2, 0.85) ? salad(3) : lineOf(pick(rng2, [AR_WORDS, ZH_WORDS, PINYIN])));
    }
    column(col);
  }
  column(['die Katze', 'der Hund', 'كتاب', 'das Haus', 'die Maus']);
  column(['你好', 'كتاب']);
  column(['كتاب', '你好']);
  column(['你好', 'nǐ hǎo', 'xiexie']);
  column(['xiexie', 'nihao', 'zaijian']);
}

cases.emit();
