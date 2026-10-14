// Prüfung (#/set/:id/exam): a vocabulary test with every question on one page, a time limit
// and a Swiss grade (port of the Mac's ExamController and ExamScreen). Phases: «Prüfung
// einrichten» (setup) → the sheet (running) → the marked exam (results).
//
// An exam records nothing (no progress, no activity, no stored session): mastery stays with
// Lernen and Schreiben. Only its settings are kept, for every set (PREF.examSettings).
// Leaving while an exam with answers runs asks first, whichever way it is left (Esc, also in an
// answer field; the back link; another route; «Neue Prüfung»). The time limit is computed from
// Date.now() on every tick, so a throttled background timer can never stretch it.
//
// This module owns the lifecycle, the keys, the timer and the top bar; the pages are built by
// exam-setup.js, exam-sheet.js and exam-results.js, the logic and texts live in core/exam.js.

import { h } from '../lib/dom.js';
import { getPref, setPref, PREF } from '../lib/prefs.js';
import { playSound } from '../lib/sounds.js';
import { db } from '../store/db.js';
import { setLeaveGuard } from '../router.js';
import { confirmDialog, toast, hasOpenModal, closeOverlays } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { missingSetView } from './write-views.js';
import { setupView, emptyView } from './exam-setup.js';
import { createSheet, statusView } from './exam-sheet.js';
import { resultsView } from './exam-results.js';
import * as E from '../core/exam.js';

// Return pressed right after a page changed does nothing (a held or double press must not run
// two steps); after the time ran out the result's Return waits longer (the Mac's KeyActionGate).
const ENTER_LOCK_MS = 280;
const TIMED_OUT_HOLD_MS = 1200;
const ANNOUNCE_DELAY_MS = 60;
// A «Noch eine Minute» that would arrive this late (a hidden window, a sleeping computer) is
// no longer true and stays away.
const STALE_WARNING_MS = 30000;

const NATIVE_ENTER = 'a[href], select, textarea, button:not([role="radio"])';

export function render(outlet, ctx) {
  const setId = ctx.params.id;
  const setTitle = typeof ctx.setTitle === 'function' ? ctx.setTitle : () => {};
  const setPath = `/set/${encodeURIComponent(setId)}`;

  const initialSet = db.getSet(setId);
  if (!initialSet) {
    setTitle('Lernset nicht gefunden');
    outlet.append(h('div', { class: 'ex ex--solo' }, h('div', { class: 'ex-col ex-col--setup' }, missingSetView())));
    return () => {};
  }

  const c = {
    set: initialSet,
    phase: 'setup', // 'setup' | 'running' | 'results' | 'gone'
    settings: E.readExamSettings(getPref(PREF.examSettings)),
    retake: null, // card ids of «Falsche prüfen»
    questions: [],
    answers: new Map(), // question number -> typed text
    startedAt: 0,
    deadline: null,
    minutes: 0, // the running sheet's time limit
    warned: false,
    result: null,
    sheetId: 0, // grows with every sheet; an old timer or dialog then does nothing
    view: null, // the page on screen: { el, dock, focusPrimary?, … }
    sheet: null,
    disposed: false,
  };
  let tickTimer = 0;
  let announceTimer = 0;
  let lockUntil = 0;
  let asking = false;
  let learning = false;
  let dockObserver = null;

  // -------------------------------------------------------------- skeleton
  const live = h('div', { class: 'sr-only', 'aria-live': 'polite', 'aria-atomic': 'true' });
  const topTitle = h('span', { class: 'ex-top__set' });
  const back = h(
    'a',
    { class: 'ex-top__back', href: `#${setPath}`, 'data-tooltip': 'Zurück zum Lernset' },
    icon('chevronLeft', { size: 18, strokeWidth: 2 }),
    h('span', { class: 'ex-top__titles' }, h('span', { class: 'ex-top__mode' }, 'Prüfung'), topTitle),
  );
  const status = statusView();
  const statusSlot = h('div', { class: 'ex-top__status' });
  const top = h('div', { class: 'ex-top' }, h('div', { class: 'ex-top__inner' }, back, statusSlot));
  const stage = h('div', { class: 'ex-stage' });
  const root = h('div', { class: 'ex', dataset: { phase: 'setup' } }, top, stage, live);
  outlet.append(root);

  function syncTitles() {
    topTitle.textContent = c.set.title;
    back.setAttribute('aria-label', `Zurück zum Lernset ${c.set.title}`);
    setTitle(`${c.set.title} – Prüfung`);
  }

  // Read out with a 60 ms delay, so the same text twice is announced again.
  function announce(text) {
    clearTimeout(announceTimer);
    live.textContent = '';
    announceTimer = setTimeout(() => {
      if (!c.disposed) live.textContent = text;
    }, ANNOUNCE_DELAY_MS);
  }

  function lock(ms = ENTER_LOCK_MS) {
    lockUntil = Math.max(lockUntil, performance.now() + ms);
  }

  const locked = () => performance.now() < lockUntil;

  // Toasts and «scrolled into view» keep clear of the bar at the bottom, whose height changes
  // with the special characters.
  function watchDock(dock) {
    if (dockObserver) dockObserver.disconnect();
    dockObserver = null;
    const rootStyle = document.documentElement.style;
    if (!dock) {
      rootStyle.removeProperty('--ex-dock-h');
      return;
    }
    const apply = () => rootStyle.setProperty('--ex-dock-h', `${Math.round(dock.getBoundingClientRect().height)}px`);
    apply();
    if (typeof ResizeObserver === 'function') {
      dockObserver = new ResizeObserver(apply);
      dockObserver.observe(dock);
    }
  }

  // Shows the phase's page. focus: 'primary' | 'first' (the sheet) | 'title' | null.
  function mount(view, { focus = 'primary', scroll = true } = {}) {
    c.view = view;
    root.dataset.phase = c.phase;
    stage.replaceChildren(view.el);
    if (c.phase === 'running') statusSlot.replaceChildren(status.el);
    else statusSlot.replaceChildren();
    watchDock(view.dock || null);
    if (scroll) window.scrollTo(0, 0);
    if (focus === 'first' && c.sheet) c.sheet.focusFirst();
    else if (focus === 'title' && view.focusTitle) view.focusTitle();
    else if (focus === 'primary' && view.focusPrimary) view.focusPrimary();
  }

  // ----------------------------------------------------------------- setup
  function showSetup({ focus = 'primary', scroll = true } = {}) {
    c.phase = 'setup';
    c.sheet = null;
    if (E.isEmptyForExam(c.set.cards)) {
      mount(emptyView({ setId, onBack: leave }), { focus, scroll });
      c.view.isEmpty = true;
      return;
    }
    mount(
      setupView(
        { set: c.set, settings: c.settings },
        {
          change: changeSettings,
          start: () => start(),
          back: leave,
        },
      ),
      { focus, scroll },
    );
  }

  // Every change is kept at once, for every set (the Mac's UserDefaults «exam.settings»).
  function changeSettings(patch) {
    const next = E.updateExamSettings(c.settings, patch);
    if (E.sameExamSettings(next, c.settings)) return;
    c.settings = next;
    setPref(PREF.examSettings, next);
    if (c.phase === 'setup' && c.view && c.view.update) c.view.update({ settings: next });
  }

  // ------------------------------------------------------------- the exam
  // «Prüfung starten» (and «Falsche prüfen»): a new sheet, the clock starts.
  function start() {
    if (c.disposed || c.phase === 'running') return;
    const questions = E.makeQuestions(c.set.cards, c.settings, {
      termLang: c.set.termLang,
      defLang: c.set.defLang,
      cardIds: c.retake,
      rng: Math.random,
    });
    if (!questions.length) return;
    c.questions = questions;
    c.answers = new Map();
    c.result = null;
    c.sheetId += 1;
    c.startedAt = Date.now();
    c.minutes = c.settings.minutes;
    c.deadline = E.examDeadline(c.startedAt, c.minutes);
    c.warned = false;
    c.phase = 'running';
    lock();
    c.sheet = createSheet(
      { questions, termLang: c.set.termLang, defLang: c.set.defLang },
      {
        input: onAnswer,
        submit: () => requestSubmit(),
      },
    );
    status.setAnswered(0, questions.length);
    mount(c.sheet, { focus: 'first' });
    tick();
    announce(E.startAnnouncement(questions.length, c.minutes));
  }

  function onAnswer(number, text) {
    if (c.phase !== 'running') return;
    c.answers.set(number, text);
    const answered = E.answeredCount(c.questions, c.answers);
    c.sheet.refreshOpen(answered);
    status.setAnswered(answered, c.questions.length);
  }

  const answered = () => (c.phase === 'running' ? E.answeredCount(c.questions, c.answers) : 0);

  // «Abgeben» (Strg+↵): asks first while questions are still open.
  async function requestSubmit() {
    if (c.disposed || c.phase !== 'running' || asking) return;
    const open = c.questions.length - answered();
    if (open <= 0) {
      submit();
      return;
    }
    const sheet = c.sheetId;
    asking = true;
    const ok = await confirmDialog({ ...E.submitConfirm(open), danger: false });
    asking = false;
    if (!ok || c.disposed || c.phase !== 'running' || c.sheetId !== sheet) return;
    submit();
  }

  // Marks the sheet and shows the result.
  function submit({ timedOut = false } = {}) {
    if (c.phase !== 'running') return;
    clearTimeout(tickTimer);
    const now = Date.now();
    // Handed in by the timer: the time taken is the limit, even when a throttled timer of a
    // hidden window noticed it late.
    const end = timedOut && c.deadline != null ? Math.min(now, c.deadline) : now;
    const result = E.evaluateExam(c.questions, c.answers, c.set.cards, c.settings.tolerance, { elapsedMs: end - c.startedAt, timedOut });
    c.result = result;
    c.phase = 'results';
    c.sheet = null;
    if (timedOut) {
      // A question asked meanwhile («Prüfung abgeben?», «Prüfung beenden?») no longer applies.
      closeOverlays();
      // Handed in while the learner may be typing: a Return meant for the next question must
      // not press «Fertig» and throw the result away unseen.
      lock(TIMED_OUT_HOLD_MS);
    } else {
      lock();
    }
    mount(resultsView(result, { newExam: requestNewExam, learn: learnMistakes, retake: retakeMistakes, done: leave }), {
      focus: timedOut ? 'title' : 'primary',
    });
    playSound(E.passes(result.grade) ? 'finished' : 'roundDone');
    if (timedOut) toast(E.TIMED_OUT_TOAST, { tone: 'warning', icon: 'clock' });
    announce(E.resultAnnouncement(result));
  }

  // «Falsche prüfen»: a new sheet with only the words to practise (same settings and time).
  function retakeMistakes() {
    if (c.disposed || c.phase !== 'results' || !c.result) return;
    const ids = E.cardIdsToPractise(c.result);
    if (!ids.length) return;
    c.retake = ids;
    start();
  }

  // «Neue Prüfung» (Strg+⇧+R): back to the settings; a running exam with answers asks first.
  async function requestNewExam() {
    if (c.disposed || c.phase === 'setup' || c.phase === 'gone' || asking) return;
    if (c.phase === 'running' && answered() > 0) {
      const sheet = c.sheetId;
      asking = true;
      const ok = await confirmDialog({ ...E.LEAVE_CONFIRM, danger: true });
      asking = false;
      if (!ok || c.disposed || c.phase !== 'running' || c.sheetId !== sheet) return;
    }
    clearTimeout(tickTimer);
    c.retake = null;
    c.questions = [];
    c.answers = new Map();
    c.result = null;
    lock();
    showSetup();
  }

  // «Falsche lernen»: a Learn session with the words to practise, mastered ones included
  // (repetition questions): the exam just found them wrong.
  async function learnMistakes() {
    if (c.disposed || !c.result || learning) return;
    const ids = E.cardIdsToPractise(c.result);
    if (!ids.length) return;
    // A second click while the helper loads (or its question is open) starts nothing twice.
    learning = true;
    try {
      const mod = await import('./learn-start.js');
      if (c.disposed) return;
      if (mod && typeof mod.startLearnWithCards === 'function') {
        await mod.startLearnWithCards({ setId, cardIds: ids, review: true, navigate: ctx.navigate });
        return;
      }
    } catch {
      /* not there (yet) or broken: the URL does the same */
    } finally {
      learning = false;
    }
    // Without the shared helper: the URL contract of Lernen.
    if (!c.disposed) ctx.navigate(E.learnCardsPath(setId, ids, { review: true }));
  }

  // Back to the set (Esc, «Zurück zum Lernset», «Fertig»): the leave guard asks while an exam
  // with answers runs.
  function leave() {
    if (!c.disposed) ctx.navigate(setPath);
  }

  // ------------------------------------------------------------------ time
  function tick() {
    clearTimeout(tickTimer);
    if (c.disposed || c.phase !== 'running') return;
    const now = Date.now();
    const clock = E.clockState({ startedAt: c.startedAt, deadline: c.deadline, now });
    status.setClock(clock);
    if (c.deadline != null) {
      const left = c.deadline - now;
      if (left <= 0) {
        submit({ timedOut: true });
        return;
      }
      if (!c.warned && E.warnsBeforeEnd(c.minutes) && left <= E.ONE_MINUTE_MS) {
        c.warned = true;
        // The toast is a status message: screen readers hear it without an announcement.
        if (left > STALE_WARNING_MS) toast(E.ONE_MINUTE_TEXT, { tone: 'warning', icon: 'clock' });
      }
    }
    // Next when the shown second changes (a little after, so it has changed).
    tickTimer = setTimeout(tick, Math.max(40, Math.min(1000, clock.nextChangeMs)) + 15);
  }

  // A hidden window's timers are throttled: catch up the moment it is shown again.
  function onVisibility() {
    if (document.visibilityState === 'visible' && c.phase === 'running') tick();
  }

  // ------------------------------------------------------------ leaving
  setLeaveGuard(async () => {
    if (c.disposed || c.phase !== 'running' || answered() === 0) return true;
    const sheet = c.sheetId;
    const ok = await confirmDialog({ ...E.LEAVE_CONFIRM, danger: true });
    // Handed in meanwhile (the time ran out): stay and show the result.
    if (c.phase !== 'running' || c.sheetId !== sheet) return false;
    if (ok) clearTimeout(tickTimer);
    return ok;
  });

  // A reload or closing the tab would lose the answers too.
  function onBeforeUnload(e) {
    if (c.phase !== 'running' || answered() === 0) return;
    e.preventDefault();
    e.returnValue = '';
  }

  // ---------------------------------------------------------------- keys
  function onKeydown(e) {
    if (c.disposed || e.defaultPrevented) return;
    if (e.isComposing || e.keyCode === 229) return;
    // A held ↵ (also Strg+↵) never presses anything, not even the button a dialog it opened
    // just focused («Abgeben» in «Prüfung abgeben?»).
    if (e.key === 'Enter' && e.repeat) {
      e.preventDefault();
      return;
    }
    if (hasOpenModal()) return;
    const command = (e.ctrlKey || e.metaKey) && !e.altKey;

    // Strg+↵ (⌘↵): hand in.
    if (command && !e.shiftKey && e.key === 'Enter') {
      if (c.phase !== 'running') {
        // Pressed again right after handing in: it must not press the focused «Fertig» too.
        if (locked()) e.preventDefault();
        return;
      }
      e.preventDefault();
      requestSubmit();
      return;
    }
    // Strg+⇧+R (⇧⌘R): «Neue Prüfung» (the browser's hard reload otherwise).
    if (command && e.shiftKey && (e.code === 'KeyR' || String(e.key).toLowerCase() === 'r')) {
      if (c.phase !== 'running' && c.phase !== 'results') {
        // Held on from the results into the settings: no hard reload either.
        if (e.repeat || locked()) e.preventDefault();
        return;
      }
      e.preventDefault();
      if (!e.repeat) requestNewExam();
      return;
    }
    // AltGr (Ctrl+Alt on Windows) and other shortcuts type or do their own thing.
    if (e.ctrlKey || e.metaKey || e.altKey) return;

    if (e.key === 'Escape') {
      if (c.phase === 'gone') return;
      e.preventDefault();
      if (!e.repeat) leave();
      return;
    }
    if (e.key !== 'Enter') return;
    if (locked()) {
      e.preventDefault();
      return;
    }
    const target = e.target && e.target.closest ? e.target : null;
    if (c.phase === 'running') {
      // ↵ in an answer: on to the next question (the last one keeps the keys).
      const number = c.sheet ? c.sheet.fieldOf(target) : null;
      if (number == null) return;
      e.preventDefault();
      c.sheet.focusNext(number);
      return;
    }
    if (target && target.closest(NATIVE_ENTER)) return; // a focused button or link handles ↵ itself
    if (target && target.closest('input:not([type="checkbox"])')) return;
    e.preventDefault();
    if (c.phase === 'setup') {
      if (c.view && c.view.isEmpty) return;
      start();
    } else if (c.phase === 'results') {
      leave();
    }
  }

  // --------------------------------------------------------- live updates
  // The settings page and the result follow the set (another tab, the editor); a running
  // sheet keeps the texts it was asked with.
  const unsubscribe = db.subscribe((evt) => {
    if (c.disposed) return;
    const keys = evt && Array.isArray(evt.keys) ? evt.keys : null;
    if (keys && !keys.includes('sets')) return;
    const fresh = db.getSet(setId);
    if (!fresh) {
      if (c.phase === 'gone') return;
      const hadFocus = root.contains(document.activeElement);
      clearTimeout(tickTimer);
      c.phase = 'gone'; // the leave guard lets go now: there is nothing left to lose
      c.view = null;
      c.sheet = null;
      setTitle('Lernset nicht gefunden');
      watchDock(null);
      statusSlot.replaceChildren();
      root.dataset.phase = 'gone';
      const missing = missingSetView();
      stage.replaceChildren(h('div', { class: 'ex-col ex-col--setup' }, missing));
      const primary = hadFocus && missing.querySelector('[data-primary="true"]');
      if (primary) primary.focus({ preventScroll: true });
      return;
    }
    c.set = fresh;
    syncTitles();
    // Deleted and restored («Rückgängig» in another tab): the settings again.
    if (c.phase === 'gone') {
      const hadFocus = root.contains(document.activeElement);
      c.retake = null;
      showSetup({ focus: hadFocus ? 'primary' : null, scroll: false });
      return;
    }
    if (c.phase !== 'setup' || !c.view) return;
    const empty = E.isEmptyForExam(fresh.cards);
    if (empty !== !!c.view.isEmpty) {
      const hadFocus = root.contains(document.activeElement);
      showSetup({ focus: hadFocus ? 'primary' : null, scroll: false });
    } else if (c.view.update) {
      c.view.update({ set: fresh });
    }
  });

  document.addEventListener('keydown', onKeydown);
  document.addEventListener('visibilitychange', onVisibility);
  window.addEventListener('beforeunload', onBeforeUnload);

  syncTitles();
  showSetup();

  return () => {
    c.disposed = true;
    clearTimeout(tickTimer);
    clearTimeout(announceTimer);
    document.removeEventListener('keydown', onKeydown);
    document.removeEventListener('visibilitychange', onVisibility);
    window.removeEventListener('beforeunload', onBeforeUnload);
    unsubscribe();
    watchDock(null);
    setLeaveGuard(null);
  };
}
