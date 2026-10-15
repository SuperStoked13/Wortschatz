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
  Schlüssel kommt aus dem Passwort, ein neues Passwort meldet also alle ab). Ohne Anmeldung gibt
  es keine Seite, keine Prüfsummen, keinen Download-Link und keine Datei. Offen bleiben nur
  `/login`, `/datenschutz`, `/healthz` (Docker-Healthcheck) und die statischen Dateien, die die
  Login-Seite braucht (CSS, Skripte, Bilder). Jeder Anmeldeversuch zählt pro Adresse: zehn auf
  einmal, dann einer alle 12 Sekunden, auch mit dem richtigen Passwort. Skripte dürfen das
  Passwort weiterhin per HTTP Basic Auth schicken (Benutzername egal, nur falsche zählen); der
  Browser fragt aber nie danach. Das Passwort reist nur dank HTTPS geschützt.
- **Signierte Download-Links.** Ein Klick auf «Laden» schickt ein Formular an `/download/mac`.
  Der Server antwortet mit einem Link, der mit HMAC-SHA256 signiert ist, nach zwei Minuten
  abläuft, höchstens dreimal benutzt werden kann und nur für die Internetadresse gilt, die ihn
  angefordert hat. Direktes Verlinken der Dateien von anderen Seiten funktioniert nicht.
- **Nur von der eigenen Seite.** Link-Anfragen ohne passenden `Origin` bzw. `Sec-Fetch-Site`
  werden abgelehnt, ebenso solche, die ein unsichtbares Formularfeld ausfüllen (Bots).
- **Download-Rate.** Pro Internetadresse 30 Downloads pro Stunde und 100 pro Tag (grosszügig,
  weil eine ganze Schule oft eine Adresse teilt). Jeder vollständige Download zählt, auch ein
  zweiter über denselben Link; das Fortsetzen eines abgebrochenen Downloads zählt nicht.
  IPv6-Adressen zählen pro /56-Netz, weil ein einzelner Anschluss Millionen davon hat.
- **Gleichzeitige Downloads.** Höchstens 6 pro Adresse und 40 insgesamt. Wer nach 30 Sekunden
  langsamer als 16 KB/s lädt oder länger als drei Stunden braucht, wird getrennt. So kann
  niemand mit absichtlich langsamen Verbindungen alle Plätze belegen.
- **Bandbreite.** Alle Downloads zusammen höchstens 50 Mbit/s und 50 GB pro Tag, pro Adresse
  höchstens 3 GB pro Tag, damit der Heimanschluss nutzbar bleibt.
- **Anfragen-Limit und Sperren.** Seitenaufrufe und Dateien pro Adresse sind begrenzt. Wer
  auffällt (Schwachstellen-Scanner auf `/wp-login.php` oder `/.env`, gefälschte Links, Fluten),
  sammelt Strafpunkte und wird für eine Stunde gesperrt. Nie gesperrt werden Anfragen, die eine
  fremde Website im Browser eines Besuchers auslöst (etwa ein Bild mit der Adresse `/.env`), und
  private Adressen (ein falsch eingerichteter Proxy würde sonst alle aussperren).
- **Keine fremden Dateien.** Ausgeliefert wird nur, was beim Start aus `public/` geladen wurde,
  und Downloads nur, wenn ein Manifest sie nennt. Pfade mit `..`, kodierten Schrägstrichen oder
  Nullbytes werden abgewiesen, Verknüpfungen aus `releases/` hinaus ignoriert. Eine Datei, die
  seit dem Einlesen ersetzt wurde, geht erst nach dem nächsten Einlesen hinaus, nie gemischt.
- **Strenge Header.** Content-Security-Policy ohne Inline-Skripte und mit Trusted Types, HSTS,
  `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy`, `Permissions-Policy`, COOP und CORP.
- **Langsame Verbindungen.** Header müssen innert 15 Sekunden ankommen, die ganze Anfrage
  innert 30; untätige Verbindungen werden nach einer Minute getrennt, mehr als 2000
  gleichzeitige Verbindungen nimmt der Server nicht an.
- **Prüfsummen.** Die SHA-256 jeder Datei steht auf der Seite, in `/checksums.txt` und im
  Header `Repr-Digest`.
- **Datenschutz.** Keine Cookies, kein Tracking, keine Inhalte von Dritten. Im Protokoll stehen
  IP-Adressen nur gekürzt (`203.0.113.0`), gezählt werden nur Downloads pro Tag
  (`data/downloads.json`). `OPERATOR_NAME` und `CONTACT_EMAIL` in `.env` setzen, damit die
  Datenschutzerklärung vollständig ist.
- **Caddy** davor sorgt für HTTPS, ersetzt `X-Forwarded-For` durch die echte Adresse (Besucher
  können sie also nicht fälschen) und begrenzt die Grösse von Anfragen. Der Docker-Container
  läuft ohne Root, mit schreibgeschütztem Dateisystem und ohne Linux-Capabilities. Docker gibt
  die Ports nur über IPv4 frei: das Docker-Netz hat kein IPv6, über IPv6 sähe der Server sonst
  bei allen Besuchern dieselbe Adresse.

Nicht abgedeckt: Die Apps sind nicht signiert bzw. nicht notarisiert (dafür braucht es
kostenpflichtige Entwicklerkonten bei Apple und ein Zertifikat für Windows; `release-mac.sh --notarize`
ist vorbereitet, siehe `VEROEFFENTLICHEN.md`). Deshalb erklärt die Seite die Warnungen beim ersten Start. Die Prüfsummen zeigen, dass ein Download vollständig
ist; sie schützen nicht davor, dass jemand den Server selbst übernimmt. Halte deshalb das
Betriebssystem, Node und Caddy aktuell.

## Tests

```bash
cd Downloadseite/server
node --test test/*.test.mjs
```

73 Tests: Bausteine (Adressen, Links, Limits, Templates, Neuigkeiten) und der ganze Server mit echten
Angriffsversuchen (Path Traversal, gefälschte Links, fremde Origins, Bots, Fluten, abgelaufene
Links, hängende Downloads, ersetzte Dateien, falsche Passwörter, gefälschte Login-Cookies).

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
