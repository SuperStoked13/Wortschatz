# Wortschatz — Vocabulary Trainer (Quizlet-style Write mode) — Design Spec

Date: 2026-10-11 · Status: approved by user ("build directly")

## 1. Goal & context

A personal, Quizlet-like web app **for learning vocabulary only**. The user (native German speaker,
Swiss spelling — writes `ss` instead of `ß`) learns French (and sometimes English). The only study
mode for now is Quizlet's **Write mode** (see a prompt, type the answer). Must feel as intuitive as
Quizlet and look beautiful and simple.

Decisions made with the user:

| Topic | Decision |
|---|---|
| Platform | Web app, **zero build step**, plain HTML/CSS/JS ES modules. Node is NOT installed. |
| Run | Double-click `Start.command` → `python3 -m http.server 4173` → opens `http://localhost:4173/` |
| UI language | **German only** (strings inline in German; no i18n framework). Swiss style: use `ss`, never `ß`, in UI copy. |
| Import sources | Paste text (always), `.txt` / `.csv` / `.tsv` / Quizlet export, **PDF**, **photos (OCR)**. Not Word. |
| Storage | This device only — `localStorage`. JSON backup export/import. No accounts/sync. |
| Mastery | A card is **gemeistert** after **2 correct answers in a row** (across rounds and sessions). |
| Out of scope | Flashcards, Learn (multiple choice), Test, Match, accounts/sync, Word import, images on cards, folders. |

Data lives in the browser's localStorage for origin `http://localhost:4173` — the port must stay fixed.

## 2. Architecture

```
index.html                 app shell: <header> + <main id="app">; loads styles + src/main.js (type=module)
Start.command              macOS double-click launcher (fixed port 4173, opens browser)
assets/icon.svg            favicon / logo mark
styles/tokens.css          design tokens (colors, type, spacing, radii, shadows, motion) light + dark
styles/base.css            reset, typography, layout primitives, focus rings, utilities
styles/components.css      buttons, inputs, toggles, segmented, cards, chips, modal, toast, menu, progress
styles/screens/*.css       one file per screen: dashboard.css, editor.css, set.css, write.css, settings.css
src/main.js                boot: apply theme, mount header, start router
src/router.js              hash router
src/lib/dom.js             h() hyperscript + helpers
src/lib/id.js              uid()
src/lib/time.js            German relative time, date keys
src/lib/labels.js          shared German labels (languages, statuses, grading notes/hints)
src/lib/speech.js          text-to-speech wrapper (Web Speech API)
src/lib/keyboard.js        accent/special-character sets per language
src/ui/icons.js            inline SVG icon set
src/ui/components.js       UI kit (buttons, toggles, modal, toast, menu, progress, …)
src/store/db.js            persistence API over localStorage (factory + default instance)
src/store/backup.js        JSON export/import, Quizlet-format text export
src/core/text.js           shared text normalisation primitives
src/core/langdetect.js     line/column language identification (fr/de/en/es/it)
src/core/parser.js         smart vocab-list parser
src/core/grading.js        answer grading with tolerance options + char diff
src/core/session.js        Write-mode session engine (pure, serialisable state machine)
src/core/mastery.js        card status + set progress + streak computations
src/import/layout.js       positioned text items → lines with column tabs (pure)
src/import/pdf.js          lazy pdf.js loader + extraction
src/import/ocr.js          lazy tesseract.js loader + recognition
src/import/files.js        File → text dispatcher
src/screens/dashboard.js   #/                      set overview
src/screens/editor.js      #/new, #/set/:id/edit   create/edit + smart import
src/screens/set.js         #/set/:id               set detail
src/screens/write.js       #/set/:id/write         Write mode
src/screens/settings.js    #/settings              settings + backup
tests/harness.js           test(), expect(), run() — runs under `jsc -m` (macOS JavaScriptCore)
tests/run.sh               runs all tests/*.test.js; `tests/run.sh grading` filters
tests/*.test.js            unit tests for all pure modules
tests/fixtures/*.txt       sample vocab lists in many layouts
```

Rules for all modules:
- ES modules, relative imports **with `.js` extension**, no bundler, no npm, no TypeScript.
- `src/core/*`, `src/import/layout.js`, `src/store/*` (with injected storage), `src/lib/time.js`,
  `src/lib/id.js` must be **pure / DOM-free** so they run under `jsc` (no `window`, `document`,
  `localStorage` at import time; `crypto.randomUUID` may be missing in jsc → fallback).
- jsc has no `console`; use only in browser code. Tests use `print` via the harness.
- External code only lazily from jsDelivr, pinned versions:
  - `https://cdn.jsdelivr.net/npm/pdfjs-dist@4.10.38/build/pdf.min.mjs` (+ `pdf.worker.min.mjs`)
  - `https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js` (UMD global `Tesseract`)
- Everything else works offline.

## 3. Data model (stored JSON)

```js
Set = {
  id: string,
  title: string,
  description: string,           // may be ''
  termLang: 'fr'|'en'|'es'|'it'|'de'|'other',   // language being learned (card.term side)
  defLang:  'fr'|'en'|'es'|'it'|'de'|'other',   // usually 'de' (card.definition side)
  cards: Card[],                 // order = user order
  studyOptions: Partial<StudyOptions> | null,   // per-set overrides (Write options remembered per set)
  createdAt: number, updatedAt: number, lastStudiedAt: number|null   // epoch ms
}
Card = { id: string, term: string, definition: string, starred: boolean }

CardProgress = {
  correct: number, incorrect: number,
  streak: number,                // consecutive correct answers (mastered when >= 2)
  streakBefore: number,          // streak value before the last answer (for "Ich hatte recht" override)
  lastResult: 'correct'|'incorrect'|null,
  lastAnsweredAt: number|null
}
// status: 'mastered' if streak >= 2; 'learning' if correct+incorrect > 0; else 'new'

StudyOptions = {
  answerWith: 'term'|'definition'|'both',
     // 'term'       → prompt shows definition (German), user types the term (target language)  [DEFAULT]
     // 'definition' → prompt shows term, user types the definition (German)
     // 'both'       → each card asked in both directions (2 questions per card)
  shuffle: true,
  copyAnswer: true,      // after a miss the user must type the correct answer once to continue
  autoAdvance: true,     // after a correct answer continue automatically after ~900 ms
  audio: false,          // auto-read the target-language side aloud when shown/revealed
  tolerance: {
    articles: true,      // missing article/reflexive pronoun accepted (wrong article stays wrong)
    abbreviations: true, // etw.=etwas, jdn.=jemanden, sth=something, qc=quelque chose, …
    multipleAnswers: true, // one of several comma/semicolon separated answers is enough
    parentheses: true,   // content in (…) optional
    ignoreCase: true,
    ignoreAccents: false, // é=e, ä=a=ae, ç=c …
    typos: false         // 1 edit (2 for long words) accepted
  }
}

Settings = { theme: 'system'|'light'|'dark', study: StudyOptions /* defaults for sets */ }
Activity = { [dateKey 'YYYY-MM-DD' local]: number /* answers that day */ }
```

localStorage keys (prefix `wortschatz:v1:`): `sets` (array of Set), `progress:<setId>`
(map cardId→CardProgress), `session:<setId>` (SessionState or absent), `settings`, `activity`, `meta`
(`{schemaVersion: 1}`). Writes are synchronous; reads parse once and are cached in memory per db
instance (cache invalidated on write and on the `storage` event from other tabs).

## 4. Module contracts

### 4.1 `src/lib/dom.js`
```js
export function h(tag, props = null, ...children) -> Element
  // tag: element name ('div', 'button', 'svg' children via icons.js only)
  // props: { class: string|Array<string|false|null>, style: string|object, dataset: object,
  //          ref: (el) => void, html: string (innerHTML, use sparingly),
  //          onClick/onInput/onKeydown/... → addEventListener(lowercased name without 'on'),
  //          value/checked/disabled/hidden/selected/autofocus/indeterminate → set as properties,
  //          for → htmlFor, everything else → setAttribute (null/false skipped, true → '')
  // children: Node | string | number | null | undefined | boolean | Array (flattened); falsy & booleans skipped
export function clear(el) -> el
export function $(sel, root = document) / $$(sel, root = document) -> Element|null / Element[]
export function on(el, type, selector, handler) -> off()   // delegated event listener
export function focusFirst(container)                     // focus first [autofocus] or input
```

### 4.2 `src/router.js`
```js
export function startRouter(outlet: Element)     // listens to hashchange; renders matching route
export function navigate(path: string, { replace = false } = {})  // path like '/set/abc/write?subset=starred'
export function currentRoute() -> { name, params, query }
export function setLeaveGuard(fn: (() => boolean | Promise<boolean>) | null)
  // while set, a hash change first calls fn(); if it resolves false the previous hash is restored
  // (no re-render). Guard is cleared automatically on successful route change. Editor uses it
  // for "Ungespeicherte Änderungen verwerfen?".
// Routes:  '/' → dashboard, '/new' → editor, '/set/:id' → set, '/set/:id/edit' → editor,
//          '/set/:id/write' → write, '/settings' → settings, unknown → dashboard
// Screen module contract:  export function render(outlet, { params, query }) -> (cleanup?: () => void)
// Router: calls previous cleanup, clears outlet, scrolls to top, sets document.title, adds
// `screen-enter` class for a subtle fade/slide-in.
```

### 4.3 `src/ui/components.js` (all return Elements; all German labels passed in by caller)
```js
button({ label, icon, iconRight, variant='secondary'|'primary'|'ghost'|'danger'|'success',
         size='md'|'sm'|'lg', onClick, type='button', disabled, title, kbd, block, attrs })
iconButton({ icon, label /* aria-label + tooltip */, onClick, variant='ghost', size='md', pressed })
toggle({ label, description, checked, onChange(checked), id })        // accessible switch
segmented({ options: [{ value, label, icon }], value, onChange(value), ariaLabel, size })
textField({ label, value, placeholder, onInput(value), multiline, rows, autofocus, id, attrs })
chip({ label, tone='neutral'|'accent'|'success'|'warning'|'danger', icon })
progressBar({ value /*0..1*/, tone='accent', label })                // returns el with el.update(v)
masteryBar({ mastered, learning, fresh, showLegend=false })          // stacked bar, counts
ring({ value /*0..1*/, size=88, label, sublabel })                    // circular progress
openModal({ title, content: Node, actions: [{ label, variant, onClick, close=true }], onClose,
            size='md'|'lg' }) -> { close(), el }     // focus trap, Esc closes, backdrop click closes
confirmDialog({ title, message, confirmLabel='Löschen', cancelLabel='Abbrechen', danger=true }) -> Promise<boolean>
toast(message, { tone='neutral'|'success'|'danger', duration=3500, action: { label, onClick } })
menu(anchorEl, items: [{ label, icon, onClick, danger, divider }])  // popover, keyboard navigable
emptyState({ icon, title, text, action: Node })
kbd(text) -> <kbd>
```
`src/ui/study-options.js` (shared by Write-mode options modal and Settings):
```js
export function studyOptionsForm({ options /* full StudyOptions */, termLang = 'fr', defLang = 'de',
                                   onChange(patch /* deep partial StudyOptions */), compact = false }) -> Element
  // Sections: "Abfrage" — segmented "Antworten auf" (<termLang name> | <defLang name> | Beides),
  //   toggles Mischen, Richtige Antwort abtippen, Automatisch weiter, Vorlesen;
  // "Toleranz" — the 7 tolerance toggles, each with a one-line German example.
```
`src/ui/icons.js`: `export function icon(name, { size = 20, className } = {}) -> SVGElement` with at
least: plus, search, settings, star, starFilled, edit, trash, copy, download, upload, play, check, x,
arrowLeft, arrowRight, chevronRight, chevronDown, volume, more, rotate, sun, moon, monitor, image,
fileText, sparkles, shuffle, keyboard, flame, book, swap, alert, info, eye, filter, grip, clipboard,
camera, layers, target, trophy, clock. Stroke icons (24-grid, 1.75 stroke, currentColor).

### 4.4 `src/lib/*`
```js
// id.js
export function uid() -> string        // 12+ char url-safe random id; works without crypto
// time.js
export function dateKey(ts = Date.now()) -> 'YYYY-MM-DD' (local)
export function relativeTime(ts, now = Date.now()) -> 'gerade eben' | 'vor 5 Minuten' | 'vor 2 Stunden' | 'gestern' | 'vor 3 Tagen' | 'am 12.09.2026'
export function formatDuration(ms) -> '4 Min. 12 Sek.' | '45 Sek.'
// labels.js
export const LANGS = { fr: { name: 'Französisch', short: 'FR', bcp47: 'fr-FR' }, en: {…'Englisch','EN','en-GB'},
  es: {'Spanisch','ES','es-ES'}, it: {'Italienisch','IT','it-IT'}, de: {'Deutsch','DE','de-CH'}, other: {'Andere','—', ''} }
export const STATUS = { new: 'Neu', learning: 'Am Lernen', mastered: 'Gemeistert' }
export const NOTE_LABELS = { article: 'Artikel fehlte', pronoun: 'Pronomen fehlte', abbreviation: 'Abkürzung',
  partial: 'Teilantwort', parentheses: 'Klammerinhalt weggelassen', case: 'Gross-/Kleinschreibung',
  accents: 'Akzente', typo: 'Tippfehler', order: 'Reihenfolge' }
export const HINT_LABELS = { wrongArticle: 'Falscher Artikel', missingArticle: 'Artikel fehlt',
  accentsOnly: 'Nur die Akzente stimmen nicht', caseOnly: 'Nur Gross-/Kleinschreibung falsch',
  typo: 'Fast – ein kleiner Tippfehler', almost: 'Knapp daneben' }
export function plural(n, one, other) -> `${n} ${n === 1 ? one : other}`
// speech.js (browser only)
export function canSpeak() -> boolean
export function speak(text, langCode /* 'fr' etc. */) -> void   // picks best voice for LANGS[lang].bcp47, cancels previous
// keyboard.js
export const SPECIAL_CHARS = { fr: ['é','è','ê','ë','à','â','ç','î','ï','ô','û','ù','ü','œ','æ'],
  de: ['ä','ö','ü','Ä','Ö','Ü'], es: ['á','é','í','ó','ú','ñ','ü','¿','¡'], it: ['à','è','é','ì','ò','ù'], en: [], other: [] }
```

### 4.5 `src/store/db.js`
```js
export function createDb(getStorage /* () => Storage-like {getItem,setItem,removeItem} */) -> Db
export const db = createDb(() => globalThis.localStorage)   // default instance; storage resolved lazily
export function memoryStorage() -> Storage-like             // for tests

Db API (all synchronous):
  listSets() -> Set[]                          // sorted: lastStudiedAt/updatedAt desc
  getSet(id) -> Set|null
  createSet({ title, description='', termLang, defLang='de', cards: [{term, definition, starred?}] }) -> Set
  updateSet(id, patch) -> Set
     // patch may contain title/description/termLang/defLang/cards/studyOptions.
     // cards: array of {id?, term, definition, starred?}; cards keep id when given; new ones get uid();
     // progress entries for removed card ids are deleted; an active session is cleared if cards changed
     // structurally (ids added/removed) — text edits keep the session.
  deleteSet(id)                                // also removes progress + session
  duplicateSet(id) -> Set                      // title + ' (Kopie)', fresh ids, no progress
  updateCard(setId, cardId, { term?, definition?, starred? }) -> Card
  toggleStar(setId, cardId) -> boolean         // new starred value
  getProgress(setId) -> { [cardId]: CardProgress }
  recordAnswer(setId, cardId, correct: boolean, at = Date.now()) -> CardProgress
     // updates counts/streak/streakBefore/lastResult/lastAnsweredAt, set.lastStudiedAt, activity[dateKey(at)] += 1
  overrideLastAnswer(setId, cardId) -> CardProgress
     // only if lastResult === 'incorrect': incorrect -= 1, correct += 1, streak = streakBefore + 1, lastResult='correct'
  resetProgress(setId)                         // clears progress + session
  getSession(setId) -> SessionState|null ; saveSession(setId, state) ; clearSession(setId)
  getSettings() -> Settings (defaults merged deep) ; updateSettings(patch /* deep merge */) -> Settings
  getStudyOptions(setId) -> StudyOptions       // deep merge: DEFAULT_STUDY_OPTIONS ← settings.study ← set.studyOptions
  updateStudyOptions(setId, patch /* deep */) -> StudyOptions   // stored on the set
  getActivity() -> Activity
  exportAll() -> { app: 'wortschatz', version: 1, exportedAt, sets, progress: {setId: map}, settings, activity }
  importAll(data, { mode = 'merge'|'replace' }) -> { setsAdded, setsUpdated }
     // validates shape; merge: sets with same id are replaced by imported, others added
  subscribe(fn) -> unsubscribe                 // called after every write (and on cross-tab storage events)
export const DEFAULT_STUDY_OPTIONS, DEFAULT_SETTINGS
```
Robustness: corrupt JSON in a key → treat as empty (never crash); quota errors → throw an
Error with `code = 'QUOTA'` so the UI can show a toast.

### 4.6 `src/store/backup.js`
```js
export function downloadJson(filename, data)          // browser: Blob + <a download>
export function readJsonFile(file) -> Promise<object>
export function setToText(set, { termSep = '\t', cardSep = '\n' }) -> string   // Quizlet-compatible export
export function downloadText(filename, text)
```

### 4.7 `src/core/text.js`
```js
export function normalizeBasic(s) -> string
  // NFC; NBSP/thin spaces → ' '; curly/backtick/acute apostrophes (’ ‘ ` ´ ʼ ′) → "'";
  // dashes (– — ‒ ‐ −) → '-'; collapse whitespace; trim
export function stripDiacritics(s) -> string    // NFD, remove \p{M}, NFC; ß→ss, œ→oe, æ→ae, ø→o
export function foldUmlauts(s) -> string        // ä→ae ö→oe ü→ue (both cases) then stripDiacritics
export function isLetter(ch) -> boolean          // \p{L}
```

### 4.8 `src/core/langdetect.js`
```js
export const SUPPORTED = ['fr', 'de', 'en', 'es', 'it']
export function scoreLanguages(text) -> { fr, de, en, es, it }   // non-negative scores, higher = more likely
export function detectLanguage(text) -> { lang: 'fr'|'de'|'en'|'es'|'it'|'unknown', confidence: 0..1 }
export function detectColumn(lines: string[]) -> { lang, confidence }  // aggregate over many short lines
```
Signals: leading articles (le/la/les/l'/un/une/des/du/se/s' ; der/die/das/den/dem/des/ein/eine/sich ;
the/a/an/to ; el/la/los/las/un/una ; il/lo/la/i/gli/le/l'/un/uno/una), diacritics (é è ê ç œ → fr;
ä ö ü ß → de; ñ á í ó ú ¿ ¡ → es; ì ò → it), capitalised noun after article (de), suffixes
(-tion -eux -euse -ment -é -ée -ier -oir → fr; -ung -heit -keit -lich -isch -chen -schaft -ieren → de;
-ing -ly -ness -ful → en; -ción -dad → es; -zione -tà → it), frequent function words, character
n-grams such as `sch`, `ch`, `qu`, `ou`, `eau`, `th`, `w`, `k`, `z`. Must classify the user's example
list correctly line by line with high accuracy (≥ 95% of lines), especially short lines like `brave`,
`calme`, `sage`, `lieb`, `ruhig` (when a single line is ambiguous, column context decides).

### 4.9 `src/core/parser.js` — smart import
```js
export function parseVocab(text, opts = {}) -> ParseResult
opts = {
  mode: 'auto' | 'delimiter' | 'lines',   // default 'auto'
  delimiter: string,                      // used when mode === 'delimiter' (e.g. '\t', ',', ';', ' - ', '=', ':')
  cardSeparator: '\n' | ';' | string,     // used when mode === 'delimiter' (default newline)
  termLang: lang hint (optional), defLang: lang hint (optional, default 'de'),
  orient: true,                           // auto-swap so the German side becomes the definition
  swap: false                             // force swap after orientation (user pressed "Seiten tauschen")
}
ParseResult = {
  cards: [{ term, definition, confidence /*0..1*/, flags: string[], lines: number[] /* 1-based source lines */ }],
  format: 'delimited' | 'alternating' | 'blocks' | 'columns' | 'empty',
  delimiter: string | null,               // detected/used delimiter for 'delimited'
  termLang, defLang,                      // detected (or hinted) languages
  swapped: boolean,                       // true when sides were auto-swapped
  skipped: [{ line, text, reason: 'heading'|'pageNumber'|'noise'|'unpaired' }],
  warnings: string[]                      // German, human-readable, e.g. 'Zeile 14 konnte nicht zugeordnet werden.'
}
// flags: 'merged' (continuation line merged), 'lowConfidence', 'langMismatch', 'missingTerm',
//        'missingDefinition', 'duplicate'
```
Algorithm requirements:
1. **Preprocess**: strip BOM; normalise line endings; `normalizeBasic` per line but keep tabs;
   remove leading bullets/numbering (`1.`, `1)`, `a)`, `•`, `-`, `*`, `–`, `▪`) only when it is a list
   marker (followed by space); drop lines that are only page numbers / `Seite 3` / `- 3 -`.
2. **Delimited detection**: for candidate delimiters in priority order `\t`, ` - `, ` – `, ` — `, ` = `,
   `=`, ` : `, `;`, `|`, ` → `, `->`, `,` (comma last and only if it yields exactly 2 parts on ≥ 80% of
   lines and the parts look like different languages), and 2+ spaces (PDF columns), pick the one
   that splits ≥ 70% of non-empty lines into exactly 2 non-empty parts (split on the FIRST occurrence
   for multi-char delimiters like ` - `; for tab, cells beyond 2 → if exactly 4 cells, emit 2 cards).
   Support quoted CSV (`"a, b","c"`). Quizlet export = tab + newline.
3. **Line-based (no delimiter)**: group non-empty lines into blocks separated by blank lines.
   - most blocks have exactly 2 lines → `blocks`: each block = (term, definition) — the user's example.
   - no blank lines or all blocks 1 line → `alternating`: pair consecutive lines.
   - mixed → use per-line language detection to pair: a line whose language equals the previous
     line's side is a continuation (wrapped) → merge with `, ` and flag `merged`.
   - **columns**: if the first half of lines is one language and the second half the other
     (e.g. OCR read a two-column page column-by-column) → pair i with i + n/2.
4. **Orientation**: detect each side's language with `detectColumn`. If `orient` and the left side
   is German (or matches `defLang` hint) while the right isn't → swap so `term` = learned language,
   `definition` = German. Set `swapped`.
5. **Confidence**: per card from language agreement with its column; < 0.5 → `lowConfidence` flag.
   Mismatching line language vs column → `langMismatch`.
6. Must parse the user's example (`tests/fixtures/user-example.txt`) into exactly **52** cards in order,
   e.g. `{term: 'le monsieur, messieurs', definition: 'der Herr'}`, last `{term: 'moche', definition: 'hässlich'}`,
   format `blocks`, termLang `fr`, defLang `de`, no flags on any card.
7. Never throws on any input; empty input → `format: 'empty'`, `cards: []`.

### 4.10 `src/core/grading.js`
```js
export function grade(given, expected, tolerance, lang /* language of the expected answer */) -> GradeResult
GradeResult = {
  correct: boolean,
  exact: boolean,            // equal after basic normalisation only (whitespace, apostrophes, ß=ss, trailing punctuation)
  notes: Array<'article'|'pronoun'|'abbreviation'|'partial'|'parentheses'|'case'|'accents'|'typo'|'order'>,
  hint: null | 'wrongArticle' | 'missingArticle' | 'accentsOnly' | 'caseOnly' | 'typo' | 'almost',
  expectedDisplay: string    // the expected answer as stored (for "Genau:" display)
}
export function splitAlternatives(expected, lang /* optional, language of expected */) -> string[]
export function diffChars(given, expected) -> Array<{ type: 'same'|'add'|'del', text: string }>
  // character-level diff for highlighting; 'del' = in given but not expected, 'add' = missing from given
export function diffAnswer(given, expected) -> same shape as diffChars
  // diffChars after the normalisation grading treats as equal (apostrophes, spaces, ß ≡ ss, œ ≡ oe),
  // so the Write feedback only highlights real mistakes
export const ARTICLES = { fr: [...], de: [...], en: [...], es: [...], it: [...] }
export const REFLEXIVES = { fr: ['se ', "s'"], de: ['sich '], en: ['oneself'], es: [], it: [] }
export const ABBREVIATIONS = [ [/regex/, 'canonical'], ... ]
```
Rules (apply to both `given` and each expected variant):
- **Always**: `normalizeBasic`; `ß` ≡ `ss`; `œ` ≡ `oe`; `æ` ≡ `ae`; hyphen ≡ space; ignore
  punctuation `. , ! ? ; : " « » ‹ › ¿ ¡ … ~ *` except apostrophes; collapse spaces. Empty given → incorrect.
- **multipleAnswers**: split expected into alternatives on top-level `,` `;` and `/` (`/` only when
  both sides have ≥ 3 letters and no space on either side, e.g. `beau/belle`, never `Lehrer/in`).
  Given may contain several parts (split the same way) → correct if every given part matches some
  alternative (`partial` note if not all alternatives given, `order` if all given but reordered).
  If OFF → all alternatives required (any order; note `order` if reordered).
- **parentheses**: ON → each alternative has variants with paren content removed and with paren
  chars removed (`(sich) freuen` → `freuen` | `sich freuen`; `marié(e)` → `marié` | `mariée`).
  Note `parentheses` when content was omitted. OFF → only the "paren chars removed" variant.
- **articles** (language `lang`): leading article / reflexive pronoun. Given without article but
  expected has one → ON: correct + note `article` (or `pronoun` for se/s'/sich); OFF: incorrect, hint
  `missingArticle`. Given article ≠ expected article (e.g. `la monsieur`, `den Herr`) → incorrect,
  hint `wrongArticle`, regardless of the toggle. Given has article, expected doesn't → ignore it.
  `l'` elision: `l'homme` = article `l'` + `homme`; given `homme` OK when ON; `le homme` ≡ `l'homme`.
  English: `to` before verbs counts as a particle (`appear` for `to appear` → note `article`).
  Articles per lang: fr `le la les l' un une des du de la de l'` ; de `der die das den dem des ein eine
  einen einem einer eines` ; en `the a an to` ; es `el la los las un una unos unas` ; it `il lo la i gli le l' un uno una un'`.
  Only strip German articles when `lang === 'de'`, etc. (English "die" is a verb!). `other` → none.
- **abbreviations** ON → expand on both sides before comparing (case-insensitive, optional trailing
  dot): `etw`→`etwas`, `jd`→`jemand`, `jdn`→`jemanden`, `jdm`→`jemandem`, `jds`→`jemandes`,
  `sth`/`s.th.`/`smth`→`something`, `sb`/`s.b.`/`smb`/`s.o.`/`someone`→`somebody`,
  `qc`/`qch`/`qqch`→`quelque chose`, `qn`/`qqn`→`quelqu'un`, `z.B.`→`zum beispiel`, `usw.`→`und so weiter`,
  `bzw.`→`beziehungsweise`, `od.`→`oder`, `u.`→`und` (only standalone `u.` with dot), `o.s.`/`oneself` kept.
  Note `abbreviation` when used. OFF → `etw.` vs `etwas` is a mismatch.
- **ignoreCase** ON → case-insensitive; note `case` when the only difference was case AND the
  expected side is German (noun capitalisation matters). OFF → hint `caseOnly` if only case differs.
- **ignoreAccents** ON → compare `stripDiacritics` forms and `foldUmlauts` forms (`Strasse`, `Haeuser`
  accepted); note `accents`. OFF → hint `accentsOnly` if only diacritics differ.
- **typos** ON → Damerau-Levenshtein ≤ 1 for strings with ≥ 4 letters, ≤ 2 for ≥ 10 letters
  (after all other normalisation), note `typo`. OFF → hint `typo` when within that distance.
  Otherwise hint `almost` when similarity ≥ 0.75.
- Tolerances combine (e.g. missing article + accent fold). The result notes list every tolerance used.

**Synonyms** (`src/core/synonyms.js`, used by Write mode via `write-model.js gradeQuestion`):
`gradeWithSynonyms(given, card, cards, ask, tolerance, answerLang) -> { result: GradeResult, matchedCard: Card|null }`.
An answer that is wrong for the asked card but correct for another card of the set whose prompt side
shares an alternative (`hässlich` → `laid, laide` and `hässlich` → `moche`) counts as correct with
the extra note `'synonym'` (first in `notes`); `expectedDisplay` stays the asked card's answer. The
copy step after a miss uses plain `grade` against the asked card.

### 4.11 `src/core/session.js` — Write-mode engine (pure, JSON-serialisable state)
```js
export function createSession(cards: Card[], options: StudyOptions, { subset = 'all', rng = Math.random, now = Date.now(), progress = {} } = {}) -> SessionState
  // subset: 'all' | 'starred' | 'learning' (not mastered, per progress) | { cardIds: string[] } (e.g. "Falsche nochmal üben")
  // builds questions: answerWith 'term' → [{qid: cardId+':t', cardId, ask: 'term'}];
  //   'definition' → ask: 'definition'; 'both' → both per card. `ask` = the side the user must TYPE.
  // shuffles (Fisher–Yates with rng) if options.shuffle.
SessionState = {
  v: 1, setOptions: { answerWith, shuffle }, subset,
  questions: { [qid]: { qid, cardId, ask: 'term'|'definition' } },
  order: qid[],                   // all qids in initial order
  round: number,                  // 1-based
  queue: qid[],                   // remaining qids in the current round (front = current)
  roundAnswered: [{ qid, correct }],   // answers in the current round, in order
  rounds: [{ round, total, correct, incorrectQids: qid[] }],   // completed rounds
  done: qid[],                    // answered correctly (finished)
  attempts: { [qid]: number }, misses: { [qid]: number },
  firstTry: { [qid]: boolean },
  startedAt, updatedAt, finishedAt: number|null, elapsedMs: number
}
export function current(state) -> Question|null
export function answer(state, correct: boolean, now = Date.now()) -> SessionState   // records for current(), removes from queue
export function override(state, qid, now) -> SessionState   // last answer of qid in this round becomes correct
export function isRoundOver(state) -> boolean               // queue empty
export function roundSummary(state) -> { round, total, correct, incorrect, items: [{ qid, cardId, ask, correct }] }
export function nextRound(state, rng = Math.random, now) -> SessionState
  // closes the round into `rounds`; new queue = qids answered incorrectly this round (shuffled if option);
  // round += 1. If none incorrect → finished (finishedAt set).
export function isFinished(state) -> boolean                // every qid in done
export function counters(state) -> { remaining, correct, incorrect, total, round, progress /*0..1 done/total*/ }
  // Quizlet semantics: remaining = queue length; incorrect = incorrect answers in current round;
  // correct = done.length (overall); progress = done.length / total.
export function finalStats(state) -> { total, firstTryCorrect, accuracy /*0..1 first try*/, rounds, elapsedMs,
                                       hardest: [{ cardId, misses }] /* desc, misses > 0, max 10 */, missedCardIds }
export function removeCard(state, cardId) -> SessionState   // when a card is deleted mid-session
export function tick(state, now) -> SessionState            // accumulates elapsedMs (cap gaps > 5 min)
```
Quizlet Write semantics: round 1 = all questions once. A missed question is not retried in the same
round. At round end the UI shows a summary; the next round contains only questions missed in the
previous round. Repeat until every question has been answered correctly once. A "Weiss ich nicht"
counts as incorrect. The copy-answer step does not change the result.

### 4.12 `src/core/mastery.js`
```js
export const MASTERY_STREAK = 2
export function cardStatus(progress?: CardProgress) -> 'new'|'learning'|'mastered'
export function setProgress(set, progressMap) -> { total, mastered, learning, fresh, percent /*0..100 mastered*/ }
export function studyStreak(activity, now = Date.now()) -> { current: number /* consecutive days ending today or yesterday */, today: number /* answers today */, longest }
export function applyAnswer(prev: CardProgress|undefined, correct, at) -> CardProgress   // used by db.recordAnswer
export function applyOverride(prev: CardProgress) -> CardProgress
```

### 4.13 `src/import/*`
```js
// layout.js (pure)
export function itemsToLines(items: [{ str, x, y, w, h }], { yTolerance = 0.5 /* × median height */, gapFactor = 2.2 } = {}) -> string[]
  // groups items into rows by y (top-origin), sorts by x; inserts '\t' where the horizontal gap >
  // gapFactor × median character width, otherwise ' '. Detects page-level column structure:
  // if rows consistently have 4 cells (term|def|term|def) emit left pairs first, then right pairs.
  // Emits '' between paragraphs when vertical gap > 1.8 × median line height.
// pdf.js (browser)
export async function extractPdfText(file: File|Blob, { onProgress(fraction, message) } = {}) -> string
  // dynamic import of pdf.min.mjs, workerSrc = pdf.worker.min.mjs; per page getTextContent →
  // items { str, x: transform[4], y: pageHeight - transform[5], w: width, h: height } → itemsToLines; pages joined with '\n\n'
// ocr.js (browser)
export async function recognizeImage(file: File|Blob, { langs = ['fra','deu'], onProgress } = {}) -> string
  // injects <script src=tesseract.min.js> once; Tesseract.createWorker(langs, 1, { logger }) ;
  // uses result.data.words bboxes → itemsToLines; terminates worker
export function ocrLangsFor(termLang) -> string[]   // fr→['fra','deu'], en→['eng','deu'], es→['spa','deu'], it→['ita','deu']
// files.js (browser)
export async function readImportFile(file, { termLang, onProgress }) -> { text, kind: 'text'|'pdf'|'image', name }
  // .txt/.csv/.tsv/.text/no-ext text/* → TextDecoder utf-8 (fatal) with windows-1252 fallback;
  // application/pdf or .pdf → extractPdfText; image/* (png, jpg, jpeg, heic*, webp, gif) → recognizeImage
  // unsupported → throws Error('Dieses Dateiformat wird nicht unterstützt.')
```

## 5. Screens & UX

Global: sticky header with logo mark + "Wortschatz", nav back where relevant, a settings icon.
Design: calm, minimal, generous whitespace, one accent colour (indigo/violet family), soft
shadows, 14–20 px radii, smooth 150–250 ms transitions, `prefers-reduced-motion` respected, dark
mode, responsive down to 360 px wide, keyboard-first with visible focus rings, ARIA live regions
for feedback. German copy, Swiss spelling (`ss`).

### 5.1 Dashboard `#/`
- Greeting + stats strip: Lernserie (🔥 days, from `studyStreak`), Heute beantwortet, Gemeistert total.
- "Deine Lernsets" grid of set cards: title, language pair chip (`FR → DE`), "52 Begriffe",
  `masteryBar`, "Zuletzt gelernt vor 2 Tagen" / "Noch nicht gelernt", primary quick action
  **Schreiben** (or **Fortsetzen** if a session is in progress), overflow menu (Bearbeiten,
  Duplizieren, Als Text exportieren, Löschen with confirm). Click card → set page.
- A prominent "+ Neues Lernset" tile (first in grid) and header button. Search field (filters by
  title/description/terms) + sort segmented (Zuletzt gelernt | Name | Neueste).
- Empty state with friendly illustration-ish icon + CTA "Erstes Lernset erstellen".

### 5.2 Editor `#/new`, `#/set/:id/edit`
- Title (required), description (optional), language pickers: "Ich lerne" (Französisch default,
  Englisch, Spanisch, Italienisch, Andere) and "Übersetzung" (Deutsch default).
- **Import panel** (prominent for new sets, collapsible "Importieren" for edits):
  big textarea "Füge deine Vokabelliste hier ein …", drop zone + "Datei wählen" (accept
  `.txt,.csv,.tsv,.pdf,image/*`), and ⌘V image paste. PDF/OCR show a progress bar and status
  ("Texterkennung läuft … 45 %"); the extracted text lands in the textarea so it can be corrected.
- Live parse (debounced 250 ms) → **detection bar**: "✨ 52 Paare erkannt · Abwechselnde Zeilen ·
  Französisch → Deutsch" + controls: Trennung `Automatisch | Tab | Komma | Strichpunkt | Bindestrich | Zeilenweise | Eigenes…`,
  "Seiten tauschen" button. Warnings listed. Low-confidence rows highlighted (amber left border + tooltip).
- **Cards table** (Quizlet-style rows): index, Begriff (term) | Definition, star, delete; each
  field is an auto-growing textarea; Tab from the last field adds a new row; drag handle optional
  (not required); "+ Karte hinzufügen". Import "Übernehmen" replaces or appends rows
  (choice when rows exist: "Ersetzen" / "Anhängen"). Duplicate terms flagged.
- Save: "Erstellen" / "Speichern" (⌘/Ctrl+Enter), disabled until title + ≥ 1 complete card.
  Leaving with unsaved changes → confirm. After create → navigate to the set page with toast.

### 5.3 Set page `#/set/:id`
- Title, description, language chip, "52 Begriffe", edit button, overflow (Duplizieren, Export,
  Fortschritt zurücksetzen, Löschen).
- Progress panel: `ring` with % gemeistert + legend (Gemeistert / Am Lernen / Neu counts).
- Study actions: big primary **Schreiben** (or **Fortsetzen · Runde 2 · 12 übrig** + secondary
  "Neu starten" when a session exists), secondary: "Nur markierte ★ (n)" (when n > 0),
  "Nur nicht gemeisterte (n)" (when some mastered).
- Terms list: filter chips Alle | Neu | Am Lernen | Gemeistert | ★ with counts; each row: term,
  definition, status dot/chip, star toggle, speaker button (TTS) for the term. Inline edit is via
  the editor.

### 5.4 Write mode `#/set/:id/write?subset=all|starred|learning|missed`
Layout: desktop → left sidebar (220 px) with set title, round label "Runde 2", counters
**Verbleibend · Falsch · Richtig** (big numbers), overall progress bar, "Optionen" button,
"Neu starten"; main column (max 720 px). Mobile → compact top bar with counters + progress.

Question view:
- Small label of the prompt side language ("Deutsch" / "Französisch"), the prompt in large type
  (clamp 28–44 px), speaker button when prompt is in the target language, star toggle.
- Answer input (large, autofocus, `autocomplete=off`, `autocapitalize=off`, `spellcheck=false`,
  `lang` = answer language) with placeholder "Antwort auf Französisch eingeben".
- Special-character bar for the answer language (buttons insert at caret, keep focus).
- Buttons: **Antworten** (primary, Enter) and **Weiss ich nicht** (ghost). Hint: "Enter ↵".

Feedback:
- **Correct** → input turns green, "Richtig!" with check animation; if `!exact` show "Genau:
  <expected>" plus note chips (e.g. "Artikel fehlte"). Auto-advance after 900 ms if `autoAdvance`
  (any key / Enter advances immediately); otherwise "Weiter" button.
- **Incorrect / Weiss ich nicht** → panel "Das lernst du noch!" (or "Nicht ganz.") with the prompt,
  "Deine Antwort" (with `diffAnswer` highlighting: wrong chars red strike, missing chars green
  underline) and "Richtige Antwort" (large, speaker), hint chip (e.g. "Falscher Artikel").
  Actions: "Ich hatte recht" (override → counts correct, `db.overrideLastAnswer`), "Bearbeiten"
  (edit the card's term/definition in a small modal; updates the set) and:
  - if `copyAnswer` → input "Tippe die richtige Antwort ab" (must grade correct to continue; wrong
    copy shakes); Enter submits.
  - else → "Weiter" button (Enter).

Round end → **round summary** screen: "Runde 1 geschafft", big % correct, counts, list of this
round's items (correct ✓ / incorrect ✗ with term ↔ definition), button **Weiter zu Runde 2**
(Enter). If none incorrect → finish.

Finish → **results** screen: celebration (subtle confetti/scale animation, reduced-motion safe),
"Geschafft!", stats (Begriffe, Erster Versuch richtig %, Runden, Zeit), "Am häufigsten falsch" list
(hardest), buttons: **Falsche nochmal üben** (new session with `{cardIds: missedCardIds}`, hidden
if none), **Nochmal von vorne**, **Zurück zum Lernset**.

Options modal (gear in sidebar; changes saved via `db.updateStudyOptions` and apply immediately to
grading; direction/shuffle/subset changes ask to restart the session):
- "Antworten auf": segmented `Französisch | Deutsch | Beides` (labels from set languages).
- Toggles: Mischen, Richtige Antwort abtippen, Automatisch weiter, Vorlesen.
- "Toleranz" group: Artikel/Pronomen vergessen erlaubt; Abkürzungen gleichwertig (etw. = etwas);
  Eine von mehreren Antworten genügt; Klammerinhalt optional; Gross-/Kleinschreibung ignorieren;
  Akzente ignorieren (é = e); Kleine Tippfehler erlauben. Each with a one-line example.

Persistence: after every answer → `db.recordAnswer` + `db.saveSession`; on finish → session kept
with `finishedAt` until user starts again (set page shows normal "Schreiben"). Leaving and
returning resumes ("Willkommen zurück – weiter geht's" toast).
Keyboard: Enter = submit/continue, Esc = close modal, `Ctrl/⌘+Enter`? not needed; `?` nothing.
Mid-session card edits/deletes handled via `removeCard`.

### 5.5 Settings `#/settings`
Theme segmented (System | Hell | Dunkel); default study options (same controls as the options
modal, saved to `settings.study`); Backup: "Backup exportieren" (JSON download
`wortschatz-backup-YYYY-MM-DD.json`), "Backup importieren" (file → merge/replace choice);
"Alle Daten löschen" (double confirm); About: storage note ("Deine Daten bleiben in diesem Browser
auf diesem Gerät.") + how to start (`Start.command`).

## 6. Testing

- `tests/run.sh` (jsc) must pass: harness, text, langdetect, parser (≥ 10 fixture layouts incl. the
  user example, tab, dash, equals, CSV with quotes, Quizlet export, German-first (auto-swap), wrapped
  definitions, blank-line-free alternating, two-column OCR order, numbered lists, English↔German),
  grading (≥ 80 cases covering every rule and toggle), session (rounds, override, both-direction,
  subsets, finish, removeCard), mastery, db (with `memoryStorage`), layout.
- Manual/agent browser QA via the built-in browser on `http://localhost:4173`.
