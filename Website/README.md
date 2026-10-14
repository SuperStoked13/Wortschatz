# Wortschatz

A Quizlet-style vocabulary trainer: you study a set with **Lernen** (multiple choice, then written answers), practise spelling with **Schreiben**, flip **Karteikarten** and test yourself with a **Prüfung**. The interface is in German.

## Folder layout

The project folder holds three parts:

- `Website/` — the web app (this folder): plain HTML, CSS and JavaScript modules. The Windows app shows exactly this app.
- `mac/` — the native Mac app (SwiftUI). `mac/scripts/build.sh` builds it into `mac/build/Wortschatz.app`.
- `windows/` — the Windows app: a small host program (`windows/host`, Go) that shows the web app in Microsoft's WebView2. `windows/build.sh` builds it into **`windows/dist/Wortschatz.exe`**.

## Start

**Windows:** double-click **`Wortschatz.exe`**. There is nothing to install: it uses Microsoft's WebView2 runtime, which comes with Windows 11 and almost every Windows 10. The exe is self-contained; you can copy it anywhere (Desktop, Documents, a USB stick).

- Your sets, progress and settings are stored in **`%LOCALAPPDATA%\Wortschatz`**, not next to the exe. They stay there when you replace the exe with a newer one.
- The first time, Windows may show «Der Computer wurde durch Windows geschützt» (SmartScreen, because the exe is not signed). Click **Weitere Informationen → Trotzdem ausführen**.
- If WebView2 is missing or too old, Wortschatz says so and offers to open Microsoft's download page.
- Read-aloud uses the voices installed in Windows. If a language has no voice (often French on a German Windows), Wortschatz tells you; add one in the Windows settings under **Zeit und Sprache**.

**Mac:** use the Mac app (`mac/build/Wortschatz.app`). The web app also runs in a browser on the Mac (the browser version): double-click **`Start.command`** in this folder. A Terminal window opens, and the app opens in your browser at <http://localhost:4173>. Keep the Terminal window open while you practise and close it when you're done.

> The first time, macOS may say the file is from an unidentified developer. Right-click `Start.command` → **Öffnen** → **Öffnen**.
>
> The browser version stores your sets **in that browser** under that address. Always use the same address (`http://localhost:4173`): a different browser or a different port starts empty.

### Moving your sets between computers

Each app keeps its own data. To move your sets, progress and statistics from one to the other (for example from the Mac to Windows):

1. On the Mac: **Einstellungen → Backup exportieren**. This saves a file like `wortschatz-backup-2026-10-14.json`.
2. Copy the file to the Windows computer (USB stick, cloud folder, e-mail).
3. In the Windows app: **Einstellungen → Backup importieren** (or drag the file onto the backup panel). If the app already has sets, choose **Zusammenführen** to keep them, or **Alles ersetzen**.

It works the same way in the other direction and with the browser version: all three use the same backup format. In the Windows app, exported files (backups, text exports) go to your **Downloads** folder.

## Features

- **Dashboard:** all your sets with a mastery bar (*Neu / Am Lernen / Gemeistert*), your learning streak, words answered today, a "Weiterlernen" card to resume, search and sorting. Each set's «…» menu starts any study mode.
- **Smart import:**
  - Paste a list, or drop a `.txt`/`.csv` file, a PDF or a photo/screenshot (⌘V / Ctrl+V). The app works out which part is the word and which is the translation.
  - It handles alternating lines, as in a typical vocab list, as well as tab, dash, `=`, `;`, CSV and Quizlet exports, numbered lists, and two-column tables from PDFs and photos.
  - It drops headings and page numbers.
  - If German is on the left, it swaps the sides automatically.
- **Learn mode (*Lernen*, the main mode, modelled on Quizlet Learn):**
  - New words first appear as **multiple choice with 4 options** (keys 1–4). You can also **type the first letters** of an answer and press Enter to choose it.
  - After a correct answer, the word is asked **in writing** the next time. A second correct answer makes it *gemeistert*.
  - A mistake sends the word back to multiple choice, and it comes up again at the end of the round.
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

There is no build step for the web app and nothing to install: plain HTML, CSS and JavaScript modules.

- `tests/run.sh`: runs all unit tests with macOS's built-in JavaScriptCore (no Node needed). `tests/run.sh grading` runs only the files whose name contains "grading".
- `windows/build.sh` (in the project folder, next to `Website/`): builds `windows/dist/Wortschatz.exe` on the Mac. It downloads its own Go compiler into `~/Library/Caches/Wortschatz/windows-toolchain` the first time and embeds the web app (`index.html`, `src/`, `styles/`, `assets/`) in the exe, so rebuild it after changing the web app.
- `serve.py`: a tiny static server (no caching), used by `Start.command`.
- Design spec: `docs/superpowers/specs/2026-10-11-wortschatz-design.md`. Implementation plans: `docs/superpowers/plans/`.
- PDF reading (pdf.js) and photo OCR (tesseract.js) are downloaded on first use, so those two imports need an internet connection, in the browser and in the Windows app. Everything else works offline.
