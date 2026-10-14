import { test, expect, run } from './harness.js';
import { uid } from '../src/lib/id.js';

const URL_SAFE = /^[A-Za-z0-9_-]+$/;

// Temporarily replaces globalThis.crypto for one callback.
function withCrypto(value, fn) {
  const had = Object.prototype.hasOwnProperty.call(globalThis, 'crypto');
  const desc = had ? Object.getOwnPropertyDescriptor(globalThis, 'crypto') : null;
  Object.defineProperty(globalThis, 'crypto', { value, configurable: true, writable: true });
  try {
    return fn();
  } finally {
    if (desc) Object.defineProperty(globalThis, 'crypto', desc);
    else delete globalThis.crypto;
  }
}

test('uid: default length is 16 and url-safe', () => {
  const id = uid();
  expect(typeof id).toBe('string');
  expect(id).toHaveLength(16);
  expect(URL_SAFE.test(id)).toBe(true);
});

test('uid: custom sizes, never shorter than 12', () => {
  expect(uid(12)).toHaveLength(12);
  expect(uid(20)).toHaveLength(20);
  expect(uid(5)).toHaveLength(12);
  expect(uid(0)).toHaveLength(16);
  expect(uid('abc')).toHaveLength(16);
});

test('uid: 10 000 ids are unique', () => {
  const seen = new Set();
  for (let i = 0; i < 10000; i++) seen.add(uid());
  expect(seen.size).toBe(10000);
});

test('uid: uses the whole 64-character alphabet', () => {
  const chars = new Set();
  for (let i = 0; i < 500; i++) for (const ch of uid()) chars.add(ch);
  expect(chars.size).toBeGreaterThan(60);
  for (const ch of chars) expect(URL_SAFE.test(ch)).toBe(true);
});

test('uid: works without crypto (Math.random fallback)', () => {
  withCrypto(undefined, () => {
    const ids = new Set();
    for (let i = 0; i < 2000; i++) {
      const id = uid();
      expect(id).toHaveLength(16);
      expect(URL_SAFE.test(id)).toBe(true);
      ids.add(id);
    }
    expect(ids.size).toBe(2000);
  });
});

test('uid: fallback stays unique even with a constant Math.random', () => {
  const original = Math.random;
  Math.random = () => 0.5;
  try {
    withCrypto(undefined, () => {
      const ids = new Set();
      for (let i = 0; i < 300; i++) ids.add(uid());
      expect(ids.size).toBe(300);
    });
  } finally {
    Math.random = original;
  }
});

test('uid: prefers crypto.getRandomValues when available', () => {
  let calls = 0;
  const fake = {
    getRandomValues(arr) {
      calls++;
      for (let i = 0; i < arr.length; i++) arr[i] = i;
      return arr;
    },
  };
  withCrypto(fake, () => {
    expect(uid(12)).toBe('ABCDEFGHIJKL');
  });
  expect(calls).toBe(1);
});

await run('id.test.js');
