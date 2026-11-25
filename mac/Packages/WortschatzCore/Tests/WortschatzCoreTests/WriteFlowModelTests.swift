import Foundation
import Testing
@testable import WortschatzCore

/// Port of tests/write-model.test.js (Write mode's pure helpers): synonym-aware grading of the main
/// answer, the copy step, resuming a pending "Nicht ganz" screen, re-showing the results of a
/// finished session, the compact time of the results screen and the special-character columns.
/// The CSS and phone-layout checks of that file test the web stylesheet and are not ported.
@Suite("WriteFlow model (write-model.test.js)")
struct WriteFlowModelTests {
    static let TOL = Tolerance.default

    static let SET = VocabSet(
        id: "s1", title: "Personen", termLang: .fr, defLang: .de,
        cards: [
            Card(id: "laid", term: "laid, laide", definition: "hässlich"),
            Card(id: "moche", term: "moche", definition: "hässlich"),
            Card(id: "brave", term: "brave", definition: "lieb"),
            Card(id: "gentil", term: "gentil, gentille", definition: "lieb, nett"),
            Card(id: "chat", term: "le chat", definition: "die Katze"),
            Card(id: "dash", term: "le pluriel", definition: "-"),
        ], createdAt: 0)

    static func card(_ id: String) -> Card { SET.cards.first { $0.id == id }! }

    static func info(_ id: String, _ ask: AskSide = .term, set: VocabSet = SET) -> WriteFlow.Question {
        WriteFlow.questionInfo(
            set: set, card: card(id), question: SessionQuestion(qid: WriteSession.qid(cardId: id, ask: ask), cardId: id, ask: ask))
    }

    static func grade(_ id: String, _ given: String, _ ask: AskSide = .term) -> SynonymGradeResult {
        WriteFlow.gradeQuestion(set: SET, question: info(id, ask), given: given, tolerance: TOL)
    }

    // MARK: - Main answer grading

    @Test("gradeQuestion: the answer of a card with the same prompt counts as correct")
    func synonymCounts() {
        let r = Self.grade("moche", "laide")
        #expect(r.result.correct)
        #expect(!r.result.exact)
        #expect(r.result.notes.contains(.synonym))
        // The feedback shows what the asked card wanted.
        #expect(r.result.expectedDisplay == "moche")
        #expect(r.matchedCard?.id == "laid")
    }

    @Test("gradeQuestion: works in both directions and for overlapping alternatives")
    func bothDirections() {
        #expect(Self.grade("laid", "moche").result.correct)
        #expect(Self.grade("brave", "gentil").result.correct)
        #expect(Self.grade("gentil", "brave").result.correct)
    }

    @Test("gradeQuestion: the asked card wins and unrelated cards never match")
    func askedCardWins() {
        let own = Self.grade("moche", "moche")
        #expect(own.result.correct)
        #expect(own.result.exact)
        #expect(own.matchedCard == nil)
        let wrong = Self.grade("moche", "le chat")
        #expect(!wrong.result.correct)
        #expect(wrong.matchedCard == nil)
    }

    @Test("gradeQuestion: falls back to plain grading when the card is not in the set")
    func orphanFallback() {
        var orphan = Self.info("chat")
        orphan.cardId = "gone"
        let r = WriteFlow.gradeQuestion(set: Self.SET, question: orphan, given: "le chat", tolerance: Self.TOL)
        #expect(r.result.correct)
        #expect(r.matchedCard == nil)
        #expect(WriteFlow.gradeQuestion(set: nil, question: orphan, given: "le chat", tolerance: Self.TOL).result.correct)
    }

    @Test("labels: the synonym note has a German label (Swiss spelling)")
    func synonymLabel() {
        let label = Labels.NOTE_LABELS[.synonym]
        #expect(label?.isEmpty == false)
        #expect(!Labels.NOTE_LABELS.values.contains { $0.contains("ß") })
    }

    // MARK: - Copy step

    @Test("copyAccepted: punctuation-only answers can be copied (no dead end)")
    func punctuationCopy() {
        let dash = Self.info("dash", .definition)
        #expect(dash.expected == "-")
        #expect(WriteFlow.copyAccepted("-", question: dash, tolerance: Self.TOL))
        #expect(WriteFlow.copyAccepted(" - ", question: dash, tolerance: Self.TOL))
        #expect(!WriteFlow.copyAccepted("x", question: dash, tolerance: Self.TOL))
        // The question itself is gradable too.
        #expect(Self.grade("dash", "-", .definition).result.correct)
    }

    @Test("copyAccepted: needs the asked answer, not a synonym, and not an empty field")
    func copyNeedsAskedAnswer() {
        #expect(WriteFlow.copyAccepted("moche", question: Self.info("moche"), tolerance: Self.TOL))
        #expect(!WriteFlow.copyAccepted("laide", question: Self.info("moche"), tolerance: Self.TOL))
        #expect(!WriteFlow.copyAccepted("   ", question: Self.info("moche"), tolerance: Self.TOL))
        #expect(!WriteFlow.copyAccepted(nil, question: Self.info("moche"), tolerance: Self.TOL))
        #expect(!WriteFlow.copyAccepted("moche", question: nil, tolerance: Self.TOL))
    }

    // MARK: - Pending "Nicht ganz"

    static func sessionWithMiss() -> (s: SessionState, missed: String) {
        var s = WriteSession.createSession([card("chat"), card("brave")], answerWith: .term, shuffle: false, now: 1000)
        let missed = WriteSession.current(s)!.qid
        s = WriteSession.answer(s, correct: false, now: 2000)
        return (s, missed)
    }

    typealias Pending = WriteFlow.PendingFeedback

    @Test("pendingFeedback: restores the miss that is still on screen")
    func restoresMiss() {
        let (s, missed) = Self.sessionWithMiss()
        #expect(
            WriteFlow.pendingFeedback(s, Pending(qid: missed, given: "la chatte", dontKnow: false))
                == Pending(qid: missed, given: "la chatte", dontKnow: false))
        #expect(
            WriteFlow.pendingFeedback(s, json: ["qid": .string(missed), "dontKnow": true])
                == Pending(qid: missed, given: "", dontKnow: true))
    }

    @Test("pendingFeedback: survives the engine rebuilding the state (tick, persist round trip)")
    func survivesRoundTrip() throws {
        let (s, missed) = Self.sessionWithMiss()
        let stored = WriteFlow.storedJSON(
            session: WriteSession.tick(s, now: 3000), feedback: Pending(qid: missed, given: "x", dontKnow: false))
        let text = try #require(String(data: try stored.jsonData(), encoding: .utf8))
        let decoded = try #require(WriteFlow.decodeStored(try JSONValue.parse(text)))
        #expect(WriteFlow.pendingFeedback(decoded.session, decoded.feedback) == Pending(qid: missed, given: "x", dontKnow: false))
        #expect(decoded.session == WriteSession.tick(s, now: 3000))
    }

    @Test("pendingFeedback: ignores stale, overridden or malformed records")
    func ignoresStale() throws {
        let (s, missed) = Self.sessionWithMiss()
        #expect(WriteFlow.pendingFeedback(s, json: nil) == nil)
        #expect(WriteFlow.pendingFeedback(s, json: "x") == nil)
        #expect(WriteFlow.pendingFeedback(s, json: ["qid": "nope:t", "given": "x"]) == nil)
        #expect(WriteFlow.pendingFeedback(nil, json: ["qid": .string(missed)]) == nil)
        // "Ich hatte recht" already counted it.
        #expect(WriteFlow.pendingFeedback(WriteSession.override(s, qid: missed, now: 2500), Pending(qid: missed, given: "x")) == nil)
        // The question that is still waiting in the queue is not a pending miss.
        let next = try #require(WriteSession.current(s)).qid
        #expect(WriteFlow.pendingFeedback(s, Pending(qid: next, given: "x")) == nil)
        // Answered correctly: nothing to show.
        let s2 = WriteSession.answer(s, correct: true, now: 3000)
        #expect(WriteFlow.pendingFeedback(s2, Pending(qid: next, given: "x")) == nil)
        // Round closed: the summary (not the feedback) comes next.
        #expect(WriteFlow.pendingFeedback(WriteSession.nextRound(s2, now: 3000), Pending(qid: missed, given: "x")) == nil)
        // A non-string answer is dropped, a huge one capped.
        #expect(WriteFlow.pendingFeedback(s, json: ["qid": .string(missed), "given": 42])?.given == "")
        let huge = WriteFlow.pendingFeedback(s, Pending(qid: missed, given: String(repeating: "a", count: 5000)))
        #expect((huge?.given.utf16.count ?? .max) <= 1000)
    }

    @Test("pendingFeedback: the cap counts UTF-16 units and never splits a character")
    func capKeepsCharacters() {
        let (s, missed) = Self.sessionWithMiss()
        // "a" + 600 emoji: unit 999 is the first half of an emoji, which JS would keep alone.
        let given = "a" + String(repeating: "😀", count: 600)
        let capped = WriteFlow.pendingFeedback(s, Pending(qid: missed, given: given))?.given
        #expect(capped?.utf16.count == 999)
        #expect(capped?.unicodeScalars.last == "😀")
        #expect(WriteFlow.utf16Prefix("abc", 5) == "abc")
        #expect(WriteFlow.utf16Prefix("abc", 2) == "ab")
    }

    // MARK: - Results after a relaunch

    static func finishedSession() -> SessionState {
        let s = WriteSession.createSession([card("chat")], answerWith: .term, shuffle: false, now: 1000)
        return WriteSession.answer(s, correct: true, now: 2000)
    }

    @Test("canShowResults: a finished session is shown again on its own screen")
    func showsResultsAgain() {
        let s = Self.finishedSession()
        #expect(s.finishedAt == 2000)
        #expect(!WriteFlow.canResume(s))
        #expect(WriteFlow.canShowResults(s, marker: s.startedAt))
        #expect(WriteFlow.canShowResults(s, subset: .all, marker: s.startedAt))
        // The round is still open when the relaunch happens during the last "Richtig!".
        #expect(WriteSession.isRoundOver(s))
        #expect(WriteFlow.canShowResults(WriteSession.nextRound(s, now: 2000), marker: s.startedAt))
    }

    @Test("canShowResults: a new visit, forceNew, another subset or a running session start fresh")
    func startsFresh() {
        let s = Self.finishedSession()
        #expect(!WriteFlow.canShowResults(s))
        #expect(!WriteFlow.canShowResults(s, marker: s.startedAt + 1))
        #expect(!WriteFlow.canShowResults(s, forceNew: true, marker: s.startedAt))
        #expect(!WriteFlow.canShowResults(s, subset: .starred, marker: s.startedAt))
        let running = WriteSession.createSession(
            [Self.card("chat"), Self.card("brave")], answerWith: .term, shuffle: true, rng: mulberry32(seed: 3), now: 5)
        #expect(!WriteFlow.canShowResults(running, marker: running.startedAt))
        var empty = s
        empty.order = []
        #expect(!WriteFlow.canShowResults(empty, marker: s.startedAt))
        #expect(!WriteFlow.canShowResults(nil, marker: 0))
        // A card-id subset is never the "same" subset (JS compares objects by identity).
        #expect(!WriteFlow.canResume(running, subset: .cardIds(["chat"])))
        #expect(WriteFlow.canResume(running, subset: .all))
        #expect(!WriteFlow.canResume(running, subset: .starred))
    }

    // MARK: - Compact time tile

    @Test("compactDuration: short clock-style values for the results tile")
    func compactDuration() {
        func cd(_ ms: Double) -> WriteFlow.CompactDuration { WriteFlow.compactDuration(ms) }
        #expect(cd(167_000) == .init(value: "2:47", label: "Zeit (Min.)"))
        #expect(cd(60_000) == .init(value: "1:00", label: "Zeit (Min.)"))
        #expect(cd(42_000) == .init(value: "42 Sek.", label: "Zeit"))
        #expect(cd(0) == .init(value: "0 Sek.", label: "Zeit"))
        #expect(cd(3_767_000) == .init(value: "1:02:47", label: "Zeit (Std.)"))
        #expect(cd(-5) == .init(value: "0 Sek.", label: "Zeit"))
        #expect(cd(.nan) == .init(value: "0 Sek.", label: "Zeit"))
        // Rounds like formatDuration: 59.6 s is a full minute.
        #expect(cd(59_600) == .init(value: "1:00", label: "Zeit (Min.)"))
        #expect(cd(.infinity) == .init(value: "0 Sek.", label: "Zeit"))
    }

    // MARK: - Placeholders

    @Test("questionInfo: a short placeholder for narrow layouts")
    func placeholders() {
        #expect(Self.info("chat").placeholder == "Antwort auf Französisch eingeben")
        #expect(Self.info("chat").placeholderShort == "Auf Französisch …")
        #expect(Self.info("chat", .definition).placeholderShort == "Auf Deutsch …")
        var same = Self.SET
        same.defLang = .fr
        #expect(Self.info("chat", set: same).placeholderShort == "Antwort eingeben")
        #expect(Self.info("chat", set: same).promptLabel == "Definition")
        #expect(Self.info("chat", .definition, set: same).promptLabel == "Begriff")
        #expect(Self.info("chat").promptLabel == "Deutsch")
        #expect(Self.info("chat").prompt == "die Katze")
        #expect(Self.info("chat").expected == "le chat")
        #expect(Self.info("chat").answerLang == .fr)
    }

    // MARK: - Special-character keys

    @Test("charColumns: balanced rows with at most the given keys per row")
    func charColumns() {
        // Up to eight keys stay on one row, more split into balanced rows.
        #expect(WriteFlow.charColumns(6, 8) == 6)
        #expect(WriteFlow.charColumns(8, 8) == 8)
        #expect(WriteFlow.charColumns(9, 8) == 5)
        #expect(WriteFlow.charColumns(15, 8) == 8)
        #expect(WriteFlow.charColumns(17, 8) == 6)
        // The tight layout: French gets three rows of five instead of 7 + 7 + 1.
        #expect(WriteFlow.charColumns(15, 7) == 5)
        #expect(WriteFlow.charColumns(7, 7) == 7)
        // Degenerate input never yields an invalid column count.
        #expect(WriteFlow.charColumns(0, 8) == 1)
        #expect(WriteFlow.charColumns(5, 0) == 1)
        #expect(WriteFlow.charColumns(.nan, 8) == 1)
        #expect(WriteFlow.charColumns(.infinity, 8) == 1)
    }

    // MARK: - Helpers of write.js and the views

    @Test("hasText and isUsableCard use JS whitespace")
    func usable() {
        #expect(!WriteFlow.hasText(nil))
        #expect(!WriteFlow.hasText(" \u{00A0}\u{3000}\n"))
        #expect(WriteFlow.hasText("\u{0085}")) // NEL is not whitespace in JS
        #expect(WriteFlow.isUsableCard(Card(id: "a", term: "x", definition: "y")))
        #expect(!WriteFlow.isUsableCard(Card(id: "a", term: "x", definition: " ")))
        #expect(!WriteFlow.isUsableCard(nil))
    }

    @Test("hasAnswers: a closed round or an answer of the current one")
    func hasAnswers() {
        let fresh = WriteSession.createSession([Self.card("chat"), Self.card("brave")], answerWith: .term, shuffle: false, now: 1)
        #expect(!WriteFlow.hasAnswers(fresh))
        let answered = WriteSession.answer(fresh, correct: false, now: 2)
        #expect(WriteFlow.hasAnswers(answered))
        let closed = WriteSession.nextRound(WriteSession.answer(answered, correct: true, now: 3), now: 4)
        #expect(closed.roundAnswered.isEmpty)
        #expect(WriteFlow.hasAnswers(closed))
    }

    @Test("stored form: the session JSON plus the open miss under `feedback`")
    func storedForm() throws {
        let (s, missed) = Self.sessionWithMiss()
        let plain = WriteFlow.storedJSON(session: s, feedback: nil)
        #expect(plain == (try JSONValue(encoding: s)))
        #expect(plain["feedback"] == nil)
        let withMiss = WriteFlow.storedJSON(session: s, feedback: Pending(qid: missed, given: "x", dontKnow: true))
        #expect(withMiss["feedback"] == ["qid": .string(missed), "given": "x", "dontKnow": true])
        #expect(WriteSession.copyState(withMiss) == s)
        #expect(WriteFlow.decodeStored(nil) == nil)
        #expect(WriteFlow.decodeStored("x") == nil)
        #expect(WriteFlow.decodeStored(withMiss)?.feedback == Pending(qid: missed, given: "x", dontKnow: true))
        // The record decodes leniently and encodes key for key.
        let decoded = try JSONValue.object(["qid": "a:t", "given": 5, "dontKnow": "yes"]).decode(as: Pending.self)
        #expect(decoded == Pending(qid: "a:t", given: "", dontKnow: false))
        #expect(try JSONValue(encoding: decoded) == decoded.json)
        #expect(throws: (any Error).self) { try JSONValue.object(["given": "x"]).decode(as: Pending.self) }
    }

    @Test("answer diff: near misses get segments, different words plain text")
    func answerDiff() {
        let near = WriteFlow.answerDiff(given: "le monsieu", expected: "le monsieur, messieurs", lang: .fr)
        // Compared with the closest alternative, only the missing "r" is marked.
        #expect(near == [DiffSegment(type: .same, text: "le monsieu"), DiffSegment(type: .add, text: "r")])
        #expect(WriteFlow.answerDiff(given: "voll daneben", expected: "le chat", lang: .fr) == nil)
        #expect(WriteFlow.answerDiff(given: "   ", expected: "le chat", lang: .fr) == nil)
        #expect(WriteFlow.closestDiff(given: "", expected: "x", lang: nil) == [DiffSegment(type: .add, text: "x")])
    }

    @Test("view texts: round summary, results and empty states (Swiss spelling)")
    func viewTexts() {
        let one = WriteSession.RoundSummary(round: 1, total: 5, correct: 4, incorrect: 1, items: [])
        let three = WriteSession.RoundSummary(round: 2, total: 3, correct: 0, incorrect: 3, items: [])
        #expect(WriteFlow.summaryText(one) == "In Runde 2 übst du nur den Begriff, der noch nicht sass.")
        #expect(WriteFlow.summaryText(three) == "In Runde 3 übst du nur die 3 Begriffe, die noch nicht sassen.")
        #expect(WriteFlow.summaryEyebrow(one) == "Runde 1 geschafft")
        #expect(WriteFlow.summaryRatio(one) == 0.8)
        #expect(WriteFlow.summaryRatio(.init(round: 1, total: 0, correct: 0, incorrect: 0, items: [])) == 0)
        #expect(WriteFlow.summaryTitle(ratio: 0.95) == "Hervorragend!")
        #expect(WriteFlow.summaryTitle(ratio: 0.9) == "Hervorragend!")
        #expect(WriteFlow.summaryTitle(ratio: 0.7) == "Gut gemacht!")
        #expect(WriteFlow.summaryTitle(ratio: 0.4) == "Weiter so!")
        #expect(WriteFlow.summaryTitle(ratio: 0.39) == "Dranbleiben – das wird!")

        #expect(WriteFlow.resultsSubtitle(cardCount: 1, accuracy: 1, bothDirections: false) == "Beim ersten Versuch richtig – perfekt!")
        #expect(WriteFlow.resultsSubtitle(cardCount: 1, accuracy: 0.5, bothDirections: true) == "Du hast den Begriff in beide Richtungen richtig geschrieben.")
        #expect(WriteFlow.resultsSubtitle(cardCount: 52, accuracy: 1, bothDirections: false) == "Alle 52 Begriffe beim ersten Versuch richtig – perfekt!")
        #expect(WriteFlow.resultsSubtitle(cardCount: 52, accuracy: 0.96, bothDirections: true) == "Du hast alle 52 Begriffe in beide Richtungen richtig geschrieben.")
        #expect(WriteFlow.percentText(0.9615) == "96 %")
        #expect(WriteFlow.percentText(1.5) == "100 %")
        #expect(WriteFlow.percentText(.nan) == "0 %")

        #expect(WriteFlow.emptyMessage(for: .starred).title == "Keine markierten Begriffe")
        #expect(WriteFlow.emptyMessage(for: .learning).title == "Alles gemeistert!")
        #expect(WriteFlow.emptyMessage(for: .missed).title == "Keine falschen Begriffe")
        #expect(WriteFlow.emptyMessage(for: .cardIds(["x"])).title == "Keine falschen Begriffe")
        #expect(WriteFlow.emptyMessage(for: .all).primaryOpensEditor)
        #expect(WriteFlow.emptyMessage(for: .all).primaryLabel == "Begriffe hinzufügen")
        #expect(WriteFlow.missingMessage.primaryLabel == "Zur Übersicht")

        let (term, definition) = WriteFlow.editorLabels(termLang: .fr, defLang: .other)
        #expect(term == "Begriff · Französisch")
        #expect(definition == "Definition")
        let errors = WriteFlow.editorErrors(term: " ", definition: "x")
        #expect(errors.term == "Bitte gib den Begriff ein.")
        #expect(errors.definition == nil)

        var texts = [
            WriteFlow.summaryText(one), WriteFlow.flawlessText, WriteFlow.missingMessage.text,
            WriteFlow.countersAccessibilityLabel(.init(remaining: 1, correct: 2, incorrect: 3, total: 4, round: 2, progress: 0.5)),
        ]
        for subset in [StudySubset.all, .starred, .learning, .missed, .cardIds([])] {
            let m = WriteFlow.emptyMessage(for: subset)
            texts += [m.title, m.text, m.primaryLabel, WriteFlow.subsetDescription(subset)]
        }
        let prompts: [WriteFlow.Prompt] = [
            .restart(resumesTimer: false),
            .replaceRound(wanted: .starred, saved: Self.finishedSession(), feedback: nil),
        ]
        for p in prompts { texts += [p.title, p.message, p.confirmLabel, p.cancelLabel] }
        for t in [WriteFlow.Toast.welcomeBack, .countedAsCorrect, .cardSaved] { texts.append(t.message) }
        #expect(!texts.contains { $0.contains("ß") })
        #expect(prompts[1].message.contains("wenn du jetzt nur die markierten Begriffe übst."))
    }
}
