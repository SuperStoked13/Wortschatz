# releases

Hier liegt je App ein kleines Manifest, das die Website liest, lokal auch die Datei selbst:

| Datei | Inhalt |
|---|---|
| `mac.json` (+ `Wortschatz-<version>-macOS.dmg`) | Mac-App, erstellt von `tools/release-mac.sh` |
| `windows.json` (+ `Wortschatz-<version>-Windows.exe`) | Windows-App, erstellt von `tools/release-windows.sh` |

**Online** (seit 26.11.2026) liegen hier nur Manifeste: Das Deploy schreibt sie aus den GitHub-Releases, mit `url`,
`size` und `sha256`, und die Seite verlinkt die Datei dort (`../README.md` › «Downloads auf GitHub»). **Lokal**
schreiben die Skripte Datei und Manifest hierher; der Server prüft alle 15 Sekunden, ob sich etwas geändert hat,
berechnet dann die SHA-256-Prüfsumme neu und zeigt die neue Version an.

Ein Manifest von Hand sieht so aus (`requirement`, `architecture`, `build` und `released`
sind freiwillig; `url`, `size` und `sha256` nur für eine Datei auf GitHub):

```json
{
  "file": "Wortschatz-1.0-macOS.dmg",
  "version": "1.0",
  "build": "1",
  "released": "2026-10-14",
  "requirement": "macOS 26 oder neuer",
  "architecture": "Apple Silicon"
}
```

Ohne `url` liefert der Server nur Dateien aus, die ein Manifest nennt, die direkt in diesem Ordner liegen
(keine Unterordner, keine Verknüpfungen nach aussen) und auf `.dmg`, `.zip`, `.pkg`, `.exe`
oder `.msi` enden.
