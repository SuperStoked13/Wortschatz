// Learn mode views besides the question cards: the progress sidebar (a compact
// sticky bar on phones) with the segmented progress bar, the counters Neu ·
// Am Lernen · Gemeistert and the key hints, the checkpoint after each round, the
// finish screen (with the best answer streak), the "everything mastered" screen,
// the one-time intro hint, the marks of a repetition question ("↺ Wiederholung",
// "Wieder am Lernen") and keeping a new step clear of the sticky bars.

import { h, replayClass } from '../lib/dom.js';
import { plural } from '../lib/labels.js';
import { button, iconButton, chip, kbd } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { termList, statTile, timeTile, confetti, missesChip, messageView, keyHints, studyKeyRows } from './write-views.js';
import { bestStreakText } from './answer-streak.js';
import { shortcutAria } from './write-keys.js';
import { isApplePlatform } from './editor-util.js';
import {
  checkpointStatus,
  checkpointTitle,
  finishSubtitle,
  finishTitle,
  masteredLine,
  progressText,
  remainingText,
  segmentFills,
  allMasteredText,
  reviewLine,
  REVIEW_LABEL,
  REVIEW_ARIA_LABEL,
  REVIEW_TOOLTIP,
  DEMOTED_TEXT,
  REVIEW_ALL_LABEL,
  REVIEW_ALL_TOOLTIP,
} from './learn-model.js';

const pct = (v) => `${Math.round(Math.max(0, Math.min(1, v || 0)) * 100)} %`;

function enterAnimation(el) {
  el.classList.add('wr-stage');
  return el;
}

/* ------------------------------------------------------ segmented progress */

// Quizlet-style progress bar: one pill per round-sized batch, filled from the
// left with the mastered (green) and learning (amber) share of the scope.
export function segmentedProgress({ size = 'md', label = 'Lernfortschritt' } = {}) {
  const el = h('div', {
    class: ['ln-progress', `ln-progress--${size}`],
    role: 'progressbar',
    'aria-label': label,
    'aria-valuemin': '0',
    'aria-valuemax': '100',
  });
  let segs = [];

  el.update = (counts, count = 1) => {
    const fills = segmentFills(counts, count);
    if (segs.length !== fills.length) {
      segs = fills.map(() => {
        const reached = h('span', { class: 'ln-progress__reached' });
        const mastered = h('span', { class: 'ln-progress__mastered' });
        return { el: h('span', { class: 'ln-progress__seg' }, reached, mastered), reached, mastered };
      });
      el.replaceChildren(...segs.map((s) => s.el));
    }
    fills.forEach((f, i) => {
      segs[i].reached.style.width = `${(f.reached * 100).toFixed(2)}%`;
      segs[i].mastered.style.width = `${(f.mastered * 100).toFixed(2)}%`;
    });
    const total = counts && counts.total > 0 ? counts.total : 0;
    el.setAttribute('aria-valuenow', String(total ? Math.round((counts.mastered / total) * 100) : 0));
    el.setAttribute('aria-valuetext', progressText(counts || {}));
    el.classList.toggle('is-complete', total > 0 && counts.mastered >= total);
  };
  return el;
}

/* ----------------------------------------------------------------- sidebar */

export function createLearnSidebar({ setId, title, onOptions, onRestart }) {
  const titleEl = h('span', { class: 'wr-side__title', dir: 'auto' }, title);
  const back = h(
    'a',
    { class: 'wr-side__back', href: `#/set/${setId}`, 'aria-label': `Zurück zum Lernset ${title}` },
    icon('arrowLeft', { size: 18 }),
    titleEl,
  );
  const roundEl = h('span', { class: 'wr-side__round' }, 'Runde 1');
  const mode = h('div', { class: 'wr-side__mode' }, h('span', { class: 'wr-side__mode-name' }, icon('sparkles', { size: 16 }), 'Lernen'), roundEl);

  const bar = segmentedProgress({ label: 'Lernfortschritt' });
  const progressValue = h('span', { class: 'wr-side__progress-value' }, '0/0');
  const progress = h(
    'div',
    { class: 'wr-side__progress ln-side__progress' },
    h('div', { class: 'wr-side__progress-head' }, h('span', null, 'Fortschritt'), progressValue),
    bar,
  );

  const stat = (key, label) => {
    const value = h('dd', { class: 'wr-stat__value' }, '0');
    const row = h(
      'div',
      { class: `wr-stat ln-stat ln-stat--${key}` },
      h('dt', { class: 'wr-stat__label' }, h('span', { class: 'wr-stat__dot', 'aria-hidden': 'true' }), label),
      value,
    );
    return { row, value };
  };
  const fresh = stat('new', 'Neu');
  const learning = stat('learning', 'Am Lernen');
  const mastered = stat('mastered', 'Gemeistert');
  const stats = h('dl', { class: 'wr-stats ln-stats' }, fresh.row, learning.row, mastered.row);

  const actions = h(
    'div',
    { class: 'wr-side__actions' },
    button({ label: 'Optionen', icon: 'sliders', variant: 'secondary', size: 'sm', block: true, onClick: onOptions }),
    button({ label: 'Neu starten', icon: 'rotate', variant: 'ghost', size: 'sm', block: true, onClick: onRestart }),
  );

  // The highest option key follows the multiple choice question on screen.
  const maxKey = kbd('4');
  const keys = keyHints([kbd('1'), '–', maxKey, ' Antwort wählen'], [kbd('Enter'), ' Antworten · Weiter'], ...studyKeyRows());
  keys.classList.add('ln-side__keys');

  const optIcon = iconButton({ icon: 'sliders', label: 'Optionen', onClick: onOptions, attrs: { class: 'wr-side__opt' } });

  const el = h('aside', { class: 'wr-side ln-side', 'aria-label': 'Fortschritt' }, back, mode, progress, stats, actions, keys, optIcon);

  // Numbers give a small bump whenever they change (not on first paint).
  const shown = new Map();
  function setNumber(valueEl, value) {
    if (shown.get(valueEl) === value) return;
    const first = !shown.has(valueEl);
    shown.set(valueEl, value);
    valueEl.textContent = String(value);
    if (!first) {
      valueEl.classList.remove('is-bumping');
      void valueEl.offsetWidth;
      valueEl.classList.add('is-bumping');
    }
  }
  for (const { value } of [fresh, learning, mastered]) {
    value.addEventListener('animationend', () => value.classList.remove('is-bumping'));
  }

  return {
    el,
    setTitle(text) {
      titleEl.textContent = text;
      back.setAttribute('aria-label', `Zurück zum Lernset ${text}`);
    },
    // counts: learn.counts(); segments: number of bar segments
    update({ counts, round, segments }) {
      if (!counts) return;
      roundEl.textContent = `Runde ${round}`;
      setNumber(fresh.value, counts.fresh);
      setNumber(learning.value, counts.learning);
      setNumber(mastered.value, counts.mastered);
      bar.update(counts, segments);
      progressValue.textContent = `${counts.mastered}/${counts.total}`;
      stats.setAttribute('aria-label', `Runde ${round}: ${progressText(counts)}`);
    },
    // n: options of the multiple choice question on screen
    setChoiceCount(n) {
      maxKey.textContent = String(Math.max(2, Math.min(4, Number(n) || 4)));
    },
  };
}

/* ---------------------------------------------------------------- scrolling */

const REVEAL_GAP = 12; // px between the sticky bars and a step scrolled back into view

// How far down the viewport the sticky app header reaches, and `bar` (the Learn
// sidebar) when it sits above `beside` (phones); next to it (desktop) it covers nothing.
function coveredTop(bar, beside) {
  const header = document.querySelector('.app-header');
  let top = header ? Math.max(0, header.getBoundingClientRect().bottom) : 0;
  const r = bar.getBoundingClientRect();
  if (r.height > 0 && r.right > beside.getBoundingClientRect().left + 1) top = Math.max(top, r.bottom);
  return top;
}

// Scrolls back just enough when the top of `target` hides under the sticky bars
// (e.g. the learner scrolled down to the options on a short screen).
export function revealBelowBars(target, { bar, beside }) {
  const covered = coveredTop(bar, beside);
  const top = target.getBoundingClientRect().top;
  if (top >= covered) return;
  window.scrollTo({ top: Math.max(0, window.scrollY + top - covered - REVEAL_GAP), behavior: 'auto' });
}

/* -------------------------------------------------------------- intro hint */

const HINT_KEY = 'wortschatz:v1:hint:learn';
let hintGone = false; // remembered for this page even when storage is unavailable

export function introHintDismissed() {
  if (hintGone) return true;
  try {
    return globalThis.localStorage.getItem(HINT_KEY) === '1';
  } catch {
    return false;
  }
}

export function dismissIntroHint() {
  hintGone = true;
  try {
    globalThis.localStorage.setItem(HINT_KEY, '1');
  } catch {
    /* private mode or blocked storage: the hint stays hidden for this page */
  }
}

export function introHint({ onDismiss }) {
  const el = h(
    'div',
    { class: 'ln-hint', role: 'note' },
    h('span', { class: 'ln-hint__icon', 'aria-hidden': 'true' }, icon('sparkles', { size: 18 })),
    h('p', { class: 'ln-hint__text' }, 'Neue Begriffe kommen zuerst als Multiple Choice – beim nächsten Mal schreibst du sie.'),
    iconButton({ icon: 'x', label: 'Hinweis schliessen', size: 'sm', onClick: () => onDismiss(), attrs: { class: 'ln-hint__close' } }),
  );
  return el;
}

/* ---------------------------------------------------- repetition questions */

// Mouse presses on a mark must not take the focus from the answer field (a tap
// still opens its tooltip: the tooltips listen to pointerup on touch).
function keepFocus(el) {
  el.addEventListener('mousedown', (e) => e.preventDefault());
  return el;
}

// "↺ Wiederholung" in the colour of "Gemeistert": a card mastered before the
// session is asked again. The tooltip explains what a miss means.
export function reviewChip() {
  const el = chip({ label: REVIEW_LABEL, tone: 'success', icon: 'rotate', size: 'sm' });
  el.classList.add('ln-review-chip');
  el.setAttribute('role', 'img');
  el.setAttribute('aria-label', REVIEW_ARIA_LABEL);
  el.setAttribute('data-tooltip', REVIEW_TOOLTIP);
  return keepFocus(el);
}

// Puts the chip next to the prompt's language label of a question card (the
// written card of write-card.js or the multiple choice card): both share the
// '.wr-q__head > .wr-q__lang' head. Returns { set(on) }; a card without that
// head gets a no-op.
export function attachReviewMark(cardEl) {
  const lang = cardEl && cardEl.querySelector ? cardEl.querySelector('.wr-q__head > .wr-q__lang') : null;
  if (!lang || !lang.parentNode) return { set() {} };
  const mark = reviewChip();
  mark.hidden = true;
  // The label and the chip stay together on the left (the head spreads its items apart).
  const row = h('span', { class: 'ui-row ln-q__label' });
  lang.parentNode.insertBefore(row, lang);
  row.append(lang, mark);
  return {
    set(on) {
      const show = !!on;
      if (show === !mark.hidden) return;
      mark.hidden = !show;
      if (show) replayClass(mark, 'ui-anim-fade-in');
    },
  };
}

// "Wieder am Lernen" after a missed repetition question, in the colour of "Am Lernen".
export function demotedChip() {
  const el = chip({ label: DEMOTED_TEXT, tone: 'warning', icon: 'rotate', size: 'sm' });
  el.classList.add('ln-demoted-chip');
  return el;
}

// Adds the chip to the "Nicht ganz" head of the written card (write-card.js
// rebuilds that head on every showIncorrect, so this runs after each one).
export function markDemoted(cardEl) {
  const head = cardEl && cardEl.querySelector ? cardEl.querySelector('.wr-fb__head') : null;
  if (!head || head.querySelector('.ln-demoted-chip')) return;
  head.append(demotedChip());
}

/* -------------------------------------------------------------- checkpoint */

function resultDots(results) {
  const spoken = results.map((ok) => (ok ? 'richtig' : 'falsch')).join(', ');
  return h(
    'span',
    { class: 'ln-dots', role: 'img', 'aria-label': `Antworten: ${spoken}` },
    results.map((ok) => h('span', { class: ['ln-dots__dot', ok ? 'is-ok' : 'is-bad'] })),
  );
}

function statusChip(stage) {
  const s = checkpointStatus(stage);
  return chip({ label: s.label, tone: s.tone, icon: s.icon, size: 'sm' });
}

/**
 * cp: learn.checkpoint(); rows: termList rows ({ cardId, stage, results, term, … });
 * from: counts before the round (the bar grows from there); segments: bar segments
 */
export function checkpointView({ cp, rows, from = null, segments = 1, onNext, onBack }) {
  const ratio = cp.answered ? cp.correct / cp.answered : 0;
  const counts = { ...cp.counts };
  const bar = segmentedProgress({ size: 'lg', label: 'Gesamtfortschritt' });
  bar.update(from || counts, segments);
  if (from) {
    // Let the bar grow from the state before the round.
    requestAnimationFrame(() => requestAnimationFrame(() => bar.update(counts, segments)));
  }

  const next = button({
    label: `Weiter zu Runde ${cp.round + 1}`,
    variant: 'primary',
    size: 'lg',
    iconRight: 'arrowRight',
    kbd: 'Enter',
    onClick: onNext,
    attrs: { class: 'wr-primary', 'data-primary': 'true' },
  });

  const legendItem = (key, label, value) =>
    h(
      'li',
      { class: `ln-legend__item ln-legend__item--${key}` },
      h('span', { class: `ui-dot ui-dot--${key}`, 'aria-hidden': 'true' }),
      h('span', null, label),
      h('strong', null, String(value)),
    );

  const view = h(
    'section',
    { class: 'ln-cp', 'aria-labelledby': 'ln-cp-title' },
    h(
      'div',
      { class: 'ln-cp__hero' },
      h('p', { class: 'wr-eyebrow' }, `Runde ${cp.round} geschafft`),
      h('h1', { class: 'ln-cp__title', id: 'ln-cp-title' }, checkpointTitle(ratio)),
      h(
        'div',
        { class: 'ln-cp__progress' },
        h('div', { class: 'ln-cp__progress-head' }, h('span', { class: 'ln-cp__mastered' }, masteredLine(counts.mastered, counts.total)), h('span', { class: 'ln-cp__pct' }, pct(counts.total ? counts.mastered / counts.total : 0))),
        bar,
        h(
          'ul',
          { class: 'ln-legend' },
          legendItem('new', 'Neu', counts.fresh),
          legendItem('learning', 'Am Lernen', counts.learning),
          legendItem('mastered', 'Gemeistert', counts.mastered),
        ),
      ),
      h('p', { class: 'ln-cp__text' }, `${plural(cp.correct, 'richtige Antwort', 'richtige Antworten')} von ${cp.answered} in dieser Runde. ${remainingText(counts)}`),
      h('div', { class: 'ln-cp__actions' }, next, button({ label: 'Zurück zum Lernset', variant: 'ghost', onClick: onBack, attrs: { 'data-leaves': 'true' } })),
    ),
    rows.length
      ? h(
          'div',
          { class: 'wr-group' },
          h('h2', { class: 'wr-group__title' }, 'In dieser Runde', h('span', { class: 'wr-group__count' }, String(rows.length))),
          termList(
            rows.map((row) => ({ ...row, trailing: h('span', { class: 'ln-cp__status' }, resultDots(row.results), statusChip(row.stage)) })),
            { markers: false },
          ),
        )
      : null,
  );
  return enterAnimation(view);
}

/* ------------------------------------------------------------------ finish */

// The "↺ Wiederholung" chip leading the finish screen's review line (decorative there).
function finishReviewChip() {
  const el = chip({ label: REVIEW_LABEL, tone: 'success', icon: 'rotate', size: 'sm' });
  el.setAttribute('aria-hidden', 'true');
  return el;
}

// "Beste Serie: 12 richtig in Folge" with the flame, from three in a row on.
function bestStreakLine(best) {
  const text = bestStreakText(best);
  if (!text) return null;
  return h(
    'p',
    { class: 'ln-fin__streak' },
    h('span', { class: 'ln-fin__flame', 'aria-hidden': 'true' }, icon('flameFilled', { size: 18 })),
    h('span', null, text),
  );
}

/**
 * stats: learn.finalStats(); subset: the session's scope; hardestRows: termList rows with `misses`;
 * review: learn.reviewStats() (null without repetition questions);
 * bestStreak: the most correct answers in a row during this visit of the screen
 */
export function finishView({ stats, subset = 'all', hardestRows, review = null, bestStreak = 0, onRestart, onWrite, onBack }) {
  const repeated = reviewLine(review);
  const view = h(
    'section',
    { class: 'wr-res ln-fin', 'aria-labelledby': 'ln-fin-title' },
    h(
      'div',
      { class: 'wr-res__hero' },
      h('div', { class: 'wr-res__badge-wrap' }, confetti(), h('div', { class: 'wr-res__badge', 'aria-hidden': 'true' }, icon('trophy', { size: 40, strokeWidth: 1.6 }))),
      h('h1', { class: 'wr-res__title ln-fin__title', id: 'ln-fin-title' }, finishTitle(subset, stats.total)),
      h('p', { class: 'wr-res__text' }, finishSubtitle(stats, subset)),
      bestStreakLine(bestStreak),
      // "12 gemeisterte Begriffe wiederholt, 2 davon sind wieder am Lernen."
      repeated ? h('p', { class: 'wr-res__text ln-fin__review' }, finishReviewChip(), ' ', repeated) : null,
    ),
    h(
      'div',
      { class: 'wr-tiles ln-tiles-stats' },
      statTile(String(stats.total), stats.total === 1 ? 'Begriff' : 'Begriffe', 'layers'),
      statTile(String(stats.rounds), stats.rounds === 1 ? 'Runde' : 'Runden', 'repeat'),
      statTile(String(stats.answered), stats.answered === 1 ? 'Antwort' : 'Antworten', 'list'),
      statTile(pct(stats.accuracy), 'Treffer', 'target', `Treffer: ${pct(stats.accuracy)} der Antworten richtig`),
      timeTile(stats.elapsedMs),
    ),
    // Enter: «Fertig» (back to the set, like the Mac app and Write's results); «Nochmal
    // lernen» resets the progress and is Ctrl+Shift+R. data-leaves: Enter on it moves to
    // another screen (learn.js holds Enter back there).
    h(
      'div',
      { class: 'wr-res__actions' },
      button({
        label: 'Fertig',
        variant: 'primary',
        size: 'lg',
        icon: 'check',
        kbd: 'Enter',
        onClick: onBack,
        attrs: { class: 'wr-primary', 'data-primary': 'true', 'data-leaves': 'true' },
      }),
      button({
        label: 'Nochmal lernen',
        variant: 'secondary',
        size: 'lg',
        icon: 'rotate',
        onClick: onRestart,
        attrs: { 'aria-keyshortcuts': shortcutAria('restart', isApplePlatform()) },
      }),
      button({ label: 'Schreiben üben', variant: 'secondary', size: 'lg', icon: 'keyboard', onClick: onWrite, attrs: { 'data-leaves': 'true' } }),
    ),
    hardestRows.length
      ? h(
          'div',
          { class: 'wr-group' },
          h('h2', { class: 'wr-group__title' }, 'Am häufigsten falsch', h('span', { class: 'wr-group__count' }, String(hardestRows.length))),
          termList(
            hardestRows.map((row) => ({ ...row, trailing: missesChip(row.misses) })),
            { markers: false },
          ),
        )
      : h('p', { class: 'wr-res__flawless' }, icon('sparkles', { size: 18 }), 'Kein einziger Fehler – beeindruckend!'),
  );
  return enterAnimation(view);
}

/* ------------------------------------------------- everything mastered */

// onReview: "Alle wiederholen" (a session that asks every mastered card once).
export function allMasteredView({ subset, count, onReset, onReview, onWrite, onBack }) {
  return messageView({
    icon: 'trophy',
    title: 'Alles gemeistert!',
    text: allMasteredText(subset, count),
    actions: [
      button({ label: 'Fortschritt zurücksetzen und neu lernen', variant: 'primary', icon: 'rotate', onClick: onReset, attrs: { 'data-primary': 'true' } }),
      button({ label: REVIEW_ALL_LABEL, variant: 'secondary', icon: 'repeat', onClick: onReview, attrs: { 'data-tooltip': REVIEW_ALL_TOOLTIP } }),
      button({ label: 'Schreiben üben', variant: 'secondary', icon: 'keyboard', onClick: onWrite, attrs: { 'data-leaves': 'true' } }),
      button({ label: 'Zurück zum Lernset', variant: 'ghost', onClick: onBack, attrs: { 'data-leaves': 'true' } }),
    ],
  });
}
