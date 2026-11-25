#!/usr/bin/env python3
"""Schreibt das windows-update.json einer Windows-Version: was die installierten Windows-Apps über das Update erfahren.

Gegenstück zu appcast.py (Mac). Das Manifest nennt die Version, die exe desselben Releases (nur den Dateinamen), ihre
Grösse und SHA-256, den Prozessor und was neu ist, auf Deutsch und Englisch (aus dem Abschnitt der Version in
Downloadseite/public/_neuigkeiten.md, Einträge ohne Plattform oder mit «Windows»; die erste Zeile zeigt die App nach
dem Update in der Seitenleiste). Signiert mit dem privaten Update-Schlüssel (ECDSA P-256, openssl); die App nimmt nur
Manifeste an, die mit einem Schlüssel aus windows-native/src/Wortschatz.App/Services/AppUpdater.cs (PublicKeys)
signiert sind, und nur eine exe, deren SHA-256 dazu passt.

Der Schlüssel liegt bei dem, der die Windows-App veröffentlicht (nie ins Git):
  Standard ~/.config/wortschatz-update/windows-update-key.pem, anders mit WORTSCHATZ_UPDATE_KEY=…

Aufruf:
  python3 -I Downloadseite/tools/windows_update.py schreiben --version 1.8 --exe releases/Wortschatz-1.8-Windows.exe \\
      --out releases/windows-update.json          (aus tools/release-windows.sh)
  python3 -I Downloadseite/tools/windows_update.py pruefen     prüft nur, ob der Schlüssel da ist und zur App passt
  python3 -I Downloadseite/tools/windows_update.py schluessel  legt einen neuen Schlüssel an (nur einmal; zeigt die
                                                              öffentliche Hälfte für AppUpdater.cs)
  python3 -I Downloadseite/tools/windows_update.py lesen DATEI zeigt, was ein windows-update.json sagt, und prüft es
"""

import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import neuigkeiten  # noqa: E402  (gleicher Ordner; -I lässt ihn sonst weg)

TOOLS = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(TOOLS))
APP_UPDATER = os.path.join(PROJECT, 'windows-native', 'src', 'Wortschatz.App', 'Services', 'AppUpdater.cs')
DEFAULT_KEY = os.path.join(os.path.expanduser('~'), '.config', 'wortschatz-update', 'windows-update-key.pem')
NOTHING = {
    'de': 'Kleinere Verbesserungen und Fehlerbehebungen.',
    'en': 'Minor improvements and fixes.',
}
FILE_NAME = re.compile(r'^Wortschatz-[0-9][0-9A-Za-z.+-]{0,40}-Windows\.exe$')


class Fehler(Exception):
    pass


def key_path():
    return os.environ.get('WORTSCHATZ_UPDATE_KEY') or DEFAULT_KEY


def openssl(*args, data=None):
    try:
        result = subprocess.run(['openssl', *args], input=data, capture_output=True)
    except FileNotFoundError:
        raise Fehler('openssl fehlt (Linux: Paket openssl; macOS und Git Bash unter Windows haben es).') from None
    if result.returncode != 0:
        raise Fehler(f'openssl {args[0]}: {result.stderr.decode(errors="replace").strip()}')
    return result.stdout


def public_key(path):
    """Die öffentliche Hälfte des Schlüssels in path, wie AppUpdater.cs sie nennt (base64 SubjectPublicKeyInfo)."""
    if not os.path.isfile(path):
        raise Fehler(f'Der Update-Schlüssel fehlt: {path}')
    der = openssl('pkey', '-in', path, '-pubout', '-outform', 'DER')
    return base64.b64encode(der).decode()


def app_keys():
    """Die öffentlichen Schlüssel, die die Windows-App annimmt (aus AppUpdater.cs, PublicKeys)."""
    with open(APP_UPDATER, encoding='utf-8') as handle:
        source = handle.read()
    block = re.search(r'PublicKeys\s*=\s*\[(.*?)\];', source, re.S)
    return re.findall(r'"([A-Za-z0-9+/=]{40,})"', block.group(1)) if block else []


def check_key(path):
    """Der Schlüssel muss zur App passen, sonst nimmt keine installierte App das Update an."""
    key = public_key(path)
    if key not in app_keys():
        raise Fehler(
            f'Der Update-Schlüssel {path} passt nicht zur App.\n'
            f'Seine öffentliche Hälfte: {key}\n'
            f'Die App nimmt nur: {", ".join(app_keys()) or "keinen"} (PublicKeys in {os.path.relpath(APP_UPDATER, PROJECT)}).')
    return key


def sign(data, path):
    return base64.b64encode(openssl('dgst', '-sha256', '-sign', path, data=data)).decode()


def verify(data, signature, key):
    """Prüft die Signatur wie die App (öffentlicher Schlüssel als base64, Signatur base64 DER)."""
    with tempfile.TemporaryDirectory() as tmp:
        pub = os.path.join(tmp, 'pub.der')
        sig = os.path.join(tmp, 'sig.der')
        with open(pub, 'wb') as handle:
            handle.write(base64.b64decode(key))
        with open(sig, 'wb') as handle:
            handle.write(base64.b64decode(signature))
        try:
            openssl('dgst', '-sha256', '-verify', pub, '-keyform', 'DER', '-signature', sig, data=data)
            return True
        except Fehler:
            return False


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def manifest(args, changes):
    """Der Text, der signiert wird (kompakt, eine Zeile)."""
    data = {
        'app': 'Wortschatz',
        'platform': 'windows',
        'version': args.version,
        'file': os.path.basename(args.exe) if not args.file_name else args.file_name,
        'size': os.path.getsize(args.exe),
        'sha256': sha256(args.exe),
        'architecture': args.architecture,
        'released': args.date,
        'changes': {
            'de': [de for de, _ in changes] or [NOTHING['de']],
            'en': [en for _, en in changes] or [NOTHING['en']],
        },
    }
    return json.dumps(data, ensure_ascii=False, separators=(',', ':'))


def write(args):
    if not re.fullmatch(r'\d{1,4}\.\d{1,4}(\.\d{1,4})?', args.version):
        raise Fehler(f'Version «{args.version}»: die App versteht nur Zahlen wie 1.8 oder 1.8.1.')
    name = args.file_name or os.path.basename(args.exe)
    if not FILE_NAME.match(name):
        raise Fehler(f'Dateiname «{name}»: erwartet wie Wortschatz-1.8-Windows.exe.')
    with open(args.exe, 'rb') as handle:
        if handle.read(2) != b'MZ':
            raise Fehler(f'{args.exe} ist kein Windows-Programm.')
    path = key_path()
    # Ein Update-Test (windows-native/tools/update-test.sh) signiert mit einem Wegwerf-Schlüssel, den nur seine Testkopien kennen.
    key = public_key(path) if args.test_schluessel else check_key(path)
    changes = neuigkeiten.changes_of(os.path.abspath(args.neuigkeiten), args.version, 'windows')
    text = manifest(args, changes)
    signature = sign(text.encode('utf-8'), path)
    if not verify(text.encode('utf-8'), signature, key):
        raise Fehler('Die eben geschriebene Signatur lässt sich nicht prüfen.')
    out = {'format': 1, 'manifest': text, 'signature': signature}
    tmp = args.out + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as handle:
        json.dump(out, handle, ensure_ascii=False, indent=2)
        handle.write('\n')
    os.replace(tmp, args.out)
    count = len(changes)
    print(f'{os.path.basename(args.out)}: Wortschatz {args.version} ({name}), '
          f'{count} {"Neuigkeit" if count == 1 else "Neuigkeiten"}, signiert.')


def read(args):
    with open(args.datei, encoding='utf-8') as handle:
        outer = json.load(handle)
    text = outer.get('manifest', '')
    signed_by = [k for k in app_keys() if verify(text.encode('utf-8'), outer.get('signature', ''), k)]
    print(json.dumps(json.loads(text), ensure_ascii=False, indent=2))
    print('Signatur: ' + ('gültig (Schlüssel der App)' if signed_by else 'UNGÜLTIG für die Schlüssel der App'))
    return 0 if signed_by else 1


def make_key():
    path = key_path()
    if os.path.exists(path):
        raise Fehler(f'{path} gibt es schon – nie überschreiben (sonst nimmt keine installierte App mehr ein Update an).')
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    old = os.umask(0o077)
    try:
        pem = openssl('ecparam', '-name', 'prime256v1', '-genkey', '-noout')
        tmp = path + '.tmp'
        with open(tmp, 'wb') as handle:
            handle.write(pem)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        os.umask(old)
    print(f'Neuer Update-Schlüssel: {path} (nur hier, nie ins Git; einmal sicher aufbewahren).')
    print('Öffentliche Hälfte für PublicKeys in windows-native/src/Wortschatz.App/Services/AppUpdater.cs:')
    print(public_key(path))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='befehl', required=True)
    w = sub.add_parser('schreiben', help='windows-update.json schreiben und signieren')
    w.add_argument('--version', required=True)
    w.add_argument('--exe', required=True, help='die exe, wie sie ans Release kommt')
    w.add_argument('--file-name', help='Dateiname im Release, falls anders als --exe')
    w.add_argument('--architecture', default='x64', choices=['x64', 'arm64'])
    w.add_argument('--out', required=True)
    w.add_argument('--neuigkeiten', default=neuigkeiten.DEFAULT_FILE)
    w.add_argument('--date', default=datetime.date.today().isoformat())
    w.add_argument('--test-schluessel', action='store_true', help=argparse.SUPPRESS)
    sub.add_parser('pruefen', help='nur prüfen, ob der Schlüssel da ist und zur App passt')
    sub.add_parser('schluessel', help='neuen Schlüssel anlegen')
    r = sub.add_parser('lesen', help='ein windows-update.json zeigen und prüfen')
    r.add_argument('datei')
    args = parser.parse_args()
    try:
        if args.befehl == 'schreiben':
            write(args)
        elif args.befehl == 'pruefen':
            check_key(key_path())
            print(f'Update-Schlüssel ok: {key_path()}')
        elif args.befehl == 'schluessel':
            make_key()
        elif args.befehl == 'lesen':
            return read(args)
    except Fehler as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
