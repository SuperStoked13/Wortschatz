# Wortschatz – native Windows-App (C# / .NET 10 / Avalonia 12)

Native Windows-Version der App «Wortschatz», gebaut als Port der **Mac-App** (`mac/`, Swift/SwiftUI). **Seit 1.2
(3.11.2026) die offizielle Windows-App** und auf `main`; sie ersetzt die frühere Windows-App (`windows/` + `Website/`,
WebView2, bis 1.1), die nicht mehr ausgeliefert wird. Entstanden auf einem eigenen Branch. Design: Richtung
**A · Glas** (so nah wie möglich an der Mac-App), von Joan am 2.11.2026 gewählt.

## Updates wie die Mac-App (25.11.2026, nach Windows 1.7.1)

Joan: «schaue an, wie Mac das Auto-Update macht … und baue dann dasselbe Prinzip für Windows». Wie Anthonys Sparkle-Updates
(`mac/Wortschatz/Services/README.md` › «Updates»), nur ohne Sparkle: Etwa einmal am Tag fragt die App GitHub nach dem
neuesten **veröffentlichten** Release des öffentlichen Repos mit einem `windows-update.json` (Entwürfe, Vorabversionen
und Mac-Releases zählen nicht), lädt die exe desselben Releases im Hintergrund und setzt sie an die Stelle der laufenden,
wenn das Fenster zugeht. Beim nächsten Start steht in der Seitenleiste «Aktualisiert auf …» mit der ersten Neuigkeit.
Einstellungen › Daten › Updates: «Automatisch aktualisieren» (aus: nichts lädt oder installiert sich ungefragt), «Jetzt
suchen» (fragt bei einem Fund «Jetzt neu starten» oder «Später»). Release-Seite: `VEROEFFENTLICHEN.md` › «Updates (Windows)».
- **Kern** (läuft und ist getestet überall, `UpdateFeedTests`, `UpdateDownloadTests`): `UpdateFeed.cs` (Release finden,
  Manifest prüfen, `UpdateNoticeStore` wie auf dem Mac), `UpdateDownload.cs` (`UpdateCheck`: Liste → Manifest → exe,
  `UpdateInstaller`: ersetzen, aufräumen; `PendingUpdate`). Das Netz kommt von der App (`IUpdateTransport`).
- **Signatur:** `windows-update.json` = `{"format": 1, "manifest": "<JSON-Text>", "signature": "<base64>"}`, ECDSA
  P-256/SHA-256 über die UTF-8-Bytes des Manifest-Texts (eingebaut in .NET, kein Paket); das Manifest nennt Version,
  Dateiname (nur der Name: immer die Datei desselben Releases), Grösse, SHA-256, Prozessor und die Neuigkeiten (Deutsch und
  Englisch). Die App nimmt nur Schlüssel aus `AppUpdater.PublicKeys`; der private liegt bei dem, der Windows
  veröffentlicht. Vor dem Ersetzen prüft sie die exe nochmals (SHA-256 und die Versionsangabe in der exe).
- **Ersetzen:** Windows lässt eine laufende exe umbenennen, nicht überschreiben. Beim Schliessen (`MainWindow.Shutdown`,
  nach dem Speichern): die laufende exe → `<Name>.old` (versteckt), die neue an ihren Namen und Ort – Verknüpfungen,
  Taskleiste und Startmenü öffnen die neue Version. Sie hat keine Download-Markierung, also keine SmartScreen-Frage. Der
  nächste Start löscht die `.old`. Der Dateiname behält die alte Nummer (`Wortschatz-1.7.1-Windows.exe` enthält dann 1.8);
  `OlderVersions` erkennt Versionen an der Versionsangabe in der exe, nicht am Namen. Liegt die exe in einem Ordner ohne
  Schreibrecht (Programme), sagt Einstellungen › Daten, dass neue Versionen von der Downloadseite kommen.
- **Gedeckelt:** Misslingt das Ersetzen dreimal (`PendingUpdate.MaxFailures`), gibt die App diese Version auf (lädt sie
  nicht mehr, Hinweis in den Einstellungen); eine neuere fängt neu an. Eine geladene Version, deren Release inzwischen
  gelöscht oder Vorabversion ist, verwirft die nächste Suche (wie Anthonys Mac-Gegenprüfung 8ac465f). Fehler stehen englisch in `preferences.json`
  (`update.error`). Getestet mit simuliertem Fehlschlag (`UpdateDownloadTests`).
- **Nur die App der Downloadseite:** Netz und Ersetzen nur im Windows-Build (`#if WINDOWS`), nicht in Debug-Builds; das
  Bild-Werkzeug zeigt Hinweis und Einstellungen mit `--only=updates` (`AppUpdater.Preview`).
- **Datenschutz:** GitHub sieht die IP und `User-Agent: Wortschatz/<Version> (Windows)`. Die Downloadseite sagt es ab der
  ersten Windows-Version nach 1.7.1 (`windowsUpdates`/`appUpdates` in `Downloadseite/server/lib/app.mjs`).
- **Ausprobieren ohne Release:** `tools/update-test.sh` baut zwei Testkopien (9.0 → 9.1) mit Wegwerf-Schlüssel
  (`-p:UpdateTestKey=…`, nie in `build.sh`), die ihre «Releases» aus dem Ordner `update-test` daneben lesen und ihre
  eigene Bibliothek dort haben → `dist/update-test/` auf einen Windows-PC kopieren, `ANLEITUNG.txt` folgen.
  Auf einem echten Windows-11-Laptop durchgespielt (25.11.2026): Suche nach etwa 20 s von selbst, «Version 9.1 ist
  bereit», nach dem Schliessen ist die exe 9.1 (alte als versteckte `.old`), beim nächsten Start «Aktualisiert auf
  9.1» mit «+1 weitere» und die `.old` ist weg; «Jetzt neu starten» startet 9.1 sofort. Die echte App fragt GitHub
  (neuestes veröffentlichtes Release mit `windows-update.json`; ohne neuere Version → «Wortschatz ist aktuell»).
- **Echt geprüft (26.11.2026, Release 1.8.3):** 1.8.2 über den Link der Downloadseite geladen (Prüfsumme wie
  `checksums.txt`), erst nach dem Release `v1.8.3-windows` gestartet: nach 26 s war 1.8.3 geladen (nichts zu sehen,
  wie gewollt), beim Schliessen ersetzt – gleicher Name, byte-gleich mit der Release-Datei, alte kurz als versteckte
  `.old` –, beim nächsten Start «Aktualisiert auf 1.8.3» mit der ersten Neuigkeit und «+1 weitere», `.old` weg.

## Optimierung 26.11.2026: weniger Abfall beim Lernen, Mausfehler, langer Lernset-Name

Joan: «detailed optimization, performance, efficiency and smoothness check … without any redundant code». Diesmal
zuerst **gemessen** – auf einem Windows-11-Laptop mit einer Mess-Kopie der App (Bildabstände, Taste bis Bild, Speicher,
Aufräumpausen der Laufzeit aus deren Ereignissen; nie veröffentlicht, nicht im Repo) und einer Kopie von Joans
grösster Bibliothek (1705 Karten, 541 im grössten Set) –, dann umgesetzt, was die Messung zeigte.
- **Befund:** Flüssig war die App schon: während Animationen 99 % der Bilder bei 60 fps (am Netzteil), Start warm
  0,77 s, Leerlauf ~1 % eines Kerns. Aber beim Lernen fielen **~20 MB Abfall pro Antwort** an (40 Antworten: 850 MB,
  13 schwere Aufräumläufe), fast alles vom Speichern der ganzen Bibliothek nach jeder Antwort (zweimal: Antwort und
  Weiter). Vom Arbeitsspeicher (~240 MB privat) sind nur ~14 MB Daten der App, der Rest Laufzeit, Skia/Grafik und die
  beim Start entpackten Assemblies.
- **Speichern** (`LibraryDocument.ToFileBytes`): schreibt die Datei direkt; Karten und Lernfortschritt-Einträge sind
  unveränderliche Records, ihr JSON wird einmal pro Objekt kodiert (`ConditionalWeakTable`) und danach kopiert;
  sortierte Schlüssel ohne LINQ und ohne Abfall (`SortedKeys`, `PooledByteBuffer`). Pro Speichern 9 → 0,64 MB Abfall
  (≈ die Datei selbst), byte-gleiche Datei (Prüfsumme alt/neu, Paritätstests). Nachbau der Lernschleife unter Linux:
  pro Antwort 12,6 → 4,5 MB.
- **Lernrunden** (`LearnEngine.ChoicePool`, Port von Anthonys Mac-Änderung 4444ee7): neue Runde mit 541 Karten 10 → 3 ms
  (längste 24 → 7 ms), Abfall 11 → 2 MB; alle 3410 Antwortlisten der echten Lernsets alt/neu gleich.
- **Maus:** Ein Feld der Mehrfachauswahl markierte sich bei `PointerEntered` – auch wenn die nächste Frage unter dem
  ruhenden Zeiger erschien; das baute den Bildschirm ~40 ms nach der neuen Frage neu und brach ihre Einblendung ab
  (Laptop: 5 von 11 Fragen). Jetzt erst bei Bewegung (`PointerMoved`): 0 von 10.
- **Lernset-Name** oben links in den Lernbildschirmen (Joan: «unschön abgeschnitten»): Grid statt StackPanel, endet
  mit «…» (`StudyChrome.BackPill`).
- **Kleineres:** gehaltene Taste baut Lernen/Schreiben nicht mehr neu (schnitt Animationen ab); Prüfung baut die
  Sonderzeichen-Leiste erst beim ersten Fokus (541 Fragen Französisch: ~30'000 Controls weniger); Einstellungen ›
  Daten misst die Backup-Grösse einmal pro Bibliotheksstand (vorher bei jedem Aufbau die ganze Bibliothek kodiert,
  Seite 53–58 ms); Lernset-Seite und Editor halten nur noch die sichtbaren Zeilen fest (`TrackRow`); Suche faltet
  jeden Text nur einmal (`StudyCopy.Fold`, vorher dreimal vorhanden); Ordner für ältere Downloads im Hintergrund;
  Synonymlisten entpacken ohne vierfachen Puffer. Toter Code weg: `IsAnimating`, `MotionState.Current`,
  `Palette.FlameText`, `StoreChange.Touches`, `LearnReview/LearnRecheck.Clone`, drei gleiche `Detach`, ein using.
  Bewusst behalten, weil Android/Pro/Abgleich (privates Repo) sie brauchen: `AppPreferences.TimesKey`,
  `StoreMessages.BadState`, `AppModel.OpenAt`/`ReceiveShared`, `AppDevice.DeviceName`, `ScrollToRow`, zwei usings in
  `ImportPanel`.
- **Laptop vorher/nachher** (gleiche Fahrt, gleiche Datenkopie, am Netzteil; 40 Antworten Lernen): Abfall 830 → 276 MB,
  Aufräumläufe 119 → 40 (schwere 13 → 4), Pausen zusammen 395 → 153 ms, längste 14 → 10 ms; Bilder während Animationen
  weiterhin 99,4 % unter 25 ms; Speicher privat Spitze 431 → 419 MB. Auf Akku war alles langsamer, der Unterschied gleich.
- **Geprüft:** 726 Kern-Tests, alle 175 Bilder des Bild-Werkzeugs (Desktop, Handy, Einstellungen, Editor, Hülle,
  Nachkontrolle) pixelgleich mit zwei Referenzläufen, Downloadseite-Tests, Builds von `main` und `pro` des privaten
  Repos (mit Abgleich bzw. Pro).
- **Offen gelassen (Entscheid Joan):** exe **ohne Kompression** (`EnableCompressionInSingleFile=false`): Start 0,77 →
  0,69 s, ~50 MB weniger Arbeitsspeicher, aber 189 statt 78 MB Download. Trimmen (kleiner und schneller) bräuchte
  Tests von COM/WinRT auf Windows. Multiple Choice baut beim Markieren noch den ganzen Bildschirm neu
  (`LearnScreen.Render`, ~150 Controls, wenige ms) – nach dem Mausfehler kaum noch spürbar.

## Optimierung: flüssiger, weniger Speicher, toter Code weg (25.11.2026, Windows 1.7.1)

Joan: «optimize and remove leftovers … run as smooth and efficiently as possible», aussen soll alles gleich aussehen.
Drei Helfer haben den Code gelesen (Lern-Bildschirme, Hülle und Seiten, Kern), umgesetzt wurde, was nichts am Bild
ändert. Live mit Windows 1.7.1 (25.11.2026, Release `v1.7.1-windows`).
- **Build** (`build.sh`): ReadyToRun pro Assembly statt eines Sammelblocks (`PublishReadyToRunComposite=false`). Der
  Sammelblock enthielt die ganze .NET-Laufzeit vorkompiliert (132 MB entpackt) und wurde bei jedem Start ganz entpackt.
  exe 75 statt 89 MB. Laptop (Kopie von Joans Daten, Median): vorher Fenster 0,90 s, bedienbereit 1,13 s, 375 MB
  Arbeitsspeicher (330 MB privat; 6 Starts); nur Build-Änderung 0,87 s / 1,13 s / 330 MB (248 privat; 5 Starts); alles
  zusammen 0,76 s / 0,76 s / 319 MB (248 privat) – nur 1 Start, danach lief der Laptop auf Akku und die Messaufgabe
  startete nicht mehr. Leerlauf bei allen unter 1 % eines Kerns (der bewegte Hintergrund kostet fast nichts).
- **Nach jeder Antwort:** Die Bibliothek wurde 300 ms nach der Antwort auf dem UI-Thread kodiert (Joans 1129 Karten:
  19 ms, mitten in der Animation der nächsten Frage). Jetzt nur noch eine Kopie (`LibraryStore.PendingSnapshot`,
  0,02 ms), Kodieren und Schreiben im Hintergrund (`LibraryStore.Encode`, `JSONValue.ToJsonBytes` ohne Umweg über
  einen String, gleiche Bytes). Falsche Antwort: die Suche nach der anderen Karte mit demselben Begriff
  (`SameTermCards.TermKeys`, gemerkt pro Text; `ExtendedSynonyms.ArticlePrefixes` pro Sprache) 32 → 0,2 ms.
- **preferences.json** (jede sortierte Karteikarte speichert ihren Stapel): gesammelt nach 300 ms und im Hintergrund
  geschrieben; `AppPreferences.Flush` beim Schliessen (`MainWindow.Shutdown`) und in `AppModel.Flush`.
- **Start:** Die Vorlese-Stimmen (SAPI, COM, Registry) kommen erst beim ersten Vorlesen bzw. in den Einstellungen
  (`SapiSpeech.EnsureReady`); die App-Stile wurden doppelt gebaut.
- **Lernen starten:** Öffnet man ein Lernset, berechnet der Hintergrund die Wortarten der Karten vor
  (`LearnEngine.PrepareChoices`, rein, ohne Zufallszahlen): grösstes Set (541 Karten) erste Runde ~170 → ~80 ms.
- **Animationen:** `AnimatedValue.Set` ohne Bewegung (Wert schon am Ziel) startet keinen Frame-Takt mehr (vorher bei
  jedem Neuzeichnen eines Lernbildschirms und jeder Taste in der Prüfung eine halbe Sekunde lang). Symbole werden
  einmal geparst (`Icons.Parsed`), Konfetti und der Kartenstapel bauen ihre Formen nicht mehr in jedem Bild neu.
- **Kleineres:** Schreiben stoppt veraltete Weiter-Timer (`WriteController.StopStaleTimers`, wie Lernen; vorher
  zeichneten sie grundlos neu und schnitten Animationen ab), Prüfung aktualisiert pro Taste nur die eigene Zeile,
  Übersicht baut sich nur noch neu, wenn Gruss oder Datum wechseln (nicht jede Minute), Rechtsklick-Menüs der
  Seitenleiste und Übersichtskarten entstehen erst beim Öffnen (`SetActions.AttachMenu`, gleiche Position), Stern
  speichert wie eine Antwort, «Alle markieren» in einem Schritt (ein Speicherfehler beendete vorher die App).
  Bewusst gelassen: Der Wechsel hell/dunkel baut zweimal – der zweite Durchgang holt die Palette von «System» aus der
  neuen Theme-Variante (eine Sperre dagegen gab beim Wechsel Dunkel → System die falsche Palette; Prüfung 25.11.).
- **Toter Code entfernt** (~230 Zeilen): ungenutzte Bausteine in `StudyChrome`, `Ui`, `StudyText`, `Icons.Ring`,
  `Motion`-Kurven, der Sprachmodell-Teil aus `ExtendedSynonyms.swift` (Windows nimmt die Synonymwörterbücher),
  `SubsetWhat`/`ScopeText`/`SubsetDescription`/`SegmentFills` (ersetzt durch ganze Sätze), unbenutzte Felder und usings.
  Nur von Tests benutzte Kern-Funktionen (Ports) bleiben, ebenso `SetLang` der Spracherkennung (braucht heute der
  Editor, `SetEditorScreen`).
- **Bewusst nicht** (Option für später, ändert sonst eventuell Animationen): Multiple Choice zeichnet bei jeder Taste
  und beim Überfahren einer Kachel den ganzen Bildschirm neu (`LearnScreen.Render`); ein Teilumbau nur der Kacheln
  spart einige ms pro Taste. Trimmen der exe (kleiner, schnellerer Start) braucht Tests auf Windows (COM, WinRT).
- **Bild-Werkzeug fest:** `Rand.Fixed` (gesetzt im Werkzeug) gibt allen Lern-Engines denselben Zufall, zwei Läufe
  zeichnen fast dieselben Bilder. Weiter wackeln nur, was in Echtzeit läuft: Hinweis-Meldungen (z. B. «Lernserie»
  nach 580 ms), Weiter-Timer, Textcursor, die angezeigte Lernzeit. Vergleich vor/nach: jedes Bild gleich einem von zwei
  Referenzläufen, sonst von Auge prüfen.

## Ältere Downloads räumen sich weg (seit Windows 1.7)

Joan: eine neu heruntergeladene Version soll die alte ersetzen. `Services/OlderVersions.cs` (Regeln:
`Wortschatz.Core/OlderDownloads.cs`, Tests `OlderDownloadsTests`) löscht bei jedem Start im Download-Ordner, auf dem
Desktop und neben der laufenden exe Dateien mit dem Namen der Downloadseite (`Wortschatz-1.3-Windows.exe`,
`… (2).exe`), deren Versionsangabe «Wortschatz» 1.2 oder neuer und älter als die laufende ist – nie die laufende exe,
keine Version, die gerade läuft, keine umbenannte Kopie (`Wortschatz.exe`), nie 1.0/1.1 (das macht `EarlierApp` nach
der Übernahme). Daten teilen sich alle Versionen ab 1.2, darum gibt es nichts zu übernehmen. Mit
`WORTSCHATZ_NATIVE_DATA` sucht es nur dort und neben der exe. Auf dem Laptop geprüft (03.11.2026): 1.2/1.3-Downloads
weg, laufende 1.3, gleiche Version, umbenannte Datei und eine Fälschung mit passendem Namen bleiben.

## Lernen mit Abstand, Einstellungen (nach 1.3, 3.11.2026)

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

## Englisch (25.11.2026)

Wie Anthonys Mac-App (0545050, 4462868): Alle Texte sind weiter deutsch geschrieben (Quelle, Schweizer «ss») und gehen
durch `L()` (`Wortschatz.Core/CoreText.cs`); ohne Tabelle bleibt alles deutsch, Wort für Wort – so sehen es die
Paritäts- und alle anderen Tests.
- **Schreiben:** `L("Neu starten?")`, `L($"Runde {n} geschafft")` (Schlüssel = der Text mit `%@` je Wert, wie die
  Mac-Schlüssel: «Runde %@ geschafft»), `L("vor %@ Tagen", n.ToString())`; `Labels.Plural(n, "Karte", "Karten")`
  übersetzt über «%@ Karte»/«%@ Karten». Ganze Sätze, keine zusammengesetzten Satzteile; Text, der zur Laufzeit
  wechseln soll, nicht in `static readonly` (sondern berechnet). `using static Wortschatz.Core.CoreText;`
- **Englisch:** `Strings/en-mac.json` ist die Abschrift des Mac-Katalogs
  (`mac/Wortschatz/Resources/Localizable.xcstrings`, Mac-«%lld» als «%@», ohne Texte, die die öffentliche
  App nicht enthalten darf) – neu schreiben mit `python3 tools/strings.py sync`, wenn Anthony Texte ändert (ein
  Test meldet, wenn die Abschrift veraltet ist). Texte, die nur Windows/Android hat oder anders sagt («Ctrl+E», «Windows»,
  «Explorer», Windows-Einstellungen), stehen in `Strings/en.json` (gewinnt; Mehrzahl als `{"one", "other"}`).
- **Prüfen:** `python3 tools/strings.py check` (Texte ohne Englisch mit Datei:Zeile), `find TEXT` (Mac-Wortlaut
  suchen), `keys DATEI`. Der Test `TranslationCoverageTests.EveryTextHasEnglish` schlägt fehl, solange ein Text kein
  Englisch hat.
- **Sprache wählen:** Einstellungen › Allgemein › Sprache (System, Deutsch, English; Einstellung `app.language` dieses
  Geräts). System = Anzeigesprache von Windows bzw. des Handys: Englisch → Englisch, sonst Deutsch (wie der Mac). Anders
  als auf dem Mac gilt die Wahl sofort: `AppLanguage.Install` und das Fenster wird neu gebaut (`MainView.Rebuild`).
  Daten und Zahlen in der Sprache der App: `AppLanguage.FormattingCulture`.
- **Bilder:** Bild-Werkzeug mit `en` (ohne: immer Deutsch, egal welche Sprache der Rechner hat).

## Anthonys Issues #7, #8 und #9 (24.11.2026)

Anthony fand sie bei der Durchsicht der Einstellungen auf dem Mac (GitHub-Issues #7 bis #9):
- **#9 Wiederholungsfragen und Nachkontrolle gelten sofort** (Port von Mac 1.6.2, 99c6f42 und 83edec5):
  `LearnEngine.SetReview`/`SetRecheck` (geben ihre Eingabe zurück, wenn sich nichts ändert – Swift vergleicht Werte, C#
  prüft mit `ReferenceEquals`), `LearnFlow.SavedLearn.Switching`, im Reducer `ApplySwitches` (sofort, auch bei offenen
  Optionen; kein «Neu starten?» mehr für die beiden) und `Boot` (folgt der Nachkontrolle; wird die Sitzung dadurch fertig,
  wird sie als fertig gespeichert). App: `AppModel` › «Learn switches» stellt beim Start und bei jedem Umschalten alle
  gespeicherten Sitzungen um (`AppPreferences.LearnSwitchesChanged`, auch für importierte Einstellungen); ein offenes
  Lernen folgt über `LearnController.SwitchesMayHaveChanged`. «Standard wiederherstellen» im Lernen-Tab setzt die beiden
  mit zurück. Tests: `LearnSwitchesTests`, `LearnSessionSimulationTests` (Ports), `LearnReviewTests` angepasst.
- **#7 Optionen ausserhalb der Sitzung geändert** (Windows zuerst; der Mac hat es seit 1.7 anders gelöst – die Optionen
  gelten sofort, ohne «Neu starten?» –, für Windows offen: `PORTING.md` › «Mac und Windows gleichziehen»): Richtung, Fragetypen und Rundengrösse
  (Lernen) bzw. Richtung und «Mischen» (Schreiben) gelten weiter erst nach einem Neustart. Neu fragt eine fortgesetzte
  Sitzung mit Antworten «Neu starten?», wenn sie anders läuft, als die Optionen jetzt sind (`AskForChangedOptions` in
  `LearnFlowReducer`/`WriteFlowMachine`, auch bei einer Änderung von aussen, während sie offen ist); ohne Antworten
  beginnt sie still neu. «Später» merkt sich das Gerät pro Lernset (`KeptOptions`, Einstellung
  `keptOptions.learn|write.<Set>`): keine Frage mehr, bis sich die Optionen wieder ändern. Die Optionen in der Sitzung
  sagen dann, womit sie noch läuft (`RunningSettingsNote`). Tests: `OptionsChangedElsewhereTests`.
- **#8 Eigene Option zurück auf den Standard** (Windows zuerst, Mac gleich seit 1.7): Die Optionen eines Lernsets speichern über
  `LibraryStore.UpdateOwnStudyOptions`. Eine geänderte Option, die danach dem Standard entspricht, ist keine eigene mehr
  (`StudyOptionsPatch.DroppingStandard`; nur die geänderten Schlüssel, die wirksamen Werte bleiben gleich).
  `UpdateStudyOptions` bleibt `mergeStudy` der Web-App (Parität mit `store.json`). Tests: `OptionsChangedElsewhereTests`.
- Bilder: `--only=recheck`, 03u3 (Nachkontrolle aus) bis 03u5 (Hinweis in den Optionen). Nicht auf echtem Windows getestet.

## Anthonys Mac-Änderungen vom 24.11.2026 übernommen

Aus 8caea20, c157bfc und c678393 (und dem älteren a0d7483), mit den Mac-Tests nach C# gezogen:
- **Abtippen wie beim Antworten** (`CopyStep`): weiter geht es, sobald die Abschrift so akzeptiert würde wie eine Antwort
  («le collègue» für «le/la collègue»), ausser sie ist nur der Anfang der angezeigten Antwort («le cerveau» von «le cerveau,
  les cerveaux»: Enter). Nach einer kurzen Pause (`CopyStep.AdvanceMs` = 400 ms, ein normaler Weiter-Timer ohne
  Countdown-Strich); Enter überspringt sie, Weitertippen bricht sie ab, offene Optionen halten sie an. Tests:
  `CopyStepTests`, `LearnFlowTests`, `WriteFlowTests`. Anthony: ohne Eintrag in den Neuigkeiten.
- **Lernuhr in Lernen** pausiert wie beim Schreiben nach `WriteFlow.ClockIdleMs` (2 min) ohne Eingabe: dieselbe
  `WriteClock`, dazu `WriteClock.IsUserActivity(LearnFlow.Event)`; die erste Eingabe danach schickt `Resume`.
- **Eine Speicheränderung pro Antwort:** `LibraryStore.Batch` (Mac `batch`); Lernen und Schreiben schreiben Antwort und
  Sitzung darin (eine Meldung an die App statt zwei). Die übrigen Teile von c678393 (Mac-`library` unter dem
  Lernbildschirm, Backup-Grösse) braucht Windows nicht: die Übersicht wird hier nur bei Bedarf neu gebaut, und
  Einstellungen und Lernen sind nie gleichzeitig offen.
- **Seitenleiste** höchstens 360 breit (statt halbes Fenster), Start bleibt 262. Kapsel-Knöpfe hatte Windows schon
  (`WsButton`: Radius = halbe Höhe); die Begriffsliste rollt hier nie seitwärts.
- **Synonyme ausserhalb des Sets pro Lernset** (Mac a0d7483, 18.11.): Schalter unter «Toleranz» in den Optionen eines
  Lernsets (`StudyChrome.SynonymSwitch`, Einstellung dieses Geräts `extendedSynonyms.<Set>` wie die Soundeffekte);
  «Weitere Synonyme erkennen» in den Einstellungen sperrt ihn. `AppModel.ExtraAnswers(setId)` fragt bei jeder Antwort
  nach. Bilder: `--only=recheck`, 03u1/03u2.
- Nur Mac, nichts zu tun: ca0cd7b (Ton auf eigener Queue), ba1049b (Glas-Reste der Leiste), fe8428f.

## Multiple Choice nur einmal pro Begriff (24.11.2026)

Anthony: Jeder Begriff kommt beim Lernen nur einmal als Multiple Choice (ausser man hat sie falsch), danach nur noch
schriftlich. Gleich in der JS-Referenz (`learn.js`), auf dem Mac (`LearnEngine.swift`) und hier (`LearnEngine.cs`):
- Neu `LearnState.Solved` (JSON `solved`): Karten, die je richtig beantwortet wurden – aus dem Fortschritt
  (`SolvedFromProgress`: `Correct > 0` oder eine Serie) und bei jeder richtigen Antwort bzw. «Ich hatte recht».
  Multiple Choice nur noch bei Stufe 0 **und** nicht gelöst (`McStage`); eine falsche schriftliche Antwort setzt die
  Stufe zurück, bleibt aber schriftlich. Gespeicherte Sitzungen ohne `solved`: Karten ab Stufe 1 gelten als gelöst,
  der Rest kommt mit dem nächsten Vergleich mit dem Fortschritt (`MatchesProgress` prüft jetzt auch `Solved`).
- Tests: Parität gegen die neuen Fixtures (`learn.json`, `store.json`, neue Funktion `solvedFromProgress`),
  `LearnReviewTests` und `LearnFlowTests` angepasst. Auf dem Mac nicht gebaut (kein .NET-SDK dort); unter Linux
  am 24.11.2026 gebaut, alle C#-Tests grün.

## Ganz getippte Antwort geht ohne Enter weiter (Port von Anthonys Mac-Änderung, 23.11.2026)

Wie auf dem Mac (Commit 1fcd631): Multiple Choice wählt eine Antwort, sobald sie (oder eine ihrer Formen) ganz getippt ist
und nur noch sie passt (`LearnFlow.TypeAhead.IsTypedOut`; nicht vor einer Klammer, nicht wenn eine längere noch passt).
Abtippen in Lernen und Schreiben geht weiter, sobald die Antwort genau wie angezeigt dasteht (`CopyStep.IsTypedOut`); nur
mit Toleranz akzeptiert wartet es auf Enter (seit 24.11. anders, siehe oben). Windows-eigen: Die Controller zeichnen nach Tipp-Ereignissen sonst nicht neu
– wechselt die Phase dadurch, kommt das Neuzeichnen nachgeschoben; beim Schreiben (ein Feld für Antwort und Abtippen)
leert `WriteScreen` das Feld sofort, sonst landete der abgetippte Text in der nächsten Frage. Geprüft im Bild-Werkzeug
(`--only=write`, `--only=learn`: Text ins echte Feld, Szenen 05c1/05c2, 04e/04f).

## Multiple Choice: ähnliche falsche Antworten (23.11.2026)

Joan: «mache die Multiple Choice schwerer: möglichst ähnliche Wörter (zumindest gleiche Wortart)». Gleich in JS-Referenz
(`src/core/wordclass.js`), Mac (`WordClass.swift`) und hier (`WordClass.cs`):
- Wortart einer Karte aus beiden Seiten: Artikel, «to», «se»/«sich», Geschlechtsangaben («, f.», «(in)»), französische
  weibliche Formen («amusant, amusante»), Satzzeichen, Zahlen; schwächer deutsche Gross-/Kleinschreibung und Endungen.
  Die Sprache jeder Seite kommt aus `LangDetect.DetectColumn` über die ganze Liste.
- `LearnEngine.RankedDistractors`: zuerst Karten derselben Wortart, dann die ähnlichsten (nahe im Set, gleicher Artikel,
  gleich viele Wörter, ähnliche Länge, gleicher Anfang/gleiches Ende), dazu 0–2 Zufallspunkte, damit fast gleich ähnliche
  abwechseln. Tests: Parität `WordClassParityTests` (Fixture `wordclass`) und `LearnEngineParityTests`.

## Vergleich mit der Mac-App umgesetzt (1.3, 3.11.2026)

Joan: «gehe jeden Code-Abschnitt der Mac-App durch» → sechs Helfer-Agenten haben den ganzen Mac-Code mit der Windows-App
verglichen, dann «alle 150
Punkte umsetzen»: die dringenden selbst (b350504: Verlassen-Sperre `AppModel.LeaveGuard` für Prüfung und Editor, leere
Kartenseiten, Datenrettungs-Hinweis `StartupPrompt`, Speichern scheitert beim Beenden, Sicherungen beim Löschen, Neustart
mit Rückfrage, Ring-Prozent), der Rest von fünf Agenten auf eigenen Branches (Lernen, Prüfung, Editor, Einstellungen,
Hülle), dann zusammengeführt. Was jeder umgesetzt hat und was bewusst
fehlt: eigene Berichte (nicht im Git).

Neu dabei u. a.: Kern `SetEditorCopy` (Editor-Texte, Trennungen, `UndoHistory`), `SpeechText` (Vorlese-Aufbereitung),
`BackupImportPreview`, `WriteClock`, `FlashcardScrollTail` (Touchpad-Nachlauf), `LibraryStorePersistenceTests`; App
`Features/Settings/BackupImportSheet.cs`, `SettingsWipeSheet.cs`, `Features/SetDetail/TextExportSheet.cs`,
`App/ShortcutsSheet.cs` (F1), `DesignSystem/Accessibility.cs` (Kontrast, Transparenz), `DesignSystem/ViewThatFits.cs`,
Editor als partielle Klasse (`SetEditorCardList.cs`, `ImportPanel.cs`). `PromptRequest` kann `Content`, `Width`,
`KeyHandler` (Blätter). Snapshot-Werkzeug: `--only=learn|write|flashcards|editor|exam|settings|shell`, `contrast`, `solid`.

Synonyme ausserhalb des Sets («Weitere Synonyme erkennen»): statt des Apple-Sprachmodells eingebaute einsprachige
Synonymwörterbücher (de, en, fr, es, it; 2,6 MB), siehe `src/Wortschatz.Core/SynonymData/README.md`.

Bewusst nicht: Haptik, Menüleiste (dafür F1 und Rechtsklick),
Blätter über dem Lernbildschirm (Ctrl+N verlässt ihn; Prüfung fragt vorher). Ungetestet auf echtem Windows: Pinyin-
Eingabe, Touchpad-Nachlauf, SAPI-Stimmenwahl, Kontrastdesign, bewegter Hintergrund (CPU/GPU beobachten).

## Neue Funktionen nach 1.2 (3.11.2026)

Joan: «mache neue Features jetzt». Alles, was gegenüber Mac und früherer Web-App fehlte:

- **PDF- und Foto-Import** im Editor: Ablagefläche «Datei hierher ziehen» (TXT, CSV, PDF oder Foto), «Datei wählen …»
  (mehrere), Ziehen auf den ganzen Editor, Ctrl+V eines Bildes oder kopierter Dateien im Importfeld, «Aus Zwischenablage».
  Fortschritt ab 160 ms mit Prozent und «Abbrechen» (auch Esc), Hinweise («Seite 3 konnte nicht gelesen werden»), Titel aus
  dem Dateinamen, Zusammenfassung als Toast (`SetEditorScreen`: `ImportSources`, `FinishImport`, `DropZone`, `RenderProgress`).
  Kern (`Import/`, `TextLayout`, `OCRPostprocess`) portiert von einem Helfer-Agenten.
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
  - App mit zwei Zielen: `net10.0-windows10.0.19041.0` (echte App, `#if WINDOWS`, baut `build.sh`) und `net10.0`
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
- Was die frühere App konnte und hier damals noch fehlte: **PDF-/Foto-Import** (die Web-App lud dafür Bibliotheken nach),
  Sonderzeichen-Leiste, Rechtschreibhilfe, Bildschirmleser-Ansagen – seither alles da («Neue Funktionen nach 1.2»).

## Erster Test auf echtem Windows und Nachbesserung (3.11.2026)

Kurz: Fenster, Snap,
DPI 125 %, Schriften inkl. Arabisch/Chinesisch, alle Lernmodi, Animationen, Datei-Dialoge und Vorlesen laufen auf Windows.
Joan: «du darfst gleich alles beheben … auch Performance». Behoben in diesem Commit:

- **Editor:** Liste im Importfeld ging beim Erstellen ohne Nachfrage verloren → wie Mac: leeres Set übernimmt sie,
  sonst «Liste noch nicht übernommen» (anhängen / ohne Liste); «Karten übernehmen» fragt Anhängen/Ersetzen (Ersetzen behält
  Karten-ID und Stern gleicher Begriffe) – seit 26.11.2026 ersetzt: die erkannten Paare stehen sofort in den Karten
  (wie Mac 1.8, `PORTING.md` › «Editor nur mit Kartenliste»); Esc mit Änderungen fragt «Änderungen verwerfen?»; Titel/unvollständige Karten
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

Damals noch offen (die ersten vier seither erledigt, «Neue Funktionen nach 1.2»): Bildschirmleser-Ansagen,
PDF/Foto-Import, Rechtschreibhilfe, Sonderzeichen-Leiste, Touchpad-Gesten auf echtem Gerät, arm64.

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
dotnet test tests/Wortschatz.Core.Tests          # alle Kern-Tests
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
| Import-Kern (`Import/`: ImportPipeline, PDFTextExtractor, OCRService/OCRTextAssembler, BandedTextRecognizer, OCRImage, TextFileDecoder, ImportFileType) | ✅ portiert, Logik mit Fakes getestet (Textseiten vs. Scans, 30-Seiten-Grenze, Warnungen, Fortschritt, Abbruch); PDF, Bild-Dekodierung und OCR sind Schnittstellen (`IPdfReader`, `IImageDecoder`, `ITextRecognizer`), die die App für Windows implementiert – siehe PORTING.md «Import» |
| Oberfläche (Avalonia, Glas-Design): Hülle, Übersicht, Lernset, Lernen, Schreiben, Karteikarten, Prüfung, Editor mit Listen-Import, Einstellungen (Hell/Dunkel, Backup) | ✅ gebaut, unter Linux headless geprüft (Screenshots), auf Windows getestet (seit 3.11.2026, «Erster Test auf echtem Windows») |
| Animationen (Motion/Effects; Karteikarten, Lernen, Schreiben, Prüfung, Toasts, Konfetti, Seiten-Eintritt) | ✅ wie Mac (Kurven/Federn aus `Metrics.swift`), Reduce Motion über Windows-«Animationseffekte»; nur als Einzelbilder geprüft |
| Vorlesen (Windows-Stimmen über SAPI/OneCore) | ✅ läuft auf Windows (Test 3.11.2026) |
| Töne, Bildschirmleser-Ansagen, PDF-/Foto-Import, Rechtschreibhilfe, Sonderzeichen-Leiste | ✅ (siehe «Neue Funktionen nach 1.2») |
| `build.sh` → `dist/Wortschatz.exe` (eine Datei, ohne .NET-Installation) | ✅ |

## Für den Test auf Windows (Claude mit Gerätezugriff)

1. `./build.sh` (oder fertige `dist/Wortschatz.exe` kopieren) und starten. Daten liegen in
   `%LOCALAPPDATA%\Wortschatz\library.json`. Achtung: Der erste Start übernimmt und entfernt die frühere App; zum
   Testen `WORTSCHATZ_NATIVE_DATA` und `WORTSCHATZ_LEGACY_DATA` setzen (siehe oben).
2. Lernsets der früheren App (bis 1.1) übernimmt der erste Start von selbst (siehe oben); ein Backup lädt man unter
   *Einstellungen → Backup laden* (oder auf der leeren Übersicht).
3. Prüfen: Fenster ziehen/maximieren/Snap (eigene Titelleiste, `WindowDecorations.BorderOnly` + Rollen), Schriften
   (Onest/Nunito, Fallback Segoe UI/Microsoft YaHei für Chinesisch, Arabisch rechts-nach-links), Tasten (Enter, Alt+Enter,
   Ctrl+Enter, Ziffern 1–4/0, Pfeile, Tippen auf Mehrfachauswahl, Esc), Vorlesen, Hell/Dunkel, Datei-Dialoge.
4. Bekannte offene Punkte stehen in PORTING.md («Noch nicht portiert»).
