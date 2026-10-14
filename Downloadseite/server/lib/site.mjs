// Loads the public folder once (and again on reload): static files are kept in memory,
// pre-compressed (brotli, gzip) and versioned by content hash; the HTML templates are
// compiled and rendered with the release data.

import crypto from 'node:crypto';
import fsp from 'node:fs/promises';
import path from 'node:path';
import zlib from 'node:zlib';
import { compile, render } from './templates.mjs';

const TYPES = Object.freeze({
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.webp': 'image/webp',
  '.avif': 'image/avif',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
});

const COMPRESSIBLE = /^(text\/|application\/(json|manifest\+json)|image\/svg\+xml)/;
const MAX_FILE_BYTES = 5 * 1024 * 1024;
const MAX_TOTAL_BYTES = 40 * 1024 * 1024;

function hashOf(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

/** A servable in-memory file with its compressed variants and ETag. */
export function makeEntry(body, type, { cacheControl } = {}) {
  const hash = hashOf(body);
  const entry = { body, type, hash, version: hash.slice(0, 10), etag: `"${hash.slice(0, 24)}"`, cacheControl };
  if (COMPRESSIBLE.test(type) && body.length > 600) {
    const br = zlib.brotliCompressSync(body, {
      params: {
        [zlib.constants.BROTLI_PARAM_QUALITY]: 11,
        [zlib.constants.BROTLI_PARAM_SIZE_HINT]: body.length,
      },
    });
    const gzip = zlib.gzipSync(body, { level: 9 });
    if (br.length < body.length * 0.95) entry.br = br;
    if (gzip.length < body.length * 0.95) entry.gzip = gzip;
  }
  return entry;
}

async function walk(dir, base = dir, out = []) {
  for (const dirent of await fsp.readdir(dir, { withFileTypes: true })) {
    if (dirent.name.startsWith('.')) continue;
    const full = path.join(dir, dirent.name);
    if (dirent.isDirectory()) await walk(full, base, out);
    else if (dirent.isFile()) out.push(path.relative(base, full).split(path.sep).join('/'));
  }
  return out;
}

/**
 * @returns {{
 *   statics: Map<string, object>,
 *   renderPage: (name: string, context: object) => object,
 *   renderHtml: (name: string, context: object) => string,
 * }}
 */
export async function loadSite(publicDir) {
  const files = await walk(publicDir);
  const statics = new Map();
  const templates = new Map();
  const partials = new Map();
  const styles = [];
  let total = 0;

  for (const rel of files) {
    const full = path.join(publicDir, rel);
    const stat = await fsp.stat(full);
    if (stat.size > MAX_FILE_BYTES) throw new Error(`${rel} ist grösser als 5 MB.`);
    total += stat.size;
    if (total > MAX_TOTAL_BYTES) throw new Error('Der Ordner public ist grösser als 40 MB.');
    const extension = path.extname(rel).toLowerCase();

    if (extension === '.html') {
      const source = await fsp.readFile(full, 'utf8');
      if (rel.startsWith('_partials/')) partials.set(path.basename(rel, '.html'), compile(source, rel));
      else templates.set(rel.replace(/\.html$/, ''), compile(source, rel));
      continue;
    }
    const type = TYPES[extension];
    if (!type) continue; // unknown types are never served
    const body = await fsp.readFile(full);
    if (extension === '.css') styles.push([`/${rel}`, body.toString('utf8')]);
    else statics.set(`/${rel}`, makeEntry(body, type));
  }

  // Version the url(/assets/…) references inside the stylesheets, then the stylesheets.
  for (const [urlPath, css] of styles) {
    const versioned = css.replace(/url\(\s*(['"]?)(\/assets\/[^'")?#\s]+)\1\s*\)/g, (match, quote, ref) => {
      const entry = statics.get(ref);
      return entry ? `url(${quote}${ref}?v=${entry.version}${quote})` : match;
    });
    statics.set(urlPath, makeEntry(Buffer.from(versioned, 'utf8'), TYPES['.css']));
  }

  const env = {
    partials,
    asset(ref) {
      const entry = statics.get(ref);
      if (!entry) throw new Error(`Asset ${ref} gibt es nicht.`);
      return `${ref}?v=${entry.version}`;
    },
  };

  function renderHtml(name, context) {
    const template = templates.get(name);
    if (!template) throw new Error(`Template ${name}.html fehlt.`);
    return render(template, context, env);
  }

  return {
    statics,
    has: (name) => templates.has(name),
    renderHtml,
    renderPage(name, context) {
      return makeEntry(Buffer.from(renderHtml(name, context), 'utf8'), 'text/html; charset=utf-8', {
        cacheControl: 'no-cache',
      });
    },
  };
}
