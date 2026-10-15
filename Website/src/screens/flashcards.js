// Karteikarten (#/set/:id/flashcards), port of the Mac's FlashcardsController + FlashcardsScreen:
// one card at a time, turned with Space / Enter / ↑↓ / a click and sorted with ← «Lerne ich noch»
// and → «Weiss ich» (or a swipe), in rounds until every card is known. The deck is stored after
// every action and follows the set; `?new=1` starts anew, `?subset=starred` with starred cards.
// Nothing here records answers, progress or activity. Card and motion: flashcards-card.js;
// swipes, keys and the views around the card: flashcards-swipe/-keys/-views.js.

import { h, prefersReducedMotion } from '../lib/dom.js';
import { bcp47, textAttrs } from '../lib/labels.js';
import { getPref, setPref, PREF } from '../lib/prefs.js';
import { playSound } from '../lib/sounds.js';
import { speak, stopSpeaking } from '../lib/speech.js';
import { db } from '../store/db.js';
import { toast, hasOpenModal } from '../ui/components.js';
import { sideNames } from '../ui/study-options.js';
import * as F from '../core/flashcards.js';
import { ask, openCardEditor } from './write-dialogs.js';
import { settleEnter } from './write-keys.js';
import { missingSetView } from './write-views.js';
import { isApplePlatform } from './editor-util.js';
import { createCardStage, cardHeightFor, STACK } from './flashcards-card.js';
import { bindSwipe } from './flashcards-swipe.js';
import { bindFlashcardKeys } from './flashcards-keys.js';
import { createFlashcardsSidebar, createActionBar, summaryView, emptyView, openFlashcardsOptions } from './flashcards-views.js';

// Enter-bound actions wait this long after a transition (a round's end, a new round, a restart),
// so one press never does two steps.
const ENTER_LOCK_MS = 280;
const SUMMARY_LEAVE_MS = 120;
// Room kept below the action bar when the card's height is fitted to the window.
const BOTTOM_ROOM = 16;

const hasText = (text) => typeof text === 'string' && text.trim() !== '';

function entryState() {
  const st = history.state;
  return st && typeof st === 'object' && !Array.isArray(st) ? st : {};
}

export function render(outlet, ctx) {
  const setId = ctx.params.id;
  const query = ctx.query || {};
  const setTitle = typeof ctx.setTitle === 'function' ? ctx.setTitle : () => {};
  const navigate = typeof ctx.navigate === 'function' ? ctx.navigate : () => {};

  let set = db.getSet(setId);
  if (!set) {
    setTitle('Lernset nicht gefunden');
    outlet.append(h('div', { class: 'wr wr--solo fc' }, h('div', { class: 'wr-main' }, missingSetView())));
    return () => {};
  }

  const apple = isApplePlatform();
  let cards = new Map();
  let deck = null;
  let front = getPref(PREF.flashcardsFront, 'term') === 'definition' ? 'definition' : 'term';
  // Grows with every new round and restart: a card that comes up again is a new card on screen
  // while its last exit can still finish.
  let generation = 0;
  let disposed = false;
  let gone = false;
  let writing = 0;
  let lockUntil = 0;
  let announceTimer = 0;
  let summaryTimer = 0;
  let summarySig = '';
  let layoutFrame = 0;
  let optionsModal = null;

  // ------------------------------------------------------------- skeleton
  const live = h('div', { class: 'sr-only', 'aria-live': 'polite', 'aria-atomic': 'true' });
  const side = createFlashcardsSidebar({ setId, title: set.title, apple, onOptions: openOptions, onRestart: requestRestart });
  const stage = createCardStage({ onSpeak: speakVisible, onStar: toggleStar, onEdit: editCard, apple });
  const summaryHost = h('div', { class: 'fc-stage__summary' });
  const stageArea = h('div', { class: 'fc-stage', dataset: { mode: 'card' } }, stage.el, summaryHost);
  const bar = createActionBar({ apple, onUndo: undo, onSort: (verdict) => sort(verdict), onPrimary: primaryAction, onBack: exit, onLearn: openLearn });
  const emptyHost = h('div', { class: 'fc-empty', hidden: true });
  const main = h('div', { class: 'wr-main fc-main' }, stageArea, bar.el, emptyHost);
  const root = h('div', { class: 'wr fc' }, side.el, main, live);
  outlet.append(root);

  // ------------------------------------------------------------- helpers
  const phase = () => F.deckPhase(deck);
  const cardOrder = () => set.cards.map((card) => card.id);
  const starredCount = () => set.cards.reduce((n, card) => n + (card.starred ? 1 : 0), 0);

  function indexCards() {
    cards = new Map(set.cards.map((card) => [card.id, card]));
  }

  // Runs a db write; the screen's own writes are ignored by the subscription below.
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
    if (!deck || disposed || gone) return;
    write(() => db.saveFlashcards(setId, deck));
  }

  // What a card shows face up (showingBack false) or face down: text, language and its name.
  function sideOf(card, showingBack, names) {
    const term = F.showsTermSide(front, showingBack);
    return {
      text: term ? card.term : card.definition,
      lang: term ? set.termLang : set.defLang,
      label: term ? names.term.label : names.definition.label,
    };
  }

  function infoFor(id) {
    const card = id != null ? cards.get(id) : null;
    if (!card) return null;
    const names = sideNames(set.termLang, set.defLang);
    const up = deck.isFlipped && F.currentCardId(deck) === id ? 'back' : 'front';
    return { key: `${generation}:${id}`, id, starred: !!card.starred, up, front: sideOf(card, false, names), back: sideOf(card, true, names) };
  }

  function visibleSide() {
    const info = infoFor(F.currentCardId(deck));
    return info ? (deck.isFlipped ? info.back : info.front) : null;
  }

  // parts: strings or { text, lang } (read with the voice of that language).
  function announce(...parts) {
    clearTimeout(announceTimer);
    live.textContent = '';
    announceTimer = setTimeout(() => {
      if (disposed) return;
      live.replaceChildren(...parts.filter(Boolean).map((p) => (typeof p === 'string' ? p : h('span', textAttrs(p.lang), p.text))));
    }, 60);
  }

  // «Französisch: la voiture» for the side on screen.
  function sideParts(s) {
    if (!s) return [];
    return hasText(s.text) ? [`${s.label}: `, { text: s.text, lang: s.lang }] : [`${s.label}: Keine Angabe`];
  }

  const lock = () => {
    lockUntil = performance.now() + ENTER_LOCK_MS;
  };
  const locked = () => performance.now() < lockUntil;

  // The primary action keeps the focus, so Enter always does the step on screen.
  function focusPrimary() {
    if (disposed || hasOpenModal()) return;
    const target = phase() === 'empty' ? emptyHost.querySelector('[data-primary="true"]') : bar.primary;
    if (target && document.activeElement !== target) target.focus({ preventScroll: true });
  }

  function updateChrome() {
    const st = F.deckStats(deck);
    side.update(st);
    bar.update(st, deck);
    stage.setStack(st.phase === 'card' ? st.upcoming : 0);
    root.classList.toggle('wr--solo', st.phase === 'empty');
    stageArea.hidden = st.phase === 'empty';
    emptyHost.hidden = st.phase !== 'empty';
  }

  // Keeps the URL resumable: drops `new=1`, keeps `subset=starred` for a starred-only deck.
  function syncUrl() {
    if (!deck || disposed) return;
    const hash = String(location.hash || '');
    const path = hash.split('?')[0];
    if (!/\/flashcards$/.test(path)) return;
    const target = deck.starredOnly ? `${path}?subset=starred` : path;
    if (hash === target) return;
    try {
      history.replaceState({ ...entryState() }, '', target);
    } catch {
      /* rate-limited (Safari): keep the current URL */
    }
  }

  // ------------------------------------------------------------- layout
  // The card's height: what is left above the action bar, in an index-card shape (240–440 px).
  function measure() {
    layoutFrame = 0;
    if (disposed || gone || phase() === 'empty') return;
    const width = stage.el.clientWidth;
    if (!width) return;
    // From the layout, not the screen: the screen slides in by a few px while this first runs.
    let top = 0;
    for (let el = stage.el; el; el = el.offsetParent) top += el.offsetTop || 0;
    const barStyle = getComputedStyle(bar.el);
    const barRoom = bar.el.offsetHeight + (parseFloat(barStyle.marginTop) || 0) + BOTTOM_ROOM;
    stage.setHeight(cardHeightFor(width, window.innerHeight - top - STACK.depth - barRoom));
  }

  function scheduleLayout() {
    if (!layoutFrame && !disposed) layoutFrame = requestAnimationFrame(measure);
  }

  // -------------------------------------------------------------- views
  function presentCurrent(arrival = 'stack', verdict = F.KNOW) {
    const info = infoFor(F.currentCardId(deck));
    if (info) stage.present(info, { arrival, verdict });
  }

  // After a round and at the end. arriving: it fades in once the last card has started to leave.
  function showSummary({ arriving = false } = {}) {
    clearTimeout(summaryTimer);
    const st = F.deckStats(deck);
    const sig = `${st.phase}|${st.round}|${st.known}|${st.learning}|${st.total}`;
    stageArea.dataset.mode = 'summary';
    const shown = summaryHost.firstElementChild;
    if (shown && !shown.classList.contains('is-leaving') && sig === summarySig) return;
    summarySig = sig;
    summaryHost.replaceChildren(summaryView(deck, { arriving: arriving && !prefersReducedMotion() }));
  }

  function hideSummary() {
    stageArea.dataset.mode = 'card';
    summarySig = '';
    const view = summaryHost.firstElementChild;
    if (!view) return;
    clearTimeout(summaryTimer);
    if (prefersReducedMotion()) {
      summaryHost.replaceChildren();
      return;
    }
    view.classList.add('is-leaving');
    summaryTimer = setTimeout(() => view.remove(), SUMMARY_LEAVE_MS);
  }

  function showEmpty() {
    stage.clear();
    hideSummary();
    summaryHost.replaceChildren();
    emptyHost.replaceChildren(emptyView({ onBack: exit, onAdd: addCards }));
  }

  // Shows the deck as it is (opening, a deck from another tab, a restart).
  function showPhase({ arrival = 'stack' } = {}) {
    const p = phase();
    if (p === 'empty') {
      showEmpty();
    } else {
      emptyHost.replaceChildren();
      if (p === 'card') {
        hideSummary();
        presentCurrent(arrival);
      } else {
        stage.drop();
        showSummary();
      }
    }
    updateChrome();
    scheduleLayout();
  }

  function showGone() {
    gone = true;
    deck = null;
    swipe.cancel({ silent: true });
    stage.clear();
    root.classList.add('wr--solo');
    main.replaceChildren(missingSetView());
    setTitle('Lernset nicht gefunden');
    // The button that had the focus is gone: «Zur Übersicht» takes Enter.
    const primary = main.querySelector('[data-primary="true"]');
    if (primary && !hasOpenModal()) primary.focus({ preventScroll: true });
  }

  // ------------------------------------------------------------ actions
  function flip() {
    if (disposed || phase() !== 'card' || !stage.current) return;
    deck = F.flipCard(deck, Date.now());
    persist();
    stage.flip(deck.isFlipped);
    announce(...sideParts(visibleSide()));
  }

  // Sorts the card on screen: it glides off to its side (`flung`: a swipe let it go there, it flies
  // on from `releaseOffset`), the next one rises from the stack. The round's fanfare replaces the
  // card's own sound when this was the round's last card.
  function sort(verdict, { flung = false, releaseOffset = null } = {}) {
    if (disposed || phase() !== 'card') return;
    const offset = releaseOffset != null ? releaseOffset : swipe.offset;
    swipe.cancel({ silent: true });
    stage.depart('sorted', { verdict, flung, releaseOffset: offset });
    deck = F.sortCard(deck, verdict, Date.now());
    persist();
    const p = phase();
    if (p === 'card') presentCurrent('stack');
    else {
      showSummary({ arriving: true });
      lock();
    }
    updateChrome();
    playSound(p === 'roundDone' ? 'roundDone' : p === 'finished' ? 'finished' : verdict);
    if (p === 'card') announce(`${F.verdictTitle(verdict)}. `, ...sideParts(visibleSide()));
    else if (p === 'roundDone') announce(`${F.verdictTitle(verdict)}. Runde ${deck.round} geschafft: ${F.roundDoneTitle(deck)}`);
    else announce(`${F.verdictTitle(verdict)}. ${F.finishedTitle(deck)}`);
    focusPrimary();
  }

  // «Zurück» (Backspace): the last sorted card comes back from its side (along its own path while
  // it is still leaving); the card on screen goes back under the stack.
  function undo() {
    if (disposed || !F.canUndo(deck)) return;
    const last = F.lastSort(deck);
    swipe.cancel({ silent: true });
    if (phase() === 'card') stage.depart('sink');
    deck = F.undoSort(deck, Date.now());
    persist();
    hideSummary();
    const info = infoFor(last.cardID);
    if (info && !stage.recall(info)) stage.present(info, { arrival: 'side', verdict: last.verdict });
    updateChrome();
    playSound('undo');
    announce('Zurückgeholt. ', ...sideParts(visibleSide()));
    focusPrimary();
  }

  // «Weiter mit N Karten» after a round.
  function nextRound() {
    if (disposed || phase() !== 'roundDone') return;
    generation++;
    deck = F.startNextRound(deck, { cardOrder: cardOrder(), now: Date.now() });
    persist();
    hideSummary();
    presentCurrent('stack');
    updateChrome();
    lock();
    announce(`Runde ${deck.round}. `, ...sideParts(visibleSide()));
    focusPrimary();
  }

  // A new deck over the same cards (or, with `starredOnly`, over all or the starred ones); it
  // keeps «Mischen». An empty starred-only deck falls back to all cards.
  function restart(starredOnly) {
    if (disposed || gone || !deck) return;
    const only = typeof starredOnly === 'boolean' ? starredOnly : deck.starredOnly;
    swipe.cancel({ silent: true });
    generation++;
    stage.drop({ fade: true });
    deck = F.restartDeck(set.cards, { starredOnly: only, shuffled: deck.isShuffled, now: Date.now() });
    persist();
    syncUrl();
    showPhase({ arrival: 'stack' });
    lock();
    if (phase() === 'card') announce('Neu gestartet. ', ...sideParts(visibleSide()));
    if (optionsModal) optionsModal.sync(optionState());
    focusPrimary();
  }

  // «Neu starten» (Ctrl+Shift+R): asks first when cards were sorted.
  async function requestRestart() {
    if (disposed || gone || phase() === 'empty') return;
    swipe.cancel();
    if (F.hasProgress(deck) && F.isResumable(deck)) {
      const ok = await ask({ title: 'Karteikarten neu starten?', message: F.restartMessage(deck), confirmLabel: 'Neu starten' });
      if (disposed || gone) return;
      if (!ok) {
        focusPrimary();
        return;
      }
    }
    restart();
  }

  // The primary button: «Umdrehen», «Weiter mit N Karten», «Nochmal von vorne» (no question).
  function primaryAction() {
    const p = phase();
    if (p === 'card') flip();
    else if (p === 'roundDone') nextRound();
    else if (p === 'finished') restart();
  }

  function exit() {
    stopSpeaking();
    navigate(`/set/${setId}`);
  }

  // «Lernen» at the end: the cards are tested for real there (resumes a running session).
  function openLearn() {
    stopSpeaking();
    navigate(`/set/${setId}/learn`);
  }

  // «Begriffe hinzufügen» (also Enter on an empty set): the editor's Enter-bound buttons wait a
  // moment, so the same press never lands there too.
  function addCards() {
    if (disposed || gone) return;
    settleEnter();
    navigate(`/set/${setId}/edit`);
  }

  // ----------------------------------------------------------- card tools
  // 🔊 (Ctrl+R): reads the side that is up (only where 🔊 shows, as in Schreiben: a side of
  // another language would be read with a wrong voice).
  function speakVisible() {
    if (disposed || phase() !== 'card') return;
    const s = visibleSide();
    if (s && hasText(s.text) && bcp47(s.lang)) speak(s.text, s.lang);
  }

  // ★ (Ctrl+D) of the card on screen.
  function toggleStar() {
    if (disposed || phase() !== 'card') return;
    const id = F.currentCardId(deck);
    const starred = write(() => db.toggleStar(setId, id));
    if (starred === undefined) return;
    reconcile();
    announce(starred ? 'Markiert' : 'Markierung entfernt');
  }

  // ✎ (Ctrl+E): the card editor of Lernen and Schreiben, on the side that is up.
  function editCard() {
    if (disposed || phase() !== 'card' || hasOpenModal()) return;
    const card = cards.get(F.currentCardId(deck));
    if (!card) return;
    swipe.cancel();
    openCardEditor({
      termLang: set.termLang,
      defLang: set.defLang,
      card,
      focusSide: F.showsTermSide(front, deck.isFlipped) ? 'term' : 'definition',
      onSave: (changes) => {
        if (!write(() => db.updateCard(setId, card.id, changes))) return false;
        reconcile();
        toast('Karte gespeichert', { tone: 'success', duration: 2200 });
        return true;
      },
      onClose: (reason) => {
        if (reason !== 'route' && !disposed) focusPrimary();
      },
    });
  }

  // ------------------------------------------------------------ options
  function optionState() {
    return { front, shuffled: !!(deck && deck.isShuffled), starredOnly: !!(deck && deck.starredOnly), starredCount: starredCount(), canRestart: F.hasProgress(deck) };
  }

  // Ctrl+K: «Vorderseite» and «Mischen» (for every set, at once) and «Nur markierte» (starts over).
  function openOptions() {
    if (disposed || gone || phase() === 'empty' || hasOpenModal()) return;
    swipe.cancel();
    optionsModal = openFlashcardsOptions({
      names: sideNames(set.termLang, set.defLang),
      state: optionState(),
      onFront: setFront,
      onShuffle: setShuffle,
      onStarredOnly: (on) => {
        if (deck && on !== deck.starredOnly) restart(on);
      },
      onClose: ({ reason, restartAsked }) => {
        optionsModal = null;
        if (reason === 'route' || disposed) return;
        if (restartAsked) requestRestart();
        else focusPrimary();
      },
    });
  }

  function setFront(value) {
    const next = value === 'definition' ? 'definition' : 'term';
    if (next === front) return;
    front = next;
    setPref(PREF.flashcardsFront, next);
    refreshCurrent();
  }

  function setShuffle(on) {
    setPref(PREF.flashcardsShuffle, !!on);
    if (!deck) return;
    const next = F.setShuffled(deck, on, { cardOrder: cardOrder(), now: Date.now() });
    if (next === deck) return;
    deck = next;
    persist();
    updateChrome();
  }

  // The texts, labels and star of the card on screen.
  function refreshCurrent() {
    const info = infoFor(F.currentCardId(deck));
    if (info) stage.update(info);
  }

  // ------------------------------------------------------- live updates
  // The set changed (star, card editor, set editor, another tab): the deck follows it.
  function reconcile() {
    if (disposed || gone) return;
    const fresh = db.getSet(setId);
    if (!fresh) {
      showGone();
      return;
    }
    const before = JSON.stringify(set);
    set = fresh;
    indexCards();
    side.setTitle(set.title);
    setTitle(`${set.title} – Karteikarten`);
    if (JSON.stringify(set) === before) return;

    const prevPhase = phase();
    const prevId = F.currentCardId(deck);
    let next = F.syncDeck(deck, set.cards, Date.now());
    if (F.deckPhase(next) === 'empty' && next.starredOnly && F.eligibleIds(set.cards).length) {
      // Every card of a starred-only deck was deleted, but the set still has cards: «Dieses
      // Lernset hat noch keine Begriffe» would be wrong, so all cards start (as on opening).
      generation++;
      next = F.restartDeck(set.cards, { shuffled: next.isShuffled, now: Date.now() });
    }
    if (next !== deck) {
      deck = next;
      persist();
      syncUrl();
    }
    const p = phase();
    const id = F.currentCardId(deck);
    if (p === 'empty') {
      if (prevPhase !== 'empty') {
        swipe.cancel({ silent: true });
        showEmpty();
      }
    } else {
      if (prevPhase === 'empty') emptyHost.replaceChildren();
      if (p === 'card') {
        if (prevPhase !== 'card') {
          hideSummary();
          presentCurrent('stack');
        } else if (id !== prevId) {
          // The card on screen was deleted: the next one rises from the stack.
          swipe.cancel({ silent: true });
          stage.drop({ fade: true });
          presentCurrent('stack');
        } else {
          refreshCurrent();
        }
      } else {
        if (prevPhase === 'card') {
          swipe.cancel({ silent: true });
          stage.drop({ fade: true });
        }
        showSummary();
      }
    }
    updateChrome();
    // The empty set's buttons came or went, or the focus was on a card that left: the step's
    // primary takes Space and Enter again.
    const active = document.activeElement;
    if ((p === 'empty') !== (prevPhase === 'empty') || !active || active === document.body || !active.isConnected) focusPrimary();
    if (optionsModal) optionsModal.sync(optionState());
    scheduleLayout();
  }

  // Another tab sorted or restarted this set's deck: show that one.
  function adoptStored() {
    if (disposed || gone) return;
    const saved = db.getFlashcards(setId);
    if (!saved || F.sameDeck(saved, deck)) return;
    swipe.cancel({ silent: true });
    generation++;
    deck = F.syncDeck(saved, set.cards, Date.now());
    stage.clear();
    showPhase({ arrival: 'none' });
    syncUrl();
    if (optionsModal) optionsModal.sync(optionState());
  }

  const unsubscribe = db.subscribe((evt) => {
    if (writing || disposed) return;
    const keys = evt && Array.isArray(evt.keys) ? evt.keys : null;
    if (!keys || keys.includes('sets')) reconcile();
    else if (evt.type === 'external' && keys.includes(`flashcards:${setId}`)) adoptStored();
  });

  // ------------------------------------------------------------- input
  const swipe = bindSwipe({
    surface: stage.el,
    wheelTarget: root,
    canStart: () => !disposed && !gone && phase() === 'card' && !!stage.current && !hasOpenModal(),
    onMove: (move) => {
      // A dialog opening mid-drag ends the swipe: the card goes back to the middle.
      if (hasOpenModal()) swipe.cancel();
      else stage.swipeTo(move);
    },
    onEnd: (verdict, offset) => {
      if (verdict && phase() === 'card') sort(verdict, { flung: true, releaseOffset: offset });
      else stage.swipeSettle(offset);
    },
    onCancel: (offset) => stage.swipeSettle(offset),
    onTap: () => flip(),
  });

  function onKeyAction(action) {
    if (action === 'flip') flip();
    else if (action === F.KNOW || action === F.STILL_LEARNING) sort(action);
    else if (action === 'undo') undo();
    else if (action === 'nextRound') nextRound();
    else if (action === 'restart') restart();
    else if (action === 'exit') exit();
    else if (action === 'add') addCards();
  }

  function onCommand(command) {
    const p = phase();
    if (command === 'options') openOptions();
    else if (command === 'restart') requestRestart();
    else if (p !== 'card') return;
    else if (command === 'speak') speakVisible();
    else if (command === 'star') toggleStar();
    else if (command === 'edit') editCard();
  }

  const unbindKeys = bindFlashcardKeys({ phase, isLocked: locked, onAction: onKeyAction, onCommand, apple });

  window.addEventListener('resize', scheduleLayout);
  const resizeObserver = typeof ResizeObserver === 'function' ? new ResizeObserver(scheduleLayout) : null;
  if (resizeObserver) resizeObserver.observe(main);

  // --------------------------------------------------------------- boot
  function boot() {
    indexCards();
    setTitle(`${set.title} – Karteikarten`);
    const subset = query.subset === 'starred' ? 'starred' : query.subset === 'all' ? 'all' : null;
    deck = F.startingDeck({
      cards: set.cards,
      saved: db.getFlashcards(setId),
      subset,
      forceNew: query.new === '1',
      shuffled: getPref(PREF.flashcardsShuffle, false) === true,
      now: Date.now(),
    });
    persist();
    syncUrl();
    updateChrome();
    measure();
    showPhase({ arrival: 'stack' });
    focusPrimary();
  }

  boot();

  return () => {
    disposed = true;
    clearTimeout(announceTimer);
    clearTimeout(summaryTimer);
    if (layoutFrame) cancelAnimationFrame(layoutFrame);
    layoutFrame = 0;
    window.removeEventListener('resize', scheduleLayout);
    if (resizeObserver) resizeObserver.disconnect();
    unbindKeys();
    unsubscribe();
    swipe.dispose();
    stage.dispose();
    stopSpeaking();
  };
}
