// Which languages the page says the apps speak (languages.mjs): German only up to Mac 1.6.2 and
// Windows 1.4, German and English from the next release on – without changing the page by hand.

import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createApp } from '../lib/app.mjs';
import { loadConfig } from '../lib/config.mjs';
import { createHttpServer } from '../lib/http.mjs';
import { compareVersions, languagesView, speaksEnglish } from '../lib/languages.mjs';
import { createLogger } from '../lib/log.mjs';

const PUBLIC_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'public');

describe('app languages', () => {
  it('compares versions by their numbers', () => {
    assert.ok(compareVersions('1.10', '1.9') > 0);
    assert.equal(compareVersions('1.4', '1.4.0'), 0);
    assert.ok(compareVersions('1.6.3', '1.6.2') > 0);
    assert.ok(compareVersions('1.6', '1.6.2') < 0);
  });

  it('English from the first release after Mac 1.6.2 and Windows 1.4', () => {
    assert.equal(speaksEnglish('mac', '1.6.2'), false);
    assert.equal(speaksEnglish('mac', '1.6.3'), true);
    assert.equal(speaksEnglish('mac', '1.7'), true);
    assert.equal(speaksEnglish('windows', '1.4'), false);
    assert.equal(speaksEnglish('windows', '1.4.1'), true);
    assert.equal(speaksEnglish('windows', '1.5'), true);
    assert.equal(speaksEnglish('linux', '9.0'), false);
  });

  it('says all, one or none – in both languages', () => {
    const live = (mac, windows) => ({ mac: mac && { platform: 'mac', version: mac }, windows: windows && { platform: 'windows', version: windows } });
    const none = languagesView(live('1.6.2', '1.4'), 'en');
    assert.equal(none.english, false);
    assert.equal(none.note, 'The app is in German.');
    assert.equal(none.label('mac'), 'German');
    assert.equal(languagesView(live('1.6.2', '1.4'), 'de').note, '');

    const mac = languagesView(live('1.7', '1.4'), 'en');
    assert.equal(mac.note, 'The app is in German; the Mac app is also in English.');
    assert.equal(mac.label('mac'), 'German and English');
    assert.equal(mac.label('windows'), 'German');
    assert.equal(languagesView(live('1.7', '1.4'), 'de').note, 'Die Mac-App gibt es auch auf Englisch.');

    const all = languagesView(live('1.7', '1.5'), 'de');
    assert.equal(all.note, 'Die App gibt es auf Deutsch und Englisch.');
    assert.equal(all.label('windows'), 'Deutsch und Englisch');
    // Only one platform with a download: it alone decides.
    assert.equal(languagesView(live(null, '1.5'), 'en').note, 'The app is in German and English.');
  });

  it('the pages follow the live releases', async () => {
    for (const [mac, windows, en, de] of [
      ['1.6.2', '1.4', /free and without an account\. The app is in German\./, null],
      ['1.7', '1.5', /The app is in German and English\./, /Die App gibt es auf Deutsch und Englisch\./],
    ]) {
      const root = await fs.mkdtemp(path.join(os.tmpdir(), 'wortschatz-lang-'));
      const releases = path.join(root, 'releases');
      await fs.mkdir(releases);
      await fs.writeFile(path.join(releases, `Wortschatz-${mac}-macOS.dmg`), Buffer.alloc(2000, 1));
      await fs.writeFile(path.join(releases, `Wortschatz-${windows}-Windows.exe`), Buffer.alloc(2000, 2));
      await fs.writeFile(path.join(releases, 'mac.json'), JSON.stringify({ file: `Wortschatz-${mac}-macOS.dmg`, version: mac }));
      await fs.writeFile(path.join(releases, 'windows.json'), JSON.stringify({ file: `Wortschatz-${windows}-Windows.exe`, version: windows }));
      const config = loadConfig({
        SITE_ORIGIN: 'https://wortschatz.test',
        PUBLIC_DIR,
        RELEASES_DIR: releases,
        DATA_DIR: path.join(root, 'data'),
        TRUST_PROXY: 'loopback',
        ACCESS_LOG: '0',
      });
      const app = await createApp(config, createLogger('silent'));
      const server = createHttpServer(app.handle);
      await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
      const get = (target) =>
        new Promise((resolve, reject) => {
          const req = http.request(
            { host: '127.0.0.1', port: server.address().port, path: target, headers: { Host: 'wortschatz.test', 'X-Forwarded-For': '203.0.113.77' } },
            (res) => {
              const chunks = [];
              res.on('data', (c) => chunks.push(c));
              res.on('end', () => resolve(Buffer.concat(chunks).toString()));
            },
          );
          req.on('error', reject);
          req.end();
        });
      try {
        const english = await get('/en');
        const german = await get('/');
        assert.match(english, en);
        assert.match(english, new RegExp(`<dt>Language</dt><dd>${speaksEnglish('mac', mac) ? 'German and English' : 'German'}</dd>`));
        assert.match(german, new RegExp(`<dt>Sprache</dt><dd>${speaksEnglish('windows', windows) ? 'Deutsch und Englisch' : 'Deutsch'}</dd>`));
        if (de) assert.match(german, de);
        else assert.doesNotMatch(german, /Englisch\./);
        assert.doesNotMatch(english + german, /\{\{/);
      } finally {
        server.closeAllConnections();
        await new Promise((resolve) => server.close(resolve));
        await app.close();
        await fs.rm(root, { recursive: true, force: true });
      }
    }
  });
});
