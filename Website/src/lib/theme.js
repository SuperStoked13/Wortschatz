// Theme handling: <html data-theme="light|dark">, following the OS when the
// setting is 'system'. Browser only at call time.

import { db } from '../store/db.js';
import { reportTheme } from './host.js';

const THEME_COLORS = { light: '#F5F6FA', dark: '#0E1016' };
const VALID = ['system', 'light', 'dark'];

let setting = 'system';
let mql = null;
let listening = false;
let subscribed = false;

function media() {
  if (!mql && typeof matchMedia === 'function') mql = matchMedia('(prefers-color-scheme: dark)');
  return mql;
}

export function resolveTheme(value = setting) {
  if (value === 'light' || value === 'dark') return value;
  const m = media();
  return m && m.matches ? 'dark' : 'light';
}

function setResolved(resolved) {
  reportTheme(resolved);
  const root = document.documentElement;
  if (root.dataset.theme === resolved) return;
  const hadTheme = !!root.dataset.theme;
  // Flip all colours in one frame instead of letting each transition run.
  if (hadTheme) root.setAttribute('data-theme-switching', '');
  root.dataset.theme = resolved;
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute('content', THEME_COLORS[resolved]);
  if (hadTheme) {
    // Force a style flush while transitions are off, then re-enable them.
    void getComputedStyle(document.body || root).opacity;
    setTimeout(() => root.removeAttribute('data-theme-switching'), 1);
  }
}

// themeSetting: 'system' | 'light' | 'dark'. Idempotent; returns the resolved theme.
export function applyTheme(themeSetting = 'system') {
  setting = VALID.includes(themeSetting) ? themeSetting : 'system';
  if (typeof document === 'undefined') return resolveTheme(setting);
  const m = media();
  if (m && !listening) {
    listening = true;
    const onChange = () => {
      if (setting === 'system') setResolved(resolveTheme('system'));
    };
    if (typeof m.addEventListener === 'function') m.addEventListener('change', onChange);
    else if (typeof m.addListener === 'function') m.addListener(onChange);
  }
  document.documentElement.dataset.themeSetting = setting;
  const resolved = resolveTheme(setting);
  setResolved(resolved);
  return resolved;
}

export function getThemeSetting() {
  return setting;
}

// Reads the stored setting, applies it and keeps following settings changes.
export function initTheme() {
  let stored = 'system';
  try {
    stored = db.getSettings().theme || 'system';
  } catch {
    stored = 'system';
  }
  const resolved = applyTheme(stored);
  if (!subscribed && typeof db.subscribe === 'function') {
    subscribed = true;
    db.subscribe(() => {
      try {
        const next = db.getSettings().theme || 'system';
        if (next !== setting) applyTheme(next);
      } catch {
        /* settings unreadable: keep the current theme */
      }
    });
  }
  return resolved;
}
