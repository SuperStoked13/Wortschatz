# Wortschatz for macOS: native SwiftUI app with Liquid Glass (spec)

Date: 2026-10-12. Requested by the user (in German):

> "verwandle es in eine native mac app, mit liquid glass und apple ui falls nicht bereits der fall mache es
> das man die app quasi nur mit der enter taste bedienen kann (also enter als weiter wie bei quizlet)"

The user decided that **the Mac app is the main app**. All logic is ported to Swift. The web version (`index.html`,
`src/`) stays as it is, for Windows, and must not be modified by this work. Data moves over through the web
app's backup JSON, which the Mac app imports.

**The reference implementation is the current JS code**, specifically `src/core/*.js`, `src/import/layout.js` and
`src/store/db.js`, together with its 827 tests in `tests/`. Port the code's actual behaviour. The older spec docs in
`docs/superpowers/specs/` describe intent, but where they disagree with the code, the code wins.

## 1. Environment & project layout

- **Toolchain:** Xcode 27.0, Swift 6.4, macOS 27 SDK.
- **Platform:** deployment target **macOS 26.0**, the first release with Liquid Glass. Apple Silicon.
- **Constraints:** Node is not installed. There is no git repo, so do not create one.
- **Developer account:** none. Signing is ad-hoc ("Sign to Run Locally", `CODE_SIGN_IDENTITY = "-"`, no team).
```
mac/
  Wortschatz.xcodeproj                 objectVersion 77, PBXFileSystemSynchronizedRootGroup folders (no per-file refs)
  Wortschatz/                          app target (synchronized folder) - SwiftUI app, macOS 26
    App/                               WortschatzApp (scenes, commands), AppModel (@Observable), Routing
    DesignSystem/                      glass components, colours, typography, KeyHint, backgrounds
    Features/Overview/  Features/Library/  Features/SetDetail/  Features/Editor/  Features/Import/
    Features/Learn/  Features/Write/  Features/Settings/
    Services/                          Speech (AVSpeechSynthesizer), OCR (Vision), PDFImport (PDFKit), FileImport, Haptics
    Resources/Assets.xcassets          AppIcon, AccentColor (#5146E5 light / #7B74FF dark)
    Wortschatz.entitlements            App Sandbox + user-selected read-write files
  WortschatzUITests/                   XCUITest target (Enter-only flows)
  Packages/WortschatzCore/             Swift package (platform-independent logic, `swift test` from CLI)
    Package.swift                      swift-tools-version 6.0; platforms macOS 14+ (logic only, no UI)
    Sources/WortschatzCore/            Models, TextNormalizer, LangDetect, TextLayout, VocabParser, Grading, Synonyms,
                                       Mastery, WriteSession, LearnEngine, LibraryStore, Backup, TimeUtil, IDGen, Random
    Tests/WortschatzCoreTests/         ported unit tests + parity tests; Fixtures/ (resources, .copy)
  Parity/                              gen-*.js generators run with JavaScriptCore against ../src (the web reference)
  build/                               local build output (Wortschatz.app)
  scripts/                             build.sh (xcodebuild Release -> build/Wortschatz.app), test.sh (swift test + xcodebuild test)
```
- **Bundle and naming:** bundle id `app.wortschatz.mac`, product name "Wortschatz", category Education, UI language German (`de-CH`), and Swiss spelling (always "ss", never the sharp s) in all UI copy.
- **Store location:** `~/Library/Containers/app.wortschatz.mac/Data/Library/Application Support/Wortschatz/library.json`, written atomically.
- **Commands:** `mac/scripts/build.sh` and `mac/scripts/test.sh` must work non-interactively.

## 2. Parity strategy (the port must behave exactly like the JS)

For every core module there is a generator `mac/Parity/gen-<module>.js` (an ES module run with
`/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc -m`, importing the web reference via
absolute paths, printing ONE JSON document to stdout via `print`). Its output is saved to
`Packages/WortschatzCore/Tests/WortschatzCoreTests/Fixtures/<module>.json` and checked by `<Module>ParityTests.swift`.
Generators must produce LARGE, diverse case sets (hundreds to thousands of cases): all existing JS test inputs, all
fixtures in `tests/fixtures/`, the user's 52-pair list, and systematic variations/fuzz (seeded). Rules:
- **JSON shape:** Swift results are encoded to JSON with the same keys as JS and compared structurally. Optional and absent values follow JS: `null` and missing are treated the same only where JS omits the key.
- **Floats:** compared with absolute tolerance 1e-9 (round in the generator only if JS itself rounds).
- **Randomness:** engines take an `RNG = () -> Double`. Both sides use **mulberry32** (identical integer arithmetic: `UInt32` wrapping in Swift, `Math.imul`/`>>> 0` in JS) and must consume random numbers in the same order. State snapshots after scripted action sequences must match JSON-for-JSON.
- **Time:** all timestamps are epoch **milliseconds as `Double`** (as in JS). Date-key logic takes an explicit `TimeZone`. Generators run with `TZ=Europe/Zurich`; Swift tests pass `TimeZone(identifier: "Europe/Zurich")`.
- **Strings:** JS is UTF-16 with `/u` regexes. Port each regex carefully: prefer Swift `Regex` with Unicode semantics, or `NSRegularExpression` on `NSString` when JS index arithmetic matters. Unicode normalisation is NFC (`precomposedStringWithCanonicalMapping`). Any divergence found by parity tests is fixed **in Swift**. The web code is not to be changed.
- **Ported tests:** the JS unit tests of each module are also ported to Swift Testing (`import Testing`, `@Test`, `#expect`) or XCTest, in addition to the parity tests.

## 3. Core API (Swift, `public`, all value types `Codable, Sendable, Equatable`)

Names avoid SwiftUI collisions (`Text`, `Layout`, `Set`). Each function mirrors the JS export of the same name and behaviour.
```swift
// Models.swift - JSON keys identical to the web app (backup compatible)
enum Lang: String { fr, en, es, it, de, other }               // + "unknown" only where JS returns it (LangDetect)
struct Card { id, term, definition: String; starred: Bool }
struct VocabSet { id, title, description: String; termLang, defLang: Lang; cards: [Card];
                  studyOptions: StudyOptionsPatch?; createdAt, updatedAt: Double; lastStudiedAt: Double? }
enum AnswerWith: String { term, definition, both }
struct Tolerance { articles, abbreviations, multipleAnswers, parentheses, ignoreCase, ignoreAccents, typos: Bool }
struct LearnOptions { roundSize: Int; mc, written, retype: Bool }
struct StudyOptions { answerWith; shuffle, copyAnswer, autoAdvance, audio: Bool; tolerance: Tolerance; learn: LearnOptions }
struct StudyOptionsPatch  // all fields optional, nested patches; merge(into:) deep-merges like db.js
struct CardProgress { correct, incorrect, streak, streakBefore: Int; lastResult: AnswerResult?; lastAnsweredAt: Double? }
enum CardStatus: String { new, learning, mastered }
struct Settings { theme: ThemeSetting(system|light|dark); study: StudyOptions }
typealias Activity = [String: Int]                            // "YYYY-MM-DD" -> answers

// TextNormalizer (text.js): normalizeBasic(_:keepTabs:), stripDiacritics, foldUmlauts, isLetter
// LangDetect (langdetect.js): SUPPORTED, scoreLanguages(_:) -> [Lang: Double], detectLanguage(_:) -> (lang, confidence), detectColumn(_:)
// TextLayout (layout.js): struct TextItem { str; x, y, w, h: Double }; itemsToLines(_:options:), estimateSlope, deskewItems
// VocabParser (parser.js): struct ParseOptions (mode, delimiter, cardSeparator, termLang, defLang, orient, swap, ...exactly as JS)
//                          struct ParseResult (cards[ParsedCard{term, definition, confidence, flags, lines}], format, delimiter,
//                          termLang, defLang, swapped, skipped[{line, text, reason}], warnings); parseVocab(_:options:)
// Grading (grading.js): ARTICLES, REFLEXIVES, ABBREVIATIONS, DEFAULT_TOLERANCE, splitAlternatives, grade(given:expected:tolerance:lang:)
//                       -> GradeResult{correct, exact, notes:[GradeNote], hint: GradeHint?, expectedDisplay}, diffChars, diffAnswer
// Synonyms (synonyms.js): promptSide, answerSide, findSynonymCards, gradeWithSynonyms -> (result, matchedCard)
// Mastery (mastery.js): MASTERY_STREAK, normalizeProgress, cardStatus, setProgress, studyStreak(activity, now, timeZone), applyAnswer, applyOverride
// WriteSession (session.js): struct SessionState (JSON keys = JS); createSession, current, answer, override, isRoundOver,
//                            roundSummary, nextRound, isFinished, counters, finalStats, removeCard, tick
// LearnEngine (learn.js): struct LearnState (JSON keys = JS); DEFAULT_LEARN, buildChoices, stageFromProgress, createLearn, current,
//                         answer, override, isRoundOver, counts, checkpoint, nextRound, isFinished, finalStats, removeCard, tick,
//                         matchesProgress, syncProgress
// Random: typealias RNG = () -> Double; func mulberry32(seed: UInt32) -> RNG; SystemRNG
// TimeUtil (lib/time.js): dateKey(ms, timeZone), relativeTime(ms, now) (German), formatDuration(ms)
// IDGen: uid()  (16 url-safe chars)
// LibraryStore (db.js) - final class, @unchecked Sendable or actor-free main-thread use; persistence via a StorageBackend
//   protocol (FileBackend: atomic JSON file + 3 rotating backups; MemoryBackend for tests). Same semantics as db.js:
//   listSets, getSet, createSet, updateSet (id preservation, progress pruning, session/learn clearing rules), deleteSet,
//   duplicateSet, updateCard, toggleStar, getProgress, recordAnswer, overrideLastAnswer, resetProgress, resetCardProgress,
//   getSession/saveSession/clearSession, getLearn/saveLearn/clearLearn, getSettings/updateSettings (deep merge),
//   getStudyOptions/updateStudyOptions, getActivity, snapshotSet/restoreSet (undo), exportAll, importAll(mode: merge|replace)
//   (accepts web-app backups), clearAll; change notification via a callback/AsyncStream; corrupt file -> recover from backup.
// Backup (backup.js): setToText(set, termSep:, cardSep:)
```

## 4. App UX: native, Apple Human Interface Guidelines, Liquid Glass

### 4.1 Structure
- **WindowGroup "Wortschatz":** min 980×640, default 1240×800, unified toolbar. It holds a `NavigationSplitView` with:
  - **Sidebar** (system Liquid Glass):
    - "Übersicht" at the top.
    - Section "Lernsets": a row per set with title, "52 Begriffe" and a small circular mastery gauge. Context menu: Lernen, Schreiben, Bearbeiten, Duplizieren, Als Text exportieren…, Löschen (with undo).
    - `.searchable(placement: .sidebar)` filters by title and terms.
    - Toolbar button "+" (Neues Lernset, ⌘N).
  - **Detail:** Overview, Set detail, Study (Learn/Write) or Editor.
- **Study mode:** the sidebar collapses automatically (`columnVisibility = .detailOnly`) and is restored when you leave (Esc, or the toolbar back button "Lernsets").
- **Editor:** a large sheet (≥ 900×680) for new or edited sets. **Settings:** a `Settings` scene (⌘,) with a TabView.
- **Menus and commands:**
  - Ablage: Neues Lernset ⌘N, Liste importieren… ⌘O, Backup exportieren…, Backup importieren…
  - Lernset: Lernen ⌘L, Schreiben ⇧⌘L, Bearbeiten ⌘E, Fortschritt zurücksetzen…, Löschen ⌘⌫
  - Lernen (while studying): Ich hatte recht ⌘↩, Weiss ich nicht ⌥↩, Optionen ⌘K, Vorlesen ⌘R, Markieren ⌘D, Neu starten ⇧⌘R, Beenden Esc
  - Standard Edit, Window and Help menus.
- **Persistence:** an `@Observable AppModel` wraps `LibraryStore`. It saves after every change, debounced at most 300 ms, and always on quit. A changed card list behaves like the web app (sessions are cleared on structural changes).

### 4.2 Visual language (Liquid Glass)
- **What is glass:** automatic system glass on sidebar, toolbar, sheets, menus and controls. Custom glass via `.glassEffect(...)` and `GlassEffectContainer` (morphing via `.glassEffectID`) **only on the control layer**: the study card surface, the multiple-choice answer tiles (interactive glass), the floating bottom action bar, the progress capsule, stat tiles and the "Weiterlernen" hero. No glass on glass.
- **Buttons:** primary actions use `.buttonStyle(.glassProminent)` tinted with the accent. Secondary actions use `.buttonStyle(.glass)`.
- **Backdrop:** behind content, a calm `MeshGradient` in accent-tinted tones (violet/indigo/teal, very low saturation in light mode, deeper in dark mode) so the glass has something to refract. It drifts only slowly, and is static with Reduce Motion.
- **Feedback states:** correct uses a green-tinted glass (`.tint(.green.opacity(…))`) with a checkmark symbol effect (`.symbolEffect(.bounce)`). Wrong uses red tint and a gentle shake. Haptic feedback via `NSHapticFeedbackManager` (`.levelChange`) on the trackpad.
- **Typography:** SF Pro. The study prompt is ~40 pt semibold rounded (`.system(.largeTitle, design: .rounded)`). Symbols are SF Symbols. Light and dark mode, increased contrast, and Reduce Transparency (glass falls back to solid materials) are all supported.

### 4.3 Enter-only operation ("Enter als Weiter wie bei Quizlet")
Rule: **every screen has exactly one primary action bound to Return** (`.keyboardShortcut(.defaultAction)` or `onKeyPress(.return)`), visibly marked with a ↩ key-hint glyph, and focus is always placed so that Return does the obvious next step.

| Screen / state | Return does | Other keys |
|---|---|---|
| Launch → Übersicht | **Weiterlernen** (most recent unfinished Learn/Write session), else opens the most recent set | ↑↓ in sidebar selects sets |
| Set detail | **Lernen** (or Weiterlernen) | ⇧⌘L Schreiben, ⌘E Bearbeiten |
| Learn - multiple choice | chooses the **highlighted** tile (↑↓←→ move the highlight; it starts on none, the first arrow press lands on tile 1) | **1-4** choose directly, **0** / ⌥↩ = Weiss ich nicht |
| Learn/Write - written question | **Antworten** (submit) | ⌥↩ Weiss ich nicht, special-character bar via click |
| Feedback correct | **Weiter** (auto-advance after ~900 ms anyway) | any key continues |
| Feedback wrong | **Weiter** (or submits the copy field when retype/copy is on) | ⌘↩ Ich hatte recht, ⌘E Bearbeiten |
| Round checkpoint / Write round summary | **Weiter zu Runde N** | Esc back to set |
| Results | **Falsche nochmal üben** if any were missed, else **Fertig** (back to set) | ⇧⌘R Nochmal von vorne |
| Editor sheet | Return in a card's definition field jumps to the next row's term (and creates a row at the end) | ⌘↩ / ⌘S Speichern, Esc Abbrechen (asks if dirty) |
| Alerts/dialogs | default button | Esc cancel |

Pressing Return once must never trigger two transitions: debounce state changes and ignore key repeat. No keyboard trap: Tab
order is complete, and focus rings are visible.

### 4.4 Screens (feature parity with the web app)
- **Übersicht:**
  - Greeting ("Guten Morgen/Tag/Abend").
  - Glass stat tiles: Lernserie (flame), Heute beantwortet, Begriffe gemeistert.
  - A **Weiterlernen** hero showing set, mode, round and progress, triggered by Return.
  - A grid of set cards with gauge and quick "Lernen", plus a "Neues Lernset" card.
  - Empty state with "Erstes Lernset erstellen ↩" and "Aus der Web-Version übernehmen…".
- **Set detail:**
  - Header: large title, description, language capsule "Französisch → Deutsch", "52 Begriffe · zuletzt gelernt vor 2 Tagen", and a mastery gauge with legend (Gemeistert/Am Lernen/Neu).
  - Actions: **Lernen ↩** (glassProminent), Schreiben, "Nur markierte (n)", "Nur offene (n)", Bearbeiten, and a "…" menu.
  - Terms `Table`: Begriff | Definition | Status chip | ★ toggle | 🔊. It has a filter Picker (Alle/Neu/Am Lernen/Gemeistert/★) and inline search.
- **Learn** (port of the web Learn screen and engine):
  - Toolbar: a progress capsule with segmented bar and counts Neu · Am Lernen · Gemeistert, plus "Runde N", Optionen (popover with the learn options form) and a back button.
  - Card: language label, prompt, 🔊 / ★ / ✎.
  - **Multiple choice:** 4 glass tiles in a 2×2 grid with number badges 1-4. Correct: green tile, varied praise ("Super!", "Klasse!", "Genau!", "Weiter so!", "Stark!"), auto-advance. Wrong: chosen tile red, correct tile green, "Nicht ganz – das lernst du noch!", Weiter ↩.
  - **Written:** large TextField with special-character bar (é è ê ë à â ç î ï ô û ù ü œ æ for French, ä ö ü for German, …). Grading uses `Synonyms.gradeWithSynonyms` with the set's tolerance. Feedback shows "Deine Antwort" (diff highlighting via `Grading.diffAnswer`), "Richtige Antwort", hint chip, "Gesucht war …" for synonyms, Ich hatte recht ⌘↩ and Bearbeiten ⌘E. An optional copy step when `learn.retype` is on.
  - **Checkpoint** after each round: "Runde N geschafft", progress, the round's cards with status, Weiter ↩.
  - **Finish:** celebration (symbol effect plus particles, Reduce Motion safe), stats, Am häufigsten falsch, Nochmal lernen, Schreiben üben, Fertig ↩.
  - **All-mastered start screen.**
  - **Persistence:** resume after quit with a "Willkommen zurück" toast. Every answer goes through `recordAnswer` / `overrideLastAnswer`, and progress is synced with Write (`syncProgress`).
  - **Read-aloud:** `AVSpeechSynthesizer` with fr-FR / de-CH (fallback de-DE) / en-GB voices.
- **Write:** port of the web Write mode (rounds, Verbleibend/Falsch/Richtig, copy step, override, edit, summary, results, Falsche nochmal üben).
- **Editor (sheet):**
  - Fields: Titel, Beschreibung, Ich lerne / Übersetzung pickers.
  - **Import area:**
    - A TextEditor ("Füge deine Vokabelliste hier ein …").
    - A drop target accepting .txt/.csv/.tsv/.pdf/images.
    - "Datei wählen…" (`fileImporter`), "Bild aus Zwischenablage" (⌘V of an image when the editor is focused), and a progress view during PDF/OCR.
  - **Recognition:**
    - The text is parsed live (debounced) with `VocabParser`.
    - A detection bar shows "✨ 52 Paare erkannt · Abwechselnde Zeilen · Französisch → Deutsch". It offers a Trennung picker (Automatisch/Tab/Komma/Strichpunkt/Bindestrich/Zeilenweise/Eigenes) and "Seiten tauschen", and lists warnings.
    - A preview Table flags low-confidence or merged rows.
    - "N Karten übernehmen" offers Ersetzen/Anhängen.
  - **Cards:** an editable list (term/definition TextFields, ★, delete) with Return/Tab navigation and duplicate warnings.
  - **Saving:** ⌘↩ saves (title and ≥ 1 complete card required). Esc asks to discard unsaved changes.
  - **Importers:**
    - PDF via PDFKit. Character bounds become `TextItem`s, then `TextLayout.itemsToLines`. Scanned pages are rendered and OCR'd.
    - Images via Vision (`RecognizeTextRequest` / `VNRecognizeTextRequest`, languages from the set: fr-FR+de-DE, en-US+de-DE …, accurate level, language correction). Word boxes become `TextItem`s, then `itemsToLines`.
    - Text files: UTF-8, with Windows-1252/MacRoman fallback.
    - Port the web OCR umlaut fix (ô/û/â → ö/ü/ä in German cells) as a safety net.
- **Settings (⌘,)** tabs:
  - Allgemein: Erscheinungsbild System/Hell/Dunkel, Stimme.
  - Lernen: Fragetypen, Begriffe pro Runde 5/7/10/15, Antworten auf, Abtippen, Vorlesen.
  - Schreiben: Mischen, Richtige Antwort abtippen, Automatisch weiter.
  - Toleranz: the 7 toggles, each with a German example.
  - Daten:
    - Backup exportieren / importieren, compatible with the web app; Zusammenführen / Ersetzen.
    - "Aus der Web-Version übernehmen" with a 3-step how-to.
    - "Speicherort im Finder zeigen" and "Alle Daten löschen…" (double confirm).

## 5. Quality bar & testing
- `swift test` must be green: ported unit tests plus parity tests over thousands of cases. The `xcodebuild` build must have no warnings in our code (Swift 6 language mode, strict concurrency for the app target).
- XCUITests drive the Enter-only flows:
  - create a set from the user list via the editor;
  - Learn with keys 1-4 and Return only (MC → next round written);
  - the checkpoint;
  - resume after relaunch.
- Accessibility: every control has a label, VoiceOver announces feedback, and focus is visible.
- The app must feel genuinely Apple: native controls, correct HIG spacing, SF Symbols, smooth spring animations, no web-isms.

## 6. Study flow controllers (testable Enter-only logic in WortschatzCore)

The UI state machines of the web screens (`src/screens/learn*.js`, `src/screens/write*.js`) are ported into **pure
reducers in WortschatzCore**, so that every keyboard rule, including "one Return = one transition", is unit-tested with
`swift test`. SwiftUI views only render state and forward events.
```swift
public enum KeyInput: Sendable, Equatable { case returnKey, optionReturn, commandReturn, escape, digit(Int),
                                            arrow(Direction), character(Character) }
public enum LearnFlow {
  public struct State: Codable, Sendable, Equatable   // phase + everything the view needs to render
  public enum Phase: question(mc|written), feedback(correct|wrong|dontKnow), copy, checkpoint, finished, allMastered, empty
  public enum Event   // .key(KeyInput, isRepeat: Bool), .choose(Int), .submit(String), .dontKnow, .proceed, .override,
                      // .editCard(Card), .toggleStar, .optionsChanged(StudyOptions), .autoAdvanceFired(token), .restart, .cardsChanged([Card])
  public enum Effect  // .recordAnswer(cardId, correct), .overrideLastAnswer(cardId), .saveLearn(LearnState), .clearLearn,
                      // .speak(text, lang), .haptic(.success|.failure), .scheduleAutoAdvance(ms, token), .announce(String), .updateCard(Card), .toggleStar(cardId)
  public static func start(set: VocabSet, progress: [String: CardProgress], options: StudyOptions, saved: LearnState?,
                           subset: Subset, forceNew: Bool, rng: RNG, now: Double) -> (State, [Effect])
  public static func reduce(_ state: State, _ event: Event, env: Env) -> (State, [Effect])   // Env: rng, now, cards, progress
  public static func returnAction(_ state: State) -> String?   // label of what Return does now (for the ↩ hint), nil = nothing
}
public enum WriteFlow { /* same pattern for Write mode (session.js + write*.js logic) */ }
```
Rules:
- **Return:** the effect of `.key(.returnKey)` in each phase must match the table in §4.3. A key with `isRepeat == true` never transitions.
- **Auto-advance:** it uses a token, so a stale timer cannot advance twice.
- **Grading:** written answers are graded with `Synonyms.gradeWithSynonyms`, and copy steps with `Grading.grade`, exactly as in the web code.
- **Tests:** port the logic-level behaviour of the web screens (see `tests/write-model.test.js`, `tests/learn-model.test.js`, and the screens' own state handling) and add exhaustive key-sequence tests.
