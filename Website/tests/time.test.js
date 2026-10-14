import { test, expect, run } from './harness.js';
import { dateKey, relativeTime, formatDuration, formatDate, calendarDaysBetween } from '../src/lib/time.js';

// All timestamps are built in local time so the tests pass in any time zone.
const at = (y, mo, d, hh = 12, mm = 0, ss = 0) => new Date(y, mo - 1, d, hh, mm, ss).getTime();
const SEC = 1000;
const MIN = 60 * SEC;
const HOUR = 60 * MIN;

const NOW = at(2026, 10, 11, 14, 0);

test('dateKey: local YYYY-MM-DD with zero padding', () => {
  expect(dateKey(at(2026, 1, 5, 9, 30))).toBe('2026-01-05');
  expect(dateKey(at(2026, 12, 31, 23, 59, 59))).toBe('2026-12-31');
  expect(dateKey(at(2027, 1, 1, 0, 0, 0))).toBe('2027-01-01');
});

test('dateKey: uses the local day, not UTC', () => {
  expect(dateKey(at(2026, 9, 12, 0, 30))).toBe('2026-09-12');
  expect(dateKey(at(2026, 9, 12, 23, 30))).toBe('2026-09-12');
});

test('dateKey: accepts Date objects and defaults to now', () => {
  expect(dateKey(new Date(2026, 2, 7, 8))).toBe('2026-03-07');
  expect(/^\d{4}-\d{2}-\d{2}$/.test(dateKey())).toBe(true);
  expect(dateKey()).toBe(dateKey(Date.now()));
});

test('relativeTime: "gerade eben" below one minute and for small future skew', () => {
  expect(relativeTime(NOW, NOW)).toBe('gerade eben');
  expect(relativeTime(NOW - 10 * SEC, NOW)).toBe('gerade eben');
  expect(relativeTime(NOW - 59 * SEC, NOW)).toBe('gerade eben');
  expect(relativeTime(NOW + 5 * SEC, NOW)).toBe('gerade eben');
});

test('relativeTime: minutes with singular and plural', () => {
  expect(relativeTime(NOW - 60 * SEC, NOW)).toBe('vor 1 Minute');
  expect(relativeTime(NOW - 119 * SEC, NOW)).toBe('vor 1 Minute');
  expect(relativeTime(NOW - 5 * MIN, NOW)).toBe('vor 5 Minuten');
  expect(relativeTime(NOW - 59 * MIN - 59 * SEC, NOW)).toBe('vor 59 Minuten');
});

test('relativeTime: hours on the same day', () => {
  expect(relativeTime(NOW - HOUR, NOW)).toBe('vor 1 Stunde');
  expect(relativeTime(NOW - HOUR - 59 * MIN, NOW)).toBe('vor 1 Stunde');
  expect(relativeTime(NOW - 2 * HOUR, NOW)).toBe('vor 2 Stunden');
  expect(relativeTime(at(2026, 10, 11, 0, 30), NOW)).toBe('vor 13 Stunden');
});

test('relativeTime: "gestern" for the previous calendar day', () => {
  expect(relativeTime(at(2026, 10, 10, 20, 0), NOW)).toBe('gestern');
  expect(relativeTime(at(2026, 10, 10, 0, 1), NOW)).toBe('gestern');
  // 3 hours ago but across midnight
  expect(relativeTime(at(2026, 10, 10, 22, 0), at(2026, 10, 11, 1, 0))).toBe('gestern');
  // across midnight but under an hour: minutes win
  expect(relativeTime(at(2026, 10, 10, 23, 50), at(2026, 10, 11, 0, 10))).toBe('vor 20 Minuten');
});

test('relativeTime: days for 2 to 6 days', () => {
  expect(relativeTime(at(2026, 10, 9, 18, 0), NOW)).toBe('vor 2 Tagen');
  expect(relativeTime(at(2026, 10, 8, 9, 0), NOW)).toBe('vor 3 Tagen');
  expect(relativeTime(at(2026, 10, 5, 23, 59), NOW)).toBe('vor 6 Tagen');
});

test('relativeTime: absolute date from 7 days on', () => {
  expect(relativeTime(at(2026, 10, 4, 12, 0), NOW)).toBe('am 04.10.2026');
  expect(relativeTime(at(2026, 9, 12, 9, 15), NOW)).toBe('am 12.09.2026');
  expect(relativeTime(at(2025, 12, 31, 23, 0), NOW)).toBe('am 31.12.2025');
});

test('relativeTime: crosses month and year boundaries by calendar day', () => {
  expect(relativeTime(at(2026, 9, 30, 21, 0), at(2026, 10, 1, 9, 0))).toBe('gestern');
  expect(relativeTime(at(2025, 12, 30, 12, 0), at(2026, 1, 1, 12, 0))).toBe('vor 2 Tagen');
});

test('relativeTime: accepts Date objects', () => {
  expect(relativeTime(new Date(NOW - 5 * MIN), new Date(NOW))).toBe('vor 5 Minuten');
});

test('relativeTime: empty string for missing or invalid input', () => {
  expect(relativeTime(null, NOW)).toBe('');
  expect(relativeTime(undefined, NOW)).toBe('');
  expect(relativeTime('', NOW)).toBe('');
  expect(relativeTime('kein Datum', NOW)).toBe('');
  expect(relativeTime(NaN, NOW)).toBe('');
});

test('calendarDaysBetween: counts local calendar days (DST-safe)', () => {
  expect(calendarDaysBetween(at(2026, 10, 11, 23, 59), at(2026, 10, 12, 0, 1))).toBe(1);
  expect(calendarDaysBetween(at(2026, 10, 11, 0, 1), at(2026, 10, 11, 23, 59))).toBe(0);
  // European DST changes (23 h and 25 h days) still count as one day
  expect(calendarDaysBetween(at(2026, 3, 28, 12), at(2026, 3, 29, 12))).toBe(1);
  expect(calendarDaysBetween(at(2026, 3, 29, 12), at(2026, 3, 30, 12))).toBe(1);
  expect(calendarDaysBetween(at(2026, 10, 24, 12), at(2026, 10, 26, 12))).toBe(2);
  expect(calendarDaysBetween(at(2026, 10, 12), at(2026, 10, 11))).toBe(-1);
});

test('formatDate: DD.MM.YYYY', () => {
  expect(formatDate(at(2026, 9, 12))).toBe('12.09.2026');
  expect(formatDate(at(2026, 1, 1))).toBe('01.01.2026');
  expect(formatDate(null)).toBe('');
});

test('formatDuration: seconds only below a minute', () => {
  expect(formatDuration(45 * SEC)).toBe('45 Sek.');
  expect(formatDuration(1 * SEC)).toBe('1 Sek.');
  expect(formatDuration(0)).toBe('0 Sek.');
  expect(formatDuration(499)).toBe('0 Sek.');
  expect(formatDuration(500)).toBe('1 Sek.');
});

test('formatDuration: minutes and seconds', () => {
  expect(formatDuration(4 * MIN + 12 * SEC)).toBe('4 Min. 12 Sek.');
  expect(formatDuration(4 * MIN)).toBe('4 Min.');
  expect(formatDuration(59 * SEC + 600)).toBe('1 Min.');
  expect(formatDuration(59 * MIN + 59 * SEC)).toBe('59 Min. 59 Sek.');
});

test('formatDuration: hours and minutes', () => {
  expect(formatDuration(HOUR)).toBe('1 Std.');
  expect(formatDuration(HOUR + 5 * MIN)).toBe('1 Std. 5 Min.');
  expect(formatDuration(2 * HOUR + 5 * MIN + 30 * SEC)).toBe('2 Std. 5 Min.');
});

test('formatDuration: robust against bad input', () => {
  expect(formatDuration(-5000)).toBe('0 Sek.');
  expect(formatDuration(NaN)).toBe('0 Sek.');
  expect(formatDuration(undefined)).toBe('0 Sek.');
  expect(formatDuration('90000')).toBe('1 Min. 30 Sek.');
});

await run('time.test.js');
