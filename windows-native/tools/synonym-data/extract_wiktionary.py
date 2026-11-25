#!/usr/bin/env python3
"""Pulls what the synonym data needs out of a wiktextract dump (kaikki.org), one language only.

    extract_wiktionary.py <dump.jsonl[.gz]> <lang> <out.jsonl.gz>

For every entry of <lang> (lang_code) it keeps: the word, its part of speech, its gender (nouns) and its synonyms,
each with the sense it belongs to (sense number or gloss, empty when the dump does not say) and its labels (tags and
raw_tags, e.g. "colloquial", "familier", "Swiss"). Works for the native editions (dewiktionary, frwiktionary …) and
for the per-language extracts of the English Wiktionary alike.
"""
import gzip
import json
import sys

GENDERS = {"masculine": "m", "feminine": "f", "neuter": "n", "plural": "p"}


def labels(item):
    out = list(item.get("tags", [])) + list(item.get("raw_tags", []))
    if item.get("qualifier"):
        out.append(item["qualifier"])
    return sorted(set(str(x) for x in out))


def main(src, lang, dst):
    opener = gzip.open if src.endswith(".gz") else open
    kept = 0
    with opener(src, "rt", encoding="utf-8") as f, gzip.open(dst, "wt", encoding="utf-8") as out:
        for line in f:
            if f'"{lang}"' not in line:
                continue
            d = json.loads(line)
            if d.get("lang_code") != lang or not d.get("word"):
                continue
            tags = set(d.get("tags", []))
            for form in d.get("head_templates", []) or []:
                tags.update(form.get("tags", []) if isinstance(form, dict) else [])
            gender = "".join(sorted({GENDERS[t] for t in tags if t in GENDERS and (t != "plural" or "singular" not in tags)}))
            # A synonym outside the senses may name its sense by gloss: give it that sense's number.
            by_gloss = {}
            for i, sense in enumerate(d.get("senses", []) or []):
                for gloss in sense.get("glosses", []) or []:
                    by_gloss.setdefault(gloss.strip().rstrip("."), str(sense.get("sense_index") or f"#{i + 1}"))
            syns = []
            for s in d.get("synonyms", []) or []:
                if s.get("word"):
                    sense = str(s.get("sense_index") or by_gloss.get(str(s.get("sense") or "").strip().rstrip("."))
                                or s.get("sense") or "")
                    syns.append([s["word"], sense, labels(s)])
            sense_tags = {}
            for i, sense in enumerate(d.get("senses", []) or []):
                # The English edition numbers no senses: "#1" is the first one listed (the main meaning).
                key = str(sense.get("sense_index") or f"#{i + 1}")
                sense_tags[key] = labels(sense)
                for s in sense.get("synonyms", []) or []:
                    if s.get("word"):
                        syns.append([s["word"], key, labels(s)])
            # Entries without synonyms stay too (short): that «bête» is also an adjective decides which synonyms
            # count when a card gives no article.
            out.write(json.dumps({"w": d["word"], "pos": d.get("pos", ""), "g": gender, "syn": syns,
                                  "st": sense_tags}, ensure_ascii=False) + "\n")
            kept += 1
    print(f"{lang}: {kept} entries -> {dst}", file=sys.stderr)


if __name__ == "__main__":
    main(*sys.argv[1:4])
