// Karteikarten views around the card (port of FlashcardsScreen / FlashcardsStage /
// FlashcardsOptionsPanel): the progress sidebar (a compact sticky bar on narrow windows, like
// Lernen), the action bar (↶ Zurück, ← «Lerne ich noch», → «Weiss ich», «Umdrehen ↵»; after a
// round «Weiter mit N Karten»; at the end «Lernen» and «Nochmal von vorne»), the summary after a
// round and at the end, the empty state and the options dialog.

import { h, replayClass } from '../lib/dom.js';
import { button, iconButton, progressBar, kbd, openModal, segmented, toggle } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import {
  KNOW,
  cardsLabel,
  deckStats,
  verdictTitle,
  nextRoundAction,
  roundDoneTitle,
  roundDoneText,
  finishedTitle,
  finishedText,
} from '../core/flashcards.js';
import { statTile, confetti, messageView } from './write-views.js';

let idCounter = 0;

// Shortcut texts as the platform writes them: ⌘K on Apple, «Strg+K» elsewhere.
export function shortcutText(key, { apple = false, shift = false } = {}) {
  if (apple) return `${shift ? '⇧' : ''}⌘${key}`;
  return `Strg+${shift ? 'Umschalt+' : ''}${key}`;
}

export const backspaceText = (apple) => (apple ? '⌫' : 'Rücktaste');

/* ----------------------------------------------------------------- sidebar */

export function createFlashcardsSidebar({ setId, title, apple = false, onOptions, onRestart }) {
  const titleEl = h('span', { class: 'wr-side__title', dir: 'auto' }, title);
  const back = h(
    'a',
    { class: 'wr-side__back', href: `#/set/${setId}`, 'aria-label': `Zurück zum Lernset ${title}` },
    icon('arrowLeft', { size: 18 }),
    titleEl,
  );
  const roundEl = h('span', { class: 'wr-side__round' }, 'Runde 1');
  const mode = h('div', { class: 'wr-side__mode' }, h('span', { class: 'wr-side__mode-name' }, icon('cards', { size: 16 }), 'Karteikarten'), roundEl);

  const bar = progressBar({ value: 0, label: 'Fortschritt der Runde', size: 'sm' });
  const progressValue = h('span', { class: 'wr-side__progress-value' }, '0 von 0');
  const progress = h(
    'div',
    { class: 'wr-side__progress fc-side__progress' },
    h('div', { class: 'wr-side__progress-head' }, h('span', null, 'Fortschritt'), progressValue),
    bar,
  );

  // Narrow windows: «Runde 2 · 3/12» in the compact bar.
  const compactRound = h('span', { class: 'fc-side__compact-round' }, 'Runde 1');
  const compactShown = h('span', { class: 'fc-side__compact-count' }, '0/0');
  const compact = h('p', { class: 'fc-side__compact', 'aria-hidden': 'true' }, compactRound, h('span', { class: 'fc-side__compact-dot' }, '·'), compactShown);

  // Over all rounds: how many cards are known («8 von 12 gewusst» on the set page).
  const known = progressBar({ value: 0, tone: 'success', label: 'Gewusst', size: 'sm' });
  const knownText = h('span', { class: 'wr-side__mastery-text' }, '0 von 0');
  const knownBox = h('div', { class: 'wr-side__mastery fc-side__known' }, h('div', { class: 'wr-side__progress-head' }, h('span', null, 'Gewusst'), knownText), known);

  const optionsBtn = button({
    label: 'Optionen',
    icon: 'sliders',
    variant: 'secondary',
    size: 'sm',
    block: true,
    onClick: onOptions,
    attrs: { 'data-tooltip': `Optionen (${shortcutText('K', { apple })})`, 'aria-keyshortcuts': apple ? 'Meta+K' : 'Control+K' },
  });
  const restartBtn = button({
    label: 'Neu starten',
    icon: 'rotate',
    variant: 'ghost',
    size: 'sm',
    block: true,
    onClick: onRestart,
    attrs: { 'data-tooltip': `Neu starten (${shortcutText('R', { apple, shift: true })})`, 'aria-keyshortcuts': apple ? 'Shift+Meta+R' : 'Control+Shift+R' },
  });
  const actions = h('div', { class: 'wr-side__actions' }, optionsBtn, restartBtn);

  const keys = h(
    'div',
    { class: 'wr-side__keys fc-side__keys', 'aria-hidden': 'true' },
    h('span', null, kbd('␣'), ' Umdrehen'),
    h('span', null, kbd('←'), ' Lerne ich noch'),
    h('span', null, kbd('→'), ' Weiss ich'),
    h('span', null, kbd(backspaceText(apple)), ' Letzte Karte zurück'),
  );

  const optIcon = iconButton({ icon: 'sliders', label: 'Optionen', onClick: onOptions, attrs: { class: 'wr-side__opt' } });

  const el = h('aside', { class: 'wr-side fc-side', 'aria-label': 'Fortschritt' }, back, mode, progress, compact, knownBox, actions, keys, optIcon);

  return {
    el,
    setTitle(text) {
      titleEl.textContent = text;
      back.setAttribute('aria-label', `Zurück zum Lernset ${text}`);
    },
    // st: core deckStats()
    update(st) {
      roundEl.textContent = `Runde ${st.round}`;
      compactRound.textContent = `Runde ${st.round}`;
      progressValue.textContent = `${st.shown} von ${st.roundSize}`;
      compactShown.textContent = `${st.shown}/${st.roundSize}`;
      bar.update(st.roundSize ? st.sorted / st.roundSize : 0);
      bar.setAttribute('aria-valuetext', `Runde ${st.round}, Karte ${st.shown} von ${st.roundSize} (${st.sorted} sortiert)`);
      known.update(st.total ? st.known / st.total : 0);
      known.setAttribute('aria-valuetext', `${st.known} von ${cardsLabel(st.total)} gewusst`);
      knownText.textContent = `${st.known} von ${st.total}`;
      optionsBtn.disabled = st.phase === 'empty';
      optIcon.disabled = st.phase === 'empty';
      restartBtn.disabled = !st.hasProgress;
    },
  };
}

/* -------------------------------------------------------------- action bar */

function sortButton(verdict, onSort) {
  const isKnow = verdict === KNOW;
  const title = verdictTitle(verdict);
  const arrow = isKnow ? '→' : '←';
  const key = h('kbd', { class: 'ui-kbd fc-sort__key', 'aria-hidden': 'true' }, arrow);
  const count = h('span', { class: 'fc-sort__count', 'aria-hidden': 'true' }, '0');
  const el = h(
    'button',
    {
      type: 'button',
      class: ['ui-btn', 'ui-btn--secondary', 'ui-btn--lg', 'fc-sort', `fc-sort--${isKnow ? 'know' : 'learning'}`],
      'aria-keyshortcuts': isKnow ? 'ArrowRight' : 'ArrowLeft',
      'data-tooltip': `${title} (${arrow})`,
    },
    isKnow ? null : key,
    h('span', { class: 'fc-sort__icon', 'aria-hidden': 'true' }, icon(isKnow ? 'check' : 'rotate', { size: 18, strokeWidth: 2.4 })),
    h('span', { class: 'fc-sort__label', 'aria-hidden': 'true' }, title),
    count,
    isKnow ? key : null,
  );
  el.addEventListener('click', () => onSort(verdict));
  count.addEventListener('animationend', () => count.classList.remove('is-bumping'));
  let shown = null;
  return {
    el,
    set(n) {
      if (shown === n) return;
      const first = shown === null;
      shown = n;
      count.textContent = String(n);
      el.setAttribute('aria-label', `${title}: ${cardsLabel(n)}`);
      if (!first) replayClass(count, 'is-bumping');
    },
  };
}

/**
 * handlers: onUndo(), onSort(verdict), onPrimary() (Umdrehen / Weiter / Nochmal von vorne),
 * onBack() (Zurück zum Lernset), onLearn() (Lernen at the end)
 */
export function createActionBar({ apple = false, onUndo, onSort, onPrimary, onBack, onLearn }) {
  const undo = button({
    icon: 'undo',
    variant: 'secondary',
    size: 'lg',
    onClick: onUndo,
    attrs: { class: 'fc-bar__undo', 'aria-label': 'Zurück', 'data-tooltip': `Letzte Karte zurückholen (${backspaceText(apple)})`, 'aria-keyshortcuts': 'Backspace' },
  });
  const learning = sortButton('stillLearning', onSort);
  const know = sortButton(KNOW, onSort);
  const back = button({ label: 'Zurück zum Lernset', variant: 'secondary', size: 'lg', kbd: 'Esc', onClick: onBack, attrs: { class: 'fc-bar__back', 'aria-keyshortcuts': 'Escape' } });
  const learn = button({
    label: 'Lernen',
    icon: 'sparkles',
    variant: 'secondary',
    size: 'lg',
    onClick: onLearn,
    attrs: { class: 'fc-bar__learn', 'data-tooltip': 'Die Begriffe jetzt abfragen, damit sie als gemeistert zählen' },
  });
  const primary = button({
    label: 'Umdrehen',
    variant: 'primary',
    size: 'lg',
    kbd: '↵',
    onClick: onPrimary,
    attrs: { class: 'wr-primary fc-bar__primary', 'data-primary': 'true', 'aria-keyshortcuts': 'Enter' },
  });
  const row = h('div', { class: 'fc-bar__row' }, undo, h('span', { class: 'fc-bar__spacer' }), learning.el, know.el, back, learn, primary);
  const el = h('div', { class: 'fc-bar' }, row);

  return {
    el,
    primary,
    // st: core deckStats(); deck: for the «Weiter mit N Karten» label
    update(st, deck) {
      const onCard = st.phase === 'card';
      el.hidden = st.phase === 'empty';
      // Another step: its buttons come in softly.
      if (el.dataset.phase && el.dataset.phase !== st.phase) replayClass(row, 'is-switching');
      el.dataset.phase = st.phase;
      learning.el.hidden = !onCard;
      know.el.hidden = !onCard;
      back.hidden = st.phase !== 'roundDone';
      learn.hidden = st.phase !== 'finished';
      undo.disabled = !st.canUndo;
      learning.set(st.learning);
      know.set(st.knownInRound);
      primary.setLabel(onCard ? 'Umdrehen' : st.phase === 'roundDone' ? nextRoundAction(deck) : 'Nochmal von vorne');
    },
  };
}

/* ----------------------------------------------------------------- summary */

function summaryTile(value, label, iconName, tone) {
  const tile = statTile(value, label, iconName);
  tile.classList.add('fc-tile', `fc-tile--${tone}`);
  return tile;
}

// After a round («Du machst Fortschritte!») and once every card is known («Super, du kennst alle
// 12 Karten!», with confetti). `arriving`: it fades in after the last card has started to leave.
export function summaryView(deck, { arriving = false } = {}) {
  const st = deckStats(deck);
  const finished = st.phase === 'finished';
  const titleId = `fc-sum-title-${++idCounter}`;
  const tiles = [summaryTile(String(st.known), 'Weiss ich', 'check', 'know')];
  if (!finished) tiles.push(summaryTile(String(st.learning), 'Lerne ich noch', 'rotate', 'learning'));
  tiles.push(summaryTile(String(deck.round), deck.round === 1 ? 'Runde' : 'Runden', 'repeat', 'rounds'));
  return h(
    'section',
    { class: ['fc-sum', finished && 'fc-sum--done', arriving && 'is-arriving'], 'aria-labelledby': titleId },
    h(
      'div',
      { class: 'fc-sum__badge-wrap' },
      finished ? confetti() : null,
      h('div', { class: 'fc-sum__badge', 'aria-hidden': 'true' }, icon(finished ? 'trophy' : 'cards', { size: 36, strokeWidth: 2 })),
    ),
    h('p', { class: 'wr-eyebrow fc-sum__eyebrow' }, finished ? 'Karteikarten' : `Runde ${deck.round} geschafft`),
    h('h1', { class: 'fc-sum__title', id: titleId }, finished ? finishedTitle(deck) : roundDoneTitle(deck)),
    h('p', { class: 'fc-sum__text' }, finished ? finishedText(deck) : roundDoneText(deck)),
    h('div', { class: 'wr-tiles fc-sum__tiles', style: { '--fc-tiles': String(tiles.length) } }, tiles),
  );
}

/* ------------------------------------------------------------------- empty */

export function emptyView({ onBack, onAdd }) {
  return messageView({
    icon: 'cards',
    title: 'Keine Karten zum Umdrehen',
    text: 'Dieses Lernset hat noch keine Begriffe. Füge welche hinzu, dann geht es los.',
    actions: [
      button({ label: 'Zurück zum Lernset', variant: 'secondary', kbd: 'Esc', onClick: onBack, attrs: { 'aria-keyshortcuts': 'Escape' } }),
      // Enter adds terms wherever the focus is (the Mac's Return button).
      button({ label: 'Begriffe hinzufügen', variant: 'primary', icon: 'plus', kbd: '↵', onClick: onAdd, attrs: { 'data-primary': 'true', 'aria-keyshortcuts': 'Enter' } }),
    ],
  });
}

/* ----------------------------------------------------------------- options */

const STARRED_HINT = {
  restart: 'Beginnt die Karteikarten mit den markierten Begriffen neu.',
  none: 'Markiere Begriffe mit dem Stern, um nur sie zu üben.',
};

/**
 * The options (Ctrl+K): «Vorderseite» and «Mischen» apply to every set and to the running deck;
 * «Nur markierte» starts the deck over. names: sideNames(termLang, defLang).
 * state: { front, shuffled, starredOnly, starredCount, canRestart }
 * handlers: onFront(value), onShuffle(on), onStarredOnly(on), onClose({ reason, restartAsked })
 * Returns the modal handle with sync(state) to show a changed deck.
 */
export function openFlashcardsOptions({ names, state, onFront, onShuffle, onStarredOnly, onClose }) {
  const n = ++idCounter;
  const frontLabelId = `fc-opt-front-${n}`;
  const front = segmented({
    options: [
      { value: 'term', label: names.term.label },
      { value: 'definition', label: names.definition.label },
    ],
    value: state.front === 'definition' ? 'definition' : 'term',
    block: true,
    ariaLabel: 'Vorderseite',
    onChange: (value) => onFront(value),
  });
  front.setAttribute('aria-labelledby', frontLabelId);
  const shuffle = toggle({ label: 'Mischen', description: 'Die Karten kommen in zufälliger Reihenfolge.', checked: !!state.shuffled, onChange: (on) => onShuffle(on) });
  const starred = toggle({ label: 'Nur markierte (0)', description: STARRED_HINT.restart, checked: !!state.starredOnly, onChange: (on) => onStarredOnly(on) });
  const starredLabel = starred.querySelector('.ui-toggle__label');
  const starredDesc = starred.querySelector('.ui-toggle__desc');

  function sync(next) {
    shuffle.setChecked(!!next.shuffled);
    starred.setChecked(!!next.starredOnly);
    const none = next.starredCount === 0 && !next.starredOnly;
    if (starredLabel) starredLabel.textContent = `Nur markierte (${next.starredCount})`;
    if (starredDesc) starredDesc.textContent = none ? STARRED_HINT.none : STARRED_HINT.restart;
    starred.setDisabled(none);
  }
  sync(state);

  const form = h(
    'div',
    { class: 'ui-so ui-so--compact fc-options' },
    h(
      'section',
      { class: 'ui-so__section' },
      h('div', { class: 'ui-so__heading' }, h('h3', { class: 'ui-so__title' }, 'Karten')),
      h('div', { class: 'ui-so__direction' }, h('span', { class: 'ui-so__label', id: frontLabelId }, 'Vorderseite'), front),
      h('div', { class: 'ui-list' }, shuffle),
    ),
    h(
      'section',
      { class: 'ui-so__section' },
      h('div', { class: 'ui-list' }, starred),
      h('p', { class: 'fc-options__note' }, 'Karteikarten zählen nicht für «Gemeistert». Dafür fragen dich Lernen und Schreiben ab.'),
    ),
  );

  let restartAsked = false;
  const modal = openModal({
    title: 'Optionen',
    content: form,
    className: 'wr-options fc-options-dialog',
    actions: [
      {
        label: 'Neu starten',
        icon: 'rotate',
        variant: 'ghost',
        disabled: !state.canRestart,
        onClick: () => {
          restartAsked = true;
        },
      },
      { label: 'Fertig', variant: 'primary', autofocus: true },
    ],
    onClose: (reason) => onClose({ reason, restartAsked }),
  });
  modal.sync = sync;
  return modal;
}
