// Parity fixture for src/core/synonyms.js → Fixtures/synonyms.json.
//
// fns:
//   sides       [card, ask]                     → [promptSide, answerSide]
//   synonymSet  [cards, ask, lang, queries]     → { synonyms: [[id] per card (findSynonymCards)],
//                                                   results: [{result, matchedCard} per query (gradeWithSynonyms)] }
//               queries: [[cardIndex, given, mask], ...]; mask bit b = DEFAULT_TOLERANCE key b
//
// Card sets: every tests/fixtures list (parseVocab), the sets of tests/synonyms.test.js and, for each
// fixture list, a synonym-rich copy with added cards that share prompts (same text, other case and
// punctuation, ß/ss, one alternative of a longer prompt, combined prompts, empty answers, a reused id).
// Both ask sides; given answers are the asked card's own answer, its synonym cards' answers (whole, one
// alternative, without article, with a typo), another card's answer and an empty answer.
import { findSynonymCards, gradeWithSynonyms, promptSide, answerSide } from '../../Website/src/core/synonyms.js';
import { splitAlternatives, DEFAULT_TOLERANCE } from '../../Website/src/core/grading.js';
import { parseVocab } from '../../Website/src/core/parser.js';
import { Cases, mulberry32, pick, randInt, chance, fixtureTexts } from './lib.js';

const cases = new Cases('synonyms');
const rng = mulberry32(0x5f0a71);

const KEYS = Object.keys(DEFAULT_TOLERANCE);
const maskOf = (tol) => KEYS.reduce((m, k, b) => m | (tol[k] ? 1 << b : 0), 0);
const tolOf = (mask) => Object.fromEntries(KEYS.map((k, b) => [k, Boolean(mask & (1 << b))]));
const DEFAULT_MASK = maskOf(DEFAULT_TOLERANCE);
const STANDARD = [DEFAULT_MASK, (1 << KEYS.length) - 1, 0, ...KEYS.map((_, b) => DEFAULT_MASK ^ (1 << b))];

const card = (id, term, definition) => ({ id, term, definition, starred: false });
const LETTERS = Array.from('abcdefghijklmnopqrstuvwxyzéèàäöüß');

function typo(s) {
  const a = Array.from(s);
  if (a.length < 2) return s;
  const i = randInt(rng, 0, a.length - 1);
  if (chance(rng, 0.5)) a[i] = pick(rng, LETTERS);
  else a.splice(i, 1);
  return a.join('');
}

const stripArticle = (s) => s.replace(/^(?:les|le|la|l'|un|une|der|die|das|the|to|a|an|el|los|las|il|lo|gli|i)\s*/i, '');

// One scenario: every card's synonyms and gradeWithSynonyms for a list of queries.
function scenario(cards, ask, lang, perCard = 4) {
  const synonyms = cards.map((c) => findSynonymCards(cards, c, ask));
  const queries = [];
  cards.forEach((c, i) => {
    const givens = new Set([answerSide(c, ask)]);
    for (const other of synonyms[i]) {
      const answer = answerSide(other, ask);
      givens.add(answer);
      const alts = splitAlternatives(answer);
      if (alts.length > 1) givens.add(pick(rng, alts));
      givens.add(stripArticle(answer));
      givens.add(typo(answer));
    }
    givens.add(answerSide(pick(rng, cards), ask));
    if (chance(rng, 0.2)) givens.add('');
    let k = 0;
    for (const given of givens) {
      if (k++ >= perCard + 2 * synonyms[i].length) break;
      queries.push([i, given, k === 1 || chance(rng, 0.5) ? DEFAULT_MASK : pick(rng, STANDARD)]);
    }
  });
  const results = queries.map(([i, given, mask]) => gradeWithSynonyms(given, cards[i], cards, ask, tolOf(mask), lang));
  cases.add('synonymSet', [cards, ask, lang, queries], { synonyms: synonyms.map((list) => list.map((c) => c.id)), results });
}

// ---------------------------------------------------------------------------
// promptSide / answerSide

for (const c of [card('a', 'moche', 'hässlich'), card('b', '', 'x'), card('c', 'le chat', ''), card('', '  a  ', 'b ')]) {
  for (const ask of ['term', 'definition']) cases.add('sides', [c, ask], [promptSide(c, ask), answerSide(c, ask)]);
}

// ---------------------------------------------------------------------------
// tests/synonyms.test.js sets

scenario([card('a', 'la figure', 'das Gesicht'), card('b', 'La Figure', 'die Figur'), card('c', 'le visage', 'das Gesicht')], 'definition', 'de');
scenario([card('a', 'la figure', 'das Gesicht'), card('b', 'La Figure', 'die Figur'), card('c', 'le visage', 'das Gesicht')], 'term', 'fr');
scenario([card('1', 'grand', 'gross, hoch'), card('2', 'haut', 'Hoch!'), card('3', 'gros', 'groß'), card('4', 'large', 'breit')], 'term', 'fr');
scenario([card('a', 'beau', 'schön'), card('b', 'jolie', 'schön'), card('c', 'joli, jolie', 'schön, hübsch')], 'term', 'fr');
scenario([card('a', 'la figure', 'das Gesicht'), card('b', 'la figure', 'die Figur')], 'definition', 'de');
scenario([card('x', 'moche', 'hässlich'), card('x', 'moche', 'hässlich'), card('y', '  ', 'hässlich'), card('z', 'laid', 'hässlich')], 'term', 'fr');
{
  // Arabic vowel marks, presentation forms, full-width punctuation and CJK quotes in prompts.
  const scripts = [
    card('a1', 'كِتَابٌ', 'Buch'), card('a2', 'كتاب', 'Band'), card('a3', 'ﻛﺘﺎﺏ، دفتر', 'Schreibzeug'), card('a4', 'قلم', 'Stift'),
    card('z1', '你好！', 'Hallo'), card('z2', '你 好', 'Guten Tag'), card('z3', '谢谢，多谢', 'Danke'), card('z4', '多谢', 'Vielen Dank'),
    card('z5', '「再见」', 'Tschüss'), card('z6', '再见', 'Auf Wiedersehen'),
  ];
  scenario(scripts, 'definition', 'de');
  scenario(scripts, 'term', 'ar');
  scenario(scripts, 'term', 'zh');
  // Letter variants and pinyin answers of synonym cards.
  const notes = [
    card('s1', 'Schule', 'المدرسة'), card('s2', 'Schule', 'كُلِّيَّة'), card('s3', 'Schule', 'مدرسه'),
    card('h1', 'Hallo', '你好 (nǐ hǎo)'), card('h2', 'Hallo', '喂 (wèi)'), card('h3', 'Hallo', 'nǐ hǎo 您好'),
  ];
  scenario(notes, 'definition', 'ar');
  scenario(notes, 'definition', 'zh');
  scenario(notes, 'term', 'de');
}

// ---------------------------------------------------------------------------
// Fixture lists, as parsed and with added synonym cards

for (const { name, text } of fixtureTexts()) {
  const r = parseVocab(text);
  const prefix = name.replace(/\.[a-z]+$/, '');
  const cards = r.cards.map((c, i) => card(`${prefix}-${i + 1}`, c.term, c.definition));
  for (const ask of ['term', 'definition']) scenario(cards, ask, ask === 'term' ? r.termLang : r.defLang);

  // Synonym-rich copy: prompts shared in many spellings.
  const rich = cards.map((c) => ({ ...c }));
  const n = cards.length;
  for (let k = 0; k < Math.min(10, n); k++) {
    const a = pick(rng, cards);
    const b = pick(rng, cards);
    const id = `${prefix}-x${k}`;
    switch (k % 7) {
      case 0: rich.push(card(id, b.term, a.definition)); break; // same German prompt
      case 1: rich.push(card(id, a.term, b.definition)); break; // same French prompt
      case 2: rich.push(card(id, b.term, `${a.definition.toUpperCase()}!`)); break;
      case 3: rich.push(card(id, b.term, pick(rng, splitAlternatives(a.definition).concat([a.definition])))); break;
      case 4: rich.push(card(id, b.term, `${a.definition.replace(/ss/g, 'ß')}, ${b.definition}`)); break;
      case 5: rich.push(card(id, '  ', a.definition)); break; // empty answer: never a synonym
      default: rich.push(card(a.id, `${b.term}x`, a.definition)); // reused id: counts as the same card
    }
  }
  for (const ask of ['term', 'definition']) scenario(rich, ask, ask === 'term' ? r.termLang : r.defLang, 3);
}

cases.emit();
