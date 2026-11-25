#!/usr/bin/env python3
"""Trägt beim Bauen eines Releases die Neuigkeiten unter der neuen Versionsnummer ein.

Verschiebt die Einträge unter «## Nächste Version» in Downloadseite/public/_neuigkeiten.md, die diese
Plattform betreffen (ohne Plattform oder mit ihr in Klammern), in den Abschnitt «## <Version> – <Datum>».
Gibt es den Abschnitt schon (dieselbe Version nochmals gebaut), kommen sie dort dazu. Einträge nur für
die andere Plattform bleiben unter «Nächste Version».

Aufruf (aus tools/release-mac.sh und release-windows.sh):
    python3 -I Downloadseite/tools/neuigkeiten.py 1.1 mac
    python3 -I Downloadseite/tools/neuigkeiten.py 1.1 windows --date 2026-10-20
"""

import argparse
import datetime
import os
import re
import sys
import tempfile

DEFAULT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'public', '_neuigkeiten.md')

HEADING = re.compile(r'^##\s+(.*?)\s*$')
UPCOMING = re.compile(r'^n(?:ä|ae)chste\s+version$', re.IGNORECASE)
VERSION = re.compile(r'^v?(\d+(?:\.\d+){0,3})\b')
ITEM = re.compile(r'^\s*[-*]\s+')
KIND = re.compile(r'^\s*[-*]\s+([^\W\d_]+)\s*(?:\(([^)]*)\))?\s*:', re.UNICODE)
PLATFORMS = {'mac': 'mac', 'macos': 'mac', 'windows': 'windows'}


def version_key(version):
    return [int(part) for part in version.split('.')] + [0] * (4 - len(version.split('.')))


def platforms_of(item_first_line):
    """Die Plattformen eines Eintrags; leer heisst beide (auch bei unbekanntem Format)."""
    match = KIND.match(item_first_line)
    if not match or match.group(2) is None:
        return set()
    names = [word for word in re.split(r'\s*(?:,|/|\bund\b|&)\s*', match.group(2), flags=re.IGNORECASE) if word]
    found = {PLATFORMS.get(word.lower()) for word in names}
    return set() if None in found else found


def sections(lines):
    """[(start, end, title)] der ##-Abschnitte; Kommentare zählen nicht als Überschriften."""
    result = []
    in_comment = False
    for index, line in enumerate(lines):
        if in_comment:
            in_comment = '-->' not in line
            continue
        if '<!--' in line and '-->' not in line.split('<!--', 1)[1]:
            in_comment = True
            continue
        match = HEADING.match(line)
        if match:
            if result:
                result[-1][1] = index
            result.append([index, len(lines), match.group(1)])
    return result


def items_of(lines, start, end):
    """Die Einträge eines Abschnitts als Listen von Zeilen (erste Zeile plus eingerückte Fortsetzungen)."""
    items = []
    for line in lines[start + 1:end]:
        if ITEM.match(line):
            items.append([line])
        elif items and line.strip() and line[:1].isspace():
            items[-1].append(line)
    return items


KINDS_EN = {'neu': 'New', 'verbessert': 'Improved', 'behoben': 'Fixed'}
EN_LINE = re.compile(r'^\s*EN:\s*(.*)$')


def changes_of(path, version, platform):
    """[(deutsch, englisch)] der Einträge für platform ('mac' oder 'windows') im Abschnitt «## <version> – …», ohne
    die Plattform in Klammern («Neu (Mac): …» → «Neu: …»). Für die Updates der Apps (appcast.py, windows_update.py).
    Eine Version, die keine Zahl ist (ein Tag wie «beta»), hat keine."""
    if not re.fullmatch(r'\d+(?:\.\d+){0,3}', version):
        return []
    with open(path, encoding='utf-8') as handle:
        lines = handle.read().split('\n')
    section = next(
        (s for s in sections(lines)
         if VERSION.match(s[2]) and version_key(VERSION.match(s[2]).group(1)) == version_key(version)),
        None)
    if section is None:
        return []
    changes = []
    for item in items_of(lines, section[0], section[1]):
        platforms = platforms_of(item[0])
        if platforms and platform not in platforms:
            continue
        match = KIND.match(item[0])
        kind = match.group(1) if match else ''
        text_de = item[0][match.end():].strip() if match else ITEM.sub('', item[0]).strip()
        text_en = None
        for line in item[1:]:
            en = EN_LINE.match(line)
            if en:
                text_en = en.group(1).strip()
            elif text_en is None:
                text_de += ' ' + line.strip()
            else:
                text_en += ' ' + line.strip()
        prefix_de = f'{kind}: ' if kind else ''
        prefix_en = f'{KINDS_EN.get(kind.lower(), kind)}: ' if kind else ''
        changes.append((prefix_de + text_de, prefix_en + (text_en or text_de)))
    return changes


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('version')
    parser.add_argument('platform', choices=['mac', 'windows'])
    parser.add_argument('--date', default=datetime.date.today().isoformat())
    parser.add_argument('--file', default=DEFAULT_FILE)
    args = parser.parse_args()

    if not re.fullmatch(r'\d+(?:\.\d+){0,3}', args.version):
        print(f'Neuigkeiten: Version «{args.version}» übersprungen (nur Zahlen wie 1.1).')
        return 0
    path = os.path.abspath(args.file)
    try:
        with open(path, encoding='utf-8') as handle:
            text = handle.read()
    except FileNotFoundError:
        print(f'Neuigkeiten: {path} fehlt, nichts eingetragen.')
        return 0
    lines = text.split('\n')
    found = sections(lines)

    upcoming = next((s for s in found if UPCOMING.match(s[2])), None)
    if not upcoming:
        print('Neuigkeiten: kein Abschnitt «## Nächste Version», nichts eingetragen.')
        return 0
    items = items_of(lines, upcoming[0], upcoming[1])
    moving = [item for item in items if not platforms_of(item[0]) or args.platform in platforms_of(item[0])]
    staying = [item for item in items if item not in moving]
    if not moving:
        print(f'Neuigkeiten: unter «Nächste Version» steht nichts für {args.platform}.')
        return 0

    versions = [(s, VERSION.match(s[2]).group(1)) for s in found if VERSION.match(s[2])]
    newest = max((v for _, v in versions), key=version_key, default=None)
    if newest and version_key(args.version) < version_key(newest):
        print(f'Neuigkeiten: {args.version} ist älter als {newest} in der Liste, nichts eingetragen.')
        return 0
    target = next((s for s, v in versions if version_key(v) == version_key(args.version)), None)

    moved = [line for item in moving for line in item]
    kept = ['## Nächste Version', ''] + [line for item in staying for line in item] + ([''] if staying else [])
    edits = [(upcoming[0], upcoming[1], kept)]
    if target:
        # Ans Ende des bestehenden Abschnitts, vor dessen Leerzeilen.
        end = target[1]
        while end > target[0] + 1 and not lines[end - 1].strip():
            end -= 1
        edits.append((end, end, ([''] if end == target[0] + 1 else []) + moved))
        where = f'zu «{lines[target[0]].strip()[3:]}»'
    else:
        edits.append((upcoming[1], upcoming[1], [f'## {args.version} – {args.date}', ''] + moved + ['']))
        where = f'unter «{args.version} – {args.date}»'
    # Von unten nach oben einsetzen, damit die Zeilennummern der anderen Stellen stimmen.
    for start, stop, replacement in sorted(edits, key=lambda edit: edit[0], reverse=True):
        lines[start:stop] = replacement

    result = '\n'.join(lines)
    result = re.sub(r'\n{3,}', '\n\n', result).rstrip('\n') + '\n'
    directory = os.path.dirname(path)
    with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=directory, delete=False, prefix='.neuigkeiten-') as handle:
        handle.write(result)
    os.replace(handle.name, path)
    count = len(moving)
    print(f'Neuigkeiten: {count} {"Eintrag" if count == 1 else "Einträge"} {where} eingetragen '
          f'(Downloadseite/public/_neuigkeiten.md, mit committen).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
