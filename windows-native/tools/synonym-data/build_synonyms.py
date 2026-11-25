#!/usr/bin/env python3
"""Builds the synonym lists of one language from free, monolingual sources (src/Wortschatz.Core/SynonymData/README.md).

    build_synonyms.py <lang> <sources-dir> <out.tsv>        (build.sh runs it for every language)

Output: one line per word and word class, "word#c/classes<TAB>synonym|genders<TAB>…": c is n (noun), v (verb,
English only) or x (anything else), classes are all the word's classes, a noun synonym's gender letters follow "|"
(m, f, n, p). The lists are directed – the synonyms *of this word* –, so nothing is linked over a third word. The C#
tool (tools/Wortschatz.SynonymData) adds the app's lookup keys and packs them.

The rules (precision first: a wrong «richtig» teaches something wrong, a missed synonym only costs a click):

1. Two evidences per pair: the word's own Wiktionary entry lists the synonym; the synonym's entry lists the word;
   the English Wiktionary (either direction); both in one set of OpenThesaurus, MultiWordNet or MCR; English: both
   in the synset of their most common WordNet sense. A small unambiguous OpenThesaurus set (at most 4 words, each in
   no other set) counts twice.
2. Ambiguous words keep only the synonyms of their most common meaning (ambiguous_synonyms): when a word's synonyms
   fall into different meanings («Wirtschaft»: Gasthaus | Ökonomie), only those listed under the first sense of the
   English Wiktionary or WordNet stay (their order is by frequency; the German Wiktionary's sense 1 of «Wirtschaft»
   is the inn). English words with several senses always keep only those of the first.
3. Labels: one label outside the language's ALLOWED set (colloquial, figurative, outdated, vulgar, regional,
   humorous …) drops the word; so does a German word that OpenThesaurus only knows with such a label.
4. Word classes stay apart (German: a capital marks a noun, «absichtlich» never gets «Absicht»); names (a capital
   where the word has none) are dropped.
"""
import collections
import gzip
import json
import os
import re
import sys

# MARK: Labels

# Labels that do not make a synonym doubtful: technical fields, formal or official language, a word's origin, the
# standard varieties (Swiss and Austrian German, Spain's Spanish), sense numbers. Everything else drops the word.
ALLOWED = {
    "de": {
        # OpenThesaurus
        "fachspr.", "geh.", "Hauptform", "lat.", "engl.", "griechisch", "schweiz.", "franz.", "österr.",
        "bildungssprachlich", "amtlich", "juristisch", "medizinisch", "botanisch", "militärisch", "bundesdeutsch",
        "Anglizismus", "ital.", "weibl.", "männl.", "Plural", "chemisch", "kaufmännisch", "offiziell", "spanisch",
        "zoologisch", "technisch", "religiös", "biologisch", "Verwaltungssprache", "wissenschaftlich", "psychologisch",
        "politisch", "förmlich", "formell", "linguistisch", "ökonomisch", "anatomisch", "mathematisch", "physikalisch",
        "Pluraletantum", "feminin", "maskulin", "Singular", "gegendert", "gendergerecht", "eingedeutscht", "japanisch",
        "arabisch", "niederländisch", "portugiesisch", "chinesisch", "persisch", "russisch", "türkisch", "hebräisch",
        "rumänisch", "amerikanisch", "neulateinisch", "latinisiert", "Deutschland", "Technik", "Musik", "Sport",
        "Medizin", "Philosophie", "Sprachwissenschaft", "Handel", "Landwirtschaft", "Bergbau", "IT-Technik",
        "Trivialname",
        # German Wiktionary (labels as the extract writes them)
        "Swiss Standard German", "Austrian German", "Österreich, Schweiz", "Schweiz", "Österreich", "formal",
        "Germany", "fachsprachlich", "in Österreich", "in der Schweiz",
    },
    "en": set(),
    "fr": {
        "Suisse", "France", "Europe", "Anglicism", "Plus courant", "Moins courant", "Beaucoup plus courant", "common",
        "formal", "orthographe rectifiée de 1990", "orthographe traditionnelle", "nom officiel", "sens 1", "sens 2",
        "sens 3", "1, 2", "1", "2", "3", "Swiss", "Switzerland", "European French",
    },
    "es": {"España", "más usado", "América", "Spain", "formal"},
    "it": {
        "diritto", "sport", "medicina", "militare", "economia", "musica", "matematica", "fisica", "botanica",
        "chimica", "filosofia", "religione", "anatomia", "biologia", "linguistica", "marina", "informatica",
        "di persona", "di individuo", "di persone", "di individui", "di oggetto", "di oggetti", "di luogo",
        "di tempo", "di colore", "di cosa", "di animali", "sostantivo", "aggettivo", "voce verbale", "formal",
    },
}

# OpenThesaurus labels without a dot or a typical ending that is_ot_label would not recognise.
OT_LABELS = {"derb", "variabel", "veraltet", "salopp", "selten", "sehr selten", "seltener", "regional", "negativ",
             "positiv", "emotional", "auch figurativ", "scherzhaft-ironisch", "ausgestorben", "aggressiv", "kölsch",
             "Zitat", "Spruch", "Redensart", "Sprichwort", "Gemeinplatz", "Schlagwort", "Modewort", "Neologismus"}


# Labels of a whole sense that make its synonyms doubtful (Wiktionary puts «vulgar», «slang» … on the sense, not on
# each synonym: «screw» → «eff», «prostituta» → «zorra»). Grammar (countable, transitive …), fields, countries,
# formal and everyday speech are fine (the English Wiktionary calls «vélo» informal, the German one «untersagen»
# gehoben); a synonym that is itself labelled colloquial still goes (labels_ok). Lower case.
SENSE_DENY = {
    "slang", "obsolete", "figuratively", "figurative", "archaic", "historical", "rare", "dated", "derogatory",
    "broadly", "vulgar", "humorous", "uncommon", "euphemistic", "dialectal", "offensive", "nonstandard", "poetic",
    "proscribed", "slur", "ethnic", "neologism", "outdated", "regional", "jargon", "impolite", "pejorative", "ironic",
    "hyperbole", "jocular", "childish", "internet", "lunfardismo", "lunfardo", "scherzoso", "popolare",
    "dispregiativo", "eufemismo", "arcaico", "disusato", "dialettale", "romanesco", "toscano", "figurato", "ironico",
    "poetico", "non comune", "par plaisanterie", "extrêmement rare", "très rare", "jägersprache", "seemannssprache",
    "rural", "utci",
}


def sense_ok(tags):
    return not any(t.lower() in SENSE_DENY for t in tags or [])


def labels_ok(lang, labels):
    allowed = ALLOWED[lang]
    for label in labels:
        if label in allowed:
            continue
        parts = [p.strip() for p in re.split(r"[,;]", label) if p.strip()]
        if not parts or not all(p in allowed for p in parts):
            return False
    return True


# MARK: Words

def clean(word):
    """The word as it is stored, or None when it cannot be an answer (placeholders, abbreviations, long phrases)."""
    w = re.sub(r"\s+", " ", word.replace(" ", " ")).strip()
    if not w or len(w) > 40 or len(w.split(" ")) > 4:
        return None
    if re.search(r"[0-9;,/=\"«»„“”?!:]|\.\.\.|…", w):
        return None
    if w.startswith(("-", "(", "'")) and not re.match(r"^\([^()]+\) \S", w):
        return None
    if w.endswith("-"):
        return None
    letters = re.sub(r"[^\w]", "", w)
    if len(letters) < 2:
        return None
    if letters.isupper() and len(letters) <= 5:  # acronyms: BLZ, UNO
        return None
    if w.count("(") != w.count(")"):
        return None
    return w


CASE_SENSITIVE = False  # German: «Lokal» (Gaststätte) is not «lokal» (örtlich); set in main


def key(word):
    """Comparison key for joining the sources (the app has its own, exact one): no notes, ss for ß, lower case
    (except in German, where the capital marks a noun)."""
    w = re.sub(r"\s*\([^()]*\)\s*", " ", word).strip().replace("ß", "ss")
    if not CASE_SENSITIVE:
        w = w.lower()
    return re.sub(r"\s+", " ", w)


def same_kind(a, b):
    """German single words: both nouns (capital) or both not – «absichtlich» never gets «Absicht»."""
    if not CASE_SENSITIVE or " " in a or " " in b:
        return True
    return a[:1].isupper() == b[:1].isupper()


# MARK: Sources

# Every label OpenThesaurus gives a word, by key: True for a neutral use. A word it only knows as colloquial,
# figurative … stays out even where Wiktionary lists it without a label («Esel» for «Fahrrad», «Mumm»).
OT_LABELLED = collections.defaultdict(list)


def openthesaurus(src):
    """OpenThesaurus text export: one synonym set per line, ";"-separated, labels in a trailing " (…)"."""
    with open(os.path.join(src, "ot", "openthesaurus.txt"), encoding="utf-8") as f:
        lines = [l.rstrip("\n") for l in f if not l.startswith("#")]
    label_words = collections.Counter()
    for line in lines:
        for term in line.split(";"):
            m = re.search(r" \(([^()]*)\)$", term)
            if m:
                label_words.update(x.strip() for x in m.group(1).split(","))

    def is_label(tok):
        return (tok in ALLOWED["de"] or tok in OT_LABELS or tok.endswith(".") or re.search(r"deutsch$", tok) is not None
                or (tok[:1].isupper() and label_words[tok] >= 3)
                or (re.search(r"(isch|lich|end|haft|ig)$", tok) is not None and label_words[tok] >= 2))

    sets = []
    for line in lines:
        words = []
        for term in line.split(";"):
            labels = []
            m = re.search(r" \(([^()]*)\)$", term)
            # A trailing "(…)" is a label group when it is made of labels (else it belongs to the term:
            # "(sich) hinwegsetzen (über)", "einzigartig (sein)").
            if m and all(is_label(x.strip()) for x in m.group(1).split(",")):
                labels = [x.strip() for x in m.group(1).split(",")]
                term = term[: m.start()]
            # A dropped word still counts for ambiguity (rule 2): it is kept with a flag.
            words.append((clean(term), labels_ok("de", labels)))
            if words[-1][0]:
                OT_LABELLED[key(words[-1][0])].append(labels_ok("de", labels))
        sets.append(words)
    return sets


def omw(path):
    """Synonym sets of an Open Multilingual Wordnet .tab file (MultiWordNet, MCR)."""
    sets = collections.defaultdict(list)
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                continue
            p = line.rstrip("\n").split("\t")
            if len(p) >= 3 and p[1].endswith(":lemma"):
                w = clean(p[2].replace("_", " "))
                sets[p[0]].append((w if w and not w.isupper() else None, True))
    # The synset id ends in its word class: 00001740-a, 02086723-n, 02005890-v.
    return [(v, "n" if sid.endswith("-n") else "v" if sid.endswith("-v") else "x") for sid, v in sets.items()]


class Wiktionary:
    """One Wiktionary extract (extract_wiktionary.py): who lists whom, in which sense, how many senses a word has."""

    def __init__(self, path, lang):
        self.lists = collections.defaultdict(dict)   # key(head) -> key(syn) -> (surface, sense key, word class)
        self.senses = collections.Counter()           # key(head) -> number of senses
        self.classes = collections.defaultdict(set)   # key(head) -> word classes of its entries
        self.plain = set()                            # keys with at least one sense without doubtful labels
        self.known = set()                            # keys with at least one sense
        self.surface = {}
        self.gender = {}
        seen = set()
        if not os.path.exists(path):
            return
        with gzip.open(path, "rt", encoding="utf-8") as f:
            for line in f:
                d = json.loads(line)
                head = clean(d["w"])
                if not head:
                    continue
                h = key(head)
                cls = word_class(d["pos"])
                if cls is None:
                    continue
                self.classes[h].add(cls)
                self.surface.setdefault(h, head)
                for tags in (d.get("st") or {}).values():
                    self.known.add(h)
                    if sense_ok(tags):
                        self.plain.add(h)
                if d["g"] and cls == "n" and d["w"] not in self.gender:
                    self.gender[d["w"]] = d["g"]
                if not d["syn"]:
                    continue
                self.senses[h] += max(1, len(d.get("st") or {}))
                # Only the word's first entry has its main meaning: «coche» (car) has a second entry «coche» (pig).
                first = h not in seen
                seen.add(h)
                sense_tags = d.get("st") or {}
                for word, sense, labels in d["syn"]:
                    w = clean(word)
                    if not w or key(w) == h or not labels_ok(lang, labels) or not sense_ok(sense_tags.get(sense)):
                        continue
                    if not first and numbered(sense):
                        sense = "later-" + sense
                    previous = self.lists[h].get(key(w))
                    # Keep the best sense: the main one if the word is listed there.
                    if previous is None or (primary(sense) and not primary(previous[1])):
                        self.lists[h][key(w)] = (w, sense, cls)


def word_class(pos):
    """n (noun), v (verb) or x (anything else that can be an answer); None for names, affixes, symbols."""
    pos = (pos or "").lower()
    if pos in ("noun", "substantiv"):
        return "n"
    if pos == "verb":
        return "v"
    if pos in ("name", "proper noun", "prefix", "suffix", "infix", "affix", "symbol", "character", "letter",
               "abbrev", "abbreviation", "punct", "romanization", "unknown", ""):
        return None
    return "x"


def primary(sense):
    """Whether a sense key is the word's first sense ("1", "1a", "1.1")."""
    return re.match(r"^#?1([a-z]|\.[0-9]+)?$", sense or "") is not None


def numbered(sense):
    return re.match(r"^(later-)?#?[0-9]+", sense or "") is not None


# MARK: Combining

def build(lang, src):
    """{(head, word class): [synonyms]}, the classes each head has, genders and a count of the decisions."""
    wikt = os.path.join(src, "wikt")
    surface = {}
    gender = {}
    evidence = collections.defaultdict(set)    # (key E, key W) -> evidences
    votes = collections.defaultdict(collections.Counter)  # (key E, key W) -> word classes the evidences give
    classes = collections.defaultdict(set)     # key -> word classes of the word's entries

    def note(e, w, what, cls=None):
        if e != w:
            evidence[(e, w)].add(what)
            if cls:
                votes[(e, w)][cls] += 1

    if lang == "en":
        # English: the English Wiktionary is the word's own edition; WordNet is the second source.
        native = Wiktionary(os.path.join(wikt, "enw-en.jsonl.gz"), lang)
        english = Wiktionary("", lang)
    else:
        native = Wiktionary(os.path.join(wikt, f"native-{lang}.jsonl.gz"), lang)
        english = Wiktionary(os.path.join(wikt, f"enw-{lang}.jsonl.gz"), lang)
    for source in (native, english):
        for k, v in source.surface.items():
            surface.setdefault(k, v)
        for k, v in source.gender.items():
            gender.setdefault(k, v)
        for h, c in source.classes.items():
            classes[h] |= c
    # Rule 2: a word is ambiguous when the data knows synonyms for more than one of its meanings – then a wrong
    # answer could be a synonym of the meaning the card does not ask for. Meanings are told apart by their synonyms:
    # sense groups (a Wiktionary sense, a thesaurus set) that share a synonym are one meaning («beginnen» 1 and 2
    # both have «anfangen»); groups without a common word are different meanings («Wirtschaft»: Gasthaus, Lokal |
    # Ökonomie). Which meaning is the common one only the English Wiktionary's sense order tells (most common first;
    # sense 1 of «Wirtschaft» in the German Wiktionary is the inn), so an ambiguous word only gets synonyms listed
    # under its first sense there.
    sense_groups = collections.defaultdict(list)    # key -> (source, set of synonym keys), per sense or thesaurus set
    unknown = set()                                 # keys with synonyms of no known sense and several meanings
    for source, tag in ((native, "native"), (english, "english")):
        by_sense = collections.defaultdict(set)
        for h, syns in source.lists.items():
            for w, (_, sense, _) in syns.items():
                if numbered(sense):
                    by_sense[(h, sense)].add(w)
                elif source.senses[h] >= 2:
                    unknown.add(h)
                else:
                    by_sense[(h, "")].add(w)
        for (h, _), ws in by_sense.items():
            sense_groups[h].append((tag, ws))
    for h, syns in native.lists.items():
        for w, (word, sense, cls) in syns.items():
            surface.setdefault(w, word)
            note(h, w, "own", cls)
            note(w, h, "listed-by", cls)
            if lang == "en" and (primary(sense) or native.senses[h] <= 1):
                note(h, w, "english-main")
    for h, syns in english.lists.items():
        for w, (word, sense, cls) in syns.items():
            surface.setdefault(w, word)
            note(h, w, "english", cls)
            note(w, h, "english", cls)
            if primary(sense) or english.senses[h] <= 1:
                note(h, w, "english-main")

    if lang == "en":
        pairs, synsets, wn_classes = oewn(src)
        for e, w, cls in pairs:
            surface.setdefault(key(e), e)
            surface.setdefault(key(w), w)
            note(key(e), key(w), "wordnet", cls)
            note(key(e), key(w), "english-main")   # WordNet's first sense is the most common one
        for e, groups in synsets.items():
            for g in groups:
                sense_groups[key(e)].append(("wordnet", {key(x) for x in g}))
        for e, c in wn_classes.items():
            classes[key(e)] |= c
        wordnet_senses = {key(e): len(groups) for e, groups in synsets.items()}

    if lang != "en":
        wordnet_senses = {}
    sets = []
    if lang == "de":
        sets = [(s, None) for s in openthesaurus(src)]
    elif lang in ("it", "es"):
        sets = omw(os.path.join(src, "omw", {"it": "wn-data-ita.tab", "es": "wn-data-spa.tab"}[lang]))
    in_sets = collections.Counter()
    for s, _ in sets:
        for k in {key(w) for w, _ in s if w}:
            in_sets[k] += 1
    for s, cls in sets:
        members = {key(w) for w, _ in s if w}
        for k in members:
            sense_groups[k].append(("set", members - {k}))
        good = [(w, key(w)) for w, ok in s if w and ok]
        tight = len(s) <= 4 and all(in_sets[k] == 1 for _, k in good)
        for w, k in good:
            surface.setdefault(k, w)
            if cls:
                classes[k].add(cls)
        for _, a in good:
            for _, b in good:
                if a != b:
                    note(a, b, "set", cls)
                    if tight:
                        note(a, b, "tight-set")
    if lang == "de":
        # German: the capital tells a noun (OpenThesaurus gives no word class).
        for k in surface:
            classes[k].add("n" if german_noun(surface[k]) else "x")

    # First pass: the synonyms each word would get without rule 2.
    candidates = collections.defaultdict(list)
    reasons = collections.Counter()
    for (e, w), ev in evidence.items():
        # "tight-set" comes with "set", so a small unambiguous set counts as two evidences (rule 3).
        count = len(ev - {"english-main"})
        if not same_kind(surface.get(e, e), surface.get(w, w)):
            reasons["word-class"] += 1
        elif lang != "de" and surface.get(w, w)[:1].isupper() and not surface.get(e, e)[:1].isupper():
            reasons["name"] += 1
        elif lang == "de" and OT_LABELLED.get(w) and not any(OT_LABELLED[w]):
            reasons["label"] += 1
        elif any(w in source.known and w not in source.plain for source in (native, english)):
            # Every sense of the synonym is slang, vulgar, outdated … («eff», «zorra»).
            reasons["label"] += 1
        elif count < 2:
            reasons["one-evidence"] += 1
        else:
            candidates[e].append(w)

    # Second pass, rule 2: if a word's synonyms belong to different meanings, only those of its most common
    # meaning stay (listed under its first sense in the English Wiktionary).
    lists = collections.defaultdict(list)
    for e, ws in candidates.items():
        # English sources order senses by frequency, so there any word with several meanings keeps only the
        # synonyms of its first one (else «guard» got «crossguard», «justice» got «judge»).
        several = e in unknown or ambiguous_synonyms(ws, sense_groups[e]) or (
            lang == "en" and max(native.senses[e], wordnet_senses.get(e, 0)) >= 2)
        for w in ws:
            if several and "english-main" not in evidence[(e, w)]:
                reasons["ambiguous"] += 1
                continue
            reasons["ok"] += 1
            if lang == "de":
                cls = "n" if german_noun(surface[e]) else "x"
            else:
                cls = votes[(e, w)].most_common(1)[0][0] if votes[(e, w)] else (sorted(classes[e]) or ["x"])[0]
                if lang != "en":
                    cls = "x" if cls == "v" else cls   # only English tells verbs apart («to …»)
            lists[(e, cls)].append(w)
    out = {(surface[e], cls): [surface[w] for w in ws] for (e, cls), ws in lists.items()}
    head_classes = {surface[e]: {c if lang == "en" or c != "v" else "x" for c in classes[e]} for (e, _) in lists}
    return out, head_classes, gender, reasons


def ambiguous_synonyms(words, groups):
    """Whether a word's synonyms belong to different meanings («Wirtschaft»: Gasthaus, Lokal | Ökonomie).

    For two synonyms, every source that knows both votes: together (one of its sense groups has both) or apart
    (it has them in different groups). Wiktionary senses weigh 1, thesaurus sets ½ (they split finely: two sets
    for «beginnen»). Two synonyms are one meaning when «together» outweighs «apart», different meanings when
    «apart» does. The word is ambiguous when two synonyms are different meanings and no chain of one-meaning pairs
    links them. A source that knows only one of two synonyms has no say about them (it cannot have seen the other
    meaning), and one sloppy entry does not join two meanings (sense 1 of «Versuch» lists «Erprobung» next to
    «Anlauf»: the thesaurus puts «Erprobung» with «Test», the German Wiktionary keeps «Test» apart – a tie)."""
    weight = {"native": 1.0, "english": 1.0, "wordnet": 1.0, "set": 0.5}
    words = list(words)
    member = [[(t, i) for i, (t, g) in enumerate(groups) if w in g] for w in words]
    n = len(words)
    parent = list(range(n))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    different = []
    for i in range(n):
        for j in range(i + 1, n):
            together = apart = 0.0
            for tag in weight:
                gi = {g for t, g in member[i] if t == tag}
                gj = {g for t, g in member[j] if t == tag}
                if gi and gj:
                    if gi & gj:
                        together += weight[tag]
                    else:
                        apart += weight[tag]
            if together > apart:
                parent[find(i)] = find(j)
            elif apart > together:
                different.append((i, j))
    return any(find(i) != find(j) for i, j in different)


def german_noun(word):
    """German: a noun when the last word is capitalised («Grund und Boden»; not «in den Krieg ziehen»)."""
    last = re.sub(r"\s*\([^()]*\)", "", word).strip().split(" ")[-1:]
    return bool(last and last[0][:1].isupper())


def oewn(src):
    """Open English WordNet: (word, synonym, class) for the synset of each word's most common sense (per word class)
    when that synset is also the synonym's most common sense («respective» does not get «various»), each word's
    synsets as sense groups, and its word classes."""
    folder = os.path.join(src, "oewn")
    rank = {}
    first = collections.defaultdict(dict)       # lemma -> class -> synset of its first sense
    synsets_of = collections.defaultdict(list)
    classes = collections.defaultdict(set)
    for name in os.listdir(folder):
        if not name.startswith("entries-"):
            continue
        for lemma, by_pos in json.load(open(os.path.join(folder, name), encoding="utf-8")).items():
            for pos, entry in by_pos.items():
                cls = "n" if pos == "n" else "v" if pos == "v" else "x"
                classes[lemma.replace("_", " ")].add(cls)
                for i, sense in enumerate(entry.get("sense", [])):
                    rank[(lemma, sense["synset"])] = i + 1
                    synsets_of[lemma].append(sense["synset"])
                    if i == 0:
                        first[lemma].setdefault(cls, sense["synset"])
    members = {}
    for name in os.listdir(folder):
        if name.startswith("entries-") or not name.endswith(".json"):
            continue
        data = json.load(open(os.path.join(folder, name), encoding="utf-8"))
        if isinstance(data, dict):
            for sid, synset in data.items():
                if isinstance(synset, dict):
                    members[sid] = synset.get("members", [])
    pairs = []
    for lemma, by_class in first.items():
        e = clean(lemma.replace("_", " "))
        if not e or e[0].isupper():
            continue
        for cls, sid in by_class.items():
            for m in members.get(sid, []):
                w = clean(m.replace("_", " "))
                if w and m != lemma and not w[0].isupper() and key(w) != key(e) and rank.get((m, sid), 99) == 1:
                    pairs.append((e, w, cls))
    groups = {lemma.replace("_", " "): [[m.replace("_", " ") for m in members.get(sid, []) if m != lemma]
                                        for sid in sids] for lemma, sids in synsets_of.items()}
    return pairs, groups, classes


def main(lang, src, dst):
    global CASE_SENSITIVE
    CASE_SENSITIVE = lang == "de"
    lists, head_classes, gender, reasons = build(lang, src)
    lines = []
    for (word, cls) in sorted(lists):
        syns = list(dict.fromkeys(lists[(word, cls)]))
        if not syns:
            continue
        head = f"{word}#{cls}/{''.join(sorted(head_classes.get(word, {cls})))}"
        lines.append("\t".join([head] + [s + ("|" + gender[s] if s in gender and cls == "n" else "") for s in syns]))
    with open(dst, "w", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")
    pairs = sum(len(l.split("\t")) - 1 for l in lines)
    print(lang, json.dumps({"lists": len(lines), "pairs": pairs, "decisions": dict(reasons)}), file=sys.stderr)


if __name__ == "__main__":
    main(*sys.argv[1:])
