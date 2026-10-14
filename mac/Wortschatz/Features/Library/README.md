# Features/Library
The sidebar (spec §4.1): "Übersicht" and the section "Lernsets" (mastery gauge, title, "52 Begriffe",
a play badge for running sessions), `.searchable(placement: .sidebar)` over titles, descriptions and
terms (Return opens the first hit), the "+" toolbar button (hidden while studying).

- `LibrarySidebar.swift`: the list; selection goes through `AppModel.select(_:)`. `LibrarySearch` is the
  port of `matchItem` (dashboard.js) on `StudyCopy.fold`.
- `SetActionsMenu.swift`: the set actions shared by the sidebar, the overview cards and the set
  detail's "…" menu (Lernen, Schreiben, Bearbeiten, Duplizieren, Als Text exportieren…, Löschen).
