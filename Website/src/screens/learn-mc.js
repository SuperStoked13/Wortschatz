// Learn mode multiple choice card: the prompt (same look as the Write card), four
// answer tiles in a 2 x 2 grid (one column on phones) with number badges for the
// keys 1–4, "Weiss ich nicht?" and the feedback: the chosen tile turns green (or
// red, with the right one green), the caption becomes the message and a "Weiter"
// button appears. While choosing, the letters typed (core/typeahead.js) fade the
// options they do not start, underline what they match and highlight the one they
// pick; a hint under the tiles says what Enter does, and «Auswählen» appears while
// an option is highlighted (by typing or the arrow keys). The card element is
// created once and reused for every multiple choice question.

import { h, replayClass, setTextAttrs } from '../lib/dom.js';
import { bcp47, textAttrs } from '../lib/labels.js';
import { canSpeak } from '../lib/speech.js';
import { button, iconButton, starButton, kbd } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { typeAhead, optionState, typingHint, correctionHint, TYPING_IDLE } from '../core/typeahead.js';
import { demotedChip } from './learn-views.js';

let uidCounter = 0;

const CAPTION = 'Wähle die richtige Antwort';
const LONG_CHOICE = 42; // characters; longer options use a smaller type size
const TYPED_SHOWN = 28; // characters of the typed letters in the hint (the end of them)

const speakable = (lang) => canSpeak() && !!bcp47(lang);

// Mouse presses on the card's tools must not take the focus from the options or «Weiter»
// (Enter would then press the tool again instead of choosing or going on), as in write-card.js.
function keepFocus(el) {
  el.addEventListener('mousedown', (e) => e.preventDefault());
  return el;
}

// The end of what was typed, when it is long (like the Mac's head truncation).
function typedTail(text) {
  const list = [...text];
  return list.length > TYPED_SHOWN ? `…${list.slice(-(TYPED_SHOWN - 1)).join('')}` : text;
}

/**
 * handlers: {
 *   onChoose(index), onDontKnow(), onContinue(), onEdit(), onToggleStar() -> boolean,
 *   onSpeak(text, lang), onSurfaceClick() — a click on the card outside its controls,
 *   onPick() — «Auswählen»: choose the highlighted option
 * }
 */
export function createMcCard(handlers) {
  const n = ++uidCounter;
  const promptId = `ln-prompt-${n}`;
  const captionId = `ln-caption-${n}`;

  let q = null; // question info (write-model questionInfo)
  let choices = [];
  let tiles = [];
  let phase = 'question';
  let pickBtn = null; // «Auswählen», shown while an option is highlighted

  // ---------------------------------------------------------------- prompt
  const langLabel = h('span', { class: 'wr-q__lang' });
  const speakPrompt = keepFocus(iconButton({ icon: 'volume', label: 'Vorlesen', size: 'sm', onClick: () => q && handlers.onSpeak(q.prompt, q.promptLang) }));
  const editBtn = keepFocus(iconButton({ icon: 'edit', label: 'Karte bearbeiten', size: 'sm', onClick: () => handlers.onEdit() }));
  const star = keepFocus(starButton({ size: 'sm', label: 'Markieren', labelActive: 'Markierung entfernen', onToggle: () => handlers.onToggleStar() }));
  const promptText = h('p', { class: 'wr-q__prompt', id: promptId });
  const promptBlock = h(
    'div',
    { class: 'wr-q ln-mc__q' },
    h('div', { class: 'wr-q__head' }, langLabel, h('div', { class: 'wr-q__tools' }, speakPrompt, editBtn, star)),
    promptText,
  );

  // ----------------------------------------------------------------- tiles
  const caption = h('p', { class: 'ln-mc__caption', id: captionId });
  const grid = h('div', {
    class: 'ln-tiles',
    role: 'group',
    tabindex: '-1',
    'aria-labelledby': captionId,
    'aria-describedby': promptId,
  });
  const actions = h('div', { class: 'wr-actions ln-mc__actions' });
  const timer = h('span', { class: 'wr-timer', 'aria-hidden': 'true' });

  // The typing hint under the tiles: ⌨ the letters, "↩ wählt «X»" / "Weiter tippen …" /
  // "Keine Antwort passt", how to correct. It opens and closes by its height, so the row
  // below glides instead of jumping. Screen readers hear the same through announcements.
  // The letters typed may be Arabic: their direction follows them.
  const taTyped = h('span', { class: 'ln-ta__typed', dir: 'auto' });
  const taKey = kbd('↩');
  taKey.classList.add('ln-ta__key');
  const taText = h('span', { class: 'ln-ta__text' });
  const taFix = h('span', { class: 'ln-ta__fix' });
  const taPill = h(
    'div',
    { class: 'ln-ta__pill' },
    h('span', { class: 'ln-ta__icon' }, icon('keyboard', { size: 16 })),
    taTyped,
    h('span', { class: 'ln-ta__what' }, taKey, taText),
    taFix,
  );
  const typing = h('div', { class: 'ln-ta', 'aria-hidden': 'true' }, h('div', { class: 'ln-ta__inner' }, taPill));

  const el = h(
    'section',
    { class: 'wr-card ln-mc', 'aria-label': 'Multiple Choice', dataset: { phase: 'question' } },
    promptBlock,
    caption,
    grid,
    typing,
    actions,
    timer,
  );

  el.addEventListener('click', (e) => {
    const t = e.target;
    if (t && t.closest && t.closest('.wr-q__tools, .wr-actions')) return;
    handlers.onSurfaceClick();
  });

  // ------------------------------------------------------------- helpers
  function setPhase(next) {
    phase = next;
    el.dataset.phase = next;
  }

  function stopTimer() {
    timer.classList.remove('is-running');
    timer.style.removeProperty('--wr-advance');
  }

  function fillPrompt() {
    langLabel.textContent = q.promptLabel;
    promptText.textContent = q.prompt;
    setTextAttrs(promptText, textAttrs(q.promptLang));
    promptText.classList.toggle('is-long', q.prompt.length > 60);
    promptText.classList.toggle('is-very-long', q.prompt.length > 140);
    speakPrompt.hidden = !speakable(q.promptLang);
    star.setStarred(!!q.starred);
  }

  function tileFor(choice, i) {
    return h(
      'button',
      {
        type: 'button',
        class: 'ln-tile',
        'aria-keyshortcuts': String(i + 1),
        dataset: { index: String(i) },
        onClick: () => handlers.onChoose(i),
      },
      h('span', { class: 'ln-tile__key', 'aria-hidden': 'true' }, String(i + 1)),
      h('span', { class: 'ln-tile__text', ...textAttrs(q.answerLang) }, choice.text),
      h('span', { class: 'ln-tile__note sr-only' }),
    );
  }

  function fillTiles() {
    tiles = choices.map(tileFor);
    grid.replaceChildren(...tiles);
    grid.classList.toggle('is-long', choices.some((c) => c.text.length > LONG_CHOICE));
    grid.classList.toggle('is-odd', choices.length % 2 === 1);
  }

  // The option's text with the typed part (range: [start, end) or null) underlined.
  function paintText(tile, i, range) {
    const textEl = tile.querySelector('.ln-tile__text');
    const text = choices[i] ? choices[i].text : '';
    const key = range && range[1] > range[0] ? `${range[0]}:${range[1]}` : '';
    if (textEl.dataset.typed === key) return;
    textEl.dataset.typed = key;
    if (!key) textEl.textContent = text;
    else textEl.replaceChildren(text.slice(0, range[0]), h('span', { class: 'ln-tile__typed' }, text.slice(range[0], range[1])), text.slice(range[1]));
  }

  function clearTyping() {
    typing.classList.remove('is-open');
    tiles.forEach((tile, i) => {
      tile.classList.remove('is-highlighted', 'is-filtered');
      paintText(tile, i, null);
    });
    if (pickBtn) pickBtn.hidden = true;
  }

  /**
   * The letters typed and the highlighted option (core/typeahead.js typingKey state).
   * lang: the options' language (their articles); apple: key names of the hint;
   * reject: Enter found nothing to choose (the hint shakes).
   */
  function setTyping(state, { lang = null, apple = false, reject = false } = {}) {
    if (phase !== 'question') return;
    const s = state || TYPING_IDLE;
    const texts = choices.map((c) => c.text);
    const match = typeAhead(s.typed, texts, lang);
    tiles.forEach((tile, i) => {
      const look = optionState(s, i, match);
      tile.classList.toggle('is-highlighted', look === 'highlighted');
      tile.classList.toggle('is-filtered', look === 'filtered');
      paintText(tile, i, (s.typed && match.ranges[i]) || null);
    });
    const active = !!s.typed && match.isActive;
    // Closing keeps the last content until the hint has folded away.
    if (active) {
      taTyped.textContent = typedTail(s.typed);
      taTyped.classList.toggle('is-none', !match.matching.length);
      const hint = typingHint(match, texts);
      taKey.hidden = hint.kind !== 'pick';
      taText.textContent = hint.text;
      taFix.textContent = correctionHint(apple);
    }
    typing.classList.toggle('is-open', active);
    if (pickBtn) pickBtn.hidden = s.highlighted == null;
    if (reject && active) replayClass(taPill, 'ui-anim-shake');
  }

  // Columns of the option grid as laid out now (one on phones), for the arrow keys.
  function columns() {
    if (typeof getComputedStyle !== 'function' || !grid.isConnected) return 2;
    const cols = getComputedStyle(grid).gridTemplateColumns;
    return cols && cols !== 'none' ? Math.max(1, cols.trim().split(/\s+/).length) : 2;
  }

  function setCaption(content, tone = null) {
    caption.className = ['ln-mc__caption', tone && `ln-mc__caption--${tone}`].filter(Boolean).join(' ');
    caption.replaceChildren(...content);
  }

  function focusGrid() {
    if (el.isConnected && document.activeElement !== grid) grid.focus({ preventScroll: true });
  }

  // ------------------------------------------------------------- phases
  function setQuestion(question, list, { animate = true } = {}) {
    q = question;
    choices = list.slice();
    setPhase('question');
    stopTimer();
    fillPrompt();
    setCaption([CAPTION]);
    fillTiles();
    typing.classList.remove('is-open');
    pickBtn = button({
      label: 'Auswählen',
      variant: 'primary',
      kbd: 'Enter',
      onClick: () => handlers.onPick(),
      attrs: { class: 'ln-pick', hidden: true },
    });
    actions.replaceChildren(
      h('span', { class: 'wr-hint ln-mc__keys' }, kbd('1'), '–', kbd(String(Math.max(2, choices.length))), h('span', { class: 'wr-hint__text' }, 'zum Auswählen')),
      h('span', { class: 'wr-actions__spacer' }),
      h(
        'button',
        { type: 'button', class: 'ln-dont', 'aria-keyshortcuts': 'Alt+Enter 0', onClick: () => handlers.onDontKnow() },
        'Weiss ich nicht?',
      ),
      pickBtn,
    );
    if (animate) {
      replayClass(promptBlock, 'is-swapping');
      replayClass(grid, 'is-entering');
    }
    focusGrid();
  }

  /**
   * correctIndex: the right option; chosenIndex: the learner's pick (null = "Weiss ich nicht").
   * message: caption text; autoAdvanceMs > 0 shows the countdown along the bottom edge.
   * demoted: a missed repetition question ("Wieder am Lernen" next to "Weiter", so the
   * tiles never move).
   */
  function showResult({ correctIndex, chosenIndex = null, message, autoAdvanceMs = 0, demoted = false }) {
    const correct = chosenIndex != null && chosenIndex === correctIndex;
    clearTyping();
    pickBtn = null;
    setPhase(correct ? 'correct' : 'incorrect');
    tiles.forEach((tile, i) => {
      const isRight = i === correctIndex;
      const isChosen = i === chosenIndex;
      tile.classList.toggle('is-correct', isRight);
      tile.classList.toggle('is-wrong', isChosen && !isRight);
      tile.classList.toggle('is-dim', !isRight && !isChosen);
      tile.setAttribute('aria-disabled', 'true');
      const key = tile.querySelector('.ln-tile__key');
      if (isRight || isChosen) key.replaceChildren(icon(isRight ? 'check' : 'x', { size: 16, strokeWidth: 2.75 }));
      tile.querySelector('.ln-tile__note').textContent = isRight ? ' – richtige Antwort' : isChosen ? ' – deine Antwort' : '';
    });
    if (chosenIndex != null && tiles[chosenIndex]) replayClass(tiles[chosenIndex], correct ? 'is-popping' : 'ui-anim-shake');
    else if (tiles[correctIndex]) replayClass(tiles[correctIndex], 'is-popping');

    const tone = correct ? 'ok' : chosenIndex == null ? 'calm' : 'bad';
    const iconName = correct ? 'checkCircle' : chosenIndex == null ? 'lightbulb' : 'xCircle';
    setCaption([icon(iconName, { size: 20, strokeWidth: 2 }), h('span', null, message)], tone);
    replayClass(caption, 'ui-anim-pop');

    const next = button({
      label: 'Weiter',
      variant: autoAdvanceMs ? 'secondary' : 'primary',
      iconRight: 'arrowRight',
      kbd: autoAdvanceMs ? null : 'Enter',
      onClick: () => handlers.onContinue(),
    });
    actions.replaceChildren(
      ...(demoted ? [demotedChip()] : []),
      h('span', { class: 'wr-hint wr-hint--solo' }, 'Weiter mit beliebiger Taste'),
      h('span', { class: 'wr-actions__spacer' }),
      next,
    );
    if (autoAdvanceMs > 0) {
      timer.style.setProperty('--wr-advance', `${autoAdvanceMs}ms`);
      timer.classList.remove('is-running');
      void timer.offsetWidth;
      timer.classList.add('is-running');
    } else {
      stopTimer();
    }
    if (el.isConnected) next.focus({ preventScroll: true });
  }

  // Updates prompt and option texts after a card was edited (keeps the phase).
  function refresh(question, list) {
    if (!question) return;
    q = question;
    fillPrompt();
    if (Array.isArray(list) && list.length === tiles.length) {
      choices = list.slice();
      tiles.forEach((tile, i) => {
        const textEl = tile.querySelector('.ln-tile__text');
        textEl.textContent = choices[i].text;
        textEl.dataset.typed = '';
      });
      grid.classList.toggle('is-long', choices.some((c) => c.text.length > LONG_CHOICE));
    }
  }

  // The step's main control: the option group while choosing, "Weiter" afterwards.
  function focusPrimary() {
    if (!el.isConnected) return;
    if (phase === 'question') {
      focusGrid();
      return;
    }
    const next = actions.querySelector('.ui-btn');
    if (next) next.focus({ preventScroll: true });
  }

  // Ctrl+R: read the prompt aloud (only where the speaker button shows).
  function pressSpeak() {
    if (q && !speakPrompt.hidden) handlers.onSpeak(q.prompt, q.promptLang);
  }

  // Ctrl+D: the star button's own click (pop included); returns the new state.
  function pressStar() {
    star.click();
    return star.getAttribute('aria-pressed') === 'true';
  }

  return {
    el,
    grid,
    setQuestion,
    showResult,
    setTyping,
    columns,
    refresh,
    focusPrimary,
    stopTimer,
    pressSpeak,
    pressStar,
    setStarred: (value) => star.setStarred(!!value),
    get phase() {
      return phase;
    },
    get count() {
      return tiles.length;
    },
  };
}
