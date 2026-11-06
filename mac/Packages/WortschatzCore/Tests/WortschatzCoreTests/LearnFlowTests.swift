import Foundation
import Testing
import WortschatzCore

/// The Learn screen reducer (spec §6): every phase, the Enter-only key map of spec §4.3, "one
/// Return = one transition", auto-advance tokens, persistence and resume, subsets, live changes
/// of cards, progress and options. The `Driver` plays the screen like the app does: it applies
/// the effects to an in-memory store and hands the stored progress back in `Env`.
@Suite("LearnFlow reducer")
struct LearnFlowTests {
    typealias Flow = LearnFlow
    typealias Effect = LearnFlow.Effect
    static let T0: Double = 1_760_000_000_000
    var T0: Double { Self.T0 }

    static func makeCards(_ n: Int) -> [Card] {
        (0..<n).map { i in
            Card(id: "c\(i + 1)", term: "terme \(i + 1)", definition: "Begriff \(i + 1)", starred: i % 3 == 0)
        }
    }

    static func makeSet(_ cards: [Card], termLang: Lang = .fr, defLang: Lang = .de) -> VocabSet {
        VocabSet(id: "set1", title: "Wörter", termLang: termLang, defLang: defLang, cards: cards, createdAt: T0)
    }

    /// Every card familiar (streak 1): questions are written.
    static func familiar(_ cards: [Card]) -> ProgressMap {
        var p: ProgressMap = [:]
        for c in cards { p[c.id] = CardProgress(correct: 1, streak: 1, lastResult: .correct, lastAnsweredAt: T0 - 1000) }
        return p
    }

    static func mastered(_ cards: [Card]) -> ProgressMap {
        var p: ProgressMap = [:]
        for c in cards { p[c.id] = CardProgress(correct: 2, streak: 2, streakBefore: 1, lastResult: .correct, lastAnsweredAt: T0 - 1000) }
        return p
    }

    static func options(retype: Bool = false, roundSize: Int = 7, audio: Bool = false, answerWith: AnswerWith = .term)
        -> StudyOptions
    {
        StudyOptions(answerWith: answerWith, audio: audio, learn: LearnOptions(roundSize: roundSize, retype: retype))
    }

    /// Plays the Learn screen like the app: effects go to an in-memory store (progress, saved
    /// session, cards), timers fire on request, and every event is `ms` after the previous one.
    final class Driver {
        var state: Flow.State
        var log: [Effect] = []
        var last: [Effect] = []
        var progress: ProgressMap
        var saved: Flow.SavedLearn?
        var cards: [Card]
        var now: Double
        let rng: RNG
        var timers: [(token: Int, ms: Int)] = []
        var navigated: [Flow.Destination] = []

        init(
            _ set: VocabSet, progress: ProgressMap = [:], options: StudyOptions = .default, saved: Flow.SavedLearn? = nil,
            subset: StudySubset? = nil, forceNew: Bool = false, seed: Int = 1, now: Double = LearnFlowTests.T0
        ) {
            self.progress = progress
            self.saved = saved
            cards = set.cards
            self.now = now
            rng = mulberry32(seed: seed)
            let (s, effects) = Flow.start(
                set: set, progress: progress, options: options, saved: saved, subset: subset, forceNew: forceNew, rng: rng,
                now: now)
            state = s
            apply(effects)
        }

        @discardableResult
        func send(_ event: Flow.Event, after ms: Double = 1000) -> [Effect] {
            now += ms
            let (s, effects) = Flow.reduce(state, event, env: Flow.Env(rng: rng, now: now, progress: progress))
            state = s
            apply(effects)
            return effects
        }

        @discardableResult
        func press(_ key: KeyInput, isRepeat: Bool = false, after ms: Double = 1000) -> [Effect] {
            send(.key(key, isRepeat: isRepeat), after: ms)
        }

        func type(_ text: String) {
            send(.draftChanged(text), after: 100)
        }

        func apply(_ effects: [Effect]) {
            last = effects
            log += effects
            for effect in effects {
                switch effect {
                case let .recordAnswer(id, correct, at):
                    progress[id] = Mastery.applyAnswer(progress[id], correct: correct, at: at)
                case let .overrideLastAnswer(id):
                    if let p = progress[id], p.lastResult == .incorrect { progress[id] = Mastery.applyOverride(p) }
                case let .resetProgress(ids):
                    if let ids { for id in ids { progress[id] = nil } } else { progress = [:] }
                case let .saveLearn(state, feedback):
                    saved = Flow.SavedLearn(state: state, feedback: feedback)
                case .clearLearn:
                    saved = nil
                case let .scheduleAutoAdvance(ms, token):
                    timers.append((token, ms))
                case let .updateCard(card):
                    if let i = cards.firstIndex(where: { $0.id == card.id }) { cards[i] = card }
                case let .toggleStar(id):
                    if let i = cards.firstIndex(where: { $0.id == id }) { cards[i].starred.toggle() }
                case let .navigate(d):
                    navigated.append(d)
                default:
                    break
                }
            }
        }

        /// Fires the most recent auto-advance timer.
        @discardableResult
        func fireTimer() -> [Effect] {
            guard let t = timers.last else { return [] }
            return send(.autoAdvanceFired(token: t.token), after: Double(t.ms))
        }

        var question: Flow.QuestionInfo? { state.question }
        var correctIndex: Int? { question.flatMap { q in q.choices.firstIndex { $0.cardId == q.cardId } } }
        var wrongIndex: Int? { question.flatMap { q in q.choices.firstIndex { $0.cardId != q.cardId } } }

        /// Answers the question on screen with keys only: a digit for multiple choice, typing and
        /// Return for a written question.
        func answerByKeys(correct: Bool) {
            guard let q = question else { return }
            if q.type == .mc {
                let index = correct ? correctIndex! : wrongIndex!
                press(.digit(index + 1))
            } else {
                type(correct ? q.expected : "ganz falsch")
                press(.returnKey)
            }
        }

        var savedFeedback: JSONValue? { saved?.feedback }
        func announced(_ text: String) -> Bool { last.contains(.announce(text)) }
        var lastAnnouncement: String? {
            last.compactMap { if case let .announce(text) = $0 { text } else { nil } }.last
        }
        var scheduled: [Int] {
            last.compactMap { if case let .scheduleAutoAdvance(_, token) = $0 { token } else { nil } }
        }
    }

    // MARK: - Start

    @Test func startsANewSessionWithAMultipleChoiceQuestion() throws {
        let d = Driver(Self.makeSet(Self.makeCards(6)))
        #expect(d.state.phase == .question(.mc))
        let q = try #require(d.question)
        #expect(q.choices.count == 4)
        #expect(q.promptLabel == "Deutsch")
        #expect(q.prompt.hasPrefix("Begriff "))
        #expect(d.state.session?.order.count == 6)
        #expect(d.saved?.state == d.state.session)
        #expect(d.lastAnnouncement == "Deutsch: \(q.prompt). Wähle die richtige Antwort, 1 bis 4.")
        #expect(Flow.returnAction(d.state) == nil)  // nothing highlighted yet
        #expect(d.state.transitions == 1)
        #expect(d.state.showsIntroHint)
        #expect(d.state.counts.fresh == 6)
        #expect(d.state.segments == 1)
        #expect(!d.log.contains { if case .toast = $0 { true } else { false } })
    }

    @Test func emptySetsAndEmptySubsets() {
        let d = Driver(Self.makeSet([]))
        #expect(d.state.phase == .empty)
        #expect(d.state.session == nil)
        #expect(Flow.message(d.state)?.title == "Noch keine Begriffe zum Üben")
        #expect(Flow.returnAction(d.state) == "Begriffe hinzufügen")
        d.press(.returnKey)
        #expect(d.navigated == [.editSet])

        let cards = Self.makeCards(4).map { Card(id: $0.id, term: $0.term, definition: $0.definition) }
        let s = Driver(Self.makeSet(cards), subset: .starred)
        #expect(s.state.phase == .empty)
        #expect(s.state.subset == .starred)
        #expect(Flow.message(s.state)?.title == "Keine markierten Begriffe")
        #expect(Flow.returnAction(s.state) == "Alle Begriffe üben")
        s.press(.returnKey)
        #expect(s.state.phase == .question(.mc))
        #expect(s.state.session?.subset == .all)

        let missed = Driver(Self.makeSet(cards), subset: .missed)
        #expect(Flow.message(missed.state)?.title == "Keine falschen Begriffe")
        missed.send(.studyAll)
        #expect(missed.state.phase == .question(.mc))
    }

    @Test func everythingMasteredAtStartOffersToRelearn() {
        let cards = Self.makeCards(4)
        let d = Driver(Self.makeSet(cards), progress: Self.mastered(cards))
        #expect(d.state.phase == .allMastered)
        #expect(d.state.session == nil)
        #expect(d.saved == nil)
        #expect(Flow.message(d.state)?.text.contains("alle 4 Begriffe") == true)
        #expect(Flow.returnAction(d.state) == "Fortschritt zurücksetzen und neu lernen")
        d.press(.returnKey)
        #expect(d.state.prompt == .relearn(cardIds: d.state.scopeCardIds))
        #expect(Flow.promptContent(d.state)?.isDestructive == true)
        #expect(Flow.promptContent(d.state)?.message.contains("dieser 4 Begriffe") == true)
        // Keys are ignored while the prompt is open.
        d.press(.returnKey)
        #expect(d.state.prompt != nil)
        d.send(.promptAnswered(confirmed: false))
        #expect(d.state.phase == .allMastered && d.state.prompt == nil)
        d.press(.returnKey)
        d.send(.promptAnswered(confirmed: true))
        #expect(d.last.first == .resetProgress(cardIds: nil))
        #expect(d.progress.isEmpty)
        #expect(d.state.phase == .question(.mc))
        #expect(d.state.counts.fresh == 4)
    }

    @Test func relearnOfASubsetResetsOnlyItsCards() {
        let cards = Self.makeCards(6)  // starred: c1, c4
        let d = Driver(Self.makeSet(cards), progress: Self.mastered(cards), subset: .starred)
        #expect(d.state.phase == .allMastered)
        #expect(Flow.message(d.state)?.text.contains("alle 2 markierten Begriffe") == true)
        let ids = d.state.scopeCardIds
        #expect(ids.sorted() == ["c1", "c4"])
        d.send(.relearn)
        d.send(.promptAnswered(confirmed: true))
        #expect(d.last.first == .resetProgress(cardIds: ids))
        #expect(d.progress["c1"] == nil && d.progress["c4"] == nil)
        #expect(d.progress["c2"] != nil)
        #expect(d.state.session?.order.sorted() == ["c1", "c4"])
        #expect(d.state.session?.subset == .starred)
    }

    // MARK: - Multiple choice

    @Test func arrowsMoveTheHighlightAndReturnChoosesIt() throws {
        let d = Driver(Self.makeSet(Self.makeCards(6)))
        #expect(d.state.highlighted == nil)
        d.press(.arrow(.down))
        #expect(d.state.highlighted == 0)  // the first press lands on option 1
        #expect(d.lastAnnouncement?.hasPrefix("Antwort 1: ") == true)
        d.press(.arrow(.right))
        #expect(d.state.highlighted == 1)
        d.press(.arrow(.right))
        #expect(d.state.highlighted == 1)
        d.press(.arrow(.down))
        #expect(d.state.highlighted == 3)
        d.press(.arrow(.left))
        #expect(d.state.highlighted == 2)
        d.press(.arrow(.up))
        #expect(d.state.highlighted == 0)
        d.press(.arrow(.up))
        #expect(d.state.highlighted == 0)
        #expect(Flow.optionState(d.state, at: 0) == .highlighted)
        #expect(Flow.optionState(d.state, at: 1) == .idle)
        #expect(Flow.returnAction(d.state) == "Auswählen")
        let target = try #require(d.correctIndex)
        if target % 2 == 1 { d.press(.arrow(.right)) }
        if target >= 2 { d.press(.arrow(.down)) }
        #expect(d.state.highlighted == target)
        let transitions = d.state.transitions
        d.press(.returnKey)
        #expect(d.state.phase == .feedback(.correct))
        #expect(d.state.feedback?.chosenIndex == target)
        #expect(d.state.transitions == transitions + 1)
    }

    @Test func arrowsOnThreeOptionsStayInTheGrid() {
        let d = Driver(Self.makeSet(Self.makeCards(3)))
        #expect(d.question?.choices.count == 3)
        d.press(.arrow(.right))
        #expect(d.state.highlighted == 0)
        d.press(.arrow(.right))
        d.press(.arrow(.down))
        #expect(d.state.highlighted == 2)  // from the top right to the lone tile below
        d.press(.arrow(.right))
        #expect(d.state.highlighted == 2)
        d.send(.highlight(1))
        #expect(d.state.highlighted == 1)
        d.send(.highlight(7))
        #expect(d.state.highlighted == nil)
    }

    @Test func returnWithoutAHighlightDoesNothing() {
        let d = Driver(Self.makeSet(Self.makeCards(6)))
        let before = d.state
        d.press(.returnKey)
        #expect(d.state == before)
        #expect(d.last.isEmpty)
    }

    @Test func digitsChooseDirectlyZeroAndOptionReturnAreWeissIchNicht() throws {
        let d = Driver(Self.makeSet(Self.makeCards(6)))
        let before = d.state
        d.press(.digit(9))
        #expect(d.state == before)
        d.press(.digit(5))
        #expect(d.state == before)
        d.press(.digit(try #require(d.correctIndex) + 1))
        #expect(d.state.phase == .feedback(.correct))

        let z = Driver(Self.makeSet(Self.makeCards(6)))
        let q = try #require(z.question)
        z.press(.digit(0))
        #expect(z.state.phase == .feedback(.dontKnow))
        #expect(z.state.feedback?.title == Flow.DONT_KNOW_TITLE)
        #expect(z.state.feedback?.chosenIndex == nil)
        #expect(z.state.pending == Flow.PendingFeedback(mcQid: q.qid, cardId: q.cardId, ask: q.ask, choices: q.storedChoices, chosen: nil))
        #expect(z.last.contains(.recordAnswer(cardId: q.cardId, correct: false, at: z.now)))
        #expect(!z.last.contains(.haptic(.failure)))
        #expect(z.announced("Kein Problem. Richtige Antwort: \(q.expected)."))

        let o = Driver(Self.makeSet(Self.makeCards(6)))
        o.press(.optionReturn)
        #expect(o.state.phase == .feedback(.dontKnow))
        let c = Driver(Self.makeSet(Self.makeCards(6)))
        c.send(.dontKnow)
        #expect(c.state.phase == .feedback(.dontKnow))
    }

    @Test func aCorrectChoicePraisesAndAdvancesByItself() throws {
        let d = Driver(Self.makeSet(Self.makeCards(6)))
        let q = try #require(d.question)
        let index = try #require(d.correctIndex)
        d.press(.digit(index + 1))
        let f = try #require(d.state.feedback)
        #expect(d.state.phase == .feedback(.correct))
        #expect(Flow.PRAISE.contains(f.title))
        #expect(f.autoAdvanceMs == Flow.ADVANCE_MS)
        #expect(d.last.contains(.recordAnswer(cardId: q.cardId, correct: true, at: d.now)))
        #expect(d.last.contains(.haptic(.success)))
        #expect(d.last.contains(.announce(f.title)))
        #expect(d.scheduled == [d.state.autoAdvanceToken!])
        #expect(d.saved?.feedback == nil)
        #expect(Flow.optionState(d.state, at: index) == .correct)
        #expect((0..<4).filter { $0 != index }.allSatisfy { Flow.optionState(d.state, at: $0) == .dimmed })
        #expect(Flow.returnAction(d.state) == "Weiter")
        #expect(d.progress[q.cardId]?.streak == 1)
        let transitions = d.state.transitions
        d.fireTimer()
        #expect(d.state.phase == .question(.mc))
        #expect(d.question?.qid != q.qid)
        #expect(d.state.transitions == transitions + 1)
    }

    @Test func aWrongChoiceShowsTheRightOptionAndWaitsForReturn() throws {
        let d = Driver(Self.makeSet(Self.makeCards(6)))
        let q = try #require(d.question)
        let wrong = try #require(d.wrongIndex)
        d.press(.digit(wrong + 1))
        #expect(d.state.phase == .feedback(.wrong))
        #expect(d.state.feedback?.title == Flow.MISS_TITLE)
        #expect(Flow.optionState(d.state, at: d.correctIndex!) == .correct)
        #expect(Flow.optionState(d.state, at: wrong) == .wrong)
        #expect(d.last.contains(.haptic(.failure)))
        #expect(d.scheduled.isEmpty)
        #expect(d.state.autoAdvanceToken == nil)
        // The open miss is stored next to the session (for a relaunch).
        #expect(d.savedFeedback?["chosen"] == .string(q.choices[wrong].cardId))
        // A Return right after the feedback appeared is swallowed.
        d.press(.returnKey, after: 100)
        #expect(d.state.phase == .feedback(.wrong))
        d.press(.returnKey, after: 500)
        #expect(d.state.phase == .question(.mc))
        #expect(d.question?.qid != q.qid)
        #expect(d.saved?.feedback == nil)
    }

    @Test func anyKeyContinuesAfterMcFeedbackWithoutPickingInTheNextQuestion() throws {
        let d = Driver(Self.makeSet(Self.makeCards(6)))
        d.press(.digit(try #require(d.wrongIndex) + 1))
        let answered = d.state.session?.answered
        d.press(.digit(1))
        #expect(d.state.phase == .question(.mc))
        #expect(d.state.session?.answered == answered)
        d.press(.digit(try #require(d.correctIndex) + 1))
        d.press(.character("x"))
        #expect(d.state.phase == .question(.mc))
        #expect(d.state.draft == "")
    }

    @Test func keyRepeatsNeverTransition() throws {
        let d = Driver(Self.makeSet(Self.makeCards(6)))
        for key: KeyInput in [.returnKey, .digit(1), .digit(0), .optionReturn, .arrow(.down), .character("a")] {
            let before = d.state
            d.press(key, isRepeat: true)
            #expect(d.state == before)
            #expect(d.last.isEmpty)
        }
        d.press(.digit(try #require(d.correctIndex) + 1))
        let before = d.state
        d.press(.returnKey, isRepeat: true)
        #expect(d.state == before)
    }

    @Test func aPressWithinTheLockAfterACorrectAnswerMovesOnWhenTheLockEnds() throws {
        let d = Driver(Self.makeSet(Self.makeCards(6)))
        d.press(.digit(try #require(d.correctIndex) + 1))
        #expect(d.state.phase == .feedback(.correct))
        let qid = d.question?.qid
        let first = try #require(d.state.autoAdvanceToken)
        // The answering press itself (delivered twice) does nothing.
        d.press(.returnKey, after: 10)
        #expect(d.state.autoAdvanceToken == first)
        #expect(d.last.isEmpty)
        // A deliberate second press is kept: the advance moves up to the end of the lock.
        d.press(.returnKey, after: 140)
        #expect(d.state.phase == .feedback(.correct))
        let token = try #require(d.state.autoAdvanceToken)
        #expect(token != first)
        #expect(d.last == [.scheduleAutoAdvance(ms: 130, token: token)])
        // The original timer is stale now; the new one moves on.
        d.send(.autoAdvanceFired(token: first), after: 0)
        #expect(d.state.phase == .feedback(.correct))
        d.send(.autoAdvanceFired(token: token), after: 130)
        #expect(d.question?.qid != qid)
        #expect(d.state.phase != .feedback(.correct))

        // A miss stays on screen for the whole lock.
        let w = Driver(Self.makeSet(Self.makeCards(6)))
        w.press(.digit(try #require(w.wrongIndex) + 1))
        let before = w.state
        w.press(.returnKey, after: 140)
        #expect(w.state == before)
        #expect(w.last.isEmpty)
    }

    @Test func clicksAreNotSwallowedButKeysRightAfterATransitionAre() throws {
        let d = Driver(Self.makeSet(Self.makeCards(6)))
        d.press(.digit(try #require(d.wrongIndex) + 1))
        d.press(.returnKey)
        #expect(d.state.phase == .question(.mc))
        // A digit within the input lock is swallowed; a click on a tile is not.
        let before = d.state
        d.press(.digit(try #require(d.correctIndex) + 1), after: 100)
        #expect(d.state == before)
        d.send(.choose(try #require(d.correctIndex)), after: 10)
        #expect(d.state.phase == .feedback(.correct))
        // Clicks on the primary button respect the lock like Return does.
        d.send(.proceed, after: 50)
        #expect(d.state.phase == .feedback(.correct))
        d.send(.proceed, after: 500)
        #expect(d.state.phase == .question(.mc))
        // Clicking an option during feedback does nothing.
        d.send(.choose(0))
        let feedback = d.state
        #expect(feedback.feedback != nil)
        d.send(.choose(1))
        #expect(d.state == feedback)
    }

    // MARK: - Auto-advance

    @Test func autoAdvanceUsesTokensSoAStaleTimerCannotAdvanceTwice() throws {
        let d = Driver(Self.makeSet(Self.makeCards(6)))
        d.press(.digit(try #require(d.correctIndex) + 1))
        let token = try #require(d.state.autoAdvanceToken)
        // Return before the timer.
        d.press(.returnKey, after: 400)
        #expect(d.state.phase == .question(.mc))
        #expect(d.state.autoAdvanceToken == nil)
        let after = d.state
        d.send(.autoAdvanceFired(token: token), after: 500)
        #expect(d.state == after)
        #expect(d.last.isEmpty)
        // A new answer gets a new token.
        d.press(.digit(try #require(d.correctIndex) + 1))
        #expect(d.state.autoAdvanceToken == token + 1)
    }

    @Test func overlaysPauseTheAutoAdvanceAndRestartItWhenClosed() throws {
        let d = Driver(Self.makeSet(Self.makeCards(6)))
        d.press(.digit(try #require(d.correctIndex) + 1))
        let token = try #require(d.state.autoAdvanceToken)
        d.send(.overlayPresented(.editor), after: 200)
        #expect(d.state.autoAdvanceToken == nil)
        #expect(d.state.autoAdvancePaused)
        d.send(.autoAdvanceFired(token: token))
        #expect(d.state.phase == .feedback(.correct))
        d.press(.returnKey)
        #expect(d.state.phase == .feedback(.correct))
        #expect(Flow.returnAction(d.state) == nil)
        d.send(.overlayDismissed)
        #expect(d.scheduled.count == 1)
        #expect(d.state.autoAdvanceToken == d.scheduled.first)
        d.fireTimer()
        #expect(d.state.phase == .question(.mc))
    }

    // MARK: - Written

    @Test func writtenAnswersAreGradedWithTheTolerance() throws {
        let cards = [
            Card(id: "a", term: "la rue", definition: "die Strasse"),
            Card(id: "b", term: "le chemin", definition: "der Weg"),
        ]
        let d = Driver(Self.makeSet(cards), progress: Self.familiar(cards), subset: .cardIds(["a"]))
        #expect(d.state.phase == .question(.written))
        #expect(Flow.returnAction(d.state) == "Antworten")
        #expect(d.question?.placeholder == "Antwort auf Französisch eingeben")
        d.type("rue")
        d.press(.returnKey)
        let f = try #require(d.state.feedback)
        #expect(d.state.phase == .feedback(.correct))
        #expect(f.title == Flow.TOLERATED_TITLE)
        #expect(f.exactLabel == "Genau:")
        #expect(f.given == "rue")
        #expect(f.result?.notes.contains(.article) == true)
        #expect(f.autoAdvanceMs == Flow.ADVANCE_MS_WITH_NOTES)
        #expect(d.last.contains(.scheduleAutoAdvance(ms: Flow.ADVANCE_MS_WITH_NOTES, token: d.state.autoAdvanceToken!)))
        #expect(d.announced("Richtig! Genau: la rue"))

        let e = Driver(Self.makeSet(cards), progress: Self.familiar(cards), subset: .cardIds(["a"]))
        e.send(.submit("  la rue "))
        #expect(e.state.phase == .feedback(.correct))
        #expect(Flow.PRAISE.contains(e.state.feedback!.title))
        #expect(e.state.feedback?.exactLabel == nil)
        #expect(e.state.feedback?.given == "la rue")
    }

    @Test func anEmptyAnswerIsRejectedWithoutATransition() {
        let cards = Self.makeCards(3)
        let d = Driver(Self.makeSet(cards), progress: Self.familiar(cards))
        let before = d.state
        d.type("   ")
        d.press(.returnKey)
        #expect(d.state.phase == .question(.written))
        #expect(d.state.rejections == before.rejections + 1)
        #expect(d.state.transitions == before.transitions)
        #expect(d.announced("Gib zuerst eine Antwort ein – oder wähle «Weiss ich nicht?»."))
        #expect(!d.last.contains { if case .recordAnswer = $0 { true } else { false } })
    }

    @Test func synonymsCountAsAuchRichtig() throws {
        let cards = [
            Card(id: "laid", term: "laid, laide", definition: "hässlich"),
            Card(id: "moche", term: "moche", definition: "hässlich"),
            Card(id: "calme", term: "calme", definition: "ruhig"),
        ]
        let d = Driver(Self.makeSet(cards), progress: Self.familiar(cards), subset: .cardIds(["laid"]))
        d.type("moche")
        d.press(.returnKey)
        let f = try #require(d.state.feedback)
        #expect(d.state.phase == .feedback(.correct))
        #expect(f.synonym)
        #expect(f.title == Flow.SYNONYM_TITLE)
        #expect(f.exactLabel == "Gesucht war:")
        #expect(d.announced("Auch richtig! Gesucht war: laid, laide"))
    }

    @Test func aWrittenMissOffersIchHatteRecht() throws {
        let cards = [
            Card(id: "a", term: "le chemin", definition: "der Weg"),
            Card(id: "b", term: "la rue", definition: "die Strasse"),
        ]
        let d = Driver(Self.makeSet(cards), progress: Self.familiar(cards), subset: .cardIds(["a"]))
        d.type("la route")
        d.press(.returnKey)
        let f = try #require(d.state.feedback)
        #expect(d.state.phase == .feedback(.wrong))
        #expect(f.canOverride)
        #expect(f.title == Flow.MISS_TITLE)
        #expect(Flow.overrideLabel(d.state) == "Ich hatte recht")
        #expect(d.last.contains(.haptic(.failure)))
        #expect(d.savedFeedback?["given"] == "la route")
        // Characters do not continue after a written miss.
        d.press(.character("x"))
        #expect(d.state.phase == .feedback(.wrong))
        d.press(.commandReturn)
        #expect(d.last.contains(.overrideLastAnswer(cardId: "a")))
        #expect(d.last.contains(.toast("Als richtig gezählt", tone: .success)))
        // The only card was familiar: counted as right it is mastered, which ends the session.
        #expect(d.progress["a"]?.streak == 2)
        #expect(d.state.phase == .finished)
        #expect(d.state.finalStats?.mastered == 1)
        #expect(d.saved?.feedback == nil)
    }

    @Test func weissIchNichtOnAWrittenQuestion() throws {
        let cards = Self.makeCards(3)
        let d = Driver(Self.makeSet(cards), progress: Self.familiar(cards))
        let q = try #require(d.question)
        d.press(.optionReturn)
        #expect(d.state.phase == .feedback(.dontKnow))
        #expect(d.state.feedback?.canOverride == false)
        #expect(Flow.overrideLabel(d.state) == nil)
        #expect(d.state.feedback?.given == "")
        #expect(d.last.contains(.recordAnswer(cardId: q.cardId, correct: false, at: d.now)))
        let before = d.state
        d.press(.commandReturn)
        #expect(d.state == before)
        d.press(.returnKey)
        #expect(d.state.phase == .question(.written) || d.state.phase == .question(.mc))
    }

    @Test func charactersAfterACorrectWrittenAnswerStartTheNextAnswer() throws {
        let cards = Self.makeCards(3)
        let d = Driver(Self.makeSet(cards), progress: Self.familiar(cards))
        d.answerByKeys(correct: true)
        #expect(d.state.phase == .feedback(.correct))
        let transitions = d.state.transitions
        d.press(.character("t"), after: 50)
        #expect(d.state.phase == .question(.written))
        #expect(d.state.draft == "t")
        #expect(d.state.transitions == transitions + 1)
        // After a written miss characters do nothing (Return continues).
        d.type("terme 9")
        d.press(.returnKey)
        #expect(d.state.phase == .feedback(.wrong))
        d.press(.character(" "))
        #expect(d.state.phase == .feedback(.wrong))
    }

    @Test func aSpaceContinuesWithoutTyping() {
        let cards = Self.makeCards(3)
        let d = Driver(Self.makeSet(cards), progress: Self.familiar(cards))
        d.answerByKeys(correct: true)
        d.press(.character(" "))
        #expect(d.state.phase == .question(.written))
        #expect(d.state.draft == "")
    }

    // MARK: - Copy step

    @Test func theCopyStepNeedsTheRightAnswerTypedOnce() throws {
        let cards = [
            Card(id: "a", term: "le chemin", definition: "der Weg"),
            Card(id: "b", term: "la rue", definition: "die Strasse"),
        ]
        let d = Driver(
            Self.makeSet(cards), progress: Self.familiar(cards), options: Self.options(retype: true), subset: .cardIds(["a"]))
        d.type("la route")
        d.press(.returnKey)
        #expect(d.state.phase == .copy)
        #expect(d.state.draft == "")
        #expect(d.state.feedback?.copy == true)
        #expect(Flow.returnAction(d.state) == "Weiter")
        #expect(d.lastAnnouncement?.hasSuffix("Tippe die richtige Antwort ab.") == true)
        d.press(.returnKey)
        #expect(d.state.phase == .copy)
        #expect(d.state.rejections == 1)
        d.type("le chemi")
        d.press(.returnKey)
        #expect(d.state.phase == .copy)
        #expect(d.state.rejections == 2)
        #expect(d.announced("Noch nicht ganz – tippe die richtige Antwort genau ab."))
        d.type("le chemin")
        d.press(.returnKey)
        // No retry at the end of the round any more: the only card comes back in the next round
        // (multiple choice).
        #expect(d.state.phase == .checkpoint)
        d.press(.returnKey)
        #expect(d.state.phase == .question(.mc))
    }

    @Test func ichHatteRechtWorksInTheCopyStep() {
        let cards = [
            Card(id: "a", term: "le chemin", definition: "der Weg"),
            Card(id: "b", term: "la rue", definition: "die Strasse"),
        ]
        let d = Driver(
            Self.makeSet(cards), progress: Self.familiar(cards), options: Self.options(retype: true), subset: .cardIds(["a"]))
        d.type("la route")
        d.press(.returnKey)
        #expect(Flow.overrideLabel(d.state) == "Ich hatte recht")
        d.send(.override)
        #expect(d.state.phase == .finished)
    }

    @Test func togglingTheCopyStepSwitchesAnOpenMiss() {
        let cards = [
            Card(id: "a", term: "le chemin", definition: "der Weg"),
            Card(id: "b", term: "la rue", definition: "die Strasse"),
        ]
        let d = Driver(Self.makeSet(cards), progress: Self.familiar(cards), subset: .cardIds(["a"]))
        d.type("la route")
        d.press(.returnKey)
        #expect(d.state.phase == .feedback(.wrong))
        let transitions = d.state.transitions
        d.send(.optionsChanged(Self.options(retype: true)))
        #expect(d.state.phase == .copy)
        d.send(.optionsChanged(Self.options(retype: false)))
        #expect(d.state.phase == .feedback(.wrong))
        #expect(d.state.transitions == transitions)
    }

    // MARK: - Checkpoint and finish

    @Test func aCheckpointFollowsEachRound() throws {
        let cards = Self.makeCards(3)
        // A round is roundSize questions (3 here: each card once, then the checkpoint).
        let d = Driver(Self.makeSet(cards), options: Self.options(roundSize: 3))
        for _ in 0..<3 {
            d.answerByKeys(correct: true)
            if d.state.phase == .feedback(.correct) && d.state.session.map(LearnEngine.isRoundOver) == false {
                d.press(.returnKey)
            }
        }
        #expect(d.state.phase == .feedback(.correct))
        d.press(.returnKey)
        #expect(d.state.phase == .checkpoint)
        #expect(d.announced("Runde 1 geschafft. 0 von 3 gemeistert."))
        #expect(Flow.returnAction(d.state) == "Weiter zu Runde 2")
        #expect(d.state.checkpoint?.answered == 3)
        #expect(d.state.roundStartCounts?.fresh == 3)
        #expect(Flow.checkpointText(d.state.checkpoint!) == "3 richtige Antworten von 3 in dieser Runde. Noch 3 Begriffe, bis alles sitzt.")
        // Any other key does nothing here.
        let before = d.state
        d.press(.character("x"))
        d.press(.digit(1))
        #expect(d.state == before)
        d.press(.returnKey)
        #expect(d.state.phase == .question(.written))
        #expect(d.state.round == 2)
        #expect(d.saved?.state.round == 2)
        #expect(!d.state.showsIntroHint)
    }

    @Test func escapeLeavesAndKeepsTheStudyTime() throws {
        let d = Driver(Self.makeSet(Self.makeCards(3)))
        d.press(.digit(try #require(d.correctIndex) + 1))
        d.press(.escape, after: 20_000)
        #expect(d.navigated == [.set])
        #expect(d.saved?.state.updatedAt == d.now)
        #expect((d.saved?.state.elapsedMs ?? 0) >= 20_000)
        #expect(d.state.autoAdvanceToken == nil)
    }

    @Test func theFinishScreenCelebratesAndReturnIsFertig() throws {
        let cards = Self.makeCards(2)
        let d = Driver(Self.makeSet(cards), options: Self.options(roundSize: 2))
        var guardCount = 0
        while d.state.phase != .finished && guardCount < 40 {
            guardCount += 1
            switch d.state.phase {
            case .question: d.answerByKeys(correct: true)
            default: d.press(.returnKey)
            }
        }
        #expect(d.state.phase == .finished)
        #expect(d.last.contains(.haptic(.success)))
        #expect(d.announced("Geschafft! Du hast alle Begriffe gemeistert!"))
        let stats = try #require(d.state.finalStats)
        #expect(stats.total == 2 && stats.mastered == 2 && stats.rounds == 2 && stats.accuracy == 1)
        #expect(d.saved?.state.finishedAt != nil)
        #expect(d.saved?.state.rounds.count == 2)
        #expect(Flow.returnAction(d.state) == "Fertig")
        #expect(!d.state.isStudying)
        d.send(.tick)
        #expect(d.last.isEmpty)
        d.press(.returnKey)
        #expect(d.navigated == [.set])
        // ⇧⌘R: "Nochmal lernen" resets the scope's progress after asking.
        d.send(.restart)
        #expect(d.state.prompt == .relearn(cardIds: d.state.session!.order))
        #expect(Flow.promptContent(d.state)?.title == "Fortschritt zurücksetzen?")
        d.send(.promptAnswered(confirmed: true))
        #expect(d.last.first == .resetProgress(cardIds: nil))
        #expect(d.state.phase == .question(.mc))
        #expect(d.state.session?.finishedAt == nil)
    }

    // MARK: - Enter-only operation

    /// Plays with correct answers (keys only) until `done` holds.
    static func play(_ d: Driver, until done: (Flow.Phase) -> Bool) {
        var steps = 0
        while !done(d.state.phase) && steps < 100 {
            steps += 1
            if case .question = d.state.phase { d.answerByKeys(correct: true) } else { d.press(.returnKey) }
        }
    }

    /// Spec §4.3: in every phase Return does the one obvious next step (or nothing, and then
    /// `returnAction` is nil or names a confirmation/navigation), and a second Return right after
    /// a transition does nothing.
    @Test func returnDoesTheOneObviousNextStepInEveryPhase() throws {
        struct Case {
            let name: String
            let make: () -> Driver
            let label: String?
            let transitions: Int
            let after: (Driver) -> Bool
        }
        let six = Self.makeSet(Self.makeCards(6))
        let words = [
            Card(id: "a", term: "le chemin", definition: "der Weg"),
            Card(id: "b", term: "la rue", definition: "die Strasse"),
        ]
        let wordSet = Self.makeSet(words)
        func written(retype: Bool = false) -> Driver {
            Driver(wordSet, progress: Self.familiar(words), options: Self.options(retype: retype), subset: .cardIds(["a"]))
        }
        let cases: [Case] = [
            Case(name: "mc, nothing highlighted", make: { Driver(six) }, label: nil, transitions: 0,
                 after: { $0.state.phase == .question(.mc) }),
            Case(name: "mc, highlighted", make: { let d = Driver(six); d.press(.arrow(.down)); return d },
                 label: "Auswählen", transitions: 1, after: { if case .feedback = $0.state.phase { true } else { false } }),
            Case(name: "written", make: { let d = written(); d.type("le chemin"); return d }, label: "Antworten",
                 transitions: 1, after: { $0.state.phase == .feedback(.correct) }),
            Case(name: "written, empty", make: { written() }, label: "Antworten", transitions: 0,
                 after: { $0.state.phase == .question(.written) && $0.state.rejections == 1 }),
            Case(name: "mc correct", make: { let d = Driver(six); d.answerByKeys(correct: true); return d },
                 label: "Weiter", transitions: 1, after: { $0.state.phase == .question(.mc) }),
            Case(name: "mc wrong", make: { let d = Driver(six); d.answerByKeys(correct: false); return d },
                 label: "Weiter", transitions: 1, after: { $0.state.phase == .question(.mc) }),
            Case(name: "mc don't know", make: { let d = Driver(six); d.press(.digit(0)); return d }, label: "Weiter",
                 transitions: 1, after: { $0.state.phase == .question(.mc) }),
            Case(name: "written correct", make: { let d = written(); d.answerByKeys(correct: true); return d },
                 label: "Weiter", transitions: 1, after: { $0.state.phase == .finished || $0.state.phase == .checkpoint }),
            // The only card of the subset: a miss comes back in the next round, after the checkpoint.
            Case(name: "written wrong", make: { let d = written(); d.answerByKeys(correct: false); return d },
                 label: "Weiter", transitions: 1, after: { $0.state.phase == .checkpoint }),
            Case(name: "copy, empty", make: { let d = written(retype: true); d.answerByKeys(correct: false); return d },
                 label: "Weiter", transitions: 0, after: { $0.state.phase == .copy && $0.state.rejections == 1 }),
            Case(name: "copy, typed", make: {
                    let d = written(retype: true)
                    d.answerByKeys(correct: false)
                    d.type("le chemin")
                    return d
                 }, label: "Weiter", transitions: 1, after: { $0.state.phase == .checkpoint }),
            Case(name: "checkpoint", make: {
                    let d = Driver(Self.makeSet(Self.makeCards(2)), options: Self.options(roundSize: 2))
                    Self.play(d) { $0 == .checkpoint }
                    return d
                 }, label: "Weiter zu Runde 2", transitions: 1, after: { $0.state.phase == .question(.written) }),
            Case(name: "finished", make: {
                    let d = Driver(Self.makeSet(Self.makeCards(2)))
                    Self.play(d) { $0 == .finished }
                    return d
                 }, label: "Fertig", transitions: 0, after: { $0.navigated == [.set] }),
            Case(name: "all mastered", make: { Driver(six, progress: Self.mastered(Self.makeCards(6))) },
                 label: "Fortschritt zurücksetzen und neu lernen", transitions: 0,
                 after: { if case .relearn = $0.state.prompt { true } else { false } }),
            Case(name: "empty set", make: { Driver(Self.makeSet([])) }, label: "Begriffe hinzufügen", transitions: 0,
                 after: { $0.navigated == [.editSet] }),
            Case(name: "empty subset", make: { Driver(Self.makeSet(words), subset: .starred) },
                 label: "Alle Begriffe üben", transitions: 1, after: { $0.state.phase == .question(.mc) }),
        ]
        for c in cases {
            let d = c.make()
            #expect(Flow.returnAction(d.state) == c.label, "\(c.name): label")
            let before = d.state.transitions
            d.press(.returnKey)
            #expect(d.state.transitions - before == c.transitions, "\(c.name): transitions")
            #expect(c.after(d), "\(c.name): result \(d.state.phase)")
            // One Return = one transition: a second press right away does nothing.
            let settled = d.state
            d.press(.returnKey, after: 50)
            #expect(d.state.transitions == settled.transitions, "\(c.name): second Return")
        }
    }

    /// Plays whole sessions with keys only (digits, typing, Return) and checks that every key
    /// press causes at most one transition, and Return on feedback or a checkpoint exactly one.
    @Test(arguments: [1, 2, 3, 4, 5, 6])
    func enterOnlyPlayOneReturnIsOneTransition(seed: Int) throws {
        let cards = Self.makeCards(5 + seed)
        let options = Self.options(retype: seed % 2 == 0, roundSize: 3 + seed % 3, answerWith: seed % 3 == 0 ? .both : .term)
        let d = Driver(Self.makeSet(cards), options: options, seed: seed)
        let decide = mulberry32(seed: seed + 100)
        var steps = 0
        while d.state.phase != .finished {
            steps += 1
            guard steps < 600 else {
                Issue.record("seed \(seed): did not finish")
                return
            }
            let before = d.state.transitions
            let phase = d.state.phase
            switch phase {
            case .question:
                d.answerByKeys(correct: decide() < 0.7)
                #expect(d.state.transitions - before <= 1)
            case .feedback(.wrong) where decide() < 0.2 && d.state.feedback?.canOverride == true:
                d.press(.commandReturn)
                #expect(d.state.transitions - before == 1)
            case .copy:
                if decide() < 0.3 {
                    d.type("nein")
                    d.press(.returnKey)
                    #expect(d.state.transitions == before)
                }
                d.type(d.question!.expected)
                d.press(.returnKey)
                #expect(d.state.transitions - before == 1)
            case .feedback, .checkpoint:
                // A double press: the second one comes within the input lock.
                d.press(.returnKey, after: 400)
                d.press(.returnKey, after: 100)
                #expect(d.state.transitions - before == 1, "phase \(phase)")
            case .allMastered, .empty, .finished:
                Issue.record("unexpected phase \(phase)")
                return
            }
        }
        #expect(d.state.counts.mastered == cards.count)
        #expect(d.saved?.state.finishedAt != nil)
        let saved = try #require(d.saved)
        #expect(LearnEngine.matchesProgress(saved.state, progress: d.progress))
    }

    /// Random key mashing (all keys, repeats, fast and slow presses) never causes two transitions
    /// for one key, and repeats never change anything.
    @Test(arguments: [11, 12, 13, 14])
    func keyMashingNeverCausesTwoTransitions(seed: Int) {
        let cards = Self.makeCards(6)
        let d = Driver(Self.makeSet(cards), options: Self.options(retype: seed % 2 == 0), seed: seed)
        let r = mulberry32(seed: seed)
        let keys: [KeyInput] = [
            .returnKey, .returnKey, .returnKey, .optionReturn, .commandReturn, .digit(0), .digit(1), .digit(2),
            .digit(3), .digit(4), .digit(7), .arrow(.up), .arrow(.down), .arrow(.left), .arrow(.right),
            .character("a"), .character(" "),
        ]
        for _ in 0..<400 {
            if r() < 0.1, case .question(.written) = d.state.phase { d.type(r() < 0.5 ? d.question!.expected : "x") }
            if r() < 0.05, case .copy = d.state.phase { d.type(d.question!.expected) }
            let key = keys[Int(r() * Double(keys.count))]
            let isRepeat = r() < 0.15
            let gap = [30.0, 150, 290, 600, 1200][Int(r() * 5)]
            let before = d.state
            d.press(key, isRepeat: isRepeat, after: gap)
            if isRepeat {
                #expect(d.state == before)
                #expect(d.last.isEmpty)
            }
            #expect(d.state.transitions - before.transitions <= 1)
            if d.now < before.inputLockedUntil, key == .returnKey || key == .optionReturn || key == .commandReturn {
                #expect(d.state.transitions == before.transitions)
            }
            if r() < 0.1, let token = d.state.autoAdvanceToken {
                let t = d.state.transitions
                d.send(.autoAdvanceFired(token: token), after: 900)
                #expect(d.state.transitions - t <= 1)
            }
            if d.state.phase == .finished { break }
        }
    }

    // MARK: - Resume

    @Test func resumesASavedSessionWhereItStopped() throws {
        let set = Self.makeSet(Self.makeCards(6))
        let a = Driver(set)
        a.press(.digit(try #require(a.correctIndex) + 1))
        a.press(.returnKey)
        let qid = a.question?.qid
        let saved = try #require(a.saved)
        let b = Driver(set, progress: a.progress, saved: saved, now: a.now + 3_600_000)
        #expect(b.state.phase == .question(.mc))
        #expect(b.question?.qid == qid)
        #expect(b.question?.choices == a.question?.choices)
        #expect(b.log.contains(.toast(Flow.WELCOME_BACK, tone: .neutral)))
        // Time away is not study time.
        #expect(b.state.session?.updatedAt == b.now)
        #expect(b.state.session?.elapsedMs == a.state.session?.elapsedMs)
    }

    @Test func aRelaunchReopensAnOpenMultipleChoiceMiss() throws {
        let set = Self.makeSet(Self.makeCards(6))
        let a = Driver(set)
        let wrong = try #require(a.wrongIndex)
        a.press(.digit(wrong + 1))
        let saved = try #require(a.saved)
        #expect(saved.feedback != nil)
        let json = try saved.json()
        let b = Driver(set, progress: a.progress, saved: Flow.SavedLearn(json: json))
        #expect(b.state.phase == .feedback(.wrong))
        #expect(b.state.feedback?.chosenIndex == wrong)
        #expect(b.state.feedback?.correctIndex == a.correctIndex)
        #expect(b.question?.qid == a.question?.qid)
        #expect(!b.log.contains(.haptic(.failure)))
        b.press(.returnKey)
        #expect(b.state.phase == .question(.mc))
        #expect(b.saved?.feedback == nil)
    }

    @Test func aRelaunchReopensAnOpenWrittenMissWithTheCopyStep() throws {
        let cards = [
            Card(id: "a", term: "le chemin", definition: "der Weg"),
            Card(id: "b", term: "la rue", definition: "die Strasse"),
        ]
        let set = Self.makeSet(cards)
        let a = Driver(set, progress: Self.familiar(cards), subset: .cardIds(["a"]))
        a.type("la route")
        a.press(.returnKey)
        let b = Driver(set, progress: a.progress, options: Self.options(retype: true), saved: a.saved)
        #expect(b.state.phase == .copy)
        #expect(b.state.feedback?.given == "la route")
        #expect(b.state.feedback?.canOverride == true)
        b.press(.commandReturn)
        #expect(b.state.phase == .finished)
    }

    @Test func resumeBringsInAnswersGivenInWriteMode() throws {
        let cards = Self.makeCards(5)
        let set = Self.makeSet(cards)
        let a = Driver(set)
        a.press(.digit(try #require(a.correctIndex) + 1))
        var progress = a.progress
        let elsewhere = try #require(a.state.session?.queue.first?.cardId)
        progress[elsewhere] = CardProgress(correct: 2, streak: 2, streakBefore: 1, lastResult: .correct, lastAnsweredAt: T0)
        let b = Driver(set, progress: progress, saved: a.saved)
        #expect(b.state.session?.stage[elsewhere] == 2)
        #expect(b.state.session?.queue.contains { $0.cardId == elsewhere } == false)
        #expect(b.saved?.state.stage[elsewhere] == 2)
        #expect(LearnEngine.matchesProgress(b.state.session!, progress: progress))
    }

    @Test func resumeDropsCardsDeletedSinceAndFinishedSessionsStartFresh() throws {
        let cards = Self.makeCards(5)
        let a = Driver(Self.makeSet(cards))
        a.press(.digit(try #require(a.correctIndex) + 1))
        let gone = try #require(a.state.session?.order.last)
        let b = Driver(Self.makeSet(cards.filter { $0.id != gone }), progress: a.progress, saved: a.saved)
        #expect(b.state.session?.order.contains(gone) == false)
        #expect(b.state.session?.order.count == 4)
        #expect(b.saved?.state.order.count == 4)

        var finished = try #require(a.saved)
        finished.state.finishedAt = T0
        let c = Driver(Self.makeSet(cards), progress: Self.mastered(cards), saved: finished)
        #expect(c.state.phase == .allMastered)
        let f = Driver(Self.makeSet(cards), progress: a.progress, saved: a.saved, forceNew: true)
        #expect(f.state.session?.answered == 0)
        #expect(!f.log.contains(.toast(Flow.WELCOME_BACK, tone: .neutral)))
    }

    @Test func aRequestedSubsetAsksBeforeEndingASessionWithAnswers() throws {
        let cards = Self.makeCards(6)  // starred: c1, c4
        let set = Self.makeSet(cards)
        let a = Driver(set)
        a.press(.digit(try #require(a.correctIndex) + 1))
        a.press(.returnKey)
        let b = Driver(set, progress: a.progress, saved: a.saved, subset: .starred)
        #expect(b.state.prompt == .replaceSession(.starred))
        #expect(Flow.promptContent(b.state)?.message.contains("nur die markierten Begriffe") == true)
        #expect(b.state.phase == .question(.mc))
        #expect(Flow.returnAction(b.state) == nil)
        let before = b.state
        b.press(.digit(1))
        #expect(b.state == before)
        b.send(.promptAnswered(confirmed: false))
        #expect(b.state.prompt == nil)
        #expect(b.last.contains(.toast(Flow.WELCOME_BACK, tone: .neutral)))
        #expect(b.state.session?.subset == .all)

        let c = Driver(set, progress: a.progress, saved: a.saved, subset: .starred)
        c.send(.promptAnswered(confirmed: true))
        #expect(c.state.session?.subset == .starred)
        #expect(c.state.session?.order.sorted() == ["c1", "c4"])
        #expect(c.saved?.state.subset == .starred)

        // Without answers there is nothing to lose: no question.
        let fresh = Driver(set)
        let d = Driver(set, saved: fresh.saved, subset: .starred)
        #expect(d.state.prompt == nil)
        #expect(d.state.session?.subset == .starred)
    }

    // MARK: - Options, restart

    @Test func optionsThatShapeTheSessionAskToRestartWhenThePopoverCloses() throws {
        let d = Driver(Self.makeSet(Self.makeCards(10)))
        d.send(.overlayPresented(.options))
        d.press(.returnKey)
        #expect(d.last.isEmpty)
        var changed = StudyOptions.default
        changed.learn.roundSize = 3
        d.send(.optionsChanged(changed))
        #expect(d.state.prompt == nil)
        d.send(.overlayDismissed)
        #expect(d.state.prompt == .restartForOptions([.roundSize]))
        #expect(Flow.promptContent(d.state)?.cancelLabel == "Später")
        let transitions = d.state.transitions
        d.send(.promptAnswered(confirmed: true))
        #expect(d.state.session?.learn.roundSize == 3)
        #expect(d.state.session?.queue.count == 3)
        #expect(d.state.transitions == transitions + 1)

        // Direction and question types need a restart too.
        let g = Driver(Self.makeSet(Self.makeCards(10)))
        g.send(.overlayPresented(.options))
        var both = StudyOptions.default
        both.answerWith = .both
        both.learn.written = false
        g.send(.optionsChanged(both))
        g.send(.overlayDismissed)
        #expect(g.state.prompt == .restartForOptions([.direction, .types]))
        #expect(Flow.promptContent(g.state)?.message.hasPrefix("Die neuen Einstellungen gelten") == true)
        g.send(.promptAnswered(confirmed: true))
        #expect(g.state.session?.answerWith == .both)
        #expect(g.state.session?.learn.written == false)

        // "Später": the session goes on; an unrelated change later does not ask again.
        let e = Driver(Self.makeSet(Self.makeCards(10)))
        let session = e.state.session
        e.send(.overlayPresented(.options))
        e.send(.optionsChanged(changed))
        e.send(.overlayDismissed)
        e.send(.promptAnswered(confirmed: false))
        #expect(e.state.session == session)
        e.send(.overlayPresented(.options))
        var tolerant = changed
        tolerant.tolerance.typos = true
        e.send(.optionsChanged(tolerant))
        e.send(.overlayDismissed)
        #expect(e.state.prompt == nil)
        // Changed and changed back: nothing to ask.
        let f = Driver(Self.makeSet(Self.makeCards(10)))
        f.send(.overlayPresented(.options))
        f.send(.optionsChanged(changed))
        f.send(.optionsChanged(.default))
        f.send(.overlayDismissed)
        #expect(f.state.prompt == nil)
    }

    @Test func theToleranceAppliesAtOnce() {
        let cards = [
            Card(id: "a", term: "bête", definition: "dumm"),
            Card(id: "b", term: "calme", definition: "ruhig"),
        ]
        let d = Driver(Self.makeSet(cards), progress: Self.familiar(cards), subset: .cardIds(["a"]))
        var lenient = StudyOptions.default
        lenient.tolerance.ignoreAccents = true
        d.send(.optionsChanged(lenient))
        d.type("bete")
        d.press(.returnKey)
        #expect(d.state.phase == .feedback(.correct))
        #expect(d.state.feedback?.result?.notes.contains(.accents) == true)
    }

    @Test func restartAsksFirstThenStartsANewSession() throws {
        let d = Driver(Self.makeSet(Self.makeCards(6)))
        d.press(.digit(try #require(d.correctIndex) + 1))
        d.send(.restart)
        #expect(d.state.prompt == .restartSession)
        #expect(d.state.autoAdvanceToken == nil)
        #expect(Flow.promptContent(d.state)?.message == Flow.restartSessionMessage(.all))
        d.send(.promptAnswered(confirmed: false))
        // The countdown the prompt interrupted starts again.
        #expect(d.scheduled.count == 1)
        d.send(.restart)
        d.send(.promptAnswered(confirmed: true))
        // The card answered right before (stage 1) comes first, written; the new ones follow as
        // multiple choice.
        #expect(d.state.phase == .question(.written))
        #expect(d.state.session?.answered == 0)
        #expect(d.state.session?.startedAt == d.now)
        #expect(d.progress.count == 1)  // the progress stays
    }

    // MARK: - Live changes

    @Test func deletingTheCardOnScreenMovesOnToAnotherQuestion() throws {
        let cards = Self.makeCards(8)
        let d = Driver(Self.makeSet(cards))
        let q = try #require(d.question)
        d.send(.cardsChanged(cards.filter { $0.id != q.cardId }))
        #expect(d.state.phase == .question(.mc))
        #expect(d.question?.cardId != q.cardId)
        #expect(d.state.session?.order.contains(q.cardId) == false)
        #expect(d.saved?.state.order.contains(q.cardId) == false)
        // Its options are refilled from the set.
        #expect(d.question?.choices.count == 4)
    }

    @Test func editsElsewhereShowAtOnce() throws {
        var cards = Self.makeCards(6)
        let d = Driver(Self.makeSet(cards))
        let q = try #require(d.question)
        let i = cards.firstIndex { $0.id == q.cardId }!
        cards[i].definition = "Neue Definition"
        let option = q.choices.first { $0.cardId != q.cardId }!
        let j = cards.firstIndex { $0.id == option.cardId }!
        cards[j].term = "nouveau terme"
        d.send(.cardsChanged(cards))
        #expect(d.question?.qid == q.qid)
        #expect(d.question?.prompt == "Neue Definition")
        #expect(d.question?.choices.contains(Choice(cardId: option.cardId, text: "nouveau terme")) == true)
        // Renamed set and languages.
        var set = Self.makeSet(cards, termLang: .en, defLang: .de)
        set.title = "Englisch"
        d.send(.setChanged(set))
        #expect(d.state.setTitle == "Englisch")
    }

    @Test func emptyingTheSetEndsTheSession() {
        let d = Driver(Self.makeSet(Self.makeCards(4)))
        d.send(.cardsChanged([]))
        #expect(d.state.phase == .empty)
        #expect(d.state.session == nil)
        #expect(d.last.contains(.clearLearn))
        #expect(d.saved == nil)
    }

    @Test func aCardDeletedDuringItsFeedbackKeepsTheFeedback() throws {
        let cards = Self.makeCards(6)
        let d = Driver(Self.makeSet(cards))
        let q = try #require(d.question)
        d.press(.digit(try #require(d.wrongIndex) + 1))
        d.send(.cardsChanged(cards.filter { $0.id != q.cardId }))
        #expect(d.state.phase == .feedback(.wrong))
        #expect(d.question?.cardId == q.cardId)
        d.press(.returnKey)
        #expect(d.state.phase == .question(.mc))
        #expect(d.state.session?.order.contains(q.cardId) == false)
    }

    @Test func answersGivenElsewhereMoveTheStages() throws {
        let cards = Self.makeCards(6)
        let d = Driver(Self.makeSet(cards))
        let queued = try #require(d.state.session?.queue.dropFirst().first?.cardId)
        d.progress[queued] = CardProgress(correct: 2, streak: 2, streakBefore: 1, lastResult: .correct, lastAnsweredAt: T0)
        d.send(.progressChanged)
        #expect(d.state.session?.stage[queued] == 2)
        #expect(d.state.session?.queue.contains { $0.cardId == queued } == false)
        #expect(d.saved?.state.stage[queued] == 2)
        #expect(d.state.counts.mastered == 1)
    }

    @Test func editingTheCardCanTurnAMissIntoAnAcceptedAnswer() throws {
        let cards = [
            Card(id: "a", term: "le chemin", definition: "der Weg"),
            Card(id: "b", term: "la rue", definition: "die Strasse"),
        ]
        let d = Driver(Self.makeSet(cards), progress: Self.familiar(cards), subset: .cardIds(["a"]))
        d.type("la route")
        d.press(.returnKey)
        d.send(.overlayPresented(.editor))
        let edited = Card(id: "a", term: "la route", definition: "der Weg")
        d.send(.editCard(edited))
        #expect(d.last.contains(.updateCard(edited)))
        #expect(d.last.contains(.toast("Karte gespeichert", tone: .success)))
        #expect(d.question?.expected == "la route")
        #expect(d.state.feedback?.editedCorrect == true)
        #expect(Flow.overrideLabel(d.state) == "Als richtig zählen")
        d.send(.overlayDismissed)
        d.press(.commandReturn)
        #expect(d.state.phase == .finished)
        #expect(d.cards[0] == edited)
    }

    @Test func starringAndReadingAloud() throws {
        let cards = Self.makeCards(6).map { Card(id: $0.id, term: $0.term, definition: $0.definition) }
        let d = Driver(Self.makeSet(cards), options: Self.options(audio: true))
        let q = try #require(d.question)
        d.send(.toggleStar)
        #expect(d.last == [.toggleStar(cardId: q.cardId)])
        #expect(d.question?.starred == true)
        #expect(d.state.cards.first { $0.id == q.cardId }?.starred == true)
        d.send(.speakPrompt)
        #expect(d.last == [.speak(text: q.prompt, lang: .de)])
        // Audio: the term is read once the answer is known.
        d.press(.digit(try #require(d.correctIndex) + 1))
        let term = cards.first { $0.id == q.cardId }!.term
        #expect(d.last.contains(.speak(text: term, lang: .fr)))

        // Asking the definition, the prompt (the term) is read when the question appears.
        let e = Driver(Self.makeSet(cards), options: Self.options(audio: true, answerWith: .definition))
        let eq = try #require(e.question)
        #expect(e.log.contains(.speak(text: eq.prompt, lang: .fr)))
    }

    @Test func theClockTicksResumesAndStopsWhenFinished() {
        let d = Driver(Self.makeSet(Self.makeCards(4)))
        d.send(.tick, after: 15_000)
        #expect(d.saved?.state.elapsedMs == 15_000)
        d.send(.resume, after: 3_600_000)
        #expect(d.state.session?.updatedAt == d.now)
        #expect(d.last.isEmpty)
        d.send(.tick, after: 10_000)
        #expect(d.saved?.state.elapsedMs == 25_000)
        #expect(d.state.isStudying)
    }

    @Test func savesHappenOncePerEventWithTheFinalState() throws {
        let d = Driver(Self.makeSet(Self.makeCards(4)))
        d.press(.digit(try #require(d.wrongIndex) + 1))
        d.press(.returnKey)
        let saves = d.last.filter { if case .saveLearn = $0 { true } else { false } }
        #expect(saves.count == 1)
        #expect(saves.last == .saveLearn(d.state.session!, feedback: nil))
        #expect(d.last.last == saves.last)
    }

    @Test func theStateIsCodable() throws {
        let d = Driver(Self.makeSet(Self.makeCards(4)))
        d.press(.digit(try #require(d.wrongIndex) + 1))
        let data = try JSONEncoder().encode(d.state)
        let back = try JSONDecoder().decode(Flow.State.self, from: data)
        #expect(back == d.state)
    }
}
