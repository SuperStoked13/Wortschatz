// Unit tests for the building blocks: `node --test test/` in the server folder.

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { loadConfig } from '../lib/config.mjs';
import { anonymizeIp, buildTrust, clientIp, expandIpv6, ipKey, isLoopback, normalizeIp } from '../lib/net.mjs';
import { LinkSigner } from '../lib/tokens.mjs';
import { ConcurrencyGate, DailyBudget, DailyQuota, PenaltyBox, TokenBucket, WindowCounter, dayKey, secondsUntilTomorrow } from '../lib/limits.mjs';
import { compile, escapeHtml, render } from '../lib/templates.mjs';
import { humanWait, notModified, parseRange, pickEncoding } from '../lib/http.mjs';
import { formatSize } from '../lib/releases.mjs';
import { ByteRate } from '../lib/throttle.mjs';

describe('config', () => {
  it('has safe defaults', () => {
    const config = loadConfig({});
    assert.equal(config.origin, 'https://wortschatz.duckdns.org');
    assert.equal(config.secure, true);
    assert.equal(config.host, '127.0.0.1');
    assert.ok(config.allowedHosts.has('wortschatz.duckdns.org'));
    assert.equal(config.limits.bindLinkToIp, true);
  });

  it('rejects broken values', () => {
    assert.throws(() => loadConfig({ SITE_ORIGIN: 'ftp://x.org' }));
    assert.throws(() => loadConfig({ SITE_ORIGIN: 'https://x.org/pfad' }));
    assert.throws(() => loadConfig({ PORT: '70000' }));
    assert.throws(() => loadConfig({ DOWNLOAD_SECRET: 'kurz' }));
    assert.throws(() => loadConfig({ CONTACT_EMAIL: 'keine-adresse' }));
    assert.throws(() => loadConfig({ DOWNLOAD_LINK_BIND_IP: 'vielleicht' }));
  });

  it('reads the DuckDNS name without the domain', () => {
    assert.equal(loadConfig({ DUCKDNS_DOMAIN: 'Wortschatz.duckdns.org' }).duckdns.domain, 'wortschatz');
  });
});

describe('addresses', () => {
  it('normalizes addresses', () => {
    assert.equal(normalizeIp('::ffff:203.0.113.9'), '203.0.113.9');
    assert.equal(normalizeIp('[2001:DB8::1]'), '2001:db8::1');
    assert.equal(normalizeIp('fe80::1%en0'), 'fe80::1');
    assert.equal(normalizeIp('nonsense'), '');
    assert.equal(normalizeIp('1.2.3.4, 5.6.7.8'), '');
  });

  it('expands IPv6', () => {
    assert.deepEqual(expandIpv6('2001:db8::1'), ['2001', '0db8', '0000', '0000', '0000', '0000', '0000', '0001']);
    assert.deepEqual(expandIpv6('::'), Array(8).fill('0000'));
    assert.deepEqual(expandIpv6('64:ff9b::192.0.2.33').slice(6), ['c000', '0221']);
  });

  it('groups IPv6 clients by /56 and shortens logs', () => {
    assert.equal(ipKey('2001:db8:1:2:aaaa:bbbb:cccc:dddd'), '2001:0db8:0001:0000::/56');
    assert.equal(ipKey('2001:db8:1:2::9'), ipKey('2001:db8:1:ff:ffff::1'), 'all /64s of a /56 share a key');
    assert.notEqual(ipKey('2001:db8:1:100::1'), ipKey('2001:db8:1:200::1'));
    assert.equal(ipKey('203.0.113.4'), '203.0.113.4');
    assert.ok(isLoopback('127.0.0.1') && isLoopback('::1') && !isLoopback('10.0.0.1') && !isLoopback(''));
    assert.equal(anonymizeIp('203.0.113.4'), '203.0.113.0');
    assert.equal(anonymizeIp('2001:db8:1:2::9'), '2001:db8:1::');
  });

  const fake = (remoteAddress, xff) => ({ socket: { remoteAddress }, headers: xff ? { 'x-forwarded-for': xff } : {} });

  it('ignores X-Forwarded-For from untrusted peers', () => {
    const trust = buildTrust('loopback');
    assert.equal(clientIp(fake('198.51.100.7', '1.1.1.1'), trust), '198.51.100.7');
  });

  it('takes the first untrusted hop from the right', () => {
    const trust = buildTrust('private');
    assert.equal(clientIp(fake('172.18.0.3', '6.6.6.6, 203.0.113.50'), trust), '203.0.113.50');
    assert.equal(clientIp(fake('127.0.0.1', '203.0.113.50, 10.0.0.2'), trust), '203.0.113.50');
    assert.equal(clientIp(fake('127.0.0.1', 'garbage'), trust), '127.0.0.1');
  });

  it('parses custom proxy lists', () => {
    const trust = buildTrust('10.1.2.3, 2001:db8::/32');
    assert.equal(clientIp(fake('10.1.2.3', '203.0.113.1'), trust), '203.0.113.1');
    assert.equal(clientIp(fake('2001:db8::5', '203.0.113.2'), trust), '203.0.113.2');
    assert.throws(() => buildTrust('10.0.0.0/99'));
  });
});

describe('download links', () => {
  it('verifies its own links only', () => {
    const signer = new LinkSigner('x'.repeat(40));
    const token = signer.sign({ p: 'mac', x: 123 });
    assert.deepEqual(signer.verify(token), { p: 'mac', x: 123 });
    assert.equal(new LinkSigner('y'.repeat(40)).verify(token), null);
  });

  it('rejects changed links', () => {
    const signer = new LinkSigner();
    const token = signer.sign({ p: 'mac', x: 1 });
    const [body, mac] = token.split('.');
    const forged = Buffer.from(JSON.stringify({ p: 'windows', x: 1 })).toString('base64url');
    assert.equal(signer.verify(`${forged}.${mac}`), null);
    assert.equal(signer.verify(`${body}.${mac.slice(0, -1)}${mac.endsWith('A') ? 'B' : 'A'}`), null);
    assert.equal(signer.verify(`${body}.${mac}.x`), null);
    assert.equal(signer.verify('../../etc/passwd'), null);
    assert.equal(signer.verify(undefined), null);
  });

  it('tags addresses stably', () => {
    const signer = new LinkSigner();
    assert.equal(signer.tag('203.0.113.1'), signer.tag('203.0.113.1'));
    assert.notEqual(signer.tag('203.0.113.1'), signer.tag('203.0.113.2'));
  });
});

describe('limits', () => {
  it('token bucket: burst, then refill', () => {
    let now = 0;
    const bucket = new TokenBucket({ capacity: 3, perSecond: 1, clock: () => now });
    assert.ok(bucket.take('a').ok);
    assert.ok(bucket.take('a').ok);
    assert.ok(bucket.take('a').ok);
    const blocked = bucket.take('a');
    assert.equal(blocked.ok, false);
    assert.equal(blocked.retryAfter, 1);
    assert.ok(bucket.take('b').ok, 'other keys are independent');
    now = 1000;
    assert.ok(bucket.take('a').ok);
  });

  it('window counter: limit per window, carried over by the overlap', () => {
    let now = 0;
    const counter = new WindowCounter({ limit: 2, windowMs: 10_000, clock: () => now });
    counter.record('a');
    now = 4000;
    counter.record('a');
    const check = counter.check('a');
    assert.equal(check.ok, false);
    assert.equal(check.retryAfter, 11, 'this window, then half of the next one');
    // Right after the window: the previous two still count almost fully.
    now = 10_500;
    assert.deepEqual(counter.check('a'), { ok: false, retryAfter: 5 });
    now = 14_900;
    assert.equal(counter.check('a').ok, false);
    // Halfway through the next window one of them has faded out.
    now = 15_100;
    assert.equal(counter.check('a').ok, true);
    // Two windows later everything is gone.
    now = 30_000;
    assert.ok(counter.check('a').ok);
    assert.ok(counter.check('b').ok, 'other keys are independent');
  });

  it('window counter keeps three numbers per key, however many events', () => {
    const counter = new WindowCounter({ limit: 1_000_000, windowMs: 1000 });
    for (let i = 0; i < 10_000; i += 1) counter.record('a');
    assert.deepEqual(Object.keys(counter.counts.get('a')).sort(), ['current', 'previous', 'start']);
  });

  it('daily quota per key', () => {
    let now = Date.parse('2026-10-14T10:00:00Z');
    const quota = new DailyQuota({ limit: 100, clock: () => now });
    quota.add('a', 99);
    assert.ok(quota.allows('a'));
    quota.add('a', 1);
    assert.equal(quota.allows('a'), false);
    assert.ok(quota.allows('b'));
    now = Date.parse('2026-10-15T10:00:00Z');
    assert.ok(quota.allows('a'), 'a new day');
    assert.ok(new DailyQuota({ limit: 0 }).allows('x'), '0 = unlimited');
  });

  it('penalties block and expire', () => {
    let now = 0;
    const box = new PenaltyBox({ threshold: 10, decayMs: 1000, banMs: 5000, clock: () => now });
    assert.equal(box.add('a', 6), false);
    assert.equal(box.add('a', 6), true);
    assert.equal(box.blockedFor('a'), 5000);
    now = 5001;
    assert.equal(box.blockedFor('a'), 0);
  });

  it('penalties fade away', () => {
    let now = 0;
    const box = new PenaltyBox({ threshold: 10, decayMs: 1000, banMs: 5000, clock: () => now });
    box.add('a', 9);
    now = 1000;
    assert.equal(box.add('a', 9), false);
  });

  it('concurrency gate', () => {
    const gate = new ConcurrencyGate({ perKey: 1, total: 2 });
    assert.ok(gate.hasRoom('a'));
    const one = gate.enter('a');
    assert.ok(one);
    assert.equal(gate.hasRoom('a'), false);
    assert.equal(gate.enter('a'), null);
    const two = gate.enter('b');
    assert.ok(two);
    assert.equal(gate.enter('c'), null);
    one();
    one();
    assert.ok(gate.enter('c'));
  });

  it('daily budget resets at midnight in Zurich', () => {
    let now = Date.parse('2026-10-14T21:50:00Z'); // 23:50 in Zurich
    const budget = new DailyBudget({ bytesPerDay: 100, clock: () => now });
    budget.add(100);
    assert.equal(budget.allows(), false);
    now = Date.parse('2026-10-14T22:00:30Z'); // 00:00:30
    assert.equal(budget.allows(), true);
    assert.equal(dayKey(Date.parse('2026-10-14T22:30:00Z')), '2026-10-15');
    const left = secondsUntilTomorrow(Date.parse('2026-10-14T21:50:00Z'));
    assert.ok(left >= 600 && left <= 660, String(left));
  });

  it('bandwidth limit waits', async () => {
    let now = 0;
    const rate = new ByteRate(1000, { burstSeconds: 0, clock: () => now });
    rate.burst = 0;
    rate.tokens = 0;
    const started = performance.now();
    await rate.take(50);
    assert.ok(performance.now() - started >= 40);
    assert.equal(new ByteRate(0).enabled, false);
  });
});

describe('templates', () => {
  const env = { partials: new Map([['p', compile('<i>{{name}}</i>')]]), asset: (p) => `${p}?v=1` };

  it('escapes values', () => {
    assert.equal(render(compile('{{x}}'), { x: '<script>"' }, env), '&lt;script&gt;&quot;');
    assert.equal(escapeHtml("'"), '&#39;');
  });

  it('renders sections, partials and assets', () => {
    const t = compile('{{#a}}A{{/a}}{{^a}}B{{/a}}{{> p}}{{@asset /x.css}}{{o.k}}');
    assert.equal(render(t, { a: true, name: 'n', o: { k: 'v' } }, env), 'A<i>n</i>/x.css?v=1v');
    assert.equal(render(t, { a: false, name: '<' }, env), 'B<i>&lt;</i>/x.css?v=1');
  });

  it('reports broken templates', () => {
    assert.throws(() => compile('{{#a}}x'));
    assert.throws(() => compile('{{/a}}'));
    assert.throws(() => compile('{{@eval x}}'));
    assert.throws(() => render(compile('{{> missing}}'), {}, env));
  });
});

describe('http helpers', () => {
  it('parses ranges', () => {
    assert.deepEqual(parseRange('bytes=0-9', 100), { start: 0, end: 9 });
    assert.deepEqual(parseRange('bytes=90-', 100), { start: 90, end: 99 });
    assert.deepEqual(parseRange('bytes=-10', 100), { start: 90, end: 99 });
    assert.deepEqual(parseRange('bytes=-500', 100), { start: 0, end: 99 });
    assert.deepEqual(parseRange(`bytes=-${'9'.repeat(40)}`, 100), { start: 0, end: 99 });
    assert.deepEqual(parseRange('bytes=50-500', 100), { start: 50, end: 99 });
    assert.equal(parseRange('bytes=100-', 100), 'unsatisfiable');
    assert.equal(parseRange('bytes=9-1', 100), 'unsatisfiable');
    assert.equal(parseRange('bytes=0-1,5-6', 100), null);
    assert.equal(parseRange('items=0-1', 100), null);
  });

  it('negotiates encodings', () => {
    const entry = { br: Buffer.alloc(1), gzip: Buffer.alloc(1) };
    assert.equal(pickEncoding('gzip, deflate, br', entry), 'br');
    assert.equal(pickEncoding('gzip, br;q=0', entry), 'gzip');
    assert.equal(pickEncoding('identity', entry), '');
    assert.equal(pickEncoding('br', { gzip: Buffer.alloc(1) }), '');
  });

  it('compares ETags', () => {
    assert.ok(notModified({ headers: { 'if-none-match': '"a", W/"b"' } }, '"b"'));
    assert.ok(!notModified({ headers: {} }, '"b"'));
  });

  it('formats in Swiss German', () => {
    assert.equal(formatSize(9_437_184), '9.4 MB');
    assert.equal(formatSize(800), '1 KB');
    assert.equal(humanWait(30), 'einer Minute');
    assert.equal(humanWait(600), '10 Minuten');
    assert.equal(humanWait(3600 * 5), '5 Stunden');
  });
});
