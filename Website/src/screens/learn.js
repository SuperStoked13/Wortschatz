// Learn mode (#/set/:id/learn): Quizlet-style "Lernen".
//
// A new card is asked as multiple choice first; after a correct answer its next
// question is written, and a second correct answer masters it (core/learn.js).
// The session runs in rounds of a few cards with a checkpoint after each round
// and a celebration when every card in scope is mastered. Every state change is
// saved with db.saveLearn, so leaving and coming back resumes exactly where the
// learner stopped: an open "Nicht ganz" screen (stored next to the state), a
// checkpoint, or — on reload or Back in the same history entry — the finish screen.
// Learn shares the stored progress with Schreiben: answers given there (or in
// another tab) move the cards' stages here too.
//
// With "Wiederholungsfragen" (a preference for every set) or ?review=1 a new
// session also asks the cards mastered already once more ("↺ Wiederholung"); a
// miss puts such a card back to "Am Lernen". ?new=1&cards=<ids> starts a session
// over chosen cards (learn-start.js builds that link for other screens).
//
// Keys (Mac parity): Enter is the main key; on multiple choice the learner may type the
// answer (core/typeahead.js) or move a highlight with the arrows, 1–4 choose, 0 or
// Alt+Enter is «Weiss ich nicht», Ctrl+Enter «Ich hatte recht», Esc goes back to the
// set, Ctrl+K/R/D/E open the options, read aloud, star, edit, Ctrl+Shift+R restarts
// («Nochmal lernen» on the finish screen, where Enter is «Fertig»).
// Correct answers in a row show a flame (answer-streak.js); answers, finished rounds
// and the finish sound (lib/sounds.js), but never when a screen is only shown again.
//
// This module owns the session lifecycle and the screen; answering lives in
// learn-answer.js, dialogs and card actions in learn-dialogs.js. They share the
// screen context `c` built below.

import { h } from '../lib/dom.js';
import { LANGS } from '../lib/labels.js';
import { speak, stopSpeaking } from '../lib/speech.js';
import { playStudyStep } from '../lib/sounds.js';
import { db } from '../store/db.js';
import * as L from '../core/learn.js';
import { TYPING_IDLE, typingKey } from '../core/typeahead.js';
import { toast } from '../ui/components.js';
import { createCard } from './write-card.js';
import { createStudyClock } from './write-clock.js';
import { learnReviewEnabled } from '../ui/study-options.js';
import { ask } from './write-dialogs.js';
import { parseSubset, isUsableCard, questionInfo as buildQuestion, gradeQuestion, canShowResults, termRows } from './write-model.js';
import { emptySubsetView, missingSetView, attachStreakBadge } from './write-views.js';
import { settleEnter, settleOnLeave } from './write-keys.js';
import { isApplePlatform } from './editor-util.js';
import { STREAK_START, recordStreak, overrideStreak } from './answer-streak.js';
import { createMcCard } from './learn-mc.js';
import { bindLearnKeys } from './learn-keys.js';
import { createAnswering, MISS_TITLE } from './learn-answer.js';
import { createLearnDialogs } from './learn-dialogs.js';
import {
  canResumeLearn,
  hasLearnAnswers,
  pendingLearnFeedback,
  choiceTexts,
  segmentCount,
  masteredLine,
  finishTitle,
  sameSubset,
  cardIdsFromHash,
  REVIEW_ARIA_LABEL,
} from './learn-model.js';
import {
  createLearnSidebar,
  checkpointView,
  finishView,
  allMasteredView,
  introHint,
  introHintDismissed,
  dismissIntroHint,
  revealBelowBars,
  attachReviewMark,
} from './learn-views.js';

const ENTER_LOCK_MS = 280;
// Enter within this long of the answering press is that press itself (a bounce), not a
// request to skip the praise.
const SKIP_MIN_GAP_MS = 50;
const HINT_LEAVE_MS = 200;
// What a new session with a named subset asks (for "Laufende Lerneinheit beenden?").
const SUBSET_WHAT = {
  all: 'alle Begriffe',
  starred: 'nur die markierten Begriffe',
  learning: 'nur die nicht gemeisterten Begriffe',
  missed: 'nur die zuletzt falsch beantworteten Begriffe',
};

const bcp47 = (lang) => (LANGS[lang] && LANGS[lang].bcp47) || null;

function entryState() {
  const st = history.state;
  return st && typeof st === 'object' && !Array.isArray(st) ? st : {};
}

// The Learn session (its startedAt) the current history entry shows.
function entryMarker() {
  const mark = entryState().lnSession;
  return typeof mark === 'number' ? mark : null;
}

export function render(outlet, ctx) {
  const setId = ctx.params.id;
  const query = ctx.query || {};
  const setTitle = typeof ctx.setTitle === 'function' ? ctx.setTitle : () => {};

  const initialSet = db.getSet(setId);
  if (!initialSet) {
    setTitle('Lernset nicht gefunden');
    outlet.append(h('div', { class: 'wr wr--solo ln' }, h('div', { class: 'wr-main' }, missingSetView())));
    return () => {};
  }

  // Screen context shared with learn-answer.js and learn-dialogs.js.
  const c = {
    setId,
    set: initialSet,
    cards: new Map(),
    options: db.getStudyOptions(setId),
    state: null, // LearnState
    stage: null, // 'question' | 'checkpoint' | 'finish' | 'message'
    phase: null, // within 'question': 'question' | 'correct' | 'incorrect'
    current: null, // the question on screen: { q, info, choices? }
    last: null, // its answer: { kind: 'mc'|'written', info, … }
    // The open "Nicht ganz" screen, stored next to the state so a reload shows it
    // again (with "Ich hatte recht" and the copy step).
    pending: null,
    advanceTimer: 0,
    lastPraise: null,
    // ?review=1 (the exam's "Falsche lernen"): new sessions ask the mastered cards
    // again whatever the "Wiederholungsfragen" preference says. Kept in the URL, so
    // a reload keeps it; switching the preference replaces it.
    reviewForced: query.review === '1',
    // Correct answers in a row during this visit (never stored; answer-streak.js).
    streak: STREAK_START,
    // Letters typed / the option highlighted on a multiple choice question (core/typeahead.js).
    typing: TYPING_IDLE,
    // «Nochmal lernen» of the finish or "everything mastered" screen (Ctrl+Shift+R there).
    relearn: null,
    apple: isApplePlatform(),
    disposed: false,
  };
  let roundFrom = null; // counts when the round started; the checkpoint bar grows from there
  let hintEl = null;
  let hintTimer = 0;
  let announceTimer = 0;
  let lockUntil = 0;
  let writing = 0;

  // The answer and dialog flows are created below; the views call them lazily.
  let answers = null;
  let dialogs = null;

  // ------------------------------------------------------------- skeleton
  const live = h('div', { class: 'sr-only', 'aria-live': 'polite', 'aria-atomic': 'true' });
  const side = createLearnSidebar({
    setId,
    title: c.set.title,
    onOptions: () => dialogs.openOptions(),
    onRestart: () => dialogs.confirmRestart(),
  });
  const meta = h('p', { class: 'ln-meta', hidden: true });
  const hintHost = h('div', { class: 'ln-hint-host' });
  const stageHost = h('div', { class: 'wr-main__stage' });
  const main = h('div', { class: 'wr-main ln-main' }, meta, hintHost, stageHost);
  const root = h('div', { class: 'wr ln' }, side.el, main, live);
  outlet.append(root);
  // Enter on a focused «Zurück zum Lernset», «Fertig» or link: Enter waits on the next screen.
  const unsettle = settleOnLeave(root);

  c.card = createCard(
    {
      onSubmit: (value) => answers.submitAnswer(value),
      onDontKnow: () => answers.writtenDontKnow(),
      onContinue: () => answers.continueNext(true),
      onCopySubmit: (value) => answers.submitCopy(value),
      onOverride: () => answers.overrideLast(),
      onEdit: () => dialogs.openEdit(),
      onToggleStar: () => dialogs.toggleStar(),
      onSpeak: (text, lang) => speak(text, lang),
    },
    { dontKnow: 'Weiss ich nicht?', miss: MISS_TITLE },
  );
  c.card.el.classList.add('wr-stage', 'ln-written');

  c.mc = createMcCard({
    onChoose: (index) => answers.choose(index),
    onDontKnow: () => answers.mcDontKnow(),
    onContinue: () => answers.continueNext(true),
    onEdit: () => dialogs.openEdit(),
    onToggleStar: () => dialogs.toggleStar(),
    onSpeak: (text, lang) => speak(text, lang),
    // Any click on the card continues early after a correct answer.
    onSurfaceClick: () => {
      if (c.stage === 'question' && c.phase === 'correct') answers.continueNext(true);
    },
    // «Auswählen» (a click is never held back by the input lock).
    onPick: () => typeOnChoices({ kind: 'return' }),
  });
  c.mc.el.classList.add('wr-stage');

  // "↺ Wiederholung" next to the prompt's language on both cards.
  const reviewMarks = [attachReviewMark(c.card.el), attachReviewMark(c.mc.el)];
  const showReviewMark = (on) => {
    for (const mark of reviewMarks) mark.set(on);
  };

  // The answer streak's flame in the head of both cards (only one is on screen).
  const streakBadges = [attachStreakBadge(c.card.el), attachStreakBadge(c.mc.el)];
  // milestone: the feedback of the answer that reached it is on screen.
  c.showStreak = (milestone = false) => {
    for (const badge of streakBadges) badge.set(c.streak.current, { milestone });
  };
  c.countAnswer = (correct) => {
    c.streak = recordStreak(c.streak, correct);
    c.showStreak(c.streak.milestone);
    return c.streak;
  };
  c.countOverride = () => {
    c.streak = overrideStreak(c.streak);
    c.showStreak(c.streak.milestone);
    return c.streak;
  };

  // The sound of a real step (lib/sounds.js playStudyStep); replays never call it.
  c.sound = (step) => {
    if (!c.disposed) playStudyStep(step);
  };

  // ------------------------------------------------------ shared helpers
  c.indexCards = () => {
    c.cards = new Map(c.set.cards.map((card) => [card.id, card]));
  };
  c.usable = (cardId) => isUsableCard(c.cards.get(cardId));
  c.questionInfo = (q) => {
    const info = q ? buildQuestion(c.set, c.cards.get(q.cardId), q) : null;
    // A repetition question of a card mastered before the session.
    if (info) info.isReview = L.isReviewQuestion(q.qid);
    return info;
  };
  c.retypeOn = () => !!(c.options.learn && c.options.learn.retype);

  // Whether a new session asks repetition questions.
  c.reviewWanted = () => c.reviewForced || learnReviewEnabled();
  c.setReviewForced = (on) => {
    if (c.reviewForced === !!on) return;
    c.reviewForced = !!on;
    syncUrl();
  };

  // Runs a db write; our own writes are ignored by the subscription below.
  c.write = (fn) => {
    writing++;
    try {
      return fn();
    } catch (err) {
      if (err && err.code === 'QUOTA') toast(err.message, { tone: 'danger', duration: 7000 });
      else if (err && err.code === 'NOT_FOUND') queueMicrotask(reconcile);
      else {
        if (typeof console !== 'undefined') console.error(err);
        toast('Das konnte nicht gespeichert werden.', { tone: 'danger' });
      }
      return undefined;
    } finally {
      writing--;
    }
  };

  c.persist = () => {
    if (!c.state || c.disposed) return;
    const saved = c.pending ? { ...c.state, feedback: c.pending } : c.state;
    c.write(() => db.saveLearn(setId, saved));
  };

  // Learn and Write share one progress model: answers given elsewhere (Schreiben,
  // another tab) move a card's stage here too. Returns whether the state changed.
  c.syncProgress = () => {
    if (!c.state) return false;
    const progress = db.getProgress(setId);
    if (L.matchesProgress(c.state, progress)) return false;
    c.state = L.syncProgress(c.state, progress, Date.now());
    return true;
  };

  c.updateSide = () => {
    if (!c.state) return;
    const counts = L.counts(c.state);
    side.update({ counts, round: c.state.round, segments: segmentCount(counts.total, c.state.learn.roundSize) });
    meta.hidden = c.stage !== 'question';
    if (!meta.hidden) meta.textContent = `Runde ${c.state.round}`;
  };

  // parts: strings or { text, lang } (read with the voice of that language).
  c.announce = (...parts) => {
    clearTimeout(announceTimer);
    live.textContent = '';
    announceTimer = setTimeout(() => {
      if (c.disposed) return;
      live.replaceChildren(...parts.map((p) => (typeof p === 'string' ? p : h('span', { lang: bcp47(p.lang) }, p.text))));
    }, 60);
  };

  c.lock = () => {
    lockUntil = performance.now() + ENTER_LOCK_MS;
  };

  c.locked = () => performance.now() < lockUntil;

  // Enter (or a click on "Weiter") inside the lock after a correct answer is not lost: it
  // moves on the moment the lock ends, so the praise can always be skipped. A press within
  // SKIP_MIN_GAP_MS of the answer is the answering press itself; a miss stays readable for
  // the whole lock.
  c.skipPraiseWhenUnlocked = () => {
    if (c.stage !== 'question' || c.phase !== 'correct' || !c.locked()) return;
    const now = performance.now();
    if (now - (lockUntil - ENTER_LOCK_MS) < SKIP_MIN_GAP_MS) return;
    clearTimeout(c.advanceTimer);
    c.advanceTimer = setTimeout(() => answers.continueNext(false), Math.max(1, Math.ceil(lockUntil - now)));
  };

  c.clearAdvance = () => {
    clearTimeout(c.advanceTimer);
    c.advanceTimer = 0;
    c.card.stopTimer();
    c.mc.stopTimer();
  };

  function focusPrimary(view) {
    const target = view.querySelector('[data-primary="true"]') || view.querySelector('.ui-btn');
    if (target) target.focus({ preventScroll: true });
  }

  c.focusStage = () => {
    if (stageHost.firstChild) focusPrimary(stageHost.firstChild);
  };

  c.focusCurrent = () => {
    if (c.stage !== 'question' || !c.current) return;
    if (c.current.q.type === 'mc') c.mc.focusPrimary();
    else c.card.focusPrimary();
  };

  // A new step (question, checkpoint, finish, message) starts in view, never under
  // the sticky bars; reveal: false keeps the scroll position (a step redrawn after
  // a change elsewhere).
  function mount(el, { reveal = true } = {}) {
    if (stageHost.firstChild !== el) stageHost.replaceChildren(el);
    root.classList.toggle('wr--solo', c.stage === 'message');
    if (c.stage !== 'question') meta.hidden = true;
    updateHint();
    if (reveal) revealBelowBars(stageHost, { bar: side.el, beside: main });
  }

  // Keeps the URL resumable (drops `new=1` and `cards=`, keeps a named subset and
  // review=1) and tags the history entry with the session it shows. Chosen cards
  // live in the stored session itself (state.subset), so a reload resumes it.
  function syncUrl() {
    const params = [];
    if (c.state && typeof c.state.subset === 'string' && c.state.subset !== 'all') params.push(`subset=${c.state.subset}`);
    if (c.reviewForced) params.push('review=1');
    const target = `#/set/${setId}/learn${params.length ? `?${params.join('&')}` : ''}`;
    const mark = c.state ? c.state.startedAt : null;
    if (location.hash === target && entryMarker() === mark) return;
    try {
      history.replaceState({ ...entryState(), lnSession: mark }, '', target);
    } catch {
      /* rate-limited (Safari): keep the current URL */
    }
  }

  function untagEntry() {
    if (entryMarker() == null) return;
    try {
      history.replaceState({ ...entryState(), lnSession: null }, '');
    } catch {
      /* rate-limited (Safari): a reload may show the last results again */
    }
  }

  const backToSet = () => ctx.navigate(`/set/${setId}`);
  const practiseWriting = () => ctx.navigate(`/set/${setId}/write?new=1`);

  // ----------------------------------------------------------- intro hint
  // "Multiple Choice first, written next time": until dismissed or the first checkpoint.
  function updateHint() {
    // A session of repetition questions without new cards has nothing to introduce.
    const reviewOnly = !!c.state && !!c.state.review && L.counts(c.state).fresh === 0;
    const want = c.stage === 'question' && !!c.state && c.state.learn.mc && c.state.learn.written && !reviewOnly && !introHintDismissed();
    if (want && !hintEl) {
      hintEl = introHint({ onDismiss: closeHint });
      hintHost.replaceChildren(hintEl);
    } else if (!want && hintEl) {
      hintEl.remove();
      hintEl = null;
    }
  }

  function closeHint() {
    dismissIntroHint();
    if (!hintEl) return;
    const el = hintEl;
    hintEl = null;
    el.classList.add('is-leaving');
    clearTimeout(hintTimer);
    hintTimer = setTimeout(() => el.remove(), HINT_LEAVE_MS);
    c.focusCurrent();
  }

  // ----------------------------------------------------------- sessions
  // review: ask the mastered cards again ("Alle wiederholen" forces it once).
  c.startFresh = (subset, { review = c.reviewWanted() } = {}) => {
    c.clearAdvance();
    c.last = null;
    c.pending = null;
    c.current = null;
    const fresh = L.createLearn(c.set.cards, c.options, { subset, progress: db.getProgress(setId), review });
    if (!fresh.order.length || L.isFinished(fresh)) {
      // Nothing to study: this history entry no longer shows a (finished) session.
      c.state = null;
      untagEntry();
      if (fresh.order.length) showAllMastered(fresh);
      else showEmpty(fresh.subset);
      return;
    }
    c.state = fresh;
    roundFrom = L.counts(c.state);
    c.persist();
    syncUrl();
    c.showQuestion({ animate: false });
  };

  // Drops a card that was deleted (or emptied); its options in other questions
  // are replaced by other cards of the set.
  c.removeCard = (id) => {
    c.state = L.removeCard(c.state, id, Date.now(), { cards: c.set.cards });
  };

  // Drops cards that were deleted (or emptied) since the session started.
  function pruneState() {
    let changed = false;
    for (const id of c.state.order.slice()) {
      if (!c.usable(id)) {
        c.removeCard(id);
        changed = true;
      }
    }
    return changed;
  }

  // A stored session with the answers given elsewhere since (its open feedback kept).
  function storedSession() {
    const saved = db.getLearn(setId);
    if (!saved || typeof saved !== 'object') return { saved, synced: false };
    const progress = db.getProgress(setId);
    if (L.matchesProgress(saved, progress)) return { saved, synced: false };
    const { feedback, ...rest } = saved;
    const state = L.syncProgress(rest, progress, Date.now());
    return { saved: feedback === undefined ? state : { ...state, feedback }, synced: true };
  }

  // The scope a link asks for: chosen cards (cards=, read from the raw hash: ids are
  // encoded one by one) or a named subset; null = whatever is stored.
  function wantedSubset() {
    if (query.cards != null) {
      const ids = cardIdsFromHash(typeof location !== 'undefined' ? location.hash : '');
      return { cardIds: ids || String(query.cards).split(',').filter(Boolean) };
    }
    return parseSubset(query.subset);
  }

  function boot() {
    const { saved, synced } = storedSession();
    const wanted = wantedSubset();
    const forceNew = query.new === '1';
    const showFinishAgain =
      canShowResults(saved, { forceNew, marker: entryMarker() }) && (wanted == null || sameSubset(saved.subset, wanted));
    if (!showFinishAgain && !canResumeLearn(saved, { forceNew, subset: wanted })) {
      // A typed or bookmarked subset link must not end a session with answers without asking.
      if (wanted != null && !forceNew && canResumeLearn(saved) && hasLearnAnswers(saved)) {
        confirmReplace(saved, wanted, synced);
        return;
      }
      c.startFresh(wanted || 'all');
      return;
    }
    resumeSaved(saved, { showFinishAgain, wanted, synced });
  }

  async function confirmReplace(saved, wanted, synced) {
    const ok = await ask({
      title: 'Laufende Lerneinheit beenden?',
      message: `Deine gespeicherte Lerneinheit endet, wenn du jetzt ${SUBSET_WHAT[wanted] || 'eine neue Auswahl'} lernst. Dein Lernfortschritt bleibt erhalten.`,
      confirmLabel: 'Neu beginnen',
      cancelLabel: 'Fortsetzen',
    });
    if (c.disposed) return;
    if (ok) c.startFresh(wanted);
    else resumeSaved(saved, { showFinishAgain: false, wanted: null, synced }); // syncUrl shows the session's own subset
  }

  // synced: the stored state was brought in line with the progress (to be saved).
  function resumeSaved(saved, { showFinishAgain, wanted, synced = false }) {
    const { feedback, ...rest } = saved;
    // Time away from the page is not study time (a finished session's clock is stopped).
    c.state = showFinishAgain ? rest : { ...rest, updatedAt: Date.now() };
    const pruned = pruneState();
    // Answers given while a dialog was open count too.
    const changed = c.syncProgress() || synced || pruned;
    c.pending = showFinishAgain ? null : pendingLearnFeedback(c.state, feedback);
    roundFrom = null;
    if (changed) c.persist();
    if (!c.state.order.length) {
      c.startFresh(wanted || 'all');
      return;
    }
    syncUrl();
    if (showFinishAgain) {
      finish();
      return;
    }
    if (hasLearnAnswers(c.state)) toast("Willkommen zurück – weiter geht's", { icon: 'sparkles' });
    if (c.pending) reopenFeedback();
    else c.advance();
  }

  // The "Nicht ganz" screen that was open when the page was left; the answer
  // itself is already recorded.
  function reopenFeedback() {
    const p = c.pending;
    const q = { qid: p.qid, cardId: p.cardId, type: p.type, ask: p.ask };
    if (p.type === 'mc') q.choices = p.choices;
    const info = c.questionInfo(q);
    if (!info) {
      c.pending = null;
      c.persist();
      c.advance();
      return;
    }
    c.stage = 'question';
    c.current = { q, info };
    showReviewMark(info.isReview);
    if (p.type === 'mc') {
      c.current.choices = choiceTexts(p.choices, c.cards, p.ask);
      mount(c.mc.el);
      c.mc.setQuestion(info, c.current.choices, { animate: false });
      side.setChoiceCount(c.current.choices.length);
      c.last = {
        kind: 'mc',
        info,
        correctIndex: c.current.choices.findIndex((choice) => choice.cardId === p.cardId),
        chosenIndex: p.chosen == null ? null : c.current.choices.findIndex((choice) => choice.cardId === p.chosen),
      };
      c.updateSide();
      answers.showMcResult();
    } else {
      mount(c.card.el);
      c.card.setQuestion(info, { animate: false });
      const result = p.dontKnow ? null : gradeQuestion(c.set, info, p.given, c.options.tolerance).result;
      c.last = { kind: 'written', info, given: p.given, result, dontKnow: p.dontKnow, copy: false, editedCorrect: false, synonym: false };
      c.updateSide();
      answers.showWrittenIncorrect();
    }
  }

  // Next step after a question, a round or a resume. afterAnswer: the step follows an
  // answer (or «Weiter zu Runde N»), so a checkpoint or the finish sounds; a resume is silent.
  c.advance = ({ afterAnswer = false } = {}) => {
    if (!c.state || !c.state.order.length) sessionEmptied();
    else if (L.isFinished(c.state)) finish({ afterAnswer });
    else if (L.isRoundOver(c.state)) showCheckpoint({ afterAnswer });
    else c.showQuestion();
  };

  // ------------------------------------------------------------ questions
  // reveal: false keeps the scroll position (a question redrawn after a change elsewhere).
  c.showQuestion = ({ animate = true, reveal = true } = {}) => {
    c.clearAdvance();
    let q = L.current(c.state);
    let pruned = false;
    while (q && !c.usable(q.cardId)) {
      c.removeCard(q.cardId);
      pruned = true;
      q = L.current(c.state);
    }
    if (pruned) c.persist();
    if (!q) {
      c.advance();
      return;
    }
    const previous = c.stage === 'question' && c.current ? c.current.q.type : null;
    c.stage = 'question';
    c.phase = 'question';
    c.last = null;
    c.relearn = null;
    // Every question starts with nothing typed; the flame calms down after a milestone.
    c.typing = TYPING_IDLE;
    c.showStreak(false);
    const info = c.questionInfo(q);
    c.current = { q, info };
    const prompt = { text: info.prompt, lang: info.promptLang };
    // "Wiederholungsfrage." leads the prompt; when the focus moves (and the focused
    // field reads the prompt) it follows on its own.
    const lead = info.isReview ? `${REVIEW_ARIA_LABEL}. ` : '';
    showReviewMark(info.isReview);
    if (q.type === 'mc') {
      c.current.choices = choiceTexts(q.choices, c.cards, q.ask);
      // A focused option group does not announce the next prompt by itself.
      const keepsFocus = document.activeElement === c.mc.grid;
      mount(c.mc.el, { reveal });
      c.mc.setQuestion(info, c.current.choices, { animate: animate && previous === 'mc' });
      side.setChoiceCount(c.current.choices.length);
      if (keepsFocus) c.announce(`${lead}${info.promptLabel}: `, prompt, `. Wähle die richtige Antwort, 1 bis ${c.current.choices.length}.`);
      else if (lead) c.announce(lead.trim());
    } else {
      const keepsFocus = document.activeElement === c.card.input;
      mount(c.card.el, { reveal });
      c.card.setQuestion(info, { animate: animate && previous === 'written' });
      if (keepsFocus) c.announce(`${lead}${info.promptLabel}: `, prompt, c.state.answerWith === 'both' ? `. ${info.placeholder}.` : '');
      else if (lead) c.announce(lead.trim());
    }
    c.updateSide();
    c.lock();
    if (c.options.audio && info.ask === 'definition') speak(info.prompt, info.promptLang);
  };

  // ------------------------------------------------- checkpoint & finish
  // refresh: redraw after a change elsewhere (keeps the scroll position, no announcement);
  // afterAnswer: reached by answering (the round-done fanfare plays).
  function showCheckpoint({ refresh = false, afterAnswer = false } = {}) {
    c.clearAdvance();
    const cp = L.checkpoint(c.state);
    if (cp.answered === 0) {
      // Nothing was answered this round (its cards were removed): refill without a checkpoint.
      c.state = L.nextRound(c.state, c.set.cards, Math.random, Date.now());
      roundFrom = L.counts(c.state);
      c.persist();
      if (L.isFinished(c.state)) finish({ afterAnswer });
      else if (L.isRoundOver(c.state)) sessionEmptied();
      else c.showQuestion({ animate: false });
      return;
    }
    c.stage = 'checkpoint';
    c.phase = null;
    c.current = null;
    c.last = null;
    c.relearn = null;
    if (afterAnswer && !refresh) c.sound({ roundDone: true });
    dismissIntroHint(); // the first round showed how Learn works
    const view = checkpointView({
      cp,
      rows: termRows(c.set, c.cards, cp.items),
      from: refresh ? null : roundFrom,
      segments: segmentCount(cp.counts.total, c.state.learn.roundSize),
      onNext: () => goNextRound(true),
      onBack: backToSet,
    });
    mount(view, { reveal: !refresh });
    c.updateSide();
    if (!refresh) {
      c.announce(`Runde ${cp.round} geschafft. ${masteredLine(cp.counts.mastered, cp.counts.total)}.`);
      c.lock();
    }
    focusPrimary(view);
  }

  function goNextRound(fromUser) {
    if (c.stage !== 'checkpoint' || (fromUser && c.locked())) return;
    c.state = L.nextRound(c.state, c.set.cards, Math.random, Date.now());
    roundFrom = L.counts(c.state);
    c.persist();
    c.advance({ afterAnswer: true });
  }

  // afterAnswer: the session was just completed (the finish fanfare plays); showing the
  // finish screen again after a reload is silent.
  function finish({ afterAnswer = false } = {}) {
    c.clearAdvance();
    // Closes the last round into the history and stamps finishedAt.
    c.state = L.nextRound(c.state, c.set.cards, Math.random, Date.now());
    c.pending = null;
    c.persist();
    syncUrl();
    showFinish({ afterAnswer });
  }

  function showFinish({ afterAnswer = false } = {}) {
    c.stage = 'finish';
    c.phase = null;
    c.current = null;
    c.last = null;
    const stats = L.finalStats(c.state);
    if (!stats.total) {
      sessionEmptied();
      return;
    }
    const subset = c.state.subset;
    const ids = c.state.order.slice();
    c.relearn = () => dialogs.confirmRelearn(subset, ids);
    if (afterAnswer) c.sound({ finished: true });
    const view = finishView({
      stats,
      subset,
      hardestRows: termRows(c.set, c.cards, stats.hardest),
      review: L.reviewStats(c.state),
      bestStreak: c.streak.best,
      onRestart: () => dialogs.confirmRelearn(subset, ids),
      onWrite: practiseWriting,
      onBack: backToSet,
    });
    mount(view);
    c.updateSide();
    c.announce(`Geschafft! ${finishTitle(subset, stats.total)}`);
    c.lock();
    focusPrimary(view);
  }

  // ----------------------------------------------------------- messages
  function showMessage(view) {
    c.clearAdvance();
    c.stage = 'message';
    c.phase = null;
    c.current = null;
    c.last = null;
    c.pending = null;
    c.relearn = null;
    mount(view);
    // An Enter meant for the screen before must not press this one's button.
    c.lock();
    focusPrimary(view);
  }

  function showEmpty(subset) {
    showMessage(emptySubsetView({ subset, setId, onAll: () => c.startFresh('all'), onBack: backToSet }));
  }

  // Everything in scope is already mastered at the start (and the repetition
  // questions are off): repeat them all, reset the progress or practise writing.
  function showAllMastered(fresh) {
    const subset = fresh.subset;
    const ids = fresh.order.slice();
    showMessage(
      allMasteredView({
        subset,
        count: ids.length,
        onReset: () => dialogs.confirmRelearn(subset, ids),
        // Once, for this session: the preference stays as it is.
        onReview: () => c.startFresh(subset, { review: true }),
        onWrite: practiseWriting,
        onBack: backToSet,
      }),
    );
    c.relearn = () => dialogs.confirmRelearn(subset, ids);
  }

  // Every card of the session vanished (deleted elsewhere).
  function sessionEmptied() {
    const subset = c.state && typeof c.state.subset === 'string' ? c.state.subset : 'all';
    if (c.set.cards.some(isUsableCard)) {
      c.startFresh(subset);
    } else {
      c.state = null;
      showEmpty('all');
    }
  }

  c.showGone = () => {
    c.state = null;
    showMessage(missingSetView());
  };

  // ------------------------------------------------------- live updates
  function reconcile() {
    if (c.disposed) return;
    const fresh = db.getSet(setId);
    if (!fresh) {
      c.showGone();
      return;
    }
    c.set = fresh;
    c.indexCards();
    c.options = db.getStudyOptions(setId);
    side.setTitle(c.set.title);
    setTitle(`${c.set.title} – Lernen`);
    if (!c.state) return;
    const pruned = pruneState();
    // Answers given in another tab (e.g. in Schreiben) move the stages here too.
    const synced = c.syncProgress();
    if (pruned || synced) c.persist();
    c.updateSide();
    if (c.stage === 'question' && c.current) {
      const head = L.current(c.state);
      const same =
        !!head &&
        head.qid === c.current.q.qid &&
        head.type === c.current.q.type &&
        JSON.stringify(head.choices || null) === JSON.stringify(c.current.q.choices || null);
      if (c.phase === 'question' && !same) c.showQuestion({ animate: false, reveal: false });
      else if (c.cards.has(c.current.q.cardId)) dialogs.refreshCurrent();
    } else if ((pruned || synced) && c.stage === 'checkpoint') {
      if (c.state.order.length && !L.isFinished(c.state) && L.checkpoint(c.state).answered > 0) showCheckpoint({ refresh: true });
      else c.advance();
    } else if (pruned && c.stage === 'finish') {
      showFinish();
    }
  }

  const unsubscribe = db.subscribe((evt) => {
    if (writing || c.disposed) return;
    const keys = evt && Array.isArray(evt.keys) ? evt.keys : null;
    if (!keys || keys.some((k) => k === 'sets' || k === 'settings' || k === `progress:${setId}`)) reconcile();
  });

  // ------------------------------------------------------------ keyboard
  const choosing = () => c.stage === 'question' && c.phase === 'question' && !!c.current && c.current.q.type === 'mc';

  // The letters typed / the highlight of the multiple choice question on the tiles.
  c.drawTyping = ({ reject = false } = {}) => {
    if (!choosing()) return;
    c.mc.setTyping(c.typing, { lang: c.current.info.answerLang, apple: c.apple, reject });
  };

  // One key on a multiple choice question (core/typeahead.js): letters type, ⌫ deletes,
  // the arrows highlight, Enter chooses the highlighted option, 1–4 choose, 0 = «Weiss
  // ich nicht», Esc clears the letters before it leaves.
  function typeOnChoices(key, repeat = false) {
    if (!choosing()) return;
    const out = typingKey(c.typing, key, {
      choices: c.current.choices,
      lang: c.current.info.answerLang,
      columns: c.mc.columns(),
      repeat,
    });
    const rejected = out.state.rejections !== c.typing.rejections;
    c.typing = out.state;
    if (out.announce) c.announce(out.announce);
    const action = out.action;
    if (action && action.type === 'choose') answers.choose(action.index);
    else if (action && action.type === 'dontKnow') answers.mcDontKnow();
    else if (action && action.type === 'leave') leave();
    else c.drawTyping({ reject: rejected });
  }

  function primaryAction() {
    if (c.stage === 'question' && c.current) {
      if (c.current.q.type === 'mc') {
        if (c.phase === 'question') typeOnChoices({ kind: 'return' });
        else answers.continueNext(true);
      } else if (c.phase === 'question') answers.submitAnswer(c.card.value);
      else if (c.phase === 'correct') answers.continueNext(true);
      else if (c.last && c.last.copy) answers.submitCopy(c.card.value);
      else answers.continueNext(true);
    } else if (c.stage === 'checkpoint') {
      goNextRound(true);
    } else {
      const primary = stageHost.querySelector('[data-primary="true"]');
      if (!primary) return;
      // A link (e.g. «Begriffe hinzufügen») leads to another screen: hold Enter back there.
      if (primary.tagName === 'A' || primary.dataset.leaves === 'true') settleEnter();
      primary.click();
    }
  }

  // Multiple choice: letters, ⌫ and the arrows go to the typing (typeOnChoices); after its
  // feedback any key continues (without typing or picking anything in the next question).
  // After a correct written answer any key continues and, typed in the answer field,
  // starts the next written answer.
  function onKey(e, { own, kind, word, direction }) {
    if (c.stage !== 'question' || !c.current) return;
    if (c.current.q.type === 'mc') {
      if (c.phase === 'question') {
        if (kind === 'delete') {
          e.preventDefault();
          typeOnChoices({ kind: 'delete', word }, e.repeat);
        } else if (kind === 'arrow') {
          e.preventDefault();
          typeOnChoices({ kind: 'arrow', direction }, e.repeat);
        } else if (/^[0-9]$/.test(e.key) && !e.altKey && !e.ctrlKey) {
          // Digits choose: a transition, never while held or right after the question appeared.
          e.preventDefault();
          if (!e.repeat && !c.locked()) typeOnChoices({ kind: 'digit', n: Number(e.key) });
        } else if (e.key === ' ' && !c.typing.typed) {
          // Nothing typed yet: Space presses a focused option (the browser's own click);
          // elsewhere it must not scroll the page.
          if (!(e.target && e.target.closest && e.target.closest('button'))) e.preventDefault();
        } else {
          e.preventDefault();
          typeOnChoices({ kind: 'char', text: e.key }, e.repeat);
        }
        return;
      }
      if (kind !== 'char') return;
      e.preventDefault();
      if (e.repeat) return;
      if (c.locked()) c.skipPraiseWhenUnlocked();
      else answers.continueNext(false);
      return;
    }
    if (kind !== 'char' || c.phase !== 'correct') return;
    // A held key never moves on (it may still be repeating from the answer typed before).
    if (e.repeat) {
      e.preventDefault();
      return;
    }
    answers.continueNext(false);
    const typesOn = own && c.stage === 'question' && c.phase === 'question' && c.current.q.type === 'written';
    if (!typesOn || e.key === ' ') e.preventDefault();
  }

  function leave() {
    backToSet();
  }

  // The study shortcuts (write-keys.js studyCommand). Transitions wait for the input lock.
  function onCommand(command) {
    const step = c.stage === 'question' && !!c.current;
    switch (command) {
      case 'exit':
        // Letters typed on a multiple choice question go first.
        if (choosing() && c.typing.typed) typeOnChoices({ kind: 'escape' });
        else if (!c.locked()) leave();
        return;
      case 'dontKnow':
        if (c.locked() || !step || c.phase !== 'question') return;
        if (c.current.q.type === 'mc') answers.mcDontKnow();
        else answers.writtenDontKnow();
        return;
      case 'override':
        if (!c.locked()) answers.overrideLast();
        return;
      case 'options':
        dialogs.openOptions();
        return;
      case 'speak':
        if (step) (c.current.q.type === 'mc' ? c.mc : c.card).pressSpeak();
        return;
      case 'star':
        if (step) c.announce((c.current.q.type === 'mc' ? c.mc : c.card).pressStar() ? 'Markiert' : 'Markierung entfernt');
        return;
      case 'edit':
        dialogs.openEdit();
        return;
      case 'restart':
        if (c.locked()) return;
        if (c.relearn) c.relearn();
        else dialogs.confirmRestart();
        return;
      default:
    }
  }

  const unbindKeys = bindLearnKeys({
    ownInput: () => c.card.input,
    isLocked: c.locked,
    onEnter: primaryAction,
    onLockedEnter: () => c.skipPraiseWhenUnlocked(),
    // A highlighted option (or typed letters) is chosen by Enter even while a tile or
    // «Auswählen» has the focus; any other focused control («Weiss ich nicht?», the star,
    // the sidebar) still does what it says.
    ownsEnter: (control) =>
      choosing() &&
      (c.typing.highlighted != null || !!c.typing.typed) &&
      !!control &&
      typeof control.closest === 'function' &&
      !!control.closest('.ln-tiles, .ln-pick'),
    onKey,
    onCommand,
  });

  // ----------------------------------------------------- time tracking
  const clock = createStudyClock({
    isStudying: () => !!c.state && c.state.finishedAt == null && (c.stage === 'question' || c.stage === 'checkpoint'),
    tick: () => {
      c.state = L.tick(c.state);
      c.persist();
    },
    // Time away (hidden tab, idle) is not study time.
    resume: () => {
      if (c.state && c.state.finishedAt == null) c.state = { ...c.state, updatedAt: Date.now() };
    },
    onHidden: stopSpeaking,
  });

  answers = createAnswering(c);
  dialogs = createLearnDialogs(c, answers);
  c.indexCards();
  setTitle(`${c.set.title} – Lernen`);
  boot();

  return () => {
    clock.tickNow();
    c.disposed = true;
    c.clearAdvance();
    clearTimeout(announceTimer);
    clearTimeout(hintTimer);
    clock.dispose();
    unbindKeys();
    unsettle();
    unsubscribe();
    c.card.dispose();
    stopSpeaking();
  };
}
