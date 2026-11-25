# Wortschatz

A Quizlet-style vocabulary trainer: you study a set with **Lernen** (multiple choice, then written answers), practise spelling with **Schreiben**, flip **Karteikarten** and test yourself with a **Prüfung**. The interface is in German.

## What this folder is now

`Website/` is the original version of Wortschatz: plain HTML, CSS and JavaScript modules. Up to version 1.1 it was
the interface of the Windows app (a small Go host showed it in WebView2). Since 1.2 the Windows app is the native
port in `windows-native/`, and this folder is no longer shipped anywhere.

It stays as the **JavaScript reference**: the generators in `mac/Parity/` run its code to produce the test fixtures
(`mac/Packages/WortschatzCore/Tests/WortschatzCoreTests/Fixtures/`) that the Mac app and the Windows app are both
tested against. Change it only together with the apps, and regenerate the fixtures (`mac/scripts/gen-fixtures.sh`).

## Features

- **Dashboard:** all your sets with a mastery bar (*Neu / Am Lernen / Gemeistert*), your learning streak, words answered today, a "Weiterlernen" card to resume, search and sorting. Each set's «…» menu starts any study mode.
- **Smart import:**
  - Paste a list, or drop a `.txt`/`.csv` file, a PDF or a photo/screenshot (⌘V / Ctrl+V). The app works out which part is the word and which is the translation.
  - It handles alternating lines, as in a typical vocab list, as well as tab, dash, `=`, `;`, CSV and Quizlet exports, numbered lists, and two-column tables from PDFs and photos.
  - It drops headings and page numbers.
  - If German is on the left, it swaps the sides automatically.
- **Learn mode (*Lernen*, the main mode, modelled on Quizlet Learn):**
  - New words first appear as **multiple choice with 4 options** (keys 1–4). You can also **type the first letters** of an answer and press Enter to choose it.
  - The wrong options are as alike as possible: cards of the **same word class** (noun, verb, adjective/adverb, expression, number), then the most similar ones – close by in the set, same article, similar length and spelling (`src/core/wordclass.js`).
  - After a correct answer, the word is asked **in writing** the next time. A second correct answer makes it *gemeistert*.
  - A mistake resets the word; it comes back after about 10–15 other questions. Each word is asked as multiple choice
    only until it was answered right once: from then on it stays written, also after a mistake (since 24.11.2026).
  - You study in **rounds of 7 words**, with a progress summary after each round. Mastered words are replaced by new ones until the whole set is mastered.
  - **Wiederholungsfragen** (option): each round also asks a few words you already mastered, so they stay fresh.
  - Options: question types, words per round, answer direction, tolerance, read-aloud and retyping.
- **Write mode (*Schreiben*):**
  - Counters on the left (*Verbleibend / Falsch / Richtig*), accent buttons (é è ç œ …) and read-aloud.
  - After a mistake you copy the correct answer once, unless you switch that off. **Ich hatte recht** overrides a wrong mark, and **Bearbeiten** fixes a card on the spot.
  - Each round ends with a summary, and the next round asks only the words you missed. The final results list your most-missed words, with **Falsche nochmal üben**.
  - Sessions are saved after every answer, so you can always pick up where you stopped.
- **Karteikarten (flashcards):** flip a card (Space or Enter) and sort it with ← *Lerne ich noch* or → *Weiss ich*; the cards you still learn come back in the next round. Sorting is only for you: it never changes your progress.
- **Prüfung (exam):** all questions on one page, answered in writing, with an optional time limit and a Swiss school grade (1–6) at the end. You choose how many words and how strictly small mistakes count. **Falsche lernen** sends the questions you got wrong straight to Lernen. The exam never changes your progress.
- **Serien (streaks):** «N richtig in Folge» while you answer, and a daily **Lernserie** that is always visible in the header. The first answer of a day celebrates it.
- **Soundeffekte:** soft sounds for right and wrong answers, streaks and finished rounds (Einstellungen → Töne; on by default).
- **Read-aloud:** every word can be read aloud; under Einstellungen → Stimmen zum Vorlesen you choose the voice for each language of your sets.
- **Nur markierte / Nur schwierige:** study only the starred words, or only the words you answered wrong at least 4 times.
- **Keyboard:** everything works with the keyboard, Enter being the main key. On a set: Enter or Ctrl+L (⌘L) Lernen, Ctrl+Shift+L Schreiben, Ctrl+E Bearbeiten; Ctrl+N starts a new set; in the editor Ctrl+Enter or Ctrl+S saves.
- **Options (per set):**
  - Answer in the target language, in German, or both directions.
  - Shuffle, copy step, auto-advance, read-aloud.
- **Leniency (*Toleranz*):**
  - On by default: a missing article or pronoun (`Herr` for *der Herr*, `appeler` for *s'appeler*), abbreviations (`etw.` = `etwas`, `sth` = `something`, `qc` = `quelque chose`), one of several answers is enough, text in brackets is optional, capitalisation is ignored.
  - Off by default: ignore accents, allow small typos.
  - Always equal: `ss` and `ß`.
- **Progress:** a word counts as *gemeistert* after 2 correct answers in a row, across rounds and sessions.

## Development

Nothing to build or install: plain HTML, CSS and JavaScript modules.

- `tests/run.sh`: runs all unit tests with macOS's built-in JavaScriptCore (no Node needed). `tests/run.sh grading` runs only the files whose name contains "grading".
- Design specs (written before the apps): `docs/superpowers/specs/`.
