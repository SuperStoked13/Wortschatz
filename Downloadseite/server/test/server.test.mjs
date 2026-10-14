// End-to-end tests against a real server on a random port, including attacks.
// Requests carry X-Forwarded-For from 127.0.0.1 (a trusted proxy), so the server sees
// public test addresses (203.0.113.x) and applies every limit to them.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createApp } from '../lib/app.mjs';
import { loadConfig } from '../lib/config.mjs';
import { createLogger } from '../lib/log.mjs';

const PUBLIC_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'public');
const HOST = 'wortschatz.test';
const ORIGIN = `https://${HOST}`;

let ipCounter = 10;
const nextIp = () => `203.0.113.${ipCounter++}`;

async function startServer(env = {}, { releases = true, macSize = 300_000 } = {}) {
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
  const app = await createApp(config, createLogger('silent'));
  const server = http.createServer(app.handle);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  return {
    port,
    files,
    app,
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
    for (const page of ['/', '/datenschutz', '/gibt-es-nicht']) {
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

  it('answers unknown pages with the 404 page', async () => {
    const res = await request(s.port, 'GET', '/gibt-es-nicht', { ip: nextIp() });
    assert.equal(res.status, 404);
    assert.match(res.body.toString(), /Seite nicht gefunden/);
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

  it('blocks bots that fill in the hidden field', async () => {
    const ip = nextIp();
    const res = await request(s.port, 'POST', '/download/mac', { ip, headers: FORM, body: 'website=http%3A%2F%2Fspam.example' });
    assert.equal(res.status, 403);
    const after = await request(s.port, 'GET', '/', { ip });
    assert.equal(after.status, 403, 'the address is blocked now');
    assert.match(after.body.toString(), /gesperrt/);
    assert.ok(Number(after.headers['retry-after']) > 0);
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

describe('limits and blocks', () => {
  let s;
  before(async () => {
    s = await startServer({
      DOWNLOADS_PER_HOUR: '2',
      RATE_PAGE_BURST: '5',
      RATE_PAGE_PER_MINUTE: '1',
      DOWNLOAD_LINK_SECONDS: '10',
      BAN_THRESHOLD: '12',
      CONCURRENT_DOWNLOADS_PER_IP: '1',
      BANDWIDTH_PER_DOWNLOAD_MBIT: '0.5',
    });
  });
  after(() => s.close());

  it('limits download links per address and hour', async () => {
    const ip = nextIp();
    assert.equal((await link(s.port, ip)).status, 303);
    assert.equal((await link(s.port, ip)).status, 303);
    const third = await link(s.port, ip, 'mac', { Accept: 'application/json' });
    assert.equal(third.status, 429);
    const data = JSON.parse(third.body);
    assert.equal(data.title, 'Zu viele Downloads');
    // Two downloads this hour with a limit of two: free again half an hour after the
    // hour ends at the earliest (the window slides), so between 30 and 90 minutes.
    const retry = Number(third.headers['retry-after']);
    assert.ok(retry >= 1800 && retry <= 5400, `retry-after ${retry}`);
    assert.equal((await link(s.port, nextIp())).status, 303, 'other addresses are not affected');
  });

  it('limits page requests per address', async () => {
    const ip = nextIp();
    const statuses = [];
    for (let i = 0; i < 7; i += 1) statuses.push((await request(s.port, 'GET', '/datenschutz', { ip })).status);
    assert.deepEqual(statuses.slice(0, 5), [200, 200, 200, 200, 200]);
    assert.equal(statuses[6], 429);
  });

  it('blocks scanners after two trap hits', async () => {
    const ip = nextIp();
    assert.equal((await request(s.port, 'GET', '/.env', { ip })).status, 404);
    assert.equal((await request(s.port, 'GET', '/', { ip })).status, 200);
    assert.equal((await request(s.port, 'GET', '/wp-login.php', { ip })).status, 404);
    assert.equal((await request(s.port, 'GET', '/', { ip })).status, 403);
  });

  it('allows one download at a time per address when configured so', async () => {
    const ip = nextIp();
    const first = (await link(s.port, ip)).headers.location;
    const slow = request(s.port, 'GET', first, { ip });
    await new Promise((resolve) => setTimeout(resolve, 150));
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

describe('fair use and robustness', () => {
  let s;
  before(async () => {
    s = await startServer(
      {
        DOWNLOADS_PER_HOUR: '2',
        RATE_PAGE_BURST: '5',
        RATE_PAGE_PER_MINUTE: '1',
        DAILY_TRAFFIC_GB_PER_IP: '0.01',
        DOWNLOAD_MIN_KBPS: '64',
        DOWNLOAD_SLOW_GRACE_SECONDS: '1',
        BANDWIDTH_TOTAL_MBIT: '0',
      },
      { macSize: 8_000_000 },
    );
  });
  after(() => s.close());

  it('does not block visitors when another website makes their browser call traps', async () => {
    const ip = nextIp();
    const image = { 'Sec-Fetch-Site': 'cross-site', 'Sec-Fetch-Dest': 'image' };
    for (const target of ['/.env', '/wp-login.php', '/.git/config', '/dl/nonsense']) {
      assert.equal((await request(s.port, 'GET', target, { ip, headers: image })).status, 404);
    }
    const oldBrowser = { Referer: 'https://evil.example/forum' };
    for (const target of ['/.env', '/wp-login.php']) {
      assert.equal((await request(s.port, 'GET', target, { ip, headers: oldBrowser })).status, 404);
    }
    assert.equal((await request(s.port, 'GET', '/', { ip })).status, 200, 'not blocked');
  });

  it('limits private addresses behind the proxy, but never blocks them', async () => {
    const ip = '10.20.30.40';
    const statuses = [];
    for (let i = 0; i < 7; i += 1) statuses.push((await request(s.port, 'GET', '/datenschutz', { ip })).status);
    assert.equal(statuses[6], 429, 'limits apply');
    for (const target of ['/.env', '/wp-login.php', '/.git/config']) await request(s.port, 'GET', target, { ip });
    const after = await request(s.port, 'GET', '/healthz', { ip });
    assert.notEqual(after.status, 403, 'no block for a private address');
  });

  it('counts a second full download through the same link', async () => {
    const ip = nextIp();
    const location = (await link(s.port, ip, 'windows')).headers.location; // download 1 of 2
    assert.equal((await request(s.port, 'GET', location, { ip })).status, 200);
    assert.equal((await request(s.port, 'GET', location, { ip })).status, 200); // download 2 of 2
    const third = await request(s.port, 'GET', location, { ip });
    assert.equal(third.status, 429);
    assert.match(third.body.toString(), /Zu viele Downloads/);
    const resume = await request(s.port, 'GET', location, { ip, headers: { Range: 'bytes=10-' } });
    assert.equal(resume.status, 206, 'resuming does not count');
  });

  it('stops an address after its daily traffic', async () => {
    const ip = nextIp();
    const first = (await link(s.port, ip)).headers.location;
    const file = await request(s.port, 'GET', first, { ip });
    assert.equal(file.body.length, s.files.mac.length);
    // 8 of 10 MB used: the next download may still start (and finish).
    const second = (await link(s.port, ip)).headers.location;
    const res = await request(s.port, 'GET', second, { ip });
    assert.equal(res.status, 200);
    assert.equal(res.body.length, s.files.mac.length);
    // 16 of 10 MB: no more links today.
    const third = await link(s.port, ip, 'mac', { Accept: 'application/json' });
    assert.equal(third.status, 429);
    assert.equal(JSON.parse(third.body).title, 'Tageslimit erreicht');
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
