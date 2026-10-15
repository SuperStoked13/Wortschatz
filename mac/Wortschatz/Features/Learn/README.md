# Features/Learn

The Learn screen (spec §4.4 "Learn", §4.3 key map, §6 `LearnFlow`). Swift files in this folder are compiled into
the app automatically.

| File | What it holds |
|---|---|
| `LearnScreen.swift` | `LearnScreen(request:)` (the shell's entry point) and `LearnScreenContent`: toolbar (Runde N, progress capsule, Optionen, Neu starten), key target and focus, the Lernen menu (`\.studyCommands`), the options popover, the card editor sheet and the prompts. |
| `LearnController.swift` | `@Observable` controller: reduces `LearnFlow` events with fresh store progress and performs every effect (store, speech, haptics, VoiceOver, toasts, auto-advance timer, navigation); store sync and the study clock. |
| `LearnKeyRouter.swift` | The single key strategy: SwiftUI key presses → `KeyInput` (with repeat), which keys the screen consumes, and where the focus belongs per phase. |
| `LearnStage.swift` | Layout per phase: scrolling study column, floating action bar (`safeAreaBar`), intro hint, question view with the 2×2 `ChoiceGrid`. |
| `LearnPromptCard.swift` | The glass study card (language, prompt, 🔊 ★ ✎) and the written answer area: answer/copy field with the special characters, the correct answer, "Deine Antwort" diff and "Richtige Antwort". |
| `LearnActionBar.swift` | The floating glass bar: status pill (key hints morphing into the feedback, `glassEffectID`) and the buttons; it always ends with `LearnFlow.returnAction` and its ↩ keycap. |
| `LearnCheckpointView.swift` | "Runde N geschafft", segmented progress bar, the round's cards (`LearnTermList`). |
| `LearnFinishView.swift` | Finish screen (trophy, confetti, stat tiles, "Am häufigsten falsch") and the message screens (all mastered, empty). |
| `LearnOptionsPanel.swift` | The options form (Abfrage, Fragetypen, Begriffe pro Runde, Abtippen, Vorlesen, Wiederholungsfragen, Toleranz). |
| `LearnCardEditor.swift` | "Karte bearbeiten" sheet. |
| `LearnSnapshots.swift` | DEBUG snapshot scenes `learn-*` (scripted `LearnFlow` on the sample library). |

## Keys

- Return always does `LearnFlow.returnAction(state)`; that label is the bar's primary button with the ↩ keycap.
- Screen focus (multiple choice, feedback, checkpoint, finish): an invisible focusable view behind the content takes
  Return, digits, arrows and printable keys (`onKeyPress`, repeats flagged). It sits *behind* the content, so the
  answer tiles do not read its focus as their own (`\.isFocused`).
- Typing on multiple choice: letters (and ⌫) build `state.typed`; the one option they start is highlighted once at
  least two letters follow the article (`LearnFlow.typeAhead`: "la vo" → la voiture, "la" or "la v" never), so Return
  chooses it. Options the letters do not start fade (`.filtered`), the typed letters are underlined in the tiles, and
  a hint below the grid shows them ("↩ wählt «…»", "Weiter tippen …", "Keine Antwort passt"). ⌫ (or fn-⌦) deletes a
  letter and keeps deleting while held, ⌥⌫ deletes a word, esc clears them first; arrows take over, digits still
  choose directly (Arabic-Indic ٠–٩ too, `LearnFlow.digitValue`; the Arabic «لا» key types both letters). ⌫ arrives
  as U+0008 through `onKeyPress` but as U+007F through the window's key fallback (`StudyKeyFallback`), so
  `LearnKeyRouter.isDeleteKey` accepts both.
- Any key continues after feedback. With an input method active (Pinyin, Kana …, not a plain layout like ABC or
  Arabic: `InputSource.isInputMethodActive`) the key continues without its raw letter landing in the next answer
  field (`LearnKeyRouter.continuing`); the answer is then typed there with the input method.
- Synonyms outside the set: Return on a written answer that would be wrong waits (at most 3 s, "Prüfe Synonym …" in
  the answer box) while `SynonymAssistant` looks it up with Apple Intelligence; it then counts as right with
  "Auch richtig!", the chip "Synonym – nicht im Set" and "Gesucht war: …".
- Answer field focus (written, copy step): letters go into the field; Return arrives through `onSubmit`, with the
  repeat flag taken from the current `NSEvent`. ⌥↩ and esc are taken by the field itself (`studyFieldKeys` in
  `LearnKeyRouter.swift`): the field editor would insert a line break for ⌥↩ and swallow esc before the menu sees
  them. Not while a dead key or an input method is composing.
- ⌘↩, ⌘K, ⌘R, ⌘D, ⇧⌘R (and ⌥↩, esc without a focused field) come through the Lernen menu
  (`LearnController.handle`), again with the repeat flag; ⌘E on the card edits the card on screen.

## Wiederholungsfragen

"Wiederholungsfragen" (Optionen, for every set: UserDefaults `learn.review`, `LearnController.setReview`) makes new
sessions ask the cards mastered already once more (`LearnReview` in the package, spec addendum §6 of the Learn mode
spec): a green "↺ Wiederholung" chip on the card (`LearnReviewChip`), "Wieder am Lernen" in the pill after a miss,
the count on the finish screen. Without it the "Alles gemeistert!" screen offers "Alle wiederholen".

Render the scenes with `--render-snapshots <dir> --snapshot-filter learn-` (see `App/DebugSnapshot.swift`).
