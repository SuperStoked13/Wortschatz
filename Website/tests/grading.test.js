import { test, expect, run } from './harness.js';
import {
  grade,
  splitAlternatives,
  diffChars,
  diffAnswer,
  ARTICLES,
  REFLEXIVES,
  GLUED_ARTICLES,
  ABBREVIATIONS,
  DEFAULT_TOLERANCE,
} from '../src/core/grading.js';

const ALL_OFF = {
  articles: false,
  abbreviations: false,
  multipleAnswers: false,
  parentheses: false,
  ignoreCase: false,
  ignoreAccents: false,
  typos: false,
};
const ALL_ON = {
  articles: true,
  abbreviations: true,
  multipleAnswers: true,
  parentheses: true,
  ignoreCase: true,
  ignoreAccents: true,
  typos: true,
};

const q = (v) => JSON.stringify(v);

// Asserts the answer is accepted; checks notes when given.
function accepts(given, expected, lang, tol = null, notes = undefined) {
  const r = grade(given, expected, tol, lang);
  if (!r.correct) throw new Error(`${q(given)} should be correct for ${q(expected)} (hint ${r.hint})`);
  expect(r.hint).toBe(null);
  if (notes !== undefined) expect(r.notes).toEqual(notes);
  return r;
}

// Asserts the answer is rejected; checks the hint when given.
function rejects(given, expected, lang, tol = null, hint = undefined) {
  const r = grade(given, expected, tol, lang);
  if (r.correct) throw new Error(`${q(given)} should be wrong for ${q(expected)} (notes ${q(r.notes)})`);
  expect(r.exact).toBe(false);
  expect(r.notes).toEqual([]);
  if (hint !== undefined) expect(r.hint).toBe(hint);
  return r;
}

function exactMatch(given, expected, lang, tol = null) {
  const r = accepts(given, expected, lang, tol, []);
  expect(r.exact).toBe(true);
}

// The 52 pairs of tests/fixtures/user-example.txt (term = French, definition = German).
const PAIRS = [
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
// Fixture: every pair in both directions

test('fixture: inline pairs match tests/fixtures/user-example.txt', () => {
  expect(PAIRS).toHaveLength(52);
  if (typeof read !== 'function') return;
  const text = read('fixtures/user-example.txt');
  const blocks = text
    .split(/\n\s*\n/)
    .map((b) => b.split('\n').map((l) => l.trim()).filter(Boolean))
    .filter((b) => b.length);
  expect(blocks.map((b) => [b[0], b[1]])).toEqual(PAIRS);
});

PAIRS.forEach(([term, def], i) => {
  test(`fixture #${i + 1} answer in French is exact: ${term}`, () => {
    for (const tol of [null, ALL_OFF, ALL_ON]) exactMatch(term, term, 'fr', tol);
  });
  test(`fixture #${i + 1} answer in German is exact: ${def}`, () => {
    for (const tol of [null, ALL_OFF, ALL_ON]) exactMatch(def, def, 'de', tol);
  });
});

test('fixture: each single alternative is a partial answer (multipleAnswers ON) and wrong when OFF', () => {
  let checked = 0;
  for (const [term, def] of PAIRS) {
    for (const [stored, lang] of [[term, 'fr'], [def, 'de']]) {
      const alts = splitAlternatives(stored);
      if (alts.length < 2) continue;
      for (const alt of alts) {
        const r = accepts(alt, stored, lang);
        expect(r.notes).toContain('partial');
        rejects(alt, stored, lang, { multipleAnswers: false });
        checked++;
      }
    }
  }
  expect(checked).toBeGreaterThan(30);
});

test('fixture: all alternatives in reverse order are accepted with note order', () => {
  for (const [term, def] of PAIRS) {
    for (const [stored, lang] of [[term, 'fr'], [def, 'de']]) {
      const alts = splitAlternatives(stored);
      if (alts.length < 2) continue;
      const reversed = [...alts].reverse().join(', ');
      expect(accepts(reversed, stored, lang).notes).toContain('order');
      expect(accepts(reversed, stored, lang, { multipleAnswers: false }).notes).toContain('order');
    }
  }
});

test('fixture: French nouns without article are accepted (articles ON) and wrong when OFF', () => {
  let checked = 0;
  for (const [term] of PAIRS) {
    const m = term.match(/^(?:(?:les|le|la) |l')([^,]+)$/);
    if (!m) continue;
    const bare = m[1].trim();
    expect(accepts(bare, term, 'fr', null).notes).toEqual(['article']);
    rejects(bare, term, 'fr', { articles: false }, 'missingArticle');
    checked++;
  }
  expect(checked).toBeGreaterThanOrEqual(20);
});

test('fixture: German nouns without article are accepted (articles ON) and wrong when OFF', () => {
  let checked = 0;
  for (const [, def] of PAIRS) {
    const m = def.match(/^(der|die|das) ([^,]+)$/);
    if (!m) continue;
    expect(accepts(m[2], def, 'de').notes).toEqual(['article']);
    rejects(m[2], def, 'de', { articles: false }, 'missingArticle');
    checked++;
  }
  expect(checked).toBeGreaterThanOrEqual(15);
});

test('fixture: a different card\'s answer is never accepted', () => {
  rejects('der Mann', 'der Herr', 'de');
  rejects('die Frau', 'die Dame', 'de');
  rejects('nennen', 'heissen', 'de');
  rejects('la fille', 'le garçon', 'fr');
  rejects('veuf', 'marié, mariée', 'fr');
  rejects('calme', 'tranquille', 'fr', ALL_ON);
});

// ---------------------------------------------------------------------------
// Always-on normalisation

test('always: identical answer is exact with no notes and no hint', () => {
  const r = grade('der Herr', 'der Herr', null, 'de');
  expect(r).toEqual({ correct: true, exact: true, notes: [], hint: null, expectedDisplay: 'der Herr' });
});

test('always: expectedDisplay is the stored answer unchanged', () => {
  expect(grade('x', 'le monsieur, messieurs', null, 'fr').expectedDisplay).toBe('le monsieur, messieurs');
  expect(grade('Herr', 'der Herr', null, 'de').expectedDisplay).toBe('der Herr');
  expect(grade('x', null, null, 'de').expectedDisplay).toBe('');
});

test('always: extra whitespace is ignored', () => {
  exactMatch('  der    Herr  ', 'der Herr', 'de', ALL_OFF);
  exactMatch('le\tnom de\nfamille', 'le nom de famille', 'fr', ALL_OFF);
});

test('always: curly apostrophes equal straight ones', () => {
  exactMatch('l’homme', "l'homme", 'fr', ALL_OFF);
  exactMatch("l'homme", 'l’homme', 'fr', ALL_OFF);
});

test('always: spaces next to apostrophes are removed', () => {
  exactMatch("s' appeler", "s'appeler", 'fr', ALL_OFF);
  exactMatch("s 'appeler", "s'appeler", 'fr', ALL_OFF);
  exactMatch("l' homme", "l'homme", 'fr', ALL_OFF);
});

test('always: sharp s equals ss and counts as exact', () => {
  exactMatch('Straße', 'Strasse', 'de', ALL_OFF);
  exactMatch('heißen', 'heissen', 'de', ALL_OFF);
  exactMatch('heissen', 'heißen', 'de', ALL_OFF);
  exactMatch('die Straße', 'die Strasse', 'de', ALL_OFF);
});

test('always: oe and ae ligatures equal their spelled-out forms', () => {
  exactMatch('cœur', 'coeur', 'fr', ALL_OFF);
  exactMatch('le coeur', 'le cœur', 'fr', ALL_OFF);
  exactMatch('ex æquo', 'ex aequo', 'fr', ALL_OFF);
  exactMatch('Œuvre', 'Oeuvre', 'fr', ALL_OFF);
});

test('always: hyphen equals space', () => {
  exactMatch("c'est à dire", "c'est-à-dire", 'fr', ALL_OFF);
  exactMatch('e-mail', 'e mail', 'en', ALL_OFF);
  exactMatch('Grand–mère', 'Grand-mère', 'fr', ALL_OFF);
});

test('always: punctuation is ignored', () => {
  exactMatch('der Herr.', 'der Herr', 'de', ALL_OFF);
  exactMatch('Hallo!', 'Hallo', 'de', ALL_OFF);
  exactMatch("Wie geht's", "Wie geht's?", 'de', ALL_OFF);
  exactMatch('« bonjour »', 'bonjour', 'fr', ALL_OFF);
  exactMatch('¿qué?', 'qué', 'es', ALL_OFF);
  exactMatch('ja…', 'ja', 'de', ALL_OFF);
});

test('always: decomposed (NFD) input equals composed text', () => {
  exactMatch('séparée'.normalize('NFD'), 'séparée', 'fr', ALL_OFF);
  exactMatch('Mädchen', 'Mädchen'.normalize('NFD'), 'de', ALL_OFF);
});

test('always: empty answers are incorrect', () => {
  for (const given of ['', '   ', null, undefined, '\n\t']) {
    rejects(given, 'der Herr', 'de', null, null);
    rejects(given, 'der Herr', 'de', ALL_ON, null);
  }
});

test('always: punctuation-only answers are incorrect', () => {
  rejects('...', 'der Herr', 'de', ALL_ON);
  rejects(',', 'lieb, nett', 'de', ALL_ON);
  rejects('?', 'lieb', 'de', ALL_ON);
});

test('always: an unrelated answer is incorrect without a hint', () => {
  rejects('Katze', 'der Herr', 'de', null, null);
  rejects('voiture', 'la maison', 'fr', ALL_ON, null);
});

test('always: an empty stored answer never accepts anything', () => {
  rejects('irgendwas', '', 'de', ALL_ON);
  rejects('irgendwas', '   ', 'de', ALL_ON);
});

// ---------------------------------------------------------------------------
// multipleAnswers

test('multipleAnswers ON: one of two answers is enough (partial)', () => {
  accepts('lieb', 'lieb, nett', 'de', null, ['partial']);
  accepts('nett', 'lieb, nett', 'de', null, ['partial']);
});

test('multipleAnswers ON: both answers reordered → note order', () => {
  accepts('nett, lieb', 'lieb, nett', 'de', null, ['order']);
});

test('multipleAnswers ON: both answers in order is exact; separators are interchangeable', () => {
  exactMatch('lieb, nett', 'lieb, nett', 'de');
  exactMatch('lieb,nett', 'lieb, nett', 'de');
  exactMatch('lieb; nett', 'lieb, nett', 'de');
});

test('multipleAnswers ON: only , ; / split the answer (not spaces)', () => {
  rejects('lieb nett', 'lieb, nett', 'de', null, 'almost');
});

test('multipleAnswers ON: "le monsieur, messieurs" accepts "monsieur" (article + partial)', () => {
  accepts('monsieur', 'le monsieur, messieurs', 'fr', null, ['article', 'partial']);
  accepts('messieurs', 'le monsieur, messieurs', 'fr', null, ['partial']);
  accepts('le monsieur', 'le monsieur, messieurs', 'fr', null, ['partial']);
});

test('multipleAnswers ON: "beau, bel, belle" accepts any single form', () => {
  accepts('belle', 'beau, bel, belle', 'fr', null, ['partial']);
  accepts('bel', 'beau, bel, belle', 'fr', null, ['partial']);
  accepts('beau, belle', 'beau, bel, belle', 'fr', null, ['partial']);
});

test('multipleAnswers ON: "das Haar, die Haare" accepts "Haare" (article + partial)', () => {
  accepts('Haare', 'das Haar, die Haare', 'de', null, ['article', 'partial']);
  accepts('die Haare', 'das Haar, die Haare', 'de', null, ['partial']);
  accepts('das Haar', 'das Haar, die Haare', 'de', null, ['partial']);
});

test('multipleAnswers ON: gender pairs "marié, mariée" accept either form', () => {
  accepts('mariée', 'marié, mariée', 'fr', null, ['partial']);
  accepts('marié', 'marié, mariée', 'fr', null, ['partial']);
});

test('multipleAnswers ON: a wrong extra part makes the answer wrong', () => {
  rejects('lieb, böse', 'lieb, nett', 'de');
  rejects('lieb, nett', 'lieb', 'de');
});

test('multipleAnswers ON: repeating one alternative is still a partial answer', () => {
  accepts('lieb, lieb', 'lieb, nett', 'de', null, ['partial']);
});

test('multipleAnswers ON: "der Familienname, der Nachname" accepts "Nachname"', () => {
  accepts('Nachname', 'der Familienname, der Nachname', 'de', null, ['article', 'partial']);
});

test('multipleAnswers ON: slash alternatives "beau/belle"', () => {
  accepts('belle', 'beau/belle', 'fr', null, ['partial']);
  accepts('beau / belle', 'beau/belle', 'fr');
  accepts('belle', 'beau / belle', 'fr', null, ['partial']);
});

test('multipleAnswers ON: "der/die Angestellte" accepts either article', () => {
  accepts('die Angestellte', 'der/die Angestellte', 'de', null, ['partial']);
  accepts('der Angestellte', 'der/die Angestellte', 'de', null, ['partial']);
  exactMatch('der/die Angestellte', 'der/die Angestellte', 'de');
});

test('multipleAnswers ON: "le/la secrétaire" accepts "la secrétaire"', () => {
  accepts('la secrétaire', 'le/la secrétaire', 'fr', null, ['partial']);
});

test('multipleAnswers ON: suffix notation "Lehrer/in" is one answer', () => {
  rejects('Lehrer', 'Lehrer/in', 'de');
  exactMatch('Lehrer/in', 'Lehrer/in', 'de');
});

test('multipleAnswers OFF: one of two answers is wrong', () => {
  rejects('lieb', 'lieb, nett', 'de', { multipleAnswers: false });
  rejects('marié', 'marié, mariée', 'fr', { multipleAnswers: false });
  rejects('Haare', 'das Haar, die Haare', 'de', { multipleAnswers: false });
});

test('multipleAnswers OFF: all answers in any order are accepted', () => {
  exactMatch('lieb, nett', 'lieb, nett', 'de', { multipleAnswers: false });
  accepts('nett, lieb', 'lieb, nett', 'de', { multipleAnswers: false }, ['order']);
  accepts('belle, beau, bel', 'beau, bel, belle', 'fr', { multipleAnswers: false }, ['order']);
});

test('multipleAnswers OFF: other tolerances still apply per part', () => {
  accepts('monsieur, messieurs', 'le monsieur, messieurs', 'fr', { multipleAnswers: false }, ['article']);
});

test('multipleAnswers OFF: a duplicated part does not cover a missing one', () => {
  rejects('lieb, lieb', 'lieb, nett', 'de', { multipleAnswers: false });
});

// ---------------------------------------------------------------------------
// splitAlternatives

test('splitAlternatives: commas and semicolons', () => {
  expect(splitAlternatives('lieb, nett')).toEqual(['lieb', 'nett']);
  expect(splitAlternatives('gut; gütig')).toEqual(['gut', 'gütig']);
  expect(splitAlternatives('a,, b ;')).toEqual(['a', 'b']);
  expect(splitAlternatives('der Herr')).toEqual(['der Herr']);
});

test('splitAlternatives: separators inside brackets and between digits do not split', () => {
  expect(splitAlternatives('(sich) freuen (über, auf)')).toEqual(['(sich) freuen (über, auf)']);
  expect(splitAlternatives('1,5 kg')).toEqual(['1,5 kg']);
});

test('splitAlternatives: slash rules', () => {
  expect(splitAlternatives('beau/belle')).toEqual(['beau', 'belle']);
  expect(splitAlternatives('beau/bel/belle')).toEqual(['beau', 'bel', 'belle']);
  expect(splitAlternatives('Lehrer/in')).toEqual(['Lehrer/in']);
  expect(splitAlternatives('Lehrer/innen')).toEqual(['Lehrer/innen']);
  expect(splitAlternatives('km/h')).toEqual(['km/h']);
  expect(splitAlternatives('marié/e')).toEqual(['marié/e']);
});

test('splitAlternatives: slash binds words or whole phrases sensibly', () => {
  expect(splitAlternatives('der/die Angestellte')).toEqual(['der Angestellte', 'die Angestellte']);
  expect(splitAlternatives('der Lehrer/die Lehrerin')).toEqual(['der Lehrer', 'die Lehrerin']);
  expect(splitAlternatives('le chat/la chatte')).toEqual(['le chat', 'la chatte']);
  expect(splitAlternatives('etw. tun/machen')).toEqual(['etw. tun', 'etw. machen']);
  expect(splitAlternatives("l'homme/la femme")).toEqual(["l'homme", 'la femme']);
  expect(splitAlternatives("s'appeler/se nommer")).toEqual(["s'appeler", 'se nommer']);
});

test('splitAlternatives: spaced slash always separates', () => {
  expect(splitAlternatives('beau / belle')).toEqual(['beau', 'belle']);
});

test('splitAlternatives: odd inputs', () => {
  expect(splitAlternatives('')).toEqual([]);
  expect(splitAlternatives(null)).toEqual([]);
  expect(splitAlternatives(undefined)).toEqual([]);
  expect(splitAlternatives(42)).toEqual(['42']);
  expect(splitAlternatives('...')).toEqual([]);
  expect(splitAlternatives('lieb, lieb')).toEqual(['lieb']);
});

// ---------------------------------------------------------------------------
// parentheses

test('parentheses ON: "(sich) freuen" accepts "freuen" and "sich freuen"', () => {
  accepts('freuen', '(sich) freuen', 'de', null, ['parentheses']);
  const r = accepts('sich freuen', '(sich) freuen', 'de', null, []);
  expect(r.exact).toBe(false);
});

test('parentheses ON: "marié(e)" accepts "marié" and "mariée"', () => {
  accepts('marié', 'marié(e)', 'fr', null, ['parentheses']);
  accepts('mariée', 'marié(e)', 'fr', null, []);
});

test('parentheses ON: typing the brackets is exact', () => {
  exactMatch('(sich) freuen', '(sich) freuen', 'de');
  exactMatch('marié(e)', 'marié(e)', 'fr');
});

test('parentheses ON: alternatives inside brackets', () => {
  accepts('freuen über', 'freuen (über, auf)', 'de', null, []);
  accepts('freuen auf', 'freuen (über, auf)', 'de', null, []);
  accepts('freuen', 'freuen (über, auf)', 'de', null, ['parentheses']);
  accepts('freuen über, auf', 'freuen (über, auf)', 'de', null, []);
});

test('parentheses ON: optional word in the middle', () => {
  accepts('la fille', 'la (petite) fille', 'fr', null, ['parentheses']);
  accepts('la petite fille', 'la (petite) fille', 'fr', null, []);
  accepts('fille', 'la (petite) fille', 'fr', null, ['article', 'parentheses']);
});

test('parentheses ON: square brackets work the same way', () => {
  accepts('freuen', '[sich] freuen', 'de', null, ['parentheses']);
});

test('parentheses OFF: "freuen" for "(sich) freuen" is incorrect', () => {
  rejects('freuen', '(sich) freuen', 'de', { parentheses: false }, 'missingArticle');
  rejects('freuen', '(sich) freuen', 'de', { parentheses: false, articles: false }, 'missingArticle');
});

test('parentheses OFF: the full content is still accepted', () => {
  accepts('sich freuen', '(sich) freuen', 'de', { parentheses: false }, []);
  accepts('mariée', 'marié(e)', 'fr', { parentheses: false }, []);
});

test('parentheses OFF: "marié" for "marié(e)" is incorrect (hint typo)', () => {
  rejects('marié', 'marié(e)', 'fr', { parentheses: false }, 'typo');
});

test('parentheses: unbalanced brackets never break grading', () => {
  accepts('mariée', 'marié(e', 'fr');
  accepts('freuen', 'freuen)', 'de');
});

// ---------------------------------------------------------------------------
// articles: French

test('articles ON: "homme" for "l\'homme" → note article', () => {
  const r = accepts('homme', "l'homme", 'fr', null, ['article']);
  expect(r.exact).toBe(false);
});

test('articles: elision "le homme" / "la homme" equals "l\'homme"', () => {
  accepts('le homme', "l'homme", 'fr', null, []);
  accepts('la homme', "l'homme", 'fr', null, []);
  accepts('le homme', "l'homme", 'fr', { articles: false }, []);
  accepts("l'enfant", 'le enfant', 'fr', null, []);
});

test('articles OFF: "homme" for "l\'homme" is wrong (missingArticle)', () => {
  rejects('homme', "l'homme", 'fr', { articles: false }, 'missingArticle');
});

test('articles: a wrong article is always wrong', () => {
  for (const tol of [null, { articles: false }, ALL_ON]) {
    rejects('la monsieur', 'le monsieur, messieurs', 'fr', tol, 'wrongArticle');
    rejects('un homme', "l'homme", 'fr', tol, 'wrongArticle');
    rejects('la garçon', 'le garçon', 'fr', tol, 'wrongArticle');
    rejects('le cheveux', 'les cheveux', 'fr', tol, 'wrongArticle');
  }
});

test('articles: multi-word nouns', () => {
  accepts('nom de famille', 'le nom de famille', 'fr', null, ['article']);
  accepts('numéro de la maison', 'le numéro de la maison', 'fr', null, ['article']);
});

test('articles: partitive "de l\'" / "du"', () => {
  accepts('eau', "de l'eau", 'fr', null, ['article']);
  accepts('de la eau', "de l'eau", 'fr', null, []);
  accepts('pain', 'du pain', 'fr', null, ['article']);
});

test('articles: an extra article in the answer is ignored', () => {
  accepts('la personne', 'personne', 'fr', null, []);
  accepts('die Frau', 'Frau', 'de', null, []);
  accepts('die Frau', 'Frau', 'de', ALL_OFF, []);
});

test('articles: capitalised article at the start is fine even with ignoreCase OFF', () => {
  accepts('Le monsieur', 'le monsieur', 'fr', { ignoreCase: false }, []);
  accepts('Der Mann', 'der Mann', 'de', { ignoreCase: false }, []);
});

// ---------------------------------------------------------------------------
// reflexive pronouns

test('reflexives ON: "appeler" for "s\'appeler" → note pronoun', () => {
  accepts('appeler', "s'appeler", 'fr', null, ['pronoun']);
});

test('reflexives: "se appeler" equals "s\'appeler"', () => {
  accepts('se appeler', "s'appeler", 'fr', null, []);
});

test('reflexives ON: "ressembler" for "se ressembler"', () => {
  accepts('ressembler', 'se ressembler', 'fr', null, ['pronoun']);
});

test('reflexives OFF: missing pronoun is wrong', () => {
  rejects('ressembler', 'se ressembler', 'fr', { articles: false }, 'missingArticle');
  rejects('gleichen', 'sich gleichen', 'de', { articles: false }, 'missingArticle');
});

test('reflexives ON: "gleichen" for "sich gleichen"', () => {
  accepts('gleichen', 'sich gleichen', 'de', null, ['pronoun']);
});

test('reflexives: "gleichen" for "sich ähnlich sein, sich gleichen" → pronoun + partial', () => {
  accepts('gleichen', 'sich ähnlich sein, sich gleichen', 'de', null, ['pronoun', 'partial']);
  accepts('ähnlich sein', 'sich ähnlich sein, sich gleichen', 'de', null, ['pronoun', 'partial']);
});

test('reflexives: a wrong pronoun/article is wrong', () => {
  rejects('le appeler', "s'appeler", 'fr', null, 'wrongArticle');
});

// ---------------------------------------------------------------------------
// articles: German

test('articles ON: "Herr" for "der Herr"', () => {
  accepts('Herr', 'der Herr', 'de', null, ['article']);
});

test('articles OFF: "Herr" for "der Herr" is wrong', () => {
  rejects('Herr', 'der Herr', 'de', { articles: false }, 'missingArticle');
});

test('articles: "den Herr" for "der Herr" is wrong (wrongArticle)', () => {
  rejects('den Herr', 'der Herr', 'de', null, 'wrongArticle');
  rejects('den Herr', 'der Herr', 'de', { articles: false }, 'wrongArticle');
});

test('articles: "die Haar" when only "das Haar" fits is wrong', () => {
  rejects('die Haar', 'das Haar, die Haare', 'de', null, 'wrongArticle');
});

test('articles: wrong article is not excused as a typo of another alternative', () => {
  rejects('die Haar', 'das Haar, die Haare', 'de', { typos: true }, 'wrongArticle');
});

test('articles: "das Fräulein, die Frau"', () => {
  accepts('Frau', 'das Fräulein, die Frau', 'de', null, ['article', 'partial']);
  accepts('Fräulein', 'das Fräulein, die Frau', 'de', null, ['article', 'partial']);
  rejects('der Frau', 'das Fräulein, die Frau', 'de', null, 'wrongArticle');
});

test('articles: indefinite instead of definite article is wrong', () => {
  rejects('ein Mann', 'der Mann', 'de', null, 'wrongArticle');
});

test('articles: "la rue" ↔ "die Strasse"/"Straße"', () => {
  accepts('Strasse', 'die Strasse', 'de', null, ['article']);
  accepts('Straße', 'die Strasse', 'de', null, ['article']);
  exactMatch('la rue', 'la rue', 'fr');
  accepts('rue', 'la rue', 'fr', null, ['article']);
});

test('articles: dictionary style "Herr, der" is read as "der Herr"', () => {
  accepts('der Herr', 'Herr, der', 'de', null, []);
  accepts('Herr', 'Herr, der', 'de', null, ['article']);
  rejects('die Herr', 'Herr, der', 'de', null, 'wrongArticle');
  // Answers that are only articles stay separate alternatives.
  accepts('la', 'le, la', 'fr', null, ['partial']);
  exactMatch('le, la', 'le, la', 'fr');
});

test('articles: German articles are only stripped for German', () => {
  rejects('Hard', 'die Hard', 'en');
  rejects('Herr', 'der Herr', 'fr');
});

test('articles: lang "other" or unknown strips nothing', () => {
  rejects('Herr', 'der Herr', 'other');
  rejects('Herr', 'der Herr', undefined);
  rejects('homme', "l'homme", 'xx');
  accepts('Herr', 'der Herr', 'de-CH', null, ['article']);
});

// ---------------------------------------------------------------------------
// articles: English, Spanish, Italian

test('articles ON: English "to appear" accepts "appear" (note article)', () => {
  accepts('appear', 'to appear', 'en', null, ['article']);
  accepts('house', 'the house', 'en', null, ['article']);
  accepts('apple', 'an apple', 'en', null, ['article']);
});

test('articles OFF: English particle "to" is required', () => {
  rejects('appear', 'to appear', 'en', { articles: false }, 'missingArticle');
});

test('articles: English "die" is a verb, "to die" accepts "die"', () => {
  accepts('die', 'to die', 'en', null, ['article']);
});

test('articles: English wrong article is wrong', () => {
  rejects('the apple', 'an apple', 'en', null, 'wrongArticle');
});

test('articles: Spanish', () => {
  accepts('perro', 'el perro', 'es', null, ['article']);
  rejects('la perro', 'el perro', 'es', null, 'wrongArticle');
});

test('articles: Italian elision', () => {
  accepts('amico', "l'amico", 'it', null, ['article']);
  accepts('lo amico', "l'amico", 'it', null, []);
  accepts('una amica', "un'amica", 'it', null, []);
  accepts('ragazzi', 'i ragazzi', 'it', null, ['article']);
});

// ---------------------------------------------------------------------------
// abbreviations

test('abbreviations ON: etw. = etwas (both directions)', () => {
  accepts('etwas machen', 'etw. machen', 'de', null, ['abbreviation']);
  accepts('etw. machen', 'etwas machen', 'de', null, ['abbreviation']);
  accepts('etw machen', 'etwas machen', 'de', null, ['abbreviation']);
});

test('abbreviations OFF: etw. ≠ etwas', () => {
  rejects('etwas machen', 'etw. machen', 'de', { abbreviations: false });
  rejects('etw. machen', 'etwas machen', 'de', { abbreviations: false });
});

test('abbreviations: same abbreviation on both sides is exact', () => {
  exactMatch('etw. machen', 'etw. machen', 'de', { abbreviations: false });
});

test('abbreviations: jdn. / jdm. / jds. / jd.', () => {
  accepts('jemanden fragen', 'jdn. fragen', 'de', null, ['abbreviation']);
  accepts('jemandem helfen', 'jdm. helfen', 'de', null, ['abbreviation']);
  accepts('jemandes Freund', 'jds. Freund', 'de', null, ['abbreviation']);
  accepts('jemand', 'jd.', 'de', null, ['abbreviation']);
});

test('abbreviations: English sth / sb / s.o.', () => {
  accepts('to do something', 'to do sth', 'en', null, ['abbreviation']);
  accepts('do something', 'to do sth', 'en', null, ['article', 'abbreviation']);
  accepts('to help somebody', 'to help sb', 'en', null, ['abbreviation']);
  accepts('to help someone', 'to help sb', 'en', null, ['abbreviation']);
  accepts('to help s.o.', 'to help somebody', 'en', null, ['abbreviation']);
  accepts('to tell s.th.', 'to tell something', 'en', null, ['abbreviation']);
});

test('abbreviations: French qc / qn', () => {
  accepts('faire quelque chose', 'faire qc', 'fr', null, ['abbreviation']);
  accepts('faire qqch', 'faire quelque chose', 'fr', null, ['abbreviation']);
  accepts("aider quelqu'un", 'aider qn', 'fr', null, ['abbreviation']);
  accepts("aider quelqu' un", 'aider qqn', 'fr', null, ['abbreviation']);
});

test('abbreviations: z.B., usw., bzw., od.', () => {
  accepts('zum Beispiel', 'z.B.', 'de', null, ['abbreviation']);
  accepts('zum Beispiel', 'z. B.', 'de', null, ['abbreviation']);
  accepts('zum beispiel', 'z.B.', 'de', null, ['abbreviation', 'case']);
  accepts('Etwas machen', 'Etw. machen', 'de', { ignoreCase: false }, ['abbreviation']);
  accepts('und so weiter', 'usw.', 'de', null, ['abbreviation']);
  accepts('beziehungsweise', 'bzw.', 'de', null, ['abbreviation']);
  accepts('ja oder nein', 'ja od. nein', 'de', null, ['abbreviation']);
});

test('abbreviations: standalone "u." means "und", "u.a." is left alone', () => {
  accepts('Herr und Frau', 'Herr u. Frau', 'de', null, ['abbreviation']);
  rejects('und a', 'u.a.', 'de');
});

test('abbreviations: o.s. = oneself', () => {
  accepts('to wash oneself', 'to wash o.s.', 'en', null, ['abbreviation']);
});

test('abbreviations combine with reflexives', () => {
  accepts('etwas leisten', 'sich etw. leisten', 'de', null, ['pronoun', 'abbreviation']);
});

test('abbreviations: words that merely start like one are not expanded', () => {
  rejects('etwasig', 'etw.', 'de');
  exactMatch('sbire', 'sbire', 'fr');
});

// ---------------------------------------------------------------------------
// ignoreCase

test('ignoreCase ON: German noun in lower case → correct with note case', () => {
  accepts('der mann', 'der Mann', 'de', null, ['case']);
  accepts('frau', 'Frau', 'de', null, ['case']);
});

test('ignoreCase ON: no case note for non-German answers', () => {
  const r = accepts('Monsieur', 'monsieur', 'fr', null, []);
  expect(r.exact).toBe(false);
  accepts('APPEAR', 'to appear', 'en', null, ['article']);
});

test('ignoreCase OFF: case-only difference is wrong (caseOnly)', () => {
  rejects('der mann', 'der Mann', 'de', { ignoreCase: false }, 'caseOnly');
  rejects('Appeler', 'appeler', 'fr', { ignoreCase: false }, 'caseOnly');
});

test('ignoreCase OFF: correct case is accepted with other tolerances', () => {
  accepts('Mann', 'der Mann', 'de', { ignoreCase: false }, ['article']);
});

test('ignoreCase combines with missing article', () => {
  accepts('mann', 'der Mann', 'de', null, ['article', 'case']);
});

// ---------------------------------------------------------------------------
// ignoreAccents

test('ignoreAccents OFF: accent-only difference is wrong (accentsOnly)', () => {
  rejects('ressembler a', 'ressembler à', 'fr', null, 'accentsOnly');
  rejects('bete', 'bête', 'fr', null, 'accentsOnly');
  rejects('hasslich', 'hässlich', 'de', null, 'accentsOnly');
  rejects('cafe', 'café', 'fr', null, 'accentsOnly');
});

test('ignoreAccents ON: accents ignored with note accents', () => {
  accepts('ressembler a', 'ressembler à', 'fr', { ignoreAccents: true }, ['accents']);
  accepts('bete', 'bête', 'fr', { ignoreAccents: true }, ['accents']);
  accepts('hasslich', 'hässlich', 'de', { ignoreAccents: true }, ['accents']);
  accepts('café', 'cafe', 'fr', { ignoreAccents: true }, ['accents']);
});

test('ignoreAccents ON: umlaut transliteration (ae/oe/ue) is accepted', () => {
  accepts('die Haeuser', 'die Häuser', 'de', { ignoreAccents: true }, ['accents']);
  accepts('huebsch', 'hübsch', 'de', { ignoreAccents: true }, ['accents']);
  accepts('Häuser', 'Haeuser', 'de', { ignoreAccents: true }, ['accents']);
  rejects('huebsch', 'hübsch', 'de', null, 'accentsOnly');
});

test('ignoreAccents combines with article and partial', () => {
  accepts('Madchen', 'das Mädchen', 'de', { ignoreAccents: true }, ['article', 'accents']);
  accepts('separee', 'séparé, séparée', 'fr', { ignoreAccents: true }, ['partial', 'accents']);
});

test('accentsOnly is not claimed when the case differs too (ignoreCase OFF)', () => {
  rejects('madchen', 'Mädchen', 'de', { ignoreCase: false }, 'almost');
  rejects('madchen', 'Mädchen', 'de', { ignoreCase: false, ignoreAccents: true }, 'caseOnly');
});

// ---------------------------------------------------------------------------
// typos

test('typos ON: one wrong letter in a 4+ letter word', () => {
  accepts('verheiratat', 'verheiratet', 'de', { typos: true }, ['typo']);
  accepts('freundlich', 'freundlisch', 'de', { typos: true }, ['typo']);
  accepts('le monsieu', 'le monsieur, messieurs', 'fr', { typos: true }, ['partial', 'typo']);
});

test('typos ON: swapped letters count as one edit (Damerau)', () => {
  accepts('ntet', 'nett', 'de', { typos: true }, ['typo']);
  accepts('Shcönheit', 'die Schönheit', 'de', { typos: true }, ['article', 'typo']);
});

test('typos OFF: one edit away → hint typo', () => {
  rejects('ntet', 'nett', 'de', null, 'typo');
  rejects('verheiratat', 'verheiratet', 'de', null, 'typo');
});

test('typos ON: words with fewer than 4 letters need to be exact', () => {
  rejects('bom', 'bon', 'fr', { typos: true });
  rejects('der Mutt', 'der Mut', 'de', { typos: true });
});

test('typos ON: 2 edits allowed from 10 letters, otherwise 1', () => {
  accepts('der Familliennamme', 'der Familienname', 'de', { typos: true }, ['typo']);
  rejects('der Familliennammee', 'der Familienname', 'de', { typos: true }, 'almost');
  rejects('verwidwed', 'verwitwet', 'de', { typos: true }, 'almost');
});

test('typos never bridge a wrong article', () => {
  rejects('den Mann', 'der Mann', 'de', ALL_ON, 'wrongArticle');
});

test('typos ON: a missing space after the article counts as a typo', () => {
  accepts('lemonsieur', 'le monsieur', 'fr', { typos: true }, ['typo']);
});

test('typos ON with ignoreCase OFF: a single case slip is one typo', () => {
  accepts('hand', 'Hand', 'de', { ignoreCase: false, typos: true }, ['typo']);
});

test('typos combine with accents', () => {
  accepts('separe', 'séparée', 'fr', { typos: true, ignoreAccents: true }, ['accents', 'typo']);
  rejects('separe', 'séparée', 'fr', { typos: true }, 'almost');
});

// ---------------------------------------------------------------------------
// hints

test('hint almost when similar but beyond typo distance', () => {
  rejects('Aufmärksamkat', 'Aufmerksamkeit', 'de', null, 'almost');
});

test('hint priority: wrongArticle over accentsOnly', () => {
  rejects('la numero', 'le numéro', 'fr', null, 'wrongArticle');
});

test('hint priority: missingArticle over accentsOnly', () => {
  rejects('numero', 'le numéro', 'fr', { articles: false }, 'missingArticle');
  rejects('Fraulein', 'das Fräulein, die Frau', 'de', { articles: false }, 'missingArticle');
});

test('hint: accentsOnly when the article was rightly left out', () => {
  rejects('Fraulein', 'das Fräulein, die Frau', 'de', null, 'accentsOnly');
});

test('hint: typo when the missing article is allowed but a letter is wrong', () => {
  rejects('Her', 'der Herr', 'de', null, 'typo');
  rejects('Vornahme', 'der Vorname', 'de', null, 'typo');
  rejects('Hrr', 'der Herr', 'de', null, 'typo');
});

test('correct answers never carry a hint; wrong answers never carry notes', () => {
  expect(grade('Herr', 'der Herr', null, 'de').hint).toBe(null);
  expect(grade('den Herr', 'der Herr', null, 'de').notes).toEqual([]);
});

// ---------------------------------------------------------------------------
// combined tolerances

test('combined: all tolerances ON at once', () => {
  accepts('ressembler a', 'ressembler à', 'fr', ALL_ON, ['accents']);
  accepts('Freundlichkiet', 'freundlichkeit, die Güte', 'de', ALL_ON);
  accepts('gute', 'die Güte', 'de', ALL_ON, ['article', 'case', 'accents']);
  accepts('Gute', 'die Güte', 'de', ALL_ON, ['article', 'accents']);
});

test('combined: all tolerances OFF only accepts the full stored answer', () => {
  rejects('monsieur', 'le monsieur, messieurs', 'fr', ALL_OFF, 'missingArticle');
  rejects('le monsieur', 'le monsieur, messieurs', 'fr', ALL_OFF);
  exactMatch('le monsieur, messieurs', 'le monsieur, messieurs', 'fr', ALL_OFF);
});

test('tolerance: missing or partial options fall back to defaults', () => {
  accepts('Herr', 'der Herr', 'de', undefined, ['article']);
  accepts('Herr', 'der Herr', 'de', {}, ['article']);
  rejects('bete', 'bête', 'fr', { typos: 'yes' }, 'accentsOnly');
  expect(DEFAULT_TOLERANCE).toEqual({
    articles: true,
    abbreviations: true,
    multipleAnswers: true,
    parentheses: true,
    ignoreCase: true,
    ignoreAccents: false,
    typos: false,
  });
});

test('tolerance: a full StudyOptions object is understood', () => {
  rejects('Herr', 'der Herr', 'de', { answerWith: 'term', tolerance: { articles: false } }, 'missingArticle');
});

// ---------------------------------------------------------------------------
// robustness

test('robust: null / undefined / numbers / booleans never throw', () => {
  const odd = [null, undefined, 0, 42, -1.5, NaN, true, false, {}, [], ['a', 'b'], () => 1];
  for (const g of odd) {
    for (const e of odd) {
      const r = grade(g, e, null, 'de');
      expect(typeof r.correct).toBe('boolean');
      expect(Array.isArray(r.notes)).toBe(true);
    }
  }
  exactMatch(42, 42, 'de');
  exactMatch('42', 42, 'de');
});

test('robust: symbols and objects with throwing toString', () => {
  const evil = { toString() { throw new Error('boom'); } };
  expect(grade(Symbol('x'), 'Herr', null, 'de').correct).toBe(false);
  expect(grade(evil, 'Herr', null, 'de').correct).toBe(false);
  expect(grade('Herr', evil, null, 'de').correct).toBe(false);
  expect(grade('Herr', 'der Herr', evil, 'de').correct).toBe(true);
});

test('robust: odd tolerance and lang values', () => {
  for (const tol of [null, undefined, 5, 'x', [], { articles: 1 }]) {
    expect(grade('Herr', 'der Herr', tol, 'de').correct).toBe(true);
  }
  for (const lang of [null, undefined, 42, {}, '', 'DE', 'zz']) {
    expect(typeof grade('Herr', 'der Herr', null, lang).correct).toBe('boolean');
  }
  expect(grade('Herr', 'der Herr', null, 'DE').correct).toBe(true);
});

test('robust: emoji and unusual unicode', () => {
  exactMatch('🙂', '🙂', 'de');
  rejects('🙂', 'lieb', 'de');
  rejects('lieb', '🙂', 'de');
  exactMatch('Haus 🏠', 'Haus 🏠', 'de');
  expect(typeof grade('\uD800', '\uDC00', ALL_ON, 'fr').correct).toBe('boolean');
  expect(typeof grade('İstanbul', 'istanbul', ALL_ON, 'en').correct).toBe('boolean');
  expect(typeof grade('​', 'a', ALL_ON, 'en').correct).toBe('boolean');
});

test('robust: very long strings', () => {
  const long = 'a'.repeat(100000);
  exactMatch(long, long, 'de');
  rejects(long, 'b'.repeat(100000), 'de', ALL_ON);
  rejects(long + 'b', long + 'c', 'de', ALL_ON);
  expect(grade(long, 'Herr', ALL_ON, 'de').correct).toBe(false);
  expect(grade('Herr', long, ALL_ON, 'de').correct).toBe(false);
});

test('robust: many separators, slashes and brackets', () => {
  const manyAlts = Array.from({ length: 3000 }, (_, i) => `wort${i}`).join(', ');
  expect(typeof grade('wort5', manyAlts, ALL_ON, 'de').correct).toBe('boolean');
  expect(typeof grade(manyAlts, manyAlts, ALL_ON, 'de').correct).toBe('boolean');
  expect(typeof grade('a/b/c/d/e/f/g/h/i/j/k/l/m', 'aaa/bbb/ccc/ddd/eee/fff/ggg/hhh/iii', ALL_ON, 'de').correct).toBe('boolean');
  expect(typeof grade('a', '((((((((a))))))))', ALL_ON, 'de').correct).toBe('boolean');
  accepts('abcdefghij', '(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)', 'de', ALL_ON);
  expect(typeof grade('x', ')))(((', ALL_ON, 'de').correct).toBe('boolean');
});

test('robust: grading the whole fixture under every toggle combination does not throw', () => {
  const keys = Object.keys(DEFAULT_TOLERANCE);
  for (let mask = 0; mask < 1 << keys.length; mask += 9) {
    const tol = {};
    keys.forEach((k, b) => {
      tol[k] = Boolean(mask & (1 << b));
    });
    for (let i = 0; i < PAIRS.length; i++) {
      const [term, def] = PAIRS[i];
      const [otherTerm, otherDef] = PAIRS[(i + 7) % PAIRS.length];
      expect(grade(term, term, tol, 'fr').exact).toBe(true);
      expect(typeof grade(otherTerm, term, tol, 'fr').correct).toBe('boolean');
      expect(typeof grade(otherDef, def, tol, 'de').correct).toBe('boolean');
    }
  }
});

// ---------------------------------------------------------------------------
// diffChars

function rebuild(segments) {
  return {
    given: segments.filter((s) => s.type !== 'add').map((s) => s.text).join(''),
    expected: segments.filter((s) => s.type !== 'del').map((s) => s.text).join(''),
  };
}

test('diffChars: identical strings', () => {
  expect(diffChars('Herr', 'Herr')).toEqual([{ type: 'same', text: 'Herr' }]);
});

test('diffChars: empty strings', () => {
  expect(diffChars('', '')).toEqual([]);
  expect(diffChars('', 'abc')).toEqual([{ type: 'add', text: 'abc' }]);
  expect(diffChars('abc', '')).toEqual([{ type: 'del', text: 'abc' }]);
  expect(diffChars(null, undefined)).toEqual([]);
  expect(diffChars(null, 'ab')).toEqual([{ type: 'add', text: 'ab' }]);
});

test('diffChars: substitution shows the wrong char and the missing one', () => {
  expect(diffChars('Herz', 'Herr')).toEqual([
    { type: 'same', text: 'Her' },
    { type: 'del', text: 'z' },
    { type: 'add', text: 'r' },
  ]);
});

test('diffChars: missing and extra characters', () => {
  expect(diffChars('Madchen', 'Mädchen')).toEqual([
    { type: 'same', text: 'M' },
    { type: 'del', text: 'a' },
    { type: 'add', text: 'ä' },
    { type: 'same', text: 'dchen' },
  ]);
  expect(diffChars('Herr', 'der Herr')).toEqual([{ type: 'add', text: 'der ' }, { type: 'same', text: 'Herr' }]);
  expect(diffChars('der Herrr', 'der Herr')).toEqual([{ type: 'same', text: 'der Herr' }, { type: 'del', text: 'r' }]);
});

test('diffChars: segments rebuild both strings and adjacent segments are merged', () => {
  const words = PAIRS.flat();
  for (let i = 0; i < words.length; i++) {
    const a = words[i];
    const b = words[(i + 5) % words.length];
    const segs = diffChars(a, b);
    expect(rebuild(segs)).toEqual({ given: a, expected: b });
    segs.forEach((s, k) => {
      expect(s.text.length).toBeGreaterThan(0);
      if (k > 0) expect(s.type).not.toBe(segs[k - 1].type);
    });
  }
});

test('diffChars: LCS keeps the longest common subsequence', () => {
  const segs = diffChars('ressembler', 'se ressembler');
  const same = segs.filter((s) => s.type === 'same').map((s) => s.text).join('');
  expect(same).toBe('ressembler');
});

test('diffChars: surrogate pairs stay intact and input is NFC-normalised', () => {
  expect(diffChars('a🙂b', 'a🙃b')).toEqual([
    { type: 'same', text: 'a' },
    { type: 'del', text: '🙂' },
    { type: 'add', text: '🙃' },
    { type: 'same', text: 'b' },
  ]);
  expect(diffChars('séparée'.normalize('NFD'), 'séparée')).toEqual([{ type: 'same', text: 'séparée' }]);
});

test('diffChars: very long strings fall back gracefully', () => {
  const a = 'x' + 'a'.repeat(3000);
  const b = 'y' + 'b'.repeat(3000);
  expect(rebuild(diffChars(a, b))).toEqual({ given: a, expected: b });
  const c = 'a'.repeat(50000);
  expect(diffChars(c, c)).toEqual([{ type: 'same', text: c }]);
});

test('diffAnswer: grading equivalences (ss, apostrophes, spaces) are not shown as errors', () => {
  expect(diffAnswer('Fussbal', 'Fußball')).toEqual([{ type: 'same', text: 'Fussbal' }, { type: 'add', text: 'l' }]);
  expect(diffAnswer('die Strase', 'die Straße')).toEqual([
    { type: 'same', text: 'die Stras' },
    { type: 'add', text: 's' },
    { type: 'same', text: 'e' },
  ]);
  expect(diffAnswer("l'homm", 'l’homme')).toEqual([{ type: 'same', text: "l'homm" }, { type: 'add', text: 'e' }]);
  expect(diffAnswer('le  monsieur', 'le monsieur')).toEqual([{ type: 'same', text: 'le monsieur' }]);
  expect(diffAnswer("l' homme", "l'homme")).toEqual([{ type: 'same', text: "l'homme" }]);
  expect(diffAnswer('coer', 'cœur')).toEqual([{ type: 'same', text: 'coe' }, { type: 'add', text: 'u' }, { type: 'same', text: 'r' }]);
});

test('diffAnswer: a sharp s typed by the learner is compared as typed', () => {
  expect(diffAnswer('Straße', 'Straße')).toEqual([{ type: 'same', text: 'Straße' }]);
  expect(rebuild(diffAnswer('Strase', 'Straße'))).toEqual({ given: 'Strase', expected: 'Strasse' });
  expect(rebuild(diffAnswer('Straß', 'Straße'))).toEqual({ given: 'Straß', expected: 'Straße' });
  expect(diffAnswer(null, undefined)).toEqual([]);
});

// ---------------------------------------------------------------------------
// review regressions

test('slash scope: "an jdn./etw. denken" binds the slash to the placeholders', () => {
  expect(splitAlternatives('an jdn./etw. denken')).toEqual(['an jdn. denken', 'an etw. denken']);
  expect(splitAlternatives('auf jdn./etw. warten')).toEqual(['auf jdn. warten', 'auf etw. warten']);
  expect(splitAlternatives('mit jdm./etw. sprechen')).toEqual(['mit jdm. sprechen', 'mit etw. sprechen']);
  expect(splitAlternatives('an jemanden/etwas denken')).toEqual(['an jemanden denken', 'an etwas denken']);
  expect(splitAlternatives('etw./sich ändern')).toEqual(['etw. ändern', 'sich ändern']);
  expect(splitAlternatives('jdn./sich vorstellen')).toEqual(['jdn. vorstellen', 'sich vorstellen']);
  expect(splitAlternatives("penser à quelqu'un/quelque chose")).toEqual(["penser à quelqu'un", 'penser à quelque chose']);
});

test('slash scope: full answers are accepted, fragments are not', () => {
  accepts('an jemanden denken', 'an jdn./etw. denken', 'de', null, ['abbreviation', 'partial']);
  accepts('an jdn. denken', 'an jdn./etw. denken', 'de', null, ['partial']);
  accepts('auf etwas warten', 'auf jdn./etw. warten', 'de', null, ['abbreviation', 'partial']);
  accepts('mit jemandem sprechen', 'mit jdm./etw. sprechen', 'de', null, ['abbreviation', 'partial']);
  accepts('etwas ändern', 'etw./sich ändern', 'de', null, ['abbreviation', 'partial']);
  accepts('sich ändern', 'etw./sich ändern', 'de', null, ['partial']);
  exactMatch('an jdn./etw. denken', 'an jdn./etw. denken', 'de');
  rejects('an jemanden', 'an jdn./etw. denken', 'de');
  rejects('etwas denken', 'an jdn./etw. denken', 'de');
  rejects('mit jemandem', 'mit jdm./etw. sprechen', 'de');
  rejects('etwas', 'etw./sich ändern', 'de');
});

test('slash scope: a trailing article group replaces the parallel group on the left', () => {
  expect(splitAlternatives('faire du vélo/du ski')).toEqual(['faire du vélo', 'faire du ski']);
  expect(splitAlternatives('to play the piano/the guitar')).toEqual(['to play the piano', 'to play the guitar']);
  expect(splitAlternatives('jouer au foot/au tennis')).toEqual(['jouer au foot', 'jouer au tennis']);
  accepts('faire du ski', 'faire du vélo/du ski', 'fr', null, ['partial']);
  accepts('jouer au tennis', 'jouer au foot/au tennis', 'fr', null, ['partial']);
  rejects('du ski', 'faire du vélo/du ski', 'fr');
  expect(splitAlternatives('faire du vélo/du ski/du golf')).toEqual(['faire du vélo', 'faire du ski', 'faire du golf']);
  expect(splitAlternatives('faire du vélo électrique/du ski')).toEqual(['faire du vélo électrique', 'faire du ski']);
  expect(splitAlternatives('ich habe einen Hund/eine Katze')).toEqual(['ich habe einen Hund', 'ich habe eine Katze']);
  // A contracted article replaces the preposition too.
  expect(splitAlternatives('aller à la plage/au cinéma')).toEqual(['aller à la plage', 'aller au cinéma']);
  expect(splitAlternatives("aller à l'école/au cinéma")).toEqual(["aller à l'école", 'aller au cinéma']);
  expect(splitAlternatives('parler de la famille/du travail')).toEqual(['parler de la famille', 'parler du travail']);
  accepts('aller au cinéma', 'aller à la plage/au cinéma', 'fr', null, ['partial']);
  // Whole phrases on both sides stay whole.
  expect(splitAlternatives('Guten Morgen/Guten Tag')).toEqual(['Guten Morgen', 'Guten Tag']);
  expect(splitAlternatives('das Haus der Familie/die Wohnung')).toEqual(['das Haus der Familie', 'die Wohnung']);
  expect(splitAlternatives('aller au lit/se coucher')).toEqual(['aller au lit', 'se coucher']);
  expect(splitAlternatives('to go to bed/to sleep')).toEqual(['to go to bed', 'to sleep']);
  expect(splitAlternatives('ein Glas Wasser/eine Tasse Tee')).toEqual(['ein Glas Wasser', 'eine Tasse Tee']);
});

test('slash scope: an article pair after other words binds to the noun', () => {
  expect(splitAlternatives('mit der/dem Lehrer')).toEqual(['mit der Lehrer', 'mit dem Lehrer']);
  expect(splitAlternatives('avec le/la secrétaire')).toEqual(['avec le secrétaire', 'avec la secrétaire']);
  accepts('mit dem Lehrer', 'mit der/dem Lehrer', 'de', null, ['partial']);
  rejects('dem Lehrer', 'mit der/dem Lehrer', 'de');
});

test('slash scope: French "verb qc/se verb" pairs two whole verb phrases', () => {
  const cases = [
    ['laver qc/se laver', ['laver qc', 'se laver']],
    ['réveiller qn/se réveiller', ['réveiller qn', 'se réveiller']],
    ['changer qc/se changer', ['changer qc', 'se changer']],
    ['coucher qn/se coucher', ['coucher qn', 'se coucher']],
    ['lever qc/se lever', ['lever qc', 'se lever']],
    ['promener qn/se promener', ['promener qn', 'se promener']],
    ['demander qc/se demander', ['demander qc', 'se demander']],
    ['lever qc/se coucher', ['lever qc', 'se coucher']],
    ["habiller qn/s'habiller", ['habiller qn', "s'habiller"]],
  ];
  for (const [stored, alts] of cases) expect(splitAlternatives(stored)).toEqual(alts);
  accepts('se laver', 'laver qc/se laver', 'fr', null, ['partial']);
  accepts('laver quelque chose', 'laver qc/se laver', 'fr', null, ['abbreviation', 'partial']);
  accepts('se réveiller', 'réveiller qn/se réveiller', 'fr', null, ['partial']);
  accepts("s'habiller", "habiller qn/s'habiller", 'fr', null, ['partial']);
  exactMatch('changer qc, se changer', 'changer qc/se changer', 'fr');
  exactMatch('laver qc / se laver', 'laver qc/se laver', 'fr', ALL_OFF);
  rejects('laver qc laver', 'laver qc/se laver', 'fr');
  // German and English reflexives share the verb with the object placeholder.
  expect(splitAlternatives('an jdn./sich denken')).toEqual(['an jdn. denken', 'an sich denken']);
  expect(splitAlternatives('to wash sth/oneself')).toEqual(['to wash sth', 'to wash oneself']);
  expect(splitAlternatives('to look after sb/oneself well')).toEqual(['to look after sb well', 'to look after oneself well']);
  expect(splitAlternatives('etw./sich ändern')).toEqual(['etw. ändern', 'sich ändern']);
  expect(splitAlternatives('jdn./sich vorstellen')).toEqual(['jdn. vorstellen', 'sich vorstellen']);
  // "se" is also a suffix.
  expect(splitAlternatives('heureux/se')).toEqual(['heureux/se']);
});

test('slash: short placeholders "sb/sth" and "qn/qc" are alternatives', () => {
  expect(splitAlternatives('to think of sb/sth')).toEqual(['to think of sb', 'to think of sth']);
  expect(splitAlternatives('penser à qn/qc')).toEqual(['penser à qn', 'penser à qc']);
  accepts('think of somebody', 'to think of sb/sth', 'en', null, ['article', 'abbreviation', 'partial']);
  accepts('think of sb', 'to think of sb/sth', 'en', null, ['article', 'partial']);
  accepts('be afraid of sb', 'to be afraid of sb/sth', 'en', null, ['article', 'partial']);
  accepts("penser à quelqu'un", 'penser à qn/qc', 'fr', null, ['abbreviation', 'partial']);
  accepts('attendre quelque chose', 'attendre qn/qc', 'fr', null, ['abbreviation', 'partial']);
  exactMatch('to think of sb/sth', 'to think of sb/sth', 'en');
});

test('slash: short pronoun and determiner lists are alternatives', () => {
  expect(splitAlternatives('il/elle')).toEqual(['il', 'elle']);
  expect(splitAlternatives('er/sie/es')).toEqual(['er', 'sie', 'es']);
  expect(splitAlternatives('mon/ma/mes')).toEqual(['mon', 'ma', 'mes']);
  expect(splitAlternatives('Er/sie')).toEqual(['Er', 'sie']);
  exactMatch('il, elle', 'il/elle', 'fr');
  exactMatch('he / she', 'he/she', 'en');
  exactMatch('er, sie, es', 'er/sie/es', 'de');
  exactMatch('mon, ma, mes', 'mon/ma/mes', 'fr');
  accepts('tu', 'tu/vous', 'fr', null, ['partial']);
});

test('slash: suffix notation is still one answer', () => {
  for (const s of ['Lehrer/in', 'Lehrer/innen', 'marié/e', 'km/h', 'bon/ne', 'gros/se', 'ein/e', 'jede/r']) {
    expect(splitAlternatives(s)).toEqual([s]);
  }
});

test('commas inside a sentence do not separate alternatives', () => {
  const cases = [
    ['please', 'Can you help me, please?', 'en'],
    ['merci', 'Ça va bien, merci.', 'fr'],
    ['Madame', 'Excusez-moi, Madame.', 'fr'],
    ['Danke', 'Danke, gleichfalls!', 'de'],
    ['Hallo', "Hallo, wie geht's?", 'de'],
    ['Oui', 'Oui, merci.', 'fr'],
    ['Monsieur', 'Bonjour, Monsieur!', 'fr'],
    ['Hallo', 'Hallo, wie geht es dir…', 'de'],
  ];
  for (const [given, expected, lang] of cases) {
    rejects(given, expected, lang);
    expect(splitAlternatives(expected)).toEqual([expected]);
    exactMatch(expected, expected, lang);
  }
  exactMatch('Ça va bien merci', 'Ça va bien, merci.', 'fr');
  accepts('ca va bien, merci', 'Ça va bien, merci.', 'fr', { ignoreAccents: true }, ['accents']);
});

test('commas: lists ending in an abbreviation or marker are still lists', () => {
  expect(splitAlternatives('jdn. fragen, etw. tun')).toEqual(['jdn. fragen', 'etw. tun']);
  expect(splitAlternatives('zum Beispiel, z. B.')).toEqual(['zum Beispiel', 'z. B.']);
  expect(splitAlternatives('lieb, nett')).toEqual(['lieb', 'nett']);
  expect(splitAlternatives('Ça va?, Comment vas-tu?')).toEqual(['Ça va?', 'Comment vas-tu?']);
  accepts('lieb', 'lieb, nett', 'de', null, ['partial']);
});

test('commas: a final dot alone does not make a list a sentence', () => {
  // Lowercase start: a list with a trailing dot.
  expect(splitAlternatives('ja, nein.')).toEqual(['ja', 'nein.']);
  expect(splitAlternatives('das Auto, die Autos.')).toEqual(['das Auto', 'die Autos.']);
  accepts('ja', 'ja, nein.', 'de', null, ['partial']);
  // Dictionary form with a trailing article.
  expect(splitAlternatives('Herr, der.')).toEqual(['Herr', 'der.']);
  accepts('der Herr', 'Herr, der.', 'de', null, []);
  accepts('Herr', 'Herr, der.', 'de', null, ['article']);
  // Capitalised sentences, also inside quotes.
  expect(splitAlternatives('«Oui, merci.»')).toEqual(['«Oui, merci.»']);
  rejects('Oui', '«Oui, merci.»', 'fr');
});

test('commas: German noun lists with a final dot are lists, not sentences', () => {
  expect(splitAlternatives('Mappe, Tasche.', 'de')).toEqual(['Mappe', 'Tasche.']);
  expect(splitAlternatives('Haus, Gebäude.', 'de')).toEqual(['Haus', 'Gebäude.']);
  expect(splitAlternatives('Die Mappe, die Tasche.', 'de')).toEqual(['Die Mappe', 'die Tasche.']);
  accepts('Mappe', 'Mappe, Tasche.', 'de', null, ['partial']);
  accepts('Tasche', 'Mappe, Tasche.', 'de', null, ['partial']);
  accepts('Haus', 'Haus, Gebäude.', 'de', null, ['partial']);
  accepts('Mappe', 'Die Mappe, die Tasche.', 'de', null, ['article', 'partial']);
  exactMatch('Mappe, Tasche', 'Mappe, Tasche.', 'de');
  // Real German sentences stay one answer.
  for (const s of ['Ja, gerne.', 'Guten Tag, Frau Müller.', 'Danke, gleichfalls!']) {
    expect(splitAlternatives(s, 'de')).toEqual([s]);
  }
  rejects('Ja', 'Ja, gerne.', 'de');
  rejects('Frau Müller', 'Guten Tag, Frau Müller.', 'de');
  // Only German capitalises nouns: in French this is a sentence.
  expect(splitAlternatives('Excusez-moi, Madame.', 'fr')).toEqual(['Excusez-moi, Madame.']);
  rejects('Madame', 'Excusez-moi, Madame.', 'fr');
});

test('comma annotations (plural endings, gender) are not alternatives', () => {
  expect(splitAlternatives('der Tisch, -e')).toEqual(['der Tisch']);
  expect(splitAlternatives('das Auto, -s')).toEqual(['das Auto']);
  expect(splitAlternatives('die Mutter, ¨')).toEqual(['die Mutter']);
  expect(splitAlternatives('die Stadt, ¨-e')).toEqual(['die Stadt']);
  expect(splitAlternatives('maison, f')).toEqual(['maison']);
  expect(splitAlternatives('les gens, pl.')).toEqual(['les gens']);
  expect(splitAlternatives('le/la secrétaire, m./f.')).toEqual(['le secrétaire', 'la secrétaire']);
  // A card whose answer is only markers keeps them.
  expect(splitAlternatives('m, f')).toEqual(['m', 'f']);
  rejects('e', 'der Tisch, -e', 'de');
  rejects('s', 'das Auto, -s', 'de');
  rejects('f', 'maison, f', 'fr');
  exactMatch('der Tisch', 'der Tisch, -e', 'de');
  exactMatch('der Tisch, -e', 'der Tisch, -e', 'de');
  exactMatch('das Auto', 'das Auto, -s', 'de', { multipleAnswers: false });
  exactMatch('maison', 'maison, f', 'fr', { multipleAnswers: false });
});

test("comma annotations: the learner's annotation must be the stored one", () => {
  rejects('der Tisch, -s', 'der Tisch, -e', 'de', ALL_OFF, 'almost');
  rejects('der Tisch, -s', 'der Tisch, -e', 'de', null, 'almost');
  rejects('maison, m', 'maison, f', 'fr', null, 'almost');
  rejects('das Auto, -en', 'das Auto, -s', 'de', null, 'almost');
  rejects('le chat, m', 'le chat', 'fr', null, 'almost');
  exactMatch('der Tisch, -e', 'der Tisch, -e', 'de', ALL_OFF);
  exactMatch('maison, f.', 'maison, f', 'fr', ALL_OFF);
  exactMatch('die Eltern, Pl.', 'die Eltern, Pl.', 'de', ALL_OFF);
  exactMatch('die Eltern', 'die Eltern, Pl.', 'de', ALL_OFF);
  // Capitals are answers, not markers.
  expect(splitAlternatives('Mme, M.')).toEqual(['Mme', 'M.']);
  expect(splitAlternatives('S, M, L')).toEqual(['S', 'M', 'L']);
  accepts('M.', 'Mme, M.', 'fr', null, ['partial']);
  accepts('M', 'S, M, L', 'en', null, ['partial']);
});

test('articles: a wrong article is wrong when the right one is in parentheses', () => {
  rejects('den Herr', '(der) Herr', 'de', null, 'wrongArticle');
  rejects('die Herr', 'Herr (der)', 'de', null, 'wrongArticle');
  rejects('la monsieur', '(le) monsieur', 'fr', null, 'wrongArticle');
  rejects('den Herr', '(der) Herr', 'de', ALL_ON, 'wrongArticle');
  accepts('Herr', '(der) Herr', 'de', null, ['parentheses']);
  accepts('der Herr', '(der) Herr', 'de', null, []);
  accepts('Herr', 'Herr (der)', 'de', null, ['parentheses']);
  accepts('le homme', "(l')homme", 'fr', null, []);
  // A trailing bracketed article also reads in front, without a "parentheses" note.
  accepts('der Herr', 'Herr (der)', 'de', null, []);
  accepts("l'homme", "homme (l')", 'fr', null, []);
  accepts('to appear', 'appear (to)', 'en', null, []);
  accepts('der Herr', 'Herr (der)', 'de', { parentheses: false }, []);
  rejects('Herr', 'Herr (der)', 'de', { parentheses: false }, 'missingArticle');
  accepts('la secrétaire', '(le/la) secrétaire', 'fr');
  // An extra article is still ignored when the answer declares none.
  accepts('die Frau', 'Frau (Dame)', 'de', null, ['parentheses']);
});

test('punctuation-only stored answers can be answered exactly', () => {
  for (const s of ['?', '!', '…', '...', '-', '–', '*', '~', '"', '«»', '%', '&', '+']) {
    exactMatch(s, s, 'fr');
  }
  exactMatch('–', '-', 'de');
  exactMatch('. . .', '...', 'de');
  rejects('!', '?', 'fr', ALL_ON);
  rejects('frage', '?', 'de', ALL_ON);
  rejects('?', 'lieb', 'de', ALL_ON);
});

test('ignoreCase OFF: case and accents both wrong is not "accents only"', () => {
  rejects('Garcon', 'garçon', 'fr', { ignoreCase: false }, 'almost');
  rejects('GARCON', 'le garçon', 'fr', { ignoreCase: false }, 'almost');
  rejects('Hubsch', 'hübsch', 'de', ALL_OFF, 'almost');
  rejects('garcon', 'garçon', 'fr', { ignoreCase: false }, 'accentsOnly');
});

test('hint: wrong article plus a small typo is almost', () => {
  rejects('der Strase', 'die Straße', 'de', null, 'almost');
  rejects('der Name', 'die Dame', 'de', null, 'almost');
  rejects('der Strasse', 'die Straße', 'de', null, 'wrongArticle');
  rejects('la nome', 'le nom', 'fr', null, null);
});

test('abbreviations: "zB" without dots means "zum Beispiel"', () => {
  for (const zb of ['zB', 'zb', 'z.B.', 'zb.', 'z. B.', 'z B']) {
    accepts(zb, 'zum Beispiel', 'de', null, ['abbreviation']);
    accepts('zum Beispiel', zb, 'de', null, ['abbreviation']);
  }
  accepts('zB', 'z. B.', 'de', null, ['abbreviation']);
  rejects('zbx', 'zum Beispiel', 'de');
});

// ---------------------------------------------------------------------------
// Arabic

test('Arabic: vowel marks, Quranic marks and tatweel never matter and give no note', () => {
  exactMatch('كتاب', 'كِتَابٌ', 'ar');
  exactMatch('كِتَابٌ', 'كتاب', 'ar');
  exactMatch('مدرسة', 'مُدَرِّسَةٌ', 'ar');
  exactMatch('هذا', 'هٰذَا', 'ar');
  exactMatch('الرحمن', 'الرَّحْمَٰنِ', 'ar');
  exactMatch('كتـــاب', 'كتاب', 'ar');
  exactMatch('كتاب', 'كتـاب', 'ar');
  // Whatever the accents setting, and in sets of another language.
  exactMatch('كتاب', 'كِتَابٌ', 'ar', { ignoreAccents: false, typos: false });
  exactMatch('كتاب', 'كِتَابٌ', null);
  exactMatch('كتاب', 'كِتَابٌ', 'other');
});

test('Arabic: presentation forms and bidi marks never matter', () => {
  exactMatch('كتاب', 'ﻛﺘﺎﺏ', 'ar');
  exactMatch('ﻛﺘﺎﺏ', 'كتاب', 'ar');
  exactMatch('لا', 'ﻻ', 'ar');
  exactMatch('كتاب', '‏كتاب‏', 'ar');
  exactMatch('‫كتاب‬', 'كتاب', 'ar');
});

test('Arabic: letter variants are correct with the note «Schreibvariante»', () => {
  accepts('مدرسه', 'مدرسة', 'ar', null, ['variant']); // ة/ه
  accepts('مدرسة', 'مدرسه', 'ar', null, ['variant']);
  accepts('مستشفي', 'مستشفى', 'ar', null, ['variant']); // ى/ي
  accepts('اب', 'أب', 'ar', null, ['variant']); // hamza on alef
  accepts('اسلام', 'إسلام', 'ar', null, ['variant']);
  accepts('القران', 'القرآن', 'ar', null, ['variant']); // madda
  accepts('اسم', 'ٱسم', 'ar', null, ['variant']); // alef wasla
  accepts('مسوول', 'مسؤول', 'ar', null, ['variant']); // ؤ → و
  accepts('رييس', 'رئيس', 'ar', null, ['variant']); // ئ → ي
  // Always allowed, even with every tolerance off.
  accepts('مدرسه', 'مدرسة', 'ar', { articles: false, abbreviations: false, multipleAnswers: false, parentheses: false, ignoreCase: false, ignoreAccents: false, typos: false }, ['variant']);
  // Gated on the script, not on the set's language.
  accepts('اب', 'أب', null, null, ['variant']);
  accepts('مدرسه', 'مدرسة', 'other', null, ['variant']);
});

test('Arabic: a hamza difference is a variant, not an accent or a typo', () => {
  accepts('اب', 'أب', 'ar', { ignoreAccents: true }, ['variant']);
  accepts('مسوول', 'مسؤول', 'ar', { ignoreAccents: true, typos: true }, ['variant']);
  accepts('مدرسة', 'مدرسه', 'ar', { typos: true }, ['variant']);
  accepts('مستشفي', 'مستشفى', 'ar', { ignoreAccents: true, typos: true }, ['variant']);
});

test('Arabic: a variant and a real typo together', () => {
  accepts('مدرصه', 'مدرسة', 'ar', { typos: true }, ['variant', 'typo']);
  rejects('مدرصه', 'مدرسة', 'ar', null, 'typo');
  // The typo comparator is tried before its variant twin: a budget of 2 takes both.
  accepts('مدرسه كبيرا', 'مدرسة كبيرة', 'ar', { typos: true }, ['typo']);
});

test('Arabic: ال is a glued article', () => {
  accepts('كتاب', 'الكتاب', 'ar', null, ['article']);
  accepts('شمس', 'الشَّمْسُ', 'ar', null, ['article']);
  rejects('كتاب', 'الكتاب', 'ar', { articles: false }, 'missingArticle');
  accepts('الكتاب', 'كتاب', 'ar', null, []); // an extra article is ignored
  exactMatch('الكتاب', 'الكتاب', 'ar');
  accepts('ال كتاب', 'الكتاب', 'ar', null, []);
  // With a letter variant in the word.
  accepts('مدرسه', 'المدرسة', 'ar', null, ['article', 'variant']);
  accepts('المدرسه', 'المدرسة', 'ar', null, ['variant']);
  // Dictionary forms: "كتاب، ال" and a bracketed article.
  accepts('الكتاب', 'كتاب، ال', 'ar', null, []);
  accepts('كتاب', '(ال)كتاب', 'ar', null, ['parentheses']);
  // ال alone is no article.
  exactMatch('ال', 'ال', 'ar');
  // Only for Arabic (the lang of the answer).
  rejects('كتاب', 'الكتاب', 'fr');
});

test('Arabic: ، and ؛ separate alternatives, ؟ is punctuation', () => {
  accepts('كتاب', 'كتاب، دفتر', 'ar', null, ['partial']);
  accepts('دفتر', 'كتاب ؛ دفتر', 'ar', null, ['partial']);
  accepts('دفتر، كتاب', 'كتاب، دفتر', 'ar', null, ['order']);
  exactMatch('كتاب، دفتر', 'كتاب, دفتر', 'ar');
  exactMatch('هل', 'هل؟', 'ar');
  exactMatch('هل؟', 'هل', 'ar');
  exactMatch('نعم', 'نعم!', 'ar');
});

test('Arabic: a sentence ending in . ? ! or … is one answer despite its commas', () => {
  rejects('كيف حالك', 'كيف حالك، يا أحمد؟', 'ar');
  rejects('مرحبا', 'مرحبا، أنا طالب.', 'ar');
  exactMatch('مرحبا، أنا طالب', 'مرحبا، أنا طالب.', 'ar');
  // Without a final mark it stays a list.
  accepts('مرحبا', 'مرحبا، أنا طالب', 'ar', null, ['partial']);
  expect(splitAlternatives('مرحبا، أنا طالب.', 'ar')).toEqual(['مرحبا، أنا طالب.']);
  expect(splitAlternatives('مرحبا، أنا طالب.')).toEqual(['مرحبا، أنا طالب.']);
});

test('Arabic: splitAlternatives keeps the vowel marks and characters as written', () => {
  expect(splitAlternatives('كتاب، دفتر')).toEqual(['كتاب', 'دفتر']);
  expect(splitAlternatives('كِتَابٌ، دَفْتَرٌ', 'ar')).toEqual(['كِتَابٌ', 'دَفْتَرٌ']);
  expect(splitAlternatives('كتاب؛ قلم؛ دفتر')).toEqual(['كتاب', 'قلم', 'دفتر']);
  expect(splitAlternatives('كتـاب، أب')).toEqual(['كتـاب', 'أب']);
  expect(splitAlternatives('هل؟')).toEqual(['هل؟']);
  expect(splitAlternatives('كتاب/دفتر')).toEqual(['كتاب', 'دفتر']);
});

test('Arabic: wrong answers stay wrong', () => {
  rejects('كتب', 'كتاب', 'ar', null, 'typo');
  accepts('كتب', 'كتاب', 'ar', { typos: true }, ['typo']);
  rejects('قلم', 'كتاب', 'ar', null, null);
  rejects('بيت', 'بنت', 'ar', null, null);
});

// ---------------------------------------------------------------------------
// Chinese

test('Chinese: lang codes resolve to zh and ar', () => {
  accepts('nǐ hǎo', '你好 (nǐ hǎo)', 'zh-CN', null, ['pinyin']);
  accepts('nǐ hǎo', '你好 (nǐ hǎo)', 'ZH', null, ['pinyin']);
  accepts('كتاب', 'الكتاب', 'ar-SA', null, ['article']);
});

test('Chinese: characters or pinyin are both correct', () => {
  accepts('你好', '你好 (nǐ hǎo)', 'zh', null, []);
  accepts('nǐ hǎo', '你好 (nǐ hǎo)', 'zh', null, ['pinyin']);
  exactMatch('你好 (nǐ hǎo)', '你好 (nǐ hǎo)', 'zh');
  accepts('你好 nǐ hǎo', '你好 (nǐ hǎo)', 'zh', null, []);
  accepts('你好nǐhǎo', '你好 (nǐ hǎo)', 'zh', null, []);
  // Full-width brackets, no brackets, pinyin first.
  accepts('你好', '你好（nǐ hǎo）', 'zh', null, []);
  accepts('nǐ hǎo', '你好（nǐ hǎo）', 'zh', null, ['pinyin']);
  accepts('你好', '你好 nǐ hǎo', 'zh', null, []);
  accepts('nǐ hǎo', '你好 nǐ hǎo', 'zh', null, ['pinyin']);
  accepts('你好', 'nǐ hǎo 你好', 'zh', null, []);
  accepts('nǐ hǎo', 'nǐ hǎo 你好', 'zh', null, ['pinyin']);
  accepts('nǐ hǎo', 'nǐ hǎo (你好)', 'zh', null, ['pinyin']);
});

test('Chinese: the characters alone get no brackets note, whatever the brackets setting', () => {
  accepts('你好', '你好 (nǐ hǎo)', 'zh', { parentheses: true }, []);
  accepts('你好', '你好 (nǐ hǎo)', 'zh', { parentheses: false }, []);
  accepts('nǐ hǎo', '你好 (nǐ hǎo)', 'zh', { parentheses: false }, ['pinyin']);
  // Other bracket contents keep the brackets rules.
  accepts('你好', '你好 (问候)', 'zh', null, ['parentheses']);
});

test('Chinese: cards with only characters need characters', () => {
  rejects('nǐ hǎo', '你好', 'zh');
  rejects('ni hao', '你好', 'zh', { ignoreAccents: true, typos: true });
  accepts('你好', '你好', 'zh', null, []);
});

test('Chinese: several pinyin readings in the brackets each count', () => {
  accepts('nǐ hǎo', '你好 (nǐ hǎo, ní hǎo)', 'zh', null, ['pinyin']);
  accepts('ní hǎo', '你好 (nǐ hǎo, ní hǎo)', 'zh', null, ['pinyin']);
  accepts('你好', '你好 (nǐ hǎo, ní hǎo)', 'zh', null, []);
});

test('Chinese: tone numbers equal tone marks', () => {
  accepts('ni3 hao3', '你好 (nǐ hǎo)', 'zh', null, ['pinyin']);
  accepts('ni3hao3', '你好 (nǐ hǎo)', 'zh', null, ['pinyin']);
  accepts('xie4xie5', '谢谢 (xiè xie)', 'zh', null, ['pinyin']);
  accepts('xie4xie', '谢谢 (xiè xie)', 'zh', null, ['pinyin']);
  // Stored with numbers, typed with marks.
  accepts('nǐ hǎo', '你好 (ni3 hao3)', 'zh', null, ['pinyin']);
  exactMatch('ma1', 'mā', 'zh');
  exactMatch('ma2', 'má', 'zh');
  exactMatch('ma3', 'mǎ', 'zh');
  exactMatch('ma4', 'mà', 'zh');
  exactMatch('ma5', 'ma', 'zh');
  exactMatch('ma0', 'ma', 'zh');
  exactMatch('Ni3', 'Nǐ', 'zh');
});

test('Chinese: the tone mark goes on a or e, on o in ou, otherwise on the last vowel', () => {
  exactMatch('hao3', 'hǎo', 'zh');
  exactMatch('xie4', 'xiè', 'zh');
  exactMatch('dou1', 'dōu', 'zh');
  exactMatch('liu2', 'liú', 'zh');
  exactMatch('gui4', 'guì', 'zh');
  exactMatch('lüe4', 'lüè', 'zh');
  exactMatch('zhuang4', 'zhuàng', 'zh');
  exactMatch('er2', 'ér', 'zh');
});

test('Chinese: v and u: stand for ü in tone syllables', () => {
  exactMatch('lv4', 'lǜ', 'zh');
  exactMatch('lǜ', 'lv4', 'zh');
  exactMatch('nu:3', 'nǚ', 'zh');
  exactMatch('nv3', 'nǚ', 'zh');
  exactMatch('lv5', 'lü', 'zh');
  // Outside a tone syllable v stays v.
  rejects('lv', 'lü', 'zh');
});

test('Chinese: digits that are no tone syllable stay', () => {
  exactMatch('3个', '3个', 'zh');
  exactMatch('MP3', 'MP3', 'zh');
  rejects('ni3', 'ni', 'zh', null, 'tonesOnly');
});

test('Chinese: spaces do not count', () => {
  accepts('nihao', '你好 (ni hao)', 'zh', null, ['pinyin']);
  accepts('nǐhǎo', '你好 (nǐ hǎo)', 'zh', null, ['pinyin']);
  accepts('ni hao', 'nihao', 'zh', null, []);
  exactMatch('你 好', '你好', 'zh');
  exactMatch('你好', '你 好', 'zh');
  accepts('我是 学生', '我是学生', 'zh', null, []);
});

test('Chinese: missing tones behave like accents (Töne)', () => {
  rejects('ni hao', '你好 (nǐ hǎo)', 'zh', null, 'tonesOnly');
  rejects('nihao', '你好 (nǐ hǎo)', 'zh', null, 'tonesOnly');
  accepts('ni hao', '你好 (nǐ hǎo)', 'zh', { ignoreAccents: true }, ['pinyin', 'tones']);
  rejects('ma', 'mā', 'zh', null, 'tonesOnly');
  rejects('mà', 'mā', 'zh', null, 'tonesOnly');
  accepts('mà', 'mā', 'zh', { ignoreAccents: true }, ['tones']);
  accepts('lu', 'lǜ', 'zh', { ignoreAccents: true }, ['tones']);
  // Other languages keep «Akzente».
  rejects('ni hao', 'nǐ hǎo', 'fr', null, 'accentsOnly');
  accepts('ni hao', 'nǐ hǎo', 'fr', { ignoreAccents: true }, ['accents']);
});

test('Chinese: a wrong character is never a typo; pinyin keeps the typo rule', () => {
  rejects('太', '大', 'zh', { typos: true });
  rejects('我是学士', '我是学生', 'zh', { typos: true });
  rejects('中家 zhōngguó', '中国 (zhōng guó)', 'zh', { typos: true });
  accepts('zhōnggua', '中国 (zhōng guó)', 'zh', { typos: true }, ['pinyin', 'typo']);
  accepts('中国 zhōnggua', '中国 (zhōng guó)', 'zh', { typos: true }, ['typo']);
  rejects('zhōnggua', '中国 (zhōng guó)', 'zh', null, 'typo');
});

test('Chinese: ，、； and / separate alternatives', () => {
  accepts('谢谢', '谢谢，多谢', 'zh', null, ['partial']);
  accepts('多谢', '谢谢、多谢', 'zh', null, ['partial']);
  accepts('多谢', '谢谢；多谢', 'zh', null, ['partial']);
  accepts('多谢', '谢谢/多谢', 'zh', null, ['partial']);
  accepts('您', '你/您', 'zh', null, ['partial']);
  expect(splitAlternatives('谢谢，多谢')).toEqual(['谢谢', '多谢']);
  expect(splitAlternatives('谢谢、多谢；再见')).toEqual(['谢谢', '多谢', '再见']);
  expect(splitAlternatives('谢谢/多谢')).toEqual(['谢谢', '多谢']);
  expect(splitAlternatives('你/您')).toEqual(['你', '您']);
  // Full-width brackets are brackets: their commas do not separate.
  expect(splitAlternatives('你好（nǐ hǎo，ní hǎo），您好')).toEqual(['你好（nǐ hǎo，ní hǎo）', '您好']);
});

test('Chinese: CJK punctuation and quotes never matter', () => {
  exactMatch('你好', '你好！', 'zh');
  exactMatch('你好！', '你好', 'zh');
  exactMatch('你好', '你好。', 'zh');
  exactMatch('好吗', '好吗？', 'zh');
  exactMatch('你好', '「你好」', 'zh');
  exactMatch('红楼梦', '《红楼梦》', 'zh');
  exactMatch('你好', '『你好』', 'zh');
  exactMatch('你好', '〈你好〉', 'zh');
});

test('Chinese: a sentence with a final 。 is one answer', () => {
  rejects('你好', '你好，我是学生。', 'zh');
  exactMatch('你好，我是学生', '你好，我是学生。', 'zh');
  expect(splitAlternatives('你好，我是学生。', 'zh')).toEqual(['你好，我是学生。']);
  expect(splitAlternatives('你好，我是学生。')).toEqual(['你好，我是学生。']);
  // A question too.
  rejects('你好', '你好，你叫什么名字？', 'zh');
});

test('Chinese: the pinyin rules apply only when the answer language is Chinese', () => {
  rejects('nǐ hǎo', '你好 (nǐ hǎo)', 'fr');
  accepts('你好', '你好 (nǐ hǎo)', 'fr', null, ['parentheses']);
  accepts('你好', '你好 (nǐ hǎo)', null, null, ['parentheses']);
  rejects('ni3', 'nǐ', 'fr');
  rejects('nihao', 'ni hao', 'fr');
  // Spaces between characters never count.
  exactMatch('你 好', '你好', 'fr');
});

test('Chinese and Arabic: note and hint order', () => {
  const r = grade('ni hao, xie xie', '你好 (nǐ hǎo), 谢谢 (xiè xie)', { ignoreAccents: true }, 'zh');
  expect(r.correct).toBe(true);
  expect(r.notes).toEqual(['pinyin', 'tones']);
  accepts('مدرسه', 'المدرسة', 'ar', null, ['article', 'variant']);
  accepts('مدرسه, كتاب', 'كتاب، المدرسة', 'ar', { typos: true }, ['article', 'variant', 'order']);
});

// ---------------------------------------------------------------------------
// Diffs for Arabic and Chinese

test('diffChars: marks stay with their letter', () => {
  expect(diffChars('كتب', 'كِتَبَ')).toEqual([
    { type: 'del', text: 'كتب' },
    { type: 'add', text: 'كِتَبَ' },
  ]);
  expect(diffChars('كِتب', 'كِتَبَ')).toEqual([
    { type: 'same', text: 'كِ' },
    { type: 'del', text: 'تب' },
    { type: 'add', text: 'تَبَ' },
  ]);
  // A Latin letter with a mark that has no precomposed form is one character too.
  expect(diffChars('q', 'q́')).toEqual([
    { type: 'del', text: 'q' },
    { type: 'add', text: 'q́' },
  ]);
});

test('diffAnswer: Arabic vowel marks only show when the learner typed some', () => {
  expect(diffAnswer('كتاب', 'كِتَابٌ')).toEqual([{ type: 'same', text: 'كتاب' }]);
  expect(diffAnswer('كتب', 'كِتَابٌ')).toEqual([
    { type: 'same', text: 'كت' },
    { type: 'add', text: 'ا' },
    { type: 'same', text: 'ب' },
  ]);
  expect(diffAnswer('كتاب', 'كتـاب')).toEqual([{ type: 'same', text: 'كتاب' }]);
  // Some marks typed: the marks count, letter by letter.
  expect(diffAnswer('كِتاب', 'كِتَابٌ')).toEqual([
    { type: 'same', text: 'كِ' },
    { type: 'del', text: 'ت' },
    { type: 'add', text: 'تَ' },
    { type: 'same', text: 'ا' },
    { type: 'del', text: 'ب' },
    { type: 'add', text: 'بٌ' },
  ]);
});

test('diffAnswer: Chinese diffs against the form typed, tone numbers as marks', () => {
  expect(diffAnswer('ni hao', '你好 (nǐ hǎo)', 'zh')).toEqual([
    { type: 'same', text: 'n' },
    { type: 'del', text: 'i' },
    { type: 'add', text: 'ǐ' },
    { type: 'same', text: ' h' },
    { type: 'del', text: 'a' },
    { type: 'add', text: 'ǎ' },
    { type: 'same', text: 'o' },
  ]);
  expect(diffAnswer('ni3 hao', '你好（nǐ hǎo）', 'zh')).toEqual([
    { type: 'same', text: 'nǐ h' },
    { type: 'del', text: 'a' },
    { type: 'add', text: 'ǎ' },
    { type: 'same', text: 'o' },
  ]);
  expect(diffAnswer('你们', '你好 (nǐ hǎo)', 'zh')).toEqual([
    { type: 'same', text: '你' },
    { type: 'del', text: '们' },
    { type: 'add', text: '好' },
  ]);
  expect(diffAnswer('你好 (ni hǎo)', '你好 (nǐ hǎo)', 'zh')).toEqual([
    { type: 'same', text: '你好 (n' },
    { type: 'del', text: 'i' },
    { type: 'add', text: 'ǐ' },
    { type: 'same', text: ' hǎo)' },
  ]);
  // Without the language: the whole answer, as before.
  expect(diffAnswer('ni hao', '你好 (nǐ hǎo)')[0]).toEqual({ type: 'add', text: '你好 (' });
});

// ---------------------------------------------------------------------------
// Latin languages keep their behaviour

test('Latin regressions: accents, brackets, spaces and typos as before', () => {
  rejects('garcon', 'garçon', 'fr', null, 'accentsOnly');
  accepts('garcon', 'garçon', 'fr', { ignoreAccents: true }, ['accents']);
  accepts('le pain', 'le pain (frais)', 'fr', null, ['parentheses']);
  rejects('frais', 'le pain (frais)', 'fr');
  rejects('lepain', 'le pain', 'fr');
  rejects('Haus', 'Hand', 'de', { typos: true });
  accepts('Hause', 'Hause', 'de', { typos: true }, []);
  accepts('Strase', 'Strasse', 'de', { typos: true }, ['typo']);
  accepts('ja', 'ja, nein.', 'de', null, ['partial']);
  rejects('Ça va', 'Ça va bien, merci.', 'fr');
  accepts('homme', "l'homme", 'fr', null, ['article']);
  expect(splitAlternatives('le chat (frais), la chatte')).toEqual(['le chat (frais)', 'la chatte']);
  expect(diffAnswer('garcon', 'garçon')).toEqual([
    { type: 'same', text: 'gar' },
    { type: 'del', text: 'c' },
    { type: 'add', text: 'ç' },
    { type: 'same', text: 'on' },
  ]);
});

// ---------------------------------------------------------------------------
// exported constants

test('constants: ARTICLES per language', () => {
  expect(ARTICLES.fr).toContain("l'");
  expect(ARTICLES.fr).toContain('de la');
  expect(ARTICLES.de).toContain('der');
  expect(ARTICLES.de).toContain('eines');
  expect(ARTICLES.en).toContain('to');
  expect(ARTICLES.es).toContain('unas');
  expect(ARTICLES.it).toContain("un'");
});

test('constants: REFLEXIVES per language', () => {
  expect(REFLEXIVES).toEqual({ fr: ['se ', "s'"], de: ['sich '], en: ['oneself'], es: [], it: [], ar: [], zh: [] });
});

test('constants: Arabic has the glued article ال, Chinese has none', () => {
  expect(ARTICLES.ar).toEqual(['ال']);
  expect(ARTICLES.zh).toEqual([]);
  expect(GLUED_ARTICLES).toEqual(['ال']);
  expect(Object.keys(ARTICLES)).toEqual(['fr', 'de', 'en', 'es', 'it', 'ar', 'zh']);
});

test('constants: ABBREVIATIONS are [RegExp, string] pairs', () => {
  expect(ABBREVIATIONS.length).toBeGreaterThan(10);
  for (const entry of ABBREVIATIONS) {
    expect(entry[0] instanceof RegExp).toBe(true);
    expect(typeof entry[1]).toBe('string');
  }
});

await run('grading.test.js');
