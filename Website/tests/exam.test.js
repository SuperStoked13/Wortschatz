// Prüfung (exam): the sheet, the marking with its tolerance, the Swiss grade, the settings and
// the texts of the exam screens. Ports every case of the Mac's ExamTests.swift plus web edge
// cases, and proves the exam screens import under JavaScriptCore.
import { test, expect, run } from './harness.js';
import * as E from '../src/core/exam.js';

// Deterministic rng (mulberry32), as in integration.test.js.
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const CARDS = [
  { id: 'c1', term: 'la maison', definition: 'das Haus', starred: true },
  { id: 'c2', term: "l'élève", definition: 'der Schüler', starred: true },
  { id: 'c3', term: "s'occuper de", definition: 'sich kümmern um', starred: false },
  { id: 'c4', term: 'aimable, gentil', definition: 'freundlich', starred: false },
  { id: 'c5', term: 'le cheval', definition: 'das Pferd', starred: false },
  { id: 'c6', term: '', definition: 'leer', starred: false },
  { id: 'c7', term: 'le chien', definition: 'der Hund', starred: false },
];

const settings = (patch = {}) => ({ ...E.DEFAULT_EXAM_SETTINGS, ...patch });

function question(cardId, ask = 'term', number = 1) {
  const card = CARDS.find((c) => c.id === cardId);
  return {
    number,
    cardId,
    ask,
    prompt: ask === 'term' ? card.definition : card.term,
    expected: ask === 'term' ? card.term : card.definition,
    promptLang: ask === 'term' ? 'de' : 'fr',
    answerLang: ask === 'term' ? 'fr' : 'de',
  };
}

const mark = (given, cardId, { ask = 'term', tolerance = 'half' } = {}) => E.markAnswer(given, question(cardId, ask), CARDS, tolerance);

/* ------------------------------------------------------------------ the sheet */

test('the sheet asks the wanted number of usable cards', () => {
  const questions = E.makeQuestions(CARDS, settings({ count: 4, answerWith: 'term' }), { termLang: 'fr', defLang: 'de', rng: mulberry32(1) });
  expect(questions.length).toBe(4);
  expect(questions.map((q) => q.number)).toEqual([1, 2, 3, 4]);
  expect(new Set(questions.map((q) => q.cardId)).size).toBe(4);
  expect(questions.some((q) => q.cardId === 'c6')).toBe(false);
  for (const q of questions) {
    const card = CARDS.find((c) => c.id === q.cardId);
    expect(q.ask).toBe('term');
    expect(q.prompt).toBe(card.definition);
    expect(q.expected).toBe(card.term);
    expect(q.promptLang).toBe('de');
    expect(q.answerLang).toBe('fr');
  }
  const all = E.makeQuestions(CARDS, settings({ count: 0 }), { termLang: 'fr', defLang: 'de', rng: mulberry32(2) });
  expect(all.length).toBe(6);
});

test('the sheet takes count questions of a larger scope, numbered from 1', () => {
  const many = Array.from({ length: 25 }, (_, i) => ({ id: `k${i}`, term: `mot ${i}`, definition: `Wort ${i}` }));
  const questions = E.makeQuestions(many, settings({ count: 10 }), { termLang: 'fr', defLang: 'de', rng: mulberry32(7) });
  expect(questions.length).toBe(10);
  expect(questions.map((q) => q.number)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  expect(new Set(questions.map((q) => q.cardId)).size).toBe(10);
  // The same seed gives the same sheet.
  const again = E.makeQuestions(many, settings({ count: 10 }), { termLang: 'fr', defLang: 'de', rng: mulberry32(7) });
  expect(again).toEqual(questions);
});

test('starred cards, retakes and both directions', () => {
  const starred = E.makeQuestions(CARDS, settings({ count: 0, starredOnly: true }), { termLang: 'fr', defLang: 'de', rng: mulberry32(3) });
  expect(starred.map((q) => q.cardId).sort()).toEqual(['c1', 'c2']);
  const retake = E.makeQuestions(CARDS, settings({ count: 2, starredOnly: true }), {
    termLang: 'fr',
    defLang: 'de',
    cardIds: ['c5', 'c7', 'c6'],
    rng: mulberry32(3),
  });
  expect(retake.map((q) => q.cardId).sort()).toEqual(['c5', 'c7']);
  const both = E.makeQuestions(CARDS, settings({ count: 0, answerWith: 'both' }), { termLang: 'fr', defLang: 'de', rng: mulberry32(5) });
  expect(new Set(both.map((q) => q.ask)).size).toBe(2);
  for (const q of both.filter((x) => x.ask === 'definition')) {
    expect(q.promptLang).toBe('fr');
    expect(q.answerLang).toBe('de');
    expect(q.prompt).toBe(CARDS.find((c) => c.id === q.cardId).term);
  }
  expect(E.questionCount(settings({ count: 20 }), 6)).toBe(6);
});

test('the scope: usable cards once each in set order; starred only when there are any', () => {
  const cards = [
    { id: 'a', term: ' x ', definition: 'y' },
    { id: 'a', term: 'dup', definition: 'dup' },
    { id: '', term: 'no id', definition: 'z' },
    { id: 'b', term: '   ', definition: 'blank' },
    { id: 'c', term: 'c', definition: 'C' },
  ];
  expect(E.examScope(cards, settings()).map((c) => c.id)).toEqual(['a', 'c']);
  // No starred card: starredOnly falls back to all of them.
  expect(E.examScope(cards, settings({ starredOnly: true })).map((c) => c.id)).toEqual(['a', 'c']);
  expect(E.examScope(null, settings())).toEqual([]);
  expect(E.starredCount(CARDS)).toBe(2);
  expect(E.isEmptyForExam([{ id: 'x', term: 'a', definition: '' }])).toBe(true);
  expect(E.isEmptyForExam(CARDS)).toBe(false);
  // A retake asks every card it was given; a new exam asks `count`.
  expect(E.plannedCount(CARDS, settings({ count: 10 }), ['c1', 'c2', 'c3'])).toBe(3);
  expect(E.plannedCount(CARDS, settings({ count: 10 }))).toBe(6);
  expect(E.plannedCount(CARDS, settings({ starredOnly: true }))).toBe(2);
});

test('the sheet trims texts and never mutates the cards', () => {
  const cards = [{ id: 'p', term: '  le pain ', definition: ' das Brot  ' }];
  const copy = JSON.parse(JSON.stringify(cards));
  const [q] = E.makeQuestions(cards, settings(), { termLang: 'fr', defLang: 'de', rng: () => 0.5 });
  expect(q.prompt).toBe('das Brot');
  expect(q.expected).toBe('le pain');
  expect(cards).toEqual(copy);
  expect(E.questionCard(q)).toEqual({ id: 'p', term: 'le pain', definition: 'das Brot' });
  // A misbehaving rng never breaks an index.
  expect(E.makeQuestions(CARDS, settings({ count: 0, answerWith: 'both' }), { rng: () => NaN }).length).toBe(6);
  expect(E.makeQuestions(CARDS, settings({ count: 0 }), { rng: () => 7 }).length).toBe(6);
});

/* -------------------------------------------------------------------- marking */

test('right answers and forms that are no mistake', () => {
  expect(mark('la maison', 'c1').mark).toBe('correct');
  expect(mark('  La maison ', 'c1').mark).toBe('correct');
  expect(mark('  La maison ', 'c1').given).toBe('La maison');
  expect(mark('gentil', 'c4').points).toBe(1);
  expect(mark('das Haus', 'c1', { ask: 'definition' }).mark).toBe('correct');
  expect(mark('la maison', 'c1').note).toBe(null);
});

test('small mistakes cost what the tolerance says', () => {
  // Missing article, missing accent, a typo.
  for (const given of ['maison', "l'eleve", 'la maisson']) {
    const id = given.includes('lev') ? 'c2' : 'c1';
    expect(mark(given, id, { tolerance: 'half' }).mark).toBe('minor');
    expect(mark(given, id, { tolerance: 'half' }).points).toBe(0.5);
    expect(mark(given, id, { tolerance: 'strict' }).points).toBe(0);
    expect(mark(given, id, { tolerance: 'lenient' }).points).toBe(1);
  }
  expect(mark('maison', 'c1').note).toBe('Artikel fehlte');
  expect(mark("l'eleve", 'c2').note).toBe('Akzente');
  expect(mark('la maisson', 'c1').note).toBe('Tippfehler');
  // A German noun's small first letter.
  const small = mark('das haus', 'c1', { ask: 'definition' });
  expect(small.mark).toBe('minor');
  expect(small.note).toBe('Gross-/Kleinschreibung');
  // A missing reflexive pronoun.
  const pronoun = mark('occuper de', 'c3');
  expect(pronoun.mark).toBe('minor');
  expect(pronoun.note).toBe('Pronomen fehlte');
});

test('wrong and blank answers', () => {
  const article = mark('le maison', 'c1');
  expect(article.mark).toBe('wrong');
  expect(article.points).toBe(0);
  expect(article.note).toBe('Falscher Artikel');
  expect(mark('le chat', 'c7').mark).toBe('wrong');
  const blank = mark('   ', 'c1');
  expect(blank.mark).toBe('blank');
  expect(blank.given).toBe('');
  expect(blank.points).toBe(0);
  expect(blank.note).toBe(null);
  expect(mark(null, 'c1').mark).toBe('blank');
});

test('the whole sheet', () => {
  const questions = ['c1', 'c2', 'c5', 'c7'].map((id, i) => question(id, 'term', i + 1));
  const result = E.evaluateExam(questions, { 1: 'la maison', 2: "l'eleve", 3: 'le cheval' }, CARDS, 'half', { elapsedMs: 90000 });
  expect(result.points).toBe(2.5);
  expect(result.maxPoints).toBe(4);
  expect(E.markCount(result, 'correct')).toBe(2);
  expect(E.markCount(result, 'minor')).toBe(1);
  expect(E.markCount(result, 'blank')).toBe(1);
  expect(result.grade).toBe(4.1);
  expect(E.cardIdsToPractise(result)).toEqual(['c2', 'c7']);
  expect(E.scoreLine(result)).toBe('2.5 von 4 Punkten');
  expect(E.markLabel(result.items[1])).toBe('Halber Punkt');
  expect(E.resultSubtitle(result)).toBe('2.5 von 4 Punkten in 1:30');
  expect(E.resultAnnouncement(result)).toBe('Note 4.1. 2.5 von 4 Punkten.');
  expect(result.items.map((it) => it.question.number)).toEqual([1, 2, 3, 4]);
  // Answers may come as a Map too.
  const viaMap = E.evaluateExam(questions, new Map([[1, 'la maison']]), CARDS, 'strict');
  expect(viaMap.points).toBe(1);
  expect(viaMap.elapsedMs).toBe(0);
  expect(viaMap.timedOut).toBe(false);
  const timed = E.evaluateExam(questions, {}, CARDS, 'nope', { elapsedMs: NaN, timedOut: true });
  expect(timed.elapsedMs).toBe(0);
  expect(timed.timedOut).toBe(true);
  expect(timed.tolerance).toBe('half');
  expect(timed.grade).toBe(1);
});

test('the cards to practise: each once, small mistakes too (also under Grosszügig)', () => {
  const questions = [question('c1', 'term', 1), question('c1', 'definition', 2), question('c2', 'term', 3), question('c5', 'term', 4)];
  const result = E.evaluateExam(questions, { 1: 'maison', 2: 'xyz', 3: "l'élève", 4: 'le chevall' }, CARDS, 'lenient');
  expect(result.points).toBe(3);
  expect(E.cardIdsToPractise(result)).toEqual(['c1', 'c5']);
});

test('answered questions count only text', () => {
  const questions = [question('c1', 'term', 1), question('c2', 'term', 2), question('c5', 'term', 3)];
  expect(E.answeredCount(questions, { 1: 'x', 2: '   ', 3: '' })).toBe(1);
  expect(E.answeredCount(questions, new Map([[3, 'y']]))).toBe(1);
  expect(E.answeredCount(questions, null)).toBe(0);
  expect(E.answerFor({ 2: 42 }, 2)).toBe('');
});

/* ------------------------------------------------------------------ the grade */

test('the Swiss grade', () => {
  expect(E.examGrade(20, 20)).toBe(6);
  expect(E.examGrade(0, 20)).toBe(1);
  expect(E.examGrade(10, 20)).toBe(3.5);
  expect(E.examGrade(12, 20)).toBe(4);
  expect(E.examGrade(17, 20)).toBe(5.3);
  expect(E.examGrade(17.5, 20)).toBe(5.4);
  expect(E.examGrade(3, 0)).toBe(1);
  // Exact halves round up (going through the share in floating point gave 4.4 and 5.1).
  expect(E.examGrade(34.5, 50)).toBe(4.5);
  expect(E.examGrade(41.5, 50)).toBe(5.2);
  expect(E.examGrade(69, 100)).toBe(4.5);
  expect(E.examGrade(25, 20)).toBe(6);
  expect(E.examGrade(-2, 20)).toBe(1);
  expect(E.examGrade(NaN, 20)).toBe(1);
  expect(E.examGrade(Infinity, 20)).toBe(1);
  expect(E.gradeText(5.3)).toBe('5.3');
  expect(E.gradeText(6)).toBe('6.0');
  expect(E.gradeText(4)).toBe('4.0');
  expect(E.gradeText(1)).toBe('1.0');
  expect(E.pointsText(17.5)).toBe('17.5');
  expect(E.pointsText(18)).toBe('18');
  expect(E.pointsText(0)).toBe('0');
  expect(E.pointsText(0.5)).toBe('0.5');
  expect(E.passes(4)).toBe(true);
  expect(E.passes(3.9)).toBe(false);
  expect(E.verdict(6)).toBe('Perfekt!');
  expect(E.verdict(5.5)).toBe('Hervorragend!');
  expect(E.verdict(5.2)).toBe('Sehr gut!');
  expect(E.verdict(4.5)).toBe('Gut gemacht!');
  expect(E.verdict(4)).toBe('Bestanden!');
  expect(E.verdict(3.5)).toBe('Noch nicht genügend');
});

test('grade colours, confetti and the one-point score line', () => {
  expect(E.gradeTone(5)).toBe('success');
  expect(E.gradeTone(4.9)).toBe('accent');
  expect(E.gradeTone(4)).toBe('accent');
  expect(E.gradeTone(3.9)).toBe('warning');
  expect(E.celebrates(5.5)).toBe(true);
  expect(E.celebrates(5.4)).toBe(false);
  const one = E.evaluateExam([question('c1')], { 1: 'la maison' }, CARDS, 'half');
  expect(E.scoreLine(one)).toBe('1 von 1 Punkt');
  expect(one.grade).toBe(6);
});

/* ---------------------------------------------------------------- the settings */

test('settings are read leniently', () => {
  const json = '{"minutes": 15.7, "count": -3, "answerWith": "both", "tolerance": "nope", "examples": true}';
  const s = E.readExamSettings(json);
  // Unknown keys ("examples" of an earlier version) are ignored.
  expect(s).toEqual({ minutes: 15, count: 0, answerWith: 'both', tolerance: 'half', starredOnly: false });
  expect(E.readExamSettings(JSON.parse(JSON.stringify(s)))).toEqual(s);
  expect(E.minutesText(0)).toBe('Ohne Zeitlimit');
  expect(E.minutesText(1)).toBe('1 Minute');
  expect(E.minutesText(10)).toBe('10 Minuten');
});

test('stored numbers snap to the choices offered', () => {
  expect(E.readExamSettings({ minutes: 7, count: 25 }).minutes).toBe(5);
  expect(E.readExamSettings({ minutes: 7, count: 25 }).count).toBe(20);
  expect(E.readExamSettings({ minutes: 600, count: 9999 })).toEqual(settings({ minutes: 45, count: 30 }));
  expect(E.readExamSettings({ minutes: 0, count: 0 })).toEqual(settings({ minutes: 0, count: 0 }));
  expect(E.readExamSettings({ minutes: 2, count: 1 })).toEqual(settings({ minutes: 5, count: 10 }));
});

test('anything else falls back to the defaults', () => {
  for (const raw of [null, undefined, 'not json', '[1,2]', [], 42, true]) expect(E.readExamSettings(raw)).toEqual(settings());
  expect(E.readExamSettings({ minutes: '10', count: '5', starredOnly: 'yes', answerWith: 'TERM' })).toEqual(settings());
  expect(E.readExamSettings({ minutes: Infinity, count: NaN })).toEqual(settings());
  expect(E.readExamSettings({ starredOnly: true, answerWith: 'definition', tolerance: 'lenient' })).toEqual(
    settings({ starredOnly: true, answerWith: 'definition', tolerance: 'lenient' }),
  );
  expect(E.nearestChoice(12.5, E.MINUTE_CHOICES)).toBe(10);
  expect(E.nearestChoice(0.4, E.COUNT_CHOICES)).toBe(10);
});

test('updating settings keeps them valid and leaves the input alone', () => {
  const before = settings();
  const next = E.updateExamSettings(before, { count: 15, minutes: 3, extra: 1 });
  expect(next).toEqual(settings({ count: 15, minutes: 5 }));
  expect(before).toEqual(settings());
  expect(E.sameExamSettings(before, settings())).toBe(true);
  expect(E.sameExamSettings(before, next)).toBe(false);
});

/* ----------------------------------------------------------- synonyms & diffs */

test('a synonym with a small mistake is compared with its own word', () => {
  const cards = [
    { id: 'v1', term: 'la voiture', definition: 'das Auto' },
    { id: 'v2', term: "l'automobile", definition: 'das Auto' },
  ];
  const q = { number: 1, cardId: 'v1', ask: 'term', prompt: 'das Auto', expected: 'la voiture', promptLang: 'de', answerLang: 'fr' };
  const typo = E.markAnswer("l'automobil", q, cards, 'half');
  expect(typo.mark).toBe('minor');
  expect(typo.synonym).toBe(true);
  expect(typo.matched).toBe("l'automobile");
  expect(E.expectedLabel(typo)).toBe('Gesucht war:');
  const own = E.markAnswer('la voitur', q, cards, 'half');
  expect(own.mark).toBe('minor');
  expect(own.matched).toBe(null);
  expect(E.expectedLabel(own)).toBe('Richtig:');
  const right = E.markAnswer("l'automobile", q, cards, 'half');
  expect(right.mark).toBe('correct');
  expect(right.synonym).toBe(true);
  expect(right.note).toBe('Anderes Wort mit gleicher Bedeutung');
  expect(E.showsExpected(right)).toBe(true);
  expect(E.expectedLabel(right)).toBe('Gesucht war:');
});

test('the answer diff marks only near misses against the closest variant', () => {
  expect(E.answerDiff('le monsieu', 'le monsieur, messieurs', 'fr')).toEqual([
    { type: 'same', text: 'le monsieu' },
    { type: 'add', text: 'r' },
  ]);
  expect(E.answerDiff('voll daneben', 'le chat', 'fr')).toBe(null);
  expect(E.answerDiff('   ', 'le chat', 'fr')).toBe(null);
  expect(E.closestDiff('', 'x', null)).toEqual([{ type: 'add', text: 'x' }]);
});

/* --------------------------------------------------------------- result texts */

test('marks, badges and points of the results list', () => {
  const item = (m, points, extra = {}) => ({ question: question('c1'), given: 'x', mark: m, points, note: null, synonym: false, matched: null, ...extra });
  expect(E.markLabel(item('correct', 1))).toBe('Richtig');
  expect(E.markLabel(item('minor', 1))).toBe('Richtig');
  expect(E.markLabel(item('minor', 0.5))).toBe('Halber Punkt');
  expect(E.markLabel(item('minor', 0))).toBe('Kleiner Fehler');
  expect(E.markLabel(item('wrong', 0))).toBe('Falsch');
  expect(E.markLabel(item('blank', 0))).toBe('Keine Antwort');
  expect(E.markBadge(item('correct', 1))).toBe('correct');
  expect(E.markBadge(item('minor', 1))).toBe('correct');
  expect(E.markBadge(item('minor', 0.5))).toBe('half');
  expect(E.markBadge(item('minor', 0))).toBe('wrong');
  expect(E.markBadge(item('wrong', 0))).toBe('wrong');
  expect(E.markBadge(item('blank', 0))).toBe('blank');
  expect(E.itemPointsText(item('correct', 1))).toBe('1');
  expect(E.itemPointsText(item('minor', 0.5))).toBe('½');
  expect(E.itemPointsText(item('wrong', 0))).toBe('0');
  expect(E.itemPointsLabel(item('minor', 0.5))).toBe('ein halber Punkt');
  expect(E.itemPointsLabel(item('blank', 0))).toBe('kein Punkt');
  expect(E.noteTone(item('minor', 0.5))).toBe('info');
  expect(E.noteTone(item('wrong', 0))).toBe('warning');
  expect(E.showsExpected(item('correct', 1))).toBe(false);
  expect(E.showsExpected(item('blank', 0))).toBe(true);
  expect(E.minorCaption('strict')).toBe('kein Punkt');
  expect(E.minorCaption('half')).toBe('je ½ Punkt');
  expect(E.minorCaption('lenient')).toBe('ganzer Punkt');
  expect(E.learnMistakesTooltip(1)).toBe('Die 1 Frage mit Fehlern in Lernen üben');
  expect(E.retakeMistakesTooltip(3)).toBe('Eine neue Prüfung nur mit den 3 Fragen mit Fehlern');
});

test('the Learn link of «Falsche lernen» follows the URL contract', () => {
  expect(E.learnCardsPath('s1', ['c1', 'c 2', 'ä/b'], { review: true })).toBe('/set/s1/learn?new=1&cards=c1,c%202,%C3%A4%2Fb&review=1');
  expect(E.learnCardsPath('s 1', ['x'])).toBe('/set/s%201/learn?new=1&cards=x');
});

/* ----------------------------------------------------------------------- time */

test('clock texts', () => {
  expect(E.clockText(0)).toBe('0:00');
  expect(E.clockText(485)).toBe('8:05');
  expect(E.clockText(3725)).toBe('1:02:05');
  expect(E.clockText(-4)).toBe('0:00');
  expect(E.spokenTime(5)).toBe('5 Sekunden');
  expect(E.spokenTime(60)).toBe('1 Minute');
  expect(E.spokenTime(485)).toBe('8 Minuten 5 Sekunden');
  expect(E.spokenTime(61)).toBe('1 Minute 1 Sekunde');
});

test('the status clock counts down (rounded up) or up, and knows when it changes', () => {
  const start = 1_000_000;
  const deadline = E.examDeadline(start, 10);
  expect(deadline).toBe(start + 600000);
  expect(E.examDeadline(start, 0)).toBe(null);
  expect(E.clockState({ startedAt: start, deadline, now: start })).toEqual({ seconds: 600, countdown: true, lastMinute: false, nextChangeMs: 1000 });
  expect(E.clockState({ startedAt: start, deadline, now: start + 250 })).toEqual({ seconds: 600, countdown: true, lastMinute: false, nextChangeMs: 750 });
  const late = E.clockState({ startedAt: start, deadline, now: deadline - 60000 });
  expect(late.seconds).toBe(60);
  expect(late.lastMinute).toBe(true);
  expect(E.clockState({ startedAt: start, deadline, now: deadline - 60001 }).lastMinute).toBe(false);
  expect(E.clockState({ startedAt: start, deadline, now: deadline + 5 })).toEqual({ seconds: 0, countdown: true, lastMinute: true, nextChangeMs: 0 });
  expect(E.clockState({ startedAt: start, now: start + 61500 })).toEqual({ seconds: 61, countdown: false, lastMinute: false, nextChangeMs: 500 });
  expect(E.warnsBeforeEnd(5)).toBe(true);
  expect(E.warnsBeforeEnd(2)).toBe(false);
  expect(E.warnsBeforeEnd(0)).toBe(false);
});

/* ---------------------------------------------------------------- setup texts */

test('setup captions, choices and the bar pill', () => {
  expect(E.countChoicesFor(52)).toEqual([10, 15, 20, 30, 0]);
  expect(E.countChoicesFor(12)).toEqual([10, 0]);
  expect(E.countChoicesFor(10)).toEqual([0]);
  expect(E.countChoiceLabel(0, 52)).toBe('Alle 52');
  expect(E.countChoiceLabel(15, 52)).toBe('15');
  expect(E.countSelection(settings({ count: 20 }), 52)).toBe(20);
  expect(E.countSelection(settings({ count: 20 }), 20)).toBe(0);
  expect(E.countSelection(settings({ count: 0 }), 52)).toBe(0);
  expect(E.countCaption(52, 52)).toBe('Alle Begriffe, in zufälliger Reihenfolge.');
  expect(E.countCaption(20, 52)).toBe('20 von 52 Begriffen, zufällig ausgewählt.');
  expect(E.timeCaption(0, 20)).toBe('So viel Zeit, wie du brauchst. Die Zeit wird trotzdem gemessen.');
  expect(E.timeCaption(10, 20)).toBe('Ist die Zeit um, wird abgegeben. Empfohlen: etwa 10 Minuten für 20 Wörter.');
  expect(E.timeCaption(5, 1)).toBe('Ist die Zeit um, wird abgegeben. Empfohlen: etwa 1 Minute für 1 Wort.');
  expect(E.suggestedMinutes(15)).toBe(8);
  expect(E.suggestedMinutes(0)).toBe(1);
  expect(E.minuteChoiceLabel(0)).toBe('Ohne');
  expect(E.minuteChoiceLabel(45)).toBe('45 Min.');
  expect(E.setupSummary(20, 10)).toBe('20 Wörter · 10 Minuten');
  expect(E.setupSummary(1, 0)).toBe('1 Wort · Ohne Zeitlimit');
  expect(E.starredLabel(4)).toBe('Nur markierte (4)');
  expect(E.toleranceTitle('strict')).toBe('Streng');
  expect(E.toleranceTitle('lenient')).toBe('Grosszügig');
  expect(E.toleranceText('half')).toBe('Ein kleiner Fehler kostet einen halben Punkt.');
  expect(E.minorPoints('nope')).toBe(0.5);
});

/* ---------------------------------------------------------------- sheet texts */

test('sheet intro, labels and placeholders', () => {
  const fr = [question('c1', 'term', 1), question('c2', 'term', 2)];
  expect(E.introText(fr, 'fr', 'de')).toBe('2 Fragen · Antworten auf Französisch');
  expect(E.introText([fr[0], question('c5', 'definition', 2)], 'fr', 'de')).toBe('2 Fragen');
  expect(E.introText([fr[0]], 'fr', 'fr')).toBe('1 Frage');
  expect(E.introText([{ ...fr[0], answerLang: 'other' }], 'other', 'de')).toBe('1 Frage');
  expect(E.introText([], 'fr', 'de')).toBe('0 Fragen');
  expect(E.promptLabel(fr[0], 'fr', 'de')).toBe('Deutsch');
  expect(E.promptLabel(fr[0], 'de', 'de')).toBe('Definition');
  expect(E.promptLabel(question('c1', 'definition'), 'fr', 'fr')).toBe('Begriff');
  expect(E.promptLabel({ ...fr[0], promptLang: 'other' }, 'fr', 'other')).toBe('Definition');
  expect(E.answerPlaceholder(fr[0], 'fr', 'de')).toBe('Auf Französisch …');
  expect(E.answerPlaceholder(fr[0], 'fr', 'fr')).toBe('Antwort');
  expect(E.answerPlaceholder({ ...fr[0], answerLang: 'other' }, 'other', 'de')).toBe('Antwort');
  expect(E.answeredText(12, 20)).toBe('12 von 20 beantwortet');
  expect(E.answeredTooltip(12, 20)).toBe('12 von 20 Fragen beantwortet');
});

test('confirmations and announcements', () => {
  expect(E.submitConfirm(1)).toEqual({ title: 'Prüfung abgeben?', message: 'Eine Frage ist noch offen. Sie zählt als falsch.', confirmLabel: 'Abgeben' });
  expect(E.submitConfirm(3).message).toBe('3 Fragen sind noch offen. Sie zählen als falsch.');
  expect(E.LEAVE_CONFIRM.title).toBe('Prüfung beenden?');
  expect(E.LEAVE_CONFIRM.message).toBe('Die Prüfung wird nicht bewertet, deine Antworten gehen verloren.');
  expect(E.LEAVE_CONFIRM.confirmLabel).toBe('Beenden');
  expect(E.startAnnouncement(20, 10)).toBe('Prüfung gestartet: 20 Fragen, 10 Minuten.');
  expect(E.startAnnouncement(1, 0)).toBe('Prüfung gestartet: 1 Frage.');
  expect(E.ONE_MINUTE_TEXT).toBe('Noch eine Minute');
  expect(E.TIMED_OUT_TOAST).toBe('Die Zeit ist um. Deine Prüfung wurde abgegeben.');
  expect(E.TIMED_OUT_LINE).toBe('Die Zeit war um, die Prüfung wurde abgegeben.');
});

test('every exam text uses the Swiss "ss"', () => {
  const texts = [
    E.SMALL_MISTAKES_TEXT,
    E.NOT_MASTERY_NOTE,
    E.STARRED_CAPTION,
    ...E.TOLERANCES.flatMap((t) => [E.toleranceTitle(t), E.toleranceText(t), E.minorCaption(t)]),
    E.LEAVE_CONFIRM.message,
    E.TIMED_OUT_TOAST,
    E.TIMED_OUT_LINE,
  ];
  for (const t of texts) expect(t.includes('ß')).toBe(false);
  expect(E.SMALL_MISTAKES_TEXT).toContain('Grossschreibung');
});

/* -------------------------------------------------------------------- screens */

test('the exam screens import under JavaScriptCore', async () => {
  const screen = await import('../src/screens/exam.js');
  expect(typeof screen.render).toBe('function');
  const setup = await import('../src/screens/exam-setup.js');
  expect(typeof setup.setupView).toBe('function');
  expect(typeof setup.emptyView).toBe('function');
  const sheet = await import('../src/screens/exam-sheet.js');
  expect(typeof sheet.createSheet).toBe('function');
  const results = await import('../src/screens/exam-results.js');
  expect(typeof results.resultsView).toBe('function');
});


/* ------------------------------------------------- the screen on a fake DOM */

// A small DOM, enough for the exam screen and the UI kit it uses (jsc has none): elements with
// attributes, classes, data, styles, events that bubble to the document, focus with
// focusin/focusout, simple selectors (tag, .class, #id, [attr], [attr="v"], :not(…), lists).
class FakeNode {
  constructor() {
    this.parentNode = null;
  }
  get isConnected() {
    let n = this;
    while (n.parentNode) n = n.parentNode;
    return n === globalThis.document?.documentElement;
  }
  remove() {
    if (this.parentNode) this.parentNode.removeChild(this);
  }
}

class FakeText extends FakeNode {
  constructor(text) {
    super();
    this.nodeType = 3;
    this.data = String(text);
  }
  get textContent() {
    return this.data;
  }
  set textContent(v) {
    this.data = String(v);
  }
}

class FakeClassList {
  constructor(el) {
    this.el = el;
  }
  list() {
    return (this.el.getAttribute('class') || '').split(/\s+/).filter(Boolean);
  }
  write(list) {
    this.el.setAttribute('class', list.join(' '));
  }
  contains(name) {
    return this.list().includes(name);
  }
  add(...names) {
    const list = this.list();
    for (const n of names) if (!list.includes(n)) list.push(n);
    this.write(list);
  }
  remove(...names) {
    this.write(this.list().filter((n) => !names.includes(n)));
  }
  toggle(name, force) {
    const on = force === undefined ? !this.contains(name) : !!force;
    if (on) this.add(name);
    else this.remove(name);
    return on;
  }
}

function fakeStyle() {
  const props = {};
  return {
    props,
    setProperty(name, value) {
      props[name] = String(value);
    },
    removeProperty(name) {
      delete props[name];
    },
    getPropertyValue(name) {
      return props[name] || '';
    },
    cssText: '',
  };
}

class FakeEvent {
  constructor(type, init = {}) {
    Object.assign(this, init);
    this.type = type;
    this.bubbles = !!init.bubbles;
    this.defaultPrevented = false;
    this.stopped = false;
  }
  preventDefault() {
    this.defaultPrevented = true;
  }
  stopPropagation() {
    this.stopped = true;
  }
}

function listen(target, type, fn, opts) {
  const list = (target.listeners[type] = target.listeners[type] || []);
  list.push({ fn, once: !!(opts && opts.once) });
}

function unlisten(target, type, fn) {
  target.listeners[type] = (target.listeners[type] || []).filter((l) => l.fn !== fn);
}

function fire(target, event) {
  event.currentTarget = target;
  for (const l of (target.listeners[event.type] || []).slice()) {
    if (l.once) unlisten(target, event.type, l.fn);
    l.fn.call(target, event);
    if (event.stopped) return;
  }
}

// One compound selector: tag, .class, #id, [attr], [attr="v"], :not(compound).
function matchesCompound(el, sel) {
  let rest = sel.trim();
  const nots = [];
  rest = rest.replace(/:not\(([^()]*)\)/g, (_, inner) => {
    nots.push(inner);
    return '';
  });
  const re = /^([a-z][a-z0-9-]*|\*)|\.([\w-]+)|#([\w-]+)|\[([\w-]+)(?:="([^"]*)")?\]/gi;
  let m;
  let consumed = '';
  while ((m = re.exec(rest))) {
    consumed += m[0];
    if (m[1] && m[1] !== '*' && el.localName !== m[1].toLowerCase()) return false;
    if (m[2] && !el.classList.contains(m[2])) return false;
    if (m[3] && el.getAttribute('id') !== m[3]) return false;
    if (m[4] && (!el.hasAttribute(m[4]) || (m[5] !== undefined && el.getAttribute(m[4]) !== m[5]))) return false;
  }
  if (consumed.length !== rest.length) throw new Error(`fake DOM: unsupported selector "${sel}"`);
  return nots.every((n) => !matchesCompound(el, n));
}

class FakeElement extends FakeNode {
  constructor(tag) {
    super();
    this.nodeType = 1;
    this.localName = String(tag).toLowerCase();
    this.tagName = this.localName.toUpperCase();
    this.childNodes = [];
    this.attrs = new Map();
    this.listeners = {};
    this.style = fakeStyle();
    // data-* attributes, as in a browser.
    const kebab = (k) => `data-${String(k).replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`;
    this.dataset = new Proxy(
      {},
      {
        get: (_t, k) => (typeof k === 'string' ? (this.getAttribute(kebab(k)) ?? undefined) : undefined),
        set: (_t, k, v) => {
          this.setAttribute(kebab(k), v);
          return true;
        },
        deleteProperty: (_t, k) => {
          this.removeAttribute(kebab(k));
          return true;
        },
      },
    );
    this.classList = new FakeClassList(this);
    this.checked = false;
    this.disabled = false;
    this.hidden = false;
    this.autofocus = false;
    this.value = '';
    this.tabIndex = -1;
    this.selectionStart = 0;
    this.selectionEnd = 0;
    this.offsetWidth = 0;
    this.offsetHeight = 0;
  }
  get className() {
    return this.getAttribute('class') || '';
  }
  set className(v) {
    this.setAttribute('class', v);
  }
  get id() {
    return this.getAttribute('id') || '';
  }
  set id(v) {
    this.setAttribute('id', v);
  }
  get htmlFor() {
    return this.getAttribute('for') || '';
  }
  set htmlFor(v) {
    this.setAttribute('for', v);
  }
  get lang() {
    return this.getAttribute('lang') || '';
  }
  set lang(v) {
    this.setAttribute('lang', v);
  }
  setAttribute(name, value) {
    this.attrs.set(name, String(value));
  }
  getAttribute(name) {
    return this.attrs.has(name) ? this.attrs.get(name) : null;
  }
  hasAttribute(name) {
    return this.attrs.has(name);
  }
  removeAttribute(name) {
    this.attrs.delete(name);
  }
  appendChild(node) {
    if (node.parentNode) node.parentNode.removeChild(node);
    node.parentNode = this;
    this.childNodes.push(node);
    return node;
  }
  insertBefore(node, ref) {
    if (!ref) return this.appendChild(node);
    if (node.parentNode) node.parentNode.removeChild(node);
    node.parentNode = this;
    this.childNodes.splice(this.childNodes.indexOf(ref), 0, node);
    return node;
  }
  append(...nodes) {
    for (const n of nodes) this.appendChild(typeof n === 'string' ? new FakeText(n) : n);
  }
  prepend(...nodes) {
    const first = this.firstChild;
    for (const n of nodes) this.insertBefore(typeof n === 'string' ? new FakeText(n) : n, first);
  }
  replaceChildren(...nodes) {
    for (const n of this.childNodes) n.parentNode = null;
    this.childNodes = [];
    this.append(...nodes);
  }
  removeChild(node) {
    const i = this.childNodes.indexOf(node);
    if (i >= 0) this.childNodes.splice(i, 1);
    node.parentNode = null;
    return node;
  }
  contains(node) {
    for (let n = node; n; n = n.parentNode) if (n === this) return true;
    return false;
  }
  get children() {
    return this.childNodes.filter((n) => n.nodeType === 1);
  }
  get firstChild() {
    return this.childNodes[0] || null;
  }
  get parentElement() {
    return this.parentNode && this.parentNode.nodeType === 1 ? this.parentNode : null;
  }
  get textContent() {
    return this.childNodes.map((n) => n.textContent).join('');
  }
  set textContent(v) {
    this.replaceChildren(...(v == null || v === '' ? [] : [String(v)]));
  }
  set innerHTML(v) {
    this.textContent = v;
  }
  matches(selector) {
    return selector.split(',').some((part) => matchesCompound(this, part));
  }
  closest(selector) {
    for (let n = this; n && n.nodeType === 1; n = n.parentNode) if (n.matches(selector)) return n;
    return null;
  }
  querySelectorAll(selector) {
    const out = [];
    const walk = (node) => {
      for (const child of node.children) {
        if (child.matches(selector)) out.push(child);
        walk(child);
      }
    };
    walk(this);
    return out;
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }
  addEventListener(type, fn, opts) {
    listen(this, type, fn, opts);
  }
  removeEventListener(type, fn) {
    unlisten(this, type, fn);
  }
  // Bubbles through the ancestors to the document.
  dispatchEvent(event) {
    if (!(event instanceof FakeEvent)) event = new FakeEvent(event.type, event);
    event.target = this;
    const path = [];
    for (let n = this; n; n = n.parentNode) path.push(n);
    if (this.isConnected) path.push(globalThis.document);
    for (const node of event.bubbles ? path : [this]) {
      fire(node, event);
      if (event.stopped) break;
    }
    return !event.defaultPrevented;
  }
  click() {
    this.dispatchEvent(new FakeEvent('click', { bubbles: true }));
  }
  focus() {
    const doc = globalThis.document;
    const prev = doc.activeElement;
    if (prev === this) return;
    doc.activeElement = this;
    if (prev && prev.dispatchEvent) prev.dispatchEvent(new FakeEvent('focusout', { bubbles: true, relatedTarget: this }));
    this.dispatchEvent(new FakeEvent('focusin', { bubbles: true, relatedTarget: prev || null }));
  }
  blur() {
    if (globalThis.document.activeElement === this) globalThis.document.activeElement = globalThis.document.body;
  }
  getBoundingClientRect() {
    return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 };
  }
  getClientRects() {
    return [];
  }
  setSelectionRange(start, end) {
    this.selectionStart = start;
    this.selectionEnd = end;
  }
  setRangeText(text, start, end) {
    this.value = this.value.slice(0, start) + text + this.value.slice(end);
    this.selectionStart = this.selectionEnd = start + text.length;
  }
}

function installFakeDom() {
  const documentElement = new FakeElement('html');
  const body = new FakeElement('body');
  documentElement.appendChild(body);
  globalThis.document = {
    nodeType: 9,
    listeners: {},
    documentElement,
    body,
    activeElement: body,
    visibilityState: 'visible',
    createElement: (tag) => new FakeElement(tag),
    createElementNS: (_ns, tag) => new FakeElement(tag),
    createTextNode: (text) => new FakeText(text),
    getElementById: (id) => documentElement.querySelector(`#${id}`),
    querySelector: (sel) => documentElement.querySelector(sel),
    querySelectorAll: (sel) => documentElement.querySelectorAll(sel),
    addEventListener(type, fn, opts) {
      listen(this, type, fn, opts);
    },
    removeEventListener(type, fn) {
      unlisten(this, type, fn);
    },
  };
  globalThis.window = {
    listeners: {},
    innerWidth: 1200,
    scrollY: 0,
    addEventListener(type, fn, opts) {
      listen(this, type, fn, opts);
    },
    removeEventListener(type, fn) {
      unlisten(this, type, fn);
    },
    scrollTo() {},
    scrollBy() {},
    getSelection: () => null,
  };
  globalThis.Event = FakeEvent;
  globalThis.getComputedStyle = () => ({ visibility: 'visible' });
  if (typeof globalThis.clearTimeout !== 'function') {
    // jsc has setTimeout but no clearTimeout: cancelled callbacks are skipped.
    const realSet = globalThis.setTimeout;
    const cancelled = new Set();
    let next = 1;
    globalThis.setTimeout = (fn, ms, ...args) => {
      const id = next++;
      realSet(() => {
        if (cancelled.delete(id)) return;
        fn(...args);
      }, ms);
      return id;
    };
    globalThis.clearTimeout = (id) => {
      if (id) cancelled.add(id);
    };
  }
  if (typeof globalThis.requestAnimationFrame !== 'function') globalThis.requestAnimationFrame = (fn) => setTimeout(fn, 0);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const settle = () => sleep(5);
const key = (target, k, extra = {}) => {
  const e = new FakeEvent('keydown', { bubbles: true, key: k, code: extra.code || '', repeat: false, ...extra });
  target.dispatchEvent(e);
  return e;
};
const typeInto = (input, text) => {
  input.value = text;
  input.dispatchEvent(new FakeEvent('input', { bubbles: true }));
};
const textOf = (root, sel) => {
  const el = root.querySelector(sel);
  return el ? el.textContent : null;
};
const buttonLabelled = (root, label) => root.querySelectorAll('button').find((b) => (b.getAttribute('aria-label') || b.textContent).includes(label));

// Screens still mounted after a test failed half way: their clock would keep jsc running (the
// suite would hang instead of reporting) and an open dialog would swallow the next test's keys.
const mounted = new Set();
async function unmountLeftovers() {
  for (const stop of [...mounted]) stop();
  const { closeOverlays } = await import('../src/ui/components.js');
  closeOverlays();
}

async function mountExam({ cards, prefs, termLang = 'fr', defLang = 'de' }) {
  await unmountLeftovers();
  const { db } = await import('../src/store/db.js');
  const { setPref, PREF } = await import('../src/lib/prefs.js');
  const screen = await import('../src/screens/exam.js');
  setPref(PREF.examSettings, prefs);
  const set = db.createSet({ title: 'Vokabeln', termLang, defLang, cards });
  const outlet = new FakeElement('main');
  document.body.appendChild(outlet);
  const navs = [];
  const titles = [];
  const stop = screen.render(outlet, {
    params: { id: set.id },
    query: {},
    route: 'exam',
    path: `/set/${set.id}/exam`,
    setTitle: (t) => titles.push(t),
    navigate: (p) => navs.push(p),
  });
  const cleanup = () => {
    if (mounted.delete(cleanup)) stop();
  };
  mounted.add(cleanup);
  const root = outlet.querySelector('.ex');
  return { db, set, outlet, root, navs, titles, cleanup, setPref, PREF };
}

const SCREEN_CARDS = [
  { term: 'la maison', definition: 'das Haus', starred: true },
  { term: 'le chien', definition: 'der Hund', starred: true },
  { term: 'le chat', definition: 'die Katze' },
];

test('the screen: setup, settings, sheet, keys, hand in, results and back to setup', async () => {
  installFakeDom();
  const x = await mountExam({ cards: SCREEN_CARDS, prefs: { minutes: 5, count: 0, answerWith: 'term', tolerance: 'half', starredOnly: false } });
  const { root, navs } = x;
  expect(x.titles[x.titles.length - 1]).toBe('Vokabeln – Prüfung');
  expect(root.dataset.phase).toBe('setup');
  expect(textOf(root, '.ex-setup__title')).toBe('Prüfung einrichten');
  expect(textOf(root, '.ex-pill__text')).toBe('3 Wörter · 5 Minuten');
  expect(textOf(root, '#ex-set-count-caption')).toBe('Alle Begriffe, in zufälliger Reihenfolge.');
  expect(textOf(root, '#ex-set-time-caption')).toBe('Ist die Zeit um, wird abgegeben. Empfohlen: etwa 2 Minuten für 3 Wörter.');
  expect(textOf(root, '#ex-set-direction-caption')).toBe('Du siehst Deutsch und antwortest auf Französisch.');
  expect(textOf(root, '#ex-set-starred')).toBe('Nur markierte (2)');
  expect(document.activeElement.classList.contains('ex-start')).toBe(true);

  // «Beides» changes the caption and is kept for every set.
  buttonLabelled(root, 'Beides').click();
  expect(textOf(root, '#ex-set-direction-caption')).toBe('Die Richtung wechselt zufällig von Frage zu Frage.');
  const { getPref } = await import('../src/lib/prefs.js');
  expect(getPref(x.PREF.examSettings).answerWith).toBe('both');
  buttonLabelled(root, 'Französisch').click();
  expect(getPref(x.PREF.examSettings).answerWith).toBe('term');

  // «Nur markierte»: two words; the count choices follow.
  const star = root.querySelector('[data-key="starred"]').querySelector('input');
  star.checked = true;
  star.dispatchEvent(new FakeEvent('change'));
  expect(textOf(root, '.ex-pill__text')).toBe('2 Wörter · 5 Minuten');
  expect(root.querySelector('[data-key="count"]').querySelectorAll('button').map((b) => b.textContent)).toEqual(['Alle 2']);

  // ↵ starts the exam.
  key(document.body, 'Enter');
  expect(root.dataset.phase).toBe('running');
  const inputs = root.querySelectorAll('.ex-q__input');
  expect(inputs.length).toBe(2);
  expect(document.activeElement).toBe(inputs[0]);
  expect(inputs[0].getAttribute('placeholder')).toBe('Auf Französisch …');
  expect(inputs[0].getAttribute('spellcheck')).toBe('false');
  expect(textOf(root, '.ex-intro__text')).toBe('2 Fragen · Antworten auf Französisch');
  expect(textOf(root, '.ex-clock__time')).toBe('5:00');
  expect(textOf(root, '.ex-status__count')).toBe('0/2');
  expect(textOf(root, '.ex-pill__count')).toBe('0 von 2 beantwortet');
  // The accents of French float above the bar while a French answer has focus.
  expect(root.querySelector('.ex-chars').hidden).toBe(false);

  // A held or immediate second ↵ does nothing; then ↵ moves on to the next question.
  key(inputs[0], 'Enter');
  expect(document.activeElement).toBe(inputs[0]);
  await sleep(300);
  const prompt0 = root.querySelectorAll('.ex-q')[0].querySelector('.ex-q__prompt').textContent;
  const answer0 = prompt0.includes('Haus') ? 'la maison' : 'le chien';
  typeInto(inputs[0], answer0);
  expect(textOf(root, '.ex-status__count')).toBe('1/2');
  expect(textOf(root, '.ex-pill__count')).toBe('1 von 2 beantwortet');
  expect(root.querySelector('.ex-q__num').classList.contains('is-answered')).toBe(true);
  key(inputs[0], 'Enter');
  expect(document.activeElement).toBe(inputs[1]);
  // The last question keeps the keys.
  key(inputs[1], 'Enter');
  expect(document.activeElement).toBe(inputs[1]);
  // A character key types at the caret.
  root.querySelector('.ex-char').click();
  expect(inputs[1].value).toBe('é');
  typeInto(inputs[1], '');

  // Strg+↵ with an open question asks first; «Abbrechen» keeps the sheet.
  key(inputs[1], 'Enter', { ctrlKey: true });
  await settle();
  let modal = document.body.querySelector('.ui-modal');
  expect(!!modal).toBe(true);
  expect(modal.textContent).toContain('Prüfung abgeben?');
  expect(modal.textContent).toContain('Eine Frage ist noch offen. Sie zählt als falsch.');
  buttonLabelled(modal, 'Abbrechen').click();
  await settle();
  expect(root.dataset.phase).toBe('running');
  key(inputs[1], 'Enter', { ctrlKey: true });
  await settle();
  modal = document.body.querySelectorAll('.ui-modal').find((m) => m.parentNode && m.parentNode.dataset.state === 'open');
  buttonLabelled(modal, 'Abgeben').click();
  await settle();

  // The result.
  expect(root.dataset.phase).toBe('results');
  expect(textOf(root, '.ex-res__title')).toBe('Noch nicht genügend');
  expect(textOf(root, '.ex-grade__value')).toBe('3.5');
  expect(textOf(root, '.ex-res__text').startsWith('1 von 2 Punkten in 0:')).toBe(true);
  expect(root.querySelector('.ex-grade').classList.contains('ex-grade--warning')).toBe(true);
  expect(root.querySelectorAll('.ex-tile').length).toBe(4);
  expect(root.querySelectorAll('.ex-item').length).toBe(2);
  expect(textOf(root, '.ex-answers__rule')).toBe('Ein kleiner Fehler kostet einen halben Punkt.');
  expect(root.querySelector('.ex-item--blank').textContent).toContain('Keine Antwort');
  expect(root.querySelector('.ex-item--blank').textContent).toContain('Richtig:');
  expect(document.activeElement.classList.contains('ex-done')).toBe(true);
  expect(textOf(root, '.ex-top__status')).toBe('');
  // Nothing was recorded.
  expect(x.db.getProgress(x.set.id)).toEqual({});
  expect(x.db.getActivity()).toEqual({});

  // «Falsche prüfen»: a new sheet with only the blank one.
  buttonLabelled(root, 'Falsche prüfen').click();
  expect(root.dataset.phase).toBe('running');
  expect(root.querySelectorAll('.ex-q__input').length).toBe(1);
  // Nothing typed yet: Strg+⇧+R goes back to the settings without asking.
  key(document.activeElement, 'R', { ctrlKey: true, shiftKey: true, code: 'KeyR' });
  await settle();
  expect(root.dataset.phase).toBe('setup');

  // Esc leaves (the router's leave guard asks while answers exist).
  key(document.body, 'Escape');
  expect(navs[navs.length - 1]).toBe(`/set/${x.set.id}`);
  x.cleanup();
  x.outlet.remove();
});

test('the screen: «Falsche lernen» opens Lernen with the wrong cards as repetition questions', async () => {
  installFakeDom();
  const x = await mountExam({ cards: SCREEN_CARDS, prefs: { minutes: 0, count: 0, answerWith: 'term', tolerance: 'strict', starredOnly: false } });
  key(document.body, 'Enter');
  expect(textOf(x.root, '.ex-clock__time')).toBe('0:00');
  // Hand in with nothing typed: every card is to practise.
  key(document.activeElement, 'Enter', { metaKey: true });
  await settle();
  buttonLabelled(document.body.querySelectorAll('.ui-modal').pop(), 'Abgeben').click();
  await settle();
  expect(x.root.dataset.phase).toBe('results');
  expect(textOf(x.root, '.ex-grade__value')).toBe('1.0');
  buttonLabelled(x.root, 'Falsche lernen').click();
  await sleep(20);
  // Through learn-start.js when it exists, else the URL contract directly.
  const last = String(x.navs[x.navs.length - 1] || '');
  expect(last).toContain(`/set/${x.set.id}/learn?`);
  expect(last).toContain('new=1');
  expect(last).toContain('review=1');
  expect(last.split('cards=')[1].split('&')[0].split(',').length).toBe(3);
  x.cleanup();
  x.outlet.remove();
});

test('the screen: the time runs out, the result waits before ↵ works', async () => {
  installFakeDom();
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    const x = await mountExam({ cards: SCREEN_CARDS, prefs: { minutes: 5, count: 0, answerWith: 'definition', tolerance: 'lenient', starredOnly: false } });
    key(document.body, 'Enter');
    const inputs = x.root.querySelectorAll('.ex-q__input');
    expect(inputs[0].getAttribute('placeholder')).toBe('Auf Deutsch …');
    typeInto(inputs[0], 'irgendwas');
    // A minute before the end: «Noch eine Minute».
    now += 241000;
    await sleep(1100);
    expect(document.body.querySelector('.ui-toasts').textContent).toContain('Noch eine Minute');
    expect(x.root.querySelector('.ex-clock').classList.contains('is-warning')).toBe(true);
    // The end: handed in by itself.
    now += 60000;
    await sleep(1100);
    expect(x.root.dataset.phase).toBe('results');
    expect(textOf(x.root, '.ex-res__timeout')).toBe('Die Zeit war um, die Prüfung wurde abgegeben.');
    expect(textOf(x.root, '.ex-res__text')).toBe('0 von 3 Punkten in 5:00');
    expect(document.body.querySelector('.ui-toasts').textContent).toContain('Die Zeit ist um. Deine Prüfung wurde abgegeben.');
    expect(document.activeElement.classList.contains('ex-res__title')).toBe(true);
    // ↵ meant for the sheet does nothing for 1.2 s, then means «Fertig».
    const blocked = key(document.activeElement, 'Enter');
    expect(blocked.defaultPrevented).toBe(true);
    expect(x.navs.length).toBe(0);
    await sleep(1250);
    key(document.activeElement, 'Enter');
    expect(x.navs[x.navs.length - 1]).toBe(`/set/${x.set.id}`);
    x.cleanup();
  } finally {
    Date.now = realNow;
  }
});

test('the screen: an empty set and a missing set', async () => {
  installFakeDom();
  const x = await mountExam({ cards: [{ term: 'nur Begriff', definition: '' }], prefs: null });
  expect(textOf(x.root, '.ui-empty__title')).toBe('Nichts zu prüfen');
  expect(document.activeElement.getAttribute('href')).toBe(`#/set/${x.set.id}/edit`);
  // Enter does not start anything here.
  key(document.body, 'Enter');
  expect(x.root.dataset.phase).toBe('setup');
  // Cards added elsewhere: the settings appear.
  x.db.updateSet(x.set.id, { cards: [{ term: 'le pain', definition: 'das Brot' }] });
  expect(textOf(x.root, '.ex-setup__title')).toBe('Prüfung einrichten');
  x.cleanup();
  const screen = await import('../src/screens/exam.js');
  const outlet = new FakeElement('main');
  const titles = [];
  screen.render(outlet, { params: { id: 'nope' }, query: {}, setTitle: (t) => titles.push(t), navigate: () => {} });
  expect(titles).toEqual(['Lernset nicht gefunden']);
  expect(outlet.textContent).toContain('Lernset nicht gefunden');
});

test('the screen: held or doubled keys never press a second thing', async () => {
  installFakeDom();
  const x = await mountExam({ cards: SCREEN_CARDS, prefs: { minutes: 0, count: 0, answerWith: 'term', tolerance: 'half', starredOnly: false } });
  key(document.body, 'Enter');
  await sleep(300);
  const inputs = x.root.querySelectorAll('.ex-q__input');
  // Strg+↵ held: the first press asks, its repeats do not press the «Abgeben» it focused.
  key(inputs[0], 'Enter', { ctrlKey: true });
  await settle();
  const open = () => document.body.querySelectorAll('.ui-modal').filter((m) => m.parentNode && m.parentNode.dataset.state === 'open');
  expect(open().length).toBe(1);
  const held = key(document.activeElement, 'Enter', { ctrlKey: true, repeat: true });
  expect(held.defaultPrevented).toBe(true);
  expect(key(document.activeElement, 'Enter', { repeat: true }).defaultPrevented).toBe(true);
  buttonLabelled(open()[0], 'Abbrechen').click();
  await settle();
  expect(x.root.dataset.phase).toBe('running');

  // Everything answered: Strg+↵ hands in at once; pressed again right away it must not press
  // the focused «Fertig» as well, a while later it may.
  for (const input of inputs) typeInto(input, 'x');
  key(inputs[0], 'Enter', { ctrlKey: true });
  expect(x.root.dataset.phase).toBe('results');
  expect(document.activeElement.classList.contains('ex-done')).toBe(true);
  expect(key(document.activeElement, 'Enter', { ctrlKey: true }).defaultPrevented).toBe(true);
  await sleep(300);
  expect(key(document.activeElement, 'Enter', { ctrlKey: true }).defaultPrevented).toBe(false);

  // Strg+⇧+R held from the results into the settings: no hard reload on its repeats.
  key(document.activeElement, 'R', { ctrlKey: true, shiftKey: true, code: 'KeyR' });
  expect(x.root.dataset.phase).toBe('setup');
  expect(key(document.activeElement, 'R', { ctrlKey: true, shiftKey: true, code: 'KeyR', repeat: true }).defaultPrevented).toBe(true);
  await sleep(300);
  // A fresh press in the settings is the browser's again.
  expect(key(document.activeElement, 'R', { ctrlKey: true, shiftKey: true, code: 'KeyR' }).defaultPrevented).toBe(false);
  x.cleanup();
  x.outlet.remove();
});

test('the screen: «Falsche lernen» clicked twice starts Lernen once; the bar fills by a transform', async () => {
  installFakeDom();
  const x = await mountExam({ cards: SCREEN_CARDS, prefs: { minutes: 0, count: 0, answerWith: 'term', tolerance: 'half', starredOnly: false } });
  key(document.body, 'Enter');
  const inputs = x.root.querySelectorAll('.ex-q__input');
  const fill = x.root.querySelector('.ex-line__fill');
  expect(fill.style.transform).toBe('translateX(-100%)');
  typeInto(inputs[0], 'x');
  expect(fill.style.transform).toBe('translateX(-66.67%)');
  for (const input of inputs) typeInto(input, 'x');
  expect(fill.style.transform).toBe('translateX(0%)');
  expect(fill.style.width).toBe(undefined);
  key(inputs[0], 'Enter', { ctrlKey: true });
  expect(x.root.dataset.phase).toBe('results');
  const learn = buttonLabelled(x.root, 'Falsche lernen');
  learn.click();
  learn.click();
  await sleep(30);
  expect(x.navs.filter((p) => p.includes('/learn?')).length).toBe(1);
  x.cleanup();
  x.outlet.remove();
});

test('the screen: a deleted set, restored in another tab, shows the settings again', async () => {
  installFakeDom();
  const x = await mountExam({ cards: SCREEN_CARDS, prefs: { minutes: 0, count: 0, answerWith: 'term', tolerance: 'half', starredOnly: false } });
  key(document.body, 'Enter');
  typeInto(x.root.querySelectorAll('.ex-q__input')[0], 'la maison');
  const snapshot = x.db.snapshotSet(x.set.id);
  x.db.deleteSet(x.set.id);
  expect(x.root.dataset.phase).toBe('gone');
  expect(x.root.textContent).toContain('Lernset nicht gefunden');
  expect(x.root.querySelector('.ex-dock')).toBe(null);
  // Focus was in the sheet: it moves to «Zur Übersicht» instead of getting lost.
  expect(document.activeElement.getAttribute('href')).toBe('#/');
  // Nothing is left to lose: Esc stays with the browser.
  expect(key(document.body, 'Escape').defaultPrevented).toBe(false);
  x.db.restoreSet(snapshot);
  expect(x.root.dataset.phase).toBe('setup');
  expect(textOf(x.root, '.ex-setup__title')).toBe('Prüfung einrichten');
  expect(document.activeElement.classList.contains('ex-start')).toBe(true);
  x.cleanup();
  x.outlet.remove();
});

test('the screen tests leave no exam running', async () => {
  await unmountLeftovers();
  expect(mounted.size).toBe(0);
});

test('Arabic and Chinese: tones are a small mistake, variants and pinyin are no mistake', () => {
  const cards = [
    { id: 'z1', term: '你好 (nǐ hǎo)', definition: 'Hallo' },
    { id: 'a1', term: 'مدرسة', definition: 'Schule' },
    { id: 'a2', term: 'الكتاب', definition: 'das Buch' },
  ];
  const q = (cardId, answerLang) => {
    const card = cards.find((c) => c.id === cardId);
    return { number: 1, cardId, ask: 'term', prompt: card.definition, expected: card.term, promptLang: 'de', answerLang };
  };
  expect(E.SMALL_MISTAKES).toContain('tones');
  expect(E.SMALL_MISTAKES).not.toContain('variant');
  expect(E.SMALL_MISTAKES).not.toContain('pinyin');
  const han = E.markAnswer('你好', q('z1', 'zh'), cards, 'half');
  expect([han.mark, han.points, han.note]).toEqual(['correct', 1, null]);
  const pinyin = E.markAnswer('ni3 hao3', q('z1', 'zh'), cards, 'half');
  expect([pinyin.mark, pinyin.points, pinyin.note]).toEqual(['correct', 1, null]);
  const tones = E.markAnswer('ni hao', q('z1', 'zh'), cards, 'half');
  expect([tones.mark, tones.points, tones.note]).toEqual(['minor', 0.5, 'Töne']);
  const variant = E.markAnswer('مدرسه', q('a1', 'ar'), cards, 'half');
  expect([variant.mark, variant.points, variant.note]).toEqual(['correct', 1, null]);
  // A missing ال is a missing article (small); the variant adds nothing.
  const article = E.markAnswer('كتاب', q('a2', 'ar'), cards, 'half');
  expect([article.mark, article.note]).toEqual(['minor', 'Artikel fehlte']);
  const wrong = E.markAnswer('谢谢', q('z1', 'zh'), cards, 'half');
  expect(wrong.mark).toBe('wrong');
});

test('Chinese and Arabic answer diffs use the form typed and hide unwritten vowel marks', () => {
  expect(E.answerDiff('ni hao', '你好 (nǐ hǎo), 您好 (nín hǎo)', 'zh')).toEqual([
    { type: 'same', text: 'n' },
    { type: 'del', text: 'i' },
    { type: 'add', text: 'ǐ' },
    { type: 'same', text: ' h' },
    { type: 'del', text: 'a' },
    { type: 'add', text: 'ǎ' },
    { type: 'same', text: 'o' },
  ]);
  expect(E.closestDiff('دفتر', 'كِتَابٌ، دَفْتَرٌ', 'ar')).toEqual([{ type: 'same', text: 'دفتر' }]);
  expect(E.closestDiff('كتب', 'كِتَابٌ، دَفْتَرٌ', 'ar')).toEqual([
    { type: 'same', text: 'كت' },
    { type: 'add', text: 'ا' },
    { type: 'same', text: 'ب' },
  ]);
});

await run('exam.test.js');
