// Write-mode session engine with Quizlet "Write" semantics.
//
// Round 1 asks every question once. A missed question is not retried within the same round;
// the next round contains only the questions missed in the previous round. This repeats until
// every question has been answered correctly once.
//
// Pure and DOM-free (runs under jsc). Every function takes a JSON-serialisable SessionState and
// returns a NEW state object; inputs are never mutated. Randomness comes from an injected rng.

import { cardStatus } from './mastery.js';

const IDLE_GAP_MS = 5 * 60 * 1000;
const ANSWER_WITH = ['term', 'definition', 'both'];
const NAMED_SUBSETS = ['all', 'starred', 'learning', 'missed'];

const hasOwn = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);
const hasText = (v) => typeof v === 'string' && v.trim() !== '';

function qidFor(cardId, ask) {
  return `${cardId}:${ask === 'term' ? 't' : 'd'}`;
}

function normalizeSubset(subset) {
  if (subset && typeof subset === 'object') {
    const ids = Array.isArray(subset.cardIds) ? subset.cardIds : [];
    return { cardIds: ids.filter((id) => id != null && id !== '').map(String) };
  }
  return NAMED_SUBSETS.includes(subset) ? subset : 'all';
}

function cardInSubset(card, subset, progress) {
  if (typeof subset === 'object') return subset.cardIds.includes(card.id);
  const p = progress && typeof progress === 'object' ? progress[card.id] : undefined;
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

// Fisher–Yates on a copy. Tolerates an rng returning values outside [0, 1).
function shuffled(list, rng) {
  const random = typeof rng === 'function' ? rng : Math.random;
  const a = list.slice();
  for (let i = a.length - 1; i > 0; i--) {
    let j = Math.floor(random() * (i + 1));
    if (!(j >= 0)) j = 0;
    if (j > i) j = i;
    const t = a[i];
    a[i] = a[j];
    a[j] = t;
  }
  return a;
}

// With answerWith 'both' a card has two questions; avoid asking them back to back, which would
// give the answer away. Deterministic: only swaps/moves items, no randomness.
function separateSiblings(qids, questions) {
  const a = qids.slice();
  const card = (i) => questions[a[i]].cardId;
  for (let i = 1; i < a.length; i++) {
    const c = card(i);
    if (c !== card(i - 1)) continue;
    let fixed = false;
    for (let j = i + 1; j < a.length; j++) {
      if (card(j) !== c) {
        const t = a[i];
        a[i] = a[j];
        a[j] = t;
        fixed = true;
        break;
      }
    }
    if (fixed) continue;
    // Last position: move the item to an earlier slot whose neighbours belong to other cards.
    for (let p = 0; p < i - 1; p++) {
      if ((p === 0 || card(p - 1) !== c) && card(p) !== c) {
        const [item] = a.splice(i, 1);
        a.splice(p, 0, item);
        break;
      }
    }
  }
  return a;
}

function arrangeQueue(qids, s, rng) {
  if (!s.setOptions.shuffle) {
    const rank = new Map(s.order.map((qid, i) => [qid, i]));
    return qids.slice().sort((x, y) => rank.get(x) - rank.get(y));
  }
  return separateSiblings(shuffled(qids, rng), s.questions);
}

const finite = (v, fallback) => (typeof v === 'number' && Number.isFinite(v) ? v : fallback);

// Defensive deep copy that also repairs missing fields and drops references to unknown qids, so
// states restored from storage never crash the engine.
function copyState(state) {
  const src = state && typeof state === 'object' ? state : {};
  const questions = {};
  const srcQuestions = src.questions && typeof src.questions === 'object' ? src.questions : {};
  for (const key of Object.keys(srcQuestions)) {
    const q = srcQuestions[key];
    if (!q || typeof q !== 'object' || q.cardId == null) continue;
    questions[key] = { qid: key, cardId: String(q.cardId), ask: q.ask === 'definition' ? 'definition' : 'term' };
  }
  const known = (qid) => typeof qid === 'string' && hasOwn(questions, qid);
  const qids = (arr) => (Array.isArray(arr) ? arr.filter(known) : []);
  const uniqueQids = (arr) => [...new Set(qids(arr))];
  const numMap = (m) => {
    const out = {};
    if (m && typeof m === 'object') for (const k of Object.keys(m)) if (known(k)) out[k] = Math.max(0, finite(m[k], 0));
    return out;
  };
  const boolMap = (m) => {
    const out = {};
    if (m && typeof m === 'object') for (const k of Object.keys(m)) if (known(k) && typeof m[k] === 'boolean') out[k] = m[k];
    return out;
  };
  const opts = src.setOptions && typeof src.setOptions === 'object' ? src.setOptions : {};
  const startedAt = finite(src.startedAt, 0);
  return {
    v: 1,
    setOptions: {
      answerWith: ANSWER_WITH.includes(opts.answerWith) ? opts.answerWith : 'term',
      shuffle: opts.shuffle !== false,
    },
    subset: normalizeSubset(src.subset),
    questions,
    order: uniqueQids(src.order),
    round: Number.isInteger(src.round) && src.round > 0 ? src.round : 1,
    queue: uniqueQids(src.queue),
    roundAnswered: (Array.isArray(src.roundAnswered) ? src.roundAnswered : [])
      .filter((a) => a && known(a.qid))
      .map((a) => ({ qid: a.qid, correct: a.correct === true })),
    rounds: (Array.isArray(src.rounds) ? src.rounds : [])
      .filter((r) => r && typeof r === 'object')
      .map((r, i) => ({
        round: Number.isInteger(r.round) ? r.round : i + 1,
        total: Math.max(0, finite(r.total, 0)),
        correct: Math.max(0, finite(r.correct, 0)),
        incorrectQids: uniqueQids(r.incorrectQids),
      })),
    done: uniqueQids(src.done),
    attempts: numMap(src.attempts),
    misses: numMap(src.misses),
    firstTry: boolMap(src.firstTry),
    startedAt,
    updatedAt: finite(src.updatedAt, startedAt),
    finishedAt: typeof src.finishedAt === 'number' ? src.finishedAt : null,
    elapsedMs: Math.max(0, finite(src.elapsedMs, 0)),
  };
}

function allDone(s) {
  const done = new Set(s.done);
  return s.order.every((qid) => done.has(qid));
}

// Adds active time since the last update; gaps longer than IDLE_GAP_MS (pause, sleeping laptop,
// resuming another day) are not counted. The clock stops once the session is finished.
function advanceClock(s, now) {
  if (s.finishedAt != null || typeof now !== 'number' || !Number.isFinite(now)) return;
  const gap = now - s.updatedAt;
  if (gap > 0 && gap <= IDLE_GAP_MS) s.elapsedMs += gap;
  s.updatedAt = now;
}

function markFinished(s, now) {
  if (s.finishedAt == null && allDone(s)) s.finishedAt = finite(now, s.updatedAt);
}

function roundIsClosed(s) {
  const last = s.rounds[s.rounds.length - 1];
  return !!last && last.round === s.round;
}

function markCorrect(s, qid) {
  if (!s.done.includes(qid)) s.done.push(qid);
  s.misses[qid] = Math.max(0, (s.misses[qid] || 0) - 1);
  if ((s.attempts[qid] || 0) <= 1) s.firstTry[qid] = true;
}

export function createSession(cards, options, { subset = 'all', rng = Math.random, now = Date.now(), progress = {} } = {}) {
  const opts = options && typeof options === 'object' ? options : {};
  const answerWith = ANSWER_WITH.includes(opts.answerWith) ? opts.answerWith : 'term';
  const shuffle = opts.shuffle !== false;
  const sub = normalizeSubset(subset);

  const seen = new Set();
  const selected = [];
  for (const raw of Array.isArray(cards) ? cards : []) {
    if (!raw || typeof raw !== 'object' || raw.id == null || raw.id === '') continue;
    const card = { ...raw, id: String(raw.id) };
    if (seen.has(card.id)) continue;
    seen.add(card.id);
    // A card with an empty side cannot be asked meaningfully in either direction.
    if (!hasText(card.term) || !hasText(card.definition)) continue;
    if (cardInSubset(card, sub, progress)) selected.push(card);
  }

  // Unshuffled 'both': every term question first, then every definition question, so a card's
  // two directions are never asked back to back.
  const sides = answerWith === 'both' ? ['term', 'definition'] : [answerWith];
  const questions = {};
  const order = [];
  for (const ask of sides) {
    for (const card of selected) {
      const qid = qidFor(card.id, ask);
      questions[qid] = { qid, cardId: card.id, ask };
      order.push(qid);
    }
  }

  const at = finite(now, 0);
  const finalOrder = shuffle ? separateSiblings(shuffled(order, rng), questions) : order;
  const attempts = {};
  const misses = {};
  for (const qid of finalOrder) {
    attempts[qid] = 0;
    misses[qid] = 0;
  }
  return {
    v: 1,
    setOptions: { answerWith, shuffle },
    subset: sub,
    questions,
    order: finalOrder,
    round: 1,
    queue: finalOrder.slice(),
    roundAnswered: [],
    rounds: [],
    done: [],
    attempts,
    misses,
    firstTry: {},
    startedAt: at,
    updatedAt: at,
    finishedAt: finalOrder.length === 0 ? at : null,
    elapsedMs: 0,
  };
}

export function current(state) {
  const s = copyState(state);
  const qid = s.queue[0];
  return qid === undefined ? null : { ...s.questions[qid] };
}

export function answer(state, correct, now = Date.now()) {
  const s = copyState(state);
  const qid = s.queue[0];
  if (qid === undefined) return s;
  advanceClock(s, now);
  const ok = correct === true;
  const previous = s.attempts[qid] || 0;
  s.attempts[qid] = previous + 1;
  if (previous === 0) s.firstTry[qid] = ok;
  if (ok) {
    if (!s.done.includes(qid)) s.done.push(qid);
  } else {
    s.misses[qid] = (s.misses[qid] || 0) + 1;
  }
  s.queue.shift();
  s.roundAnswered.push({ qid, correct: ok });
  markFinished(s, now);
  return s;
}

// "Ich hatte recht": the incorrect answer of `qid` in the current round becomes correct. Also
// works right after nextRound() for a miss of the just-closed round, as long as the qid has not
// been answered in the new round yet. Idempotent: anything else is a no-op.
export function override(state, qid, now = Date.now()) {
  const s = copyState(state);
  if (typeof qid !== 'string' || !hasOwn(s.questions, qid) || s.done.includes(qid)) return s;

  let idx = -1;
  for (let i = s.roundAnswered.length - 1; i >= 0; i--) {
    if (s.roundAnswered[i].qid === qid) {
      idx = i;
      break;
    }
  }

  if (idx >= 0) {
    if (s.roundAnswered[idx].correct) return s;
    advanceClock(s, now);
    s.roundAnswered[idx] = { qid, correct: true };
    markCorrect(s, qid);
    if (roundIsClosed(s)) {
      const last = s.rounds[s.rounds.length - 1];
      last.incorrectQids = last.incorrectQids.filter((q) => q !== qid);
      last.correct = Math.min(last.total, last.correct + 1);
    }
    markFinished(s, now);
    return s;
  }

  const last = s.rounds[s.rounds.length - 1];
  if (!last || last.round !== s.round - 1 || !last.incorrectQids.includes(qid)) return s;
  advanceClock(s, now);
  last.incorrectQids = last.incorrectQids.filter((q) => q !== qid);
  last.correct = Math.min(last.total, last.correct + 1);
  s.queue = s.queue.filter((q) => q !== qid);
  markCorrect(s, qid);
  if (s.queue.length === 0 && s.roundAnswered.length === 0) {
    // The new round lost its only questions: the session ended with the closed round.
    s.round = last.round;
  }
  markFinished(s, now);
  return s;
}

export function isRoundOver(state) {
  return copyState(state).queue.length === 0;
}

export function roundSummary(state) {
  const s = copyState(state);
  const items = s.roundAnswered.map(({ qid, correct }) => ({
    qid,
    cardId: s.questions[qid].cardId,
    ask: s.questions[qid].ask,
    correct,
  }));
  const correct = items.filter((it) => it.correct).length;
  return {
    round: s.round,
    total: items.length + s.queue.length,
    correct,
    incorrect: items.length - correct,
    items,
  };
}

// Closes the finished round into `rounds` and starts the next one with the questions missed in
// it. When nothing is left the session is finished instead; the closed round's answers stay in
// `roundAnswered` so its summary can still be shown. No-op while the round is still running.
export function nextRound(state, rng = Math.random, now = Date.now()) {
  const s = copyState(state);
  if (s.queue.length > 0 || roundIsClosed(s)) return s;
  advanceClock(s, now);

  const incorrectQids = [];
  for (const a of s.roundAnswered) if (!a.correct && !incorrectQids.includes(a.qid)) incorrectQids.push(a.qid);
  const finished = allDone(s);
  if (s.roundAnswered.length > 0) {
    s.rounds.push({
      round: s.round,
      total: s.roundAnswered.length,
      correct: s.roundAnswered.length - s.roundAnswered.filter((a) => !a.correct).length,
      incorrectQids,
    });
  }
  if (finished) {
    markFinished(s, now);
    return s;
  }

  const done = new Set(s.done);
  const missed = incorrectQids.filter((qid) => !done.has(qid));
  // Safety net for inconsistent restored states: any other open question joins the next round.
  for (const qid of s.order) if (!done.has(qid) && !missed.includes(qid)) missed.push(qid);
  s.queue = arrangeQueue(missed, s, rng);
  // A round without answers (only possible in a repaired state) is refilled, not counted.
  if (s.roundAnswered.length > 0) s.round += 1;
  s.roundAnswered = [];
  return s;
}

export function isFinished(state) {
  return allDone(copyState(state));
}

export function counters(state) {
  const s = copyState(state);
  const total = s.order.length;
  return {
    remaining: s.queue.length,
    correct: s.done.length,
    incorrect: s.roundAnswered.filter((a) => !a.correct).length,
    total,
    round: s.round,
    progress: total === 0 ? 0 : s.done.length / total,
  };
}

export function finalStats(state) {
  const s = copyState(state);
  const total = s.order.length;
  const firstTryCorrect = s.order.filter((qid) => s.firstTry[qid] === true).length;

  // Misses per card (both directions together), in order of first appearance.
  const byCard = new Map();
  for (const qid of s.order) {
    const cardId = s.questions[qid].cardId;
    byCard.set(cardId, (byCard.get(cardId) || 0) + (s.misses[qid] || 0));
  }
  const missedCards = [...byCard].filter(([, misses]) => misses > 0).map(([cardId, misses]) => ({ cardId, misses }));
  const hardest = missedCards
    .map((entry, i) => ({ entry, i }))
    .sort((x, y) => y.entry.misses - x.entry.misses || x.i - y.i)
    .map(({ entry }) => entry);

  return {
    total,
    firstTryCorrect,
    accuracy: total === 0 ? 0 : firstTryCorrect / total,
    rounds: total === 0 ? 0 : s.round,
    elapsedMs: s.elapsedMs,
    hardest,
    missedCardIds: missedCards.map((m) => m.cardId),
  };
}

// Removes every question of a card (e.g. the card was deleted mid-session), including its share
// of the closed rounds' tallies. Rounds left without any question are dropped.
export function removeCard(state, cardId, now = Date.now()) {
  const s = copyState(state);
  const id = String(cardId);
  const gone = new Set(Object.keys(s.questions).filter((qid) => s.questions[qid].cardId === id));
  if (gone.size === 0) return s;
  advanceClock(s, now);

  // Round 1 asked every question; round n asked exactly the misses of round n - 1.
  const rounds = s.rounds.map((r, i) => {
    let { total, correct } = r;
    for (const qid of gone) {
      const asked = i === 0 || s.rounds[i - 1].incorrectQids.includes(qid);
      if (!asked) continue;
      total -= 1;
      if (!r.incorrectQids.includes(qid)) correct -= 1;
    }
    total = Math.max(0, total);
    return {
      round: r.round,
      total,
      correct: Math.min(total, Math.max(0, correct)),
      incorrectQids: r.incorrectQids.filter((qid) => !gone.has(qid)),
    };
  });
  const firstEmpty = rounds.findIndex((r) => r.total === 0);
  s.rounds = firstEmpty === -1 ? rounds : rounds.slice(0, firstEmpty);

  const keep = (qid) => !gone.has(qid);
  for (const qid of gone) {
    delete s.questions[qid];
    delete s.attempts[qid];
    delete s.misses[qid];
    delete s.firstTry[qid];
  }
  s.order = s.order.filter(keep);
  s.queue = s.queue.filter(keep);
  s.done = s.done.filter(keep);
  s.roundAnswered = s.roundAnswered.filter((a) => keep(a.qid));

  if (s.queue.length === 0 && s.roundAnswered.length === 0) {
    // The current round has nothing left: fall back to the last round that still has content.
    s.round = s.rounds.length ? s.rounds[s.rounds.length - 1].round : 1;
  }
  markFinished(s, now);
  return s;
}

export function tick(state, now = Date.now()) {
  const s = copyState(state);
  advanceClock(s, now);
  return s;
}
