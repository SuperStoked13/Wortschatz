// Learn mode's pure helpers (src/screens/learn-model.js): praise, resuming a stored
// session and its open "Nicht ganz" screen, options that need a restart, option
// texts after edits, checkpoint status, the segmented progress bar and copy texts.
import { test, expect, run } from './harness.js';
import {
  PRAISE,
  MAX_SEGMENTS,
  pickPraise,
  canResumeLearn,
  hasLearnAnswers,
  pendingLearnFeedback,
  sessionSettings,
  settingsChanges,
  restartMessage,
  choiceTexts,
  stageStatus,
  checkpointStatus,
  masteredLine,
  checkpointTitle,
  remainingText,
  finishTitle,
  finishSubtitle,
  restartSessionMessage,
  scopeText,
  segmentCount,
  segmentFills,
  progressText,
  sameSubset,
  REVIEW_LABEL,
  REVIEW_ARIA_LABEL,
  REVIEW_TOOLTIP,
  DEMOTED_TEXT,
  REVIEW_ALL_LABEL,
  REVIEW_ALL_TOOLTIP,
  allMasteredText,
  reviewLine,
  learnCardsPath,
  cardIdsFromHash,
  learnSessionDetail,
  runningLearnSession,
} from '../src/screens/learn-model.js';
import * as L from '../src/core/learn.js';

function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const T0 = 1760000000000;
const OPTS = { answerWith: 'term', learn: { roundSize: 7, mc: true, written: true, retype: false } };

function makeCards(n) {
  return Array.from({ length: n }, (_, i) => ({ id: `c${i + 1}`, term: `terme ${i + 1}`, definition: `Begriff ${i + 1}`, starred: i % 2 === 0 }));
}

// A session whose first question (multiple choice) was answered wrong.
function missedMc() {
  const cards = makeCards(6);
  let s = L.createLearn(cards, OPTS, { rng: mulberry32(7), now: T0 });
  const q = L.current(s);
  s = L.answer(s, false, T0 + 1000);
  const wrong = q.choices.find((c) => c.cardId !== q.cardId);
  return { cards, s, q, feedback: { qid: q.qid, cardId: q.cardId, type: 'mc', ask: q.ask, choices: q.choices, chosen: wrong.cardId } };
}

// A session whose first written question was answered wrong.
function missedWritten() {
  const cards = makeCards(4);
  const progress = Object.fromEntries(cards.map((c) => [c.id, { correct: 1, incorrect: 0, streak: 1, streakBefore: 0, lastResult: 'correct', lastAnsweredAt: T0 }]));
  let s = L.createLearn(cards, OPTS, { rng: mulberry32(3), now: T0, progress });
  const q = L.current(s);
  s = L.answer(s, false, T0 + 1000);
  return { s, q, feedback: { qid: q.qid, cardId: q.cardId, type: 'written', ask: q.ask, given: 'terme 9', dontKnow: false } };
}

/* ------------------------------------------------------------------ praise */

test('praise is varied: never the same twice in a row', () => {
  const rng = mulberry32(11);
  let prev = null;
  const seen = new Set();
  for (let i = 0; i < 200; i++) {
    const p = pickPraise(prev, rng);
    expect(PRAISE).toContain(p);
    expect(p === prev).toBe(false);
    seen.add(p);
    prev = p;
  }
  expect(seen.size).toBe(PRAISE.length);
  expect(PRAISE).toEqual(['Super!', 'Klasse!', 'Genau!', 'Weiter so!', 'Stark!']);
});

test('praise tolerates a misbehaving rng and a one-item pool', () => {
  expect(PRAISE).toContain(pickPraise(null, () => 7));
  expect(PRAISE).toContain(pickPraise(null, () => -3));
  expect(PRAISE).toContain(pickPraise(null, () => NaN));
  expect(pickPraise('Top!', Math.random, ['Top!'])).toBe('Top!');
});

/* ------------------------------------------------------------------ resume */

test('canResumeLearn: running sessions resume, finished/empty/forced/other subsets do not', () => {
  const cards = makeCards(5);
  const s = L.createLearn(cards, OPTS, { rng: mulberry32(1), now: T0 });
  expect(canResumeLearn(s)).toBe(true);
  expect(canResumeLearn(s, { subset: 'all' })).toBe(true);
  expect(canResumeLearn(s, { subset: 'starred' })).toBe(false);
  expect(canResumeLearn(s, { forceNew: true })).toBe(false);
  expect(canResumeLearn(null)).toBe(false);
  expect(canResumeLearn({ order: [] })).toBe(false);
  expect(canResumeLearn({ ...s, finishedAt: T0 })).toBe(false);
  // Everything mastered (but not stamped yet) is not resumable either.
  const mastered = { ...s, stage: Object.fromEntries(s.order.map((id) => [id, 2])) };
  expect(canResumeLearn(mastered)).toBe(false);
});

test('hasLearnAnswers: answers in this round or earlier rounds', () => {
  const cards = makeCards(5);
  const s = L.createLearn(cards, OPTS, { rng: mulberry32(1), now: T0 });
  expect(hasLearnAnswers(s)).toBe(false);
  expect(hasLearnAnswers(L.answer(s, true, T0 + 10))).toBe(true);
  expect(hasLearnAnswers({ rounds: [{ round: 1 }] })).toBe(true);
  expect(hasLearnAnswers(null)).toBe(false);
});

/* -------------------------------------------------------- pending feedback */

test('pendingLearnFeedback: a missed multiple choice question comes back with its options', () => {
  const { s, q, feedback } = missedMc();
  const p = pendingLearnFeedback(s, JSON.parse(JSON.stringify(feedback)));
  expect(p).toEqual({ qid: q.qid, cardId: q.cardId, type: 'mc', ask: q.ask, choices: q.choices, chosen: feedback.chosen });
  // "Weiss ich nicht?" has no chosen option.
  expect(pendingLearnFeedback(s, { ...feedback, chosen: null }).chosen).toBe(null);
});

test('pendingLearnFeedback: a missed written question keeps what was typed', () => {
  const { s, q, feedback } = missedWritten();
  expect(q.type).toBe('written');
  expect(pendingLearnFeedback(s, feedback)).toEqual({ qid: q.qid, cardId: q.cardId, type: 'written', ask: q.ask, given: 'terme 9', dontKnow: false });
  expect(pendingLearnFeedback(s, { ...feedback, given: '   ' }).dontKnow).toBe(true);
  expect(pendingLearnFeedback(s, { ...feedback, given: 'x'.repeat(5000) }).given.length).toBe(1000);
});

test('pendingLearnFeedback: invalid once overridden, after the round or for another question', () => {
  const { s, feedback } = missedMc();
  expect(pendingLearnFeedback(L.override(s, T0 + 2000), feedback)).toBe(null);
  expect(pendingLearnFeedback(s, { ...feedback, qid: 'other' })).toBe(null);
  expect(pendingLearnFeedback(s, { ...feedback, type: 'written' })).toBe(null);
  expect(pendingLearnFeedback(s, { ...feedback, cardId: 'c99' })).toBe(null);
  expect(pendingLearnFeedback(s, null)).toBe(null);
  expect(pendingLearnFeedback(null, feedback)).toBe(null);
  // The chosen option must be a wrong one, and the options must contain the card.
  expect(pendingLearnFeedback(s, { ...feedback, chosen: feedback.cardId })).toBe(null);
  expect(pendingLearnFeedback(s, { ...feedback, chosen: 'nope' })).toBe(null);
  expect(pendingLearnFeedback(s, { ...feedback, choices: feedback.choices.filter((c) => c.cardId !== feedback.cardId) })).toBe(null);
  // A later correct answer replaces `last`.
  let t = s;
  while (L.current(t)) t = L.answer(t, true, T0 + 3000);
  expect(pendingLearnFeedback(t, feedback)).toBe(null);
  // nextRound clears `last`.
  expect(pendingLearnFeedback(L.nextRound(t, makeCards(6), mulberry32(2), T0 + 4000), feedback)).toBe(null);
});

/* ------------------------------------------------------------- restarts */

test('settingsChanges: direction, question types and round size need a restart', () => {
  const cards = makeCards(5);
  const s = L.createLearn(cards, OPTS, { rng: mulberry32(1), now: T0 });
  expect(sessionSettings(s)).toEqual({ answerWith: 'term', roundSize: 7, mc: true, written: true });
  expect(settingsChanges(s, OPTS)).toEqual([]);
  // Tolerance, audio and retype do not shape the session.
  expect(settingsChanges(s, { ...OPTS, audio: true, tolerance: { typos: true }, learn: { ...OPTS.learn, retype: true } })).toEqual([]);
  expect(settingsChanges(s, { ...OPTS, answerWith: 'both' })).toEqual(['direction']);
  expect(settingsChanges(s, { ...OPTS, learn: { ...OPTS.learn, mc: false } })).toEqual(['types']);
  expect(settingsChanges(s, { ...OPTS, learn: { ...OPTS.learn, roundSize: 10 } })).toEqual(['roundSize']);
  expect(settingsChanges(s, { answerWith: 'definition', learn: { roundSize: 5, mc: true, written: false } })).toEqual(['direction', 'types', 'roundSize']);
  // Both types off counts as both on (as in the engine).
  expect(settingsChanges(s, { ...OPTS, learn: { roundSize: 7, mc: false, written: false } })).toEqual([]);
});

test('restartMessage names a single change, or the settings in general', () => {
  expect(restartMessage(['direction'])).toBe('Die neue Abfragerichtung gilt ab einem Neustart. Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert.');
  expect(restartMessage(['types']).startsWith('Die neuen Fragetypen gelten ab einem Neustart.')).toBe(true);
  expect(restartMessage(['roundSize']).startsWith('Die neue Rundengrösse gilt ab')).toBe(true);
  expect(restartMessage(['direction', 'roundSize']).startsWith('Die neuen Einstellungen gelten ab')).toBe(true);
});

/* ---------------------------------------------------------- option texts */

test('choiceTexts shows the current card texts and keeps stored texts of deleted cards', () => {
  const cards = new Map([
    ['a', { id: 'a', term: 'le nom de famille', definition: 'der Nachname' }],
    ['b', { id: 'b', term: '  la rue ', definition: 'die Strasse' }],
  ]);
  const choices = [
    { cardId: 'a', text: 'le nom' },
    { cardId: 'b', text: 'la rue' },
    { cardId: 'gone', text: "l'enfant" },
  ];
  expect(choiceTexts(choices, cards, 'term')).toEqual([
    { cardId: 'a', text: 'le nom de famille' },
    { cardId: 'b', text: 'la rue' },
    { cardId: 'gone', text: "l'enfant" },
  ]);
  expect(choiceTexts(choices, cards, 'definition').map((c) => c.text)).toEqual(['der Nachname', 'die Strasse', "l'enfant"]);
  expect(choiceTexts(null, cards, 'term')).toEqual([]);
});

/* ------------------------------------------------------------ checkpoint */

test('stageStatus: Gemeistert / Am Lernen / Noch neu', () => {
  expect(stageStatus(2)).toEqual({ key: 'mastered', label: 'Gemeistert', tone: 'success', icon: 'check' });
  expect(stageStatus(1).label).toBe('Am Lernen');
  expect(stageStatus(1).tone).toBe('warning');
  expect(stageStatus(0).label).toBe('Noch neu');
});

test('checkpointStatus: a card answered in the round is never "Noch neu" (as in the counters)', () => {
  expect(checkpointStatus(0)).toEqual(stageStatus(1));
  expect(checkpointStatus(0).label).toBe('Am Lernen');
  expect(checkpointStatus(1).label).toBe('Am Lernen');
  expect(checkpointStatus(2).label).toBe('Gemeistert');
  // The rule of the counters: a wrongly answered card (stage 0) is seen, so it is not new.
  const cards = Array.from({ length: 3 }, (_, i) => ({ id: `k${i}`, term: `t${i}`, definition: `d${i}` }));
  let s = L.createLearn(cards, OPTS, { rng: mulberry32(5), now: T0 });
  while (!L.isRoundOver(s)) s = L.answer(s, false, T0 + 1000);
  const cp = L.checkpoint(s);
  expect(cp.counts.fresh).toBe(0);
  expect(cp.items.every((it) => it.stage === 0 && checkpointStatus(it.stage).key === 'learning')).toBe(true);
});

test('finish and restart texts name the scope', () => {
  expect(finishTitle('all', 52)).toBe('Du hast alle Begriffe gemeistert!');
  expect(finishTitle('starred', 3)).toBe('Du hast alle markierten Begriffe gemeistert!');
  expect(finishTitle('starred', 1)).toBe('Du hast den markierten Begriff gemeistert!');
  expect(finishTitle('learning', 5)).toBe('Du hast alle offenen Begriffe gemeistert!');
  expect(finishTitle('missed', 2)).toBe('Du hast alle falsch beantworteten Begriffe gemeistert!');
  expect(finishTitle({ cardIds: ['a', 'b'] }, 2)).toBe('Du hast alle ausgewählten Begriffe gemeistert!');
  expect(finishTitle('all', 1)).toBe('Du hast den Begriff gemeistert!');
  expect(finishSubtitle({ total: 3, rounds: 3 }, 'starred')).toBe('Alle 3 markierten Begriffe in 3 Runden gemeistert – stark!');
  expect(finishSubtitle({ total: 1, rounds: 2 }, 'starred')).toBe('Den markierten Begriff in 2 Runden gemeistert – stark!');
  // Cards mastered before the session started are not counted as learned in it.
  expect(finishSubtitle({ total: 50, rounds: 16, alreadyMastered: 6 })).toBe('44 Begriffe in 16 Runden gemeistert, 6 sassen schon vorher – stark!');
  expect(finishSubtitle({ total: 3, rounds: 3, alreadyMastered: 1 }, 'starred')).toBe('2 Begriffe in 3 Runden gemeistert, 1 sass schon vorher – stark!');
  expect(finishSubtitle({ total: 2, rounds: 1, alreadyMastered: 1 })).toBe('1 Begriff in 1 Runde gemeistert, 1 sass schon vorher – stark!');
  // Mastered elsewhere before any Learn round was closed: no "in 0 Runden".
  expect(finishSubtitle({ total: 4, rounds: 0 })).toBe('Alle 4 Begriffe gemeistert – stark!');
  expect(restartSessionMessage('all')).toBe('Du beginnst eine neue Lerneinheit mit allen Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert.');
  expect(restartSessionMessage('learning')).toBe(restartSessionMessage('all'));
  expect(restartSessionMessage('starred')).toBe('Du beginnst eine neue Lerneinheit mit allen markierten Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert.');
  expect(restartSessionMessage('missed')).toBe('Du beginnst eine neue Lerneinheit mit allen zuletzt falsch beantworteten Begriffen. Dein Lernfortschritt bleibt gespeichert.');
  expect(restartSessionMessage({ cardIds: ['a'] })).toBe('Du beginnst eine neue Lerneinheit mit den ausgewählten Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert.');
  // A finished starred session: the stats from the engine feed the texts.
  const cards = Array.from({ length: 3 }, (_, i) => ({ id: `s${i}`, term: `t${i}`, definition: `d${i}`, starred: true }));
  const progress = { s0: { correct: 2, incorrect: 0, streak: 2, streakBefore: 1, lastResult: 'correct', lastAnsweredAt: T0 } };
  let s = L.createLearn(cards, OPTS, { subset: 'starred', progress, rng: mulberry32(9), now: T0 });
  for (let i = 0; i < 20 && !L.isFinished(s); i++) {
    if (L.isRoundOver(s)) s = L.nextRound(s, cards, mulberry32(i), T0 + i * 1000);
    else s = L.answer(s, true, T0 + i * 1000);
  }
  s = L.nextRound(s, cards, mulberry32(99), T0 + 60000);
  const stats = L.finalStats(s);
  expect(stats.alreadyMastered).toBe(1);
  expect(finishSubtitle(stats, s.subset)).toBe(`2 Begriffe in ${stats.rounds === 1 ? '1 Runde' : `${stats.rounds} Runden`} gemeistert, 1 sass schon vorher – stark!`);
});

test('checkpoint and finish texts', () => {
  expect(masteredLine(18, 52)).toBe('18 von 52 gemeistert');
  expect(progressText({ fresh: 27, learning: 7, mastered: 18, total: 52 })).toBe('18 von 52 gemeistert, 7 am Lernen, 27 neu');
  expect(checkpointTitle(1)).toBe('Hervorragend!');
  expect(checkpointTitle(0.75)).toBe('Gut gemacht!');
  expect(checkpointTitle(0.5)).toBe('Du machst Fortschritte!');
  expect(checkpointTitle(0)).toBe('Dranbleiben – das wird!');
  expect(remainingText({ mastered: 18, total: 52 })).toBe('Noch 34 Begriffe, bis alles sitzt.');
  expect(remainingText({ mastered: 51, total: 52 })).toBe('Noch 1 Begriff, bis alles sitzt.');
  expect(remainingText({ mastered: 52, total: 52 })).toBe('Alles sitzt!');
  expect(finishSubtitle({ total: 52, rounds: 9 })).toBe('Alle 52 Begriffe in 9 Runden gemeistert – stark!');
  expect(finishSubtitle({ total: 1, rounds: 1 })).toBe('Den Begriff in 1 Runde gemeistert – stark!');
  expect(scopeText('all', 52)).toBe('alle 52 Begriffe');
  expect(scopeText('starred', 3)).toBe('alle 3 markierten Begriffe');
  expect(scopeText('starred', 1)).toBe('den markierten Begriff');
  expect(scopeText({ cardIds: ['a'] }, 1)).toBe('den Begriff');
});

/* ------------------------------------------------------- segmented bar */

test('segmentCount: one segment per round-sized batch, at least one, at most MAX_SEGMENTS', () => {
  expect(segmentCount(52, 7)).toBe(8);
  expect(segmentCount(52, 15)).toBe(4);
  expect(segmentCount(3, 7)).toBe(1);
  expect(segmentCount(0, 7)).toBe(1);
  expect(segmentCount(500, 5)).toBe(MAX_SEGMENTS);
  expect(segmentCount(14, undefined)).toBe(2);
});

test('segmentFills fill the bar from the left: mastered, then learning', () => {
  const fills = segmentFills({ mastered: 3, learning: 3, total: 8 }, 4);
  expect(fills).toEqual([
    { mastered: 1, reached: 1 },
    { mastered: 0.5, reached: 1 },
    { mastered: 0, reached: 1 },
    { mastered: 0, reached: 0 },
  ]);
  expect(segmentFills({ mastered: 0, learning: 0, total: 0 }, 3)).toEqual([
    { mastered: 0, reached: 0 },
    { mastered: 0, reached: 0 },
    { mastered: 0, reached: 0 },
  ]);
  expect(segmentFills({ mastered: 52, learning: 0, total: 52 }, 8).every((f) => f.mastered === 1 && f.reached === 1)).toBe(true);
  expect(segmentFills({ mastered: 1, learning: 0, total: 2 }, 0)).toEqual([{ mastered: 0.5, reached: 0.5 }]);
});

/* ------------------------------------------------- repetition questions */

// Mastered progress for `cards`, the first one answered longest ago.
function masteredProgress(cards) {
  return Object.fromEntries(
    cards.map((c, i) => [c.id, { correct: 2, incorrect: 0, streak: 2, streakBefore: 1, lastResult: 'correct', lastAnsweredAt: T0 - 100000 + i }]),
  );
}

test('review copy: the chip, the miss and "Alle wiederholen" (Mac strings)', () => {
  expect(REVIEW_LABEL).toBe('Wiederholung');
  expect(REVIEW_ARIA_LABEL).toBe('Wiederholungsfrage');
  expect(REVIEW_TOOLTIP).toBe('Diesen Begriff hast du schon gemeistert. Ist deine Antwort falsch, ist er wieder am Lernen.');
  expect(DEMOTED_TEXT).toBe('Wieder am Lernen');
  expect(REVIEW_ALL_LABEL).toBe('Alle wiederholen');
  expect(REVIEW_ALL_TOOLTIP).toBe('Jeden gemeisterten Begriff einmal abfragen. Was falsch ist, lernst du neu.');
});

test('allMasteredText offers to repeat, reset or write (one card: ihn/er)', () => {
  expect(allMasteredText('all', 12)).toBe(
    'Du beherrschst bereits alle 12 Begriffe. Wiederhole sie, um zu prüfen, ob sie noch sitzen, setz den Fortschritt zurück, um nochmal von vorne zu lernen, oder übe sie schriftlich.',
  );
  expect(allMasteredText('starred', 3).startsWith('Du beherrschst bereits alle 3 markierten Begriffe. Wiederhole sie,')).toBe(true);
  expect(allMasteredText({ cardIds: ['a'] }, 1)).toBe(
    'Du beherrschst bereits den Begriff. Wiederhole ihn, um zu prüfen, ob er noch sitzt, setz den Fortschritt zurück, um nochmal von vorne zu lernen, oder übe ihn schriftlich.',
  );
});

test('reviewLine: how many mastered cards were repeated and how many sit no more', () => {
  expect(reviewLine({ asked: 12, kept: 10, left: 0 })).toBe('12 gemeisterte Begriffe wiederholt, 2 davon sind wieder am Lernen.');
  expect(reviewLine({ asked: 4, kept: 3, left: 0 })).toBe('4 gemeisterte Begriffe wiederholt, 1 davon ist wieder am Lernen.');
  expect(reviewLine({ asked: 3, kept: 3, left: 2 })).toBe('3 gemeisterte Begriffe wiederholt, alle sassen noch.');
  expect(reviewLine({ asked: 1, kept: 1, left: 0 })).toBe('1 gemeisterten Begriff wiederholt, er sass noch.');
  expect(reviewLine({ asked: 1, kept: 0, left: 0 })).toBe('1 gemeisterten Begriff wiederholt, 1 davon ist wieder am Lernen.');
  // Before the first repetition question, or without them: no line.
  expect(reviewLine({ asked: 0, kept: 0, left: 5 })).toBe(null);
  expect(reviewLine(null)).toBe(null);
  expect(reviewLine(L.reviewStats(L.createLearn(makeCards(3), OPTS, { rng: mulberry32(1), now: T0 })))).toBe(null);
});

test('the screen starts with repetition questions when everything is mastered and the option is on', () => {
  const cards = makeCards(5);
  const progress = masteredProgress(cards);
  // Off: nothing to study, the "Alles gemeistert!" screen offers "Alle wiederholen".
  const off = L.createLearn(cards, OPTS, { progress, rng: mulberry32(2), now: T0 });
  expect(L.isFinished(off)).toBe(true);
  expect(canResumeLearn(off)).toBe(false);
  // On (or "Alle wiederholen"): a written repetition question first; the session can be resumed.
  const on = L.createLearn(cards, OPTS, { progress, rng: mulberry32(2), now: T0, review: true });
  const q = L.current(on);
  expect(L.isReviewQuestion(q.qid)).toBe(true);
  expect(q.type).toBe('written');
  expect(canResumeLearn(JSON.parse(JSON.stringify(on)))).toBe(true);
  expect(hasLearnAnswers(on)).toBe(false);
});

test('switching "Wiederholungsfragen" asks to restart; the message names it', () => {
  const cards = makeCards(6);
  const plain = L.createLearn(cards, OPTS, { rng: mulberry32(2), now: T0 });
  const review = L.createLearn(cards, OPTS, { rng: mulberry32(2), now: T0, review: true });
  expect(settingsChanges(plain, OPTS)).toEqual([]);
  expect(settingsChanges(plain, { ...OPTS, review: true })).toEqual(['review']);
  expect(settingsChanges(review, { ...OPTS, review: true })).toEqual([]);
  expect(settingsChanges(review, OPTS)).toEqual(['review']);
  expect(settingsChanges(review, { ...OPTS, answerWith: 'both', review: false })).toEqual(['direction', 'review']);
  expect(settingsChanges({ ...OPTS, review: false }, { ...OPTS, review: true })).toEqual(['review']);
  expect(restartMessage(['review'])).toBe('Die Einstellung für Wiederholungsfragen gilt ab einem Neustart. Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert.');
  expect(restartMessage(['review', 'types']).startsWith('Die neuen Einstellungen gelten ab')).toBe(true);
});

/* ---------------------------------------------- sessions over chosen cards */

test('sameSubset: named subsets by name, chosen cards in any order', () => {
  expect(sameSubset('all', 'all')).toBe(true);
  expect(sameSubset('all', 'starred')).toBe(false);
  expect(sameSubset({ cardIds: ['a', 'b'] }, { cardIds: ['b', 'a'] })).toBe(true);
  expect(sameSubset({ cardIds: ['a', 'b'] }, { cardIds: ['a', 'b', 'c'] })).toBe(false);
  expect(sameSubset({ cardIds: ['a'] }, 'all')).toBe(false);
  expect(sameSubset('all', { cardIds: [] })).toBe(false);
  expect(sameSubset({ cardIds: [] }, { cardIds: [] })).toBe(true);
  expect(sameSubset({}, { cardIds: [] })).toBe(false);
});

test('canResumeLearn compares chosen cards by value', () => {
  const cards = makeCards(6);
  const s = JSON.parse(JSON.stringify(L.createLearn(cards, OPTS, { subset: { cardIds: ['c2', 'c4'] }, rng: mulberry32(1), now: T0 })));
  expect(canResumeLearn(s, { subset: { cardIds: ['c4', 'c2'] } })).toBe(true);
  expect(canResumeLearn(s, { subset: { cardIds: ['c4'] } })).toBe(false);
  expect(canResumeLearn(s, { subset: 'all' })).toBe(false);
  expect(canResumeLearn(s)).toBe(true);
});

test('learnCardsPath and cardIdsFromHash: any card id survives the link', () => {
  const ids = ['c1', 'a,b', 'x&y=z', '50%', 'sp ace', 'plus+one', 'ümlaut', 'q?r#s', 'a/b'];
  const path = learnCardsPath('set 1', ids, { review: true });
  expect(path.startsWith('/set/set%201/learn?new=1&cards=c1,a%2Cb,x%26y%3Dz,')).toBe(true);
  expect(path.endsWith('&review=1')).toBe(true);
  expect(cardIdsFromHash(`#${path}`)).toEqual(ids);
  expect(learnCardsPath('s', ['a', 'b'])).toBe('/set/s/learn?new=1&cards=a,b');
  // Duplicates and empty ids are dropped on both sides.
  expect(learnCardsPath('s', ['a', '', null, 'a', 7])).toBe('/set/s/learn?new=1&cards=a,7');
  expect(cardIdsFromHash('#/set/s/learn?new=1&cards=a,,b,a')).toEqual(['a', 'b']);
  // No parameter, an empty one, a broken escape, hand-typed '+'.
  expect(cardIdsFromHash('#/set/s/learn?new=1')).toBe(null);
  expect(cardIdsFromHash('#/set/s/learn')).toBe(null);
  expect(cardIdsFromHash('')).toBe(null);
  expect(cardIdsFromHash('#/set/s/learn?cards=')).toEqual([]);
  expect(cardIdsFromHash('#/set/s/learn?cards')).toEqual([]);
  expect(cardIdsFromHash('#/set/s/learn?cards=%E0%A4,ok')).toEqual(['%E0%A4', 'ok']);
  expect(cardIdsFromHash('#/set/s/learn?cards=a+b')).toEqual(['a b']);
  // The last 'cards' wins, like the router's query parsing.
  expect(cardIdsFromHash('#/set/s/learn?cards=a&cards=b')).toEqual(['b']);
});

test('learnSessionDetail: scope, round and mastered count (the set page wording)', () => {
  const cards = makeCards(6);
  const nb = (text) => text.replace(/ /g, ' ');
  let s = L.createLearn(cards, { ...OPTS, learn: { ...OPTS.learn, roundSize: 3 } }, { subset: { cardIds: ['c1', 'c2', 'c3', 'c4'] }, rng: mulberry32(4), now: T0 });
  expect(learnSessionDetail(s)).toBe([nb('Ausgewählte Begriffe'), nb('Runde 1'), nb('0 von 4 gemeistert')].join(' · '));
  while (L.current(s)) s = L.answer(s, true, T0 + 1000);
  expect(learnSessionDetail(s)).toBe([nb('Ausgewählte Begriffe'), nb('Runde 1 geschafft'), nb('0 von 4 gemeistert')].join(' · '));
  const starred = L.createLearn(cards, OPTS, { subset: 'starred', rng: mulberry32(4), now: T0 });
  expect(learnSessionDetail(starred).startsWith(nb('Nur markierte'))).toBe(true);
  expect(learnSessionDetail(L.createLearn(cards, OPTS, { rng: mulberry32(4), now: T0 }))).toBe([nb('Runde 1'), nb('0 von 6 gemeistert')].join(' · '));
});

test('runningLearnSession: only an unfinished stored session with answers', () => {
  const cards = makeCards(5);
  const s = L.createLearn(cards, OPTS, { rng: mulberry32(5), now: T0 });
  expect(runningLearnSession(s, {})).toBe(null); // no answers yet
  const q = L.current(s);
  const answered = L.answer(s, true, T0 + 1000);
  const progress = { [q.cardId]: { correct: 1, incorrect: 0, streak: 1, streakBefore: 0, lastResult: 'correct', lastAnsweredAt: T0 + 1000 } };
  const running = runningLearnSession({ ...JSON.parse(JSON.stringify(answered)), feedback: { qid: 'x' } }, progress);
  expect(running.answered).toBe(1);
  expect('feedback' in running).toBe(false);
  expect(runningLearnSession({ ...answered, finishedAt: T0 }, progress)).toBe(null);
  expect(runningLearnSession(null, progress)).toBe(null);
  expect(runningLearnSession('junk', progress)).toBe(null);
  // Everything mastered elsewhere since: nothing left to end.
  const all = Object.fromEntries(cards.map((c) => [c.id, { correct: 2, incorrect: 0, streak: 2, streakBefore: 1, lastResult: 'correct', lastAnsweredAt: T0 }]));
  expect(runningLearnSession(answered, all)).toBe(null);
});

/* ----------------------------------------------------------- copy rules */

test('Swiss spelling: no sharp s in any Learn text', () => {
  const texts = [
    ...PRAISE,
    restartMessage(['direction']),
    restartMessage(['types']),
    restartMessage(['roundSize']),
    restartMessage(['direction', 'types']),
    ...[0, 1, 2].map((s) => stageStatus(s).label),
    checkpointTitle(1),
    checkpointTitle(0.75),
    checkpointTitle(0.5),
    checkpointTitle(0),
    remainingText({ mastered: 1, total: 3 }),
    finishSubtitle({ total: 3, rounds: 2 }),
    finishSubtitle({ total: 3, rounds: 2, alreadyMastered: 1 }),
    finishSubtitle({ total: 3, rounds: 2, alreadyMastered: 2 }),
    ...['all', 'starred', 'learning', 'missed', { cardIds: [] }].flatMap((sub) => [finishTitle(sub, 2), finishTitle(sub, 1), restartSessionMessage(sub)]),
    scopeText('starred', 2),
    progressText({ fresh: 1, learning: 1, mastered: 1, total: 3 }),
    restartMessage(['review']),
    REVIEW_LABEL,
    REVIEW_ARIA_LABEL,
    REVIEW_TOOLTIP,
    DEMOTED_TEXT,
    REVIEW_ALL_LABEL,
    REVIEW_ALL_TOOLTIP,
    allMasteredText('all', 1),
    allMasteredText('starred', 4),
    ...[
      [1, 1],
      [2, 2],
      [3, 2],
      [4, 1],
    ].map(([asked, kept]) => reviewLine({ asked, kept, left: 0 })),
  ];
  expect(texts.join(' ').includes('ß')).toBe(false);
});

await run('learn-model.test.js');
