# Features/Exam

Prüfungsmodus (spec: docs/superpowers/specs/2026-10-13-wortschatz-exam.md): a vocabulary test with every question on
one page, a time limit and a Swiss grade. Swift files in this folder are compiled into the app automatically.

| File | What it holds |
|---|---|
| `ExamScreen.swift` | `ExamScreen(request:)` (the shell's entry point) and `ExamScreenContent`: the phase's page, the toolbar status (time, answered questions), the Lernen menu; `ExamBar`, `ExamTime`, the empty set. |
| `ExamController.swift` | `@Observable` controller: settings (UserDefaults `exam.settings`), the sheet and its answers, the time limit, marking, retakes and "Falsche lernen". Records nothing. |
| `ExamSetupView.swift` | "Prüfung einrichten": Wörter, Zeitlimit, Antworten auf, Kleine Fehler, Nur markierte. |
| `ExamSheetView.swift` | The sheet: numbered rows (prompt, answer field), ↩ to the next question, ⌘↩ "Abgeben", the accent buttons over the bar. |
| `ExamResultsView.swift` | The grade, verdict, tiles and every answer with its mark. |
| `ExamSnapshots.swift` | DEBUG snapshot scenes `exam-*`. |

The marking and the grade live in the package (`Exam.swift`).
