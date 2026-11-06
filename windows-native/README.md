# Wortschatz – native Windows-App (C# / .NET 10 / Avalonia 12)

Native Windows-Version der App «Wortschatz», gebaut als Port der **Mac-App** (`mac/`, Swift/SwiftUI). **Seit 1.2
(3.11.2026) die offizielle Windows-App** und auf `main`; sie ersetzt die frühere Windows-App (`windows/` + `Website/`,
WebView2, bis 1.1), die nicht mehr ausgeliefert wird. Entstanden auf dem Branch `native-windows-app`. Design: Richtung
**A · Glas** (so nah wie möglich an der Mac-App), von Joan am 2.11.2026 gewählt.

## Ältere Downloads räumen sich weg (nach 1.4, auf main, kommt mit 1.5)

Joan: eine neu heruntergeladene Version soll die alte ersetzen. `Services/OlderVersions.cs` (Regeln:
`Wortschatz.Core/OlderDownloads.cs`, Tests `OlderDownloadsTests`) löscht bei jedem Start im Download-Ordner, auf dem
Desktop und neben der laufenden exe Dateien mit dem Namen der Downloadseite (`Wortschatz-1.3-Windows.exe`,
`… (2).exe`), deren Versionsangabe «Wortschatz» 1.2 oder neuer und älter als die laufende ist – nie die laufende exe,
keine Version, die gerade läuft, keine umbenannte Kopie (`Wortschatz.exe`), nie 1.0/1.1 (das macht `EarlierApp` nach
der Übernahme). Daten teilen sich alle Versionen ab 1.2, darum gibt es nichts zu übernehmen. Mit
`WORTSCHATZ_NATIVE_DATA` sucht es nur dort und neben der exe. Auf dem Laptop geprüft (03.11.2026): 1.2/1.3-Downloads
weg, laufende 1.3, gleiche Version, umbenannte Datei und eine Fälschung mit passendem Namen bleiben.

## Lernen mit Abstand, Einstellungen (nach 1.3, 3.11.2026, Branch `lernen-und-einstellungen`)

Joans zwei offene Punkte, gleich in JS-Referenz, Mac und Windows:
- **Lernen** (`LearnEngine.cs`, Kopfkommentar; JS `src/core/learn.js` massgebend): statt Runden über eine feste Gruppe
  mit Retry am Rundenende plant `PlanRound` die nächsten `roundSize` Fragen mit Abstand – eine Karte frühestens nach
  10, spätestens nach etwa 15 anderen Fragen wieder, gemischt mit neuen (höchstens 3 Wiederholungen hintereinander,
  höchstens 10 Karten gleichzeitig am Lernen). Neu die **Nachkontrolle** (`state.recheck`, Einstellung
  `learn.recheck`, standardmässig an): in Sitzungen mit mehr als 60 Karten kommt eine einmal falsch beantwortete Karte
  30–50 Fragen nach dem Meistern nochmals. Abgestimmt mit einer Lern-Simulation (nicht im Git).
  Tests: `LearnSpacingTests`, angepasste `LearnReviewTests`/`LearnFlowTests`, Parität gegen die neuen Fixtures.
- **Einstellungen:** eigener Eintrag «Einstellungen» unten in der Seitenleiste (das Zahnrad sah wie eine Sonne aus und
  sass in der Lernserie-Box), Abschnitt «Wiederholung» in Einstellungen › Lernen, «Begriffe pro Runde» → «Fragen pro
  Runde». Optionen eines Lernsets zeigen, was vom Standard abweicht, mit «Auf Standard zurücksetzen»
  (`StudyChrome.OptionsBody`/`StandardNote`, `LearnOptionsCopy.Deviations`), und öffnen sich auch auf der Lernset-Seite
  (`StudyChrome.ShowSetOptions`).

## Abgleich mit der Mac-App umgesetzt (1.3, 3.11.2026)

Joan: «gehe jeden Code-Abschnitt der Mac-App durch» → sechs Helfer-Agenten haben den ganzen Mac-Code mit der Windows-App
verglichen, dann «alle 150
Punkte umsetzen»: die dringenden selbst (b350504: Verlassen-Sperre `AppModel.LeaveGuard` für Prüfung und Editor, leere
Kartenseiten, Datenrettungs-Hinweis `StartupPrompt`, Speichern scheitert beim Beenden, Sicherungen beim Löschen, Neustart
mit Rückfrage, Ring-Prozent), der Rest von fünf Agenten auf eigenen Branches (fix-a-lernen, fix-b-pruefung, fix-c-editor,
fix-d-einstellungen, fix-e-huelle), dann in `windows-import` zusammengeführt. Was jeder umgesetzt hat und was bewusst
fehlt: eigene Berichte (nicht im Git).

Neu dabei u. a.: Kern `SetEditorCopy` (Editor-Texte, Trennungen, `UndoHistory`), `SpeechText` (Vorlese-Aufbereitung),
`BackupImportPreview`, `WriteClock`, `FlashcardScrollTail` (Touchpad-Nachlauf), `LibraryStorePersistenceTests`; App
`Features/Settings/BackupImportSheet.cs`, `SettingsWipeSheet.cs`, `Features/SetDetail/TextExportSheet.cs`,
`App/ShortcutsSheet.cs` (F1), `DesignSystem/Accessibility.cs` (Kontrast, Transparenz), `DesignSystem/ViewThatFits.cs`,
Editor als partielle Klasse (`SetEditorCardList.cs`, `ImportPanel.cs`). `PromptRequest` kann `Content`, `Width`,
`KeyHandler` (Blätter). Snapshot-Werkzeug: `--only=learn|write|flashcards|editor|exam|settings|shell`, `contrast`, `solid`.

Bewusst nicht: Synonyme ausserhalb des Sets (Apple-Sprachmodell), Haptik, Menüleiste (dafür F1 und Rechtsklick),
Blätter über dem Lernbildschirm (Ctrl+N verlässt ihn; Prüfung fragt vorher). Ungetestet auf echtem Windows: Pinyin-
Eingabe, Touchpad-Nachlauf, SAPI-Stimmenwahl, Kontrastdesign, bewegter Hintergrund (CPU/GPU beobachten).

## Neue Funktionen nach 1.2 (3.11.2026, Branch `windows-import`)

Joan: «mache neue Features jetzt». Alles, was gegenüber Mac und früherer Web-App fehlte:

- **PDF- und Foto-Import** im Editor: Ablagefläche «Datei hierher ziehen» (TXT, CSV, PDF oder Foto), «Datei wählen …»
  (mehrere), Ziehen auf den ganzen Editor, Ctrl+V eines Bildes oder kopierter Dateien im Importfeld, «Aus Zwischenablage».
  Fortschritt ab 160 ms mit Prozent und «Abbrechen» (auch Esc), Hinweise («Seite 3 konnte nicht gelesen werden»), Titel aus
  dem Dateinamen, Zusammenfassung als Toast (`SetEditorScreen`: `ImportSources`, `FinishImport`, `DropZone`, `RenderProgress`).
  Kern (`Import/`, `TextLayout`, `OCRPostprocess`) portiert von einem Helfer-Agenten (Branch `windows-import-core`, gemergt).
  Windows-Teil `Services/ImportServices.cs`:
  - PDF-Text: **PdfPig** 0.1.16 (managed, läuft auch unter Linux), Wörter → `TextItem` (Grundlinie von oben, Schriftgrösse).
  - Gescannte Seiten: `Windows.Data.Pdf` rendert (Grösse aus `PdfPage.Size` in DIP, ×72/96 je Punkt).
  - Bilder: `Windows.Graphics.Imaging` (EXIF-Drehung, HEIC/TIFF wenn Windows den Codec hat), sonst Skia.
  - Texterkennung: `Windows.Media.Ocr`, eine Engine pro Schrift (Latein, Chinesisch, Arabisch), umhüllt von
    `BandedTextRecognizer`. **Wichtig:** Windows richtet schräge Bilder intern gerade und meldet die Boxen im gedrehten Bild
    (`OcrResult.TextAngle`); `Geometry` dreht sie zurück, sonst liegen die Zeilen der Teilbilder verschieden und Wortstücke
    («ruder» aus «Bruder») bleiben stehen. Leerzeichen zwischen chinesischen Zeichen werden entfernt.
  - Fehlt Windows die Texterkennung einer Lernsprache, sagt ein Toast einmal, wo man sie hinzufügt (`MissingRecognizer`).
    Joans Laptop hat nur **de-DE** als OCR-Sprache: Französisch wird mit dem deutschen Erkenner gelesen (Akzente teils falsch).
  - App mit zwei Zielen: `net10.0-windows10.0.19041.0` (echte App, `#if WINDOWS`, `build.sh -f …`) und `net10.0`
    (Snapshot-Werkzeug unter Linux). Die WinRT-Projektion macht die exe ~84 statt 63 MB.
- **Rechtschreibhilfe** im Editor (`VocabSpellChecker` im Kern, Port mit Tests; Windows `ISpellCheckerFactory` per COM in
  `Services/WindowsSpellEngine.cs`): Hinweise unter der Karte «‹separee› → séparée?», Menü mit Vorschlägen und
  «ignorieren» (gemerkt in `preferences.json`), Zähler «3 mögliche Tippfehler». Prüft nur Sprachen mit Windows-Wörterbuch
  (Joans Laptop: nur Deutsch).
- **Sonderzeichen-Leiste** (`DesignSystem/SpecialCharacterBar.cs`) unter dem Antwortfeld in Lernen/Schreiben/Prüfung.
- **Bildschirmleser-Ansagen** (`DesignSystem/Announcer.cs`): Live-Regionen (UIA LiveRegionChanged) für die Announce-Effekte,
  Markieren, Karteikarten, Prüfungsnote, «Noch eine Minute», Toasts, Import-Fortschritt (höchstens alle 1,5 s).
- Prüfen ohne Fenster auf Windows: ein eigenes Prüfprogramm (nicht im Git): `win-check.exe`
  (Wörterbücher, OCR-Sprachen, Rechtschreibung), `win-check.exe <dateien>` (ganzer Import), `win-check.exe --raw <bild>`
  (Rohzeilen jedes Teilbilds). Snapshot: `--only=editor`.

## Ersetzt die frühere Windows-App (1.2, 3.11.2026)

Joan: «aktuellen Stand in main, neues Release, ersetze die Webapp»; beim ersten Start soll sie **alles 1:1 übernehmen**
und die Web-App **deinstallieren**.

- **Daten** jetzt in `%LOCALAPPDATA%\Wortschatz\library.json` (+ `preferences.json`), also im Ordner der früheren App
  (`FileBackend.DefaultPath`). Die Testversionen davor speicherten in `%LOCALAPPDATA%\Wortschatz Native\`; die bleiben
  dort liegen und werden nicht übernommen.
- **Übernahme beim ersten Start** (`AppModel.OpenDefault`, nur wenn es noch keine `library.json` und keine Sicherungen
  gibt): `Wortschatz.Core/LegacyWebStorage.cs` liest das localStorage der früheren App direkt aus der LevelDB von WebView2
  (`WebView2\EBWebView\Default\Local Storage\leveldb`, Origin `https://wortschatz.example`, eigener Leser für Log-
  und Tabellendateien inkl. Snappy, keine Pakete) und legt die Schlüssel 1:1 ab: `sets`, `progress:*`, `session:*`,
  `learn:*`, `settings`, `activity` → `library.json`; `flashcards:*`, `pref:*` (Töne, Karteikarten-Vorderseite/Mischen,
  Wiederholungsfragen, Prüfung → pro Set, Lernserie-Tag) und `hint:learn` → `preferences.json`. Nicht übernommen:
  `pref:voices` (Browser-Stimmen ≠ Windows-Stimmen). Toast «N Lernsets aus der bisherigen Windows-App übernommen.»
- **Deinstallieren** (`Services/EarlierApp.cs`, im Hintergrund, bei jedem Start erneut versucht bis erledigt, Merker
  `earlierApp.removePending` in `preferences.json`): nicht solange eine Wortschatz-exe der Version ≤ 1.1 läuft; zuerst
  `Backup der bisherigen Windows-App.json` in den Datenordner (Backup-Format der Web-App, ohne Backup wird nichts
  gelöscht), dann die Ordner `WebView2\` und `App\`, dann in «Downloads» und auf dem Desktop nur Dateien mit den
  Download-Namen der Seite (`Wortschatz-1.0…`/`Wortschatz-1.1…-Windows.exe`, auch «(1)») und Version ≤ 1.1.
  **Nie** `Wortschatz.exe` oder `Wortschatz Kopie.exe` (gleiche Versionsangaben, darum nur über den Namen unterscheidbar),
  nie die laufende exe. Verknüpfungen auf die alte exe bleiben (die alte App legte keine an).
- Testen ohne echte Daten: `WORTSCHATZ_NATIVE_DATA=<Ordner>` + `WORTSCHATZ_LEGACY_DATA=<Ersatz für %LOCALAPPDATA%\Wortschatz>`
  (exe-Dateien werden dann nur in diesem Ordner gesucht). Ein Testordner ohne `WORTSCHATZ_LEGACY_DATA` übernimmt und
  löscht nie etwas Echtes. So auf dem Laptop geprüft (Kopie von Joans WebView2-Daten: 4 Sets, Fortschritt, Lernrunde,
  Karteikarten-Stapel, Einstellungen übernommen; Ordner und zwei Download-exes entfernt, `Wortschatz.exe` blieb).
- Tests: `LegacyWebStorageTests` (selbst geschriebene LevelDB-Dateien, Snappy, Übernahme aller Teile).
- Version `1.2.0` in `src/Wortschatz.App/Wortschatz.App.csproj`; `Downloadseite/tools/release-windows.sh` baut jetzt
  diese App (`build.sh test`).
- Was die frühere App konnte und hier noch fehlt: **PDF-/Foto-Import** (die Web-App lud dafür Bibliotheken nach),
  Sonderzeichen-Leiste, Rechtschreibhilfe, Bildschirmleser-Ansagen.

## Erster Test auf echtem Windows und Nachbesserung (3.11.2026)

Kurz: Fenster, Snap,
DPI 125 %, Schriften inkl. Arabisch/Chinesisch, alle Lernmodi, Animationen, Datei-Dialoge und Vorlesen laufen auf Windows.
Joan: «du darfst gleich alles beheben … auch Performance». Behoben in diesem Commit:

- **Editor:** Liste im Importfeld ging beim Erstellen ohne Nachfrage verloren → wie Mac: leeres Set übernimmt sie,
  sonst «Liste noch nicht übernommen» (anhängen / ohne Liste); «Karten übernehmen» fragt Anhängen/Ersetzen (Ersetzen behält
  Karten-ID und Stern gleicher Begriffe); Esc mit Änderungen fragt «Änderungen verwerfen?»; Titel/unvollständige Karten
  werden markiert statt leer gespeichert; Ctrl+O öffnet direkt die Datei-Auswahl, Dateiname wird Titel.
- **Rückfragen** allgemein: `AppModel.Ask(PromptRequest)` + Ebene im `MainWindow` (Enter = Standard, Esc = Abbrechen).
- **Tastenkürzel** wie `AppCommands.swift` (Ctrl statt ⌘): Ctrl+N, Ctrl+O, Ctrl+, ; auf einem Set Ctrl+L / Ctrl+Shift+L /
  Ctrl+Alt+L / Ctrl+Alt+Shift+L, Ctrl+E, Ctrl+Entf.
- **Rechtsklick-Menüs** (`Features/Library/SetActions.cs` = `SetActionsMenu.swift`) in Seitenleiste, Übersichtskarten,
  «…»; pro Begriff Markieren/Vorlesen/Bearbeiten.
- **Vorlesen:** ohne Windows-Stimme für die Sprache wird nicht mehr mit falscher Stimme/stumm gelesen, sondern ein Toast
  sagt, wo man Stimmen hinzufügt. Einstellungen zeigen die installierten Stimmen mit «Probe hören».
- **Töne** (`Services/SoundEffects.cs`, gleiche Noten wie `SoundEffects.swift`, über winmm): Lernen, Schreiben,
  Karteikarten, Prüfung, Lernserie-Toast («Neue Lernserie gestartet …»). Schalter Einstellungen › Allgemein.
- **Übersicht** im Mac-Aufbau: Satz zum Tag, Kacheln mit Untertitel, Hero mit Ring, Sortierung, gestrichelte
  «Neues Lernset»-Karte, Karten mit Ring, Status und «Lernen/Weiterlernen» (`AdaptiveGrid`).
- **Lernset-Seite:** Panel mit grossem Ring und anklickbarer Legende, Filter Alle/Neu/Am Lernen/Gemeistert/Markiert/
  Schwierig (gemerkt pro Set), «Nur schwierige», Knöpfe in einer Zeile (`AdaptiveRow` = `ViewThatFits`), Erklärsätze.
- **Prüfung einrichten** wie `ExamSetupView`: «Begriff | Definition» bei gleicher Sprache, Wortzahl nur bis zur Set-Grösse
  («Alle 10»), Kopf, Zeilen mit Symbol und Erklärung, Hinweise, Pille «5 Wörter · 10 Minuten».
- **Optionen** (Lernen/Schreiben) und **Einstellungen** mit Tabs Allgemein/Lernen/Schreiben/Toleranz/Daten: alle sieben
  Toleranz-Schalter mit Beispielen, Standard-Lernoptionen, «Standard wiederherstellen».
- Arabisch in Antwort-Kacheln rechtsbündig.
- **Performance** (auf dem Laptop gemessen, Joans Daten, 289-Begriffe-Set): Lernset-Seite 1,5 s → 0,1 s, Editor 2,5 s →
  0,07 s (Listen virtualisiert); Start 4,2 s → 2,5 s (`PublishReadyToRun` in `build.sh`, exe 63 statt 48 MB); jede Antwort
  schrieb die ganze Bibliothek 2× auf dem UI-Thread (28 ms) → jetzt gesammelt nach 0,4 s im Hintergrund
  (`AppModel.SaveSoon`, `LibraryStore.EncodePending/WriteEncoded`, Tests `LibraryStoreSaveTests`), beim Schliessen `Flush`;
  Übersicht/Seitenleiste lesen einen `LibrarySnapshot` statt pro Zeile den Store.
- Testhilfen: `WORTSCHATZ_NATIVE_DATA=<Ordner>` (eigener Datenordner), `WORTSCHATZ_TRACE=1` (Zeiten nach
  `%TEMP%\wortschatz-trace.log`).

Noch offen: Bildschirmleser-Ansagen, PDF/Foto-Import, Rechtschreibhilfe, Sonderzeichen-Leiste, Touchpad-Gesten auf echtem
Gerät, arm64.

## Warum C# + Avalonia

- **Läuft gut unter Windows:** .NET ist Microsofts eigene Plattform; Ergebnis ist eine einzelne `.exe`, keine Installation.
- **Kein Windows-Look:** Avalonia zeichnet die Oberfläche selbst (Skia), wie Flutter – das Glas-Design der Mac-App lässt
  sich nachbauen, ohne Fluent/WinUI.
- **Leicht von der Mac-App zu übernehmen:** Swift → C# ist eine sehr direkte Übersetzung (Strukturen, Enums, async).
  Jede Swift-Datei des Kerns hat eine gleichnamige C#-Datei mit denselben Funktionen (siehe `PORTING.md`).
- **Claude kann es ohne Windows-Rechner bauen und testen:** `dotnet` läuft unter Linux/macOS; die Kern-Tests und
  Oberflächen-Screenshots (Avalonia headless) laufen dort, und `dotnet publish -r win-x64` erzeugt die Windows-exe.

## Aufbau

| Ordner | Inhalt | Mac-Gegenstück |
|---|---|---|
| `src/Wortschatz.Core/` | Plattformunabhängige Logik: Modelle, Speicher, Antwortprüfung, Parser, Lern-/Schreibmodus, Import-Kern (`Import/`: PDF/Foto/Textdateien, Windows-Dienste hinter Schnittstellen) … | `mac/Packages/WortschatzCore/Sources/WortschatzCore/` |
| `tests/Wortschatz.Core.Tests/` | xUnit: Paritätstests gegen die JS-Fixtures + Unit-Tests | `mac/Packages/WortschatzCore/Tests/WortschatzCoreTests/` |
| `src/Wortschatz.App/` | Avalonia-Oberfläche (Glas-Design, C#-Code statt XAML), Windows-Dienste (Vorlesen, Dateien) | `mac/Wortschatz/` |
| `tools/Wortschatz.Snapshots/` | Rendert die Bildschirme headless als PNG (Designprüfung ohne Windows) | `DebugSnapshot.swift` |
| `build.sh` | `dist/Wortschatz.exe` (self-contained, eine Datei) | `Downloadseite/tools/release-mac.sh` |

Die Paritätstests lesen die **Fixtures der Mac-App direkt** aus
`mac/Packages/WortschatzCore/Tests/WortschatzCoreTests/Fixtures/*.json` (aus der JS-Referenz erzeugt, siehe
`mac/Parity/README.md`). Dieselben Fälle, dieselben Erwartungen – Mac, Web und Windows verhalten sich gleich.

## Bauen und testen

```bash
cd windows-native
dotnet test tests/Wortschatz.Core.Tests          # alle Kern-Tests (410, ~35 s)
dotnet test tests/Wortschatz.Core.Tests --filter GradingParityTests
dotnet run --project tools/Wortschatz.Snapshots -- /tmp/shots    # Bildschirme als PNG (Linux, ohne Windows)
dotnet run --project tools/Wortschatz.Snapshots -- /tmp/shots dark --only=flashcards   # dunkel, nur Karteikarten
./build.sh                                        # dist/Wortschatz.exe für Windows (x64), ./build.sh arm64 für ARM
```

Voraussetzung: .NET SDK 10 (`dotnet --version`). Unter Ubuntu: `apt-get install dotnet-sdk-10.0`.

## Stand (laufend nachgeführt)

| Teil | Stand |
|---|---|
| Grundlagen (JSCompat, JSONValue, JsRegex, Random/IDGen, TimeUtil, TextNormalizer, Models) | ✅ portiert, Text/Zeit/Zufall-Parität grün |
| Mastery | ✅ Parität grün (7'671 Fälle) |
| Grading (Antwortprüfung) | ✅ Parität grün (65'855 Fälle) |
| Labels, Synonyms (+ ExtendedSynonyms, reiner Teil) | ✅ Synonym-Parität grün |
| LangDetect (Spracherkennung) | ✅ Parität grün (32'073 Fälle); Lexikon per `tools/gen-langdetect-lexicon.mjs` aus dem JS erzeugt |
| VocabParser (Import-Parser) | ✅ Parität grün (9'097 Fälle) |
| LibraryStore (Speicher), Backup | ✅ Parität grün (1'197 Fälle inkl. Szenarien); Daten in `%LOCALAPPDATA%\Wortschatz\library.json`, Backups im selben Format wie Web/Mac; Übernahme der früheren App (`LegacyWebStorage`) |
| LearnEngine (Lernmodus-Logik, inkl. Mac-Wiederholungsfragen) | ✅ Parität grün (1'540 Fälle: 746 Lernabläufe mit 5'938 Zwischenständen, Antwortoptionen) + `LearnReviewTests` |
| LearnTypeAhead (Tippen bei Mehrfachauswahl) | ✅ Tests portiert (Bereiche in UTF-16 wie die JS-Tests) |
| WriteSession (Schreibmodus-Logik) | ✅ Parität grün (859 Fälle, 5'141 Zwischenstände) |
| Flashcards (Karteikarten), Exam (Prüfung, Schweizer Note), StudyFlowCommon (Tasten) | ✅ Mac-Tests portiert (die Web-App hat beides nicht, darum keine Fixture) |
| WriteFlow, WriteFlowModel, WriteFlowMachine, WriteFlowText (Bildschirm-Logik «Schreiben») | ✅ Web-Parität des Modells grün (>1'500 Fälle aus `WriteFlowWebCases.swift`), 39 Reducer-Tests (`WriteFlowTests`) portiert; `WriteFlowKeyTests` noch nicht |
| LearnFlow, LearnFlowModel, LearnFlowReducer (Bildschirm-Logik «Lernen») | ✅ 58 Reducer-Tests (`LearnFlowTests`, inkl. «nur Enter»- und Tastenhämmer-Läufe), Tipp-Tasten- und Wiederholungs-Bildschirmtests portiert |
| `LearnFlowModelTests`, `WriteFlowKeyTests`, `WriteFlowModelTests`, `LearnEngineTests` (Mac-Unit-Tests) | ⏳ nicht portiert – Parität und Reducer-Tests decken das Verhalten ab |
| TextLayout, OCRPostprocess (Zeilen/Spalten aus PDF-Text und OCR-Wortboxen, Umlaute, Chinesisch) | ✅ Parität grün (`layout.json` 7'048 Fälle, `ocr.json` 3'098 Fälle) + `TextLayoutTests`, `TextLayoutScriptsTests`, `OCRPostprocessTests`, `OCRPostprocessCJKTests` |
| Import-Kern (`Import/`: ImportPipeline, PDFTextExtractor, OCRService/OCRTextAssembler, BandedTextRecognizer, OCRImage, TextFileDecoder, ImportFileType) | ✅ portiert (Branch `windows-import-core`), Logik mit Fakes getestet (Textseiten vs. Scans, 30-Seiten-Grenze, Warnungen, Fortschritt, Abbruch); PDF, Bild-Dekodierung und OCR sind Schnittstellen (`IPdfReader`, `IImageDecoder`, `ITextRecognizer`), die die App für Windows implementiert – siehe PORTING.md «Import» |
| Oberfläche (Avalonia, Glas-Design): Hülle, Übersicht, Lernset, Lernen, Schreiben, Karteikarten, Prüfung, Editor mit Listen-Import, Einstellungen (Hell/Dunkel, Backup) | ✅ gebaut, unter Linux headless geprüft (Screenshots); **auf Windows noch nicht getestet** |
| Animationen (Motion/Effects; Karteikarten, Lernen, Schreiben, Prüfung, Toasts, Konfetti, Seiten-Eintritt) | ✅ wie Mac (Kurven/Federn aus `Metrics.swift`), Reduce Motion über Windows-«Animationseffekte»; nur als Einzelbilder geprüft |
| Vorlesen (Windows-Stimmen über SAPI/OneCore) | ✅ geschrieben, auf Windows ungetestet |
| Töne, Bildschirmleser-Ansagen, PDF-/Foto-Import, Rechtschreibhilfe, Sonderzeichen-Leiste | ✅ (siehe «Neue Funktionen nach 1.2») |
| `build.sh` → `dist/Wortschatz.exe` (eine Datei, ohne .NET-Installation) | ✅ |

## Für den Test auf Windows (Claude mit Gerätezugriff)

1. `./build.sh` (oder fertige `dist/Wortschatz.exe` kopieren) und starten. Daten liegen in
   `%LOCALAPPDATA%\Wortschatz\library.json`. Achtung: Der erste Start übernimmt und entfernt die frühere App; zum
   Testen `WORTSCHATZ_NATIVE_DATA` und `WORTSCHATZ_LEGACY_DATA` setzen (siehe oben).
2. Lernsets aus der heutigen App: dort Backup exportieren, hier *Einstellungen → Backup laden* (oder auf der leeren Übersicht).
3. Prüfen: Fenster ziehen/maximieren/Snap (eigene Titelleiste, `WindowDecorations.BorderOnly` + Rollen), Schriften
   (Onest/Nunito, Fallback Segoe UI/Microsoft YaHei für Chinesisch, Arabisch rechts-nach-links), Tasten (Enter, Alt+Enter,
   Ctrl+Enter, Ziffern 1–4/0, Pfeile, Tippen auf Mehrfachauswahl, Esc), Vorlesen, Hell/Dunkel, Datei-Dialoge.
4. Bekannte offene Punkte stehen in PORTING.md («Noch nicht portiert»).
