// Parity fixture for src/lib/time.js → Fixtures/time.json. Run with TZ=Europe/Zurich.
// fns: dateKey [ts], formatDate [ts|null], calendarDaysBetween [from, to], relativeTime [ts|null, now],
//      formatDuration [ms], localTimestamp [y, m(1-12), d, hh, mm, ss] (JS `new Date(y, m - 1, …).getTime()`)
import { dateKey, formatDate, calendarDaysBetween, relativeTime, formatDuration } from '../../Website/src/lib/time.js';
import { Cases, mulberry32, randInt, pick } from './lib.js';

const cases = new Cases('time');
const SEC = 1000;
const MIN = 60 * SEC;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const at = (y, mo, d, hh = 12, mm = 0, ss = 0) => new Date(y, mo - 1, d, hh, mm, ss).getTime();

// 1. Inputs of tests/time.test.js
const NOW = at(2026, 10, 11, 14, 0);
const testTimes = [
  at(2026, 1, 5, 9, 30), at(2026, 12, 31, 23, 59, 59), at(2027, 1, 1, 0, 0, 0), at(2026, 9, 12, 0, 30),
  at(2026, 9, 12, 23, 30), new Date(2026, 2, 7, 8).getTime(), at(2026, 9, 12), at(2026, 1, 1),
];
for (const t of testTimes) {
  cases.add('dateKey', [t], dateKey(t));
  cases.add('formatDate', [t], formatDate(t));
}
cases.add('formatDate', [null], formatDate(null));
const relPairs = [
  [NOW, NOW], [NOW - 10 * SEC, NOW], [NOW - 59 * SEC, NOW], [NOW + 5 * SEC, NOW], [NOW - 60 * SEC, NOW],
  [NOW - 119 * SEC, NOW], [NOW - 5 * MIN, NOW], [NOW - 59 * MIN - 59 * SEC, NOW], [NOW - HOUR, NOW],
  [NOW - HOUR - 59 * MIN, NOW], [NOW - 2 * HOUR, NOW], [at(2026, 10, 11, 0, 30), NOW], [at(2026, 10, 10, 20, 0), NOW],
  [at(2026, 10, 10, 0, 1), NOW], [at(2026, 10, 10, 22, 0), at(2026, 10, 11, 1, 0)],
  [at(2026, 10, 10, 23, 50), at(2026, 10, 11, 0, 10)], [at(2026, 10, 9, 18, 0), NOW], [at(2026, 10, 8, 9, 0), NOW],
  [at(2026, 10, 5, 23, 59), NOW], [at(2026, 10, 4, 12, 0), NOW], [at(2026, 9, 12, 9, 15), NOW],
  [at(2025, 12, 31, 23, 0), NOW], [at(2026, 9, 30, 21, 0), at(2026, 10, 1, 9, 0)],
  [at(2025, 12, 30, 12, 0), at(2026, 1, 1, 12, 0)], [null, NOW],
];
for (const [t, n] of relPairs) cases.add('relativeTime', [t, n], relativeTime(t, n));
const dayPairs = [
  [at(2026, 10, 11, 23, 59), at(2026, 10, 12, 0, 1)], [at(2026, 10, 11, 0, 1), at(2026, 10, 11, 23, 59)],
  [at(2026, 3, 28, 12), at(2026, 3, 29, 12)], [at(2026, 3, 29, 12), at(2026, 3, 30, 12)],
  [at(2026, 10, 24, 12), at(2026, 10, 26, 12)], [at(2026, 10, 12), at(2026, 10, 11)],
];
for (const [a, b] of dayPairs) cases.add('calendarDaysBetween', [a, b], calendarDaysBetween(a, b));
for (const ms of [45 * SEC, SEC, 0, 499, 500, 4 * MIN + 12 * SEC, 4 * MIN, 59 * SEC + 600, 59 * MIN + 59 * SEC, HOUR,
  HOUR + 5 * MIN, 2 * HOUR + 5 * MIN + 30 * SEC, -5000, 90000]) {
  cases.add('formatDuration', [ms], formatDuration(ms));
}

// 2. Systematic: DST transitions (Europe/Zurich, last Sunday of March/October), midnights,
//    month/year ends; ±1 ms, ±1 min, ±1 h around each
const rng = mulberry32(777);
const lastSunday = (y, m) => {
  const d = new Date(y, m, 0); // last day of month m (1-based)
  return d.getDate() - d.getDay();
};
const anchors = [];
for (let y = 1975; y <= 2040; y++) {
  for (const m of [3, 10]) {
    const d = lastSunday(y, m);
    for (const hh of [0, 1, 2, 3, 4, 12, 23]) anchors.push(at(y, m, d, hh, 0, 0));
  }
  anchors.push(at(y, 1, 1, 0, 0, 0), at(y, 12, 31, 23, 59, 59), at(y, 2, 28, 12), at(y, 3, 1, 0, 0, 0));
}
for (const a of anchors) {
  for (const delta of [0, -1, 1, -MIN, MIN, -HOUR, HOUR]) {
    const t = a + delta;
    cases.add('dateKey', [t], dateKey(t));
  }
}
// Random timestamps 1900…2100 (some with fractional milliseconds)
for (let i = 0; i < 1500; i++) {
  let t = Math.floor(-2208988800000 + rng() * (4102444800000 + 2208988800000));
  if (i % 7 === 0) t += Math.round(rng() * 1000) / 1000;
  cases.add('dateKey', [t], dateKey(t));
  if (i % 3 === 0) cases.add('formatDate', [t], formatDate(t));
}
// Before 1970 and the 1900 boundary (historic offsets)
for (const t of [-1, 0, 1, -DAY, -2208988800000, -2208992400000, -1e12, 1e12, 2e12, 4102444800000]) {
  cases.add('dateKey', [t], dateKey(t));
  cases.add('formatDate', [t], formatDate(t));
}

// calendarDaysBetween: random pairs within ±40 days, across DST
for (let i = 0; i < 800; i++) {
  const a = pick(rng, anchors) + randInt(rng, -2 * DAY, 2 * DAY);
  const b = a + randInt(rng, -40 * DAY, 40 * DAY);
  cases.add('calendarDaysBetween', [a, b], calendarDaysBetween(a, b));
}

// relativeTime: interesting deltas against random "now" values
const DELTAS = [
  -HOUR, -MIN, -SEC, 0, 1, SEC, 30 * SEC, 59 * SEC, 59 * SEC + 999, MIN, MIN + 1, 2 * MIN - 1, 2 * MIN, 5 * MIN,
  59 * MIN, HOUR - 1, HOUR, HOUR + 1, 2 * HOUR - 1, 2 * HOUR, 5 * HOUR, 11 * HOUR, 13 * HOUR, 23 * HOUR,
  DAY - 1, DAY, DAY + HOUR, 2 * DAY, 3 * DAY, 6 * DAY, 6 * DAY + 23 * HOUR, 7 * DAY, 8 * DAY, 30 * DAY, 400 * DAY,
];
for (let i = 0; i < 120; i++) {
  const now = pick(rng, anchors) + randInt(rng, 0, DAY);
  for (const d of DELTAS) cases.add('relativeTime', [now - d, now], relativeTime(now - d, now));
}
for (let i = 0; i < 400; i++) {
  const now = pick(rng, anchors) + randInt(rng, -DAY, DAY);
  const ts = now - randInt(rng, -2 * MIN, 12 * DAY);
  cases.add('relativeTime', [ts, now], relativeTime(ts, now));
}

// formatDuration: boundaries, fractions and large values
for (let s = 0; s <= 7400; s += 37) cases.add('formatDuration', [s * SEC], formatDuration(s * SEC));
for (let i = 0; i < 600; i++) {
  const ms = pick(rng, [
    randInt(rng, 0, 120000), randInt(rng, 0, 10 * HOUR), randInt(rng, -10000, 10000), rng() * 100000,
    randInt(rng, 0, 3600) * SEC + 500, randInt(rng, 0, 1e7) * SEC,
  ]);
  cases.add('formatDuration', [ms], formatDuration(ms));
}
for (const ms of [1499, 1500, 1500.5, 2500, -499, -500, -501, 3599499, 3599500, 3600000, 86400000, 1e12, 1e15]) {
  cases.add('formatDuration', [ms], formatDuration(ms));
}

// localTimestamp: JS local-time construction incl. DST gaps and ambiguous hours
for (let y = 2018; y <= 2032; y++) {
  for (const m of [3, 10]) {
    const d = lastSunday(y, m);
    for (const [hh, mm] of [[0, 0], [1, 30], [1, 59], [2, 0], [2, 30], [2, 59], [3, 0], [3, 30], [12, 0]]) {
      cases.add('localTimestamp', [y, m, d, hh, mm, 0], new Date(y, m - 1, d, hh, mm, 0).getTime());
    }
  }
}
for (let i = 0; i < 300; i++) {
  const args = [randInt(rng, 1900, 2100), randInt(rng, 1, 12), randInt(rng, 1, 28), randInt(rng, 0, 23), randInt(rng, 0, 59), randInt(rng, 0, 59)];
  cases.add('localTimestamp', args, new Date(args[0], args[1] - 1, args[2], args[3], args[4], args[5]).getTime());
}

cases.emit();
