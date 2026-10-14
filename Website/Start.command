#!/bin/bash
# Wortschatz starten: Doppelklick im Finder.
# Startet einen kleinen lokalen Server auf Port 4173 und öffnet den Browser.
# Der Port bleibt immer gleich, weil der Browser deine Daten pro Adresse speichert.

PORT=4173
URL="http://localhost:${PORT}/"

cd "$(dirname "$0")" || exit 1

echo ""
echo "  Wortschatz"
echo "  ----------"

port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1
  else
    nc -z 127.0.0.1 "${PORT}" >/dev/null 2>&1
  fi
}

if port_in_use; then
  echo "  Wortschatz läuft bereits – der Browser wird geöffnet."
  echo ""
  open "${URL}"
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import sys" >/dev/null 2>&1; then
  echo "  Python 3 wurde nicht gefunden."
  echo ""
  echo "  So installierst du es:"
  echo "    1. Öffne das Programm «Terminal»."
  echo "    2. Gib ein:  xcode-select --install   und folge den Anweisungen."
  echo "       (Alternativ: Python von https://www.python.org/downloads/ installieren.)"
  echo "    3. Danach Start.command erneut doppelklicken."
  echo ""
  read -r -p "  Zum Schliessen Enter drücken … " _
  exit 1
fi

echo "  Wortschatz läuft auf ${URL}"
echo "  Dieses Fenster offen lassen. Zum Beenden das Fenster schliessen."
echo ""

(sleep 1; open "${URL}") &

exec python3 serve.py
