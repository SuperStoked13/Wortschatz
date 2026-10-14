// The daily Lernserie outside the dashboard, a port of the Mac app's sidebar footer and
// AppModel.celebrateDailyStreak: an always-visible indicator in the app header («6 Tage
// Lernserie · Heute geschafft») and, once a day, a flame toast with a short fanfare after
// the first answer in Lernen or Schreiben. The copy helpers are pure and shared with the
// dashboard's Lernserie tile; the DOM parts only touch the document when called.

import { h, replayClass } from '../lib/dom.js';
import { icon } from './icons.js';
import { toast } from './components.js';
import { plural } from '../lib/labels.js';
import { dateKey } from '../lib/time.js';
import { PREF, getPref, setPref } from '../lib/prefs.js';
import { playSound } from '../lib/sounds.js';
import { studyStreak } from '../core/mastery.js';
import { db } from '../store/db.js';

// Mac: the toast comes a moment late so the fanfare does not sound over the answer's chime.
export const CELEBRATE_DELAY_MS = 650;
export const CELEBRATE_TOAST_MS = 3500;

// Only answers count (Karteikarten and Prüfung record no activity).
const STUDY_ROUTES = new Set(['learn', 'write']);

// Narrow windows show the flame and the number only (the phone layout of the header).
const COMPACT_QUERY = '(max-width: 560px)';

/* ------------------------------------------------------------------ copy */

const days = (n) => plural(n, 'Tag', 'Tage');

// 'lit' (answered today), 'pending' (a streak waits for today's answers) or 'off'.
export function streakTone(streak) {
  if (streak && streak.today > 0) return 'lit';
  if (streak && streak.current > 0) return 'pending';
  return 'off';
}

// «6 Tage Lernserie», «1 Tag Lernserie» or «Noch keine Lernserie».
export function streakTitle(streak) {
  const current = streak ? streak.current : 0;
  return current > 0 ? `${days(current)} Lernserie` : 'Noch keine Lernserie';
}

// «Heute geschafft», «Heute noch lernen», «Rekord: 9 Tage» or «Lerne heute, um zu starten».
export function streakCaption(streak) {
  const s = streak || {};
  if (s.today > 0) return 'Heute geschafft';
  if (s.current > 0) return 'Heute noch lernen';
  if (s.longest > 0) return `Rekord: ${days(s.longest)}`;
  return 'Lerne heute, um zu starten';
}

// «Längste Serie: 9 Tage»; empty before the first streak.
export function streakTooltip(streak) {
  return streak && streak.longest > 0 ? `Längste Serie: ${days(streak.longest)}` : '';
}

// The once-a-day toast.
export function celebrationMessage(current) {
  return current === 1 ? 'Neue Lernserie gestartet – lerne morgen weiter!' : `Lernserie: ${current} Tage in Folge!`;
}

// Whether today's Lernserie still deserves its toast: answered today, a streak is running and
// today was not celebrated yet (`celebratedDay` is the stored 'YYYY-MM-DD').
export function shouldCelebrate(streak, celebratedDay, today) {
  return !!streak && streak.today > 0 && streak.current > 0 && celebratedDay !== today;
}

// Milliseconds from `now` until the next local midnight (DST-safe: built from the calendar).
export function msUntilMidnight(now = Date.now()) {
  const next = new Date(now);
  next.setHours(24, 0, 0, 0);
  return Math.max(0, next.getTime() - now);
}

/* ------------------------------------------------------------- indicator */

// The header indicator: flame, «N Tage Lernserie» and the caption; `update(streak)` redraws it.
export function createStreakIndicator() {
  const flame = h('span', { class: 'app-streak__flame', 'aria-hidden': 'true' }, icon('flameFilled', { size: 18 }));
  const count = h('span', { class: 'app-streak__count', 'aria-hidden': 'true' });
  const title = h('span', { class: 'app-streak__title' });
  const caption = h('span', { class: 'app-streak__caption' });
  const longest = h('span', { class: 'sr-only' });
  const el = h(
    'div',
    { class: 'app-streak', dataset: { tone: 'off' } },
    flame,
    count,
    h('span', { class: 'app-streak__text' }, title, caption),
    longest,
  );

  const mql = typeof matchMedia === 'function' ? matchMedia(COMPACT_QUERY) : null;
  let shown = null;

  // Wide: the record only (title and caption are on screen); compact: everything.
  function syncTooltip() {
    if (!shown) return;
    const record = streakTooltip(shown);
    const text = mql && mql.matches ? [streakTitle(shown), streakCaption(shown), record].filter(Boolean).join(' · ') : record;
    if (text) el.dataset.tooltip = text;
    else delete el.dataset.tooltip;
  }
  if (mql) {
    if (typeof mql.addEventListener === 'function') mql.addEventListener('change', syncTooltip);
    else if (typeof mql.addListener === 'function') mql.addListener(syncTooltip);
  }

  el.update = (streak) => {
    const next = { current: streak.current || 0, today: streak.today || 0, longest: streak.longest || 0 };
    const tone = streakTone(next);
    const grew = !!shown && (next.current > shown.current || (tone === 'lit' && shown.today === 0));
    if (shown && shown.current === next.current && (shown.today > 0) === (next.today > 0) && shown.longest === next.longest) return;
    shown = next;
    el.dataset.tone = tone;
    title.textContent = streakTitle(next);
    caption.textContent = streakCaption(next);
    count.textContent = next.current > 0 ? String(next.current) : '';
    const record = streakTooltip(next);
    longest.textContent = record ? ` ${record}` : '';
    syncTooltip();
    // The flame hops when the streak goes on (like the Mac footer's bounce).
    if (grew) replayClass(flame, 'is-bumping');
  };
  return el;
}

/* --------------------------------------------------------------- watcher */

// Keeps `indicator` current (db changes, midnight, coming back to the window) and celebrates
// the first answer of a day in Lernen or Schreiben. Returns `stop`.
export function watchDailyStreak(indicator = null) {
  let midnightTimer = 0;
  let celebrateTimer = 0;
  let stopped = false;

  function read() {
    let activity = {};
    try {
      activity = db.getActivity();
    } catch {
      activity = {};
    }
    return studyStreak(activity, Date.now());
  }

  function refresh() {
    const streak = read();
    if (indicator && typeof indicator.update === 'function') indicator.update(streak);
    return streak;
  }

  function scheduleMidnight() {
    clearTimeout(midnightTimer);
    // A second late, so the new day has surely begun when the streak is read again.
    midnightTimer = setTimeout(() => {
      if (stopped) return;
      refresh();
      scheduleMidnight();
    }, msUntilMidnight(Date.now()) + 1000);
  }

  function celebrate(streak) {
    const route = typeof document !== 'undefined' ? document.documentElement.dataset.route : '';
    if (!STUDY_ROUTES.has(route)) return;
    const today = dateKey(Date.now());
    if (!shouldCelebrate(streak, getPref(PREF.streakCelebrated, null), today)) return;
    setPref(PREF.streakCelebrated, today);
    const message = celebrationMessage(streak.current);
    clearTimeout(celebrateTimer);
    celebrateTimer = setTimeout(() => {
      if (stopped) return;
      toast(message, { tone: 'streak', duration: CELEBRATE_TOAST_MS });
      playSound('dailyStreak');
    }, CELEBRATE_DELAY_MS);
  }

  const unsubscribe = db.subscribe((event) => {
    const keys = event && Array.isArray(event.keys) ? event.keys : null;
    if (keys && !keys.includes('activity')) return;
    const streak = refresh();
    // Only answers given in this window celebrate (another tab celebrates its own).
    if (event && event.type === 'local' && keys) celebrate(streak);
  });

  const onVisible = () => {
    if (document.visibilityState !== 'hidden') {
      refresh();
      scheduleMidnight();
    }
  };
  if (typeof document !== 'undefined') document.addEventListener('visibilitychange', onVisible);

  refresh();
  scheduleMidnight();

  return () => {
    stopped = true;
    clearTimeout(midnightTimer);
    clearTimeout(celebrateTimer);
    unsubscribe();
    if (typeof document !== 'undefined') document.removeEventListener('visibilitychange', onVisible);
  };
}
