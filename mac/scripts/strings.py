#!/usr/bin/env python3
"""The app's String Catalogs (mac/Wortschatz/Resources/*.xcstrings): German source, English.

Xcode collects the app's own texts (`Text("…")`, `String(localized:)` …) into the catalog when it
builds. The core package's texts go through `L("…")` (WortschatzCore/CoreText.swift) and the forms
of `Labels.plural` ("%@ Karte" / "%@ Karten"); Xcode does not see them, so `sync` adds them as manual
entries. Most texts live in Localizable.xcstrings; a table of its own (`L(table: "Name", "…")` in the
core, `Text("…", tableName: "Name")` in the app) goes to Name.xcstrings, for texts that not every build
carries (the file can be left out of a target). Every command covers every catalog.

  strings.py sync [DERIVED]   add the core's texts (and, with a derived-data folder of a finished
                              build, the texts Xcode extracted there) to the catalog
  strings.py check            list texts without an English translation or with placeholders that
                              differ from the German (exit 1 if there are any)
  strings.py missing OUT.json write the untranslated texts as {"German": ""} (with the files they
                              come from, where known) for translating
  strings.py apply IN.json    write {"German": "English"} into the catalog ({"one": …, "other": …}
                              instead of "English" for a count %lld that needs a plural form)
"""

import glob
import json
import os
import re
import sys

MAC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(MAC, "Wortschatz", "Resources")
CATALOG = os.path.join(RESOURCES, "Localizable.xcstrings")
MAIN = "Localizable"
CORE = os.path.join(MAC, "Packages", "WortschatzCore", "Sources")
APP = os.path.join(MAC, "Wortschatz")

# A Swift string literal (single line, no interpolation inside L()).
LIT = r'"((?:[^"\\\n]|\\.)*)"'
L_CALL = re.compile(r'(?<![A-Za-z0-9_.])L\(\s*' + LIT + r'\s*[,)]')
L_TABLE = re.compile(r'(?<![A-Za-z0-9_.])L\(\s*table:\s*"(\w+)"\s*,\s*' + LIT + r'\s*[,)]')
PLURAL = re.compile(r'Labels\.plural\([^,()]*(?:\([^()]*\)[^,()]*)*,\s*' + LIT + r'\s*,\s*' + LIT)
PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:lld|ld|d|lf|f|@)|%%')


ESCAPE = re.compile(r'\\(u\{([0-9A-Fa-f]+)\}|.)')
SIMPLE = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def unescape(s):
    """The text of a Swift string literal's body."""
    return ESCAPE.sub(lambda m: chr(int(m.group(2), 16)) if m.group(2) else SIMPLE.get(m.group(1), m.group(1)), s)


def catalog_path(table=MAIN):
    return os.path.join(RESOURCES, table + ".xcstrings")


def existing_tables():
    """The tables that have a catalog file (Localizable first)."""
    others = sorted(os.path.basename(p)[:-len(".xcstrings")] for p in glob.glob(os.path.join(RESOURCES, "*.xcstrings")))
    return [MAIN] + [name for name in others if name != MAIN]


def load(table=MAIN):
    path = catalog_path(table)
    if not os.path.exists(path):
        return {"sourceLanguage": "de", "strings": {}, "version": "1.0"}
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save(cat, table=MAIN):
    text = json.dumps(cat, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    with open(catalog_path(table), "w", encoding="utf-8") as f:
        f.write(text + "\n")


def swift_files(root):
    for path in glob.glob(os.path.join(root, "**", "*.swift"), recursive=True):
        yield path


def core_keys():
    """German texts the core translates at run time: {table: {key: [files]}}."""
    keys = {}
    for root in (CORE, APP):
        for path in swift_files(root):
            src = open(path, encoding="utf-8").read()
            found = []
            if root == CORE:
                found += [(MAIN, m.group(1)) for m in L_CALL.finditer(src)]
                found += [(m.group(1), m.group(2)) for m in L_TABLE.finditer(src)]
            for m in PLURAL.finditer(src):
                # Labels.plural looks up "%@ Karte" / "%@ Karten".
                found += [(MAIN, "%@ " + m.group(1)), (MAIN, "%@ " + m.group(2))]
            for table, k in found:
                if "\\(" in k:
                    continue  # interpolated: not a fixed key (the check below reports L() misuse)
                keys.setdefault(table, {}).setdefault(unescape(k), []).append(os.path.relpath(path, MAC))
    return keys


def debug_only(source):
    """Whether a source file is compiled in DEBUG builds only (starts with `#if DEBUG`)."""
    try:
        with open(source, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    return line.strip() == "#if DEBUG"
    except OSError:
        pass
    return False


def extracted_keys(derived):
    """Texts Xcode extracted in a Debug build (.stringsdata files of the app target, without the
    DEBUG-only files), per table: {table: ({key: comment or None}, {key: German default value, where
    it has one})}."""
    tables = {}
    # Debug (what test.sh builds); other configurations may hold an older state.
    pattern = os.path.join(derived, "**", "Wortschatz.build", "Debug", "Wortschatz.build", "**", "*.stringsdata")
    for path in glob.glob(pattern, recursive=True):
        try:
            data = json.load(open(path, encoding="utf-8"))
        except (ValueError, UnicodeDecodeError):
            continue
        if debug_only(data.get("source", "")):
            continue
        for table, entries in data.get("tables", {}).items():
            keys, values = tables.setdefault(table, ({}, {}))
            for entry in entries:
                if not keys.get(entry["key"]):
                    keys[entry["key"]] = entry.get("comment")
                if entry.get("value"):
                    values[entry["key"]] = entry["value"]
    return tables


def english(entry):
    """The English text, or for a plural variation every form joined by " | " (None if missing)."""
    en = entry.get("localizations", {}).get("en", {})
    unit = en.get("stringUnit")
    if unit:
        return unit["value"] if unit.get("state") == "translated" else None
    forms = en.get("variations", {}).get("plural", {})
    values = [f["stringUnit"]["value"] for f in forms.values() if f.get("stringUnit", {}).get("state") == "translated"]
    return " | ".join(values) if values and len(values) == len(forms) else None


def placeholders(s):
    return sorted(PLACEHOLDER.findall(s))


def cmd_sync(args):
    all_core = core_keys()
    all_extracted = extracted_keys(args[0]) if args else {}
    tables = existing_tables()
    tables += sorted(t for t in set(all_core) | set(all_extracted) if t not in tables)
    for table in tables:
        sync_table(table, all_core.get(table, {}), all_extracted.get(table, ({}, {})) if args else None)


def sync_table(table, core, extracted_tables):
    if not os.path.exists(catalog_path(table)) and not core and not (extracted_tables and extracted_tables[0]):
        return
    cat = load(table)
    strings = cat.setdefault("strings", {})
    added = stale = 0
    for key in core:
        entry = strings.setdefault(key, {})
        if not entry:
            added += 1
        entry["extractionState"] = "manual"
    if extracted_tables is not None:
        extracted, sources = extracted_tables
        for key, comment in extracted.items():
            if key not in strings:
                strings[key] = {}
                added += 1
            entry = strings[key]
            if key not in core:
                entry.pop("extractionState", None)
            if comment:
                entry["comment"] = comment
            source = sources.get(key)
            if source and source != key:
                # `String(localized: "key", defaultValue: "German")`: the German text is the source value.
                entry.setdefault("localizations", {})["de"] = {"stringUnit": {"state": "translated", "value": source}}
        # What the code no longer has: marked like Xcode does, or dropped if it was never translated.
        for key in list(strings):
            entry = strings[key]
            if key in extracted or key in core:
                continue
            if english(entry) is None:
                del strings[key]
                stale += 1
            elif entry.get("extractionState") != "stale":
                entry["extractionState"] = "stale"
                stale += 1
    save(cat, table)
    print(f"{table}: {added} new, {stale} no longer used; catalog has {len(strings)} text(s).")


def problems():
    missing, mismatched = [], []
    for table in existing_tables():
        table_problems(load(table), missing, mismatched)
    return missing, mismatched


def table_problems(cat, missing, mismatched):
    for key, entry in cat.get("strings", {}).items():
        if entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
            continue
        en = english(entry)
        if en is None:
            missing.append(key)
        elif any(placeholders(key) != placeholders(form) and not re.search(r'%\d+\$', form)
                 for form in en.split(" | ")):
            mismatched.append((key, en))


def cmd_check(_):
    missing, mismatched = problems()
    bad_core = []
    for path in swift_files(CORE):
        src = open(path, encoding="utf-8").read()
        for key in [m.group(1) for m in L_CALL.finditer(src)] + [m.group(2) for m in L_TABLE.finditer(src)]:
            if "\\(" in key:
                bad_core.append((os.path.relpath(path, MAC), key))
    for key in missing:
        print(f"no English: {key!r}")
    for key, en in mismatched:
        print(f"placeholders differ: {key!r} → {en!r}")
    for path, key in bad_core:
        print(f"interpolation inside L() (use %@): {path}: {key!r}")
    if missing or mismatched or bad_core:
        print(f"{len(missing)} without English, {len(mismatched)} with other placeholders, {len(bad_core)} L() misuses.")
        sys.exit(1)
    print("OK: every text has an English translation.")


def cmd_missing(args):
    missing, mismatched = problems()
    out = {k: "" for k in missing}
    out.update({k: "" for k, _ in mismatched})
    with open(args[0], "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1, sort_keys=True)
    print(f"{len(out)} text(s) → {args[0]}")


def cmd_apply(args):
    cats = {table: load(table) for table in existing_tables()}
    with open(args[0], encoding="utf-8") as f:
        translations = json.load(f)
    done = 0
    for key, en in translations.items():
        if not en:
            continue
        # The catalog that has the text (Localizable when none has it yet).
        table = next((t for t, c in cats.items() if key in c.get("strings", {})), MAIN)
        entry = cats[table].setdefault("strings", {}).setdefault(key, {})
        if isinstance(en, dict):
            # {"one": "%lld typo?", "other": "%lld typos?"} – only for the app's %lld texts, not for L().
            value = {"variations": {"plural": {form: {"stringUnit": {"state": "translated", "value": text}}
                                               for form, text in en.items()}}}
        else:
            value = {"stringUnit": {"state": "translated", "value": en}}
        entry.setdefault("localizations", {})["en"] = value
        done += 1
    for table, cat in cats.items():
        save(cat, table)
    print(f"{done} translation(s) written.")


if __name__ == "__main__":
    commands = {"sync": cmd_sync, "check": cmd_check, "missing": cmd_missing, "apply": cmd_apply}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        print(__doc__)
        sys.exit(2)
    commands[sys.argv[1]](sys.argv[2:])
