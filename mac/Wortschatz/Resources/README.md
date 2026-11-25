# Resources
Assets.xcassets (AppIcon, AccentColor #5146E5 / #7B74FF). Regenerate the icon with mac/scripts/make-icon.swift.

## Sprachen (Deutsch und Englisch, seit 24.11.2026)
`Localizable.xcstrings` ist der String Catalog: Deutsch ist die Ausgangssprache (der Text im Code ist der
Schlüssel), Englisch die Übersetzung. Welche Sprache gilt, entscheidet macOS beim Start (Sprache des Mac
oder Einstellungen › Allgemein › Sprache, `App/AppLanguage.swift`).
- **Neuer Text in der App:** `Text("…")`, `Button("…")`, `.help("…")` usw. werden von selbst übersetzt;
  alles, was als `String` weitergereicht wird, als `String(localized: "…")`. Ganze Sätze, keine
  zusammengesetzten Satzteile; Variablen im Literal (`String(localized: "Runde \(n) geschafft")`).
- **Neuer Text im Kern** (`Packages/WortschatzCore`): `L("…")` bzw. `L("Runde %@ geschafft", "\(n)")`
  (`CoreText.swift`). Ohne App bleibt er deutsch – `swift test`, Linux und die Paritätstests sehen nichts davon.
  Die Windows-App übernimmt die deutschen Texte wie bisher.
- **Übersetzen:** nach einem Build `mac/scripts/strings.py sync <DerivedData>` (holt neue Texte in den
  Katalog), `strings.py missing neu.json` (offene Texte), übersetzen, `strings.py apply neu.json`,
  `strings.py check`. `mac/scripts/test.sh` meldet Texte ohne Englisch. In Xcode geht es auch direkt im Katalog.
- **Texte, die nicht jede App hat** (nicht die Mac-App der Downloadseite): in einer eigenen Tabelle, im Kern
  `L(table: "Name", "…")`, in der App `Text("…", tableName: "Name")`; `strings.py` führt dafür `Name.xcstrings`
  (seit 25.11.2026). Eine solche Datei steht in den Ausnahmen des Ziels «Wortschatz», die Mac-App der
  Downloadseite bekommt sie nicht.
- Tests laufen auf Deutsch (Schema: Testsprache de, UI-Tests mit `-AppleLanguages (de)`).
