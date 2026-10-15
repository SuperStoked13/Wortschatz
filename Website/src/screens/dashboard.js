// Dashboard (#/): greeting, study stats, "continue" banner (the latest Learn
// session, else the latest Write session) and the grid of sets with search and
// sort. Re-renders its data parts whenever the store changes.

import { h, prefersReducedMotion } from '../lib/dom.js';
import { icon } from '../ui/icons.js';
import {
  button,
  iconButton,
  chip,
  masteryBar,
  progressBar,
  segmented,
  menu,
  confirmDialog,
  toast,
  emptyState,
  hasOpenOverlay,
} from '../ui/components.js';
import { langName, langPair, plural, textAttrs } from '../lib/labels.js';
import { isComposingKey } from '../lib/shortcuts.js';
import { dateKey, relativeTime } from '../lib/time.js';
import { db } from '../store/db.js';
import { setToText, downloadText } from '../store/backup.js';
import { setProgress, studyStreak } from '../core/mastery.js';
import { counters } from '../core/session.js';
import {
  counts as learnCounts,
  checkpoint as learnCheckpoint,
  isRoundOver as learnRoundOver,
  isFinished as learnFinished,
  syncProgress as learnSync,
} from '../core/learn.js';
import { stripDiacritics } from '../core/text.js';
import { navigate } from '../router.js';
import { streakCaption, streakTone, streakTooltip } from '../ui/daily-streak.js';

const SORTS = [
  { value: 'recent', label: 'Zuletzt gelernt' },
  { value: 'name', label: 'Name' },
  { value: 'newest', label: 'Neueste' },
];

// Survives navigation within this visit (the search query deliberately does not).
const view = { sort: 'recent' };

const REFRESH_MS = 60 * 1000;
const MAX_STAGGER = 12;

let collator = null;
function compareTitles(a, b) {
  if (!collator) collator = new Intl.Collator('de-CH', { sensitivity: 'base', numeric: true });
  return collator.compare(a, b);
}

// Case-, accent- and sharp-s-insensitive form used for searching.
function fold(value) {
  return stripDiacritics(String(value == null ? '' : value).toLowerCase())
    .replace(/\s+/g, ' ')
    .trim();
}

function greetingFor(date) {
  const hour = date.getHours();
  if (hour >= 5 && hour < 11) return 'Guten Morgen';
  if (hour >= 11 && hour < 18) return 'Guten Tag';
  return 'Guten Abend';
}

function todayLabel(date) {
  try {
    return new Intl.DateTimeFormat('de-CH', { weekday: 'long', day: 'numeric', month: 'long' }).format(date);
  } catch {
    return '';
  }
}

// Answers over the last seven calendar days including today.
function weekTotal(activity, now) {
  const cursor = new Date(now);
  cursor.setHours(12, 0, 0, 0);
  let sum = 0;
  for (let i = 0; i < 7; i++) {
    const n = activity[dateKey(cursor.getTime())];
    if (typeof n === 'number' && n > 0) sum += n;
    cursor.setDate(cursor.getDate() - 1);
  }
  return sum;
}

function activeSession(setId) {
  let session = null;
  try {
    session = db.getSession(setId);
  } catch {
    session = null;
  }
  return session && !session.finishedAt ? session : null;
}

function sessionInfo(session) {
  try {
    return counters(session);
  } catch {
    const queue = Array.isArray(session.queue) ? session.queue.length : 0;
    return { round: Number(session.round) || 1, remaining: queue, total: 0, correct: 0, progress: 0 };
  }
}

function sessionLabel(info) {
  if (info.remaining === 0) return `Runde ${info.round} geschafft`;
  return `Runde ${info.round} · ${info.remaining} übrig`;
}

// The set's unfinished Learn session with its counts, or null. `progress` is the
// set's stored progress: answers given in Schreiben count for Learn too.
function activeLearn(setId, progress) {
  let stored = null;
  try {
    stored = db.getLearn(setId);
  } catch {
    stored = null;
  }
  if (!stored || stored.finishedAt != null) return null;
  try {
    const state = learnSync(stored, progress);
    const info = learnCounts(state);
    if (!(info.total > 0) || learnFinished(state)) return null;
    // A round without answers (only after removals) shows no checkpoint: it is not "geschafft".
    const roundOver = learnRoundOver(state) && learnCheckpoint(state).answered > 0;
    const round = Number.isInteger(state.round) && state.round > 0 ? state.round : 1;
    return { state, info, round, roundOver };
  } catch {
    return null;
  }
}

function learnRound(learn) {
  return learn.roundOver ? `Runde ${learn.round} geschafft` : `Runde ${learn.round}`;
}

const SUBSET_LABELS = { starred: 'Nur markierte', learning: 'Nur nicht gemeisterte', missed: 'Nur falsche' };
// The scope after the count on a set card: 'Runde 1 · 0/3 markierte'.
const SUBSET_NOUNS = { starred: 'markierte', learning: 'offene', missed: 'falsche' };

function learnScope(learn) {
  const subset = learn.state.subset;
  if (subset && typeof subset === 'object') return 'Ausgewählte Begriffe';
  return SUBSET_LABELS[subset] || null;
}

function learnScopeNoun(learn) {
  const subset = learn.state.subset;
  if (subset && typeof subset === 'object') return 'ausgewählte';
  return SUBSET_NOUNS[subset] || null;
}

const updatedAt = (state) => (state && typeof state.updatedAt === 'number' ? state.updatedAt : 0);

function loadData() {
  const now = Date.now();
  const sets = db.listSets();
  const activity = db.getActivity();
  const streak = studyStreak(activity, now);
  let mastered = 0;
  let total = 0;
  let resumeLearn = null;
  let resumeWrite = null;
  const items = sets.map((set, order) => {
    const stored = db.getProgress(set.id);
    const progress = setProgress(set, stored);
    mastered += progress.mastered;
    total += progress.total;
    const learn = activeLearn(set.id, stored);
    const session = activeSession(set.id);
    const info = session ? sessionInfo(session) : null;
    if (learn && (!resumeLearn || updatedAt(learn.state) > updatedAt(resumeLearn.learn.state))) {
      resumeLearn = { mode: 'learn', set, learn };
    }
    if (session && (!resumeWrite || updatedAt(session) > updatedAt(resumeWrite.session))) {
      resumeWrite = { mode: 'write', set, session, info };
    }
    return { set, progress, learn, session, info, order, index: null };
  });
  // "Weiterlernen" prefers the latest Learn session; a Write session is the fallback.
  const resume = resumeLearn || resumeWrite;
  return { now, items, streak, week: weekTotal(activity, now), mastered, total, resume };
}

// Folded search fields, built lazily once per data load.
function searchIndex(item) {
  if (!item.index) {
    const { set } = item;
    item.index = {
      title: fold(set.title),
      description: fold(set.description),
      cards: set.cards.map((c) => ({ card: c, text: `${fold(c.term)}\n${fold(c.definition)}` })),
    };
  }
  return item.index;
}

function matchItem(item, q) {
  const index = searchIndex(item);
  const inTitle = index.title.includes(q);
  const inDescription = index.description.includes(q);
  const cards = [];
  for (const entry of index.cards) if (entry.text.includes(q)) cards.push(entry.card);
  if (!inTitle && !inDescription && !cards.length) return null;
  return { inTitle, inDescription, cards };
}

function sortItems(items, sort) {
  const list = items.slice();
  if (sort === 'name') {
    list.sort((a, b) => compareTitles(a.set.title, b.set.title) || a.order - b.order);
  } else if (sort === 'newest') {
    list.sort((a, b) => (b.set.createdAt || 0) - (a.set.createdAt || 0) || a.order - b.order);
  }
  // 'recent' keeps the store order: most recently studied or edited first.
  return list;
}

// Wraps the first case-insensitive occurrence of `query` in <mark>.
function highlight(text, query) {
  const value = String(text == null ? '' : text);
  const needle = query.trim().toLowerCase();
  if (!needle) return value;
  const lower = value.toLowerCase();
  const at = lower.indexOf(needle);
  if (at < 0 || lower.length !== value.length) return value;
  return [value.slice(0, at), h('mark', { class: 'dash-mark' }, value.slice(at, at + needle.length)), value.slice(at + needle.length)];
}

function fileNameFor(title) {
  const base = String(title || '')
    .replace(/[\\/:*?"<>|\u0000-\u001f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 80);
  return `${base || 'Lernset'}.txt`;
}

function shortTitle(title, max = 40) {
  const t = String(title || '');
  return t.length > max ? `${t.slice(0, max - 1).trimEnd()}…` : t;
}

function capitalize(text) {
  return text ? text.charAt(0).toUpperCase() + text.slice(1) : '';
}

function errorMessage(err, fallback) {
  return (err && err.message) || fallback;
}

/* ------------------------------------------------------------- render */

export function render(outlet) {
  const state = { query: '', sort: view.sort, data: null, visible: [] };
  const cleanups = [];

  /* Greeting */
  const eyebrow = h('p', { class: 'dash-head__date ui-eyebrow' });
  const title = h('h1', { class: 'dash-head__title ui-h1' });
  const lead = h('p', { class: 'dash-head__lead ui-lead' });
  const newButton = button({ label: 'Neues Lernset', icon: 'plus', variant: 'primary', href: '#/new', attrs: { class: 'dash-head__new' } });
  const head = h('header', { class: 'dash-head' }, h('div', { class: 'dash-head__text' }, eyebrow, title, lead), newButton);

  /* Data hosts */
  const statsHost = h('section', { class: 'dash-stats-host', 'aria-label': 'Deine Statistik' });
  const resumeHost = h('div', { class: 'dash-resume-host' });

  /* Toolbar: title, search, sort */
  const countChip = h('span', { class: 'dash-toolbar__count' });
  const searchInput = h('input', {
    class: 'ui-input dash-search__input',
    type: 'search',
    placeholder: 'Lernsets durchsuchen',
    'aria-label': 'Lernsets und Begriffe durchsuchen',
    autocomplete: 'off',
    autocapitalize: 'off',
    spellcheck: 'false',
    dir: 'auto',
    enterkeyhint: 'search',
    onInput: () => {
      state.query = searchInput.value;
      syncSearchChrome();
      renderGrid();
    },
    onKeydown: onSearchKeydown,
  });
  const clearSearchBtn = h(
    'button',
    { type: 'button', class: 'dash-search__clear', 'aria-label': 'Suche löschen', hidden: true, onClick: () => clearSearch(true) },
    icon('x', { size: 16 }),
  );
  const slashHint = h('kbd', { class: 'ui-kbd dash-search__kbd', 'aria-hidden': 'true', title: 'Taste / zum Suchen' }, '/');
  const search = h(
    'div',
    { class: 'dash-search', role: 'search' },
    icon('search', { size: 18, className: 'dash-search__icon' }),
    searchInput,
    slashHint,
    clearSearchBtn,
  );
  const sortControl = segmented({
    options: SORTS,
    value: state.sort,
    ariaLabel: 'Sortieren nach',
    onChange: (value) => {
      state.sort = value;
      view.sort = value;
      renderGrid();
    },
  });
  sortControl.classList.add('dash-sort');
  const toolbar = h(
    'div',
    { class: 'dash-toolbar' },
    h('div', { class: 'dash-toolbar__heading' }, h('h2', { class: 'dash-toolbar__title', id: 'dash-sets-title' }, 'Deine Lernsets'), countChip),
    h('div', { class: 'dash-toolbar__controls' }, search, sortControl),
  );

  const gridHost = h('div', { class: 'dash-grid-host' });
  const announcer = h('p', { class: 'sr-only', role: 'status', 'aria-live': 'polite' });
  const library = h('section', { class: 'dash-library', 'aria-labelledby': 'dash-sets-title' }, toolbar, gridHost, announcer);
  const emptyHost = h('div', { class: 'dash-empty-host' });

  const root = h('div', { class: ['ui-page', 'dash', 'dash--enter'] }, head, statsHost, resumeHost, library, emptyHost);
  outlet.append(root);

  /* ------------------------------------------------------ data rendering */

  function refresh() {
    const focus = captureFocus();
    const data = loadData();
    state.data = data;
    const hasSets = data.items.length > 0;
    const date = new Date(data.now);

    eyebrow.textContent = todayLabel(date);
    title.textContent = greetingFor(date);
    lead.textContent = leadText(data);
    newButton.hidden = !hasSets;

    statsHost.replaceChildren(hasSets ? statsStrip(data) : '');
    statsHost.hidden = !hasSets;
    resumeHost.replaceChildren(data.resume ? resumeBanner(data.resume) : '');
    resumeHost.hidden = !data.resume;
    library.hidden = !hasSets;
    emptyHost.hidden = hasSets;
    if (hasSets) {
      emptyHost.replaceChildren();
      renderGrid();
    } else if (!emptyHost.firstChild) {
      emptyHost.append(emptyView());
    }
    restoreFocus(focus);
  }

  function leadText(data) {
    const { streak, items, resume } = data;
    if (!items.length) return 'Schön, dass du da bist. Leg dein erstes Lernset an und starte direkt.';
    if (streak.today > 0) return `Heute schon ${plural(streak.today, 'Antwort', 'Antworten')} – weiter so!`;
    if (streak.current > 0) return `Lerne heute, damit deine Serie von ${plural(streak.current, 'Tag', 'Tagen')} weiterläuft.`;
    if (resume) return 'Mach dort weiter, wo du aufgehört hast.';
    return 'Bereit für ein paar Wörter? Wähle ein Lernset und leg los.';
  }

  function statsStrip(data) {
    const { streak } = data;
    // The same words as the Lernserie in the header (ui/daily-streak.js).
    return h(
      'ul',
      { class: 'dash-stats', role: 'list' },
      statTile({
        kind: 'streak',
        tone: streakTone(streak),
        iconName: 'flame',
        value: streak.current,
        unit: streak.current === 1 ? 'Tag' : 'Tage',
        label: 'Lernserie',
        hint: streakCaption(streak),
        tooltip: streakTooltip(streak) || null,
      }),
      statTile({
        kind: 'today',
        tone: streak.today > 0 ? 'lit' : 'off',
        iconName: 'target',
        value: streak.today,
        label: 'Heute beantwortet',
        hint: `Letzte 7 Tage: ${data.week}`,
      }),
      statTile({
        kind: 'mastered',
        tone: data.mastered > 0 ? 'lit' : 'off',
        iconName: 'trophy',
        value: data.mastered,
        label: 'Begriffe gemeistert',
        hint: `von ${plural(data.total, 'Begriff', 'Begriffen')}`,
        tooltip: 'Ein Begriff gilt als gemeistert, wenn du ihn zweimal in Folge richtig beantwortest.',
      }),
    );
  }

  function statTile({ kind, tone, iconName, value, unit, label, hint, tooltip }) {
    return h(
      'li',
      { class: ['dash-stat', `dash-stat--${kind}`, `is-${tone}`], 'data-tooltip': tooltip || null },
      h('span', { class: 'dash-stat__icon', 'aria-hidden': 'true' }, icon(iconName, { size: 22 })),
      h(
        'div',
        { class: 'dash-stat__body' },
        h(
          'p',
          { class: 'dash-stat__value' },
          h('span', { class: 'dash-stat__num' }, String(value)),
          unit ? h('span', { class: 'dash-stat__unit' }, unit) : null,
        ),
        h('p', { class: 'dash-stat__label' }, label),
        hint ? h('p', { class: 'dash-stat__hint' }, hint) : null,
      ),
    );
  }

  function resumeBanner(resume) {
    const { set, mode } = resume;
    const setHref = `#/set/${encodeURIComponent(set.id)}`;
    const meta = [];
    let progress = 0;
    let barLabel = '';
    if (mode === 'learn') {
      const { learn } = resume;
      const scope = learnScope(learn);
      if (scope) meta.push(scope);
      meta.push(learnRound(learn), `${learn.info.mastered} von ${learn.info.total} gemeistert`);
      progress = learn.info.progress;
      barLabel = 'Gemeistert in dieser Lerneinheit';
    } else {
      const { info } = resume;
      meta.push(sessionLabel(info));
      if (info.total > 0) meta.push(`${info.correct} von ${info.total} richtig`);
      progress = info.progress || 0;
      barLabel = 'Fortschritt dieser Schreibrunde';
    }
    // Each separator travels with the part after it, so a wrapped line never ends in '·'.
    const metaNodes = meta.map((text, i) =>
      h('span', { class: 'dash-resume__item' }, i ? h('span', { class: 'dash-resume__sep', 'aria-hidden': 'true' }, '·') : null, text),
    );
    const bar = progressBar({ value: progress, size: 'sm', label: barLabel });
    return h(
      'section',
      { class: 'dash-resume', 'aria-label': 'Weiterlernen' },
      h('span', { class: 'dash-resume__icon', 'aria-hidden': 'true' }, icon('play', { size: 22 })),
      h(
        'div',
        { class: 'dash-resume__body' },
        h(
          'p',
          { class: 'dash-resume__eyebrow' },
          icon(mode === 'learn' ? 'sparkles' : 'keyboard', { size: 14 }),
          mode === 'learn' ? 'Lernen' : 'Schreiben',
        ),
        h('p', { class: 'dash-resume__title', dir: 'auto' }, h('a', { href: setHref, class: 'dash-resume__link' }, set.title)),
        h('div', { class: 'dash-resume__meta' }, metaNodes),
        h('div', { class: 'dash-resume__bar' }, bar),
      ),
      button({
        label: mode === 'learn' ? 'Weiterlernen' : 'Fortsetzen',
        iconRight: 'arrowRight',
        variant: 'primary',
        href: `${setHref}/${mode}`,
        attrs: { class: 'dash-resume__action' },
      }),
    );
  }

  /* ------------------------------------------------------------- grid */

  function renderGrid() {
    const data = state.data;
    if (!data) return;
    const raw = state.query;
    const q = fold(raw);
    const sorted = sortItems(data.items, state.sort);
    const list = q
      ? sorted
          .map((item) => ({ item, match: matchItem(item, q) }))
          .filter((x) => x.match)
          .map(({ item, match }) => ({ ...item, match }))
      : sorted.map((item) => ({ ...item, match: null }));
    state.visible = list;

    countChip.textContent = q ? `${list.length} von ${data.items.length}` : String(data.items.length);

    if (q && !list.length) {
      gridHost.replaceChildren(noResults(raw.trim()));
      announcer.textContent = 'Keine Lernsets gefunden.';
      return;
    }
    announcer.textContent = q ? `${plural(list.length, 'Lernset', 'Lernsets')} gefunden.` : '';

    const tiles = [];
    if (!q) tiles.push(h('li', { class: 'dash-grid__item', style: { '--i': 0 } }, newTile()));
    list.forEach((item, i) => {
      tiles.push(h('li', { class: 'dash-grid__item', style: { '--i': Math.min(i + 1, MAX_STAGGER) } }, setCard(item, raw)));
    });
    gridHost.replaceChildren(h('ul', { class: 'dash-grid', role: 'list' }, tiles));
  }

  function newTile() {
    return h(
      'a',
      { class: 'dash-new', href: '#/new', dataset: { role: 'new' } },
      h('span', { class: 'dash-new__icon', 'aria-hidden': 'true' }, icon('plus', { size: 24, strokeWidth: 2 })),
      h(
        'span',
        { class: 'dash-new__text' },
        h('span', { class: 'dash-new__title' }, 'Neues Lernset'),
        h('span', { class: 'dash-new__sub' }, 'Liste einfügen oder Foto, PDF und Textdatei importieren'),
      ),
    );
  }

  function setCard(item, query) {
    const { set, progress, learn, session, match } = item;
    const titleId = `dash-set-${set.id}`;
    const setHref = `#/set/${encodeURIComponent(set.id)}`;

    // The quick action is Lernen, the main study mode; a Write round is resumed from the set page.
    const action = button({
      label: learn ? 'Weiterlernen' : 'Lernen',
      icon: learn ? 'play' : 'sparkles',
      variant: learn ? 'primary' : 'soft',
      size: 'sm',
      href: learn ? `${setHref}/learn` : `${setHref}/learn?new=1`,
      attrs: { class: 'dash-card__action', dataset: { role: 'action' }, 'aria-describedby': titleId },
    });

    const menuBtn = iconButton({
      icon: 'more',
      label: 'Weitere Aktionen',
      size: 'sm',
      attrs: { class: 'dash-card__menu', dataset: { role: 'menu' }, 'aria-describedby': titleId },
      onClick: (e) => {
        e.preventDefault();
        e.stopPropagation();
        openCardMenu(menuBtn, item);
      },
    });

    return h(
      'article',
      { class: ['dash-card', (learn || session) && 'is-active'], 'aria-labelledby': titleId, dataset: { setId: set.id } },
      h(
        'div',
        { class: 'dash-card__top' },
        chip({
          label: langPair(set.termLang, set.defLang),
          tone: 'accent',
          size: 'sm',
          title: `${langName(set.termLang)} → ${langName(set.defLang)}`,
        }),
      ),
      // User text: an Arabic title runs (and is cut) right to left.
      h(
        'h3',
        { class: 'dash-card__title', dir: 'auto' },
        h('a', { class: 'dash-card__link', href: setHref, id: titleId, dataset: { role: 'link' } }, highlight(set.title, query)),
      ),
      h('p', { class: 'dash-card__meta' }, plural(progress.total, 'Begriff', 'Begriffe')),
      match ? matchHint(set, match, query) : null,
      h(
        'div',
        { class: 'dash-card__progress' },
        masteryBar({ mastered: progress.mastered, learning: progress.learning, fresh: progress.fresh, showLegend: true, size: 'sm' }),
      ),
      h('div', { class: 'dash-card__foot' }, cardStatus(item), action),
      menuBtn,
    );
  }

  function matchHint(set, match, query) {
    if (match.inTitle) return null;
    if (match.inDescription && !match.cards.length) {
      return h(
        'p',
        { class: 'dash-card__match' },
        icon('search', { size: 14 }),
        h('span', { class: 'dash-card__match-text', dir: 'auto' }, highlight(set.description, query)),
      );
    }
    const card = match.cards[0];
    if (!card) return null;
    const more = match.cards.length - 1;
    // Term and definition each carry their language and direction (an Arabic term is isolated,
    // so the dash stays between them); the line itself stays left to right like the card.
    return h(
      'p',
      { class: 'dash-card__match' },
      icon('search', { size: 14 }),
      h(
        'span',
        { class: 'dash-card__match-text' },
        h('span', textAttrs(set.termLang), highlight(card.term, query)),
        h('span', { class: 'dash-card__match-sep', 'aria-hidden': 'true' }, ' – '),
        h('span', textAttrs(set.defLang), highlight(card.definition, query)),
      ),
      more > 0 ? h('span', { class: 'dash-card__match-more', title: `${more} weitere Treffer` }, `+${more}`) : null,
    );
  }

  // A running round: pulse + short text; `full` is the spelled-out version for
  // the tooltip and screen readers.
  function activeStatus(text, full) {
    return h(
      'span',
      { class: 'dash-card__status is-active', title: full || null },
      h('span', { class: 'dash-card__pulse', 'aria-hidden': 'true' }),
      h('span', { class: 'ui-truncate', 'aria-hidden': full ? 'true' : null }, text),
      full ? h('span', { class: 'sr-only' }, full) : null,
    );
  }

  function cardStatus({ set, progress, learn, info }) {
    if (learn) {
      // A subset session names its scope, so "0/3" next to "50 Begriffe" reads right
      // (short enough to keep the count visible on phones).
      const scope = learnScope(learn);
      const noun = learnScopeNoun(learn);
      const counts = `${learn.info.mastered}/${learn.info.total}${noun ? ` ${noun}` : ''}`;
      const full = `${scope ? `${scope} · ` : ''}${learnRound(learn)} · ${learn.info.mastered} von ${learn.info.total} gemeistert`;
      return activeStatus(`${learnRound(learn)} · ${counts}`, `Lernen: ${full}`);
    }
    if (info) {
      const short = info.remaining > 0 ? `${info.remaining} übrig` : 'Runde geschafft';
      return activeStatus(`Schreiben · ${short}`, `Schreiben: ${sessionLabel(info)}`);
    }
    if (progress.total > 0 && progress.mastered === progress.total) {
      return h(
        'span',
        { class: 'dash-card__status is-done' },
        icon('checkCircle', { size: 16 }),
        h('span', { class: 'ui-truncate' }, 'Alles gemeistert'),
      );
    }
    if (set.lastStudiedAt) {
      const when = relativeTime(set.lastStudiedAt);
      return h(
        'span',
        { class: 'dash-card__status', title: `Zuletzt gelernt ${when}` },
        icon('clock', { size: 15 }),
        h('span', { class: 'ui-truncate' }, h('span', { class: 'sr-only' }, 'Zuletzt gelernt '), capitalize(when)),
      );
    }
    return h(
      'span',
      { class: 'dash-card__status is-new' },
      icon('sparkles', { size: 15 }),
      h('span', { class: 'ui-truncate' }, 'Noch nicht gelernt'),
    );
  }

  function noResults(query) {
    return h(
      'div',
      { class: 'dash-noresults' },
      h('span', { class: 'dash-noresults__icon', 'aria-hidden': 'true' }, icon('search', { size: 24 })),
      h('p', { class: 'dash-noresults__title' }, `Keine Treffer für «${shortTitle(query, 48)}»`),
      h('p', { class: 'dash-noresults__text' }, 'Gesucht wird in Titeln, Beschreibungen und allen Begriffen deiner Lernsets.'),
      button({ label: 'Suche zurücksetzen', icon: 'x', variant: 'secondary', size: 'sm', onClick: () => clearSearch(true) }),
    );
  }

  function emptyView() {
    const steps = [
      ['clipboard', 'Liste einfügen', 'Wortschatz erkennt Begriffe und Übersetzungen automatisch – auch aus Fotos und PDFs.'],
      ['sparkles', 'Lernen', 'Neue Begriffe kommen zuerst als Multiple Choice, danach schreibst du sie selbst – bis alles sitzt.'],
      ['trophy', 'Fortschritt sehen', 'Zweimal in Folge richtig – und ein Begriff gilt als gemeistert.'],
    ];
    return h(
      'section',
      { class: 'dash-empty', 'aria-label': 'Noch keine Lernsets' },
      emptyState({
        icon: 'bookOpen',
        title: 'Noch keine Lernsets',
        text: 'Erstelle dein erstes Lernset aus einer Vokabelliste – in wenigen Sekunden kannst du mit Lernen loslegen.',
        action: [
          button({ label: 'Erstes Lernset erstellen', icon: 'plus', variant: 'primary', size: 'lg', href: '#/new', attrs: { 'data-cta': '' } }),
          button({ label: 'Backup wiederherstellen', icon: 'upload', variant: 'ghost', size: 'lg', href: '#/settings' }),
        ],
      }),
      h(
        'ol',
        { class: 'dash-steps', role: 'list' },
        steps.map(([iconName, heading, text], i) =>
          h(
            'li',
            { class: 'dash-step' },
            h('span', { class: 'dash-step__icon', 'aria-hidden': 'true' }, icon(iconName, { size: 20 })),
            h('p', { class: 'dash-step__title' }, h('span', { class: 'dash-step__num' }, `${i + 1}.`), ' ', heading),
            h('p', { class: 'dash-step__text' }, text),
          ),
        ),
      ),
    );
  }

  /* -------------------------------------------------------- card actions */

  // The study modes first (Mac SetActionsMenu), then the set's own actions.
  function openCardMenu(anchor, item) {
    const { set, learn, session } = item;
    const base = `/set/${encodeURIComponent(set.id)}`;
    const empty = !set.cards.length;
    menu(
      anchor,
      [
        {
          label: learn ? 'Weiterlernen' : 'Lernen',
          icon: learn ? 'play' : 'sparkles',
          disabled: empty,
          onClick: () => navigate(learn ? `${base}/learn` : `${base}/learn?new=1`),
        },
        {
          label: session ? 'Schreiben fortsetzen' : 'Schreiben',
          icon: 'keyboard',
          disabled: empty,
          onClick: () => navigate(session ? `${base}/write` : `${base}/write?new=1`),
        },
        { label: 'Karteikarten', icon: 'cards', disabled: empty, onClick: () => navigate(`${base}/flashcards`) },
        { label: 'Prüfung', icon: 'graduationCap', disabled: empty, onClick: () => navigate(`${base}/exam`) },
        { divider: true, label: 'Bearbeiten', icon: 'edit', onClick: () => navigate(`${base}/edit`) },
        { label: 'Duplizieren', icon: 'copy', onClick: () => duplicate(set) },
        { label: 'Als Text exportieren', icon: 'download', disabled: empty, onClick: () => exportText(set) },
        { divider: true, label: 'Löschen', icon: 'trash', danger: true, onClick: () => remove(set) },
      ],
      { label: `Aktionen für ${set.title}` },
    );
  }

  function duplicate(set) {
    let copy;
    try {
      copy = db.duplicateSet(set.id);
    } catch (err) {
      toast(errorMessage(err, 'Das Lernset konnte nicht dupliziert werden.'), { tone: 'danger' });
      return;
    }
    const card = findCard(copy.id);
    if (card) {
      card.classList.add('is-new');
      card.addEventListener('animationend', () => card.classList.remove('is-new'), { once: true });
      card.scrollIntoView({ block: 'nearest', behavior: prefersReducedMotion() ? 'auto' : 'smooth' });
      focusIn(card, 'link');
    }
    toast(`Kopie von «${shortTitle(set.title)}» erstellt`, {
      tone: 'success',
      action: { label: 'Öffnen', onClick: () => navigate(`/set/${copy.id}`) },
    });
  }

  function exportText(set) {
    try {
      const fresh = db.getSet(set.id) || set;
      downloadText(fileNameFor(fresh.title), setToText(fresh));
      // The Windows app saves without asking: say where the file went.
      toast(`«${shortTitle(fresh.title)}» als Textdatei im Ordner «Downloads» gespeichert`, { tone: 'success' });
    } catch (err) {
      toast(errorMessage(err, 'Der Export ist fehlgeschlagen.'), { tone: 'danger' });
    }
  }

  async function remove(set) {
    const ok = await confirmDialog({
      title: 'Lernset löschen?',
      message: `«${set.title}» mit ${plural(set.cards.length, 'Begriff', 'Begriffen')} und deinem Lernfortschritt wird gelöscht.`,
      confirmLabel: 'Löschen',
    });
    if (!ok || !root.isConnected) return;

    const position = state.visible.findIndex((x) => x.set.id === set.id);
    const snapshot = db.snapshotSet(set.id);
    try {
      db.deleteSet(set.id);
    } catch (err) {
      toast(errorMessage(err, 'Das Lernset konnte nicht gelöscht werden.'), { tone: 'danger' });
      return;
    }
    focusAfterRemoval(position);
    toast(`«${shortTitle(set.title)}» gelöscht`, {
      duration: 7000,
      action: snapshot ? { label: 'Rückgängig', onClick: () => restore(snapshot) } : undefined,
    });
  }

  // Undo for deletions: puts the set back with the same id, its progress and its running sessions.
  function restore(snapshot) {
    try {
      const set = db.restoreSet(snapshot);
      toast(`«${shortTitle(set.title)}» wiederhergestellt`, { tone: 'success' });
    } catch (err) {
      toast(errorMessage(err, 'Das Lernset konnte nicht wiederhergestellt werden.'), { tone: 'danger' });
    }
  }

  /* ------------------------------------------------------- search & keys */

  function syncSearchChrome() {
    const hasQuery = searchInput.value !== '';
    clearSearchBtn.hidden = !hasQuery;
    search.classList.toggle('has-query', hasQuery);
  }

  function clearSearch(refocus) {
    searchInput.value = '';
    state.query = '';
    syncSearchChrome();
    renderGrid();
    if (refocus) searchInput.focus();
  }

  function onSearchKeydown(e) {
    // Enter and Esc of an input method (Pinyin) confirm or cancel its composition.
    if (isComposingKey(e)) return;
    if (e.key === 'Escape') {
      if (searchInput.value) {
        e.preventDefault();
        clearSearch(true);
      } else {
        searchInput.blur();
      }
    } else if (e.key === 'Enter') {
      e.preventDefault();
      const first = state.visible[0];
      if (state.query.trim() && first) navigate(`/set/${first.set.id}`);
    } else if (e.key === 'ArrowDown') {
      const link = gridHost.querySelector('[data-role="link"]');
      if (link) {
        e.preventDefault();
        link.focus();
      }
    }
  }

  function onGlobalKeydown(e) {
    if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key !== '/' || library.hidden || hasOpenOverlay()) return;
    const target = e.target;
    const tag = target && target.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || (target && target.isContentEditable)) return;
    e.preventDefault();
    searchInput.focus();
    searchInput.select();
  }

  /* --------------------------------------------------------------- focus */

  function findCard(id) {
    return Array.from(gridHost.querySelectorAll('.dash-card')).find((el) => el.dataset.setId === id) || null;
  }

  function focusIn(card, role) {
    const target = card && card.querySelector(`[data-role="${role}"]`);
    if (target) target.focus({ preventScroll: true });
    return !!target;
  }

  function captureFocus() {
    const el = document.activeElement;
    if (!el || !gridHost.contains(el)) return null;
    const card = el.closest('.dash-card');
    if (card) return { id: card.dataset.setId, role: el.dataset.role || 'link' };
    if (el.closest('.dash-new')) return { role: 'new' };
    return null;
  }

  function focusLost() {
    const active = document.activeElement;
    return !active || active === document.body || !active.isConnected;
  }

  function restoreFocus(saved) {
    if (!saved || !focusLost()) return;
    if (saved.role === 'new') {
      const tile = gridHost.querySelector('.dash-new');
      if (tile) tile.focus({ preventScroll: true });
      return;
    }
    const card = findCard(saved.id);
    if (card && !focusIn(card, saved.role)) focusIn(card, 'link');
  }

  function focusAfterRemoval(position) {
    if (!focusLost()) return;
    if (library.hidden) {
      const cta = emptyHost.querySelector('[data-cta]');
      if (cta) cta.focus({ preventScroll: true });
      return;
    }
    const cards = gridHost.querySelectorAll('.dash-card');
    const next = cards[Math.min(Math.max(position, 0), cards.length - 1)];
    if (next) focusIn(next, 'link');
    else {
      const tile = gridHost.querySelector('.dash-new');
      if (tile) tile.focus({ preventScroll: true });
    }
  }

  /* ----------------------------------------------------------- lifecycle */

  refresh();
  syncSearchChrome();

  cleanups.push(
    db.subscribe(() => {
      if (root.isConnected) refresh();
    }),
  );

  document.addEventListener('keydown', onGlobalKeydown);
  cleanups.push(() => document.removeEventListener('keydown', onGlobalKeydown));

  // Keep relative times and the greeting current while the page stays open.
  const timer = setInterval(() => {
    if (document.visibilityState !== 'hidden' && root.isConnected && !hasOpenOverlay()) refresh();
  }, REFRESH_MS);
  cleanups.push(() => clearInterval(timer));

  // The staggered entrance only plays on arrival, not on later re-renders.
  const enterTimer = setTimeout(() => root.classList.remove('dash--enter'), 1400);
  cleanups.push(() => clearTimeout(enterTimer));

  return () => {
    for (const fn of cleanups.splice(0)) {
      try {
        fn();
      } catch {
        /* keep cleaning up */
      }
    }
  };
}
