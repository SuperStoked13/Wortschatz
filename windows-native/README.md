# Wortschatz – native Windows-App (C# / .NET 10 / Avalonia 12)

Native Windows-Version der App «Wortschatz», gebaut als Port der **Mac-App** (`mac/`, Swift/SwiftUI). **Seit 1.2
(3.11.2026) die offizielle Windows-App** und auf `main`; sie ersetzt die frühere Windows-App (`windows/` + `Website/`,
WebView2, bis 1.1), die nicht mehr ausgeliefert wird. Entstanden auf dem Branch `native-windows-app`. Design: Richtung
**A · Glas** (so nah wie möglich an der Mac-App), von Joan am 2.11.2026 gewählt.

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
| `src/Wortschatz.Core/` | Plattformunabhängige Logik: Modelle, Speicher, Antwortprüfung, Parser, Lern-/Schreibmodus … | `mac/Packages/WortschatzCore/Sources/WortschatzCore/` |
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
dotnet test tests/Wortschatz.Core.Tests          # alle Kern-Tests (205, ~35 s)
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
| TextLayout, OCRPostprocess (PDF/Foto-Import) | ⏳ später (braucht Windows-OCR/PDF) |
| Oberfläche (Avalonia, Glas-Design): Hülle, Übersicht, Lernset, Lernen, Schreiben, Karteikarten, Prüfung, Editor mit Listen-Import, Einstellungen (Hell/Dunkel, Backup) | ✅ gebaut, unter Linux headless geprüft (Screenshots); **auf Windows noch nicht getestet** |
| Animationen (Motion/Effects; Karteikarten, Lernen, Schreiben, Prüfung, Toasts, Konfetti, Seiten-Eintritt) | ✅ wie Mac (Kurven/Federn aus `Metrics.swift`), Reduce Motion über Windows-«Animationseffekte»; nur als Einzelbilder geprüft |
| Vorlesen (Windows-Stimmen über SAPI/OneCore) | ✅ geschrieben, auf Windows ungetestet |
| Töne, Bildschirmleser-Ansagen, PDF-/Foto-Import, Rechtschreibhilfe, Sonderzeichen-Leiste | ⏳ noch nicht |
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
