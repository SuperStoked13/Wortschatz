// Learn-mode ("Lernen") engine with Quizlet Learn semantics.
//
// Every card in scope has a stage derived from its persistent streak: 0 = new or reset (asked as
// multiple choice), 1 = familiar (asked written), 2 = mastered (not asked any more). A correct
// answer moves the card up one stage, a wrong one sends it back to stage 0.
//
// Multiple choice only once (since 24.11.2026): a card is asked as multiple choice only until it
// was answered right once (`state.solved`, from the progress: any right answer ever). From then
// on it is asked written, at stage 0 too: a wrong written answer resets the stage but stays
// written; only a wrong multiple-choice answer brings multiple choice again.
//
// Spacing (Abstand, since 1.4): a card comes back only after at least MIN_GAP (10) other
// questions – fewer only when fewer cards are left – and at the latest after about MAX_WAIT (15);
// in between, the longer it waits the likelier it is picked, mixed with new cards. So a new card
// is asked, ~10–15 questions later asked again, and gone once both answers were right. A wrong
// answer sends it back to stage 0; it too comes back only after the gap (no retry at the end of
// the round any more). New cards are taken stage-1 cards first, then stage-0 cards, in `order`.
//
// A round is the next `roundSize` questions (after it the checkpoint shows the interim result).
// They are planned when the round starts, as if every answer were right; an actual answer adjusts
// the card's later questions in the round to its new stage.
//
// Rechecks (Nachkontrolle, opt-in via createLearn(…, { recheck: true }), only for sessions with
// more than 60 cards): a card answered wrong in this session is asked once more RECHECK_GAP to
// RECHECK_WAIT (30–50) questions after it was mastered; wrong again, it is learned again. They
// live in `state.recheck = { due }` (mastered cards waiting for their recheck, not yet queued).
// A recheck never comes sooner than MIN_GAP questions after the card was mastered (since 23.11.2026;
// before, a round's plan with nothing else left asked it early). At the end of a session, when
// nothing else is left to ask, a recheck that could not come that late is dropped (dropLateRechecks).
//
// Pure and DOM-free (runs under jsc). Every function takes a JSON-serialisable LearnState and
// returns a NEW state object; inputs are never mutated. Randomness comes from an injected rng.
// Multiple-choice options are generated when a question is created and stored in the state, so a
// resumed session shows identical options.
//
// Repetition questions (Wiederholungsfragen, the Mac app's LearnReview, opt-in via
// createLearn(…, { review: true })): the cards mastered when the session starts are asked once
// more, mixed in among the new cards (about every third). They live in
// `state.review = { due, results }`, which exists only in such sessions.

import { cardStatus, normalizeProgress, MASTERY_STREAK } from './mastery.js';
import { answerSide, findSynonymCards } from './synonyms.js';
import { splitAlternatives } from './grading.js';
import { normalizeBasic, foldScripts } from './text.js';
import { listProfiles, cardClass, shapeOf, shapePoints, nearPoints } from './wordclass.js';

export const DEFAULT_LEARN = { roundSize: 7, mc: true, written: true, retype: false };

const MASTERED = MASTERY_STREAK; // stage of a mastered card (2)
const IDLE_GAP_MS = 5 * 60 * 1000;
const MAX_CHOICES = 4;
// Spacing: other questions at least between two questions of a card, and after how many a waiting
// card is asked for sure; the same for rechecks, counted from the answer that mastered the card.
export const MIN_GAP = 10;
export const MAX_WAIT = 15;
export const RECHECK_GAP = 30;
export const RECHECK_WAIT = 50;
// The mix: at most this many questions in a row of cards asked before while there are new cards,
// and no new card while this many cards are being learned.
export const MAX_REPEATS = 3;
export const MAX_LEARNING = 10;
// Rechecks only in sessions with more cards than this.
export const RECHECK_MIN_CARDS = 60;
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

// Comparison key for answer texts: basic normalisation, script folds (Arabic vowel marks,
// full-width punctuation) + lowercase.
const textKey = (text) => foldScripts(normalizeBasic(text)).toLowerCase();

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

// Wrong options for `card` asked on `side`, most alike first (since 23.11.2026, wordclass.js): cards of
// the same word class before cards of an open class before others, then by similarity points (close
// in the set, same article, as many words, similar length, same beginning and ending) plus a random
// 0–2, so options almost as similar take turns; equal ones in random order.
function rankedDistractors(list, card, side, rng, takenKeys = []) {
  const candidates = distractors(list, card, side, takenKeys);
  const at = new Map(list.map((c, i) => [c.id, i]));
  const sides = listProfiles(list.map((c) => ({ term: answerSide(c, 'term'), definition: answerSide(c, 'definition') })));
  const own = { term: answerSide(card, 'term'), definition: answerSide(card, 'definition') };
  const cls = cardClass(own, sides);
  const shape = shapeOf(answerSide(card, side).trim(), sides[side]);
  const here = at.has(card.id) ? at.get(card.id) : -1;
  const ranked = shuffled(candidates, rng).map((c, order) => {
    const i = at.get(c.cardId);
    const other = list[i];
    const otherCls = cardClass({ term: answerSide(other, 'term'), definition: answerSide(other, 'definition') }, sides);
    const tier = !cls || !otherCls ? 1 : otherCls === cls ? 2 : 0;
    let points = shapePoints(shape, shapeOf(c.text, sides[side]));
    if (here >= 0) points += nearPoints(Math.abs(i - here));
    return { choice: c, order, key: tier * 100 + points + randomIndex(rng, 3) };
  });
  ranked.sort((a, b) => b.key - a.key || a.order - b.order);
  return ranked.map((x) => x.choice);
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

  const ranked = rankedDistractors(cardList(cards), { ...card, id: cardId }, side, rng);
  // The most alike, in random order; the correct option's position is uniform over all slots.
  const choices = shuffled(ranked.slice(0, size - 1), rng);
  choices.splice(randomIndex(rng, choices.length + 1), 0, correct);
  return choices;
}

// ---------------------------------------------------------------------------
// Questions

function pickAsk(answerWith, rng) {
  if (answerWith !== 'both') return answerWith;
  return randomIndex(rng, 2) === 0 ? 'term' : 'definition';
}

// Whether a card at `stage` is asked as multiple choice: at stage 0 until it was answered right once.
function mcStage(s, id, stage) {
  return stage === 0 && !s.solved[id];
}

// stage 0 → multiple choice (until solved), else written; a disabled type falls back to the other
// one, and multiple choice needs at least two options. `retryChoices` (internal) holds the options
// for when the question has to be asked as multiple choice after all (a wrong multiple-choice
// answer earlier in the round).
function makeQuestion(s, card, stage, pool, qid, rng) {
  const ask = pickAsk(s.answerWith, rng);
  const choices = s.learn.mc ? buildChoices(pool, card, ask, rng) : [];
  const canMc = choices.length >= 2;
  let type;
  if (mcStage(s, card.id, stage)) type = canMc ? 'mc' : 'written';
  else type = s.learn.written || !canMc ? 'written' : 'mc';
  const q = { qid, cardId: card.id, type, ask };
  if (type === 'mc') q.choices = choices;
  if (canMc) q.retryChoices = buildChoices(pool, card, ask, rng);
  return q;
}

// Question ids: "<round>.<kind>:<cardId>", kind 1 = learning, 3 = repetition question, 4 = recheck;
// a card's second (third, …) question in the same round gets "<round>.<kind>.<n>:<cardId>".
const LEARN = 1;
const REVIEW = 3;
const RECHECK = 4;
const questionId = (round, kind, cardId, n) => `${round}.${kind}${n > 1 ? `.${n}` : ''}:${cardId}`;
const REVIEW_QID = /^\d+\.3(\.\d+)?:/;
const RECHECK_QID = /^\d+\.4(\.\d+)?:/;
// A repetition question or recheck asked as an ordinary learning question (its card is learned).
const asLearnQid = (qid) => qid.replace(/^(\d+)\.[34]/, '$1.1');

function publicQuestion(q) {
  const out = { qid: q.qid, cardId: q.cardId, type: q.type, ask: q.ask };
  if (q.type === 'mc') out.choices = q.choices.map((c) => ({ cardId: c.cardId, text: c.text }));
  return out;
}

// Of `list` ({id, …}), the entry with the highest score; ties go to the one earlier in `order`.
function best(list, score, index) {
  let top = null;
  for (const e of list) {
    if (top === null || score(e) > score(top) || (score(e) === score(top) && index.get(e.id) < index.get(top.id))) top = e;
  }
  return top;
}

// The card asked at question number `t` (the session's answer count when it is asked) in the
// planning state `p` ({stage, lastAt, reviewDue, recheckDue}): {id, kind} or null when no card
// needs a question any more.
//
// Waiting cards (learning cards asked before, and rechecks) may come once they have waited `min`
// other questions; once they have waited `max` they come for sure (the longest overdue first).
// In between, the card that is furthest past its `min` comes with a chance that grows with every
// question it waits – (wait - min + 1) in (max - min + 1) – otherwise a new card comes. New cards:
// learning cards not asked yet in this session (stage-1 cards first) and repetition questions
// (about every third one while there are both).
//
// Two limits keep the mix: after MAX_REPEATS questions in a row of cards asked before, a new card
// comes (even before an overdue one); while MAX_LEARNING cards are being learned (asked, not
// mastered yet) new cards come only by that rule, after twice as many. Only when no card may come
// yet, the card that has waited longest comes early (a recheck only after MIN_GAP; null when only
// rechecks are waiting that have not waited that long: the round ends there).
function nextPick(s, p, t, rng, index) {
  const learning = s.order.filter((id) => p.stage[id] < MASTERED);
  // Cards that can fill a learning card's gap: the learning cards and the repetition questions (rechecks
  // wait 30 questions and more, so they do not count here).
  const toLearn = learning.length + p.reviewDue.length;
  const open = toLearn + p.recheckDue.length;
  if (open === 0) return null;
  const waiting = [];
  const fresh = [];
  for (const want of [1, 0]) {
    for (const id of learning) {
      if (hasOwn(p.lastAt, id)) {
        if (want === 1) waiting.push({ id, kind: LEARN, wait: t - p.lastAt[id] - 1, min: Math.min(MIN_GAP, toLearn - 1), max: MAX_WAIT });
      } else if (p.stage[id] === want) fresh.push(id);
    }
  }
  const inFlight = waiting.length;
  for (const id of p.recheckDue) {
    // A recheck without a known last answer is overdue.
    const wait = hasOwn(p.lastAt, id) ? t - p.lastAt[id] - 1 : RECHECK_WAIT;
    // Fewer open cards bring it closer, but never closer than a learning card's gap.
    waiting.push({ id, kind: RECHECK, wait, min: Math.max(MIN_GAP, Math.min(RECHECK_GAP, open - 1)), max: RECHECK_WAIT });
  }
  const ready = waiting.filter((c) => c.wait >= c.min);
  const hasNew = fresh.length > 0 || p.reviewDue.length > 0;
  const takeNew = () => {
    if (fresh.length && p.reviewDue.length) {
      return randomIndex(rng, 3) === 0 ? { id: p.reviewDue[0], kind: REVIEW } : { id: fresh[0], kind: LEARN };
    }
    return fresh.length ? { id: fresh[0], kind: LEARN } : { id: p.reviewDue[0], kind: REVIEW };
  };
  if (!ready.length) {
    if (hasNew) return takeNew();
    // Nothing may come yet: the learning card that has waited longest comes early. A recheck only
    // when nothing is left to learn and never before MIN_GAP other questions (sooner it would check
    // nothing): with only such rechecks left the round ends here; they come once they have waited,
    // or are dropped when nothing else is left (dropLateRechecks).
    const learn = waiting.filter((c) => c.kind === LEARN);
    if (learn.length) return best(learn, (c) => c.wait, index);
    const rechecks = waiting.filter((c) => c.wait >= MIN_GAP);
    return rechecks.length ? best(rechecks, (c) => c.wait, index) : null;
  }
  if (!hasNew) return best(ready, (c) => c.wait - c.max, index);
  const full = inFlight >= MAX_LEARNING;
  if (p.repeats >= (full ? 2 * MAX_REPEATS : MAX_REPEATS)) return takeNew();
  const forced = ready.filter((c) => c.wait >= c.max);
  if (forced.length) return best(forced, (c) => c.wait - c.max, index);
  const c = best(ready, (e) => e.wait - e.min, index);
  if (full || randomIndex(rng, c.max - c.min + 1) < c.wait - c.min + 1) return c;
  return takeNew();
}

// Plans the round's `roundSize` questions (fewer when the session ends sooner), as if every answer
// were right. Planned repetition questions and rechecks leave `review.due` / `recheck.due`; cards
// there that are no longer mastered (answered wrong elsewhere) are learned instead and leave too.
function planRound(s, cards, rng) {
  const all = cardList(cards);
  const byId = new Map(all.map((c) => [c.id, c]));
  const pool = all.filter(askable);
  const index = new Map(s.order.map((id, i) => [id, i]));
  const mastered = (id) => index.has(id) && s.stage[id] >= MASTERED;
  const p = {
    stage: { ...s.stage },
    lastAt: { ...s.lastAt },
    repeats: s.repeats,
    reviewDue: s.review ? s.review.due.filter(mastered) : [],
    recheckDue: s.recheck ? s.recheck.due.filter(mastered) : [],
  };
  const asked = {};
  const queue = [];
  for (let k = 0; k < s.learn.roundSize; k++) {
    const t = s.clock + k;
    const pick = nextPick(s, p, t, rng, index);
    if (!pick) break;
    const { id, kind } = pick;
    asked[id] = (asked[id] || 0) + 1;
    const card = byId.get(id) || { id, term: '', definition: '' };
    queue.push(makeQuestion(s, card, p.stage[id], pool, questionId(s.round, kind, id, asked[id]), rng));
    p.repeats = hasOwn(p.lastAt, id) ? p.repeats + 1 : 0;
    p.lastAt[id] = t;
    if (kind === REVIEW) p.reviewDue = p.reviewDue.filter((x) => x !== id);
    else if (kind === RECHECK) p.recheckDue = p.recheckDue.filter((x) => x !== id);
    else p.stage[id] = Math.min(p.stage[id] + 1, MASTERED);
  }
  if (s.review) s.review = { due: p.reviewDue, results: s.review.results };
  if (s.recheck) s.recheck = { due: p.recheckDue };
  return queue;
}

// After an answer (or a correction) the card's later questions in this round follow its stage:
// learning questions of a mastered card go, the others are asked at the new stage.
function followStage(s, id) {
  s.queue = s.queue
    .filter((q) => q.cardId !== id || s.stage[id] < MASTERED || REVIEW_QID.test(q.qid) || RECHECK_QID.test(q.qid))
    .map((q) => (q.cardId === id ? retype(s, q) : q));
}

// A card mastered by a right answer after it was answered wrong in this session waits for its
// recheck (unless one is queued already).
function noteRecheck(s, id) {
  if (!s.recheck || s.stage[id] < MASTERED || !((s.misses[id] || 0) > 0)) return;
  if (s.recheck.due.includes(id) || s.queue.some((q) => q.cardId === id && RECHECK_QID.test(q.qid))) return;
  s.recheck = { due: [...s.recheck.due, id] };
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
  // A card past stage 0 was answered right (sessions stored before 24.11.2026 have no `solved`).
  const solved = trueMap(src.solved);
  for (const id of order) if (stage[id] > 0) solved[id] = true;
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
  // Sessions stored before spacing (1.4) have no clock: their answer count stands in for it.
  const clock = Number.isInteger(src.clock) && src.clock >= 0 ? src.clock : Math.floor(answered);
  const lastAt = {};
  if (isObj(src.lastAt)) {
    for (const k of Object.keys(src.lastAt)) {
      const v = src.lastAt[k];
      if (known.has(k) && Number.isInteger(v) && v >= 0) lastAt[k] = v;
    }
  }
  const out = {
    v: 1,
    subset: normalizeSubset(src.subset),
    answerWith: ANSWER_WITH.includes(src.answerWith) ? src.answerWith : 'term',
    learn: normalizeLearn(src.learn),
    order,
    stage,
    initiallyMastered: ids(src.initiallyMastered),
    seen: trueMap(src.seen),
    solved,
    round,
    queue,
    clock,
    lastAt,
    repeats: Number.isInteger(src.repeats) && src.repeats >= 0 ? src.repeats : 0,
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
  // Only sessions with rechecks carry the key.
  if (isObj(src.recheck)) out.recheck = { due: ids(src.recheck.due) };
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

// Rechecks are queued, or still to come for cards that are still mastered.
function recheckPending(s) {
  if (!s.recheck) return false;
  return s.queue.some((q) => RECHECK_QID.test(q.qid)) || s.recheck.due.some((id) => s.stage[id] >= MASTERED);
}

// The session's goal is reached: everything mastered, every repetition question and recheck asked.
const isComplete = (s) => allMastered(s) && !reviewPending(s) && !recheckPending(s);

// Adds active time since the last update; gaps longer than IDLE_GAP_MS (pause, sleeping laptop,
// resuming another day) are not counted. The clock stops once the session is finished.
function advanceClock(s, now) {
  if (s.finishedAt != null || typeof now !== 'number' || !Number.isFinite(now)) return;
  const gap = now - s.updatedAt;
  if (gap > 0 && gap <= IDLE_GAP_MS) s.elapsedMs += gap;
  s.updatedAt = now;
}

// Once nothing but rechecks is left to ask (every card mastered, no repetition question pending,
// only rechecks queued), a waiting recheck that would come fewer than MIN_GAP questions after the
// answer that mastered its card is dropped: asked right away it would check nothing.
function dropLateRechecks(s) {
  if (!s.recheck || !s.recheck.due.length || !allMastered(s) || reviewPending(s)) return;
  if (s.queue.some((q) => !RECHECK_QID.test(q.qid))) return;
  const ahead = s.queue.length;
  const due = s.recheck.due.filter((id) => !hasOwn(s.lastAt, id) || s.clock + ahead - s.lastAt[id] - 1 >= MIN_GAP);
  if (due.length !== s.recheck.due.length) s.recheck = { due };
}

function markFinished(s, now) {
  dropLateRechecks(s);
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

// The round's tally; cardIds = the cards answered in it, in the order of their first answer.
function archiveRound(s) {
  s.rounds.push({
    round: s.round,
    answered: s.roundLog.length,
    correct: s.roundLog.filter((e) => e.correct).length,
    cardIds: [...new Set(s.roundLog.map((e) => e.cardId))],
  });
}

// The options of question `q` without card `id`. With `refill` ({ pool, byId, rng }: the set's
// askable cards without `id`) its slot gets the most alike other valid wrong option when there is
// one, so a question keeps its number of options and the other options keep their places.
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
  const candidates = rankedDistractors(refill.pool, card, q.ask, refill.rng, taken).filter((c) => !present.has(c.cardId));
  if (!candidates.length) return rest;
  rest.splice(at, 0, candidates[0]);
  return rest;
}

function dropCard(s, id, refill = null) {
  s.order = s.order.filter((x) => x !== id);
  delete s.stage[id];
  delete s.seen[id];
  delete s.solved[id];
  delete s.lastAt[id];
  delete s.misses[id];
  s.initiallyMastered = s.initiallyMastered.filter((x) => x !== id);
  if (s.review) {
    const results = { ...s.review.results };
    delete results[id];
    s.review = { due: s.review.due.filter((x) => x !== id), results };
  }
  if (s.recheck) s.recheck = { due: s.recheck.due.filter((x) => x !== id) };
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

// Whether a card was ever answered right (then it is no longer asked as multiple choice). A streak
// counts too, so every card past stage 0 is solved.
export function solvedFromProgress(progress) {
  const p = normalizeProgress(progress);
  return p.correct > 0 || p.streak > 0;
}

// `review: true` adds repetition questions for the cards that are mastered already, `recheck: true`
// rechecks (in sessions with more than RECHECK_MIN_CARDS cards; see the top of this file).
export function createLearn(cards, options, { subset = 'all', progress = {}, rng = Math.random, now = Date.now(), review = false, recheck = false } = {}) {
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
  const solved = {};
  for (const id of order) {
    const p = progressOf(prog, id);
    stage[id] = stageFromProgress(p);
    if (cardStatus(p) !== 'new') seen[id] = true;
    if (solvedFromProgress(p)) solved[id] = true;
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
    solved,
    round: 1,
    queue: [],
    clock: 0,
    lastAt: {},
    repeats: 0,
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
  if (recheck === true && order.length > RECHECK_MIN_CARDS) s.recheck = { due: [] };
  s.queue = planRound(s, cards, rng);
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
  if (ok) s.solved[id] = true;
  s.answered += 1;
  if (ok) s.correct += 1;
  else s.misses[id] = (s.misses[id] || 0) + 1;
  s.queue.shift();
  s.repeats = hasOwn(s.lastAt, id) ? s.repeats + 1 : 0;
  s.lastAt[id] = s.clock;
  s.clock += 1;
  s.roundLog.push({ qid: q.qid, cardId: id, type: q.type, ask: q.ask, correct: ok, stageAfter });
  s.last = { qid: q.qid, cardId: id, type: q.type, ask: q.ask, correct: ok, stageBefore };

  // A miss comes back like any card, after the gap (planned in a later round).
  followStage(s, id);
  if (stageBefore < MASTERED) noteRecheck(s, id);
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
// stageBefore + 1 and its later questions in this round follow that stage. Idempotent; a no-op
// after nextRound().
export function override(state, now = Date.now()) {
  const s = copyState(state);
  const l = s.last;
  if (!l || l.correct) return s;
  advanceClock(s, now);
  const id = l.cardId;
  const stageAfter = Math.min(l.stageBefore + 1, MASTERED);
  s.stage[id] = stageAfter;
  s.solved[id] = true;
  s.correct = Math.min(s.answered, s.correct + 1);
  s.misses[id] = Math.max(0, (s.misses[id] || 0) - 1);
  for (let i = s.roundLog.length - 1; i >= 0; i--) {
    const e = s.roundLog[i];
    if (e.cardId === id && (e.qid === undefined || e.qid === l.qid)) {
      s.roundLog[i] = { ...e, correct: true, stageAfter };
      break;
    }
  }
  followStage(s, id);
  if (l.stageBefore < MASTERED) noteRecheck(s, id);
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

// Closes the finished round into `rounds` and plans the next round's questions (planRound). When
// every card is mastered (and every repetition question and recheck asked) the final round is closed and the
// session stays finished (its roundLog is kept for the checkpoint). No-op mid-round.
// Scope cards missing from `cards` (deleted) are removed from the session.
export function nextRound(state, cards, rng = Math.random, now = Date.now()) {
  const s = copyState(state);
  if (s.queue.length > 0) return s;
  if (Array.isArray(cards)) {
    const present = new Set(cardList(cards).map((c) => c.id));
    for (const id of s.order.slice()) if (!present.has(id)) dropCard(s, id);
  }
  dropLateRechecks(s);
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
  s.last = null;
  s.queue = planRound(s, cards, rng);
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

// Removes a card from the session (e.g. it was deleted mid-session): its stage, spacing,
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

// Whether every card's stage, seen and solved flags match `progress` (a finished session always
// does: it keeps its result).
export function matchesProgress(state, progress) {
  const s = copyState(state);
  if (s.finishedAt != null) return true;
  return s.order.every((id) => {
    const p = progressOf(progress, id);
    return (
      s.stage[id] === stageFromProgress(p) &&
      !!s.seen[id] === (cardStatus(p) !== 'new') &&
      !!s.solved[id] === solvedFromProgress(p)
    );
  });
}

// The question `q` asked at its card's current stage (like makeQuestion: multiple choice at
// stage 0 until solved, else written), using the options it already holds. Keeps qid and ask.
function retype(s, q) {
  const options = q.type === 'mc' ? q.choices : q.retryChoices;
  const canMc = s.learn.mc && Array.isArray(options) && options.length >= 2;
  const type = mcStage(s, q.cardId, s.stage[q.cardId]) ? (canMc ? 'mc' : 'written') : s.learn.written || !canMc ? 'written' : 'mc';
  if (type === q.type) return q;
  const out = { qid: q.qid, cardId: q.cardId, type, ask: q.ask };
  if (type === 'mc') out.choices = options;
  const retry = q.retryChoices || (q.type === 'mc' ? q.choices : null);
  if (retry) out.retryChoices = retry;
  return out;
}

// Brings the session in line with `progress`: every stage becomes min(streak, 2), `seen`
// follows whether the card was ever answered and `solved` whether it was ever answered right. A
// card that is mastered now leaves this round's queue; a card whose stage (or, not mastered, whose
// solved flag) changed otherwise keeps its queued questions, switched to the type of its new
// stage; a card no longer mastered is studied again. A queued repetition question or
// recheck of a card that is no longer mastered (missed elsewhere) becomes an ordinary question:
// the card is learned instead, so it neither shows as a repetition nor counts in reviewStats,
// and it leaves the cards waiting for a recheck. A finished session is left as it is.
export function syncProgress(state, progress, now = Date.now()) {
  const s = copyState(state);
  if (s.finishedAt != null) return s;
  const changed = [];
  for (const id of s.order) {
    const p = progressOf(progress, id);
    const stage = stageFromProgress(p);
    const solved = solvedFromProgress(p);
    if (stage !== s.stage[id] || (solved !== !!s.solved[id] && stage < MASTERED)) changed.push(id);
    s.stage[id] = stage;
    if (cardStatus(p) === 'new') delete s.seen[id];
    else s.seen[id] = true;
    if (solved) s.solved[id] = true;
    else delete s.solved[id];
  }
  for (const id of changed) {
    if (s.stage[id] >= MASTERED) {
      s.queue = s.queue.filter((q) => q.cardId !== id);
    } else {
      s.initiallyMastered = s.initiallyMastered.filter((x) => x !== id);
      if (s.recheck) s.recheck = { due: s.recheck.due.filter((x) => x !== id) };
      s.queue = s.queue.map((q) => (q.cardId === id ? retype(s, { ...q, qid: asLearnQid(q.qid) }) : q));
    }
  }
  finishEarly(s, now);
  return s;
}
