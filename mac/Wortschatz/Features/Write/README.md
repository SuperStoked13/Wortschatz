# Features/Write
The Write screen (spec §4.4 "Write", §4.3 key map, §6 `WriteFlow`). Swift files in this folder are compiled into the app automatically.

- `WriteScreen.swift`: `WriteScreen(request:)` (shell contract), `WriteScreenContent` (keys, focus, toolbar, alerts, editor sheet, Lernen menu), `WriteToolbarProgress`.
- `WriteController.swift`: runs the `WriteFlow` reducer and performs its effects (store, speech, haptics, VoiceOver, toasts, auto-advance timer, study clock, navigation).
- `WriteKeyRouter.swift`: which keys the screen takes and where the focus belongs.
- `WriteStage.swift`, `WritePromptCard.swift`, `WriteActionBar.swift`: question card, feedback, copy step and the floating bar with the Return action.
- `WriteSummaryView.swift`, `WriteResultsView.swift`: round summary and results.
- `WriteOptionsPanel.swift`, `WriteCardEditor.swift`: options popover (⌘K) and "Karte bearbeiten" (⌘E). Direction
  and «Mischen» apply at once since 2026-11-25, wherever they are changed, also when a stored session resumes
  (`WriteSession.setOptions`): what was answered right stays done, the open questions follow the new direction, the
  questions still to come are shuffled or put in the set's order. No «Neu starten?» for options any more.
- `WriteSnapshots.swift` (DEBUG): `--render-snapshots <dir> --snapshot-filter write-`.
