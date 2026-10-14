// Parity fixture for the pure OCR clean-up of src/import/ocr.js → Fixtures/ocr.json.
// fns: fixGermanUmlauts [lines]
//
// Inputs: every input of tests/layout.test.js, every tests/fixtures text (as is, with every German
// umlaut misread as a circumflex, misread only in the definition column, re-split into tab cells,
// single lines and alternating stacks), hand-picked edge cases (holes in columns, blank and
// whitespace cells, decomposed circumflexes, upper case, many columns, null / number entries) and
// seeded tables mixing French words that really carry a circumflex ("le rôle", "tôt", "le château")
// with German words whose umlauts were misread ("schôn", "die Tûr").
import { fixGermanUmlauts } from '../../Website/src/import/ocr.js';
import { Cases, mulberry32, randInt, pick, chance, fixtureTexts } from './lib.js';

const cases = new Cases('ocr');

const seen = new Set();
function fix(lines) {
  const key = JSON.stringify(lines === undefined ? null : lines);
  if (seen.has(key)) return;
  seen.add(key);
  cases.add('fixGermanUmlauts', [lines], fixGermanUmlauts(lines));
}

// ---------------------------------------------------------------------------
// 1. tests/layout.test.js

fix(['le chat\tdie Katze', 'beau\tschôn', 'le rôle\tdie Rolle', 'vert\tgrûn', 'fatigué\tmûde', 'à côté de\tneben', 'la porte\tdie Tûr']);
fix(['tôt', 'früh', 'le rôle', 'die Rolle', 'beau', 'schôn', 'la porte', 'die Tûr', 'brûler', 'brennen']);
fix(['LA PORTE\tDIE TÛR', 'le chat\tdie Katze', 'le chien\tder Hund']);
fix(['le château\tdas Schloss', 'le gâteau\tder Kuchen', 'âgé\talt']);
fix(null);
// ocrDataToText cases (the rows it builds before the clean-up)
fix(['beau, belle\tschôn', 'le rôle\tdie Rolle', 'la porte\tdie Tûr', 'fatigué\tmûde']);
fix(['die Tûr', 'la porte']);

// ---------------------------------------------------------------------------
// 2. Misreading helpers

const TO_CIRCUMFLEX = { ä: 'â', ö: 'ô', ü: 'û', Ä: 'Â', Ö: 'Ô', Ü: 'Û' };
const misread = (s) => s.replace(/[äöüÄÖÜ]/g, (c) => TO_CIRCUMFLEX[c]);
// Misreads each umlaut with probability p.
const misreadSome = (rng, s, p) => s.replace(/[äöüÄÖÜ]/g, (c) => (chance(rng, p) ? TO_CIRCUMFLEX[c] : c));

const splitLines = (s) => s.split(/\r\n|\r|\n/);

// Cells of one line, split at the first delimiter that occurs.
const DELIMITERS = ['\t', ' = ', ' - ', ' – ', ' — ', ';', ' : ', /\s{2,}/, '|', ','];
function cellsOf(line) {
  for (const d of DELIMITERS) {
    const parts = line.split(d);
    if (parts.length > 1) return parts.map((p) => p.trim());
  }
  return [line];
}

// ---------------------------------------------------------------------------
// 3. Every fixture text

for (const { text } of fixtureTexts()) {
  const lines = splitLines(text);
  const rows = lines.map(cellsOf);
  const tabbed = rows.map((r) => r.join('\t'));
  fix(lines);
  fix(lines.map(misread));
  fix(tabbed);
  fix(tabbed.map(misread));
  // Only the definition (second) column misread.
  fix(rows.map((r) => r.map((c, i) => (i === 1 ? misread(c) : c)).join('\t')));
  // Only the term column misread (French words with fake circumflexes stay French).
  fix(rows.map((r) => r.map((c, i) => (i === 0 ? misread(c) : c)).join('\t')));
  // Swapped columns.
  fix(rows.map((r) => r.slice().reverse().map(misread).join('\t')));
  // Stacked: term line, definition line.
  fix(rows.flatMap((r) => r.map(misread)));
  // Every non-empty line on its own.
  for (const line of lines) {
    if (!line.trim()) continue;
    fix([misread(line)]);
    fix([cellsOf(line).map(misread).join('\t')]);
  }
  // Windows of 6 rows.
  for (let i = 0; i < tabbed.length; i += 6) fix(tabbed.slice(i, i + 6).map(misread));
}

// ---------------------------------------------------------------------------
// 4. Edge cases

const EDGE = [
  [],
  [''],
  ['\t'],
  ['\t\t'],
  ['â'],
  ['Â'],
  ['ô\tû'],
  ['schôn'],
  ['Schôn'],
  ['SCHÔN'],
  ['schôn\t'],
  ['\tschôn'],
  ['   \tschôn', 'die Katze\tle chat'],
  ['le chat\t\tdie Katze', 'beau\t\tschôn', 'la porte\t\tdie Tûr'],
  ['le chat\t \tdie Katze', 'beau\t \tschôn'],
  // A column that never gets a cell (hole) before a German one.
  ['\t\tdie Katze', '\t\tdie Tûr', '\t\tder Hund', 'x'],
  ['a\t\t\tdie Katze', 'b\t\t\tschôn', 'c\t\t\tmûde\tgrûn'],
  // Decomposed circumflexes are not matched by the JS regex.
  ['schôn\tbeau', 'die Tûr\tla porte'],
  ['schôn', 'schôn'],
  // Many columns.
  ['le chat\tdie Katze\tle chien\tder Hund', 'beau\tschôn\tla porte\tdie Tûr', 'vert\tgrûn\tfatigué\tmûde'],
  ['1\tle chat\tdie Katze', '2\tbeau\tschôn', '3\tla porte\tdie Tûr', '4\tle rôle\tdie Rolle'],
  // Clearly French cells in a German column stay.
  ['der Hund\tle chien', 'die Katze\tle chat', 'tôt\tfrüh', 'le rôle\tdie Rolle', 'die Tûr\tla porte'],
  ['die Katze', 'der Hund', 'das Haus', 'die Tûr'],
  ['Brôtchen', 'Kâse', 'Ûbung', 'Ôsterreich', 'Âpfel'],
  ['das Brôtchen\tle petit pain', 'der Kâse\tle fromage', 'die Ûbung\tl’exercice', 'Ôsterreich\tl’Autriche'],
  ['hôpital\tSpital', 'château\tSchloss', 'gâteau\tKuchen', 'côté\tSeite', 'sûr\tsicher', 'mûr\treif'],
  ['ich bin mûde und mochte schlafen', 'je suis fatigué et je veux dormir'],
  ['über\tsur', 'fûr\tpour', 'grôsser\tplus grand'],
  ['Strasse\true', 'Mûller\tMeunier'],
];
for (const e of EDGE) fix(e);
// Non-string entries (String(l), null → '').
fix(['beau\tschôn', null, 'la porte\tdie Tûr']);
fix([42, 'die Tûr', null]);
fix('not an array');

// ---------------------------------------------------------------------------
// 5. Seeded tables

const FR_PLAIN = [
  'le chat', 'le chien', 'la maison', 'le jardin', 'la porte', 'beau, belle', 'fatigué', 'vert', 'manger', 'boire',
  'la gare', 'le billet', 'le train', 'avoir lieu', 'la rue', 'le nom', 'la fille', 'le garçon', 'l’enfant', 'la sœur',
  'les parents', 'le père', 'la mère', 'le frère', 'aimable', 'gentil, gentille', 'calme', 'sage', 'à côté de', 'le départ',
];
const FR_CIRC = [
  'le rôle', 'tôt', 'le château', 'le gâteau', 'âgé', 'à côté de', 'brûler', 'sûr', 'mûr', 'l’hôpital', 'le côté',
  'le coût', 'le goût', 'août', 'bientôt', 'plutôt', 'la côte', 'le pôle', 'drôle', 'le contrôle', 'la pâte', 'le bâtiment',
  'la tâche', 'le hôtel', 'le fantôme', 'diplômé', 'Le Rôle', 'LE CHÂTEAU', 'Côte d’Azur', 'Sûr',
];
const DE_UMLAUT = [
  'schön', 'die Tür', 'müde', 'grün', 'das Mädchen', 'der Bäcker', 'das Brötchen', 'der Käse', 'das Hähnchen', 'die Übung',
  'Österreich', 'die Äpfel', 'früh', 'über', 'für', 'das Stück', 'die Mütze', 'hören', 'können', 'müssen', 'die Brücke',
  'fünf', 'zwölf', 'die Grösse', 'schön, hübsch', 'die Grosseltern', 'der Schlüssel', 'glücklich', 'täglich', 'Ärger',
  'die Küche', 'das Gemüse', 'das Frühstück', 'die Höhle', 'der Löffel', 'ÜBER', 'SCHÖN', 'Tschüss', 'die Fähre', 'das Öl',
];
const DE_PLAIN = [
  'die Katze', 'der Hund', 'das Haus', 'der Garten', 'die Rolle', 'das Schloss', 'der Kuchen', 'alt', 'neben', 'essen',
  'trinken', 'der Bahnhof', 'die Fahrkarte', 'der Zug', 'stattfinden', 'die Strasse', 'der Name', 'der Junge', 'das Kind',
  'die Schwester', 'die Eltern', 'der Vater', 'die Mutter', 'der Bruder', 'freundlich', 'lieb, nett', 'ruhig', 'brav, artig',
  'sicher', 'reif', 'brennen', 'die Seite', 'der Geschmack',
];
const NOISE = ['', ' ', '12', '|', '…', 'p. 4', 'Unité 3', 'Lektion 5', '—', 'x'];

const rng = mulberry32(0x0c12);

function deCell(r) {
  const word = chance(r, 0.55) ? pick(r, DE_UMLAUT) : pick(r, DE_PLAIN);
  return misreadSome(r, word, chance(r, 0.2) ? 1 : 0.7);
}

function frCell(r) {
  return chance(r, 0.35) ? pick(r, FR_CIRC) : pick(r, FR_PLAIN);
}

for (let n = 0; n < 1400; n++) {
  const shape = randInt(rng, 0, 5);
  const rows = randInt(rng, 1, 12);
  const lines = [];
  for (let r = 0; r < rows; r++) {
    if (chance(rng, 0.06)) {
      lines.push(pick(rng, NOISE));
      continue;
    }
    if (shape === 0) {
      // term \t definition
      lines.push(`${frCell(rng)}\t${deCell(rng)}`);
    } else if (shape === 1) {
      // definition \t term (German first)
      lines.push(`${deCell(rng)}\t${frCell(rng)}`);
    } else if (shape === 2) {
      // stacked lines
      lines.push(frCell(rng));
      lines.push(deCell(rng));
    } else if (shape === 3) {
      // four columns, sometimes with an empty cell
      const cells = [frCell(rng), deCell(rng), frCell(rng), deCell(rng)];
      if (chance(rng, 0.2)) cells[randInt(rng, 0, 3)] = chance(rng, 0.5) ? '' : '  ';
      lines.push(cells.join('\t'));
    } else if (shape === 4) {
      // numbered rows
      lines.push(`${r + 1}\t${frCell(rng)}\t${deCell(rng)}`);
    } else {
      // free mix: any number of cells of either language
      const k = randInt(rng, 1, 4);
      const cells = [];
      for (let i = 0; i < k; i++) cells.push(chance(rng, 0.5) ? frCell(rng) : deCell(rng));
      lines.push(cells.join('\t'));
    }
  }
  fix(lines);
}

cases.emit();
