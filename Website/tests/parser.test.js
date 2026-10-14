import { test, expect, run } from './harness.js';
import { parseVocab } from '../src/core/parser.js';

const read = (name) => readFile(`fixtures/${name}`);
const pairs = (r) => r.cards.map((c) => [c.term, c.definition]);
const NBSP = String.fromCharCode(0xa0);
const FLAGS = ['merged', 'lowConfidence', 'langMismatch', 'missingTerm', 'missingDefinition', 'duplicate'];

function expectShape(r) {
  expect(Array.isArray(r.cards)).toBe(true);
  expect(['delimited', 'alternating', 'blocks', 'columns', 'empty']).toContain(r.format);
  expect(typeof r.swapped).toBe('boolean');
  expect(Array.isArray(r.skipped)).toBe(true);
  expect(Array.isArray(r.warnings)).toBe(true);
  expect(['fr', 'de', 'en', 'es', 'it', 'other']).toContain(r.termLang);
  expect(['fr', 'de', 'en', 'es', 'it', 'other']).toContain(r.defLang);
  if (r.format !== 'delimited') expect(r.delimiter).toBe(null);
  for (const c of r.cards) {
    expect(typeof c.term).toBe('string');
    expect(typeof c.definition).toBe('string');
    expect(c.confidence >= 0 && c.confidence <= 1).toBe(true);
    expect(Array.isArray(c.lines) && c.lines.length > 0).toBe(true);
    for (const f of c.flags) expect(FLAGS).toContain(f);
  }
  for (const s of r.skipped) {
    expect(typeof s.line).toBe('number');
    expect(typeof s.text).toBe('string');
    expect(['heading', 'pageNumber', 'noise', 'unpaired']).toContain(s.reason);
  }
  for (const w of r.warnings) {
    expect(typeof w).toBe('string');
    expect(w.includes(String.fromCharCode(0xdf))).toBe(false); // Swiss spelling
  }
}

// [fixture, cards, format, delimiter, termLang, defLang, swapped, some exact pairs]
function checkFixture(name, n, format, delimiter, termLang, defLang, swapped, some) {
  const r = parseVocab(read(name));
  expectShape(r);
  expect(`${name}:${r.cards.length}`).toBe(`${name}:${n}`);
  expect(`${name}:${r.format}`).toBe(`${name}:${format}`);
  expect(r.delimiter).toBe(delimiter);
  expect(`${name}:${r.termLang}/${r.defLang}`).toBe(`${name}:${termLang}/${defLang}`);
  expect(r.swapped).toBe(swapped);
  const all = pairs(r);
  for (const p of some) expect(all).toContain(p);
  return r;
}

const USER_PAIRS = [
  ['le monsieur, messieurs', 'der Herr'],
  ["l'homme", 'der Mann'],
  ['la madame, mesdames', 'Frau'],
  ['la femme', 'die Frau'],
  ['la dame', 'die Dame'],
  ['la mademoiselle, mesdemoiselles', 'das Fräulein, die Frau'],
  ["l'enfant", 'das Kind'],
  ['le garçon', 'der Junge'],
  ['la fille', 'das Mädchen'],
  ['appeler', 'nennen'],
  ["s'appeler", 'heissen'],
  ['le nom', 'der Name'],
  ['le nom de famille', 'der Familienname, der Nachname'],
  ['le prénom', 'der Vorname'],
  ['marié, mariée', 'verheiratet'],
  ['veuf, veuve', 'verwitwet'],
  ['séparé, séparée', 'getrennt'],
  ['la personne', 'die Person'],
  ["l'adresse", 'die Adresse, die Anschrift'],
  ['la rue', 'die Strasse'],
  ['le numéro de la maison', 'die Hausnummer'],
  ['brave', 'lieb'],
  ['gentil, gentille', 'lieb, nett'],
  ['bon, bonne', 'gut, gütig'],
  ['aimable', 'freundlich'],
  ['sage', 'brav, artig'],
  ['le charme', 'der Charme'],
  ['charmant, charmante', 'charmant'],
  ['la raison', 'die Vernunft'],
  ['raisonnable', 'vernünftig'],
  ['sérieux, sérieuse', 'ernst, ernsthaft'],
  ['sympathique', 'sympathisch'],
  ['calme', 'ruhig'],
  ['tranquille', 'still'],
  ['comique', 'komisch'],
  ['le courage', 'der Mut'],
  ['courageux, courageuse', 'mutig'],
  ['la bêtise', 'die Dummheit'],
  ['bête', 'dumm'],
  ['méchant, méchante', 'böse, gemein'],
  ['lâche', 'feige'],
  ['le visage', 'das Gesicht'],
  ['la figure', 'das Gesicht'],
  ['les cheveux', 'das Haar, die Haare'],
  ['ressembler à', 'ähneln, gleichen'],
  ['se ressembler', 'sich ähnlich sein, sich gleichen'],
  ['joli, jolie', 'hübsch'],
  ['la beauté', 'die Schönheit'],
  ['beau, bel, belle', 'schön'],
  ['attirant, attirante', 'attraktiv, anziehend'],
  ['laid, laide', 'hässlich'],
  ['moche', 'hässlich'],
];

// ---------------------------------------------------------------------------
// The user's own example
// ---------------------------------------------------------------------------

test("user example: exactly the 52 expected pairs, in order", () => {
  const r = parseVocab(read('user-example.txt'));
  expectShape(r);
  expect(r.cards).toHaveLength(52);
  expect(pairs(r)).toEqual(USER_PAIRS);
});

test('user example: blocks, fr -> de, not swapped, no flags, nothing skipped', () => {
  const r = parseVocab(read('user-example.txt'));
  expect(r.format).toBe('blocks');
  expect(r.delimiter).toBe(null);
  expect(r.termLang).toBe('fr');
  expect(r.defLang).toBe('de');
  expect(r.swapped).toBe(false);
  expect(r.skipped).toEqual([]);
  expect(r.warnings).toEqual([]);
  for (const c of r.cards) {
    expect(`${c.term}:${c.flags.join(',')}`).toBe(`${c.term}:`);
    expect(c.confidence).toBeGreaterThanOrEqual(0.5);
  }
  expect(r.cards[0].lines).toEqual([1, 2]);
  expect(r.cards[2].lines).toEqual([14, 15]);
  expect(r.cards[51].lines).toEqual([311, 312]);
});

test('user example: same pairs with single blank lines, CRLF, no blank lines and hints', () => {
  const lines = read('user-example.txt').split('\n').filter((l) => l.trim());
  const blocks = [];
  for (let i = 0; i < lines.length; i += 2) blocks.push(`${lines[i]}\n${lines[i + 1]}`);
  const single = parseVocab(blocks.join('\n\n'));
  expect(single.format).toBe('blocks');
  expect(pairs(single)).toEqual(USER_PAIRS);
  const crlf = parseVocab(read('user-example.txt').replace(/\n/g, '\r\n'));
  expect(pairs(crlf)).toEqual(USER_PAIRS);
  const dense = parseVocab(lines.join('\n'));
  expect(dense.format).toBe('alternating');
  expect(pairs(dense)).toEqual(USER_PAIRS);
  const hinted = parseVocab(read('user-example.txt'), { termLang: 'fr', defLang: 'de' });
  expect(pairs(hinted)).toEqual(USER_PAIRS);
  expect(parseVocab(read('user-example.txt'), { mode: 'lines' }).cards).toHaveLength(52);
});

test('user example written German-first is auto-swapped', () => {
  const lines = read('user-example.txt').split('\n').filter((l) => l.trim());
  const flipped = [];
  for (let i = 0; i < lines.length; i += 2) flipped.push(`${lines[i + 1]}\n${lines[i]}`);
  const r = parseVocab(flipped.join('\n\n\n'));
  expect(r.swapped).toBe(true);
  expect(r.termLang).toBe('fr');
  expect(r.defLang).toBe('de');
  expect(pairs(r)).toEqual(USER_PAIRS);
});

// ---------------------------------------------------------------------------
// Fixture layouts
// ---------------------------------------------------------------------------

test('fixture: Quizlet export (tab + newline)', () => {
  checkFixture('quizlet-export.txt', 10, 'delimited', '\t', 'fr', 'de', false, [
    ['le chien', 'der Hund'],
    ['avoir faim', 'Hunger haben'],
    ['beau, bel, belle', 'schön'],
    ["c'est-à-dire", 'das heisst'],
  ]);
});

test('fixture: " - " separated (hyphenated words stay intact)', () => {
  checkFixture('dash-hyphen.txt', 8, 'delimited', ' - ', 'fr', 'de', false, [
    ['le monsieur', 'der Herr'],
    ["c'est-à-dire", 'das heisst'],
    ['le grand-père', 'der Grossvater'],
    ["aujourd'hui", 'heute'],
  ]);
});

test('fixture: en dash and em dash separated', () => {
  checkFixture('dash-en-em.txt', 6, 'delimited', ' - ', 'fr', 'de', false, [
    ['la fenêtre', 'das Fenster'],
    ['la porte', 'die Tür'],
    ["l'escalier", 'die Treppe'],
  ]);
});

test('fixture: " = " separated', () => {
  checkFixture('equals.txt', 6, 'delimited', ' = ', 'fr', 'de', false, [
    ['manger', 'essen'],
    ['la boulangerie', 'die Bäckerei'],
    ['acheter', 'kaufen'],
  ]);
});

test('fixture: quoted CSV with commas and escaped quotes inside fields', () => {
  checkFixture('csv-quoted.csv', 6, 'delimited', ',', 'fr', 'de', false, [
    ['le monsieur, messieurs', 'der Herr'],
    ['gentil, gentille', 'lieb, nett'],
    ['le chat', 'die Katze'],
    ['le "bon" vin', 'der "gute" Wein'],
    ['bon, bonne', 'gut'],
  ]);
});

test('fixture: semicolon separated', () => {
  checkFixture('semicolon.txt', 7, 'delimited', ';', 'fr', 'de', false, [
    ['le livre', 'das Buch'],
    ['le taille-crayon', 'der Spitzer'],
    ['le sac à dos', 'der Rucksack'],
  ]);
});

test('fixture: German first is swapped automatically', () => {
  const r = checkFixture('german-first.txt', 7, 'delimited', ' - ', 'fr', 'de', true, [
    ['le chien', 'der Hund'],
    ['le chat', 'die Katze'],
    ["l'oiseau", 'der Vogel'],
  ]);
  expect(r.cards[0].term).toBe('le chien');
});

test('fixture: alternating lines without blank lines', () => {
  const r = checkFixture('alternating.txt', 7, 'alternating', null, 'fr', 'de', false, [
    ['le printemps', 'der Frühling'],
    ["l'été", 'der Sommer'],
    ['il pleut', 'es regnet'],
    ['le soleil', 'die Sonne'],
  ]);
  expect(r.cards[0].lines).toEqual([1, 2]);
});

test('fixture: single lines separated by single blank lines', () => {
  checkFixture('single-blank-alternating.txt', 5, 'alternating', null, 'fr', 'de', false, [
    ['la tête', 'der Kopf'],
    ['le pied', 'der Fuss'],
    ['le genou', 'das Knie'],
  ]);
});

test('fixture: wrapped definitions are merged and flagged', () => {
  const r = checkFixture('wrapped-blocks.txt', 6, 'blocks', null, 'fr', 'de', false, [
    ['la voiture', 'das Auto, der Wagen'],
    ['le cours', 'der Kurs, die Unterrichtsstunde'],
    ["l'ordinateur", 'der Computer'],
    ['la pomme de terre', 'die Kartoffel'],
  ]);
  expect(r.cards[1].flags).toContain('merged');
  expect(r.cards[1].lines).toEqual([4, 5, 6]);
  expect(r.cards[2].flags).toContain('merged');
  expect(r.cards[0].flags).toEqual([]);
  expect(r.warnings.some((w) => w.includes('Fortsetzung'))).toBe(true);
});

test('fixture: numbered and bulleted list', () => {
  checkFixture('numbered.txt', 8, 'delimited', ' - ', 'fr', 'de', false, [
    ['le chat', 'die Katze'],
    ['la souris', 'die Maus'],
    ['le poisson', 'der Fisch'],
    ["l'oiseau", 'der Vogel'],
    ['le cheval', 'das Pferd'],
    ['la vache', 'die Kuh'],
  ]);
});

test('fixture: two-column OCR order pairs line i with line i + n/2', () => {
  const r = checkFixture('two-column-ocr.txt', 8, 'columns', null, 'fr', 'de', false, [
    ['le frère', 'der Bruder'],
    ['la sœur', 'die Schwester'],
    ['les parents', 'die Eltern'],
    ['les grands-parents', 'die Grosseltern'],
  ]);
  expect(r.cards[0].lines).toEqual([1, 9]);
});

test('fixture: English-German list', () => {
  checkFixture('english-german.txt', 9, 'delimited', ' - ', 'en', 'de', false, [
    ['to appear', 'erscheinen'],
    ['to look for sth', 'etw. suchen'],
    ['the house', 'das Haus'],
    ['to take care of sb', 'sich um jdn. kümmern'],
  ]);
});

test('fixture: PDF text with 2+ spaces between columns (incl. a collapsed row)', () => {
  checkFixture('pdf-columns.txt', 8, 'delimited', '  ', 'fr', 'de', false, [
    ['la gare', 'der Bahnhof'],
    ["l'arrivée", 'die Ankunft'],
    ['le numéro de la voie', 'die Gleisnummer'],
    ['le guichet', 'der Schalter'],
  ]);
});

test('fixture: noise - headings, page numbers and header row are skipped', () => {
  const r = checkFixture('noisy.txt', 7, 'delimited', ' - ', 'fr', 'de', false, [
    ['le monsieur', 'der Herr'],
    ['gentil, gentille', 'lieb, nett'],
    ['sérieux, sérieuse', 'ernst'],
    ['la voisine', 'die Nachbarin'],
  ]);
  const reasons = Object.fromEntries(r.skipped.map((s) => [s.line, s.reason]));
  expect(reasons).toEqual({ 1: 'heading', 2: 'heading', 4: 'heading', 8: 'heading', 11: 'pageNumber', 12: 'pageNumber' });
  expect(r.skipped[0].text).toBe('Unité 3 - Les personnes');
  for (const c of r.cards) {
    expect(c.term.includes('Unité')).toBe(false);
    expect(c.term.includes('Vocabulaire')).toBe(false);
  }
  expect(r.warnings).toContain('6 Zeilen ohne Vokabeln wurden übersprungen.');
});

test('fixture: four tab cells per line give two cards per line (left column first)', () => {
  const r = checkFixture('four-cells.tsv', 8, 'delimited', '\t', 'fr', 'de', false, [
    ['le lundi', 'der Montag'],
    ['le vendredi', 'der Freitag'],
    ['la semaine', 'die Woche'],
  ]);
  expect(r.cards.map((c) => c.term)).toEqual([
    'le lundi', 'le mardi', 'le mercredi', 'le jeudi', 'le vendredi', 'le samedi', 'le dimanche', 'la semaine',
  ]);
  expect(r.cards[4].lines).toEqual([1]);
});

test('fixture: Windows line endings, BOM and non-breaking spaces', () => {
  const r = checkFixture('windows-bom.txt', 4, 'delimited', ' - ', 'fr', 'de', false, [
    ['le chien', 'der Hund'],
    ['le lapin', 'das Kaninchen'],
    ["l'écureuil", 'das Eichhörnchen'],
  ]);
  expect(r.cards[0].term.charCodeAt(0)).toBe('l'.charCodeAt(0));
  expect(r.cards[3].lines).toEqual([5]);
});

test('fixture: Spanish-German list', () => {
  checkFixture('spanish.txt', 10, 'delimited', ' - ', 'es', 'de', false, [
    ['el perro', 'der Hund'],
    ['el niño', 'das Kind'],
    ['¿Qué tal?', "Wie geht's?"],
    ['bonito, bonita', 'hübsch'],
  ]);
});

test('fixture: Italian-German list', () => {
  checkFixture('italian.txt', 10, 'delimited', ' = ', 'it', 'de', false, [
    ['il cane', 'der Hund'],
    ['gli amici', 'die Freunde'],
    ['la città', 'die Stadt'],
    ['perché', 'warum'],
  ]);
});

test('fixture: Markdown table with header and separator row', () => {
  const r = checkFixture('markdown-table.txt', 4, 'delimited', '|', 'fr', 'de', false, [
    ['le pain', 'das Brot'],
    ['la viande', 'das Fleisch'],
  ]);
  expect(r.skipped.map((s) => s.reason)).toEqual(['heading', 'noise']);
});

test('fixture: whole list on one line separated by semicolons', () => {
  checkFixture('inline-semicolon.txt', 4, 'delimited', ' - ', 'fr', 'de', false, [
    ['le chat', 'die Katze'],
    ['le lapin', 'das Kaninchen'],
  ]);
});

test('fixture: collapsed PDF columns without any delimiter are split by language', () => {
  const r = checkFixture('collapsed-columns.txt', 6, 'delimited', ' ', 'fr', 'de', false, [
    ['le chat', 'die Katze'],
    ['le cheval', 'das Pferd'],
    ['le cochon', 'das Schwein'],
  ]);
  for (const c of r.cards) expect(c.flags).toEqual([]);
});

test('fixture: German-first blocks are swapped', () => {
  checkFixture('german-first-blocks.txt', 4, 'blocks', null, 'fr', 'de', true, [
    ['la cuillère', 'der Löffel'],
    ["l'assiette", 'der Teller'],
  ]);
});

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

test('mode "delimiter" with a custom delimiter', () => {
  const r = parseVocab('le chat :: die Katze\nle chien :: der Hund\n\nla souris :: die Maus', {
    mode: 'delimiter',
    delimiter: '::',
  });
  expect(r.format).toBe('delimited');
  expect(r.delimiter).toBe('::');
  expect(pairs(r)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la souris', 'die Maus'],
  ]);
  expect(r.cards[2].lines).toEqual([4]);
});

test('mode "delimiter" with cardSeparator ";"', () => {
  const r = parseVocab('le chat - die Katze; le chien - der Hund;\nla souris - die Maus;', {
    mode: 'delimiter',
    delimiter: ' - ',
    cardSeparator: ';',
  });
  expect(pairs(r)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la souris', 'die Maus'],
  ]);
  expect(r.cards[2].lines).toEqual([2]);
  const quizlet = parseVocab('le chat,die Katze;le chien,der Hund;la souris,die Maus', {
    mode: 'delimiter',
    delimiter: ',',
    cardSeparator: ';',
  });
  expect(quizlet.delimiter).toBe(',');
  expect(pairs(quizlet)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la souris', 'die Maus'],
  ]);
});

test('mode "delimiter": bare dash prefers the spaced dash, then the language boundary', () => {
  const r = parseVocab("c'est-à-dire - das heisst\nle grand-père-der Grossvater\nle chat-die Katze", {
    mode: 'delimiter',
    delimiter: '-',
  });
  expect(pairs(r)).toEqual([
    ["c'est-à-dire", 'das heisst'],
    ['le grand-père', 'der Grossvater'],
    ['le chat', 'die Katze'],
  ]);
});

test('mode "delimiter": tab default, newline delimiter with blank-line card separator', () => {
  expect(pairs(parseVocab('le chat\tdie Katze', { mode: 'delimiter' }))).toEqual([['le chat', 'die Katze']]);
  const r = parseVocab('le chat\ndie Katze\n\n\n\nle chien\nder Hund', { mode: 'delimiter', delimiter: '\n', cardSeparator: '\n\n' });
  expect(pairs(r)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
  ]);
  expect(r.cards[1].lines).toEqual([6, 7]);
});

test('mode "delimiter": en dash delimiter matches normalised text', () => {
  const r = parseVocab('le chat – die Katze\nle chien – der Hund', { mode: 'delimiter', delimiter: ' – ' });
  expect(pairs(r)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
  ]);
});

test('swap: true flips the sides after orientation', () => {
  const r = parseVocab(read('dash-hyphen.txt'), { swap: true });
  expect(r.swapped).toBe(true);
  expect(r.termLang).toBe('de');
  expect(r.defLang).toBe('fr');
  expect(r.cards[0].term).toBe('der Herr');
  expect(r.cards[0].definition).toBe('le monsieur');
  // German-first input: auto swap and forced swap cancel out.
  const g = parseVocab(read('german-first.txt'), { swap: true });
  expect(g.swapped).toBe(false);
  expect(g.cards[0].term).toBe('der Hund');
  expect(g.termLang).toBe('de');
});

test('orient: false keeps the source order', () => {
  const r = parseVocab(read('german-first.txt'), { orient: false });
  expect(r.swapped).toBe(false);
  expect(r.cards[0].term).toBe('der Hund');
  expect(r.termLang).toBe('de');
  expect(r.defLang).toBe('fr');
});

test('English first stays; German first with English is swapped (English is learned)', () => {
  const r = parseVocab('der Hund - the dog\ndie Katze - the cat\ndas Haus - the house');
  expect(r.swapped).toBe(true);
  expect(r.termLang).toBe('en');
  expect(pairs(r)).toEqual([
    ['the dog', 'der Hund'],
    ['the cat', 'die Katze'],
    ['the house', 'das Haus'],
  ]);
});

test('mode "lines" never splits on delimiters', () => {
  const r = parseVocab('le chat - die Katze\nle chien - der Hund', { mode: 'lines' });
  expect(r.format).toBe('alternating');
  expect(pairs(r)).toEqual([['le chat - die Katze', 'le chien - der Hund']]);
});

test('language hints are used when detection is impossible', () => {
  // Only one side has words: it becomes the term, the other side takes the hint.
  const r = parseVocab('12\tdouze\n13\ttreize', { termLang: 'fr', defLang: 'de' });
  expect(pairs(r)).toEqual([
    ['douze', '12'],
    ['treize', '13'],
  ]);
  expect(r.swapped).toBe(true);
  expect(r.termLang).toBe('fr');
  expect(r.defLang).toBe('de');
  const german = parseVocab('12 - zwölf\n13 - dreizehn');
  expect(german.swapped).toBe(false);
  expect(german.defLang).toBe('de');
  const empty = parseVocab('', { termLang: 'en', defLang: 'de' });
  expect(empty.termLang).toBe('en');
  expect(empty.defLang).toBe('de');
});

test('header row naming the languages is skipped', () => {
  const r = parseVocab('Deutsch - Französisch\nder Hund - le chien\ndie Katze - le chat');
  expect(r.skipped).toEqual([{ line: 1, text: 'Deutsch - Französisch', reason: 'heading' }]);
  expect(r.swapped).toBe(true);
  expect(pairs(r)).toEqual([
    ['le chien', 'der Hund'],
    ['le chat', 'die Katze'],
  ]);
  const fr = parseVocab('FR | DE\nle chat | die Katze\nle chien | der Hund');
  expect(fr.cards).toHaveLength(2);
  expect(fr.skipped[0].reason).toBe('heading');
});

test('a translation of a language name is a card, not a header', () => {
  const r = parseVocab('le français - Französisch\nfrançais - Französisch\nl’allemand - Deutsch');
  expect(r.cards).toHaveLength(3);
  expect(r.skipped).toEqual([]);
});

// ---------------------------------------------------------------------------
// Robustness
// ---------------------------------------------------------------------------

test('headings and page numbers inside a blocks list', () => {
  const r = parseVocab('Les animaux\n\nle chat\ndie Katze\n\nSeite 4\n\nle chien\nder Hund\n\n12\n\nla souris\ndie Maus');
  expect(r.format).toBe('blocks');
  expect(pairs(r)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la souris', 'die Maus'],
  ]);
  expect(r.skipped.map((s) => [s.line, s.reason])).toEqual([
    [1, 'heading'],
    [6, 'pageNumber'],
    [11, 'pageNumber'],
  ]);
});

test('mixed list: delimited lines and an alternating pair', () => {
  const r = parseVocab('le chat - die Katze\nle chien\nder Hund\nla souris - die Maus\nle lapin - das Kaninchen');
  expect(pairs(r)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la souris', 'die Maus'],
    ['le lapin', 'das Kaninchen'],
  ]);
});

test('missing translation in an alternating list is reported, not merged', () => {
  const r = parseVocab('le chat\ndie Katze\nle chien\nla souris\ndie Maus\nle lapin\ndas Kaninchen');
  expect(pairs(r)).toEqual([
    ['le chat', 'die Katze'],
    ['la souris', 'die Maus'],
    ['le lapin', 'das Kaninchen'],
  ]);
  expect(r.skipped).toEqual([{ line: 3, text: 'le chien', reason: 'unpaired' }]);
  expect(r.warnings).toContain('Zeile 3 konnte keinem Paar zugeordnet werden.');
});

test('wrapped definition inside a delimited list', () => {
  const r = parseVocab('le chat - die Katze,\n   der Kater\nle chien - der Hund');
  expect(r.format).toBe('delimited');
  expect(pairs(r)).toEqual([
    ['le chat', 'die Katze, der Kater'],
    ['le chien', 'der Hund'],
  ]);
  expect(r.cards[0].flags).toContain('merged');
  expect(r.cards[0].lines).toEqual([1, 2]);
});

test('missing sides are kept and flagged', () => {
  const r = parseVocab('le chat\t\n\tder Hund\nla souris\tdie Maus\nle lapin\tdas Kaninchen');
  expect(r.delimiter).toBe('\t');
  expect(pairs(r)).toEqual([
    ['le chat', ''],
    ['', 'der Hund'],
    ['la souris', 'die Maus'],
    ['le lapin', 'das Kaninchen'],
  ]);
  expect(r.cards[0].flags).toContain('missingDefinition');
  expect(r.cards[1].flags).toContain('missingTerm');
  expect(r.warnings).toContain('Zeile 1: Die Definition fehlt.');
  expect(r.warnings).toContain('Zeile 2: Der Begriff fehlt.');
  const dash = parseVocab('le chat -\nle chien - der Hund\nla souris - die Maus');
  expect(dash.cards[0].definition).toBe('');
  expect(dash.cards[0].flags).toContain('missingDefinition');
});

test('duplicates are flagged on repeated terms only', () => {
  const r = parseVocab('le chat - die Katze\nle chien - der Hund\nle chat - der Kater\nle visage - das Gesicht\nla figure - das Gesicht');
  expect(r.cards[0].flags).toEqual([]);
  expect(r.cards[2].flags).toContain('duplicate');
  expect(r.cards[4].flags).toEqual([]);
  expect(r.warnings).toContain('«le chat» kommt mehrfach vor (Zeilen 1 und 3).');
});

test('a single reversed row is turned around', () => {
  const r = parseVocab('le chat - die Katze\nder Hund - le chien\nla souris - die Maus\nle lapin - das Kaninchen');
  expect(r.cards[1].term).toBe('le chien');
  expect(r.cards[1].definition).toBe('der Hund');
  expect(r.warnings.some((w) => w.startsWith('Zeile 2: Begriff und Definition'))).toBe(true);
});

test('low confidence and language mismatch are flagged', () => {
  const r = parseVocab('le chat - die Katze\nder Hund - 42\nla souris - die Maus\nle lapin - das Kaninchen');
  const card = r.cards[1];
  expect(card.term).toBe('der Hund');
  expect(card.flags).toContain('lowConfidence');
  expect(card.flags).toContain('langMismatch');
  expect(card.confidence).toBeLessThan(0.5);
  expect(r.cards[0].flags).toEqual([]);
});

test('comma inside entries of an alternating list is not taken as delimiter', () => {
  const r = parseVocab('gentil, gentille\nlieb, nett\nbon, bonne\ngut, gütig');
  expect(r.format).toBe('alternating');
  expect(pairs(r)).toEqual([
    ['gentil, gentille', 'lieb, nett'],
    ['bon, bonne', 'gut, gütig'],
  ]);
});

test('multi-line quoted CSV field', () => {
  const r = parseVocab('"le monsieur,\nmessieurs","der Herr"\n"la dame","die Dame"\nle chat,die Katze');
  expect(r.delimiter).toBe(',');
  expect(pairs(r)).toEqual([
    ['le monsieur, messieurs', 'der Herr'],
    ['la dame', 'die Dame'],
    ['le chat', 'die Katze'],
  ]);
  expect(r.cards[0].lines).toEqual([1, 2]);
});

test('arrows of mixed styles, colons and pipes', () => {
  const arrows = parseVocab('le chat -> die Katze\nle chien => der Hund\nla souris → die Maus');
  expect(arrows.format).toBe('delimited');
  expect(pairs(arrows)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la souris', 'die Maus'],
  ]);
  const colon = parseVocab('le chat: die Katze\nle chien : der Hund\nla souris: die Maus');
  expect(pairs(colon)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la souris', 'die Maus'],
  ]);
  const pipe = parseVocab('le chat | die Katze\nle chien | der Hund');
  expect(pipe.delimiter).toBe('|');
});

test('a leading title does not hide the delimiter', () => {
  const r = parseVocab('Les animaux\nle chat - die Katze\nle chien - der Hund');
  expect(r.format).toBe('delimited');
  expect(r.cards).toHaveLength(2);
  expect(r.skipped).toEqual([{ line: 1, text: 'Les animaux', reason: 'heading' }]);
});

test('non-breaking spaces and curly apostrophes are normalised', () => {
  const r = parseVocab(`l’homme${NBSP}-${NBSP}der Mann\naujourd’hui - heute`);
  expect(pairs(r)).toEqual([
    ["l'homme", 'der Mann'],
    ["aujourd'hui", 'heute'],
  ]);
});

test('empty and blank input', () => {
  for (const input of ['', '   ', '\n\n\t\n', null, undefined]) {
    const r = parseVocab(input);
    expectShape(r);
    expect(r.format).toBe('empty');
    expect(r.cards).toEqual([]);
    expect(r.delimiter).toBe(null);
    expect(r.swapped).toBe(false);
  }
  const pages = parseVocab('1\n- 2 -\nSeite 3');
  expect(pages.format).toBe('empty');
  expect(pages.skipped.map((s) => s.reason)).toEqual(['pageNumber', 'pageNumber', 'pageNumber']);
});

test('a single line without partner is reported', () => {
  const r = parseVocab('le chat');
  expect(r.cards).toEqual([]);
  expect(r.skipped).toEqual([{ line: 1, text: 'le chat', reason: 'unpaired' }]);
  expect(r.warnings).toEqual(['Zeile 1 konnte keinem Paar zugeordnet werden.']);
});

test('never throws on odd input or options', () => {
  const inputs = [42, {}, [], ['a', 'b'], true, '\uFEFF', '"', '""""', '\t\t\t', ';;;;', ' - - - ', '|||', '===',
    '\u2028\u2029', 'a'.repeat(50000), 'le chat - '.repeat(2000), '\r\r\r', '"a\n"b\n"c'];
  const options = [undefined, null, 5, 'x', {}, { mode: 'nope' }, { mode: 'delimiter' }, { mode: 'delimiter', delimiter: '' },
    { mode: 'delimiter', delimiter: '-', cardSeparator: ';' }, { mode: 'lines' }, { termLang: 'xx', defLang: 7, swap: 'yes' }];
  for (const input of inputs) {
    for (const opts of options) {
      const r = parseVocab(input, opts);
      expectShape(r);
    }
  }
});

test('fuzz: random text never throws or falls back to the error path', () => {
  let seed = 12345;
  const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  const alphabet = ['a', 'é', 'ü', 'Der ', 'le ', '\t', '\n', '\n\n', ' ', '  ', '-', ' - ', '"', ',', ';', '|', '=',
    '1', '.', '–', NBSP, '\r', '(', ')', '*', '•', '¿', ':', '→', 'Seite ', 'x', 'Z'];
  for (let i = 0; i < 250; i++) {
    let s = '';
    const len = Math.floor(rnd() * 160);
    for (let k = 0; k < len; k++) s += alphabet[Math.floor(rnd() * alphabet.length)];
    for (const opts of [{}, { mode: 'lines' }, { mode: 'delimiter', delimiter: ' - ', cardSeparator: ';' }]) {
      const r = parseVocab(s, opts);
      expectShape(r);
      expect(r.warnings.includes('Der Text konnte nicht verarbeitet werden.')).toBe(false);
    }
  }
});

test('large lists parse quickly', () => {
  const big = Array(250).fill(read('dash-hyphen.txt')).join('');
  const t0 = Date.now();
  const r = parseVocab(big);
  expect(r.cards).toHaveLength(2000);
  expect(Date.now() - t0).toBeLessThan(2000);
  const blocks = Array(10).fill(read('user-example.txt')).join('\n\n');
  const t1 = Date.now();
  expect(parseVocab(blocks).cards).toHaveLength(520);
  expect(Date.now() - t1).toBeLessThan(2000);
});

test('two-column OCR order repeated per page', () => {
  const r = parseVocab(
    'le chat\nle chien\nla souris\nle lapin\n\ndie Katze\nder Hund\ndie Maus\ndas Kaninchen\n\n' +
      'le cheval\nla vache\nle cochon\n\ndas Pferd\ndie Kuh\ndas Schwein',
  );
  expect(r.format).toBe('columns');
  expect(pairs(r)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la souris', 'die Maus'],
    ['le lapin', 'das Kaninchen'],
    ['le cheval', 'das Pferd'],
    ['la vache', 'die Kuh'],
    ['le cochon', 'das Schwein'],
  ]);
  expect(r.cards[4].lines).toEqual([11, 15]);
});

test('columns of different length report the leftover line', () => {
  const r = parseVocab('le chat\nle chien\nla souris\nle lapin\nle cheval\ndie Katze\nder Hund\ndie Maus\ndas Kaninchen');
  expect(r.format).toBe('columns');
  expect(r.cards).toHaveLength(4);
  expect(r.skipped).toEqual([{ line: 5, text: 'le cheval', reason: 'unpaired' }]);
  expect(r.warnings).toContain('Die beiden Spalten sind unterschiedlich lang (5 und 4 Zeilen).');
});

test('hyphen without spaces is split at the language boundary', () => {
  const r = parseVocab('le chat-die Katze\nle chien-der Hund\nle grand-père-der Grossvater\nla pomme de terre-die Kartoffel');
  expect(pairs(r)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['le grand-père', 'der Grossvater'],
    ['la pomme de terre', 'die Kartoffel'],
  ]);
  const q = parseVocab('le chat-die Katze;le chien-der Hund;la souris-die Maus');
  expect(pairs(q)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la souris', 'die Maus'],
  ]);
});

test('typographic quotes and guillemets around fields are removed', () => {
  const r = parseVocab('« le chat » - « die Katze »\n„le chien“ - "der Hund"\n“la souris” - ‹die Maus›');
  expect(pairs(r)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la souris', 'die Maus'],
  ]);
});

test('Swiss spellings and Spanish blocks', () => {
  const ch = parseVocab('la rue\ndie Strasse\n\ngrand\ngross\n\nfermer\nschliessen');
  expect(ch.format).toBe('blocks');
  expect(pairs(ch)).toEqual([
    ['la rue', 'die Strasse'],
    ['grand', 'gross'],
    ['fermer', 'schliessen'],
  ]);
  const es = parseVocab('el perro\nder Hund\n\nla casa\ndas Haus\n\nhablar\nsprechen');
  expect(es.termLang).toBe('es');
  expect(es.cards).toHaveLength(3);
});

// ---------------------------------------------------------------------------
// Review regressions

const flagged = (r) => r.cards.filter((c) => c.flags.length).map((c) => [c.term, c.flags]);

test('lines with 3+ parts split where the languages change, not at the first delimiter', () => {
  const komma = parseVocab(
    'le monsieur, messieurs, der Herr, die Herren\nbeau, belle, schön\nle chat, die Katze\nheureux, heureuse, glücklich\ngentil, gentille, nett, freundlich',
    { mode: 'delimiter', delimiter: ',' },
  );
  expect(pairs(komma)).toEqual([
    ['le monsieur, messieurs', 'der Herr, die Herren'],
    ['beau, belle', 'schön'],
    ['le chat', 'die Katze'],
    ['heureux, heureuse', 'glücklich'],
    ['gentil, gentille', 'nett, freundlich'],
  ]);
  expect(flagged(komma)).toEqual([]);
  const dash = parseVocab('Comment ça va ? - Ça va bien. - Wie geht es dir? - Es geht mir gut.');
  expect(pairs(dash)).toEqual([['Comment ça va ? - Ça va bien.', 'Wie geht es dir? - Es geht mir gut.']]);
  const forms = parseVocab('le monsieur - messieurs - der Herr\nle chat - die Katze\nle chien - der Hund');
  expect(pairs(forms)[0]).toEqual(['le monsieur - messieurs', 'der Herr']);
});

test('3-cell rows without any 2-cell row still split by language', () => {
  const r = parseVocab('le monsieur\tmessieurs\tder Herr\nle cheval\tchevaux\tdas Pferd\nbeau\tbelle\tschön\nheureux\theureuse\tglücklich');
  expect(pairs(r)).toEqual([
    ['le monsieur, messieurs', 'der Herr'],
    ['le cheval, chevaux', 'das Pferd'],
    ['beau, belle', 'schön'],
    ['heureux, heureuse', 'glücklich'],
  ]);
  expect(flagged(r)).toEqual([]);
});

test('a part left on the wrong side of a 3-part split is flagged for review', () => {
  const r = parseVocab('le chat - die Katze - le chien\nla vache - die Kuh\nle cheval - das Pferd\nla souris - die Maus');
  expect(r.cards[0].flags).toContain('lowConfidence');
  expect(r.cards[1].flags).toEqual([]);
});

test('Quizlet comma export keeps ", " inside the fields', () => {
  const r = parseVocab(
    'beau, belle,schön\nle monsieur, messieurs,der Herr\nla plage,der Strand\nle soleil,die Sonne\nheureux, heureuse,glücklich\nnager,schwimmen\ngrand, grande,gross\nla mer,das Meer',
  );
  expect(r.format).toBe('delimited');
  expect(r.delimiter).toBe(',');
  expect(pairs(r)).toEqual([
    ['beau, belle', 'schön'],
    ['le monsieur, messieurs', 'der Herr'],
    ['la plage', 'der Strand'],
    ['le soleil', 'die Sonne'],
    ['heureux, heureuse', 'glücklich'],
    ['nager', 'schwimmen'],
    ['grand, grande', 'gross'],
    ['la mer', 'das Meer'],
  ]);
  expect(flagged(r)).toEqual([]);
  const few = parseVocab('la plage,der Strand\nle soleil,die Sonne\nnager,schwimmen\nbeau, belle,schön\ngrand, grande,gross\nla vague,die Welle');
  expect(pairs(few)).toEqual([
    ['la plage', 'der Strand'],
    ['le soleil', 'die Sonne'],
    ['nager', 'schwimmen'],
    ['beau, belle', 'schön'],
    ['grand, grande', 'gross'],
    ['la vague', 'die Welle'],
  ]);
});

test('number vocabulary keeps its numbers', () => {
  const dash = parseVocab('11 - onze\n12 - douze\n13 - treize\n14 - quatorze\n15 - quinze\n16 - seize\n20 - vingt\n21 - vingt et un\n30 - trente\n100 - cent');
  expect(dash.cards).toHaveLength(10);
  expect(pairs(dash).slice(0, 2)).toEqual([
    ['onze', '11'],
    ['douze', '12'],
  ]);
  expect(pairs(dash)).toContain(['vingt et un', '21']);
  expect(dash.termLang).toBe('fr');
  const colon = parseVocab('11: onze\n12: douze\n13: treize\n14: quatorze\n15: quinze');
  expect(pairs(colon)[4]).toEqual(['quinze', '15']);
  const alt = parseVocab('onze\n11\ndouze\n12\ntreize\n13\nquatorze\n14\nquinze\n15');
  expect(pairs(alt)).toEqual([
    ['onze', '11'],
    ['douze', '12'],
    ['treize', '13'],
    ['quatorze', '14'],
    ['quinze', '15'],
  ]);
  expect(alt.skipped).toEqual([]);
  // Real list numbering is still removed.
  const numbered = parseVocab('1 - le chat - die Katze\n2 - le chien - der Hund\n3 - la vache - die Kuh\n4 - le cheval - das Pferd');
  expect(pairs(numbered)[0]).toEqual(['le chat', 'die Katze']);
  expect(numbered.cards).toHaveLength(4);
});

test('3-cell rows: example sentences and note columns are dropped, forms are merged', () => {
  const sentence = parseVocab(
    'le chat\tdie Katze\tLe chat dort sur le lit.\nle chien\tder Hund\tLe chien aboie.\nla maison\tdas Haus\tLa maison est grande et belle.\nle jardin\tder Garten\tJe travaille dans le jardin.',
  );
  expect(pairs(sentence)).toEqual([
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la maison', 'das Haus'],
    ['le jardin', 'der Garten'],
  ]);
  const klett = parseVocab(
    'la maison\tMa maison est grande.\tdas Haus\nle chat\tLe chat dort sur le lit.\tdie Katze\nle chien\tLe chien aboie très fort.\tder Hund\nle jardin\tLe jardin est très beau.\tder Garten',
  );
  expect(pairs(klett)).toEqual([
    ['la maison', 'das Haus'],
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['le jardin', 'der Garten'],
  ]);
  const notes = parseVocab('la maison\tdas Haus\tNomen, f.\nle chat\tdie Katze\tNomen, m.\nmanger\tessen\tVerb\nle chien\tder Hund\tNomen, m.');
  expect(pairs(notes)).toEqual([
    ['la maison', 'das Haus'],
    ['le chat', 'die Katze'],
    ['manger', 'essen'],
    ['le chien', 'der Hund'],
  ]);
  const german = parseVocab('le chat\tdie Katze\tDie Katze schläft.\nle chien\tder Hund\tDer Hund bellt.\nla maison\tdas Haus\tDas Haus ist gross.');
  expect(pairs(german)[0]).toEqual(['le chat', 'die Katze']);
  const synonyms = parseVocab('beau\tschön\thübsch\ngrand\tgross\thoch\npetit\tklein\tgering');
  expect(pairs(synonyms)[0]).toEqual(['beau', 'schön, hübsch']);
});

test('3-cell rows in three languages keep the German column and are flagged', () => {
  const r = parseVocab('cat\tle chat\tdie Katze\ndog\tle chien\tder Hund\nhouse\tla maison\tdas Haus\ncow\tla vache\tdie Kuh');
  expect(r.cards).toHaveLength(4);
  expect(r.cards.filter((c) => c.definition.includes('die Katze'))).toHaveLength(1);
  for (const c of r.cards) expect(c.flags).toContain('lowConfidence');
  expect(r.defLang).toBe('de');
});

test('two page columns of "term – definition" entries give one card per entry, left column first', () => {
  const left = [
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la vache', 'die Kuh'],
  ];
  const right = [
    ['le lapin', 'das Kaninchen'],
    ['la poule', 'das Huhn'],
    ['le canard', 'die Ente'],
  ];
  const text = left.map(([t, d], i) => `${t} – ${d}\t${right[i][0]} – ${right[i][1]}`).join('\n');
  const r = parseVocab(text);
  expect(pairs(r)).toEqual([...left, ...right]);
  expect(flagged(r)).toEqual([]);
  // A page column that ends early leaves an empty cell.
  const uneven = parseVocab(`${text}\nle cheval – das Pferd\n\tle renard – der Fuchs`);
  expect(pairs(uneven)).toEqual([...left, ['le cheval', 'das Pferd'], ...right, ['le renard', 'der Fuchs']]);
  // Pasted with a wide gap instead of a tab.
  const gap = parseVocab(left.map(([t, d], i) => `${t} – ${d}        ${right[i][0]} – ${right[i][1]}`).join('\n'));
  expect(pairs(gap)).toEqual([...left, ...right]);
  // Verb forms on both sides are not page columns.
  const forms = parseVocab('aller - allé\tgehen - gegangen\nvenir - venu\tkommen - gekommen\nprendre - pris\tnehmen - genommen\nfaire - fait\tmachen - gemacht');
  expect(pairs(forms)[0]).toEqual(['aller - allé', 'gehen - gegangen']);
});

test('column order survives a misdetected first or last line', () => {
  const r = parseVocab(
    'timide\ndrôle\nsérieux, sérieuse\npoli, polie\ncalme\nsage\nbrave\ncharmant, charmante\nschüchtern\nlustig\nernst\nhöflich\nruhig\nbrav\nlieb\ncharmant',
  );
  expect(r.format).toBe('columns');
  expect(pairs(r)).toEqual([
    ['timide', 'schüchtern'],
    ['drôle', 'lustig'],
    ['sérieux, sérieuse', 'ernst'],
    ['poli, polie', 'höflich'],
    ['calme', 'ruhig'],
    ['sage', 'brav'],
    ['brave', 'lieb'],
    ['charmant, charmante', 'charmant'],
  ]);
  const first = parseVocab('plein, pleine\nle chat\nle chien\nla vache\nle cheval\nla souris\nvoll\ndie Katze\nder Hund\ndie Kuh\ndas Pferd\ndie Maus');
  expect(first.format).toBe('columns');
  expect(pairs(first)[0]).toEqual(['plein, pleine', 'voll']);
  expect(pairs(first)[5]).toEqual(['la souris', 'die Maus']);
});

test('mixed separators: each line is split at its own tab or dash', () => {
  const r = parseVocab(
    'le pantalon - die Hose\nla chemise\tdas Hemd\nle pull\tder Pullover\nla jupe - der Rock\nle short\tdie kurze Hose\nla robe - das Kleid\nle manteau - der Mantel\nle lit\tdas Bett\nles chaussures - die Schuhe\nle chapeau\tder Hut',
  );
  expect(pairs(r)).toEqual([
    ['le pantalon', 'die Hose'],
    ['la chemise', 'das Hemd'],
    ['le pull', 'der Pullover'],
    ['la jupe', 'der Rock'],
    ['le short', 'die kurze Hose'],
    ['la robe', 'das Kleid'],
    ['le manteau', 'der Mantel'],
    ['le lit', 'das Bett'],
    ['les chaussures', 'die Schuhe'],
    ['le chapeau', 'der Hut'],
  ]);
  expect(r.format).toBe('delimited');
  const more = parseVocab(
    'le pantalon - die Hose\nla chemise = das Hemd\nle pull\tder Pullover\nla jupe - der Rock\nle short = die kurze Hose\nla robe - das Kleid\nle manteau : der Mantel\nle lit : das Bett\nles chaussures - die Schuhe\nle chapeau\tder Hut',
  );
  expect(pairs(more)).toContain(['le short', 'die kurze Hose']);
  expect(pairs(more)).toContain(['le lit', 'das Bett']);
  expect(more.cards).toHaveLength(10);
  // A line written the other way round is turned around.
  const reversed = parseVocab(
    'le pantalon - die Hose\nla chemise\tdas Hemd\nle pull\tder Pullover\nder Rock - la jupe\nle short\tdie kurze Hose\nla robe - das Kleid\nle manteau - der Mantel\nle lit\tdas Bett\nles chaussures - die Schuhe\nle chapeau\tder Hut',
  );
  expect(pairs(reversed)[3]).toEqual(['la jupe', 'der Rock']);
});

test('mixed separators label the format as delimited', () => {
  const r = parseVocab(
    'le lit - das Bett\nle bus - der Bus\nle train - der Zug\nla table - der Tisch\nle sport - der Sport\nla radio = das Radio\nle film = der Film\nle fils = der Sohn\nle mur = die Wand\nle sol = der Boden',
  );
  expect(r.cards).toHaveLength(10);
  expect(r.format).toBe('delimited');
  expect(r.delimiter).toBe(' - ');
});

test('a cognate definition in an alternating list stays one card', () => {
  const text = 'calme\nruhig\nintelligent, intelligente\nintelligent\ntimide\nschüchtern\ndrôle\nlustig';
  const expected = [
    ['calme', 'ruhig'],
    ['intelligent, intelligente', 'intelligent'],
    ['timide', 'schüchtern'],
    ['drôle', 'lustig'],
  ];
  expect(pairs(parseVocab(text))).toEqual(expected);
  expect(pairs(parseVocab(text, { mode: 'lines' }))).toEqual(expected);
});

test('a section heading inside an alternating list is not merged into the next term', () => {
  for (const heading of ['Les couleurs', 'Couleurs', 'Adjectifs', 'B) Couleurs et formes', 'Les couleurs:']) {
    const r = parseVocab(`le chat\ndie Katze\nle chien\nder Hund\nla vache\ndie Kuh\n${heading}\nrouge\nrot\nbleu, bleue\nblau\nvert, verte\ngrün\njaune\ngelb`);
    expect(`${heading}: ${JSON.stringify(pairs(r)[3])}`).toBe(`${heading}: ${JSON.stringify(['rouge', 'rot'])}`);
    expect(r.cards).toHaveLength(7);
    expect(r.skipped.map((s) => s.text)).toEqual([heading]);
  }
});

test('French words ending in -ein / -eindre are French', () => {
  const r = parseVocab('peindre\nmalen\néteindre\nausschalten\natteindre\nerreichen\ncraindre\nfürchten\nplein, pleine\nvoll\nserein, sereine\ngelassen\nfreiner\nbremsen\nrejoindre\ntreffen');
  expect(r.cards).toHaveLength(8);
  expect(pairs(r)).toContain(['plein, pleine', 'voll']);
  expect(pairs(r)).toContain(['serein, sereine', 'gelassen']);
  const dash = parseVocab('plein, pleine - voll\nserein, sereine - gelassen\nfreiner - bremsen\npeindre - malen\natteindre - erreichen');
  expect(flagged(dash)).toEqual([]);
});

test('English school and media words are English; the picked language wins a close call', () => {
  const school = parseVocab(
    'homework - Hausaufgaben\nlesson - Lektion\npage - Seite\nunit - Einheit\nchapter - Kapitel\nexercise - Übung\nvocabulary - Wortschatz\ngrammar - Grammatik\nmodule - Modul\nsection - Abschnitt',
  );
  expect(school.termLang).toBe('en');
  const media = parseVocab(
    'newspaper - Zeitung\narticle - Artikel\nadvertisement - Werbung\nchannel - Sender\naudience - Publikum\njournalist - Journalist\ninterview - Interview\nopinion - Meinung\nsource - Quelle\ninformation - Information',
  );
  expect(media.termLang).toBe('en');
  // Words that are also French: detection alone says French, the hint decides.
  const shared = 'module - Modul\nsection - Abschnitt\npage - Seite\narticle - Artikel\naudience - Publikum\nsource - Quelle\nopinion - Meinung\nlesson - Lektion';
  const hinted = parseVocab(shared, { termLang: 'en' });
  expect(hinted.termLang).toBe('en');
  expect(flagged(hinted)).toEqual([]);
  // A clearly French list keeps French.
  expect(parseVocab('le chat - die Katze\nle chien - der Hund\nla maison - das Haus\nmanger - essen', { termLang: 'en' }).termLang).toBe('fr');
});

test('a table border on only one side is not part of the row', () => {
  const left = parseVocab('| le chat | die Katze\n| le chien | der Hund\n| la vache | die Kuh\n| le cheval | das Pferd\n| la souris | die Maus\n| le cochon | das Schwein');
  expect(left.delimiter).toBe('|');
  expect(pairs(left)[0]).toEqual(['le chat', 'die Katze']);
  expect(left.cards).toHaveLength(6);
  const right = parseVocab('le chat | die Katze |\nle chien | der Hund |\nla vache | die Kuh |\nle cheval | das Pferd |');
  expect(pairs(right)[3]).toEqual(['le cheval', 'das Pferd']);
  const missing = parseVocab('le chat | die Katze\nle chien |\nla vache | die Kuh\nle cheval | das Pferd');
  expect(pairs(missing)[1]).toEqual(['le chien', '']);
});

test('wrapped phrases are joined with a space, not a comma', () => {
  const blocks = parseVocab('se mettre en\ncolère\nwütend werden\n\navoir lieu\nstattfinden\n\nfaire la grasse\nmatinée\nausschlafen');
  expect(pairs(blocks)).toEqual([
    ['se mettre en colère', 'wütend werden'],
    ['avoir lieu', 'stattfinden'],
    ['faire la grasse matinée', 'ausschlafen'],
  ]);
  const tab = parseVocab("s'entendre avec qn\tsich mit jdm\nverstehen\navoir lieu\tstattfinden\nle chat\tdie Katze\nle chien\tder Hund");
  expect(pairs(tab)[0]).toEqual(["s'entendre avec qn", 'sich mit jdm verstehen']);
  const verb = parseVocab('se brosser les dents\nsich die Zähne\nputzen\n\nle chat\ndie Katze\n\nle chien\nder Hund');
  expect(pairs(verb)[0]).toEqual(['se brosser les dents', 'sich die Zähne putzen']);
  // Separate alternatives keep their comma.
  const alt = parseVocab('le chat\ndie Katze\nder Kater\n\nle chien\nder Hund\n\nla maison\ndas Haus');
  expect(pairs(alt)[0]).toEqual(['le chat', 'die Katze, der Kater']);
});

test('"both languages per line" lists keep every line', () => {
  const list = [
    ['attendre', 'warten'], ['oublier', 'vergessen'], ['essayer', 'versuchen'], ['chanter', 'singen'], ['danser', 'tanzen'],
    ['grandir', 'wachsen'], ['grossir', 'zunehmen'], ['maigrir', 'abnehmen'], ['emprunter', 'ausleihen'], ['prêter', 'leihen'],
    ['perdre', 'verlieren'], ['gagner', 'gewinnen'], ['peindre', 'malen'], ['dessiner', 'zeichnen'], ['écrire', 'schreiben'],
    ['lire', 'lesen'], ['dormir', 'schlafen'], ['manger', 'essen'], ['boire', 'trinken'], ['parler', 'sprechen'],
    ['chercher', 'suchen'], ['trouver', 'finden'], ['ouvrir', 'öffnen'], ['fermer', 'schliessen'], ['acheter', 'kaufen'],
    ['vendre', 'verkaufen'], ['payer', 'bezahlen'], ['courir', 'rennen'], ['nager', 'schwimmen'], ['voyager', 'reisen'],
  ];
  const r = parseVocab(list.map(([t, d]) => `${t} ${d}`).join('\n'));
  expect(r.format).toBe('delimited');
  expect(r.delimiter).toBe(' ');
  expect(pairs(r)).toEqual(list);
  expect(r.skipped).toEqual([]);
});

test('an en dash glued between words is the delimiter, not a hyphen', () => {
  const r = parseVocab("c'est-à-dire–das heisst\nle chat–die Katze\nle week-end–das Wochenende\npeut-être–vielleicht\nla grand-mère–die Grossmutter\nlà-bas–dort");
  expect(pairs(r)).toEqual([
    ["c'est-à-dire", 'das heisst'],
    ['le chat', 'die Katze'],
    ['le week-end', 'das Wochenende'],
    ['peut-être', 'vielleicht'],
    ['la grand-mère', 'die Grossmutter'],
    ['là-bas', 'dort'],
  ]);
  const short = parseVocab('le chat–die Katze\nle chien—der Hund\nla vache–die Kuh\nle cheval–das Pferd\nle week-end–das Wochenende');
  expect(short.cards).toHaveLength(5);
  expect(pairs(short)[4]).toEqual(['le week-end', 'das Wochenende']);
});

test('"vocabulary - Wortschatz" is a card, "Vocabulaire : les animaux" a heading', () => {
  const r = parseVocab('homework - Hausaufgaben\nlesson - Lektion\npage - Seite\nvocabulary - Wortschatz\ngrammar - Grammatik');
  expect(r.cards).toHaveLength(5);
  expect(pairs(r)).toContain(['vocabulary', 'Wortschatz']);
  expect(r.skipped).toEqual([]);
  expect(pairs(parseVocab('vocabulaire - Wortschatz\nle chat - die Katze\nle chien - der Hund'))[0]).toEqual(['vocabulaire', 'Wortschatz']);
  const headings = parseVocab('Wortschatz Unité 3\nVocabulaire : les animaux\nle chat - die Katze\nle chien - der Hund\nla vache - die Kuh');
  expect(headings.cards).toHaveLength(3);
  expect(headings.skipped.map((s) => s.reason)).toEqual(['heading', 'heading']);
});

test('the first line of a wrapped sentence term is kept, not skipped as a heading', () => {
  const blocks = parseVocab("Bonjour\nGuten Tag\n\nComment allez-vous\naujourd'hui ?\nWie geht es Ihnen heute?\n\nMerci beaucoup\nVielen Dank");
  expect(pairs(blocks)[1]).toEqual(["Comment allez-vous aujourd'hui ?", 'Wie geht es Ihnen heute?']);
  expect(blocks.cards[1].flags).toEqual(['merged']);
  expect(blocks.skipped).toEqual([]);
  const blocks2 = parseVocab(
    "Je voudrais un café\ns'il vous plaît\nIch hätte gern einen Kaffee, bitte\n\nComment tu t'appelles\net quel âge as-tu ?\nWie heisst du und wie alt bist du?\n\nJ'ai faim\nIch habe Hunger",
  );
  expect(pairs(blocks2).slice(0, 2)).toEqual([
    ["Je voudrais un café s'il vous plaît", 'Ich hätte gern einen Kaffee, bitte'],
    ["Comment tu t'appelles et quel âge as-tu ?", 'Wie heisst du und wie alt bist du?'],
  ]);
  expect(blocks2.skipped).toEqual([]);
  const question = parseVocab("Qu'est-ce que tu fais\nce week-end ?\nWas machst du dieses Wochenende?\n\nJ'ai faim\nIch habe Hunger\n\nOù habites-tu ?\nWo wohnst du?");
  expect(pairs(question)[0]).toEqual(["Qu'est-ce que tu fais ce week-end ?", 'Was machst du dieses Wochenende?']);
  const article = parseVocab("Il fait beau\naujourd'hui\nDas Wetter ist heute schön\n\nOù est\nla gare ?\nWo ist der Bahnhof?\n\nJ'ai faim\nIch habe Hunger");
  expect(pairs(article)[1]).toEqual(['Où est la gare ?', 'Wo ist der Bahnhof?']);
  // Alternating lines without blank lines, French and English.
  const alt = parseVocab("le chat\ndie Katze\nComment tu t'appelles\net quel âge as-tu ?\nWie heisst du und wie alt bist du?\nle chien\nder Hund\nla vache\ndie Kuh");
  expect(pairs(alt)[1]).toEqual(["Comment tu t'appelles et quel âge as-tu ?", 'Wie heisst du und wie alt bist du?']);
  expect(alt.skipped).toEqual([]);
  const en = parseVocab('the dog\nder Hund\nThe weather is nice\ntoday\nDas Wetter ist heute schön\nthe cat\ndie Katze\nThank you\nvery much\nVielen Dank\nthe cow\ndie Kuh');
  expect(pairs(en)[1]).toEqual(['The weather is nice today', 'Das Wetter ist heute schön']);
  expect(en.cards[3].term).toContain('Thank you');
  expect(en.cards[3].term).toContain('very much');
  expect(en.skipped).toEqual([]);
  // A heading before a group of entries is still skipped.
  const nombres = parseVocab('le chat\ndie Katze\nle chien\nder Hund\nLes nombres\nvingt et un\neinundzwanzig\ntrente\ndreissig\ncent\nhundert');
  expect(pairs(nombres)[2]).toEqual(['vingt et un', 'einundzwanzig']);
  expect(nombres.skipped.map((s) => [s.text, s.reason])).toEqual([['Les nombres', 'heading']]);
});

test('bare numbers before the entries of a table are numbering, not number vocabulary', () => {
  const expected = [
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la vache', 'die Kuh'],
    ['le cheval', 'das Pferd'],
  ];
  const rows = (fmt) => expected.map(([t, d], i) => `${i + 1}\n${fmt(t, d)}`);
  for (const [name, text] of [
    ['dash', rows((t, d) => `${t} - ${d}`).join('\n')],
    ['tab', rows((t, d) => `${t}\t${d}`).join('\n')],
    ['lines', rows((t, d) => `${t}\n${d}`).join('\n')],
    ['blocks', rows((t, d) => `${t}\n${d}`).join('\n\n')],
    ['bilingual', rows((t, d) => `${t} ${d}`).join('\n')],
  ]) {
    const r = parseVocab(text);
    expect(`${name}: ${JSON.stringify(pairs(r))}`).toBe(`${name}: ${JSON.stringify(expected)}`);
    expect(`${name}: ${r.skipped.map((s) => s.reason).join(',')}`).toBe(`${name}: pageNumber,pageNumber,pageNumber,pageNumber`);
  }
  // Number vocabulary on alternating lines and in blocks keeps its numbers.
  expect(pairs(parseVocab('11\nonze\n12\ndouze\n13\ntreize\n14\nquatorze'))[3]).toEqual(['quatorze', '14']);
  expect(pairs(parseVocab('onze\n11\n\ndouze\n12\n\ntreize\n13'))[2]).toEqual(['treize', '13']);
});

test('en dashes inside compounds of line-based lists stay hyphens', () => {
  const blocks = parseVocab("l'amitié franco–allemande\ndie deutsch-französische Freundschaft\n\nle chat\ndie Katze\n\nle chien\nder Hund\n\nla vache\ndie Kuh");
  expect(pairs(blocks)[0]).toEqual(["l'amitié franco-allemande", 'die deutsch-französische Freundschaft']);
  const alt = parseVocab('le chat\ndie Katze\nla relation mère–fille\ndie Mutter-Tochter-Beziehung\nle chien\nder Hund\nle trajet Paris–Berlin\ndie Strecke Paris-Berlin');
  expect(pairs(alt)[1]).toEqual(['la relation mère-fille', 'die Mutter-Tochter-Beziehung']);
  expect(pairs(alt)[3]).toEqual(['le trajet Paris-Berlin', 'die Strecke Paris-Berlin']);
  // A glued en dash mixed into a list of spaced dashes is still the delimiter.
  const mixed = parseVocab('le chat – die Katze\nle week-end–das Wochenende\nla vache – die Kuh\nle cheval – das Pferd');
  expect(pairs(mixed)[1]).toEqual(['le week-end', 'das Wochenende']);
  // The user picked the tab: the dash belongs to the term.
  const tab = parseVocab('la relation mère–fille\tdie Mutter-Tochter-Beziehung\nle chat\tdie Katze', { mode: 'delimiter', delimiter: '\t' });
  expect(pairs(tab)[0]).toEqual(['la relation mère-fille', 'die Mutter-Tochter-Beziehung']);
});

test('a right page column that ends early still splits every entry, left column first', () => {
  const left = [
    ['le chat', 'die Katze'],
    ['le chien', 'der Hund'],
    ['la vache', 'die Kuh'],
    ['le cheval', 'das Pferd'],
    ['la souris', 'die Maus'],
    ['le cochon', 'das Schwein'],
    ['la poule', 'das Huhn'],
  ];
  const right = [
    ['le lapin', 'das Kaninchen'],
    ['le mouton', 'das Schaf'],
  ];
  for (const sep of ['\t', '        ']) {
    const text = left.map(([t, d], i) => (right[i] ? `${t} – ${d}${sep}${right[i][0]} – ${right[i][1]}` : `${t} – ${d}`)).join('\n');
    const r = parseVocab(text);
    expect(pairs(r)).toEqual([...left, ...right]);
    expect(flagged(r)).toEqual([]);
  }
  const equals = parseVocab(left.map(([t, d], i) => (right[i] ? `${t}=${d}      ${right[i][0]}=${right[i][1]}` : `${t}=${d}`)).join('\n'));
  expect(pairs(equals)).toEqual([...left, ...right]);
  // A dash list with notes after a wide gap is not two page columns.
  const notes = parseVocab('le chat - die Katze   (f)\nle chien - der Hund\nla vache - die Kuh   (f)\nle cheval - das Pferd');
  expect(pairs(notes)[0]).toEqual(['le chat', 'die Katze (f)']);
});

test('German -ein / -einte words next to French -ein words keep their language', () => {
  const r = parseVocab('uni, unie - vereint\npleurer - weinen\npenser - meinen\nplein, pleine - voll\nserein, sereine - gelassen\nla pierre - der Stein');
  expect(r.cards).toHaveLength(6);
  expect(flagged(r)).toEqual([]);
  const alt = parseVocab('pleurer\nweinen\nil pleurait\ner weinte\nil pensait\ner meinte\nuni, unie\nvereint');
  expect(pairs(alt)[3]).toEqual(['uni, unie', 'vereint']);
  expect(flagged(alt)).toEqual([]);
});

// ---------------------------------------------------------------------------
// One word per side without a delimiter: "Bonjour Hallo" used to be skipped as
// a heading, and a list of such lines was read as alternating lines.

test('a single line with a greeting on each side is one card', () => {
  for (const [fr, de] of [['Bonjour', 'Hallo'], ['Merci', 'Danke'], ['Salut', 'Hallo'], ['Oui', 'Ja'], ['chien', 'Hund']]) {
    const r = parseVocab(`${fr} ${de}`);
    expect(pairs(r)).toEqual([[fr, de]]);
    expect(r.skipped).toEqual([]);
    expect(`${r.termLang}/${r.defLang}`).toBe('fr/de');
  }
});

test('a list of greetings is split on every line, not paired line by line', () => {
  const r = parseVocab('Bonjour Hallo\nMerci Danke\nAu revoir Tschüss\nOui Ja\nNon Nein');
  expect(r.format).toBe('delimited');
  expect(r.delimiter).toBe(' ');
  expect(pairs(r)).toEqual([['Bonjour', 'Hallo'], ['Merci', 'Danke'], ['Au revoir', 'Tschüss'], ['Oui', 'Ja'], ['Non', 'Nein']]);
  expect(flagged(r)).toEqual([]);
});

test('a two-word line with a weak side is kept instead of dropped', () => {
  // "chien" looks a little German ("ch", "ie").
  const r = parseVocab("Salut Hallo\nBonsoir Guten Abend\nS'il vous plaît Bitte\nmaison Haus\nchien Hund");
  expect(pairs(r)).toEqual([['Salut', 'Hallo'], ['Bonsoir', 'Guten Abend'], ["S'il vous plaît", 'Bitte'], ['maison', 'Haus'], ['chien', 'Hund']]);
  const words = parseVocab('les grands-parents die Grosseltern\nle stylo der Kugelschreiber\ngrandir wachsen\nl’enfant das Kind');
  expect(pairs(words)[2]).toEqual(['grandir', 'wachsen']);
});

test('alternating lines of two words in one language stay alternating', () => {
  const r = parseVocab('le chien\nder Hund\nla maison\ndas Haus\nGuten Tag\nBonjour');
  expect(r.format).toBe('alternating');
  expect(pairs(r)).toEqual([['le chien', 'der Hund'], ['la maison', 'das Haus'], ['Bonjour', 'Guten Tag']]);
});

await run('parser.test.js');
