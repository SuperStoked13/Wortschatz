// Pure helpers for Learn mode: resumability of a stored Learn session (incl. an
// open "Nicht ganz" screen), the options that need a restart, praise, the option
// texts of a multiple choice question, the checkpoint status of a card, the
// segments of the progress bar, the repetition questions' copy and the
// "#/set/<id>/learn?new=1&cards=…" link for a session over chosen cards. DOM-free.

import { isFinished, syncProgress, counts as learnCounts, checkpoint, isRoundOver } from '../core/learn.js';
import { answerSide } from '../core/synonyms.js';
import { plural } from '../lib/labels.js';

// Praise after a correct answer, varied (never the same twice in a row).
export const PRAISE = Object.freeze(['Super!', 'Klasse!', 'Genau!', 'Weiter so!', 'Stark!']);

// The progress bar has one segment per round-sized batch, at most this many.
export const MAX_SEGMENTS = 12;

const MAX_GIVEN = 1000;
const ANSWER_WITH = ['term', 'definition', 'both'];
const DEFAULT_ROUND_SIZE = 7;

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const hasText = (v) => typeof v === 'string' && v.trim() !== '';
const clamp01 = (v) => Math.min(1, Math.max(0, Number(v) || 0));

export function pickPraise(previous = null, rng = Math.random, pool = PRAISE) {
  const list = Array.isArray(pool) && pool.length ? pool : PRAISE;
  const others = list.filter((p) => p !== previous);
  const from = others.length ? others : list;
  let i = Math.floor((typeof rng === 'function' ? rng() : Math.random()) * from.length);
  if (!(i >= 0)) i = 0;
  if (i > from.length - 1) i = from.length - 1;
  return from[i];
}

// Whether two subsets name the same scope: the same named subset, or the same
// chosen cards (in any order).
export function sameSubset(a, b) {
  if (isObj(a) || isObj(b)) {
    if (!isObj(a) || !isObj(b) || !Array.isArray(a.cardIds) || !Array.isArray(b.cardIds)) return false;
    const x = [...new Set(a.cardIds.map(String))].sort();
    const y = [...new Set(b.cardIds.map(String))].sort();
    return x.length === y.length && x.every((id, i) => id === y[i]);
  }
  return a === b;
}

// A stored Learn session is resumed unless a fresh one was requested, it is
// finished or empty, or a different subset was asked for.
export function canResumeLearn(saved, { forceNew = false, subset = null } = {}) {
  return (
    !forceNew &&
    isObj(saved) &&
    saved.finishedAt == null &&
    Array.isArray(saved.order) &&
    saved.order.length > 0 &&
    !isFinished(saved) &&
    (subset == null || sameSubset(saved.subset, subset))
  );
}

export function hasLearnAnswers(state) {
  if (!isObj(state)) return false;
  return (
    (typeof state.answered === 'number' && state.answered > 0) ||
    (Array.isArray(state.rounds) && state.rounds.length > 0) ||
    (Array.isArray(state.roundLog) && state.roundLog.length > 0)
  );
}

function cleanChoices(list, cardId) {
  if (!Array.isArray(list)) return null;
  const seen = new Set();
  const out = [];
  for (const c of list) {
    if (!isObj(c) || c.cardId == null || c.cardId === '') continue;
    const id = String(c.cardId);
    if (seen.has(id)) continue;
    seen.add(id);
    out.push({ cardId: id, text: typeof c.text === 'string' ? c.text : '' });
  }
  return out.length >= 2 && seen.has(cardId) ? out : null;
}

// The "Nicht ganz" screen that was open when the page was left. `feedback` is
// stored next to the Learn state:
//   multiple choice: { qid, cardId, type: 'mc', ask, choices, chosen /* cardId | null = "Weiss ich nicht" */ }
//   written:         { qid, cardId, type: 'written', ask, given, dontKnow }
// It is valid while it describes the state's last answer and that answer is still
// counted as wrong (not overridden, round not closed). Returns the cleaned record or null.
export function pendingLearnFeedback(state, feedback) {
  if (!isObj(state) || !isObj(feedback)) return null;
  const last = state.last;
  if (!isObj(last) || last.correct !== false || last.cardId == null) return null;
  const cardId = String(last.cardId);
  if (typeof feedback.qid !== 'string' || feedback.qid !== last.qid) return null;
  if (feedback.cardId == null || String(feedback.cardId) !== cardId) return null;
  if (!Array.isArray(state.order) || !state.order.map(String).includes(cardId)) return null;
  const type = last.type === 'mc' ? 'mc' : 'written';
  if ((feedback.type === 'mc' ? 'mc' : 'written') !== type) return null;
  const ask = last.ask === 'definition' ? 'definition' : 'term';
  const base = { qid: feedback.qid, cardId, type, ask };
  if (type === 'mc') {
    const choices = cleanChoices(feedback.choices, cardId);
    if (!choices) return null;
    const chosen = feedback.chosen == null ? null : String(feedback.chosen);
    // A chosen option must be one of the wrong ones (null = "Weiss ich nicht").
    if (chosen !== null && (chosen === cardId || !choices.some((c) => c.cardId === chosen))) return null;
    return { ...base, choices, chosen };
  }
  const given = typeof feedback.given === 'string' ? feedback.given.slice(0, MAX_GIVEN) : '';
  return { ...base, given, dontKnow: feedback.dontKnow === true || !hasText(given) };
}

function learnPart(learn) {
  const src = isObj(learn) ? learn : {};
  const roundSize = typeof src.roundSize === 'number' && Number.isFinite(src.roundSize) && src.roundSize >= 1 ? Math.floor(src.roundSize) : DEFAULT_ROUND_SIZE;
  let mc = src.mc !== false;
  let written = src.written !== false;
  if (!mc && !written) {
    mc = true;
    written = true;
  }
  return { roundSize, mc, written };
}

// The options a Learn state was built with: { answerWith, roundSize, mc, written }.
export function sessionSettings(source) {
  const src = isObj(source) ? source : {};
  return { answerWith: ANSWER_WITH.includes(src.answerWith) ? src.answerWith : 'term', ...learnPart(src.learn) };
}

// Whether an option source asks repetition questions: a Learn state that has them
// (state.review), or StudyOptions with `review: true` added by the caller (the
// "Wiederholungsfragen" preference is not a per-set option).
const asksReview = (source) => isObj(source) && (source.review === true || isObj(source.review));

// Which settings that shape a session differ between two option sources (a Learn
// state, or StudyOptions plus `review`): 'direction', 'types', 'roundSize', 'review'.
export function settingsChanges(a, b) {
  const x = sessionSettings(a);
  const y = sessionSettings(b);
  const out = [];
  if (x.answerWith !== y.answerWith) out.push('direction');
  if (x.mc !== y.mc || x.written !== y.written) out.push('types');
  if (x.roundSize !== y.roundSize) out.push('roundSize');
  if (asksReview(a) !== asksReview(b)) out.push('review');
  return out;
}

const CHANGE_TEXT = {
  direction: 'Die neue Abfragerichtung gilt',
  types: 'Die neuen Fragetypen gelten',
  roundSize: 'Die neue Rundengrösse gilt',
  review: 'Die Einstellung für Wiederholungsfragen gilt',
};

// "Neu starten?" message after options that only apply to a new session.
export function restartMessage(changes) {
  const list = Array.isArray(changes) ? changes.filter((c) => CHANGE_TEXT[c]) : [];
  const lead = list.length === 1 ? CHANGE_TEXT[list[0]] : 'Die neuen Einstellungen gelten';
  return `${lead} ab einem Neustart. Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert.`;
}

// Texts of a question's options, from the current cards (so edits show at once);
// the stored text is kept for a card that no longer exists.
export function choiceTexts(choices, cardsById, ask) {
  if (!Array.isArray(choices)) return [];
  return choices.map((c) => {
    const card = cardsById && typeof cardsById.get === 'function' ? cardsById.get(c.cardId) : null;
    const live = card ? answerSide(card, ask).trim() : '';
    return { cardId: c.cardId, text: live || (typeof c.text === 'string' ? c.text : '') };
  });
}

// Status of a card by its stage (used for the checkpoint list, where every card
// was just answered: see checkpointStatus).
export function stageStatus(stage) {
  if (stage >= 2) return { key: 'mastered', label: 'Gemeistert', tone: 'success', icon: 'check' };
  if (stage === 1) return { key: 'learning', label: 'Am Lernen', tone: 'warning', icon: null };
  return { key: 'new', label: 'Noch neu', tone: 'neutral', icon: null };
}

// Checkpoint chip of a card answered in the round: stage 0 there means "answered
// wrong", which the counters (learn.counts) show as Am Lernen, not as Neu.
export function checkpointStatus(stage) {
  return stageStatus(stage >= 1 ? stage : 1);
}

export function masteredLine(mastered, total) {
  return `${mastered} von ${total} gemeistert`;
}

export function checkpointTitle(ratio) {
  if (ratio >= 0.9) return 'Hervorragend!';
  if (ratio >= 0.7) return 'Gut gemacht!';
  if (ratio >= 0.4) return 'Du machst Fortschritte!';
  return 'Dranbleiben – das wird!';
}

// What is left after a checkpoint, e.g. 'Noch 34 Begriffe, bis alles sitzt.'
export function remainingText({ mastered = 0, total = 0 } = {}) {
  const left = Math.max(0, total - mastered);
  if (left === 0) return 'Alles sitzt!';
  return `Noch ${plural(left, 'Begriff', 'Begriffe')}, bis alles sitzt.`;
}

// The adjective naming a session's scope ('markierten ', …, with a trailing space;
// '' for the whole set). It reads right after "den" and "alle".
const SCOPE_ADJECTIVES = { starred: 'markierten', learning: 'offenen', missed: 'falsch beantworteten' };

function scopeAdjective(subset) {
  if (subset && typeof subset === 'object') return 'ausgewählten ';
  return SCOPE_ADJECTIVES[subset] ? `${SCOPE_ADJECTIVES[subset]} ` : '';
}

// 'Du hast alle markierten Begriffe gemeistert!' (the finish screen's title).
export function finishTitle(subset = 'all', total = 2) {
  const adj = scopeAdjective(subset);
  return total === 1 ? `Du hast den ${adj}Begriff gemeistert!` : `Du hast alle ${adj}Begriffe gemeistert!`;
}

// stats: learn.finalStats(). Cards mastered before the session are named apart:
// 'Alle 3 markierten Begriffe in 2 Runden gemeistert – stark!' or
// '44 Begriffe in 16 Runden gemeistert, 6 sassen schon vorher – stark!'
export function finishSubtitle({ total = 0, rounds = 0, alreadyMastered = 0 } = {}, subset = 'all') {
  const when = rounds > 0 ? ` in ${plural(rounds, 'Runde', 'Runden')}` : '';
  const before = Math.max(0, Number(alreadyMastered) || 0);
  const learned = total - before;
  if (before > 0 && learned > 0) {
    return `${plural(learned, 'Begriff', 'Begriffe')}${when} gemeistert, ${before} ${before === 1 ? 'sass' : 'sassen'} schon vorher – stark!`;
  }
  const adj = scopeAdjective(subset);
  const what = total === 1 ? `Den ${adj}Begriff` : `Alle ${total} ${adj}Begriffe`;
  return `${what}${when} gemeistert – stark!`;
}

// "Neu starten?" in a running session: what the new one covers.
export function restartSessionMessage(subset = 'all') {
  let what = 'mit allen Begriffen, die noch nicht sitzen';
  if (subset === 'starred') what = 'mit allen markierten Begriffen, die noch nicht sitzen';
  else if (subset === 'missed') what = 'mit allen zuletzt falsch beantworteten Begriffen';
  else if (subset && typeof subset === 'object') what = 'mit den ausgewählten Begriffen, die noch nicht sitzen';
  return `Du beginnst eine neue Lerneinheit ${what}. Dein Lernfortschritt bleibt gespeichert.`;
}

// How many cards a scope covers, for the "everything mastered" screen.
export function scopeText(subset, count) {
  if (subset === 'starred') return count === 1 ? 'den markierten Begriff' : `alle ${count} markierten Begriffe`;
  return count === 1 ? 'den Begriff' : `alle ${count} Begriffe`;
}

/* ------------------------------------------------- repetition questions */

// The chip on a repetition question (Wiederholungsfrage) of a card mastered before
// the session, in the colour of "Gemeistert".
export const REVIEW_LABEL = 'Wiederholung';
export const REVIEW_ARIA_LABEL = 'Wiederholungsfrage';
export const REVIEW_TOOLTIP = 'Diesen Begriff hast du schon gemeistert. Ist deine Antwort falsch, ist er wieder am Lernen.';
// After a missed repetition question: the card is learned again.
export const DEMOTED_TEXT = 'Wieder am Lernen';
// The "everything mastered" screen's offer to ask every mastered card once.
export const REVIEW_ALL_LABEL = 'Alle wiederholen';
export const REVIEW_ALL_TOOLTIP = 'Jeden gemeisterten Begriff einmal abfragen. Was falsch ist, lernst du neu.';

// The "everything mastered" screen: repeat them, reset the progress or practise
// writing (one card: "ihn … er … sitzt").
export function allMasteredText(subset, count) {
  const one = count === 1;
  return (
    `Du beherrschst bereits ${scopeText(subset, count)}. ` +
    `Wiederhole ${one ? 'ihn' : 'sie'}, um zu prüfen, ob ${one ? 'er noch sitzt' : 'sie noch sitzen'}, ` +
    `setz den Fortschritt zurück, um nochmal von vorne zu lernen, oder übe ${one ? 'ihn' : 'sie'} schriftlich.`
  );
}

// The finish screen's line about the repetition questions (stats: learn.reviewStats()),
// e.g. '12 gemeisterte Begriffe wiederholt, 2 davon sind wieder am Lernen.'; null
// before the first one was answered (or without repetition questions).
export function reviewLine(stats) {
  if (!isObj(stats) || !(stats.asked > 0)) return null;
  const asked = plural(stats.asked, 'gemeisterten Begriff', 'gemeisterte Begriffe');
  const missed = stats.asked - Math.max(0, Number(stats.kept) || 0);
  if (missed <= 0) return `${asked} wiederholt, ${stats.asked === 1 ? 'er sass' : 'alle sassen'} noch.`;
  return `${asked} wiederholt, ${missed} davon ${missed === 1 ? 'ist' : 'sind'} wieder am Lernen.`;
}

/* ------------------------------------------- sessions over chosen cards */

const safeDecode = (s) => {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
};

// '/set/<id>/learn?new=1&cards=<id1>,<id2>' (each id encodeURIComponent-ed, so an id
// may contain ',' or '&'), plus '&review=1' to ask the mastered ones again.
export function learnCardsPath(setId, cardIds, { review = false } = {}) {
  const ids = [...new Set((Array.isArray(cardIds) ? cardIds : []).filter((id) => id != null && id !== '').map(String))];
  return `/set/${encodeURIComponent(String(setId))}/learn?new=1&cards=${ids.map(encodeURIComponent).join(',')}${review ? '&review=1' : ''}`;
}

// The card ids of a 'cards=' parameter, read from the raw (still encoded) location
// hash: the router decodes query values as a whole, which would split an id with
// an encoded ','. null without the parameter; ids are unique, empty ones dropped.
export function cardIdsFromHash(hash) {
  const raw = String(hash || '');
  const q = raw.indexOf('?');
  if (q < 0) return null;
  let value = null;
  for (const part of raw.slice(q + 1).split('&')) {
    const eq = part.indexOf('=');
    const key = safeDecode((eq >= 0 ? part.slice(0, eq) : part).replace(/\+/g, ' '));
    if (key === 'cards') value = eq >= 0 ? part.slice(eq + 1) : ''; // the last one wins, like the router
  }
  if (value == null) return null;
  const ids = value.split(',').map((id) => safeDecode(id.replace(/\+/g, ' ')));
  return [...new Set(ids.filter((id) => id !== ''))];
}

// "Ausgewählte Begriffe · Runde 3 · 18 von 52 gemeistert" for a running Learn
// session (the set page's wording); `state` is in line with the progress.
const SCOPE_LABELS = { starred: 'Nur markierte', learning: 'Nur nicht gemeisterte', missed: 'Nur falsche' };

export function learnSessionDetail(state) {
  const parts = [];
  const subset = isObj(state) ? state.subset : null;
  const scope = isObj(subset) ? 'Ausgewählte Begriffe' : SCOPE_LABELS[subset] || null;
  if (scope) parts.push(scope);
  const c = learnCounts(state);
  const round = isObj(state) && Number.isInteger(state.round) && state.round > 0 ? state.round : 1;
  // A round without answers (only after removals) shows no checkpoint: it is not "geschafft".
  const roundOver = isRoundOver(state) && checkpoint(state).answered > 0;
  parts.push(roundOver ? `Runde ${round} geschafft` : `Runde ${round}`);
  parts.push(`${c.mastered} von ${c.total} gemeistert`);
  // A line only breaks between parts, never inside one.
  return parts.map((p) => p.replace(/ /g, ' ')).join(' · ');
}

// The stored Learn session that a new one would end (brought in line with the
// progress): unfinished, with cards and with answers. null when there is none.
export function runningLearnSession(saved, progress) {
  if (!isObj(saved) || saved.finishedAt != null) return null;
  let state;
  try {
    const { feedback, ...rest } = saved;
    state = syncProgress(rest, isObj(progress) ? progress : {}, Date.now());
  } catch {
    return null;
  }
  if (!state.order.length || isFinished(state) || !hasLearnAnswers(state)) return null;
  return state;
}

export function segmentCount(total, roundSize) {
  if (!(total > 0)) return 1;
  const size = typeof roundSize === 'number' && roundSize >= 1 ? Math.floor(roundSize) : DEFAULT_ROUND_SIZE;
  return Math.max(1, Math.min(MAX_SEGMENTS, Math.ceil(total / size)));
}

// Fill of each segment (0..1): `mastered` (green) and `reached` (mastered +
// learning, amber below green), filling the bar from the left.
export function segmentFills({ mastered = 0, learning = 0, total = 0 } = {}, count = 1) {
  const n = Math.max(1, Math.floor(Number(count) || 1));
  const t = Math.max(0, Number(total) || 0);
  const share = (v) => (t > 0 ? (Math.max(0, Number(v) || 0) / t) * n : 0);
  const m = share(mastered);
  const r = share((Number(mastered) || 0) + (Number(learning) || 0));
  const out = [];
  for (let i = 0; i < n; i++) out.push({ mastered: clamp01(m - i), reached: clamp01(r - i) });
  return out;
}

// '18 von 52 gemeistert, 7 am Lernen, 27 neu'
export function progressText({ fresh = 0, learning = 0, mastered = 0, total = 0 } = {}) {
  return `${masteredLine(mastered, total)}, ${learning} am Lernen, ${fresh} neu`;
}
