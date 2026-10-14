// Persistence layer over a localStorage-like store.
//
// Pure and DOM-free: storage is injected through `getStorage` and resolved
// lazily on first use, so this module can be imported under jsc. Values are
// parsed once per key and cached per db instance; the cache is updated on
// writes and invalidated by cross-tab `storage` events. Every public method
// returns copies, never cached objects.
//
// Write sessions (`session:<setId>`) and Learn sessions (`learn:<setId>`) are
// transient: they follow the same lifecycle (cleared with the set, on a
// progress reset and when cards are added or removed) and are never exported.
// Karteikarten decks (`flashcards:<setId>`, core/flashcards.js) are the learner's
// own sorting, not progress: they go with the set (delete, undo, import, clear
// all) but survive progress resets and card edits (the deck follows the set
// instead), and are never exported either.
//
// Subscribers receive `{ type: 'local' | 'external', keys: string[] | null }`
// once per public write operation (keys without the storage prefix; null when
// another tab cleared the whole storage).

import { uid } from '../lib/id.js';
import { dateKey } from '../lib/time.js';
import { applyAnswer, applyOverride, normalizeProgress } from '../core/mastery.js';
import { parseDeck } from '../core/flashcards.js';

const PREFIX = 'wortschatz:v1:';
const SCHEMA_VERSION = 1;
const KEY_SETS = 'sets';
const KEY_SETTINGS = 'settings';
const KEY_ACTIVITY = 'activity';
const KEY_META = 'meta';
const progressKey = (setId) => `progress:${setId}`;
const sessionKey = (setId) => `session:${setId}`;
const learnKey = (setId) => `learn:${setId}`;
const flashcardsKey = (setId) => `flashcards:${setId}`;
// Per-set keys that belong to a set (removed with it).
const SET_KEY_RE = /^(progress|session|learn|flashcards):(.*)$/;

const LANG_CODES = ['fr', 'en', 'es', 'it', 'de', 'other'];
const ANSWER_WITH = ['term', 'definition', 'both'];
const THEMES = ['system', 'light', 'dark'];
const BOOLEAN_OPTIONS = ['shuffle', 'copyAnswer', 'autoAdvance', 'audio'];
const TOLERANCE_KEYS = ['articles', 'abbreviations', 'multipleAnswers', 'parentheses', 'ignoreCase', 'ignoreAccents', 'typos'];
const LEARN_BOOLEANS = ['mc', 'written', 'retype'];
const LEARN_ROUND_SIZE_MAX = 50;
const DATE_KEY_RE = /^\d{4}-\d{2}-\d{2}$/;

const DEFAULT_TITLE = 'Unbenanntes Lernset';
const COPY_SUFFIX = ' (Kopie)';

const MSG = {
  quota: 'Der Speicher für Wortschatz ist voll. Exportiere ein Backup und lösche Lernsets, die du nicht mehr brauchst.',
  setNotFound: 'Dieses Lernset wurde nicht gefunden.',
  cardNotFound: 'Diese Karte wurde nicht gefunden.',
  emptyCard: 'Begriff und Definition dürfen nicht beide leer sein.',
  notBackup: 'Diese Datei ist kein Wortschatz-Backup.',
  newerBackup: 'Dieses Backup stammt aus einer neueren Version von Wortschatz und kann nicht importiert werden.',
  noSets: 'Das Backup ist unvollständig: Die Lernsets fehlen.',
  badSet: (n) => `Das Backup ist beschädigt: Lernset Nr. ${n} ist ungültig.`,
  badPart: (name) => `Das Backup ist beschädigt: Der Bereich «${name}» ist ungültig.`,
  badSnapshot: 'Dieses Lernset kann nicht wiederhergestellt werden.',
};

function deepFreeze(obj) {
  for (const value of Object.values(obj)) {
    if (value && typeof value === 'object' && !Object.isFrozen(value)) deepFreeze(value);
  }
  return Object.freeze(obj);
}

export const DEFAULT_STUDY_OPTIONS = deepFreeze({
  answerWith: 'term',
  shuffle: true,
  copyAnswer: true,
  autoAdvance: true,
  audio: false,
  tolerance: {
    articles: true,
    abbreviations: true,
    multipleAnswers: true,
    parentheses: true,
    ignoreCase: true,
    ignoreAccents: false,
    typos: false,
  },
  // Learn mode ("Lernen"): terms per round, question types (at least one stays
  // on) and whether a missed written answer has to be typed once.
  learn: {
    roundSize: 7,
    mc: true,
    written: true,
    retype: false,
  },
});

export const DEFAULT_SETTINGS = deepFreeze({
  theme: 'system',
  study: DEFAULT_STUDY_OPTIONS,
});

// ---------------------------------------------------------------------------
// Generic helpers

function isObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function hasOwn(obj, key) {
  return Object.prototype.hasOwnProperty.call(obj, key);
}

function clone(v) {
  return v === undefined ? undefined : JSON.parse(JSON.stringify(v));
}

function cleanText(v) {
  if (v == null) return '';
  return String(v).replace(/\r\n?/g, '\n').trim();
}

function finiteOr(v, fallback) {
  return typeof v === 'number' && Number.isFinite(v) ? v : fallback;
}

function dbError(code, message, cause) {
  const err = new Error(message);
  err.code = code;
  if (cause !== undefined) err.cause = cause;
  return err;
}

// ---------------------------------------------------------------------------
// Study options / settings sanitising and merging

// Valid part of a partial `learn` object. Switching both question types off is
// not a valid choice, so that part of such a patch is ignored.
function sanitizeLearnPatch(raw) {
  const out = {};
  if (!isObject(raw)) return out;
  const size = raw.roundSize;
  if (Number.isInteger(size) && size >= 1 && size <= LEARN_ROUND_SIZE_MAX) out.roundSize = size;
  for (const key of LEARN_BOOLEANS) {
    if (typeof raw[key] === 'boolean') out[key] = raw[key];
  }
  if (out.mc === false && out.written === false) {
    delete out.mc;
    delete out.written;
  }
  return out;
}

// Keeps only known keys with valid values (a deep partial StudyOptions).
function sanitizeStudyPatch(patch) {
  const out = {};
  if (!isObject(patch)) return out;
  if (ANSWER_WITH.includes(patch.answerWith)) out.answerWith = patch.answerWith;
  for (const key of BOOLEAN_OPTIONS) {
    if (typeof patch[key] === 'boolean') out[key] = patch[key];
  }
  if (isObject(patch.tolerance)) {
    const tol = {};
    for (const key of TOLERANCE_KEYS) {
      if (typeof patch.tolerance[key] === 'boolean') tol[key] = patch.tolerance[key];
    }
    if (Object.keys(tol).length) out.tolerance = tol;
  }
  const learn = sanitizeLearnPatch(patch.learn);
  if (Object.keys(learn).length) out.learn = learn;
  return out;
}

// Merges partial learn options. When the result would switch off both question
// types, the patch's choice wins and the other type is switched back on.
function mergeLearn(base, patch) {
  const out = { ...(base || {}), ...(patch || {}) };
  if (out.mc === false && out.written === false) {
    const p = patch || {};
    if (p.mc === false) out.written = true;
    else if (p.written === false) out.mc = true;
    else {
      out.mc = true;
      out.written = true;
    }
  }
  return out;
}

// Deep-merges a sanitised partial into a (full or partial) options object.
function mergeStudy(base, patch) {
  const src = isObject(base) ? base : {};
  const p = sanitizeStudyPatch(patch);
  const out = { ...src, ...p };
  if (src.tolerance || p.tolerance) out.tolerance = { ...(src.tolerance || {}), ...(p.tolerance || {}) };
  if (src.learn || p.learn) {
    const learn = mergeLearn(sanitizeLearnPatch(src.learn), p.learn);
    if (Object.keys(learn).length) out.learn = learn;
    else delete out.learn;
  }
  return out;
}

function fullStudyOptions(...layers) {
  let out = clone(DEFAULT_STUDY_OPTIONS);
  for (const layer of layers) out = mergeStudy(out, layer);
  return out;
}

function mergeSettings(base, patch) {
  const src = isObject(base) ? base : DEFAULT_SETTINGS;
  const p = isObject(patch) ? patch : {};
  return {
    theme: THEMES.includes(p.theme) ? p.theme : THEMES.includes(src.theme) ? src.theme : DEFAULT_SETTINGS.theme,
    study: fullStudyOptions(src.study, p.study),
  };
}

// ---------------------------------------------------------------------------
// Stored-data sanitisers (corrupt or foreign data never crashes the app)

function buildCards(input, { keepIds = true, previousById = null } = {}) {
  const out = [];
  const seen = new Set();
  if (!Array.isArray(input)) return out;
  for (const raw of input) {
    if (!isObject(raw)) continue;
    const term = cleanText(raw.term);
    const definition = cleanText(raw.definition);
    if (!term && !definition) continue;
    let id = keepIds && typeof raw.id === 'string' && raw.id !== '' && !seen.has(raw.id) ? raw.id : null;
    while (!id || seen.has(id)) id = uid();
    seen.add(id);
    const prev = previousById ? previousById.get(id) : null;
    const starred = typeof raw.starred === 'boolean' ? raw.starred : prev ? prev.starred : false;
    out.push({ id, term, definition, starred });
  }
  return out;
}

function sanitizeSet(raw, fallbackNow) {
  if (!isObject(raw) || typeof raw.id !== 'string' || raw.id === '') return null;
  const createdAt = finiteOr(raw.createdAt, fallbackNow);
  const studyOptions = sanitizeStudyPatch(raw.studyOptions);
  return {
    id: raw.id,
    title: cleanText(raw.title) || DEFAULT_TITLE,
    description: cleanText(raw.description),
    termLang: LANG_CODES.includes(raw.termLang) ? raw.termLang : 'fr',
    defLang: LANG_CODES.includes(raw.defLang) ? raw.defLang : 'de',
    cards: buildCards(raw.cards, { keepIds: true }),
    studyOptions: Object.keys(studyOptions).length ? studyOptions : null,
    createdAt,
    updatedAt: finiteOr(raw.updatedAt, createdAt),
    lastStudiedAt: finiteOr(raw.lastStudiedAt, null),
  };
}

function sanitizeProgressMap(raw, validIds = null) {
  const out = {};
  if (!isObject(raw)) return out;
  for (const id of Object.keys(raw)) {
    if (validIds && !validIds.has(id)) continue;
    if (isObject(raw[id])) out[id] = normalizeProgress(raw[id]);
  }
  return out;
}

function sanitizeActivity(raw) {
  const out = {};
  if (!isObject(raw)) return out;
  for (const key of Object.keys(raw)) {
    const n = raw[key];
    if (DATE_KEY_RE.test(key) && typeof n === 'number' && Number.isFinite(n) && n > 0) out[key] = Math.floor(n);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Storage

export function memoryStorage(initial = null) {
  const map = new Map();
  if (isObject(initial)) {
    for (const key of Object.keys(initial)) map.set(key, String(initial[key]));
  }
  return {
    getItem(key) {
      const k = String(key);
      return map.has(k) ? map.get(k) : null;
    },
    setItem(key, value) {
      map.set(String(key), String(value));
    },
    removeItem(key) {
      map.delete(String(key));
    },
    clear() {
      map.clear();
    },
    key(index) {
      const keys = Array.from(map.keys());
      return index >= 0 && index < keys.length ? keys[index] : null;
    },
    get length() {
      return map.size;
    },
  };
}

function isStorageLike(s) {
  return !!s && typeof s.getItem === 'function' && typeof s.setItem === 'function' && typeof s.removeItem === 'function';
}

// ---------------------------------------------------------------------------
// Db factory

export function createDb(getStorage, { now = () => Date.now() } = {}) {
  let storage = null;
  const cache = new Map();
  const listeners = new Set();
  const changedKeys = new Set();
  let depth = 0;
  let metaChecked = false;
  let detachExternal = null;
  // While `atomically` runs: storage key -> raw value before the first change.
  let journal = null;

  // Resolved on first use. Inaccessible storage (e.g. blocked site data)
  // falls back to memory so the app still works for this visit.
  function store() {
    if (storage) return storage;
    let s = null;
    try {
      s = typeof getStorage === 'function' ? getStorage() : getStorage;
    } catch {
      s = null;
    }
    storage = isStorageLike(s) ? s : memoryStorage();
    return storage;
  }

  function read(key, sanitize) {
    if (cache.has(key)) return cache.get(key);
    let raw = null;
    try {
      raw = store().getItem(PREFIX + key);
    } catch {
      raw = null;
    }
    let parsed = null;
    if (typeof raw === 'string' && raw !== '') {
      try {
        parsed = JSON.parse(raw);
      } catch {
        parsed = null;
      }
    }
    const value = sanitize(parsed);
    cache.set(key, value);
    return value;
  }

  // Remembers a key's stored value before an atomic operation first changes it.
  function track(key) {
    if (!journal || journal.has(key)) return;
    let raw = null;
    try {
      raw = store().getItem(PREFIX + key);
    } catch {
      raw = null;
    }
    journal.set(key, typeof raw === 'string' ? raw : null);
  }

  function writeRaw(key, value) {
    const raw = JSON.stringify(value);
    track(key);
    try {
      store().setItem(PREFIX + key, raw);
    } catch (err) {
      cache.delete(key);
      throw dbError('QUOTA', MSG.quota, err);
    }
    cache.set(key, value);
    changedKeys.add(key);
  }

  function write(key, value) {
    writeRaw(key, value);
    if (!metaChecked) {
      metaChecked = true;
      const meta = read(KEY_META, (v) => (isObject(v) ? v : null));
      if (!meta || meta.schemaVersion !== SCHEMA_VERSION) {
        try {
          writeRaw(KEY_META, { schemaVersion: SCHEMA_VERSION });
        } catch {
          // Informational only; the next session retries.
          metaChecked = false;
        }
      }
    }
  }

  function remove(key) {
    track(key);
    try {
      store().removeItem(PREFIX + key);
    } catch {
      // Ignore: the next read re-parses whatever is left.
    }
    cache.delete(key);
    changedKeys.add(key);
  }

  // Removes progress/session/learn/flashcards keys that do not belong to any of `keepIds`
  // (only possible when the storage can enumerate its keys).
  function removeOrphans(keepIds) {
    const s = store();
    if (typeof s.key !== 'function' || typeof s.length !== 'number') return;
    const doomed = [];
    for (let i = 0; i < s.length; i++) {
      let full = null;
      try {
        full = s.key(i);
      } catch {
        full = null;
      }
      if (typeof full !== 'string' || !full.startsWith(PREFIX)) continue;
      const key = full.slice(PREFIX.length);
      const m = SET_KEY_RE.exec(key);
      if (m && !keepIds.has(m[2])) doomed.push(key);
    }
    for (const key of doomed) remove(key);
  }

  function emit(event) {
    for (const fn of Array.from(listeners)) {
      try {
        fn(event);
      } catch (err) {
        if (typeof globalThis.reportError === 'function') globalThis.reportError(err);
      }
    }
  }

  // Groups the writes of one public operation into a single notification.
  function mutate(fn) {
    depth++;
    try {
      return fn();
    } finally {
      depth--;
      if (depth === 0 && changedKeys.size) {
        const keys = Array.from(changedKeys);
        changedKeys.clear();
        emit({ type: 'local', keys });
      }
    }
  }

  // Runs `fn` all-or-nothing: if any write fails (e.g. QUOTA), every key it
  // touched gets its previous value back before the error is rethrown.
  function atomically(fn) {
    if (journal) return fn();
    const saved = new Map();
    journal = saved;
    try {
      return fn();
    } catch (err) {
      journal = null;
      rollback(saved);
      throw err;
    } finally {
      journal = null;
    }
  }

  // Shrinking keys go first and growing keys last, so storage never needs
  // more room than before the failed write or after the rollback.
  function rollback(saved) {
    const s = store();
    const steps = [];
    for (const [key, before] of saved) {
      let now = null;
      try {
        now = s.getItem(PREFIX + key);
      } catch {
        now = null;
      }
      const growth = (before === null ? 0 : before.length) - (typeof now === 'string' ? now.length : 0);
      steps.push({ key, before, growth });
    }
    steps.sort((a, b) => a.growth - b.growth);
    for (const { key, before } of steps) {
      try {
        if (before === null) s.removeItem(PREFIX + key);
        else s.setItem(PREFIX + key, before);
      } catch {
        // Best effort: keep restoring the remaining keys.
      }
      cache.delete(key);
    }
    if (saved.has(KEY_META)) metaChecked = false;
  }

  function onStorageEvent(e) {
    if (!e) return;
    if (e.storageArea && storage && e.storageArea !== storage) return;
    if (e.key === null || e.key === undefined) {
      cache.clear();
      emit({ type: 'external', keys: null });
      return;
    }
    if (typeof e.key !== 'string' || !e.key.startsWith(PREFIX)) return;
    const key = e.key.slice(PREFIX.length);
    cache.delete(key);
    emit({ type: 'external', keys: [key] });
  }

  function attachExternal() {
    if (detachExternal || typeof globalThis.addEventListener !== 'function') return;
    const handler = (e) => onStorageEvent(e);
    globalThis.addEventListener('storage', handler);
    detachExternal = () => {
      if (typeof globalThis.removeEventListener === 'function') globalThis.removeEventListener('storage', handler);
      detachExternal = null;
    };
  }

  // -- typed readers (return cached objects; never hand these out directly)

  const readSets = () =>
    read(KEY_SETS, (v) => {
      if (!Array.isArray(v)) return [];
      const out = [];
      const ids = new Set();
      const fallback = now();
      for (const raw of v) {
        const set = sanitizeSet(raw, fallback);
        if (set && !ids.has(set.id)) {
          ids.add(set.id);
          out.push(set);
        }
      }
      return out;
    });
  const readProgress = (setId) => read(progressKey(setId), (v) => sanitizeProgressMap(v));
  const readSession = (setId) => read(sessionKey(setId), (v) => (isObject(v) ? v : null));
  const readLearn = (setId) => read(learnKey(setId), (v) => (isObject(v) ? v : null));
  // Inconsistent or foreign decks read as no deck (the Mac drops them on read too).
  const readFlashcards = (setId) => read(flashcardsKey(setId), (v) => parseDeck(v));
  const readSettings = () => read(KEY_SETTINGS, (v) => mergeSettings(DEFAULT_SETTINGS, v));
  const readActivity = () => read(KEY_ACTIVITY, sanitizeActivity);

  function findSet(setId) {
    const sets = readSets();
    const index = sets.findIndex((s) => s.id === setId);
    return { sets, index, set: index >= 0 ? sets[index] : null };
  }

  function requireSet(setId) {
    const found = findSet(setId);
    if (!found.set) throw dbError('NOT_FOUND', MSG.setNotFound);
    return found;
  }

  function replaceSet(sets, index, next) {
    const copy = sets.slice();
    copy[index] = next;
    write(KEY_SETS, copy);
  }

  function newSetId(taken) {
    let id = uid();
    while (taken.has(id)) id = uid();
    return id;
  }

  // -- sets

  function listSets() {
    const sets = readSets();
    const recency = (s) => Math.max(s.lastStudiedAt || 0, s.updatedAt || 0);
    return clone(sets)
      .map((s, i) => ({ s, i }))
      .sort((a, b) => recency(b.s) - recency(a.s) || (b.s.createdAt || 0) - (a.s.createdAt || 0) || a.i - b.i)
      .map((x) => x.s);
  }

  function getSet(setId) {
    const { set } = findSet(setId);
    return set ? clone(set) : null;
  }

  function createSet({ title = '', description = '', termLang = 'fr', defLang = 'de', cards = [] } = {}) {
    return mutate(() => {
      const sets = readSets();
      const t = now();
      const set = {
        id: newSetId(new Set(sets.map((s) => s.id))),
        title: cleanText(title) || DEFAULT_TITLE,
        description: cleanText(description),
        termLang: LANG_CODES.includes(termLang) ? termLang : 'fr',
        defLang: LANG_CODES.includes(defLang) ? defLang : 'de',
        cards: buildCards(cards, { keepIds: false }),
        studyOptions: null,
        createdAt: t,
        updatedAt: t,
        lastStudiedAt: null,
      };
      write(KEY_SETS, [set, ...sets]);
      return clone(set);
    });
  }

  function updateSet(setId, patch = {}) {
    return mutate(() => {
      const { sets, index, set: old } = requireSet(setId);
      const p = isObject(patch) ? patch : {};
      const next = { ...old };
      let contentChanged = false;
      let removedIds = [];
      let structural = false;

      if (p.title !== undefined) {
        next.title = cleanText(p.title) || DEFAULT_TITLE;
        contentChanged = true;
      }
      if (p.description !== undefined) {
        next.description = cleanText(p.description);
        contentChanged = true;
      }
      if (LANG_CODES.includes(p.termLang)) {
        next.termLang = p.termLang;
        contentChanged = true;
      }
      if (LANG_CODES.includes(p.defLang)) {
        next.defLang = p.defLang;
        contentChanged = true;
      }
      if (p.studyOptions !== undefined) {
        const opts = sanitizeStudyPatch(p.studyOptions);
        next.studyOptions = Object.keys(opts).length ? opts : null;
      }
      if (Array.isArray(p.cards)) {
        const previousById = new Map(old.cards.map((c) => [c.id, c]));
        next.cards = buildCards(p.cards, { keepIds: true, previousById });
        const nextIds = new Set(next.cards.map((c) => c.id));
        removedIds = old.cards.filter((c) => !nextIds.has(c.id)).map((c) => c.id);
        structural = removedIds.length > 0 || next.cards.some((c) => !previousById.has(c.id));
        contentChanged = true;
      }
      if (contentChanged) next.updatedAt = now();

      replaceSet(sets, index, next);
      if (removedIds.length) {
        const progress = { ...readProgress(setId) };
        let pruned = false;
        for (const id of removedIds) {
          if (hasOwn(progress, id)) {
            delete progress[id];
            pruned = true;
          }
        }
        if (pruned) write(progressKey(setId), progress);
      }
      if (structural && readSession(setId)) remove(sessionKey(setId));
      if (structural && readLearn(setId)) remove(learnKey(setId));
      return clone(next);
    });
  }

  function deleteSet(setId) {
    return mutate(() => {
      const { sets, index } = findSet(setId);
      if (index >= 0) write(KEY_SETS, sets.filter((_, i) => i !== index));
      remove(progressKey(setId));
      remove(sessionKey(setId));
      remove(learnKey(setId));
      remove(flashcardsKey(setId));
      return index >= 0;
    });
  }

  function duplicateSet(setId) {
    return mutate(() => {
      const { sets, set } = requireSet(setId);
      const t = now();
      const copy = {
        ...clone(set),
        id: newSetId(new Set(sets.map((s) => s.id))),
        title: set.title + COPY_SUFFIX,
        cards: buildCards(set.cards, { keepIds: false }),
        createdAt: t,
        updatedAt: t,
        lastStudiedAt: null,
      };
      write(KEY_SETS, [copy, ...sets]);
      return clone(copy);
    });
  }

  // -- cards

  function updateCard(setId, cardId, changes = {}) {
    return mutate(() => {
      const { sets, index, set } = requireSet(setId);
      const pos = set.cards.findIndex((c) => c.id === cardId);
      if (pos < 0) throw dbError('NOT_FOUND', MSG.cardNotFound);
      const c = isObject(changes) ? changes : {};
      const card = set.cards[pos];
      const term = c.term !== undefined ? cleanText(c.term) : card.term;
      const definition = c.definition !== undefined ? cleanText(c.definition) : card.definition;
      if (!term && !definition) throw dbError('INVALID', MSG.emptyCard);
      const next = { ...card, term, definition, starred: typeof c.starred === 'boolean' ? c.starred : card.starred };
      const textChanged = term !== card.term || definition !== card.definition;
      const cards = set.cards.slice();
      cards[pos] = next;
      replaceSet(sets, index, { ...set, cards, updatedAt: textChanged ? now() : set.updatedAt });
      return clone(next);
    });
  }

  function toggleStar(setId, cardId) {
    return mutate(() => {
      const { sets, index, set } = requireSet(setId);
      const pos = set.cards.findIndex((c) => c.id === cardId);
      if (pos < 0) throw dbError('NOT_FOUND', MSG.cardNotFound);
      const cards = set.cards.slice();
      cards[pos] = { ...cards[pos], starred: !cards[pos].starred };
      replaceSet(sets, index, { ...set, cards });
      return cards[pos].starred;
    });
  }

  // -- progress

  function getProgress(setId) {
    return clone(readProgress(setId));
  }

  function recordAnswer(setId, cardId, correct, at = now()) {
    return mutate(() => {
      const { sets, index, set } = requireSet(setId);
      if (!set.cards.some((c) => c.id === cardId)) throw dbError('NOT_FOUND', MSG.cardNotFound);
      const time = finiteOr(at, now());
      const progress = { ...readProgress(setId) };
      const entry = applyAnswer(progress[cardId], !!correct, time);
      progress[cardId] = entry;
      write(progressKey(setId), progress);
      replaceSet(sets, index, { ...set, lastStudiedAt: Math.max(set.lastStudiedAt || 0, time) });
      const activity = { ...readActivity() };
      const day = dateKey(time);
      activity[day] = (activity[day] || 0) + 1;
      write(KEY_ACTIVITY, activity);
      return clone(entry);
    });
  }

  function overrideLastAnswer(setId, cardId) {
    return mutate(() => {
      const current = readProgress(setId);
      const prev = hasOwn(current, cardId) ? current[cardId] : undefined;
      if (!prev || prev.lastResult !== 'incorrect') return normalizeProgress(prev);
      const entry = applyOverride(prev);
      write(progressKey(setId), { ...current, [cardId]: entry });
      return clone(entry);
    });
  }

  function resetProgress(setId) {
    mutate(() => {
      remove(progressKey(setId));
      remove(sessionKey(setId));
      remove(learnKey(setId));
    });
  }

  // Forgets the progress of just these cards (they count as new again) and ends
  // the set's Write and Learn sessions, which were built on the old progress.
  // Returns how many progress entries were removed; no valid id is a no-op.
  function resetCardProgress(setId, cardIds) {
    const ids = new Set();
    for (const id of Array.isArray(cardIds) ? cardIds : []) {
      if (typeof id === 'string' && id !== '') ids.add(id);
    }
    if (!ids.size) return 0;
    return mutate(() => {
      const progress = { ...readProgress(setId) };
      let removed = 0;
      for (const id of ids) {
        if (hasOwn(progress, id)) {
          delete progress[id];
          removed++;
        }
      }
      if (removed) {
        if (Object.keys(progress).length) write(progressKey(setId), progress);
        else remove(progressKey(setId));
      }
      remove(sessionKey(setId));
      remove(learnKey(setId));
      return removed;
    });
  }

  // -- sessions

  function getSession(setId) {
    const s = readSession(setId);
    return s ? clone(s) : null;
  }

  function saveSession(setId, state) {
    if (!isObject(state)) {
      clearSession(setId);
      return;
    }
    mutate(() => {
      if (!findSet(setId).set) return;
      write(sessionKey(setId), clone(state));
    });
  }

  function clearSession(setId) {
    mutate(() => remove(sessionKey(setId)));
  }

  // -- learn sessions (same rules as Write sessions)

  function getLearn(setId) {
    const s = readLearn(setId);
    return s ? clone(s) : null;
  }

  function saveLearn(setId, state) {
    if (!isObject(state)) {
      clearLearn(setId);
      return;
    }
    mutate(() => {
      if (!findSet(setId).set) return;
      write(learnKey(setId), clone(state));
    });
  }

  function clearLearn(setId) {
    mutate(() => remove(learnKey(setId)));
  }

  // -- Karteikarten decks (not progress: kept on progress resets and card edits)

  function getFlashcards(setId) {
    const deck = readFlashcards(setId);
    return deck ? clone(deck) : null;
  }

  // Stores the set's deck (normalised to the Mac's keys); a non-deck or inconsistent value
  // clears it. Unknown sets are ignored.
  function saveFlashcards(setId, deck) {
    const parsed = parseDeck(deck);
    if (!parsed) {
      clearFlashcards(setId);
      return;
    }
    mutate(() => {
      if (!findSet(setId).set) return;
      write(flashcardsKey(setId), parsed);
    });
  }

  function clearFlashcards(setId) {
    mutate(() => remove(flashcardsKey(setId)));
  }

  // -- settings & study options

  function getSettings() {
    return clone(readSettings());
  }

  function updateSettings(patch) {
    return mutate(() => {
      const next = mergeSettings(readSettings(), patch);
      write(KEY_SETTINGS, next);
      return clone(next);
    });
  }

  function getStudyOptions(setId) {
    const { set } = findSet(setId);
    return fullStudyOptions(readSettings().study, set ? set.studyOptions : null);
  }

  function updateStudyOptions(setId, patch) {
    return mutate(() => {
      const { sets, index, set } = requireSet(setId);
      const merged = mergeStudy(set.studyOptions || {}, patch);
      replaceSet(sets, index, { ...set, studyOptions: Object.keys(merged).length ? merged : null });
      return getStudyOptions(setId);
    });
  }

  // -- activity

  function getActivity() {
    return clone(readActivity());
  }

  // -- backup

  function exportAll() {
    const sets = listSets();
    const progress = {};
    for (const set of sets) {
      const map = readProgress(set.id);
      if (Object.keys(map).length) progress[set.id] = clone(map);
    }
    return {
      app: 'wortschatz',
      version: SCHEMA_VERSION,
      exportedAt: now(),
      sets,
      progress,
      settings: getSettings(),
      activity: getActivity(),
    };
  }

  function invalidBackup(message) {
    return dbError('INVALID_BACKUP', message);
  }

  // Validates and normalises a backup object; throws a German error if invalid.
  function parseBackup(data) {
    if (!isObject(data) || data.app !== 'wortschatz') throw invalidBackup(MSG.notBackup);
    if (data.version !== undefined) {
      if (typeof data.version !== 'number' || !Number.isFinite(data.version) || data.version < 1) throw invalidBackup(MSG.notBackup);
      if (data.version > SCHEMA_VERSION) throw invalidBackup(MSG.newerBackup);
    }
    if (!Array.isArray(data.sets)) throw invalidBackup(MSG.noSets);
    for (const part of ['progress', 'settings', 'activity']) {
      if (data[part] != null && !isObject(data[part])) throw invalidBackup(MSG.badPart(part));
    }
    const fallback = now();
    const ids = new Set();
    const sets = [];
    const progress = {};
    data.sets.forEach((raw, i) => {
      if (!isObject(raw) || !Array.isArray(raw.cards)) throw invalidBackup(MSG.badSet(i + 1));
      if (raw.title != null && typeof raw.title !== 'string') throw invalidBackup(MSG.badSet(i + 1));
      const originalId = typeof raw.id === 'string' && raw.id !== '' ? raw.id : null;
      const id = originalId && !ids.has(originalId) ? originalId : newSetId(ids);
      ids.add(id);
      const set = sanitizeSet({ ...raw, id }, fallback);
      sets.push(set);
      // Progress can only be matched when the set kept its original id.
      if (id === originalId && data.progress && isObject(data.progress[originalId])) {
        const map = sanitizeProgressMap(data.progress[originalId], new Set(set.cards.map((c) => c.id)));
        if (Object.keys(map).length) progress[id] = map;
      }
    });
    return {
      sets,
      progress,
      settings: isObject(data.settings) ? mergeSettings(DEFAULT_SETTINGS, data.settings) : null,
      activity: sanitizeActivity(data.activity),
    };
  }

  // All or nothing: obsolete keys are removed before anything new is written
  // (so the old data never has to fit next to the new), and a failed write
  // restores every key as it was.
  function importAll(data, { mode = 'merge' } = {}) {
    const backup = parseBackup(data);
    const replace = mode === 'replace';
    return mutate(() =>
      atomically(() => {
        const existing = readSets();
        const existingIds = new Set(existing.map((s) => s.id));
        const importedIds = new Set(backup.sets.map((s) => s.id));
        let setsAdded = 0;
        let setsUpdated = 0;
        for (const s of backup.sets) {
          if (existingIds.has(s.id)) setsUpdated++;
          else setsAdded++;
        }

        let nextSets;
        if (replace) {
          nextSets = backup.sets;
        } else {
          const importedById = new Map(backup.sets.map((s) => [s.id, s]));
          nextSets = existing.map((s) => importedById.get(s.id) || s);
          for (const s of backup.sets) if (!existingIds.has(s.id)) nextSets.push(s);
        }

        // Imported sets replace their local counterpart, including progress;
        // their Write and Learn sessions and their Karteikarten deck end.
        for (const s of backup.sets) {
          remove(progressKey(s.id));
          remove(sessionKey(s.id));
          remove(learnKey(s.id));
          remove(flashcardsKey(s.id));
        }
        if (replace) {
          for (const s of existing) {
            remove(progressKey(s.id));
            remove(sessionKey(s.id));
            remove(learnKey(s.id));
            remove(flashcardsKey(s.id));
          }
          removeOrphans(importedIds);
        }

        write(KEY_SETS, nextSets);
        for (const s of backup.sets) {
          if (backup.progress[s.id]) write(progressKey(s.id), backup.progress[s.id]);
        }
        if (replace) {
          if (backup.settings) write(KEY_SETTINGS, backup.settings);
          else remove(KEY_SETTINGS);
          write(KEY_ACTIVITY, backup.activity);
        } else {
          // Max per day keeps repeated imports of the same backup idempotent.
          const activity = { ...readActivity() };
          for (const [day, n] of Object.entries(backup.activity)) activity[day] = Math.max(activity[day] || 0, n);
          write(KEY_ACTIVITY, activity);
        }
        return { setsAdded, setsUpdated };
      }),
    );
  }

  // Everything deleteSet(setId) removes, as plain JSON (null for unknown sets).
  function snapshotSet(setId) {
    const set = getSet(setId);
    if (!set) return null;
    return { set, progress: getProgress(setId), session: getSession(setId), learn: getLearn(setId), flashcards: getFlashcards(setId) };
  }

  // Undoes a deleteSet: puts a snapshotSet() result back under the same id,
  // with its progress, its running Write and Learn sessions and its
  // Karteikarten deck, in one write operation.
  function restoreSet(snapshot) {
    const snap = isObject(snapshot) ? snapshot : {};
    const set = isObject(snap.set) && Array.isArray(snap.set.cards) ? sanitizeSet(snap.set, now()) : null;
    if (!set) throw dbError('INVALID', MSG.badSnapshot);
    const progress = sanitizeProgressMap(snap.progress, new Set(set.cards.map((c) => c.id)));
    const deck = parseDeck(snap.flashcards);
    return mutate(() =>
      atomically(() => {
        const { sets, index } = findSet(set.id);
        remove(progressKey(set.id));
        remove(sessionKey(set.id));
        remove(learnKey(set.id));
        remove(flashcardsKey(set.id));
        write(KEY_SETS, index >= 0 ? sets.map((s, i) => (i === index ? set : s)) : [...sets, set]);
        if (Object.keys(progress).length) write(progressKey(set.id), progress);
        if (isObject(snap.session)) write(sessionKey(set.id), clone(snap.session));
        if (isObject(snap.learn)) write(learnKey(set.id), clone(snap.learn));
        if (deck) write(flashcardsKey(set.id), deck);
        return clone(set);
      }),
    );
  }

  // Removes every set, progress, session, Karteikarten deck, setting and activity entry.
  function clearAll() {
    mutate(() => {
      const existing = readSets();
      for (const s of existing) {
        remove(progressKey(s.id));
        remove(sessionKey(s.id));
        remove(learnKey(s.id));
        remove(flashcardsKey(s.id));
      }
      removeOrphans(new Set());
      remove(KEY_SETS);
      remove(KEY_SETTINGS);
      remove(KEY_ACTIVITY);
    });
  }

  // -- subscriptions

  function subscribe(fn) {
    if (typeof fn !== 'function') return () => {};
    listeners.add(fn);
    attachExternal();
    return () => {
      listeners.delete(fn);
      if (!listeners.size && detachExternal) detachExternal();
    };
  }

  return {
    listSets,
    getSet,
    createSet,
    updateSet,
    deleteSet,
    snapshotSet,
    restoreSet,
    duplicateSet,
    updateCard,
    toggleStar,
    getProgress,
    recordAnswer,
    overrideLastAnswer,
    resetProgress,
    resetCardProgress,
    getSession,
    saveSession,
    clearSession,
    getLearn,
    saveLearn,
    clearLearn,
    getFlashcards,
    saveFlashcards,
    clearFlashcards,
    getSettings,
    updateSettings,
    getStudyOptions,
    updateStudyOptions,
    getActivity,
    exportAll,
    importAll,
    clearAll,
    subscribe,
  };
}

export const db = createDb(() => globalThis.localStorage);
