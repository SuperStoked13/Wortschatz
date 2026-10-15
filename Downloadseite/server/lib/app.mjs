// The request handler: pages, static files, download links and every protection
// around them (see README, section "Sicherheit").

import crypto from 'node:crypto';
import { once } from 'node:events';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { anonymizeIp, buildTrust, clientIp, ipKey, isLoopback, normalizeIp } from './net.mjs';
import {
  ConcurrencyGate,
  DailyBudget,
  DailyQuota,
  LruMap,
  PenaltyBox,
  TokenBucket,
  WindowCounter,
  secondsUntilTomorrow,
} from './limits.mjs';
import { ByteRate } from './throttle.mjs';
import { LinkSigner, randomId } from './tokens.mjs';
import { PLATFORMS, checksumsText, loadReleases, releasesSignature } from './releases.mjs';
import { loadSite, makeEntry } from './site.mjs';
import { changelogView, parseChangelog } from './changelog.mjs';
import { escapeHtml } from './templates.mjs';
import { humanWait, parseRange, securityHeaders, send, sendEntry, sendJson, wantsJson } from './http.mjs';
import { createStats } from './stats.mjs';

const METHODS = new Set(['GET', 'HEAD', 'POST']);
const PAGES = new Map([
  ['/', 'index'],
  ['/datenschutz', 'datenschutz'],
  ['/neuigkeiten', 'neuigkeiten'],
]);
const CHANGELOG = '_neuigkeiten.md';
const DEV_HOST = /^(?:localhost|127\.0\.0\.1|\[::1\])(?::\d{1,5})?$/;
const PLATFORM_PATH = /^\/download\/(mac|windows)$/;
const LINK_PATH = /^\/dl\/([A-Za-z0-9_-]{8,700}\.[A-Za-z0-9_-]{43})$/;
const VERSIONED = /(?:^|&)v=[0-9a-f]{10}(?:&|$)/;
// With SITE_PASSWORD: what is open without signing in (the login page needs the static files),
// and how long a browser stays signed in.
const OPEN_PATHS = new Set(['/login', '/healthz', '/datenschutz']);
const LOGIN_DAYS = 90;

// Paths only vulnerability scanners ask for. Two hits block the address.
const TRAPS = [
  /^\/(?:wp-|wordpress|xmlrpc|phpmyadmin|pma(?:\/|$)|myadmin|adminer|cgi-bin|vendor\/|\.env|\.git|\.svn|\.hg|\.aws|\.ssh|\.docker|\.vscode|\.idea|\.ht|server-status|actuator|boaform|hnap1|owa\/|autodiscover|ecp\/|remote\/|solr|druid|jenkins|telescope|_ignition|console|shell|cmd|admin|setup|install|config)/i,
  /\.(?:php\d?|asp|aspx|jsp|cgi|env|ini|bak|sql|old|swp|yml|yaml|config|tar|gz|rar|7z)$/i,
];

const ERRORS = Object.freeze({
  400: ['Ungültige Anfrage', 'Diese Adresse kann der Server nicht verarbeiten.'],
  401: ['Anmeldung nötig', 'Diese Seite ist passwortgeschützt. Melde dich auf der Startseite mit dem Passwort an.'],
  403: ['Kein Zugriff', 'Diese Anfrage ist nicht erlaubt.'],
  404: ['Seite nicht gefunden', 'Diese Seite gibt es nicht. Prüf die Adresse oder geh zur Startseite.'],
  405: ['Nicht erlaubt', 'Diese Art von Anfrage wird hier nicht unterstützt.'],
  410: ['Nicht mehr gültig', 'Dieser Link gilt nicht mehr. Lade Wortschatz über die Website.'],
  413: ['Anfrage zu gross', 'Die Anfrage ist zu gross.'],
  414: ['Adresse zu lang', 'Die Adresse ist zu lang.'],
  415: ['Format nicht unterstützt', 'Dieses Format nimmt der Server nicht an.'],
  421: ['Falsche Adresse', 'Diese Website ist unter einer anderen Adresse erreichbar.'],
  429: ['Zu viele Anfragen', 'Von deiner Internetadresse kamen sehr viele Anfragen. Warte einen Moment und versuch es dann nochmals.'],
  500: ['Serverfehler', 'Etwas ist schiefgelaufen. Versuch es in einem Moment nochmals.'],
  503: ['Gerade ausgelastet', 'Der Server ist im Moment ausgelastet. Versuch es gleich nochmals.'],
});

const sha256 = (text) => crypto.createHash('sha256').update(text, 'utf8').digest();

function redirect(req, res, status, location) {
  send(req, res, status, { Location: location, 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' }, `${location}\n`);
}

/** The request body as text, or null when it is larger than `limit` bytes. */
function readBody(req, limit) {
  return new Promise((resolve, reject) => {
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
    req.on('error', (error) => {
      if (done) return;
      done = true;
      reject(error);
    });
  });
}

function seconds(n) {
  return n % 60 === 0 ? `${n / 60} ${n === 60 ? 'Minute' : 'Minuten'}` : `${n} Sekunden`;
}

/** The values the templates see. */
function viewModel(releases, config, changelog) {
  const pick = (release) =>
    release
      ? {
          available: true,
          version: release.version,
          versionLabel: release.build ? `${release.version} (${release.build})` : release.version,
          file: release.file,
          sizeLabel: release.sizeLabel,
          sha256: release.sha256,
          requirement: release.requirement,
          architecture: release.architecture,
          released: release.released,
          releasedLabel: release.releasedLabel,
        }
      : { available: false };
  const mac = pick(releases.mac);
  const windows = pick(releases.windows);
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
    version: mac.version || windows.version || '',
    updates: changelogView(changelog, releases),
  };
}

export async function createApp(config, log) {
  const trust = buildTrust(config.trustProxy);
  const privateNets = buildTrust('private');
  const signer = new LinkSigner(config.secret);
  const L = config.limits;

  const pageRate = new TokenBucket({ capacity: L.pageBurst, perSecond: L.pagePerMinute / 60 });
  const assetRate = new TokenBucket({ capacity: L.assetBurst, perSecond: L.assetPerMinute / 60 });
  const hourly = new WindowCounter({ limit: L.downloadsPerHour, windowMs: 3_600_000 });
  const daily = new WindowCounter({ limit: L.downloadsPerDay, windowMs: 86_400_000 });
  const traffic = new DailyQuota({ limit: L.dailyBytesPerIp });
  const penalties = new PenaltyBox({ threshold: L.banThreshold, decayMs: 10 * 60_000, banMs: L.banMinutes * 60_000 });
  const gate = new ConcurrencyGate({ perKey: L.concurrentPerIp, total: L.concurrentTotal });
  const budget = new DailyBudget({ bytesPerDay: L.dailyBytes });
  const totalRate = new ByteRate(L.totalBytesPerSecond);
  // Wrong passwords per address: ten tries, then one every 12 seconds (guessing takes forever).
  const passwordRate = new TokenBucket({ capacity: 10, perSecond: 5 / 60 });
  const passwordHash = config.password ? sha256(config.password) : null;
  // Signs the login cookies. Derived from the password: a new password signs everybody out,
  // a restart or a new release does not.
  const loginKey = config.password ? crypto.createHmac('sha256', config.password).update('wortschatz-login').digest() : null;
  // __Host-: only over HTTPS, only for this exact host and path / (no subdomain can set or read it).
  const loginCookie = config.secure ? '__Host-wortschatz' : 'wortschatz';
  const links = new LruMap(50_000);
  const stats = await createStats(config.dataDir, log);
  const baseHeaders = securityHeaders(config);
  const warned = new Set();

  const warnOnce = (id, message) => {
    if (warned.has(id)) return;
    warned.add(id);
    log.warn(id, { message });
  };

  async function build() {
    const [site, releases] = await Promise.all([loadSite(config.publicDir), loadReleases(config.releasesDir, log)]);
    const changelog = parseChangelog(site.text(CHANGELOG));
    for (const { line, message } of changelog.problems) log.warn('changelog', { file: CHANGELOG, line, message });
    const model = viewModel(releases, config, changelog);
    const pages = new Map();
    for (const [route, name] of PAGES) pages.set(route, site.renderPage(name, model));
    site.renderHtml('_error', { ...model, error: { status: 404, title: 'Test', message: 'Test' } });
    site.renderHtml('_login', { ...model, login: { next: '/', error: '' } });
    const checksums = makeEntry(Buffer.from(checksumsText(releases, config.origin), 'utf8'), 'text/plain; charset=utf-8', {
      cacheControl: 'no-cache',
    });
    return { site, releases, model, pages, checksums };
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
    pageRate.sweep();
    assetRate.sweep();
    passwordRate.sweep();
    hourly.sweep();
    daily.sweep();
    traffic.sweep();
    penalties.sweep();
    const now = Date.now() / 1000;
    for (const [id, usage] of links) if (usage.expires < now - 3600) links.delete(id);
  }, 5 * 60_000);
  sweeper.unref();

  const isPrivate = (ip) => Boolean(ip) && privateNets.check(ip, ip.includes(':') ? 'ipv6' : 'ipv4');

  /**
   * Penalty points lead to a block. Never for this machine or private addresses (a wrongly
   * configured proxy would otherwise lock everybody out), and never for requests a browser
   * makes on behalf of another website (an <img src="…/.env"> must not get visitors blocked).
   */
  function penalize(ctx, points) {
    if (ctx.local || ctx.shielded || ctx.foreign) return;
    if (penalties.add(ctx.key, points)) {
      log.warn('blocked', { ip: anonymizeIp(ctx.ip), path: ctx.path, minutes: L.banMinutes });
    }
  }

  function fail(req, res, status, { title, message, retryAfter, headers = {} } = {}) {
    const [defaultTitle, defaultMessage] = ERRORS[status] ?? ERRORS[500];
    const error = { status, title: title ?? defaultTitle, message: message ?? defaultMessage };
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
      html = state.site.renderHtml('_error', {
        ...state.model,
        error: { ...error, retry: status === 429 || status === 503 },
      });
    } catch {
      html = `<!doctype html><meta charset="utf-8"><title>${status}</title><p>${escapeHtml(error.message)}</p>`;
    }
    send(req, res, status, { 'Content-Type': 'text/html; charset=utf-8' }, html);
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

  /** A browser request that another website triggered (Sec-Fetch-Site, else the Referer). */
  function isForeign(req) {
    const site = req.headers['sec-fetch-site'];
    if (site) return site === 'cross-site' || site === 'same-site';
    const referer = req.headers.referer;
    if (!referer) return false;
    try {
      return !expectedOrigins(req).has(new URL(referer).origin);
    } catch {
      return false;
    }
  }

  const passwordMatches = (password) => crypto.timingSafeEqual(sha256(String(password)), passwordHash);

  /** A login cookie value: expiry (Unix seconds) and its signature. */
  function loginToken(expires) {
    return `${expires}.${crypto.createHmac('sha256', loginKey).update(`login:${expires}`).digest('base64url')}`;
  }

  function hasLoginCookie(req) {
    const prefix = `${loginCookie}=`;
    const value = String(req.headers.cookie || '')
      .split(';')
      .map((part) => part.trim())
      .find((part) => part.startsWith(prefix))
      ?.slice(prefix.length);
    const match = /^(\d{10})\.[A-Za-z0-9_-]{43}$/.exec(value || '');
    if (!match || Number(match[1]) < Date.now() / 1000) return false;
    const expected = Buffer.from(loginToken(Number(match[1])));
    return crypto.timingSafeEqual(Buffer.from(value), expected);
  }

  /**
   * Counts a password attempt for the address: ten at once, then one every 12 seconds. On /login
   * every attempt counts, also a right one, so guessing there really slows down; with Basic Auth
   * only wrong ones (a browser that remembers an earlier Basic login sends it with every request).
   * Answers 429 and returns false once there were too many.
   */
  function passwordAttempt(req, res, ctx) {
    if (ctx.local) return true;
    const limit = passwordRate.take(ctx.key);
    if (limit.ok) return true;
    penalize(ctx, 1);
    fail(req, res, 429, { retryAfter: limit.retryAfter });
    return false;
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
      const credentials = Buffer.from(basic[1], 'base64').toString('utf8');
      const colon = credentials.indexOf(':');
      if (colon !== -1 && passwordMatches(credentials.slice(colon + 1))) return true;
      log.info('password.wrong', { ip: anonymizeIp(ctx.ip) });
      if (!passwordAttempt(req, res, ctx)) return false;
    }
    if ((req.method === 'GET' || req.method === 'HEAD') && (PAGES.has(path) || path === '/index.html')) {
      redirect(req, res, 303, path === '/' || path === '/index.html' ? '/login' : `/login?weiter=${encodeURIComponent(path)}`);
      return false;
    }
    fail(req, res, 401);
    return false;
  }

  function loginPage(req, res, status, next, error = '') {
    const html = state.site.renderHtml('_login', { ...state.model, login: { next, error } });
    send(req, res, status, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' }, html);
  }

  /** GET shows the password form; POST checks the password and sets the login cookie. */
  async function login(req, res, ctx, query) {
    const wanted = (value) => (PAGES.has(value) ? value : '/');
    if (!passwordHash) return redirect(req, res, 303, '/');
    if (req.method !== 'POST') {
      const next = wanted(query.get('weiter'));
      return hasLoginCookie(req) ? redirect(req, res, 303, next) : loginPage(req, res, 200, next);
    }
    // Only this website's own form may sign in.
    const fetchSite = req.headers['sec-fetch-site'];
    const origin = req.headers.origin;
    if ((fetchSite && fetchSite !== 'same-origin') || (origin && !expectedOrigins(req).has(origin)) || (!fetchSite && !origin)) {
      penalize(ctx, 2);
      return fail(req, res, 403);
    }
    const type = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
    if (type !== 'application/x-www-form-urlencoded') return fail(req, res, 415);
    const body = await readBody(req, 1024);
    if (body === null) return fail(req, res, 413, { headers: { Connection: 'close' } });
    const form = new URLSearchParams(body);
    const next = wanted(form.get('weiter'));
    if (!passwordAttempt(req, res, ctx)) return;
    if (!passwordMatches(form.get('passwort') ?? '')) {
      log.info('password.wrong', { ip: anonymizeIp(ctx.ip) });
      return loginPage(req, res, 401, next, 'Das Passwort stimmt nicht.');
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

  function tooManyDownloads(req, res, ctx, retryAfter) {
    penalize(ctx, 1);
    return fail(req, res, 429, {
      retryAfter,
      title: 'Zu viele Downloads',
      message: `Von deiner Internetadresse wurde Wortschatz in kurzer Zeit sehr oft geladen. Versuch es in ${humanWait(retryAfter)} wieder.`,
    });
  }

  function trafficExhausted(req, res) {
    return fail(req, res, 429, {
      retryAfter: secondsUntilTomorrow(),
      title: 'Tageslimit erreicht',
      message: 'Von deiner Internetadresse wurde heute schon sehr viel geladen. Ab Mitternacht geht es wieder.',
    });
  }

  function busy(req, res) {
    return fail(req, res, 503, {
      retryAfter: 15,
      title: 'Gerade viel los',
      message: 'Im Moment laufen viele Downloads gleichzeitig. Versuch es in ein paar Sekunden nochmals.',
    });
  }

  /** Counts one more full download for this address, or answers 429 and returns false. */
  function countDownload(req, res, ctx) {
    if (ctx.local) return true;
    const perHour = hourly.check(ctx.key);
    const perDay = daily.check(ctx.key);
    if (!perHour.ok || !perDay.ok) {
      tooManyDownloads(req, res, ctx, Math.max(perHour.retryAfter, perDay.retryAfter));
      return false;
    }
    hourly.record(ctx.key);
    daily.record(ctx.key);
    return true;
  }

  async function issueLink(req, res, ctx, platform) {
    res.setHeader('Cache-Control', 'no-store');

    // Only this website's own page may ask for a link: no hotlinking, no forms elsewhere.
    const fetchSite = req.headers['sec-fetch-site'];
    const origin = req.headers.origin;
    if ((fetchSite && fetchSite !== 'same-origin') || (origin && !expectedOrigins(req).has(origin)) || (!fetchSite && !origin)) {
      penalize(ctx, 2);
      return fail(req, res, 403, { title: 'Download nicht möglich', message: 'Lade Wortschatz bitte direkt über die Website.' });
    }

    const type = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
    if (type && type !== 'application/x-www-form-urlencoded') return fail(req, res, 415);
    const body = await readBody(req, 1024);
    if (body === null) return fail(req, res, 413, { headers: { Connection: 'close' } });

    // A field people never see: only bots fill it in.
    if (new URLSearchParams(body).get('website')) {
      penalize(ctx, L.banThreshold);
      log.warn('honeypot', { ip: anonymizeIp(ctx.ip) });
      return fail(req, res, 403, { title: 'Download nicht möglich', message: 'Lade Wortschatz bitte direkt über die Website.' });
    }

    const release = state.releases[platform];
    if (!release) {
      return fail(req, res, 404, {
        title: 'Noch nicht verfügbar',
        message: `Die Version für ${PLATFORMS[platform].label} wird gerade vorbereitet.`,
      });
    }

    // Answer "busy" here, on the page, rather than after the browser has left it for the file.
    if (!gate.hasRoom(ctx.key)) return busy(req, res);
    if (!ctx.local && !traffic.allows(ctx.key)) return trafficExhausted(req, res);
    if (!countDownload(req, res, ctx)) return;

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

  /** The slowest a download may get before it is cut off (bytes per second, 0 = no check). */
  function minimumRate() {
    let floor = L.minBytesPerSecond;
    if (!floor) return 0;
    if (L.totalBytesPerSecond) floor = Math.min(floor, (L.totalBytesPerSecond / Math.max(1, gate.active)) * 0.5);
    if (L.perDownloadBytesPerSecond) floor = Math.min(floor, L.perDownloadBytesPerSecond * 0.5);
    return floor;
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
      penalize(ctx, 3);
      return fail(req, res, 404, { title: 'Link ungültig', message: 'Dieser Download-Link ist ungültig. Lade Wortschatz über die Website.' });
    }
    if (link.x < Date.now() / 1000) {
      return fail(req, res, 410, {
        title: 'Link abgelaufen',
        message: `Ein Download-Link gilt ${seconds(L.linkSeconds)}. Lade Wortschatz einfach nochmals über die Website.`,
      });
    }
    if (link.a && link.a !== signer.tag(ctx.key)) {
      penalize(ctx, 2);
      return fail(req, res, 403, {
        title: 'Link für ein anderes Gerät',
        message: 'Dieser Download-Link gilt nur für das Gerät, das ihn angefordert hat. Lade Wortschatz über die Website.',
      });
    }
    const release = state.releases[link.p];
    if (!release || release.fingerprint !== link.f) {
      return fail(req, res, 410, { title: 'Neue Version', message: 'Inzwischen gibt es eine neue Version. Lade sie über die Website.' });
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
      usage = { uses: 0, counted: false, expires: link.x };
      links.set(link.n, usage);
    }
    if (usage.uses >= L.linkUses) {
      return fail(req, res, 410, {
        title: 'Link schon verwendet',
        message: 'Dieser Download-Link wurde schon verwendet. Lade Wortschatz nochmals über die Website.',
      });
    }
    if (!budget.allows()) {
      return fail(req, res, 503, {
        retryAfter: secondsUntilTomorrow(),
        title: 'Tageslimit erreicht',
        message: 'Heute wurde Wortschatz schon sehr oft geladen. Ab Mitternacht geht es wieder.',
      });
    }
    if (!ctx.local && !traffic.allows(ctx.key)) return trafficExhausted(req, res);
    // The link request counted the first download; a new one from the start counts again.
    if (usage.uses > 0 && start === 0 && !countDownload(req, res, ctx)) return;

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
      log.warn('download.file', { file: release.file, message: error.message });
      reload('download');
      return fail(req, res, 503, {
        retryAfter: 20,
        title: 'Neue Version unterwegs',
        message: 'Die Datei wird gerade ersetzt. Versuch es in einer halben Minute nochmals.',
      });
    }

    const leave = gate.enter(ctx.key);
    if (!leave) {
      await handle.close().catch(() => {});
      return busy(req, res);
    }
    usage.uses += 1;
    downloadHeaders();

    const abort = new AbortController();
    const onClose = () => abort.abort();
    res.once('close', onClose);
    const perDownload = new ByteRate(L.perDownloadBytesPerSecond);
    const startedAt = performance.now();
    let sent = 0;

    // Watchdog: a download that crawls (or takes hours) gives its slot back.
    const checkMs = Math.min(10_000, L.slowGraceSeconds * 1000);
    let lastSent = 0;
    let slowChecks = 0;
    const watchdog = setInterval(() => {
      const elapsed = performance.now() - startedAt;
      if (elapsed > L.maxDownloadMinutes * 60_000) {
        abort.abort(new Error('Download dauerte zu lange.'));
        return;
      }
      const rate = ((sent - lastSent) * 1000) / checkMs;
      lastSent = sent;
      if (elapsed < L.slowGraceSeconds * 1000) return;
      slowChecks = rate < minimumRate() ? slowChecks + 1 : 0;
      if (slowChecks >= 3) abort.abort(new Error('Download zu langsam.'));
    }, checkMs);
    watchdog.unref();

    try {
      const file = handle.createReadStream({ start, end, highWaterMark: 64 * 1024 });
      abort.signal.addEventListener('abort', () => file.destroy(), { once: true });
      for await (const chunk of file) {
        await totalRate.take(chunk.length, abort.signal);
        await perDownload.take(chunk.length, abort.signal);
        if (!res.write(chunk)) await once(res, 'drain', { signal: abort.signal });
        sent += chunk.length;
        ctx.bytes = sent;
        budget.add(chunk.length);
        if (!ctx.local) traffic.add(ctx.key, chunk.length);
      }
      if (sent !== length) throw new Error(`Datei kürzer als erwartet (${sent} von ${length} Bytes).`);
      res.end();
      if (end === release.size - 1 && !usage.counted) {
        usage.counted = true;
        stats.count(release.platform);
      }
    } catch (error) {
      const reason = abort.signal.reason;
      if (reason instanceof Error) log.info('download.cut', { ip: anonymizeIp(ctx.ip), reason: reason.message, bytes: sent });
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
    const blocked = ctx.local || ctx.shielded ? 0 : penalties.blockedFor(ctx.key);
    if (blocked) {
      send(
        req,
        res,
        403,
        {
          'Content-Type': 'text/plain; charset=utf-8',
          'Cache-Control': 'no-store',
          'Retry-After': String(Math.ceil(blocked / 1000)),
          Connection: 'close',
        },
        'Zugriff vorübergehend gesperrt.\n',
      );
      return;
    }
    if (!METHODS.has(req.method)) {
      penalize(ctx, 2);
      return fail(req, res, 405, { headers: { Allow: 'GET, HEAD, POST' } });
    }
    const url = req.url || '';
    if (url.length > 2048) {
      penalize(ctx, 2);
      return fail(req, res, 414);
    }
    if (!url.startsWith('/')) {
      penalize(ctx, 2);
      return fail(req, res, 400);
    }
    const host = String(req.headers.host || '').toLowerCase();
    if (!config.allowedHosts.has(host) && !DEV_HOST.test(host)) return fail(req, res, 421);

    const queryAt = url.indexOf('?');
    const rawPath = queryAt === -1 ? url : url.slice(0, queryAt);
    // Encoded slashes and backslashes have no business in a path.
    if (/%(?:2f|5c|00)/i.test(rawPath)) {
      penalize(ctx, 3);
      return fail(req, res, 400);
    }
    let path;
    try {
      path = decodeURIComponent(rawPath);
    } catch {
      penalize(ctx, 2);
      return fail(req, res, 400);
    }
    if (path.includes('\0') || path.includes('\\') || path.includes('//') || /(?:^|\/)\.{1,2}(?:\/|$)/.test(path)) {
      penalize(ctx, 3);
      return fail(req, res, 400);
    }
    ctx.path = path.startsWith('/dl/') ? '/dl/…' : path.slice(0, 200);

    if (TRAPS.some((pattern) => pattern.test(path))) {
      penalize(ctx, Math.ceil(L.banThreshold / 2) + 1);
      return fail(req, res, 404);
    }

    // Only the download form sends a body.
    if (req.method !== 'POST' && (Number(req.headers['content-length']) > 0 || req.headers['transfer-encoding'])) {
      return fail(req, res, 400, { headers: { Connection: 'close' } });
    }

    const asset = req.method === 'POST' ? null : state.site.statics.get(path);
    if (asset) {
      if (!ctx.local) {
        const limit = assetRate.take(ctx.key);
        if (!limit.ok) {
          penalize(ctx, 1);
          return fail(req, res, 429, { retryAfter: limit.retryAfter });
        }
        if (!traffic.allows(ctx.key)) return trafficExhausted(req, res);
      }
      const bytes = sendEntry(req, res, asset, { versioned: queryAt !== -1 && VERSIONED.test(url.slice(queryAt + 1)) });
      budget.add(bytes);
      if (!ctx.local) traffic.add(ctx.key, bytes);
      return;
    }

    const limit = ctx.local ? { ok: true } : pageRate.take(ctx.key);
    if (!limit.ok) {
      penalize(ctx, 1);
      return fail(req, res, 429, { retryAfter: limit.retryAfter });
    }
    if (path === '/login') return login(req, res, ctx, new URLSearchParams(queryAt === -1 ? '' : url.slice(queryAt + 1)));
    if (!OPEN_PATHS.has(path) && !admitted(req, res, ctx, path)) return;

    const page = state.pages.get(path);
    if (page) {
      if (req.method === 'POST') return fail(req, res, 405, { headers: { Allow: 'GET, HEAD' } });
      const bytes = sendEntry(req, res, page);
      budget.add(bytes);
      if (!ctx.local) traffic.add(ctx.key, bytes);
      return;
    }
    if (path === '/index.html') return redirect(req, res, 301, '/');
    if (path.length > 1 && path.endsWith('/') && state.pages.has(path.slice(0, -1))) {
      return redirect(req, res, 301, path.slice(0, -1));
    }
    if (path === '/checksums.txt' && req.method !== 'POST') return sendEntry(req, res, state.checksums);
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
      return redirect(req, res, 303, '/#download');
    }
    const token = LINK_PATH.exec(path)?.[1];
    if (token) {
      if (req.method === 'POST') return fail(req, res, 405, { headers: { Allow: 'GET, HEAD' } });
      return serveDownload(req, res, ctx, token);
    }
    if (path.startsWith('/dl/')) {
      penalize(ctx, 3);
      return fail(req, res, 404, { title: 'Link ungültig', message: 'Dieser Download-Link ist ungültig. Lade Wortschatz über die Website.' });
    }
    penalize(ctx, 1);
    return fail(req, res, 404);
  }

  async function handle(req, res) {
    const started = performance.now();
    const peer = normalizeIp(req.socket?.remoteAddress);
    const forwardedFor = req.headers['x-forwarded-for'];
    const ip = clientIp(req, trust);
    const ctx = {
      ip,
      key: ipKey(ip),
      // Only a request straight from this machine is exempt from the limits (health check,
      // local testing). Through a proxy, every client counts, also a private address.
      local: !forwardedFor && isLoopback(peer),
      shielded: isPrivate(ip),
      foreign: isForeign(req),
      path: '-',
      bytes: 0,
    };

    if (forwardedFor && peer === ip && isPrivate(peer)) {
      warnOnce('proxy', 'X-Forwarded-For von einem nicht vertrauten Proxy ignoriert, alle Besucher erscheinen gleich. Hinter Docker TRUST_PROXY=private setzen.');
    } else if (forwardedFor && peer !== ip && isPrivate(ip)) {
      warnOnce('proxy.private', `Besucher kommen über den Proxy mit privater Adresse an (${anonymizeIp(ip)}). Die Limits gelten dann für alle zusammen. Bei Docker die Ports nur über IPv4 freigeben oder IPv6 im Docker-Netz einschalten.`);
    }
    if (config.accessLog) {
      res.once('close', () => {
        log.info('request', {
          ip: anonymizeIp(ip),
          method: req.method,
          path: ctx.path,
          status: res.statusCode,
          ms: Math.round(performance.now() - started),
          ...(ctx.bytes ? { bytes: ctx.bytes } : {}),
        });
      });
    }
    for (const [name, value] of Object.entries(baseHeaders)) res.setHeader(name, value);
    try {
      await route(req, res, ctx);
    } catch (error) {
      log.error('handler', { message: error.message, stack: String(error.stack).split('\n').slice(1, 4).join(' | ') });
      if (!res.headersSent) fail(req, res, 500);
      else res.destroy();
    }
  }

  return {
    handle,
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
      await stats.flush();
    },
  };
}
