# Eine neue Version veröffentlichen

**Kurz:** Pushen ist immer sicher – auf die Downloadseite geht nur, was als **GitHub-Release** veröffentlicht wird.
Der Server schaut alle 5 Minuten nach, testet, baut und schaltet um. Klappt etwas nicht, bleibt die bisherige Version
online.

> **Seit 26.11.2026 kommt die Downloadseite aus diesem Repo.** Der Code der Seite stammt aus dem «Latest»-Release, die
> Downloads je App aus dem neuesten veröffentlichten Release mit einer Datei dafür: Mac und Windows dürfen also
> getrennte Releases haben, ein Mac-Release lässt Windows, wie es ist. Die Seite verlinkt die Dateien auf GitHub.

## So geht's

1. **Versionsnummer erhöhen** (Windows: `<Version>` in `windows-native/src/Wortschatz.App/Wortschatz.App.csproj`,
   Mac: im Xcode-Projekt).
2. **Bauen** – die Dateien landen in `Downloadseite/releases/`:
   ```bash
   Downloadseite/tools/release-windows.sh   # → Wortschatz-<version>-Windows.exe + windows.json + windows-update.json
   Downloadseite/tools/release-mac.sh       # → Wortschatz-<version>-macOS.dmg + mac.json + appcast.xml
   ```
   Dabei wandern die Einträge dieser Plattform (ohne Klammer oder mit ihr) unter «Nächste Version» in
   `Downloadseite/public/_neuigkeiten.md` in den Abschnitt der neuen Version (das ist die Seite `/neuigkeiten`).
3. **Code committen und pushen** – auch die geänderte `_neuigkeiten.md` (die Downloads selbst kommen nicht ins Git).
4. **Release erstellen**, je App ein eigenes: GitHub → *Releases* → *Draft a new release* → neuen Tag auf `main`:
   **`v<version>-mac`** bzw. **`v<version>-windows`** (beim Mac genau der Tag, den `release-mac.sh` am Ende nennt – er
   steht im `appcast.xml`, siehe «Updates (Mac)») → Titel `Wortschatz <version> (Mac)` bzw. `(Windows)` → die Dateien
   aus `Downloadseite/releases/` anhängen (`.dmg` + `mac.json` + `appcast.xml` bzw. `.exe` + `windows.json` +
   `windows-update.json`) → *Set as the latest release* angehakt lassen → **Publish release**. Alle Dateien
   **vorher** anhängen: Danach lässt sich keine mehr anhängen oder austauschen (unveränderliche Releases, siehe
   «Gut zu wissen»).
   Oder im Terminal:
   ```bash
   gh release create v<version>-mac --title "Wortschatz <version> (Mac)" --notes "Was neu ist …" \
     Downloadseite/releases/Wortschatz-<version>-macOS.dmg Downloadseite/releases/mac.json \
     Downloadseite/releases/appcast.xml
   gh release create v<version>-windows --title "Wortschatz <version> (Windows)" --notes "Was neu ist …" \
     Downloadseite/releases/Wortschatz-<version>-Windows.exe Downloadseite/releases/windows.json \
     Downloadseite/releases/windows-update.json
   ```
   Beide Apps in einem Release geht auch: dann den Mac mit `release-mac.sh --tag=<Tag>` bauen (siehe «Updates (Mac)» und «Gut zu wissen»).
5. Nach höchstens etwa **6 Minuten** ist die neue Version online. Prüfen: Die Seite zeigt die neue
   Versionsnummer, und `/checksums.txt` nennt die neuen Dateien. Die Seite ist öffentlich (seit 26.11.2026 ohne
   Passwort).

## Updates (Mac)

Die Mac-App aktualisiert sich selbst (Sparkle): Etwa einmal am Tag fragt sie GitHub nach dem neuesten
**veröffentlichten** Release dieses Repos mit einem `appcast.xml`, lädt das DMG aus demselben Release im Hintergrund und
installiert es, wenn man Wortschatz beendet. Beim nächsten Start steht in der Seitenleiste «Aktualisiert auf …» mit der
ersten Neuigkeit. Entwürfe und Vorabversionen zählen nicht – wie bei der Seite. Ausschalten: Einstellungen › Daten ›
Updates. Die Windows-App macht es genauso (unten).

- **Was du tun musst:** `appcast.xml` aus `Downloadseite/releases/` mit dem DMG und `mac.json` ans Release hängen, und
  zwar an ein Release mit **genau dem Tag, den `release-mac.sh` am Ende nennt** (Standard `v<Version>-mac`, ein anderer
  mit `--tag=v1.8` beim Bauen): Das Appcast nennt das DMG mit voller Adresse samt Tag. Eine Adresse nur mit
  Dateinamen geht nicht, weil GitHub jede Release-Datei auf eine andere Adresse umleitet.
- **Was die App zeigt:** die Neuigkeiten der Version (`_neuigkeiten.md`, Mac-Einträge, Deutsch und Englisch); die
  erste steht in der Seitenleiste. Soll eine andere vorne stehen, sie vor dem Bauen unter «Nächste Version» nach oben
  schieben. Ohne Neuigkeiten heisst es «Kleinere Verbesserungen und Fehlerbehebungen.»
- **Der Schlüssel:** `release-mac.sh` signiert DMG und `appcast.xml` mit dem privaten Schlüssel im Schlüsselbund
  (Sparkle, Konto «wortschatz»; die öffentliche Hälfte steht in `mac/Wortschatz-Info.plist`). Nur wer ihn hat, kann ein
  Mac-Release machen, das die installierten Apps annehmen; fehlt er oder passt er nicht, bricht das Skript vor dem
  Bauen ab. Beim ersten Release fragt macOS, ob `sign_update` ihn benutzen darf → «Immer erlauben». Nie ins Git.
- **Zurückziehen:** Release löschen oder zur Vorabversion machen – die App fragt GitHub vor jeder Suche neu, wer es
  noch nicht geladen hat, bekommt es also nicht mehr. Schon geladene Updates installieren sich beim nächsten Beenden,
  aktualisierte Apps bleiben auf der neuen Version (kein Zurück); einen Fehler behebt eine neue Version.
- **Ausprobieren ohne Release:** `mac/scripts/update-test.sh` (zwei Testkopien mit eigener Bundle-ID und einem
  Wegwerf-Schlüssel, ein lokaler Server, der wie GitHub umleitet; die Testkopie erscheint dabei kurz auf dem Bildschirm).

## Updates (Windows)

Die Windows-App aktualisiert sich nach demselben Prinzip: Etwa einmal am Tag fragt sie GitHub nach dem neuesten
**veröffentlichten** Release dieses Repos mit einem `windows-update.json`, lädt die exe aus demselben Release im
Hintergrund und setzt sie an die Stelle der alten, wenn man Wortschatz schliesst (gleicher Ort und Name, Verknüpfungen
bleiben). Beim nächsten Start steht in der Seitenleiste «Aktualisiert auf …». Ausschalten: Einstellungen › Daten ›
Updates.

- **Was du tun musst:** `windows-update.json` aus `Downloadseite/releases/` mit der exe und `windows.json` ans Release
  hängen. Anders als beim Mac ist der Tag egal: Das Manifest nennt die exe nur mit Dateinamen, und die App nimmt ihre
  Adresse aus der Dateiliste desselben Releases (keine relative Adresse, die eine Umleitung von GitHub stören könnte).
- **Was die App zeigt:** die Neuigkeiten der Version (`_neuigkeiten.md`, Windows-Einträge, Deutsch und Englisch); die
  erste steht in der Seitenleiste.
- **Der Schlüssel:** `release-windows.sh` signiert `windows-update.json` mit dem privaten Update-Schlüssel (ECDSA,
  `Downloadseite/tools/windows_update.py`; Standard `~/.config/wortschatz-update/windows-update-key.pem`, anders mit
  `WORTSCHATZ_UPDATE_KEY=…`; die öffentliche Hälfte steht in `AppUpdater.PublicKeys`). Fehlt er oder passt er nicht,
  bricht das Skript vor dem Bauen ab; `--ohne-update` baut trotzdem, nur ohne Update für die installierten Apps. Nie ins
  Git.
- **Zurückziehen:** wie beim Mac – Release löschen oder zur Vorabversion machen. Eine schon geladene, noch nicht
  installierte Version verwirft die App bei der nächsten Suche.
- **Ausprobieren ohne Release:** `windows-native/tools/update-test.sh` (zwei Testkopien mit Wegwerf-Schlüssel, die
  sich aus einem Ordner daneben aktualisieren; auf einem Windows-PC nach `ANLEITUNG.txt`).

## Später: Mac-App notarisieren

Die Mac-App ist nicht notarisiert. Darum gibt sie jeder beim ersten Start unter «Systemeinstellungen ›
Datenschutz & Sicherheit › Dennoch öffnen» frei oder mit dem Terminal-Befehl, den die Downloadseite
unter «Erster Start auf dem Mac» zeigt. Notarisiert fragt macOS nur einmal «Öffnen?». Dafür einmal:

1. Dem **Apple Developer Program** beitreten: https://developer.apple.com/programs/enroll/
   (99 USD pro Jahr, mit der eigenen Apple-ID; die Freischaltung dauert meist ein bis zwei Tage).
2. **Zertifikat:** Xcode → *Einstellungen* → *Accounts* → das Team → *Manage Certificates…* → **+** →
   *Developer ID Application*.
3. **App-spezifisches Passwort** erstellen: https://account.apple.com → *Anmelden und Sicherheit* →
   *App-spezifische Passwörter*.
4. Den **Zugang für notarytool** im Schlüsselbund speichern (fragt nach dem Passwort aus Schritt 3). Die
   Team-ID (10 Zeichen) steht auf https://developer.apple.com/account unter *Membership details*:
   ```bash
   xcrun notarytool store-credentials wortschatz-notary --apple-id <Apple-ID> --team-id <Team-ID>
   ```

Danach `Downloadseite/tools/release-mac.sh --notarize`: Es signiert die App (auch Sparkle darin), lässt sie notarisieren und
prüft das Ergebnis wie Gatekeeper. Fehlt etwas davon, bricht es vor dem Bauen ab und sagt, was fehlt.
Dann auch den Abschnitt «Erster Start auf dem Mac» in `Downloadseite/public/index.html` und `public/en/index.html` kürzen.

## Gut zu wissen

- **Nur eine Plattform neu?** Nur deren Dateien anhängen – die andere bleibt, wie sie ist.
- **Neuigkeiten:** Jede spürbare Änderung an einer App kommt mit einer Zeile in `Downloadseite/public/_neuigkeiten.md`
  unter «Nächste Version» (Format steht oben in der Datei). Nicht für Kleinigkeiten.
- **Nur die Seite geändert** (Texte, Design in `Downloadseite/public/`, Server in `Downloadseite/server/`)?
  Release ohne angehängte Dateien – die Apps bleiben.
- **`windows.json`/`mac.json` vergessen?** Geht auch: Die Version kommt dann aus dem Tag (`v1.1` → `1.1`).
  Mit Manifest ist es genauer (Build-Nummer, Datum).
- **Erst ausprobieren?** Release als *Draft* speichern oder *Set as a pre-release* anhaken – das geht nicht live.
- **Zurück auf die vorherige Version:** das neueste Release löschen oder zur Vorabversion machen – nach
  höchstens etwa 6 Minuten ist die vorherige wieder online.
- **Tests:** `cd Downloadseite/server && node --test test/*.test.mjs` muss grün sein, sonst geht nichts live.
- **Dateinamen:** keine Leerzeichen; Endungen `.exe`, `.msi`, `.dmg`, `.pkg` oder `.zip`
  (ein Mac-ZIP braucht „mac“ im Namen); höchstens 500 MB. Tags wie `v1.9-mac` oder `v1.9.1-windows`.
- **Was der Server übernimmt:** `Downloadseite/server/` und `Downloadseite/public/` im Stand des «Latest»-Release. Die
  angehängten App-Dateien prüft er (Prüfsumme) und verlinkt sie auf GitHub, ausliefern tut er sie nicht. `Website/`,
  `mac/`, `windows-native/` gehen nie online.
- **Was der Server nicht übernimmt:** `.env` und alles für den Betrieb – Container, HTTPS und Limits sind auf dem
  Server fest eingestellt.
- **Nichts passiert?** Auf dem Server steht im Protokoll, warum (z. B. Test fehlgeschlagen). Ein gescheitertes
  Release wird erst wieder versucht, wenn es einen neuen Tag gibt (die Dateien lassen sich nicht mehr austauschen).
- **Unveränderliche Releases** (seit 25.11.2026): Nach dem Veröffentlichen sind die angehängten Dateien und der Tag
  gesperrt – niemand kann eine Datei still austauschen, auch nicht mit einem gestohlenen Zugang. Titel, Text und
  «Vorabversion» bleiben änderbar, Löschen geht auch; der Tag eines gelöschten Release ist aber für immer vergeben.
  Ein Fehler in einer Datei heisst also: neue Versionsnummer. Kommen beide Apps ins selbe Release,
  zuerst als *Draft* speichern, beide hängen ihre Dateien an, dann veröffentlichen.
