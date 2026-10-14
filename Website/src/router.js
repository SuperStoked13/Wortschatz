// Hash router: '#/set/abc/learn?subset=starred'. Screens are loaded lazily so a
// broken screen cannot take the whole app down.

import { h, clear } from './lib/dom.js';
import { icon } from './ui/icons.js';
import { closeOverlays } from './ui/components.js';

const SCREENS = {
  dashboard: () => import('./screens/dashboard.js'),
  editor: () => import('./screens/editor.js'),
  set: () => import('./screens/set.js'),
  learn: () => import('./screens/learn.js'),
  write: () => import('./screens/write.js'),
  flashcards: () => import('./screens/flashcards.js'),
  exam: () => import('./screens/exam.js'),
  settings: () => import('./screens/settings.js'),
};

const ROUTES = [
  { pattern: /^\/$/, name: 'dashboard', keys: [] },
  { pattern: /^\/new$/, name: 'editor', keys: [] },
  { pattern: /^\/set\/([^/]+)$/, name: 'set', keys: ['id'] },
  { pattern: /^\/set\/([^/]+)\/edit$/, name: 'editor', keys: ['id'] },
  { pattern: /^\/set\/([^/]+)\/learn$/, name: 'learn', keys: ['id'] },
  { pattern: /^\/set\/([^/]+)\/write$/, name: 'write', keys: ['id'] },
  { pattern: /^\/set\/([^/]+)\/flashcards$/, name: 'flashcards', keys: ['id'] },
  { pattern: /^\/set\/([^/]+)\/exam$/, name: 'exam', keys: ['id'] },
  { pattern: /^\/settings$/, name: 'settings', keys: [] },
];

const APP_NAME = 'Wortschatz';

let outlet = null;
let started = false;
let current = { name: 'dashboard', params: {}, query: {}, path: '/', full: '/' };
let renderedFull = null;
let cleanup = null;
let renderToken = 0;
let leaveGuard = null;
let guardPending = false;
// Position of the rendered entry in the session history. Every entry the app
// shows is tagged with its position (history.state.wsIdx), so a refused
// Back/Forward move can be undone by traversing back to it.
let renderedIdx = 0;

function safeDecode(s) {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}

// Parses '/set/abc/write?subset=starred' (with or without leading '#').
export function parsePath(input) {
  let raw = String(input || '').replace(/^#/, '');
  if (!raw.startsWith('/')) raw = `/${raw}`;
  const qIndex = raw.indexOf('?');
  let path = qIndex >= 0 ? raw.slice(0, qIndex) : raw;
  const search = qIndex >= 0 ? raw.slice(qIndex + 1) : '';
  path = path.replace(/\/{2,}/g, '/');
  if (path.length > 1) path = path.replace(/\/+$/, '');
  const query = {};
  if (search) {
    for (const part of search.split('&')) {
      if (!part) continue;
      const eq = part.indexOf('=');
      const key = safeDecode((eq >= 0 ? part.slice(0, eq) : part).replace(/\+/g, ' '));
      const value = eq >= 0 ? safeDecode(part.slice(eq + 1).replace(/\+/g, ' ')) : '';
      if (key) query[key] = value;
    }
  }
  let name = 'dashboard';
  const params = {};
  for (const route of ROUTES) {
    const m = path.match(route.pattern);
    if (m) {
      name = route.name;
      route.keys.forEach((k, i) => {
        params[k] = safeDecode(m[i + 1]);
      });
      break;
    }
  }
  const matched = ROUTES.some((r) => r.pattern.test(path));
  const canonicalPath = matched ? path : '/';
  const full = search && matched ? `${canonicalPath}?${search}` : canonicalPath;
  return { name, params, query, path: canonicalPath, full };
}

function readHash() {
  return parsePath(typeof location !== 'undefined' ? location.hash : '');
}

function defaultTitle(route) {
  switch (route.name) {
    case 'editor':
      return route.params.id ? 'Lernset bearbeiten' : 'Neues Lernset';
    case 'set':
      return 'Lernset';
    case 'learn':
      return 'Lernen';
    case 'write':
      return 'Schreiben';
    case 'flashcards':
      return 'Karteikarten';
    case 'exam':
      return 'Prüfung';
    case 'settings':
      return 'Einstellungen';
    default:
      return 'Lernsets';
  }
}

// Sets document.title to '<text> · Wortschatz'.
export function setTitle(text) {
  if (typeof document === 'undefined') return;
  document.title = text ? `${text} · ${APP_NAME}` : APP_NAME;
}

export function currentRoute() {
  return { name: current.name, params: { ...current.params }, query: { ...current.query } };
}

// '#/set/abc' style href for links.
export function href(path) {
  return `#${parsePath(path).full}`;
}

export function setLeaveGuard(fn) {
  leaveGuard = typeof fn === 'function' ? fn : null;
}

// Asks the guard (if any). Resolves true when navigation may proceed.
async function passGuard() {
  if (!leaveGuard) return true;
  const guard = leaveGuard;
  guardPending = true;
  try {
    const ok = await guard();
    return ok !== false;
  } catch (err) {
    if (typeof console !== 'undefined') console.error('Leave guard failed', err);
    return true;
  } finally {
    guardPending = false;
  }
}

export function navigate(path, { replace = false } = {}) {
  const target = parsePath(path);
  if (!started) {
    if (typeof location !== 'undefined') location.hash = target.full;
    return;
  }
  if (replace) {
    transition(target, 'replace');
  } else if (`#${target.full}` === location.hash) {
    transition(target, 'same'); // same hash fires no hashchange: re-render explicitly
  } else {
    location.hash = target.full; // handled by onHashChange
  }
}

function entryState() {
  const st = history.state;
  return st && typeof st === 'object' && !Array.isArray(st) ? st : null;
}

function entryIndex() {
  const st = entryState();
  return st && Number.isInteger(st.wsIdx) ? st.wsIdx : null;
}

// Tags the current entry with its history position; an untagged entry was
// just pushed on top of the previously rendered one.
function markEntry() {
  const idx = entryIndex();
  if (idx != null) {
    renderedIdx = idx;
    return;
  }
  renderedIdx += 1;
  history.replaceState({ ...(entryState() || {}), wsIdx: renderedIdx }, '');
}

// The guard refused a hash change the browser has already committed: return
// to the rendered entry without rewriting (and so losing) any other entry.
function undoHashChange() {
  if (renderedFull == null) return;
  const idx = entryIndex();
  if (idx == null) history.back(); // a fresh entry (link, typed URL) on top of ours
  else if (idx !== renderedIdx) history.go(renderedIdx - idx); // Back/Forward moved us
  else history.replaceState(history.state, '', `#${renderedFull}`); // same entry, new hash
  // The traversal's hashchange lands on renderedFull: onHashChange ignores it.
}

// The hash shown before this change (null when unknown).
function previousHash(e) {
  if (!e || typeof e.oldURL !== 'string') return null;
  const i = e.oldURL.indexOf('#');
  return parsePath(i >= 0 ? e.oldURL.slice(i) : '').full;
}

// A screen may rewrite its own URL with replaceState (e.g. Write mode drops `new=1` and
// shows its round's subset), which leaves renderedFull behind. A fresh, untagged
// entry (typed URL, link) for renderedFull is then a real navigation; the tagged
// entry an undone hash change returns to is not.
function isFreshVisitOfRendered(e) {
  const shown = previousHash(e);
  return shown != null && shown !== renderedFull && entryIndex() == null;
}

function onHashChange(e) {
  if (guardPending) return; // a guard prompt is open; its outcome decides
  const target = readHash();
  if (target.full === renderedFull && !isFreshVisitOfRendered(e)) {
    // e.g. '#/unknown' while the dashboard is shown: just tidy the URL
    if (location.hash !== `#${target.full}`) history.replaceState(history.state, '', `#${target.full}`);
    if (entryIndex() !== renderedIdx) markEntry();
    return;
  }
  transition(target, 'hash');
}

async function transition(target, mode) {
  if (guardPending) return;
  const ok = await passGuard();
  if (!ok) {
    if (mode === 'hash') undoHashChange();
    return;
  }
  // The URL may have moved on while the guard was asking.
  const latest = mode === 'hash' ? readHash() : target;
  if (mode === 'replace' || (mode === 'hash' && `#${latest.full}` !== location.hash)) {
    history.replaceState(history.state, '', `#${latest.full}`);
  }
  await render(latest);
}

function runCleanup() {
  const fn = cleanup;
  cleanup = null;
  if (typeof fn === 'function') {
    try {
      fn();
    } catch (err) {
      if (typeof console !== 'undefined') console.error('Screen cleanup failed', err);
    }
  }
}

function playEnter() {
  if (!outlet) return;
  outlet.classList.remove('screen-enter');
  void outlet.offsetWidth;
  outlet.classList.add('screen-enter');
}

function renderError(err, route) {
  if (typeof console !== 'undefined') console.error(`Screen "${route.name}" failed`, err);
  clear(outlet);
  outlet.append(
    h(
      'section',
      { class: 'app-error', role: 'alert' },
      h('div', { class: 'app-error__icon' }, icon('alert', { size: 26 })),
      h('h1', { class: 'app-error__title' }, 'Diese Seite konnte nicht geladen werden'),
      h('p', { class: 'app-error__text' }, 'Etwas ist schiefgelaufen. Deine Daten sind sicher gespeichert.'),
      err && err.message ? h('pre', { class: 'app-error__detail' }, err.message) : null,
      h(
        'div',
        { class: 'app-error__actions' },
        h('a', { class: 'ui-btn ui-btn--secondary ui-btn--md', href: '#/' }, 'Zur Übersicht'),
        h('button', { class: 'ui-btn ui-btn--primary ui-btn--md', type: 'button', onClick: () => location.reload() }, 'Neu laden'),
      ),
    ),
  );
}

async function render(route) {
  const token = ++renderToken;
  leaveGuard = null; // cleared on every successful route change
  closeOverlays();
  runCleanup();
  current = route;
  renderedFull = route.full;
  markEntry();
  document.documentElement.dataset.route = route.name;
  setTitle(defaultTitle(route));
  window.dispatchEvent(new CustomEvent('wortschatz:route', { detail: currentRoute() }));

  let mod;
  try {
    mod = await SCREENS[route.name]();
  } catch (err) {
    if (token === renderToken) renderError(err, route);
    return;
  }
  if (token !== renderToken) return;

  clear(outlet);
  window.scrollTo(0, 0);
  const ctx = {
    params: { ...route.params },
    query: { ...route.query },
    route: route.name,
    path: route.path,
    setTitle,
    navigate,
  };
  try {
    const result = mod.render(outlet, ctx);
    if (result && typeof result.then === 'function') {
      result
        .then((fn) => {
          if (token === renderToken) cleanup = typeof fn === 'function' ? fn : null;
          else if (typeof fn === 'function') fn();
        })
        .catch((err) => {
          if (token === renderToken) renderError(err, route);
        });
    } else {
      cleanup = typeof result === 'function' ? result : null;
    }
  } catch (err) {
    renderError(err, route);
  }
  playEnter();
  const active = document.activeElement;
  if (!active || active === document.body || !active.isConnected) outlet.focus({ preventScroll: true });
}

export function startRouter(el) {
  outlet = el;
  if (started) return;
  started = true;
  if (!outlet.hasAttribute('tabindex')) outlet.setAttribute('tabindex', '-1');
  outlet.addEventListener('animationend', (e) => {
    if (e.target === outlet) outlet.classList.remove('screen-enter');
  });
  window.addEventListener('hashchange', onHashChange);
  const initial = readHash();
  if (location.hash !== `#${initial.full}`) history.replaceState(history.state, '', `#${initial.full}`);
  render(initial);
}
