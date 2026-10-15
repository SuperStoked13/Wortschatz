import { test, expect, run } from './harness.js';
import { createDb, memoryStorage, db as defaultDb, DEFAULT_STUDY_OPTIONS, DEFAULT_SETTINGS } from '../src/store/db.js';
import { setToText, readJsonFile } from '../src/store/backup.js';
import { parseVocab } from '../src/core/parser.js';
import { dateKey } from '../src/lib/time.js';
import { DEFAULT_LEARN } from '../src/core/learn.js';

const P = 'wortschatz:v1:';

function setup(initial = null) {
  let t = 1000;
  const storage = memoryStorage(initial);
  const db = createDb(() => storage, { now: () => t });
  return {
    db,
    storage,
    tick(ms = 1000) {
      t += ms;
      return t;
    },
    at: () => t,
  };
}

const SAMPLE = [
  { term: 'le monsieur, messieurs', definition: 'der Herr' },
  { term: "l'homme", definition: 'der Mann' },
  { term: 'la femme', definition: 'die Frau', starred: true },
];

function codeOf(fn) {
  try {
    fn();
  } catch (e) {
    return e && e.code;
  }
  return 'did-not-throw';
}

function errorOf(fn) {
  try {
    fn();
  } catch (e) {
    return e;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Storage resolution & caching

test('storage is resolved lazily and only once', () => {
  let calls = 0;
  const storage = memoryStorage();
  const db = createDb(() => {
    calls++;
    return storage;
  });
  expect(calls).toBe(0);
  db.listSets();
  db.getSettings();
  db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  expect(calls).toBe(1);
});

test('default db instance reads globalThis.localStorage lazily', () => {
  const fake = memoryStorage();
  globalThis.localStorage = fake;
  try {
    const set = defaultDb.createSet({ title: 'Lazy', termLang: 'fr', cards: SAMPLE });
    expect(typeof fake.getItem(P + 'sets')).toBe('string');
    expect(defaultDb.getSet(set.id).title).toBe('Lazy');
  } finally {
    delete globalThis.localStorage;
  }
});

test('reads are cached per instance', () => {
  const inner = memoryStorage();
  let gets = 0;
  const spy = {
    getItem(k) {
      gets++;
      return inner.getItem(k);
    },
    setItem: (k, v) => inner.setItem(k, v),
    removeItem: (k) => inner.removeItem(k),
  };
  const db = createDb(() => spy);
  db.listSets();
  db.listSets();
  db.getSet('x');
  expect(gets).toBe(1);
});

test('unavailable storage falls back to memory', () => {
  const db = createDb(() => {
    throw new Error('SecurityError');
  });
  const set = db.createSet({ title: 'Offline', termLang: 'en', cards: SAMPLE });
  expect(db.getSet(set.id).title).toBe('Offline');
  const db2 = createDb(() => undefined);
  expect(db2.listSets()).toEqual([]);
});

// ---------------------------------------------------------------------------
// Sets CRUD

test('createSet stores a clean set', () => {
  const { db, storage, at } = setup();
  const set = db.createSet({
    title: '  Personen  ',
    termLang: 'fr',
    cards: [...SAMPLE, { term: '   ', definition: '' }, { term: ' calme ', definition: ' ruhig ' }],
  });
  expect(set.title).toBe('Personen');
  expect(set.description).toBe('');
  expect(set.termLang).toBe('fr');
  expect(set.defLang).toBe('de');
  expect(set.cards).toHaveLength(4);
  expect(set.cards[3]).toEqual({ id: set.cards[3].id, term: 'calme', definition: 'ruhig', starred: false });
  expect(set.cards[2].starred).toBe(true);
  expect(new Set(set.cards.map((c) => c.id)).size).toBe(4);
  expect(set.cards.every((c) => typeof c.id === 'string' && c.id.length >= 12)).toBe(true);
  expect(set.studyOptions).toBe(null);
  expect(set.createdAt).toBe(at());
  expect(set.updatedAt).toBe(at());
  expect(set.lastStudiedAt).toBe(null);
  expect(JSON.parse(storage.getItem(P + 'sets'))[0].id).toBe(set.id);
  expect(JSON.parse(storage.getItem(P + 'meta'))).toEqual({ schemaVersion: 1 });
});

test('createSet falls back to a default title and valid languages', () => {
  const { db } = setup();
  const set = db.createSet({ title: '   ', termLang: 'xx', defLang: 'yy', cards: [] });
  expect(set.title).toBe('Unbenanntes Lernset');
  expect(set.termLang).toBe('fr');
  expect(set.defLang).toBe('de');
  expect(set.cards).toEqual([]);
});

test('createSet assigns fresh card ids even if ids are passed', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'X', termLang: 'fr', cards: [{ id: 'fixed', term: 'a', definition: 'b' }] });
  expect(set.cards[0].id).not.toBe('fixed');
});

test('getSet returns copies and null for unknown ids', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const copy = db.getSet(set.id);
  copy.title = 'mutated';
  copy.cards.push({ id: 'z', term: 'z', definition: 'z', starred: false });
  expect(db.getSet(set.id).title).toBe('A');
  expect(db.getSet(set.id).cards).toHaveLength(3);
  expect(db.getSet('nope')).toBe(null);
});

test('listSets orders by most recent activity (studied or edited)', () => {
  const { db, tick } = setup();
  const a = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  tick();
  const b = db.createSet({ title: 'B', termLang: 'fr', cards: SAMPLE });
  tick();
  const c = db.createSet({ title: 'C', termLang: 'fr', cards: SAMPLE });
  expect(db.listSets().map((s) => s.title)).toEqual(['C', 'B', 'A']);
  db.recordAnswer(a.id, a.cards[0].id, true, tick());
  expect(db.listSets().map((s) => s.title)).toEqual(['A', 'C', 'B']);
  tick();
  db.updateSet(b.id, { title: 'B2' });
  expect(db.listSets().map((s) => s.title)).toEqual(['B2', 'A', 'C']);
  expect(c.id).not.toBe(a.id);
});

test('listSets breaks recency ties by creation time (newest first)', () => {
  const { db, tick } = setup();
  const older = db.createSet({ title: 'older', termLang: 'fr', cards: SAMPLE });
  const t = tick();
  db.createSet({ title: 'newer', termLang: 'fr', cards: SAMPLE });
  db.recordAnswer(older.id, older.cards[0].id, true, t);
  expect(db.listSets().map((s) => s.title)).toEqual(['newer', 'older']);
});

test('updateSet changes metadata and bumps updatedAt', () => {
  const { db, tick } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const t = tick();
  const next = db.updateSet(set.id, { title: ' Neu ', description: ' Kapitel 1 ', termLang: 'en', defLang: 'de' });
  expect(next.title).toBe('Neu');
  expect(next.description).toBe('Kapitel 1');
  expect(next.termLang).toBe('en');
  expect(next.updatedAt).toBe(t);
  expect(next.createdAt).toBe(1000);
  expect(db.getSet(set.id).title).toBe('Neu');
});

test('updateSet ignores invalid languages and throws NOT_FOUND for unknown sets', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  expect(db.updateSet(set.id, { termLang: 'klingon' }).termLang).toBe('fr');
  expect(codeOf(() => db.updateSet('missing', { title: 'x' }))).toBe('NOT_FOUND');
});

test('updateSet preserves card ids, assigns new ids and keeps stars', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const [c1, c2, c3] = set.cards;
  const next = db.updateSet(set.id, {
    cards: [
      { id: c3.id, term: ' la femme ', definition: 'die Frau, das Weib' },
      { id: c1.id, term: c1.term, definition: c1.definition, starred: true },
      { term: 'la dame', definition: 'die Dame' },
      { id: c2.id, term: '', definition: '  ' },
    ],
  });
  expect(next.cards).toHaveLength(3);
  expect(next.cards[0].id).toBe(c3.id);
  expect(next.cards[0].term).toBe('la femme');
  expect(next.cards[0].definition).toBe('die Frau, das Weib');
  expect(next.cards[0].starred).toBe(true);
  expect(next.cards[1].id).toBe(c1.id);
  expect(next.cards[1].starred).toBe(true);
  expect([c1.id, c2.id, c3.id]).not.toContain(next.cards[2].id);
  expect(next.cards.map((c) => c.id)).not.toContain(c2.id);
});

test('updateSet de-duplicates repeated card ids', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const id = set.cards[0].id;
  const next = db.updateSet(set.id, {
    cards: [
      { id, term: 'a', definition: 'b' },
      { id, term: 'c', definition: 'd' },
    ],
  });
  expect(next.cards[0].id).toBe(id);
  expect(next.cards[1].id).not.toBe(id);
});

test('updateSet prunes progress of removed cards', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const [c1, c2] = set.cards;
  db.recordAnswer(set.id, c1.id, true);
  db.recordAnswer(set.id, c2.id, false);
  db.updateSet(set.id, { cards: [c1] });
  const progress = db.getProgress(set.id);
  expect(Object.keys(progress)).toEqual([c1.id]);
  expect(progress[c1.id].correct).toBe(1);
});

test('updateSet clears the session only on structural card changes', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const state = { v: 1, round: 1, queue: ['x'] };

  db.saveSession(set.id, state);
  db.updateSet(set.id, { cards: set.cards.map((c) => ({ ...c, definition: c.definition + '!' })) });
  expect(db.getSession(set.id)).toEqual(state);

  db.updateSet(set.id, { cards: [...set.cards].reverse() });
  expect(db.getSession(set.id)).toEqual(state);

  db.updateSet(set.id, { title: 'Nur Titel' });
  expect(db.getSession(set.id)).toEqual(state);

  db.updateSet(set.id, { cards: [...set.cards, { term: 'neu', definition: 'new' }] });
  expect(db.getSession(set.id)).toBe(null);

  const current = db.getSet(set.id);
  db.saveSession(set.id, state);
  db.updateSet(set.id, { cards: current.cards.slice(1) });
  expect(db.getSession(set.id)).toBe(null);
});

test('deleteSet removes the set, its progress and its session', () => {
  const { db, storage } = setup();
  const keep = db.createSet({ title: 'keep', termLang: 'fr', cards: SAMPLE });
  const set = db.createSet({ title: 'gone', termLang: 'fr', cards: SAMPLE });
  db.recordAnswer(set.id, set.cards[0].id, true);
  db.saveSession(set.id, { v: 1 });
  expect(db.deleteSet(set.id)).toBe(true);
  expect(db.getSet(set.id)).toBe(null);
  expect(db.listSets().map((s) => s.id)).toEqual([keep.id]);
  expect(storage.getItem(P + 'progress:' + set.id)).toBe(null);
  expect(storage.getItem(P + 'session:' + set.id)).toBe(null);
  expect(db.deleteSet('unknown')).toBe(false);
});

test('snapshotSet + restoreSet undo a deleteSet, including progress and the running session', () => {
  const { db, storage } = setup();
  const keep = db.createSet({ title: 'keep', termLang: 'fr', cards: SAMPLE });
  const set = db.createSet({ title: 'gone', termLang: 'fr', cards: SAMPLE });
  db.recordAnswer(set.id, set.cards[0].id, true);
  const session = { v: 1, round: 1, queue: ['b:t', 'c:t'], roundAnswered: [{ qid: 'a:t', correct: true }], finishedAt: null };
  db.saveSession(set.id, session);
  const before = { set: db.getSet(set.id), progress: db.getProgress(set.id) };

  const snapshot = db.snapshotSet(set.id);
  expect(JSON.parse(JSON.stringify(snapshot))).toEqual(snapshot);
  db.deleteSet(set.id);
  expect(db.getSession(set.id)).toBe(null);

  let notified = 0;
  const off = db.subscribe(() => notified++);
  const restored = db.restoreSet(snapshot);
  off();
  expect(notified).toBe(1);
  expect(restored).toEqual(before.set);
  expect(db.getSet(set.id)).toEqual(before.set);
  expect(db.getProgress(set.id)).toEqual(before.progress);
  expect(db.getSession(set.id)).toEqual(session);
  expect(db.listSets().map((s) => s.id).sort()).toEqual([keep.id, set.id].sort());
  expect(storage.getItem(P + 'session:' + set.id) !== null).toBe(true);
});

test('restoreSet works without progress or session and rejects junk', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const snapshot = db.snapshotSet(set.id);
  expect(snapshot.progress).toEqual({});
  expect(snapshot.session).toBe(null);
  db.deleteSet(set.id);
  db.restoreSet(snapshot);
  expect(db.getSet(set.id).title).toBe('A');
  expect(db.getSession(set.id)).toBe(null);
  expect(db.snapshotSet('unknown')).toBe(null);
  expect(codeOf(() => db.restoreSet(null))).toBe('INVALID');
  expect(codeOf(() => db.restoreSet({ set: { title: 'ohne id' } }))).toBe('INVALID');
});

test('duplicateSet copies content with fresh ids and no progress', () => {
  const { db, tick } = setup();
  const set = db.createSet({ title: 'Original', description: 'd', termLang: 'en', cards: SAMPLE });
  db.updateStudyOptions(set.id, { answerWith: 'both' });
  db.recordAnswer(set.id, set.cards[0].id, true);
  const t = tick();
  const copy = db.duplicateSet(set.id);
  expect(copy.title).toBe('Original (Kopie)');
  expect(copy.id).not.toBe(set.id);
  expect(copy.description).toBe('d');
  expect(copy.termLang).toBe('en');
  expect(copy.cards.map((c) => c.term)).toEqual(set.cards.map((c) => c.term));
  expect(copy.cards.map((c) => c.starred)).toEqual([false, false, true]);
  expect(copy.cards.some((c) => set.cards.some((o) => o.id === c.id))).toBe(false);
  expect(db.getProgress(copy.id)).toEqual({});
  expect(copy.lastStudiedAt).toBe(null);
  expect(copy.createdAt).toBe(t);
  expect(db.getStudyOptions(copy.id).answerWith).toBe('both');
  expect(db.listSets()).toHaveLength(2);
  expect(codeOf(() => db.duplicateSet('missing'))).toBe('NOT_FOUND');
});

// ---------------------------------------------------------------------------
// Cards

test('updateCard edits one card and validates input', () => {
  const { db, tick } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const card = set.cards[1];
  const t = tick();
  const next = db.updateCard(set.id, card.id, { definition: '  der Mensch ' });
  expect(next).toEqual({ id: card.id, term: "l'homme", definition: 'der Mensch', starred: false });
  expect(db.getSet(set.id).cards[1].definition).toBe('der Mensch');
  expect(db.getSet(set.id).updatedAt).toBe(t);
  expect(codeOf(() => db.updateCard(set.id, card.id, { term: ' ', definition: '' }))).toBe('INVALID');
  expect(codeOf(() => db.updateCard(set.id, 'nope', { term: 'x' }))).toBe('NOT_FOUND');
  expect(codeOf(() => db.updateCard('nope', card.id, { term: 'x' }))).toBe('NOT_FOUND');
  expect(db.updateCard(set.id, card.id, { starred: true }).starred).toBe(true);
});

test('toggleStar flips and persists the star without reordering', () => {
  const { db, tick } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  tick();
  expect(db.toggleStar(set.id, set.cards[0].id)).toBe(true);
  expect(db.getSet(set.id).cards[0].starred).toBe(true);
  expect(db.toggleStar(set.id, set.cards[0].id)).toBe(false);
  expect(db.toggleStar(set.id, set.cards[2].id)).toBe(false);
  expect(db.getSet(set.id).updatedAt).toBe(1000);
  expect(codeOf(() => db.toggleStar(set.id, 'nope'))).toBe('NOT_FOUND');
});

// ---------------------------------------------------------------------------
// Progress

test('recordAnswer updates progress, lastStudiedAt and activity', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const id = set.cards[0].id;
  const at = new Date(2026, 9, 11, 10, 0).getTime();
  const p1 = db.recordAnswer(set.id, id, true, at);
  expect(p1).toEqual({ correct: 1, incorrect: 0, streak: 1, streakBefore: 0, lastResult: 'correct', lastAnsweredAt: at });
  const p2 = db.recordAnswer(set.id, id, false, at + 1000);
  expect(p2.streak).toBe(0);
  expect(p2.streakBefore).toBe(1);
  expect(p2.incorrect).toBe(1);
  db.recordAnswer(set.id, set.cards[1].id, true, at + 2000);
  expect(db.getSet(set.id).lastStudiedAt).toBe(at + 2000);
  expect(db.getActivity()).toEqual({ [dateKey(at)]: 3 });
  const next = new Date(2026, 9, 12, 9, 0).getTime();
  db.recordAnswer(set.id, id, true, next);
  expect(db.getActivity()[dateKey(next)]).toBe(1);
  expect(Object.keys(db.getProgress(set.id))).toHaveLength(2);
});

test('recordAnswer drives status: new -> learning -> mastered -> miss -> learning', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const id = set.cards[0].id;
  expect(db.getProgress(set.id)[id]).toBe(undefined);
  expect(db.recordAnswer(set.id, id, true).streak).toBe(1);
  expect(db.recordAnswer(set.id, id, true).streak).toBe(2);
  const miss = db.recordAnswer(set.id, id, false);
  expect(miss.streak).toBe(0);
  expect(miss.streakBefore).toBe(2);
  expect(miss.correct).toBe(2);
  expect(miss.incorrect).toBe(1);
});

test('recordAnswer rejects unknown sets and cards', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  expect(codeOf(() => db.recordAnswer('nope', set.cards[0].id, true))).toBe('NOT_FOUND');
  expect(codeOf(() => db.recordAnswer(set.id, 'nope', true))).toBe('NOT_FOUND');
  expect(db.getActivity()).toEqual({});
});

test('overrideLastAnswer turns the last miss into a correct answer', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const id = set.cards[0].id;
  db.recordAnswer(set.id, id, true, 5000);
  db.recordAnswer(set.id, id, false, 6000);
  const o = db.overrideLastAnswer(set.id, id);
  expect(o).toEqual({ correct: 2, incorrect: 0, streak: 2, streakBefore: 1, lastResult: 'correct', lastAnsweredAt: 6000 });
  expect(db.getProgress(set.id)[id]).toEqual(o);
  // A second override does nothing.
  expect(db.overrideLastAnswer(set.id, id)).toEqual(o);
  expect(db.getActivity()[dateKey(5000)]).toBe(2);
});

test('overrideLastAnswer is a no-op after a correct answer or without progress', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const id = set.cards[0].id;
  const fresh = db.overrideLastAnswer(set.id, id);
  expect(fresh.correct).toBe(0);
  expect(fresh.lastResult).toBe(null);
  expect(db.getProgress(set.id)).toEqual({});
  const p = db.recordAnswer(set.id, id, true);
  expect(db.overrideLastAnswer(set.id, id)).toEqual(p);
});

test('resetProgress clears progress and session but keeps the set', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  db.recordAnswer(set.id, set.cards[0].id, true);
  db.saveSession(set.id, { v: 1 });
  db.resetProgress(set.id);
  expect(db.getProgress(set.id)).toEqual({});
  expect(db.getSession(set.id)).toBe(null);
  expect(db.getSet(set.id).cards).toHaveLength(3);
});

// ---------------------------------------------------------------------------
// Sessions

test('sessions round-trip as copies', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  expect(db.getSession(set.id)).toBe(null);
  const state = { v: 1, round: 2, queue: ['a:t'], misses: { 'a:t': 1 }, finishedAt: null };
  db.saveSession(set.id, state);
  state.round = 99;
  const loaded = db.getSession(set.id);
  expect(loaded.round).toBe(2);
  loaded.queue.push('mutated');
  expect(db.getSession(set.id).queue).toEqual(['a:t']);
  db.clearSession(set.id);
  expect(db.getSession(set.id)).toBe(null);
});

test('saveSession ignores unknown sets and null clears', () => {
  const { db, storage } = setup();
  db.saveSession('ghost', { v: 1 });
  expect(storage.getItem(P + 'session:ghost')).toBe(null);
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  db.saveSession(set.id, { v: 1 });
  db.saveSession(set.id, null);
  expect(db.getSession(set.id)).toBe(null);
});

// ---------------------------------------------------------------------------
// Learn sessions (key learn:<setId>, same lifecycle as Write sessions)

const LEARN_STATE = { v: 1, round: 2, order: ['a', 'b'], stage: { a: 1, b: 0 }, queue: [{ qid: '2.1:a', cardId: 'a', type: 'written', ask: 'term' }], finishedAt: null };

test('Learn sessions round-trip as copies under learn:<setId>', () => {
  const { db, storage } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  expect(db.getLearn(set.id)).toBe(null);
  const state = JSON.parse(JSON.stringify(LEARN_STATE));
  db.saveLearn(set.id, state);
  state.round = 99;
  const loaded = db.getLearn(set.id);
  expect(loaded).toEqual(LEARN_STATE);
  loaded.order.push('mutated');
  expect(db.getLearn(set.id).order).toEqual(['a', 'b']);
  expect(JSON.parse(storage.getItem(P + 'learn:' + set.id))).toEqual(LEARN_STATE);
  db.clearLearn(set.id);
  expect(db.getLearn(set.id)).toBe(null);
  expect(storage.getItem(P + 'learn:' + set.id)).toBe(null);
});

test('saveLearn ignores unknown sets; a non-object clears', () => {
  const { db, storage } = setup();
  db.saveLearn('ghost', LEARN_STATE);
  expect(storage.getItem(P + 'learn:ghost')).toBe(null);
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  for (const junk of [null, undefined, 'state', [1, 2]]) {
    db.saveLearn(set.id, LEARN_STATE);
    db.saveLearn(set.id, junk);
    expect(db.getLearn(set.id)).toBe(null);
  }
});

test('Learn and Write sessions are stored independently', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const session = { v: 1, round: 1, queue: ['x'] };
  db.saveSession(set.id, session);
  db.saveLearn(set.id, LEARN_STATE);
  db.clearSession(set.id);
  expect(db.getLearn(set.id)).toEqual(LEARN_STATE);
  db.saveSession(set.id, session);
  db.clearLearn(set.id);
  expect(db.getSession(set.id)).toEqual(session);
});

test('saveLearn / clearLearn notify subscribers with the learn key', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const events = [];
  const off = db.subscribe((e) => events.push(e));
  db.saveLearn(set.id, LEARN_STATE);
  db.clearLearn(set.id);
  off();
  expect(events).toEqual([
    { type: 'local', keys: ['learn:' + set.id] },
    { type: 'local', keys: ['learn:' + set.id] },
  ]);
});

test('updateSet clears the Learn session exactly when it clears the Write session', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const session = { v: 1, round: 1, queue: ['x'] };
  const both = () => [db.getSession(set.id), db.getLearn(set.id)];
  db.saveSession(set.id, session);
  db.saveLearn(set.id, LEARN_STATE);

  // Text edits, reordering, metadata and options keep both.
  db.updateSet(set.id, { cards: set.cards.map((c) => ({ ...c, term: c.term + '!' })) });
  db.updateSet(set.id, { cards: [...db.getSet(set.id).cards].reverse() });
  db.updateSet(set.id, { title: 'Nur Titel', description: 'neu' });
  db.updateStudyOptions(set.id, { learn: { roundSize: 10 } });
  db.updateCard(set.id, set.cards[0].id, { definition: 'der Herr (Anrede)' });
  db.toggleStar(set.id, set.cards[1].id);
  expect(both()).toEqual([session, LEARN_STATE]);

  // A card added: both end.
  db.updateSet(set.id, { cards: [...db.getSet(set.id).cards, { term: 'neu', definition: 'new' }] });
  expect(both()).toEqual([null, null]);

  // A card removed: both end.
  db.saveSession(set.id, session);
  db.saveLearn(set.id, LEARN_STATE);
  db.updateSet(set.id, { cards: db.getSet(set.id).cards.slice(1) });
  expect(both()).toEqual([null, null]);

  // Only a Learn session running: it ends on its own too.
  db.saveLearn(set.id, LEARN_STATE);
  db.updateSet(set.id, { cards: db.getSet(set.id).cards.slice(1) });
  expect(db.getLearn(set.id)).toBe(null);
});

test('recording answers keeps the Learn session', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  db.saveLearn(set.id, LEARN_STATE);
  db.recordAnswer(set.id, set.cards[0].id, false);
  db.overrideLastAnswer(set.id, set.cards[0].id);
  expect(db.getLearn(set.id)).toEqual(LEARN_STATE);
});

test('deleteSet and resetProgress remove the Learn session', () => {
  const { db, storage } = setup();
  const keep = db.createSet({ title: 'keep', termLang: 'fr', cards: SAMPLE });
  const gone = db.createSet({ title: 'gone', termLang: 'fr', cards: SAMPLE });
  db.saveLearn(keep.id, LEARN_STATE);
  db.saveLearn(gone.id, LEARN_STATE);
  db.deleteSet(gone.id);
  expect(storage.getItem(P + 'learn:' + gone.id)).toBe(null);
  expect(db.getLearn(keep.id)).toEqual(LEARN_STATE);

  db.recordAnswer(keep.id, keep.cards[0].id, true);
  db.saveSession(keep.id, { v: 1 });
  db.resetProgress(keep.id);
  expect(db.getProgress(keep.id)).toEqual({});
  expect(db.getSession(keep.id)).toBe(null);
  expect(db.getLearn(keep.id)).toBe(null);
  expect(storage.getItem(P + 'learn:' + keep.id)).toBe(null);
});

test('snapshotSet + restoreSet bring the Learn session back with the set', () => {
  const { db, storage } = setup();
  const set = db.createSet({ title: 'gone', termLang: 'fr', cards: SAMPLE });
  db.saveLearn(set.id, LEARN_STATE);
  const snapshot = db.snapshotSet(set.id);
  expect(snapshot.learn).toEqual(LEARN_STATE);
  expect(snapshot.session).toBe(null);
  db.deleteSet(set.id);
  expect(db.getLearn(set.id)).toBe(null);
  db.restoreSet(JSON.parse(JSON.stringify(snapshot)));
  expect(db.getLearn(set.id)).toEqual(LEARN_STATE);
  expect(db.getSession(set.id)).toBe(null);

  // A snapshot without a Learn session restores none (and drops a stale one).
  const plain = db.snapshotSet(set.id);
  db.clearLearn(set.id);
  const bare = db.snapshotSet(set.id);
  expect(bare.learn).toBe(null);
  db.saveLearn(set.id, { v: 1, stale: true });
  db.restoreSet(bare);
  expect(db.getLearn(set.id)).toBe(null);
  expect(storage.getItem(P + 'learn:' + set.id)).toBe(null);
  expect(plain.learn).toEqual(LEARN_STATE);
});

// ---------------------------------------------------------------------------
// Per-card progress reset

test('resetCardProgress forgets just those cards and ends both sessions', () => {
  const { db, storage, tick } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const [c1, c2, c3] = set.cards.map((c) => c.id);
  db.recordAnswer(set.id, c1, true);
  db.recordAnswer(set.id, c1, true);
  db.recordAnswer(set.id, c2, false);
  db.recordAnswer(set.id, c3, true);
  const studied = db.getSet(set.id).lastStudiedAt;
  const activity = db.getActivity();
  db.saveSession(set.id, { v: 1 });
  db.saveLearn(set.id, LEARN_STATE);
  tick();

  const events = [];
  const off = db.subscribe((e) => events.push(e));
  expect(db.resetCardProgress(set.id, [c1, c2, c2, 'unknown'])).toBe(2);
  off();
  expect(events).toHaveLength(1);
  expect(Object.keys(db.getProgress(set.id))).toEqual([c3]);
  expect(db.getSession(set.id)).toBe(null);
  expect(db.getLearn(set.id)).toBe(null);
  // Set data, study date and activity stay as they were.
  expect(db.getSet(set.id).cards).toHaveLength(3);
  expect(db.getSet(set.id).lastStudiedAt).toBe(studied);
  expect(db.getActivity()).toEqual(activity);

  // The last entry removed: the key goes away.
  expect(db.resetCardProgress(set.id, [c3])).toBe(1);
  expect(db.getProgress(set.id)).toEqual({});
  expect(storage.getItem(P + 'progress:' + set.id)).toBe(null);
});

test('resetCardProgress without valid ids changes nothing', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  db.recordAnswer(set.id, set.cards[0].id, true);
  db.saveSession(set.id, { v: 1 });
  db.saveLearn(set.id, LEARN_STATE);
  const progress = db.getProgress(set.id);
  let notified = 0;
  const off = db.subscribe(() => notified++);
  for (const ids of [[], null, undefined, 'abc', [null, '', 7, {}]]) expect(db.resetCardProgress(set.id, ids)).toBe(0);
  off();
  expect(notified).toBe(0);
  expect(db.getProgress(set.id)).toEqual(progress);
  expect(db.getSession(set.id)).toEqual({ v: 1 });
  expect(db.getLearn(set.id)).toEqual(LEARN_STATE);
});

test('resetCardProgress of cards without progress still restarts the sessions', () => {
  const { db, storage } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  db.saveSession(set.id, { v: 1 });
  db.saveLearn(set.id, LEARN_STATE);
  expect(db.resetCardProgress(set.id, [set.cards[0].id])).toBe(0);
  expect(storage.getItem(P + 'progress:' + set.id)).toBe(null);
  expect(db.getSession(set.id)).toBe(null);
  expect(db.getLearn(set.id)).toBe(null);
  // Unknown sets are fine too.
  expect(db.resetCardProgress('ghost', ['x'])).toBe(0);
});

// ---------------------------------------------------------------------------
// Settings & study options

test('defaults are complete and frozen', () => {
  expect(DEFAULT_STUDY_OPTIONS.answerWith).toBe('term');
  expect(DEFAULT_STUDY_OPTIONS.tolerance.articles).toBe(true);
  expect(DEFAULT_STUDY_OPTIONS.tolerance.ignoreAccents).toBe(false);
  expect(DEFAULT_STUDY_OPTIONS.tolerance.typos).toBe(false);
  expect(DEFAULT_SETTINGS.theme).toBe('system');
  expect(DEFAULT_SETTINGS.study).toEqual(DEFAULT_STUDY_OPTIONS);
  expect(Object.isFrozen(DEFAULT_STUDY_OPTIONS.tolerance)).toBe(true);
  expect(Object.isFrozen(DEFAULT_SETTINGS)).toBe(true);
});

test('getSettings returns defaults and copies', () => {
  const { db } = setup();
  const s = db.getSettings();
  expect(s).toEqual({ theme: 'system', study: DEFAULT_STUDY_OPTIONS });
  s.study.tolerance.typos = true;
  expect(db.getSettings().study.tolerance.typos).toBe(false);
});

test('updateSettings deep-merges and ignores invalid values', () => {
  const { db } = setup();
  db.updateSettings({ theme: 'dark', study: { tolerance: { typos: true } } });
  const s = db.updateSettings({ study: { shuffle: false, answerWith: 'nonsense', tolerance: { ignoreCase: 'yes' } }, extra: 1 });
  expect(s.theme).toBe('dark');
  expect(s.study.shuffle).toBe(false);
  expect(s.study.answerWith).toBe('term');
  expect(s.study.tolerance.typos).toBe(true);
  expect(s.study.tolerance.ignoreCase).toBe(true);
  expect(s.study.tolerance.articles).toBe(true);
  expect(s.extra).toBe(undefined);
  expect(db.updateSettings({ theme: 'neon' }).theme).toBe('dark');
  expect(db.getSettings()).toEqual(s);
});

test('getStudyOptions merges defaults <- settings.study <- set.studyOptions', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  expect(db.getStudyOptions(set.id)).toEqual(DEFAULT_STUDY_OPTIONS);
  db.updateSettings({ study: { answerWith: 'definition', tolerance: { ignoreAccents: true } } });
  expect(db.getStudyOptions(set.id).answerWith).toBe('definition');
  const opts = db.updateStudyOptions(set.id, { answerWith: 'both', tolerance: { typos: true } });
  expect(opts.answerWith).toBe('both');
  expect(opts.tolerance.typos).toBe(true);
  expect(opts.tolerance.ignoreAccents).toBe(true);
  expect(opts.tolerance.articles).toBe(true);
  expect(db.getSet(set.id).studyOptions).toEqual({ answerWith: 'both', tolerance: { typos: true } });
  db.updateStudyOptions(set.id, { tolerance: { articles: false } });
  expect(db.getSet(set.id).studyOptions).toEqual({ answerWith: 'both', tolerance: { typos: true, articles: false } });
  // Settings changes still flow through for keys the set does not override.
  db.updateSettings({ study: { copyAnswer: false } });
  expect(db.getStudyOptions(set.id).copyAnswer).toBe(false);
  expect(db.getStudyOptions('unknown').answerWith).toBe('definition');
  expect(codeOf(() => db.updateStudyOptions('unknown', { shuffle: false }))).toBe('NOT_FOUND');
});

test('updateStudyOptions does not reorder the dashboard', () => {
  const { db, tick } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  tick();
  db.updateStudyOptions(set.id, { shuffle: false });
  expect(db.getSet(set.id).updatedAt).toBe(1000);
});

test('Learn options default to the engine defaults and are frozen', () => {
  expect(DEFAULT_STUDY_OPTIONS.learn).toEqual({ roundSize: 7, mc: true, written: true, retype: false });
  expect(DEFAULT_STUDY_OPTIONS.learn).toEqual(DEFAULT_LEARN);
  expect(Object.isFrozen(DEFAULT_STUDY_OPTIONS.learn)).toBe(true);
  expect(DEFAULT_SETTINGS.study.learn).toEqual(DEFAULT_LEARN);
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  expect(db.getStudyOptions(set.id).learn).toEqual(DEFAULT_LEARN);
  expect(db.getSettings().study.learn).toEqual(DEFAULT_LEARN);
  const copy = db.getStudyOptions(set.id);
  copy.learn.roundSize = 99;
  expect(db.getStudyOptions(set.id).learn.roundSize).toBe(7);
});

test('Learn options deep-merge: defaults <- settings.study.learn <- set.studyOptions.learn', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const s = db.updateSettings({ study: { learn: { roundSize: 10 } } });
  expect(s.study.learn).toEqual({ roundSize: 10, mc: true, written: true, retype: false });
  const opts = db.updateStudyOptions(set.id, { learn: { retype: true } });
  expect(opts.learn).toEqual({ roundSize: 10, mc: true, written: true, retype: true });
  expect(db.getSet(set.id).studyOptions).toEqual({ learn: { retype: true } });
  db.updateStudyOptions(set.id, { learn: { roundSize: 15 }, answerWith: 'both' });
  expect(db.getSet(set.id).studyOptions).toEqual({ learn: { retype: true, roundSize: 15 }, answerWith: 'both' });
  // Settings still flow through for keys the set does not override.
  db.updateSettings({ study: { learn: { roundSize: 5, retype: false } } });
  expect(db.getStudyOptions(set.id).learn).toEqual({ roundSize: 15, mc: true, written: true, retype: true });
  expect(db.getStudyOptions('unknown').learn).toEqual({ roundSize: 5, mc: true, written: true, retype: false });
  // Other options are untouched by learn patches.
  expect(db.getStudyOptions(set.id).tolerance).toEqual(DEFAULT_STUDY_OPTIONS.tolerance);
});

test('invalid Learn option values are ignored', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  for (const roundSize of [0, -3, 7.5, '10', 51, Infinity, NaN, null]) {
    expect(db.updateStudyOptions(set.id, { learn: { roundSize } }).learn.roundSize).toBe(7);
  }
  expect(db.updateStudyOptions(set.id, { learn: { mc: 'no', written: 0, retype: 'yes', bogus: true } }).learn).toEqual(DEFAULT_LEARN);
  expect(db.updateStudyOptions(set.id, { learn: 'all' }).learn).toEqual(DEFAULT_LEARN);
  expect(db.getSet(set.id).studyOptions).toBe(null);
  expect(db.updateStudyOptions(set.id, { learn: { roundSize: 1 } }).learn.roundSize).toBe(1);
  expect(db.updateStudyOptions(set.id, { learn: { roundSize: 50 } }).learn.roundSize).toBe(50);
});

test('Learn options never switch off both question types', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const learn = () => db.getStudyOptions(set.id).learn;

  db.updateStudyOptions(set.id, { learn: { mc: false } });
  expect([learn().mc, learn().written]).toEqual([false, true]);
  // Turning the other one off: the newest choice wins, the first comes back on.
  db.updateStudyOptions(set.id, { learn: { written: false } });
  expect([learn().mc, learn().written]).toEqual([true, false]);
  expect(db.getSet(set.id).studyOptions.learn).toEqual({ mc: true, written: false });
  // Both off in one patch is not a valid choice: that part is ignored.
  db.updateStudyOptions(set.id, { learn: { mc: false, written: false, roundSize: 10 } });
  expect(learn()).toEqual({ roundSize: 10, mc: true, written: false, retype: false });

  // Across layers the set's own choice wins over the defaults in Settings.
  db.updateSettings({ study: { learn: { mc: false } } });
  expect([learn().mc, learn().written]).toEqual([true, false]);
  db.updateSettings({ study: { learn: { written: false } } });
  expect(db.getSettings().study.learn).toEqual({ roundSize: 7, mc: true, written: false, retype: false });
  expect(db.updateSettings({ study: { learn: { mc: false, written: false } } }).study.learn).toEqual({ roundSize: 7, mc: true, written: false, retype: false });

  const other = db.createSet({ title: 'B', termLang: 'fr', cards: SAMPLE });
  db.updateStudyOptions(other.id, { learn: { mc: false } });
  expect(db.getStudyOptions(other.id).learn).toEqual({ roundSize: 7, mc: false, written: true, retype: false });
});

test('resetting the defaults in Settings resets the Learn options too', () => {
  const { db } = setup();
  db.updateSettings({ study: { learn: { roundSize: 15, mc: false, retype: true } } });
  expect(db.updateSettings({ study: DEFAULT_STUDY_OPTIONS }).study).toEqual(DEFAULT_STUDY_OPTIONS);
});

// ---------------------------------------------------------------------------
// Subscriptions & cross-tab sync

test('subscribe notifies once per write operation and unsubscribes', () => {
  const { db } = setup();
  const events = [];
  const off = db.subscribe((e) => events.push(e));
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  expect(events).toHaveLength(1);
  expect(events[0].type).toBe('local');
  expect(events[0].keys).toContain('sets');
  db.recordAnswer(set.id, set.cards[0].id, true);
  expect(events).toHaveLength(2);
  expect(events[1].keys).toContain('progress:' + set.id);
  expect(events[1].keys).toContain('activity');
  db.listSets();
  db.getSettings();
  expect(events).toHaveLength(2);
  off();
  db.updateSettings({ theme: 'light' });
  expect(events).toHaveLength(2);
});

test('a throwing subscriber does not break writes or other subscribers', () => {
  const { db } = setup();
  let calls = 0;
  db.subscribe(() => {
    throw new Error('boom');
  });
  db.subscribe(() => calls++);
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  expect(calls).toBe(1);
  expect(db.getSet(set.id).title).toBe('A');
});

test('storage events from other tabs invalidate the cache', () => {
  const handlers = [];
  const removed = [];
  globalThis.addEventListener = (type, fn) => handlers.push({ type, fn });
  globalThis.removeEventListener = (type, fn) => removed.push({ type, fn });
  try {
    const { db, storage } = setup();
    const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
    expect(handlers).toHaveLength(0);
    const events = [];
    const off = db.subscribe((e) => events.push(e));
    expect(handlers).toHaveLength(1);
    expect(handlers[0].type).toBe('storage');
    // A second subscriber does not attach another listener.
    const off2 = db.subscribe(() => {});
    expect(handlers).toHaveLength(1);

    // Another tab renames the set.
    const raw = JSON.parse(storage.getItem(P + 'sets'));
    raw[0].title = 'Aus anderem Tab';
    storage.setItem(P + 'sets', JSON.stringify(raw));
    expect(db.getSet(set.id).title).toBe('A');
    handlers[0].fn({ key: P + 'sets', storageArea: storage });
    expect(db.getSet(set.id).title).toBe('Aus anderem Tab');
    expect(events).toEqual([{ type: 'external', keys: ['sets'] }]);

    // Foreign keys and other storage areas are ignored.
    handlers[0].fn({ key: 'other-app', storageArea: storage });
    handlers[0].fn({ key: P + 'sets', storageArea: memoryStorage() });
    expect(events).toHaveLength(1);

    // storage.clear() in another tab (key === null) drops everything.
    storage.clear();
    handlers[0].fn({ key: null, storageArea: storage });
    expect(db.listSets()).toEqual([]);
    expect(events[1]).toEqual({ type: 'external', keys: null });

    off();
    expect(removed).toHaveLength(0);
    off2();
    expect(removed).toHaveLength(1);
    expect(removed[0].fn).toBe(handlers[0].fn);
  } finally {
    delete globalThis.addEventListener;
    delete globalThis.removeEventListener;
  }
});

// ---------------------------------------------------------------------------
// Backup export / import

function seeded() {
  const env = setup();
  const { db, tick } = env;
  const a = db.createSet({ title: 'Personen', termLang: 'fr', cards: SAMPLE });
  tick();
  const b = db.createSet({ title: 'Farben', termLang: 'en', cards: [{ term: 'red', definition: 'rot' }] });
  db.recordAnswer(a.id, a.cards[0].id, true, new Date(2026, 9, 10, 12).getTime());
  db.recordAnswer(a.id, a.cards[1].id, false, new Date(2026, 9, 11, 12).getTime());
  db.updateSettings({ theme: 'dark', study: { tolerance: { typos: true } } });
  db.updateStudyOptions(b.id, { answerWith: 'definition' });
  db.saveSession(a.id, { v: 1, round: 1 });
  return { ...env, a, b };
}

test('exportAll has the documented shape', () => {
  const { db, a, at } = seeded();
  const data = db.exportAll();
  expect(data.app).toBe('wortschatz');
  expect(data.version).toBe(1);
  expect(data.exportedAt).toBe(at());
  expect(data.sets).toHaveLength(2);
  expect(Object.keys(data.progress)).toEqual([a.id]);
  expect(data.settings.theme).toBe('dark');
  expect(data.activity).toEqual({ '2026-10-10': 1, '2026-10-11': 1 });
  expect(JSON.parse(JSON.stringify(data))).toEqual(data);
});

test('export -> import (replace) round-trips into an empty db', () => {
  const { db, a, b } = seeded();
  const data = JSON.parse(JSON.stringify(db.exportAll()));
  const target = setup().db;
  const result = target.importAll(data, { mode: 'replace' });
  expect(result).toEqual({ setsAdded: 2, setsUpdated: 0 });
  expect(target.listSets()).toEqual(db.listSets());
  expect(target.getProgress(a.id)).toEqual(db.getProgress(a.id));
  expect(target.getSettings()).toEqual(db.getSettings());
  expect(target.getActivity()).toEqual(db.getActivity());
  expect(target.getStudyOptions(b.id).answerWith).toBe('definition');
  expect(target.getSession(a.id)).toBe(null);
});

test('import (merge) replaces same-id sets, adds new ones and keeps the rest', () => {
  const { db, a, b } = seeded();
  const backup = db.exportAll();
  const edited = JSON.parse(JSON.stringify(backup));
  edited.sets = edited.sets.filter((s) => s.id === a.id);
  edited.sets[0].title = 'Personen (Backup)';
  edited.sets.push({ id: 'brandnew', title: 'Neu', termLang: 'it', defLang: 'de', cards: [{ id: 'k1', term: 'ciao', definition: 'hallo' }] });
  edited.progress = {};
  edited.settings = { theme: 'light' };
  edited.activity = { '2026-10-11': 7, '2026-01-01': 2 };

  const result = db.importAll(edited, { mode: 'merge' });
  expect(result).toEqual({ setsAdded: 1, setsUpdated: 1 });
  expect(db.listSets()).toHaveLength(3);
  expect(db.getSet(a.id).title).toBe('Personen (Backup)');
  expect(db.getSet(b.id).title).toBe('Farben');
  expect(db.getSet('brandnew').cards[0]).toEqual({ id: 'k1', term: 'ciao', definition: 'hallo', starred: false });
  // The replaced set takes the backup's (empty) progress; its session is dropped.
  expect(db.getProgress(a.id)).toEqual({});
  expect(db.getSession(a.id)).toBe(null);
  // Settings stay local in merge mode; activity keeps the max per day.
  expect(db.getSettings().theme).toBe('dark');
  expect(db.getActivity()).toEqual({ '2026-10-10': 1, '2026-10-11': 7, '2026-01-01': 2 });
});

test('import (merge) is idempotent', () => {
  const { db } = seeded();
  const backup = db.exportAll();
  const first = db.importAll(backup);
  expect(first).toEqual({ setsAdded: 0, setsUpdated: 2 });
  const before = JSON.stringify([db.listSets(), db.getActivity()]);
  db.importAll(backup);
  expect(JSON.stringify([db.listSets(), db.getActivity()])).toBe(before);
});

test('import (replace) wipes previous sets, progress and sessions', () => {
  const { db, storage, a } = seeded();
  db.createSet({ title: 'Lokal', termLang: 'fr', cards: SAMPLE });
  storage.setItem(P + 'progress:orphan', '{}');
  const backup = {
    app: 'wortschatz',
    version: 1,
    sets: [{ id: 'only', title: 'Einzig', termLang: 'fr', defLang: 'de', cards: [{ id: 'c', term: 'la rue', definition: 'die Strasse' }] }],
    progress: { only: { c: { correct: 2, incorrect: 0, streak: 2, streakBefore: 1, lastResult: 'correct', lastAnsweredAt: 1 } } },
  };
  const result = db.importAll(backup, { mode: 'replace' });
  expect(result).toEqual({ setsAdded: 1, setsUpdated: 0 });
  expect(db.listSets().map((s) => s.id)).toEqual(['only']);
  expect(db.getProgress('only').c.streak).toBe(2);
  expect(storage.getItem(P + 'progress:' + a.id)).toBe(null);
  expect(storage.getItem(P + 'session:' + a.id)).toBe(null);
  expect(storage.getItem(P + 'progress:orphan')).toBe(null);
  expect(db.getSettings()).toEqual({ theme: 'system', study: DEFAULT_STUDY_OPTIONS });
  expect(db.getActivity()).toEqual({});
});

test('import drops progress for unknown cards and renames duplicate set ids', () => {
  const { db } = setup();
  const backup = {
    app: 'wortschatz',
    version: 1,
    sets: [
      { id: 'same', title: 'Eins', cards: [{ id: 'c1', term: 'a', definition: 'b' }] },
      { id: 'same', title: 'Zwei', cards: [{ id: 'c2', term: 'c', definition: 'd' }] },
    ],
    progress: { same: { c1: { correct: 1, streak: 1 }, ghost: { correct: 3, streak: 3 } } },
  };
  const result = db.importAll(backup);
  expect(result.setsAdded).toBe(2);
  const sets = db.listSets();
  expect(sets).toHaveLength(2);
  expect(new Set(sets.map((s) => s.id)).size).toBe(2);
  expect(Object.keys(db.getProgress('same'))).toEqual(['c1']);
});

test('importAll rejects invalid backups with German messages and changes nothing', () => {
  const { db } = seeded();
  const before = JSON.stringify(db.exportAll().sets);
  const invalid = [
    null,
    'text',
    [],
    { app: 'quizlet', sets: [] },
    { app: 'wortschatz', version: 2, sets: [] },
    { app: 'wortschatz', version: 'eins', sets: [] },
    { app: 'wortschatz', version: 1 },
    { app: 'wortschatz', version: 1, sets: [{ title: 'ohne Karten' }] },
    { app: 'wortschatz', version: 1, sets: ['kaputt'] },
    { app: 'wortschatz', version: 1, sets: [], progress: [] },
  ];
  for (const data of invalid) {
    const err = errorOf(() => db.importAll(data, { mode: 'replace' }));
    expect(err !== null).toBe(true);
    expect(err.code).toBe('INVALID_BACKUP');
    expect(typeof err.message).toBe('string');
    expect(err.message.includes('ß')).toBe(false);
  }
  expect(errorOf(() => db.importAll({ app: 'wortschatz', version: 2, sets: [] })).message).toContain('neueren Version');
  expect(errorOf(() => db.importAll({ app: 'x', sets: [] })).message).toContain('kein Wortschatz-Backup');
  expect(JSON.stringify(db.exportAll().sets)).toBe(before);
});

// A storage that, like localStorage, refuses writes once keys + values exceed `limit` chars.
function limitedStorage(limit) {
  const inner = memoryStorage();
  const size = () => {
    let n = 0;
    for (let i = 0; i < inner.length; i++) {
      const k = inner.key(i);
      n += k.length + inner.getItem(k).length;
    }
    return n;
  };
  return {
    getItem: (k) => inner.getItem(k),
    setItem(k, v) {
      const old = inner.getItem(k);
      const next = size() - (old === null ? 0 : k.length + old.length) + k.length + String(v).length;
      if (next > limit) {
        const e = new Error('The quota has been exceeded.');
        e.name = 'QuotaExceededError';
        throw e;
      }
      inner.setItem(k, v);
    },
    removeItem: (k) => inner.removeItem(k),
    key: (i) => inner.key(i),
    get length() {
      return inner.length;
    },
    size,
    dump() {
      const out = {};
      for (let i = 0; i < inner.length; i++) out[inner.key(i)] = inner.getItem(inner.key(i));
      return out;
    },
  };
}

function bigSet(id, n, prefix) {
  const cards = [];
  const progress = {};
  for (let i = 0; i < n; i++) {
    cards.push({ id: `${prefix}${i}`, term: `${prefix} terme numero ${i}`, definition: `${prefix} Begriff Nummer ${i}`, starred: false });
    progress[`${prefix}${i}`] = { correct: 2, incorrect: 1, streak: 2, streakBefore: 1, lastResult: 'correct', lastAnsweredAt: 5 };
  }
  return { set: { id, title: `Set ${id}`, termLang: 'fr', defLang: 'de', cards }, progress };
}

test('import (replace) frees the old data first, so a backup that fits on its own imports under a tight quota', () => {
  const a = bigSet('A', 150, 'a');
  const b = bigSet('B', 300, 'b');
  const backupB = { app: 'wortschatz', version: 1, sets: [b.set], progress: { B: b.progress } };
  // How much B needs in an empty store.
  const probe = limitedStorage(Infinity);
  createDb(() => probe).importAll(backupB, { mode: 'replace' });
  const needB = probe.size();

  const storage = limitedStorage(needB + 2000);
  const db = createDb(() => storage);
  db.importAll({ app: 'wortschatz', version: 1, sets: [a.set], progress: { A: a.progress } }, { mode: 'replace' });
  expect(storage.size() + needB > needB + 2000).toBe(true); // A and B never fit together

  const result = db.importAll(backupB, { mode: 'replace' });
  expect(result).toEqual({ setsAdded: 1, setsUpdated: 0 });
  const fresh = createDb(() => storage);
  expect(fresh.listSets().map((s) => [s.id, s.cards.length])).toEqual([['B', 300]]);
  expect(Object.keys(fresh.getProgress('B'))).toHaveLength(300);
  expect(storage.getItem(P + 'progress:A')).toBe(null);
});

test('a failed import (QUOTA) leaves every key exactly as it was', () => {
  const a = bigSet('A', 40, 'a');
  const b = bigSet('B', 200, 'b'); // its cards fit, its progress does not
  const storage = limitedStorage(30000);
  const db = createDb(() => storage);
  db.importAll({ app: 'wortschatz', version: 1, sets: [a.set], progress: { A: a.progress } }, { mode: 'replace' });
  db.updateSettings({ theme: 'dark' });
  db.saveSession('A', { v: 1, round: 2 });
  const before = storage.dump();

  for (const mode of ['replace', 'merge']) {
    const err = errorOf(() => db.importAll({ app: 'wortschatz', version: 1, sets: [b.set], progress: { B: b.progress }, settings: { theme: 'light' } }, { mode }));
    expect(err && err.code).toBe('QUOTA');
    const after = storage.dump();
    const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
    expect([...keys].filter((k) => before[k] !== after[k])).toEqual([]);
    // Neither this instance's cache nor a fresh reader sees half-imported data.
    for (const reader of [db, createDb(() => storage)]) {
      expect(reader.listSets().map((s) => s.id)).toEqual(['A']);
      expect(Object.keys(reader.getProgress('A'))).toHaveLength(40);
      expect(reader.getSession('A')).toEqual({ v: 1, round: 2 });
      expect(reader.getSettings().theme).toBe('dark');
    }
  }
  // The store still works normally afterwards.
  expect(db.updateSettings({ theme: 'light' }).theme).toBe('light');
});

test('clearAll removes all user data', () => {
  const { db, storage, a } = seeded();
  db.clearAll();
  expect(db.listSets()).toEqual([]);
  expect(db.getProgress(a.id)).toEqual({});
  expect(db.getSession(a.id)).toBe(null);
  expect(db.getActivity()).toEqual({});
  expect(db.getSettings().theme).toBe('system');
  expect(storage.getItem(P + 'progress:' + a.id)).toBe(null);
});

// ---------------------------------------------------------------------------
// Robustness

test('corrupt JSON in every key is treated as empty', () => {
  const garbage = '{not json';
  const { db } = setup({
    [P + 'sets']: garbage,
    [P + 'settings']: garbage,
    [P + 'activity']: garbage,
    [P + 'progress:s1']: garbage,
    [P + 'session:s1']: garbage,
    [P + 'meta']: garbage,
  });
  expect(db.listSets()).toEqual([]);
  expect(db.getSet('s1')).toBe(null);
  expect(db.getSettings()).toEqual({ theme: 'system', study: DEFAULT_STUDY_OPTIONS });
  expect(db.getActivity()).toEqual({});
  expect(db.getProgress('s1')).toEqual({});
  expect(db.getSession('s1')).toBe(null);
  expect(db.getStudyOptions('s1')).toEqual(DEFAULT_STUDY_OPTIONS);
  const set = db.createSet({ title: 'Neu', termLang: 'fr', cards: SAMPLE });
  expect(db.listSets()).toHaveLength(1);
  expect(db.getSet(set.id).cards).toHaveLength(3);
});

test('wrongly typed but valid JSON is sanitised', () => {
  const { db } = setup({
    [P + 'sets']: JSON.stringify([
      null,
      { title: 'ohne id', cards: [] },
      {
        id: 's1',
        title: 42,
        termLang: 'zz',
        cards: [{ id: 'c1', term: 'le nom', definition: 'der Name', starred: 'yes' }, 'junk', { term: '', definition: '' }],
        studyOptions: { answerWith: 'both', shuffle: 'no', tolerance: { typos: true, bogus: true } },
        createdAt: 'gestern',
      },
      { id: 's1', title: 'Duplikat', cards: [] },
    ]),
    [P + 'settings']: JSON.stringify({ theme: 7, study: { tolerance: 'none' } }),
    [P + 'activity']: JSON.stringify({ '2026-10-11': 3, '2026-10-12': -1, foo: 2, '2026-10-13': 'x' }),
    [P + 'progress:s1']: JSON.stringify({ c1: { correct: '2', streak: 2 }, c2: 'bad' }),
    [P + 'session:s1']: JSON.stringify([1, 2, 3]),
  });
  const sets = db.listSets();
  expect(sets).toHaveLength(1);
  const s = sets[0];
  expect(s.title).toBe('42');
  expect(s.termLang).toBe('fr');
  expect(s.cards).toEqual([{ id: 'c1', term: 'le nom', definition: 'der Name', starred: false }]);
  expect(s.studyOptions).toEqual({ answerWith: 'both', tolerance: { typos: true } });
  expect(typeof s.createdAt).toBe('number');
  expect(db.getSettings()).toEqual({ theme: 'system', study: DEFAULT_STUDY_OPTIONS });
  expect(db.getActivity()).toEqual({ '2026-10-11': 3 });
  expect(db.getProgress('s1')).toEqual({ c1: { correct: 0, incorrect: 0, streak: 2, streakBefore: 0, lastResult: null, lastAnsweredAt: null } });
  expect(db.getSession('s1')).toBe(null);
});

test('a throwing getItem is treated as missing data', () => {
  const db = createDb(() => ({
    getItem() {
      throw new Error('denied');
    },
    setItem() {},
    removeItem() {},
  }));
  expect(db.listSets()).toEqual([]);
  expect(db.getSettings().theme).toBe('system');
});

test('quota errors surface as code QUOTA with a German message', () => {
  const inner = memoryStorage();
  let full = false;
  const storage = {
    getItem: (k) => inner.getItem(k),
    setItem(k, v) {
      if (full) {
        const e = new Error('The quota has been exceeded.');
        e.name = 'QuotaExceededError';
        throw e;
      }
      inner.setItem(k, v);
    },
    removeItem: (k) => inner.removeItem(k),
  };
  const db = createDb(() => storage);
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  full = true;
  const err = errorOf(() => db.createSet({ title: 'B', termLang: 'fr', cards: SAMPLE }));
  expect(err.code).toBe('QUOTA');
  expect(err.message).toContain('Speicher');
  expect(err.message.includes('ß')).toBe(false);
  expect(err.cause.name).toBe('QuotaExceededError');
  // The cache stays consistent with what is actually stored.
  expect(db.listSets().map((s) => s.title)).toEqual(['A']);
  expect(codeOf(() => db.updateSet(set.id, { title: 'Neu' }))).toBe('QUOTA');
  expect(db.getSet(set.id).title).toBe('A');
  expect(codeOf(() => db.recordAnswer(set.id, set.cards[0].id, true))).toBe('QUOTA');
  expect(db.getProgress(set.id)).toEqual({});
  full = false;
  expect(db.updateSet(set.id, { title: 'Neu' }).title).toBe('Neu');
});

test('Learn sessions are not exported; importing a set ends its Learn session', () => {
  const { db, a, b } = seeded();
  db.saveLearn(a.id, LEARN_STATE);
  db.saveLearn(b.id, LEARN_STATE);
  const data = db.exportAll();
  expect(JSON.stringify(data).includes('"learn:')).toBe(false);
  expect(JSON.stringify(data.sets).includes('"stage"')).toBe(false);

  const onlyA = JSON.parse(JSON.stringify(data));
  onlyA.sets = onlyA.sets.filter((s) => s.id === a.id);
  db.importAll(onlyA, { mode: 'merge' });
  expect(db.getLearn(a.id)).toBe(null);
  expect(db.getLearn(b.id)).toEqual(LEARN_STATE);

  const target = setup().db;
  target.importAll(data, { mode: 'replace' });
  expect(target.getLearn(a.id)).toBe(null);
  expect(target.getLearn(b.id)).toBe(null);
});

test('import (replace) and clearAll wipe Learn sessions, including orphans', () => {
  for (const wipe of [(db) => db.importAll({ app: 'wortschatz', version: 1, sets: [] }, { mode: 'replace' }), (db) => db.clearAll()]) {
    const { db, storage, a } = seeded();
    db.saveLearn(a.id, LEARN_STATE);
    storage.setItem(P + 'learn:orphan', JSON.stringify(LEARN_STATE));
    wipe(db);
    expect(storage.getItem(P + 'learn:' + a.id)).toBe(null);
    expect(storage.getItem(P + 'learn:orphan')).toBe(null);
  }
});

test('duplicateSet does not copy the Learn session', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  db.saveLearn(set.id, LEARN_STATE);
  const copy = db.duplicateSet(set.id);
  expect(db.getLearn(copy.id)).toBe(null);
  expect(db.getLearn(set.id)).toEqual(LEARN_STATE);
});

test('a failed import (QUOTA) restores the Learn session', () => {
  const a = bigSet('A', 40, 'a');
  const b = bigSet('B', 200, 'b');
  const storage = limitedStorage(30000);
  const db = createDb(() => storage);
  db.importAll({ app: 'wortschatz', version: 1, sets: [a.set], progress: { A: a.progress } }, { mode: 'replace' });
  db.saveLearn('A', LEARN_STATE);
  const err = errorOf(() => db.importAll({ app: 'wortschatz', version: 1, sets: [a.set, b.set], progress: { B: b.progress } }, { mode: 'merge' }));
  expect(err && err.code).toBe('QUOTA');
  expect(db.getLearn('A')).toEqual(LEARN_STATE);
  expect(createDb(() => storage).getLearn('A')).toEqual(LEARN_STATE);
});

test('corrupt or wrongly typed Learn data reads as no session', () => {
  const { db } = setup({
    [P + 'sets']: JSON.stringify([{ id: 's1', title: 'A', cards: [{ id: 'c1', term: 'a', definition: 'b' }] }]),
    [P + 'learn:s1']: '{not json',
    [P + 'learn:s2']: JSON.stringify([1, 2]),
    [P + 'learn:s3']: JSON.stringify('state'),
  });
  expect(db.getLearn('s1')).toBe(null);
  expect(db.getLearn('s2')).toBe(null);
  expect(db.getLearn('s3')).toBe(null);
  db.saveLearn('s1', LEARN_STATE);
  expect(db.getLearn('s1')).toEqual(LEARN_STATE);
});

// ---------------------------------------------------------------------------
// Karteikarten decks (key flashcards:<setId>): kept with the set, not progress

function deckFor(set, extra = {}) {
  const ids = set.cards.map((c) => c.id);
  return {
    round: 1,
    queue: ids,
    sorts: [{ cardID: ids[0], verdict: 'know' }],
    knownEarlier: [],
    isFlipped: false,
    starredOnly: false,
    isShuffled: false,
    updatedAt: 42,
    ...extra,
  };
}

test('the storage-full message is neutral (browser and Windows app)', () => {
  const inner = memoryStorage();
  let full = false;
  const storage = {
    getItem: (k) => inner.getItem(k),
    setItem(k, v) {
      if (full) throw new Error('quota');
      inner.setItem(k, v);
    },
    removeItem: (k) => inner.removeItem(k),
  };
  const db = createDb(() => storage);
  db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  full = true;
  const err = errorOf(() => db.createSet({ title: 'B', termLang: 'fr', cards: SAMPLE }));
  expect(err.message).toBe('Der Speicher für Wortschatz ist voll. Exportiere ein Backup und lösche Lernsets, die du nicht mehr brauchst.');
});

test('Karteikarten decks round-trip as copies under flashcards:<setId> with the Mac keys', () => {
  const { db, storage } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  expect(db.getFlashcards(set.id)).toBe(null);
  const deck = deckFor(set);
  db.saveFlashcards(set.id, { ...deck, extra: 'dropped' });
  const loaded = db.getFlashcards(set.id);
  expect(loaded).toEqual(deck);
  loaded.queue.push('mutated');
  expect(db.getFlashcards(set.id)).toEqual(deck);
  const raw = JSON.parse(storage.getItem(P + 'flashcards:' + set.id));
  expect(Object.keys(raw).sort()).toEqual(['isFlipped', 'isShuffled', 'knownEarlier', 'queue', 'round', 'sorts', 'starredOnly', 'updatedAt']);
  expect(raw.sorts[0]).toEqual({ cardID: set.cards[0].id, verdict: 'know' });
  db.clearFlashcards(set.id);
  expect(db.getFlashcards(set.id)).toBe(null);
  expect(storage.getItem(P + 'flashcards:' + set.id)).toBe(null);
});

test('saveFlashcards ignores unknown sets; an inconsistent deck or junk clears', () => {
  const { db, storage } = setup();
  db.saveFlashcards('ghost', { round: 1, queue: ['a'], sorts: [], knownEarlier: [] });
  expect(storage.getItem(P + 'flashcards:ghost')).toBe(null);
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const ids = set.cards.map((c) => c.id);
  for (const junk of [null, 'deck', [1], { ...deckFor(set), sorts: [{ cardID: ids[1], verdict: 'know' }] }, { ...deckFor(set), knownEarlier: [ids[0]] }, { ...deckFor(set), round: 0 }]) {
    db.saveFlashcards(set.id, deckFor(set));
    db.saveFlashcards(set.id, junk);
    expect(db.getFlashcards(set.id)).toBe(null);
  }
});

test('saveFlashcards / clearFlashcards notify subscribers once with the flashcards key', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const events = [];
  const off = db.subscribe((e) => events.push(e));
  db.saveFlashcards(set.id, deckFor(set));
  db.clearFlashcards(set.id);
  off();
  expect(events).toEqual([
    { type: 'local', keys: ['flashcards:' + set.id] },
    { type: 'local', keys: ['flashcards:' + set.id] },
  ]);
});

test('a deck survives card edits, added and removed cards, star changes and progress resets', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  const deck = deckFor(set);
  db.saveFlashcards(set.id, deck);
  db.updateSet(set.id, { cards: [...db.getSet(set.id).cards, { term: 'neu', definition: 'new' }] });
  db.updateSet(set.id, { cards: db.getSet(set.id).cards.slice(1) });
  db.updateCard(set.id, set.cards[1].id, { definition: 'der Mann (Mensch)' });
  db.toggleStar(set.id, set.cards[1].id);
  db.recordAnswer(set.id, set.cards[1].id, true);
  db.resetProgress(set.id);
  db.resetCardProgress(set.id, [set.cards[1].id]);
  db.updateStudyOptions(set.id, { answerWith: 'definition' });
  // The stored deck stays as it was: the screen syncs it with the set when it opens.
  expect(db.getFlashcards(set.id)).toEqual(deck);
});

test('deleteSet removes the deck; snapshotSet + restoreSet bring it back', () => {
  const { db, storage } = setup();
  const keep = db.createSet({ title: 'keep', termLang: 'fr', cards: SAMPLE });
  const set = db.createSet({ title: 'gone', termLang: 'fr', cards: SAMPLE });
  db.saveFlashcards(keep.id, deckFor(keep));
  db.saveFlashcards(set.id, deckFor(set, { round: 2, sorts: [] }));
  const snapshot = db.snapshotSet(set.id);
  expect(snapshot.flashcards).toEqual(deckFor(set, { round: 2, sorts: [] }));
  db.deleteSet(set.id);
  expect(db.getFlashcards(set.id)).toBe(null);
  expect(storage.getItem(P + 'flashcards:' + set.id)).toBe(null);
  expect(db.getFlashcards(keep.id)).toEqual(deckFor(keep));
  let notified = 0;
  const off = db.subscribe(() => notified++);
  db.restoreSet(JSON.parse(JSON.stringify(snapshot)));
  off();
  expect(notified).toBe(1);
  expect(db.getFlashcards(set.id)).toEqual(deckFor(set, { round: 2, sorts: [] }));

  // A snapshot without a deck restores none (and drops a newer one); a broken one is ignored.
  db.clearFlashcards(set.id);
  const bare = db.snapshotSet(set.id);
  expect(bare.flashcards).toBe(null);
  db.saveFlashcards(set.id, deckFor(set));
  db.restoreSet(bare);
  expect(db.getFlashcards(set.id)).toBe(null);
  db.restoreSet({ ...bare, flashcards: { round: 1, queue: ['x', 'x'], sorts: [], knownEarlier: [] } });
  expect(db.getFlashcards(set.id)).toBe(null);
  expect(db.getSet(set.id).title).toBe('gone');
});

test('decks are not exported; importing a set ends its deck, replace and clearAll wipe all (orphans too)', () => {
  const { db, storage, a, b } = seeded();
  db.saveFlashcards(a.id, deckFor(a));
  db.saveFlashcards(b.id, deckFor(b));
  const data = db.exportAll();
  expect(JSON.stringify(data).includes('flashcards')).toBe(false);
  expect(JSON.stringify(data).includes('"knownEarlier"')).toBe(false);

  const onlyA = JSON.parse(JSON.stringify(data));
  onlyA.sets = onlyA.sets.filter((s) => s.id === a.id);
  db.importAll(onlyA, { mode: 'merge' });
  expect(db.getFlashcards(a.id)).toBe(null);
  expect(db.getFlashcards(b.id)).toEqual(deckFor(b));

  storage.setItem(P + 'flashcards:orphan', JSON.stringify(deckFor(b)));
  db.importAll(data, { mode: 'replace' });
  expect(db.getFlashcards(b.id)).toBe(null);
  expect(storage.getItem(P + 'flashcards:orphan')).toBe(null);

  db.saveFlashcards(a.id, deckFor(a));
  storage.setItem(P + 'flashcards:orphan', JSON.stringify(deckFor(b)));
  db.clearAll();
  expect(storage.getItem(P + 'flashcards:' + a.id)).toBe(null);
  expect(storage.getItem(P + 'flashcards:orphan')).toBe(null);
});

test('duplicateSet does not copy the deck', () => {
  const { db } = setup();
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  db.saveFlashcards(set.id, deckFor(set));
  const copy = db.duplicateSet(set.id);
  expect(db.getFlashcards(copy.id)).toBe(null);
  expect(db.getFlashcards(set.id)).toEqual(deckFor(set));
});

test('a failed import (QUOTA) restores the deck', () => {
  const a = bigSet('A', 40, 'a');
  const b = bigSet('B', 200, 'b');
  const storage = limitedStorage(30000);
  const db = createDb(() => storage);
  db.importAll({ app: 'wortschatz', version: 1, sets: [a.set], progress: { A: a.progress } }, { mode: 'replace' });
  const deck = deckFor(db.getSet('A'));
  db.saveFlashcards('A', deck);
  const err = errorOf(() => db.importAll({ app: 'wortschatz', version: 1, sets: [a.set, b.set], progress: { B: b.progress } }, { mode: 'merge' }));
  expect(err && err.code).toBe('QUOTA');
  expect(db.getFlashcards('A')).toEqual(deck);
  expect(createDb(() => storage).getFlashcards('A')).toEqual(deck);
});

test('corrupt, wrongly typed or inconsistent stored decks read as no deck', () => {
  const sorted = { round: 1, queue: ['c1'], sorts: [{ cardID: 'c1', verdict: 'know' }], knownEarlier: [], isFlipped: false, starredOnly: false, isShuffled: false, updatedAt: 0 };
  const { db } = setup({
    [P + 'sets']: JSON.stringify([{ id: 's1', title: 'A', cards: [{ id: 'c1', term: 'a', definition: 'b' }] }]),
    [P + 'flashcards:s1']: '{not json',
    [P + 'flashcards:s2']: JSON.stringify([1, 2]),
    [P + 'flashcards:s3']: JSON.stringify({ ...sorted, sorts: [{ cardID: 'c1', verdict: 'maybe' }] }),
    [P + 'flashcards:s4']: JSON.stringify({ ...sorted, knownEarlier: ['c1'] }),
    [P + 'flashcards:s5']: JSON.stringify(sorted),
  });
  for (const id of ['s1', 's2', 's3', 's4']) expect(db.getFlashcards(id)).toBe(null);
  expect(db.getFlashcards('s5')).toEqual(sorted);
  db.saveFlashcards('s1', sorted);
  expect(db.getFlashcards('s1')).toEqual(sorted);
});

// ---------------------------------------------------------------------------
// backup.js (pure parts)

test('setToText produces Quizlet-compatible text', () => {
  const set = {
    cards: [
      { term: 'le monsieur, messieurs', definition: 'der Herr' },
      { term: 'la mademoiselle', definition: 'das Fräulein,\ndie Frau' },
      { term: ' ', definition: '' },
    ],
  };
  expect(setToText(set)).toBe('le monsieur, messieurs\tder Herr\nla mademoiselle\tdas Fräulein, die Frau');
  expect(setToText(set, { termSep: ' - ', cardSep: '\n' })).toBe('le monsieur, messieurs - der Herr\nla mademoiselle - das Fräulein, die Frau');
  expect(setToText(set, { termSep: ',', cardSep: ';' })).toBe('"le monsieur, messieurs",der Herr;la mademoiselle,"das Fräulein, die Frau"');
  expect(setToText(null)).toBe('');
  // A ';' inside a field would split the card; grading treats ';' and ',' alike, so it becomes ', '.
  expect(setToText({ cards: [{ term: 'say "hi"', definition: 'a;b' }] }, { termSep: '\t', cardSep: ';' })).toBe('say "hi"\ta, b');
  expect(setToText({ cards: [{ term: 'a ; b', definition: 'c;  d;' }] }, { termSep: ' - ', cardSep: ';' })).toBe('a, b - c, d,');
  // With a newline between cards a ';' is harmless and stays as typed.
  expect(setToText({ cards: [{ term: 'aimer', definition: 'lieben; mögen' }] })).toBe('aimer\tlieben; mögen');
});

test('a semicolon-separated export re-imports every card without stray quotes', () => {
  const cards = [
    { term: 'aimer', definition: 'lieben; mögen' },
    { term: 'le temps', definition: 'das Wetter; die Zeit' },
    { term: 'la maison', definition: 'das Haus' },
    { term: 'le chien', definition: 'der Hund' },
  ];
  const text = setToText({ cards }, { termSep: ' - ', cardSep: ';' });
  expect(text.includes('"')).toBe(false);
  const parsed = parseVocab(text);
  expect(parsed.cards.map((c) => [c.term, c.definition])).toEqual([
    ['aimer', 'lieben, mögen'],
    ['le temps', 'das Wetter, die Zeit'],
    ['la maison', 'das Haus'],
    ['le chien', 'der Hund'],
  ]);
});

test('every export option re-imports the 52-card example list card for card', () => {
  const original = parseVocab(readFile('fixtures/user-example.txt')).cards.map((c) => ({ term: c.term, definition: c.definition }));
  expect(original).toHaveLength(52);
  for (const termSep of ['\t', ', ', ' - ']) {
    for (const cardSep of ['\n', ';']) {
      const back = parseVocab(setToText({ cards: original }, { termSep, cardSep }));
      expect([JSON.stringify(termSep + cardSep), back.cards.map((c) => ({ term: c.term, definition: c.definition }))]).toEqual([
        JSON.stringify(termSep + cardSep),
        original,
      ]);
    }
  }
});

test('readJsonFile parses objects and rejects junk', async () => {
  const fileOf = (text) => ({ text: async () => text });
  expect(await readJsonFile(fileOf('﻿{"app":"wortschatz"}'))).toEqual({ app: 'wortschatz' });
  let message = '';
  try {
    await readJsonFile(fileOf('nope'));
  } catch (e) {
    message = e.message;
  }
  expect(message).toContain('keine gültige Backup-Datei');
  message = '';
  try {
    await readJsonFile(fileOf('[1,2]'));
  } catch (e) {
    message = e.message;
  }
  expect(message).toContain('keine gültige Backup-Datei');
  message = '';
  try {
    await readJsonFile({ text: async () => { throw new Error('io'); } });
  } catch (e) {
    message = e.message;
  }
  expect(message).toContain('nicht gelesen');
});

test('Arabic and Chinese sets keep their languages', () => {
  const { db, storage } = setup();
  const ar = db.createSet({ title: 'Arabisch', termLang: 'ar', defLang: 'de', cards: [{ term: 'كِتَابٌ', definition: 'Buch' }] });
  expect(ar.termLang).toBe('ar');
  expect(ar.cards[0].term).toBe('كِتَابٌ');
  const zh = db.createSet({ title: 'Chinesisch', termLang: 'zh', defLang: 'ar', cards: [{ term: '你好 (nǐ hǎo)', definition: 'مرحبا' }] });
  expect([zh.termLang, zh.defLang]).toEqual(['zh', 'ar']);
  const set = db.createSet({ title: 'A', termLang: 'fr', cards: SAMPLE });
  db.updateSet(set.id, { termLang: 'zh', defLang: 'ar' });
  const updated = db.getSet(set.id);
  expect([updated.termLang, updated.defLang]).toEqual(['zh', 'ar']);
  // Stored sets are read back with their languages (and unknown codes still fall back).
  const raw = JSON.parse(storage.getItem(P + 'sets'));
  raw.push({ ...raw[0], id: 'odd', termLang: 'zh-CN', defLang: 'arabic' });
  const again = setup({ [P + 'sets']: JSON.stringify(raw) }).db;
  expect(again.getSet(zh.id).termLang).toBe('zh');
  expect(again.getSet(ar.id).termLang).toBe('ar');
  expect([again.getSet('odd').termLang, again.getSet('odd').defLang]).toEqual(['fr', 'de']);
});

await run('db.test.js');
