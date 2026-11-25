# Wortschatz

Ein Vokabeltrainer für Mac und Windows. Lernsets tippt man ein oder importiert sie (Text, CSV, PDF, Foto), dann
lernt man mit **Lernen** (erst Multiple Choice, dann schriftlich), **Schreiben**, **Karteikarten** und **Prüfung** –
mit Lernserie, Tönen und Vorlesen. Die Oberfläche ist deutsch; Lernsprachen sind unter anderem Französisch, Englisch,
Italienisch, Spanisch, Arabisch und Mandarin.

## Was hier drin ist

- `mac/` – die Mac-App (SwiftUI, macOS 26, Apple Silicon). Die Logik steckt im Swift-Paket
  `mac/Packages/WortschatzCore`, die Oberfläche in `mac/Wortschatz/`.
- `windows-native/` – die Windows-App (C#, .NET 10, Avalonia): eine einzige exe ohne Installation, Funktion für
  Funktion ein Port der Mac-App. Wie ein Mac-Feature nach Windows kommt: `windows-native/PORTING.md`.
- `Downloadseite/` – die Website, von der man die Apps lädt (Node ohne Pakete), mit der Liste der Neuigkeiten
  (`Downloadseite/public/_neuigkeiten.md`).
- `Website/` – die ursprüngliche Web-Version. Sie wird nicht mehr ausgeliefert; aus ihr entstehen die Testfälle,
  gegen die Mac- und Windows-App geprüft werden (`mac/Parity/`).

## Bauen und testen

Mac (Xcode 26):

```bash
mac/scripts/test.sh            # Kern-Tests, App bauen, App-Tests
mac/scripts/build.sh           # Release-Build: mac/build/Wortschatz.app
mac/scripts/gen-fixtures.sh    # Testfälle aus Website/ neu erzeugen (darf nichts ändern)
```

Windows (.NET 10 SDK, läuft auch auf macOS und Linux):

```bash
windows-native/build.sh test   # Kern-Tests, dann windows-native/dist/Wortschatz.exe
```

Downloadseite (Node 20 oder neuer) und die Web-Referenz:

```bash
cd Downloadseite && node server/server.mjs                    # http://localhost:8080
cd Downloadseite/server && node --test test/*.test.mjs
Website/tests/run.sh
```

## Neue Version

Neue Versionen kommen über GitHub-Releases auf die Downloadseite: `VEROEFFENTLICHEN.md`.

## Lizenz

Keine: Der Code ist zum Anschauen da, alle Rechte bleiben bei den Autoren.
