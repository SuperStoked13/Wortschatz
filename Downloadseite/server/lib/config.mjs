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
    operator: raw(env, 'OPERATOR_NAME').slice(0, 120),
    contactEmail: readEmail(env, 'CONTACT_EMAIL'),
    accessLog: readBool(env, 'ACCESS_LOG', true),
    logLevel: raw(env, 'LOG_LEVEL') || 'info',
    duckdns: Object.freeze({ domain: duckdnsDomain, token: duckdnsToken }),
    limits: Object.freeze({
      // Pages and form posts per address: a burst, then a steady rate.
      pageBurst: readInt(env, 'RATE_PAGE_BURST', 60, 5, 100_000),
      pagePerMinute: readInt(env, 'RATE_PAGE_PER_MINUTE', 60, 1, 100_000),
      // Static files (CSS, JS, images): a page needs about a dozen, a school class a few hundred.
      assetBurst: readInt(env, 'RATE_ASSET_BURST', 150, 20, 1_000_000),
      assetPerMinute: readInt(env, 'RATE_ASSET_PER_MINUTE', 300, 60, 1_000_000),
      // Downloads per address (a school shares one address, so not too strict). Every full
      // download counts, also a second one through the same link.
      downloadsPerHour: readInt(env, 'DOWNLOADS_PER_HOUR', 30, 1, 100_000),
      downloadsPerDay: readInt(env, 'DOWNLOADS_PER_DAY', 100, 1, 1_000_000),
      concurrentPerIp: readInt(env, 'CONCURRENT_DOWNLOADS_PER_IP', 6, 1, 10_000),
      concurrentTotal: readInt(env, 'CONCURRENT_DOWNLOADS_TOTAL', 40, 1, 100_000),
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
      dailyBytes: Math.round(readNumber(env, 'DAILY_TRAFFIC_GB', 50, 0, 1_000_000) * 1e9),
      dailyBytesPerIp: Math.round(readNumber(env, 'DAILY_TRAFFIC_GB_PER_IP', 3, 0, 1_000_000) * 1e9),
      // Penalty points that lead to a temporary block (scanners, floods, forged links).
      banThreshold: readInt(env, 'BAN_THRESHOLD', 12, 2, 10_000),
      banMinutes: readInt(env, 'BAN_MINUTES', 60, 1, 60 * 24 * 30),
    }),
  });
}
