# Wortschatz (Mac): Prüfungsmodus (exam)

Date: 2026-10-13. Mac only (the web app has no exam).

## Decisions (user)

> "beim prüfungs mode vielleicht separate einstellungen (zeit, anzahl wörter, toleranz (egü gibt nur ein halben punkt abzug) ich würde beim prüfungsmode auch ein toggle einbauen für beispielsätze aktivieren (man erhält beispiel sätze welches das voci beihalten) der prüfungs modus soll eine andere ansicht haben (nicht ein wort nach dem anderen sondern alles auf einer seite)"

- An exam has its own settings: time limit, number of words, direction and tolerance (a small mistake costs half a point).
- Example sentences were built first (a context sentence per word, written by Apple Intelligence), then dropped the same evening: the user had meant a second task translating whole sentences built from the vocabulary, and decided against it as too complex to grade. The exam is a plain vocabulary test: translating words only.
- Every question is on one page (an exam sheet), not one word after the other.
- The result is a Swiss grade (1 to 6).
- An exam records nothing: mastery stays with Lernen and Schreiben. The result offers to learn the words that went wrong.

## Behaviour

- Entry points: the "Prüfung" button after "Karteikarten" on the set page, Lernset › Prüfung (⌃⌘L), and the set context menu (sidebar, overview). Same study layout as the other modes (the sidebar slides away, "‹ Lernsets" and esc lead back).
- **Prüfung einrichten** (settings page): Wörter (10, 15, 20, 30, Alle; only sizes below the set's count), Zeitlimit (Ohne, 5 to 45 minutes, with a suggestion of about 30 seconds per word), Antworten auf (term language, definition language, Beides: random per question), Kleine Fehler (Streng / Halber Punkt / Grosszügig), and Nur markierte when the set has starred cards. All settings apply to every set (UserDefaults `exam.settings`, JSON of `ExamSettings`, read leniently). Return = "Prüfung starten".
- **The sheet**: numbered rows on one panel: the prompt (with its language) and the answer field. Wide windows put the field beside the prompt, narrow ones under it. ↩ moves to the next question (and scrolls to it), Tab works too, ⌘↩ = "Abgeben" (asks when questions are still open: they count as wrong). The accent buttons of the focused answer's language float above the bar. The toolbar shows the time left (amber in the last minute; without a limit the time taken) and "12/20". A minute before the end a toast says so; at zero the exam is handed in by itself ("Die Zeit ist um").
- Leaving or "Neue Prüfung" (⇧⌘R) during an exam with answers asks first ("Prüfung beenden?"), whichever way it is left (esc, also typed in an answer field; "‹ Lernsets"; the Lernset menu; the sidebar; a newly saved set): `AppModel.studyLeaveGuard`. An unfinished exam is not kept. Handed in by the timer, the result's Return button waits 1.2 s, so a Return meant for the next question does not close the result unseen.
- **Result**: the grade in a large circle (green from 5, accent from 4, amber below), a verdict ("Perfekt!", "Hervorragend!", "Sehr gut!", "Gut gemacht!", "Bestanden!", "Noch nicht genügend"), points and time ("17.5 von 20 Punkten in 8:41"), tiles (Richtig, Kleine Fehler with what they cost, Falsch, Ohne Antwort), confetti from 5.5, and every answer with its mark (✓, ½, ✗, –), the typed answer with the mistakes marked (against the synonym's own word when the answer was another card's), the right answer and a note ("Tippfehler", "Falscher Artikel", …). Bar: "Neue Prüfung", "Falsche lernen" (a Learn session with those cards; cards Lernen counts as mastered are asked again too, as repetition questions, `StudyRequest.reviewMastered`), "Falsche prüfen" (a new sheet with only those), "Fertig ↩".

## Marking (`WortschatzCore/Exam.swift`, tested in `ExamTests`)

- Two passes of the Learn/Write grader (`Synonyms.gradeWithSynonyms`, so the answer of a card with the same prompt counts too):
  1. Only forms that are no mistake: one of several answers, optional brackets, abbreviations, capitals (outside German). Right → 1 point, unless a German noun lost its capital letter (a small mistake).
  2. With the small mistakes allowed: a typo, missing accents, a missing article or reflexive pronoun. Right → a small mistake.
- A small mistake scores by the tolerance: Streng 0, Halber Punkt 0.5, Grosszügig 1. A wrong article is a mistake, not a small one.
- Grade: 1 + 5 × points / maximum, rounded to tenths ("5.3"; computed in tenths, so exact halves such as 34.5 of 50 = 4.45 round up to 4.5); 4 passes.

## Code

- Core: `Exam.swift` (`ExamSettings`, `ExamTolerance`, `ExamQuestion`, `Exam.makeQuestions/mark/evaluate/grade`, `ExamCopy`), `StudyMode.exam`.
- App: `Features/Exam/` (controller, screen with toolbar status and bar, setup, sheet, results, snapshots), `App/AppModel+Exam.swift` (`startExam`), the `DetailRoute.exam` route.
- Snapshot scenes `exam-setup`, `exam-sheet`, `exam-results` (`--render-snapshots <dir> --snapshot-filter exam-`).
