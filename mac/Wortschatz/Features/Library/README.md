# Features/Library
The sidebar (spec §4.1): "Übersicht" and the section "Lernsets" (mastery gauge, title, "52 Begriffe",
a play badge for running sessions), `.searchable(placement: .sidebar)` over titles, descriptions and
terms (Return opens the first hit), the "+" toolbar button (hidden while studying).

- `LibrarySidebar.swift`: the list; selection goes through `AppModel.select(_:)`. `LibrarySearch` is the
  port of `matchItem` (dashboard.js) on `StudyCopy.fold`.
- `UpdateNoticeCard.swift`: «Aktualisiert auf 1.8» above the streak after the app updated itself, the first
  change and «+2 weitere», all of them in a popover (`AppUpdater.notice`; download app only). Snapshots:
  `--snapshot-filter sidebar-update`.
- `SetActionsMenu.swift`: the set actions shared by the sidebar, the overview cards and the set
  detail's "…" menu (Lernen, Schreiben, Bearbeiten, Duplizieren, Als Text exportieren…, Löschen).
