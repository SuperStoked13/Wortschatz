import Foundation
import Testing
import WortschatzCore

/// Port of tests/learn-model.test.js (the Learn screen's pure helpers, src/screens/learn-model.js)
/// plus the parts of write-model.js the Learn screen uses (question texts, grading, copy step).
@Suite("LearnFlow model (learn-model.test.js)")
struct LearnFlowModelTests {
    static let T0: Double = 1_760_000_000_000
    var T0: Double { Self.T0 }

    static func makeCards(_ n: Int) -> [Card] {
        (0..<n).map { i in
            Card(id: "c\(i + 1)", term: "terme \(i + 1)", definition: "Begriff \(i + 1)", starred: i % 2 == 0)
        }
    }

    static func create(_ cards: [Card], seed: Int, subset: StudySubset = .all, progress: ProgressMap = [:]) -> LearnState {
        LearnEngine.createLearn(cards, options: .default, subset: subset, progress: progress, rng: mulberry32(seed: seed), now: T0)
    }

    /// A session whose first question (multiple choice) was answered wrong.
    static func missedMc() -> (s: LearnState, q: LearnEngine.Question, feedback: JSONValue, chosen: String) {
        let cards = makeCards(6)
        var s = create(cards, seed: 7)
        let q = LearnEngine.current(s)!
        s = LearnEngine.answer(s, correct: false, now: T0 + 1000)
        let wrong = q.choices!.first { $0.cardId != q.cardId }!
        let feedback: JSONValue = [
            "qid": .string(q.qid), "cardId": .string(q.cardId), "type": "mc", "ask": .string(q.ask.rawValue),
            "choices": try! JSONValue(encoding: q.choices!), "chosen": .string(wrong.cardId),
        ]
        return (s, q, feedback, wrong.cardId)
    }

    /// A session whose first written question was answered wrong.
    static func missedWritten() -> (s: LearnState, q: LearnEngine.Question, feedback: JSONValue) {
        let cards = makeCards(4)
        var progress: ProgressMap = [:]
        for c in cards {
            progress[c.id] = CardProgress(correct: 1, streak: 1, lastResult: .correct, lastAnsweredAt: T0)
        }
        var s = create(cards, seed: 3, progress: progress)
        let q = LearnEngine.current(s)!
        s = LearnEngine.answer(s, correct: false, now: T0 + 1000)
        let feedback: JSONValue = [
            "qid": .string(q.qid), "cardId": .string(q.cardId), "type": "written", "ask": .string(q.ask.rawValue),
            "given": "terme 9", "dontKnow": false,
        ]
        return (s, q, feedback)
    }

    static func with(_ json: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
        var o = json.objectValue ?? [:]
        o[key] = value
        return .object(o)
    }

    // MARK: - Praise

    @Test func praiseIsVariedNeverTheSameTwiceInARow() {
        let rng = mulberry32(seed: 11)
        var prev: String?
        var seen = Set<String>()
        for _ in 0..<200 {
            let p = LearnFlow.pickPraise(prev, rng: rng)
            #expect(LearnFlow.PRAISE.contains(p))
            #expect(p != prev)
            seen.insert(p)
            prev = p
        }
        #expect(seen.count == LearnFlow.PRAISE.count)
        #expect(LearnFlow.PRAISE == ["Super!", "Klasse!", "Genau!", "Weiter so!", "Stark!"])
    }

    @Test func praiseToleratesAMisbehavingRngAndAOneItemPool() {
        #expect(LearnFlow.PRAISE.contains(LearnFlow.pickPraise(nil, rng: { 7 })))
        #expect(LearnFlow.PRAISE.contains(LearnFlow.pickPraise(nil, rng: { -3 })))
        #expect(LearnFlow.PRAISE.contains(LearnFlow.pickPraise(nil, rng: { .nan })))
        #expect(LearnFlow.pickPraise("Top!", pool: ["Top!"]) == "Top!")
        #expect(LearnFlow.PRAISE.contains(LearnFlow.pickPraise(nil, pool: [])))
    }

    // MARK: - Resume

    @Test func canResumeLearnRunningSessionsResumeOthersDoNot() {
        let s = Self.create(Self.makeCards(5), seed: 1)
        #expect(LearnFlow.canResumeLearn(s))
        #expect(LearnFlow.canResumeLearn(s, subset: .all))
        #expect(!LearnFlow.canResumeLearn(s, subset: .starred))
        #expect(!LearnFlow.canResumeLearn(s, forceNew: true))
        #expect(!LearnFlow.canResumeLearn(nil))
        #expect(!LearnFlow.canResumeLearn(LearnEngine.copyState(["order": []])))
        var finished = s
        finished.finishedAt = T0
        #expect(!LearnFlow.canResumeLearn(finished))
        // Everything mastered (but not stamped yet) is not resumable either.
        var mastered = s
        for id in s.order { mastered.stage[id] = 2 }
        #expect(!LearnFlow.canResumeLearn(mastered))
    }

    @Test func hasLearnAnswersInThisRoundOrEarlierRounds() {
        let s = Self.create(Self.makeCards(5), seed: 1)
        #expect(!LearnFlow.hasLearnAnswers(s))
        #expect(LearnFlow.hasLearnAnswers(LearnEngine.answer(s, correct: true, now: T0 + 10)))
        #expect(LearnFlow.hasLearnAnswers(LearnEngine.copyState(["rounds": [["round": 1]]])))
        #expect(!LearnFlow.hasLearnAnswers(nil))
    }

    // MARK: - Pending feedback

    @Test func pendingFeedbackAMissedMcQuestionComesBackWithItsOptions() {
        let (s, q, feedback, chosen) = Self.missedMc()
        let p = LearnFlow.pendingFeedback(s, feedback)
        #expect(p == LearnFlow.PendingFeedback(mcQid: q.qid, cardId: q.cardId, ask: q.ask, choices: q.choices!, chosen: chosen))
        // "Weiss ich nicht?" has no chosen option.
        #expect(LearnFlow.pendingFeedback(s, Self.with(feedback, "chosen", nil))?.chosen == nil)
        #expect(LearnFlow.pendingFeedback(s, Self.with(feedback, "chosen", nil)) != nil)
    }

    @Test func pendingFeedbackAMissedWrittenQuestionKeepsWhatWasTyped() {
        let (s, q, feedback) = Self.missedWritten()
        #expect(q.type == .written)
        #expect(
            LearnFlow.pendingFeedback(s, feedback)
                == LearnFlow.PendingFeedback(writtenQid: q.qid, cardId: q.cardId, ask: q.ask, given: "terme 9", dontKnow: false))
        #expect(LearnFlow.pendingFeedback(s, Self.with(feedback, "given", "   "))?.dontKnow == true)
        let long = String(repeating: "x", count: 5000)
        #expect(LearnFlow.pendingFeedback(s, Self.with(feedback, "given", .string(long)))?.given?.utf16.count == 1000)
        // A split surrogate pair at the cut is dropped (JSON cannot keep a lone surrogate).
        let emoji = String(repeating: "x", count: 999) + "😀"
        #expect(LearnFlow.pendingFeedback(s, Self.with(feedback, "given", .string(emoji)))?.given?.utf16.count == 999)
    }

    @Test func pendingFeedbackInvalidOnceOverriddenAfterTheRoundOrForAnotherQuestion() {
        let (s, _, feedback, _) = Self.missedMc()
        #expect(LearnFlow.pendingFeedback(LearnEngine.override(s, now: T0 + 2000), feedback) == nil)
        #expect(LearnFlow.pendingFeedback(s, Self.with(feedback, "qid", "other")) == nil)
        #expect(LearnFlow.pendingFeedback(s, Self.with(feedback, "type", "written")) == nil)
        #expect(LearnFlow.pendingFeedback(s, Self.with(feedback, "cardId", "c99")) == nil)
        #expect(LearnFlow.pendingFeedback(s, nil as JSONValue?) == nil)
        #expect(LearnFlow.pendingFeedback(s, JSONValue.null) == nil)
        // The chosen option must be a wrong one, and the options must contain the card.
        #expect(LearnFlow.pendingFeedback(s, Self.with(feedback, "chosen", feedback["cardId"]!)) == nil)
        #expect(LearnFlow.pendingFeedback(s, Self.with(feedback, "chosen", "nope")) == nil)
        let cardId = feedback["cardId"]!
        let others = JSONValue.array((feedback["choices"]?.arrayValue ?? []).filter { $0["cardId"] != cardId })
        #expect(LearnFlow.pendingFeedback(s, Self.with(feedback, "choices", others)) == nil)
        // A later correct answer replaces `last`.
        var t = s
        while LearnEngine.current(t) != nil { t = LearnEngine.answer(t, correct: true, now: T0 + 3000) }
        #expect(LearnFlow.pendingFeedback(t, feedback) == nil)
        // nextRound clears `last`.
        let n = LearnEngine.nextRound(t, cards: Self.makeCards(6), rng: mulberry32(seed: 2), now: T0 + 4000)
        #expect(LearnFlow.pendingFeedback(n, feedback) == nil)
    }

    @Test func pendingFeedbackTypedRecordsRoundTripThroughJSON() throws {
        let (s, q, feedback, chosen) = Self.missedMc()
        let typed = LearnFlow.PendingFeedback(mcQid: q.qid, cardId: q.cardId, ask: q.ask, choices: q.choices!, chosen: chosen)
        #expect(JSONValue.identical(try JSONValue(encoding: typed), feedback))
        #expect(LearnFlow.pendingFeedback(s, typed) == typed)
        let dontKnow = LearnFlow.PendingFeedback(mcQid: q.qid, cardId: q.cardId, ask: q.ask, choices: q.choices!, chosen: nil)
        #expect(try JSONValue(encoding: dontKnow)["chosen"] == .null)
        let (ws, wq, wfeedback) = Self.missedWritten()
        let written = LearnFlow.PendingFeedback(writtenQid: wq.qid, cardId: wq.cardId, ask: wq.ask, given: "terme 9", dontKnow: false)
        #expect(JSONValue.identical(try JSONValue(encoding: written), wfeedback))
        #expect(LearnFlow.pendingFeedback(ws, written) == written)
    }

    @Test func savedLearnKeepsTheFeedbackNextToTheState() throws {
        let (s, _, feedback, _) = Self.missedMc()
        let saved = LearnFlow.SavedLearn(state: s, feedbackJSON: feedback)
        let json = try saved.json()
        #expect(json["feedback"] == feedback)
        let back = try #require(LearnFlow.SavedLearn(json: json))
        #expect(back.state == s)
        #expect(back.feedback == feedback)
        #expect(LearnFlow.SavedLearn(json: "kaputt") == nil)
        #expect(try LearnFlow.SavedLearn(state: s).json()["feedback"] == nil)
    }

    // MARK: - Option texts

    @Test func choiceTextsShowTheCurrentCardTextsAndKeepStoredTextsOfDeletedCards() {
        let cards = [
            Card(id: "a", term: "le nom de famille", definition: "der Nachname"),
            Card(id: "b", term: "  la rue ", definition: "die Strasse"),
        ]
        let choices = [
            Choice(cardId: "a", text: "le nom"), Choice(cardId: "b", text: "la rue"), Choice(cardId: "gone", text: "l'enfant"),
        ]
        #expect(
            LearnFlow.choiceTexts(choices, cards: cards, ask: .term) == [
                Choice(cardId: "a", text: "le nom de famille"), Choice(cardId: "b", text: "la rue"),
                Choice(cardId: "gone", text: "l'enfant"),
            ])
        #expect(LearnFlow.choiceTexts(choices, cards: cards, ask: .definition).map(\.text) == ["der Nachname", "die Strasse", "l'enfant"])
        #expect(LearnFlow.choiceTexts([], cards: cards, ask: .term).isEmpty)
    }

    // MARK: - Checkpoint

    @Test func stageStatusGemeistertAmLernenNochNeu() {
        #expect(LearnFlow.stageStatus(2) == LearnFlow.StageStatus(status: .mastered, label: "Gemeistert", tone: .success, systemImage: "checkmark"))
        #expect(LearnFlow.stageStatus(1).label == "Am Lernen")
        #expect(LearnFlow.stageStatus(1).tone == .warning)
        #expect(LearnFlow.stageStatus(0).label == "Noch neu")
    }

    @Test func checkpointStatusACardAnsweredInTheRoundIsNeverNochNeu() {
        #expect(LearnFlow.checkpointStatus(0) == LearnFlow.stageStatus(1))
        #expect(LearnFlow.checkpointStatus(0).label == "Am Lernen")
        #expect(LearnFlow.checkpointStatus(1).label == "Am Lernen")
        #expect(LearnFlow.checkpointStatus(2).label == "Gemeistert")
        // The rule of the counters: a wrongly answered card (stage 0) is seen, so it is not new.
        let cards = (0..<3).map { Card(id: "k\($0)", term: "t\($0)", definition: "d\($0)") }
        var s = Self.create(cards, seed: 5)
        while !LearnEngine.isRoundOver(s) { s = LearnEngine.answer(s, correct: false, now: T0 + 1000) }
        let cp = LearnEngine.checkpoint(s)
        #expect(cp.counts.fresh == 0)
        #expect(cp.items.allSatisfy { $0.stage == 0 && LearnFlow.checkpointStatus($0.stage).status == .learning })
    }

    @Test func finishAndRestartTextsNameTheScope() {
        #expect(LearnFlow.finishTitle(.all, total: 52) == "Du hast alle Begriffe gemeistert!")
        #expect(LearnFlow.finishTitle(.starred, total: 3) == "Du hast alle markierten Begriffe gemeistert!")
        #expect(LearnFlow.finishTitle(.starred, total: 1) == "Du hast den markierten Begriff gemeistert!")
        #expect(LearnFlow.finishTitle(.learning, total: 5) == "Du hast alle offenen Begriffe gemeistert!")
        #expect(LearnFlow.finishTitle(.missed, total: 2) == "Du hast alle falsch beantworteten Begriffe gemeistert!")
        #expect(LearnFlow.finishTitle(.cardIds(["a", "b"]), total: 2) == "Du hast alle ausgewählten Begriffe gemeistert!")
        #expect(LearnFlow.finishTitle(.all, total: 1) == "Du hast den Begriff gemeistert!")
        #expect(LearnFlow.finishSubtitle(total: 3, rounds: 3, subset: .starred) == "Alle 3 markierten Begriffe in 3 Runden gemeistert – stark!")
        #expect(LearnFlow.finishSubtitle(total: 1, rounds: 2, subset: .starred) == "Den markierten Begriff in 2 Runden gemeistert – stark!")
        // Cards mastered before the session started are not counted as learned in it.
        #expect(LearnFlow.finishSubtitle(total: 50, rounds: 16, alreadyMastered: 6) == "44 Begriffe in 16 Runden gemeistert, 6 sassen schon vorher – stark!")
        #expect(LearnFlow.finishSubtitle(total: 3, rounds: 3, alreadyMastered: 1, subset: .starred) == "2 Begriffe in 3 Runden gemeistert, 1 sass schon vorher – stark!")
        #expect(LearnFlow.finishSubtitle(total: 2, rounds: 1, alreadyMastered: 1) == "1 Begriff in 1 Runde gemeistert, 1 sass schon vorher – stark!")
        // Mastered elsewhere before any Learn round was closed: no "in 0 Runden".
        #expect(LearnFlow.finishSubtitle(total: 4, rounds: 0) == "Alle 4 Begriffe gemeistert – stark!")
        #expect(
            LearnFlow.restartSessionMessage(.all)
                == "Du beginnst eine neue Lerneinheit mit allen Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert.")
        #expect(LearnFlow.restartSessionMessage(.learning) == LearnFlow.restartSessionMessage(.all))
        #expect(
            LearnFlow.restartSessionMessage(.starred)
                == "Du beginnst eine neue Lerneinheit mit allen markierten Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert.")
        #expect(
            LearnFlow.restartSessionMessage(.missed)
                == "Du beginnst eine neue Lerneinheit mit allen zuletzt falsch beantworteten Begriffen. Dein Lernfortschritt bleibt gespeichert.")
        #expect(
            LearnFlow.restartSessionMessage(.cardIds(["a"]))
                == "Du beginnst eine neue Lerneinheit mit den ausgewählten Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert.")
        // A finished starred session: the stats from the engine feed the texts.
        let cards = (0..<3).map { Card(id: "s\($0)", term: "t\($0)", definition: "d\($0)", starred: true) }
        let progress = ["s0": CardProgress(correct: 2, streak: 2, streakBefore: 1, lastResult: .correct, lastAnsweredAt: T0)]
        var s = Self.create(cards, seed: 9, subset: .starred, progress: progress)
        for i in 0..<20 where !LearnEngine.isFinished(s) {
            if LearnEngine.isRoundOver(s) {
                s = LearnEngine.nextRound(s, cards: cards, rng: mulberry32(seed: i), now: T0 + Double(i) * 1000)
            } else {
                s = LearnEngine.answer(s, correct: true, now: T0 + Double(i) * 1000)
            }
        }
        s = LearnEngine.nextRound(s, cards: cards, rng: mulberry32(seed: 99), now: T0 + 60000)
        let stats = LearnEngine.finalStats(s)
        #expect(stats.alreadyMastered == 1)
        #expect(
            LearnFlow.finishSubtitle(stats, subset: s.subset)
                == "2 Begriffe in \(stats.rounds == 1 ? "1 Runde" : "\(stats.rounds) Runden") gemeistert, 1 sass schon vorher – stark!")
    }

    @Test func checkpointAndFinishTexts() {
        #expect(LearnFlow.masteredLine(18, 52) == "18 von 52 gemeistert")
        #expect(LearnFlow.progressText(fresh: 27, learning: 7, mastered: 18, total: 52) == "18 von 52 gemeistert, 7 am Lernen, 27 neu")
        #expect(LearnFlow.checkpointTitle(1) == "Hervorragend!")
        #expect(LearnFlow.checkpointTitle(0.75) == "Gut gemacht!")
        #expect(LearnFlow.checkpointTitle(0.5) == "Du machst Fortschritte!")
        #expect(LearnFlow.checkpointTitle(0) == "Dranbleiben – das wird!")
        #expect(LearnFlow.remainingText(mastered: 18, total: 52) == "Noch 34 Begriffe, bis alles sitzt.")
        #expect(LearnFlow.remainingText(mastered: 51, total: 52) == "Noch 1 Begriff, bis alles sitzt.")
        #expect(LearnFlow.remainingText(mastered: 52, total: 52) == "Alles sitzt!")
        #expect(LearnFlow.finishSubtitle(total: 52, rounds: 9) == "Alle 52 Begriffe in 9 Runden gemeistert – stark!")
        #expect(LearnFlow.finishSubtitle(total: 1, rounds: 1) == "Den Begriff in 1 Runde gemeistert – stark!")
        #expect(LearnFlow.scopeText(.all, count: 52) == "alle 52 Begriffe")
        #expect(LearnFlow.scopeText(.starred, count: 3) == "alle 3 markierten Begriffe")
        #expect(LearnFlow.scopeText(.starred, count: 1) == "den markierten Begriff")
        #expect(LearnFlow.scopeText(.cardIds(["a"]), count: 1) == "den Begriff")
        let cp = LearnEngine.Checkpoint(
            round: 2, answered: 7, correct: 5, items: [],
            counts: LearnEngine.CheckpointCounts(fresh: 20, learning: 14, mastered: 18, total: 52))
        #expect(LearnFlow.checkpointText(cp) == "5 richtige Antworten von 7 in dieser Runde. Noch 34 Begriffe, bis alles sitzt.")
    }

    // MARK: - Segmented bar

    @Test func segmentCountOnePerRoundSizedBatchAtLeastOneAtMostMax() {
        #expect(LearnFlow.segmentCount(total: 52, roundSize: 7) == 8)
        #expect(LearnFlow.segmentCount(total: 52, roundSize: 15) == 4)
        #expect(LearnFlow.segmentCount(total: 3, roundSize: 7) == 1)
        #expect(LearnFlow.segmentCount(total: 0, roundSize: 7) == 1)
        #expect(LearnFlow.segmentCount(total: 500, roundSize: 5) == LearnFlow.MAX_SEGMENTS)
        #expect(LearnFlow.segmentCount(total: 14, roundSize: nil) == 2)
    }

    @Test func segmentFillsFillTheBarFromTheLeft() {
        typealias F = LearnFlow.SegmentFill
        #expect(
            LearnFlow.segmentFills(mastered: 3, learning: 3, total: 8, count: 4) == [
                F(mastered: 1, reached: 1), F(mastered: 0.5, reached: 1), F(mastered: 0, reached: 1), F(mastered: 0, reached: 0),
            ])
        #expect(LearnFlow.segmentFills(mastered: 0, learning: 0, total: 0, count: 3) == Array(repeating: F(mastered: 0, reached: 0), count: 3))
        #expect(LearnFlow.segmentFills(mastered: 52, learning: 0, total: 52, count: 8).allSatisfy { $0.mastered == 1 && $0.reached == 1 })
        #expect(LearnFlow.segmentFills(mastered: 1, learning: 0, total: 2, count: 0) == [F(mastered: 0.5, reached: 0.5)])
    }

    // MARK: - Questions (write-model.js)

    @Test func questionInfoTextsPerDirection() {
        let card = Card(id: "a", term: "la rue", definition: "die Strasse", starred: true)
        let q = LearnEngine.Question(qid: "1.1:a", cardId: "a", type: .written, ask: .term)
        let info = LearnFlow.questionInfo(q, card: card, cards: [card], termLang: .fr, defLang: .de)
        #expect(info.prompt == "die Strasse")
        #expect(info.expected == "la rue")
        #expect(info.promptLang == .de && info.answerLang == .fr)
        #expect(info.promptLabel == "Deutsch")
        #expect(info.placeholder == "Antwort auf Französisch eingeben")
        #expect(info.placeholderShort == "Auf Französisch …")
        #expect(info.starred)
        #expect(info.choices.isEmpty && info.storedChoices.isEmpty)
        let d = LearnFlow.questionInfo(
            LearnEngine.Question(qid: "1.1:a", cardId: "a", type: .written, ask: .definition), card: card, cards: [card],
            termLang: .fr, defLang: .de)
        #expect(d.prompt == "la rue" && d.expected == "die Strasse" && d.promptLabel == "Französisch")
        let same = LearnFlow.questionInfo(q, card: card, cards: [card], termLang: .de, defLang: .de)
        #expect(same.promptLabel == "Definition")
        #expect(same.placeholder == "Antwort eingeben")
        let other = LearnFlow.questionInfo(q, card: card, cards: [card], termLang: .other, defLang: .other)
        #expect(other.promptLabel == "Definition")
        let mixed = LearnFlow.questionInfo(q, card: card, cards: [card], termLang: .other, defLang: .de)
        #expect(mixed.promptLabel == "Deutsch")
        #expect(mixed.placeholder == "Antwort eingeben")
    }

    @Test func gradeQuestionAcceptsSynonymCardsAndTheCopyStepDoesNot() {
        let cards = [
            Card(id: "laid", term: "laid, laide", definition: "hässlich"),
            Card(id: "moche", term: "moche", definition: "hässlich"),
        ]
        let q = LearnEngine.Question(qid: "1.1:laid", cardId: "laid", type: .written, ask: .term)
        let info = LearnFlow.questionInfo(q, card: cards[0], cards: cards, termLang: .fr, defLang: .de)
        let synonym = LearnFlow.gradeQuestion(info, given: "moche", cards: cards, tolerance: .default)
        #expect(synonym.result.correct)
        #expect(synonym.result.notes.contains(.synonym))
        #expect(synonym.matchedCard?.id == "moche")
        #expect(LearnFlow.gradeQuestion(info, given: "laide", cards: cards, tolerance: .default).result.correct)
        #expect(!LearnFlow.gradeQuestion(info, given: "joli", cards: cards, tolerance: .default).result.correct)
        // A deleted card is graded against the shown answer.
        #expect(LearnFlow.gradeQuestion(info, given: "laid", cards: [], tolerance: .default).result.correct)
        #expect(LearnFlow.copyAccepted("laid, laide", info: info, tolerance: .default))
        #expect(!LearnFlow.copyAccepted("moche", info: info, tolerance: .default))
        #expect(!LearnFlow.copyAccepted("   ", info: info, tolerance: .default))
    }

    // MARK: - Copy rules

    @Test func swissSpellingNoSharpSInAnyLearnText() {
        var texts = LearnFlow.PRAISE + [
            LearnFlow.MISS_TITLE, LearnFlow.DONT_KNOW_TITLE, LearnFlow.SYNONYM_TITLE, LearnFlow.TOLERATED_TITLE,
            LearnFlow.INTRO_HINT, LearnFlow.EDITED_CORRECT_TEXT, LearnFlow.WELCOME_BACK,
            LearnFlow.checkpointTitle(1), LearnFlow.checkpointTitle(0.75), LearnFlow.checkpointTitle(0.5),
            LearnFlow.checkpointTitle(0), LearnFlow.remainingText(mastered: 1, total: 3),
            LearnFlow.finishSubtitle(total: 3, rounds: 2), LearnFlow.finishSubtitle(total: 3, rounds: 2, alreadyMastered: 1),
            LearnFlow.finishSubtitle(total: 3, rounds: 2, alreadyMastered: 2), LearnFlow.scopeText(.starred, count: 2),
            LearnFlow.progressText(fresh: 1, learning: 1, mastered: 1, total: 3),
        ]
        texts += (0...2).map { LearnFlow.stageStatus($0).label }
        for sub: StudySubset in [.all, .starred, .learning, .missed, .cardIds([])] {
            texts += [
                LearnFlow.finishTitle(sub, total: 2), LearnFlow.finishTitle(sub, total: 1), LearnFlow.restartSessionMessage(sub),
                LearnFlow.subsetWhat(sub),
            ]
        }
        #expect(!texts.joined(separator: " ").contains("\u{00DF}"))
    }
}
