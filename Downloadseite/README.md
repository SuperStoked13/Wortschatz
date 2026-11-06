# Downloadseite für Wortschatz

Die Website **wortschatz.duckdns.org**: zeigt Wortschatz mit einer animierten App-Vorschau und bietet
die Mac- und die Windows-App zum Download an. Design, Farben und Texte kommen aus der App selbst
(Liquid Glass, Mesh-Hintergrund, Enter als Hauptaktion).

Technisch: ein kleiner Node-Server ohne zusätzliche Pakete (nichts mit `npm install`), davor Caddy
für HTTPS mit automatischem Zertifikat.

```
Downloadseite/
  public/        Seiten (index.html, datenschutz.html, _error.html, _partials/) und assets/ (CSS, JS, Bilder)
  server/        Node-Server: server.mjs, lib/, test/
  releases/      die Downloads und ihre Manifeste (mac.json, windows.json)
  tools/         release-mac.sh, release-windows.sh
  deploy/        Caddyfile (HTTPS), wortschatz-web.service (systemd)
  compose.original.yaml   Docker: Server und Caddy zusammen (auf Joans Server nicht benutzt, siehe unten)
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

Im Terminal, im Projektordner (neben `mac/`, `windows/` und `Website/`):

```bash
Downloadseite/tools/release-mac.sh       # baut die Mac-App, erstellt Wortschatz-1.0-macOS.dmg (--notarize: notarisiert)
Downloadseite/tools/release-windows.sh   # baut Wortschatz.exe und legt sie als Wortschatz-1.0-Windows.exe ab
```

Mit `--skip-build` nehmen die Skripte die zuletzt gebaute App (`mac/build/Wortschatz.app`,
`windows/dist/Wortschatz.exe`). Die Versionsnummer kommt aus dem Xcode-Projekt bzw. aus
`windows/host/winres/winres.json`. Ältere Versionen im Ordner werden dabei entfernt.

Der Server merkt neue Dateien innert 15 Sekunden, berechnet die SHA-256-Prüfsumme und zeigt
Version, Grösse und Prüfsumme auf der Seite an. Läuft der Server auf einem anderen Gerät, den
Ordner `releases/` dorthin kopieren (z. B. `rsync -av Downloadseite/releases/ pi@raspberrypi:/opt/wortschatz-web/releases/`).

## Online stellen unter wortschatz.duckdns.org

> **Auf Joans Server läuft es anders** (seit 14.10.2026): Dort ist schon ein Caddy für mehrere Adressen, die Seite
> läuft als Container hinter ihm, und neue Versionen gehen über **GitHub-Releases** online – siehe
> `../VEROEFFENTLICHEN.md` und `../CLAUDE.md`. Die Schritte unten (eigener Caddy, `compose.original.yaml`, systemd)
> gelten nur für ein anderes, eigenes Gerät. Auf Joans Server nie `docker compose` in diesem Ordner starten.

### 1. DuckDNS

1. Auf https://www.duckdns.org anmelden und die Subdomain `wortschatz` anlegen.
2. Den Token (steht oben auf der Seite) in `.env` bei `DUCKDNS_TOKEN` eintragen. Der Server
   meldet dann alle fünf Minuten die aktuelle IP-Adresse deines Anschlusses an DuckDNS.
   Kann dein Router DuckDNS selbst aktualisieren (z. B. eine FRITZ!Box unter «DynDNS»), das Feld leer lassen.

### 2. Router

Im Router eine **Portweiterleitung** für TCP 80 und TCP 443 (und UDP 443 für HTTP/3) auf den
Computer einrichten, auf dem die Seite läuft. Gib diesem Computer im Router eine feste lokale Adresse.

Manche Anschlüsse haben keine eigene öffentliche IPv4-Adresse (CGNAT oder DS-Lite, oft bei
Kabelanschlüssen). Dann kommt aus dem Internet nichts an; beim Anbieter eine öffentliche IPv4 verlangen.

### 3a. Mit Docker (am einfachsten)

```bash
cd Downloadseite
cp .env.example .env      # ausfüllen: DUCKDNS_TOKEN, OPERATOR_NAME, CONTACT_EMAIL
docker compose up -d
docker compose logs -f    # zuschauen, wie Caddy das Zertifikat holt
```

Neue Releases einfach in `releases/` legen, ein Neustart ist nicht nötig.

### 3b. Ohne Docker (Linux, z. B. Raspberry Pi)

Node 20 oder neuer und Caddy installieren. Debian und Raspberry Pi OS liefern oft ein älteres
Node (`node --version` prüfen); dann Node 22 von https://nodejs.org nehmen (für den Raspberry Pi
die ARM64-Version). Caddy gibt es mit `sudo apt install caddy`.

```bash
sudo useradd --system --home /opt/wortschatz-web --shell /usr/sbin/nologin wortschatz
sudo mkdir -p /opt/wortschatz-web
sudo cp -R server public releases deploy .env.example /opt/wortschatz-web/
sudo cp /opt/wortschatz-web/.env.example /opt/wortschatz-web/.env   # dann ausfüllen
sudo mkdir -p /opt/wortschatz-web/data && sudo chown wortschatz: /opt/wortschatz-web/data
sudo chmod 640 /opt/wortschatz-web/.env && sudo chgrp wortschatz /opt/wortschatz-web/.env

sudo cp deploy/wortschatz-web.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now wortschatz-web

sudo cp deploy/Caddyfile /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

Der Mac eignet sich zum Ausprobieren, aber nicht als dauerhafter Server: er schläft, und die
Seite ist dann weg. Besser ist ein Raspberry Pi, ein alter Laptop mit Linux oder ein kleiner VPS.

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

## Tests

```bash
cd Downloadseite/server
node --test test/*.test.mjs
```

101 Tests: Bausteine (Adressen, Links, Limits, Templates, Neuigkeiten) und der ganze Server mit echten
Angriffsversuchen (Path Traversal, gefälschte Links, fremde Origins, Bots, Fluten, langsame Clients,
abgelaufene Links, hängende Downloads, ersetzte Dateien, falsche Passwörter, gefälschte Login-Cookies).

## Anpassen

- Texte der Startseite: `public/index.html`, Datenschutz: `public/datenschutz.html`
- Neuigkeiten (`/neuigkeiten`): die Einträge in `public/_neuigkeiten.md` (Format oben in der Datei; die Datei selbst
  wird nie ausgeliefert), die Seite in `public/neuigkeiten.html`. `tools/release-*.sh` setzt beim Bauen die
  Versionsnummer über `tools/neuigkeiten.py`.
- Design: `public/assets/css/site.css` (oben die Farben und Radien aus dem Design-System der App)
- Animierte App-Vorschau: `public/assets/js/demo.js`, Mesh-Hintergrund: `public/assets/js/backdrop.js`
- Download-Knöpfe, Enter-Taste, Meldungen: `public/assets/js/site.js`

Nach Änderungen in `public/` den Server neu starten (oder `kill -HUP` an den Prozess,
`sudo systemctl reload wortschatz-web`, `docker compose restart web`).
