#!/bin/bash
# Builds the synonym data of the Windows/Android app from scratch (see src/Wortschatz.Core/SynonymData/README.md):
# downloads the sources into a cache folder (about 4 GB, kept for the next run), extracts what is needed, applies the
# rules of build_synonyms.py and packs src/Wortschatz.Core/SynonymData/<lang>.syn.
#
#   windows-native/tools/synonym-data/build.sh [cache folder, default ~/.cache/ws-thes]
#
# Needs python3, curl and the .NET SDK. Takes about 15 minutes (most of it downloading and reading Wiktionary).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CACHE="${1:-$HOME/.cache/ws-thes}"
mkdir -p "$CACHE"/{ot,oewn,omw,wikt,out}

get() {  # url target: download once
  [ -s "$2" ] || { echo "Lade $1"; curl -sfL "$1" -o "$2.part" && mv "$2.part" "$2"; }
}
getz() { # url target: download once, gzip on the way (the per-language extracts are plain JSON lines)
  [ -s "$2" ] || { echo "Lade $1"; curl -sfL "$1" | gzip -1 > "$2.part" && mv "$2.part" "$2"; }
}

# German: OpenThesaurus (text export, CC BY-SA 4.0 or LGPL)
get https://www.openthesaurus.de/export/OpenThesaurus-Textversion.zip "$CACHE/ot/ot.zip"
python3 -I -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$CACHE/ot/ot.zip" "$CACHE/ot"
# English: Open English WordNet (CC BY 4.0)
get https://en-word.net/static/english-wordnet-2025-json.zip "$CACHE/oewn/oewn-json.zip"
python3 -I -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$CACHE/oewn/oewn-json.zip" "$CACHE/oewn"
# Italian and Spanish wordnets from the Open Multilingual Wordnet (CC BY 3.0)
get https://raw.githubusercontent.com/omwn/omw-data/main/wns/ita/wn-data-ita.tab "$CACHE/omw/wn-data-ita.tab"
get https://raw.githubusercontent.com/omwn/omw-data/main/wns/mcr/wn-data-spa.tab "$CACHE/omw/wn-data-spa.tab"
# Wiktionary through wiktextract (kaikki.org; CC BY-SA 4.0 and GFDL): each language's own edition …
for l in de fr es it; do
  get "https://kaikki.org/${l}wiktionary/raw-wiktextract-data.jsonl.gz" "$CACHE/wikt/${l}wiktionary.jsonl.gz"
done
# … and the English edition's entries of each language
for pair in de:German fr:French es:Spanish it:Italian en:English; do
  getz "https://kaikki.org/dictionary/${pair#*:}/kaikki.org-dictionary-${pair#*:}.jsonl" "$CACHE/wikt/en-${pair#*:}.jsonl.gz"
done

cd "$CACHE/wikt"
for l in de fr es it; do python3 -I "$HERE/extract_wiktionary.py" "${l}wiktionary.jsonl.gz" "$l" "native-$l.jsonl.gz" & done
for pair in de:German fr:French es:Spanish it:Italian en:English; do
  python3 -I "$HERE/extract_wiktionary.py" "en-${pair#*:}.jsonl.gz" "${pair%%:*}" "enw-${pair%%:*}.jsonl.gz" &
done
wait
cd "$CACHE"
for l in de en fr es it; do python3 -I "$HERE/build_synonyms.py" "$l" . "out/syn-$l.tsv" & done
wait
cd "$ROOT"
dotnet run --project tools/Wortschatz.SynonymData -c Release -- "$CACHE/out" src/Wortschatz.Core/SynonymData
