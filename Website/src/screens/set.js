// Set detail screen (#/set/:id): header with actions, study entry points
// (Lernen first, then Schreiben, Karteikarten and Prüfung), mastery overview and the
// filterable term list. Keys: Ctrl+L Lernen, Ctrl+Shift+L Schreiben, Ctrl+E Bearbeiten.

import { h, replayClass, prefersReducedMotion } from '../lib/dom.js';
import { navigate, setTitle } from '../router.js';
import {
  button,
  iconButton,
  starButton,
  chip,
  ring,
  progressBar,
  segmented,
  openModal,
  confirmDialog,
  toast,
  menu,
  emptyState,
  hasOpenModal,
} from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { LANGS, STATUS, plural, langName } from '../lib/labels.js';
import { canSpeak, speak, stopSpeaking } from '../lib/speech.js';
import { relativeTime } from '../lib/time.js';
import { isDesktopApp } from '../lib/host.js';
import { isTypingTarget } from '../lib/shortcuts.js';
import { db } from '../store/db.js';
import { downloadText, setToText } from '../store/backup.js';
import { cardStatus, setProgress } from '../core/mastery.js';
import { counters } from '../core/session.js';
import {
  counts as learnCounts,
  checkpoint as learnCheckpoint,
  isRoundOver as learnRoundOver,
  isFinished as learnFinished,
  syncProgress as learnSync,
} from '../core/learn.js';
import {
  runningDeck as runningFlashcards,
  knownShare as deckKnownShare,
  runningDetail as deckDetail,
  restartMessage as deckRestartMessage,
} from '../core/flashcards.js';
import { directionText, learnOptions } from '../ui/study-options.js';
import { hasAnswers } from './write-model.js';
import { restartSessionMessage } from './learn-model.js';
import { startLearnWithCards } from './learn-start.js';
import { isApplePlatform } from './editor-util.js';
import { DIFFICULT_MISTAKES, difficultCards, mistakesOf, setPageCommand } from './set-model.js';

const STATUS_KEYS = ['mastered', 'learning', 'new'];

const FILTERS = [
  { value: 'all', label: 'Alle' },
  { value: 'new', label: STATUS.new },
  { value: 'learning', label: STATUS.learning },
  { value: 'mastered', label: STATUS.mastered },
  { value: 'starred', label: 'Markiert', icon: 'starFilled' },
  { value: 'difficult', label: 'Schwierig', icon: 'flame' },
];

const FILTER_EMPTY = {
  new: { icon: 'sparkles', title: 'Keine neuen Begriffe', text: 'Du hast jeden Begriff schon mindestens einmal geübt.' },
  learning: {
    icon: 'book',
    title: 'Gerade nichts am Lernen',
    text: 'Hier erscheinen Begriffe, die du schon geübt, aber noch nicht gemeistert hast.',
  },
  mastered: {
    icon: 'trophy',
    title: 'Noch nichts gemeistert',
    text: 'Ein Begriff gilt als gemeistert, wenn du ihn zweimal hintereinander richtig beantwortest.',
  },
  starred: {
    icon: 'star',
    title: 'Keine markierten Begriffe',
    text: 'Tippe bei einem Begriff auf den Stern, um ihn später gezielt zu üben.',
  },
  difficult: {
    icon: 'flame',
    title: 'Keine schwierigen Begriffe',
    text: `Hier erscheinen Begriffe, die du mindestens ${DIFFICULT_MISTAKES}× falsch beantwortet hast.`,
  },
};

// The set page no longer offers «Nur nicht gemeisterte» (Karteikarten replaced it on the
// Mac), but stored sessions and old links with the 'learning' subset still show their scope.
const SUBSET_LABELS = { starred: 'Nur markierte', learning: 'Nur nicht gemeisterte', missed: 'Nur falsche' };

// What the subset shortcuts practise, for the "Laufende Runde beenden?" prompt.
const SUBSET_WHAT = { starred: 'die markierten Begriffe', learning: 'die nicht gemeisterten Begriffe' };

const FLASHCARDS_TAGLINE = 'Karten umdrehen und sortieren: Weiss ich oder Lerne ich noch';
const EXAM_TAGLINE = 'Alle Fragen auf einer Seite, mit Zeitlimit und einer Note wie in der Schule';

// "Laufende Runde beenden?" wording per study mode (Lernen, Schreiben); Lernen
// uses the words of the Learn screen (a Lerneinheit spans many Runden).
const SUBSET_CONFIRM = {
  learn: {
    confirmTitle: 'Laufende Lerneinheit beenden?',
    saved: 'Deine gespeicherte Lerneinheit',
    verb: 'lernst',
    confirmLabel: 'Neu beginnen',
  },
  write: {
    confirmTitle: 'Laufende Runde beenden?',
    saved: 'Deine gespeicherte Runde',
    verb: 'übst',
    confirmLabel: 'Neue Runde starten',
  },
};

const TERM_SEPARATORS = [
  { value: 'tab', label: 'Tab', sep: '\t' },
  { value: 'comma', label: 'Komma', sep: ', ' },
  { value: 'dash', label: 'Bindestrich', sep: ' - ' },
];

const CARD_SEPARATORS = [
  { value: 'newline', label: 'Neue Zeile', sep: '\n' },
  { value: 'semicolon', label: 'Strichpunkt', sep: ';' },
];

// The chosen term filter per set, kept while the app stays open.
const filterMemory = new Map();

/* ------------------------------------------------------------------ helpers */

const langAttr = (code) => (LANGS[code] && LANGS[code].bcp47) || null;
const setPath = (setId) => `/set/${encodeURIComponent(setId)}`;
const editHref = (setId) => `#${setPath(setId)}/edit`;
const modePath = (setId, mode, query = '') => `${setPath(setId)}/${mode}${query ? `?${query}` : ''}`;
const writeHref = (setId, query = '') => `#${modePath(setId, 'write', query)}`;
const learnHref = (setId, query = '') => `#${modePath(setId, 'learn', query)}`;

// After arriving with Enter (e.g. «Zurück zum Lernset»), the page's Enter waits a moment (Mac KeyActionGate).
const ENTER_GATE_MS = 280;

const isPlainEnter = (e) => e.key === 'Enter' && !e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey;

// Controls that handle Enter themselves.
const INTERACTIVE =
  'a[href], button, input, textarea, select, summary, [contenteditable=""], [contenteditable="true"], [role="button"], [role="menuitem"], [role="switch"], [role="tab"], [role="radio"], [role="checkbox"], [tabindex]:not([tabindex="-1"])';

function isInteractive(target) {
  const el = target && target.nodeType === 1 ? target : target && target.parentElement;
  return !!(el && el.closest && el.closest(INTERACTIVE));
}

// aria-keyshortcuts for the set page's keys (⌘ on Apple, Ctrl elsewhere).
const keyShortcut = (key, shift = false) => `${isApplePlatform() ? 'Meta' : 'Control'}+${shift ? 'Shift+' : ''}${key}`;
const keyHint = (key) => (isApplePlatform() ? `⌘${key}` : `Strg+${key}`);

function errorMessage(err) {
  return err && err.message ? err.message : 'Etwas ist schiefgelaufen. Bitte versuche es nochmal.';
}

function answerLabel(set, options) {
  const mode = options && options.answerWith;
  if (mode === 'both') return 'Antworten in beide Richtungen';
  const lang = mode === 'definition' ? set.defLang : set.termLang;
  // A language name only tells the sides apart when it is known and differs.
  if (lang === 'other' || set.termLang === set.defLang) {
    return mode === 'definition' ? 'Antworten mit der Definition' : 'Antworten mit dem Begriff';
  }
  return `Antworten auf ${langName(lang)}`;
}

// The Learn explanation under the study buttons; it follows the question types
// chosen in the options.
function studyNote(set, options) {
  const direction = directionText(options ? options.answerWith : 'term', set.termLang, set.defLang, 'learn');
  const { mc, written } = learnOptions(options && options.learn);
  let how = 'Neue Begriffe zuerst als Multiple Choice, danach schriftlich.';
  if (!written) how = 'Alle Fragen als Multiple Choice.';
  else if (!mc) how = 'Alle Fragen schriftlich.';
  return `${direction} ${how} Zweimal richtig = gemeistert.`;
}

function learnTagline(options) {
  const { mc, written } = learnOptions(options && options.learn);
  if (mc && written) return 'Multiple Choice & schriftlich – bis alles sitzt';
  return mc ? 'Multiple Choice – bis alles sitzt' : 'Schriftlich – bis alles sitzt';
}

function subsetLabel(subset, objectLabel) {
  if (subset && typeof subset === 'object') return objectLabel;
  return SUBSET_LABELS[subset] || null;
}

// Detail parts joined by ' · '; a line only breaks between parts, never inside
// one ("0 von 3 gemeistert" stays together).
function joinParts(parts) {
  return parts.map((p) => p.replace(/ /g, '\u00a0')).join(' · ');
}

// "Runde 3 · 18 von 52 gemeistert" for a running Learn session.
function learnDetail(learn) {
  const { state, counts, roundOver } = learn;
  const parts = [];
  const scope = subsetLabel(state.subset, 'Ausgewählte Begriffe');
  if (scope) parts.push(scope);
  const round = Number.isInteger(state.round) && state.round > 0 ? state.round : 1;
  parts.push(roundOver ? `Runde ${round} geschafft` : `Runde ${round}`);
  parts.push(`${counts.mastered} von ${counts.total} gemeistert`);
  return joinParts(parts);
}

// The named scope of a Learn session that a restart link can carry (null: all cards).
function learnSubsetQuery(state) {
  const subset = state && state.subset;
  return typeof subset === 'string' && subset !== 'all' && SUBSET_LABELS[subset] ? subset : null;
}

function sessionDetail(session) {
  const { round, remaining, incorrect } = session.counters;
  const parts = [];
  const scope = subsetLabel(session.state.subset, 'Falsche Begriffe');
  if (scope) parts.push(scope);
  if (remaining > 0) parts.push(`Runde ${round}`, `${remaining} übrig`);
  else {
    parts.push(`Runde ${round} geschafft`);
    if (incorrect > 0) parts.push(`${incorrect} zum Wiederholen`);
  }
  return joinParts(parts);
}

function progressCaption(stats) {
  if (!stats.total) return 'Füge Begriffe hinzu, um loszulegen.';
  if (stats.mastered === stats.total) return 'Alles gemeistert – grossartig! Wiederhole ab und zu, damit es sitzt.';
  if (!stats.mastered && !stats.learning) {
    return 'Ein Begriff gilt als gemeistert, wenn du ihn zweimal hintereinander richtig beantwortest.';
  }
  return `${stats.mastered} von ${plural(stats.total, 'Begriff', 'Begriffen')} gemeistert. Zweimal hintereinander richtig zählt als gemeistert.`;
}

function progressTitle(p) {
  if (!p || !(p.correct + p.incorrect)) return 'Noch nicht geübt';
  return `${p.correct}× richtig · ${p.incorrect}× falsch`;
}

// Whether starting over would throw answers away (Write: hasAnswers in write-model.js).
function learnHasAnswers(state) {
  return (Array.isArray(state.rounds) && state.rounds.length > 0) || (typeof state.answered === 'number' && state.answered > 0);
}

function matches(filter, card, model) {
  if (filter === 'all') return true;
  if (filter === 'starred') return !!card.starred;
  if (filter === 'difficult') return mistakesOf(model.progress, card.id) >= DIFFICULT_MISTAKES;
  return model.status.get(card.id) === filter;
}

// The cards a filter shows, in list order: card order, except «Schwierig» (most mistakes first).
function visibleCards(filter, model) {
  if (filter === 'difficult') return model.difficult;
  return model.set.cards.filter((c) => matches(filter, c, model));
}

// The set's Karteikarten deck while it is under way (sorted at least one card, not
// finished), synced with the cards as they are now; null otherwise (Mac runningFlashcardDeck).
function runningDeck(set) {
  try {
    return runningFlashcards(db.getFlashcards(set.id), set.cards);
  } catch {
    return null;
  }
}

function shortTitle(title, max = 40) {
  const t = String(title || '');
  return t.length > max ? `${t.slice(0, max - 1).trimEnd()}…` : t;
}

function fileNameFor(title) {
  const base = String(title || '')
    .normalize('NFC')
    .replace(/[\\/:*?"<>|\x00-\x1f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 80);
  return `${base || 'Lernset'}.txt`;
}

async function copyText(text, field) {
  try {
    const clip = globalThis.navigator && globalThis.navigator.clipboard;
    if (clip && typeof clip.writeText === 'function') {
      await clip.writeText(text);
      return true;
    }
  } catch {
    // Fall back to the selection-based copy below.
  }
  try {
    field.focus();
    field.select();
    return document.execCommand('copy');
  } catch {
    return false;
  }
}

// Rebuilds `container` and moves focus back to the element with the same
// data-fkey, so live updates never steal the keyboard position.
function keepFocus(container, rebuild) {
  const active = document.activeElement;
  const key = active && active !== document.body && container.contains(active) ? active.getAttribute('data-fkey') : null;
  rebuild();
  if (!key || container.contains(document.activeElement)) return;
  const next = Array.from(container.querySelectorAll('[data-fkey]')).find((el) => el.getAttribute('data-fkey') === key);
  if (next) next.focus({ preventScroll: true });
}

function readModel(setId) {
  const set = setId ? db.getSet(setId) : null;
  if (!set) return null;
  const progress = db.getProgress(setId);
  const stats = setProgress(set, progress);
  const status = new Map();
  for (const card of set.cards) status.set(card.id, cardStatus(progress[card.id]));
  const raw = db.getSession(setId);
  let session = null;
  if (raw && raw.finishedAt == null) {
    try {
      const info = counters(raw);
      if (info.total > 0) session = { state: raw, counters: info };
    } catch {
      session = null;
    }
  }
  const learnRaw = db.getLearn(setId);
  let learn = null;
  if (learnRaw && learnRaw.finishedAt == null) {
    try {
      // Answers given in Schreiben count for the Learn session too (shared progress);
      // once that masters everything, there is nothing left to continue.
      const state = learnSync(learnRaw, progress);
      const info = learnCounts(state);
      // A round without answers (only after removals) shows no checkpoint: it is not "geschafft".
      const roundOver = learnRoundOver(state) && learnCheckpoint(state).answered > 0;
      if (info.total > 0 && !learnFinished(state)) learn = { state, counts: info, roundOver };
    } catch {
      learn = null;
    }
  }
  let options = null;
  try {
    options = db.getStudyOptions(setId);
  } catch {
    options = null;
  }
  return {
    set,
    progress,
    stats,
    status,
    starred: set.cards.filter((c) => c.starred).length,
    difficult: difficultCards(set.cards, progress),
    session,
    learn,
    deck: runningDeck(set),
    options,
    canReset: Object.keys(progress).length > 0 || !!raw || !!learnRaw,
  };
}

// Restores a deleted set with its progress and its running sessions.
function restoreSet(snapshot) {
  if (!snapshot) return;
  try {
    const set = db.restoreSet(snapshot);
    navigate(setPath(set.id));
    toast('Lernset wiederhergestellt', { tone: 'success' });
  } catch (err) {
    toast(errorMessage(err), { tone: 'danger' });
  }
}

/* ----------------------------------------------------------- export modal */

function openExport(set) {
  let termSep = TERM_SEPARATORS[0].sep;
  let cardSep = CARD_SEPARATORS[0].sep;
  const text = h('textarea', {
    class: 'ui-input ui-textarea set-export__text',
    readonly: true,
    rows: '10',
    spellcheck: 'false',
    'aria-label': 'Exportierter Text',
  });
  // Tab stops just past the longest term make the preview read like two columns.
  const longest = set.cards.reduce((max, c) => Math.max(max, String(c.term || '').length), 0);
  text.style.setProperty('--set-tab', String(Math.min(48, longest + 3)));
  const sync = () => {
    text.value = setToText(set, { termSep, cardSep });
  };
  const group = (title, list, onPick) =>
    h(
      'div',
      { class: 'set-export__group' },
      h('span', { class: 'set-export__label' }, title),
      segmented({
        options: list.map((o) => ({ value: o.value, label: o.label })),
        value: list[0].value,
        ariaLabel: title,
        size: 'sm',
        block: true,
        onChange: (value) => {
          onPick(list.find((o) => o.value === value).sep);
          sync();
        },
      }),
    );
  const content = h(
    'div',
    { class: 'set-export' },
    h(
      'p',
      { class: 'set-export__intro' },
      'Kopiere die Liste oder lade sie als Textdatei herunter. Mit «Neue Zeile» zwischen den Karten lässt sie sich in Wortschatz und Quizlet wieder importieren.',
    ),
    h(
      'div',
      { class: 'set-export__options' },
      group('Zwischen Begriff und Definition', TERM_SEPARATORS, (sep) => (termSep = sep)),
      group('Zwischen den Karten', CARD_SEPARATORS, (sep) => (cardSep = sep)),
    ),
    text,
  );
  sync();
  openModal({
    title: 'Als Text exportieren',
    size: 'lg',
    content,
    actions: [
      {
        label: 'Kopieren',
        icon: 'copy',
        close: false,
        onClick: async () => {
          const ok = await copyText(text.value, text);
          if (ok) toast('Text kopiert', { tone: 'success' });
          else toast('Kopieren hat nicht geklappt. Markiere den Text und kopiere ihn von Hand.', { tone: 'danger' });
        },
      },
      {
        label: 'Herunterladen',
        icon: 'download',
        variant: 'primary',
        autofocus: true,
        onClick: () => {
          const name = fileNameFor(set.title);
          try {
            downloadText(name, text.value);
          } catch (err) {
            toast(errorMessage(err), { tone: 'danger' });
            return false;
          }
          // The Windows app saves without asking: say where the file went.
          if (isDesktopApp()) toast(`«${shortTitle(set.title)}» als Textdatei im Ordner «Downloads» gespeichert`, { tone: 'success' });
          return true;
        },
      },
    ],
  });
}

/* ------------------------------------------------------------- components */

function startTile({ href, iconName, title, detail, progress, fkey }) {
  const progressEl =
    progress != null
      ? h('span', { class: 'set-start__progress', 'aria-hidden': 'true' }, progressBar({ value: progress, size: 'sm' }))
      : null;
  return h(
    'a',
    { class: 'set-start', href, 'data-fkey': fkey },
    h('span', { class: 'set-start__icon', 'aria-hidden': 'true' }, icon(iconName, { size: 24 })),
    h(
      'span',
      { class: 'set-start__text' },
      h('span', { class: 'set-start__title' }, title),
      h('span', { class: 'set-start__detail' }, detail),
      progressEl,
    ),
    h('span', { class: 'set-start__go', 'aria-hidden': 'true' }, icon('arrowRight', { size: 20 })),
  );
}

function countButton({ label, count, iconName, href, fkey, ariaLabel, className, onClick, tooltip }) {
  const btn = button({
    label,
    icon: iconName,
    size: 'sm',
    href,
    onClick,
    attrs: { class: ['set-extra', className], 'data-fkey': fkey, 'aria-label': ariaLabel, 'data-tooltip': tooltip || null },
  });
  btn.append(h('span', { class: 'set-count', 'aria-hidden': 'true' }, String(count)));
  return btn;
}

// A study mode below Lernen (Schreiben, Karteikarten, Prüfung): one row that starts or
// continues it, an optional progress bar for a running session, and an optional «…» menu.
function modeRow({ href, iconName, title, detail, active = false, progress = null, fkey, keys = null, items = [], menuLabel, moreLabel }) {
  const bar =
    progress != null
      ? h('span', { class: 'set-mode__progress', 'aria-hidden': 'true' }, progressBar({ value: Math.min(1, Math.max(0, progress)), size: 'sm' }))
      : null;
  const link = h(
    'a',
    { class: ['set-mode__link', active && 'is-active'], href, 'data-fkey': fkey, 'aria-keyshortcuts': keys },
    h('span', { class: 'set-mode__icon', 'aria-hidden': 'true' }, icon(iconName, { size: 20 })),
    h('span', { class: 'set-mode__text' }, h('span', { class: 'set-mode__title' }, title), h('span', { class: 'set-mode__detail' }, detail), bar),
    h('span', { class: 'set-mode__go', 'aria-hidden': 'true' }, icon('chevronRight', { size: 18 })),
  );
  let more = null;
  if (items.length) {
    more = iconButton({
      icon: 'more',
      label: moreLabel,
      variant: 'secondary',
      attrs: { class: 'set-mode__more', 'data-fkey': `${fkey}-more`, 'aria-haspopup': 'menu' },
    });
    more.addEventListener('click', () => menu(more, items, { label: menuLabel }));
  }
  return h('div', { class: 'set-mode' }, link, more);
}

function missingView() {
  return h(
    'div',
    { class: 'set-missing' },
    emptyState({
      icon: 'search',
      title: 'Lernset nicht gefunden',
      text: 'Dieses Lernset gibt es nicht mehr – vielleicht wurde es gelöscht.',
      action: button({ label: 'Zur Übersicht', icon: 'arrowLeft', variant: 'primary', href: '#/' }),
    }),
  );
}

/* ----------------------------------------------------------------- screen */

export function render(outlet, ctx = {}) {
  const setId = ctx.params && ctx.params.id ? String(ctx.params.id) : '';
  const speechOk = canSpeak();
  const root = h('div', { class: 'ui-page set-page' });
  outlet.append(root);

  let model = null;
  let view = null;
  let sigs = {};
  let filter = filterMemory.get(setId) || 'all';
  let visibleIds = [];
  let rows = new Map();
  let softUpdate = false;
  let leaving = false;
  let disposed = false;
  let missingShown = false;
  let raf = 0;
  const shownAt = Date.now();

  /* ---------------------------------------------------------------- build */

  function buildView() {
    missingShown = false;
    const chips = {};
    const filterBar = h(
      'div',
      { class: 'set-filters', role: 'group', 'aria-label': 'Begriffe filtern' },
      FILTERS.map((f) => {
        const el = chip({ label: f.label, icon: f.icon, count: 0, selected: f.value === filter, onClick: () => setFilter(f.value) });
        if (f.value === 'starred') el.classList.add('set-chip--starred');
        if (f.value === 'difficult') el.classList.add('set-chip--difficult');
        chips[f.value] = el;
        return el;
      }),
    );
    const countBadge = h('span', { class: 'set-terms__count' });
    const listSlot = h('div', { class: 'set-list-slot' });
    const live = h('p', { class: 'sr-only', 'aria-live': 'polite' });
    const foot = h(
      'div',
      { class: 'set-terms__foot' },
      button({ label: 'Begriffe hinzufügen oder bearbeiten', icon: 'edit', href: editHref(setId) }),
    );
    const terms = h(
      'section',
      { class: 'set-terms', 'aria-labelledby': 'set-terms-title' },
      h('div', { class: 'set-terms__head' }, h('h2', { class: 'ui-h2 set-terms__title', id: 'set-terms-title' }, 'Begriffe', countBadge)),
      filterBar,
      live,
      listSlot,
      foot,
    );
    const headSlot = h('div', { class: 'set-head-slot' });
    const studySlot = h('section', { class: 'set-card set-study', 'aria-labelledby': 'set-study-title' });
    const progress = buildProgress();
    const hero = h('div', { class: 'set-hero' }, studySlot, progress);
    root.replaceChildren(headSlot, hero, terms);
    view = { headSlot, studySlot, progress, hero, chips, filterBar, countBadge, listSlot, live, foot, terms };
    sigs = {};
    rows = new Map();
    visibleIds = [];
  }

  function buildHeader(m) {
    const { set } = m;
    const more = iconButton({ icon: 'more', label: 'Weitere Aktionen', variant: 'secondary', attrs: { 'data-fkey': 'more' } });
    more.addEventListener('click', () => openActions(more));
    return h(
      'header',
      { class: 'set-head' },
      h('a', { class: 'ui-back set-head__back', href: '#/', 'data-fkey': 'back' }, icon('arrowLeft', { size: 16 }), 'Lernsets'),
      h(
        'div',
        { class: 'set-head__actions' },
        button({
          label: 'Bearbeiten',
          icon: 'edit',
          href: editHref(set.id),
          attrs: {
            'data-fkey': 'edit',
            'data-tooltip': `Begriffe hinzufügen oder bearbeiten (${keyHint('E')})`,
            'aria-keyshortcuts': keyShortcut('E'),
          },
        }),
        more,
      ),
      h(
        'div',
        { class: 'set-head__main' },
        h('h1', { class: 'ui-h1 set-head__title' }, set.title),
        h(
          'div',
          { class: 'set-head__meta' },
          chip({ label: `${langName(set.termLang)} → ${langName(set.defLang)}`, tone: 'accent', icon: 'globe' }),
          h(
            'span',
            { class: 'set-head__facts' },
            h('span', { class: 'set-head__fact' }, plural(set.cards.length, 'Begriff', 'Begriffe')),
            h(
              'span',
              { class: 'set-head__fact' },
              set.lastStudiedAt ? `Zuletzt gelernt ${relativeTime(set.lastStudiedAt)}` : 'Noch nicht gelernt',
            ),
          ),
        ),
        set.description ? h('p', { class: 'set-head__desc' }, set.description) : null,
      ),
    );
  }

  function fillStudy(m) {
    const { set, stats, learn, starred, difficult } = m;
    const nodes = [h('h2', { class: 'ui-eyebrow set-card__eyebrow', id: 'set-study-title' }, 'Üben')];
    // An empty set hides the whole hero; the term list shows the call to action.
    if (stats.total) {
      const allMastered = stats.mastered === stats.total;
      const tile = learn
        ? startTile({
            href: learnHref(set.id),
            iconName: 'play',
            title: 'Weiterlernen',
            detail: learnDetail(learn),
            progress: learn.counts.progress,
            fkey: 'start',
          })
        : startTile({
            href: learnHref(set.id, 'new=1'),
            iconName: 'sparkles',
            title: 'Lernen',
            detail: allMastered ? 'Alles gemeistert – nochmals von vorne?' : learnTagline(m.options),
            fkey: 'start',
          });
      tile.setAttribute('aria-keyshortcuts', `Enter ${keyShortcut('L')}`);
      nodes.push(tile);
      const extras = [];
      if (learn) {
        // Like "Neu starten" in Learn itself: same scope, and asks before a session with answers ends.
        const sub = learnSubsetQuery(learn.state);
        extras.push(
          button({
            label: 'Neu starten',
            icon: 'rotate',
            size: 'sm',
            href: learnHref(set.id, sub ? `new=1&subset=${sub}` : 'new=1'),
            onClick: (e) => restartLearn(e),
            attrs: { 'data-fkey': 'restart', 'aria-label': sub ? `Lernen neu starten (${SUBSET_LABELS[sub]})` : 'Lernen neu starten' },
          }),
        );
      }
      if (starred > 0) {
        extras.push(
          countButton({
            label: 'Nur markierte',
            count: starred,
            iconName: 'starFilled',
            href: learnHref(set.id, 'new=1&subset=starred'),
            fkey: 'starred',
            ariaLabel: `Nur markierte Begriffe lernen (${starred})`,
            className: 'set-extra--starred',
            tooltip: 'Nur die markierten Begriffe lernen',
            onClick: (e) => startSubset(e, 'learn', 'starred'),
          }),
        );
      }
      if (difficult.length > 0) {
        extras.push(
          countButton({
            label: 'Nur schwierige',
            count: difficult.length,
            iconName: 'flame',
            fkey: 'difficult',
            ariaLabel: `Nur schwierige Begriffe lernen (${difficult.length})`,
            className: 'set-extra--difficult',
            tooltip: `Nur die Begriffe lernen, die du mindestens ${DIFFICULT_MISTAKES}× falsch beantwortet hast`,
            onClick: () => startDifficult(),
          }),
        );
      }
      if (extras.length) nodes.push(h('div', { class: 'set-extras' }, extras));
      // Like the Mac: the star tip stays until something is starred or Lernen runs.
      if (!starred && !learn) {
        nodes.push(
          h(
            'p',
            { class: 'set-study__hint' },
            icon('lightbulb', { size: 16 }),
            h('span', null, 'Markiere schwierige Begriffe mit dem Stern, um sie gezielt zu üben.'),
          ),
        );
      }
      nodes.push(h('div', { class: 'set-modes' }, writeRow(m), flashcardsRow(m), examRow(m)));
      nodes.push(h('p', { class: 'set-study__note' }, studyNote(set, m.options)));
    }
    keepFocus(view.studySlot, () => view.studySlot.replaceChildren(...nodes));
  }

  // Schreiben: one row that starts or continues it, plus a small menu for
  // starting over and for the starred subset.
  function writeRow(m) {
    const { set, session, starred } = m;
    const items = [];
    if (session) {
      items.push({ label: 'Neu starten', icon: 'rotate', onClick: () => navigate(modePath(set.id, 'write', 'new=1')) });
    }
    if (starred > 0) {
      items.push({ label: 'Nur markierte schreiben', icon: 'starFilled', hint: String(starred), onClick: () => startSubset(null, 'write', 'starred') });
    }
    return modeRow({
      href: session ? writeHref(set.id) : writeHref(set.id, 'new=1'),
      iconName: 'keyboard',
      title: session ? 'Schreiben fortsetzen' : 'Schreiben',
      detail: session ? sessionDetail(session) : `Jede Karte schriftlich · ${answerLabel(set, m.options)}`,
      active: !!session,
      fkey: 'write',
      keys: keyShortcut('L', true),
      items,
      menuLabel: 'Schreiben',
      moreLabel: 'Weitere Optionen zum Schreiben',
    });
  }

  // Karteikarten: continues the running deck (its detail and how many cards are known) or
  // starts one; «…» › «Karteikarten neu starten» while a deck runs.
  function flashcardsRow(m) {
    const { set, deck } = m;
    return modeRow({
      href: `#${modePath(set.id, 'flashcards')}`,
      iconName: 'cards',
      title: 'Karteikarten',
      detail: deck ? deckDetail(deck) : FLASHCARDS_TAGLINE,
      active: !!deck,
      progress: deck ? deckKnownShare(deck) : null,
      fkey: 'flashcards',
      items: deck ? [{ label: 'Karteikarten neu starten', icon: 'rotate', onClick: () => restartFlashcards() }] : [],
      menuLabel: 'Karteikarten',
      moreLabel: 'Weitere Optionen für Karteikarten',
    });
  }

  // Prüfung: opens the exam's setup page.
  function examRow(m) {
    return modeRow({
      href: `#${modePath(m.set.id, 'exam')}`,
      iconName: 'graduationCap',
      title: 'Prüfung',
      detail: EXAM_TAGLINE,
      fkey: 'exam',
    });
  }

  function buildProgress() {
    const ringEl = ring({ value: 0, size: 112, label: '0 %', sublabel: 'gemeistert' });
    const items = {};
    const legend = h(
      'ul',
      { class: 'set-legend', role: 'list' },
      STATUS_KEYS.map((key) => {
        const count = h('span', { class: 'set-legend__count' }, '0');
        const btn = h(
          'button',
          { type: 'button', class: 'set-legend__item', onClick: () => showFilter(key) },
          h('span', { class: `ui-dot ui-dot--${key}`, 'aria-hidden': 'true' }),
          h('span', { class: 'set-legend__label' }, STATUS[key]),
          count,
          icon('chevronRight', { size: 16, className: 'set-legend__chevron' }),
        );
        items[key] = { btn, count };
        return h('li', null, btn);
      }),
    );
    const caption = h('p', { class: 'set-progress__caption' });
    const el = h(
      'section',
      { class: 'set-card set-progress', 'aria-labelledby': 'set-progress-title' },
      h('h2', { class: 'ui-eyebrow set-card__eyebrow', id: 'set-progress-title' }, 'Fortschritt'),
      h('div', { class: 'set-progress__body' }, ringEl, legend),
      caption,
    );

    let painted = false;
    let target = { value: 0, label: '0 %' };
    el.update = (m) => {
      const { stats } = m;
      const counts = { mastered: stats.mastered, learning: stats.learning, new: stats.fresh };
      for (const key of STATUS_KEYS) {
        items[key].count.textContent = String(counts[key]);
        items[key].btn.setAttribute('aria-label', `${STATUS[key]}: ${plural(counts[key], 'Begriff', 'Begriffe')} anzeigen`);
      }
      ringEl.classList.toggle('ui-ring--success', stats.total > 0 && stats.mastered === stats.total);
      caption.textContent = progressCaption(stats);
      target = { value: stats.total ? stats.percent / 100 : 0, label: `${stats.percent} %` };
      if (painted) {
        ringEl.update(target.value, target.label, 'gemeistert');
        return;
      }
      // First paint: start empty and let the arc sweep in.
      ringEl.update(0, target.label, 'gemeistert');
      if (!raf) {
        raf = requestAnimationFrame(() => {
          raf = requestAnimationFrame(() => {
            raf = 0;
            painted = true;
            if (!disposed) ringEl.update(target.value, target.label, 'gemeistert');
          });
        });
      }
    };
    return el;
  }

  function buildRow(card, m) {
    const termId = `set-term-${card.id}`;
    // The progress detail is a tooltip (hover, touch tap) plus sr-only text; tabindex -1
    // keeps a long list from getting one Tab stop per row (see components.js tooltips).
    const status = h('span', { class: 'set-status', tabindex: '-1' });
    const statusDetail = h('span', { class: 'sr-only' });
    const star = starButton({ starred: card.starred, size: 'sm', onToggle: (next) => toggleStar(card.id, next) });
    star.setAttribute('data-fkey', `star:${card.id}`);
    star.setAttribute('aria-describedby', termId);
    const speaker =
      speechOk && card.term
        ? iconButton({
            icon: 'volume',
            label: 'Vorlesen',
            size: 'sm',
            onClick: () => speak(card.term, m.set.termLang),
            attrs: { 'data-fkey': `speak:${card.id}`, 'aria-describedby': termId },
          })
        : null;
    const el = h(
      'li',
      { class: 'set-term' },
      status,
      h('p', { class: ['set-term__term', !card.term && 'is-empty'], id: termId, lang: langAttr(m.set.termLang) }, card.term || '–'),
      h('p', { class: ['set-term__def', !card.definition && 'is-empty'], lang: langAttr(m.set.defLang) }, card.definition || '–'),
      h('div', { class: 'set-term__actions' }, speaker, star),
    );
    const row = {
      el,
      status: null,
      starred: !!card.starred,
      update(nextStatus, progress, starred) {
        if (nextStatus !== row.status) {
          row.status = nextStatus;
          el.dataset.status = nextStatus;
          status.className = `set-status set-status--${nextStatus}`;
          status.replaceChildren(
            h('span', { class: `ui-dot ui-dot--${nextStatus}`, 'aria-hidden': 'true' }),
            h('span', { class: 'set-status__label' }, STATUS[nextStatus]),
            statusDetail,
          );
        }
        const detail = progressTitle(progress);
        status.dataset.tooltip = detail;
        statusDetail.textContent = ` (${detail})`;
        if (!!starred !== row.starred) {
          row.starred = !!starred;
          star.setStarred(row.starred);
        }
      },
    };
    row.update(m.status.get(card.id), m.progress[card.id], card.starred);
    return row;
  }

  function renderList(m, { animate = false } = {}) {
    const cards = visibleCards(filter, m);
    visibleIds = cards.map((c) => c.id);
    rows = new Map();
    const slot = view.listSlot;
    keepFocus(slot, () => {
      if (!m.set.cards.length) {
        slot.replaceChildren(
          emptyState({
            icon: 'layers',
            title: 'Noch keine Begriffe',
            text: 'Tippe Begriffe ein oder importiere eine Vokabelliste.',
            action: button({ label: 'Begriffe hinzufügen', icon: 'plus', variant: 'primary', href: editHref(m.set.id) }),
          }),
        );
        return;
      }
      if (!cards.length) {
        slot.replaceChildren(filterEmpty(filter));
        return;
      }
      const items = cards.map((card) => {
        const row = buildRow(card, m);
        rows.set(card.id, row);
        return row.el;
      });
      slot.replaceChildren(h('ul', { class: 'set-list', role: 'list', 'aria-label': 'Begriffe' }, items));
    });
    if (animate) replayClass(slot, 'set-fade');
  }

  function filterEmpty(key) {
    const info = FILTER_EMPTY[key] || FILTER_EMPTY.new;
    return h(
      'div',
      { class: 'set-empty' },
      h('span', { class: 'set-empty__icon', 'aria-hidden': 'true' }, icon(info.icon, { size: 22 })),
      h('p', { class: 'set-empty__title' }, info.title),
      h('p', { class: 'set-empty__text' }, info.text),
      button({ label: 'Alle Begriffe anzeigen', variant: 'ghost', size: 'sm', onClick: () => setFilter('all') }),
    );
  }

  /* -------------------------------------------------------------- refresh */

  function showMissing() {
    view = null;
    model = null;
    sigs = {};
    rows = new Map();
    visibleIds = [];
    if (missingShown) return;
    missingShown = true;
    setTitle('Lernset nicht gefunden');
    root.replaceChildren(missingView());
  }

  function refresh({ refilter = true } = {}) {
    const m = readModel(setId);
    if (!m) {
      showMissing();
      return;
    }
    if (!view) buildView();
    model = m;
    const { set } = m;

    const headSig = JSON.stringify([
      set.title,
      set.description,
      set.termLang,
      set.defLang,
      set.cards.length,
      set.lastStudiedAt ? relativeTime(set.lastStudiedAt) : null,
    ]);
    if (headSig !== sigs.head) {
      sigs.head = headSig;
      keepFocus(view.headSlot, () => view.headSlot.replaceChildren(buildHeader(m)));
      setTitle(set.title);
    }

    const studySig = JSON.stringify([
      m.learn ? [learnDetail(m.learn), Math.round(m.learn.counts.progress * 1000)] : null,
      m.session ? sessionDetail(m.session) : null,
      m.deck ? [deckDetail(m.deck), Math.round(deckKnownShare(m.deck) * 1000), !!m.deck.starredOnly] : null,
      m.stats.total,
      m.stats.mastered,
      m.starred,
      m.difficult.length,
      m.options && m.options.answerWith,
      m.options && learnTagline(m.options),
      set.termLang,
      set.defLang,
    ]);
    if (studySig !== sigs.study) {
      sigs.study = studySig;
      fillStudy(m);
    }

    view.progress.update(m);

    const counts = {
      all: m.stats.total,
      new: m.stats.fresh,
      learning: m.stats.learning,
      mastered: m.stats.mastered,
      starred: m.starred,
      difficult: m.difficult.length,
    };
    for (const f of FILTERS) view.chips[f.value].setCount(counts[f.value]);
    view.countBadge.textContent = String(m.stats.total);
    const hasCards = set.cards.length > 0;
    view.hero.hidden = !hasCards;
    view.filterBar.hidden = !hasCards;
    view.foot.hidden = !hasCards;

    const listSig = JSON.stringify([set.termLang, set.defLang, set.cards.map((c) => [c.id, c.term, c.definition])]);
    const ids = visibleCards(filter, m).map((c) => c.id);
    const membershipChanged = ids.length !== visibleIds.length || ids.some((id, i) => id !== visibleIds[i]);
    if (listSig !== sigs.list || (refilter && membershipChanged)) {
      sigs.list = listSig;
      renderList(m);
    } else {
      // Keep rows in place (e.g. a just-unstarred card under "Markiert") and patch them.
      for (const card of set.cards) {
        const row = rows.get(card.id);
        if (row) row.update(m.status.get(card.id), m.progress[card.id], card.starred);
      }
    }
  }

  /* -------------------------------------------------------------- actions */

  function setFilter(next) {
    if (!view || !model) return;
    filter = FILTERS.some((f) => f.value === next) ? next : 'all';
    filterMemory.set(setId, filter);
    for (const f of FILTERS) view.chips[f.value].setSelected(f.value === filter);
    renderList(model, { animate: true });
    view.live.textContent = `${plural(visibleIds.length, 'Begriff', 'Begriffe')} angezeigt`;
  }

  function showFilter(key) {
    setFilter(key);
    if (!view) return;
    const target = view.chips[key];
    if (target) target.focus({ preventScroll: true });
    view.terms.scrollIntoView({ behavior: prefersReducedMotion() ? 'auto' : 'smooth', block: 'start' });
  }

  function toggleStar(cardId, next) {
    softUpdate = true;
    try {
      return db.toggleStar(setId, cardId);
    } catch (err) {
      toast(errorMessage(err), { tone: 'danger' });
      return !next;
    } finally {
      softUpdate = false;
    }
  }

  function openActions(anchor) {
    const m = model;
    if (!m) return;
    menu(
      anchor,
      [
        { label: 'Duplizieren', icon: 'copy', onClick: duplicate },
        { label: 'Als Text exportieren', icon: 'download', disabled: !m.set.cards.length, onClick: () => model && openExport(model.set) },
        { divider: true, label: 'Fortschritt zurücksetzen', icon: 'rotate', disabled: !m.canReset, onClick: resetProgress },
        { label: 'Löschen', icon: 'trash', danger: true, onClick: removeSet },
      ],
      { label: 'Aktionen für dieses Lernset' },
    );
  }

  // The subset shortcuts start a new round of `mode` ('learn' | 'write'). A
  // round the learner already answered in is only given up after asking (one
  // stored round per set and mode). `event` is the link click, or null from a menu.
  async function startSubset(event, mode, subset) {
    const path = modePath(setId, mode, `new=1&subset=${subset}`);
    const running = model && (mode === 'learn' ? model.learn : model.session);
    const answered = running && (mode === 'learn' ? learnHasAnswers(running.state) : hasAnswers(running.state));
    if (!answered) {
      // Nothing to lose: links simply follow their href.
      if (!event) navigate(path);
      return;
    }
    if (event) event.preventDefault();
    const info = SUBSET_CONFIRM[mode];
    const detail = mode === 'learn' ? learnDetail(running) : sessionDetail(running);
    const ok = await confirmDialog({
      title: info.confirmTitle,
      message: `${info.saved} (${detail}) endet, wenn du jetzt nur ${SUBSET_WHAT[subset]} ${info.verb}. Dein Lernfortschritt bleibt erhalten.`,
      confirmLabel: info.confirmLabel,
      danger: false,
    });
    if (!ok || disposed) return;
    leaving = true;
    try {
      // The study screen would ask again for a subset link while a round is stored.
      if (mode === 'learn') db.clearLearn(setId);
      else db.clearSession(setId);
    } catch {
      // The study screen starts fresh anyway (new=1).
    }
    navigate(path);
  }

  // "Neu starten" next to a running Learn session: a session with answers only
  // ends after asking, with the words of Learn's own "Neu starten?".
  async function restartLearn(event) {
    const running = model && model.learn;
    if (!running || !learnHasAnswers(running.state)) return; // the link starts over at once
    event.preventDefault();
    const ok = await confirmDialog({
      title: 'Neu starten?',
      message: restartSessionMessage(learnSubsetQuery(running.state) || 'all'),
      confirmLabel: 'Neu starten',
      danger: false,
    });
    if (!ok || disposed) return;
    leaving = true;
    const sub = learnSubsetQuery(running.state);
    navigate(modePath(setId, 'learn', sub ? `new=1&subset=${sub}` : 'new=1'));
  }

  // «Nur schwierige»: Lernen with the cards answered wrong at least 4 times (no repetition
  // questions); a running Lerneinheit with answers only ends after asking (learn-start.js).
  async function startDifficult() {
    const m = model;
    if (!m || !m.difficult.length || leaving) return;
    await startLearnWithCards({
      setId,
      cardIds: m.difficult.map((c) => c.id),
      review: false,
      navigate,
      scope: 'schwierigen Begriffe',
      // Once confirmed the page is on its way out (the ended session must not redraw the hero
      // for a frame); a page left while the dialog was open starts nothing.
      confirm: async (options) => {
        const ok = (await confirmDialog({ ...options, danger: false })) && !disposed;
        if (ok) leaving = true;
        return ok;
      },
    });
  }

  // «Karteikarten neu starten»: the same cards (all or the starred ones) from the start; a
  // deck with sorted cards only starts over after asking (Mac restartFlashcards).
  async function restartFlashcards() {
    const deck = model && model.deck;
    const query = deck && deck.starredOnly ? 'new=1&subset=starred' : 'new=1';
    if (deck) {
      const ok = await confirmDialog({
        title: 'Karteikarten neu starten?',
        message: deckRestartMessage(deck),
        confirmLabel: 'Neu starten',
        danger: false,
      });
      if (!ok || disposed) return;
    }
    leaving = true;
    try {
      db.clearFlashcards(setId);
    } catch {
      // The flashcards screen starts a new deck anyway (new=1).
    }
    navigate(modePath(setId, 'flashcards', query));
  }

  // Ctrl+L Lernen / Weiterlernen, Ctrl+Shift+L Schreiben, Ctrl+E Bearbeiten (Mac: ⌘L, ⇧⌘L,
  // ⌘E), and Enter starts Lernen like the Mac's «Lernen ↩» when no control has the focus. Not
  // while typing or with a dialog open; held keys repeat nothing.
  function onKeydown(e) {
    if (e.defaultPrevented || e.isComposing || !model || !view) return;
    if (isPlainEnter(e)) {
      // An Enter that just brought us here (Learn's «Zurück zum Lernset») starts nothing.
      if (e.repeat || leaving || Date.now() - shownAt < ENTER_GATE_MS || hasOpenModal()) return;
      if (!model.set.cards.length || isInteractive(e.target)) return;
      e.preventDefault();
      navigate(modePath(model.set.id, 'learn', model.learn ? '' : 'new=1'));
      return;
    }
    const command = setPageCommand(e);
    if (!command || isTypingTarget(e.target) || hasOpenModal()) return;
    e.preventDefault();
    if (e.repeat || leaving) return;
    const { set, learn, session } = model;
    if (command === 'edit') {
      navigate(`${setPath(set.id)}/edit`);
      return;
    }
    if (!set.cards.length) return;
    if (command === 'learn') navigate(modePath(set.id, 'learn', learn ? '' : 'new=1'));
    else navigate(modePath(set.id, 'write', session ? '' : 'new=1'));
  }

  function duplicate() {
    try {
      const copy = db.duplicateSet(setId);
      toast('Lernset dupliziert', { tone: 'success', action: { label: 'Öffnen', onClick: () => navigate(setPath(copy.id)) } });
    } catch (err) {
      toast(errorMessage(err), { tone: 'danger' });
    }
  }

  async function resetProgress() {
    const ok = await confirmDialog({
      title: 'Fortschritt zurücksetzen?',
      message: 'Alle Begriffe gelten danach wieder als «Neu», und laufende Runden in Lernen und Schreiben werden beendet. Die Begriffe selbst bleiben erhalten.',
      confirmLabel: 'Zurücksetzen',
    });
    if (!ok || disposed) return;
    try {
      db.resetProgress(setId);
      toast('Fortschritt zurückgesetzt', { tone: 'success' });
    } catch (err) {
      toast(errorMessage(err), { tone: 'danger' });
    }
  }

  async function removeSet() {
    const m = model;
    if (!m) return;
    const ok = await confirmDialog({
      title: 'Lernset löschen?',
      message: `«${m.set.title}» mit ${plural(m.set.cards.length, 'Begriff', 'Begriffen')} und dein Lernfortschritt werden gelöscht.`,
      confirmLabel: 'Löschen',
    });
    if (!ok || disposed) return;
    const snapshot = db.snapshotSet(setId);
    leaving = true;
    try {
      db.deleteSet(setId);
    } catch (err) {
      leaving = false;
      toast(errorMessage(err), { tone: 'danger' });
      return;
    }
    navigate('/');
    toast('Lernset gelöscht', { duration: 6000, action: { label: 'Rückgängig', onClick: () => restoreSet(snapshot) } });
  }

  /* ------------------------------------------------------------ lifecycle */

  refresh();
  const unsubscribe = db.subscribe(() => {
    if (disposed || leaving) return;
    refresh({ refilter: !softUpdate });
  });
  document.addEventListener('keydown', onKeydown);

  return () => {
    disposed = true;
    document.removeEventListener('keydown', onKeydown);
    unsubscribe();
    if (raf) cancelAnimationFrame(raf);
    raf = 0;
    stopSpeaking();
  };
}
