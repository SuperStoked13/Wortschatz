// Learn-mode ("Lernen") engine with Quizlet Learn semantics.
//
// Every card in scope has a stage derived from its persistent streak: 0 = new or reset (asked as
// multiple choice), 1 = familiar (asked written), 2 = mastered (not asked any more). A correct
// answer moves the card up one stage, a wrong one sends it back to stage 0.
//
// The session works in rounds over an active batch of up to `roundSize` unmastered cards: one
// question per card in shuffled order, plus one retry at the end of the round for a card answered
// wrong. The next round drops the mastered cards from the batch and refills it (stage-1 cards
// first, then stage-0 cards in order) until every card in scope is mastered.
//
// Pure and DOM-free (runs under jsc). Every function takes a JSON-serialisable LearnState and
// returns a NEW state object; inputs are never mutated. Randomness comes from an injected rng.
// Multiple-choice options are generated when a question is created and stored in the state, so a
// resumed session shows identical options.
//
// Repetition questions (Wiederholungsfragen, the Mac app's LearnReview, opt-in via
// createLearn(…, { review: true })): the cards mastered when the session starts are asked once
// more, mixed into the rounds. They live in `state.review = { due, results }`, which exists only
// in such sessions; without it every function behaves (and draws from the rng) exactly as before.

import { cardStatus, normalizeProgress, MASTERY_STREAK } from './mastery.js';
import { answerSide, findSynonymCards } from './synonyms.js';
import { splitAlternatives } from './grading.js';
import { normalizeBasic } from './text.js';

export const DEFAULT_LEARN = { roundSize: 7, mc: true, written: true, retype: false };

const MASTERED = MASTERY_STREAK; // stage of a mastered card (2)
const IDLE_GAP_MS = 5 * 60 * 1000;
const MAX_CHOICES = 4;
const ANSWER_WITH = ['term', 'definition', 'both'];
const NAMED_SUBSETS = ['all', 'starred', 'learning', 'missed'];

const hasOwn = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const hasText = (v) => typeof v === 'string' && v.trim() !== '';
const finite = (v, fallback) => (typeof v === 'number' && Number.isFinite(v) ? v : fallback);

// ---------------------------------------------------------------------------
// Small helpers

// Fisher–Yates on a copy. Tolerates an rng returning values outside [0, 1).
function shuffled(list, rng) {
  const a = list.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = randomIndex(rng, i + 1);
    const t = a[i];
    a[i] = a[j];
    a[j] = t;
  }
  return a;
}

// Integer in [0, n) from the rng, clamped so a misbehaving rng never breaks an index.
function randomIndex(rng, n) {
  const random = typeof rng === 'function' ? rng : Math.random;
  let i = Math.floor(random() * n);
  if (!(i >= 0)) i = 0;
  if (i > n - 1) i = n - 1;
  return i;
}

function normalizeSubset(subset) {
  if (subset && typeof subset === 'object') {
    const ids = Array.isArray(subset.cardIds) ? subset.cardIds : [];
    return { cardIds: ids.filter((id) => id != null && id !== '').map(String) };
  }
  return NAMED_SUBSETS.includes(subset) ? subset : 'all';
}

function progressOf(progress, id) {
  return isObj(progress) && hasOwn(progress, id) ? progress[id] : undefined;
}

function cardInSubset(card, subset, progress) {
  if (typeof subset === 'object') return subset.cardIds.includes(card.id);
  const p = progressOf(progress, card.id);
  switch (subset) {
    case 'starred':
      return card.starred === true;
    case 'learning':
      return cardStatus(p) !== 'mastered';
    case 'missed':
      return !!p && p.lastResult === 'incorrect';
    default:
      return true;
  }
}

function normalizeLearn(learn) {
  const src = isObj(learn) ? learn : {};
  const size = typeof src.roundSize === 'number' && Number.isFinite(src.roundSize) ? Math.floor(src.roundSize) : 0;
  let mc = src.mc !== false;
  let written = src.written !== false;
  // At least one question type must stay enabled; with both off fall back to the defaults.
  if (!mc && !written) {
    mc = DEFAULT_LEARN.mc;
    written = DEFAULT_LEARN.written;
  }
  return { roundSize: size >= 1 ? size : DEFAULT_LEARN.roundSize, mc, written };
}

// Unique cards (by id, as strings) that are objects with an id, in the given order.
function cardList(cards) {
  const seen = new Set();
  const out = [];
  for (const raw of Array.isArray(cards) ? cards : []) {
    if (!isObj(raw) || raw.id == null || raw.id === '') continue;
    const card = { ...raw, id: String(raw.id) };
    if (seen.has(card.id)) continue;
    seen.add(card.id);
    out.push(card);
  }
  return out;
}

// A card with an empty side cannot be asked (and is no useful distractor either).
const askable = (card) => hasText(card.term) && hasText(card.definition);

const clampStage = (v) => (typeof v === 'number' && Number.isFinite(v) ? Math.max(0, Math.min(MASTERED, Math.floor(v))) : 0);

// ---------------------------------------------------------------------------
// Multiple-choice options

// Comparison key for answer texts: basic normalisation + lowercase.
const textKey = (text) => normalizeBasic(text).toLowerCase();

// The whole answer and each of its alternatives ("laid, laide" → laid, laide | laid | laide).
function answerKeys(text) {
  const keys = new Set([textKey(text)]);
  for (const alt of splitAlternatives(text)) keys.add(textKey(alt));
  keys.delete('');
  return keys;
}

// Possible wrong options for `card` (id as a string) asked on `side`, in `list` order (list:
// cardList output): other cards' answer texts that are non-empty, distinct, differ from the correct
// answer and share none of its alternatives, from cards that are no synonyms of `card`. Texts whose
// key is in `takenKeys` are skipped too.
function distractors(list, card, side, takenKeys = []) {
  const correctText = answerSide(card, side).trim();
  // Synonym cards (same prompt) would make their answer correct too.
  const synonyms = new Set(findSynonymCards(list, card, side).map((c) => c.id));
  const correctKeys = answerKeys(correctText);
  const usedKeys = new Set([textKey(correctText), ...takenKeys]);
  const out = [];
  for (const other of list) {
    if (other.id === card.id || synonyms.has(other.id)) continue;
    const text = answerSide(other, side).trim();
    const key = textKey(text);
    if (!key || usedKeys.has(key)) continue;
    // An option sharing an alternative with the correct answer would be correct as well.
    let overlaps = false;
    for (const k of answerKeys(text)) if (correctKeys.has(k)) overlaps = true;
    if (overlaps) continue;
    usedKeys.add(key);
    out.push({ cardId: other.id, text });
  }
  return out;
}

export function buildChoices(cards, card, ask, rng = Math.random, n = MAX_CHOICES) {
  if (!isObj(card) || card.id == null || card.id === '') return [];
  const side = ask === 'definition' ? 'definition' : 'term';
  const cardId = String(card.id);
  const correctText = answerSide(card, side).trim();
  if (!normalizeBasic(correctText)) return [];
  const size = typeof n === 'number' && Number.isFinite(n) && n >= 1 ? Math.floor(n) : MAX_CHOICES;
  const correct = { cardId, text: correctText };
  if (size === 1) return [correct];

  const candidates = distractors(cardList(cards), { ...card, id: cardId }, side);
  const choices = shuffled(candidates, rng).slice(0, size - 1);
  // The correct option's position is uniform over all slots.
  choices.splice(randomIndex(rng, choices.length + 1), 0, correct);
  return choices;
}

// ---------------------------------------------------------------------------
// Questions

function pickAsk(answerWith, rng) {
  if (answerWith !== 'both') return answerWith;
  return randomIndex(rng, 2) === 0 ? 'term' : 'definition';
}

// stage 0 → multiple choice, stage 1 → written; a disabled type falls back to the other one, and
// multiple choice needs at least two options. `retryChoices` (internal) holds the options for a
// re-queue after a wrong answer, which is always asked at stage 0.
function makeQuestion(s, card, pool, qid, rng) {
  const ask = pickAsk(s.answerWith, rng);
  const choices = s.learn.mc ? buildChoices(pool, card, ask, rng) : [];
  const canMc = choices.length >= 2;
  const stage = s.stage[card.id] || 0;
  let type;
  if (stage === 0) type = canMc ? 'mc' : 'written';
  else type = s.learn.written || !canMc ? 'written' : 'mc';
  const q = { qid, cardId: card.id, type, ask };
  if (type === 'mc') q.choices = choices;
  if (canMc) q.retryChoices = buildChoices(pool, card, ask, rng);
  return q;
}

const mainQid = (round, cardId) => `${round}.1:${cardId}`;
const retryQid = (round, cardId) => `${round}.2:${cardId}`;
const reviewQid = (round, cardId) => `${round}.3:${cardId}`;
const REVIEW_QID = /^\d+\.3:/;

function publicQuestion(q) {
  const out = { qid: q.qid, cardId: q.cardId, type: q.type, ask: q.ask };
  if (q.type === 'mc') out.choices = q.choices.map((c) => ({ cardId: c.cardId, text: c.text }));
  return out;
}

// Keeps the batch's unmastered cards and refills it up to roundSize: stage-1 cards first, then
// stage-0 cards, each in `order`.
function fillBatch(s) {
  const inOrder = new Set(s.order);
  s.active = s.active.filter((id) => inOrder.has(id) && s.stage[id] < MASTERED);
  const inBatch = new Set(s.active);
  for (const want of [1, 0]) {
    for (const id of s.order) {
      if (s.active.length >= s.learn.roundSize) return;
      if (!inBatch.has(id) && s.stage[id] === want) {
        s.active.push(id);
        inBatch.add(id);
      }
    }
  }
}

// The round's questions: one per batch card in shuffled order, with the repetition questions
// `reviews` (card ids) mixed in among them. Without reviews the rng is drawn exactly as before.
function buildQueue(s, cards, rng, reviews = []) {
  const all = cardList(cards);
  const byId = new Map(all.map((c) => [c.id, c]));
  const pool = all.filter(askable);
  const question = (id, qid) => makeQuestion(s, byId.get(id) || { id, term: '', definition: '' }, pool, qid, rng);
  if (!reviews.length) return shuffled(s.active, rng).map((id) => question(id, mainQid(s.round, id)));
  const entries = [...s.active.map((id) => ({ id, review: false })), ...reviews.map((id) => ({ id, review: true }))];
  return shuffled(entries, rng).map((e) => question(e.id, e.review ? reviewQid(s.round, e.id) : mainQid(s.round, e.id)));
}

// Takes the next round's repetition questions off `review.due`: a few next to the cards being
// learned (reviewsPerRound), a whole round once nothing is left to learn. Cards that are no
// longer mastered (answered wrong elsewhere) are learned instead and leave the list.
function takeReviews(s) {
  if (!s.review) return [];
  const inOrder = new Set(s.order);
  const due = s.review.due.filter((id) => inOrder.has(id) && s.stage[id] >= MASTERED);
  const count = s.active.length === 0 ? s.learn.roundSize : reviewsPerRound(s.learn.roundSize);
  const picks = due.slice(0, count);
  s.review = { due: due.slice(picks.length), results: s.review.results };
  return picks;
}

// Card ids by when they were last answered, the longest ago (or never) first; ties keep their order.
function mostOverdueFirst(ids, progress) {
  const at = (id) => {
    const p = progressOf(progress, id);
    return isObj(p) && typeof p.lastAnsweredAt === 'number' && Number.isFinite(p.lastAnsweredAt) ? p.lastAnsweredAt : -Infinity;
  };
  return ids
    .map((id, i) => ({ id, i, t: at(id) }))
    .sort((a, b) => (a.t !== b.t ? (a.t < b.t ? -1 : 1) : a.i - b.i))
    .map((e) => e.id);
}

// ---------------------------------------------------------------------------
// State copy / repair

function normChoices(list, cardId) {
  if (!Array.isArray(list)) return null;
  const ids = new Set();
  const out = [];
  for (const c of list) {
    if (!isObj(c) || c.cardId == null || c.cardId === '') continue;
    const id = String(c.cardId);
    if (ids.has(id)) continue;
    ids.add(id);
    out.push({ cardId: id, text: typeof c.text === 'string' ? c.text : '' });
  }
  return out.length >= 2 && ids.has(cardId) ? out : null;
}

function normQuestion(q, known, fallbackQid) {
  if (!isObj(q) || q.cardId == null) return null;
  const cardId = String(q.cardId);
  if (!known.has(cardId)) return null;
  const choices = normChoices(q.choices, cardId);
  const retryChoices = normChoices(q.retryChoices, cardId);
  const out = {
    qid: typeof q.qid === 'string' && q.qid !== '' ? q.qid : fallbackQid(cardId),
    cardId,
    type: q.type === 'mc' && choices ? 'mc' : 'written',
    ask: q.ask === 'definition' ? 'definition' : 'term',
  };
  if (out.type === 'mc') out.choices = choices;
  if (retryChoices) out.retryChoices = retryChoices;
  return out;
}

// Defensive deep copy that also repairs missing fields and drops references to cards outside
// `order`, so states restored from storage never crash the engine.
function copyState(state) {
  const src = isObj(state) ? state : {};
  const order = [...new Set((Array.isArray(src.order) ? src.order : []).filter((id) => id != null && id !== '').map(String))];
  const known = new Set(order);
  const ids = (arr) => [...new Set((Array.isArray(arr) ? arr : []).filter((id) => id != null && known.has(String(id))).map(String))];
  const srcStage = isObj(src.stage) ? src.stage : {};
  const stage = {};
  for (const id of order) stage[id] = clampStage(hasOwn(srcStage, id) ? srcStage[id] : 0);
  const trueMap = (m) => {
    const out = {};
    if (isObj(m)) for (const k of Object.keys(m)) if (known.has(k) && m[k] === true) out[k] = true;
    return out;
  };
  const misses = {};
  if (isObj(src.misses)) for (const k of Object.keys(src.misses)) if (known.has(k)) misses[k] = Math.max(0, finite(src.misses[k], 0));

  const round = Number.isInteger(src.round) && src.round > 0 ? src.round : 1;
  const queue = [];
  (Array.isArray(src.queue) ? src.queue : []).forEach((q, i) => {
    const n = normQuestion(q, known, (cardId) => `${round}.q${i}:${cardId}`);
    if (n) queue.push(n);
  });

  const roundLog = (Array.isArray(src.roundLog) ? src.roundLog : [])
    .filter((e) => isObj(e) && e.cardId != null && known.has(String(e.cardId)))
    .map((e) => {
      const entry = {};
      if (typeof e.qid === 'string') entry.qid = e.qid;
      entry.cardId = String(e.cardId);
      entry.type = e.type === 'mc' ? 'mc' : 'written';
      entry.ask = e.ask === 'definition' ? 'definition' : 'term';
      entry.correct = e.correct === true;
      entry.stageAfter = clampStage(e.stageAfter);
      return entry;
    });

  const rounds = (Array.isArray(src.rounds) ? src.rounds : [])
    .filter(isObj)
    .map((r, i) => {
      const answered = Math.max(0, finite(r.answered, 0));
      return {
        round: Number.isInteger(r.round) ? r.round : i + 1,
        answered,
        correct: Math.min(answered, Math.max(0, finite(r.correct, 0))),
        cardIds: ids(r.cardIds),
      };
    });

  let last = null;
  const l = src.last;
  if (isObj(l) && l.cardId != null && known.has(String(l.cardId))) {
    last = {
      qid: typeof l.qid === 'string' ? l.qid : '',
      cardId: String(l.cardId),
      type: l.type === 'mc' ? 'mc' : 'written',
      ask: l.ask === 'definition' ? 'definition' : 'term',
      correct: l.correct === true,
      stageBefore: clampStage(l.stageBefore),
    };
  }

  const answered = Math.max(0, finite(src.answered, 0));
  const startedAt = finite(src.startedAt, 0);
  const out = {
    v: 1,
    subset: normalizeSubset(src.subset),
    answerWith: ANSWER_WITH.includes(src.answerWith) ? src.answerWith : 'term',
    learn: normalizeLearn(src.learn),
    order,
    stage,
    initiallyMastered: ids(src.initiallyMastered),
    seen: trueMap(src.seen),
    active: ids(src.active),
    round,
    queue,
    retried: trueMap(src.retried),
    roundLog,
    rounds,
    answered,
    correct: Math.min(answered, Math.max(0, finite(src.correct, 0))),
    misses,
    last,
    startedAt,
    updatedAt: finite(src.updatedAt, startedAt),
    finishedAt: typeof src.finishedAt === 'number' ? src.finishedAt : null,
    elapsedMs: Math.max(0, finite(src.elapsedMs, 0)),
  };
  // Only sessions with repetition questions carry the key, so every other state stays as it was.
  if (isObj(src.review)) {
    const results = {};
    if (isObj(src.review.results)) {
      for (const k of Object.keys(src.review.results)) {
        if (known.has(k) && typeof src.review.results[k] === 'boolean') results[k] = src.review.results[k];
      }
    }
    out.review = { due: ids(src.review.due), results };
  }
  return out;
}

// ---------------------------------------------------------------------------
// Internal state transitions (mutate the private copy only)

const allMastered = (s) => s.order.every((id) => s.stage[id] >= MASTERED);

// Repetition questions are queued, or still to come for cards that are still mastered.
function reviewPending(s) {
  if (!s.review) return false;
  return s.queue.some((q) => REVIEW_QID.test(q.qid)) || s.review.due.some((id) => s.stage[id] >= MASTERED);
}

// The session's goal is reached: everything mastered and every repetition question asked.
const isComplete = (s) => allMastered(s) && !reviewPending(s);

// Adds active time since the last update; gaps longer than IDLE_GAP_MS (pause, sleeping laptop,
// resuming another day) are not counted. The clock stops once the session is finished.
function advanceClock(s, now) {
  if (s.finishedAt != null || typeof now !== 'number' || !Number.isFinite(now)) return;
  const gap = now - s.updatedAt;
  if (gap > 0 && gap <= IDLE_GAP_MS) s.elapsedMs += gap;
  s.updatedAt = now;
}

function markFinished(s, now) {
  if (s.finishedAt == null && isComplete(s)) s.finishedAt = finite(now, s.updatedAt);
}

// markFinished for a change outside of answering (a removed card, progress from elsewhere): when
// the current round ends without a single answer, the session ended with the last closed round.
function finishEarly(s, now) {
  markFinished(s, now);
  if (s.finishedAt != null && s.queue.length === 0 && s.roundLog.length === 0) {
    s.round = s.rounds.length ? s.rounds[s.rounds.length - 1].round : 1;
  }
}

function roundIsClosed(s) {
  const last = s.rounds[s.rounds.length - 1];
  return !!last && last.round === s.round;
}

function archiveRound(s) {
  s.rounds.push({
    round: s.round,
    answered: s.roundLog.length,
    correct: s.roundLog.filter((e) => e.correct).length,
    cardIds: s.active.slice(),
  });
}

// The options of question `q` without card `id`. With `refill` ({ pool, byId, rng }: the set's
// askable cards without `id`) its slot gets another valid wrong option when there is one, so a
// question keeps its number of options and the other options keep their places.
function withoutOption(list, id, q, refill) {
  if (!list) return [];
  const at = list.findIndex((c) => c.cardId === id);
  if (at < 0) return list;
  const rest = list.filter((c) => c.cardId !== id);
  const card = refill ? refill.byId.get(q.cardId) : null;
  if (!card) return rest;
  const present = new Set(rest.map((c) => c.cardId));
  // Keys of the remaining options, from the cards' current texts where they still exist.
  const taken = rest.map((c) => {
    const owner = refill.byId.get(c.cardId);
    return textKey(owner ? answerSide(owner, q.ask) : c.text);
  });
  const candidates = distractors(refill.pool, card, q.ask, taken).filter((c) => !present.has(c.cardId));
  if (!candidates.length) return rest;
  rest.splice(at, 0, candidates[randomIndex(refill.rng, candidates.length)]);
  return rest;
}

function dropCard(s, id, refill = null) {
  s.order = s.order.filter((x) => x !== id);
  delete s.stage[id];
  delete s.seen[id];
  delete s.retried[id];
  delete s.misses[id];
  s.initiallyMastered = s.initiallyMastered.filter((x) => x !== id);
  s.active = s.active.filter((x) => x !== id);
  if (s.review) {
    const results = { ...s.review.results };
    delete results[id];
    s.review = { due: s.review.due.filter((x) => x !== id), results };
  }
  // Its questions go; other questions lose it as an option (refilled when possible; mc needs two
  // options to stay mc).
  s.queue = s.queue
    .filter((q) => q.cardId !== id)
    .map((q) => {
      const choices = withoutOption(q.choices, id, q, refill);
      const retryChoices = withoutOption(q.retryChoices, id, q, refill);
      const out = { qid: q.qid, cardId: q.cardId, type: q.type === 'mc' && choices.length >= 2 ? 'mc' : 'written', ask: q.ask };
      if (out.type === 'mc') out.choices = choices;
      if (retryChoices.length >= 2) out.retryChoices = retryChoices;
      return out;
    });
  // The current round forgets its answers (so the checkpoint never shows a deleted card);
  // closed rounds keep their tallies as history.
  const removed = s.roundLog.filter((e) => e.cardId === id);
  s.roundLog = s.roundLog.filter((e) => e.cardId !== id);
  s.answered = Math.max(0, s.answered - removed.length);
  s.correct = Math.min(s.answered, Math.max(0, s.correct - removed.filter((e) => e.correct).length));
  s.rounds = s.rounds.map((r) => ({ ...r, cardIds: r.cardIds.filter((x) => x !== id) }));
  if (s.last && s.last.cardId === id) s.last = null;
}

// ---------------------------------------------------------------------------
// Public API

export function stageFromProgress(progress) {
  return Math.min(normalizeProgress(progress).streak, MASTERED);
}

// `review: true` adds repetition questions for the cards that are mastered already (see the top
// of this file); without it the session is built exactly as before, rng draw for rng draw.
export function createLearn(cards, options, { subset = 'all', progress = {}, rng = Math.random, now = Date.now(), review = false } = {}) {
  const opts = isObj(options) ? options : {};
  const answerWith = ANSWER_WITH.includes(opts.answerWith) ? opts.answerWith : 'term';
  const sub = normalizeSubset(subset);
  const prog = isObj(progress) ? progress : {};
  const selected = cardList(cards).filter((c) => askable(c) && cardInSubset(c, sub, prog));
  const order = shuffled(
    selected.map((c) => c.id),
    rng,
  );

  const stage = {};
  const seen = {};
  for (const id of order) {
    const p = progressOf(prog, id);
    stage[id] = stageFromProgress(p);
    if (cardStatus(p) !== 'new') seen[id] = true;
  }

  const at = finite(now, 0);
  const s = {
    v: 1,
    subset: sub,
    answerWith,
    learn: normalizeLearn(opts.learn),
    order,
    stage,
    initiallyMastered: order.filter((id) => stage[id] >= MASTERED),
    seen,
    active: [],
    round: 1,
    queue: [],
    retried: {},
    roundLog: [],
    rounds: [],
    answered: 0,
    correct: 0,
    misses: {},
    last: null,
    startedAt: at,
    updatedAt: at,
    finishedAt: null,
    elapsedMs: 0,
  };
  // The most overdue mastered cards are asked again first.
  if (review === true) s.review = { due: mostOverdueFirst(s.initiallyMastered, prog), results: {} };
  fillBatch(s);
  s.queue = buildQueue(s, cards, rng, takeReviews(s));
  markFinished(s, at);
  return s;
}

export function current(state) {
  const s = copyState(state);
  return s.queue.length ? publicQuestion(s.queue[0]) : null;
}

export function answer(state, correct, now = Date.now()) {
  const s = copyState(state);
  const q = s.queue[0];
  if (!q) return s;
  advanceClock(s, now);
  const ok = correct === true;
  const id = q.cardId;
  const stageBefore = s.stage[id];
  const stageAfter = ok ? Math.min(stageBefore + 1, MASTERED) : 0;
  s.stage[id] = stageAfter;
  s.seen[id] = true;
  s.answered += 1;
  if (ok) s.correct += 1;
  else s.misses[id] = (s.misses[id] || 0) + 1;
  s.queue.shift();
  s.roundLog.push({ qid: q.qid, cardId: id, type: q.type, ask: q.ask, correct: ok, stageAfter });
  s.last = { qid: q.qid, cardId: id, type: q.type, ask: q.ask, correct: ok, stageBefore };

  // A miss is asked once more at the end of the round, at its new stage (multiple choice).
  if (!ok && !s.retried[id]) {
    s.retried[id] = true;
    const retry = { qid: retryQid(s.round, id), cardId: id, type: 'written', ask: q.ask };
    if (s.learn.mc && q.retryChoices) {
      retry.type = 'mc';
      retry.choices = q.retryChoices;
    }
    s.queue.push(retry);
  }
  if (s.review && REVIEW_QID.test(q.qid)) {
    // The first answer to a mastered card's repetition question counts; a miss means it is
    // learned again (stage 0), so it no longer counts as mastered before the session.
    if (!hasOwn(s.review.results, id)) s.review = { due: s.review.due, results: { ...s.review.results, [id]: ok } };
    if (!ok) s.initiallyMastered = s.initiallyMastered.filter((x) => x !== id);
  }
  markFinished(s, now);
  return s;
}

// "Ich hatte recht": the last answer (if it was wrong) becomes correct: the card's stage is
// stageBefore + 1 and its retry in this round is dropped. Idempotent; a no-op after nextRound().
export function override(state, now = Date.now()) {
  const s = copyState(state);
  const l = s.last;
  if (!l || l.correct) return s;
  advanceClock(s, now);
  const id = l.cardId;
  const stageAfter = Math.min(l.stageBefore + 1, MASTERED);
  s.stage[id] = stageAfter;
  s.correct = Math.min(s.answered, s.correct + 1);
  s.misses[id] = Math.max(0, (s.misses[id] || 0) - 1);
  for (let i = s.roundLog.length - 1; i >= 0; i--) {
    const e = s.roundLog[i];
    if (e.cardId === id && (e.qid === undefined || e.qid === l.qid)) {
      s.roundLog[i] = { ...e, correct: true, stageAfter };
      break;
    }
  }
  const before = s.queue.length;
  s.queue = s.queue.filter((q) => q.cardId !== id);
  if (s.queue.length < before) delete s.retried[id];
  s.last = { ...l, correct: true };
  if (s.review && REVIEW_QID.test(l.qid)) {
    // The repetition question was right after all: the card is still mastered.
    s.review = { due: s.review.due, results: { ...s.review.results, [id]: true } };
    if (stageAfter >= MASTERED && !s.initiallyMastered.includes(id)) {
      const kept = new Set([...s.initiallyMastered, id]);
      s.initiallyMastered = s.order.filter((x) => kept.has(x));
    }
  }
  markFinished(s, now);
  return s;
}

export function isRoundOver(state) {
  return copyState(state).queue.length === 0;
}

export function counts(state) {
  const s = copyState(state);
  let fresh = 0;
  let mastered = 0;
  for (const id of s.order) {
    if (s.stage[id] >= MASTERED) mastered++;
    else if (s.stage[id] === 0 && !s.seen[id]) fresh++;
  }
  const total = s.order.length;
  return { fresh, learning: total - fresh - mastered, mastered, total, progress: total === 0 ? 0 : mastered / total };
}

export function checkpoint(state) {
  const s = copyState(state);
  const items = [];
  const index = new Map();
  for (const e of s.roundLog) {
    if (!index.has(e.cardId)) {
      index.set(e.cardId, items.length);
      items.push({ cardId: e.cardId, stage: s.stage[e.cardId], results: [] });
    }
    items[index.get(e.cardId)].results.push(e.correct);
  }
  const { fresh, learning, mastered, total } = counts(s);
  return {
    round: s.round,
    answered: s.roundLog.length,
    correct: s.roundLog.filter((e) => e.correct).length,
    items,
    counts: { fresh, learning, mastered, total },
  };
}

// Closes the finished round into `rounds`, drops mastered cards from the batch, refills it and
// builds the next round's questions (with the next repetition questions, if any). When every
// card is mastered (and every repetition question asked) the final round is closed and the
// session stays finished (its roundLog is kept for the checkpoint). No-op mid-round.
// Scope cards missing from `cards` (deleted) are removed from the session.
export function nextRound(state, cards, rng = Math.random, now = Date.now()) {
  const s = copyState(state);
  if (s.queue.length > 0) return s;
  if (Array.isArray(cards)) {
    const present = new Set(cardList(cards).map((c) => c.id));
    for (const id of s.order.slice()) if (!present.has(id)) dropCard(s, id);
  }
  if (isComplete(s)) {
    if (s.roundLog.length > 0 && !roundIsClosed(s)) archiveRound(s);
    markFinished(s, now);
    return s;
  }
  advanceClock(s, now);
  // A round without answers (only possible after removals or in a repaired state) is refilled,
  // not counted.
  if (s.roundLog.length > 0) {
    if (!roundIsClosed(s)) archiveRound(s);
    s.round += 1;
  }
  s.roundLog = [];
  s.retried = {};
  s.last = null;
  fillBatch(s);
  s.queue = buildQueue(s, cards, rng, takeReviews(s));
  return s;
}

// Every card in scope is mastered (also true for a session without cards) and, with repetition
// questions, every card mastered before the session was asked again.
export function isFinished(state) {
  return isComplete(copyState(state));
}

export function finalStats(state) {
  const s = copyState(state);
  const total = s.order.length;
  const mastered = s.order.filter((id) => s.stage[id] >= MASTERED).length;
  const rounds = s.rounds.length + (s.roundLog.length > 0 && !roundIsClosed(s) ? 1 : 0);
  const hardest = s.order
    .map((cardId, i) => ({ cardId, misses: s.misses[cardId] || 0, i }))
    .filter((e) => e.misses > 0)
    .sort((x, y) => y.misses - x.misses || x.i - y.i)
    .slice(0, 10)
    .map(({ cardId, misses }) => ({ cardId, misses }));
  return {
    total,
    mastered,
    // Cards that were mastered before the session started (and stayed so).
    alreadyMastered: s.initiallyMastered.length,
    rounds,
    answered: s.answered,
    accuracy: s.answered === 0 ? 0 : s.correct / s.answered,
    elapsedMs: s.elapsedMs,
    hardest,
  };
}

// ---------------------------------------------------------------------------
// Repetition questions

// Whether question `qid` is a repetition question ("<round>.3:<cardId>").
export function isReviewQuestion(qid) {
  return typeof qid === 'string' && REVIEW_QID.test(qid);
}

// How many repetition questions a round asks next to the cards being learned.
export function reviewsPerRound(roundSize) {
  const n = typeof roundSize === 'number' && Number.isFinite(roundSize) ? Math.floor(roundSize) : 0;
  return Math.max(1, Math.floor(n / 3));
}

// The repetition questions so far: { asked, kept, left } (mastered cards asked again, how many
// of them were still known, how many are still to come); null for a session without them.
export function reviewStats(state) {
  const s = copyState(state);
  if (!s.review) return null;
  const queued = new Set(s.queue.filter((q) => REVIEW_QID.test(q.qid)).map((q) => q.cardId));
  const due = s.review.due.filter((id) => s.stage[id] >= MASTERED && !queued.has(id));
  const results = Object.keys(s.review.results).map((k) => s.review.results[k]);
  return { asked: results.length, kept: results.filter((ok) => ok === true).length, left: queued.size + due.length };
}

// Removes a card from the session (e.g. it was deleted mid-session): its stage, batch slot,
// questions, current-round answers and misses, and its options in other questions. With `cards`
// (the set's current cards) each lost option is replaced by another wrong option from the set
// where one is left, in the same place.
export function removeCard(state, cardId, now = Date.now(), { cards = null, rng = Math.random } = {}) {
  const s = copyState(state);
  const id = String(cardId);
  if (!s.order.includes(id)) return s;
  advanceClock(s, now);
  let refill = null;
  if (Array.isArray(cards)) {
    const all = cardList(cards);
    refill = { pool: all.filter((c) => c.id !== id && askable(c)), byId: new Map(all.map((c) => [c.id, c])), rng };
  }
  dropCard(s, id, refill);
  finishEarly(s, now);
  return s;
}

export function tick(state, now = Date.now()) {
  const s = copyState(state);
  advanceClock(s, now);
  return s;
}

// ---------------------------------------------------------------------------
// Shared progress
//
// Learn and Write record every answer in the same CardProgress, which is the source of truth: a
// card's stage is min(streak, 2) and it counts as seen once it was ever answered. Every Learn
// transition keeps that true by itself; answers given elsewhere (Write mode, another tab) are
// brought in with syncProgress().

// Whether every card's stage and seen flag match `progress` (a finished session always does:
// it keeps its result).
export function matchesProgress(state, progress) {
  const s = copyState(state);
  if (s.finishedAt != null) return true;
  return s.order.every((id) => {
    const p = progressOf(progress, id);
    return s.stage[id] === stageFromProgress(p) && !!s.seen[id] === (cardStatus(p) !== 'new');
  });
}

// The question `q` asked at its card's current stage (like makeQuestion: multiple choice at
// stage 0, written at stage 1), using the options it already holds. Keeps qid and ask.
function retype(s, q) {
  const options = q.type === 'mc' ? q.choices : q.retryChoices;
  const canMc = s.learn.mc && Array.isArray(options) && options.length >= 2;
  const type = s.stage[q.cardId] === 0 ? (canMc ? 'mc' : 'written') : s.learn.written || !canMc ? 'written' : 'mc';
  if (type === q.type) return q;
  const out = { qid: q.qid, cardId: q.cardId, type, ask: q.ask };
  if (type === 'mc') out.choices = options;
  const retry = q.retryChoices || (q.type === 'mc' ? q.choices : null);
  if (retry) out.retryChoices = retry;
  return out;
}

// Brings the session in line with `progress`: every stage becomes min(streak, 2) and `seen`
// follows whether the card was ever answered. A card that is mastered now leaves the batch and
// this round's queue; a card whose stage changed otherwise keeps its queued questions, switched
// to the type of its new stage; a card no longer mastered is studied again from the next round
// on. A queued repetition question of a card that is no longer mastered (missed elsewhere)
// becomes an ordinary question: the card is learned instead of repeated, so it neither shows as
// a repetition nor counts in reviewStats. A finished session is left as it is.
export function syncProgress(state, progress, now = Date.now()) {
  const s = copyState(state);
  if (s.finishedAt != null) return s;
  const changed = [];
  for (const id of s.order) {
    const p = progressOf(progress, id);
    const stage = stageFromProgress(p);
    if (stage !== s.stage[id]) {
      s.stage[id] = stage;
      changed.push(id);
    }
    if (cardStatus(p) === 'new') delete s.seen[id];
    else s.seen[id] = true;
  }
  for (const id of changed) {
    if (s.stage[id] >= MASTERED) {
      s.active = s.active.filter((x) => x !== id);
      s.queue = s.queue.filter((q) => q.cardId !== id);
    } else {
      s.initiallyMastered = s.initiallyMastered.filter((x) => x !== id);
      s.queue = s.queue.map((q) => (q.cardId === id ? retype(s, REVIEW_QID.test(q.qid) ? { ...q, qid: q.qid.replace(/^(\d+)\.3:/, '$1.1:') } : q) : q));
    }
  }
  finishEarly(s, now);
  return s;
}
