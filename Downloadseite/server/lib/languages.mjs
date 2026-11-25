// Which languages the live apps speak. Every app is German; English came with the first release
// after Mac 1.6.2 and Windows 1.4 (the versions that were live on 25.11.2026, when English was on
// main for both). Releases are built from main, so every newer version has it – the page switches
// by itself when such a release goes live.

/** The last version of each platform with German only. */
export const GERMAN_ONLY_UP_TO = Object.freeze({ mac: '1.6.2', windows: '1.4' });

/** Compares "1.6.2" and "1.10" by their numbers (missing parts count as 0); < 0, 0 or > 0. */
export function compareVersions(a, b) {
  const parts = (v) => String(v ?? '').split(/[^0-9]+/).filter(Boolean).map(Number);
  const x = parts(a);
  const y = parts(b);
  for (let i = 0; i < Math.max(x.length, y.length); i += 1) {
    const d = (x[i] ?? 0) - (y[i] ?? 0);
    if (d !== 0) return d;
  }
  return 0;
}

/** Whether this platform's version also speaks English. */
export function speaksEnglish(platform, version) {
  const last = GERMAN_ONLY_UP_TO[platform];
  return Boolean(last && version) && compareVersions(version, last) > 0;
}

const TEXTS = Object.freeze({
  de: Object.freeze({
    both: 'Deutsch und Englisch',
    german: 'Deutsch',
    // The German page says nothing while every app is German only (that goes without saying).
    allNote: 'Die App gibt es auf Deutsch und Englisch.',
    macNote: 'Die Mac-App gibt es auch auf Englisch.',
    windowsNote: 'Die Windows-App gibt es auch auf Englisch.',
    noneNote: '',
    allText: 'Die App ist auf Deutsch (mit Schweizer Schreibweise) und Englisch: Sie folgt der Sprache deines Computers, unter Einstellungen › Allgemein › Sprache wählst du selbst.',
    macText: 'Die Mac-App ist auf Deutsch (mit Schweizer Schreibweise) und Englisch, die Windows-App auf Deutsch.',
    windowsText: 'Die Windows-App ist auf Deutsch (mit Schweizer Schreibweise) und Englisch, die Mac-App auf Deutsch.',
    noneText: '',
  }),
  en: Object.freeze({
    both: 'German and English',
    german: 'German',
    allNote: 'The app is in German and English.',
    macNote: 'The app is in German; the Mac app is also in English.',
    windowsNote: 'The app is in German; the Windows app is also in English.',
    noneNote: 'The app is in German.',
    allText: 'The app is in German (with Swiss spelling) and English: it follows your computer’s language, and you can choose under Settings › General › Language.',
    macText: 'The Mac app is in German (with Swiss spelling) and English, the Windows app in German.',
    windowsText: 'The Windows app is in German (with Swiss spelling) and English, the Mac app in German.',
    noneText: 'The app itself is in German, with Swiss spelling.',
  }),
});

/**
 * The languages of the live apps for the templates: per platform a label ("Deutsch und Englisch"),
 * and for the page a short note (hero) and a sentence (download section) – all, some or none in
 * English. Platforms without a download don't count.
 */
export function languagesView(releases, lang) {
  const t = TEXTS[lang] ?? TEXTS.de;
  const english = {};
  for (const platform of Object.keys(GERMAN_ONLY_UP_TO)) {
    const release = releases?.[platform];
    if (release) english[platform] = speaksEnglish(platform, release.version);
  }
  const live = Object.keys(english);
  const withEnglish = live.filter((platform) => english[platform]);
  let key = 'none';
  if (live.length > 0 && withEnglish.length === live.length) key = 'all';
  else if (withEnglish.length === 1) key = withEnglish[0];
  return {
    english: withEnglish.length > 0,
    note: t[`${key}Note`],
    text: t[`${key}Text`],
    label: (platform) => (english[platform] ? t.both : t.german),
  };
}
