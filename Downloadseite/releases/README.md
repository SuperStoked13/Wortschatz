# releases

Hier liegen die Dateien, die die Website zum Download anbietet, und je ein kleines Manifest:

| Datei | Inhalt |
|---|---|
| `mac.json` + `Wortschatz-<version>-macOS.dmg` | Mac-App, erstellt von `tools/release-mac.sh` |
| `windows.json` + `Wortschatz-<version>-Windows.exe` | Windows-App, erstellt von `tools/release-windows.sh` |

Die Skripte schreiben beides selbst. Der Server prüft alle 15 Sekunden, ob sich hier etwas
geändert hat, berechnet dann die SHA-256-Prüfsumme neu und zeigt die neue Version an.

Ein Manifest von Hand sieht so aus (`requirement`, `architecture`, `build` und `released`
sind freiwillig):

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

Der Server liefert nur Dateien aus, die ein Manifest nennt, die direkt in diesem Ordner liegen
(keine Unterordner, keine Verknüpfungen nach aussen) und auf `.dmg`, `.zip`, `.pkg`, `.exe`
oder `.msi` enden.
