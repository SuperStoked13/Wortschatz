import { test, expect, run } from './harness.js';
import { promptSide, answerSide, findSynonymCards, gradeWithSynonyms } from '../src/core/synonyms.js';
import { grade, DEFAULT_TOLERANCE } from '../src/core/grading.js';

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

const CARDS = PAIRS.map(([term, definition], i) => ({ id: `c${i + 1}`, term, definition, starred: false }));
const byTerm = (term) => CARDS.find((c) => c.term === term);
const terms = (cards) => cards.map((c) => c.term);

// The prompts that appear on two cards of the user's list (answerWith 'term':
// the German definition is shown, the French term is typed).
const SYNONYM_PAIRS = [
  ['laid, laide', 'moche'], // hässlich
  ['le visage', 'la figure'], // das Gesicht
  ['brave', 'gentil, gentille'], // lieb | lieb, nett
  ['la femme', 'la mademoiselle, mesdemoiselles'], // die Frau | das Fräulein, die Frau
];

// ---------------------------------------------------------------------------
// promptSide / answerSide

test('promptSide/answerSide: ask is the side the learner types', () => {
  const card = byTerm('moche');
  expect(promptSide(card, 'term')).toBe('hässlich');
  expect(answerSide(card, 'term')).toBe('moche');
  expect(promptSide(card, 'definition')).toBe('moche');
  expect(answerSide(card, 'definition')).toBe('hässlich');
});

test('promptSide/answerSide: never throw on odd input', () => {
  expect(promptSide(null, 'term')).toBe('');
  expect(answerSide(undefined, 'definition')).toBe('');
  expect(promptSide({ term: 42 }, 'definition')).toBe('42');
  expect(answerSide({ term: null }, 'term')).toBe('');
  expect(promptSide('card', 'term')).toBe('');
});

// ---------------------------------------------------------------------------
// findSynonymCards

test('findSynonymCards: the four shared prompts of the user list, both ways', () => {
  for (const [a, b] of SYNONYM_PAIRS) {
    expect(terms(findSynonymCards(CARDS, byTerm(a), 'term'))).toEqual([b]);
    expect(terms(findSynonymCards(CARDS, byTerm(b), 'term'))).toEqual([a]);
  }
});

test('findSynonymCards: no other card of the user list has a synonym', () => {
  const paired = new Set(SYNONYM_PAIRS.flat());
  for (const card of CARDS) {
    const found = findSynonymCards(CARDS, card, 'term');
    if (!paired.has(card.term)) expect([card.term, terms(found)]).toEqual([card.term, []]);
    // Asking for the German side shows distinct French prompts: no synonyms at all.
    expect([card.term, terms(findSynonymCards(CARDS, card, 'definition'))]).toEqual([card.term, []]);
  }
  // "Frau" (la madame) and "die Frau" (la femme) are different prompts.
  expect(terms(findSynonymCards(CARDS, byTerm('la madame, mesdames'), 'term'))).toEqual([]);
});

test('findSynonymCards: works when the definition is asked', () => {
  const cards = [
    { id: 'a', term: 'la figure', definition: 'das Gesicht' },
    { id: 'b', term: 'La Figure', definition: 'die Figur' },
    { id: 'c', term: 'le visage', definition: 'das Gesicht' },
  ];
  expect(findSynonymCards(cards, cards[0], 'definition').map((c) => c.id)).toEqual(['b']);
  expect(findSynonymCards(cards, cards[1], 'definition').map((c) => c.id)).toEqual(['a']);
  expect(findSynonymCards(cards, cards[2], 'definition').map((c) => c.id)).toEqual([]);
  expect(findSynonymCards(cards, cards[0], 'term').map((c) => c.id)).toEqual(['c']);
});

test('findSynonymCards: prompts match by alternative, case, ß/ss and punctuation', () => {
  const cards = [
    { id: '1', term: 'grand', definition: 'gross, hoch' },
    { id: '2', term: 'haut', definition: 'Hoch!' },
    { id: '3', term: 'gros', definition: 'groß' },
    { id: '4', term: 'large', definition: 'breit' },
  ];
  expect(findSynonymCards(cards, cards[0], 'term').map((c) => c.id)).toEqual(['2', '3']);
  expect(findSynonymCards(cards, cards[2], 'term').map((c) => c.id)).toEqual(['1']);
  expect(findSynonymCards(cards, cards[3], 'term').map((c) => c.id)).toEqual([]);
});

test('findSynonymCards: skips the card itself, empty answers and junk', () => {
  const card = { id: 'x', term: 'moche', definition: 'hässlich' };
  const copy = { id: 'x', term: 'moche', definition: 'hässlich' }; // same id, other object
  const empty = { id: 'y', term: '  ', definition: 'hässlich' };
  const noId = { term: 'laid', definition: 'hässlich' };
  expect(findSynonymCards([card, copy, empty, null, 7, noId], card, 'term')).toEqual([noId]);
  expect(findSynonymCards([noId], noId, 'term')).toEqual([]);
  expect(findSynonymCards(null, card, 'term')).toEqual([]);
  expect(findSynonymCards([card], null, 'term')).toEqual([]);
  expect(findSynonymCards([card, noId], { id: 'z', term: 'x', definition: '' }, 'term')).toEqual([]);
});

// ---------------------------------------------------------------------------
// gradeWithSynonyms

test('gradeWithSynonyms: a synonym card\'s answer is accepted, both ways', () => {
  for (const [a, b] of SYNONYM_PAIRS) {
    for (const [asked, other] of [
      [byTerm(a), byTerm(b)],
      [byTerm(b), byTerm(a)],
    ]) {
      const given = other.term;
      expect(grade(given, asked.term, DEFAULT_TOLERANCE, 'fr').correct).toBe(false);
      const { result, matchedCard } = gradeWithSynonyms(given, asked, CARDS, 'term', DEFAULT_TOLERANCE, 'fr');
      expect([given, result.correct]).toEqual([given, true]);
      expect(result.notes[0]).toBe('synonym');
      expect(result.exact).toBe(false);
      expect(result.hint).toBe(null);
      expect(result.expectedDisplay).toBe(asked.term);
      expect(matchedCard).toBe(other);
    }
  }
});

test('gradeWithSynonyms: single forms of a synonym card count, with its tolerance notes', () => {
  const moche = byTerm('moche');
  const r1 = gradeWithSynonyms('laide', moche, CARDS, 'term', null, 'fr');
  expect(r1.result.correct).toBe(true);
  expect(r1.result.notes).toEqual(['synonym']); // "partial" describes the other card
  expect(r1.matchedCard).toBe(byTerm('laid, laide'));
  const r2 = gradeWithSynonyms('visage', byTerm('la figure'), CARDS, 'term', null, 'fr');
  expect(r2.result.notes).toEqual(['synonym', 'article']);
  const r3 = gradeWithSynonyms('gentile', byTerm('brave'), CARDS, 'term', { typos: true }, 'fr');
  expect(r3.result.correct).toBe(true);
  expect(r3.result.notes).toEqual(['synonym', 'typo']);
  // Tolerances still apply: the typo is wrong with typos off.
  expect(gradeWithSynonyms('gentile', byTerm('brave'), CARDS, 'term', null, 'fr').result.correct).toBe(false);
});

test('gradeWithSynonyms: the asked card wins and keeps its own result', () => {
  const asked = byTerm('laid, laide');
  const own = grade('laid', asked.term, null, 'fr');
  const r = gradeWithSynonyms('laid', asked, CARDS, 'term', null, 'fr');
  expect(r.result).toEqual(own);
  expect(r.matchedCard).toBe(null);
  const exact = gradeWithSynonyms('moche', byTerm('moche'), CARDS, 'term', null, 'fr');
  expect(exact.result.exact).toBe(true);
  expect(exact.result.notes).toEqual([]);
  expect(exact.matchedCard).toBe(null);
});

test('gradeWithSynonyms: answers of unrelated cards stay wrong', () => {
  const cases = [
    ['le garçon', 'la fille'],
    ['sage', 'brave'], // "brav, artig" is not "lieb"
    ['la madame', 'la femme'], // "Frau" is not "die Frau"
    ['joli', 'moche'],
  ];
  for (const [given, askedTerm] of cases) {
    const asked = byTerm(askedTerm);
    const r = gradeWithSynonyms(given, asked, CARDS, 'term', null, 'fr');
    expect([given, r.result]).toEqual([given, grade(given, asked.term, null, 'fr')]);
    expect(r.matchedCard).toBe(null);
  }
  // A wrong answer keeps the asked card's hint.
  const r = gradeWithSynonyms('le visage', byTerm('la figure'), CARDS, 'term', null, 'fr');
  expect(r.result.correct).toBe(true);
  const wrong = gradeWithSynonyms('la visage', byTerm('la figure'), CARDS, 'term', null, 'fr');
  expect(wrong.result.correct).toBe(false);
  expect(wrong.matchedCard).toBe(null);
});

test('gradeWithSynonyms: works when the definition is asked', () => {
  const cards = [
    { id: 'a', term: 'la figure', definition: 'das Gesicht' },
    { id: 'b', term: 'la figure', definition: 'die Figur' },
  ];
  const r = gradeWithSynonyms('Figur', cards[0], cards, 'definition', null, 'de');
  expect(r.result.correct).toBe(true);
  expect(r.result.notes).toEqual(['synonym', 'article']);
  expect(r.result.expectedDisplay).toBe('das Gesicht');
  expect(r.matchedCard).toBe(cards[1]);
  // The user's list asked for German: distinct French prompts, no synonyms.
  const own = gradeWithSynonyms('hässlich', byTerm('le visage'), CARDS, 'definition', null, 'de');
  expect(own.result.correct).toBe(false);
  expect(own.matchedCard).toBe(null);
});

test('gradeWithSynonyms: the closest synonym match is reported', () => {
  const cards = [
    { id: 'a', term: 'beau', definition: 'schön' },
    { id: 'b', term: 'jolie', definition: 'schön' },
    { id: 'c', term: 'joli, jolie', definition: 'schön, hübsch' },
  ];
  const r = gradeWithSynonyms('jolie', cards[0], cards, 'term', null, 'fr');
  expect(r.matchedCard).toBe(cards[1]); // exact beats partial
  expect(r.result.notes).toEqual(['synonym']);
});

test('gradeWithSynonyms: never throws on odd input', () => {
  const card = byTerm('moche');
  for (const cards of [null, undefined, 'x', [], [null, 1, {}]]) {
    const r = gradeWithSynonyms('laide', card, cards, 'term', null, 'fr');
    expect(r.result.correct).toBe(false);
    expect(r.matchedCard).toBe(null);
  }
  const r = gradeWithSynonyms('', card, CARDS, 'term', null, 'fr');
  expect(r.result.correct).toBe(false);
  expect(gradeWithSynonyms('x', null, CARDS, 'term', null, 'fr').result.correct).toBe(false);
  expect(gradeWithSynonyms(null, card, CARDS, undefined, undefined, undefined).result.correct).toBe(false);
});

test('findSynonymCards: Arabic vowel marks and full-width punctuation do not matter', () => {
  const cards = [
    { id: 'a1', term: 'كِتَابٌ', definition: 'Buch' },
    { id: 'a2', term: 'كتاب', definition: 'Band' },
    { id: 'a3', term: 'ﻛﺘﺎﺏ، دفتر', definition: 'Schreibzeug' },
    { id: 'a4', term: 'قلم', definition: 'Stift' },
    { id: 'z1', term: '你好！', definition: 'Hallo' },
    { id: 'z2', term: '你 好', definition: 'Guten Tag' },
    { id: 'z3', term: '谢谢，多谢', definition: 'Danke' },
    { id: 'z4', term: '多谢', definition: 'Vielen Dank' },
    { id: 'z5', term: '「再见」', definition: 'Tschüss' },
    { id: 'z6', term: '再见', definition: 'Auf Wiedersehen' },
  ];
  const ids = (id) => findSynonymCards(cards, cards.find((c) => c.id === id), 'definition').map((c) => c.id);
  expect(ids('a1')).toEqual(['a2', 'a3']);
  expect(ids('a4')).toEqual([]);
  expect(ids('z1')).toEqual(['z2']);
  expect(ids('z3')).toEqual(['z4']);
  expect(ids('z5')).toEqual(['z6']);
  const r = gradeWithSynonyms('Band', cards[0], cards, 'definition', DEFAULT_TOLERANCE, 'de');
  expect(r.result.correct).toBe(true);
  expect(r.result.notes).toEqual(['synonym']);
  expect(r.matchedCard.id).toBe('a2');
});

test('gradeWithSynonyms: Arabic and Chinese notes of a synonym card are kept', () => {
  const cards = [
    { id: 's1', term: 'Schule', definition: 'المدرسة' },
    { id: 's2', term: 'Schule', definition: 'كُلِّيَّة' },
    { id: 'h1', term: 'Hallo', definition: '你好 (nǐ hǎo)' },
    { id: 'h2', term: 'Hallo', definition: '喂 (wèi)' },
  ];
  const variant = gradeWithSynonyms('كليه', cards[0], cards, 'definition', DEFAULT_TOLERANCE, 'ar');
  expect(variant.result.notes).toEqual(['synonym', 'variant']);
  const pinyin = gradeWithSynonyms('wei4', cards[2], cards, 'definition', DEFAULT_TOLERANCE, 'zh');
  expect(pinyin.result.notes).toEqual(['synonym', 'pinyin']);
  expect(pinyin.matchedCard.id).toBe('h2');
});

await run('synonyms.test.js');
