# Synonymwörterbücher (SynonymLexicon.cs)

Für «Weitere Synonyme erkennen» in der Windows- und Android-App (GitHub-Issue #4, 10.11.2026). Der Mac fragt dafür das
Sprachmodell von Apple Intelligence; Windows hat keines, darum liegen hier **einsprachige** Synonymlisten (deutsche
Wörter für deutsche Wörter usw., kein Übersetzungswörterbuch, Joans Vorgabe). Bei einer geschriebenen Antwort zählen
die Synonyme der **erwarteten Antwort** in ihrer eigenen Sprache: Karte «bike → das Fahrrad», Antwort «das Velo» →
richtig, mit dem Hinweis «Synonym – nicht im Set».

| Datei | Wörter mit Synonymen | gepackt | im Speicher, sobald gebraucht |
|---|---|---|---|
| `de.syn` | 83 294 | 1,1 MB | 4,8 MB |
| `en.syn` | 32 947 | 0,4 MB | 1,7 MB |
| `es.syn` | 45 216 | 0,5 MB | 2,2 MB |
| `fr.syn` | 22 355 | 0,3 MB | 1,2 MB |
| `it.syn` | 25 884 | 0,3 MB | 1,4 MB |

Zusammen 2,6 MB in der exe. Eine Sprache wird erst entpackt, wenn eine Lernsitzung sie braucht (im Hintergrund beim
Start der Sitzung). Chinesisch und Arabisch: keine Daten (keine Quelle in brauchbarer Qualität).

## Quellen und Lizenzen

| Sprache | Quelle | Stand | Lizenz |
|---|---|---|---|
| Deutsch | OpenThesaurus, Textexport (openthesaurus.de) | 09.11.2026 | CC BY-SA 4.0 (wahlweise LGPL) |
| alle ausser Englisch | Wiktionary der eigenen Sprache (de, fr, es, it), über wiktextract (kaikki.org) | Abzug vom 10.11.2026 | CC BY-SA 4.0 / GFDL |
| alle | Englisches Wiktionary (Einträge der jeweiligen Sprache), über wiktextract (kaikki.org) | Abzug vom 10.11.2026 | CC BY-SA 4.0 / GFDL |
| Englisch | Open English WordNet 2025 (en-word.net) | 2025 | CC BY 4.0 |
| Italienisch | MultiWordNet 1.5 (über Open Multilingual Wordnet) | – | CC BY 3.0 |
| Spanisch | Multilingual Central Repository 3.0 (über Open Multilingual Wordnet) | – | CC BY 3.0 |

Die `.syn`-Dateien sind aus diesen Quellen ausgewählt und bearbeitet und stehen darum selbst unter **CC BY-SA 4.0**
(ShareAlike gilt für die Daten, nicht für den Programmcode). Die App nennt die Quellen unter Einstellungen › Daten ›
Info. Nicht verwendet: die Thesauren von LibreOffice (Französisch ohne getrennte Bedeutungen und sehr locker:
«courage» → «sacrifice», «prix»; Italienisch GPL; Deutsch ist ein OpenThesaurus-Stand von 2017).

## Regeln (Genauigkeit vor Vollständigkeit)

Ein falsches «richtig» bringt etwas Falsches bei, ein verpasstes Synonym kostet nur einen Klick. Die Regeln stehen
ausführlich in `tools/synonym-data/build_synonyms.py`; kurz:

1. **Zwei Belege:** Ein Paar braucht zwei unabhängige Belege – der Eintrag des Worts nennt das Synonym, der Eintrag
   des Synonyms nennt das Wort, das englische Wiktionary nennt es, beide stehen in einem Thesaurus-/WordNet-Satz. Ein
   kleiner, eindeutiger OpenThesaurus-Satz (höchstens 4 Wörter, keines in einem anderen Satz) zählt doppelt.
2. **Nur die Hauptbedeutung, wenn ein Wort mehrdeutig ist:** Zerfallen die Synonyme eines Worts in verschiedene
   Bedeutungen («Wirtschaft»: Gasthaus, Lokal | Ökonomie; «Versuch»: Test | Anlauf), bleiben nur die der häufigsten
   Bedeutung, und zwar nach der Reihenfolge im englischen Wiktionary bzw. in WordNet (die ist nach Häufigkeit; im
   deutschen Wiktionary ist Bedeutung 1 von «Wirtschaft» das Gasthaus). Weiss das niemand, bekommt das Wort keine.
   So nimmt «wirtschaftlich» (economic) nie «sparsam» (economical).
3. **Markierungen:** Ein als umgangssprachlich, bildlich, veraltet, derb, mundartlich, scherzhaft usw. markiertes
   Synonym fällt weg (Liste `ALLOWED` im Skript: erlaubt sind z. B. Fachsprache, gehoben, schweizerisch,
   österreichisch). Steht die Markierung an der ganzen Bedeutung (Slang, vulgär, veraltet, bildlich …; `SENSE_DENY`),
   fallen deren Synonyme weg, und ein Wort, das nur solche Bedeutungen hat, gilt nie als Synonym («zorra», «eff»).
   Was OpenThesaurus nur umgangssprachlich kennt, fällt auch weg, wenn Wiktionary es ohne Markierung führt («Mumm»).
4. **Wortart:** Die Listen sind nach Wortart getrennt. Die App nimmt Nomen-Synonyme nur, wenn die Karte ein Nomen
   zeigt: einen Artikel, im Deutschen einen Grossbuchstaben («Steuern» → Abgaben, «steuern» → navigieren), im
   Englischen kein «to» («to spy» → espy, «spy» → undercover agent). «bête» ohne Artikel bekommt nicht «animal».
5. **Artikel:** Steht auf der Karte ein Artikel, gilt ein Nomen-Synonym nur mit dem Artikel seines eigenen
   Geschlechts («das Fahrrad» → «das Velo», nie «der Velo»; Geschlecht aus Wiktionary). Ist das Geschlecht
   unbekannt, fällt das Synonym weg.
6. Wie beim Mac zählen die Antwort einer anderen Karte des Lernsets und die Frage selbst nie als Synonym
   (`Synonyms.GradeWithSynonyms`).

Geprüft an Joans Lernsets (Englisch–Deutsch, Französisch) und an Grundwortschatz aller fünf Sprachen; Beispiele, die
nicht durchgehen dürfen, stehen als Tests in `tests/Wortschatz.Core.Tests/SynonymLexiconTests.cs`. Bekannte
Grenzen: Französisch findet eher wenig (Wiktionary ordnet dort Synonyme selten einer Bedeutung zu); vereinzelt geht
ein loses Paar durch («damals» → «derzeit», veraltet gebraucht).

## Neu bauen

```bash
windows-native/tools/synonym-data/build.sh        # lädt die Quellen nach ~/.cache/ws-thes (ca. 4 GB), ~15 min
```

Danach `dotnet test tests/Wortschatz.Core.Tests --filter "FullyQualifiedName~SynonymLexicon"`. Ändert sich
`ExtendedSynonyms.LooseKey`, müssen die Daten neu gepackt werden (der Test `EveryStoredKeyIsStillTheKeyTheAppComputes`
merkt es); dafür reicht der letzte Schritt des Skripts (`dotnet run --project tools/Wortschatz.SynonymData …`).

Format: `SynonymLexicon.cs` (Kopf).
