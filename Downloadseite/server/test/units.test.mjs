// Unit tests for the building blocks: `node --test test/` in the server folder.

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { loadConfig } from '../lib/config.mjs';
import { anonymizeIp, buildTrust, clientIp, expandIpv6, ipKey, isLoopback, networkKey, normalizeIp } from '../lib/net.mjs';
import { LinkSigner } from '../lib/tokens.mjs';
import { ConcurrencyGate, DailyBudget, DailyQuota, TokenBucket, WindowCounter, dayKey, downloadFloor } from '../lib/limits.mjs';
import { compile, escapeHtml, render } from '../lib/templates.mjs';
import { notModified, parseRange, pickEncoding } from '../lib/http.mjs';
import { formatSize, githubReleaseUrl } from '../lib/releases.mjs';
import { ByteRate } from '../lib/throttle.mjs';
import { changelogView, compareVersions, parseChangelog } from '../lib/changelog.mjs';
import { englishLabel, errorText, formatDate, languageOfPath, message, preferredLanguage } from '../lib/lang.mjs';

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
    assert.throws(() => loadConfig({ SITE_PASSWORD: 'kurz' }));
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

  it('counts a whole /48 as one for password guesses', () => {
    assert.equal(networkKey('2001:db8:1:100::1'), '2001:0db8:0001::/48');
    assert.equal(networkKey('2001:db8:1:100::1'), networkKey('2001:db8:1:ff00::2'));
    assert.notEqual(networkKey('2001:db8:1::1'), networkKey('2001:db8:2::1'));
    assert.equal(networkKey('203.0.113.4'), '203.0.113.4');
    assert.equal(networkKey(''), 'unknown');
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

  it('token bucket: peek answers like take, but takes nothing', () => {
    let now = 0;
    const bucket = new TokenBucket({ capacity: 2, perSecond: 1, clock: () => now });
    assert.ok(bucket.peek('a').ok, 'unknown key');
    assert.equal(bucket.buckets.size, 0, 'peeking stores nothing');
    bucket.take('a');
    bucket.take('a');
    assert.deepEqual(bucket.peek('a'), { ok: false, retryAfter: 1 });
    assert.deepEqual(bucket.peek('a'), bucket.take('a'));
    now = 1000;
    assert.ok(bucket.peek('a').ok, 'refilled');
    assert.ok(bucket.take('a').ok);
    assert.equal(bucket.peek('a').ok, false, 'the token was there only once');
  });

  it('token bucket: spending may run into debt, which peek sees until it is paid off', () => {
    let now = 0;
    const bucket = new TokenBucket({ capacity: 10, perSecond: 5, clock: () => now });
    bucket.spend('a', 30);
    assert.deepEqual(bucket.peek('a'), { ok: false, retryAfter: 5 }, '-20 tokens: 21 to go to the next whole one');
    now = 4000;
    assert.equal(bucket.peek('a').ok, false, 'the debt is paid off, but no token is there yet');
    now = 5000;
    assert.equal(bucket.peek('a').ok, true);
    const none = new TokenBucket({ capacity: Infinity, perSecond: 0, clock: () => now });
    none.spend('a', 1e12);
    assert.equal(none.peek('a').ok, true, 'without a limit nothing ever runs out');
    assert.equal(none.peek('a', none.capacity - 100).ok, true, 'and everybody counts as having used little');
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

  it('download floor: half a fair share when slots run short, otherwise the configured floor', () => {
    const base = { floor: 16_000, laneRate: 6_250_000, perDownload: 0, slots: 200 };
    assert.equal(downloadFloor({ ...base, active: 10 }), 16_000, 'plenty of room');
    assert.equal(downloadFloor({ ...base, floor: 0, active: 200 }), 0, 'no check configured');
    assert.equal(downloadFloor({ ...base, active: 149 }), 16_000);
    assert.equal(downloadFloor({ ...base, active: 150 }), 6_250_000 / 150 / 2, 'three quarters full: real bandwidth for a slot');
    assert.equal(downloadFloor({ ...base, slots: 40, active: 40 }), 6_250_000 / 40 / 2);
    assert.equal(downloadFloor({ ...base, laneRate: 100_000, active: 10 }), 5_000, 'never more than half a share');
    assert.equal(downloadFloor({ ...base, active: 150, perDownload: 10_000 }), 5_000, 'a download limit lowers it');
    assert.equal(downloadFloor({ ...base, laneRate: 0, active: 200 }), 16_000, 'no bandwidth limit');
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

  it('repeats a block for each item of a list, with the outer values still visible', () => {
    const t = compile('{{#list}}[{{n}}{{#flag}}!{{/flag}}{{o.k}}]{{/list}}{{^list}}leer{{/list}}');
    assert.equal(render(t, { list: [{ n: 1, flag: true }, { n: '<' }], o: { k: 'v' } }, env), '[1!v][&lt;v]');
    assert.equal(render(t, { list: [] }, env), 'leer');
  });

  it('reports broken templates', () => {
    assert.throws(() => compile('{{#a}}x'));
    assert.throws(() => compile('{{/a}}'));
    assert.throws(() => compile('{{@eval x}}'));
    assert.throws(() => render(compile('{{> missing}}'), {}, env));
  });
});

describe('changelog', () => {
  const SOURCE = [
    '# Neuigkeiten',
    '<!-- Erklärung',
    '## 9.9 – nicht beachten',
    '- Neu: im Kommentar -->',
    '',
    '## Nächste Version',
    '',
    '- Neu: Arabisch und Mandarin.',
    '- Behoben (Mac): Nur auf dem Mac,',
    '  über zwei Zeilen.',
    '- Verbessert (Windows und Mac): Beide.',
    '',
    '## 1.1 – 2026-10-20',
    'Kleine Version.',
    '- Behoben (Windows): Ein Fehler.',
    '- Ohne Art.',
    '',
    '## 1.0 – 14.10.2026',
    '',
  ].join('\n');
  const releases = (mac, windows) => ({
    mac: mac ? { version: mac, released: '2026-11-02' } : null,
    windows: windows ? { version: windows, released: '2026-11-01' } : null,
  });

  it('compares version numbers', () => {
    assert.equal(compareVersions('1.10', '1.9'), 1);
    assert.equal(compareVersions('1.0', '1'), 0);
    assert.equal(compareVersions('1.0.2', '1.1'), -1);
  });

  it('reads the file and skips comments', () => {
    const log = parseChangelog(SOURCE);
    assert.deepEqual(
      log.upcoming.map((c) => [c.kind, c.platforms.join(), c.text]),
      [
        ['neu', '', 'Arabisch und Mandarin.'],
        ['behoben', 'mac', 'Nur auf dem Mac, über zwei Zeilen.'],
        ['verbessert', '', 'Beide.'],
      ],
    );
    assert.deepEqual(log.versions.map((v) => [v.version, v.date, v.changes.length, v.note]), [
      ['1.1', '2026-10-20', 2, 'Kleine Version.'],
      ['1.0', '2026-10-14', 0, ''],
    ]);
    assert.deepEqual(log.problems.map((p) => p.line), [16]);
    assert.equal(log.versions[0].changes[1].text, 'Ohne Art.');
  });

  it('never fails on a broken file', () => {
    const log = parseChangelog('## Irgendwas\n- Neu: weg\n## 1.2 – 2026-13-45\n- Neu (Linux): unbekannt\n');
    assert.equal(log.versions.length, 1);
    assert.equal(log.versions[0].date, '');
    assert.equal(log.versions[0].changes[0].kind, '');
    assert.equal(log.problems.length, 4);
    assert.deepEqual(parseChangelog('').versions, []);
  });

  it('shows coming changes until a newer app is online, and hides the empty starting point', () => {
    const view = changelogView(parseChangelog(SOURCE), releases('1.1', '1.1'));
    assert.equal(view.upcoming.changes.length, 3);
    assert.deepEqual(view.versions.map((v) => v.version), ['1.1']);
    assert.equal(view.versions[0].dateLabel, '20. Oktober 2026');
    assert.equal(view.versions[0].changes[0].platformLabel, 'Windows');
    assert.equal(view.versions[0].changes[0].kindLabel, 'Behoben');
    assert.equal(view.latest.version, '1.1');
  });

  it('counts unnumbered changes as released once a newer app is online for their platform', () => {
    const windowsOnly = changelogView(parseChangelog(SOURCE), releases('1.1', '1.2'));
    assert.deepEqual(windowsOnly.versions.map((v) => v.version), ['1.2', '1.1']);
    assert.deepEqual(windowsOnly.versions[0].changes.map((c) => c.text), ['Arabisch und Mandarin.', 'Beide.']);
    assert.equal(windowsOnly.versions[0].dateLabel, '1. November 2026');
    assert.deepEqual(windowsOnly.upcoming.changes.map((c) => c.platformLabel), ['Mac']);

    const both = changelogView(parseChangelog(SOURCE), releases('1.2', '1.2'));
    assert.equal(both.upcoming, null);
    assert.equal(both.versions[0].changes.length, 3);
  });

  it('reads the English line of an entry and shows it on the English page', () => {
    const source = [
      '## Nächste Version',
      '- Neu: Arabisch und Mandarin,',
      '  über zwei Zeilen.',
      '  EN: Arabic and Mandarin,',
      '  over two lines.',
      '- Behoben (Mac): Ohne Englisch.',
      'EN: nicht eingerückt',
      '## 1.0 – 2026-10-14',
    ].join('\n');
    const log = parseChangelog(source);
    assert.equal(log.upcoming[0].text, 'Arabisch und Mandarin, über zwei Zeilen.');
    assert.equal(log.upcoming[0].textEn, 'Arabic and Mandarin, over two lines.');
    assert.deepEqual(log.problems.map((p) => p.line), [7]);
    const en = changelogView(log, releases('1.0', '1.0'), 'en').upcoming.changes;
    assert.deepEqual(en.map((c) => [c.kindLabel, c.text, c.textLang]), [
      ['New', 'Arabic and Mandarin, over two lines.', ''],
      ['Fixed', 'Ohne Englisch.', 'de'],
    ]);
    assert.equal(changelogView(log, releases('1.0', '1.0')).upcoming.changes[0].text, 'Arabisch und Mandarin, über zwei Zeilen.');
    assert.equal(changelogView(parseChangelog(SOURCE), releases('1.1', '1.1'), 'en').versions[0].dateLabel, '20 October 2026');
  });

  it('is empty without entries', () => {
    const view = changelogView(parseChangelog('## Nächste Version\n\n## 1.0 – 2026-10-14\n'), releases('1.0', '1.0'));
    assert.equal(view.any, false);
    assert.equal(view.latest, null);
    // Without a starting point nothing is ever counted as released.
    assert.equal(changelogView(parseChangelog('## Nächste Version\n- Neu: X\n'), releases('1.0', '1.0')).upcoming.changes.length, 1);
  });
});

describe('languages', () => {
  it('picks German or English like lang.js: whichever the browser lists first', () => {
    assert.equal(preferredLanguage(undefined), 'de', 'no header: German');
    assert.equal(preferredLanguage(''), 'de');
    assert.equal(preferredLanguage('de-CH,de;q=0.9,en;q=0.8'), 'de');
    assert.equal(preferredLanguage('en-US,en;q=0.9,de;q=0.8'), 'en');
    assert.equal(preferredLanguage('fr-CH, fr;q=0.9, de;q=0.7, en;q=0.8'), 'en', 'by weight, not order');
    assert.equal(preferredLanguage('fr-CH,fr;q=0.9,de;q=0.8'), 'de');
    assert.equal(preferredLanguage('ja,zh;q=0.5'), 'en', 'neither: English');
    assert.equal(preferredLanguage('en;q=0,de'), 'de', 'q=0 means not wanted');
    assert.equal(preferredLanguage('*'), 'en');
  });

  it('knows the English pages by their path', () => {
    assert.equal(languageOfPath('/en'), 'en');
    assert.equal(languageOfPath('/en/whats-new'), 'en');
    assert.equal(languageOfPath('/english'), 'de');
    assert.equal(languageOfPath('/'), 'de');
  });

  it('translates the labels of the release manifests and formats dates', () => {
    assert.equal(englishLabel('macOS 26 oder neuer'), 'macOS 26 or later');
    assert.equal(englishLabel('Windows 10 oder 11'), 'Windows 10 or 11');
    assert.equal(englishLabel('Apple Silicon und Intel'), 'Apple Silicon and Intel');
    assert.equal(englishLabel('64 Bit (x64)'), '64-bit (x64)');
    assert.equal(formatDate('2026-10-20', 'en'), '20 October 2026');
    assert.equal(formatDate('2026-10-20'), '20. Oktober 2026');
    assert.equal(formatDate('', 'en'), '');
  });

  it('has every message in both languages', () => {
    for (const status of [400, 401, 403, 404, 405, 410, 413, 414, 415, 421, 429, 500, 503]) {
      assert.notDeepEqual(errorText(status, 'en'), errorText(status, 'de'), String(status));
    }
    for (const key of ['busy', 'refused', 'notYet', 'invalidLink', 'expired', 'otherDevice', 'newVersion', 'used', 'replacing']) {
      const values = { platform: 'macOS', seconds: 120 };
      assert.ok(message(key, 'en', values).message, key);
      assert.notEqual(message(key, 'en', values).title, message(key, 'de', values).title, key);
    }
    assert.match(message('expired', 'en', { seconds: 120 }).message, /2 minutes/);
    assert.match(message('expired', 'de', { seconds: 60 }).message, /1 Minute\b/);
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
    assert.equal(pickEncoding(`br${','.repeat(300)}`, entry), '', 'a long list is not taken apart');
  });

  it('compares ETags', () => {
    assert.ok(notModified({ headers: { 'if-none-match': '"a", W/"b"' } }, '"b"'));
    assert.ok(!notModified({ headers: {} }, '"b"'));
    assert.ok(!notModified({ headers: { 'if-none-match': `"b"${','.repeat(2000)}` } }, '"b"'), 'a long list is not taken apart');
  });

  it('formats in Swiss German', () => {
    assert.equal(formatSize(9_437_184), '9.4 MB');
    assert.equal(formatSize(800), '1 KB');
  });
});

describe('githubReleaseUrl', () => {
  const repo = 'SuperStoked13/Wortschatz';
  const file = 'Wortschatz-1.5-Windows.exe';
  const good = `https://github.com/SuperStoked13/Wortschatz/releases/download/v1.5/${file}`;

  it('takes a release file of the repository as GitHub writes it', () => {
    assert.equal(githubReleaseUrl(good, repo, file), good);
    assert.equal(githubReleaseUrl(good, 'superstoked13/wortschatz', file), good);
    assert.equal(githubReleaseUrl(good.replace('v1.5', 'v1.6.2-mac'), repo, file), good.replace('v1.5', 'v1.6.2-mac'));
  });

  it('refuses everything else', () => {
    for (const value of [
      good.replace('https:', 'http:'),
      good.replace('github.com', 'github.com.example.org'),
      good.replace('github.com', 'GITHUB.com'),
      good.replace('github.com', 'github.com:443'),
      good.replace('https://', 'https://user@'),
      good.replace('SuperStoked13', 'Other'),
      good.replace('/Wortschatz/', '/Wortschatz2/'),
      good.replace('/releases/download/', '/raw/main/'),
      good.replace('/v1.5/', '/v1.5/sub/'),
      good.replace('/v1.5/', '/../'),
      good.replace('/v1.5/', '/%2e%2e/'),
      good.replace('/v1.5/', '/-x/'),
      `${good}?download=1`,
      `${good}#x`,
      good.replace(file, 'Wortschatz-1.4-Windows.exe'),
      `${good} `,
      'javascript:alert(1)',
      '',
      `https://github.com/SuperStoked13/Wortschatz/releases/download/v1.5/${'a'.repeat(400)}`,
    ]) {
      assert.equal(githubReleaseUrl(value, repo, file), '', value);
    }
    assert.equal(githubReleaseUrl(42, repo, file), '');
    assert.equal(githubReleaseUrl(good, '', file), '');
  });
});

describe('config: DOWNLOAD_REPO', () => {
  it('defaults to the public repository and checks the form', () => {
    assert.equal(loadConfig({}).downloadRepo, 'SuperStoked13/Wortschatz');
    assert.equal(loadConfig({ DOWNLOAD_REPO: 'a-b/c.d_e' }).downloadRepo, 'a-b/c.d_e');
    for (const value of ['nur-ein-teil', 'a/b/c', 'https://github.com/a/b', '-a/b', 'a/..', 'a b/c']) {
      assert.throws(() => loadConfig({ DOWNLOAD_REPO: value }), /DOWNLOAD_REPO/, value);
    }
  });
});

describe('config: LISTEN_SOCKET', () => {
  it('is off by default and takes only an absolute path', () => {
    assert.equal(loadConfig({}).socket, '');
    assert.equal(loadConfig({ LISTEN_SOCKET: '/run/wortschatz//web.sock' }).socket, '/run/wortschatz/web.sock');
    for (const value of ['web.sock', './web.sock', `/${'x'.repeat(120)}`]) {
      assert.throws(() => loadConfig({ LISTEN_SOCKET: value }), /LISTEN_SOCKET/, value);
    }
  });
});

describe('clientIp over the proxy socket', () => {
  const trust = buildTrust('private');
  const over = (header) => ({ socket: {}, headers: header === undefined ? {} : { 'x-forwarded-for': header } });

  it('takes the address the proxy names, read from the right', () => {
    assert.equal(clientIp(over('203.0.113.7'), trust, { proxySocket: true }), '203.0.113.7');
    assert.equal(clientIp(over('198.51.100.1, 203.0.113.7'), trust, { proxySocket: true }), '203.0.113.7');
    assert.equal(clientIp(over('203.0.113.7, 172.20.0.1'), trust, { proxySocket: true }), '203.0.113.7');
  });

  it('is nobody in particular without a usable header', () => {
    assert.equal(clientIp(over(undefined), trust, { proxySocket: true }), '');
    assert.equal(clientIp(over('kaputt'), trust, { proxySocket: true }), '');
    assert.equal(ipKey(''), 'unknown');
  });

  it('changes nothing without the socket', () => {
    assert.equal(clientIp(over('203.0.113.7'), trust), '');
  });
});
