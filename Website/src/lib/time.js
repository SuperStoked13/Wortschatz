// German date/time helpers. Pure: no DOM, runs under jsc.

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

const pad = (n) => String(n).padStart(2, '0');

function toDate(ts) {
  if (ts == null || ts === '') return null;
  const d = ts instanceof Date ? new Date(ts.getTime()) : new Date(Number(ts));
  return Number.isNaN(d.getTime()) ? null : d;
}

// Local calendar day as 'YYYY-MM-DD'.
export function dateKey(ts = Date.now()) {
  const d = toDate(ts) || new Date();
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

// Local date as 'DD.MM.YYYY'.
export function formatDate(ts) {
  const d = toDate(ts);
  if (!d) return '';
  return `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()}`;
}

// Whole local calendar days from `from` to `to` (DST-safe).
export function calendarDaysBetween(from, to) {
  const a = toDate(from);
  const b = toDate(to);
  if (!a || !b) return 0;
  const dayA = Date.UTC(a.getFullYear(), a.getMonth(), a.getDate());
  const dayB = Date.UTC(b.getFullYear(), b.getMonth(), b.getDate());
  return Math.round((dayB - dayA) / DAY);
}

// 'gerade eben' | 'vor 5 Minuten' | 'vor 2 Stunden' | 'gestern' | 'vor 3 Tagen' | 'am 12.09.2026'
export function relativeTime(ts, now = Date.now()) {
  const then = toDate(ts);
  const ref = toDate(now);
  if (!then || !ref) return '';
  const diff = ref.getTime() - then.getTime();
  if (diff < MINUTE) return 'gerade eben'; // also absorbs small clock skew into the future
  if (diff < HOUR) {
    const m = Math.floor(diff / MINUTE);
    return m === 1 ? 'vor 1 Minute' : `vor ${m} Minuten`;
  }
  const days = calendarDaysBetween(then, ref);
  if (days <= 0) {
    const hrs = Math.floor(diff / HOUR);
    return hrs === 1 ? 'vor 1 Stunde' : `vor ${hrs} Stunden`;
  }
  if (days === 1) return 'gestern';
  if (days < 7) return `vor ${days} Tagen`;
  return `am ${formatDate(then)}`;
}

// '1 Std. 5 Min.' | '4 Min. 12 Sek.' | '4 Min.' | '45 Sek.'
export function formatDuration(ms) {
  const total = Math.max(0, Math.round((Number(ms) || 0) / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return m > 0 ? `${h} Std. ${m} Min.` : `${h} Std.`;
  if (m > 0) return s > 0 ? `${m} Min. ${s} Sek.` : `${m} Min.`;
  return `${s} Sek.`;
}
