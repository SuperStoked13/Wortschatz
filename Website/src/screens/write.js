// Write mode (#/set/:id/write): Quizlet-style "Schreiben".
//
// Stages: 'card' (phases question → correct | incorrect [+ copy step]) → round
// summary → … → results. Every state change is persisted with db.saveSession,
// so leaving and coming back resumes exactly where the learner stopped (an open
// "Nicht ganz" screen included); reloading a finished session's page, or coming
// back to it with Back, shows its results again.
//
// Keys (Mac parity): Enter answers / continues («Fertig» on results without misses),
// Alt+Enter «Weiss ich nicht», Ctrl+Enter «Ich hatte recht», Esc back to the set,
// Ctrl+K/R/D/E options, read aloud, star, edit, Ctrl+Shift+R «Neu starten». Correct
// answers in a row show a flame (answer-streak.js); answers, rounds and the results
// sound (lib/sounds.js) — only when they happen, never when a screen is shown again.

import { h } from '../lib/dom.js';
import { LANGS, NOTE_LABELS, HINT_LABELS } from '../lib/labels.js';
import { speak, stopSpeaking } from '../lib/speech.js';
import { playStudyStep } from '../lib/sounds.js';
import { db } from '../store/db.js';
import { setProgress } from '../core/mastery.js';
import * as S from '../core/session.js';
import { toast } from '../ui/components.js';
import { createCard } from './write-card.js';
import { createStudyClock } from './write-clock.js';
import { ask, openCardEditor, openOptionsDialog } from './write-dialogs.js';
import { bindWriteKeys, settleEnter, settleOnLeave } from './write-keys.js';
import { STREAK_START, recordStreak, overrideStreak, streakTitle } from './answer-streak.js';
import {
  hasText,
  parseSubset,
  isUsableCard,
  questionInfo as buildQuestion,
  gradeQuestion,
  copyAccepted,
  pendingFeedback,
  canResume,
  canShowResults,
  hasAnswers,
  termRows,
} from './write-model.js';
import { createSidebar, roundSummaryView, resultsView, emptySubsetView, missingSetView, attachStreakBadge } from './write-views.js';

const ADVANCE_MS = 900;
const ADVANCE_MS_WITH_NOTES = 1800; // time to read "Genau: …" after a tolerated answer
const ENTER_LOCK_MS = 280;
// Enter within this long of the answering press is that press itself, not a skip.
const SKIP_MIN_GAP_MS = 50;
const PRAISE = ['Richtig!', 'Super!', 'Genau!', 'Stark!'];
// What a new round with a named subset asks (for "Laufende Runde beenden?").
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

// The session (its startedAt) the current history entry shows; see canShowResults.
function entryMarker() {
  const mark = entryState().wrSession;
  return typeof mark === 'number' ? mark : null;
}

export function render(outlet, ctx) {
  const setId = ctx.params.id;
  const query = ctx.query || {};
  const setTitle = typeof ctx.setTitle === 'function' ? ctx.setTitle : () => {};

  let set = db.getSet(setId);
  if (!set) {
    setTitle('Lernset nicht gefunden');
    outlet.append(h('div', { class: 'wr wr--solo' }, h('div', { class: 'wr-main' }, missingSetView())));
    return () => {};
  }

  let cards = new Map();
  let options = db.getStudyOptions(setId);
  let session = null;
  let stage = null; // 'card' | 'summary' | 'results' | 'message'
  let phase = null; // within 'card': 'question' | 'correct' | 'incorrect'
  let last = null; // { info, given, result, dontKnow, copy, editedCorrect, synonym }
  // The open "Nicht ganz" screen ({ qid, given, dontKnow }). It is stored next to the
  // session, so a reload shows it again with its copy step and "Ich hatte recht".
  let pending = null;
  let advanceTimer = 0;
  let announceTimer = 0;
  let lockUntil = 0;
  let writing = 0;
  let lastPraise = '';
  // Correct answers in a row during this visit (never stored; answer-streak.js).
  let streak = STREAK_START;
  let disposed = false;

  indexCards();
  setTitle(`${set.title} – Schreiben`);

  // ------------------------------------------------------------- skeleton
  const live = h('div', { class: 'sr-only', 'aria-live': 'polite', 'aria-atomic': 'true' });
  const side = createSidebar({ setId, title: set.title, onOptions: openOptions, onRestart: confirmRestart });
  const roundNote = h('p', { class: 'wr-main__round', hidden: true });
  const stageHost = h('div', { class: 'wr-main__stage' });
  const main = h('div', { class: 'wr-main' }, roundNote, stageHost);
  const root = h('div', { class: 'wr' }, side.el, main, live);
  outlet.append(root);
  // Enter on a focused «Zurück zum Lernset», «Fertig» or link: Enter waits on the next screen.
  const unsettle = settleOnLeave(root);

  const card = createCard({
    onSubmit: submitAnswer,
    onDontKnow: dontKnow,
    onContinue: () => continueNext(true),
    onCopySubmit: submitCopy,
    onOverride: overrideLast,
    onEdit: openEdit,
    onToggleStar: toggleStar,
    onSpeak: (text, lang) => speak(text, lang),
  });
  card.el.classList.add('wr-stage');
  // The answer streak's flame in the card's head (it is built once, never rebuilt).
  const streakBadge = attachStreakBadge(card.el);
  // milestone: the feedback of the answer that reached it is on screen.
  const showStreak = (milestone = false) => streakBadge.set(streak.current, { milestone });
  // The sound of a real step (never on a replay).
  const sound = (step) => {
    if (!disposed) playStudyStep(step);
  };

  // ------------------------------------------------------- data helpers
  function indexCards() {
    cards = new Map(set.cards.map((c) => [c.id, c]));
  }

  const usable = (cardId) => isUsableCard(cards.get(cardId));
  const questionInfo = (q) => (q ? buildQuestion(set, cards.get(q.cardId), q) : null);
  const infoFor = (info) => questionInfo({ qid: info.qid, cardId: info.cardId, ask: info.ask });

  function activeInfo() {
    if (stage !== 'card' || !session) return null;
    if (phase === 'question') return questionInfo(S.current(session));
    return last ? infoFor(last.info) : null;
  }

  // Runs a db write; our own writes are ignored by the subscription below.
  function write(fn) {
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
  }

  function persist() {
    if (!session || disposed) return;
    const state = pending ? { ...session, feedback: pending } : session;
    write(() => db.saveSession(setId, state));
  }

  function setStats() {
    return setProgress(set, db.getProgress(setId));
  }

  function updateSide() {
    const c = session ? S.counters(session) : null;
    side.update({ counters: c, setStats: setStats() });
    const showRound = !!c && c.round > 1 && stage === 'card';
    roundNote.hidden = !showRound;
    if (showRound) roundNote.textContent = `Runde ${c.round} · nur die Begriffe, die noch nicht sassen`;
  }

  // parts: strings or { text, lang } (a set language, so screen readers read a
  // French prompt with a French voice).
  function announce(...parts) {
    clearTimeout(announceTimer);
    live.textContent = '';
    announceTimer = setTimeout(() => {
      if (disposed) return;
      live.replaceChildren(...parts.map((p) => (typeof p === 'string' ? p : h('span', { lang: bcp47(p.lang) }, p.text))));
    }, 60);
  }

  function lock() {
    lockUntil = performance.now() + ENTER_LOCK_MS;
  }

  const locked = () => performance.now() < lockUntil;

  // Enter (or a click on "Weiter") inside the lock after a correct answer is not lost: it
  // moves on the moment the lock ends. A press within SKIP_MIN_GAP_MS of the answer is the
  // answering press itself; a miss stays readable for the whole lock.
  function skipPraiseWhenUnlocked() {
    if (stage !== 'card' || phase !== 'correct' || !locked()) return;
    const now = performance.now();
    if (now - (lockUntil - ENTER_LOCK_MS) < SKIP_MIN_GAP_MS) return;
    clearTimeout(advanceTimer);
    advanceTimer = setTimeout(() => continueNext(false), Math.max(1, Math.ceil(lockUntil - now)));
  }

  function clearAdvance() {
    clearTimeout(advanceTimer);
    advanceTimer = 0;
    card.stopTimer();
  }

  // Keeps the URL resumable (drops `new=1`, keeps a named subset) and tags the
  // history entry with the session it shows.
  function syncUrl() {
    const sub = session && typeof session.subset === 'string' && session.subset !== 'all' ? `?subset=${session.subset}` : '';
    const target = `#/set/${setId}/write${sub}`;
    const mark = session ? session.startedAt : null;
    if (location.hash === target && entryMarker() === mark) return;
    try {
      history.replaceState({ ...entryState(), wrSession: mark }, '', target);
    } catch {
      /* rate-limited (Safari): keep the current URL */
    }
  }

  function mount(el) {
    if (stageHost.firstChild !== el) stageHost.replaceChildren(el);
    root.classList.toggle('wr--solo', stage === 'message');
    if (stage !== 'card') roundNote.hidden = true;
  }

  // ----------------------------------------------------------- sessions
  function startFresh(subset) {
    clearAdvance();
    last = null;
    pending = null;
    const fresh = S.createSession(set.cards, options, { subset, progress: db.getProgress(setId) });
    if (!fresh.order.length) {
      showEmpty(subset);
      return;
    }
    session = fresh;
    persist();
    syncUrl();
    showNextQuestion({ animate: false });
  }

  function cardIdsInSession() {
    return [...new Set(Object.values(session.questions || {}).map((q) => q.cardId))];
  }

  // Drops questions whose card was deleted (or emptied) since the session started.
  function pruneSession() {
    let changed = false;
    for (const id of cardIdsInSession()) {
      if (!usable(id)) {
        session = S.removeCard(session, id);
        changed = true;
      }
    }
    return changed;
  }

  function boot() {
    const saved = db.getSession(setId);
    const wanted = parseSubset(query.subset);
    const forceNew = query.new === '1';
    const showResultsAgain = canShowResults(saved, { forceNew, subset: wanted, marker: entryMarker() });
    if (!showResultsAgain && !canResume(saved, { forceNew, subset: wanted })) {
      // A typed or bookmarked subset link (…/write?subset=starred) must not drop a round
      // the learner already answered in without asking. The set page asks itself and
      // clears the round before it navigates, so this never asks twice.
      if (wanted != null && canResume(saved) && hasAnswers(saved)) {
        confirmReplace(saved, wanted);
        return;
      }
      startFresh(wanted || 'all');
      return;
    }
    resumeSaved(saved, { showResultsAgain, wanted });
  }

  async function confirmReplace(saved, wanted) {
    const ok = await ask({
      title: 'Laufende Runde beenden?',
      message: `Deine gespeicherte Runde endet, wenn du jetzt ${SUBSET_WHAT[wanted] || 'eine neue Runde'} übst. Dein Lernfortschritt bleibt erhalten.`,
      confirmLabel: 'Neue Runde starten',
      cancelLabel: 'Runde fortsetzen',
    });
    if (disposed) return;
    if (ok) startFresh(wanted);
    else resumeSaved(saved, { showResultsAgain: false, wanted: null }); // syncUrl shows the round's own subset
  }

  function resumeSaved(saved, { showResultsAgain, wanted }) {
    const { feedback, ...state } = saved;
    // Time away from the page is not study time (a finished session's clock is stopped).
    session = showResultsAgain ? state : { ...state, updatedAt: Date.now() };
    const pruned = pruneSession();
    pending = showResultsAgain ? null : pendingFeedback(session, feedback);
    if (pruned) persist();
    if (!session.order.length) {
      startFresh(wanted || 'all');
      return;
    }
    syncUrl();
    if (showResultsAgain) {
      // Also closes the last round when the page was left during the final "Richtig!".
      finish();
      return;
    }
    if (hasAnswers(session)) toast("Willkommen zurück – weiter geht's", { icon: 'sparkles' });
    if (pending) reopenFeedback();
    else afterRoundEnds();
  }

  // The "Nicht ganz" screen that was open when the page was left; the answer
  // itself is already recorded.
  function reopenFeedback() {
    const info = questionInfo(session.questions[pending.qid]);
    if (!info) {
      pending = null;
      afterRoundEnds();
      return;
    }
    const { given, dontKnow: isDontKnow } = pending;
    stage = 'card';
    mount(card.el);
    card.setQuestion(info, { animate: false });
    const result = isDontKnow || !hasText(given) ? null : gradeQuestion(set, info, given, options.tolerance).result;
    last = { info, given, result, dontKnow: isDontKnow, copy: false, editedCorrect: false, synonym: false };
    updateSide();
    showIncorrect();
  }

  // ------------------------------------------------------------ question
  function showNextQuestion({ animate = true } = {}) {
    clearAdvance();
    let q = S.current(session);
    let pruned = false;
    while (q && !usable(q.cardId)) {
      session = S.removeCard(session, q.cardId);
      pruned = true;
      q = S.current(session);
    }
    if (pruned) persist();
    if (!q) {
      afterRoundEnds();
      return;
    }
    const enteringStage = stage !== 'card';
    stage = 'card';
    phase = 'question';
    last = null;
    showStreak(false);
    mount(card.el);
    const info = questionInfo(q);
    // When focus stays in the answer field, the new prompt (its description) is
    // not read out by itself.
    const keepsFocus = document.activeElement === card.input;
    card.setQuestion(info, { animate: animate && !enteringStage });
    updateSide();
    lock();
    if (keepsFocus) {
      const both = !!session.setOptions && session.setOptions.answerWith === 'both';
      announce(`${info.promptLabel}: `, { text: info.prompt, lang: info.promptLang }, both ? `. ${info.placeholder}.` : '');
    }
    if (options.audio && info.ask === 'definition') speak(info.prompt, info.promptLang);
  }

  function submitAnswer(value) {
    if (stage !== 'card' || phase !== 'question') return;
    const info = questionInfo(S.current(session));
    if (!info) return;
    if (!hasText(value)) {
      card.rejectEmpty();
      announce('Gib zuerst eine Antwort ein – oder wähle «Weiss ich nicht».');
      return;
    }
    const { result, matchedCard } = gradeQuestion(set, info, value, options.tolerance);
    commitAnswer(info, value.trim(), result, false, !!matchedCard);
  }

  function dontKnow() {
    if (stage !== 'card' || phase !== 'question') return;
    const info = questionInfo(S.current(session));
    if (info) commitAnswer(info, '', null, true);
  }

  // synonym: the answer belongs to another card with the same prompt.
  function commitAnswer(info, given, result, isDontKnow, synonym = false) {
    clearAdvance();
    const correct = !!(result && result.correct);
    const at = Date.now();
    write(() => db.recordAnswer(setId, info.cardId, correct, at));
    session = S.answer(session, correct, at);
    // The streak counts every answer; a milestone replaces the praise and gets the fanfare.
    streak = recordStreak(streak, correct);
    showStreak(streak.milestone);
    sound({ answer: correct ? 'correct' : isDontKnow ? 'dontKnow' : 'wrong', milestone: streak.milestone });
    pending = correct ? null : { qid: info.qid, given, dontKnow: isDontKnow };
    persist();
    last = {
      info,
      given,
      result,
      dontKnow: isDontKnow,
      copy: false,
      editedCorrect: false,
      synonym,
      praise: streak.milestone ? streakTitle(streak.current) : null,
    };
    updateSide();
    if (options.audio) {
      const c = cards.get(info.cardId);
      if (c) speak(c.term, set.termLang);
    }
    if (correct) showCorrect();
    else showIncorrect();
  }

  function pickPraise() {
    const pool = PRAISE.filter((p) => p !== lastPraise);
    lastPraise = pool[Math.floor(Math.random() * pool.length)];
    return lastPraise;
  }

  // Also re-shows the praise after a dialog (the same words again).
  function showCorrect() {
    phase = 'correct';
    const { result, synonym } = last;
    // "Genau!" right above a "Genau: …" correction would read oddly. A synonym shows
    // the word the card asked for.
    if (!last.praise) last.praise = synonym ? 'Auch richtig!' : result.exact ? pickPraise() : 'Richtig!';
    const praise = last.praise;
    const exactLabel = synonym ? 'Gesucht war:' : 'Genau:';
    const notes = (result.notes || [])
      .filter((n) => NOTE_LABELS[n])
      .map((n) => ({ label: NOTE_LABELS[n], tone: n === 'synonym' ? 'accent' : 'warning' }));
    const ms = options.autoAdvance ? (result.exact ? ADVANCE_MS : ADVANCE_MS_WITH_NOTES) : 0;
    card.showCorrect({ praise, result, autoAdvanceMs: ms, notes, exactLabel });
    if (result.exact) announce(praise);
    else announce(`${praise} ${exactLabel} `, { text: result.expectedDisplay, lang: last.info.answerLang });
    lock();
    if (ms) advanceTimer = setTimeout(() => continueNext(false), ms);
  }

  function showIncorrect() {
    phase = 'incorrect';
    const { info, given, result, dontKnow: isDontKnow, editedCorrect } = last;
    last.copy = !!options.copyAnswer;
    const hintLabel = result && result.hint ? HINT_LABELS[result.hint] || null : null;
    card.showIncorrect({
      given,
      dontKnow: isDontKnow,
      hintLabel,
      copy: last.copy,
      canOverride: !isDontKnow && hasText(given),
      editedCorrect,
    });
    const lead = isDontKnow ? 'Kein Problem.' : 'Nicht ganz.';
    const tail = last.copy ? ' Tippe die richtige Antwort ab.' : '';
    announce(`${lead} Richtige Antwort: ${info.expected}.${hintLabel ? ` ${hintLabel}.` : ''}${tail}`);
    lock();
  }

  function submitCopy(value) {
    if (stage !== 'card' || phase !== 'incorrect' || !last) return;
    if (!last.copy) {
      continueNext(true);
      return;
    }
    const info = infoFor(last.info) || last.info;
    if (copyAccepted(value, info, options.tolerance)) {
      continueNext(true);
    } else {
      card.rejectCopy();
      announce('Noch nicht ganz – tippe die richtige Antwort genau ab.');
    }
  }

  // fromUser: clicks/keys respect the short lock so one press never skips two steps
  // (after a correct answer they move on when the lock ends instead).
  function continueNext(fromUser) {
    if (stage !== 'card' || phase === 'question') return;
    if (fromUser && locked()) {
      skipPraiseWhenUnlocked();
      return;
    }
    clearAdvance();
    if (pending) {
      // The miss is dealt with: a reload now continues after it.
      pending = null;
      persist();
    }
    if (S.isRoundOver(session)) afterRoundEnds({ afterAnswer: true });
    else showNextQuestion();
  }

  // «Ich hatte recht» / «Als richtig zählen»: the miss counts as correct, and so the streak
  // it ended goes on.
  function overrideLast() {
    if (stage !== 'card' || phase !== 'incorrect' || !last || last.dontKnow) return;
    clearAdvance();
    write(() => db.overrideLastAnswer(setId, last.info.cardId));
    session = S.override(session, last.info.qid, Date.now());
    pending = null;
    persist();
    updateSide();
    streak = overrideStreak(streak);
    showStreak(streak.milestone);
    toast('Als richtig gezählt', { tone: 'success', duration: 2000 });
    continueNext(false);
    // A round or the session that ends with it sounds its own fanfare instead.
    if (stage === 'card') sound({ answer: 'correct', milestone: streak.milestone });
  }

  // ------------------------------------------------------ rounds & finish
  // afterAnswer: the step follows an answer (or «Weiter zu Runde N»), so the round summary
  // or the results sound; a resume shows them silently.
  function afterRoundEnds({ afterAnswer = false } = {}) {
    if (!session.order.length) sessionEmptied();
    else if (S.isFinished(session)) finish({ afterAnswer });
    else if (S.isRoundOver(session)) showSummary({ afterAnswer });
    else showNextQuestion();
  }

  function showSummary({ afterAnswer = false } = {}) {
    clearAdvance();
    stage = 'summary';
    phase = null;
    if (afterAnswer) sound({ roundDone: true });
    const summary = S.roundSummary(session);
    const view = roundSummaryView({ summary, rows: termRows(set, cards, summary.items), onNext: () => goNextRound(true), onBack: backToSet });
    mount(view);
    updateSide();
    announce(`Runde ${summary.round} geschafft: ${summary.correct} von ${summary.total} richtig.`);
    lock();
    focusPrimary(view);
  }

  function goNextRound(fromUser) {
    if (stage !== 'summary' || (fromUser && locked())) return;
    session = S.nextRound(session);
    persist();
    if (S.isFinished(session)) finish({ afterAnswer: true });
    else showNextQuestion({ animate: false });
  }

  // afterAnswer: the session was just completed (the finish fanfare plays).
  function finish({ afterAnswer = false } = {}) {
    clearAdvance();
    // Closes the last round into the history and stamps finishedAt.
    session = S.nextRound(session);
    persist();
    if (afterAnswer) sound({ finished: true });
    showResults();
  }

  function showResults() {
    stage = 'results';
    phase = null;
    const stats = S.finalStats(session);
    if (!stats.total) {
      sessionEmptied();
      return;
    }
    const missed = stats.missedCardIds.filter((id) => usable(id));
    const view = resultsView({
      stats,
      hardestRows: termRows(set, cards, stats.hardest),
      setStats: setStats(),
      cardCount: cardIdsInSession().length,
      both: !!session.setOptions && session.setOptions.answerWith === 'both',
      onRetryMissed: missed.length ? () => startFresh({ cardIds: missed }) : null,
      onRestart: () => startFresh(typeof session.subset === 'string' ? session.subset : 'all'),
      onBack: backToSet,
    });
    mount(view);
    updateSide();
    announce(`Geschafft! ${Math.round(stats.accuracy * 100)} Prozent beim ersten Versuch richtig.`);
    lock();
    focusPrimary(view);
  }

  function focusPrimary(view) {
    const target = view.querySelector('[data-primary="true"]') || view.querySelector('.ui-btn');
    if (target) target.focus({ preventScroll: true });
  }

  function backToSet() {
    ctx.navigate(`/set/${setId}`);
  }

  // ----------------------------------------------------------- messages
  function showEmpty(subset) {
    clearAdvance();
    pending = null;
    stage = 'message';
    phase = null;
    const view = emptySubsetView({ subset, setId, onAll: () => startFresh('all'), onBack: backToSet });
    mount(view);
    // An Enter meant for the screen before must not press this one's button.
    lock();
    focusPrimary(view);
  }

  // Every question of the session vanished (cards deleted elsewhere).
  function sessionEmptied() {
    if (set.cards.some(isUsableCard)) startFresh(typeof session.subset === 'string' ? session.subset : 'all');
    else showEmpty('all');
  }

  function showGone() {
    clearAdvance();
    stage = 'message';
    phase = null;
    session = null;
    pending = null;
    mount(missingSetView());
    lock();
  }

  // --------------------------------------------------------- card edits
  function toggleStar() {
    const info = activeInfo();
    if (!info) return false;
    const value = write(() => db.toggleStar(setId, info.cardId));
    const fresh = db.getSet(setId);
    if (fresh) {
      set = fresh;
      indexCards();
    }
    card.focusPrimary();
    return !!value;
  }

  function openEdit() {
    const info = activeInfo();
    const c = info && cards.get(info.cardId);
    if (!c) return;
    const wasTimer = !!advanceTimer;
    clearAdvance();
    openCardEditor({
      termLang: set.termLang,
      defLang: set.defLang,
      card: c,
      focusSide: info.ask,
      onSave: (changes) => {
        if (!write(() => db.updateCard(setId, c.id, changes))) return false;
        applyCardEdit(info);
        toast('Karte gespeichert', { tone: 'success', duration: 2200 });
        return true;
      },
      onClose: (reason) => {
        if (reason !== 'route' && !disposed) resumeAfterOverlay({ wasTimer });
      },
    });
  }

  function applyCardEdit(info) {
    const fresh = db.getSet(setId);
    if (!fresh) {
      showGone();
      return;
    }
    set = fresh;
    indexCards();
    const updated = infoFor(info);
    if (!updated) return;
    if (phase === 'incorrect' && last) {
      last.info = updated;
      card.refresh(updated);
      // If the corrected card now accepts what was typed, offer to count it.
      const r = !last.dontKnow && hasText(last.given) ? gradeQuestion(set, updated, last.given, options.tolerance).result : null;
      last.editedCorrect = !!(r && r.correct);
      showIncorrect();
    } else {
      if (last) last.info = updated;
      card.refresh(updated);
    }
  }

  // ------------------------------------------------------------- options
  function openOptions() {
    if (stage === 'message') return;
    const wasTimer = !!advanceTimer;
    clearAdvance();
    const before = { answerWith: options.answerWith, shuffle: options.shuffle, copyAnswer: options.copyAnswer };
    openOptionsDialog({
      options,
      termLang: set.termLang,
      defLang: set.defLang,
      onChange: (patch) => {
        const next = write(() => db.updateStudyOptions(setId, patch));
        if (next) options = next;
      },
      onClose: ({ reason, restartAsked }) => {
        if (reason !== 'route' && !disposed) afterOptions({ before, wasTimer, restartAsked });
      },
    });
  }

  async function afterOptions({ before, wasTimer, restartAsked }) {
    if (restartAsked) {
      confirmRestart({ wasTimer });
      return;
    }
    const directionChanged = options.answerWith !== before.answerWith;
    const orderChanged = directionChanged || options.shuffle !== before.shuffle;
    const differsFromSession =
      !!session && !!session.setOptions && (session.setOptions.answerWith !== options.answerWith || session.setOptions.shuffle !== options.shuffle);
    if (session && session.finishedAt == null && orderChanged && differsFromSession) {
      const ok = await ask({
        title: 'Neu starten?',
        message: `${directionChanged ? 'Die neue Abfragerichtung' : 'Die neue Reihenfolge'} gilt ab einem Neustart. Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert.`,
        confirmLabel: 'Neu starten',
        cancelLabel: 'Später',
      });
      if (disposed) return;
      if (ok) {
        startFresh(session.subset);
        return;
      }
    }
    resumeAfterOverlay({ wasTimer, copyChanged: options.copyAnswer !== before.copyAnswer });
  }

  // Closing a dialog returns focus to the button that opened it (e.g. the sidebar's
  // "Optionen"), where the next Enter would open it again: hand it back to the step.
  function resumeAfterOverlay({ wasTimer = false, copyChanged = false } = {}) {
    if (disposed) return;
    if (stage === 'summary' || stage === 'results') {
      if (stageHost.firstChild) focusPrimary(stageHost.firstChild);
      return;
    }
    if (stage !== 'card') return;
    if (phase === 'correct' && (wasTimer || options.autoAdvance)) showCorrect();
    else if (phase === 'incorrect' && copyChanged) showIncorrect();
    card.focusPrimary();
  }

  async function confirmRestart({ wasTimer } = {}) {
    if (stage === 'message') return;
    const timerWasRunning = wasTimer || !!advanceTimer;
    clearAdvance();
    const ok = await ask({
      title: 'Neu starten?',
      message: 'Alle Begriffe dieser Lernrunde werden von vorne abgefragt. Dein Lernfortschritt bleibt gespeichert.',
      confirmLabel: 'Neu starten',
    });
    if (disposed) return;
    if (ok) startFresh(session ? session.subset : 'all');
    else resumeAfterOverlay({ wasTimer: timerWasRunning });
  }

  // ------------------------------------------------------- live updates
  function reconcile() {
    if (disposed) return;
    const fresh = db.getSet(setId);
    if (!fresh) {
      showGone();
      return;
    }
    set = fresh;
    indexCards();
    options = db.getStudyOptions(setId);
    side.setTitle(set.title);
    setTitle(`${set.title} – Schreiben`);
    if (!session) return;
    const pruned = pruneSession();
    if (pruned) persist();
    updateSide();
    if (stage === 'card') {
      if (phase === 'question') {
        const info = questionInfo(S.current(session));
        if (info) card.refresh(info);
        else afterRoundEnds();
      } else if (last) {
        const info = infoFor(last.info);
        if (info) {
          last.info = info;
          card.refresh(info);
        }
      }
    } else if (pruned && stage === 'summary') {
      afterRoundEnds();
    } else if (pruned && stage === 'results') {
      showResults();
    }
  }

  const unsubscribe = db.subscribe((evt) => {
    if (writing || disposed) return;
    const keys = evt && Array.isArray(evt.keys) ? evt.keys : null;
    if (!keys || keys.some((k) => k === 'sets' || k === 'settings' || k === `progress:${setId}`)) reconcile();
  });

  // ------------------------------------------------------------ keyboard
  function primaryAction() {
    if (stage === 'card') {
      if (phase === 'question') submitAnswer(card.value);
      else if (phase === 'correct') continueNext(true);
      else if (phase === 'incorrect') {
        if (last && last.copy) submitCopy(card.value);
        else continueNext(true);
      }
    } else if (stage === 'summary') {
      goNextRound(true);
    } else {
      const primary = stageHost.querySelector('[data-primary="true"]');
      if (!primary) return;
      // «Fertig» or a link leads to another screen: hold Enter back there for a moment.
      if (primary.tagName === 'A' || primary.dataset.leaves === 'true') settleEnter();
      primary.click();
    }
  }

  // The study shortcuts (write-keys.js studyCommand). Transitions wait for the input lock.
  function onCommand(command) {
    const onCard = stage === 'card' && !!session;
    switch (command) {
      case 'exit':
        if (!locked()) backToSet();
        return;
      case 'dontKnow':
        if (!locked()) dontKnow();
        return;
      case 'override':
        if (!locked()) overrideLast();
        return;
      case 'options':
        openOptions();
        return;
      case 'speak':
        if (onCard && activeInfo()) card.pressSpeak();
        return;
      case 'star':
        if (onCard && activeInfo()) announce(card.pressStar() ? 'Markiert' : 'Markierung entfernt');
        return;
      case 'edit':
        openEdit();
        return;
      case 'restart':
        if (locked() || stage === 'message' || !session) return;
        // On the results «Nochmal von vorne» starts at once, like its button.
        if (stage === 'results') startFresh(typeof session.subset === 'string' ? session.subset : 'all');
        else confirmRestart();
        return;
      default:
    }
  }

  const unbindKeys = bindWriteKeys({
    ownInput: () => card.input,
    isLocked: locked,
    onEnter: primaryAction,
    onLockedEnter: skipPraiseWhenUnlocked,
    canContinueOnKey: () => stage === 'card' && phase === 'correct',
    onContinueKey: () => continueNext(false),
    onCommand,
  });

  // ----------------------------------------------------- time tracking
  function studying() {
    return !!session && session.finishedAt == null && (stage === 'card' || stage === 'summary');
  }

  const clock = createStudyClock({
    isStudying: studying,
    tick: () => {
      session = S.tick(session);
      persist();
    },
    // Time away (hidden tab, idle) is not study time.
    resume: () => {
      if (session && session.finishedAt == null) session = { ...session, updatedAt: Date.now() };
    },
    onHidden: stopSpeaking,
  });

  boot();

  return () => {
    clock.tickNow();
    disposed = true;
    clearAdvance();
    clearTimeout(announceTimer);
    clock.dispose();
    unbindKeys();
    unsettle();
    unsubscribe();
    card.dispose();
    stopSpeaking();
  };
}
