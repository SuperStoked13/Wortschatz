// Shared helpers for the parity generators (mac/Parity/gen-*.js).
//
// Generators are ES modules run with JavaScriptCore (`jsc -m`, no Node): they import the web
// reference via ABSOLUTE paths, compute results for many inputs and print ONE JSON document:
//
//   {"module":"<name>","count":N,"cases":[
//   {"id":"<fn>#<n>","fn":"<fn>","args":[...],"out":<result>},
//   ...
//   ]}
//
// mac/scripts/gen-fixtures.sh stores it as Tests/WortschatzCoreTests/Fixtures/<name>.json.
// Everything here must be deterministic: never use Math.random or Date.now (use mulberry32 and
// fixed timestamps).

export const REPO = '../../Website';

// The seeded PRNG of tests/learn.test.js (bit-for-bit identical to Swift `mulberry32(seed:)`).
export function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// ---------------------------------------------------------------------------
// Plain JSON conversion

// Converts a JS value into plain JSON data, like JSON.stringify would see it, but explicit:
// undefined/functions are dropped from objects (null in arrays), Map → object, Set → array,
// Date → epoch ms, -0 → 0, NaN/±Infinity → null.
export function plain(v) {
  if (v === undefined || typeof v === 'function') return undefined;
  if (v === null) return null;
  if (typeof v === 'number') {
    if (!Number.isFinite(v)) return null;
    return Object.is(v, -0) ? 0 : v;
  }
  if (typeof v === 'string' || typeof v === 'boolean') return v;
  if (typeof v === 'bigint') return Number(v);
  if (v instanceof Date) return plain(v.getTime());
  if (Array.isArray(v)) return v.map((x) => {
    const p = plain(x);
    return p === undefined ? null : p;
  });
  if (v instanceof Set) return plain([...v]);
  if (v instanceof Map) {
    const out = {};
    for (const [k, x] of v) {
      const p = plain(x);
      if (p !== undefined) out[String(k)] = p;
    }
    return out;
  }
  if (typeof v === 'object') {
    if (typeof v.toJSON === 'function') return plain(v.toJSON());
    const out = {};
    for (const k of Object.keys(v)) {
      const p = plain(v[k]);
      if (p !== undefined) out[k] = p;
    }
    return out;
  }
  return undefined;
}

function sortKeys(v) {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v).sort()) out[k] = sortKeys(v[k]);
    return out;
  }
  return v;
}

// JSON text with recursively sorted keys and no whitespace (stable across runs).
export function stableStringify(v) {
  const p = plain(v);
  return JSON.stringify(sortKeys(p === undefined ? null : p));
}

// ---------------------------------------------------------------------------
// Case collection

export class Cases {
  constructor(module) {
    this.module = module;
    this.list = [];
    this.counters = new Map();
  }

  // Records one case: `fn` names the function (the Swift test switches on it), `args` are the
  // JSON arguments, `out` the JS result (converted with plain()).
  add(fn, args, out) {
    const n = this.counters.get(fn) || 0;
    this.counters.set(fn, n + 1);
    const out2 = plain(out);
    this.list.push({ id: `${fn}#${n}`, fn, args: plain(args), out: out2 === undefined ? null : out2 });
  }

  // Calls `f(...args)` and records the result (exceptions are recorded as {"throws": message}).
  run(fn, f, args) {
    let out;
    try {
      out = f(...args);
    } catch (e) {
      out = { throws: String(e && e.message ? e.message : e) };
    }
    this.add(fn, args, out);
    return out;
  }

  get count() {
    return this.list.length;
  }

  // Prints the fixture document (one case per line for readable diffs).
  emit() {
    const lines = this.list.map((c) => stableStringify(c));
    print(`{"module":${JSON.stringify(this.module)},"count":${lines.length},"cases":[\n${lines.join(',\n')}\n]}`);
  }
}

// ---------------------------------------------------------------------------
// Fuzz helpers (all take a mulberry32 rng)

export function randInt(rng, lo, hi) {
  return lo + Math.floor(rng() * (hi - lo + 1));
}

export function pick(rng, list) {
  return list[Math.floor(rng() * list.length)];
}

export function chance(rng, p) {
  return rng() < p;
}

// A string of `min`…`max` units drawn from `alphabet` (an array of strings).
export function fuzzString(rng, alphabet, min, max) {
  const n = randInt(rng, min, max);
  let s = '';
  for (let i = 0; i < n; i++) s += pick(rng, alphabet);
  return s;
}

// ---------------------------------------------------------------------------
// Web test fixtures (jsc cannot list directories, so the names are listed here; keep in sync
// with tests/fixtures/).

export const FIXTURE_FILES = [
  'alternating.txt',
  'collapsed-columns.txt',
  'csv-quoted.csv',
  'dash-en-em.txt',
  'dash-hyphen.txt',
  'english-german.txt',
  'equals.txt',
  'four-cells.tsv',
  'german-first-blocks.txt',
  'german-first.txt',
  'inline-semicolon.txt',
  'italian.txt',
  'markdown-table.txt',
  'noisy.txt',
  'numbered.txt',
  'pdf-columns.txt',
  'quizlet-export.txt',
  'semicolon.txt',
  'single-blank-alternating.txt',
  'spanish.txt',
  'two-column-ocr.txt',
  'user-example.txt',
  'windows-bom.txt',
  'wrapped-blocks.txt',
];

export function readText(relPath) {
  return readFile(`${REPO}/${relPath}`);
}

// { name, text } of every text fixture in tests/fixtures/ (includes the user's 52-pair list,
// user-example.txt).
export function fixtureTexts() {
  return FIXTURE_FILES.map((name) => ({ name, text: readText(`tests/fixtures/${name}`) }));
}
