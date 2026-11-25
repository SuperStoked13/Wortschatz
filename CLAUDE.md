# Wortschatz

Vokabeltrainer: Mac-App (`mac/`), Windows-App (`windows-native/`) und die Downloadseite (`Downloadseite/`), von der
man die Apps lädt. Überblick und Befehle: `README.md`.

> **Dieses Repository ist öffentlich.** Nie hineinschreiben: Serveradressen ausser der Downloadseite, Passwörter,
> Tokens, Schlüssel, `.env`-Inhalte, private Notizen oder Pfade auf eigenen Rechnern. Der Betrieb der Downloadseite
> (Server, Container, Caddy, Deploy-Skript, `.env`) liegt bewusst nicht hier – ein Push darf nie bestimmen, was mit
> welchen Rechten auf dem Server läuft. Darum hier auch kein Compose, Dockerfile oder Deploy.

## Veröffentlichen = GitHub-Release
- Pushes gehen **nie** live. Live geht nur ein **GitHub-Release** („Latest“, kein Entwurf/keine Vorabversion),
  Anleitung: `VEROEFFENTLICHEN.md`. Der Server prüft alle 5 Minuten, testet, baut, schaltet um, prüft und schaltet bei
  Fehlern automatisch zurück.

## Neuigkeiten-Liste – bei App-Änderungen immer mitführen
Die Seite `/neuigkeiten` zeigt `Downloadseite/public/_neuigkeiten.md`. **Ohne Nachfrage:** Wer an einer App etwas
ändert (`mac/`, `windows-native/`), das man beim Benutzen bemerkt, trägt es dort im selben Commit ein.
- **Ja:** neue Funktion, spürbare Verbesserung, behobener Fehler (Beispiel: Arabisch und Mandarin als Lernsprachen).
  **Nein:** Wortlaut, Abstände, Farben, interne Umbauten, Tests, Build-/Release-Skripte, die Downloadseite selbst.
  Nichts Vergangenes nachtragen (die Liste beginnt nach 1.0).
- **Format:** eine Zeile unter `## Nächste Version` (zuoberst; fehlt der Abschnitt, anlegen), das Neueste zuoberst:
  `- Neu: …`, `- Verbessert (Mac): …`, `- Behoben (Windows): …`. Plattform in Klammern nur, wenn nur eine App betroffen
  ist. Ein bis zwei Sätze für Benutzer, Deutsch mit ss. Ändert sich derselbe Punkt vor dem Release nochmals: den
  Eintrag anpassen, keinen zweiten schreiben.
- **Englisch:** direkt darunter, eingerückt, `  EN: …` mit demselben Punkt auf Englisch (für `/en/whats-new`;
  Bezeichnungen aus der deutschen App bleiben in «…»). Wird der deutsche Eintrag geändert, die EN-Zeile mit anpassen.
  Fehlt sie, zeigt die englische Seite den deutschen Text.
- **Keine Versionsnummern von Hand:** `Downloadseite/tools/release-*.sh` verschiebt beim Bauen die Einträge der gebauten
  Plattform (ohne Klammer oder mit ihr) aus «Nächste Version» nach `## <Version> – <Datum>` (`tools/neuigkeiten.py`).
  Bis dahin zeigt die Seite sie als «Demnächst». Die leere `## 1.0 – 2026-10-14` ist der Ausgangspunkt und bleibt leer.

## Ordner
- `Downloadseite/` – Node-Server ohne npm-Pakete (eigene `README.md`). Live geht davon nur `server/` + `public/`.
  **Zwei Sprachen:** Deutsch unter `/`, Englisch unter `/en` (Vorlagen in `public/en/`, Server-Texte in
  `server/lib/lang.mjs`) – eine Seite immer in beiden Sprachen ändern. Die Apps können seit 24./25.11.2026 auch Englisch;
  was die Seite dazu sagt, folgt den live Versionen von selbst (`server/lib/languages.mjs`). Spenden nur als Links auf Ko-fi (Kaffee im Hero, Abschnitt unten auf der Startseite): nichts
  von Ko-fi einbinden, keine Spendenstände erfinden.
- `windows-native/` – **die Windows-App seit 1.2** (C#/.NET 10/Avalonia 12, Port der Mac-App, eine einzige exe ohne
  Installation; eigene `README.md`). Übernimmt beim ersten Start alles aus der früheren Windows-App und entfernt sie.
  Kern = Funktion für Funktion `WortschatzCore` mit Paritätstests gegen die Mac-Fixtures; Oberfläche in C#-Code (eine
  SwiftUI-Datei ↔ eine C#-Datei). **Mac-Feature übernehmen: Rezept in `windows-native/PORTING.md`.**
  Bauen: `windows-native/build.sh` → `dist/Wortschatz.exe` (mit `test` zuerst die Tests). Deutsch und Englisch: neue
  Texte durch `L("…")`/`L($"…")` (`CoreText`), Englisch aus dem Mac-Katalog oder `Strings/en.json` –
  `windows-native/README.md` › «Englisch».
- `mac/` – Quellcode der Mac-App (Swift/Xcode). Bauen, testen und das DMG (`Downloadseite/tools/release-mac.sh`) nur
  auf einem Mac; `mac/scripts/test.sh`, `mac/scripts/build.sh`.
- `Website/` – die frühere Web-Version (bis 1.1 die Oberfläche der Windows-App), wird nicht mehr ausgeliefert. Sie
  bleibt als JS-Referenz: die Generatoren in `mac/Parity/` erzeugen daraus die Fixtures, gegen die Mac- und
  Windows-App getestet werden (`mac/scripts/gen-fixtures.sh` darf nichts ändern). **Keine Browser-Version.**
- **Updates:** Mac-App mit Sparkle, Windows-App nach demselben Prinzip (`AppUpdater`): täglich, aus dem neuesten
  veröffentlichten Release dieses Repos (`appcast.xml` bzw. `windows-update.json`, signiert), installiert beim Beenden.
  Ablauf und Schlüssel: `VEROEFFENTLICHEN.md` › «Updates (Mac)», «Updates (Windows)».
- Nicht im Git (`.gitignore`): Builds (`mac/build/`, `windows-native/dist/`, Downloads in `Downloadseite/releases/`),
  `xcuserdata/`, `Downloadseite/.env`, `data/`.

## Mac und Windows gleich halten
- Was die Mac-App neu kann, kommt auch in die Windows-App (und umgekehrt), mit denselben Tests.
- Ändert sich Verhalten, das die JS-Referenz in `Website/` abbildet, dort mitziehen und die Fixtures neu erzeugen.
