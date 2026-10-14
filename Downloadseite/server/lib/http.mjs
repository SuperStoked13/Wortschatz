// Response helpers: security headers, content negotiation, caching.

const PERMISSIONS = [
  'accelerometer=()',
  'autoplay=()',
  'browsing-topics=()',
  'camera=()',
  'display-capture=()',
  'encrypted-media=()',
  'geolocation=()',
  'gyroscope=()',
  'hid=()',
  'magnetometer=()',
  'microphone=()',
  'midi=()',
  'payment=()',
  'picture-in-picture=()',
  'publickey-credentials-get=()',
  'screen-wake-lock=()',
  'serial=()',
  'usb=()',
  'xr-spatial-tracking=()',
].join(', ');

/** Headers for every response (also errors and downloads). */
export function securityHeaders({ secure }) {
  const csp = [
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self'",
    "font-src 'self'",
    "connect-src 'self'",
    "manifest-src 'self'",
    "form-action 'self'",
    "base-uri 'none'",
    "frame-ancestors 'none'",
    "require-trusted-types-for 'script'",
    "trusted-types 'none'",
    ...(secure ? ['upgrade-insecure-requests'] : []),
  ].join('; ');
  const headers = {
    'Content-Security-Policy': csp,
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'same-origin',
    'Permissions-Policy': PERMISSIONS,
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Resource-Policy': 'same-origin',
    'Origin-Agent-Cluster': '?1',
    'X-DNS-Prefetch-Control': 'off',
    'X-Permitted-Cross-Domain-Policies': 'none',
  };
  if (secure) headers['Strict-Transport-Security'] = 'max-age=63072000; includeSubDomains';
  return Object.freeze(headers);
}

/** Ends the response (no body for HEAD). */
export function send(req, res, status, headers, body = '') {
  res.statusCode = status;
  for (const [name, value] of Object.entries(headers)) res.setHeader(name, value);
  const buffer = typeof body === 'string' ? Buffer.from(body, 'utf8') : body;
  res.setHeader('Content-Length', buffer.length);
  res.end(req.method === 'HEAD' ? undefined : buffer);
}

export function sendJson(req, res, status, value, headers = {}) {
  send(req, res, status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...headers }, JSON.stringify(value));
}

/** True when the client asked for JSON (the page's fetch calls). */
export function wantsJson(req) {
  const accept = String(req.headers.accept || '');
  return accept.includes('application/json') && !accept.includes('text/html');
}

/** The best encoding the client accepts and the entry has: "br", "gzip" or "". */
export function pickEncoding(header, entry) {
  if (!header || (!entry.br && !entry.gzip)) return '';
  const accepted = new Map();
  for (const part of String(header).toLowerCase().split(',')) {
    const [name, ...params] = part.trim().split(';');
    const q = params.map((p) => p.trim()).find((p) => p.startsWith('q='));
    accepted.set(name.trim(), q ? Number(q.slice(2)) : 1);
  }
  if (entry.br && (accepted.get('br') ?? 0) > 0) return 'br';
  if (entry.gzip && (accepted.get('gzip') ?? 0) > 0) return 'gzip';
  return '';
}

/** If-None-Match matches the given ETag (weak comparison, as RFC 9110 asks for it). */
export function notModified(req, etag) {
  const header = req.headers['if-none-match'];
  if (!header) return false;
  if (header.trim() === '*') return true;
  const bare = etag.replace(/^W\//, '');
  return header.split(',').some((tag) => tag.trim().replace(/^W\//, '') === bare);
}

/** Serves an in-memory entry (static file or rendered page). Returns the body bytes sent. */
export function sendEntry(req, res, entry, { versioned = false } = {}) {
  const encoding = pickEncoding(req.headers['accept-encoding'], entry);
  const etag = encoding ? entry.etag.replace(/"$/, `-${encoding}"`) : entry.etag;
  res.setHeader('Content-Type', entry.type);
  res.setHeader(
    'Cache-Control',
    entry.cacheControl ?? (versioned ? 'public, max-age=31536000, immutable' : 'public, max-age=3600'),
  );
  if (entry.br || entry.gzip) res.setHeader('Vary', 'Accept-Encoding');
  res.setHeader('ETag', etag);
  if (notModified(req, etag)) {
    res.statusCode = 304;
    res.end();
    return 0;
  }
  if (encoding) res.setHeader('Content-Encoding', encoding);
  const body = encoding === 'br' ? entry.br : encoding === 'gzip' ? entry.gzip : entry.body;
  res.statusCode = 200;
  res.setHeader('Content-Length', body.length);
  res.end(req.method === 'HEAD' ? undefined : body);
  return req.method === 'HEAD' ? 0 : body.length;
}

/**
 * Parses a single byte range ("bytes=0-99", "bytes=100-", "bytes=-500").
 * Returns {start, end}, "unsatisfiable", or null (ignore the header, send everything).
 */
export function parseRange(header, size) {
  const match = /^bytes=(\d*)-(\d*)$/.exec(String(header || '').trim());
  if (!match) return null;
  const [, first, last] = match;
  if (first === '' && last === '') return null;
  let start;
  let end;
  if (first === '') {
    // The last N bytes; more than the whole file means the whole file.
    const suffix = Number(last);
    if (suffix === 0) return 'unsatisfiable';
    start = suffix >= size ? 0 : size - suffix;
    end = size - 1;
  } else {
    start = Number(first);
    end = last === '' ? size - 1 : Math.min(Number(last), size - 1);
  }
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || start > end) {
    return 'unsatisfiable';
  }
  return { start, end };
}

/** "einer Minute", "5 Minuten", "2 Stunden" for waiting times in messages. */
export function humanWait(seconds) {
  if (seconds < 90) return 'einer Minute';
  const minutes = Math.ceil(seconds / 60);
  if (minutes < 90) return `${minutes} Minuten`;
  const hours = Math.ceil(minutes / 60);
  return hours === 1 ? 'einer Stunde' : `${hours} Stunden`;
}
