// Parity fixture for src/store/db.js and src/store/backup.js → Fixtures/store.json.
// Run with TZ=Europe/Zurich (mac/scripts/gen-fixtures.sh store).
//
// fns:
//   scenario [spec] → steps: a scripted sequence of store operations against createDb(memoryStorage).
//     spec = { name, seed, idCounter, clock0, initial, known0, ops }
//     - Determinism: under jsc `crypto` is missing, so uid() (src/lib/id.js) draws 16 bytes from
//       Math.random and mixes `(Date.now() + counter++) >>> 0` into the last 6 characters. Here
//       Math.random is mulberry32(seed) (fresh per scenario, consumed only by uid()), Date.now()
//       and the db's now() return a fake clock, and `idCounter` is id.js's counter at the start of
//       the scenario. The Swift test replays exactly that generator, so ids match verbatim.
//     - initial: null (empty storage) or { "<key without prefix>": parsed JSON | null } — the
//       storage before the first read (null = unparseable or null; the key exists either way).
//     - ops: [{ op, clock, known, ...args }]. The clock is set before the op; `known` lists the
//       set ids whose progress, sessions and study options are reported after it.
//     - steps[0] is the initial state, steps[i + 1] the state after ops[i]:
//       { result?, error?: { code, message }, events: [{ type, keys (sorted) }], changed }
//       `changed` holds only the parts whose JSON differs from the previous step: head
//       { app, version, exportedAt }, sets, exportProgress, settings, activity (all exportAll()),
//       progress / sessions / learns { id: value } (non-empty / non-null only) and
//       options { id: getStudyOptions(id) } for the known ids.
//   setToText [set, opts] → text
//   readJsonFile [text] → object | { throws }
//   jsonText [value] → JSON.stringify(value, null, 2) with the key order of Backup.jsonText (the
//     web app's creation order for known keys, other keys sorted), i.e. a backup file's text
//   webBackup [backup, clock] → exportAll() of an empty store after importAll(backup, { mode: 'replace' })
//     (the backup is a real web backup: exportAll() of a library with the user's 52 cards,
//     answers, a Write session and a Learn session).
import { createDb, memoryStorage } from '../../Website/src/store/db.js';
import { setToText, readJsonFile } from '../../Website/src/store/backup.js';
import { parseVocab } from '../../Website/src/core/parser.js';
import {
  createSession,
  answer as writeAnswer,
  nextRound as writeNextRound,
  isRoundOver as writeRoundOver,
} from '../../Website/src/core/session.js';
import {
  createLearn,
  answer as learnAnswer,
  nextRound as learnNextRound,
  isRoundOver as learnRoundOver,
} from '../../Website/src/core/learn.js';
import { Cases, mulberry32, randInt, pick, chance, fixtureTexts, readText, stableStringify } from './lib.js';

const cases = new Cases('store');

// ---------------------------------------------------------------------------
// Determinism hooks (see the header)

let idRng = mulberry32(1);
let randomCalls = 0;
Math.random = () => {
  randomCalls++;
  return idRng();
};
let clock = 0;
Date.now = () => clock;

const P = 'wortschatz:v1:';
const SET_KEY_RE = /^(progress|session|learn):(.*)$/;
const DAY = 86400000;
const HOUR = 3600000;
// 2026-10-11 10:00 in Zurich.
const BASE = Date.UTC(2026, 9, 11, 8, 0, 0);
const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

// ---------------------------------------------------------------------------
// Scenario runner

class Runner {
  constructor({ name, seed, clock0, initial = null }) {
    if (randomCalls % 16 !== 0) throw new Error(`uid stream misaligned before ${name}`);
    this.spec = { name, seed, idCounter: randomCalls / 16, clock0 };
    idRng = mulberry32(seed);
    clock = clock0;
    const raw = {};
    const parsed = {};
    if (initial) {
      for (const key of Object.keys(initial)) {
        raw[P + key] = initial[key];
        try {
          parsed[key] = JSON.parse(initial[key]);
        } catch {
          parsed[key] = null;
        }
      }
    }
    this.spec.initial = initial ? parsed : null;
    this.clean = !initial;
    this.storage = memoryStorage(raw);
    this.ops = [];
    this.steps = [];
    this.prev = {};
    this.pool = []; // snapshots for restoreSet
    this.open();
    const known = this.known();
    this.spec.known0 = known;
    this.steps.push({ events: [], changed: this.delta(this.parts(known)) });
  }

  open() {
    this.db = createDb(() => this.storage, { now: () => clock });
    this.events = [];
    this.db.subscribe((e) => this.events.push(e));
  }

  known() {
    const ids = new Set(['ghost']);
    for (const s of this.db.listSets()) ids.add(s.id);
    for (let i = 0; i < this.storage.length; i++) {
      const key = this.storage.key(i);
      if (!key.startsWith(P)) continue;
      const m = SET_KEY_RE.exec(key.slice(P.length));
      if (m) ids.add(m[2]);
    }
    return [...ids].sort();
  }

  parts(known) {
    const db = this.db;
    const ex = db.exportAll();
    const progress = {};
    const sessions = {};
    const learns = {};
    const options = {};
    for (const id of known) {
      const p = db.getProgress(id);
      if (Object.keys(p).length) progress[id] = p;
      const s = db.getSession(id);
      if (s !== null) sessions[id] = s;
      const l = db.getLearn(id);
      if (l !== null) learns[id] = l;
      options[id] = db.getStudyOptions(id);
    }
    return {
      head: { app: ex.app, version: ex.version, exportedAt: ex.exportedAt },
      sets: ex.sets,
      exportProgress: ex.progress,
      settings: ex.settings,
      activity: ex.activity,
      progress,
      sessions,
      learns,
      options,
    };
  }

  delta(parts) {
    const changed = {};
    for (const key of Object.keys(parts)) {
      const json = stableStringify(parts[key]);
      if (this.prev[key] !== json) {
        changed[key] = parts[key];
        this.prev[key] = json;
      }
    }
    return changed;
  }

  // Runs one operation and records it. Returns { result, error }.
  run(op) {
    const full = { ...op, clock: op.clock === undefined ? clock : op.clock };
    if (full.op === 'reload' && !this.clean) throw new Error('reload needs a clean storage');
    clock = full.clock;
    this.events = [];
    let result;
    let error;
    try {
      result = apply(this, full);
    } catch (e) {
      if (!e || typeof e.code !== 'string') throw e;
      error = { code: e.code, message: e.message };
    }
    if (full.op === 'snapshotSet' && result) this.pool.push(clone(result));
    const known = this.known();
    const step = {
      events: this.events.map((e) => ({ type: e.type, keys: e.keys === null ? null : [...e.keys].sort() })),
      changed: this.delta(this.parts(known)),
    };
    if (result !== undefined) step.result = clone(result);
    if (error) step.error = error;
    this.ops.push({ ...full, known });
    this.steps.push(step);
    return { result, error };
  }

  finish() {
    cases.add('scenario', [{ ...this.spec, ops: this.ops }], this.steps);
  }
}

function apply(r, op) {
  const db = r.db;
  switch (op.op) {
    case 'createSet':
      return db.createSet(op.args);
    case 'updateSet':
      return db.updateSet(op.setId, op.patch);
    case 'deleteSet':
      return db.deleteSet(op.setId);
    case 'duplicateSet':
      return db.duplicateSet(op.setId);
    case 'getSet':
      return db.getSet(op.setId);
    case 'updateCard':
      return db.updateCard(op.setId, op.cardId, op.changes);
    case 'toggleStar':
      return db.toggleStar(op.setId, op.cardId);
    case 'recordAnswer':
      return db.recordAnswer(op.setId, op.cardId, op.correct, op.at);
    case 'overrideLastAnswer':
      return db.overrideLastAnswer(op.setId, op.cardId);
    case 'resetProgress':
      return db.resetProgress(op.setId);
    case 'resetCardProgress':
      return db.resetCardProgress(op.setId, op.cardIds);
    case 'saveSession':
      return db.saveSession(op.setId, op.state);
    case 'clearSession':
      return db.clearSession(op.setId);
    case 'saveLearn':
      return db.saveLearn(op.setId, op.state);
    case 'clearLearn':
      return db.clearLearn(op.setId);
    case 'updateSettings':
      return db.updateSettings(op.patch);
    case 'updateStudyOptions':
      return db.updateStudyOptions(op.setId, op.patch);
    case 'importAll':
      return op.mode === undefined ? db.importAll(op.data) : db.importAll(op.data, { mode: op.mode });
    case 'snapshotSet':
      return db.snapshotSet(op.setId);
    case 'restoreSet':
      return db.restoreSet(op.snapshot);
    case 'clearAll':
      return db.clearAll();
    case 'reload':
      r.open();
      return undefined;
    default:
      throw new Error(`unknown op ${op.op}`);
  }
}

// ---------------------------------------------------------------------------
// Data pools

const userCards = parseVocab(readText('tests/fixtures/user-example.txt')).cards.map((c) => ({ term: c.term, definition: c.definition }));
if (userCards.length !== 52) throw new Error(`expected the 52-pair list, got ${userCards.length}`);
const fixturePairs = [];
for (const { text } of fixtureTexts()) {
  for (const c of parseVocab(text).cards) fixturePairs.push({ term: c.term, definition: c.definition });
}
const PAIRS = userCards.concat(fixturePairs);
const SAMPLE = [
  { term: 'le monsieur, messieurs', definition: 'der Herr' },
  { term: "l'homme", definition: 'der Mann' },
  { term: 'la femme', definition: 'die Frau', starred: true },
];
const NOISE = ['', ' ', '  ', '\t', '\n', '\r\n', ' ', ' ', '﻿', '　'];
const ODD_VALUES = [42, 0, true, false, null, undefined, 3.5, -0.25, 1e21, [1, 'a'], {}, ['x', null], [[1, 2], 3]];
const LANG_VALUES = ['fr', 'en', 'es', 'it', 'de', 'other', 'xx', '', null, 7, 'FR'];
const THEME_VALUES = ['system', 'light', 'dark', 'neon', '', null, 1];

function fuzzSide(r, s) {
  const x = r();
  if (x < 0.72) return s;
  if (x < 0.8) return pick(r, NOISE) + s + pick(r, NOISE);
  if (x < 0.85) return s.replace(' ', '\r\n').replace('e', '\re');
  if (x < 0.9) return pick(r, NOISE) + pick(r, NOISE);
  if (x < 0.94) return s + '\u0085';
  return pick(r, ODD_VALUES);
}

function fuzzCard(r, existing = []) {
  const pair = pick(r, PAIRS);
  const c = {};
  const term = fuzzSide(r, pair.term);
  const definition = fuzzSide(r, pair.definition);
  if (term !== undefined) c.term = term;
  if (definition !== undefined) c.definition = definition;
  if (existing.length && chance(r, 0.4)) c.id = pick(r, existing).id;
  else if (chance(r, 0.15)) c.id = pick(r, ['', 7, null, 'fixed-id', 'id-é', 'c1', true]);
  if (chance(r, 0.3)) c.starred = pick(r, [true, false, true, 'yes', 1, null]);
  return c;
}

function freshCards(r, min, max) {
  const n = randInt(r, min, max);
  const out = [];
  for (let i = 0; i < n; i++) out.push(fuzzCard(r));
  return out;
}

function cardsVariant(r, cards) {
  const x = r();
  const copy = cards.map((c) => ({ ...c }));
  if (x < 0.2) return copy.map((c) => (chance(r, 0.5) ? { ...c, definition: fuzzSide(r, `${c.definition}!`) } : c));
  if (x < 0.32) return copy.reverse();
  if (x < 0.5) return copy.concat(freshCards(r, 1, 3));
  if (x < 0.66) return copy.filter(() => chance(r, 0.6));
  if (x < 0.74) return copy.length ? copy.concat([{ id: copy[0].id, term: 'dup', definition: 'Duplikat' }]) : copy;
  if (x < 0.8) return copy.map((c) => ({ id: c.id, term: c.term, definition: c.definition }));
  if (x < 0.84) return copy.map((c) => ({ ...c, starred: !c.starred }));
  const out = [];
  const n = randInt(r, 0, 7);
  for (let i = 0; i < n; i++) out.push(fuzzCard(r, cards));
  return out;
}

function fuzzStudyPatch(r) {
  if (chance(r, 0.05)) return pick(r, [null, 'x', [], 5]);
  const p = {};
  if (chance(r, 0.3)) p.answerWith = pick(r, ['term', 'definition', 'both', 'nonsense', null]);
  for (const key of ['shuffle', 'copyAnswer', 'autoAdvance', 'audio']) {
    if (chance(r, 0.15)) p[key] = pick(r, [true, false, 'no', 0]);
  }
  if (chance(r, 0.35)) {
    if (chance(r, 0.1)) p.tolerance = pick(r, ['none', null, [true]]);
    else {
      const t = {};
      for (const key of ['articles', 'abbreviations', 'multipleAnswers', 'parentheses', 'ignoreCase', 'ignoreAccents', 'typos', 'bogus']) {
        if (chance(r, 0.25)) t[key] = pick(r, [true, false, true, false, 'yes']);
      }
      p.tolerance = t;
    }
  }
  if (chance(r, 0.4)) {
    if (chance(r, 0.1)) p.learn = pick(r, ['all', null, [1]]);
    else {
      const l = {};
      if (chance(r, 0.5)) l.roundSize = pick(r, [0, -3, 7.5, '10', 51, 1, 5, 7, 10, 15, 50, null, 7.0]);
      for (const key of ['mc', 'written', 'retype']) {
        if (chance(r, 0.4)) l[key] = pick(r, [true, false, false, 'no', 0]);
      }
      if (chance(r, 0.1)) l.bogus = true;
      p.learn = l;
    }
  }
  if (chance(r, 0.05)) p.extra = 1;
  return p;
}

function fuzzSettingsPatch(r) {
  if (chance(r, 0.05)) return pick(r, [null, 'dark', [], 3]);
  const p = {};
  if (chance(r, 0.5)) p.theme = pick(r, THEME_VALUES);
  if (chance(r, 0.6)) p.study = fuzzStudyPatch(r);
  return p;
}

function fuzzPatch(r, set) {
  if (chance(r, 0.03)) return pick(r, [null, 'x', [], undefined]);
  const p = {};
  if (chance(r, 0.25)) p.title = pick(r, ['  Neu  ', '', null, `Titel ${randInt(r, 1, 99)}`, 42, '\tTab\r\nZeile', '   ']);
  if (chance(r, 0.15)) p.description = pick(r, ['Kapitel 1', '', null, ' x ', 7]);
  if (chance(r, 0.15)) p.termLang = pick(r, LANG_VALUES);
  if (chance(r, 0.15)) p.defLang = pick(r, LANG_VALUES);
  if (chance(r, 0.12)) p.studyOptions = chance(r, 0.2) ? pick(r, [null, 'x', {}]) : fuzzStudyPatch(r);
  if (chance(r, 0.6)) p.cards = chance(r, 0.04) ? pick(r, ['x', null, 5]) : cardsVariant(r, set.cards);
  return p;
}

function fuzzChanges(r) {
  if (chance(r, 0.04)) return pick(r, [null, 'x', undefined]);
  const c = {};
  if (chance(r, 0.5)) c.term = fuzzSide(r, pick(r, PAIRS).term);
  if (chance(r, 0.5)) c.definition = fuzzSide(r, pick(r, PAIRS).definition);
  if (chance(r, 0.3)) c.starred = pick(r, [true, false, 'yes']);
  if (chance(r, 0.05)) {
    c.term = pick(r, [' ', '', null]);
    c.definition = pick(r, ['', '\n', null]);
  }
  for (const key of Object.keys(c)) if (c[key] === undefined) delete c[key];
  return c;
}

// A real Write session for the set (the engine's own state), optionally with a few answers.
function engineSession(r, set, now) {
  const rng = mulberry32(randInt(r, 1, 1e9));
  let s = createSession(set.cards, { answerWith: pick(r, ['term', 'definition', 'both']), shuffle: chance(r, 0.7) }, {
    subset: pick(r, ['all', 'all', 'starred', 'learning']),
    rng,
    now,
  });
  const answers = randInt(r, 0, 6);
  for (let i = 0; i < answers; i++) {
    if (writeRoundOver(s)) s = writeNextRound(s, rng, now + i);
    else s = writeAnswer(s, chance(r, 0.6), now + i * 1000);
  }
  return s;
}

// A real Learn session for the set, optionally with a few answers.
function engineLearn(r, set, progress, now) {
  const rng = mulberry32(randInt(r, 1, 1e9));
  let s = createLearn(
    set.cards,
    { answerWith: pick(r, ['term', 'definition']), learn: { roundSize: pick(r, [3, 5, 7]), mc: true, written: chance(r, 0.8) } },
    { progress, rng, now },
  );
  const answers = randInt(r, 0, 6);
  for (let i = 0; i < answers; i++) {
    if (learnRoundOver(s)) s = learnNextRound(s, set.cards, rng, now + i);
    else s = learnAnswer(s, chance(r, 0.6), now + i * 1000);
  }
  return s;
}

const INVALID_BACKUPS = [
  null,
  'text',
  [],
  { app: 'quizlet', sets: [] },
  { app: 'wortschatz', version: 2, sets: [] },
  { app: 'wortschatz', version: 'eins', sets: [] },
  { app: 'wortschatz', version: null, sets: [] },
  { app: 'wortschatz', version: 0.5, sets: [] },
  { app: 'wortschatz', version: 1.5, sets: [] },
  { app: 'wortschatz', version: 1 },
  { app: 'wortschatz', version: 1, sets: {} },
  { app: 'wortschatz', version: 1, sets: [{ title: 'ohne Karten' }] },
  { app: 'wortschatz', version: 1, sets: ['kaputt'] },
  { app: 'wortschatz', version: 1, sets: [{ id: 'x', title: 7, cards: [] }] },
  { app: 'wortschatz', version: 1, sets: [{ id: 'x', cards: [] }, null] },
  { app: 'wortschatz', version: 1, sets: [], progress: [] },
  { app: 'wortschatz', version: 1, sets: [], settings: 'dark' },
  { app: 'wortschatz', version: 1, sets: [], activity: 5 },
  { app: 'Wortschatz', sets: [] },
  {},
];

function craftedBackup(r, db) {
  const sets = [];
  const progress = {};
  const n = randInt(r, 0, 3);
  for (let i = 0; i < n; i++) {
    const existing = db.listSets();
    const id = chance(r, 0.3) && existing.length ? pick(r, existing).id : pick(r, ['imp-a', 'imp-b', 'same', 'same', '', undefined, 9]);
    const cards = freshCards(r, 0, 5).map((c, k) => (chance(r, 0.8) ? { ...c, id: `k${k}` } : c));
    const set = { cards };
    if (id !== undefined) set.id = id;
    if (chance(r, 0.8)) set.title = pick(r, ['Import', '  Leerzeichen  ', '', null]);
    if (chance(r, 0.5)) set.termLang = pick(r, LANG_VALUES);
    if (chance(r, 0.3)) set.studyOptions = fuzzStudyPatch(r);
    if (chance(r, 0.4)) set.createdAt = pick(r, [BASE - DAY, 'gestern', null, 5]);
    if (chance(r, 0.3)) set.updatedAt = pick(r, [BASE, null]);
    if (chance(r, 0.3)) set.lastStudiedAt = pick(r, [BASE - HOUR, null, 'x']);
    sets.push(set);
    if (typeof id === 'string' && chance(r, 0.6)) {
      const map = {};
      for (let k = 0; k < 6; k++) {
        if (chance(r, 0.5)) map[`k${k}`] = { correct: randInt(r, 0, 3), streak: randInt(r, 0, 3), lastResult: pick(r, ['correct', 'incorrect', 'x']) };
      }
      if (chance(r, 0.2)) map.ghost = { correct: 1, streak: 1 };
      if (chance(r, 0.1)) map.k0 = 'bad';
      progress[id] = map;
    }
  }
  const data = { app: 'wortschatz', sets };
  if (chance(r, 0.8)) data.version = pick(r, [1, 1, 1.0]);
  if (chance(r, 0.7)) data.progress = progress;
  if (chance(r, 0.4)) data.settings = chance(r, 0.2) ? null : fuzzSettingsPatch(r) || {};
  if (chance(r, 0.5)) {
    data.activity = { '2026-10-11': randInt(r, 1, 9), '2026-01-01': 2, 'kein-datum': 4, '2026-10-12': pick(r, [-1, 0.5, 'x', 3.7]) };
  }
  if (data.settings !== undefined && data.settings !== null && typeof data.settings !== 'object') delete data.settings;
  return data;
}

function editedExport(r, db) {
  const data = clone(db.exportAll());
  if (chance(r, 0.4)) data.sets = data.sets.filter(() => chance(r, 0.6));
  for (const s of data.sets) {
    if (chance(r, 0.3)) s.title = `${s.title} (Backup)`;
    if (chance(r, 0.2)) s.cards = cardsVariant(r, s.cards);
  }
  if (chance(r, 0.3)) data.sets.push({ id: 'brandnew', title: 'Neu', termLang: 'it', defLang: 'de', cards: [{ id: 'k1', term: 'ciao', definition: 'hallo' }] });
  if (chance(r, 0.2) && data.sets.length) data.sets.push(clone(data.sets[0]));
  if (chance(r, 0.3)) data.progress = {};
  if (chance(r, 0.3)) data.settings = { theme: 'light' };
  if (chance(r, 0.2)) delete data.settings;
  if (chance(r, 0.3)) data.activity = { '2026-10-11': 7, '2026-01-01': 2 };
  if (chance(r, 0.1)) delete data.version;
  return data;
}

// ---------------------------------------------------------------------------
// Fuzzed scenarios

const ADVANCE = [0, 0, 1, 1000, 60000, HOUR, DAY, 3 * DAY];

function randomOp(r, run, { allowReload }) {
  const db = run.db;
  const sets = db.listSets();
  const someSet = () => (sets.length && chance(r, 0.9) ? pick(r, sets) : null);
  const setIdOf = (set) => (set ? set.id : pick(r, ['ghost', 'nope', '']));
  const cardIdOf = (set) => (set && set.cards.length && chance(r, 0.9) ? pick(r, set.cards).id : pick(r, ['nope', '', 'c1']));
  const x = r() * 100;
  if (x < 12 || !sets.length) {
    const args = {};
    if (chance(r, 0.9)) args.title = pick(r, ['Personen', '  Farben  ', '', null, 'Unité 3 – Vocabulaire', 5]);
    if (chance(r, 0.3)) args.description = pick(r, ['Kapitel 1', ' x ', null]);
    if (chance(r, 0.8)) args.termLang = pick(r, LANG_VALUES);
    if (chance(r, 0.5)) args.defLang = pick(r, LANG_VALUES);
    if (chance(r, 0.95)) args.cards = chance(r, 0.03) ? 'x' : freshCards(r, 0, 7);
    return { op: 'createSet', args: chance(r, 0.02) ? undefined : args };
  }
  if (x < 25) {
    const set = someSet();
    return { op: 'updateSet', setId: setIdOf(set), patch: fuzzPatch(r, set || { cards: [] }) };
  }
  if (x < 31) {
    const set = someSet();
    return { op: 'updateCard', setId: setIdOf(set), cardId: cardIdOf(set), changes: fuzzChanges(r) };
  }
  if (x < 35) {
    const set = someSet();
    return { op: 'toggleStar', setId: setIdOf(set), cardId: cardIdOf(set) };
  }
  if (x < 50) {
    const set = someSet();
    const op = { op: 'recordAnswer', setId: setIdOf(set), cardId: cardIdOf(set), correct: pick(r, [true, false, true, false, 1, 0, '', null, 'x']) };
    if (chance(r, 0.4)) op.at = pick(r, [clock - randInt(r, 0, 5 * DAY), clock + 0.5, 0, -HOUR, 'x', clock + DAY]);
    return op;
  }
  if (x < 55) {
    const set = someSet();
    return { op: 'overrideLastAnswer', setId: setIdOf(set), cardId: cardIdOf(set) };
  }
  if (x < 57) return { op: 'resetProgress', setId: setIdOf(someSet()) };
  if (x < 60) {
    const set = someSet();
    const ids = set ? set.cards.filter(() => chance(r, 0.4)).map((c) => c.id) : [];
    const cardIds = chance(r, 0.8) ? ids.concat(chance(r, 0.3) ? [ids[0] || 'x', 'unknown'] : []) : pick(r, [[], null, 'abc', [null, '', 7, {}]]);
    return { op: 'resetCardProgress', setId: setIdOf(set), cardIds };
  }
  if (x < 65) {
    const set = someSet();
    let state;
    const y = r();
    if (set && y < 0.6) state = engineSession(r, set, clock);
    else if (y < 0.85) state = { v: 1, round: randInt(r, 1, 3), queue: ['x'], finishedAt: null };
    else state = pick(r, [null, 'state', [1, 2], 5]);
    return { op: 'saveSession', setId: setIdOf(set), state };
  }
  if (x < 67) return { op: 'clearSession', setId: setIdOf(someSet()) };
  if (x < 72) {
    const set = someSet();
    let state;
    const y = r();
    if (set && y < 0.6) state = engineLearn(r, set, db.getProgress(set.id), clock);
    else if (y < 0.85) state = { v: 1, round: 2, order: ['a', 'b'], stage: { a: 1, b: 0 }, finishedAt: null };
    else state = pick(r, [null, 'state', [1, 2]]);
    return { op: 'saveLearn', setId: setIdOf(set), state };
  }
  if (x < 74) return { op: 'clearLearn', setId: setIdOf(someSet()) };
  if (x < 77) return { op: 'updateSettings', patch: fuzzSettingsPatch(r) };
  if (x < 82) return { op: 'updateStudyOptions', setId: setIdOf(someSet()), patch: fuzzStudyPatch(r) };
  if (x < 85) return { op: 'deleteSet', setId: setIdOf(someSet()) };
  if (x < 88) return { op: 'duplicateSet', setId: setIdOf(someSet()) };
  if (x < 90) return { op: 'snapshotSet', setId: setIdOf(someSet()) };
  if (x < 92) {
    let snapshot;
    const y = r();
    if (run.pool.length && y < 0.7) {
      snapshot = clone(pick(r, run.pool));
      if (chance(r, 0.3)) snapshot.set.title = `${snapshot.set.title} wieder`;
      if (chance(r, 0.2)) snapshot.set.cards = cardsVariant(r, snapshot.set.cards);
      if (chance(r, 0.2)) snapshot.progress = { ...snapshot.progress, ghost: { correct: 1, streak: 1 } };
      if (chance(r, 0.15)) snapshot.session = pick(r, ['x', [1], null, { v: 1, restored: true }]);
      if (chance(r, 0.15)) snapshot.learn = pick(r, ['x', null, { v: 1, restored: true }]);
    } else {
      snapshot = pick(r, [null, 'x', {}, { set: { title: 'ohne id' } }, { set: { id: 'x', cards: 'no' } }, { set: { id: '', cards: [] } }, { set: { id: 'neu', cards: [] }, progress: 'x' }]);
    }
    return { op: 'restoreSet', snapshot };
  }
  if (x < 96) {
    const y = r();
    let data;
    if (y < 0.35) data = clone(db.exportAll());
    else if (y < 0.6) data = editedExport(r, db);
    else if (y < 0.85) data = craftedBackup(r, db);
    else data = clone(pick(r, INVALID_BACKUPS));
    const op = { op: 'importAll', data };
    if (chance(r, 0.85)) op.mode = pick(r, ['merge', 'replace', 'replace', 'bogus']);
    return op;
  }
  if (x < 97) return { op: 'clearAll' };
  if (x < 98.5) return { op: 'getSet', setId: setIdOf(someSet()) };
  if (allowReload) return { op: 'reload' };
  return { op: 'getSet', setId: 'ghost' };
}

function fuzzScenario(i, { initial = null, clock0 = BASE + i * 7 * DAY + randInt(mulberry32(i), 0, 1000) * 1000, steps = [6, 22] } = {}) {
  const r = mulberry32(90000 + i);
  const run = new Runner({ name: `fuzz-${i}`, seed: 4242 + i, clock0, initial });
  const n = randInt(r, steps[0], steps[1]);
  for (let k = 0; k < n; k++) {
    clock += pick(r, ADVANCE);
    const op = randomOp(r, run, { allowReload: run.clean });
    run.run(op);
  }
  run.finish();
}

// Garbage storage like a damaged localStorage (no reload: the web app re-sanitises unsaved keys
// on every read, the Mac app writes its sanitised document once).
function fuzzInitial(i) {
  const r = mulberry32(70000 + i);
  const initial = {};
  const sets = [];
  const n = randInt(r, 0, 4);
  for (let k = 0; k < n; k++) {
    const y = r();
    if (y < 0.1) {
      sets.push(pick(r, [null, 'x', 5, [], { title: 'ohne id', cards: [] }]));
      continue;
    }
    const set = { id: pick(r, [`s${k}`, `s${k}`, 's0', '', 7]) };
    if (chance(r, 0.8)) set.title = pick(r, ['Gespeichert', 42, null, '  ', { x: 1 }]);
    if (chance(r, 0.6)) set.termLang = pick(r, LANG_VALUES);
    if (chance(r, 0.4)) set.defLang = pick(r, LANG_VALUES);
    if (chance(r, 0.9)) set.cards = chance(r, 0.1) ? 'x' : freshCards(r, 0, 5).map((c, j) => (chance(r, 0.7) ? { ...c, id: `c${j}` } : c)).concat(chance(r, 0.2) ? ['junk', null] : []);
    if (chance(r, 0.4)) set.studyOptions = fuzzStudyPatch(r);
    if (chance(r, 0.7)) set.createdAt = pick(r, [BASE - 3 * DAY, 'gestern', null, BASE - DAY + 0.5]);
    if (chance(r, 0.5)) set.updatedAt = pick(r, [BASE - DAY, null, 'x']);
    if (chance(r, 0.4)) set.lastStudiedAt = pick(r, [BASE - HOUR, null, 'x', 0]);
    sets.push(set);
  }
  const enc = (v) => (chance(r, 0.1) ? '{not json' : JSON.stringify(v));
  if (chance(r, 0.9)) initial.sets = chance(r, 0.1) ? pick(r, ['{not json', '"x"', '{}', '']) : enc(sets);
  if (chance(r, 0.5)) initial.settings = enc(chance(r, 0.3) ? pick(r, [7, 'x', null]) : fuzzSettingsPatch(r));
  if (chance(r, 0.5)) initial.activity = enc({ '2026-10-11': 3, '2026-10-12': -1, foo: 2, '2026-10-13': 'x', '2026-10-09': 2.7 });
  if (chance(r, 0.6)) initial.meta = pick(r, ['{"schemaVersion":1}', '{"schemaVersion":2}', '{not json', '"x"', '{"schemaVersion":"1"}']);
  for (const id of ['s0', 's1', 'orphan']) {
    if (chance(r, 0.4)) initial[`progress:${id}`] = enc(pick(r, [{ c0: { correct: 2, streak: 2 }, c1: 'bad', ghost: { correct: '2', streak: 1 } }, 'x', [1], {}]));
    if (chance(r, 0.3)) initial[`session:${id}`] = enc(pick(r, [{ v: 1, round: 2 }, [1, 2, 3], 'state']));
    if (chance(r, 0.3)) initial[`learn:${id}`] = enc(pick(r, [{ v: 1, round: 1, order: ['c0'] }, [1, 2], 'state']));
  }
  return initial;
}

// ---------------------------------------------------------------------------
// Scenarios mirroring tests/db.test.js

function testScenarios() {
  // Basic CRUD, ordering, sessions and options (db.test.js "Sets CRUD" … "Settings").
  {
    const r = new Runner({ name: 'crud', seed: 11, clock0: 1000 });
    const a = r.run({ op: 'createSet', args: { title: '  Personen  ', termLang: 'fr', cards: [...SAMPLE, { term: '   ', definition: '' }, { term: ' calme ', definition: ' ruhig ' }] } }).result;
    r.run({ op: 'createSet', clock: 2000, args: { title: '   ', termLang: 'xx', defLang: 'yy', cards: [] } });
    const c = r.run({ op: 'createSet', clock: 3000, args: { title: 'X', termLang: 'fr', cards: [{ id: 'fixed', term: 'a', definition: 'b' }] } }).result;
    r.run({ op: 'recordAnswer', clock: 4000, setId: a.id, cardId: a.cards[0].id, correct: true, at: 4000 });
    r.run({ op: 'updateSet', clock: 5000, setId: c.id, patch: { title: ' Neu ', description: ' Kapitel 1 ', termLang: 'en', defLang: 'de' } });
    r.run({ op: 'updateSet', setId: c.id, patch: { termLang: 'klingon' } });
    r.run({ op: 'updateSet', setId: 'missing', patch: { title: 'x' } });
    const [c1, c2, c3] = a.cards;
    r.run({
      op: 'updateSet',
      clock: 6000,
      setId: a.id,
      patch: {
        cards: [
          { id: c3.id, term: ' la femme ', definition: 'die Frau, das Weib' },
          { id: c1.id, term: c1.term, definition: c1.definition, starred: true },
          { term: 'la dame', definition: 'die Dame' },
          { id: c2.id, term: '', definition: '  ' },
        ],
      },
    });
    r.run({ op: 'updateSet', setId: a.id, patch: { cards: [{ id: c1.id, term: 'a', definition: 'b' }, { id: c1.id, term: 'c', definition: 'd' }] } });
    r.run({ op: 'saveSession', setId: a.id, state: { v: 1, round: 1, queue: ['x'] } });
    r.run({ op: 'saveLearn', setId: a.id, state: { v: 1, round: 2, order: ['a', 'b'], stage: { a: 1, b: 0 }, finishedAt: null } });
    const current = r.db.getSet(a.id);
    r.run({ op: 'updateSet', setId: a.id, patch: { cards: current.cards.map((x) => ({ ...x, definition: `${x.definition}!` })) } });
    r.run({ op: 'updateSet', setId: a.id, patch: { cards: [...current.cards].reverse() } });
    r.run({ op: 'updateSet', setId: a.id, patch: { title: 'Nur Titel' } });
    r.run({ op: 'updateStudyOptions', setId: a.id, patch: { learn: { roundSize: 10 } } });
    r.run({ op: 'updateCard', setId: a.id, cardId: current.cards[0].id, changes: { definition: 'der Herr (Anrede)' } });
    r.run({ op: 'toggleStar', setId: a.id, cardId: current.cards[1].id });
    r.run({ op: 'updateSet', setId: a.id, patch: { cards: [...current.cards, { term: 'neu', definition: 'new' }] } });
    r.run({ op: 'saveSession', setId: a.id, state: { v: 1 } });
    r.run({ op: 'saveLearn', setId: a.id, state: { v: 1 } });
    r.run({ op: 'updateSet', setId: a.id, patch: { cards: r.db.getSet(a.id).cards.slice(1) } });
    r.run({ op: 'saveSession', setId: 'ghost', state: { v: 1 } });
    r.run({ op: 'saveLearn', setId: a.id, state: [1, 2] });
    r.run({ op: 'updateCard', setId: a.id, cardId: current.cards[1].id, changes: { term: ' ', definition: '' } });
    r.run({ op: 'updateCard', setId: a.id, cardId: 'nope', changes: { term: 'x' } });
    r.run({ op: 'updateCard', setId: 'nope', cardId: current.cards[1].id, changes: { term: 'x' } });
    r.run({ op: 'toggleStar', setId: a.id, cardId: 'nope' });
    r.run({ op: 'recordAnswer', setId: 'nope', cardId: 'x', correct: true });
    r.run({ op: 'duplicateSet', clock: 9000, setId: a.id });
    r.run({ op: 'duplicateSet', setId: 'missing' });
    r.run({ op: 'reload' });
    r.run({ op: 'deleteSet', setId: c.id });
    r.run({ op: 'deleteSet', setId: 'unknown' });
    r.finish();
  }
  // Progress, override, resets, activity across days.
  {
    const r = new Runner({ name: 'progress', seed: 12, clock0: 1000 });
    const set = r.run({ op: 'createSet', args: { title: 'A', termLang: 'fr', cards: SAMPLE } }).result;
    const [c1, c2, c3] = set.cards.map((c) => c.id);
    const at = new Date(2026, 9, 11, 10, 0).getTime();
    r.run({ op: 'recordAnswer', setId: set.id, cardId: c1, correct: true, at });
    r.run({ op: 'recordAnswer', setId: set.id, cardId: c1, correct: false, at: at + 1000 });
    r.run({ op: 'recordAnswer', setId: set.id, cardId: c2, correct: true, at: at + 2000 });
    r.run({ op: 'recordAnswer', setId: set.id, cardId: c1, correct: true, at: new Date(2026, 9, 12, 9, 0).getTime() });
    r.run({ op: 'recordAnswer', setId: set.id, cardId: c3, correct: false, at: 5000 });
    r.run({ op: 'overrideLastAnswer', setId: set.id, cardId: c3 });
    r.run({ op: 'overrideLastAnswer', setId: set.id, cardId: c3 });
    r.run({ op: 'overrideLastAnswer', setId: set.id, cardId: 'fresh' });
    r.run({ op: 'overrideLastAnswer', setId: 'ghost', cardId: c1 });
    r.run({ op: 'saveSession', setId: set.id, state: { v: 1 } });
    r.run({ op: 'saveLearn', setId: set.id, state: { v: 1, round: 1 } });
    r.run({ op: 'resetCardProgress', clock: 9000, setId: set.id, cardIds: [c1, c2, c2, 'unknown'] });
    for (const ids of [[], null, 'abc', [null, '', 7, {}]]) r.run({ op: 'resetCardProgress', setId: set.id, cardIds: ids });
    r.run({ op: 'resetCardProgress', setId: set.id, cardIds: [c3] });
    r.run({ op: 'resetCardProgress', setId: 'ghost', cardIds: ['x'] });
    r.run({ op: 'recordAnswer', setId: set.id, cardId: c1, correct: true });
    r.run({ op: 'resetProgress', setId: set.id });
    r.finish();
  }
  // Settings and study options (deep merges, Learn options rules).
  {
    const r = new Runner({ name: 'options', seed: 13, clock0: 1000 });
    const set = r.run({ op: 'createSet', args: { title: 'A', termLang: 'fr', cards: SAMPLE } }).result;
    r.run({ op: 'updateSettings', patch: { theme: 'dark', study: { tolerance: { typos: true } } } });
    r.run({ op: 'updateSettings', patch: { study: { shuffle: false, answerWith: 'nonsense', tolerance: { ignoreCase: 'yes' } }, extra: 1 } });
    r.run({ op: 'updateSettings', patch: { theme: 'neon' } });
    r.run({ op: 'updateSettings', patch: { study: { answerWith: 'definition', tolerance: { ignoreAccents: true } } } });
    r.run({ op: 'updateStudyOptions', setId: set.id, patch: { answerWith: 'both', tolerance: { typos: true } } });
    r.run({ op: 'updateStudyOptions', setId: set.id, patch: { tolerance: { articles: false } } });
    r.run({ op: 'updateSettings', patch: { study: { copyAnswer: false } } });
    r.run({ op: 'updateStudyOptions', setId: 'unknown', patch: { shuffle: false } });
    for (const roundSize of [0, -3, 7.5, '10', 51, null]) r.run({ op: 'updateStudyOptions', setId: set.id, patch: { learn: { roundSize } } });
    r.run({ op: 'updateStudyOptions', setId: set.id, patch: { learn: { mc: 'no', written: 0, retype: 'yes', bogus: true } } });
    r.run({ op: 'updateStudyOptions', setId: set.id, patch: { learn: 'all' } });
    r.run({ op: 'updateStudyOptions', setId: set.id, patch: { learn: { roundSize: 1 } } });
    r.run({ op: 'updateStudyOptions', setId: set.id, patch: { learn: { roundSize: 50 } } });
    r.run({ op: 'updateStudyOptions', setId: set.id, patch: { learn: { mc: false } } });
    r.run({ op: 'updateStudyOptions', setId: set.id, patch: { learn: { written: false } } });
    r.run({ op: 'updateStudyOptions', setId: set.id, patch: { learn: { mc: false, written: false, roundSize: 10 } } });
    r.run({ op: 'updateSettings', patch: { study: { learn: { mc: false } } } });
    r.run({ op: 'updateSettings', patch: { study: { learn: { written: false } } } });
    r.run({ op: 'updateSettings', patch: { study: { learn: { mc: false, written: false } } } });
    r.run({ op: 'updateSettings', patch: { study: { learn: { roundSize: 15, mc: false, retype: true } } } });
    r.run({
      op: 'updateSettings',
      patch: {
        study: {
          answerWith: 'term', shuffle: true, copyAnswer: true, autoAdvance: true, audio: false,
          tolerance: { articles: true, abbreviations: true, multipleAnswers: true, parentheses: true, ignoreCase: true, ignoreAccents: false, typos: false },
          learn: { roundSize: 7, mc: true, written: true, retype: false },
        },
      },
    });
    r.run({ op: 'updateSet', setId: set.id, patch: { studyOptions: null } });
    r.run({ op: 'updateSet', setId: set.id, patch: { studyOptions: { audio: true, learn: { retype: true } } } });
    r.run({ op: 'reload' });
    r.finish();
  }
  // Backup export / import (db.test.js "Backup export / import").
  {
    const r = new Runner({ name: 'backup', seed: 14, clock0: 1000 });
    const a = r.run({ op: 'createSet', args: { title: 'Personen', termLang: 'fr', cards: SAMPLE } }).result;
    const b = r.run({ op: 'createSet', clock: 2000, args: { title: 'Farben', termLang: 'en', cards: [{ term: 'red', definition: 'rot' }] } }).result;
    r.run({ op: 'recordAnswer', setId: a.id, cardId: a.cards[0].id, correct: true, at: new Date(2026, 9, 10, 12).getTime() });
    r.run({ op: 'recordAnswer', setId: a.id, cardId: a.cards[1].id, correct: false, at: new Date(2026, 9, 11, 12).getTime() });
    r.run({ op: 'updateSettings', patch: { theme: 'dark', study: { tolerance: { typos: true } } } });
    r.run({ op: 'updateStudyOptions', setId: b.id, patch: { answerWith: 'definition' } });
    r.run({ op: 'saveSession', setId: a.id, state: { v: 1, round: 1 } });
    r.run({ op: 'saveLearn', setId: b.id, state: { v: 1, round: 1 } });
    const backup = clone(r.db.exportAll());
    jsonTextInputs.push(backup);
    const edited = clone(backup);
    edited.sets = edited.sets.filter((s) => s.id === a.id);
    edited.sets[0].title = 'Personen (Backup)';
    edited.sets.push({ id: 'brandnew', title: 'Neu', termLang: 'it', defLang: 'de', cards: [{ id: 'k1', term: 'ciao', definition: 'hallo' }] });
    edited.progress = {};
    edited.settings = { theme: 'light' };
    edited.activity = { '2026-10-11': 7, '2026-01-01': 2 };
    r.run({ op: 'importAll', data: edited, mode: 'merge' });
    r.run({ op: 'importAll', data: backup });
    r.run({ op: 'importAll', data: backup });
    for (const data of INVALID_BACKUPS) r.run({ op: 'importAll', data, mode: 'replace' });
    r.run({ op: 'createSet', args: { title: 'Lokal', termLang: 'fr', cards: SAMPLE } });
    r.run({
      op: 'importAll',
      mode: 'replace',
      data: {
        app: 'wortschatz',
        version: 1,
        sets: [{ id: 'only', title: 'Einzig', termLang: 'fr', defLang: 'de', cards: [{ id: 'c', term: 'la rue', definition: 'die Strasse' }] }],
        progress: { only: { c: { correct: 2, incorrect: 0, streak: 2, streakBefore: 1, lastResult: 'correct', lastAnsweredAt: 1 } } },
      },
    });
    r.run({
      op: 'importAll',
      data: {
        app: 'wortschatz',
        version: 1,
        sets: [
          { id: 'same', title: 'Eins', cards: [{ id: 'c1', term: 'a', definition: 'b' }] },
          { id: 'same', title: 'Zwei', cards: [{ id: 'c2', term: 'c', definition: 'd' }] },
        ],
        progress: { same: { c1: { correct: 1, streak: 1 }, ghost: { correct: 3, streak: 3 } } },
      },
    });
    r.run({ op: 'importAll', data: { app: 'wortschatz', version: 1, sets: [] }, mode: 'replace' });
    r.run({ op: 'importAll', data: backup, mode: 'replace' });
    r.run({ op: 'reload' });
    r.run({ op: 'clearAll' });
    r.run({ op: 'importAll', data: backup, mode: 'replace' });
    r.finish();
  }
  // Undo of deleteSet (snapshotSet / restoreSet).
  {
    const r = new Runner({ name: 'undo', seed: 15, clock0: 1000 });
    const keep = r.run({ op: 'createSet', args: { title: 'keep', termLang: 'fr', cards: SAMPLE } }).result;
    const set = r.run({ op: 'createSet', args: { title: 'gone', termLang: 'fr', cards: SAMPLE } }).result;
    r.run({ op: 'recordAnswer', setId: set.id, cardId: set.cards[0].id, correct: true });
    r.run({ op: 'saveSession', setId: set.id, state: { v: 1, round: 1, queue: ['b:t', 'c:t'], roundAnswered: [{ qid: 'a:t', correct: true }], finishedAt: null } });
    r.run({ op: 'saveLearn', setId: set.id, state: { v: 1, round: 2 } });
    const snapshot = r.run({ op: 'snapshotSet', setId: set.id }).result;
    r.run({ op: 'deleteSet', setId: set.id });
    r.run({ op: 'restoreSet', snapshot });
    r.run({ op: 'clearLearn', setId: set.id });
    const bare = r.run({ op: 'snapshotSet', setId: set.id }).result;
    r.run({ op: 'saveLearn', setId: set.id, state: { v: 1, stale: true } });
    r.run({ op: 'restoreSet', snapshot: bare });
    r.run({ op: 'snapshotSet', setId: 'unknown' });
    r.run({ op: 'restoreSet', snapshot: null });
    r.run({ op: 'restoreSet', snapshot: { set: { title: 'ohne id' } } });
    r.run({ op: 'deleteSet', setId: keep.id });
    r.run({ op: 'restoreSet', snapshot: { set: { id: keep.id, title: '  wieder da ', cards: [{ id: 'z', term: 'z', definition: 'z' }, { id: 'z', term: 'y', definition: 'y' }, { term: '' }] }, progress: { z: { correct: 1, streak: 1 }, q: { correct: 1 } }, session: 'x', learn: { v: 1 } } });
    r.finish();
  }
  // Corrupt storage (db.test.js "Robustness").
  {
    const garbage = '{not json';
    const r = new Runner({
      name: 'corrupt',
      seed: 16,
      clock0: 1000,
      initial: { sets: garbage, settings: garbage, activity: garbage, 'progress:s1': garbage, 'session:s1': garbage, meta: garbage },
    });
    r.run({ op: 'createSet', args: { title: 'Neu', termLang: 'fr', cards: SAMPLE } });
    r.run({ op: 'clearAll' });
    r.finish();
  }
  {
    const r = new Runner({
      name: 'wrongly-typed',
      seed: 17,
      clock0: 1000,
      initial: {
        sets: JSON.stringify([
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
        settings: JSON.stringify({ theme: 7, study: { tolerance: 'none' } }),
        activity: JSON.stringify({ '2026-10-11': 3, '2026-10-12': -1, foo: 2, '2026-10-13': 'x' }),
        'progress:s1': JSON.stringify({ c1: { correct: '2', streak: 2 }, c2: 'bad' }),
        'session:s1': JSON.stringify([1, 2, 3]),
        'learn:s1': '{not json',
        'learn:s2': JSON.stringify([1, 2]),
        'learn:s3': JSON.stringify('state'),
        'learn:orphan': JSON.stringify({ v: 1 }),
      },
    });
    r.run({ op: 'saveLearn', setId: 's1', state: { v: 1, round: 2 } });
    r.run({ op: 'updateSet', setId: 's1', patch: { cards: [{ id: 'c1', term: 'le nom', definition: 'der Name' }, { term: 'neu', definition: 'x' }] } });
    r.run({ op: 'importAll', data: { app: 'wortschatz', version: 1, sets: [] }, mode: 'replace' });
    r.finish();
  }
}

// ---------------------------------------------------------------------------
// A real web library and its backup (the user's 52 cards, answers, sessions)

function webLibrary() {
  const r = new Runner({ name: 'web-library', seed: 777, clock0: Date.UTC(2026, 9, 5, 7, 30) });
  const fr = r.run({
    op: 'createSet',
    args: { title: 'Französisch – Unité 1: Les personnes', description: 'Aus dem Lehrmittel, Seite 12', termLang: 'fr', defLang: 'de', cards: userCards },
  }).result;
  const en = r.run({
    op: 'createSet',
    clock: clock + 60000,
    args: { title: 'Englisch – Colours', termLang: 'en', defLang: 'de', cards: fixturePairs.slice(0, 12).map((c, i) => ({ ...c, starred: i % 4 === 0 })) },
  }).result;
  const engine = mulberry32(31337);
  // Three study days with answers on most cards.
  for (let day = 0; day < 3; day++) {
    clock = Date.UTC(2026, 9, 6 + day, 16, 0);
    for (let i = 0; i < fr.cards.length; i++) {
      if (engine() < 0.7) r.run({ op: 'recordAnswer', setId: fr.id, cardId: fr.cards[i].id, correct: engine() < 0.65, at: clock + i * 7000 });
    }
    r.run({ op: 'recordAnswer', setId: en.id, cardId: en.cards[day].id, correct: day !== 1, at: clock + 500000 });
  }
  r.run({ op: 'overrideLastAnswer', setId: en.id, cardId: en.cards[1].id });
  r.run({ op: 'toggleStar', setId: fr.id, cardId: fr.cards[5].id });
  r.run({ op: 'updateCard', setId: fr.id, cardId: fr.cards[7].id, changes: { definition: `${fr.cards[7].definition} (Anrede)` } });
  r.run({ op: 'updateSettings', patch: { theme: 'dark', study: { tolerance: { ignoreAccents: true }, learn: { roundSize: 10 } } } });
  r.run({ op: 'updateStudyOptions', setId: fr.id, patch: { answerWith: 'term', learn: { retype: true } } });
  r.run({ op: 'updateStudyOptions', setId: en.id, patch: { answerWith: 'both', shuffle: false } });
  // A running Write session and a running Learn session, straight from the engines.
  const now = Date.UTC(2026, 9, 9, 18, 0);
  clock = now;
  let session = createSession(r.db.getSet(fr.id).cards, { answerWith: 'term', shuffle: true }, { rng: engine, now });
  for (let i = 0; i < 9; i++) session = writeAnswer(session, engine() < 0.7, now + i * 9000);
  r.run({ op: 'saveSession', setId: fr.id, state: session });
  let learn = createLearn(r.db.getSet(fr.id).cards, { answerWith: 'term', learn: { roundSize: 10, mc: true, written: true } }, { progress: r.db.getProgress(fr.id), rng: engine, now });
  for (let i = 0; i < 12; i++) {
    if (learnRoundOver(learn)) learn = learnNextRound(learn, r.db.getSet(fr.id).cards, engine, now + i * 5000);
    else learn = learnAnswer(learn, engine() < 0.7, now + i * 5000);
  }
  r.run({ op: 'saveLearn', setId: fr.id, state: learn });
  let enLearn = createLearn(r.db.getSet(en.id).cards, { answerWith: 'definition', learn: { roundSize: 5, mc: true, written: false } }, { progress: r.db.getProgress(en.id), rng: engine, now });
  enLearn = learnAnswer(enLearn, false, now + 1000);
  r.run({ op: 'saveLearn', setId: en.id, state: enLearn });

  // The real web backup of this library.
  const backup = clone(r.db.exportAll());
  jsonTextInputs.push(backup);
  // Importing its own backup (merge) keeps the data and ends the sessions; replace too.
  r.run({ op: 'importAll', clock: now + HOUR, data: backup, mode: 'merge' });
  r.run({ op: 'reload' });
  r.run({ op: 'clearAll' });
  r.run({ op: 'importAll', data: backup, mode: 'replace' });
  r.run({ op: 'recordAnswer', clock: now + DAY, setId: fr.id, cardId: fr.cards[0].id, correct: true });
  r.finish();

  // An empty Mac library takes over the web backup.
  const m = new Runner({ name: 'web-backup-import', seed: 778, clock0: Date.UTC(2026, 9, 12, 9, 0) });
  m.run({ op: 'importAll', data: backup, mode: 'replace' });
  m.run({ op: 'reload' });
  m.run({ op: 'importAll', data: backup });
  m.run({ op: 'createSet', args: { title: 'Neu auf dem Mac', termLang: 'fr', cards: SAMPLE } });
  m.run({ op: 'importAll', data: backup });
  m.run({ op: 'importAll', data: backup, mode: 'replace' });
  m.finish();

  const at = Date.UTC(2026, 9, 12, 9, 0);
  clock = at;
  const fresh = createDb(() => memoryStorage(), { now: () => at });
  fresh.importAll(clone(backup), { mode: 'replace' });
  cases.add('webBackup', [backup, at], fresh.exportAll());
}

// ---------------------------------------------------------------------------
// backup.js: setToText and readJsonFile

function setToTextCases() {
  const sample = {
    cards: [
      { term: 'le monsieur, messieurs', definition: 'der Herr' },
      { term: 'la mademoiselle', definition: 'das Fräulein,\ndie Frau' },
      { term: ' ', definition: '' },
    ],
  };
  const OPTS = [
    undefined,
    { termSep: '\t', cardSep: '\n' },
    { termSep: ' - ', cardSep: '\n' },
    { termSep: ',', cardSep: ';' },
    { termSep: ', ', cardSep: ';' },
    { termSep: ' - ', cardSep: ';' },
    { termSep: '\t', cardSep: ';' },
    { termSep: ', ', cardSep: '\n' },
    { termSep: ';', cardSep: '\n' },
    { termSep: '|', cardSep: '\n\n' },
    { termSep: ' ', cardSep: '\n' },
    { termSep: '', cardSep: '' },
    { termSep: '=', cardSep: ' ; ' },
    { termSep: '"', cardSep: '\n' },
    { termSep: ' – ', cardSep: '\r\n' },
  ];
  const add = (set, opts) => cases.add('setToText', opts === undefined ? [set] : [set, opts], setToText(set, opts));
  for (const opts of OPTS) {
    add(sample, opts);
    add({ cards: userCards }, opts);
  }
  add({ cards: [{ term: 'say "hi"', definition: 'a;b' }] }, { termSep: '\t', cardSep: ';' });
  add({ cards: [{ term: 'a ; b', definition: 'c;  d;' }] }, { termSep: ' - ', cardSep: ';' });
  add({ cards: [{ term: 'aimer', definition: 'lieben; mögen' }] });
  add({ cards: [{ term: 'aimer', definition: 'lieben; mögen' }, { term: 'le temps', definition: 'das Wetter; die Zeit' }] }, { termSep: ' - ', cardSep: ';' });
  add({ cards: [] });
  // Every fixture list with every option.
  for (const { text } of fixtureTexts()) {
    const cards = parseVocab(text).cards.map((c) => ({ term: c.term, definition: c.definition }));
    for (const opts of OPTS.slice(0, 8)) add({ cards }, opts);
  }
  // Fuzz: separators, quotes, semicolons and every kind of whitespace inside fields.
  const r = mulberry32(5150);
  const ALPHA = ['a', 'é', ' ', ' ', '  ', ';', ' ; ', ',', '"', '\t', '\n', '\r', '\r\n', ' ', ' ', '　', '﻿', '-', ' - ', '|', 'ß', '😀', 'x', 'Wort'];
  const SEPS = ['\t', '\n', ';', ' ; ', ',', ', ', ' - ', '|', ' ', '', '"', ' ;', 'x'];
  for (let i = 0; i < 600; i++) {
    const n = randInt(r, 0, 5);
    const cards = [];
    for (let k = 0; k < n; k++) {
      const field = () => {
        let s = '';
        const len = randInt(r, 0, 8);
        for (let j = 0; j < len; j++) s += pick(r, ALPHA);
        return s;
      };
      cards.push({ term: field(), definition: field() });
    }
    add({ cards }, { termSep: pick(r, SEPS), cardSep: pick(r, SEPS) });
  }
}

async function readJsonCases() {
  const inputs = [
    '{"app":"wortschatz"}',
    '﻿{"app":"wortschatz"}',
    'nope',
    '[1,2]',
    'null',
    '5',
    '"x"',
    '',
    '  {"a": [1, 2, {"b": null}], "c": "ä\\u00e9"}  ',
    '{"a":1,}',
    '{"nested":{"deep":{"x":[true,false,null]}},"n":-0.5e3}',
    '\n\t{}\r\n',
    '{"x": "\\ud83d\\ude00"}',
  ];
  for (const text of inputs) {
    let out;
    try {
      out = await readJsonFile({ text: async () => text });
    } catch (e) {
      out = { throws: e.message };
    }
    cases.add('readJsonFile', [text], out);
  }
}

// The key order of Backup.jsonText (Swift): known keys in the web app's creation order, other
// keys sorted by UTF-16 code units. (Integer-like keys would be enumerated first by JS; the
// inputs here have none.)
const KEY_RANK = [
  'app', 'version', 'exportedAt', 'sets', 'progress', 'settings', 'activity',
  'id', 'title', 'description', 'termLang', 'defLang', 'cards', 'term', 'definition', 'starred',
  'studyOptions', 'theme', 'study', 'answerWith', 'shuffle', 'copyAnswer', 'autoAdvance', 'audio',
  'tolerance', 'articles', 'abbreviations', 'multipleAnswers', 'parentheses', 'ignoreCase', 'ignoreAccents',
  'typos', 'learn', 'roundSize', 'mc', 'written', 'retype', 'createdAt', 'updatedAt', 'lastStudiedAt',
  'correct', 'incorrect', 'streak', 'streakBefore', 'lastResult', 'lastAnsweredAt',
];
function canonicalOrder(v) {
  if (Array.isArray(v)) return v.map(canonicalOrder);
  if (v && typeof v === 'object') {
    const keys = Object.keys(v).sort((a, b) => {
      const x = KEY_RANK.indexOf(a);
      const y = KEY_RANK.indexOf(b);
      if (x >= 0 && y >= 0) return x - y;
      if (x >= 0) return -1;
      if (y >= 0) return 1;
      return a < b ? -1 : a > b ? 1 : 0;
    });
    const out = {};
    for (const k of keys) out[k] = canonicalOrder(v[k]);
    return out;
  }
  return v;
}

const jsonTextInputs = [];
function jsonTextCases() {
  for (const value of jsonTextInputs) cases.add('jsonText', [value], JSON.stringify(canonicalOrder(value), null, 2));
  const r = mulberry32(6060);
  const STRINGS = ['', 'a', 'é', '"', '\\', '/', '\u0001', '\u001f', '\u007f', '\u2028', '\b\f\n\r\t', '😀', 'ß', 'x y', '{}', '[1]'];
  const NUMBERS = [0, 1, -1, 0.1, 1e21, 1e-7, 123456789012345680000, 1.5e300, -2.5, 1760000000000, 0.000001];
  const value = (depth) => {
    const x = r();
    if (depth > 3 || x < 0.3) return pick(r, STRINGS) + pick(r, STRINGS);
    if (x < 0.5) return pick(r, NUMBERS);
    if (x < 0.6) return pick(r, [true, false, null]);
    if (x < 0.8) {
      const n = randInt(r, 0, 4);
      const out = [];
      for (let i = 0; i < n; i++) out.push(value(depth + 1));
      return out;
    }
    const n = randInt(r, 0, 5);
    const out = {};
    for (let i = 0; i < n; i++) out[pick(r, [...KEY_RANK.slice(0, 20), 'zeta', 'Alpha', 'a b', 'é', 'k' + randInt(r, 0, 9)])] = value(depth + 1);
    return out;
  };
  for (let i = 0; i < 150; i++) {
    const v = value(0);
    cases.add('jsonText', [v], JSON.stringify(canonicalOrder(v), null, 2));
  }
}

// ---------------------------------------------------------------------------
// Run

testScenarios();
webLibrary();
for (let i = 0; i < 110; i++) fuzzScenario(i);
// Around the autumn and spring DST switches in Zurich (activity day keys).
for (let i = 110; i < 120; i++) fuzzScenario(i, { clock0: Date.UTC(2026, 9, 24, 20, 0) + (i - 110) * HOUR });
for (let i = 120; i < 126; i++) fuzzScenario(i, { clock0: Date.UTC(2027, 2, 27, 20, 0) + (i - 120) * HOUR });
for (let i = 0; i < 45; i++) fuzzScenario(200 + i, { initial: fuzzInitial(i), steps: [3, 12] });
setToTextCases();
await readJsonCases();
jsonTextCases();

cases.emit();
