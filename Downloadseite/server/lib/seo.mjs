// What search engines and AI assistants read besides the pages themselves: the structured data
// in the head of both home pages (schema.org, JSON-LD), sitemap.xml, robots.txt and llms.txt.
// Everything is built from the live releases, so a new version shows up here by itself.
//
// While SITE_PASSWORD is set, nobody outside sees the pages: robots.txt then names no sitemap,
// and sitemap.xml and llms.txt need signing in like the pages (see route in app.mjs).

import { englishLabel } from './lang.mjs';

const REPOSITORY = 'https://github.com/SuperStoked13/Wortschatz';
const IMAGE = '/assets/img/og.png';

const TEXTS = Object.freeze({
  de: Object.freeze({
    home: '/',
    whatsNew: '/neuigkeiten',
    language: 'de-CH',
    category: 'Vokabeltrainer',
    description:
      'Wortschatz ist ein kostenloser Vokabeltrainer für Mac und Windows. Neue Wörter kommen zuerst als Multiple Choice, ' +
      'dann schreibst du sie selbst. Ohne Konto, ohne Werbung und offline: Die Lernsets bleiben auf deinem Computer.',
    features: Object.freeze([
      'Lernen: neue Wörter zuerst als Multiple Choice, dann schriftlich; zweimal hintereinander richtig heisst gemeistert',
      'Schreiben: Fehlt nur der Artikel oder das Pronomen, zählt die Antwort; Akzente mit einem Klick',
      'Karteikarten: umdrehen mit der Leertaste, sortieren mit den Pfeiltasten',
      'Prüfung: alle Fragen auf einem Blatt, auf Wunsch mit Zeitlimit, Schweizer Note von 1 bis 6',
      'Import aus Listen, Dateien (auch PDF) und Fotos von Vokabelseiten',
      'Lernsprachen: Französisch, Englisch, Spanisch, Italienisch, Arabisch, Chinesisch (Mandarin), Deutsch und weitere',
      'Ganz mit der Tastatur: Die Hauptaktion jedes Bildschirms liegt auf der Enter-Taste',
      'Backup exportieren und auf einem anderen Computer wieder einlesen',
      'Kostenlos, ohne Konto, ohne Werbung, offline',
    ]),
  }),
  en: Object.freeze({
    home: '/en',
    whatsNew: '/en/whats-new',
    language: 'en',
    category: 'Vocabulary trainer',
    description:
      'Wortschatz is a free vocabulary trainer for Mac and Windows. New words come up as multiple choice first, then you ' +
      'type them yourself. No account, no ads, works offline: your study sets stay on your computer.',
    features: Object.freeze([
      'Learn: new words as multiple choice first, then typed; right twice in a row means mastered',
      'Write: if only the article or pronoun is missing, the answer counts; accents are one click away',
      'Flashcards: flip with the space bar, sort with the arrow keys',
      'Test: all questions on one sheet, optional time limit, Swiss grade from 1 to 6 (6 is best)',
      'Import from lists, files (including PDF) and photos of vocabulary pages',
      'Study languages: French, English, Spanish, Italian, Arabic, Chinese (Mandarin), German and more',
      'Keyboard first: the main action of every screen is on the Return key',
      'Export a backup and load it on another computer',
      'Free, no account, no ads, works offline',
    ]),
  }),
});

const PLATFORM_NAMES = Object.freeze({ mac: 'macOS', windows: 'Windows' });

function live(releases) {
  return ['mac', 'windows'].filter((platform) => releases?.[platform]).map((platform) => ({ platform, ...releases[platform] }));
}

/** The newest release date ("2026-11-25"), or "" without releases. */
export function lastUpdated(releases) {
  return live(releases)
    .map((release) => release.released)
    .filter(Boolean)
    .sort()
    .at(-1) ?? '';
}

/**
 * The structured data of a home page: the website and the app (schema.org SoftwareApplication).
 * `english`: whether a live app also speaks English.
 */
export function structuredData({ releases, origin, lang, english }) {
  const t = TEXTS[lang] ?? TEXTS.de;
  const present = live(releases);
  const label = (text) => (lang === 'en' ? englishLabel(text) : text);
  const systems = present.map((release) => label(release.requirement) || PLATFORM_NAMES[release.platform]);
  const versions = [...new Set(present.map((release) => release.version))];
  const onGitHub = present.filter((release) => release.external && release.url).map((release) => release.url);
  const updated = lastUpdated(releases);

  const app = {
    '@type': 'SoftwareApplication',
    '@id': `${origin}/#app`,
    name: 'Wortschatz',
    url: `${origin}${t.home}`,
    description: t.description,
    applicationCategory: 'EducationalApplication',
    applicationSubCategory: t.category,
    operatingSystem: systems.length ? systems.join(', ') : 'macOS, Windows',
    ...(versions.length === 1 ? { softwareVersion: versions[0] } : {}),
    ...(updated ? { dateModified: updated } : {}),
    downloadUrl: onGitHub.length ? onGitHub : `${origin}${t.home}#download`,
    releaseNotes: `${origin}${t.whatsNew}`,
    image: `${origin}${IMAGE}`,
    inLanguage: english ? ['de', 'en'] : ['de'],
    isAccessibleForFree: true,
    offers: { '@type': 'Offer', price: '0', priceCurrency: 'CHF' },
    featureList: t.features,
    sameAs: [REPOSITORY],
  };
  const website = {
    '@type': 'WebSite',
    '@id': `${origin}/#website`,
    name: 'Wortschatz',
    url: `${origin}/`,
    inLanguage: ['de-CH', 'en'],
    about: { '@id': app['@id'] },
  };
  return { '@context': 'https://schema.org', '@graph': [website, app] };
}

const xml = (text) =>
  String(text).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/**
 * sitemap.xml: every page that may be found, with its other language (hreflang). English is
 * x-default, as in lang.js: visitors whose language is neither German nor English get English.
 * `pages`: [{ de: '/', en: '/en' }, …]
 */
export function sitemapXml({ origin, pages, lastmod = '' }) {
  const urls = [];
  for (const pair of pages) {
    for (const route of [pair.de, pair.en]) {
      urls.push(
        [
          '  <url>',
          `    <loc>${xml(origin + route)}</loc>`,
          ...(lastmod ? [`    <lastmod>${xml(lastmod)}</lastmod>`] : []),
          `    <xhtml:link rel="alternate" hreflang="de" href="${xml(origin + pair.de)}"/>`,
          `    <xhtml:link rel="alternate" hreflang="en" href="${xml(origin + pair.en)}"/>`,
          `    <xhtml:link rel="alternate" hreflang="x-default" href="${xml(origin + pair.en)}"/>`,
          '  </url>',
        ].join('\n'),
      );
    }
  }
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">',
    ...urls,
    '</urlset>',
    '',
  ].join('\n');
}

/** robots.txt: everything but the download links; the sitemap only once the site is public. */
export function robotsText({ origin, sitemap }) {
  return ['User-agent: *', 'Disallow: /dl/', 'Disallow: /download/', ...(sitemap ? ['', `Sitemap: ${origin}/sitemap.xml`] : []), ''].join(
    '\n',
  );
}

/**
 * llms.txt (llmstxt.org): what Wortschatz is, in plain Markdown, for AI assistants that answer
 * questions about it. In English, the language they read best; the pages link both languages.
 */
export function llmsText({ releases, origin, english }) {
  const lines = [
    '# Wortschatz',
    '',
    '> Wortschatz is a free vocabulary trainer (German: Vokabeltrainer) for Mac and Windows. New words come up as',
    '> multiple choice first, then you type them yourself. No account, no ads, works offline: study sets stay on',
    `> the user's computer. ${english ? 'The app is in German and English.' : 'The app is in German.'}`,
    '',
    '## Features',
    '',
    ...TEXTS.en.features.map((feature) => `- ${feature}`),
    '',
    '## Download',
    '',
  ];
  const present = live(releases);
  for (const release of present) {
    const details = [
      `version ${release.version}`,
      englishLabel(release.requirement),
      englishLabel(release.architecture),
      release.released ? `released ${release.released}` : '',
    ].filter(Boolean);
    const where = release.external && release.url ? release.url : `${origin}/en#download`;
    lines.push(`- ${PLATFORM_NAMES[release.platform]}: ${details.join(', ')}. Download: ${where}`);
  }
  if (!present.length) lines.push(`- Mac and Windows versions will be available at ${origin}/en#download`);
  lines.push(
    '',
    'Both apps are free. They are not signed with a paid Apple or Microsoft certificate, so macOS and Windows show',
    `a warning on first launch; the download page explains how to open them (${origin}/en#help-mac, ${origin}/en#help-windows).`,
    '',
    '## Pages',
    '',
    `- [Home page in English](${origin}/en): features, keyboard shortcuts, downloads and first-launch help`,
    `- [Startseite auf Deutsch](${origin}/): the same in German`,
    `- [What's new](${origin}/en/whats-new): changes in each version ([Neuigkeiten](${origin}/neuigkeiten) in German)`,
    `- [Source code on GitHub](${REPOSITORY})`,
    '',
    '## Optional',
    '',
    `- [Privacy](${origin}/en/privacy): the website sets no tracking cookies and the apps keep all data on the computer`,
    `- [Checksums](${origin}/checksums.txt): SHA-256 of the current downloads`,
    '',
  );
  return lines.join('\n');
}
