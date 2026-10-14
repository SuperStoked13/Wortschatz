# Features/Overview
"Übersicht" (spec §4.4, port of src/screens/dashboard.js).

- `OverviewScreen.swift`: greeting ("Guten Morgen/Tag/Abend", date), the three glass stat tiles.
- `OverviewHero.swift`: the "Weiterlernen" hero bound to Return (latest Learn session, else Write
  session, else the most recent set with "Öffnen").
- `OverviewSetGrid.swift`: "Deine Lernsets" with sort (Zuletzt gelernt / Name / Neueste), the dashed
  "Neues Lernset" card and the set cards on a content surface (`contentSurface`, not glass: gauge, status line, quick "Lernen"/"Weiterlernen").
- `OverviewEmptyState.swift`: "Erstes Lernset erstellen ↩", "Aus der Web-Version übernehmen…", 3 steps.
- `WebMigrationSheet.swift`: the 3-step how-to and the backup file chooser.
