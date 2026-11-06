# Wortschatz — Learn mode ("Lernen"), a 1:1 copy of Quizlet Learn — Spec addendum

> **Überholt seit 1.4 (03.11.2026):** Runden über eine feste Gruppe (active batch) und der Retry am Rundenende gibt es nicht mehr. Lernen plant jetzt mit Abstand (eine Karte frühestens nach 10, spätestens nach etwa 15 anderen Fragen wieder, gemischt mit neuen Karten), eine Runde ist die nächsten `roundSize` Fragen, dazu die Nachkontrolle nach Fehlern. Massgebend: Kopfkommentar von `src/core/learn.js`.

Date: 2026-10-11 · Requested by the user (in German):

> "baue wie in quizlet für neue wörter ein multiple choice ein (4 möglichkeiten) also wenn man beginnt
> kommt für jedes wort welches noch nie drann kam ein multiple choice, bei korrekter lösung wird
> nächstesmal nach einer geschriebenen antwort gefragt. Generell soll es einfach eine 1:1 kopie sein
> vom quizlet learn mode."

Extends `2026-10-11-wortschatz-design.md` (read that first; all global rules apply). Write mode
("Schreiben") stays as a secondary mode; **Lernen becomes the primary study mode**.

## 1. Learning model (Quizlet Learn semantics)

- A card is mastered after **2 correct answers in a row** (unchanged global rule, `MASTERY_STREAK = 2`).
  In Learn the two steps are: **multiple choice first, then written**.
- Per card *stage* (derived from the persistent `CardProgress.streak` at session start):
  - stage 0 = new or reset → next question is **multiple choice** (4 options)
  - stage 1 = "vertraut" (1 correct) → next question is **written**
  - stage 2 = mastered → not asked any more
- Correct answer → stage + 1. Wrong answer / "Weiss ich nicht?" → stage 0 (back to multiple choice),
  exactly like the streak reset in `db.recordAnswer`. Every Learn answer is recorded with
  `db.recordAnswer(setId, cardId, correct)` (so Learn and Write share one progress model).
  "Ich hatte recht" → `db.overrideLastAnswer` + engine `override`.
- Question-type options: if multiple choice is disabled, stage 0 is asked written; if written is
  disabled, stage 1 is asked as multiple choice. At least one type must stay enabled.
  Multiple choice needs ≥ 2 distinct answer texts in the set; otherwise the card is asked written.

## 2. Rounds (Quizlet: batches of 7)

- The session studies the **unmastered** cards of the scope (`all` | `starred` | `{cardIds}`), in
  set order shuffled. Already-mastered cards count as mastered in the progress bar but are not asked.
- **Active batch**: up to `roundSize` (default **7**) unmastered cards. A round = one question per
  active card at its current stage, in shuffled order. A card answered wrong is re-queued **once**
  at the end of the same round (at its new stage, i.e. multiple choice).
- At round end → **checkpoint** screen. Next round: mastered cards leave the batch; the batch keeps
  its unmastered cards and is refilled to `roundSize` from the remaining unmastered cards
  (cards with stage 1 first, then stage 0 in order). When no unmastered card is left → finished.

## 3. Engine contract — `src/core/learn.js` (pure, DOM-free, JSON-serialisable, immutable updates)

```js
export const DEFAULT_LEARN = { roundSize: 7, mc: true, written: true, retype: false }
export function stageFromProgress(progress /* CardProgress|undefined */) -> 0|1|2   // min(streak, 2)

export function createLearn(cards, options /* StudyOptions incl. options.learn */, {
  subset = 'all', progress = {}, rng = Math.random, now = Date.now() } = {}) -> LearnState
  // options.answerWith: 'term'|'definition'|'both' ('both' → each question picks ask randomly via rng)

LearnState = {
  v: 1, subset, answerWith, learn: { roundSize, mc, written },
  order: cardId[],                        // scope, shuffled once
  stage: { [cardId]: 0|1|2 },
  initiallyMastered: cardId[],
  active: cardId[],                       // current batch
  round: number,                          // 1-based
  queue: Question[],                      // remaining questions in this round (front = current)
  retried: { [cardId]: true },            // re-queued this round already
  roundLog: [{ cardId, type, ask, correct, stageAfter }],
  rounds: [{ round, answered, correct, cardIds }],
  answered: number, correct: number,
  misses: { [cardId]: number },
  last: null | { qid, cardId, type, ask, correct, stageBefore },   // for override
  startedAt, updatedAt, finishedAt: number|null, elapsedMs: number
}
Question = { qid, cardId, type: 'mc'|'written', ask: 'term'|'definition',
             choices?: [{ cardId, text }] }   // mc only; 2–4 entries, exactly one with cardId === question.cardId

export function current(state) -> Question|null
export function answer(state, correct: boolean, now) -> LearnState
export function override(state, now) -> LearnState          // flips state.last to correct (stage = stageBefore + 1, removes its retry)
export function isRoundOver(state) -> boolean
export function checkpoint(state) -> { round, answered, correct, items: [{ cardId, stage, results: boolean[] }],
                                      counts: { fresh, learning, mastered, total } }
export function nextRound(state, cards, rng, now) -> LearnState   // archives round, refills batch, builds questions (+choices)
export function isFinished(state) -> boolean               // every card in scope has stage 2
export function counts(state) -> { fresh /* stage 0 never answered in this session nor before */, learning, mastered, total, progress /* mastered/total */ }
export function buildChoices(cards, card, ask, rng, n = 4) -> [{ cardId, text }]
  // answer side = ask === 'term' ? card.term : card.definition; distractors are other cards' answer sides;
  // exclude texts equal to the correct text after normalizeBasic + lowercase, exclude duplicates, and
  // exclude cards that are synonyms (same prompt side, see src/core/synonyms.js findSynonymCards) because
  // their answer would also be correct; shuffle so the correct option's position is uniform.
export function removeCard(state, cardId, now, { cards, rng } = {}) -> LearnState
  // with `cards` (the set's current cards) each lost option is replaced in place by another valid one
export function finalStats(state) -> { total, mastered, alreadyMastered /* mastered before the session */,
                                       rounds, answered, accuracy, elapsedMs, hardest: [{ cardId, misses }] }
export function tick(state, now) -> LearnState              // like session.tick
export function matchesProgress(state, progress) -> boolean  // stages = min(streak, 2), seen = ever answered
export function syncProgress(state, progress, now) -> LearnState
  // brings in answers given elsewhere (Write mode, another tab): stages follow the stored progress,
  // newly mastered cards leave the batch and the round, queued questions switch type with their stage
```
The stored progress is the source of truth: the Learn screen syncs a stored session on resume and on
external progress changes; the set page and the dashboard show a stored session's counts synced too.
Choices are generated when a question is created (createLearn / nextRound / re-queue) and stored in
the state so a resumed session shows identical options.

## 4. Screen — `#/set/:id/learn` (`src/screens/learn.js`, helpers `learn-*.js`, `styles/screens/learn.css`)

Same overall shell as Write mode (left sidebar on desktop / compact top bar on phones), but with
Quizlet Learn's progress: a **segmented progress bar** + three counters **Neu · Am Lernen · Gemeistert**,
"Runde N", Optionen, Neu starten.

- **Multiple choice**: small label of prompt language, large prompt, speaker/star/edit icons, caption
  "Wähle die richtige Antwort", **4 large answer tiles in a 2×2 grid** (1 column on phones), each with
  its number badge 1–4; keys **1–4** select, Enter is not needed. "Weiss ich nicht?" link.
  - correct → chosen tile green with check, message "Super!" (varied), auto-advance after ~900 ms
    (any key / click continues earlier).
  - wrong → chosen tile red, correct tile green, message "Nicht ganz – das lernst du noch!", button
    **Weiter** (Enter / any key). No copy step for MC.
- **Written**: identical feel to Write mode's question card (input, special-character bar, Antworten,
  "Weiss ich nicht?"). Grading via `gradeWithSynonyms` with the set's tolerance options. Correct →
  "Richtig!" (+ "Genau:" / note chips when tolerated), auto-advance. Wrong → "Deine Antwort" (diff) +
  "Richtige Antwort", hint chip, **Ich hatte recht**, **Bearbeiten**, **Weiter**; if `learn.retype`
  (default **off**, Quizlet Learn behaviour) the copy step from Write mode is required.
- A small "Neu: Multiple Choice → nächstes Mal schriftlich" hint the very first time (dismissible).
- **Checkpoint** after each round: "Runde 3 geschafft", progress bar + "18 von 52 gemeistert",
  list of the round's cards with status chip (Gemeistert ✓ / Am Lernen / Noch neu) and per-answer
  dots, button **Weiter** (Enter).
- **Finish**: celebration, "Du hast alle Begriffe gemeistert!", stats (Begriffe, Runden, Antworten,
  Treffer %, Zeit), "Am häufigsten falsch", buttons **Nochmal lernen** (asks to reset progress of the
  scope → `db.resetProgress` or per-card reset, then new session), **Schreiben üben**, **Zurück zum Lernset**.
- If everything in scope is already mastered at start → friendly screen with "Fortschritt
  zurücksetzen und neu lernen" and "Schreiben üben".
- Options modal: "Antworten auf" (same as Write), **Fragetypen** (Multiple Choice / Schriftlich
  toggles, at least one on), **Begriffe pro Runde** (5 | 7 | 10 | 15), Vorlesen, "Richtige Antwort
  abtippen" (learn.retype), the 7 tolerance toggles. Stored per set in `studyOptions.learn` + shared fields.
- Resume: Learn state saved after every answer (`db.saveLearn/getLearn/clearLearn`, key
  `learn:<setId>`); returning resumes ("Willkommen zurück"). `?new=1` forces a new session;
  `?subset=starred` scope.
- Keyboard: 1–4 choose, Enter submit/continue, Esc closes modals; never one key press → two transitions.

## 5. Integration

- `db.js`: `DEFAULT_STUDY_OPTIONS.learn = { roundSize: 7, mc: true, written: true, retype: false }`;
  `getLearn(setId) / saveLearn(setId, state) / clearLearn(setId)`; clear on deleteSet/resetProgress and
  when cards are added/removed (like Write sessions); export/import unaffected.
- Router: `/set/:id/learn` → `src/screens/learn.js`.
- Set page: primary big **Lernen** button ("Multiple Choice & schriftlich, bis alles sitzt"), or
  **Weiterlernen · Runde 3 · 18/52 gemeistert** when a Learn session is in progress; **Schreiben**
  becomes a secondary button; starred / not-mastered shortcuts apply to Lernen.
- Dashboard: quick action becomes **Lernen** / **Weiterlernen**; "Weiterlernen" card prefers an
  in-progress Learn session.
- `index.html` links `styles/screens/learn.css`; `tests/imports.test.js` covers the new modules.
- `study-options.js`: Learn-specific section (Fragetypen, Begriffe pro Runde, Abtippen) shown when
  rendered for Learn (`mode: 'learn'`) and in Settings.

## 6. Mac app: Wiederholungsfragen (repetition questions)

Added 2026-10-13 at the user's request ("ein toggle für den lern mode das es repitionsfragen beinhaltet; wenn man eine repetitionsfrage falsch beantwortet geht es von gemeistert wieder zurück zu am lernen"). Ported to the web app on 2026-10-14 for the Windows app (`src/core/learn.js` `review`, pref `learn.review`, `?review=1`); without it every session stays rng draw for rng draw as before (the parity tests are unchanged).

- Option "Wiederholungsfragen" in the Learn options (⌘K), section "Wiederholung", off by default, for every set (UserDefaults `learn.review`). Like direction, question types and round size it shapes a session: switched during a session, closing the popover asks to restart.
- A session with the option (`LearnState.review`, encoded only when present: `{"due": [ids], "results": {id: bool}}`) asks every card that was mastered when it started once more: the ones answered longest ago first, `max(1, roundSize / 3)` per round mixed in among the round's questions, a whole round of them once nothing is left to learn. They are written questions (multiple choice when written is off) with qid `"<round>.3:<cardId>"` (`LearnEngine.isReviewQuestion`).
- Answers are recorded like any other: a wrong one resets the streak, so the card is "Am Lernen" again (stage 0, asked once more at the end of the round as multiple choice, then learned again until mastered). "Ich hatte recht" keeps it mastered. A card answered wrong elsewhere is learned instead of repeated.
- The session ends when everything is mastered and every repetition question was asked. With the option, a scope that is all mastered starts a session of repetition questions instead of the "Alles gemeistert!" screen; without it that screen offers "Alle wiederholen".
- Screen: a green "↺ Wiederholung" chip next to the prompt's language; after a missed one the feedback pill says "Wieder am Lernen" (VoiceOver too); the finish screen adds "12 gemeisterte Begriffe wiederholt, 2 davon sind wieder am Lernen."
- Core: `LearnReview`, `LearnEngine.reviewStats`, `LearnFlow.Event.reviewChanged/.startReview`, `SettingsChange.review`; tests in `LearnReviewTests`.
