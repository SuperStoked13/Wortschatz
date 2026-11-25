#!/usr/bin/env python3
"""Texte der Windows-/Android-App und ihr Englisch (CoreText, TextTable).

  python3 tools/strings.py check            Texte in L(…) ohne Englisch (Datei:Zeile, Schlüssel)
  python3 tools/strings.py missing          dasselbe als JSON-Vorlage für src/Wortschatz.Core/Strings/en.json
  python3 tools/strings.py find TEXT        Schlüssel im Mac-Katalog und in en.json, die TEXT enthalten (mit Englisch)
  python3 tools/strings.py keys DATEI.cs    die Schlüssel, die eine Datei benutzt (mit Englisch oder «FEHLT»)
  python3 tools/strings.py sync             src/Wortschatz.Core/Strings/en-mac.json neu aus dem Mac-Katalog schreiben

Ein Schlüssel ist der deutsche Text mit «%@» für jeden Wert: L($"Runde {n} geschafft") → «Runde %@ geschafft».
Labels.Plural(n, "Karte", "Karten") braucht «%@ Karte» und «%@ Karten». Englisch kommt aus dem Mac-Katalog
(mac/Wortschatz/Resources/Localizable.xcstrings) und aus src/Wortschatz.Core/Strings/en.json (gewinnt). Die App liest
den Mac-Katalog nicht selbst, sondern seine Abschrift en-mac.json (`sync`): flach, Zahl-Platzhalter als «%@».
Ändert Anthony Mac-Texte: `sync` laufen lassen.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NATIVE = os.path.dirname(HERE)
REPO = os.path.dirname(NATIVE)
CATALOG = os.path.join(REPO, 'mac', 'Wortschatz', 'Resources', 'Localizable.xcstrings')
OWN = os.path.join(NATIVE, 'src', 'Wortschatz.Core', 'Strings', 'en.json')
MAC_COPY = os.path.join(NATIVE, 'src', 'Wortschatz.Core', 'Strings', 'en-mac.json')
SRC = os.path.join(NATIVE, 'src')
PRIVATE = re.compile(r'(?!)')
SKIPPED_DIRS = ('obj', 'bin')
SKIPPED_IF = None
skipped_file = lambda name: False

NUMBER = re.compile(r'%(\d+\$)?(?:lld|ld|d|lu|u|lf|f)')


def normalize(s):
    return NUMBER.sub(lambda m: '%' + (m.group(1) or '') + '@', s)


def mac_copy():
    """The Mac catalog as en-mac.json: {key: English} or {key: {"one": …, "other": …}}, sorted (PRIVATE texts left out)."""
    out = {}
    with open(CATALOG, encoding='utf-8') as f:
        for key, value in json.load(f)['strings'].items():
            en = value.get('localizations', {}).get('en')
            if not en or PRIVATE.search(key):
                continue
            if 'stringUnit' in en:
                text = normalize(en['stringUnit']['value'])
                if not PRIVATE.search(text):
                    out[normalize(key)] = text
            elif 'variations' in en:
                plural = en['variations'].get('plural', {})
                other = plural.get('other', {}).get('stringUnit', {}).get('value')
                one = plural.get('one', {}).get('stringUnit', {}).get('value')
                if other:
                    out[normalize(key)] = {'one': normalize(one), 'other': normalize(other)} if one else normalize(other)
    return dict(sorted(out.items()))


def mac_copy_text():
    return json.dumps(mac_copy(), ensure_ascii=False, indent=1) + '\n'


def load_table():
    table = {}
    with open(MAC_COPY, encoding='utf-8') as f:
        for key, value in json.load(f).items():
            table[key] = value if isinstance(value, str) else value.get('other', '')
    own = {}
    if os.path.exists(OWN):
        with open(OWN, encoding='utf-8') as f:
            for key, value in json.load(f).items():
                if key.startswith('//'):
                    continue
                own[key] = value if isinstance(value, str) else value.get('other', '')
    table.update(own)
    return table, own


ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\', "'": "'", '0': '\0'}


def read_literal(src, i):
    """Reads a C# string literal at src[i] ('"', '$"', '@"', '$@"', '@$"'). Returns (key, has_holes, end) or None."""
    interp = verbatim = False
    j = i
    while j < len(src) and src[j] in '$@':
        interp |= src[j] == '$'
        verbatim |= src[j] == '@'
        j += 1
    if j >= len(src) or src[j] != '"':
        return None
    if src.startswith('"""', j):
        return None  # raw strings: not used for UI texts
    j += 1
    out = []
    holes = 0
    while j < len(src):
        c = src[j]
        if c == '"':
            if verbatim and src.startswith('""', j):
                out.append('"')
                j += 2
                continue
            j += 1
            break
        if c == '\\' and not verbatim:
            n = src[j + 1]
            if n == 'u':
                out.append(chr(int(src[j + 2:j + 6], 16)))
                j += 6
            else:
                out.append(ESCAPES.get(n, n))
                j += 2
            continue
        if interp and c == '{':
            if src.startswith('{{', j):
                out.append('{')
                j += 2
                continue
            # a hole: skip to the matching brace (nested braces, strings, chars)
            depth = 1
            j += 1
            while j < len(src) and depth:
                d = src[j]
                if d in '{':
                    depth += 1
                elif d == '}':
                    depth -= 1
                elif d == '"' or (d in '$@' and j + 1 < len(src) and src[j + 1] in '"$@'):
                    inner = read_literal(src, j)
                    if inner:
                        j = inner[2]
                        continue
                elif d == "'":
                    k = j + 1
                    while k < len(src) and src[k] != "'":
                        k += 2 if src[k] == '\\' else 1
                    j = k + 1
                    continue
                j += 1
            out.append('\x00')
            holes += 1
            continue
        if interp and c == '}' and src.startswith('}}', j):
            out.append('}')
            j += 2
            continue
        out.append(c)
        j += 1
    text = ''.join(out)
    if holes:
        text = text.replace('%', '%%').replace('\x00', '%@')
    return text, holes > 0, j


CALL = re.compile(r'(?<![\w.])(?:CoreText\.)?L\(\s*(?=[$@]*")|Labels\.Plural\(')


def skip_sync_blocks(src):
    """Blanks out comment lines and #if SKIPPED_IF … #endif (their #else parts stay)."""
    lines = src.split('\n')
    out = []
    stack = []  # True = inside a skipped block
    for line in lines:
        s = line.strip()
        if s.startswith('#if'):
            stack.append(SKIPPED_IF is not None and SKIPPED_IF in s and '!' not in s)
        elif s.startswith('#else') or s.startswith('#elif'):
            if stack:
                stack[-1] = False if stack[-1] else stack[-1]
        elif s.startswith('#endif'):
            if stack:
                stack.pop()
        # comment lines (doc comments show calls as examples)
        out.append('' if any(stack) or s.startswith('//') else line)
    return '\n'.join(out)


def keys_in(path):
    with open(path, encoding='utf-8') as f:
        src = skip_sync_blocks(f.read())
    found = []
    for m in CALL.finditer(src):
        line = src.count('\n', 0, m.start()) + 1
        j = m.end()
        if m.group(0).startswith('Labels.Plural'):
            # Labels.Plural(n, "one", "other"): two literal keys "%@ one", "%@ other"
            depth = 0
            k = j
            while k < len(src):
                if src[k] in '([':
                    depth += 1
                elif src[k] in ')]':
                    if depth == 0:
                        break
                    depth -= 1
                elif src[k] == ',' and depth == 0:
                    break
                k += 1
            k += 1
            for _ in range(2):
                while k < len(src) and src[k] in ' \n\r\t,':
                    k += 1
                lit = read_literal(src, k)
                if not lit or lit[1]:
                    break
                found.append((line, '%@ ' + lit[0]))
                k = lit[2]
            continue
        while j < len(src) and src[j] in ' \n\r\t':
            j += 1
        lit = read_literal(src, j)
        if lit:
            after = lit[2]
            while after < len(src) and src[after] in ' \n\r\t':
                after += 1
            if after < len(src) and src[after] == '+':
                continue  # L("%@ " + word): a key built at run time (Labels.Plural)
            found.append((line, lit[0]))
    return found


def source_files():
    for project in sorted(os.listdir(SRC)):
        for d, dirs, files in os.walk(os.path.join(SRC, project)):
            dirs[:] = [x for x in dirs if x not in SKIPPED_DIRS]
            for name in files:
                if name.endswith('.cs') and not skipped_file(name):
                    yield os.path.join(d, name)


def all_keys():
    for path in sorted(source_files()):
        for line, key in keys_in(path):
            yield os.path.relpath(path, NATIVE), line, key


def main(argv):
    cmd = argv[1] if len(argv) > 1 else 'check'
    if cmd == 'sync':
        with open(MAC_COPY, 'w', encoding='utf-8') as f:
            f.write(mac_copy_text())
        print(f'{len(mac_copy())} Mac-Texte → {os.path.relpath(MAC_COPY, NATIVE)}', file=sys.stderr)
        return 0
    table, own = load_table()
    if cmd == 'check':
        missing = [(p, l, k) for p, l, k in all_keys() if k not in table]
        for p, l, k in missing:
            print(f'{p}:{l}: {k!r}')
        used = sum(1 for _ in all_keys())
        print(f'{len(missing)} ohne Englisch, {used} Texte in L(…)', file=sys.stderr)
        return 1 if missing else 0
    if cmd == 'missing':
        missing = {}
        for p, l, k in all_keys():
            if k not in table:
                missing.setdefault(k, '')
        print(json.dumps(missing, ensure_ascii=False, indent=2))
        return 0
    if cmd == 'find':
        needle = ' '.join(argv[2:]).lower()
        for k, v in table.items():
            if needle in k.lower():
                print(f'{k!r} → {v!r}' + ('  [en.json]' if k in own else ''))
        return 0
    if cmd == 'keys':
        for path in argv[2:]:
            for line, key in keys_in(path):
                print(f'{line}: {key!r} → {table.get(key, "FEHLT")!r}')
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
