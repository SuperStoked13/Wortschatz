# Features/Write
The Write screen (spec §4.4 "Write", §4.3 key map, §6 `WriteFlow`). Swift files in this folder are compiled into the app automatically.

- `WriteScreen.swift`: `WriteScreen(request:)` (shell contract), `WriteScreenContent` (keys, focus, toolbar, alerts, editor sheet, Lernen menu), `WriteToolbarProgress`.
- `WriteController.swift`: runs the `WriteFlow` reducer and performs its effects (store, speech, haptics, VoiceOver, toasts, auto-advance timer, study clock, navigation).
- `WriteKeyRouter.swift`: which keys the screen takes and where the focus belongs.
- `WriteStage.swift`, `WritePromptCard.swift`, `WriteActionBar.swift`: question card, feedback, copy step and the floating bar with the Return action.
- `WriteSummaryView.swift`, `WriteResultsView.swift`: round summary and results.
- `WriteOptionsPanel.swift`, `WriteCardEditor.swift`: options popover (⌘K) and "Karte bearbeiten" (⌘E).
- `WriteSnapshots.swift` (DEBUG): `--render-snapshots <dir> --snapshot-filter write-`.
