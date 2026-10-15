// Prüfung › the exam sheet (port of the Mac's ExamSheetView and ExamToolbarStatus): every
// question on one page, numbered, each with its answer field (beside the prompt in wide
// columns, under it in narrow ones), the special characters of the focused answer's language
// floating above the bar, the bar with «X von N beantwortet» and «Abgeben», and the status
// (time left or taken, answered questions) for the screen's top bar. The keys (↵ next
// question, Strg+↵ hand in, Esc leave) are routed by exam.js through `fieldOf`/`focusNext`.

import { h, prefersReducedMotion } from '../lib/dom.js';
import { bcp47, textAttrs, fieldAttrs } from '../lib/labels.js';
import { charsFor, insertAtCaret } from '../lib/keyboard.js';
import { button, kbd } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { isApplePlatform } from './editor-util.js';
import { examDock, examPill } from './exam-setup.js';
import * as E from '../core/exam.js';
// Space kept free between a question scrolled into view and the sticky bars.
const REVEAL_GAP = 16;

// "Strg ↵" on Windows and Linux, "⌘↵" on a Mac.
export function submitKeyLabel() {
  return isApplePlatform() ? '⌘↵' : 'Strg ↵';
}

// Mouse and touch presses on the character keys must not take focus from the answer field.
function keepFocus(el) {
  el.addEventListener('mousedown', (e) => e.preventDefault());
  return el;
}

/**
 * The status in the screen's top bar: the clock and «X/N».
 * Returns { el, setClock(clockState), setAnswered(answered, total) }.
 */
export function statusView() {
  const time = h('span', { class: 'ex-clock__time' }, '0:00');
  const clock = h('span', { class: 'ex-clock', role: 'timer' }, icon('clock', { size: 16, strokeWidth: 2 }), time);
  const count = h('span', { class: 'ex-status__count' }, '0/0');
  const el = h('div', { class: 'ex-status' }, clock, count);
  let shownSeconds = null;
  let shownMode = null;
  return {
    el,
    setClock({ seconds, countdown, lastMinute }) {
      if (seconds === shownSeconds && countdown === shownMode) {
        clock.classList.toggle('is-warning', countdown && lastMinute);
        return;
      }
      shownSeconds = seconds;
      shownMode = countdown;
      time.textContent = E.clockText(seconds);
      clock.classList.toggle('is-warning', countdown && lastMinute);
      clock.setAttribute('aria-label', `${countdown ? 'Verbleibende Zeit' : 'Verstrichene Zeit'}: ${E.spokenTime(seconds)}`);
      clock.dataset.tooltip = countdown ? 'Verbleibende Zeit' : 'Ohne Zeitlimit: so lange läuft die Prüfung schon';
    },
    setAnswered(answered, total) {
      count.textContent = `${answered}/${total}`;
      count.setAttribute('aria-label', E.answeredTooltip(answered, total));
      count.dataset.tooltip = E.answeredTooltip(answered, total);
    },
  };
}

/**
 * model: { questions, termLang, defLang }
 * on: { input(number, text), submit() }
 * Returns { el, dock, fieldOf(target) -> number|null, focusFirst(), focusNext(number) -> bool,
 *   focusField(number), refreshOpen(answered) }.
 */
export function createSheet({ questions, termLang, defLang }, on) {
  const fields = new Map(); // number -> { row, input, badge, lang }
  const last = questions.length ? questions[questions.length - 1].number : 0;

  // ----------------------------------------------------------------- rows
  const rows = questions.map((q) => {
    const label = E.promptLabel(q, termLang, defLang);
    const promptId = `ex-prompt-${q.number}`;
    const input = h('input', {
      class: 'ex-q__input',
      type: 'text',
      id: `ex-answer-${q.number}`,
      autocomplete: 'off',
      autocorrect: 'off',
      autocapitalize: 'off',
      spellcheck: 'false',
      enterkeyhint: q.number === last ? 'done' : 'next',
      ...fieldAttrs(q.answerLang),
      placeholder: E.answerPlaceholder(q, termLang, defLang),
      'aria-label': `Antwort zu Frage ${q.number}`,
      'aria-describedby': promptId,
      dataset: { number: q.number },
    });
    const badge = h('span', { class: 'ex-q__num', 'aria-hidden': 'true' }, String(q.number));
    const row = h(
      'li',
      { class: 'ex-q', dataset: { number: q.number } },
      badge,
      h(
        'div',
        { class: 'ex-q__body' },
        h(
          'div',
          { class: 'ex-q__ask' },
          h('span', { class: 'ex-eyebrow ex-q__label', 'aria-hidden': 'true' }, label),
          h(
            'p',
            { class: 'ex-q__prompt', id: promptId },
            h('span', { class: 'sr-only' }, `Frage ${q.number}, ${label}: `),
            h('span', textAttrs(q.promptLang), q.prompt),
          ),
        ),
        h('div', { class: 'ex-q__field' }, input),
      ),
    );
    fields.set(q.number, { row, input, badge, lang: q.answerLang });
    input.addEventListener('input', () => {
      badge.classList.toggle('is-answered', E.hasText(input.value));
      on.input(q.number, input.value);
    });
    return row;
  });

  const intro = h(
    'div',
    { class: 'ex-intro' },
    h('p', { class: 'ex-intro__text' }, icon('list', { size: 16 }), h('span', null, E.introText(questions, termLang, defLang))),
    h(
      'p',
      { class: 'ex-intro__keys', 'aria-hidden': 'true' },
      kbd('↵'),
      h('span', null, 'nächste Frage'),
      kbd(submitKeyLabel()),
      h('span', null, 'abgeben'),
    ),
  );
  const list = h('ol', { class: 'ex-sheet', 'aria-label': 'Fragen' }, rows);

  // ------------------------------------------------- characters and bar
  const chars = h('div', { class: 'ex-chars', role: 'group', 'aria-label': 'Sonderzeichen einfügen', hidden: true });
  let charsLang = null;
  let focused = null; // number of the focused answer field
  let movingFocus = false; // focusField scrolls itself

  function renderChars(lang) {
    const list = lang ? charsFor(lang) : [];
    if (!list.length) {
      chars.hidden = true;
      charsLang = null;
      return;
    }
    if (lang !== charsLang || chars.hidden) {
      chars.replaceChildren(
        ...list.map((ch) =>
          keepFocus(
            h(
              'button',
              {
                type: 'button',
                class: 'ex-char',
                tabindex: '-1',
                lang: bcp47(lang),
                title: 'Mit Umschalttaste als Grossbuchstabe',
                onClick: (e) => {
                  const f = focused != null ? fields.get(focused) : null;
                  if (f) insertAtCaret(f.input, e.shiftKey ? ch.toUpperCase() : ch);
                },
              },
              ch,
            ),
          ),
        ),
      );
      chars.hidden = false;
      // Arrives softly (CSS), only when it appears or the language changes.
      chars.classList.remove('is-arriving');
      void chars.offsetWidth;
      chars.classList.add('is-arriving');
    }
    charsLang = lang;
  }

  const answeredText = h('span', { class: 'ex-pill__text ex-pill__count' });
  const progressFill = h('span', { class: 'ex-line__fill' });
  const progress = h('span', { class: 'ex-line', 'aria-hidden': 'true' }, progressFill);
  const submit = button({
    label: 'Abgeben',
    icon: 'check',
    variant: 'primary',
    kbd: submitKeyLabel(),
    onClick: () => on.submit(),
    attrs: { class: 'ex-submit', 'aria-keyshortcuts': isApplePlatform() ? 'Meta+Enter' : 'Control+Enter' },
  });
  const dock = examDock({
    above: h('div', { class: 'ex-dock__above' }, chars),
    leading: [examPill(answeredText, progress)],
    trailing: [submit],
    className: 'ex-dock--sheet',
  });

  const body = h('div', { class: 'ex-col' }, h('h1', { class: 'sr-only' }, 'Prüfung'), intro, list);
  const el = h('div', { class: 'ex-page ex-run ex-enter' }, body, dock);

  // --------------------------------------------------------------- focus
  function numberOf(target) {
    if (!target || !target.classList || !target.classList.contains('ex-q__input')) return null;
    const n = Number(target.dataset.number);
    return fields.has(n) ? n : null;
  }

  // Scrolls just enough to show `row` between the sticky top bar and the bar at the bottom.
  function reveal(row, smooth) {
    if (!row.isConnected) return;
    const top = document.querySelector('.ex-top');
    const topEdge = (top ? top.getBoundingClientRect().bottom : 0) + REVEAL_GAP;
    const bottomEdge = dock.getBoundingClientRect().top - REVEAL_GAP;
    const r = row.getBoundingClientRect();
    let delta = 0;
    if (r.top < topEdge) delta = r.top - topEdge;
    else if (r.bottom > bottomEdge) delta = Math.min(r.bottom - bottomEdge, r.top - topEdge);
    if (Math.abs(delta) < 1) return;
    window.scrollBy({ top: delta, behavior: smooth && !prefersReducedMotion() ? 'smooth' : 'auto' });
  }

  el.addEventListener('focusin', (e) => {
    const n = numberOf(e.target);
    if (n == null) return;
    focused = n;
    const f = fields.get(n);
    renderChars(f.lang);
    // Tab or a click may leave the field under one of the bars (after the characters
    // appeared, which makes the bottom bar taller).
    if (!movingFocus) requestAnimationFrame(() => reveal(f.row, true));
  });

  el.addEventListener('focusout', (e) => {
    if (numberOf(e.relatedTarget) != null) return; // the next field's focusin takes over
    focused = null;
    renderChars(null);
  });

  function focusField(n, { smooth = true } = {}) {
    const f = fields.get(n);
    if (!f) return false;
    movingFocus = true;
    try {
      f.input.focus({ preventScroll: true });
    } finally {
      movingFocus = false;
    }
    // Caret at the end (a field revisited with ↵ or Tab keeps what was typed).
    const len = f.input.value.length;
    try {
      f.input.setSelectionRange(len, len);
    } catch {
      /* not every input supports selection */
    }
    reveal(f.row, smooth);
    return true;
  }

  function refreshOpen(answered) {
    const total = questions.length;
    answeredText.textContent = E.answeredText(answered, total);
    const left = total ? Math.round((1 - answered / total) * 10000) / 100 : 100;
    progressFill.style.transform = `translateX(${left ? -left : 0}%)`;
  }

  refreshOpen(0);

  return {
    el,
    dock,
    fieldOf: numberOf,
    focusFirst() {
      if (questions.length) focusField(questions[0].number, { smooth: false });
    },
    // ↵: on to the next question (the last one keeps the keys).
    focusNext(number) {
      const i = questions.findIndex((q) => q.number === number);
      if (i < 0 || i >= questions.length - 1) return false;
      return focusField(questions[i + 1].number);
    },
    focusField,
    refreshOpen,
  };
}
