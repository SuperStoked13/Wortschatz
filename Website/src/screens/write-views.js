// Write mode views besides the question card: the progress sidebar (a compact
// sticky bar on phones) with its key hints, the round summary, the results screen
// and simple message states (empty subset, missing set). The term list, stat
// tiles, confetti, key hints and the answer-streak flame are shared with Learn mode.

import { h, prefersReducedMotion, replayClass } from '../lib/dom.js';
import { LANGS, plural } from '../lib/labels.js';
import { formatDuration } from '../lib/time.js';
import { compactDuration } from './write-model.js';
import { shortcutText, shortcutAria } from './write-keys.js';
import { streakVisible, streakLabel } from './answer-streak.js';
import { isApplePlatform } from './editor-util.js';
import { button, iconButton, progressBar, masteryBar, ring, chip, kbd, emptyState } from '../ui/components.js';
import { icon } from '../ui/icons.js';

const bcp47 = (lang) => (LANGS[lang] && LANGS[lang].bcp47) || null;
const pct = (v) => `${Math.round(Math.max(0, Math.min(1, v || 0)) * 100)} %`;

/* ----------------------------------------------------------------- sidebar */

export function createSidebar({ setId, title, onOptions, onRestart }) {
  const titleEl = h('span', { class: 'wr-side__title' }, title);
  const back = h(
    'a',
    { class: 'wr-side__back', href: `#/set/${setId}`, 'aria-label': `Zurück zum Lernset ${title}` },
    icon('arrowLeft', { size: 18 }),
    titleEl,
  );
  const roundEl = h('span', { class: 'wr-side__round' }, 'Runde 1');
  const mode = h('div', { class: 'wr-side__mode' }, h('span', { class: 'wr-side__mode-name' }, icon('keyboard', { size: 16 }), 'Schreiben'), roundEl);

  const stat = (key, label) => {
    const value = h('dd', { class: 'wr-stat__value' }, '0');
    const row = h('div', { class: `wr-stat wr-stat--${key}` }, h('dt', { class: 'wr-stat__label' }, h('span', { class: 'wr-stat__dot', 'aria-hidden': 'true' }), label), value);
    return { row, value };
  };
  const remaining = stat('remaining', 'Verbleibend');
  const wrong = stat('wrong', 'Falsch');
  const right = stat('right', 'Richtig');
  const stats = h('dl', { class: 'wr-stats' }, remaining.row, wrong.row, right.row);

  const bar = progressBar({ value: 0, label: 'Fortschritt der Lernrunde', size: 'sm' });
  const progressText = h('span', { class: 'wr-side__progress-value' }, '0/0');
  const progress = h('div', { class: 'wr-side__progress' }, h('div', { class: 'wr-side__progress-head' }, h('span', null, 'Fortschritt'), progressText), bar);

  const actions = h(
    'div',
    { class: 'wr-side__actions' },
    button({ label: 'Optionen', icon: 'sliders', variant: 'secondary', size: 'sm', block: true, onClick: onOptions }),
    button({ label: 'Neu starten', icon: 'rotate', variant: 'ghost', size: 'sm', block: true, onClick: onRestart }),
  );

  const mastery = masteryBar({ size: 'sm' });
  const masteryText = h('span', { class: 'wr-side__mastery-text' });
  const masteryBox = h(
    'div',
    { class: 'wr-side__mastery' },
    h('div', { class: 'wr-side__progress-head' }, h('span', null, 'Lernset'), masteryText),
    mastery,
  );

  const keys = keyHints([kbd('Enter'), ' Antworten · Weiter'], ...studyKeyRows());

  const optIcon = iconButton({ icon: 'sliders', label: 'Optionen', onClick: onOptions, attrs: { class: 'wr-side__opt' } });

  const el = h('aside', { class: 'wr-side', 'aria-label': 'Fortschritt' }, back, mode, stats, progress, actions, masteryBox, keys, optIcon);

  // Numbers give a small bump whenever they change (not on first paint).
  const shown = new Map();
  function setNumber(valueEl, n) {
    if (shown.get(valueEl) === n) return;
    const first = !shown.has(valueEl);
    shown.set(valueEl, n);
    valueEl.textContent = String(n);
    if (!first) {
      valueEl.classList.remove('is-bumping');
      void valueEl.offsetWidth;
      valueEl.classList.add('is-bumping');
    }
  }
  for (const { value } of [remaining, wrong, right]) {
    value.addEventListener('animationend', () => value.classList.remove('is-bumping'));
  }

  return {
    el,
    setTitle(text) {
      titleEl.textContent = text;
      back.setAttribute('aria-label', `Zurück zum Lernset ${text}`);
    },
    update({ counters, setStats }) {
      if (counters) {
        roundEl.textContent = `Runde ${counters.round}`;
        setNumber(remaining.value, counters.remaining);
        setNumber(wrong.value, counters.incorrect);
        setNumber(right.value, counters.correct);
        bar.update(counters.progress);
        progressText.textContent = `${counters.correct}/${counters.total}`;
        stats.setAttribute(
          'aria-label',
          `Runde ${counters.round}: ${counters.remaining} verbleibend, ${counters.incorrect} falsch, ${counters.correct} von ${counters.total} richtig`,
        );
      }
      if (setStats) {
        mastery.update(setStats);
        masteryText.textContent = `${setStats.mastered}/${setStats.total} gemeistert`;
      }
    },
  };
}

/* ------------------------------------------------------------- key hints */

// The sidebar's key hints, one row each: [content…] (kbd elements and text).
export function keyHints(...rows) {
  return h(
    'div',
    { class: 'wr-side__keys', 'aria-hidden': 'true' },
    rows.map((row) => h('span', { class: 'wr-side__key' }, row)),
  );
}

// The study shortcuts both sidebars list (⌥ ⌘ on Apple, Alt / Strg elsewhere).
export function studyKeyRows(apple = isApplePlatform()) {
  return [
    [kbd(shortcutText('dontKnow', apple)), ' Weiss ich nicht'],
    [kbd(shortcutText('options', apple)), ' Optionen'],
    [kbd(shortcutText('exit', apple)), ' Beenden'],
  ];
}

/* ----------------------------------------------------------- answer streak */

// The flame with the number of correct answers in a row, next to the question's tools (the
// head of both question cards is built once and never rebuilt, so it survives every step).
// Hidden below three in a row; it pops when the number grows, stronger at a milestone, where
// the flame also bounces. Returns { el, set(count, { milestone }) }; a card without the head
// gets a no-op.
export function attachStreakBadge(cardEl) {
  const tools = cardEl && cardEl.querySelector ? cardEl.querySelector('.wr-q__head .wr-q__tools') : null;
  if (!tools) return { el: null, set() {} };
  const flame = h('span', { class: 'wr-streak__flame', 'aria-hidden': 'true' }, icon('flameFilled', { size: 15 }));
  const number = h('span', { class: 'wr-streak__count', 'aria-hidden': 'true' }, '0');
  const el = h('span', { class: 'wr-streak', role: 'img', hidden: true }, flame, number);
  // A press on the badge (for its tooltip) must not take the focus from the answer field.
  el.addEventListener('mousedown', (e) => e.preventDefault());
  tools.prepend(el);

  let shown = 0;
  let leaveTimer = 0;
  const still = () => {
    el.classList.remove('is-entering', 'is-popping', 'is-leaving');
    flame.classList.remove('is-bouncing');
  };

  return {
    el,
    set(count, { milestone = false } = {}) {
      const n = Number.isInteger(count) && count > 0 ? count : 0;
      const grew = n > shown;
      shown = n;
      clearTimeout(leaveTimer);
      // Drawn off screen (the other card): no animation waits for it.
      const live = el.isConnected && !prefersReducedMotion();
      if (!streakVisible(n)) {
        if (el.hidden) return;
        if (!live) {
          still();
          el.hidden = true;
          return;
        }
        el.classList.remove('is-entering', 'is-popping');
        el.classList.add('is-leaving');
        leaveTimer = setTimeout(() => {
          el.hidden = true;
          still();
        }, 180);
        return;
      }
      number.textContent = String(n);
      el.setAttribute('aria-label', streakLabel(n));
      el.dataset.tooltip = streakLabel(n);
      el.classList.toggle('is-milestone', !!milestone);
      const appearing = el.hidden || el.classList.contains('is-leaving');
      el.classList.remove('is-leaving');
      el.hidden = false;
      if (!live) {
        still();
        return;
      }
      if (appearing) replayClass(el, 'is-entering');
      else if (grew) replayClass(el, 'is-popping');
      if (milestone && grew) replayClass(flame, 'is-bouncing');
    },
  };
}

/* ----------------------------------------------------------- shared lists */

// rows: [{ correct?, term, definition, termLang, defLang, trailing? }]
export function termList(rows, { markers = true } = {}) {
  return h(
    'ul',
    { class: ['wr-list', !markers && 'wr-list--plain'], role: 'list' },
    rows.map((row) =>
      h(
        'li',
        { class: ['wr-item', markers && (row.correct ? 'wr-item--right' : 'wr-item--wrong'), row.trailing && 'wr-item--trailing'] },
        markers
          ? h(
              'span',
              { class: 'wr-item__mark', role: 'img', 'aria-label': row.correct ? 'Richtig' : 'Falsch' },
              icon(row.correct ? 'check' : 'x', { size: 14, strokeWidth: 2.5 }),
            )
          : null,
        h('span', { class: 'wr-item__term', lang: bcp47(row.termLang) }, row.term),
        h('span', { class: 'wr-item__def', lang: bcp47(row.defLang) }, row.definition),
        row.trailing ? h('span', { class: 'wr-item__trailing' }, row.trailing) : null,
      ),
    ),
  );
}

function enterAnimation(el) {
  el.classList.add('wr-stage');
  return el;
}

/* ----------------------------------------------------------- round summary */

function summaryTitle(ratio) {
  if (ratio >= 0.9) return 'Hervorragend!';
  if (ratio >= 0.7) return 'Gut gemacht!';
  if (ratio >= 0.4) return 'Weiter so!';
  return 'Dranbleiben – das wird!';
}

// summary: session.roundSummary(); rows: termList rows in answer order
export function roundSummaryView({ summary, rows, onNext, onBack }) {
  const total = Math.max(1, summary.total);
  const ratio = summary.correct / total;
  const nextRound = summary.round + 1;
  const missed = rows.filter((r) => !r.correct);
  const hit = rows.filter((r) => r.correct);

  const next = button({
    label: `Weiter zu Runde ${nextRound}`,
    variant: 'primary',
    size: 'lg',
    iconRight: 'arrowRight',
    kbd: 'Enter',
    onClick: onNext,
    attrs: { class: 'wr-primary', 'data-primary': 'true' },
  });

  const view = h(
    'section',
    { class: 'wr-sum', 'aria-labelledby': 'wr-sum-title' },
    h(
      'div',
      { class: 'wr-sum__hero' },
      ring({ value: ratio, size: 132, label: pct(ratio), sublabel: 'richtig', tone: ratio >= 0.8 ? 'success' : 'accent' }),
      h(
        'div',
        { class: 'wr-sum__intro' },
        h('p', { class: 'wr-eyebrow' }, `Runde ${summary.round} geschafft`),
        h('h1', { class: 'wr-sum__title', id: 'wr-sum-title' }, summaryTitle(ratio)),
        h(
          'div',
          { class: 'wr-sum__counts' },
          chip({ label: `${summary.correct} richtig`, tone: 'success', icon: 'check' }),
          chip({ label: `${summary.incorrect} falsch`, tone: 'danger', icon: 'x' }),
        ),
        h(
          'p',
          { class: 'wr-sum__text' },
          `In Runde ${nextRound} übst du nur ${summary.incorrect === 1 ? 'den Begriff, der' : `die ${summary.incorrect} Begriffe, die`} noch nicht sass${summary.incorrect === 1 ? '' : 'en'}.`,
        ),
      ),
    ),
    h('div', { class: 'wr-sum__actions' }, next, button({ label: 'Zurück zum Lernset', variant: 'ghost', onClick: onBack, attrs: { 'data-leaves': 'true' } })),
    missed.length
      ? h('div', { class: 'wr-group' }, h('h2', { class: 'wr-group__title' }, 'Noch üben', h('span', { class: 'wr-group__count' }, String(missed.length))), termList(missed))
      : null,
    hit.length
      ? h('div', { class: 'wr-group' }, h('h2', { class: 'wr-group__title' }, 'Richtig', h('span', { class: 'wr-group__count' }, String(hit.length))), termList(hit))
      : null,
  );
  return enterAnimation(view);
}

/* ------------------------------------------------------------------ results */

const CONFETTI_COLORS = ['var(--accent)', 'var(--success)', 'var(--warning)', 'var(--danger)', 'var(--info)', 'var(--star)'];

export function confetti() {
  if (prefersReducedMotion()) return null;
  const pieces = [];
  for (let i = 0; i < 46; i++) {
    const angle = (Math.PI * 2 * i) / 46 + Math.random() * 0.4;
    const dist = 90 + Math.random() * 150;
    const x = Math.cos(angle) * dist;
    const y = Math.sin(angle) * dist * 0.75 + 70 + Math.random() * 60;
    const wide = Math.random() > 0.5;
    pieces.push(
      h('i', {
        style: {
          '--x': `${x.toFixed(1)}px`,
          '--y': `${y.toFixed(1)}px`,
          '--r': `${Math.round(Math.random() * 720 - 360)}deg`,
          '--d': `${Math.round(Math.random() * 120)}ms`,
          '--w': wide ? '10px' : '6px',
          '--h': wide ? '5px' : '10px',
          '--c': CONFETTI_COLORS[i % CONFETTI_COLORS.length],
        },
      }),
    );
  }
  const box = h('div', { class: 'wr-confetti', 'aria-hidden': 'true' }, pieces);
  setTimeout(() => box.remove(), 2400);
  return box;
}

// spoken: text for screen readers instead of the visible value + label.
export function statTile(value, label, iconName, spoken = null) {
  const hidden = spoken ? 'true' : null;
  return h(
    'div',
    { class: 'wr-tile' },
    h('span', { class: 'wr-tile__icon', 'aria-hidden': 'true' }, icon(iconName, { size: 18 })),
    spoken ? h('span', { class: 'sr-only' }, spoken) : null,
    h('span', { class: 'wr-tile__value', 'aria-hidden': hidden }, value),
    h('span', { class: 'wr-tile__label', 'aria-hidden': hidden }, label),
  );
}

// '2:47' / 'Zeit (Min.)' fits one line next to the other tiles.
export function timeTile(ms) {
  const { value, label } = compactDuration(ms);
  return statTile(value, label, 'clock', `Zeit: ${formatDuration(ms)}`);
}

function resultsSubtitle({ cardCount, accuracy, both }) {
  const dir = both ? ' in beide Richtungen' : '';
  if (cardCount === 1) {
    return accuracy >= 1 ? `Beim ersten Versuch richtig${dir} – perfekt!` : `Du hast den Begriff${dir} richtig geschrieben.`;
  }
  const what = plural(cardCount, 'Begriff', 'Begriffe');
  if (accuracy >= 1) return `Alle ${what}${dir} beim ersten Versuch richtig – perfekt!`;
  return `Du hast alle ${what}${dir} richtig geschrieben.`;
}

/**
 * stats: session.finalStats(); hardestRows: termList rows with `misses`;
 * setStats: mastery.setProgress(); cardCount: unique cards; both: answerWith === 'both'
 * Enter: «Falsche nochmal üben» after misses, else «Fertig» (back to the set, like the Mac
 * app); «Nochmal von vorne» is Ctrl+Shift+R.
 */
export function resultsView({ stats, hardestRows, setStats, cardCount, both, onRetryMissed, onRestart, onBack }) {
  const hasMissed = stats.missedCardIds.length > 0 && typeof onRetryMissed === 'function';
  const retry = hasMissed
    ? button({
        label: 'Falsche nochmal üben',
        variant: 'primary',
        size: 'lg',
        icon: 'repeat',
        kbd: 'Enter',
        onClick: onRetryMissed,
        attrs: { class: 'wr-primary', 'data-primary': 'true' },
      })
    : null;
  // data-leaves: Enter on it moves to another screen (write.js holds Enter back there).
  const done = hasMissed
    ? null
    : button({
        label: 'Fertig',
        variant: 'primary',
        size: 'lg',
        icon: 'check',
        kbd: 'Enter',
        onClick: onBack,
        attrs: { class: 'wr-primary', 'data-primary': 'true', 'data-leaves': 'true' },
      });
  const restart = button({
    label: 'Nochmal von vorne',
    variant: 'secondary',
    size: 'lg',
    icon: 'rotate',
    onClick: onRestart,
    attrs: { 'aria-keyshortcuts': shortcutAria('restart', isApplePlatform()) },
  });

  const masteryEl = masteryBar({ ...setStats, showLegend: true });
  const view = h(
    'section',
    { class: 'wr-res', 'aria-labelledby': 'wr-res-title' },
    h(
      'div',
      { class: 'wr-res__hero' },
      h('div', { class: 'wr-res__badge-wrap' }, confetti(), h('div', { class: 'wr-res__badge', 'aria-hidden': 'true' }, icon('trophy', { size: 40, strokeWidth: 1.6 }))),
      h('h1', { class: 'wr-res__title', id: 'wr-res-title' }, 'Geschafft!'),
      h('p', { class: 'wr-res__text' }, resultsSubtitle({ cardCount, accuracy: stats.accuracy, both })),
    ),
    h(
      'div',
      { class: 'wr-tiles' },
      statTile(String(cardCount), cardCount === 1 ? 'Begriff' : 'Begriffe', 'layers'),
      statTile(pct(stats.accuracy), 'Beim ersten Versuch richtig', 'target'),
      statTile(String(stats.rounds), stats.rounds === 1 ? 'Runde' : 'Runden', 'repeat'),
      timeTile(stats.elapsedMs),
    ),
    h(
      'div',
      { class: 'wr-res__actions' },
      retry,
      done,
      restart,
      hasMissed ? button({ label: 'Zurück zum Lernset', variant: 'ghost', size: 'lg', onClick: onBack, attrs: { 'data-leaves': 'true' } }) : null,
    ),
    h(
      'div',
      { class: 'wr-res__mastery' },
      h(
        'div',
        { class: 'wr-res__mastery-head' },
        h('h2', { class: 'wr-group__title' }, 'Dein Lernset'),
        h('span', { class: 'wr-res__mastery-pct' }, `${setStats.percent} % gemeistert`),
      ),
      masteryEl,
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
      : h('p', { class: 'wr-res__flawless' }, icon('sparkles', { size: 18 }), 'Kein einziger Fehler in dieser Lernrunde.'),
  );
  return enterAnimation(view);
}

export function missesChip(misses) {
  return chip({ label: `${misses}× falsch`, tone: 'danger', size: 'sm' });
}

/* ----------------------------------------------------------------- messages */

export function messageView({ icon: iconName = 'layers', title, text, actions = [] }) {
  const view = h(
    'section',
    { class: 'wr-msg' },
    emptyState({
      icon: iconName,
      title,
      text,
      action: actions.length ? h('div', { class: 'wr-msg__actions' }, actions) : null,
    }),
  );
  return enterAnimation(view);
}

// Nothing to practise in the requested subset (or the set has no complete cards).
export function emptySubsetView({ subset, setId, onAll, onBack }) {
  const back = button({ label: 'Zurück zum Lernset', variant: 'ghost', onClick: onBack, attrs: { 'data-leaves': 'true' } });
  const all = button({ label: 'Alle Begriffe üben', variant: 'primary', icon: 'play', onClick: onAll, attrs: { 'data-primary': 'true' } });
  if (subset === 'starred') {
    return messageView({
      icon: 'star',
      title: 'Keine markierten Begriffe',
      text: 'Markiere schwierige Begriffe mit dem Stern, um sie gezielt zu üben.',
      actions: [all, back],
    });
  }
  if (subset === 'learning') {
    return messageView({
      icon: 'trophy',
      title: 'Alles gemeistert!',
      text: 'Du beherrschst bereits alle Begriffe in diesem Lernset. Übe trotzdem alle, damit sie frisch bleiben.',
      actions: [all, back],
    });
  }
  if (subset === 'missed' || (subset && typeof subset === 'object')) {
    return messageView({
      icon: 'checkCircle',
      title: 'Keine falschen Begriffe',
      text: 'Hier gibt es gerade nichts nachzuholen.',
      actions: [all, back],
    });
  }
  return messageView({
    icon: 'layers',
    title: 'Noch keine Begriffe zum Üben',
    text: 'Füge diesem Lernset Begriffe mit Übersetzung hinzu, dann kann es losgehen.',
    actions: [button({ label: 'Begriffe hinzufügen', variant: 'primary', icon: 'plus', href: `#/set/${setId}/edit`, attrs: { 'data-primary': 'true' } }), back],
  });
}

export function missingSetView() {
  return messageView({
    icon: 'search',
    title: 'Lernset nicht gefunden',
    text: 'Dieses Lernset gibt es nicht mehr. Vielleicht wurde es gelöscht.',
    actions: [button({ label: 'Zur Übersicht', variant: 'primary', icon: 'arrowLeft', href: '#/', attrs: { 'data-primary': 'true' } })],
  });
}
