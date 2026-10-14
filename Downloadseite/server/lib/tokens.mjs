// Short-lived, signed download links. A link carries its platform, the file's
// fingerprint, an expiry, a tag of the requesting address and a random id, signed with
// HMAC-SHA256. Without the secret nobody can make or change one.

import crypto from 'node:crypto';

const MAC_LENGTH = 43; // base64url of 32 bytes, without padding
const BODY_RE = /^[A-Za-z0-9_-]{8,700}$/;
const MAC_RE = /^[A-Za-z0-9_-]{43}$/;

export class LinkSigner {
  /** @param {string} secret empty = a random key per process (links die with a restart) */
  constructor(secret = '') {
    this.key = secret ? Buffer.from(secret, 'utf8') : crypto.randomBytes(32);
  }

  #mac(text) {
    return crypto.createHmac('sha256', this.key).update(text).digest('base64url');
  }

  /** A short tag of a value (the client's address key): not reversible, not guessable. */
  tag(value) {
    return this.#mac(`tag:${value}`).slice(0, 16);
  }

  sign(payload) {
    const body = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64url');
    return `${body}.${this.#mac(`link:${body}`)}`;
  }

  /** The payload of a genuine link, or null. Compares in constant time. */
  verify(token) {
    if (typeof token !== 'string' || token.length > 800) return null;
    const dot = token.indexOf('.');
    if (dot === -1 || dot !== token.lastIndexOf('.')) return null;
    const body = token.slice(0, dot);
    const mac = token.slice(dot + 1);
    if (!BODY_RE.test(body) || !MAC_RE.test(mac)) return null;
    const expected = Buffer.from(this.#mac(`link:${body}`), 'utf8');
    const given = Buffer.from(mac, 'utf8');
    if (given.length !== MAC_LENGTH || !crypto.timingSafeEqual(given, expected)) return null;
    try {
      const payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
      return payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : null;
    } catch {
      return null;
    }
  }
}

/** A random id of `length` url-safe characters. */
export function randomId(length = 16) {
  return crypto.randomBytes(Math.ceil((length * 3) / 4)).toString('base64url').slice(0, length);
}
