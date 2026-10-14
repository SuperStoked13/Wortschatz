// Parity fixture for the seeded PRNG of the web tests → Fixtures/random.json.
// fns: mulberry32 [seed (uint32), count] → first `count` values
//      mulberry32Int [seed (any integer, JS `seed >>> 0`), count]
//      shuffle [seed, n] → Fisher–Yates of [0..n) as in session.js/learn.js (j = floor(rng() * (i + 1)))
import { Cases, mulberry32, randInt } from './lib.js';

const cases = new Cases('random');

function values(seed, count) {
  const rng = mulberry32(seed);
  return Array.from({ length: count }, () => rng());
}

const SEEDS = [
  0, 1, 2, 3, 7, 42, 99, 123, 1234, 2026, 31337, 99999, 123456789, 1760000000, 0x6d2b79f5, 0x7fffffff, 0x80000000,
  0xdeadbeef, 0xcafebabe, 0xfffffffe, 0xffffffff,
];
for (const seed of SEEDS) cases.add('mulberry32', [seed, 200], values(seed, 200));

// Seeds drawn from a meta generator
const meta = mulberry32(424242);
for (let i = 0; i < 300; i++) {
  const seed = Math.floor(meta() * 4294967296) >>> 0;
  cases.add('mulberry32', [seed, 64], values(seed, 64));
}

// Integer seeds that wrap (seed >>> 0)
for (const seed of [-1, -2, -42, -2147483648, 4294967296, 4294967297, 8589934593, -4294967297, 123456789012]) {
  cases.add('mulberry32Int', [seed, 32], values(seed, 32));
}

// Fisher–Yates as used by the engines (consumes one value per step, from the end)
function shuffled(n, rng) {
  const a = Array.from({ length: n }, (_, i) => i);
  for (let i = a.length - 1; i > 0; i--) {
    let j = Math.floor(rng() * (i + 1));
    if (!(j >= 0)) j = 0;
    if (j > i) j = i;
    const t = a[i];
    a[i] = a[j];
    a[j] = t;
  }
  return a;
}
for (let i = 0; i < 200; i++) {
  const seed = Math.floor(meta() * 4294967296) >>> 0;
  const n = randInt(meta, 0, 60);
  cases.add('shuffle', [seed, n], shuffled(n, mulberry32(seed)));
}

cases.emit();
