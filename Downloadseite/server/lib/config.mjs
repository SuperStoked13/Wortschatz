// Configuration from environment variables (see .env.example).
// Every value has a safe default, so `node server/server.mjs` works without any setup.

import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const WEBSITE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

const TRUE = new Set(['1', 'true', 'yes', 'on', 'ja']);
const FALSE = new Set(['0', 'false', 'no', 'off', 'nein']);

function raw(env, name) {
  const value = env[name];
  return value === undefined ? '' : String(value).trim();
}

function readInt(env, name, fallback, min, max) {
  const value = raw(env, name);
  if (value === '') return fallback;
  const n = Number(value);
  if (!Number.isInteger(n) || n < min || n > max) {
    throw new Error(`${name} muss eine ganze Zahl von ${min} bis ${max} sein (gesetzt: "${value}").`);
  }
  return n;
}

function readNumber(env, name, fallback, min, max) {
  const value = raw(env, name);
  if (value === '') return fallback;
  const n = Number(value);
  if (!Number.isFinite(n) || n < min || n > max) {
    throw new Error(`${name} muss eine Zahl von ${min} bis ${max} sein (gesetzt: "${value}").`);
  }
  return n;
}

function readBool(env, name, fallback) {
  const value = raw(env, name).toLowerCase();
  if (value === '') return fallback;
  if (TRUE.has(value)) return true;
  if (FALSE.has(value)) return false;
  throw new Error(`${name} muss 1 oder 0 sein (gesetzt: "${value}").`);
}

function readDir(env, name, fallback) {
  const value = raw(env, name);
  return path.resolve(value || fallback);
}

function readEmail(env, name) {
  const value = raw(env, name);
  if (value === '') return '';
  if (value.length > 120 || !/^[^\s@<>"']+@[^\s@<>"']+\.[a-z]{2,}$/i.test(value)) {
    throw new Error(`${name} ist keine gültige E-Mail-Adresse (gesetzt: "${value}").`);
  }
  return value;
}

/** Megabit per second to bytes per second. */
const mbit = (n) => Math.round((n * 1_000_000) / 8);

export function loadConfig(env = process.env) {
  let origin;
  try {
    origin = new URL(raw(env, 'SITE_ORIGIN') || 'https://wortschatz.duckdns.org');
  } catch {
    throw new Error(`SITE_ORIGIN ist keine gültige Adresse (gesetzt: "${raw(env, 'SITE_ORIGIN')}").`);
  }
  if (
    !['https:', 'http:'].includes(origin.protocol) ||
    origin.pathname !== '/' ||
    origin.search ||
    origin.hash ||
    origin.username ||
    origin.password
  ) {
    throw new Error('SITE_ORIGIN muss die Form https://name.duckdns.org haben (ohne Pfad).');
  }

  const port = readInt(env, 'PORT', 8080, 1, 65535);
  const extraHosts = raw(env, 'ALLOWED_HOSTS')
    .split(',')
    .map((h) => h.trim().toLowerCase())
    .filter(Boolean);

  const secret = raw(env, 'DOWNLOAD_SECRET');
  if (secret && secret.length < 32) {
    throw new Error('DOWNLOAD_SECRET muss mindestens 32 Zeichen lang sein (oder leer bleiben).');
  }

  const password = raw(env, 'SITE_PASSWORD');
  if (password && password.length < 8) {
    throw new Error('SITE_PASSWORD muss mindestens 8 Zeichen lang sein (oder leer bleiben).');
  }

  const duckdnsDomain = raw(env, 'DUCKDNS_DOMAIN').toLowerCase().replace(/\.duckdns\.org$/, '');
  const duckdnsToken = raw(env, 'DUCKDNS_TOKEN');

  return Object.freeze({
    host: raw(env, 'HOST') || '127.0.0.1',
    port,
    origin: origin.origin,
    secure: origin.protocol === 'https:',
    allowedHosts: new Set([origin.host.toLowerCase(), ...extraHosts]),
    trustProxy: raw(env, 'TRUST_PROXY') || 'loopback',
    publicDir: readDir(env, 'PUBLIC_DIR', path.join(WEBSITE_ROOT, 'public')),
    releasesDir: readDir(env, 'RELEASES_DIR', path.join(WEBSITE_ROOT, 'releases')),
    dataDir: readDir(env, 'DATA_DIR', path.join(WEBSITE_ROOT, 'data')),
    secret,
    password,
    operator: raw(env, 'OPERATOR_NAME').slice(0, 120),
    contactEmail: readEmail(env, 'CONTACT_EMAIL'),
    accessLog: readBool(env, 'ACCESS_LOG', true),
    logLevel: raw(env, 'LOG_LEVEL') || 'info',
    duckdns: Object.freeze({ domain: duckdnsDomain, token: duckdnsToken }),
    limits: Object.freeze({
      // Requests per address, whatever they ask for: a burst, then a steady rate. A first visit
      // is about ten requests, and a whole class often shares one address.
      requestBurst: readInt(env, 'RATE_REQUEST_BURST', 1000, 5, 1_000_000),
      requestsPerSecond: readNumber(env, 'RATE_REQUESTS_PER_SECOND', 20, 0.01, 100_000),
      // Bytes of pages, files and error pages (downloads have their own limits below): per
      // address, and for everybody together, so that the upload of a home connection survives
      // many addresses that each stay within their limit. 0 = no limit.
      siteBytesPerSecondPerIp: mbit(readNumber(env, 'SITE_BANDWIDTH_PER_IP_MBIT', 0.5, 0, 100_000)),
      siteBytesPerSecond: mbit(readNumber(env, 'SITE_BANDWIDTH_MBIT', 20, 0, 100_000)),
      passwordGuessesPerDay: readInt(env, 'PASSWORD_GUESSES_PER_DAY', 200, 1, 1_000_000),
      // Parallel downloads: the bandwidth limit below still applies to all of them together.
      concurrentPerIp: readInt(env, 'CONCURRENT_DOWNLOADS_PER_IP', 12, 1, 10_000),
      concurrentTotal: readInt(env, 'CONCURRENT_DOWNLOADS_TOTAL', 200, 1, 100_000),
      linkSeconds: readInt(env, 'DOWNLOAD_LINK_SECONDS', 120, 10, 3600),
      linkUses: readInt(env, 'DOWNLOAD_LINK_USES', 3, 1, 100),
      bindLinkToIp: readBool(env, 'DOWNLOAD_LINK_BIND_IP', true),
      // A download slower than this (after a grace period) is cut off, so slow readers
      // cannot hold all slots. Below the share of BANDWIDTH_TOTAL_MBIT the check relaxes.
      minBytesPerSecond: Math.round(readNumber(env, 'DOWNLOAD_MIN_KBPS', 16, 0, 1_000_000) * 1024),
      slowGraceSeconds: readInt(env, 'DOWNLOAD_SLOW_GRACE_SECONDS', 30, 1, 3600),
      maxDownloadMinutes: readInt(env, 'DOWNLOAD_MAX_MINUTES', 180, 1, 24 * 60),
      // Bandwidth: protects the upload of a home connection. 0 = no limit.
      totalBytesPerSecond: mbit(readNumber(env, 'BANDWIDTH_TOTAL_MBIT', 50, 0, 100_000)),
      perDownloadBytesPerSecond: mbit(readNumber(env, 'BANDWIDTH_PER_DOWNLOAD_MBIT', 0, 0, 100_000)),
      // After this much in a day, downloads share a slow lane instead of stopping: an attacker
      // who uses up the allowance must not be able to switch the downloads off until midnight.
      dailyBytes: Math.round(readNumber(env, 'DAILY_TRAFFIC_GB', 50, 0, 1_000_000) * 1e9),
      dailyBytesPerIp: Math.round(readNumber(env, 'DAILY_TRAFFIC_GB_PER_IP', 20, 0, 1_000_000) * 1e9),
      slowLaneBytesPerSecond: mbit(readNumber(env, 'DAILY_TRAFFIC_SLOW_MBIT', 10, 0.1, 100_000)),
    }),
  });
}
