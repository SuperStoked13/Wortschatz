#!/usr/bin/env node
// Wortschatz website: `node server/server.mjs` (Node 20 or newer, no packages needed).
// Behind Caddy (HTTPS) in production, see deploy/ and README.md.

import { createApp } from './lib/app.mjs';
import { loadConfig } from './lib/config.mjs';
import { startDuckDns } from './lib/duckdns.mjs';
import { createHttpServer } from './lib/http.mjs';
import { createLogger } from './lib/log.mjs';

const [major] = process.versions.node.split('.').map(Number);
if (major < 20) {
  console.error(`Wortschatz braucht Node 20 oder neuer (installiert: ${process.versions.node}).`);
  process.exit(1);
}

let config;
try {
  config = loadConfig(process.env);
} catch (error) {
  console.error(`Konfiguration: ${error.message}`);
  process.exit(78);
}

const log = createLogger(config.logLevel);
const app = await createApp(config, log);

const server = createHttpServer(app.handle);
// A failing accept must not take the whole site down; not being able to listen at all must.
server.on('error', (error) => {
  log.error('server', { message: error.message, code: error.code });
  if (!server.listening) process.exit(1);
});

const stopDuckDns = startDuckDns(config.duckdns, log);

server.listen(config.port, config.host, () => {
  const { mac, windows } = app.state.releases;
  log.info('listening', {
    url: `http://${config.host.includes(':') ? `[${config.host}]` : config.host}:${config.port}/`,
    origin: config.origin,
    mac: mac ? `${mac.file} (${mac.sizeLabel})` : 'fehlt',
    windows: windows ? `${windows.file} (${windows.sizeLabel})` : 'fehlt',
  });
  if (!config.contactEmail || !config.operator) {
    log.warn('datenschutz', { message: 'OPERATOR_NAME und CONTACT_EMAIL setzen, damit die Datenschutzerklärung vollständig ist.' });
  }
});

process.on('SIGHUP', () => app.reload('SIGHUP'));

let stopping = false;
async function shutdown(signal) {
  if (stopping) return;
  stopping = true;
  log.info('shutdown', { signal });
  stopDuckDns();
  server.close();
  server.closeIdleConnections();
  setTimeout(() => process.exit(0), 10_000).unref();
  await app.close();
  process.exit(0);
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
