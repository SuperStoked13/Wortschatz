// Cross-module integration: the pure pipeline behind the screens
// (editor: parser -> db; write mode: db options -> session -> grading -> db progress).
import { test, expect, run } from './harness.js';
import { parseVocab } from '../src/core/parser.js';
import { createDb, memoryStorage, DEFAULT_STUDY_OPTIONS } from '../src/store/db.js';
import { grade, DEFAULT_TOLERANCE } from '../src/core/grading.js';
import * as S from '../src/core/session.js';
import { setProgress, cardStatus, studyStreak } from '../src/core/mastery.js';
import { setToText } from '../src/store/backup.js';
import { NOTE_LABELS, HINT_LABELS } from '../src/lib/labels.js';

const readFixture = (name) => readFile(`fixtures/${name}`);

// Deterministic rng (mulberry32) so shuffled sessions are reproducible.
function seeded(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Mirrors write-model.questionInfo: which text is expected for a question.
function expectedFor(set, q) {
  const card = set.cards.find((c) => c.id === q.cardId);
  return q.ask === 'term'
    ? { expected: card.term, lang: set.termLang }
    : { expected: card.definition, lang: set.defLang };
}

function createUserExampleSet(db) {
  const parsed = parseVocab(readFixture('user-example.txt'), { termLang: 'fr', defLang: 'de' });
  return db.createSet({
    title: 'Personen',
    termLang: parsed.termLang,
    defLang: parsed.defLang,
    cards: parsed.cards.map((c) => ({ term: c.term, definition: c.definition })),
  });
}

test('editor flow: user example parses into a stored 52-card set', () => {
  const db = createDb(() => memoryStorage());
  const set = createUserExampleSet(db);
  expect(set.cards).toHaveLength(52);
  expect(set.termLang).toBe('fr');
  expect(set.defLang).toBe('de');
  expect(set.cards[0].term).toBe('le monsieur, messieurs');
  expect(set.cards[0].definition).toBe('der Herr');
  expect(db.listSets().map((s) => s.id)).toEqual([set.id]);
  // Quizlet text export round-trips through the parser.
  const again = parseVocab(setToText(set), { termLang: 'fr', defLang: 'de' });
  expect(again.cards.map((c) => [c.term, c.definition])).toEqual(set.cards.map((c) => [c.term, c.definition]));
});

test('default study options agree between store and grading', () => {
  expect({ ...DEFAULT_STUDY_OPTIONS.tolerance }).toEqual({ ...DEFAULT_TOLERANCE });
  const db = createDb(() => memoryStorage());
  const set = createUserExampleSet(db);
  const options = db.getStudyOptions(set.id);
  expect(options.answerWith).toBe('term');
  expect({ ...options.tolerance }).toEqual({ ...DEFAULT_TOLERANCE });
});

test('write flow: rounds, retest of misses, override, persistence and mastery', () => {
  const storage = memoryStorage();
  let clock = Date.UTC(2026, 9, 11, 10, 0, 0);
  const db = createDb(() => storage, { now: () => clock });
  const set = createUserExampleSet(db);
  const options = db.getStudyOptions(set.id);
  const rng = seeded(7);

  let session = S.createSession(set.cards, options, { subset: 'all', rng, now: clock, progress: db.getProgress(set.id) });
  db.saveSession(set.id, session);
  expect(S.counters(session).total).toBe(52);

  // Round 1: first question wrong, second "Weiss ich nicht", third wrong then overridden, rest correct.
  let i = 0;
  let overriddenQid = null;
  while (!S.isRoundOver(session)) {
    const q = S.current(session);
    const { expected, lang } = expectedFor(set, q);
    clock += 4000;
    let correct;
    if (i === 0 || i === 2) correct = grade('voll daneben', expected, options.tolerance, lang).correct;
    else if (i === 1) correct = false; // "Weiss ich nicht"
    else {
      const r = grade(expected, expected, options.tolerance, lang);
      expect(r.correct).toBe(true);
      expect(r.exact).toBe(true);
      correct = r.correct;
    }
    expect(typeof correct).toBe('boolean');
    db.recordAnswer(set.id, q.cardId, correct, clock);
    session = S.answer(session, correct, clock);
    if (i === 2) {
      db.overrideLastAnswer(set.id, q.cardId);
      session = S.override(session, q.qid, clock);
      overriddenQid = q.qid;
    }
    db.saveSession(set.id, session);
    i++;
  }
  expect(i).toBe(52);
  const summary = S.roundSummary(session);
  expect(summary.total).toBe(52);
  expect(summary.incorrect).toBe(2);
  expect(summary.items.find((it) => it.qid === overriddenQid).correct).toBe(true);

  // Resume from storage in a fresh db instance (what a reload does).
  const db2 = createDb(() => storage, { now: () => clock });
  const restored = db2.getSession(set.id);
  expect(restored).toEqual(JSON.parse(JSON.stringify(session)));

  // Round 2 contains only the two misses.
  session = S.nextRound(restored, rng, clock);
  expect(session.round).toBe(2);
  expect(session.queue).toHaveLength(2);
  while (!S.isRoundOver(session)) {
    const q = S.current(session);
    const { expected, lang } = expectedFor(set, q);
    clock += 3000;
    db2.recordAnswer(set.id, q.cardId, true, clock);
    session = S.answer(session, grade(expected, expected, options.tolerance, lang).correct, clock);
  }
  expect(S.isFinished(session)).toBe(true);
  session = S.nextRound(session, rng, clock);
  db2.saveSession(set.id, session);
  expect(typeof db2.getSession(set.id).finishedAt).toBe('number');

  const stats = S.finalStats(session);
  expect(stats.total).toBe(52);
  expect(stats.firstTryCorrect).toBe(50);
  expect(stats.missedCardIds).toHaveLength(2);

  // Progress: 50 answered correctly once (learning), the 2 missed ones correct once after a miss.
  const progress = db2.getProgress(set.id);
  const sp = setProgress(db2.getSet(set.id), progress);
  expect(sp.total).toBe(52);
  expect(sp.mastered).toBe(0);
  expect(sp.learning).toBe(52);
  expect(cardStatus(progress[set.cards[3].id])).toBe('learning');
  expect(db2.getActivity()['2026-10-11']).toBe(54);
  expect(studyStreak(db2.getActivity(), clock).today).toBe(54);

  // "Falsche nochmal üben": a new session over just the missed cards.
  const retry = S.createSession(db2.getSet(set.id).cards, options, { subset: { cardIds: stats.missedCardIds }, rng, now: clock });
  expect(retry.order).toHaveLength(2);
});

test('write flow: second correct answer in a row masters a card; learning subset skips it', () => {
  const db = createDb(() => memoryStorage());
  const set = createUserExampleSet(db);
  const card = set.cards[10];
  db.recordAnswer(set.id, card.id, true);
  db.recordAnswer(set.id, card.id, true);
  const progress = db.getProgress(set.id);
  expect(cardStatus(progress[card.id])).toBe('mastered');
  const learning = S.createSession(set.cards, db.getStudyOptions(set.id), { subset: 'learning', progress, rng: seeded(1) });
  expect(learning.order).toHaveLength(51);
  expect(learning.order.some((qid) => learning.questions[qid].cardId === card.id)).toBe(false);
});

test('write flow: options from updateStudyOptions drive direction and grading', () => {
  const db = createDb(() => memoryStorage());
  const set = createUserExampleSet(db);
  const options = db.updateStudyOptions(set.id, { answerWith: 'both', shuffle: false, tolerance: { articles: false } });
  const session = S.createSession(set.cards, options, { rng: seeded(3) });
  expect(session.order).toHaveLength(104);
  expect(session.questions[session.order[0]].ask).toBe('term');
  expect(session.questions[session.order[52]].ask).toBe('definition');
  // "l'homme" without the article is wrong when the article tolerance is off.
  const r = grade('homme', "l'homme", options.tolerance, 'fr');
  expect(r.correct).toBe(false);
  expect(r.hint).toBe('missingArticle');
  expect(db.getStudyOptions(set.id).tolerance.articles).toBe(false);
  const on = grade('homme', "l'homme", DEFAULT_TOLERANCE, 'fr');
  expect(on.correct).toBe(true);
  expect(on.notes).toContain('article');
});

test('grading results map onto the UI label tables', () => {
  const samples = [
    ['monsieur', 'le monsieur, messieurs', 'fr'],
    ['Herr', 'der Herr', 'de'],
    ['den Herr', 'der Herr', 'de'],
    ['appeler', "s'appeler", 'fr'],
    ['Strasse', 'die Straße', 'de'],
    ['hasslich', 'hässlich', 'de'],
    ['marie', 'marié, mariée', 'fr'],
    ['ernst', 'ernst, ernsthaft', 'de'],
    ['etw. tun', 'etwas tun', 'de'],
    ['verheiratte', 'verheiratet', 'de'],
  ];
  for (const [given, expected, lang] of samples) {
    const r = grade(given, expected, DEFAULT_TOLERANCE, lang);
    for (const n of r.notes) expect(typeof NOTE_LABELS[n]).toBe('string');
    if (r.hint) expect(typeof HINT_LABELS[r.hint]).toBe('string');
    expect(typeof r.expectedDisplay).toBe('string');
  }
});

test('editing cards: structural changes clear the session; text edits keep it', () => {
  const db = createDb(() => memoryStorage());
  const set = createUserExampleSet(db);
  const session = S.createSession(set.cards, db.getStudyOptions(set.id), { rng: seeded(5) });
  db.saveSession(set.id, session);
  db.updateCard(set.id, set.cards[0].id, { definition: 'der Herr, die Herren' });
  expect(db.getSession(set.id)).toEqual(JSON.parse(JSON.stringify(session)));
  const removed = set.cards[1].id;
  db.updateSet(set.id, { cards: set.cards.filter((c) => c.id !== removed) });
  expect(db.getSession(set.id)).toBe(null);
  // A screen that keeps its in-memory session prunes the deleted card itself.
  const pruned = S.removeCard(session, removed);
  expect(pruned.order).toHaveLength(51);
});

test('undo after delete: the screens\' minimal merge import restores set and progress', () => {
  const db = createDb(() => memoryStorage());
  db.updateSettings({ theme: 'dark' });
  const set = createUserExampleSet(db);
  db.recordAnswer(set.id, set.cards[0].id, true);
  const snapshot = { set: db.getSet(set.id), progress: db.getProgress(set.id) };
  db.deleteSet(set.id);
  expect(db.getSet(set.id)).toBe(null);
  // Same payload shape as dashboard.js restore() and set.js restoreSet().
  const res = db.importAll(
    { app: 'wortschatz', version: 1, sets: [snapshot.set], progress: { [set.id]: snapshot.progress }, activity: {} },
    { mode: 'merge' },
  );
  expect(res.setsAdded).toBe(1);
  expect(db.getSet(set.id).cards).toHaveLength(52);
  expect(db.getProgress(set.id)[set.cards[0].id].correct).toBe(1);
  expect(db.getSettings().theme).toBe('dark');
});

await run('integration.test.js');
