import { test, expect, run } from './harness.js';
import {
  sideProfile,
  textClass,
  combineClasses,
  optionShape,
  shapePoints,
  nearPoints,
  listProfiles,
  cardClass,
} from '../src/core/wordclass.js';

const side = (lang, flags = {}) => ({ lang, wordCaps: false, capsNoun: false, capsRare: false, ...flags });
// German with capitalised nouns, with and without texts starting with a capital; the others with few capitals.
const DE = side('de', { wordCaps: true, capsNoun: true });
const DE_ARTICLES = side('de', { wordCaps: true });
const FR = side('fr', { capsRare: true });
const EN = side('en', { capsRare: true });
const ES = side('es', { capsRare: true });
const IT = side('it', { capsRare: true });
const UNKNOWN = side('unknown');

const cls = (text, s) => {
  const r = textClass(text, s);
  return r.cls ? `${r.cls}${r.strength}` : '';
};

test('textClass: articles, gender marks and brackets make nouns', () => {
  expect(cls('le corps', FR)).toBe('noun2');
  expect(cls("l'oreille, f.", FR)).toBe('noun2');
  expect(cls("l'œil, m. les yeux", FR)).toBe('noun2');
  expect(cls('le/la pilote', FR)).toBe('noun2');
  expect(cls('la brosse (à cheveux)', FR)).toBe('noun2');
  expect(cls('der Körper', DE_ARTICLES)).toBe('noun2');
  expect(cls('Aussenminister(in)', DE)).toBe('noun2');
  expect(cls('the United Nations', EN)).toBe('noun2');
  expect(cls('el perro', ES)).toBe('noun2');
  expect(cls("l'amico", IT)).toBe('noun2');
  expect(cls('gli amici', IT)).toBe('noun2');
  // "a" is an article in English only; "die" only in German.
  expect(cls('a dog', EN)).toBe('noun2');
  expect(cls('a dog', FR)).toBe('');
  expect(cls('die Katze', UNKNOWN)).toBe('');
  expect(cls('das Haus', UNKNOWN)).toBe('noun2');
  // An article alone is no noun.
  expect(cls('le', FR)).toBe('');
});

test('textClass: verbs', () => {
  expect(cls('to propose sth', EN)).toBe('verb2');
  expect(cls('to be in ruins', EN)).toBe('verb2');
  expect(cls('se lever', FR)).toBe('verb2');
  expect(cls("s'amuser", FR)).toBe('verb2');
  expect(cls("s'amuser", EN)).toBe('');
  expect(cls('sich freuen', DE)).toBe('verb2');
  expect(cls('(sich) duschen', DE)).toBe('verb2');
  // German: the last word in lowercase with a verb ending, before particles.
  expect(cls('essen', DE)).toBe('verb1');
  expect(cls('wehtun', DE)).toBe('verb1');
  expect(cls('Schmerzen haben', DE)).toBe('verb1');
  expect(cls('Lust haben auf', DE)).toBe('verb1');
  expect(cls('etw. vorschlagen', DE)).toBe('verb2');
  expect(cls('jmdm. zu Hilfe kommen', DE)).toBe('verb2');
  expect(cls('eine Wahl abhalten', DE)).toBe('verb2');
  expect(cls('ein wesentlicher Bestandteil von etw. sein', DE)).toBe('verb2');
  expect(cls('modern', DE)).toBe('adj1');
  // Not without capitalised nouns on the side (everything in lowercase: "das essen").
  expect(cls('essen', side('de'))).toBe('');
  // French infinitives, also starting a phrase.
  expect(cls('manger', FR)).toBe('verb1');
  expect(cls('écrire', FR)).toBe('verb1');
  expect(cls('avoir mal', FR)).toBe('verb1');
  expect(cls('faire une réclamation', FR)).toBe('verb1');
  expect(cls('hier', FR)).toBe('');
  expect(cls('premier', FR)).toBe('');
  // "-er" is a French verb ending only.
  expect(cls('teacher', EN)).toBe('');
  expect(cls('hablar', ES)).toBe('verb1');
  expect(cls('levantarse', ES)).toBe('verb2');
  expect(cls('parlare', IT)).toBe('verb1');
  expect(cls('alzarsi', IT)).toBe('verb2');
});

test('textClass: adjectives and adverbs', () => {
  expect(cls('amusant, amusante', FR)).toBe('adj2');
  expect(cls('heureux, -euse', FR)).toBe('adj2');
  expect(cls('grand, e', FR)).toBe('adj2');
  expect(cls('marié(e)', FR)).toBe('adj2');
  expect(cls('courageux, courageuse', FR)).toBe('adj2');
  expect(cls('bonito, bonita', ES)).toBe('adj2');
  // A pair of different words is no feminine form, nor in German or English.
  expect(cls('lieb, nett', FR)).toBe('');
  expect(cls('rule, ruler', EN)).toBe('');
  expect(cls('formidable', FR)).toBe('adj1');
  expect(cls('rapidement', FR)).toBe('adj1');
  expect(cls('essential', EN)).toBe('adj1');
  expect(cls('annually', EN)).toBe('adj1');
  expect(cls('rápidamente', ES)).toBe('adj1');
  // German lowercase: adjectives and adverbs, adverbial phrases; with an adjective ending strong.
  expect(cls('toll', DE)).toBe('adj1');
  expect(cls('jährlich', DE)).toBe('adj2');
  expect(cls('unbedingt erforderlich', DE)).toBe('adj2');
  expect(cls('im Durchschnitt', DE)).toBe('adj1');
  expect(cls('stolz auf etw.', DE)).toBe('adj1');
});

test('textClass: German capitals', () => {
  expect(cls('Meilenstein', DE)).toBe('noun2');
  expect(cls('Zerstörung', DE)).toBe('noun2');
  expect(cls('zerstörung', DE)).toBe('noun2');
  expect(cls('gemeinsame Politik', DE)).toBe('noun1');
  expect(cls('Besorgnis über etw.', DE)).toBe('noun2');
  expect(cls('Frohe Weihnachten', DE)).toBe('noun2');
  // Where every text starts with a capital, a capital says nothing.
  expect(cls('Meilenstein', side('de', { wordCaps: true }))).toBe('');
  // Other languages: a capital among lowercase texts is a name.
  expect(cls('Noël', FR)).toBe('noun1');
  expect(cls('Congress', EN)).toBe('noun1');
  expect(cls('Congress', side('en'))).toBe('');
});

test('textClass: sentences, numbers, long texts, nothing', () => {
  expect(cls('Joyeux Noël!', FR)).toBe('phrase2');
  expect(cls('Achtung!', DE)).toBe('phrase2');
  expect(cls("C'est mon tour.", FR)).toBe('phrase2');
  expect(cls('¿Qué tal?', ES)).toBe('phrase2');
  expect(cls('etw. tun bei etw.', DE)).toBe('verb2');
  expect(cls('usw.', DE)).toBe('adj1');
  expect(cls('1474', UNKNOWN)).toBe('number2');
  expect(cls('1914-1918', UNKNOWN)).toBe('number2');
  expect(cls('3,5 %', UNKNOWN)).toBe('number2');
  expect(cls('3 Äpfel', DE)).toBe('noun1');
  expect(cls('on a large scale for many', EN)).toBe('phrase1');
  expect(cls('chouette', FR)).toBe('');
  expect(cls('', FR)).toBe('');
  expect(cls('   ', DE)).toBe('');
  expect(cls('()', DE)).toBe('');
  expect(cls(null, DE)).toBe('');
  expect(cls('كتاب', side('ar'))).toBe('');
  expect(cls('你好', side('zh'))).toBe('');
});

test('combineClasses: agreement, one cue, the stronger cue, compound classes', () => {
  const c = (cls, strength) => ({ cls, strength });
  expect(combineClasses(c('noun', 2), c('noun', 1))).toBe('noun');
  expect(combineClasses(c('', 0), c('verb', 1))).toBe('verb');
  expect(combineClasses(c('adj', 1), c('', 0))).toBe('adj');
  expect(combineClasses(c('', 0), c('', 0))).toBe('');
  expect(combineClasses(c('verb', 2), c('noun', 1))).toBe('verb');
  expect(combineClasses(c('adj', 1), c('noun', 2))).toBe('noun');
  expect(combineClasses(c('adj', 1), c('noun', 1))).toBe('');
  expect(combineClasses(c('number', 2), c('phrase', 2))).toBe('number/phrase');
});

test('sideProfile: language and capitals', () => {
  const de = sideProfile(['der Hund', 'die Katze', 'Meilenstein', 'Zerstörung', 'essen', 'schnell', 'Versöhnung', 'jährlich', 'Rede', 'etw. vorschlagen']);
  expect(de).toEqual({ lang: 'de', wordCaps: true, capsNoun: true, capsRare: false });
  const articles = sideProfile(['der Hund', 'die Katze', 'das Haus', 'der Körper', 'essen', 'schnell', 'die Stirn', 'das Auge', 'der Mund', 'lustig', 'die Nase']);
  expect(articles).toEqual({ lang: 'de', wordCaps: true, capsNoun: false, capsRare: false });
  const lower = sideProfile(['der hund', 'die katze', 'das haus', 'essen', 'schnell', 'die stirn', 'das auge', 'der mund', 'lustig']);
  expect(lower.lang).toBe('de');
  expect(lower.wordCaps).toBe(false);
  const fr = sideProfile(['le chien', 'la chatte', 'manger', 'Noël', 'rapide', 'la maison', "l'école", 'le livre']);
  expect(fr).toEqual({ lang: 'fr', wordCaps: false, capsNoun: false, capsRare: true });
  const capitals = sideProfile(['Milestone', 'Destruction', 'To propose', 'Essential', 'Speech', 'Reconciliation']);
  expect(capitals.lang).toBe('en');
  expect(capitals.capsRare).toBe(false);
  expect(sideProfile([])).toEqual({ lang: 'unknown', wordCaps: false, capsNoun: false, capsRare: false });
  expect(sideProfile(null).lang).toBe('unknown');
  expect(sideProfile(['1474', '1517', '1521']).capsRare).toBe(false);
});

test('cardClass: both sides with the profiles of their list', () => {
  const list = [
    { term: 'le corps', definition: 'der Körper' },
    { term: 'milestone', definition: 'Meilenstein' },
    { term: 'manger', definition: 'essen' },
    { term: 'amusant, amusante', definition: 'lustig' },
    { term: 'chouette', definition: 'klasse' },
    { term: 'Joyeux Noël!', definition: 'Frohe Weihnachten!' },
    { term: '1474', definition: 'Beginn der Burgunderkriege.' },
    { term: 'ouvert, ouverte', definition: 'offen' },
    { term: 'la tête', definition: 'der Kopf' },
    { term: 'le nez', definition: 'die Nase' },
  ];
  const sides = listProfiles(list);
  expect(sides.term.lang).toBe('fr');
  expect(sides.definition.lang).toBe('de');
  expect(list.map((c) => cardClass(c, sides))).toEqual(['noun', 'noun', 'verb', 'adj', 'adj', 'phrase', 'number/phrase', 'adj', 'noun', 'noun']);
  // Memoised per list content: the same answer again.
  expect(listProfiles(list.map((c) => ({ ...c })))).toEqual(sides);
});

test('optionShape and shapePoints: article, words, length, beginning, ending', () => {
  expect(optionShape('la tête', FR)).toEqual({ article: 'la', head: 'tête', words: 1, length: 4 });
  expect(optionShape("l'oreille, f.", FR)).toEqual({ article: "l'", head: 'oreille', words: 1, length: 7 });
  expect(optionShape('Der Kopf (Körperteil)', DE)).toEqual({ article: 'der', head: 'kopf', words: 1, length: 4 });
  expect(optionShape('to propose sth', EN)).toEqual({ article: '', head: 'to propose sth', words: 3, length: 14 });
  expect(optionShape('', FR)).toEqual({ article: '', head: '', words: 0, length: 0 });
  const p = (a, b, s = FR) => shapePoints(optionShape(a, s), optionShape(b, s));
  // Same article, one word, similar length, "tê"/"te" differ, "ête"/"nte" differ.
  expect(p('la tête', 'la tente')).toBe(3);
  expect(p('la tête', 'la fête')).toBe(4);
  expect(p('la tête', 'le front')).toBe(2);
  expect(p('la nation', 'la natation')).toBe(5);
  expect(p('se lever', 'manger')).toBe(1);
  expect(p('Zerstörung', 'Versöhnung', DE)).toBe(3);
});

test('nearPoints: closer cards in the set get more', () => {
  expect([1, 3, 4, 10, 11, 25, 26, 400].map(nearPoints)).toEqual([3, 3, 2, 2, 1, 1, 0, 0]);
});

await run('wordclass.test.js');
