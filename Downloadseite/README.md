# Downloadseite für Wortschatz

Die Website **wortschatz.duckdns.org**: zeigt Wortschatz mit einer animierten App-Vorschau und bietet
die Mac- und die Windows-App zum Download an. Design, Farben und Texte kommen aus der App selbst
(Liquid Glass, Mesh-Hintergrund, Enter als Hauptaktion).

Technisch: ein kleiner Node-Server ohne zusätzliche Pakete (nichts mit `npm install`), davor Caddy
für HTTPS mit automatischem Zertifikat.

```
Downloadseite/
  public/        Seiten (index.html, datenschutz.html, _error.html, _partials/), en/ (dieselben auf Englisch)
                 und assets/ (CSS, JS, Bilder)
  server/        Node-Server: server.mjs, lib/, test/
  releases/      die Downloads und ihre Manifeste (mac.json, windows.json)
  tools/         release-mac.sh, release-windows.sh, neuigkeiten.py, appcast.py, windows_update.py, handschrift.py
  .env.example   Einstellungen (nach .env kopieren)
```

## Lokal ansehen

Voraussetzung: Node 20 oder neuer (`brew install node` oder https://nodejs.org).

```bash
cd Downloadseite
SITE_ORIGIN=http://localhost:8080 node server/server.mjs
```

Dann http://localhost:8080 öffnen. Solange `releases/` leer ist, steht bei den Downloads
«Version folgt».

## Downloads bereitstellen

Im Terminal, im Projektordner (neben `mac/` und `windows-native/`):

```bash
Downloadseite/tools/release-mac.sh       # baut die Mac-App, erstellt Wortschatz-1.0-macOS.dmg (--notarize: notarisiert)
                                         # und appcast.xml (Updates der Mac-App, ../VEROEFFENTLICHEN.md)
Downloadseite/tools/release-windows.sh   # baut Wortschatz.exe und legt sie als Wortschatz-1.0-Windows.exe ab,
                                         # dazu windows-update.json (Updates der Windows-App, ../VEROEFFENTLICHEN.md)
```

Mit `--skip-build` nehmen die Skripte die zuletzt gebaute App (`mac/build/Wortschatz.app`,
`windows-native/dist/Wortschatz.exe`). Die Versionsnummer kommt aus dem Xcode-Projekt bzw. aus
`windows-native/src/Wortschatz.App/Wortschatz.App.csproj`. Ältere Versionen im Ordner werden dabei entfernt.

Der Server merkt neue Dateien innert 15 Sekunden, berechnet die SHA-256-Prüfsumme und zeigt
Version, Grösse und Prüfsumme auf der Seite an. Läuft der Server auf einem anderen Gerät, den
Ordner `releases/` dorthin kopieren (z. B. `rsync -av Downloadseite/releases/ pi@raspberrypi:/opt/wortschatz-web/releases/`).

**Downloads auf GitHub.** Statt einer Datei im Ordner kann ein Manifest auf die Datei in einem GitHub-Release zeigen:

```json
{ "file": "Wortschatz-1.5-Windows.exe", "version": "1.5", "size": 92000000, "sha256": "…",
  "url": "https://github.com/SuperStoked13/Wortschatz/releases/download/v1.5/Wortschatz-1.5-Windows.exe" }
```

Dann ist «Laden» ein gewöhnlicher Link dorthin (kein Formular, kein signierter Link), Version, Grösse und
Prüfsumme kommen aus dem Manifest, und der Server schickt selbst keine Datei. Erlaubt sind nur Release-Dateien von
`DOWNLOAD_REPO` (Standard `SuperStoked13/Wortschatz`) unter `https://github.com/<repo>/releases/download/<tag>/<file>`,
genau so geschrieben; alles andere gilt als fehlende Version. Eine Seite von vorher, die noch das Formular schickt,
und alte Download-Links bekommen «Seite neu laden» (410). Mac und Windows dürfen dabei verschieden kommen.

## Online

Im Betrieb läuft die Seite als Container hinter Caddy, der HTTPS macht und `X-Forwarded-For` selbst setzt
(`TRUST_PROXY`). Neue Versionen gehen über **GitHub-Releases** online (`../VEROEFFENTLICHEN.md`). Der Betrieb
selbst (Container, Caddy, Deploy-Skript, `.env`) liegt bewusst nicht in diesem Repo. Der Server braucht Node 20
oder neuer, `server/`, `public/`, `releases/` und die Einstellungen aus `.env.example`. Mit `DUCKDNS_TOKEN` meldet
er alle fünf Minuten die aktuelle IP-Adresse an DuckDNS (leer lassen, wenn das schon jemand anderes tut).

## Sicherheit

Was der Server tut (alle Werte lassen sich in `.env` ändern, siehe `.env.example`):

- **Passwort (optional).** Mit `SITE_PASSWORD` in `.env` leitet die Startseite auf `/login`:
  ein einziges Passwortfeld, kein Benutzername. Danach merkt sich der Browser die Anmeldung
  90 Tage in einem Cookie (`__Host-wortschatz`, HttpOnly, SameSite=Lax, mit HMAC signiert; der
  Schlüssel kommt mit scrypt aus dem Passwort, ein neues Passwort meldet also alle ab). «Abmelden»
  in der Fusszeile löscht das Cookie, für geteilte Computer. Ohne Anmeldung gibt es keine Seite,
  keine Prüfsummen, keinen Download-Link und keine Datei. Offen bleiben nur `/login`, `/datenschutz`,
  `/healthz` (Docker-Healthcheck) und die statischen Dateien, die die Login-Seite braucht (CSS,
  Skripte, Bilder). Nur falsche Passwörter zählen, pro Adresse (bei IPv6 pro /48): zehn auf einmal,
  dann einer alle 12 Sekunden, höchstens 200 am Tag. Eine ganze Klasse kann sich also gleichzeitig
  anmelden; ist die Grenze erreicht, kommt auch das richtige Passwort nicht durch, damit ein Treffer
  nicht auffällt. Skripte dürfen das Passwort weiterhin per HTTP Basic Auth schicken (Benutzername
  egal, gleiche Grenzen); der Browser fragt aber nie danach. Das Passwort reist nur dank HTTPS
  geschützt, und es sollte lang und zufällig sein: Gegen viele Adressen hilft nur das.
- **Downloads auf GitHub (empfohlen für eine öffentliche Seite).** Zeigen die Manifeste auf GitHub (siehe
  «Downloads bereitstellen»), liefert der Server keine Datei mehr aus: kein Upload für Fremde, keine Download-Plätze
  zum Belegen, und die Seite verteilt selbst keine Programme. Die Punkte zu Downloads unten gelten dann nicht.
- **Ohne Netz im Container (optional).** Mit `LISTEN_SOCKET=/pfad/web.sock` hört der Server zusätzlich auf einer
  Unix-Socket-Datei, über die der Proxy kommt (Caddy: `reverse_proxy unix//pfad/web.sock`). Dann braucht der
  Container gar kein Netz (Docker `network_mode: none`): Wer eine Lücke im Server fände, käme von dort weder an den
  Rechner noch ins Heimnetz oder ins Internet. Alles über den Socket gilt als vom Proxy (seine `X-Forwarded-For`
  zählt, nie «lokal»); `HOST:PORT` dient dann nur noch dem Gesundheitscheck im Container. Den Ordner der
  Socket-Datei teilen sich Container und Proxy; verbinden dürfen nur Besitzer und Gruppe. Lauscht am Pfad noch ein
  anderer Server, startet der neue nicht (er nimmt ihm den Socket nicht weg). **Wichtig:** Der Container darf diesen
  Ordner beschreiben, könnte die Datei also durch einen Verweis auf einen anderen Socket ersetzen, dem der Proxy
  folgt. Darum gibt es im Proxy-Container keine anderen Unix-Sockets (nie `docker.sock` oder einen Admin-Socket
  einbinden), und der Ordner dient nur dieser einen Seite.
- **Signierte Download-Links.** Ein Klick auf «Laden» schickt ein Formular an `/download/mac`.
  Der Server antwortet mit einem Link, der mit HMAC-SHA256 signiert ist, nach zwei Minuten
  abläuft, höchstens dreimal benutzt werden kann und nur für die Internetadresse gilt, die ihn
  angefordert hat. Direktes Verlinken der Dateien von anderen Seiten funktioniert nicht.
- **Nur von der eigenen Seite.** Link-Anfragen ohne passenden `Origin` bzw. `Sec-Fetch-Site`
  werden abgelehnt, ebenso solche, die ein unsichtbares Formularfeld ausfüllen (Bots).
- **Anfragen pro Adresse.** Jede Anfrage zählt, egal wonach sie fragt und wie die Antwort ausfällt:
  1000 auf einmal, dann 20 pro Sekunde. Das reicht für eine ganze Klasse hinter einer Adresse (ein
  erster Besuch sind etwa zehn Anfragen). Darüber kommt nur noch eine Zeile Text ohne Seite und fast
  ohne Header, also etwa so viel, wie die Anfrage selbst gekostet hat. Eine Flut kann den Upload so
  nicht mehr gegen sich selbst verwenden, und sie schreibt auch nichts ins Protokoll (siehe unten).
- **Keine Sperren.** Der Server sperrt niemanden, und das mit Absicht: In einer Schule teilen sich alle
  eine Adresse, also hätten ein, zwei Anfragen alle eine Stunde lang aussperren können, ein Klassenbesuch
  sogar aus Versehen. Seit Abweisungen kaum noch etwas kosten, bringt eine Sperre nichts mehr.
- **Daten pro Adresse und insgesamt.** Seiten, Dateien und Fehlerseiten zusammen: pro Adresse 16 MB auf
  einmal (ein erster Besuch kostet höchstens etwa 180 KB), dann 0,5 Mbit/s, und für alle zusammen 20 Mbit/s
  mit 20 MB Reserve (Downloads haben eigene Grenzen). Mehr
  soll der Heimanschluss dafür nicht tragen müssen. Wird es knapp, müssen zuerst die Adressen warten,
  die zuletzt viel bekommen haben, damit ein paar gierige Adressen die ersten Seiten eines Besuchers
  nicht verdrängen. Bei noch mehr Andrang antwortet die Seite allen kurz mit 503: Anschluss und
  Maschine bleiben dabei nutzbar, laufende Downloads laufen weiter.
- **Fremde Websites.** Fragt eine andere Website im Browser eines Besuchers etwas ab (Bild, Skript,
  Frame, `fetch`, erkannt an `Sec-Fetch-*`), gibt es eine Zeile Text, und die Limits der Adresse
  bleiben unberührt. Benutzen dürfte sie die Antwort wegen CORP und CSP sowieso nicht. Links von
  anderen Seiten funktionieren normal.
- **Gleichzeitige Downloads.** Höchstens 12 pro Adresse und 200 insgesamt. Wer nach 30 Sekunden im
  Schnitt langsamer als 16 KB/s lädt oder länger als drei Stunden braucht, wird getrennt. Sind drei
  Viertel der Plätze belegt, muss jeder Download mindestens seinen halben fairen Anteil an der
  Bandbreite schaffen: Einen Platz zu halten kostet dann echte Bandbreite (alle Plätze etwa 25 Mbit/s).
- **Bandbreite der Downloads.** Alle Downloads zusammen höchstens 50 Mbit/s, damit der Heimanschluss
  nutzbar bleibt. Der Wert muss unter dem echten Upload liegen (`.env.example`: etwa 70 %). Nach
  50 GB am Tag für alle oder 20 GB für eine Adresse teilen sich die betroffenen Downloads innerhalb
  dieser 50 Mbit/s eine langsame Spur von 10 Mbit/s: Sie werden langsam, hören aber nie auf, und niemand kann sie bis
  Mitternacht abschalten, indem er das Guthaben aufbraucht.
- **Protokoll.** Abweisungen mit einer Zeile Text schreiben nichts ins Protokoll, sonst höchstens 20
  Zeilen pro Sekunde, und jede Minute eine Zeile mit dem, was fehlt. So füllt eine Flut die Platte
  nicht. Lange Adressen werden gekürzt.
- **Keine fremden Dateien.** Ausgeliefert wird nur, was beim Start aus `public/` geladen wurde,
  und Downloads nur, wenn ein Manifest sie nennt. Pfade mit `..`, kodierten Schrägstrichen oder
  Nullbytes werden abgewiesen, Verknüpfungen aus `releases/` hinaus ignoriert. Eine Datei, die
  seit dem Einlesen ersetzt wurde, geht erst nach dem nächsten Einlesen hinaus, nie gemischt.
- **Strenge Header.** Content-Security-Policy ohne Inline-Skripte und mit Trusted Types, HSTS,
  `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy`, `Permissions-Policy`, COOP und CORP.
- **Langsame Verbindungen.** Header und ganze Anfrage müssen innert 10 Sekunden ankommen, höchstens
  8 Formulare pro Adresse (bei IPv6 pro /48) und 1500 insgesamt dürfen gleichzeitig unterwegs sein. Untätige Verbindungen
  werden nach einer Minute getrennt. Mehr als 2000 gleichzeitige Verbindungen nimmt der Server nicht
  an und schliesst dann zuerst die untätigen.
- **Prüfsummen.** Die SHA-256 jeder Datei steht auf der Seite, in `/checksums.txt` und im
  Header `Repr-Digest`.
- **Datenschutz.** Keine Cookies (ausser dem Login-Cookie, wenn ein Passwort gesetzt ist), kein Tracking, keine Inhalte von Dritten. Im Protokoll stehen
  IP-Adressen nur gekürzt (`203.0.113.0`), gezählt werden nur Downloads pro Tag
  (`data/downloads.json`). `OPERATOR_NAME` und `CONTACT_EMAIL` in `.env` setzen, damit die
  Datenschutzerklärung vollständig ist.
- **Caddy** davor sorgt für HTTPS, ersetzt `X-Forwarded-For` durch die echte Adresse (Besucher
  können sie also nicht fälschen) und begrenzt die Grösse von Anfragen. Der Docker-Container
  läuft ohne Root, mit schreibgeschütztem Dateisystem und ohne Linux-Capabilities. Docker gibt
  die Ports nur über IPv4 frei: das Docker-Netz hat kein IPv6, über IPv6 sähe der Server sonst
  bei allen Besuchern dieselbe Adresse.

Nicht abgedeckt: Eine Flut, die schon die Leitung füllt, kann kein Programm am Ende dieser Leitung
abwehren; dagegen hilft nur etwas davor (Tunnel, CDN, Anbieter). Caddy, Docker und der Worker haben
eigene Grenzen, die dieser Server nicht setzen kann. Die Apps sind nicht signiert bzw. nicht notarisiert (dafür braucht es
kostenpflichtige Entwicklerkonten bei Apple und ein Zertifikat für Windows; `release-mac.sh --notarize`
ist vorbereitet, siehe `VEROEFFENTLICHEN.md`). Deshalb erklärt die Seite die Warnungen beim ersten Start. Die Prüfsummen zeigen, dass ein Download vollständig
ist; sie schützen nicht davor, dass jemand den Server selbst übernimmt. Halte deshalb das
Betriebssystem, Node und Caddy aktuell.

### Öffentlich ohne Passwort (seit 26.11.2026)

Die Seite ist öffentlich, ohne `SITE_PASSWORD`. Vorher, in dieser Reihenfolge: Die Apps kommen aus den Releases dieses
Repos («Downloads auf GitHub» oben, die Seite verteilt selbst keine Programme), der Container läuft ohne Netz
(`LISTEN_SOCKET`, Docker `network_mode: none`), und Name und Kontakt stehen in der Datenschutzerklärung
(`OPERATOR_NAME`, `CONTACT_EMAIL`). Das ersetzt «Das Passwort bleibt» vom 05.11.2026 (Grund damals: Eine offene
Seite, die selbst eine unsignierte exe verteilt, würde schnell als gefährlich markiert) und den Einladungslink.
Der Passwortschutz bleibt im Code, falls er wieder gebraucht wird.

## Tests

```bash
cd Downloadseite/server
node --test test/*.test.mjs
```

151 Tests: Bausteine (Adressen, Links, Limits, Templates, Kompression, Neuigkeiten, Sprachen) und der ganze Server mit echten
Angriffsversuchen (Path Traversal, gefälschte Links, fremde Origins, Bots, Fluten, langsame Clients,
abgelaufene Links, hängende Downloads, ersetzte Dateien, falsche Passwörter, gefälschte Login-Cookies,
falsche GitHub-Links in Manifesten, Besucheradressen über den Socket).

## Anpassen

- Texte der Startseite: `public/index.html`, Datenschutz: `public/datenschutz.html`. Jede Seite gibt es auch auf
  Englisch in `public/en/` (`index.html`, `privacy.html`, `whats-new.html`, `_login.html`, `_error.html`; Navigation
  und Fusszeile in `_partials/nav-en.html`, `footer-en.html`): beide Sprachen zusammen ändern.
- Sprachen: Deutsch unter `/`, Englisch unter `/en`. `assets/js/lang.js` (im `<head>`, vor dem Stylesheet) schickt
  Besucher, die von aussen kommen, auf ihre Sprache: die mit dem DE/EN-Schalter gewählte (im localStorage gemerkt,
  geht nie an den Server), sonst Deutsch, wenn der Browser Deutsch vor Englisch nennt, und sonst Englisch. Links
  innerhalb der Seite leitet es nie um. Was der Server selbst sagt (Fehlerseiten, Login, Meldungen beim Download),
  steht in `server/lib/lang.mjs` und folgt der Seite (`/en…`, auch die vorherige) oder `Accept-Language`.
  Suchmaschinen und andere Crawler leitet `lang.js` nie um: Google liest Seiten mit einem englischen Browser und sähe
  sonst jede deutsche Seite als Umleitung auf die englische.
- Suchmaschinen und KI-Assistenten (`server/lib/seo.mjs`): strukturierte Daten (schema.org, JSON-LD) im Kopf beider
  Startseiten, `/sitemap.xml`, `/robots.txt` und `/llms.txt` – alles aus den live Releases, ein neues Release
  aktualisiert sie von selbst. Titel und Beschreibung stehen in den Seiten selbst (`<title>`, `<meta name="description">`).
  Solange `SITE_PASSWORD` gesetzt ist, nennt `robots.txt` keine Sitemap, und Sitemap und `llms.txt` brauchen die
  Anmeldung wie die Seiten. Eine neue Seite, die Suchmaschinen finden dürfen, kommt in `PAGES` (`server/lib/app.mjs`) und
  damit in die Sitemap; eine, die sie nicht finden sollen, bekommt dort `noindex: true` und in der Vorlage
  `<meta name="robots" content="noindex">` (ein Test prüft, dass beides zusammenpasst).
- Sprachen der Apps: `server/lib/languages.mjs`. Bis Mac 1.6.2 und Windows 1.4 nur Deutsch, jede neuere Version auch
  Englisch (Releases kommen von `main`). Danach richten sich der Hinweis oben, der Satz im Download-Abschnitt und die
  Zeile «Sprache» jeder Karte – ein neues Release schaltet die Seite von selbst um. Tests: `test/languages.test.mjs`.
- Updates der Apps: Ist eine Mac- bzw. Windows-Version nach 1.7.1 online, sagen die Datenschutzerklärung (die eine, die
  andere oder beide Apps) und die Hilfe der App, dass sie bei GitHub nach Updates fragt (`updatesView` in
  `server/lib/app.mjs`: `macUpdates`, `windowsUpdates`, `appUpdates`).
- Spenden: der gezeichnete Kaffee im Hero (`_partials/coffee.html`, `coffee-en.html`, die Tasse in `cup.html`) und
  der Abschnitt «Wortschatz unterstützen» unten auf der Startseite verlinken Ko-fi. Nichts davon lädt etwas von dort.
  Die Worte daneben schreiben sich Strich für Strich (`coffee-note.html`, `coffee-note-en.html`); die Dateien
  erzeugt `tools/handschrift.py`, nur wenn sich der Text ändert, nicht von Hand ändern.
- Neuigkeiten (`/neuigkeiten`, `/en/whats-new`): die Einträge in `public/_neuigkeiten.md` (Format oben in der Datei,
  mit eingerückter `EN:`-Zeile für die englische Seite; die Datei selbst wird nie ausgeliefert), die Seiten in
  `public/neuigkeiten.html` und `public/en/whats-new.html`. `tools/release-*.sh` setzt beim Bauen die
  Versionsnummer über `tools/neuigkeiten.py`.
- Design: `public/assets/css/site.css` (oben die Farben und Radien aus dem Design-System der App)
- Animierte App-Vorschau: `public/assets/js/demo.js`, Mesh-Hintergrund: `public/assets/js/backdrop.js`
- Download-Knöpfe, Enter-Taste, Meldungen: `public/assets/js/site.js`

Nach Änderungen in `public/` den Server neu starten (oder `kill -HUP` an den Prozess).
