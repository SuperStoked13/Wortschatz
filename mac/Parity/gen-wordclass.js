// Parity fixture for src/core/wordclass.js (word classes of multiple-choice options) → Fixtures/wordclass.json.
//
// fns:
//   sideProfile  [texts]          → { lang, wordCaps, capsNoun, capsRare }
//   textClass    [text, side]     → { cls, strength }
//   optionShape  [text, side]     → { article, head, words, length }
//   cardClasses  [cards]          → { sides: listProfiles(cards), classes: [cardClass per card] }
//   shapePoints  [a, b]           → points (a, b: optionShape results)
//   nearPoints   [distance]       → points
//
// Inputs: every tests/fixtures list (parseVocab, both sides), the texts of tests/wordclass.test.js and
// hand-made texts for every cue, each with every side profile below, plus seeded fuzz built from
// articles, cue words, endings, brackets, commas and punctuation.
import {
  sideProfile,
  textClass,
  optionShape,
  listProfiles,
  cardClass,
  shapePoints,
  nearPoints,
} from '../../Website/src/core/wordclass.js';
import { parseVocab } from '../../Website/src/core/parser.js';
import { Cases, mulberry32, pick, randInt, chance, fixtureTexts } from './lib.js';

const cases = new Cases('wordclass');
const rng = mulberry32(0x3c1a55);

const side = (lang, flags = {}) => ({ lang, wordCaps: false, capsNoun: false, capsRare: false, ...flags });
const SIDES = [
  side('de', { wordCaps: true, capsNoun: true }),
  side('de', { wordCaps: true }),
  side('de', { capsNoun: true }),
  side('de'),
  side('fr', { capsRare: true }),
  side('fr'),
  side('en', { capsRare: true }),
  side('en'),
  side('es', { capsRare: true }),
  side('it', { capsRare: true }),
  side('ar', { capsRare: true }),
  side('zh'),
  side('unknown'),
  side('unknown', { capsRare: true }),
];

const TEXTS = [
  // nouns
  'le corps', 'la tête', "l'oreille, f.", "l'œil, m. les yeux", 'le/la pilote', 'la brosse (à cheveux)', 'les secours',
  'un chien', 'une maison', 'des amis', 'du pain', "l'os, m.", "l'alcoolique, m./f.", 'le cerveau, les cerveaux',
  'der Körper', 'die Katze', 'das Haus', 'ein Hund', 'eine Frau', 'der/die Angestellte', 'Aussenminister(in)',
  'Staatsbürger(in)', 'Lehrer/in', 'the United Nations', 'a dog', 'an apple', 'the (European) Single Market',
  'el perro', 'los niños', 'las casas', 'una mesa', 'unos libros', 'il cane', 'lo zio', 'gli amici', 'i libri',
  "l'amico", "un'amica", 'le case', 'le', 'la', 'Le Chat', "L'Homme", 'LE CORPS',
  'Meilenstein', 'Zerstörung', 'zerstörung', 'Versöhnung', 'Gemeinsame Agrarpolitik', 'gemeinsame Politik',
  'Besorgnis über etw.', 'Zoll (auf etw.)', '(verabschiedetes) Gesetz', 'Frohe Weihnachten', 'Achtung', 'Noël',
  'Congress', 'European Court of Justice', 'Common Agricultural Policy', 'destruction', 'invulnerability',
  'reconciliation', 'isolationism', 'citizenship', 'la nation', 'nation', 'le gouvernement', 'mankind',
  // verbs
  'to propose sth', 'to be in ruins', 'to date back to a certain time', 'to', 'to go', 'se lever', 'se', "s'amuser",
  "s'habituer à", 's', "s'", 'sich freuen', '(sich) duschen', 'sich (an einem Ort) niederlassen', 'essen', 'wissen',
  'feiern', 'sammeln', 'wehtun', 'sein', 'tun', 'Schmerzen haben', 'Lust haben auf', 'etw. vorschlagen',
  'jmdm. zu Hilfe kommen', 'jmdn./etw. betreffen', 'eine Wahl abhalten', 'die Unabhängigkeit erlangen',
  'ein wesentlicher Bestandteil von etw. sein', 'in Schutt und Asche liegen, in Trümmern liegen', 'Essen', 'modern',
  'golden', 'offen', 'gestern', 'manger', 'écrire', 'boire', 'voir', 'savoir', 'finir', 'dire', 'avoir mal',
  'faire une réclamation', 'prendre un bain de soleil', 'hier', 'cher', 'premier', 'autre', 'libre', 'noir', 'teacher',
  'garden', 'hablar', 'comer', 'vivir', 'levantarse', 'mar', 'parlare', 'vedere', 'dormire', 'alzarsi', 'mare',
  'to propose (sth)', 'donner qc à qn', 'to affect sb/ sth', "to uphold sb's interests",
  // adjectives and adverbs
  'amusant, amusante', 'heureux, -euse', 'grand, e', 'grand, -e', 'marié(e)', 'courageux, courageuse',
  'actif, active', 'premier, première', 'beau, belle', 'nouveau, nouvelle', 'vieux, vieille', 'fou, folle',
  'bonito, bonita', 'bello, bella', 'lieb, nett', 'rule, ruler', 'acteur, actrice', 'formidable', 'rapidement',
  'magnifique', 'dangereux', 'essential', 'annually', 'beautiful', 'careless', 'rápidamente', 'famoso', 'velocemente',
  'toll', 'jährlich', 'einzigartig', 'unbedingt erforderlich', 'im Durchschnitt', 'in grossem Ausmass',
  'stolz auf etw.', 'ehemalige(r/s), frühere(r/s)', 'hoch technologisiert', 'usw.', 'z.B.', 'chouette', 'bon marché',
  // sentences, numbers, long texts, edge cases
  'Joyeux Noël!', 'Achtung!', 'Santé!', "C'est mon tour.", '¿Qué tal?', '¡Hola!', 'Wie geht es dir?', 'Combien coûte...?',
  'etw. tun bei etw.', 'Ich gehe nach Hause.', 'Es regnet…', '1474', '1914-1918', '3,5 %', '3 Äpfel', '12:30', '-5',
  'on a large scale for many', 'aus einer bestimmten Zeit stammen', 'Beginn der Burgunderkriege (Grandson, Murten, Nancy).',
  '', ' ', '()', '(  )', '[x]', '((le chien))', 'le chien)', '(le chien', ',', ', f.', 'f.', 'chien,, f.', 'chien ; m.',
  'la  tête ', '\tle chien', 'le’chien', 'l’école', 'L’ÉTÉ', 'ΟΔΟΣ', 'İstanbul', 'ẞtraße', 'ǅemal',
  'كتاب', 'قلم، دَفْتَر', '你好', '你好！', '谢谢，多谢', 'nǐ hǎo', '𝔄pfel', '😀 Spass', 'été', 'Été',
];

// ---------------------------------------------------------------------------
// 1. Texts with every side profile

// optionShape only reads the language.
const SHAPE_SIDES = [SIDES[0], SIDES[4], SIDES[6], SIDES[9], SIDES[12]];
for (const text of TEXTS) {
  for (const s of SIDES) cases.add('textClass', [text, s], textClass(text, s));
  for (const s of SHAPE_SIDES) cases.add('optionShape', [text, s], optionShape(text, s));
}

// ---------------------------------------------------------------------------
// 2. Fixture lists: both sides' profiles, every card's class, its shapes

const lists = [];
for (const { name, text } of fixtureTexts()) {
  if (!name.endsWith('.txt') && !name.endsWith('.tsv') && !name.endsWith('.csv')) continue;
  const cards = parseVocab(text).cards.map((c) => ({ term: c.term, definition: c.definition }));
  if (!cards.length) continue;
  lists.push(cards);
  cases.add('sideProfile', [cards.map((c) => c.term)], sideProfile(cards.map((c) => c.term)));
  cases.add('sideProfile', [cards.map((c) => c.definition)], sideProfile(cards.map((c) => c.definition)));
  const sides = listProfiles(cards);
  cases.add('cardClasses', [cards], { sides, classes: cards.map((c) => cardClass(c, sides)) });
  for (const c of cards) {
    cases.add('optionShape', [c.term, sides.term], optionShape(c.term, sides.term));
    cases.add('optionShape', [c.definition, sides.definition], optionShape(c.definition, sides.definition));
  }
}

// The test lists of tests/wordclass.test.js and small or odd ones.
const PROFILE_LISTS = [
  ['der Hund', 'die Katze', 'Meilenstein', 'Zerstörung', 'essen', 'schnell', 'Versöhnung', 'jährlich', 'Rede', 'etw. vorschlagen'],
  ['der Hund', 'die Katze', 'das Haus', 'der Körper', 'essen', 'schnell', 'die Stirn', 'das Auge', 'der Mund', 'lustig', 'die Nase'],
  ['der hund', 'die katze', 'das haus', 'essen', 'schnell', 'die stirn', 'das auge', 'der mund', 'lustig'],
  ['le chien', 'la chatte', 'manger', 'Noël', 'rapide', 'la maison', "l'école", 'le livre'],
  ['Milestone', 'Destruction', 'To propose', 'Essential', 'Speech', 'Reconciliation'],
  ['1474', '1517', '1521'],
  [],
  ['', '  ', '\n'],
  ['Hund'],
  ['hund'],
  ['ΟΔΟΣ', 'οδός', 'İstanbul'],
  ['كتاب', 'دفتر', 'بيت'],
  ['你好', '谢谢', '再见'],
];
for (const texts of PROFILE_LISTS) cases.add('sideProfile', [texts], sideProfile(texts));

// ---------------------------------------------------------------------------
// 3. Seeded fuzz: texts from pieces, lists of them

const LEADS = ['', '', '', 'le ', 'la ', "l'", 'les ', 'der ', 'die ', 'das ', 'the ', 'a ', 'el ', 'il ', 'gli ', 'to ', 'se ', "s'", 'sich ', 'etw. ', 'jmdn. ', '(sich) ', 'im ', 'in '];
const WORDS = [
  'chien', 'Hund', 'hund', 'maison', 'Haus', 'manger', 'essen', 'Essen', 'lever', 'feiern', 'amusant', 'lustig', 'jährlich',
  'Zerstörung', 'destruction', 'essential', 'annually', 'hablar', 'parlare', 'rápidamente', 'modern', 'hier', 'tun', 'sein',
  'haben', 'auf', 'nach', 'sth', 'sb', 'qc', 'Noël', 'Congress', 'teacher', 'ab', 'x', 'été', 'Été', '1474', 'Politik',
];
const TAILS = ['', '', '', '!', '?', '.', '…', ', f.', ', m.', ', -e', ', e', 'e, ', '(e)', '(in)', ' (m)', ' (pl.)', ' sth', ' etw.', ', ', ';', ' (x)', ')'];

function fuzzText() {
  let t = pick(rng, LEADS);
  const n = randInt(rng, 1, 4);
  for (let i = 0; i < n; i++) t += (i ? ' ' : '') + pick(rng, WORDS);
  t += pick(rng, TAILS);
  if (chance(rng, 0.15)) t += ` ${pick(rng, WORDS)}${pick(rng, TAILS)}`;
  if (chance(rng, 0.1)) t = t.toUpperCase();
  if (chance(rng, 0.1)) t = `  ${t} `;
  return t;
}

for (let i = 0; i < 1500; i++) {
  const text = fuzzText();
  const s = pick(rng, SIDES);
  cases.add('textClass', [text, s], textClass(text, s));
  if (i % 3 === 0) cases.add('optionShape', [text, s], optionShape(text, s));
}

for (let i = 0; i < 60; i++) {
  const n = randInt(rng, 1, 25);
  const cards = [];
  for (let k = 0; k < n; k++) cards.push({ term: fuzzText(), definition: fuzzText() });
  // Now and then a real list as the base, so languages get detected.
  if (chance(rng, 0.5) && lists.length) {
    const base = pick(rng, lists);
    for (let k = 0; k < Math.min(base.length, 20); k++) cards.push(base[k]);
  }
  const sides = listProfiles(cards);
  cases.add('cardClasses', [cards], { sides, classes: cards.map((c) => cardClass(c, sides)) });
}

// ---------------------------------------------------------------------------
// 4. Points

const SHAPE_TEXTS = ['la tête', 'la fête', 'la tente', 'le front', 'la nation', 'la natation', 'se lever', 'manger',
  'Zerstörung', 'Versöhnung', 'to propose sth', 'to promote sth', '', 'ab', 'abc', 'le 𝔄pfel', 'le 𝔄pfelx', 'été', 'étés'];
for (const a of SHAPE_TEXTS) {
  for (const b of SHAPE_TEXTS) {
    const s = SIDES[(a.length + b.length) % SIDES.length];
    const x = optionShape(a, s);
    const y = optionShape(b, s);
    cases.add('shapePoints', [x, y], shapePoints(x, y));
  }
}
for (const d of [0, 1, 2, 3, 4, 9, 10, 11, 24, 25, 26, 100, 5000]) cases.add('nearPoints', [d], nearPoints(d));

cases.emit();
