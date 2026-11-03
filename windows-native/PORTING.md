# PORTING.md – Mac (Swift) → Windows (C#)

Für Claude (und Menschen), die eine Änderung der Mac-App in die native Windows-App übertragen oder hier weiterbauen.
Kurzfassung für eilige Claudes: **Rezept «Mac-Feature übernehmen» ganz unten** (Abschnitt «Rezept»).

## Grundregeln

1. **Eine Swift-Datei ↔ eine C#-Datei mit gleichem Namen.** `Grading.swift` → `Grading.cs`, `LearnEngine.swift` →
   `LearnEngine.cs`. Typen und Funktionen behalten ihre Namen, nur in C#-Schreibweise (PascalCase):
   `splitAlternatives` → `SplitAlternatives`, `MASTERY_STREAK` bleibt `MASTERY_STREAK`.
2. **Die JS-Referenz ist die Wahrheit für den Kern.** Swift-Kern und C#-Kern sind beide Ports von `Website/src/core`,
   `src/lib`, `src/store`, `src/import/layout.js`. Wo Swift JS-Strings nachbildet (`JSText`, Codepoint-Arrays,
   handgeschriebene Regex-Ersatzfunktionen), nimmt C# einfach `string` und `JsRegex` – C#-Strings sind UTF-16 wie JS.
   Dann ist die JS-Funktion oft die kürzere Vorlage; Namen und Aufteilung bleiben die von Swift/JS.
3. **Parität vor allem.** Jede Kern-Datei mit Fixture bekommt einen Paritätstest (`tests/.../<Name>ParityTests.cs`,
   Port von `<Name>ParityTests.swift`). Ein Port gilt erst als fertig, wenn alle Fixture-Fälle grün sind.
4. **JSON wie die Web-App.** Modelle haben `FromJson(JSONValue)` (nachsichtig wie die JS-Sanitizer) und
   `ToJson()` mit exakt den JS-Schlüsseln. Keine Reflection-Serialisierung: Backups bleiben zwischen Web, Mac und
   Windows austauschbar.
5. **Werttypen:** Swift-`struct`s sind hier `record`s. Nie eine Liste/ein Record von aussen verändern: mit
   `with { }` bzw. `new List<T>(...)` kopieren (Swift kopiert automatisch, C# nicht).

## Übersetzungstabelle

| Swift | C# |
|---|---|
| `enum X { static func f() }` (Namensraum) | `public static class X { public static … F() }` |
| `struct S: Codable` | `public sealed record S(...) : IJsonEncodable` mit `FromJson`/`ToJson` |
| `enum E: String` (rawValue) | `public enum E { … }` + `EnumRaw` (`e.Raw()`, `EnumRaw.Parse<E>("…")`); abweichende Rohwerte mit `[Raw("case")]` |
| `enum` mit assoziierten Werten | `abstract record` + Unterklassen, oder `record` mit `Kind`-Enum (z. B. `StudySubset`) |
| `JSONValue` | `JSONValue` (eigene Klasse, gleiche Accessoren: `StringValue`, `FiniteNumber`, `IntegerValue`, `JsPrimitiveString` …) |
| `JSCompat.trim/round/numberToString` | `JSCompat.Trim/Round/NumberToString` |
| `s.lowercased()` (wo JS `toLowerCase`) | `JSCompat.Lower(s)` (volle Unicode-Abbildung wie JS: İ, Schluss-Sigma) |
| JS-Regex `/…/gu` | `JsRegex.ReplaceAll(s, @"…", …)`, `JsRegex.Test`, `JsRegex.Match`, `JsRegex.Split` – Muster unverändert aus dem JS kopieren |
| `RNG` / `mulberry32(seed:)` | `RNG` (Delegate) / `Rand.Mulberry32(seed)` |
| `TimeZone` | `TimeZoneInfo` (Fixtures: `Fixtures.Zurich`) |
| `Date().timeIntervalSince1970` | `TimeUtil.NowMs()` (über `TimeUtil.Clock` austauschbar für Tests) |

## Umbenennungen (Namenskonflikte in C#)

| Swift | C# | Grund |
|---|---|---|
| `Mastery.cardStatus(_:)` | `Mastery.CardStatusOf` | `CardStatus` ist der Enum-Name |
| `Mastery.setProgress(_:_:)` | `Mastery.SetProgressOf` | `SetProgress` ist der Typname |
| `Mastery.studyStreak(_:)` | `Mastery.StudyStreakOf` | `StudyStreak` ist der Typname |
| `mulberry32(seed:)` (global) | `Rand.Mulberry32` | C# hat keine freien Funktionen |
| `Lang.fr` … | `Lang.Fr` … (JSON weiterhin `"fr"`) | C#-Konvention |
| `GradeNote.letterCase` | `GradeNote.LetterCase` mit `[Raw("case")]` | wie in Swift |
| `Theme` (DesignSystem/Theme.swift) | `WsTheme` (`WsTheme.P` = aktive Palette, `WsTheme.B(color)` = Pinsel) | Avalonia-Controls haben eine Eigenschaft `Theme` |
| `Route.setID` | `Route.RouteSetId` | Record-Positionsparameter `SetId` der Unterklassen würden die Basiseigenschaft verdecken (Endlosschleife!) |
| `LearnEngine.counts/checkpoint/finalStats/reviewStats` | `LearnEngine.CountsOf/CheckpointOf/FinalStatsOf/ReviewStatsOf` | gleichnamige verschachtelte Typen (`LearnEngine.Counts` …) |
| `WriteSession.counters/roundSummary/finalStats` | `WriteSession.CountersOf/RoundSummaryOf/FinalStatsOf` | ebenso |
| `LearnFlow.typeAhead(_:choices:lang:)` | `LearnFlow.TypeAheadOf` | Typ `LearnFlow.TypeAhead` |
| `WriteSession.qid(cardId:ask:)` | `WriteSession.Qid` | – |
| Allgemein: Funktion heisst wie ein Typ im selben Namensraum | Funktion bekommt `Of` angehängt | C# erlaubt keine Methode mit dem Namen eines verschachtelten Typs |

## Swift-Enums mit Werten in C# (Flows)

Die Flows (`WriteFlow`, später `LearnFlow`) sind reine Reducer: `(State, Event, Env) → (State, [Effect])`.
- `enum Event { case submit(String) … }` → `abstract record Event` mit einem verschachtelten `sealed record` pro Fall
  (`new WriteFlow.Event.Submit("…")`); im Reducer `switch (e) { case Event.Submit submit: … }`.
- `enum Effect` genauso; Tests prüfen mit `Assert.Contains(new Effect.Haptic(HapticKind.Success), fx)` (Record-Gleichheit).
  Achtung: `Effect.SaveSession` enthält ein `SessionState` (Klasse) → Gleichheit per Referenz; das passt, weil der
  Reducer genau das Objekt aus `State.Session` übergibt.
- `enum Phase { case feedback(FeedbackKind) … }` → `readonly record struct Phase(PhaseKind Kind, FeedbackKind …)` mit
  `Phase.Question`, `Phase.FeedbackOf(FeedbackKind.Correct)`; `switch (s.Phase.Kind)` für `case .feedback:`.
- `struct State` mit `internal(set)` → `sealed class State` mit `internal set`; die `Machine` arbeitet auf `Clone()`.
  Records darin werden ersetzt (`s.Feedback = fb with { … }`), nie verändert. `VocabSet`-Karten ändern: neue Liste +
  `set with { Cards = … }`.
- Mac-Tasten: `.optionReturn` = Alt+Enter, `.commandReturn` = Ctrl+Enter (die App übersetzt die Windows-Tasten).

## Datei-Zuordnung Kern (Stand)

| Swift (`mac/Packages/WortschatzCore/Sources/WortschatzCore/`) | C# (`windows-native/src/Wortschatz.Core/`) | Paritätstest |
|---|---|---|
| `JSCompat.swift` | `JSCompat.cs` | – |
| `JSONValue.swift` | `JSONValue.cs` | – |
| – (Swift hat Regex-Ersatz pro Datei) | `JsRegex.cs` | über alle Tests |
| `Random.swift`, `IDGen.swift` | `Random.cs` | `BasicsParityTests.Random` |
| `TimeUtil.swift` | `TimeUtil.cs` | `BasicsParityTests.Time` |
| `TextNormalizer.swift` | `TextNormalizer.cs` | `BasicsParityTests.Text` |
| `Models.swift` | `Models.cs` | über Mastery/Store |
| `Mastery.swift` | `Mastery.cs` | `MasteryParityTests` |
| `Grading.swift` | `Grading.cs` | `GradingParityTests` (8 Teile) |
| `Labels.swift` | `Labels.cs` | – |
| `TextMemo.swift` | `TextMemo.cs` | – |
| `Synonyms.swift` | `Synonyms.cs` | `SynonymsParityTests` |
| `ExtendedSynonyms.swift` | `ExtendedSynonyms.cs` (nur der reine Teil; Windows hat kein Apple-Sprachmodell, die App übergibt keine `extraAnswers`) | – |
| `LangDetect.swift` | `LangDetect.cs` | `LangDetectParityTests` |
| `LangDetectLexicon.swift` | `LangDetectLexicon.cs` (**generiert**: `node windows-native/tools/gen-langdetect-lexicon.mjs`) | – |

| `VocabParser.swift` + `VocabParser+{Context,Lines,Split,Text,Delimited,LineBased}.swift` | `VocabParser.cs` (Typen, Optionen, Vorverarbeitung, Klassifizierung, Trenn-Helfer) + `VocabParser.Lists.cs` (getrennte und zeilenbasierte Listen, Ausrichtung, Finish, Warnungen) | `VocabParserParityTests` (8 Teile) |

Hinweis Parser: Die C#-Datei folgt `parser.js` Funktion für Funktion (gleiche Namen). In Swift sind dieselben Funktionen
auf `VocabParser+*.swift` verteilt (z. B. `languageSplit` in `+Split`, `align` in `+LineBased`). Eine Mac-Änderung findet
man in C# über den Funktionsnamen. `VocabParser+Text.swift` (Swift-Ersatz für JS-Regex) hat kein Gegenstück: C# nimmt
die JS-Muster direkt über `JsRegex`.
| `LibraryStoreTypes.swift` | `LibraryStoreTypes.cs` | – |
| `LibraryStoreSanitizer.swift` | `LibraryStoreSanitizer.cs` (`JSLoose`, `StoreSanitizer`) | – |
| `LibraryStoreBackends.swift` | `LibraryStoreBackends.cs` (`IStorageBackend`, `MemoryBackend`, `FileBackend`) | – |
| `LibraryStore.swift` | `LibraryStore.cs` (inkl. typisierte `GetSession`/`SaveSession`/`GetLearn`/`SaveLearn`) | `LibraryStoreParityTests` |
| `Backup.swift` | `Backup.cs` | `LibraryStoreParityTests` |
| `LearnTypeAhead.swift` | `LearnTypeAhead.cs` (`partial class LearnFlow`; nach `typeahead.js` geschrieben, Bereiche = UTF-16-Offsets statt `Character`-Offsets) | `LearnTypeAheadTests` |
| `WriteSession.swift` | `WriteSession.cs` (`SessionState` ist wie `LearnState` eine Klasse) | `WriteSessionParityTests` (Fixture `session`) |
| `StudyFlowCommon.swift` | `StudyFlowCommon.cs` (`KeyInput` = `record struct` mit `Kind`; vergleichen mit `==`, z. B. `key == KeyInput.Arrow(Direction.Up)`) | – |
| `Flashcards.swift` | `Flashcards.cs` (`FlashcardDeck` = Klasse mit verändernden Methoden wie Swifts `mutating`; `Clone()`/`SameAs()` statt Wertkopie/`==`; `Phase` → `DeckPhase`, `Sort` → `SortEntry`, `action(for:)` → `ActionFor`) | `FlashcardsTests` |
| `Exam.swift` | `Exam.cs` (`ExamSettings.init(from:)` → `FromJson`; `tolerance.minorPoints` → Erweiterung `MinorPoints()`) | `ExamTests` |
| `WriteFlow.swift` | `WriteFlow.cs` (Typen, Ereignisse, Effekte, `Start`/`Reduce`) | `WriteFlowTests` |
| `WriteFlowModel.swift` | `WriteFlowModel.cs` (`pendingFeedback` → `PendingFeedbackOf`, `compactDuration` → `CompactDurationOf`) | `WriteFlowModelParityTests` (liest das JSON direkt aus `WriteFlowWebCases.swift`) |
| `WriteFlowMachine.swift` | `WriteFlowMachine.cs` (Methode für Methode, gleiche Namen) | `WriteFlowTests` |
| `WriteFlowText.swift` | `WriteFlowText.cs` (`Prompt.message` → `Prompt.MessageText`, weil `Message` der Typ der Leer-Bildschirme ist) | über `WriteFlowTests` |
| `LearnFlow.swift` | `LearnFlow.cs` (Typen, Ereignisse, Effekte, `Start`/`Reduce`; `optionState` → `OptionStateOf`, `promptContent` → `PromptContentOf`, `message` → `MessageOf`) | `LearnFlowTests` |
| `LearnFlowModel.swift` | `LearnFlowModel.cs` (`questionInfo` → `QuestionInfoOf`, `pendingFeedback` → `PendingFeedbackOf`, `sessionSettings` → `SessionSettingsOf`, `stageStatus` → `StageStatusOf`) | über `LearnFlowTests` |
| `LearnFlowReducer.swift` | `LearnFlowReducer.cs` (Methode für Methode; `Graphemes` bildet Swifts `Character`-Zählung für getippte Buchstaben nach) | `LearnFlowTests`, `LearnTypeAheadTests` |
| `LearnEngine.swift` | `LearnEngine.cs` | `LearnEngineParityTests` (Fixture `learn`), `LearnReviewTests` (Wiederholungsfragen, nur Mac) |

Hinweis LearnEngine: `LearnState` ist in C# eine **Klasse** (viele Listen/Maps, Swift mutiert eine Kopie mit `var s`).
Regel: Engine-Funktionen beginnen immer mit `var s = CopyState(state)` – das ist die frische Kopie, die verändert wird;
der Eingabezustand wird nie angefasst. Wer ausserhalb der Engine einen Zustand ändern will (Tests, Flow), macht das nur
auf einem `CopyState`-Ergebnis. Die Werte darin (`LearnQueueQuestion`, `LearnRoundLogEntry` …) sind Records: ändern
mit `with { }`. `LearnEngineTests.swift` (Unit-Tests) ist nicht portiert – die Parität deckt dasselbe Verhalten ab;
Mac-only-Verhalten (Wiederholungsfragen) hat eigene Tests.

Speicherort: Die native App speichert seit 1.2 in `%LOCALAPPDATA%\Wortschatz\library.json` (Ordner der früheren
WebView-App, deren localStorage beim ersten Start 1:1 übernommen wird, siehe README «Ersetzt die frühere Windows-App»).
Lernsets wandern per Backup-Datei zwischen den Apps (gleiches Format).

## Generierte Dateien

- `LangDetectLexicon.cs` ← `tools/gen-langdetect-lexicon.mjs` liest die Daten aus `Website/src/core/langdetect.js`.
  Ändert sich das Lexikon (JS bzw. `LangDetectLexicon.swift`), Generator laufen lassen, nicht von Hand ändern.

## JS-Eigenheiten, die bewusst nachgebildet sind

- `LangDetect`: `LEADING["constructor"]` ist in JS wahr (Objekt-Prototyp) → `LeadingHas`. Mac macht dasselbe.
- `JsRegex` mit Flags `iu`: ſ ≡ s und K (Kelvin) ≡ k wie in JS (.NET kennt diese Faltung nicht).
- `JSCompat.Lower`: volle Unicode-Kleinschreibung wie JS (`İ` → `i̇`, Schluss-Sigma), .NET hätte die einfache.


## Oberfläche (src/Wortschatz.App) – Zuordnung Mac → Windows

Die Oberfläche ist **C#-Code, kein XAML**: eine SwiftUI-Datei ↔ eine C#-Datei, gleiche Namen wo möglich.

| Mac (`mac/Wortschatz/`) | Windows (`windows-native/src/Wortschatz.App/`) |
|---|---|
| `App/WortschatzApp.swift` | `App/App.cs` (`Program.Main`, Simple-Theme + `AppStyles`) |
| `App/AppModel.swift`, `AppModel+Actions.swift`, `Routing.swift` | `App/AppModel.cs` (`Route`, `StudyRequest`, Toasts, Aktionen) |
| `App/ContentView.swift` | `App/MainWindow.cs` (eigene Titelleiste, Seitenleiste, Tastenweiterleitung, Toasts) |
| `DesignSystem/Theme.swift` | `DesignSystem/Theme.cs` (`Palette.Light`/`DarkPalette`, `WsTheme`) |
| `DesignSystem/GlassSurfaces.swift`, `Buttons.swift`, `Chips.swift`, `KeyHint.swift`, `ProgressViews.swift` | `DesignSystem/Ui.cs` (`Ui.Glass`, `Ui.Hero`, `Ui.Card`, `Ui.Primary`, `Ui.Secondary`, `Ui.IconButton`, `Ui.Chip`, `Ui.KeyCap`, `Ui.StatusBar`, `Ui.Field`, `WsButton`) |
| `DesignSystem/Metrics.swift` (`Motion`), `StudyEntrance.swift` (Timing), SwiftUI-Animationen | `DesignSystem/Motion.cs` (`Curve`, `Motion.Spring/Snappy/Gentle/Soft/Arrive/Depart/Glide`, `AnimatedValue`, `Matrices.Rotate3D`) |
| `DesignSystem/Effects.swift`, `StudyEntrance.swift` (`entranceReveal`, `entranceShift`) | `DesignSystem/Effects.cs` (`Effects.Of(c).Place/Enter`, `Shake`, `Pop`, `PromptSwapIn`, `AnswerSwapIn`, `EntranceShift`, `StudyEntrance.RevealScreen`) |
| `DesignSystem/Celebration.swift` | `DesignSystem/Celebration.cs` (`CelebrationView`, Konfetti in geschlossener Form, Reduce Motion: Leuchten) |
| `DesignSystem/ProgressViews.swift`, `WriteProgressLine`, `WriteRatioRing`, `LearnSegmentedBar` | `DesignSystem/ProgressViews.cs` (`ProgressLine`, `AnimatedStatusBar`, `SegmentedBar`, `ProgressCapsuleView`, `RatioRing`) |
| `DesignSystem/StatTile.swift`, `EmptyStateView.swift` | `DesignSystem/StatTile.cs` (`StatTile.Create/Row`, `EmptyStateView.Create`) |
| `DesignSystem/ChoiceTile.swift` | `DesignSystem/ChoiceTile.cs` |
| `DesignSystem/Toasts.swift` | `DesignSystem/Toasts.cs` (`ToastOverlay`; Daten in `AppModel.Toasts`, `ToastTone`) |
| SwiftUI `Toggle`, `Picker(.segmented)`, `Form(.grouped)` | `DesignSystem/Ui.cs` (`WsSwitch`, `WsSegmented`, `Form.Section/Row`) |
| SF Symbols | `DesignSystem/Icons.cs` (`IconName`, Pfade 24×24; `Icons.ForSymbol("trophy")` für Namen aus den Flows) |
| Mesh-Hintergrund | `DesignSystem/Backdrop.cs` |
| `Features/Library/LibrarySidebar.swift` | `Features/Library/LibrarySidebar.cs` |
| `Features/Overview/*` | `Features/Overview/OverviewScreen.cs` |
| `Features/SetDetail/*` | `Features/SetDetail/SetDetailScreen.cs` |
| `Features/Learn/LearnController.swift` | `Features/Learn/LearnController.cs` (Effekte → Speicher/Timer/Sprache) |
| `Features/Learn/LearnScreen.swift`, `LearnStage`, `LearnPromptCard`, `LearnActionBar`, `LearnCheckpointView`, `LearnFinishView`, `LearnCardEditor` | `Features/Learn/LearnScreen.cs` (eine Datei, Abschnitte in derselben Reihenfolge) |
| `Features/Learn/AnswerStreak.swift` | `Features/Learn/AnswerStreak.cs` (auch von Schreiben benutzt) |
| `LearnStatus`/`LearnStatusPill`/`StreakBadge`/`LearnCountdownLine`/`StudyActionBar` (in `LearnActionBar.swift`) | `Features/Study/StudyStatusPill.cs` (`StudyStatus`, `StudyStatusPill`, `StudyCountdown`, `StudyActionBarView`) |
| `StudyAnswerBox` (in `LearnPromptCard.swift`) | `Features/Study/StudyAnswerBox.cs` |
| `Features/Write/WriteController.swift`, `WriteScreen.swift`, `WriteStage`, `WritePromptCard`, `WriteActionBar`, `WriteSummaryView`, `WriteResultsView` | `Features/Write/WriteController.cs`, `WriteScreen.cs` |
| `Features/Flashcards/FlashcardsController.swift` | `Features/Flashcards/FlashcardsController.cs` (Abflüge, Ankunft, Wischen; Stapel in `AppPreferences`) |
| `Features/Flashcards/FlashcardCard.swift` | `Features/Flashcards/FlashcardCard.cs` (`FlashcardMotion`, `FlashcardMetrics`, `FlashcardFace`, `FlashcardView`, `FlashcardStackPeeks`, `FlashcardDeckView`) |
| `Features/Flashcards/FlashcardSwipe.swift` | `Features/Flashcards/FlashcardSwipe.cs` (`FlashcardSwipe`, `FlashcardScrollMonitor` für das Touchpad) |
| `Features/Flashcards/FlashcardsStage.swift`, `FlashcardsScreen.swift`, `FlashcardsOptionsPanel.swift` | `FlashcardsStage.cs`, `FlashcardsScreen.cs`, `FlashcardsOptionsPanel.cs` |
| `Features/Exam/*` | `Features/Exam/ExamScreen.cs` |
| `Features/Editor/*`, `Features/Import/*` | `Features/Editor/SetEditorScreen.cs` (Text/Datei/Zwischenablage; **noch kein PDF/Foto**) |
| `Features/Settings/*` | `Features/Settings/SettingsScreen.cs` (Darstellung, Backup, Daten löschen, Info) |
| gemeinsame Lern-Teile (Kopfzeile, Aktionsleiste, Dialoge, Optionen) | `Features/Study/StudyChrome.cs`, `StudyText.cs` |
| `Services/SpeechService.swift` | `Services/SpeechService.cs` (SAPI/OneCore-Stimmen über COM) |
| UserDefaults | `Services/AppPreferences.cs` (`preferences.json` neben der Bibliothek) |
| Snapshot-Harness (`DebugSnapshot.swift`) | `tools/Wortschatz.Snapshots` (headless PNGs) |

Noch nicht portiert (bewusste Lücken, Stand 2.11.2026): Töne/Haptik (`SoundEffects.swift`), Bildschirmleser-Ansagen
(`Effect.Announce` wird ignoriert), PDF-/Foto-Import (Mac: PDFKit/Vision; Windows bräuchte `Windows.Media.Ocr`),
Rechtschreibvorschläge im Editor, Sonderzeichen-Leiste, Menüleisten-Befehle, App-Updates, die Einstellungs-Tabs
«Lernen»/«Schreiben»/«Töne».

### Wie ein Bildschirm funktioniert

- `Screen` (Features/Screen.cs): `Build()` baut den Inhalt; `Refresh()` baut neu (Speicheränderung); Lern-Bildschirme
  rendern stattdessen bei jedem Zustandswechsel ihres Controllers (`Changed`) und behalten Textfelder (`_answer`, `_field`)
  über Renders hinweg – **vor** dem Neuaufbau mit `Detach` aus dem alten Baum lösen.
- Tasten: `MainWindow` leitet KeyDown (Tunnel) an `Screen.HandleKey` und Texteingabe an `Screen.HandleText`.
  `Screen.Translate` macht aus Enter/Alt+Enter/Ctrl+Enter/Esc/Pfeilen/Rücktaste die `KeyInput` der Flows; Ziffern und
  Buchstaben kommen als Text (`Screen.TextKey`) – das funktioniert mit jeder Tastaturbelegung.
- Mac-Tasten → Windows: ⌘ → Ctrl, ⌥↩ → Alt+Enter, ⌘↩ → Ctrl+Enter, ⌥⌫ → Ctrl+Rücktaste, ⇧⌘R → Ctrl+Shift+R.
- Farben/Abstände nie hart kodieren: `WsTheme.P.<Token>`; neue Tokens in **beiden** Paletten (hell und dunkel) anlegen.
- Lernen/Schreiben bauen bei jeder Zustandsänderung neu auf. Was sich bewegen soll, entscheidet die Klasse `Moves`
  im Bildschirm: sie vergleicht mit dem, was der letzte Aufbau zeigte (neue Frage, neue Phase, mehr Abweisungen,
  längere Serie) und spielt dann den Effekt auf dem **neu gebauten** Control. Einmalige Effekte (Konfetti, Ring,
  Pokal-Pop) nur, wenn die Phase gerade erschien – sonst starten sie bei jedem Neuaufbau (Lernzeit-Tick alle 15 s) neu.
- Die Karteikarten sind dagegen **dauerhaft** aufgebaut (`FlashcardDeckView` mit einer `FlashcardView` pro Karte und
  Runde), weil Karten über mehrere Schritte fliegen; dort ruft `Changed` nur `Update()` auf.

### Prüfen ohne Windows

```bash
cd windows-native
dotnet test tests/Wortschatz.Core.Tests                                   # Kern (Parität + Reducer)
dotnet run --project tools/Wortschatz.Snapshots -- /tmp/shots            # Bildschirme als PNG (hell)
dotnet run --project tools/Wortschatz.Snapshots -- /tmp/shots-dark dark  # dunkel
./build.sh                                                                # dist/Wortschatz.exe für Windows
```
Neue Bildschirme/Zustände in `tools/Wortschatz.Snapshots/Program.cs` (`Samples.Steps`) ergänzen und die PNGs ansehen.
Die Uhr ist dort gefälscht (+1 s pro Lesen), damit die Eingabesperren (280 ms) Skripte nicht blockieren.
Animationen haben eine eigene Uhr (`Motion.Now`): ein Schritt `"name@0.2"` macht das Bild 0,2 s nach der Aktion
(eingefrorener Moment), ein Schritt ohne `@` lässt erst alles fertig laufen. `--only=learn|write|flashcards` filtert,
`reduce` simuliert «Animationseffekte aus».

## Rezept: Animationen übernehmen

1. **Kurve übersetzen** (`Motion.cs`): `.timingCurve(a,b,c,d, duration:)` → `Curve.Bezier(a,b,c,d,duration)`,
   `.spring(response:dampingFraction:)` → `Curve.Spring(r,d)`, `.snappy/.smooth(duration:)` →
   `Curve.SpringDuration(d, bounce)`, `.easeOut(duration:)` → `Curve.EaseOut(d)`, `.delay(x)` → `.Delayed(x)`; die
   Mac-Voreinstellungen heissen gleich (`Motion.Gentle`, `Motion.Arrive(0.48)` …). `Motion.Animation(c)` wird unter
   Reduce Motion zur Überblendung.
2. **`withAnimation { wert = x }`** → ein `AnimatedValue` mit `Set(x, kurve, fertig)`; sein `Changed` setzt pro Bild
   den `RenderTransform`/die `Opacity` (wie ein `Animatable`-Modifier auf dem Mac: nur Transformationen, kein Neuaufbau).
   Matrizen: `Matrices.Affine(scale, rotate, x, y)`, `Matrices.Rotate3D(…)` für `rotation3DEffect`.
3. **Transitions** (`.transition(.modifier(active:identity:))`) → `Effects.Of(control).Enter(new Placement(...), kurve)`
   beim Einfügen, `Place(..., kurve, () => entfernen)` beim Entfernen. `.shake(trigger:)` → `Effects.Shake(c, 7)`,
   `.pop(trigger:)` → `Effects.Pop(c, 1.12)`, `.promptSwap` → `Effects.PromptSwapIn`, `.answerSwap` → `AnswerSwapIn`.
4. **Zeitgesteuertes** (`TimelineView`, Konfetti, Countdown) → `Motion.OnFrames(now => …; return weiter)` und
   `InvalidateVisual()` in einem eigenen `Control.Render`.
5. **Prüfen**: Moment im Snapshot-Werkzeug als `"name@sekunden"` ablegen, hell und dunkel und mit `reduce` ansehen.
   Avalonia-Stolperstein: `new Placement()` (parameterloser Konstruktor eines `record struct`) ignoriert die
   Standardwerte – immer `Placement.Identity` nehmen.

## Rezept: ein Mac-Feature in die Windows-App übernehmen

Für Claude. Vorgehen in dieser Reihenfolge; jeder Schritt hat ein prüfbares Ergebnis.

1. **Diff lesen.** `git log -p -- mac/` bzw. den Mac-Commit ansehen. Für jede geänderte Swift-Datei die C#-Datei in den
   Tabellen oben suchen (gleicher Name; Kern: `src/Wortschatz.Core/<Name>.cs`, Oberfläche: siehe Zuordnung).
2. **Kern zuerst** (`mac/Packages/WortschatzCore/Sources/WortschatzCore/*.swift` → `src/Wortschatz.Core/*.cs`):
   - Funktion für Funktion übersetzen, Namen behalten (PascalCase; Konflikte → `…Of`, siehe Umbenennungen).
   - Hat das Feature ein JS-Gegenstück (`Website/src/...`), ist es oft die bessere Vorlage (C#-Strings = UTF-16 wie JS).
   - Swift-`struct` + `mutating` → C#-Record mit `with` (oder Klasse mit `Clone()`, wie `LearnState`/`FlowState`).
   - Swift-Enum mit Werten → `abstract record` mit verschachtelten Records (Event/Effect) bzw. `record struct` mit `Kind`.
   - Neue JSON-Felder: `FromJson` nachsichtig, `ToJson` mit exakt den JS/Swift-Schlüsseln (Backups bleiben austauschbar).
3. **Tests mitnehmen.** Geänderte Mac-Tests (`mac/Packages/WortschatzCore/Tests/...`) in `tests/Wortschatz.Core.Tests`
   nachziehen. Neue Fixture (`Fixtures/*.json`, von `mac/Parity/gen-*.js` erzeugt)? → Paritätstest wie
   `LearnEngineParityTests.cs` (die Fixtures werden **im Mac-Ordner gelesen**, nie kopiert). Alles grün, sonst nicht weiter.
4. **Flows** (LearnFlow/WriteFlow): sie enthalten die Bildschirmlogik. Neue Events/Effects zuerst hier; der Controller
   (`Features/*/…Controller.cs`) führt neue Effects aus (Speicher, Timer, Sprache, Navigation).
5. **Oberfläche.** Mac-View lesen, im entsprechenden C#-Bildschirm denselben Abschnitt anpassen. Bausteine aus `Ui`/
   `StudyChrome` nehmen statt neuer Controls. Deutsch mit «ss», Texte möglichst aus dem Kern (`…Copy`, `LearnFlow.*_TEXT`).
   Tastenkürzel in `HandleKey` (Ctrl statt ⌘). Hell **und** dunkel prüfen.
6. **Ansehen.** Screenshot-Werkzeug laufen lassen (ggf. Schritt in `Samples.Steps` ergänzen), PNGs anschauen.
7. **Bauen.** `./build.sh` → `dist/Wortschatz.exe`. Ohne Windows-Gerät nicht als «getestet» bezeichnen.
8. **Doku.** README-Stand und diese Tabellen nachführen; Commit-Nachricht auf Deutsch, erklärt *was* und *warum*.

Typische Stolpersteine: Avalonia-12-API weicht von 11 ab (z. B. `FocusChangedEventArgs`, `WindowDecorations`,
Zwischenablage über `ClipboardExtensions`); im Zweifel die XML-Doku im NuGet-Cache durchsuchen
(`~/.nuget/packages/avalonia/12.1.5/lib/net8.0/*.xml`). Ein Control kann nur **einen** Elternteil haben (wiederverwendete
Felder vor dem Neuaufbau lösen). Swift `Character` ≠ C# `char` (Graphem-Cluster: `Graphemes` in LearnFlowReducer.cs).
