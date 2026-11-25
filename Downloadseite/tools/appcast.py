#!/usr/bin/env python3
"""Schreibt das appcast.xml einer Mac-Version: was Sparkle in der Mac-App über das Update erfährt.

Ein Eintrag für die gebaute Version: Versionsnummern, Mindest-macOS, die EdDSA-Signatur des DMG und
was neu ist, auf Deutsch und Englisch (xml:lang; die App zeigt die Sprache, in der sie läuft). Die
Neuigkeiten kommen aus dem Abschnitt der Version in Downloadseite/public/_neuigkeiten.md (Einträge
ohne Plattform oder mit «Mac»), «(Mac)» fällt weg; steht dort nichts, heisst es «Kleinere
Verbesserungen und Fehlerbehebungen.» Die erste Zeile zeigt die App nach dem Update in der
Seitenleiste.

Das DMG steht mit voller Adresse im Release (https://github.com/<repo>/releases/download/<tag>/<datei>),
nicht relativ: GitHub leitet jede Release-Datei auf eine andere Adresse um, und Sparkle sucht eine relative
Adresse neben dieser, wo es das DMG nicht gibt. Darum muss der Tag des Releases der sein, den
release-mac.sh nennt. Danach signiert release-mac.sh das appcast.xml selbst (sign_update; die App
verlangt signierte Appcasts).

Aufruf (aus tools/release-mac.sh):
    python3 -I Downloadseite/tools/appcast.py --version 1.8 --build 10 --min-os 26.0 \\
        --url https://github.com/<repo>/releases/download/v1.8-mac/Wortschatz-1.8-macOS.dmg \\
        --length 7340032 --signature <EdDSA> --out appcast.xml
"""

import argparse
import datetime
import email.utils
import os
import sys
from xml.sax.saxutils import escape, quoteattr

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import neuigkeiten  # noqa: E402  (gleicher Ordner; -I lässt ihn sonst weg)

NOTHING = {
    'de': 'Kleinere Verbesserungen und Fehlerbehebungen.',
    'en': 'Minor improvements and fixes.',
}


def mac_changes(path, version):
    """[(deutsch, englisch)] der Mac-Einträge im Abschnitt «## <version> – …»."""
    return neuigkeiten.changes_of(path, version, 'mac')


def cdata(text):
    return '<![CDATA[' + text.replace(']]>', ']]]]><![CDATA[>') + ']]>'


def appcast(args, changes):
    notes = {
        'de': '\n'.join('• ' + de for de, _ in changes) or NOTHING['de'],
        'en': '\n'.join('• ' + en for _, en in changes) or NOTHING['en'],
    }
    major, minor, *rest = (args.min_os.split('.') + ['0', '0'])[:3]
    minimum = '.'.join([major, minor] + rest)
    date = email.utils.format_datetime(args.date)
    descriptions = '\n'.join(
        f'      <description xml:lang="{lang}" sparkle:format="plain-text">{cdata(text)}</description>'
        for lang, text in notes.items())
    return f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Wortschatz</title>
    <item>
      <title>{escape(f'Wortschatz {args.version}')}</title>
      <pubDate>{escape(date)}</pubDate>
      <sparkle:version>{escape(args.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum)}</sparkle:minimumSystemVersion>
{descriptions}
      <enclosure url={quoteattr(args.url)} length={quoteattr(str(args.length))} type="application/octet-stream" sparkle:edSignature={quoteattr(args.signature)}/>
    </item>
  </channel>
</rss>
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--min-os', default='26.0')
    parser.add_argument('--url', required=True, help='volle Adresse des DMG im Release')
    parser.add_argument('--length', required=True, type=int)
    parser.add_argument('--signature', required=True, help='EdDSA-Signatur des DMG (sign_update)')
    parser.add_argument('--out', required=True)
    parser.add_argument('--neuigkeiten', default=neuigkeiten.DEFAULT_FILE)
    parser.add_argument('--date', type=datetime.datetime.fromisoformat,
                        default=datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0))
    args = parser.parse_args()
    if args.date.tzinfo is None:
        args.date = args.date.replace(tzinfo=datetime.timezone.utc)

    changes = mac_changes(os.path.abspath(args.neuigkeiten), args.version)
    with open(args.out, 'w', encoding='utf-8') as handle:
        handle.write(appcast(args, changes))
    count = len(changes)
    print(f'appcast.xml: Wortschatz {args.version} ({args.build}), '
          f'{count} {"Neuigkeit" if count == 1 else "Neuigkeiten"}.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
