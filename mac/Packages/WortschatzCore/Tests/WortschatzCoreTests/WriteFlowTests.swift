import Foundation
import Testing
@testable import WortschatzCore

/// The Write screen's state machine (src/screens/write.js, write-card.js, write-keys.js) as a
/// reducer: answering, feedback, the copy step, "Ich hatte recht", rounds, results, resuming,
/// dialogs, card edits, live updates and the study clock.
@Suite("WriteFlow (write.js)")
struct WriteFlowTests {
    typealias Effect = WriteFlow.Effect
    typealias Pending = WriteFlow.PendingFeedback

    static func driver(
        _ cards: [Card] = WriteFlowSamples.three(), copy: Bool = false, autoAdvance: Bool = true, audio: Bool = false,
        answerWith: AnswerWith = .term, shuffle: Bool = false, seed: Int = 1, termLang: Lang = .fr, defLang: Lang = .de
    ) -> WriteFlowDriver {
        WriteFlowDriver(
            cards: cards, termLang: termLang, defLang: defLang,
            options: StudyOptionsPatch(
                answerWith: answerWith, shuffle: shuffle, copyAnswer: copy, autoAdvance: autoAdvance, audio: audio),
            seed: seed)
    }

    // MARK: - Start

    @Test("a fresh start asks the first question and stores the session")
    func freshStart() throws {
        let d = Self.driver(WriteFlowSamples.userCards)
        #expect(d.phase == .question)
        let q = try #require(d.question)
        #expect(q.cardId == "u1")
        #expect(q.prompt == "der Herr")
        #expect(q.expected == "le monsieur, messieurs")
        #expect(q.promptLabel == "Deutsch")
        #expect(WriteFlow.fieldPlaceholder(d.state) == "Antwort auf Französisch eingeben")
        #expect(WriteFlow.fieldLabel(d.state) == "Deine Antwort")
        // Only the new session is saved: no announcement (focus moves to the field) and no speech.
        #expect(d.effects == [.saveSession(try #require(d.session), feedback: nil)])
        #expect(d.stored?.session == d.session)
        #expect(WriteFlow.returnAction(d.state) == "Antworten")
        #expect(WriteFlow.returnHint(d.state) == "zum Antworten")
        #expect(WriteFlow.isStudying(d.state))
        #expect(!d.state.animatesQuestion)
        #expect(WriteFlow.counters(d.state)?.remaining == 52)
        #expect(WriteFlow.roundNote(d.state) == nil)
        #expect(d.state.isInputEditable)
    }

    @Test("a missing set shows the message; Return and Esc leave")
    func missingSet() {
        let (state, effects) = WriteFlow.start(set: nil, options: .default, saved: nil, env: .init(now: 1))
        #expect(state.phase == .missing)
        #expect(effects.isEmpty)
        #expect(WriteFlow.returnAction(state) == "Zur Übersicht")
        #expect(WriteFlow.reduce(state, .key(.returnKey), env: .init(now: 2)).1 == [.exit])
        #expect(WriteFlow.reduce(state, .key(.escape), env: .init(now: 2)).1 == [.exit])
        #expect(WriteFlow.reduce(state, .restart, env: .init(now: 2)).1.isEmpty)
        #expect(WriteFlow.reduce(state, .requestOptions, env: .init(now: 2)).0.overlay == nil)
    }

    // MARK: - Answering

    @Test("an empty answer is rejected with a shake and a hint")
    func emptyAnswer() {
        let d = Self.driver()
        #expect(d.press(.returnKey) == [.announce("Gib zuerst eine Antwort ein – oder wähle «Weiss ich nicht».")])
        #expect(d.state.rejections == 1)
        #expect(d.phase == .question)
        d.type(" \u{00A0} ")
        d.press(.returnKey)
        #expect(d.state.rejections == 2)
        #expect(d.progress.isEmpty)
    }

    @Test("a correct answer is recorded, praised and auto-advances")
    func correctAnswer() throws {
        let d = Self.driver()
        let fx = d.answer(" le chat ")
        #expect(d.phase == .feedback(.correct))
        #expect(fx.first == .recordAnswer(cardId: "a", correct: true, at: d.now))
        #expect(fx.contains(.haptic(.success)))
        #expect(fx.contains(.scheduleAutoAdvance(ms: 900, token: 1)))
        #expect(d.saves(fx).count == 1)
        #expect(d.saves(fx).first?.1 == nil)
        let fb = try #require(d.state.feedback)
        #expect(fb.given == "le chat")
        #expect(WriteFlow.praise.contains(fb.title))
        #expect(d.announcements(fx) == [fb.title])
        #expect(!fb.showsExact)
        // The field keeps what was typed (read-only).
        #expect(d.state.input == " le chat ")
        #expect(!d.state.isInputEditable)
        #expect(d.state.autoAdvance == WriteFlow.AutoAdvance(token: 1, ms: 900))
        #expect(WriteFlow.returnHint(d.state) == "Weiter mit beliebiger Taste")
        #expect(WriteFlow.returnAction(d.state) == "Weiter")
        #expect(d.progress["a"]?.correct == 1)
        #expect(d.stored?.session.roundAnswered == [SessionAnswer(qid: "a:t", correct: true)])
    }

    @Test("Return right after a transition never skips a step (one press, one step)")
    func enterLock() throws {
        let d = Self.driver()
        d.answerCorrectly()
        // The answering press delivered twice does nothing.
        #expect(d.press(.returnKey, after: 10).isEmpty)
        #expect(d.phase == .feedback(.correct))
        // 300 ms after the answer the lock is over; the next prompt is announced (focus stayed in the field).
        #expect(d.press(.returnKey, after: 290) == [.announce("Deutsch: der Hund")])
        #expect(d.question?.cardId == "b")
        #expect(d.state.animatesQuestion)
        #expect(d.state.autoAdvance == nil)
    }

    @Test("Return within the lock after a correct answer is not lost: it moves on when the lock ends")
    func skipWithinLock() throws {
        let d = Self.driver()
        d.answerCorrectly()
        let fx = d.press(.returnKey, after: 100)
        #expect(d.phase == .feedback(.correct))
        let advance = try #require(d.state.autoAdvance)
        #expect(advance.ms == 180)
        #expect(fx == [.scheduleAutoAdvance(ms: 180, token: advance.token)])
        d.fireTimer()
        #expect(d.question?.cardId == "b")
        // A miss is never skipped that way.
        d.answer("falsch")
        #expect(d.phase.isMiss)
        #expect(d.press(.returnKey, after: 100).isEmpty)
        #expect(d.state.autoAdvance == nil)
    }

    @Test("a clock set back does not leave Return locked")
    func clockSetBack() {
        let d = Self.driver()
        d.answerCorrectly()
        // The system clock jumps back ten minutes right after the answer.
        #expect(d.press(.returnKey, after: -600_000) == [.announce("Deutsch: der Hund")])
        #expect(d.question?.cardId == "b")
    }

    @Test("auto-advance: a stale timer never advances, the current one advances once")
    func autoAdvanceTokens() {
        let d = Self.driver()
        d.answerCorrectly()
        d.press(.returnKey)
        d.answerCorrectly()
        #expect(d.state.autoAdvance?.token == 2)
        #expect(d.send(.autoAdvanceFired(token: 1)).isEmpty)
        #expect(d.phase == .feedback(.correct))
        d.fireTimer()
        #expect(d.phase == .question)
        #expect(d.question?.cardId == "c")
        // The same timer firing again does nothing.
        #expect(d.send(.autoAdvanceFired(token: 2)).isEmpty)
    }

    @Test("a tolerated answer shows the exact one and waits longer")
    func toleratedAnswer() throws {
        let d = Self.driver(WriteFlowSamples.userCards)
        d.answerCorrectly()
        d.fireTimer()
        #expect(d.question?.expected == "l'homme")
        let fx = d.answer("homme")
        let fb = try #require(d.state.feedback)
        #expect(fb.isCorrect)
        #expect(fb.title == "Richtig!")
        #expect(fb.showsExact)
        #expect(fb.exactLabel == "Genau:")
        #expect(fb.notes.map(\.note) == [.article])
        #expect(fb.notes.first?.label == "Artikel fehlte")
        #expect(d.announcements(fx) == ["Richtig! Genau: l'homme"])
        #expect(fx.contains(.scheduleAutoAdvance(ms: 1800, token: 2)))
    }

    @Test("without auto-advance Return continues")
    func manualContinue() {
        let d = Self.driver(autoAdvance: false)
        let fx = d.answerCorrectly()
        #expect(!fx.contains { if case .scheduleAutoAdvance = $0 { true } else { false } })
        #expect(WriteFlow.returnHint(d.state) == "zum Weitermachen")
        d.press(.returnKey)
        #expect(d.question?.cardId == "b")
    }

    @Test("a synonym is accepted with “Auch richtig!” and the asked word")
    func synonymAnswer() throws {
        let d = Self.driver(WriteFlowSamples.personen)
        #expect(d.question?.cardId == "laid")
        let fx = d.answer("moche")
        let fb = try #require(d.state.feedback)
        #expect(fb.isCorrect && fb.synonym)
        #expect(fb.title == "Auch richtig!")
        #expect(fb.exactLabel == "Gesucht war:")
        #expect(fb.notes.first?.isSynonym == true)
        #expect(d.announcements(fx) == ["Auch richtig! Gesucht war: laid, laide"])
    }

    @Test("praise never repeats twice in a row")
    func praiseVaries() {
        let d = Self.driver(WriteFlowSamples.userCards, autoAdvance: false, seed: 5)
        var last = ""
        var seen = Set<String>()
        for _ in 0..<20 {
            d.answerCorrectly()
            let praise = d.state.feedback?.praise ?? ""
            #expect(WriteFlow.praise.contains(praise))
            #expect(praise != last)
            seen.insert(praise)
            last = praise
            d.press(.returnKey)
        }
        #expect(seen.count > 2)
    }

    // MARK: - Misses

    @Test("a wrong answer shows “Nicht ganz.” and is stored as the open miss")
    func wrongAnswer() throws {
        let d = Self.driver()
        let fx = d.answer("  la chatte ")
        #expect(d.phase == .feedback(.wrong))
        #expect(fx.first == .recordAnswer(cardId: "a", correct: false, at: d.now))
        #expect(fx.contains(.haptic(.failure)))
        let pending = Pending(qid: "a:t", given: "la chatte", dontKnow: false)
        #expect(d.saves(fx).first?.1 == pending)
        #expect(d.stored?.feedback == pending)
        let fb = try #require(d.state.feedback)
        #expect(fb.title == "Nicht ganz.")
        #expect(fb.canOverride && fb.showsGiven)
        #expect(fb.overrideLabel == "Ich hatte recht")
        let hint = fb.hintLabel.map { " \($0)." } ?? ""
        #expect(d.announcements(fx) == ["Nicht ganz. Richtige Antwort: le chat.\(hint)"])
        #expect(WriteFlow.returnAction(d.state) == "Weiter")
        #expect(WriteFlow.returnHint(d.state) == nil)
        // Continuing clears the open miss; the next prompt is not announced (focus was on "Weiter").
        let next = d.press(.returnKey)
        #expect(next == [.saveSession(try #require(d.session), feedback: nil)])
        #expect(d.stored?.feedback == nil)
        #expect(d.question?.cardId == "b")
    }

    @Test("⌥↩ is “Weiss ich nicht”: no haptic, no override")
    func dontKnow() throws {
        let d = Self.driver()
        let fx = d.press(.optionReturn)
        #expect(d.phase == .feedback(.dontKnow))
        #expect(fx.first == .recordAnswer(cardId: "a", correct: false, at: d.now))
        #expect(!fx.contains { if case .haptic = $0 { true } else { false } })
        #expect(d.announcements(fx) == ["Kein Problem. Richtige Antwort: le chat."])
        let fb = try #require(d.state.feedback)
        #expect(fb.title == "Kein Problem – merk dir das:")
        #expect(!fb.canOverride && !fb.showsGiven)
        #expect(d.stored?.feedback == Pending(qid: "a:t", given: "", dontKnow: true))
        #expect(d.press(.commandReturn).isEmpty)
        #expect(d.send(.override).isEmpty)
        // The button does the same as the key.
        let other = Self.driver()
        other.send(.dontKnow)
        #expect(other.phase == .feedback(.dontKnow))
    }

    @Test("the copy step needs the asked answer itself")
    func copyStep() throws {
        let d = Self.driver(WriteFlowSamples.personen, copy: true)
        d.press(.returnKey) // empty: rejected
        #expect(d.question?.cardId == "laid")
        d.answerCorrectly()
        d.send(.proceed) // "Weiter" after a correct answer
        #expect(d.question?.cardId == "moche")
        let fx = d.answer("joli")
        #expect(d.phase == .copy)
        #expect(d.state.input == "")
        #expect(d.state.isInputEditable)
        #expect(WriteFlow.fieldLabel(d.state) == "Tippe die richtige Antwort ab")
        #expect(WriteFlow.fieldPlaceholder(d.state) == "Richtige Antwort abtippen")
        #expect(WriteFlow.returnHint(d.state) == "zum Prüfen")
        #expect(d.announcements(fx).first?.hasSuffix(" Tippe die richtige Antwort ab.") == true)
        // Empty and synonym copies are rejected.
        #expect(d.press(.returnKey) == [.announce("Noch nicht ganz – tippe die richtige Antwort genau ab.")])
        #expect(d.state.inputInvalid)
        d.answer("laide")
        #expect(d.phase == .copy)
        #expect(d.state.rejections == 3)
        d.type("moch")
        #expect(!d.state.inputInvalid)
        // The right copy continues (focus stayed in the field: the prompt is announced).
        let next = d.send(.submit("moche"))
        #expect(d.question?.cardId == "brave")
        #expect(next.contains(.saveSession(try #require(d.session), feedback: nil)))
        #expect(d.announcements(next) == ["Deutsch: lieb"])
    }

    @Test("a copy typed out continues without Return after a short beat")
    func copyTypedOut() {
        let d = Self.driver(copy: true)
        d.answer("x")
        #expect(d.phase == .copy)
        #expect(d.question?.cardId == "a")
        // Accepted like an answer (without its article): the beat starts…
        d.type("chat")
        #expect(d.phase == .copy)
        #expect(d.state.autoAdvance?.ms == CopyStep.advanceMs)
        let spoiled = d.timers.last?.token
        // …and typing on so that it is no longer right stops it.
        d.type("le cha")
        #expect(d.state.autoAdvance == nil)
        _ = d.send(.autoAdvanceFired(token: spoiled ?? -1), after: 0)
        #expect(d.phase == .copy)
        d.type("le chat")
        #expect(d.phase == .copy)
        d.fireTimer()
        #expect(d.phase == .question)
        #expect(d.question?.cardId != "a")
    }

    @Test("⌘↩ “Ich hatte recht” counts the miss as correct and moves on")
    func override() throws {
        let d = Self.driver()
        d.answer("la chatte")
        let fx = d.press(.commandReturn)
        #expect(Array(fx.prefix(3)) == [
            .overrideLastAnswer(cardId: "a"), .saveSession(try #require(d.session), feedback: nil),
            .toast(.countedAsCorrect),
        ])
        #expect(d.question?.cardId == "b")
        #expect(d.session?.roundAnswered == [SessionAnswer(qid: "a:t", correct: true)])
        #expect(d.progress["a"]?.correct == 1)
        #expect(d.progress["a"]?.incorrect == 0)
        #expect(d.stored?.feedback == nil)
    }

    @Test("the copy step offers “Ich hatte recht” too, not after “Weiss ich nicht”")
    func overrideInCopy() {
        let d = Self.driver(copy: true)
        d.answer("la chatte")
        #expect(d.phase == .copy)
        d.send(.override)
        #expect(d.question?.cardId == "b")
        d.press(.optionReturn)
        #expect(d.phase == .copy)
        #expect(d.state.feedback?.dontKnow == true)
        #expect(d.press(.commandReturn).isEmpty)
    }

    // MARK: - Rounds and results

    @Test("rounds, summary, results, retry of the misses and Fertig")
    func roundsAndResults() throws {
        let d = Self.driver(autoAdvance: false)
        d.answer("falsch")
        d.press(.returnKey)
        d.answerCorrectly()
        d.press(.returnKey)
        d.answerCorrectly()
        let toSummary = d.press(.returnKey)
        #expect(d.phase == .summary)
        let summary = try #require(d.state.summary)
        #expect((summary.round, summary.total, summary.correct, summary.incorrect) == (1, 3, 2, 1))
        #expect(d.announcements(toSummary) == ["Runde 1 geschafft: 2 von 3 richtig."])
        #expect(WriteFlow.returnAction(d.state) == "Weiter zu Runde 2")
        #expect(WriteFlow.summaryRows(d.state).map(\.correct) == [false, true, true])
        #expect(WriteFlow.summaryRows(d.state).first?.term == "le chat")
        #expect(WriteFlow.isStudying(d.state))
        #expect(d.press(.returnKey, after: 100).isEmpty) // locked

        d.press(.returnKey)
        #expect(d.phase == .question)
        #expect(d.question?.cardId == "a")
        #expect(!d.state.animatesQuestion)
        #expect(d.session?.round == 2)
        d.answerCorrectly()
        #expect(WriteFlow.roundNote(d.state) == "Runde 2 · nur die Begriffe, die noch nicht sassen")
        let toResults = d.press(.returnKey)
        #expect(d.phase == .results)
        let results = try #require(d.state.results)
        #expect(results.stats.total == 3)
        #expect(results.stats.firstTryCorrect == 2)
        #expect(results.retryCardIds == ["a"])
        #expect(results.cardCount == 3)
        #expect(d.announcements(toResults) == ["Geschafft! 67 Prozent beim ersten Versuch richtig."])
        #expect(d.session?.finishedAt != nil)
        #expect(d.stored?.session.finishedAt != nil)
        #expect(!WriteFlow.isStudying(d.state))
        #expect(WriteFlow.returnAction(d.state) == "Falsche nochmal üben")
        #expect(WriteFlow.hardestRows(d.state) == [
            WriteFlow.TermRow(id: "a", cardId: "a", term: "le chat", definition: "die Katze", termLang: .fr, defLang: .de, misses: 1)
        ])
        #expect(WriteFlow.resultsSubtitle(results) == "Du hast alle 3 Begriffe richtig geschrieben.")

        // "Falsche nochmal üben": a session over the missed card only.
        d.press(.returnKey)
        #expect(d.phase == .question)
        #expect(d.session?.subset == .cardIds(["a"]))
        #expect(d.session?.order == ["a:t"])
        d.answerCorrectly()
        d.press(.returnKey)
        #expect(d.phase == .results)
        #expect(d.state.results?.canRetry == false)
        #expect(WriteFlow.returnAction(d.state) == "Fertig")
        #expect(d.press(.returnKey) == [.exit])
        #expect(d.exits == 1)
        // ⇧⌘R "Nochmal von vorne": a card-id session restarts with all cards (write.js).
        d.send(.restart)
        #expect(d.phase == .question)
        #expect(d.session?.subset == .all)
        #expect(d.session?.order.count == 3)
    }

    @Test("the last question of a round goes to the summary also by auto-advance and by key")
    func lastQuestionPaths() {
        let d = Self.driver([Card(id: "a", term: "un", definition: "eins"), Card(id: "b", term: "deux", definition: "zwei")])
        d.answer("x")
        d.press(.returnKey)
        d.answerCorrectly()
        d.fireTimer()
        #expect(d.phase == .summary)
        d.press(.returnKey)
        d.answerCorrectly()
        d.press(.character("q"))
        #expect(d.phase == .results)
        // The key did not land anywhere.
        #expect(d.state.input == "")
    }

    // MARK: - Resuming

    @Test("an open miss comes back after leaving, with “Willkommen zurück”")
    func resumeMiss() throws {
        let d = Self.driver(copy: true)
        d.answer("la chatte")
        let d2 = d.reopen()
        #expect(d2.phase == .copy)
        #expect(d2.question?.cardId == "a")
        #expect(d2.state.feedback?.given == "la chatte")
        #expect(d2.state.feedback?.result?.correct == false)
        #expect(d2.effects.contains(.toast(.welcomeBack)))
        #expect(d2.announcements().first?.hasPrefix("Nicht ganz. Richtige Antwort: le chat.") == true)
        // Time away is not study time.
        #expect(d2.session?.updatedAt == d2.now)
        #expect(d2.session?.elapsedMs == d.session?.elapsedMs)
        d2.answer("le chat")
        #expect(d2.question?.cardId == "b")
        #expect(d2.stored?.feedback == nil)
        // A "Weiss ich nicht" comes back as such.
        d2.press(.optionReturn)
        let d3 = d2.reopen()
        #expect(d3.phase == .copy)
        #expect(d3.state.feedback?.dontKnow == true)
        #expect(d3.state.feedback?.result == nil)
    }

    @Test("resuming without answers is silent; with answers it continues where it stopped")
    func resumeQuestion() {
        let d = Self.driver()
        let fresh = d.reopen()
        #expect(fresh.phase == .question)
        #expect(fresh.effects.isEmpty)
        d.answerCorrectly()
        let d2 = d.reopen()
        #expect(d2.question?.cardId == "b")
        #expect(d2.effects == [.toast(.welcomeBack)])
        // forceNew starts over.
        let d3 = d.reopen(forceNew: true)
        #expect(d3.question?.cardId == "a")
        #expect(d3.session?.roundAnswered.isEmpty == true)
    }

    @Test("the round summary comes back after a relaunch")
    func resumeSummary() {
        let d = Self.driver(autoAdvance: false)
        d.answer("x")
        d.press(.returnKey)
        d.answerCorrectly()
        d.press(.returnKey)
        d.answerCorrectly()
        d.press(.returnKey)
        #expect(d.phase == .summary)
        let d2 = d.reopen()
        #expect(d2.phase == .summary)
        #expect(d2.state.summary == d.state.summary)
    }

    @Test("a finished session's results are shown again only on its own screen")
    func resultsAgain() {
        let d = Self.driver([Card(id: "a", term: "un", definition: "eins")])
        d.answerCorrectly()
        // Left during the final "Richtig!": the round is still open.
        let marker = d.state.resultsMarker
        let again = d.reopen(marker: marker)
        #expect(again.phase == .results)
        #expect(again.state.results?.stats.total == 1)
        #expect(again.stored?.session.rounds.count == 1)
        let fresh = d.reopen(marker: nil)
        #expect(fresh.phase == .question)
        #expect(fresh.session?.startedAt != d.session?.startedAt)
    }

    @Test("asking for a subset never drops an answered round without asking")
    func replaceRoundPrompt() throws {
        let d = Self.driver()
        d.answer("x")
        let asked = d.reopen(subset: .starred)
        #expect(asked.phase == .starting)
        let prompt = try #require(asked.state.prompt)
        #expect(prompt.title == "Laufende Runde beenden?")
        #expect(prompt.confirmLabel == "Neue Runde starten")
        #expect(prompt.cancelLabel == "Runde fortsetzen")
        #expect(WriteFlow.returnAction(asked.state) == nil)
        #expect(asked.press(.returnKey).isEmpty)
        #expect(asked.press(.escape).isEmpty)
        asked.send(.promptAnswered(confirmed: true))
        #expect(asked.phase == .question)
        #expect(asked.session?.subset == .starred)
        #expect(asked.question?.cardId == "b")

        let d2 = Self.driver()
        d2.answer("x")
        let kept = d2.reopen(subset: .starred)
        kept.send(.promptAnswered(confirmed: false))
        #expect(kept.phase == .feedback(.wrong))
        #expect(kept.session?.subset == .all)
        #expect(kept.effects.contains(.toast(.welcomeBack)))

        // Without answers there is nothing to lose.
        let d3 = Self.driver()
        let direct = d3.reopen(subset: .starred)
        #expect(direct.phase == .question)
        #expect(direct.session?.subset == .starred)
    }

    // MARK: - Empty subsets

    @Test("an empty subset shows its message; Return practises all cards")
    func emptySubset() throws {
        let d = WriteFlowDriver(cards: WriteFlowSamples.three(), options: StudyOptionsPatch(shuffle: false), open: false)
        d.open(subset: .missed)
        #expect(d.phase == .empty)
        #expect(d.state.emptySubset == .missed)
        #expect(WriteFlow.returnAction(d.state) == "Alle Begriffe üben")
        #expect(d.session == nil)
        #expect(d.send(.requestOptions).isEmpty)
        #expect(d.state.overlay == nil)
        d.press(.returnKey)
        #expect(d.phase == .question)
        #expect(d.session?.subset == .all)
        let e = WriteFlowDriver(cards: WriteFlowSamples.three(), options: StudyOptionsPatch(shuffle: false), open: false)
        e.open(subset: .learning)
        #expect(e.phase == .question) // nothing mastered yet
        let f = WriteFlowDriver(cards: WriteFlowSamples.three(), options: StudyOptionsPatch(shuffle: false), open: false)
        f.open(subset: .missed)
        f.send(.practiceAll)
        #expect(f.phase == .question)
    }

    @Test("a set without complete cards offers the editor")
    func noCards() {
        let d = WriteFlowDriver(cards: [Card(id: "x", term: "un", definition: " ")])
        #expect(d.phase == .empty)
        #expect(d.state.emptySubset == .all)
        #expect(WriteFlow.returnAction(d.state) == "Begriffe hinzufügen")
        #expect(d.press(.returnKey) == [.editSet])
        #expect(d.editorRequests == 1)
        #expect(d.phase == .empty)
    }

    // MARK: - Options and dialogs

    @Test("options pause the timer; direction and order apply at once")
    func optionsApplyAtOnce() throws {
        let d = Self.driver()
        d.answerCorrectly()
        d.send(.requestOptions)
        #expect(d.state.autoAdvance == nil)
        #expect(d.state.overlay == .options(before: .init(StudyOptions(shuffle: false, copyAnswer: false)), resumesTimer: true))
        #expect(WriteFlow.returnAction(d.state) == nil)
        #expect(d.press(.returnKey).isEmpty)
        #expect(d.press(.character("x")).isEmpty)
        #expect(d.send(.autoAdvanceFired(token: 1)).isEmpty)
        var options = d.state.options
        options.answerWith = .both
        d.send(.optionsChanged(options))
        // A question per card on the new side; the answer given stays done.
        #expect(d.session?.setOptions == SessionSetOptions(answerWith: .both, shuffle: false))
        #expect(d.session?.order == ["a:t", "b:t", "c:t", "a:d", "b:d", "c:d"])
        #expect(d.session?.done == ["a:t"])
        #expect(d.stored?.session.setOptions.answerWith == .both)
        let resumed = d.send(.overlayDismissed())
        #expect(d.state.prompt == nil)
        // The paused timer runs again.
        #expect(d.phase == .feedback(.correct))
        #expect(resumed.contains(.scheduleAutoAdvance(ms: 900, token: 2)))
        #expect(d.state.focusSerial == 1)
        // A new order applies at once too.
        d.send(.requestOptions)
        options.shuffle = true
        d.send(.optionsChanged(options))
        d.send(.overlayDismissed())
        #expect(d.state.prompt == nil)
        #expect(d.session?.setOptions == SessionSetOptions(answerWith: .both, shuffle: true))
        #expect(Set(d.session?.queue ?? []) == ["b:t", "c:t", "a:d", "b:d", "c:d"])
    }

    @Test("a new direction turns the question on screen around; a resumed session follows the options")
    func directionTurnsTheQuestionAround() throws {
        let d = Self.driver()
        #expect(d.question?.qid == "a:t")
        var options = d.state.options
        options.answerWith = .definition
        d.send(.optionsChanged(options))
        #expect(d.phase == .question)
        #expect(d.question?.qid == "a:d")
        #expect(d.question?.prompt == "le chat")
        #expect(d.session?.order == ["a:d", "b:d", "c:d"])
        d.answerCorrectly()
        // Changed elsewhere while Write mode was left: the stored session follows when it resumes.
        _ = try d.store.updateStudyOptions(d.setId, StudyOptionsPatch(answerWith: .term))
        let e = d.reopen()
        #expect(e.session?.setOptions.answerWith == .term)
        #expect(e.session?.done == ["a:t"])
        #expect(e.question?.qid == "b:t")
        #expect(e.stored?.session.setOptions.answerWith == .term)
    }

    @Test("options: switching the copy step on shows it for the open miss; Neu starten asks")
    func optionsCopyAndRestart() {
        let d = Self.driver()
        d.answer("x")
        d.send(.requestOptions)
        var options = d.state.options
        options.copyAnswer = true
        d.send(.optionsChanged(options))
        d.send(.overlayDismissed())
        #expect(d.state.prompt == nil)
        #expect(d.phase == .copy)
        // Changing only the tolerance resumes quietly.
        d.send(.requestOptions)
        options.tolerance.typos = false
        d.send(.optionsChanged(options))
        d.send(.overlayDismissed())
        #expect(d.phase == .copy)
        // "Neu starten" in the sheet asks first.
        d.send(.requestOptions)
        d.send(.overlayDismissed(restartRequested: true))
        #expect(d.state.prompt == .restart(resumesTimer: false))
        d.send(.promptAnswered(confirmed: true))
        #expect(d.phase == .question)
        #expect(d.session?.roundAnswered.isEmpty == true)
    }

    @Test("Neu starten asks; cancelling keeps the step and its timer")
    func restartPrompt() throws {
        let d = Self.driver()
        d.answerCorrectly()
        d.send(.restart)
        #expect(d.state.prompt == .restart(resumesTimer: true))
        #expect(d.state.prompt?.cancelLabel == "Abbrechen")
        let fx = d.send(.promptAnswered(confirmed: false))
        #expect(fx.contains(.scheduleAutoAdvance(ms: 900, token: 2)))
        #expect(d.phase == .feedback(.correct))
        // A stray answer without a prompt does nothing.
        #expect(d.send(.promptAnswered(confirmed: true)).isEmpty)
    }

    // MARK: - Card edits

    @Test("editing the card during a miss can make the answer correct")
    func editDuringMiss() throws {
        let d = Self.driver()
        d.answer("le chien")
        d.send(.requestEdit)
        #expect(d.state.overlay == .editor(question: SessionQuestion(qid: "a:t", cardId: "a", ask: .term), focus: .term, resumesTimer: false))
        #expect(d.press(.returnKey).isEmpty)
        var card = try #require(WriteFlow.editorCard(d.state))
        #expect(card.term == "le chat")
        card.term = "  le chien "
        let fx = d.send(.editCard(card))
        #expect(fx.first == .updateCard(Card(id: "a", term: "le chien", definition: "die Katze")))
        #expect(fx.last == .toast(.cardSaved))
        #expect(d.state.overlay == nil)
        #expect(d.store.getSet(d.setId)?.cards.first?.term == "le chien")
        #expect(d.question?.expected == "le chien")
        let fb = try #require(d.state.feedback)
        #expect(fb.editedCorrect)
        #expect(fb.overrideLabel == "Als richtig zählen")
        #expect(fb.editedNote != nil)
        #expect(!fb.showsHint)
        d.press(.commandReturn)
        #expect(d.question?.cardId == "b")
        #expect(d.progress["a"]?.correct == 1)
    }

    @Test("editing pauses and resumes the auto-advance; cancelling too")
    func editDuringCorrect() {
        let d = Self.driver()
        d.answerCorrectly()
        d.send(.requestEdit)
        #expect(d.state.autoAdvance == nil)
        var card = WriteFlow.editorCard(d.state)!
        card.definition = "die Hauskatze"
        let fx = d.send(.editCard(card))
        #expect(fx.contains(.scheduleAutoAdvance(ms: 900, token: 2)))
        #expect(d.question?.prompt == "die Hauskatze")
        d.send(.requestEdit)
        let cancel = d.send(.overlayDismissed())
        #expect(cancel.contains(.scheduleAutoAdvance(ms: 900, token: 3)))
        // Empty sides are never saved.
        d.send(.requestEdit)
        card.term = " "
        #expect(d.send(.editCard(card)).isEmpty)
        #expect(d.state.overlay != nil)
        // Without the editor open nothing is saved.
        d.send(.overlayDismissed())
        #expect(d.send(.editCard(card)).isEmpty)
    }

    @Test("editing in the question phase keeps the typed text")
    func editDuringQuestion() {
        let d = Self.driver()
        d.type("le ch")
        d.send(.requestEdit)
        var card = WriteFlow.editorCard(d.state)!
        card.term = "le matou"
        d.send(.editCard(card))
        #expect(d.question?.expected == "le matou")
        #expect(d.state.input == "le ch")
        #expect(d.phase == .question)
        // No editor outside the card.
        let e = WriteFlowDriver(cards: [Card(id: "x", term: "un", definition: " ")])
        e.send(.requestEdit)
        #expect(e.state.overlay == nil)
    }

    @Test("the star toggles the question's card")
    func toggleStar() {
        let d = Self.driver()
        #expect(d.question?.starred == false)
        #expect(d.send(.toggleStar) == [.toggleStar(cardId: "a")])
        #expect(d.question?.starred == true)
        #expect(d.store.getSet(d.setId)?.cards.first?.starred == true)
        d.answerCorrectly()
        d.send(.toggleStar)
        #expect(d.question?.starred == false)
    }

    @Test("speaker buttons read the prompt or the answer in their language")
    func speakButtons() {
        let d = Self.driver()
        #expect(d.send(.speak(.prompt)) == [.speak(text: "die Katze", lang: .de)])
        #expect(d.send(.speak(.answer)) == [.speak(text: "le chat", lang: .fr)])
        let other = Self.driver(termLang: .other, defLang: .other)
        #expect(other.send(.speak(.prompt)).isEmpty)
    }

    @Test("Vorlesen: the term is read when it is the prompt and after every answer")
    func audio() {
        let d = Self.driver(audio: true, answerWith: .definition)
        #expect(d.effects.contains(.speak(text: "le chat", lang: .fr)))
        let fx = d.answer("die Katze")
        #expect(fx.contains(.speak(text: "le chat", lang: .fr)))
        let plain = Self.driver(audio: true)
        #expect(!plain.effects.contains { if case .speak = $0 { true } else { false } })
        #expect(plain.answer("x").contains(.speak(text: "le chat", lang: .fr)))
    }

    // MARK: - Live updates

    @Test("cards deleted elsewhere leave the session; an empty set and a deleted set end it")
    func liveUpdates() throws {
        let d = Self.driver()
        let cards = WriteFlowSamples.three()
        d.type("le c")
        let fx = d.send(.cardsChanged([cards[1], cards[2]]))
        #expect(d.saves(fx).count == 1)
        #expect(d.question?.cardId == "b")
        #expect(d.state.input == "le c")
        #expect(d.session?.order == ["b:t", "c:t"])
        // A changed text updates the card on screen.
        var renamed = cards[1]
        renamed.definition = "der Rüde"
        d.send(.cardsChanged([renamed, cards[2]]))
        #expect(d.question?.prompt == "der Rüde")
        // Nothing usable left: the empty message.
        d.send(.cardsChanged([]))
        #expect(d.phase == .empty)
        #expect(d.state.emptySubset == .all)
        d.send(.setDeleted)
        #expect(d.phase == .missing)
        #expect(d.session == nil)
        #expect(d.state.set == nil)
    }

    @Test("a deleted card in the summary or results updates the screen")
    func liveUpdatesAfterRounds() {
        let d = Self.driver(autoAdvance: false)
        let cards = WriteFlowSamples.three()
        d.answer("x")
        d.press(.returnKey)
        d.answerCorrectly()
        d.press(.returnKey)
        d.answer("y")
        d.press(.returnKey)
        #expect(d.state.summary?.incorrect == 2)
        d.send(.cardsChanged([cards[1], cards[2]]))
        #expect(d.phase == .summary)
        #expect(d.state.summary?.total == 2)
        d.press(.returnKey)
        d.answerCorrectly()
        d.press(.returnKey)
        #expect(d.phase == .results)
        d.send(.cardsChanged([cards[1]]))
        #expect(d.phase == .results)
        #expect(d.state.results?.stats.total == 1)
        // The card being edited disappears: the editor closes.
        let e = Self.driver()
        e.send(.requestEdit)
        e.send(.cardsChanged([cards[1], cards[2]]))
        #expect(e.state.overlay == nil)
        #expect(e.state.focusSerial == 1)
    }

    // MARK: - Study clock

    @Test("the clock counts study time only while studying")
    func clock() throws {
        let d = Self.driver()
        let start = try #require(d.session).elapsedMs
        let fx = d.send(.clockTick, after: 15_000)
        #expect(fx == [.saveSession(try #require(d.session), feedback: nil)])
        #expect(d.session?.elapsedMs == start + 15_000)
        // Hidden or idle: the gap is skipped.
        #expect(d.send(.clockResumed, after: 600_000).isEmpty)
        #expect(d.session?.updatedAt == d.now)
        d.send(.clockTick, after: 1000)
        #expect(d.session?.elapsedMs == start + 16_000)
        // Not while the results are shown.
        let one = Self.driver([Card(id: "a", term: "un", definition: "eins")])
        one.answerCorrectly()
        one.fireTimer()
        #expect(one.phase == .results)
        #expect(one.send(.clockTick).isEmpty)
        #expect(one.send(.clockResumed).isEmpty)
    }

    // MARK: - Leaving

    @Test("Esc and “Zurück zum Lernset” leave Write mode")
    func leaving() {
        let d = Self.driver()
        #expect(d.press(.escape) == [.exit])
        #expect(d.press(.escape, repeat: true).isEmpty)
        #expect(d.send(.leave) == [.exit])
        #expect(d.exits == 2)
        #expect(d.phase == .question)
    }

    @Test("the state encodes and decodes losslessly")
    func codable() throws {
        let d = Self.driver(copy: true)
        d.answer("x")
        d.send(.requestEdit)
        let data = try JSONEncoder().encode(d.state)
        let back = try JSONDecoder().decode(WriteFlow.State.self, from: data)
        #expect(back == d.state)
    }
}
