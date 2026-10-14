# Wortschatz — Implementation Plan

Spec: `docs/superpowers/specs/2026-10-11-wortschatz-design.md` (the contract — read it fully).
Execution: multi-agent workflow. Each workstream owns a disjoint set of files. Never edit files
owned by another workstream; if a contract seems wrong, follow the spec and note it in your report.

Already done (do not rewrite): `tests/harness.js`, `tests/run.sh`, `tests/harness.test.js`,
`src/core/text.js` + `tests/text.test.js`, `tests/fixtures/user-example.txt` (52 pairs),
`serve.py` (no-cache static server on port 4173) and `.claude/launch.json`. A dev server is already
running at http://localhost:4173 serving the project root.

## Global engineering rules

1. Plain ES modules, relative imports with `.js` extension. No npm, no bundler, no TypeScript.
2. **No top-level access** to `window`, `document`, `localStorage`, `navigator`, `matchMedia`,
   `speechSynthesis`, `HTMLElement` etc. in ANY module — only inside functions. Every module must
   be importable under JavaScriptCore (`jsc -m`) so `tests/imports.test.js` can verify the module
   graph links (all named imports exist).
3. Tests: `tests/<module>.test.js` using `import { test, expect, run } from './harness.js'` and
   ending with `await run('<file name>')`. Run with `tests/run.sh` (or `tests/run.sh <filter>`).
   jsc has no `console` — never call console in pure modules.
4. UI copy in German with Swiss spelling (`ss`, never `ß`). Code identifiers/comments in English.
5. Styling only through CSS custom properties from `styles/tokens.css`; class names prefixed per
   screen (`dash-`, `ed-`, `set-`, `wr-`, `st-`), shared components prefixed `ui-`.
6. Accessibility: semantic elements, labels, `aria-live` for feedback, visible `:focus-visible`
   rings, 44 px touch targets, `prefers-reduced-motion` respected.
7. Keep files focused; split if a file exceeds ~600 lines.

## Visual direction (all UI work)

Calm, refined, minimal — the clarity of Things 3 / Linear with the friendliness of a study app.
Generous whitespace, one confident indigo-violet accent, soft layered shadows, rounded corners
(12–20 px), crisp typography (system UI stack; prompt text large and airy), subtle motion
(150–250 ms, ease-out), satisfying feedback states (success green pulse, error gentle shake).
Never cluttered, never generic-bootstrap. Light + dark themes from day one.

Starting tokens (refine, but keep names):
```
--bg #F5F6FA  --surface #FFFFFF  --surface-2 #EFF1F6  --surface-3 #E6E9F0  --border #E2E5ED
--text #161922  --text-2 #4A5163  --text-3 #7A8194
--accent #5146E5  --accent-hover #4338CA  --accent-soft #ECEBFD  --accent-contrast #FFFFFF
--success #12A150 --success-soft #E6F6EC  --danger #E5484D --danger-soft #FDECEC
--warning #D9930D --warning-soft #FFF4DB
dark: --bg #0E1016 --surface #161922 --surface-2 #1D212B --surface-3 #252A36 --border #2A2F3B
      --text #ECEEF3 --text-2 #B3B9C7 --text-3 #828A9C --accent #7B74FF --accent-soft #23214A
--radius-sm 8px --radius 14px --radius-lg 20px; spacing scale 4/8/12/16/20/24/32/40/56/72
--shadow-1 0 1px 2px rgb(16 24 40 / .06), 0 1px 3px rgb(16 24 40 / .08)
--shadow-2 0 4px 12px -2px rgb(16 24 40 / .08), 0 2px 6px -2px rgb(16 24 40 / .05)
--shadow-3 0 18px 40px -12px rgb(16 24 40 / .22)
--font-ui: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Inter, system-ui, sans-serif
--font-display: ui-rounded, "SF Pro Rounded", -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif
--ease: cubic-bezier(.2,.8,.2,1)
```
Theme switching: `<html data-theme="light|dark">`; when setting is `system`, follow
`prefers-color-scheme` (set the attribute from JS and listen for changes).

## Workstreams

### W1 Foundation (files: `index.html`, `Start.command`, `assets/icon.svg`, `src/ui/study-options.js`,
`styles/tokens.css`, `styles/base.css`, `styles/components.css`, `src/main.js`, `src/router.js`,
`src/lib/dom.js`, `src/lib/id.js`, `src/lib/time.js`, `src/lib/labels.js`, `src/lib/speech.js`,
`src/lib/keyboard.js`, `src/ui/icons.js`, `src/ui/components.js`, stub `src/screens/*.js` and empty
`styles/screens/*.css` (dashboard, editor, set, write, settings), `tests/id.test.js`,
`tests/time.test.js`, `tests/imports.test.js`)
- `index.html`: `<html lang="de-CH">`, meta viewport, theme-color, favicon, links all CSS files
  (tokens, base, components, screens/*), header markup container, `<main id="app">`,
  `<div id="toasts" aria-live="polite">`, `<script type="module" src="src/main.js">`.
- `Start.command` (chmod +x): cd to its dir; if port 4173 is already in use just
  `open http://localhost:4173/` and exit; otherwise schedule `(sleep 1; open http://localhost:4173/) &`
  and run `python3 serve.py` in the foreground. Print a friendly German message ("Wortschatz läuft …
  Dieses Fenster offen lassen. Zum Beenden das Fenster schliessen."). Check python3 exists; if not,
  explain in German how to install it.
- `src/ui/study-options.js` per spec §4.3 (used by Settings and the Write-mode options modal).
- `main.js`: apply theme from `db.getSettings()`, render header (logo mark + "Wortschatz" link to
  `#/`, right side: settings icon button), start router. Catch boot errors → friendly message.
- Router, dom, ui kit, icons, lib per spec §4.1–4.4. Components must be polished (hover/active/
  focus/disabled states, dark mode). Toasts stack bottom-center. Modal with focus trap.
- Stub screens: each exports `render(outlet, ctx)` showing a placeholder heading, so the app boots.
- `tests/imports.test.js`: dynamically imports EVERY `.js` module under `src/` (list them
  explicitly) and asserts key exports exist (e.g. `typeof h === 'function'`). Later workstreams
  append to the list.

### W2 Store & mastery (files: `src/store/db.js`, `src/store/backup.js`, `src/core/mastery.js`,
`tests/db.test.js`, `tests/mastery.test.js`) — spec §3, §4.5, §4.6, §4.12. db uses
`mastery.applyAnswer/applyOverride`, `lib/id.js` `uid()` (W1 writes it; if missing when you start,
write a minimal compatible `src/lib/id.js` exporting `uid()` — W1 will keep the same contract) and
`lib/time.js` `dateKey()` (same rule). Exhaustive tests with `memoryStorage()`.

### W3 Parser (files: `src/core/langdetect.js`, `src/core/parser.js`, `tests/langdetect.test.js`,
`tests/parser.test.js`, `tests/fixtures/*` except `user-example.txt`) — spec §4.8, §4.9. Create ≥ 12
realistic fixtures (see spec §6) and test each. The user example must yield exactly 52 cards with
correct term/definition pairs and no flags.

### W4 Grading (files: `src/core/grading.js`, `tests/grading.test.js`) — spec §4.10, ≥ 100 cases,
including every example from the user's list (articles, reflexives `s'appeler`/`se ressembler`/
`sich gleichen`, gender pairs `marié, mariée`, plural lists `le monsieur, messieurs`, `la rue`
↔ `die Strasse`/`Straße`, `ressembler à`).

### W5 Session engine (files: `src/core/session.js`, `tests/session.test.js`) — spec §4.11. Deterministic
tests via a seeded rng. Cover: rounds, retest of missed only, both directions, subsets, override,
finish, counters, finalStats, removeCard, JSON round-trip of state.

### W6 Import adapters (files: `src/import/layout.js`, `src/import/pdf.js`, `src/import/ocr.js`,
`src/import/files.js`, `tests/layout.test.js`) — spec §4.13. Browser-only code lazy-loads CDN libs
(pinned URLs in spec §2). `layout.js` pure + well tested (two columns, four columns, wrapped lines,
paragraph gaps, slight y jitter).

### W7 Dashboard + Settings screens (files: `src/screens/dashboard.js`, `src/screens/settings.js`,
`styles/screens/dashboard.css`, `styles/screens/settings.css`) — spec §5.1, §5.5.

### W8 Editor screen (files: `src/screens/editor.js`, `styles/screens/editor.css`, optional helper
`src/screens/editor-import.js`) — spec §5.2. Uses `parseVocab`, `readImportFile`.

### W9 Set screen (files: `src/screens/set.js`, `styles/screens/set.css`) — spec §5.3.

### W10 Write mode (files: `src/screens/write.js`, `styles/screens/write.css`, optional helpers
`src/screens/write-*.js`) — spec §5.4. The heart of the app: must feel exactly like Quizlet's Write
mode, fast and keyboard-driven.

### W11 Integration (any file, minimal edits) — after all others: run `tests/run.sh`, extend
`tests/imports.test.js` with all modules, statically cross-check every named import against the
target module's exports, check every `styles/screens/*.css` is linked in `index.html`, fix wiring
bugs, and report.

## Verification (main session, after the workflow)
1. `tests/run.sh` green.
2. Browser QA on `http://localhost:4173` (built-in browser): create a set from the user example,
   check the 52 parsed pairs, run a full Write session (correct, incorrect, copy, override, don't
   know, round 2, finish, missed-only replay), options toggles, resume after reload, dark mode,
   mobile width, settings backup export/import.
3. Review workflow (adversarial lenses: grading, parser, session/UX fidelity, visual/a11y) → fixes.
