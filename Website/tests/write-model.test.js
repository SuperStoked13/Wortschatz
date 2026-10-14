// Write mode's pure helpers (src/screens/write-model.js): synonym-aware grading of the
// main answer, the copy step, resuming a pending "Nicht ganz" screen, re-showing the
// results of a finished session, the compact time of the results screen and the
// phone layout of the special-character keys.
import { test, expect, run } from './harness.js';
import {
  questionInfo,
  gradeQuestion,
  copyAccepted,
  pendingFeedback,
  canShowResults,
  canResume,
  compactDuration,
  charColumns,
} from '../src/screens/write-model.js';
import { NOTE_LABELS } from '../src/lib/labels.js';
import { SPECIAL_CHARS } from '../src/lib/keyboard.js';
import { DEFAULT_TOLERANCE } from '../src/core/grading.js';
import * as S from '../src/core/session.js';

const TOL = DEFAULT_TOLERANCE;

const SET = {
  id: 's1',
  title: 'Personen',
  termLang: 'fr',
  defLang: 'de',
  cards: [
    { id: 'laid', term: 'laid, laide', definition: 'hässlich' },
    { id: 'moche', term: 'moche', definition: 'hässlich' },
    { id: 'brave', term: 'brave', definition: 'lieb' },
    { id: 'gentil', term: 'gentil, gentille', definition: 'lieb, nett' },
    { id: 'chat', term: 'le chat', definition: 'die Katze' },
    { id: 'dash', term: 'le pluriel', definition: '-' },
  ],
};

const card = (id) => SET.cards.find((c) => c.id === id);
const info = (id, ask = 'term') => questionInfo(SET, card(id), { qid: `${id}:${ask === 'term' ? 't' : 'd'}`, cardId: id, ask });

// ------------------------------------------------------------ main answer grading

test('gradeQuestion: the answer of a card with the same prompt counts as correct', () => {
  const { result, matchedCard } = gradeQuestion(SET, info('moche'), 'laide', TOL);
  expect(result.correct).toBe(true);
  expect(result.exact).toBe(false);
  expect(result.notes).toContain('synonym');
  // The feedback shows what the asked card wanted.
  expect(result.expectedDisplay).toBe('moche');
  expect(matchedCard && matchedCard.id).toBe('laid');
});

test('gradeQuestion: works in both directions and for overlapping alternatives', () => {
  expect(gradeQuestion(SET, info('laid'), 'moche', TOL).result.correct).toBe(true);
  expect(gradeQuestion(SET, info('brave'), 'gentil', TOL).result.correct).toBe(true);
  expect(gradeQuestion(SET, info('gentil'), 'brave', TOL).result.correct).toBe(true);
});

test('gradeQuestion: the asked card wins and unrelated cards never match', () => {
  const own = gradeQuestion(SET, info('moche'), 'moche', TOL);
  expect(own.result.correct).toBe(true);
  expect(own.result.exact).toBe(true);
  expect(own.matchedCard).toBe(null);
  const wrong = gradeQuestion(SET, info('moche'), 'le chat', TOL);
  expect(wrong.result.correct).toBe(false);
  expect(wrong.matchedCard).toBe(null);
});

test('gradeQuestion: falls back to plain grading when the card is not in the set', () => {
  const orphan = { ...info('chat'), cardId: 'gone' };
  const { result, matchedCard } = gradeQuestion(SET, orphan, 'le chat', TOL);
  expect(result.correct).toBe(true);
  expect(matchedCard).toBe(null);
  expect(gradeQuestion(null, orphan, 'le chat', TOL).result.correct).toBe(true);
});

test('labels: the synonym note has a German label (Swiss spelling)', () => {
  expect(typeof NOTE_LABELS.synonym).toBe('string');
  expect(NOTE_LABELS.synonym.length).toBeGreaterThan(0);
  expect(JSON.stringify(NOTE_LABELS).includes('ß')).toBe(false);
});

// --------------------------------------------------------------------- copy step

test('copyAccepted: punctuation-only answers can be copied (no dead end)', () => {
  const dash = info('dash', 'definition');
  expect(dash.expected).toBe('-');
  expect(copyAccepted('-', dash, TOL)).toBe(true);
  expect(copyAccepted(' - ', dash, TOL)).toBe(true);
  expect(copyAccepted('x', dash, TOL)).toBe(false);
  // The question itself is gradable too.
  expect(gradeQuestion(SET, dash, '-', TOL).result.correct).toBe(true);
});

test('copyAccepted: needs the asked answer, not a synonym, and not an empty field', () => {
  expect(copyAccepted('moche', info('moche'), TOL)).toBe(true);
  expect(copyAccepted('laide', info('moche'), TOL)).toBe(false);
  expect(copyAccepted('   ', info('moche'), TOL)).toBe(false);
  expect(copyAccepted(undefined, info('moche'), TOL)).toBe(false);
  expect(copyAccepted('moche', null, TOL)).toBe(false);
});

// ---------------------------------------------------------- pending "Nicht ganz"

function sessionWithMiss() {
  const cards = [card('chat'), card('brave')];
  let s = S.createSession(cards, { answerWith: 'term', shuffle: false }, { now: 1000 });
  const missed = S.current(s).qid;
  s = S.answer(s, false, 2000);
  return { s, missed };
}

test('pendingFeedback: restores the miss that is still on screen', () => {
  const { s, missed } = sessionWithMiss();
  expect(pendingFeedback(s, { qid: missed, given: 'la chatte', dontKnow: false })).toEqual({ qid: missed, given: 'la chatte', dontKnow: false });
  expect(pendingFeedback(s, { qid: missed, dontKnow: true })).toEqual({ qid: missed, given: '', dontKnow: true });
});

test('pendingFeedback: survives the engine rebuilding the state (tick, persist round trip)', () => {
  const { s, missed } = sessionWithMiss();
  const stored = JSON.parse(JSON.stringify({ ...S.tick(s, 3000), feedback: { qid: missed, given: 'x', dontKnow: false } }));
  expect(pendingFeedback(stored, stored.feedback)).toEqual({ qid: missed, given: 'x', dontKnow: false });
});

test('pendingFeedback: ignores stale, overridden or malformed records', () => {
  const { s, missed } = sessionWithMiss();
  expect(pendingFeedback(s, null)).toBe(null);
  expect(pendingFeedback(s, 'x')).toBe(null);
  expect(pendingFeedback(s, { qid: 'nope:t', given: 'x' })).toBe(null);
  expect(pendingFeedback(null, { qid: missed })).toBe(null);
  // "Ich hatte recht" already counted it.
  expect(pendingFeedback(S.override(s, missed, 2500), { qid: missed, given: 'x' })).toBe(null);
  // The question that is still waiting in the queue is not a pending miss.
  const next = S.current(s).qid;
  expect(pendingFeedback(s, { qid: next, given: 'x' })).toBe(null);
  // Answered correctly: nothing to show.
  const s2 = S.answer(s, true, 3000);
  expect(pendingFeedback(s2, { qid: next, given: 'x' })).toBe(null);
  // Round closed: the summary (not the feedback) comes next.
  expect(pendingFeedback(S.nextRound(s2), { qid: missed, given: 'x' })).toBe(null);
  // A non-string answer is dropped, a huge one capped.
  expect(pendingFeedback(s, { qid: missed, given: 42 }).given).toBe('');
  expect(pendingFeedback(s, { qid: missed, given: 'a'.repeat(5000) }).given.length).toBeLessThanOrEqual(1000);
});

// ------------------------------------------------------- results after reload/Back

function finishedSession() {
  let s = S.createSession([card('chat')], { answerWith: 'term', shuffle: false }, { now: 1000 });
  s = S.answer(s, true, 2000);
  return s;
}

test('canShowResults: a finished session is shown again in its own history entry', () => {
  const s = finishedSession();
  expect(s.finishedAt).toBe(2000);
  expect(canResume(s)).toBe(false);
  expect(canShowResults(s, { marker: s.startedAt })).toBe(true);
  expect(canShowResults(s, { marker: s.startedAt, subset: 'all' })).toBe(true);
  // The round is still open when the reload happens during the last "Richtig!".
  expect(S.isRoundOver(s)).toBe(true);
  expect(canShowResults(S.nextRound(s), { marker: s.startedAt })).toBe(true);
});

test('canShowResults: a new visit, new=1, another subset or a running session start fresh', () => {
  const s = finishedSession();
  expect(canShowResults(s, {})).toBe(false);
  expect(canShowResults(s, { marker: s.startedAt + 1 })).toBe(false);
  expect(canShowResults(s, { marker: s.startedAt, forceNew: true })).toBe(false);
  expect(canShowResults(s, { marker: s.startedAt, subset: 'starred' })).toBe(false);
  const running = S.createSession([card('chat'), card('brave')], { answerWith: 'term' }, { now: 5 });
  expect(canShowResults(running, { marker: running.startedAt })).toBe(false);
  expect(canShowResults({ ...s, order: [] }, { marker: s.startedAt })).toBe(false);
  expect(canShowResults(null, { marker: 0 })).toBe(false);
});

// ----------------------------------------------------------- compact time tile

test('compactDuration: short clock-style values for the results tile', () => {
  expect(compactDuration(167000)).toEqual({ value: '2:47', label: 'Zeit (Min.)' });
  expect(compactDuration(60000)).toEqual({ value: '1:00', label: 'Zeit (Min.)' });
  expect(compactDuration(42000)).toEqual({ value: '42 Sek.', label: 'Zeit' });
  expect(compactDuration(0)).toEqual({ value: '0 Sek.', label: 'Zeit' });
  expect(compactDuration(3767000)).toEqual({ value: '1:02:47', label: 'Zeit (Std.)' });
  expect(compactDuration(-5)).toEqual({ value: '0 Sek.', label: 'Zeit' });
  expect(compactDuration(NaN)).toEqual({ value: '0 Sek.', label: 'Zeit' });
  // Rounds like formatDuration: 59.6 s is a full minute.
  expect(compactDuration(59600)).toEqual({ value: '1:00', label: 'Zeit (Min.)' });
});

// ------------------------------------------------------------------ placeholders

test('questionInfo: a short placeholder for narrow screens', () => {
  expect(info('chat').placeholder).toBe('Antwort auf Französisch eingeben');
  expect(info('chat').placeholderShort).toBe('Auf Französisch …');
  expect(info('chat', 'definition').placeholderShort).toBe('Auf Deutsch …');
  const same = questionInfo({ ...SET, defLang: 'fr' }, card('chat'), { qid: 'chat:t', cardId: 'chat', ask: 'term' });
  expect(same.placeholderShort).toBe('Antwort eingeben');
});

// ------------------------------------------------------- special-character keys

test('charColumns: balanced rows with at most the given keys per row', () => {
  // Up to eight keys stay on one row, more split into balanced rows.
  expect(charColumns(6, 8)).toBe(6);
  expect(charColumns(8, 8)).toBe(8);
  expect(charColumns(9, 8)).toBe(5);
  expect(charColumns(15, 8)).toBe(8);
  expect(charColumns(17, 8)).toBe(6);
  // The tight layout: French gets three rows of five instead of 7 + 7 + 1.
  expect(charColumns(15, 7)).toBe(5);
  expect(charColumns(7, 7)).toBe(7);
  // Degenerate input never yields an invalid repeat() count.
  expect(charColumns(0, 8)).toBe(1);
  expect(charColumns(5, 0)).toBe(1);
  expect(charColumns(NaN, 8)).toBe(1);
});

// Phone layout (write.css, max-width 560px): the key bar is the card's content box
// plus 2 x 14px reach into its padding; keys are 40px wide on touch with 4px gaps.
const BAR = (viewport) => viewport - 2 * 16 - 2 * (1 + 18) + 2 * 14;
const rowWidth = (cols) => cols * 40 + (cols - 1) * 4;

test('special characters: touch keys stay 40px wide down to the 360px minimum', () => {
  // Eight 40px keys need a 390px screen (French at 360px was squeezed to 36px) ...
  expect(rowWidth(8)).toBe(BAR(390));
  expect(rowWidth(8) > BAR(389)).toBe(true);
  // ... so narrower touch screens use the tight layout, which fits every language.
  for (const [lang, list] of Object.entries(SPECIAL_CHARS)) {
    expect([lang, rowWidth(charColumns(list.length, 7)) <= BAR(360)]).toEqual([lang, true]);
  }
});

// Pulls the body of the first block whose prelude contains `head` out of `css`.
function block(css, head) {
  const at = css.indexOf(head);
  if (at < 0) return null;
  let i = css.indexOf('{', at);
  const start = i + 1;
  for (let depth = 1; depth > 0 && ++i < css.length; ) {
    if (css[i] === '{') depth++;
    else if (css[i] === '}') depth--;
  }
  return css.slice(start, i);
}

test('write.css: on touch phones the keys keep 40px tracks and switch to the tight layout', () => {
  const css = readFile('../styles/screens/write.css').replace(/\/\*[\s\S]*?\*\//g, '');
  // The card is the size container the tight layout queries.
  expect(/container:\s*wr-card\s*\/\s*inline-size/.test(block(css, '.wr-card {'))).toBe(true);
  const touch = block(css, '@media (max-width: 560px) and (pointer: coarse)');
  expect(touch == null).toBe(false);
  expect(block(touch, '.wr-chars {')).toContain('minmax(40px, 46px)');
  // The container threshold is exactly where eight keys stop fitting.
  const query = touch.match(/@container wr-card \(width < (\d+)px\)/);
  expect(query && Number(query[1])).toBe(rowWidth(8) - 2 * 14);
  expect(block(touch, '@container wr-card')).toContain('--wr-chars-n: var(--wr-chars-cols-tight');
  // Nothing after the touch block shrinks the keys again.
  const rest = css.slice(css.indexOf('@media (max-width: 560px) and (pointer: coarse)'));
  expect(/\.wr-chars?\s*\{[^}]*minmax\(0/.test(rest)).toBe(false);
});

await run();
