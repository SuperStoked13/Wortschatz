// Random, URL-safe identifiers. Pure: works under jsc where `crypto` may be missing.

const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
const DEFAULT_SIZE = 16; // 16 × 6 bits = 96 bits of randomness

let counter = 0;

function randomBytes(n) {
  const out = new Uint8Array(n);
  const c = globalThis.crypto;
  if (c && typeof c.getRandomValues === 'function') {
    c.getRandomValues(out);
    return out;
  }
  for (let i = 0; i < n; i++) out[i] = Math.floor(Math.random() * 256);
  // Mix in a strictly increasing stamp (time + counter), 6 bits per character,
  // so ids stay distinct even with a weak PRNG.
  const stamp = (Date.now() + counter++) >>> 0;
  for (let i = 0; i < 6; i++) out[n - 1 - i] ^= (stamp >>> (i * 6)) & 63;
  return out;
}

// Returns a url-safe id of `size` characters (minimum 12).
export function uid(size = DEFAULT_SIZE) {
  const n = Math.max(12, Math.floor(Number(size) || DEFAULT_SIZE));
  const bytes = randomBytes(n);
  let id = '';
  for (let i = 0; i < n; i++) id += ALPHABET[bytes[i] & 63];
  return id;
}
