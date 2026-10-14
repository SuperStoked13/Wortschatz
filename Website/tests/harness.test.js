import { test, expect, run } from './harness.js';

test('harness: basic matchers', () => {
  expect(1 + 1).toBe(2);
  expect({ a: [1, 2] }).toEqual({ a: [1, 2] });
  expect('séparée'.normalize('NFD').replace(/\p{M}/gu, '')).toBe('separee');
  expect(() => {
    throw new Error('x');
  }).toThrow();
  expect([1, 2, 3]).not.toContain(4);
});

await run('harness.test.js');
