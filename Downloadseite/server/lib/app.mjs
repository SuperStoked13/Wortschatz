// The request handler: pages, static files, download links and every protection
// around them (see README, section "Sicherheit").

import crypto from 'node:crypto';
import { once } from 'node:events';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { anonymizeIp, buildTrust, clientIp, ipKey, isLoopback, networkKey, normalizeIp } from './net.mjs';
import { ConcurrencyGate, DailyBudget, DailyQuota, LruMap, TokenBucket, WindowCounter, downloadFloor } from './limits.mjs';
import { ByteRate } from './throttle.mjs';
import { LinkSigner, randomId } from './tokens.mjs';
import { PLATFORMS, checksumsText, loadReleases, releasesSignature } from './releases.mjs';
import { loadSite, makeEntry } from './site.mjs';
import { changelogView, parseChangelog } from './changelog.mjs';
import { compareVersions, languagesView } from './languages.mjs';
import { englishLabel, errorText, formatDate, languageOfPath, message, preferredLanguage } from './lang.mjs';
import { escapeHtml } from './templates.mjs';
import { parseRange, securityHeaders, send, sendEntry, sendJson, wantsJson } from './http.mjs';
import { createStats } from './stats.mjs';

/** The last Mac version that never went online (no update check). */
const MAC_WITHOUT_UPDATES_UP_TO = '1.7.1';
/** The last Windows version without the update check (AppUpdater came after it). */
const WINDOWS_WITHOUT_UPDATES_UP_TO = '1.7.1';

const METHODS = new Set(['GET', 'HEAD', 'POST']);
// Every page in German and in English: its template, its language and the same page in the other one.
const PAGES = new Map([
  ['/', { name: 'index', lang: 'de', other: '/en' }],
  ['/datenschutz', { name: 'datenschutz', lang: 'de', other: '/en/privacy' }],
  ['/neuigkeiten', { name: 'neuigkeiten', lang: 'de', other: '/en/whats-new' }],
  ['/en', { name: 'en/index', lang: 'en', other: '/' }],
  ['/en/privacy', { name: 'en/privacy', lang: 'en', other: '/datenschutz' }],
  ['/en/whats-new', { name: 'en/whats-new', lang: 'en', other: '/neuigkeiten' }],
]);
const HOME = Object.freeze({ de: '/', en: '/en' });
const LOGIN = Object.freeze({ de: '/login', en: '/en/login' });
const CHANGELOG = '_neuigkeiten.md';
const DEV_HOST = /^(?:localhost|127\.0\.0\.1|\[::1\])(?::\d{1,5})?$/;
const PLATFORM_PATH = /^\/download\/(mac|windows)$/;
const LINK_PATH = /^\/dl\/([A-Za-z0-9_-]{8,700}\.[A-Za-z0-9_-]{43})$/;
// With SITE_PASSWORD: what is open without signing in (the login page needs the static files),
// and how long a browser stays signed in.
const OPEN_PATHS = new Set(['/login', '/en/login', '/healthz', '/datenschutz', '/en/privacy']);
const LOGIN_DAYS = 90;

// What a response costs on top of its body: the headers.
const HEADER_BYTES = 1200;
// When the upload runs short, an address that got less than this lately still comes first.
const LIGHT_BYTES = 1_000_000;
// The answers to floods (see tiny): short and plain.
const TOO_MANY = 'Zu viele Anfragen. Bitte kurz warten.\n';
const BUSY = 'Der Server ist ausgelastet. Bitte kurz warten.\n';
const NOT_ALLOWED = 'Nicht erlaubt.\n';


const sha256 = (text) => crypto.createHash('sha256').update(text, 'utf8').digest();

function redirect(req, res, status, location) {
  send(req, res, status, { Location: location, 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' }, `${location}\n`);
}

/** The request body as text, or null when it is larger than `limit` bytes or never finishes. */
function readBody(req, limit) {
  return new Promise((resolve) => {
    const declared = Number(req.headers['content-length']);
    if (Number.isFinite(declared) && declared > limit) {
      resolve(null);
      return;
    }
    const chunks = [];
    let size = 0;
    let done = false;
    const finish = (value) => {
      if (done) return;
      done = true;
      resolve(value);
    };
    req.on('data', (chunk) => {
      if (done) return;
      size += chunk.length;
      if (size > limit) {
        req.pause();
        finish(null);
      } else {
        chunks.push(chunk);
      }
    });
    req.on('end', () => finish(Buffer.concat(chunks).toString('utf8')));
    req.on('close', () => finish(null));
    req.on('error', () => finish(null));
  });
}

/** A byte allowance per second with `burstSeconds` of it in reserve; 0 = no limit. */
function bytesBucket(bytesPerSecond, burstSeconds) {
  return new TokenBucket({ capacity: bytesPerSecond ? bytesPerSecond * burstSeconds : Infinity, perSecond: bytesPerSecond });
}

/**
 * Another website's page asking for something of ours through a visitor's browser (an image, a
 * script, a frame, a fetch). CORP and the CSP keep it from using the answer anyway, so it gets
 * none, and this costs the visitor's address nothing. A click on a link stays a navigation.
 */
function requestedByOtherWebsite(req) {
  const site = req.headers['sec-fetch-site'];
  if (site !== 'cross-site' && site !== 'same-site') return false;
  const mode = req.headers['sec-fetch-mode'];
  const dest = req.headers['sec-fetch-dest'];
  return (mode !== undefined && mode !== 'navigate') || (dest !== undefined && dest !== 'document');
}

/** The same page in the other language ("/neuigkeiten" ↔ "/en/whats-new"); unknown paths stay. */
function counterpart(path) {
  return PAGES.get(path)?.other ?? path;
}

/** A page in the wanted language: "/" in English is "/en", "/en" in English stays. */
function inLanguage(path, lang) {
  const page = PAGES.get(path);
  return page && page.lang !== lang ? page.other : path;
}

/** The values the templates see, in German or English. */
/** Which live apps look for updates on GitHub (macUpdates/windowsUpdates for the help, appUpdates for the privacy page). */
function updatesView(releases) {
  const mac = Boolean(releases.mac && compareVersions(releases.mac.version, MAC_WITHOUT_UPDATES_UP_TO) > 0);
  const windows = Boolean(releases.windows && compareVersions(releases.windows.version, WINDOWS_WITHOUT_UPDATES_UP_TO) > 0);
  return {
    macUpdates: mac,
    windowsUpdates: windows,
    appUpdates: { any: mac || windows, both: mac && windows, macOnly: mac && !windows, windowsOnly: windows && !mac },
  };
}

function viewModel(releases, config, changelog, lang) {
  const english = lang === 'en';
  const languages = languagesView(releases, lang);
  const pick = (release) =>
    release
      ? {
          available: true,
          version: release.version,
          versionLabel: release.build ? `${release.version} (${release.build})` : release.version,
          file: release.file,
          sizeLabel: release.sizeLabel,
          sha256: release.sha256,
          requirement: english ? englishLabel(release.requirement) : release.requirement,
          architecture: english ? englishLabel(release.architecture) : release.architecture,
          released: release.released,
          releasedLabel: english ? formatDate(release.released, 'en') : release.releasedLabel,
          size: release.size,
          // On GitHub: the page links straight to the file there instead of asking this server.
          url: release.external ? release.url : '',
          languages: languages.label(release.platform),
        }
      : { available: false };
  const mac = pick(releases.mac);
  const windows = pick(releases.windows);
  const present = [releases.mac, releases.windows].filter(Boolean);
  return {
    site: {
      origin: config.origin,
      year: new Date().getFullYear(),
      operator: config.operator,
      contactEmail: config.contactEmail,
      mailto: config.contactEmail ? `mailto:${config.contactEmail}` : '',
      login: Boolean(config.password),
      loginDays: LOGIN_DAYS,
    },
    mac,
    windows,
    anyAvailable: mac.available || windows.available,
    // Where the files come from, for the privacy page: this server, GitHub or both.
    downloads: { local: present.some((r) => !r.external), github: present.some((r) => r.external) },
    version: mac.version || windows.version || '',
    // What the live apps speak (German; English since the first release after Mac 1.6.2 / Windows 1.4).
    appLanguages: { english: languages.english, note: languages.note, text: languages.text },
    // The live apps ask GitHub for updates (Mac: Sparkle, Windows: AppUpdater, each from the first release
    // after 1.7.1): the privacy page and the help of each app say so.
    ...updatesView(releases),
    updates: changelogView(changelog, releases, lang),
  };
}

/**
 * What the head, nav and footer need to know about a page: its language and where it is in the
 * other one (the language switch), and for pages that exist in both, both addresses (lang.js).
 */
function pageView(lang, other, alternates = null) {
  return {
    lang,
    other,
    otherLang: lang === 'en' ? 'de' : 'en',
    alternates: alternates ? { de: alternates.de, en: alternates.en } : null,
  };
}

export async function createApp(config, log) {
  const trust = buildTrust(config.trustProxy);
  const privateNets = buildTrust('private');
  const signer = new LinkSigner(config.secret);
  const L = config.limits;

  // Every request of an address counts here, whatever it asks for and however it is answered.
  const requestRate = new TokenBucket({ capacity: L.requestBurst, perSecond: L.requestsPerSecond });
  // Bytes of everything but the downloads, per address and for everybody together.
  const addressBytes = bytesBucket(L.siteBytesPerSecondPerIp, 256);
  const siteBytes = bytesBucket(L.siteBytesPerSecond, 8);
  const traffic = new DailyQuota({ limit: L.dailyBytesPerIp });
  const gate = new ConcurrencyGate({ perKey: L.concurrentPerIp, total: L.concurrentTotal });
  // Form bodies under way: one that never arrives holds a connection.
  const bodies = new ConcurrencyGate({ perKey: 8, total: 1500 });
  const budget = new DailyBudget({ bytesPerDay: L.dailyBytes });
  const totalRate = new ByteRate(L.totalBytesPerSecond);
  const slowLane = new ByteRate(L.slowLaneBytesPerSecond);
  // Wrong passwords per address: ten tries, then one every 12 seconds, and only so many a day.
  const passwordRate = new TokenBucket({ capacity: 10, perSecond: 5 / 60 });
  const guessesPerDay = new WindowCounter({ limit: L.passwordGuessesPerDay, windowMs: 86_400_000 });
  const passwordHash = config.password ? sha256(config.password) : null;
  // Signs the login cookies. Derived from the password: a new password signs everybody out,
  // a restart or a new release does not. Slowly, because whoever gets hold of one cookie could
  // otherwise try out passwords against it as fast as a graphics card can.
  const loginKey = config.password
    ? crypto.scryptSync(config.password, 'wortschatz-login-v1', 32, { N: 2 ** 15, r: 8, p: 1, maxmem: 64 * 1024 * 1024 })
    : null;
  // __Host-: only over HTTPS, only for this exact host and path / (no subdomain can set or read it).
  const loginCookie = config.secure ? '__Host-wortschatz' : 'wortschatz';
  const links = new LruMap(50_000);
  const stats = await createStats(config.dataDir, log);
  const baseHeaders = securityHeaders(config);
  const warned = new Set();
  // A flood must not fill the disk with one line per request: at most this many, and every
  // minute a line with what was left out.
  const logRate = new TokenBucket({ capacity: 200, perSecond: 20 });
  let refused = 0;
  let unlogged = 0;

  const warnOnce = (id, message) => {
    if (warned.has(id)) return;
    warned.add(id);
    log.warn(id, { message });
  };

  async function build() {
    const [site, releases] = await Promise.all([loadSite(config.publicDir), loadReleases(config.releasesDir, log, { repo: config.downloadRepo })]);
    const changelog = parseChangelog(site.text(CHANGELOG));
    for (const { line, message } of changelog.problems) log.warn('changelog', { file: CHANGELOG, line, message });
    const models = { de: viewModel(releases, config, changelog, 'de'), en: viewModel(releases, config, changelog, 'en') };
    const pages = new Map();
    for (const [route, { name, lang, other }] of PAGES) {
      const alternates = lang === 'de' ? { de: route, en: other } : { de: other, en: route };
      pages.set(route, site.renderPage(name, { ...models[lang], page: pageView(lang, other, alternates) }));
    }
    // Templates that are rendered per request: fail now, at start or reload, rather than then.
    for (const lang of ['de', 'en']) {
      const prefix = lang === 'en' ? 'en/' : '';
      site.renderHtml(`${prefix}_error`, { ...models[lang], page: pageView(lang, HOME.de), error: { status: 404, title: 'Test', message: 'Test' } });
      site.renderHtml(`${prefix}_login`, { ...models[lang], page: pageView(lang, LOGIN.de, LOGIN), login: { next: '/', wrong: false } });
    }
    const checksums = makeEntry(Buffer.from(checksumsText(releases, config.origin), 'utf8'), 'text/plain; charset=utf-8', {
      cacheControl: 'no-cache',
    });
    return { site, releases, models, pages, checksums };
  }

  let state = await build();
  let signature = await releasesSignature(config.releasesDir);
  let reloading = null;

  function reload(reason) {
    reloading ??= (async () => {
      try {
        state = await build();
        signature = await releasesSignature(config.releasesDir);
        log.info('reload', { reason, mac: Boolean(state.releases.mac), windows: Boolean(state.releases.windows) });
      } catch (error) {
        log.error('reload', { reason, message: error.message });
      } finally {
        reloading = null;
      }
    })();
    return reloading;
  }

  // New files in the releases folder go live by themselves.
  const watcher = setInterval(async () => {
    const next = await releasesSignature(config.releasesDir);
    if (next !== signature) {
      signature = next;
      await reload('releases');
    }
  }, 15_000);
  watcher.unref();

  const sweeper = setInterval(() => {
    requestRate.sweep();
    addressBytes.sweep();
    siteBytes.sweep();
    passwordRate.sweep();
    guessesPerDay.sweep();
    traffic.sweep();
    logRate.sweep();
    const now = Date.now() / 1000;
    for (const [id, usage] of links) if (usage.expires < now - 3600) links.delete(id);
  }, 5 * 60_000);
  sweeper.unref();

  const reporter = setInterval(() => {
    if (!refused && !unlogged) return;
    log.info('refused', { refused, unlogged });
    refused = 0;
    unlogged = 0;
  }, 60_000);
  reporter.unref();

  const isPrivate = (ip) => Boolean(ip) && privateNets.check(ip, ip.includes(':') ? 'ipv6' : 'ipv4');

  /**
   * The language of what the server says by itself: that of the page asked for or the page the
   * request came from (English below /en), otherwise the browser's (Accept-Language, which the
   * page script sets to the page's language).
   */
  function languageOf(req) {
    const url = req.url || '';
    if (languageOfPath(url.split('?')[0]) === 'en') return 'en';
    const referer = String(req.headers.referer || '');
    if (referer) {
      try {
        const from = new URL(referer);
        if (from.host === String(req.headers.host || '').toLowerCase() && languageOfPath(from.pathname) === 'en') return 'en';
      } catch {
        // not a URL: ignore
      }
    }
    return preferredLanguage(req.headers['accept-language']);
  }

  /**
   * An error page (or JSON for the page script). `say` names one of the messages in lang.mjs,
   * otherwise the status gives title and text.
   */
  function fail(req, res, status, { say, values, retryAfter, headers = {} } = {}) {
    const lang = languageOf(req);
    const [defaultTitle, defaultMessage] = errorText(status, lang);
    const said = say ? message(say, lang, values) : null;
    const error = { status, title: said?.title ?? defaultTitle, message: said?.message ?? defaultMessage };
    res.removeHeader('Content-Disposition');
    res.setHeader('Cache-Control', 'no-store');
    if (retryAfter) res.setHeader('Retry-After', String(retryAfter));
    for (const [name, value] of Object.entries(headers)) res.setHeader(name, value);
    if (wantsJson(req)) {
      sendJson(req, res, status, { error: status, title: error.title, message: error.message, ...(retryAfter ? { retryAfter } : {}) });
      return;
    }
    let html;
    try {
      html = state.site.renderHtml(lang === 'en' ? 'en/_error' : '_error', {
        ...state.models[lang],
        page: pageView(lang, lang === 'en' ? HOME.de : HOME.en),
        error: { ...error, retry: status === 429 || status === 503 },
      });
    } catch {
      html = `<!doctype html><meta charset="utf-8"><title>${status}</title><p>${escapeHtml(error.message)}</p>`;
    }
    send(req, res, status, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Language': lang, Vary: 'Accept-Language' }, html);
  }

  /**
   * The answer to a flood: one line of plain text, nothing rendered, almost no headers (plain
   * text needs no CSP), no log line, no limit charged. It costs about as much as the request that
   * caused it, so refusing can never be turned against the upload of the connection.
   * Returns false, for callers that report whether the request may go on.
   */
  function tiny(req, res, ctx, status, text, retryAfter) {
    ctx.tiny = true;
    res.sendDate = false;
    // no-store: the answer depends on who asks, and a cache on the way must not keep it for others.
    const headers = { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' };
    if (retryAfter) headers['Retry-After'] = String(retryAfter);
    send(req, res, status, headers, text);
    return false;
  }

  /** The limits every request passes first. Answers and returns false when one of them is used up. */
  function withinLimits(req, res, ctx) {
    if (ctx.local) return true;
    const requests = requestRate.take(ctx.key);
    if (!requests.ok) return tiny(req, res, ctx, 429, TOO_MANY, requests.retryAfter);
    const bytes = addressBytes.peek(ctx.key);
    if (!bytes.ok) return tiny(req, res, ctx, 429, TOO_MANY, bytes.retryAfter);
    const site = siteBytes.peek('all');
    if (site.ok) return true;
    // Over what the upload should carry. Whoever got a lot lately goes first, so that a few greedy
    // addresses cannot shut out a visitor's first pages. If that is not enough, everybody waits.
    const light = addressBytes.peek(ctx.key, addressBytes.capacity - LIGHT_BYTES).ok;
    if (light && siteBytes.peek('all', -siteBytes.capacity).ok) return true;
    return tiny(req, res, ctx, 503, BUSY, site.retryAfter);
  }

  function expectedOrigins(req) {
    const origins = new Set([config.origin]);
    const host = String(req.headers.host || '').toLowerCase();
    if (DEV_HOST.test(host) || config.allowedHosts.has(host)) {
      origins.add(`http://${host}`);
      origins.add(`https://${host}`);
    }
    return origins;
  }

  /** A form post from this website's own pages: no other website, no script without browser headers. */
  function ownForm(req) {
    const fetchSite = req.headers['sec-fetch-site'];
    const origin = req.headers.origin;
    return !((fetchSite && fetchSite !== 'same-origin') || (origin && !expectedOrigins(req).has(origin)) || (!fetchSite && !origin));
  }

  /** The body of a small form, or null when it has answered instead. */
  async function readForm(req, res, ctx) {
    const leave = bodies.enter(networkKey(ctx.ip));
    if (!leave) {
      fail(req, res, 429, { retryAfter: 5 });
      return null;
    }
    try {
      const body = await readBody(req, 1024);
      if (body === null) fail(req, res, 413);
      return body;
    } finally {
      leave();
    }
  }

  const passwordMatches = (password) => crypto.timingSafeEqual(sha256(String(password)), passwordHash);

  /** A login cookie value: expiry (Unix seconds) and its signature. */
  function loginToken(expires) {
    return `${expires}.${crypto.createHmac('sha256', loginKey).update(`login:${expires}`).digest('base64url')}`;
  }

  function hasLoginCookie(req) {
    const header = String(req.headers.cookie || '');
    if (header.length > 4096) return false;
    const prefix = `${loginCookie}=`;
    const value = header
      .split(';')
      .map((part) => part.trim())
      .find((part) => part.startsWith(prefix))
      ?.slice(prefix.length);
    const match = /^(\d{10})\.[A-Za-z0-9_-]{43}$/.exec(value || '');
    if (!match) return false;
    const expires = Number(match[1]);
    const now = Date.now() / 1000;
    if (expires < now || expires > now + LOGIN_DAYS * 86_400 + 60) return false;
    const expected = Buffer.from(loginToken(expires));
    return crypto.timingSafeEqual(Buffer.from(value), expected);
  }

  /**
   * Whether this address may try a password right now. Asked before comparing, on /login and
   * with Basic Auth alike, and only wrong passwords use it up: a whole class may sign in at
   * once, but while guessing is slowed down, a right guess looks like any other.
   */
  function guessingLimit(ctx) {
    if (ctx.local) return { ok: true, retryAfter: 0 };
    const key = networkKey(ctx.ip);
    const now = passwordRate.peek(key);
    return now.ok ? guessesPerDay.check(key) : now;
  }

  function wrongPassword(ctx) {
    log.info('password.wrong', { ip: anonymizeIp(ctx.ip) });
    if (ctx.local) return;
    const key = networkKey(ctx.ip);
    passwordRate.take(key);
    guessesPerDay.record(key);
  }

  /**
   * With SITE_PASSWORD, everything except OPEN_PATHS and the static files needs signing in.
   * Browsers sign in on /login (only a password field) and then send a cookie; scripts may send
   * the password with HTTP Basic Auth (user name ignored, the browser never asks for it). Without:
   * pages redirect to /login, everything else gets 401. Returns false when it has answered.
   */
  function admitted(req, res, ctx, path) {
    if (!passwordHash || hasLoginCookie(req)) return true;
    const basic = /^Basic +([A-Za-z0-9+/]+={0,2}) *$/i.exec(String(req.headers.authorization || ''));
    if (basic) {
      const limit = guessingLimit(ctx);
      if (!limit.ok) {
        fail(req, res, 429, { retryAfter: limit.retryAfter });
        return false;
      }
      const credentials = Buffer.from(basic[1], 'base64').toString('utf8');
      const colon = credentials.indexOf(':');
      if (colon !== -1 && passwordMatches(credentials.slice(colon + 1))) return true;
      wrongPassword(ctx);
    }
    if ((req.method === 'GET' || req.method === 'HEAD') && (PAGES.has(path) || path === '/index.html')) {
      const lang = languageOfPath(path);
      const home = path === HOME[lang] || path === '/index.html';
      redirect(req, res, 303, home ? LOGIN[lang] : `${LOGIN[lang]}?weiter=${encodeURIComponent(path)}`);
      return false;
    }
    fail(req, res, 401);
    return false;
  }

  function loginPage(req, res, lang, status, next, wrong = false) {
    const other = lang === 'en' ? 'de' : 'en';
    const html = state.site.renderHtml(lang === 'en' ? 'en/_login' : '_login', {
      ...state.models[lang],
      page: pageView(lang, `${LOGIN[other]}?weiter=${encodeURIComponent(counterpart(next))}`, LOGIN),
      login: { next, wrong },
    });
    send(req, res, status, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Content-Language': lang }, html);
  }

  /**
   * GET shows the password form; POST checks the password and sets the login cookie. The login
   * page exists in German (/login) and English (/en/login); after it come the pages of its language.
   */
  async function login(req, res, ctx, lang, query) {
    const wanted = (value) => (PAGES.has(value) ? inLanguage(value, lang) : HOME[lang]);
    if (!passwordHash) return redirect(req, res, 303, HOME[lang]);
    if (req.method !== 'POST') {
      const next = wanted(query.get('weiter'));
      return hasLoginCookie(req) ? redirect(req, res, 303, next) : loginPage(req, res, lang, 200, next);
    }
    // Only this website's own form may sign in.
    if (!ownForm(req)) return fail(req, res, 403);
    const type = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
    if (type !== 'application/x-www-form-urlencoded') return fail(req, res, 415);
    const body = await readForm(req, res, ctx);
    if (body === null) return;
    const form = new URLSearchParams(body);
    const next = wanted(form.get('weiter'));
    const limit = guessingLimit(ctx);
    if (!limit.ok) return fail(req, res, 429, { retryAfter: limit.retryAfter });
    if (!passwordMatches(form.get('passwort') ?? '')) {
      wrongPassword(ctx);
      return loginPage(req, res, lang, 401, next, true);
    }
    const maxAge = LOGIN_DAYS * 86_400;
    const token = loginToken(Math.floor(Date.now() / 1000) + maxAge);
    res.setHeader(
      'Set-Cookie',
      `${loginCookie}=${token}; Path=/; Max-Age=${maxAge}; HttpOnly; SameSite=Lax${config.secure ? '; Secure' : ''}`,
    );
    log.info('login', { ip: anonymizeIp(ctx.ip) });
    return redirect(req, res, 303, next);
  }

  /** Signs out of this browser, for shared computers. Only by the website's own form. */
  function logout(req, res, lang) {
    if (!passwordHash || req.method !== 'POST') return redirect(req, res, 303, HOME[lang]);
    if (!ownForm(req)) return fail(req, res, 403);
    res.setHeader('Set-Cookie', `${loginCookie}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax${config.secure ? '; Secure' : ''}`);
    return redirect(req, res, 303, LOGIN[lang]);
  }

  function busy(req, res) {
    return fail(req, res, 503, { retryAfter: 15, say: 'busy' });
  }

  async function issueLink(req, res, ctx, platform) {
    res.setHeader('Cache-Control', 'no-store');

    // Only this website's own page may ask for a link: no hotlinking, no forms elsewhere.
    if (!ownForm(req)) {
      return fail(req, res, 403, { say: 'refused' });
    }

    const type = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
    if (type && type !== 'application/x-www-form-urlencoded') return fail(req, res, 415);
    const body = await readForm(req, res, ctx);
    if (body === null) return;

    // A field people never see: only bots fill it in.
    if (new URLSearchParams(body).get('website')) {
      return fail(req, res, 403, { say: 'refused' });
    }

    const release = state.releases[platform];
    if (!release) {
      return fail(req, res, 404, { say: 'notYet', values: { platform: PLATFORMS[platform].label } });
    }
    // On GitHub: the page links there; only a page from before the switch still posts here.
    if (release.external) return fail(req, res, 410, { say: 'moved' });

    // Answer "busy" here, on the page, rather than after the browser has left it for the file.
    if (!gate.hasRoom(ctx.key)) return busy(req, res);

    const expires = Math.floor(Date.now() / 1000) + L.linkSeconds;
    const token = signer.sign({
      p: platform,
      f: release.fingerprint,
      x: expires,
      a: L.bindLinkToIp ? signer.tag(ctx.key) : '',
      n: randomId(16),
    });
    const location = `/dl/${token}`;
    if (wantsJson(req)) {
      return sendJson(req, res, 200, { url: location, file: release.file, size: release.size, sha256: release.sha256, expires });
    }
    return redirect(req, res, 303, location);
  }

  /**
   * Past the daily allowance of the site or of this address, downloads share a slow lane instead
   * of stopping: slow costs the upload little, and nobody can switch the downloads off for a day.
   */
  const overAllowance = (ctx) => !budget.allows() || (!ctx.local && !traffic.allows(ctx.key));

  /** The slowest this download may get before it is cut off (bytes per second, 0 = no check). */
  function minimumRate(ctx) {
    return downloadFloor({
      floor: L.minBytesPerSecond,
      laneRate: overAllowance(ctx) ? L.slowLaneBytesPerSecond : L.totalBytesPerSecond,
      perDownload: L.perDownloadBytesPerSecond,
      active: gate.active,
      slots: L.concurrentTotal,
    });
  }

  async function serveDownload(req, res, ctx, token) {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Robots-Tag', 'noindex');

    const link = signer.verify(token);
    if (
      !link ||
      !Object.hasOwn(PLATFORMS, link.p) ||
      !Number.isFinite(link.x) ||
      typeof link.f !== 'string' ||
      typeof link.a !== 'string' ||
      typeof link.n !== 'string'
    ) {
      return fail(req, res, 404, { say: 'invalidLink' });
    }
    if (link.x < Date.now() / 1000) {
      return fail(req, res, 410, { say: 'expired', values: { seconds: L.linkSeconds } });
    }
    if (link.a && link.a !== signer.tag(ctx.key)) {
      return fail(req, res, 403, { say: 'otherDevice' });
    }
    const release = state.releases[link.p];
    // A link from before the file moved to GitHub: there is no file here to send.
    if (release?.external) return fail(req, res, 410, { say: 'moved' });
    if (!release || release.fingerprint !== link.f) {
      return fail(req, res, 410, { say: 'newVersion' });
    }

    let start = 0;
    let end = release.size - 1;
    let status = 200;
    const ifRange = req.headers['if-range'];
    if (req.headers.range && (!ifRange || ifRange === release.etag || ifRange === release.mtime.toUTCString())) {
      const range = parseRange(req.headers.range, release.size);
      if (range === 'unsatisfiable') {
        return send(req, res, 416, { 'Content-Range': `bytes */${release.size}`, 'Content-Type': 'text/plain; charset=utf-8' }, '');
      }
      if (range) {
        ({ start, end } = range);
        status = 206;
      }
    }
    const length = end - start + 1;

    const downloadHeaders = () => {
      res.statusCode = status;
      res.setHeader('Content-Type', release.contentType);
      res.setHeader('Content-Disposition', `attachment; filename="${release.file}"`);
      res.setHeader('Content-Length', length);
      res.setHeader('Accept-Ranges', 'bytes');
      res.setHeader('ETag', release.etag);
      res.setHeader('Last-Modified', release.mtime.toUTCString());
      res.setHeader('Repr-Digest', `sha-256=:${release.sha256Base64}:`);
      if (status === 206) res.setHeader('Content-Range', `bytes ${start}-${end}/${release.size}`);
    };

    if (req.method === 'HEAD') {
      downloadHeaders();
      res.end();
      return;
    }

    let usage = links.get(link.n);
    if (!usage) {
      usage = { uses: 0, sent: 0, counted: false, expires: link.x };
      links.set(link.n, usage);
    }
    if (usage.uses >= L.linkUses) {
      return fail(req, res, 410, { say: 'used' });
    }
    // Both before the first wait: requests arriving together must not all pass the check above,
    // and a client that is gone by then must not leave a download waiting for it, slot and all.
    usage.uses += 1;
    const abort = new AbortController();
    const onClose = () => abort.abort();
    res.once('close', onClose);

    // Open the file exactly as it was measured: no symlink, same size and time. A file
    // replaced in the meantime waits for the next reload instead of mixing two versions.
    let handle;
    try {
      handle = await fsp.open(release.path, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
      const stat = await handle.stat();
      if (!stat.isFile() || stat.size !== release.size || stat.mtimeMs !== release.mtimeMs) {
        throw new Error('Die Datei hat sich geändert.');
      }
    } catch (error) {
      await handle?.close().catch(() => {});
      res.off('close', onClose);
      usage.uses -= 1;
      log.warn('download.file', { file: release.file, message: error.message });
      reload('download');
      return fail(req, res, 503, { retryAfter: 20, say: 'replacing' });
    }

    const leave = abort.signal.aborted ? null : gate.enter(ctx.key);
    if (!leave) {
      await handle.close().catch(() => {});
      res.off('close', onClose);
      usage.uses -= 1;
      return busy(req, res);
    }
    ctx.file = true;
    downloadHeaders();

    const perDownload = new ByteRate(L.perDownloadBytesPerSecond);
    const startedAt = performance.now();
    let sent = 0;

    // Watchdog: a download that crawls (or takes hours) gives its slot back. It is judged on the
    // average of the last three checks, so that one good moment cannot make up for the rest.
    const checkMs = Math.min(10_000, L.slowGraceSeconds * 1000);
    const marks = [0, 0, 0];
    let checks = 0;
    const watchdog = setInterval(() => {
      const elapsed = performance.now() - startedAt;
      if (elapsed > L.maxDownloadMinutes * 60_000) {
        abort.abort(new Error('Download dauerte zu lange.'));
        return;
      }
      const rate = ((sent - marks.shift()) * 1000) / (3 * checkMs);
      marks.push(sent);
      checks += 1;
      if (checks >= 3 && elapsed >= L.slowGraceSeconds * 1000 && rate < minimumRate(ctx)) {
        abort.abort(new Error('Download zu langsam.'));
      }
    }, checkMs);
    watchdog.unref();

    try {
      const file = handle.createReadStream({ start, end, highWaterMark: 64 * 1024 });
      abort.signal.addEventListener('abort', () => file.destroy(), { once: true });
      for await (const chunk of file) {
        if (overAllowance(ctx)) await slowLane.take(chunk.length, abort.signal);
        await totalRate.take(chunk.length, abort.signal);
        await perDownload.take(chunk.length, abort.signal);
        const room = res.write(chunk);
        sent += chunk.length;
        usage.sent += chunk.length;
        ctx.bytes = sent;
        budget.add(chunk.length);
        if (!ctx.local) traffic.add(ctx.key, chunk.length);
        // At once, not after the loop: the client may have the whole file before the loop ends.
        if (usage.sent >= release.size && !usage.counted) {
          usage.counted = true;
          stats.count(release.platform);
        }
        if (!room) await once(res, 'drain', { signal: abort.signal });
      }
      if (sent !== length) throw new Error(`Datei kürzer als erwartet (${sent} von ${length} Bytes).`);
      res.end();
    } catch (error) {
      const reason = abort.signal.reason;
      if (reason instanceof Error && reason.name !== 'AbortError') log.info('download.cut', { ip: anonymizeIp(ctx.ip), reason: reason.message, bytes: sent });
      else if (!abort.signal.aborted) log.warn('download', { message: error.message });
      res.destroy();
    } finally {
      clearInterval(watchdog);
      res.off('close', onClose);
      leave();
      await handle.close().catch(() => {});
    }
  }

  async function route(req, res, ctx) {
    if (requestedByOtherWebsite(req)) return tiny(req, res, ctx, 403, NOT_ALLOWED);
    if (!withinLimits(req, res, ctx)) return;
    for (const [name, value] of Object.entries(baseHeaders)) res.setHeader(name, value);

    if (!METHODS.has(req.method)) return fail(req, res, 405, { headers: { Allow: 'GET, HEAD, POST' } });
    const url = req.url || '';
    if (url.length > 2048) return fail(req, res, 414);
    if (!url.startsWith('/')) return fail(req, res, 400);
    const host = String(req.headers.host || '').toLowerCase();
    if (!config.allowedHosts.has(host) && !DEV_HOST.test(host)) return fail(req, res, 421);

    const queryAt = url.indexOf('?');
    const rawPath = queryAt === -1 ? url : url.slice(0, queryAt);
    const query = queryAt === -1 ? '' : url.slice(queryAt + 1);
    // Encoded slashes and backslashes have no business in a path.
    if (/%(?:2f|5c|00)/i.test(rawPath)) return fail(req, res, 400);
    let path;
    try {
      path = decodeURIComponent(rawPath);
    } catch {
      return fail(req, res, 400);
    }
    if (path.includes('\0') || path.includes('\\') || path.includes('//') || /(?:^|\/)\.{1,2}(?:\/|$)/.test(path)) {
      return fail(req, res, 400);
    }
    ctx.path = path.startsWith('/dl/') ? '/dl/…' : path.slice(0, 80);

    // Only the download form sends a body.
    if (req.method !== 'POST' && (Number(req.headers['content-length']) > 0 || req.headers['transfer-encoding'])) {
      return fail(req, res, 400);
    }

    const asset = req.method === 'POST' ? null : state.site.statics.get(path);
    if (asset) return sendEntry(req, res, asset, { versioned: new URLSearchParams(query).get('v') === asset.version });

    if (path === LOGIN.de || path === LOGIN.en) return login(req, res, ctx, languageOfPath(path), new URLSearchParams(query));
    if (path === '/logout' || path === '/en/logout') return logout(req, res, languageOfPath(path));
    if (!OPEN_PATHS.has(path) && !admitted(req, res, ctx, path)) return;

    const personal = Boolean(passwordHash);
    const page = state.pages.get(path);
    if (page) {
      if (req.method === 'POST') return fail(req, res, 405, { headers: { Allow: 'GET, HEAD' } });
      return sendEntry(req, res, page, { personal });
    }
    if (path === '/index.html') return redirect(req, res, 301, '/');
    if (path.length > 1 && path.endsWith('/') && state.pages.has(path.slice(0, -1))) {
      return redirect(req, res, 301, path.slice(0, -1));
    }
    if (path === '/checksums.txt' && req.method !== 'POST') return sendEntry(req, res, state.checksums, { personal });
    if (path === '/healthz' && req.method !== 'POST') {
      return send(req, res, 200, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' }, 'ok\n');
    }
    if (path === '/.well-known/security.txt' && config.contactEmail && req.method !== 'POST') {
      const expires = new Date(Date.now() + 180 * 86_400_000).toISOString();
      const body = [
        `Contact: mailto:${config.contactEmail}`,
        `Expires: ${expires}`,
        'Preferred-Languages: de, en',
        `Canonical: ${config.origin}/.well-known/security.txt`,
        '',
      ].join('\n');
      return send(req, res, 200, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'public, max-age=86400' }, body);
    }

    const platform = PLATFORM_PATH.exec(path)?.[1];
    if (platform) {
      if (req.method === 'POST') return issueLink(req, res, ctx, platform);
      return redirect(req, res, 303, languageOf(req) === 'en' ? '/en#download' : '/#download');
    }
    const token = LINK_PATH.exec(path)?.[1];
    if (token) {
      if (req.method === 'POST') return fail(req, res, 405, { headers: { Allow: 'GET, HEAD' } });
      return serveDownload(req, res, ctx, token);
    }
    if (path.startsWith('/dl/')) {
      return fail(req, res, 404, { say: 'invalidLink' });
    }
    return fail(req, res, 404);
  }

  /** Charges a response as soon as it is under way: a client that never reads it must not put this off. */
  function charge(req, res, ctx) {
    if (ctx.tiny || ctx.local || ctx.file) return;
    const bytes = HEADER_BYTES + (req.method === 'HEAD' ? 0 : Number(res.getHeader('Content-Length')) || 0);
    addressBytes.spend(ctx.key, bytes);
    siteBytes.spend('all', bytes);
  }

  /** After each response: logs it, unless too many are coming in. */
  function finished(req, res, ctx, started) {
    if (ctx.tiny) {
      refused += 1;
      return;
    }
    if (!config.accessLog) return;
    if (!logRate.take('all').ok) {
      unlogged += 1;
      return;
    }
    log.info('request', {
      ip: anonymizeIp(ctx.ip),
      method: req.method,
      path: ctx.path,
      status: res.statusCode,
      ms: Math.round(performance.now() - started),
      ...(ctx.bytes ? { bytes: ctx.bytes } : {}),
    });
  }

  /** `proxySocket`: the request came over the Unix socket of LISTEN_SOCKET, i.e. from the proxy. */
  async function handle(req, res, { proxySocket = false } = {}) {
    const started = performance.now();
    const peer = proxySocket ? '' : normalizeIp(req.socket?.remoteAddress);
    const forwardedFor = req.headers['x-forwarded-for'];
    const ip = clientIp(req, trust, { proxySocket });
    const ctx = {
      ip,
      key: ipKey(ip),
      // Only a request straight from this machine is exempt from the limits (health check,
      // local testing). Through a proxy, every client counts, also a private address, and
      // over the socket it is always the proxy.
      local: !proxySocket && !forwardedFor && isLoopback(peer),
      path: '-',
      bytes: 0,
      tiny: false, // answered by tiny()
      file: false, // a download: its bytes have their own limits
    };

    if (proxySocket && !ip) {
      warnOnce('proxy.socket', 'Über den Socket kam eine Anfrage ohne brauchbares X-Forwarded-For: Solche Besucher teilen sich alle eine Grenze. Der Proxy muss den Header setzen.');
    } else if (forwardedFor && peer === ip && isPrivate(peer)) {
      warnOnce('proxy', 'X-Forwarded-For von einem nicht vertrauten Proxy ignoriert, alle Besucher erscheinen gleich. Hinter Docker TRUST_PROXY=private setzen.');
    } else if (forwardedFor && peer !== ip && isPrivate(ip)) {
      warnOnce('proxy.private', `Besucher kommen über den Proxy mit privater Adresse an (${anonymizeIp(ip)}). Die Limits gelten dann für alle zusammen. Bei Docker die Ports nur über IPv4 freigeben oder IPv6 im Docker-Netz einschalten.`);
    }
    res.once('close', () => finished(req, res, ctx, started));
    try {
      await route(req, res, ctx);
    } catch (error) {
      log.error('handler', { message: error.message, stack: String(error.stack).split('\n').slice(1, 4).join(' | ') });
      if (!res.headersSent) fail(req, res, 500);
      else res.destroy();
    }
    charge(req, res, ctx);
  }

  return {
    handle,
    /** The handler for the Unix socket (LISTEN_SOCKET): every request comes from the proxy. */
    handleProxied: (req, res) => handle(req, res, { proxySocket: true }),
    reload,
    get state() {
      return state;
    },
    /** Downloads running right now. */
    get activeDownloads() {
      return gate.active;
    },
    stats,
    async close() {
      clearInterval(watcher);
      clearInterval(sweeper);
      clearInterval(reporter);
      await stats.flush();
    },
  };
}
