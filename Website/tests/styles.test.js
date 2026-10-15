// Design-system guards: WCAG contrast of the colour tokens in both themes and a few
// structural rules in the shared stylesheets (focus rings, placeholders, tooltips,
// touch targets, toasts over bottom sheets, the screen enter animation).
import { test, expect, run } from './harness.js';

/* ------------------------------------------------------------ tiny CSS parser */

// Flat list of leaf rules: { selector, decls, at: [enclosing preludes] }.
function parseRules(css) {
  const src = css.replace(/\/\*[\s\S]*?\*\//g, '');
  const out = [];
  const stack = [];
  let buf = '';
  for (const ch of src) {
    if (ch === '{') {
      if (stack.length) stack[stack.length - 1].nested = true;
      stack.push({ prelude: buf.trim(), nested: false });
      buf = '';
    } else if (ch === '}') {
      const top = stack.pop();
      if (top && !top.nested) out.push({ selector: top.prelude, decls: parseDecls(buf), at: stack.map((s) => s.prelude) });
      buf = '';
    } else {
      buf += ch;
    }
  }
  return out;
}

function parseDecls(body) {
  const decls = {};
  for (const part of body.split(';')) {
    const i = part.indexOf(':');
    if (i > 0) decls[part.slice(0, i).trim()] = part.slice(i + 1).trim().replace(/\s+/g, ' ');
  }
  return decls;
}

const load = (path) => parseRules(readFile(path));
const TOKENS = load('../styles/tokens.css');
const COMPONENTS = load('../styles/components.css');
const BASE = load('../styles/base.css');

// Declarations of every top-level rule (or rule inside `media`) whose selector list
// contains `selector`, merged in source order.
function declsFor(rules, selector, media = null) {
  const merged = {};
  for (const r of rules) {
    const inMedia = media ? r.at.includes(media) : r.at.length === 0;
    if (!inMedia) continue;
    if (!r.selector.split(',').map((s) => s.trim()).includes(selector)) continue;
    Object.assign(merged, r.decls);
  }
  return merged;
}

const LIGHT = declsFor(TOKENS, ':root');
const DARK = { ...LIGHT, ...declsFor(TOKENS, ':root[data-theme="dark"]') };
const THEMES = [
  ['light', LIGHT],
  ['dark', DARK],
];

function resolve(vars, value, depth = 0) {
  if (depth > 10) throw new Error(`var() cycle in ${value}`);
  return value.replace(/var\((--[\w-]+)\)/g, (_, name) => {
    if (!(name in vars)) throw new Error(`unknown token ${name}`);
    return resolve(vars, vars[name], depth + 1);
  });
}
const token = (vars, name) => {
  if (!(name in vars)) throw new Error(`missing token ${name}`);
  return resolve(vars, vars[name]);
};

/* ---------------------------------------------------------------- contrast */

function rgbOf(hex) {
  let h = hex.replace('#', '');
  if (h.length === 3) h = h.split('').map((c) => c + c).join('');
  if (!/^[0-9a-f]{6}$/i.test(h)) throw new Error(`not an opaque hex colour: ${hex}`);
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
}

function luminance(hex) {
  const [r, g, b] = rgbOf(hex).map((v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(a, b) {
  const la = luminance(a);
  const lb = luminance(b);
  return Math.round(((Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)) * 100) / 100;
}

const hexColours = (value) => value.match(/#[0-9a-f]{3,8}\b/gi) || [];

function expectContrast(label, fg, bg, min) {
  const ratio = contrast(fg, bg);
  if (ratio < min) throw new Error(`${label}: ${fg} on ${bg} is ${ratio}:1, needs ${min}:1`);
}

/* ------------------------------------------------------------------ tokens */

test('parser sanity: both themes expose the core tokens', () => {
  expect(LIGHT['--surface']).toBe('#FFFFFF');
  expect(DARK['--surface']).toBe('#161922');
});

test('secondary text (--text-3) reaches 4.5:1 on every surface in both themes', () => {
  for (const [name, vars] of THEMES) {
    for (const bg of ['--surface', '--bg', '--surface-2', '--surface-3', '--popover-bg', '--seg-bg']) {
      expectContrast(`${name} --text-3 on ${bg}`, token(vars, '--text-3'), token(vars, bg), 4.5);
    }
  }
});

test('white labels on solid fills reach 4.5:1 in both themes', () => {
  const fills = ['--accent-fill', '--accent-fill-hover', '--success-fill', '--success-fill-hover', '--danger-fill', '--danger-fill-hover'];
  for (const [name, vars] of THEMES) {
    for (const fill of fills) expectContrast(`${name} white on ${fill}`, '#FFFFFF', token(vars, fill), 4.5);
  }
});

test('every stop of the accent gradient carries white text at 4.5:1', () => {
  for (const [name, vars] of THEMES) {
    const stops = hexColours(token(vars, '--accent-gradient'));
    expect(stops.length).toBeGreaterThan(1);
    for (const stop of stops) expectContrast(`${name} white on gradient stop`, '#FFFFFF', stop, 4.5);
  }
});

test('the keyboard focus ring is opaque and reaches 3:1 next to every surface', () => {
  for (const [name, vars] of THEMES) {
    const ring = token(vars, '--focus-ring');
    expect(/rgba?\(|hsla?\(|transparent/.test(ring)).toBe(false);
    const colours = hexColours(ring);
    const outer = colours[colours.length - 1];
    for (const bg of ['--surface', '--bg', '--surface-2', '--surface-3', '--popover-bg']) {
      expectContrast(`${name} focus ring next to ${bg}`, outer, token(vars, bg), 3);
    }
    const inset = token(vars, '--focus-ring-inset');
    expect(inset.startsWith('inset')).toBe(true);
    for (const bg of ['--popover-hover', '--danger-soft', '--seg-indicator', '--seg-bg']) {
      expectContrast(`${name} inset focus ring on ${bg}`, hexColours(inset)[0], token(vars, bg), 3);
    }
  }
});

/* -------------------------------------------------------------- components */

test('keyboard focus in shared components never relies on the translucent --ring halo', () => {
  const offenders = COMPONENTS.filter((r) => r.selector.includes(':focus-visible') && /var\(--ring/.test(r.decls['box-shadow'] || ''));
  expect(offenders.map((r) => r.selector)).toEqual([]);
  for (const sel of ['.ui-btn:focus-visible', '.ui-icon-btn:focus-visible', '.ui-chip--interactive:focus-visible', '.ui-toggle__input:focus-visible + .ui-toggle__track']) {
    expect(declsFor(COMPONENTS, sel)['box-shadow'] || '').toContain('var(--focus-ring)');
  }
  expect(declsFor(COMPONENTS, '.ui-seg__btn:focus-visible')['box-shadow'] || '').toContain('var(--focus-ring-inset)');
  expect(declsFor(COMPONENTS, '.ui-menu__item:focus-visible')['box-shadow'] || '').toContain('var(--focus-ring-inset)');
});

test('placeholders are not faded below the --text-3 contrast', () => {
  expect(declsFor(COMPONENTS, '.ui-input::placeholder').opacity).toBe('1');
});

test('danger and success buttons put white labels on the dark fill tokens', () => {
  expect(declsFor(COMPONENTS, '.ui-btn--danger').background).toBe('var(--danger-fill)');
  expect(declsFor(COMPONENTS, '.ui-btn--danger:hover:not(:disabled)').background).toBe('var(--danger-fill-hover)');
  expect(declsFor(COMPONENTS, '.ui-btn--success').background).toBe('var(--success-fill)');
  expect(declsFor(COMPONENTS, '.ui-btn--success:hover:not(:disabled)').background).toBe('var(--success-fill-hover)');
});

test('tooltips wrap long text inside the pill', () => {
  const tip = declsFor(COMPONENTS, '.ui-tooltip');
  expect(tip['white-space']).not.toBe('nowrap');
  expect(tip.width).toBe('max-content');
  expect(tip['max-width']).toContain('100vw');
});

test('small icon buttons grow to 40px on coarse pointers', () => {
  expect(declsFor(COMPONENTS, '.ui-icon-btn--sm', '@media (pointer: coarse)')['--ib']).toBe('40px');
});

test('toasts move to the top while a bottom-sheet modal is open on phones', () => {
  const rule = COMPONENTS.find((r) => r.at.includes('@media (max-width: 560px)') && r.selector.includes('.ui-scroll-locked .ui-toasts'));
  expect(!!rule).toBe(true);
  expect(rule.decls.bottom).toBe('auto');
  expect(rule.decls.top || '').toContain('safe-area-inset-top');
});

/* -------------------------------------------------------------------- base */

test('screens with fixed UI (editor dock) enter without a transform on #app', () => {
  const rule = declsFor(BASE, '.app-main.screen-enter:has(.ed-dock)');
  const name = rule['animation-name'];
  expect(!!name).toBe(true);
  const frames = BASE.filter((r) => r.at.includes(`@keyframes ${name}`));
  expect(frames.length).toBeGreaterThan(0);
  for (const f of frames) expect('transform' in f.decls).toBe(false);
});

// Screen stylesheets: keyboard focus uses the opaque ring too. .dash-new and .ed-add keep
// the soft halo because their solid accent border already marks the focus.
const SCREENS = ['dashboard', 'set', 'settings', 'editor', 'write', 'learn', 'flashcards', 'exam'].map((name) => [name, load(`../styles/screens/${name}.css`)]);

test('screen stylesheets do not mark keyboard focus with the translucent --ring halo alone', () => {
  const allowed = new Set(['.dash-new:focus-visible', '.ed-add:focus-visible']);
  const offenders = [];
  for (const [name, rules] of SCREENS) {
    for (const r of rules) {
      if (!r.selector.includes(':focus-visible') || allowed.has(r.selector)) continue;
      if (/var\(--ring\)/.test(r.decls['box-shadow'] || '')) offenders.push(`${name}.css ${r.selector}`);
    }
  }
  expect(offenders).toEqual([]);
});

test('Write placeholder and the set start tile detail keep their contrast', () => {
  const rules = (name) => SCREENS.find(([n]) => n === name)[1];
  expect(declsFor(rules('write'), '.wr-input::placeholder').opacity).toBe('1');
  expect(declsFor(rules('set'), '.set-start__detail').color).toBe('#FFFFFF');
});

/* ------------------------------------------------------ Arabic and Chinese text */

const screenRules = (name) => SCREENS.find(([n]) => n === name)[1];

// [ids, classes + attributes + pseudo-classes, types] of a selector without :is()/:not().
function specificity(selector) {
  const plain = selector.replace(/::[\w-]+/g, '');
  const ids = (plain.match(/#[\w-]+/g) || []).length;
  const classes = (plain.match(/\.[\w-]+|\[[^\]]*\]|:[\w-]+(\([^)]*\))?/g) || []).length;
  const types = (plain.replace(/\[[^\]]*\]|\([^)]*\)|[.#:][\w-]+/g, ' ').match(/[a-z][\w-]*/gi) || []).length;
  return [ids, classes, types];
}

// Whether rule a ({ spec, order }) overrides rule b on an element both match.
function overrides(a, b) {
  for (let i = 0; i < 3; i++) if (a.spec[i] !== b.spec[i]) return a.spec[i] > b.spec[i];
  return a.order > b.order;
}

test('Arabic and Chinese text: natural spacing, Chinese fonts, start-aligned options, unbroken Arabic words', () => {
  for (const lang of [':lang(ar)', ':lang(zh)']) {
    const decls = declsFor(BASE, lang);
    expect(decls['letter-spacing']).toBe('normal');
    expect(decls['--tracking-tight']).toBe('normal');
    expect(decls['--tracking-display']).toBe('normal');
  }
  const zh = declsFor(BASE, ':lang(zh)');
  for (const font of ['"Segoe UI"', '"Microsoft YaHei UI"', '"PingFang SC"', '"Noto Sans CJK SC"']) expect(zh['--font-ui']).toContain(font);
  expect(zh['--font-display']).toBe('var(--font-ui)');
  expect(zh['font-family']).toBe('var(--font-ui)');
  // Wrapped Arabic options align right inside their tile.
  expect(declsFor(screenRules('learn'), '.ln-tile')['text-align']).toBe('start');
  // Padding inside a word would break the joined Arabic letters apart.
  for (const [name, sel] of [
    ['write', '.wr-diff__del:lang(ar)'],
    ['write', '.wr-diff__add:lang(ar)'],
    ['exam', '.ex-diff:lang(ar)'],
    ['dashboard', '.dash-mark:lang(ar)'],
  ]) {
    expect(declsFor(screenRules(name), sel).padding).toBe('0');
  }
  for (const [name, sel] of [
    ['write', '.wr-fb__expected:lang(ar)'],
    ['learn', '.ln-tile__text:lang(ar)'],
    ['flashcards', '.fc-face__text:lang(ar)'],
    ['set', '.set-term__term:lang(ar)'],
    ['set', '.set-term__def:lang(ar)'],
    ['exam', '.ex-q__prompt :lang(ar)'],
    ['exam', '.ex-answer:lang(ar)'],
  ]) {
    expect(declsFor(screenRules(name), sel)['line-height']).toBe('1.6');
  }
  // The editor's hidden sizing copy wraps each line in its own direction, like the field.
  expect(declsFor(screenRules('editor'), '.ed-grow::after')['unicode-bidi']).toBe('plaintext');
});

test('the Arabic prompt line height wins over every prompt rule of Lernen and Schreiben', () => {
  // learn.css loads before write.css (index.html).
  const ordered = ['learn', 'write'].flatMap((name) => screenRules(name));
  const entries = [];
  ordered.forEach((r, order) => {
    if (!('line-height' in r.decls)) return;
    for (const sel of r.selector.split(',').map((s) => s.trim())) {
      if (sel.includes('.wr-q__prompt')) entries.push({ sel, order, spec: specificity(sel), value: r.decls['line-height'] });
    }
  });
  const arabic = entries.filter((e) => e.sel.endsWith(':lang(ar)'));
  expect(arabic.map((e) => e.value)).toEqual(['1.6', '1.6']);
  const others = entries.filter((e) => !e.sel.endsWith(':lang(ar)'));
  expect(others.length).toBeGreaterThan(4);
  for (const other of others) {
    // A multiple choice prompt (.ln-mc) is matched by the Lernen rule, a written one by Schreiben's.
    const mine = arabic.find((a) => a.sel.includes('.ln-mc') === other.sel.includes('.ln-mc'));
    if (!overrides(mine, other)) throw new Error(`${other.sel} overrides ${mine.sel}`);
  }
});

await run('styles.test.js');
