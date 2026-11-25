// The update list on /neuigkeiten, read from public/_neuigkeiten.md (written by hand or by Claude
// whenever an app gets something new; the format is described at the top of that file):
//
//   ## Nächste Version              changes that are done but not released yet
//   - Neu: …                        Neu | Verbessert | Behoben, then the text
//   - Behoben (Windows): …          a platform in brackets when only one app changes
//   ## 1.1 – 2026-10-20             a released version (tools/release-*.sh writes these)
//   ## 1.0 – 2026-10-14             a version without entries: only the starting point, not shown
//   - Neu: Arabisch …               an indented line «EN: …» under an entry is its English text for
//     EN: Arabic …                  /en/whats-new (without one, the English page shows the German text)
//
// Lenient on purpose: a typo never takes the site down. Lines it cannot read are skipped and
// reported as problems (the server logs them).

import { formatDate } from './lang.mjs';

const KINDS = Object.freeze({ neu: 'Neu', verbessert: 'Verbessert', behoben: 'Behoben' });
const KINDS_EN = Object.freeze({ neu: 'New', verbessert: 'Improved', behoben: 'Fixed' });
const PLATFORM_NAMES = Object.freeze({ mac: 'mac', macos: 'mac', windows: 'windows' });
const PLATFORM_LABELS = Object.freeze({ mac: 'Mac', windows: 'Windows' });
const ALL_PLATFORMS = Object.freeze(['mac', 'windows']);

const UPCOMING_RE = /^n(?:ä|ae)chste\s+version$/i;
const VERSION_RE = /^v?(\d+(?:\.\d+){0,3})\b\s*(.*)$/;
const ISO_DATE_RE = /\b(\d{4})-(\d{2})-(\d{2})\b/;
const SWISS_DATE_RE = /\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b/;
const ITEM_RE = /^[-*]\s+(.*)$/;
const KIND_RE = /^([\p{L}]+)\s*(?:\(([^)]*)\))?\s*:\s*(.+)$/u;
const ENGLISH_RE = /^en\s*:\s*(.*)$/i;

/** Compares "1.10" and "1.9.2" by their numbers; missing parts count as 0. */
export function compareVersions(a, b) {
  const pa = String(a).split('.');
  const pb = String(b).split('.');
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (Number.parseInt(pa[i], 10) || 0) - (Number.parseInt(pb[i], 10) || 0);
    if (diff !== 0) return Math.sign(diff);
  }
  return 0;
}

function isoDate(text) {
  let match = ISO_DATE_RE.exec(text);
  let parts = match ? [match[1], match[2], match[3]] : null;
  if (!parts) {
    match = SWISS_DATE_RE.exec(text);
    if (match) parts = [match[3], match[2].padStart(2, '0'), match[1].padStart(2, '0')];
  }
  if (!parts) return '';
  const iso = parts.join('-');
  const date = new Date(`${iso}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().startsWith(iso) ? iso : '';
}

export function dateLabel(iso, lang = 'de') {
  return formatDate(iso, lang);
}

/** "Neu (Mac): Text" → { kind, platforms, text }. Unknown kinds or platforms stay part of the text. */
function parseChange(line) {
  const match = KIND_RE.exec(line);
  const kind = match?.[1].toLowerCase();
  if (!match || !Object.hasOwn(KINDS, kind)) return { change: { kind: '', platforms: [], text: line }, known: false };
  const platforms = [];
  if (match[2] !== undefined) {
    for (const word of match[2].split(/\s*(?:,|\/|\bund\b|&)\s*/i).filter(Boolean)) {
      const name = word.toLowerCase();
      if (!Object.hasOwn(PLATFORM_NAMES, name)) return { change: { kind: '', platforms: [], text: line }, known: false };
      const platform = PLATFORM_NAMES[name];
      if (!platforms.includes(platform)) platforms.push(platform);
    }
  }
  // Both apps named is the same as none named.
  return { change: { kind, platforms: platforms.length === ALL_PLATFORMS.length ? [] : platforms, text: match[3].trim() }, known: true };
}

/**
 * @returns {{ upcoming: Array<object>, versions: Array<{version: string, date: string, note: string, changes: Array<object>}>, problems: Array<{line: number, message: string}> }}
 */
export function parseChangelog(source) {
  // Comments vanish, but keep their line breaks so the line numbers stay right.
  const lines = String(source ?? '')
    .replace(/<!--[\s\S]*?-->/g, (comment) => comment.replace(/[^\n]/g, ''))
    .split(/\r?\n/);
  const result = { upcoming: [], versions: [], problems: [] };
  let section; // { changes, note } of the current heading; undefined before the first one, null after an unknown one
  let last = null; // the change that indented lines continue
  let field = 'text'; // and which of its texts: the German one or, after «EN:», the English one
  const problem = (index, message) => result.problems.push({ line: index + 1, message });

  lines.forEach((raw, index) => {
    const line = raw.trim();
    if (!line) return;
    const heading = /^(#+)\s+(.*)$/.exec(line);
    if (heading) {
      last = null;
      if (heading[1] !== '##') return; // the title and smaller headings are just for reading the file
      const title = heading[2].trim();
      if (UPCOMING_RE.test(title)) {
        section = { changes: result.upcoming, note: [] };
        return;
      }
      const version = VERSION_RE.exec(title);
      if (!version) {
        section = null;
        problem(index, `Unbekannte Überschrift «${title}» (erwartet: «Nächste Version» oder eine Versionsnummer).`);
        return;
      }
      const entry = { version: version[1], date: isoDate(version[2]), note: [], changes: [] };
      if (version[2] && !entry.date && /\d/.test(version[2])) problem(index, `Datum in «${title}» nicht lesbar (so: 2026-10-20).`);
      result.versions.push(entry);
      section = entry;
      return;
    }
    if (!section) {
      if (section === null) problem(index, 'Zeile unter einer unbekannten Überschrift übersprungen.');
      return;
    }
    const item = ITEM_RE.exec(line);
    if (item) {
      const { change, known } = parseChange(item[1].trim());
      if (!known) problem(index, `Art fehlt oder unbekannt (Neu, Verbessert, Behoben; Plattform Mac oder Windows): «${item[1].trim()}».`);
      section.changes.push(change);
      last = change;
      field = 'text';
      return;
    }
    if (last && /^\s/.test(raw)) {
      const english = ENGLISH_RE.exec(line);
      if (english) {
        field = 'textEn';
        last.textEn = english[1].trim();
        if (!last.textEn) problem(index, 'Leere Zeile «EN:».');
        return;
      }
      last[field] = last[field] ? `${last[field]} ${line}` : line;
      return;
    }
    if (last && ENGLISH_RE.test(line)) problem(index, '«EN:» gehört eingerückt unter seinen Eintrag.');
    last = null;
    section.note.push(line);
  });

  for (const entry of result.versions) entry.note = entry.note.join(' ');
  return result;
}

function changeView(change, lang) {
  const english = lang === 'en';
  return {
    kind: change.kind,
    kindLabel: (english ? KINDS_EN : KINDS)[change.kind] ?? '',
    platformLabel: change.platforms.map((platform) => PLATFORM_LABELS[platform]).join(', '),
    text: english && change.textEn ? change.textEn : change.text,
    // The English page falls back to the German text; screen readers should read it as German.
    textLang: english && !change.textEn ? 'de' : '',
  };
}

/**
 * What the template shows: released versions (newest first, the empty starting point left out) and
 * what is still coming. Changes under «Nächste Version» count as released once a newer app than the
 * newest version in the file is online for their platform (when nobody numbered them at release).
 * @param {ReturnType<typeof parseChangelog>} changelog
 * @param {{mac?: {version: string, released: string} | null, windows?: {version: string, released: string} | null}} releases
 * @param {'de' | 'en'} lang
 */
export function changelogView(changelog, releases = {}, lang = 'de') {
  const versions = changelog.versions.map((entry) => ({ ...entry, changes: [...entry.changes] }));
  const newest = versions.reduce((max, entry) => (!max || compareVersions(entry.version, max) > 0 ? entry.version : max), '');
  const newer = ALL_PLATFORMS.map((platform) => releases[platform]).filter(
    (release) => release && newest && compareVersions(release.version, newest) > 0,
  );
  const newerPlatforms = new Set(ALL_PLATFORMS.filter((platform) => newer.includes(releases[platform])));

  const shipped = [];
  const coming = [];
  for (const change of changelog.upcoming) {
    const platforms = change.platforms.length ? change.platforms : ALL_PLATFORMS;
    (platforms.some((platform) => newerPlatforms.has(platform)) ? shipped : coming).push(change);
  }
  if (shipped.length) {
    const live = newer.reduce((max, release) => (!max || compareVersions(release.version, max.version) > 0 ? release : max), null);
    versions.push({ version: live.version, date: live.released || '', note: '', changes: shipped });
  }

  const releasedOn = (version) =>
    ALL_PLATFORMS.map((platform) => releases[platform]).find((release) => release && release.version === version)?.released || '';
  const shown = versions
    .filter((entry) => entry.changes.length || entry.note)
    .sort((a, b) => compareVersions(b.version, a.version))
    .map((entry) => {
      const date = entry.date || releasedOn(entry.version);
      return {
        version: entry.version,
        anchor: `v${entry.version.replaceAll('.', '-')}`,
        date,
        dateLabel: dateLabel(date, lang),
        note: entry.note,
        hasChanges: entry.changes.length > 0,
        changes: entry.changes.map((change) => changeView(change, lang)),
      };
    });

  return {
    any: shown.length > 0 || coming.length > 0,
    upcoming: coming.length ? { changes: coming.map((change) => changeView(change, lang)) } : null,
    versions: shown,
    latest: shown[0] ?? null,
  };
}
