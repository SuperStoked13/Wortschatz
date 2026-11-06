// The HTTP server and response helpers: security headers, content negotiation, caching.

import http from 'node:http';

/** The HTTP server with its timeouts and limits (`options` only for tests). */
export function createHttpServer(handler, options = {}) {
  const server = http.createServer(
    {
      headersTimeout: 10_000, // all headers within 10 s (slow-loris)
      requestTimeout: 10_000, // the whole request within 10 s: the only bodies are tiny forms
      connectionsCheckingInterval: 2_000, // the default of 30 s would make both up to 30 s late
      // Longer than Caddy keeps idle upstream connections (30 s, see deploy/Caddyfile), so
      // Caddy never reuses a connection that Node is just closing.
      keepAliveTimeout: 65_000,
      maxHeaderSize: 16 * 1024,
      requireHostHeader: true,
      ...options,
    },
    handler,
  );
  server.maxRequestsPerSocket = 1000;
  server.maxConnections = 2000;
  // A connection that does nothing for a minute (also a stalled download) is closed.
  server.setTimeout(60_000, (socket) => socket.destroy());
  server.on('clientError', (error, socket) => {
    // Nothing sent yet means no request to answer, and a proxy could take an answer for its next one.
    if (error.code === 'ECONNRESET' || !socket.writable || !socket.bytesRead) {
      socket.destroy();
      return;
    }
    const status = error.code === 'ERR_HTTP_REQUEST_TIMEOUT' ? '408 Request Timeout' : '400 Bad Request';
    // Then really close: a client that goes on sending must not keep the connection.
    socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`, () => socket.destroy());
  });
  // At the connection limit, make room: idle connections are the cheapest to give up.
  let lastDrop = 0;
  server.on('drop', () => {
    if (Date.now() - lastDrop < 1000) return;
    lastDrop = Date.now();
    server.closeIdleConnections();
  });
  return server;
}

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
  // A body nobody read to the end would keep the connection busy for as long as it trickles.
  if (!req.readableEnded && (Number(req.headers['content-length']) > 0 || req.headers['transfer-encoding'])) {
    res.setHeader('Connection', 'close');
  }
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
  // No browser sends a long list; a long one only costs time to take apart.
  if (!header || header.length > 256 || (!entry.br && !entry.gzip)) return '';
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
  if (!header || header.length > 1024) return false;
  if (header.trim() === '*') return true;
  const bare = etag.replace(/^W\//, '');
  return header.split(',').some((tag) => tag.trim().replace(/^W\//, '') === bare);
}

/**
 * Serves an in-memory entry (static file or rendered page). `personal`: only for whoever is
 * signed in, so no shared cache may keep it for others.
 */
export function sendEntry(req, res, entry, { versioned = false, personal = false } = {}) {
  const encoding = pickEncoding(req.headers['accept-encoding'], entry);
  const etag = encoding ? entry.etag.replace(/"$/, `-${encoding}"`) : entry.etag;
  const cacheControl = entry.cacheControl ?? (versioned ? 'public, max-age=31536000, immutable' : 'public, max-age=3600');
  res.setHeader('Content-Type', entry.type);
  res.setHeader('Cache-Control', personal ? `private, ${cacheControl}` : cacheControl);
  const vary = [...(entry.br || entry.gzip ? ['Accept-Encoding'] : []), ...(personal ? ['Cookie', 'Authorization'] : [])];
  if (vary.length) res.setHeader('Vary', vary.join(', '));
  res.setHeader('ETag', etag);
  if (notModified(req, etag)) {
    res.statusCode = 304;
    res.end();
    return;
  }
  if (encoding) res.setHeader('Content-Encoding', encoding);
  const body = encoding === 'br' ? entry.br : encoding === 'gzip' ? entry.gzip : entry.body;
  res.statusCode = 200;
  res.setHeader('Content-Length', body.length);
  res.end(req.method === 'HEAD' ? undefined : body);
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
