// End-to-end tests against a real server on a random port, including attacks.
// Requests carry X-Forwarded-For from 127.0.0.1 (a trusted proxy), so the server sees
// public test addresses (203.0.113.x) and applies every limit to them.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { after, before, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';
import { createApp } from '../lib/app.mjs';
import { loadConfig } from '../lib/config.mjs';
import { createHttpServer, listenOnSocket } from '../lib/http.mjs';
import { createLogger } from '../lib/log.mjs';

const PUBLIC_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'public');
const HOST = 'wortschatz.test';
const ORIGIN = `https://${HOST}`;

let ipCounter = 10;
const nextIp = () => {
  ipCounter += 1;
  return `203.0.${113 + Math.floor(ipCounter / 250)}.${(ipCounter % 250) + 1}`;
};

async function startServer(env = {}, { releases = true, macSize = 300_000, logger = createLogger('silent'), serverOptions = {} } = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'wortschatz-test-'));
  const releasesDir = path.join(root, 'releases');
  const dataDir = path.join(root, 'data');
  await fs.mkdir(releasesDir);
  const files = {};
  if (releases) {
    files.mac = crypto.randomBytes(macSize);
    files.windows = crypto.randomBytes(120_000);
    await fs.writeFile(path.join(releasesDir, 'Wortschatz-1.0-macOS.dmg'), files.mac);
    await fs.writeFile(path.join(releasesDir, 'Wortschatz-1.0-Windows.exe'), files.windows);
    await fs.writeFile(
      path.join(releasesDir, 'mac.json'),
      JSON.stringify({ file: 'Wortschatz-1.0-macOS.dmg', version: '1.0', build: '1', released: '2026-10-14', requirement: 'macOS 26 oder neuer', architecture: 'Apple Silicon' }),
    );
    await fs.writeFile(
      path.join(releasesDir, 'windows.json'),
      JSON.stringify({ file: 'Wortschatz-1.0-Windows.exe', version: '1.0', released: '2026-10-14', requirement: 'Windows 10 oder 11', architecture: '64 Bit (x64)' }),
    );
  }
  const config = loadConfig({
    SITE_ORIGIN: ORIGIN,
    PUBLIC_DIR,
    RELEASES_DIR: releasesDir,
    DATA_DIR: dataDir,
    TRUST_PROXY: 'loopback',
    ACCESS_LOG: '0',
    ...env,
  });
  const app = await createApp(config, logger);
  const server = createHttpServer(app.handle, serverOptions);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  return {
    port,
    files,
    app,
    server,
    releasesDir,
    async close() {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      await app.close();
      await fs.rm(root, { recursive: true, force: true });
    },
  };
}

function request(port, method, target, { headers = {}, body, ip } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: '127.0.0.1',
        port,
        method,
        path: target,
        headers: { Host: HOST, ...(ip ? { 'X-Forwarded-For': ip } : {}), ...headers },
      },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
      },
    );
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

const FORM = { 'Content-Type': 'application/x-www-form-urlencoded', Origin: ORIGIN, 'Sec-Fetch-Site': 'same-origin' };

async function link(port, ip, platform = 'mac', extra = {}) {
  const res = await request(port, 'POST', `/download/${platform}`, { ip, headers: { ...FORM, ...extra }, body: 'website=' });
  return res;
}

const sha = (buffer) => crypto.createHash('sha256').update(buffer).digest('hex');

describe('website', () => {
  let s;
  before(async () => {
    s = await startServer();
  });
  after(() => s.close());

  it('serves the home page with the release data and security headers', async () => {
    const res = await request(s.port, 'GET', '/', { ip: nextIp() });
    assert.equal(res.status, 200);
    const html = res.body.toString();
    assert.match(html, /Wortschatz-1\.0-macOS\.dmg|Für macOS laden/);
    assert.ok(html.includes(sha(s.files.mac)), 'checksum on the page');
    assert.match(html, /300 KB/);
    const csp = res.headers['content-security-policy'];
    assert.match(csp, /default-src 'none'/);
    assert.match(csp, /script-src 'self'/);
    assert.match(csp, /frame-ancestors 'none'/);
    assert.equal(res.headers['x-content-type-options'], 'nosniff');
    assert.equal(res.headers['x-frame-options'], 'DENY');
    assert.match(res.headers['strict-transport-security'], /max-age=63072000/);
    assert.equal(res.headers['referrer-policy'], 'same-origin');
    assert.equal(res.headers['cross-origin-opener-policy'], 'same-origin');
    assert.equal(res.headers['x-powered-by'], undefined);
    assert.equal(res.headers['cache-control'], 'no-cache');
  });

  it('has no inline scripts or styles (the CSP would block them)', async () => {
    for (const page of ['/', '/datenschutz', '/neuigkeiten', '/en', '/en/privacy', '/en/whats-new', '/gibt-es-nicht']) {
      const html = (await request(s.port, 'GET', page, { ip: nextIp() })).body.toString();
      assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/i, `${page}: inline script`);
      assert.doesNotMatch(html, /<style\b/i, `${page}: style element`);
      assert.doesNotMatch(html, /\sstyle="/i, `${page}: style attribute`);
      assert.doesNotMatch(html, /\son[a-z]+="/i, `${page}: event handler attribute`);
    }
  });

  it('caches versioned assets forever and answers revalidation with 304', async () => {
    const html = (await request(s.port, 'GET', '/', { ip: nextIp() })).body.toString();
    const css = html.match(/\/assets\/css\/site\.css\?v=[0-9a-f]{10}/)[0];
    const res = await request(s.port, 'GET', css, { ip: nextIp(), headers: { 'Accept-Encoding': 'br, gzip' } });
    assert.equal(res.status, 200);
    assert.equal(res.headers['content-encoding'], 'br');
    assert.match(res.headers['cache-control'], /immutable/);
    const again = await request(s.port, 'GET', css, { ip: nextIp(), headers: { 'Accept-Encoding': 'br', 'If-None-Match': res.headers.etag } });
    assert.equal(again.status, 304);
    assert.equal(again.body.length, 0);
    const wrong = await request(s.port, 'GET', '/assets/css/site.css?v=0000000000', { ip: nextIp() });
    assert.equal(wrong.status, 200);
    assert.doesNotMatch(wrong.headers['cache-control'], /immutable/, 'only its own version is cached forever');
  });

  it('versions the asset urls inside the stylesheet', async () => {
    const html = (await request(s.port, 'GET', '/', { ip: nextIp() })).body.toString();
    const css = html.match(/\/assets\/css\/site\.css\?v=[0-9a-f]{10}/)[0];
    const body = (await request(s.port, 'GET', css, { ip: nextIp() })).body.toString();
    assert.match(body, /url\(\/assets\/img\/noise\.png\?v=[0-9a-f]{10}\)/);
  });

  it('never serves files outside the public folder', async () => {
    const attempts = [
      '/../server/server.mjs',
      '/%2e%2e/%2e%2e/etc/passwd',
      '/assets/..%2f..%2fserver%2flib%2fapp.mjs',
      '/assets/%2e%2e/%2e%2e/server/lib/config.mjs',
      '/assets//css/site.css',
      '/assets/css/site.css%00.txt',
      '/assets%2Fcss%2Fsite.css',
      '/assets%5Ccss%5Csite.css',
      '/assets\\..\\..\\server\\server.mjs',
      '/_partials/head.html',
      '/index',
      '/_error',
      '/%E0%A4%A',
    ];
    for (const target of attempts) {
      const res = await request(s.port, 'GET', target, { ip: nextIp() });
      assert.ok([400, 404].includes(res.status), `${target} → ${res.status}`);
      const text = res.body.toString();
      assert.doesNotMatch(text, /createApp|import http|root:x:0|\{\{/, `${target} leaked something`);
    }
  });

  it('refuses other methods, hosts and absolute urls', async () => {
    assert.equal((await request(s.port, 'PUT', '/', { ip: nextIp() })).status, 405);
    assert.equal((await request(s.port, 'DELETE', '/', { ip: nextIp() })).status, 405);
    assert.equal((await request(s.port, 'GET', '/', { ip: nextIp(), headers: { Host: 'evil.example' } })).status, 421);
    assert.equal((await request(s.port, 'GET', 'http://evil.example/', { ip: nextIp() })).status, 400);
    assert.equal((await request(s.port, 'GET', `/${'a'.repeat(3000)}`, { ip: nextIp() })).status, 414);
    assert.equal((await request(s.port, 'POST', '/', { ip: nextIp(), headers: FORM, body: 'x' })).status, 405);
  });

  it('serves checksums.txt, robots.txt and a health check', async () => {
    const sums = (await request(s.port, 'GET', '/checksums.txt', { ip: nextIp() })).body.toString();
    assert.ok(sums.includes(`${sha(s.files.mac)}  Wortschatz-1.0-macOS.dmg`));
    assert.ok(sums.includes(`${sha(s.files.windows)}  Wortschatz-1.0-Windows.exe`));
    assert.match((await request(s.port, 'GET', '/robots.txt', { ip: nextIp() })).body.toString(), /Disallow: \/dl\//);
    assert.equal((await request(s.port, 'GET', '/healthz', { ip: nextIp() })).body.toString(), 'ok\n');
  });

  it('shows the update list from public/_neuigkeiten.md, but never the file itself', async () => {
    const res = await request(s.port, 'GET', '/neuigkeiten', { ip: nextIp() });
    assert.equal(res.status, 200);
    const html = res.body.toString();
    assert.match(html, /<h1>Neuigkeiten<\/h1>/);
    assert.doesNotMatch(html, /\{\{|<!--/, 'no template tags or file comments');
    assert.match((await request(s.port, 'GET', '/', { ip: nextIp() })).body.toString(), /href="\/neuigkeiten"/);
    assert.equal((await request(s.port, 'GET', '/_neuigkeiten.md', { ip: nextIp() })).status, 404);
  });

  it('answers unknown pages with the 404 page', async () => {
    const res = await request(s.port, 'GET', '/gibt-es-nicht', { ip: nextIp() });
    assert.equal(res.status, 404);
    assert.match(res.body.toString(), /Seite nicht gefunden/);
  });

  it('serves every page in English below /en, each linked to the same page in German', async () => {
    const pairs = [
      ['/', '/en'],
      ['/neuigkeiten', '/en/whats-new'],
      ['/datenschutz', '/en/privacy'],
    ];
    for (const [de, en] of pairs) {
      const german = (await request(s.port, 'GET', de, { ip: nextIp() })).body.toString();
      const res = await request(s.port, 'GET', en, { ip: nextIp() });
      assert.equal(res.status, 200, en);
      const english = res.body.toString();
      assert.match(german, /<html lang="de-CH">/);
      assert.match(english, /<html lang="en">/);
      for (const html of [german, english]) {
        assert.ok(html.includes(`<link rel="alternate" hreflang="de" href="${ORIGIN}${de}">`), `${de}: German alternate`);
        assert.ok(html.includes(`<link rel="alternate" hreflang="en" href="${ORIGIN}${en}">`), `${en}: English alternate`);
        const script = html.search(/<script src="\/assets\/js\/lang\.js\?v=[0-9a-f]+"><\/script>/);
        assert.ok(script > 0 && script < html.indexOf('rel="stylesheet"'), 'lang.js, before the stylesheet (it would wait for it)');
        assert.doesNotMatch(html, /\{\{/, 'no template tags');
      }
      assert.ok(german.includes(`class="nav-lang" href="${en}" hreflang="en"`), `${de}: switch to English`);
      assert.ok(english.includes(`class="nav-lang" href="${de}" hreflang="de"`), `${en}: switch to German`);
    }
    const home = (await request(s.port, 'GET', '/en', { ip: nextIp() })).body.toString();
    assert.match(home, /Download for macOS/);
    assert.match(home, /The app is in German/);
    assert.match(home, /<dd>macOS 26 or later<\/dd>/, 'system requirement in English');
    assert.match(home, /<dd>64-bit \(x64\)<\/dd>/);
    assert.match(home, /<dd>14 October 2026<\/dd>/);
    assert.ok(home.includes(sha(s.files.mac)), 'same checksums');
    assert.doesNotMatch(home, /Für macOS laden|Erster Start|Prüfsumme/, 'no German outside the app window');
    assert.equal((await request(s.port, 'GET', '/en/', { ip: nextIp() })).headers.location, '/en');
  });

  it('shows the update list in English, with the German text where an entry has no English line', async () => {
    const html = (await request(s.port, 'GET', '/en/whats-new', { ip: nextIp() })).body.toString();
    assert.match(html, /<h1>What’s new<\/h1>/);
    assert.match(html, /Arabic and Mandarin as study languages/);
    assert.match(html, /class="change-kind change-kind-neu">New</);
    assert.doesNotMatch(html, /Arabisch und Mandarin/);
  });

  it('links to Ko-fi from the home page in both languages, and loads nothing from there', async () => {
    for (const page of ['/', '/en']) {
      const html = (await request(s.port, 'GET', page, { ip: nextIp() })).body.toString();
      assert.equal(html.match(/href="https:\/\/ko-fi\.com\/anthonybuilds13" target="_blank" rel="noopener"/g)?.length, 2, page);
      assert.doesNotMatch(html, /(?:src|srcset)="https?:/, `${page}: nothing from other servers`);
    }
  });

  it('answers errors in the language of the page, of the page before or of the browser', async () => {
    const ask = (target, headers = {}) => request(s.port, 'GET', target, { ip: nextIp(), headers });
    const plain = await ask('/gibt-es-nicht');
    assert.match(plain.body.toString(), /Seite nicht gefunden/, 'no header: German');
    assert.equal(plain.headers['content-language'], 'de');
    for (const [target, headers] of [
      ['/gibt-es-nicht', { 'Accept-Language': 'en-US,en;q=0.9,de;q=0.8' }],
      ['/gibt-es-nicht', { 'Accept-Language': 'ja' }],
      ['/en/gibt-es-nicht', { 'Accept-Language': 'de-CH' }],
      ['/gibt-es-nicht', { Referer: `http://${HOST}/en/whats-new`, 'Accept-Language': 'de' }],
    ]) {
      const res = await ask(target, headers);
      assert.equal(res.status, 404);
      assert.match(res.body.toString(), /Page not found/, JSON.stringify(headers));
      assert.match(res.body.toString(), /<html lang="en">/);
      assert.equal(res.headers['content-language'], 'en');
    }
    for (const headers of [{ 'Accept-Language': 'fr-CH,de;q=0.8,en;q=0.5' }, { Referer: 'https://evil.example/en/x' }]) {
      assert.match((await ask('/gibt-es-nicht', headers)).body.toString(), /Seite nicht gefunden/, JSON.stringify(headers));
    }
  });
});

describe('downloads', () => {
  let s;
  before(async () => {
    s = await startServer({ DOWNLOAD_LINK_USES: '3' });
  });
  after(() => s.close());

  it('delivers the file through a signed link (form post, 303)', async () => {
    const ip = nextIp();
    const res = await link(s.port, ip);
    assert.equal(res.status, 303);
    assert.match(res.headers.location, /^\/dl\/[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}$/);
    assert.equal(res.headers['cache-control'], 'no-store');
    const file = await request(s.port, 'GET', res.headers.location, { ip });
    assert.equal(file.status, 200);
    assert.equal(file.headers['content-type'], 'application/x-apple-diskimage');
    assert.equal(file.headers['content-disposition'], 'attachment; filename="Wortschatz-1.0-macOS.dmg"');
    assert.equal(Number(file.headers['content-length']), s.files.mac.length);
    assert.equal(sha(file.body), sha(s.files.mac));
    assert.equal(file.headers['repr-digest'], `sha-256=:${crypto.createHash('sha256').update(s.files.mac).digest('base64')}:`);
  });

  it('answers the page script with JSON', async () => {
    const ip = nextIp();
    const res = await link(s.port, ip, 'windows', { Accept: 'application/json' });
    assert.equal(res.status, 200);
    const data = JSON.parse(res.body);
    assert.equal(data.file, 'Wortschatz-1.0-Windows.exe');
    assert.equal(data.url.startsWith('/dl/'), true);
    assert.equal(data.size, s.files.windows.length);
    assert.equal(data.sha256, sha(s.files.windows));
    const file = await request(s.port, 'GET', data.url, { ip });
    assert.equal(file.headers['content-type'], 'application/vnd.microsoft.portable-executable');
    assert.equal(sha(file.body), sha(s.files.windows));
  });

  it('answers the page script in the language it asks for', async () => {
    const res = await link(s.port, nextIp(), 'mac', { Accept: 'application/json', 'Accept-Language': 'en', Origin: 'https://evil.example', 'Sec-Fetch-Site': 'cross-site' });
    assert.equal(res.status, 403);
    assert.deepEqual(JSON.parse(res.body), { error: 403, title: 'Download not possible', message: 'Please download Wortschatz directly from the website.' });
    const german = await link(s.port, nextIp(), 'mac', { Accept: 'application/json', Origin: 'https://evil.example', 'Sec-Fetch-Site': 'cross-site' });
    assert.equal(JSON.parse(german.body).title, 'Download nicht möglich');
  });

  it('refuses link requests from other websites and from scripts without browser headers', async () => {
    const ip = nextIp();
    const base = { 'Content-Type': 'application/x-www-form-urlencoded' };
    const cases = [
      { ...base },
      { ...base, Origin: 'https://evil.example' },
      { ...base, Origin: ORIGIN, 'Sec-Fetch-Site': 'cross-site' },
      { ...base, 'Sec-Fetch-Site': 'same-site' },
      { ...base, Origin: 'null' },
    ];
    for (const headers of cases) {
      const res = await request(s.port, 'POST', '/download/mac', { ip: nextIp(), headers, body: '' });
      assert.equal(res.status, 403, JSON.stringify(headers));
    }
    assert.equal((await request(s.port, 'GET', '/download/mac', { ip })).status, 303, 'a plain GET leads to the page');
  });

  it('rejects forged, changed and foreign links', async () => {
    const ip = nextIp();
    const location = (await link(s.port, ip)).headers.location;
    const [body, mac] = location.slice(4).split('.');
    const payload = JSON.parse(Buffer.from(body, 'base64url'));
    payload.p = 'windows';
    const forged = `/dl/${Buffer.from(JSON.stringify(payload)).toString('base64url')}.${mac}`;
    assert.equal((await request(s.port, 'GET', forged, { ip })).status, 404);
    assert.equal((await request(s.port, 'GET', `/dl/${body}.${'A'.repeat(43)}`, { ip })).status, 404);
    assert.equal((await request(s.port, 'GET', '/dl/nonsense', { ip })).status, 404);
    // The genuine link from another address (another device) is refused.
    assert.equal((await request(s.port, 'GET', location, { ip: '198.51.100.99' })).status, 403);
  });

  it('limits how often one link works, but HEAD does not count', async () => {
    const ip = nextIp();
    const location = (await link(s.port, ip)).headers.location;
    const head = await request(s.port, 'HEAD', location, { ip });
    assert.equal(head.status, 200);
    assert.equal(head.body.length, 0);
    for (let i = 0; i < 3; i += 1) assert.equal((await request(s.port, 'GET', location, { ip })).status, 200);
    assert.equal((await request(s.port, 'GET', location, { ip })).status, 410);
  });

  it('supports resuming with byte ranges', async () => {
    const ip = nextIp();
    const location = (await link(s.port, ip)).headers.location;
    const part = await request(s.port, 'GET', location, { ip, headers: { Range: 'bytes=1000-1999' } });
    assert.equal(part.status, 206);
    assert.equal(part.headers['content-range'], `bytes 1000-1999/${s.files.mac.length}`);
    assert.deepEqual(part.body, s.files.mac.subarray(1000, 2000));
    const bad = await request(s.port, 'GET', location, { ip, headers: { Range: `bytes=${s.files.mac.length}-` } });
    assert.equal(bad.status, 416);
  });

  it('gives no link to bots that fill in the hidden field, and blocks nobody for it', async () => {
    const ip = nextIp();
    const res = await request(s.port, 'POST', '/download/mac', { ip, headers: FORM, body: 'website=http%3A%2F%2Fspam.example' });
    assert.equal(res.status, 403);
    assert.equal(res.headers.location, undefined);
    assert.equal((await request(s.port, 'GET', '/', { ip })).status, 200, 'others at the same address go on');
  });

  it('counts a link use at once, so that requests arriving together cannot share one', async () => {
    const ip = nextIp();
    const location = (await link(s.port, ip)).headers.location;
    const statuses = (await Promise.all(Array.from({ length: 6 }, () => request(s.port, 'GET', location, { ip })))).map((res) => res.status);
    assert.deepEqual(statuses.sort(), [200, 200, 200, 410, 410, 410]);
  });

  it('counts a download only when the whole file has gone out', async () => {
    const ip = nextIp();
    const mac = () => s.app.stats.snapshot()[Object.keys(s.app.stats.snapshot()).sort().at(-1)]?.windows ?? 0;
    const before = mac();
    const location = (await link(s.port, ip, 'windows')).headers.location;
    assert.equal((await request(s.port, 'GET', location, { ip, headers: { Range: 'bytes=-1' } })).status, 206);
    assert.equal(mac(), before, 'the last byte alone is no download');
    assert.equal((await request(s.port, 'GET', location, { ip })).status, 200);
    assert.equal(mac(), before + 1);
    assert.equal((await request(s.port, 'GET', location, { ip })).status, 200);
    assert.equal(mac(), before + 1, 'one link counts once');
  });

  it('does not hold a slot for a client that is already gone', async () => {
    const ip = nextIp();
    for (let i = 0; i < 20; i += 1) {
      const location = (await link(s.port, ip)).headers.location;
      await new Promise((resolve) => {
        const socket = net.connect(s.port, '127.0.0.1');
        socket.on('error', () => {});
        socket.on('close', resolve);
        // The request and the end of the connection arrive together.
        socket.end(`GET ${location} HTTP/1.1\r\nHost: ${HOST}\r\nX-Forwarded-For: ${ip}\r\n\r\n`);
        socket.resume();
      });
    }
    const started = Date.now();
    while (s.app.activeDownloads > 0) {
      assert.ok(Date.now() - started < 10_000, `${s.app.activeDownloads} slots still held`);
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  });

  it('rejects oversized and unexpected bodies', async () => {
    const big = await request(s.port, 'POST', '/download/mac', { ip: nextIp(), headers: FORM, body: `website=&x=${'a'.repeat(5000)}` });
    assert.equal(big.status, 413);
    const json = await request(s.port, 'POST', '/download/mac', {
      ip: nextIp(),
      headers: { ...FORM, 'Content-Type': 'application/json' },
      body: '{}',
    });
    assert.equal(json.status, 415);
    const getBody = await request(s.port, 'GET', '/', { ip: nextIp(), headers: { 'Content-Length': '5' }, body: 'hello' });
    assert.equal(getBody.status, 400);
  });
});

describe('limits', () => {
  let s;
  before(async () => {
    s = await startServer({
      RATE_REQUEST_BURST: '6',
      RATE_REQUESTS_PER_SECOND: '0.02',
      DOWNLOAD_LINK_SECONDS: '10',
      CONCURRENT_DOWNLOADS_PER_IP: '1',
      BANDWIDTH_PER_DOWNLOAD_MBIT: '0.5',
    });
  });
  after(() => s.close());

  it('limits requests per address, whatever they ask for, with one short line', async () => {
    for (const target of ['/datenschutz', '/assets/img/og.png', '/gibt-es-nicht', '/a%2fb', '/.env']) {
      const ip = nextIp();
      const answers = [];
      for (let i = 0; i < 8; i += 1) answers.push(await request(s.port, 'GET', target, { ip }));
      assert.equal(answers[5].status === 429, false, `${target}: within the burst`);
      const last = answers[7];
      assert.equal(last.status, 429, target);
      assert.ok(Number(last.headers['retry-after']) > 0, target);
      assert.ok(last.body.length < 80, `${target}: ${last.body.length} bytes`);
      assert.equal(last.headers['content-security-policy'], undefined, 'plain text needs none of the page headers');
    }
    const other = await request(s.port, 'GET', '/datenschutz', { ip: nextIp() });
    assert.equal(other.status, 200, 'other addresses are not affected');
  });

  it('counts refusals too: wrong methods, hosts and long addresses', async () => {
    const attempts = [
      (ip) => request(s.port, 'PUT', '/', { ip }),
      (ip) => request(s.port, 'GET', '/', { ip, headers: { Host: 'evil.example' } }),
      (ip) => request(s.port, 'GET', `/${'a'.repeat(3000)}`, { ip }),
      (ip) => request(s.port, 'GET', 'http://evil.example/', { ip }),
    ];
    for (const attempt of attempts) {
      const ip = nextIp();
      let last;
      for (let i = 0; i < 8; i += 1) last = await attempt(ip);
      assert.equal(last.status, 429);
    }
  });

  it('blocks nobody for asking for odd things: others at the same address go on', async () => {
    const ip = nextIp();
    assert.equal((await request(s.port, 'GET', '/.env', { ip })).status, 404);
    assert.equal((await request(s.port, 'GET', '/wp-login.php', { ip })).status, 404);
    assert.equal((await request(s.port, 'GET', '/dl/nonsense', { ip })).status, 404);
    assert.equal((await request(s.port, 'GET', '/', { ip })).status, 200);
  });

  it('allows one download at a time per address when configured so', async () => {
    const ip = nextIp();
    const first = (await link(s.port, ip)).headers.location;
    const slow = request(s.port, 'GET', first, { ip });
    while (s.app.activeDownloads === 0) await new Promise((resolve) => setTimeout(resolve, 10));
    const ip2 = nextIp();
    const second = (await link(s.port, ip2)).headers.location;
    // Same address as the running download: refused for now, already on the page.
    const busy = await link(s.port, ip, 'mac', { Accept: 'application/json' });
    assert.equal(busy.status, 503);
    assert.equal(JSON.parse(busy.body).title, 'Gerade viel los');
    assert.ok(Number(busy.headers['retry-after']) > 0);
    // Another address still gets its file.
    assert.equal((await request(s.port, 'GET', second, { ip: ip2, headers: { Range: 'bytes=0-99' } })).status, 206);
    const done = await slow;
    assert.equal(done.status, 200);
    assert.equal(sha(done.body), sha(s.files.mac));
  });

  it('expires links', async () => {
    const ip = nextIp();
    const location = (await link(s.port, ip)).headers.location;
    const [body, mac] = location.slice(4).split('.');
    const payload = JSON.parse(Buffer.from(body, 'base64url'));
    assert.ok(payload.x - Date.now() / 1000 <= 10);
    assert.ok(mac);
    await new Promise((resolve) => setTimeout(resolve, 10_500));
    const res = await request(s.port, 'GET', location, { ip });
    assert.equal(res.status, 410);
    assert.match(res.body.toString(), /abgelaufen/);
  });
});

describe('without releases', () => {
  let s;
  before(async () => {
    s = await startServer({}, { releases: false });
  });
  after(() => s.close());

  it('shows that the versions are coming and refuses links', async () => {
    const html = (await request(s.port, 'GET', '/', { ip: nextIp() })).body.toString();
    assert.match(html, /macOS-Version folgt/);
    assert.match(html, /Windows-Version folgt/);
    const res = await link(s.port, nextIp(), 'mac', { Accept: 'application/json' });
    assert.equal(res.status, 404);
    assert.equal(JSON.parse(res.body).title, 'Noch nicht verfügbar');
  });

  it('picks up a new release after a reload', async () => {
    await fs.writeFile(path.join(s.releasesDir, 'Wortschatz-2.0-macOS.dmg'), Buffer.from('neu'));
    await fs.writeFile(path.join(s.releasesDir, 'mac.json'), JSON.stringify({ file: 'Wortschatz-2.0-macOS.dmg', version: '2.0' }));
    await s.app.reload('test');
    const html = (await request(s.port, 'GET', '/', { ip: nextIp() })).body.toString();
    assert.match(html, /Version 2\.0/);
  });

  it('ignores manifests that point outside the folder', async () => {
    await fs.writeFile(path.join(s.releasesDir, 'windows.json'), JSON.stringify({ file: '../../etc/passwd', version: '1' }));
    await fs.symlink('/etc/hostname', path.join(s.releasesDir, 'evil.exe')).catch(() => {});
    await fs.writeFile(path.join(s.releasesDir, 'mac.json'), JSON.stringify({ file: 'evil.exe', version: '1' }));
    await s.app.reload('test');
    assert.equal(s.app.state.releases.windows, null);
    assert.equal(s.app.state.releases.mac, null);
  });
});

describe('downloads on GitHub', () => {
  const REPO = 'https://github.com/SuperStoked13/Wortschatz/releases/download';
  const MAC_SHA = 'a'.repeat(64);
  const WIN_SHA = 'b'.repeat(64);
  const macManifest = (extra = {}) => ({
    file: 'Wortschatz-1.6.2-macOS.dmg',
    version: '1.6.2',
    url: `${REPO}/v1.6.2-mac/Wortschatz-1.6.2-macOS.dmg`,
    size: 12_345_678,
    sha256: MAC_SHA,
    ...extra,
  });
  const windowsManifest = (extra = {}) => ({
    file: 'Wortschatz-1.5-Windows.exe',
    version: '1.5',
    url: `${REPO}/v1.5/Wortschatz-1.5-Windows.exe`,
    size: 92_000_000,
    sha256: WIN_SHA.toUpperCase(),
    ...extra,
  });
  const write = (s, name, manifest) => fs.writeFile(path.join(s.releasesDir, name), JSON.stringify(manifest));

  let s;
  before(async () => {
    s = await startServer({}, { releases: false });
    await write(s, 'mac.json', macManifest());
    await write(s, 'windows.json', windowsManifest());
    await s.app.reload('test');
  });
  after(() => s.close());

  it('links straight to the files on GitHub, in both languages, without forms', async () => {
    for (const page of ['/', '/en']) {
      const html = (await request(s.port, 'GET', page, { ip: nextIp() })).body.toString();
      assert.equal((html.match(new RegExp(`href="${REPO}/v1\\.5/Wortschatz-1\\.5-Windows\\.exe"`, 'g')) || []).length, 2, page);
      assert.equal((html.match(new RegExp(`href="${REPO}/v1\\.6\\.2-mac/Wortschatz-1\\.6\\.2-macOS\\.dmg"`, 'g')) || []).length, 2, page);
      assert.doesNotMatch(html, /action="\/download\//, page);
      assert.match(html, /data-size="92000000"/, page);
      assert.match(html, new RegExp(WIN_SHA), page);
      assert.match(html, /92,0 MB|92\.0 MB/, page);
    }
  });

  it('lists the checksums from the manifests', async () => {
    const res = await request(s.port, 'GET', '/checksums.txt', { ip: nextIp() });
    assert.equal(res.status, 200);
    assert.match(res.body.toString(), new RegExp(`${MAC_SHA}  Wortschatz-1\\.6\\.2-macOS\\.dmg`));
    assert.match(res.body.toString(), new RegExp(`${WIN_SHA}  Wortschatz-1\\.5-Windows\\.exe`));
  });

  it('asks a page from before the switch to reload instead of sending a file', async () => {
    const de = await link(s.port, nextIp(), 'windows', { Accept: 'application/json' });
    assert.equal(de.status, 410);
    assert.equal(JSON.parse(de.body).title, 'Seite neu laden');
    assert.match(JSON.parse(de.body).message, /GitHub/);
    const en = await link(s.port, nextIp(), 'mac', { Accept: 'application/json', 'Accept-Language': 'en' });
    assert.equal(en.status, 410);
    assert.equal(JSON.parse(en.body).title, 'Reload the page');
    const page = await link(s.port, nextIp(), 'mac');
    assert.equal(page.status, 410);
    assert.match(page.body.toString(), /Seite neu laden/);
  });

  it('tells the privacy page that downloads come from GitHub', async () => {
    const de = (await request(s.port, 'GET', '/datenschutz', { ip: nextIp() })).body.toString();
    assert.match(de, /Die Apps liegen auf GitHub/);
    assert.doesNotMatch(de, /zählt der Server, wie oft/);
    const en = (await request(s.port, 'GET', '/en/privacy', { ip: nextIp() })).body.toString();
    assert.match(en, /The apps are hosted on GitHub/);
    assert.doesNotMatch(en, /the server counts how often/);
  });

  it('says that the Mac app asks GitHub for updates once a version after 1.7.1 is live', async () => {
    const pages = async () => {
      const get = async (page) => (await request(s.port, 'GET', page, { ip: nextIp() })).body.toString();
      return { de: await get('/datenschutz'), en: await get('/en/privacy'), help: await get('/'), helpEn: await get('/en') };
    };
    const before = await pages();
    assert.match(before.de, /Wortschatz selbst sendet keine Daten\./);
    assert.doesNotMatch(before.de, /nach Updates zu fragen/);
    assert.doesNotMatch(before.en, /to check for updates/);
    assert.match(before.help, /braucht keinen Internetzugang\./);
    assert.match(before.helpEn, /doesn’t need internet access\./);

    await write(s, 'mac.json', macManifest({ version: '1.8', file: 'Wortschatz-1.8-macOS.dmg', url: `${REPO}/v1.8-mac/Wortschatz-1.8-macOS.dmg` }));
    await s.app.reload('test');
    try {
      const after = await pages();
      assert.match(after.de, /Ins Internet geht nur die Mac-App, um nach Updates zu fragen/);
      assert.match(after.de, /«Automatisch aktualisieren»/);
      assert.doesNotMatch(after.de, /Wortschatz selbst sendet keine Daten\./);
      assert.match(after.en, /Only the Mac app goes online, to check for updates/);
      assert.match(after.help, /um bei GitHub nach neuen Versionen zu fragen/);
      assert.doesNotMatch(after.help, /braucht keinen Internetzugang/);
      assert.match(after.helpEn, /to ask GitHub for new versions/);
      for (const html of Object.values(after)) assert.doesNotMatch(html, /\{\{/);
    } finally {
      await write(s, 'mac.json', macManifest());
      await s.app.reload('test');
    }
  });

  it('says that the Windows app asks GitHub for updates once a version after 1.7.1 is live, and names both apps when both do', async () => {
    const pages = async () => {
      const get = async (page) => (await request(s.port, 'GET', page, { ip: nextIp() })).body.toString();
      return { de: await get('/datenschutz'), en: await get('/en/privacy'), help: await get('/'), helpEn: await get('/en') };
    };
    const windows18 = windowsManifest({ version: '1.8', file: 'Wortschatz-1.8-Windows.exe', url: `${REPO}/v1.8-windows/Wortschatz-1.8-Windows.exe` });
    const before = await pages();
    assert.doesNotMatch(before.help, /Neue Versionen holt Wortschatz selbst/);
    assert.doesNotMatch(before.helpEn, /gets new versions by itself/);

    await write(s, 'windows.json', windows18);
    await s.app.reload('test');
    try {
      const windowsOnly = await pages();
      assert.match(windowsOnly.de, /Ins Internet geht nur die Windows-App, um nach Updates zu fragen/);
      assert.match(windowsOnly.de, /Internetadresse deines Computers und welche Version von Wortschatz er hat,/);
      assert.match(windowsOnly.de, /«Automatisch aktualisieren»/);
      assert.doesNotMatch(windowsOnly.de, /Wortschatz selbst sendet keine Daten\./);
      assert.doesNotMatch(windowsOnly.de, /Mac-App, um nach Updates/);
      assert.match(windowsOnly.en, /Only the Windows app goes online, to check for updates/);
      assert.match(windowsOnly.help, /Neue Versionen holt Wortschatz selbst/);
      assert.match(windowsOnly.help, /braucht keinen Internetzugang\./);
      assert.match(windowsOnly.helpEn, /gets new versions by itself/);

      await write(s, 'mac.json', macManifest({ version: '1.8', file: 'Wortschatz-1.8-macOS.dmg', url: `${REPO}/v1.8-mac/Wortschatz-1.8-macOS.dmg` }));
      await s.app.reload('test');
      const both = await pages();
      assert.match(both.de, /Ins Internet gehen die Apps nur, um nach Updates zu fragen/);
      assert.match(both.de, /\(beim Mac auch von macOS\)/);
      assert.doesNotMatch(both.de, /geht nur die (Mac|Windows)-App/);
      assert.match(both.en, /The apps only go online to check for updates/);
      assert.match(both.en, /“Update Automatically”/);
      assert.match(both.help, /um bei GitHub nach neuen Versionen zu fragen/);
      assert.match(both.help, /Neue Versionen holt Wortschatz selbst/);
      for (const html of [...Object.values(windowsOnly), ...Object.values(both)]) assert.doesNotMatch(html, /\{\{/);
    } finally {
      await write(s, 'mac.json', macManifest());
      await write(s, 'windows.json', windowsManifest());
      await s.app.reload('test');
    }
  });

  it('accepts only release files of DOWNLOAD_REPO on GitHub, complete with size and checksum', async () => {
    // The address itself is checked in detail in units.test.mjs (githubReleaseUrl).
    const bad = [
      windowsManifest({ url: `${REPO.replace('SuperStoked13', 'someone-else')}/v1.5/Wortschatz-1.5-Windows.exe` }),
      windowsManifest({ url: 'javascript:alert(1)//Wortschatz-1.5-Windows.exe' }),
      windowsManifest({ url: null }),
      windowsManifest({ sha256: 'xyz' }),
      windowsManifest({ sha256: undefined }),
      windowsManifest({ size: '92000000' }),
    ];
    for (const manifest of bad) {
      await write(s, 'windows.json', manifest);
      await s.app.reload('test');
      assert.equal(s.app.state.releases.windows, null, JSON.stringify(manifest));
      const html = (await request(s.port, 'GET', '/', { ip: nextIp() })).body.toString();
      assert.match(html, /Windows-Version folgt/);
    }
    await write(s, 'windows.json', windowsManifest());
    await s.app.reload('test');
    assert.equal(s.app.state.releases.windows.url, `${REPO}/v1.5/Wortschatz-1.5-Windows.exe`);
  });

  it('follows DOWNLOAD_REPO', async () => {
    const other = await startServer({ DOWNLOAD_REPO: 'example/wortschatz-fork' }, { releases: false });
    try {
      await write(other, 'windows.json', windowsManifest());
      await write(other, 'mac.json', macManifest({ url: 'https://github.com/example/wortschatz-fork/releases/download/v2/Wortschatz-1.6.2-macOS.dmg' }));
      await other.app.reload('test');
      assert.equal(other.app.state.releases.windows, null);
      assert.equal(other.app.state.releases.mac.url, 'https://github.com/example/wortschatz-fork/releases/download/v2/Wortschatz-1.6.2-macOS.dmg');
    } finally {
      await other.close();
    }
  });
});

describe('moving the downloads to GitHub', () => {
  let s;
  before(async () => {
    s = await startServer();
  });
  after(() => s.close());

  it('answers a link from before the move without touching the file', async () => {
    const ip = nextIp();
    const issued = await link(s.port, ip, 'mac', { Accept: 'application/json' });
    assert.equal(issued.status, 200);
    const { url } = JSON.parse(issued.body);
    await fs.writeFile(
      path.join(s.releasesDir, 'mac.json'),
      JSON.stringify({
        file: 'Wortschatz-1.0-macOS.dmg',
        version: '1.0',
        url: 'https://github.com/SuperStoked13/Wortschatz/releases/download/v1.0/Wortschatz-1.0-macOS.dmg',
        size: s.files.mac.length,
        sha256: sha(s.files.mac),
      }),
    );
    await s.app.reload('test');
    for (const method of ['GET', 'HEAD']) {
      const res = await request(s.port, method, url, { ip });
      assert.equal(res.status, 410, method);
      assert.notEqual(res.headers['content-type'], 'application/x-apple-diskimage');
      assert.ok(res.body.length < 50_000);
    }
  });

  it('keeps the other platform on this server, and the privacy page names both', async () => {
    const html = (await request(s.port, 'GET', '/', { ip: nextIp() })).body.toString();
    assert.match(html, /href="https:\/\/github\.com\/SuperStoked13\/Wortschatz\/releases\/download\/v1\.0\/Wortschatz-1\.0-macOS\.dmg"/);
    assert.match(html, /action="\/download\/windows"/);
    assert.doesNotMatch(html, /action="\/download\/mac"/);
    const windows = await link(s.port, nextIp(), 'windows', { Accept: 'application/json' });
    assert.equal(windows.status, 200);
    const privacy = (await request(s.port, 'GET', '/datenschutz', { ip: nextIp() })).body.toString();
    assert.match(privacy, /Die Apps liegen auf GitHub/);
    assert.match(privacy, /zählt der Server, wie oft/);
  });
});

/** A socket file as a crash leaves it: a process that listened on it and then died without closing. */
function leaveStaleSocket(file) {
  execFileSync(process.execPath, ['-e', "require('net').createServer().listen(process.argv[1], () => process.exit(0))", file]);
}

function socketRequest(socketPath, method, target, { headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ socketPath, method, path: target, headers: { Host: HOST, ...headers } }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
    req.end();
  });
}

describe('behind a Unix socket (container without network)', () => {
  let s;
  let proxied;
  let socketPath;
  before(async () => {
    s = await startServer({ TRUST_PROXY: 'private', RATE_REQUEST_BURST: '5', RATE_REQUESTS_PER_SECOND: '0.01' });
    socketPath = path.join(await fs.mkdtemp(path.join(os.tmpdir(), 'wortschatz-sock-')), 'web.sock');
    proxied = createHttpServer(s.app.handleProxied);
    await listenOnSocket(proxied, socketPath);
  });
  after(async () => {
    proxied.closeAllConnections();
    await new Promise((resolve) => proxied.close(resolve));
    await s.close();
  });

  it('serves the pages, and only owner and group may connect', async () => {
    const res = await socketRequest(socketPath, 'GET', '/', { headers: { 'X-Forwarded-For': nextIp() } });
    assert.equal(res.status, 200);
    assert.match(res.body.toString(), /Wortschatz/);
    assert.equal((await fs.stat(socketPath)).mode & 0o777, 0o660);
  });

  it('counts every visitor by the address the proxy names', async () => {
    const visitor = nextIp();
    const statuses = [];
    for (let i = 0; i < 7; i += 1) statuses.push((await socketRequest(socketPath, 'GET', '/healthz', { headers: { 'X-Forwarded-For': visitor } })).status);
    assert.deepEqual(statuses.slice(0, 5), [200, 200, 200, 200, 200]);
    assert.equal(statuses.at(-1), 429);
    // Another visitor is not affected, and a made-up address further left changes nothing.
    assert.equal((await socketRequest(socketPath, 'GET', '/healthz', { headers: { 'X-Forwarded-For': nextIp() } })).status, 200);
    assert.equal((await socketRequest(socketPath, 'GET', '/healthz', { headers: { 'X-Forwarded-For': `${nextIp()}, ${visitor}` } })).status, 429);
  });

  it('never treats a request over the socket as local, also without the header', async () => {
    const statuses = [];
    for (let i = 0; i < 7; i += 1) statuses.push((await socketRequest(socketPath, 'GET', '/healthz')).status);
    assert.equal(statuses.at(-1), 429);
    // The health check inside the container (straight to HOST:PORT, no proxy) stays exempt.
    for (let i = 0; i < 7; i += 1) assert.equal((await request(s.port, 'GET', '/healthz')).status, 200);
  });

  it('never takes the socket away from a server that still listens on it', async () => {
    await assert.rejects(listenOnSocket(http.createServer(), socketPath), { code: 'EADDRINUSE' });
    assert.equal((await socketRequest(socketPath, 'GET', '/healthz', { headers: { 'X-Forwarded-For': nextIp() } })).status, 200);
  });

  it('warns once when the proxy sends no usable address', async () => {
    const lines = [];
    const stream = { write: (line) => { lines.push(String(line)); } };
    const quiet = await startServer({ TRUST_PROXY: 'private' }, { logger: createLogger('info', { stdout: stream, stderr: stream }) });
    const file = path.join(await fs.mkdtemp(path.join(os.tmpdir(), 'wortschatz-sock-')), 'web.sock');
    const proxy = createHttpServer(quiet.app.handleProxied);
    try {
      await listenOnSocket(proxy, file);
      await socketRequest(file, 'GET', '/healthz', { headers: { 'X-Forwarded-For': nextIp() } });
      assert.equal(lines.filter((line) => line.includes('proxy.socket')).length, 0);
      await socketRequest(file, 'GET', '/healthz');
      await socketRequest(file, 'GET', '/healthz', { headers: { 'X-Forwarded-For': 'kaputt' } });
      assert.equal(lines.filter((line) => line.includes('proxy.socket')).length, 1);
    } finally {
      proxy.closeAllConnections();
      await new Promise((resolve) => proxy.close(resolve));
      await quiet.close();
    }
  });

  it('replaces a socket left over, but nothing else', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'wortschatz-sock-'));
    const stale = path.join(dir, 'stale.sock');
    leaveStaleSocket(stale);
    assert.ok((await fs.lstat(stale)).isSocket());
    const second = http.createServer((req, res) => res.end('ok'));
    await listenOnSocket(second, stale);
    assert.equal((await socketRequest(stale, 'GET', '/')).body.toString(), 'ok');
    second.closeAllConnections();
    await new Promise((resolve) => second.close(resolve));
    await fs.writeFile(path.join(dir, 'kein-socket'), 'wichtig');
    const third = http.createServer();
    await assert.rejects(listenOnSocket(third, path.join(dir, 'kein-socket')), /kein Socket/);
    assert.equal(await fs.readFile(path.join(dir, 'kein-socket'), 'utf8'), 'wichtig');
    // Nor a link that points somewhere else, also to a socket.
    leaveStaleSocket(path.join(dir, 'anderer.sock'));
    await fs.symlink(path.join(dir, 'anderer.sock'), path.join(dir, 'link.sock'));
    await assert.rejects(listenOnSocket(http.createServer(), path.join(dir, 'link.sock')), /kein Socket/);
    assert.ok((await fs.lstat(path.join(dir, 'anderer.sock'))).isSocket());
    await fs.rm(dir, { recursive: true, force: true });
  });
});

describe('server.mjs with LISTEN_SOCKET', () => {
  it('listens on both, and removes the socket when it stops', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'wortschatz-proc-'));
    const socketPath = path.join(dir, 'web.sock');
    // A leftover from a crash: the server has to take its place.
    leaveStaleSocket(socketPath);
    const port = await new Promise((resolve) => {
      const probe = net.createServer().listen(0, '127.0.0.1', () => {
        const { port: free } = probe.address();
        probe.close(() => resolve(free));
      });
    });
    const child = spawn(process.execPath, [fileURLToPath(new URL('../server.mjs', import.meta.url))], {
      env: {
        PATH: process.env.PATH,
        SITE_ORIGIN: ORIGIN,
        PORT: String(port),
        LISTEN_SOCKET: socketPath,
        TRUST_PROXY: 'private',
        RELEASES_DIR: path.join(dir, 'releases'),
        DATA_DIR: path.join(dir, 'data'),
        LOG_LEVEL: 'error',
      },
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    let errors = '';
    child.stderr.on('data', (chunk) => {
      errors += chunk;
    });
    try {
      let res;
      for (let i = 0; i < 100 && !res; i += 1) {
        res = await socketRequest(socketPath, 'GET', '/healthz', { headers: { 'X-Forwarded-For': nextIp() } }).catch(() => null);
        if (!res) await new Promise((resolve) => setTimeout(resolve, 50));
      }
      assert.equal(res?.status, 200, errors);
      assert.equal((await request(port, 'GET', '/healthz')).status, 200);
    } finally {
      child.kill('SIGTERM');
      await once(child, 'exit');
    }
    await assert.rejects(fs.stat(socketPath), { code: 'ENOENT' });
    await fs.rm(dir, { recursive: true, force: true });
  });
});

describe('fair use and robustness', () => {
  let s;
  before(async () => {
    s = await startServer(
      {
        RATE_REQUEST_BURST: '8',
        RATE_REQUESTS_PER_SECOND: '0.02',
        DAILY_TRAFFIC_GB_PER_IP: '0.01',
        DAILY_TRAFFIC_SLOW_MBIT: '16',
        DOWNLOAD_MIN_KBPS: '64',
        DOWNLOAD_SLOW_GRACE_SECONDS: '1',
        BANDWIDTH_TOTAL_MBIT: '0',
      },
      { macSize: 8_000_000 },
    );
  });
  after(() => s.close());

  it('answers another website asking through a visitor\'s browser with one line, at no cost to the address', async () => {
    const ip = nextIp();
    const asks = [
      { 'Sec-Fetch-Site': 'cross-site', 'Sec-Fetch-Mode': 'no-cors', 'Sec-Fetch-Dest': 'image' },
      { 'Sec-Fetch-Site': 'cross-site', 'Sec-Fetch-Mode': 'cors', 'Sec-Fetch-Dest': 'empty' },
      { 'Sec-Fetch-Site': 'same-site', 'Sec-Fetch-Mode': 'no-cors', 'Sec-Fetch-Dest': 'script' },
      { 'Sec-Fetch-Site': 'cross-site', 'Sec-Fetch-Mode': 'navigate', 'Sec-Fetch-Dest': 'iframe' },
    ];
    for (let i = 0; i < 40; i += 1) {
      const res = await request(s.port, 'GET', '/assets/img/og.png', { ip, headers: asks[i % asks.length] });
      assert.equal(res.status, 403);
      assert.ok(res.body.length < 40);
    }
    assert.equal((await request(s.port, 'GET', '/', { ip })).status, 200, 'the limits of the address are untouched');
    const click = { 'Sec-Fetch-Site': 'cross-site', 'Sec-Fetch-Mode': 'navigate', 'Sec-Fetch-Dest': 'document' };
    assert.equal((await request(s.port, 'GET', '/', { ip: nextIp(), headers: click })).status, 200, 'a link from another website works');
    const own = { 'Sec-Fetch-Site': 'same-origin', 'Sec-Fetch-Mode': 'no-cors', 'Sec-Fetch-Dest': 'image' };
    assert.equal((await request(s.port, 'GET', '/assets/img/og.png', { ip: nextIp(), headers: own })).status, 200, 'its own pages load everything');
  });

  it('limits private addresses behind the proxy like any other', async () => {
    const ip = '10.20.30.40';
    const statuses = [];
    for (let i = 0; i < 10; i += 1) statuses.push((await request(s.port, 'GET', '/datenschutz', { ip })).status);
    assert.equal(statuses[9], 429);
  });

  it('slows an address down after its daily traffic, but never stops it', async () => {
    const ip = nextIp();
    const first = (await link(s.port, ip)).headers.location;
    const file = await request(s.port, 'GET', first, { ip });
    assert.equal(file.body.length, s.files.mac.length);
    const second = (await link(s.port, ip)).headers.location;
    assert.equal((await request(s.port, 'GET', second, { ip })).status, 200);
    // 16 of 10 MB: only the slow lane now, 2 MB/s here, so the 8 MB take seconds.
    const started = Date.now();
    const third = (await link(s.port, ip)).headers.location;
    const slow = await request(s.port, 'GET', third, { ip });
    assert.equal(slow.status, 200);
    assert.equal(slow.body.length, s.files.mac.length);
    assert.ok(Date.now() - started > 2500, `${Date.now() - started} ms`);
  });

  it('cuts off a download that does not move and frees the slot', async () => {
    const ip = nextIp();
    const location = (await link(s.port, ip)).headers.location;
    const started = Date.now();
    let response;
    // A fresh connection: a reused one may have grown buffers that swallow the whole file.
    const options = { host: '127.0.0.1', port: s.port, path: location, agent: false, headers: { Host: HOST, 'X-Forwarded-For': ip } };
    const req = http.get(options, (res) => {
      res.pause(); // the reader stops, so the server's writes stall
      response = res;
    });
    req.on('error', () => {});
    // A paused reader never hears about the cut, so watch the server's side.
    while (!response || s.app.activeDownloads > 0) {
      assert.ok(Date.now() - started < 15_000, 'the server should give up on the download');
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    const seconds = (Date.now() - started) / 1000;
    assert.equal(response.statusCode, 200);
    assert.ok(seconds >= 1, `not before the grace period (${seconds} s)`);
    // When the reader comes back, it gets what was under way and then the connection ends.
    const received = await new Promise((resolve) => {
      let bytes = 0;
      response.on('data', (chunk) => {
        bytes += chunk.length;
      });
      response.on('error', () => {});
      response.on('close', () => resolve({ bytes, complete: response.complete }));
      response.resume();
    });
    assert.equal(received.complete, false);
    assert.ok(received.bytes < s.files.mac.length, `${received.bytes} bytes`);
  });

  it('refuses a file that was replaced since it was measured', async () => {
    const ip = nextIp();
    const location = (await link(s.port, ip, 'windows')).headers.location;
    const file = path.join(s.releasesDir, 'Wortschatz-1.0-Windows.exe');
    await fs.writeFile(file, crypto.randomBytes(120_000));
    const replaced = await request(s.port, 'GET', location, { ip });
    assert.equal(replaced.status, 503);
    assert.match(replaced.body.toString(), /Neue Version unterwegs/);
    // The server reloads by itself; wait until it has measured the new file.
    const before = Date.now();
    const measured = (await fs.stat(file)).mtimeMs;
    while (s.app.state.releases.windows?.mtimeMs !== measured) {
      assert.ok(Date.now() - before < 5000, 'the server should reload');
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    const stale = await request(s.port, 'GET', location, { ip });
    assert.equal(stale.status, 410, 'after the reload the old link is outdated');
  });
});

describe('password', () => {
  let s;
  const PASSWORD = 'Test-Pw8';
  const basic = (user, password) => ({ Authorization: `Basic ${Buffer.from(`${user}:${password}`).toString('base64')}` });
  const AUTH = basic('', PASSWORD);
  const signIn = (ip, password, extra = {}, next = '/') =>
    request(s.port, 'POST', '/login', { ip, headers: { ...FORM, ...extra }, body: `weiter=${encodeURIComponent(next)}&passwort=${encodeURIComponent(password)}` });
  const cookieOf = (res) => String(res.headers['set-cookie'] ?? '').split(';')[0];
  before(async () => {
    s = await startServer({ SITE_PASSWORD: PASSWORD });
  });
  after(() => s.close());

  it('sends pages to the login, refuses files and checksums, and never makes the browser ask for a user name', async () => {
    const ip = nextIp();
    const home = await request(s.port, 'GET', '/', { ip });
    assert.equal(home.status, 303);
    assert.equal(home.headers.location, '/login');
    const updates = await request(s.port, 'GET', '/neuigkeiten', { ip });
    assert.equal(updates.status, 303);
    assert.equal(updates.headers.location, '/login?weiter=%2Fneuigkeiten');
    for (const target of ['/checksums.txt', '/gibt-es-nicht']) {
      const res = await request(s.port, 'GET', target, { ip });
      assert.equal(res.status, 401, target);
      assert.equal(res.headers['cache-control'], 'no-store');
      assert.doesNotMatch(res.body.toString(), /Wortschatz-1\.0/, `${target}: nothing about the files`);
    }
    for (const target of ['/', '/checksums.txt', '/login']) {
      assert.equal((await request(s.port, 'GET', target, { ip })).headers['www-authenticate'], undefined, target);
    }
  });

  it('keeps the login page, its styles, the privacy page and the health check open', async () => {
    const ip = nextIp();
    const page = await request(s.port, 'GET', '/login', { ip });
    assert.equal(page.status, 200);
    const html = page.body.toString();
    assert.match(html, /type="password"/);
    assert.doesNotMatch(html, /name="(?:user|benutzer)/i, 'no user name field');
    assert.doesNotMatch(html, /Wortschatz-1\.0|[0-9a-f]{64}/, 'nothing about the files');
    assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>|<style\b|\sstyle="|\son[a-z]+="/i, 'CSP-safe');
    const css = html.match(/href="(\/assets\/css\/site\.css\?v=[0-9a-f]+)"/)[1];
    assert.equal((await request(s.port, 'GET', css, { ip })).status, 200);
    assert.equal((await request(s.port, 'GET', '/robots.txt', { ip })).status, 200);
    // Safari asks for these on every visit.
    for (const icon of ['/apple-touch-icon.png', '/apple-touch-icon-precomposed.png', '/favicon.ico']) {
      assert.equal((await request(s.port, 'GET', icon, { ip })).status, 200, icon);
    }
    const privacy = await request(s.port, 'GET', '/datenschutz', { ip });
    assert.equal(privacy.status, 200);
    assert.match(privacy.body.toString(), /Cookie/);
    assert.equal((await request(s.port, 'GET', '/healthz', { ip })).status, 200);
  });

  it('signs in with only the password and remembers it in a cookie', async () => {
    const ip = nextIp();
    const wrong = await signIn(ip, 'falsch123');
    assert.equal(wrong.status, 401);
    assert.match(wrong.body.toString(), /Das Passwort stimmt nicht/);
    assert.equal(wrong.headers['set-cookie'], undefined);

    const res = await signIn(ip, PASSWORD, {}, '/datenschutz');
    assert.equal(res.status, 303);
    assert.equal(res.headers.location, '/datenschutz');
    const setCookie = String(res.headers['set-cookie']);
    assert.match(setCookie, /^__Host-wortschatz=\d{10}\.[A-Za-z0-9_-]{43}; Path=\/; Max-Age=7776000; HttpOnly; SameSite=Lax; Secure$/);
    const cookie = cookieOf(res);
    const home = await request(s.port, 'GET', '/', { ip, headers: { Cookie: cookie } });
    assert.equal(home.status, 200);
    assert.ok(home.body.toString().includes(sha(s.files.mac)));
    assert.equal((await request(s.port, 'GET', '/checksums.txt', { ip, headers: { Cookie: `x=1; ${cookie}` } })).status, 200);
    assert.equal((await request(s.port, 'GET', '/login', { ip, headers: { Cookie: cookie } })).headers.location, '/', 'signed in: no form');
  });

  it('signs in on the English login page and goes on to the English pages', async () => {
    const ip = nextIp();
    assert.equal((await request(s.port, 'GET', '/en', { ip })).headers.location, '/en/login');
    assert.equal((await request(s.port, 'GET', '/en/whats-new', { ip })).headers.location, '/en/login?weiter=%2Fen%2Fwhats-new');
    const page = await request(s.port, 'GET', '/en/login?weiter=%2Fneuigkeiten', { ip });
    assert.equal(page.status, 200);
    const html = page.body.toString();
    assert.match(html, /<html lang="en">/);
    assert.match(html, /action="\/en\/login"/);
    assert.match(html, /name="weiter" value="\/en\/whats-new"/, 'goes on in English');
    assert.match(html, /href="\/login\?weiter=%2Fneuigkeiten" hreflang="de"/, 'the switch keeps where to go, in German');
    assert.equal((await request(s.port, 'GET', '/en/privacy', { ip })).status, 200, 'privacy open in English too');

    const english = (password, next) =>
      request(s.port, 'POST', '/en/login', { ip, headers: FORM, body: `weiter=${encodeURIComponent(next)}&passwort=${encodeURIComponent(password)}` });
    const wrong = await english('falsch123', '/');
    assert.equal(wrong.status, 401);
    assert.match(wrong.body.toString(), /That password isn’t right/);
    assert.equal((await english(PASSWORD, '/neuigkeiten')).headers.location, '/en/whats-new', 'German next, English login: English page');
    assert.equal((await english(PASSWORD, '//evil.example')).headers.location, '/en');
    assert.equal((await signIn(ip, PASSWORD, {}, '/en')).headers.location, '/', 'and the other way round');
    const out = await request(s.port, 'POST', '/en/logout', { ip, headers: { ...FORM, Cookie: cookieOf(await english(PASSWORD, '/')) } });
    assert.equal(out.headers.location, '/en/login');
  });

  it('only accepts its own cookie and its own form', async () => {
    const ip = nextIp();
    const cookie = cookieOf(await signIn(ip, PASSWORD));
    const [name, value] = cookie.split('=');
    const flipped = `${name}=${value.slice(0, -1)}${value.endsWith('A') ? 'B' : 'A'}`;
    const expired = `${name}=1000000000.${value.split('.')[1]}`;
    for (const bad of [flipped, expired, `wortschatz=${value}`]) {
      assert.equal((await request(s.port, 'GET', '/', { ip, headers: { Cookie: bad } })).status, 303, bad);
    }
    assert.equal((await signIn(nextIp(), PASSWORD, { Origin: 'https://evil.example', 'Sec-Fetch-Site': 'cross-site' })).status, 403);
    assert.equal((await signIn(nextIp(), PASSWORD, {}, '//evil.example')).headers.location, '/', 'no open redirect');
    const elsewhere = await request(s.port, 'GET', '/login?weiter=https%3A%2F%2Fevil.example', { ip: nextIp() });
    assert.match(elsewhere.body.toString(), /name="weiter" value="\/"/);
  });

  it('downloads when signed in, not without', async () => {
    const ip = nextIp();
    assert.equal((await link(s.port, ip)).status, 401);
    const cookie = cookieOf(await signIn(ip, PASSWORD));
    const res = await link(s.port, ip, 'mac', { Cookie: cookie });
    assert.equal(res.status, 303);
    assert.equal((await request(s.port, 'GET', res.headers.location, { ip })).status, 401);
    const file = await request(s.port, 'GET', res.headers.location, { ip, headers: { Cookie: cookie } });
    assert.equal(file.status, 200);
    assert.equal(sha(file.body), sha(s.files.mac));
  });

  it('still lets scripts in with HTTP Basic Auth, whatever the user name', async () => {
    const ip = nextIp();
    assert.equal((await request(s.port, 'GET', '/', { ip, headers: AUTH })).status, 200);
    assert.equal((await request(s.port, 'GET', '/checksums.txt', { ip, headers: basic('joan', PASSWORD) })).status, 200);
    assert.equal((await request(s.port, 'GET', '/checksums.txt', { ip, headers: basic('', 'falsch123') })).status, 401);
    assert.equal((await request(s.port, 'GET', '/checksums.txt', { ip, headers: { Authorization: `Basic ${Buffer.from(PASSWORD).toString('base64')}` } })).status, 401, 'no colon');
    assert.equal((await request(s.port, 'GET', '/checksums.txt', { ip, headers: { Authorization: 'Bearer x' } })).status, 401);
    const statuses = [];
    for (let i = 0; i < 25; i += 1) statuses.push((await request(s.port, 'GET', '/checksums.txt', { ip, headers: AUTH })).status);
    assert.ok(statuses.every((status) => status === 200), 'a remembered right password never runs into the limit');
  });

  it('slows down guessing, even when a guess is right', async () => {
    const ip = nextIp();
    const statuses = [];
    for (let i = 0; i < 11; i += 1) statuses.push((await signIn(ip, `falsch${i}xx`)).status);
    assert.deepEqual(statuses.slice(0, 10), Array(10).fill(401));
    assert.equal(statuses[10], 429);
    assert.equal((await signIn(ip, PASSWORD)).status, 429, 'the right password does not help while guessing is slowed down');
    assert.equal((await signIn(nextIp(), PASSWORD)).status, 303, 'other addresses are not affected');
    const basicIp = nextIp();
    const basicStatuses = [];
    for (let i = 0; i < 12; i += 1) basicStatuses.push((await request(s.port, 'GET', '/checksums.txt', { ip: basicIp, headers: basic('', `falsch${i}xx`) })).status);
    assert.deepEqual(basicStatuses.slice(0, 10), Array(10).fill(401));
    assert.equal(basicStatuses[11], 429);
  });

  it('does not give away a right Basic Auth guess while guessing is slowed down', async () => {
    const ip = nextIp();
    const check = (headers) => request(s.port, 'GET', '/checksums.txt', { ip, headers });
    for (let i = 0; i < 10; i += 1) assert.equal((await check(basic('', `falsch${i}xx`))).status, 401);
    assert.equal((await check(basic('', 'falsch-xxx'))).status, 429);
    assert.equal((await check(AUTH)).status, 429, 'answered like any other guess');
    const other = await request(s.port, 'GET', '/checksums.txt', { ip: nextIp(), headers: AUTH });
    assert.equal(other.status, 200, 'other addresses are not affected');
  });

  it('lets a whole class sign in at once from one address', async () => {
    const ip = nextIp();
    for (let i = 0; i < 24; i += 1) assert.equal((await signIn(ip, PASSWORD)).status, 303, `student ${i}`);
    for (let i = 0; i < 24; i += 1) assert.equal((await request(s.port, 'GET', '/checksums.txt', { ip, headers: AUTH })).status, 200);
  });

  it('takes no header as an excuse for guessing', async () => {
    const ip = nextIp();
    const faked = { ...basic('', 'falsch-xxx'), 'Sec-Fetch-Site': 'cross-site' };
    let last;
    for (let i = 0; i < 11; i += 1) last = await request(s.port, 'GET', '/checksums.txt', { ip, headers: faked });
    assert.equal(last.status, 429);
    const referer = { 'Content-Type': FORM['Content-Type'], Origin: ORIGIN, Referer: 'https://evil.example/' };
    const other = nextIp();
    for (let i = 0; i < 11; i += 1) last = await request(s.port, 'POST', '/login', { ip: other, headers: referer, body: 'weiter=%2F&passwort=falsch-xxx' });
    assert.equal(last.status, 429);
  });

  it('counts all addresses of an IPv6 /48 as one for guessing', async () => {
    let last;
    for (let i = 0; i < 11; i += 1) {
      last = await request(s.port, 'GET', '/checksums.txt', { ip: `2001:db8:77:${i}00::1`, headers: basic('', 'falsch-xxx') });
    }
    assert.equal(last.status, 429);
    assert.equal((await request(s.port, 'GET', '/checksums.txt', { ip: '2001:db8:78::1', headers: AUTH })).status, 200, 'the next /48 goes on');
  });

  it('refuses a correctly signed cookie that would last too long', async () => {
    const key = crypto.scryptSync(PASSWORD, 'wortschatz-login-v1', 32, { N: 2 ** 15, r: 8, p: 1, maxmem: 64 * 1024 * 1024 });
    const cookie = (expires) => `__Host-wortschatz=${expires}.${crypto.createHmac('sha256', key).update(`login:${expires}`).digest('base64url')}`;
    const now = Math.floor(Date.now() / 1000);
    assert.equal((await request(s.port, 'GET', '/', { ip: nextIp(), headers: { Cookie: cookie(now + 3600) } })).status, 200, 'the key is the right one');
    assert.equal((await request(s.port, 'GET', '/', { ip: nextIp(), headers: { Cookie: cookie(9999999999) } })).status, 303);
    const long = `${'x'.repeat(5000)}=1; ${cookie(now + 3600)}`;
    assert.equal((await request(s.port, 'GET', '/', { ip: nextIp(), headers: { Cookie: long } })).status, 303, 'very long cookie headers are not read');
  });

  it('signs out, only by its own form', async () => {
    const ip = nextIp();
    const cookie = cookieOf(await signIn(ip, PASSWORD));
    const home = await request(s.port, 'GET', '/', { ip, headers: { Cookie: cookie } });
    assert.match(home.body.toString(), /action="\/logout"/);
    assert.doesNotMatch((await request(s.port, 'GET', '/login', { ip: nextIp() })).body.toString(), /action="\/logout"/, 'not on the login page');
    assert.equal((await request(s.port, 'GET', '/logout', { ip, headers: { Cookie: cookie } })).headers['set-cookie'], undefined, 'a link cannot sign anybody out');
    const foreign = await request(s.port, 'POST', '/logout', { ip, headers: { Cookie: cookie, Origin: 'https://evil.example', 'Sec-Fetch-Site': 'cross-site' } });
    assert.equal(foreign.status, 403);
    assert.equal(foreign.headers['set-cookie'], undefined);
    const out = await request(s.port, 'POST', '/logout', { ip, headers: { Cookie: cookie, ...FORM } });
    assert.equal(out.status, 303);
    assert.equal(out.headers.location, '/login');
    assert.match(String(out.headers['set-cookie']), /^__Host-wortschatz=; Path=\/; Max-Age=0; HttpOnly; SameSite=Lax; Secure$/);
  });

  it('keeps what is behind the password out of shared caches', async () => {
    const ip = nextIp();
    const cookie = cookieOf(await signIn(ip, PASSWORD));
    for (const target of ['/', '/checksums.txt']) {
      const res = await request(s.port, 'GET', target, { ip, headers: { Cookie: cookie } });
      assert.equal(res.headers['cache-control'], 'private, no-cache', target);
      assert.match(res.headers.vary, /Cookie, Authorization/, target);
    }
    assert.match((await request(s.port, 'GET', '/robots.txt', { ip })).headers['cache-control'], /^public/);
  });
});

describe('password guesses per day', () => {
  let s;
  before(async () => {
    s = await startServer({ SITE_PASSWORD: 'Test-Pw8', PASSWORD_GUESSES_PER_DAY: '3' });
  });
  after(() => s.close());

  it('allows only so many wrong passwords a day, however slowly they come', async () => {
    const ip = nextIp();
    const wrong = () => request(s.port, 'POST', '/login', { ip, headers: FORM, body: 'weiter=%2F&passwort=falsch-xxx' });
    assert.deepEqual([(await wrong()).status, (await wrong()).status, (await wrong()).status, (await wrong()).status], [401, 401, 401, 429]);
    const right = await request(s.port, 'POST', '/login', { ip, headers: FORM, body: 'weiter=%2F&passwort=Test-Pw8' });
    assert.equal(right.status, 429, 'answered like any other guess');
    assert.ok(Number(right.headers['retry-after']) > 3600);
    assert.equal((await request(s.port, 'POST', '/login', { ip: nextIp(), headers: FORM, body: 'weiter=%2F&passwort=Test-Pw8' })).status, 303);
  });
});

describe('floods', () => {
  /** A server of its own, closed again even when a check fails (open sockets would keep the tests running). */
  const using = async (env, options, run) => {
    const s = await startServer(env, options);
    try {
      await run(s);
    } finally {
      await s.close();
    }
  };

  const firstVisit = async (port, ip) => {
    // What a browser with a retina screen loads on a first visit, compressed.
    const encoded = { 'Accept-Encoding': 'br', 'Sec-Fetch-Site': 'same-origin' };
    const page = await request(port, 'GET', '/', { ip, headers: encoded });
    const html = zlib.brotliDecompressSync(page.body).toString();
    const wanted = [
      ...[...html.matchAll(/(?:src|href)="(\/assets\/[^"]+\.(?:css|js)[^"]*)"/g)].map((match) => match[1]),
      ...[...html.matchAll(/(\/assets\/img\/[^"\s,]+) 2x/g)].map((match) => match[1]),
      ...[...html.matchAll(/<img[^>]+src="(\/assets\/[^"]+)"/g)].map((match) => match[1]),
      '/assets/img/noise.png',
      '/favicon.ico',
    ];
    const answers = [page];
    for (const asset of new Set(wanted)) answers.push(await request(port, 'GET', asset, { ip, headers: encoded }));
    return answers;
  };

  it('lets a whole class of 60 visit at once from one address', () =>
    using({}, {}, async (s) => {
      const ip = nextIp();
      const answers = (await Promise.all(Array.from({ length: 60 }, () => firstVisit(s.port, ip)))).flat();
      assert.ok(answers.length >= 60 * 6, `${answers.length} requests: as many as real browsers make`);
      const refused = answers.filter((answer) => answer.status !== 200);
      assert.equal(refused.length, 0, refused.map((answer) => answer.status).join(' '));
    }));

  it('keeps refused and missing pages small', () =>
    using({}, {}, async (s) => {
      const missing = await request(s.port, 'GET', '/gibt-es-nicht', { ip: nextIp() });
      assert.equal(missing.status, 404);
      assert.ok(missing.body.length < 5000, `${missing.body.length} bytes`);
    }));

  it('limits the bytes per address, also when each request stays within the limits', () =>
    using({ SITE_BANDWIDTH_PER_IP_MBIT: '0.0125' }, {}, async (s) => {
      // 1.5 KB/s, 400 KB in reserve.
      const ip = nextIp();
      let fetched = 0;
      let last;
      do {
        last = await request(s.port, 'GET', '/assets/img/og.png', { ip });
        if (last.status === 200) fetched += 1;
      } while (last.status === 200 && fetched < 900);
      assert.equal(last.status, 429);
      assert.ok(last.body.length < 80);
      const size = (await request(s.port, 'GET', '/assets/img/og.png', { ip: nextIp() })).body.length + 1200;
      assert.ok(fetched * size >= 400_000 && (fetched - 2) * size < 400_000, `${fetched} images of ${size} bytes`);
      assert.equal((await request(s.port, 'GET', '/assets/img/og.png', { ip: nextIp() })).status, 200, 'others go on');
    }));

  it('protects the upload when many addresses each stay within their limits', () =>
    using({ SITE_BANDWIDTH_MBIT: '1' }, {}, async (s) => {
      // 125 KB/s, 1 MB in reserve, and as much again for addresses that got little so far.
      let last;
      let fetched = 0;
      do {
        last = await request(s.port, 'GET', '/assets/img/og.png', { ip: nextIp() });
        fetched += 1;
      } while (last.status === 200 && fetched < 900);
      assert.equal(last.status, 503);
      assert.ok(last.body.length < 80);
      assert.ok(Number(last.headers['retry-after']) > 0);
      assert.equal((await request(s.port, 'GET', '/healthz')).status, 200, 'the health check from this machine still works');
    }));

  it('sends away those who got a lot first when the upload runs short', () =>
    using({ SITE_BANDWIDTH_MBIT: '2' }, {}, async (s) => {
      // 250 KB/s, 2 MB in reserve. The greedy address gets 2 MB, more than the 1 MB of a light one.
      const greedy = nextIp();
      let answer;
      do {
        answer = await request(s.port, 'GET', '/assets/img/og.png', { ip: greedy });
      } while (answer.status === 200);
      assert.equal(answer.status, 503, 'its own allowance is not used up, but the upload is');
      assert.equal((await request(s.port, 'GET', '/', { ip: nextIp() })).status, 200, "a visitor's first page still gets through");
    }));

  it('lets running downloads finish while pages are refused', () =>
    using({ SITE_BANDWIDTH_MBIT: '0.1', BANDWIDTH_PER_DOWNLOAD_MBIT: '1' }, {}, async (s) => {
      // 300 KB at 125 KB/s: about two seconds. Pages: 12.5 KB/s, 100 KB in reserve.
      const ip = nextIp();
      const location = (await link(s.port, ip)).headers.location;
      const download = request(s.port, 'GET', location, { ip });
      await new Promise((resolve) => setTimeout(resolve, 200));
      let page;
      let asked = 0;
      do {
        page = await request(s.port, 'GET', '/assets/img/og.png', { ip: nextIp() });
        asked += 1;
      } while (page.status === 200 && asked < 900);
      assert.equal(page.status, 503);
      const file = await download;
      assert.equal(file.status, 200);
      assert.equal(sha(file.body), sha(s.files.mac));
    }));

  it('charges a response at once, even if the client never reads it', async () => {
    // A file too big for the socket buffers: nobody reading means the response never finishes.
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'wortschatz-big-'));
    await fs.cp(PUBLIC_DIR, root, { recursive: true });
    await fs.writeFile(path.join(root, 'assets/img/big.png'), crypto.randomBytes(4_500_000));
    try {
      await using({ PUBLIC_DIR: root, SITE_BANDWIDTH_PER_IP_MBIT: '0.0125' }, {}, async (s) => {
        const ip = nextIp();
        const socket = net.connect(s.port, '127.0.0.1');
        socket.on('error', () => {});
        socket.pause();
        socket.write(`GET /assets/img/big.png HTTP/1.1\r\nHost: ${HOST}\r\nX-Forwarded-For: ${ip}\r\n\r\n`);
        // The limit answers as soon as the response is under way.
        let answer;
        for (let i = 0; i < 100 && answer?.status !== 429; i += 1) {
          await new Promise((resolve) => setTimeout(resolve, 20));
          answer = await request(s.port, 'GET', '/healthz', { ip });
        }
        assert.equal(answer.status, 429);
        socket.destroy();
      });
    } finally {
      await fs.rm(root, { recursive: true, force: true });
    }
  });

  it('keeps the slow lane inside the bandwidth limit', () =>
    using({ BANDWIDTH_TOTAL_MBIT: '8', DAILY_TRAFFIC_GB_PER_IP: '0.0001', DAILY_TRAFFIC_SLOW_MBIT: '100' }, { macSize: 2_000_000 }, async (s) => {
      // 1 MB/s for everything: 100 KB fast, or not, the file takes about two seconds anyway.
      const one = nextIp();
      const two = nextIp();
      const started = Date.now();
      const [a, b] = await Promise.all([one, two].map(async (ip) => {
        const { location } = (await link(s.port, ip)).headers;
        return request(s.port, 'GET', location, { ip });
      }));
      assert.equal(a.status, 200);
      assert.equal(b.status, 200);
      assert.ok(Date.now() - started > 3000, `${Date.now() - started} ms for 4 MB at 1 MB/s`);
    }));

  it('keeps refusals out of every cache', () =>
    using({ RATE_REQUEST_BURST: '5', RATE_REQUESTS_PER_SECOND: '0.02' }, {}, async (s) => {
      const asked = await request(s.port, 'GET', '/assets/css/site.css', { ip: nextIp(), headers: { 'Sec-Fetch-Site': 'cross-site', 'Sec-Fetch-Mode': 'no-cors' } });
      assert.equal(asked.status, 403);
      assert.equal(asked.headers['cache-control'], 'no-store');
      const ip = nextIp();
      let last;
      for (let i = 0; i < 7; i += 1) last = await request(s.port, 'GET', '/healthz', { ip });
      assert.equal(last.status, 429);
      assert.equal(last.headers['cache-control'], 'no-store');
    }));

  it('closes the connection after refusing a body it did not read', () =>
    using({}, {}, async (s) => {
      for (const [method, target] of [['POST', '/'], ['PUT', '/'], ['POST', '/logout']]) {
        const socket = net.connect(s.port, '127.0.0.1');
        socket.on('error', () => {});
        const closed = new Promise((resolve) => socket.on('close', resolve));
        socket.write(`${method} ${target} HTTP/1.1\r\nHost: ${HOST}\r\nX-Forwarded-For: ${nextIp()}\r\nContent-Length: 500\r\n\r\nx`);
        socket.resume();
        const started = Date.now();
        await closed;
        assert.ok(Date.now() - started < 5000, `${method} ${target}: ${Date.now() - started} ms`);
      }
    }));

  it('closes a timed-out connection even if the client goes on sending, and stays silent to one that never sent anything', () =>
    using({}, { serverOptions: { requestTimeout: 500, headersTimeout: 500, connectionsCheckingInterval: 100 } }, async (s) => {
      const silent = net.connect(s.port, '127.0.0.1');
      const heard = [];
      silent.on('data', (data) => heard.push(data));
      silent.on('error', () => {});
      await new Promise((resolve) => silent.on('close', resolve));
      assert.equal(heard.length, 0, 'no answer without a question');

      const stubborn = net.connect({ port: s.port, host: '127.0.0.1', allowHalfOpen: true });
      stubborn.on('error', () => {});
      const answer = new Promise((resolve) => stubborn.once('data', (data) => resolve(data.toString('latin1'))));
      const closed = new Promise((resolve) => stubborn.on('close', resolve));
      stubborn.write(`POST /download/mac HTTP/1.1\r\nHost: ${HOST}\r\nX-Forwarded-For: ${nextIp()}\r\nOrigin: ${ORIGIN}\r\nSec-Fetch-Site: same-origin\r\nContent-Type: ${FORM['Content-Type']}\r\nContent-Length: 900\r\n\r\nw`);
      const drip = setInterval(() => stubborn.write('x'), 100);
      assert.match(await answer, /^HTTP\/1\.1 408/);
      await closed;
      clearInterval(drip);
    }));

  it('writes no log line per refused request', async () => {
    let lines = 0;
    const stream = { write: () => { lines += 1; } };
    await using({ ACCESS_LOG: '1', RATE_REQUEST_BURST: '5', RATE_REQUESTS_PER_SECOND: '0.02' }, { logger: createLogger('info', { stdout: stream, stderr: stream }) }, async (s) => {
      const before = lines;
      const ip = nextIp();
      for (let i = 0; i < 100; i += 1) await request(s.port, 'GET', '/', { ip });
      assert.ok(lines - before <= 6, `${lines - before} lines`);
    });
  });

  it('caps the log lines when many addresses come at once', async () => {
    let lines = 0;
    const stream = { write: () => { lines += 1; } };
    await using({ ACCESS_LOG: '1' }, { logger: createLogger('info', { stdout: stream, stderr: stream }) }, async (s) => {
      const before = lines;
      const started = Date.now();
      // In batches: the system refuses too many new connections at the same instant.
      for (let batch = 0; batch < 15; batch += 1) {
        await Promise.all(Array.from({ length: 40 }, () => request(s.port, 'GET', '/healthz', { ip: nextIp() })));
      }
      const allowed = 200 + 20 * ((Date.now() - started) / 1000) + 5;
      assert.ok(lines - before <= allowed, `${lines - before} lines for 600 requests, ${allowed} allowed`);
    });
  });

  it('shortens long addresses in the log', async () => {
    const seen = [];
    const stream = { write: (line) => seen.push(JSON.parse(line)) };
    await using({ ACCESS_LOG: '1' }, { logger: createLogger('info', { stdout: stream, stderr: stream }) }, async (s) => {
      await request(s.port, 'GET', `/${'a'.repeat(1500)}`, { ip: nextIp() });
      let line;
      for (let i = 0; i < 500 && !line; i += 1) {
        line = seen.find((entry) => entry.msg === 'request');
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      assert.ok(line.path.length <= 80, String(line.path.length));
    });
  });

  it('holds only a few unfinished form posts per address, and drops them when time is up', () =>
    using({}, { serverOptions: { requestTimeout: 2000, headersTimeout: 2000, connectionsCheckingInterval: 100 } }, async (s) => {
      const post = (ip) => {
        const socket = net.connect(s.port, '127.0.0.1');
        socket.on('error', () => {});
        const closed = new Promise((resolve) => socket.on('close', resolve));
        const answer = new Promise((resolve) => socket.once('data', (data) => resolve(data.toString('latin1'))));
        socket.write(`POST /download/mac HTTP/1.1\r\nHost: ${HOST}\r\nX-Forwarded-For: ${ip}\r\nOrigin: ${ORIGIN}\r\nSec-Fetch-Site: same-origin\r\nContent-Type: ${FORM['Content-Type']}\r\nContent-Length: 900\r\n\r\nwebsite=`);
        return { socket, closed, answer };
      };
      const ip = nextIp();
      const posts = Array.from({ length: 9 }, () => post(ip));
      assert.match(await Promise.race(posts.map((item) => item.answer)), /^HTTP\/1\.1 429/, 'nine at once from one address');
      const network = Array.from({ length: 9 }, (_, i) => post(`2001:db8:99:${i}00::1`));
      assert.match(await Promise.race(network.map((item) => item.answer)), /^HTTP\/1\.1 429/, 'an IPv6 /48 counts as one');
      assert.equal((await request(s.port, 'GET', '/datenschutz', { ip: nextIp() })).status, 200, 'pages are not affected');
      const started = Date.now();
      await Promise.all([...posts, ...network].map((item) => item.closed));
      // Far below the 60 s after which idle connections go anyway.
      assert.ok(Date.now() - started < 20_000, `${Date.now() - started} ms`);
    }));

  it('makes room at the connection limit by closing idle connections', () =>
    using({}, {}, async (s) => {
      s.server.maxConnections = 20;
      const sockets = [];
      try {
        for (let i = 0; i < 20; i += 1) {
          await new Promise((resolve) => {
            const socket = net.connect(s.port, '127.0.0.1', () => {
              socket.write(`GET /healthz HTTP/1.1\r\nHost: ${HOST}\r\n\r\n`);
            });
            socket.on('error', () => {});
            socket.once('data', resolve);
            sockets.push(socket);
          });
        }
        // Full now: the first new connection is dropped and clears the idle ones.
        let answer = null;
        for (let i = 0; i < 100 && answer?.status !== 200; i += 1) {
          answer = await request(s.port, 'GET', '/healthz').catch(() => null);
          if (answer?.status !== 200) await new Promise((resolve) => setTimeout(resolve, 50));
        }
        assert.equal(answer?.status, 200);
      } finally {
        sockets.forEach((socket) => socket.destroy());
      }
    }));
});
