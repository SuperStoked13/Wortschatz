// Minimal test harness for pure ES modules. Runs under macOS JavaScriptCore
// (`jsc -m`) and in browsers. Usage in a test file:
//
//   import { test, expect, run } from './harness.js';
//   test('adds', () => { expect(1 + 1).toBe(2); });
//   await run();
//
// run() prints a summary line `RESULT <file> passed=N failed=M` that
// tests/run.sh parses.

const tests = [];
const log = typeof print === 'function' ? print : (...a) => console.log(...a);

export function test(name, fn) {
  tests.push({ name, fn });
}

function fmt(v) {
  try {
    return typeof v === 'string' ? JSON.stringify(v) : JSON.stringify(v, null, 0);
  } catch {
    return String(v);
  }
}

function deepEqual(a, b) {
  if (Object.is(a, b)) return true;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const ka = Object.keys(a);
  const kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  return ka.every((k) => deepEqual(a[k], b[k]));
}

function fail(msg) {
  throw new Error(msg);
}

export function expect(actual) {
  const api = {
    toBe(expected) {
      if (!Object.is(actual, expected)) fail(`expected ${fmt(actual)} to be ${fmt(expected)}`);
    },
    toEqual(expected) {
      if (!deepEqual(actual, expected)) fail(`expected ${fmt(actual)} to equal ${fmt(expected)}`);
    },
    toBeTruthy() {
      if (!actual) fail(`expected ${fmt(actual)} to be truthy`);
    },
    toBeFalsy() {
      if (actual) fail(`expected ${fmt(actual)} to be falsy`);
    },
    toContain(item) {
      const ok = typeof actual === 'string' ? actual.includes(item) : Array.isArray(actual) && actual.some((x) => deepEqual(x, item));
      if (!ok) fail(`expected ${fmt(actual)} to contain ${fmt(item)}`);
    },
    toHaveLength(n) {
      if (!actual || actual.length !== n) fail(`expected length ${n}, got ${actual ? actual.length : actual} (${fmt(actual)})`);
    },
    toBeGreaterThan(n) {
      if (!(actual > n)) fail(`expected ${fmt(actual)} > ${n}`);
    },
    toBeGreaterThanOrEqual(n) {
      if (!(actual >= n)) fail(`expected ${fmt(actual)} >= ${n}`);
    },
    toBeLessThan(n) {
      if (!(actual < n)) fail(`expected ${fmt(actual)} < ${n}`);
    },
    toBeLessThanOrEqual(n) {
      if (!(actual <= n)) fail(`expected ${fmt(actual)} <= ${n}`);
    },
    toThrow() {
      let threw = false;
      try {
        actual();
      } catch {
        threw = true;
      }
      if (!threw) fail('expected function to throw');
    },
  };
  api.not = {
    toBe(expected) {
      if (Object.is(actual, expected)) fail(`expected ${fmt(actual)} not to be ${fmt(expected)}`);
    },
    toEqual(expected) {
      if (deepEqual(actual, expected)) fail(`expected ${fmt(actual)} not to equal ${fmt(expected)}`);
    },
    toContain(item) {
      const has = typeof actual === 'string' ? actual.includes(item) : Array.isArray(actual) && actual.some((x) => deepEqual(x, item));
      if (has) fail(`expected ${fmt(actual)} not to contain ${fmt(item)}`);
    },
  };
  return api;
}

export async function run(fileLabel = '') {
  let passed = 0;
  let failed = 0;
  for (const t of tests) {
    try {
      await t.fn();
      passed++;
    } catch (e) {
      failed++;
      log(`  ✗ ${t.name}\n      ${e && e.message ? e.message : e}`);
    }
  }
  log(`RESULT ${fileLabel} passed=${passed} failed=${failed}`);
  tests.length = 0;
  return { passed, failed };
}
