// Optional: keeps wortschatz.duckdns.org pointed at this connection's public address.
// Set DUCKDNS_DOMAIN (e.g. "wortschatz") and DUCKDNS_TOKEN; the server then calls the
// DuckDNS update URL every five minutes. The token never appears in the log.

import https from 'node:https';

const INTERVAL_MS = 5 * 60_000;

export function startDuckDns({ domain, token }, log) {
  // Without a token the router (or nobody) keeps the name up to date.
  if (!token) return () => {};
  if (!/^[a-z0-9-]{1,63}$/.test(domain) || !/^[0-9a-f-]{36}$/i.test(token)) {
    log.warn('duckdns', { message: 'DUCKDNS_DOMAIN oder DUCKDNS_TOKEN ist ungültig, keine Aktualisierung.' });
    return () => {};
  }
  let lastResult = '';

  const update = () => {
    const url = new URL('https://www.duckdns.org/update');
    url.searchParams.set('domains', domain);
    url.searchParams.set('token', token);
    url.searchParams.set('ip', '');
    const req = https.get(url, { timeout: 15_000, headers: { 'User-Agent': 'wortschatz-web' } }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        if (body.length < 64) body += chunk;
      });
      res.on('end', () => {
        const result = body.trim().slice(0, 16) || String(res.statusCode);
        if (result !== lastResult) {
          (result === 'OK' ? log.info : log.warn)('duckdns', { domain: `${domain}.duckdns.org`, result });
          lastResult = result;
        }
      });
    });
    req.on('timeout', () => req.destroy(new Error('Zeitüberschreitung')));
    req.on('error', (error) => log.warn('duckdns', { message: error.message }));
  };

  update();
  const interval = setInterval(update, INTERVAL_MS);
  interval.unref();
  return () => clearInterval(interval);
}
