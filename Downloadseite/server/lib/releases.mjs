// The downloadable files. Each platform has a small manifest in the releases folder
// (mac.json, windows.json, written by tools/release-*.sh) that names its file. The server
// checks the file, measures it and computes its SHA-256 once per version.

import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';

export const PLATFORMS = Object.freeze({
  mac: Object.freeze({ id: 'mac', label: 'macOS', manifest: 'mac.json' }),
  windows: Object.freeze({ id: 'windows', label: 'Windows', manifest: 'windows.json' }),
});

const CONTENT_TYPES = Object.freeze({
  '.dmg': 'application/x-apple-diskimage',
  '.zip': 'application/zip',
  '.pkg': 'application/octet-stream',
  '.exe': 'application/vnd.microsoft.portable-executable',
  '.msi': 'application/x-msi',
});

const FILE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,150}$/;
const VERSION_RE = /^[0-9A-Za-z][0-9A-Za-z.+-]{0,31}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TEXT_RE = /^[\p{L}\p{N} .,:+()/_-]{1,80}$/u;
const MAX_MANIFEST_BYTES = 16 * 1024;

const sizeFormat = new Intl.NumberFormat('de-CH', { minimumFractionDigits: 1, maximumFractionDigits: 1 });
const dateFormat = new Intl.DateTimeFormat('de-CH', {
  day: 'numeric',
  month: 'long',
  year: 'numeric',
  timeZone: 'UTC',
});

/** 23412345 → "23.4 MB" (Swiss number format). */
export function formatSize(bytes) {
  if (bytes < 1_000_000) return `${Math.max(1, Math.round(bytes / 1000))} KB`;
  return `${sizeFormat.format(bytes / 1_000_000)} MB`;
}

const digestCache = new Map();

async function sha256(file) {
  const hash = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest();
}

function text(value, fallback = '') {
  return typeof value === 'string' && TEXT_RE.test(value.trim()) ? value.trim() : fallback;
}

/** Loads one platform's release, or null (no manifest, invalid manifest, missing file). */
export async function loadRelease(dir, platform, log) {
  const manifestPath = path.join(dir, platform.manifest);
  let manifest;
  try {
    const stat = await fsp.stat(manifestPath);
    if (stat.size > MAX_MANIFEST_BYTES) throw new Error('Manifest ist zu gross.');
    manifest = JSON.parse(await fsp.readFile(manifestPath, 'utf8'));
  } catch (error) {
    if (error.code !== 'ENOENT') log.warn('release.manifest', { platform: platform.id, message: error.message });
    return null;
  }

  const file = typeof manifest?.file === 'string' ? manifest.file : '';
  const extension = path.extname(file).toLowerCase();
  if (!FILE_RE.test(file) || !CONTENT_TYPES[extension]) {
    log.warn('release.manifest', { platform: platform.id, message: `Ungültiger Dateiname "${file}".` });
    return null;
  }
  const version = typeof manifest.version === 'string' && VERSION_RE.test(manifest.version) ? manifest.version : '';
  if (!version) {
    log.warn('release.manifest', { platform: platform.id, message: 'Version fehlt oder ist ungültig.' });
    return null;
  }

  // The file must really sit in the releases folder (no symlink pointing elsewhere).
  let filePath;
  let stat;
  try {
    const dirReal = await fsp.realpath(dir);
    filePath = await fsp.realpath(path.join(dir, file));
    if (path.dirname(filePath) !== dirReal) throw new Error('Datei liegt ausserhalb des Release-Ordners.');
    stat = await fsp.stat(filePath);
    if (!stat.isFile() || stat.size === 0) throw new Error('Keine gültige Datei.');
  } catch (error) {
    log.warn('release.file', { platform: platform.id, file, message: error.message });
    return null;
  }

  const cacheKey = `${filePath}:${stat.size}:${stat.mtimeMs}`;
  let digest = digestCache.get(cacheKey);
  if (!digest) {
    digest = await sha256(filePath);
    digestCache.set(cacheKey, digest);
  }
  const hex = digest.toString('hex');
  const released = typeof manifest.released === 'string' && DATE_RE.test(manifest.released) ? manifest.released : '';
  const releasedDate = released ? new Date(`${released}T00:00:00Z`) : null;

  return Object.freeze({
    platform: platform.id,
    label: platform.label,
    file,
    path: filePath,
    size: stat.size,
    mtime: stat.mtime,
    mtimeMs: stat.mtimeMs,
    contentType: CONTENT_TYPES[extension],
    sha256: hex,
    sha256Base64: digest.toString('base64'),
    fingerprint: hex.slice(0, 16),
    etag: `"${hex.slice(0, 32)}"`,
    version,
    build: typeof manifest.build === 'string' && VERSION_RE.test(manifest.build) ? manifest.build : '',
    requirement: text(manifest.requirement),
    architecture: text(manifest.architecture),
    released,
    releasedLabel: releasedDate && !Number.isNaN(releasedDate.getTime()) ? dateFormat.format(releasedDate) : '',
    sizeLabel: formatSize(stat.size),
  });
}

export async function loadReleases(dir, log) {
  const entries = await Promise.all(
    Object.values(PLATFORMS).map(async (platform) => [platform.id, await loadRelease(dir, platform, log)]),
  );
  return Object.freeze(Object.fromEntries(entries));
}

/**
 * A cheap signature of the releases folder (names, sizes, change times), to notice
 * new files without hashing them.
 */
export async function releasesSignature(dir) {
  try {
    const names = (await fsp.readdir(dir)).filter((name) => !name.startsWith('.')).sort();
    const parts = await Promise.all(
      names.map(async (name) => {
        try {
          const stat = await fsp.stat(path.join(dir, name));
          return `${name}:${stat.size}:${stat.mtimeMs}`;
        } catch {
          return `${name}:-`;
        }
      }),
    );
    return parts.join('|');
  } catch {
    return '';
  }
}

/** checksums.txt in the format of `shasum -a 256` (can be checked with `shasum -c`). */
export function checksumsText(releases, origin) {
  const lines = [`# SHA-256 der Downloads von ${origin}`, '# Prüfen: shasum -a 256 -c checksums.txt', ''];
  for (const release of Object.values(releases)) {
    if (release) lines.push(`${release.sha256}  ${release.file}`);
  }
  return `${lines.join('\n')}\n`;
}
