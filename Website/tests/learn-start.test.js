// Starting Learn over chosen cards from another screen (src/screens/learn-start.js):
// the link, the question before a running session with answers is ended, and the
// flow itself on the in-memory database (jsc has no localStorage).
import { test, expect, run } from './harness.js';
import { startLearnWithCards, replaceLearnPrompt, REPLACE_TITLE, REPLACE_CONFIRM } from '../src/screens/learn-start.js';
import { cardIdsFromHash, learnSessionDetail } from '../src/screens/learn-model.js';
import { db } from '../src/store/db.js';
import * as L from '../src/core/learn.js';

const T0 = 1760000000000;
const OPTS = { answerWith: 'term', learn: { roundSize: 7, mc: true, written: true, retype: false } };

function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function makeSet(n = 6) {
  return db.createSet({
    title: 'Wörter',
    cards: Array.from({ length: n }, (_, i) => ({ term: `terme ${i + 1}`, definition: `Begriff ${i + 1}` })),
  });
}

test('the module imports under jsc and exports the shared helper', () => {
  expect(typeof startLearnWithCards).toBe('function');
  expect(typeof replaceLearnPrompt).toBe('function');
  expect(REPLACE_TITLE).toBe('Laufende Lerneinheit beenden?');
  expect(REPLACE_CONFIRM).toBe('Neu beginnen');
});

test('replaceLearnPrompt asks only for a running session with answers', () => {
  const cards = Array.from({ length: 5 }, (_, i) => ({ id: `c${i + 1}`, term: `t${i + 1}`, definition: `d${i + 1}` }));
  const s = L.createLearn(cards, OPTS, { rng: mulberry32(1), now: T0 });
  expect(replaceLearnPrompt(null, {})).toBe(null);
  expect(replaceLearnPrompt(s, {})).toBe(null); // no answers yet: nothing is lost
  const q = L.current(s);
  const answered = L.answer(s, false, T0 + 1000);
  const progress = { [q.cardId]: { correct: 0, incorrect: 1, streak: 0, streakBefore: 0, lastResult: 'incorrect', lastAnsweredAt: T0 + 1000 } };
  const prompt = replaceLearnPrompt(answered, progress, 'schwierigen Begriffe');
  expect(prompt.title).toBe('Laufende Lerneinheit beenden?');
  expect(prompt.confirmLabel).toBe('Neu beginnen');
  expect(prompt.message).toBe(
    `Deine gespeicherte Lerneinheit (${learnSessionDetail(answered)}) endet, wenn du jetzt nur die schwierigen Begriffe lernst. Dein Lernfortschritt bleibt erhalten.`,
  );
  expect(replaceLearnPrompt(answered, progress).message).toContain('wenn du jetzt nur die ausgewählten Begriffe lernst.');
  expect(replaceLearnPrompt({ ...answered, finishedAt: T0 + 2000 }, progress)).toBe(null);
  expect(prompt.message.includes('ß')).toBe(false);
});

test('startLearnWithCards: without a running session it opens Learn at once', async () => {
  const set = makeSet();
  const ids = [set.cards[1].id, set.cards[3].id];
  const paths = [];
  let asked = 0;
  const ok = await startLearnWithCards({
    setId: set.id,
    cardIds: ids,
    review: true,
    navigate: (p) => paths.push(p),
    confirm: async () => {
      asked++;
      return true;
    },
  });
  expect(ok).toBe(true);
  expect(asked).toBe(0);
  expect(paths).toHaveLength(1);
  expect(paths[0].startsWith(`/set/${encodeURIComponent(set.id)}/learn?new=1&cards=`)).toBe(true);
  expect(paths[0].endsWith('&review=1')).toBe(true);
  expect(cardIdsFromHash(`#${paths[0]}`)).toEqual(ids);
  // Without review the link has no review flag.
  await startLearnWithCards({ setId: set.id, cardIds: ids, navigate: (p) => paths.push(p) });
  expect(paths[1].includes('review=1')).toBe(false);
});

test('startLearnWithCards asks before it ends a session with answers', async () => {
  const set = makeSet();
  let s = L.createLearn(set.cards, db.getStudyOptions(set.id), { rng: mulberry32(2), now: T0 });
  const q = L.current(s);
  s = L.answer(s, true, T0 + 1000);
  db.recordAnswer(set.id, q.cardId, true, T0 + 1000);
  db.saveLearn(set.id, s);

  // Kept: nothing happens.
  const paths = [];
  const prompts = [];
  const keep = await startLearnWithCards({
    setId: set.id,
    cardIds: [set.cards[0].id],
    navigate: (p) => paths.push(p),
    scope: 'falschen Begriffe',
    confirm: async (prompt) => {
      prompts.push(prompt);
      return false;
    },
  });
  expect(keep).toBe(false);
  expect(paths).toEqual([]);
  expect(prompts).toHaveLength(1);
  expect(prompts[0].title).toBe('Laufende Lerneinheit beenden?');
  expect(prompts[0].message).toContain('Runde 1');
  expect(prompts[0].message).toContain('wenn du jetzt nur die falschen Begriffe lernst.');
  expect(db.getLearn(set.id)).not.toBe(null);

  // Confirmed: the stored session ends and Learn opens.
  const replaced = await startLearnWithCards({
    setId: set.id,
    cardIds: [set.cards[0].id],
    review: true,
    navigate: (p) => paths.push(p),
    confirm: async () => true,
  });
  expect(replaced).toBe(true);
  expect(db.getLearn(set.id)).toBe(null);
  expect(paths).toHaveLength(1);
  expect(cardIdsFromHash(`#${paths[0]}`)).toEqual([set.cards[0].id]);
});

await run('learn-start.test.js');
