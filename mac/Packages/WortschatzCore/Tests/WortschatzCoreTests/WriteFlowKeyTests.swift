import Foundation
import Testing
@testable import WortschatzCore

/// Exhaustive keyboard checks of the Write flow (spec §4.3 and §6): every key in every reachable
/// step, held keys, the lock after a transition, "one Return = one transition", a seeded fuzz walk
/// over random event sequences with invariants, and a complete Enter-only session over the user's
/// 52 cards.
@Suite("WriteFlow keys (spec §4.3)")
struct WriteFlowKeyTests {
    typealias State = WriteFlow.State
    typealias Effect = WriteFlow.Effect

    /// Every key the view can forward.
    static let allKeys: [KeyInput] = [
        .returnKey, .optionReturn, .commandReturn, .escape,
        .digit(0), .digit(1), .digit(4), .digit(9),
        .arrow(.up), .arrow(.down), .arrow(.left), .arrow(.right),
        .character("a"), .character(" "), .character("?"), .character("é"), .character("ab"), .character("😀"),
    ]

    /// A state to press keys in, with the time of its last event.
    struct Snapshot: CustomStringConvertible {
        var name: String
        var state: State
        var now: Double
        var progress: ProgressMap
        var description: String { name }

        init(_ name: String, _ d: WriteFlowDriver) {
            self.name = name
            state = d.state
            now = d.now
            progress = d.progress
        }

        init(_ name: String, state: State, now: Double) {
            self.name = name
            self.state = state
            self.now = now
            progress = [:]
        }

        func apply(_ event: WriteFlow.Event, after dt: Double) -> (State, [Effect]) {
            WriteFlow.reduce(state, event, env: .init(now: now + dt, rng: mulberry32(seed: 99), progress: progress))
        }
    }

    static func driver(
        _ cards: [Card] = WriteFlowSamples.three(), copy: Bool = false, autoAdvance: Bool = true, open: Bool = true
    ) -> WriteFlowDriver {
        WriteFlowDriver(
            cards: cards, options: StudyOptionsPatch(shuffle: false, copyAnswer: copy, autoAdvance: autoAdvance),
            open: open)
    }

    /// One snapshot of every step the screen can be in.
    static let scenarios: [Snapshot] = {
        var out: [Snapshot] = []
        var d = driver()
        out.append(Snapshot("question", d))
        d.type("le chat")
        out.append(Snapshot("questionTypedCorrect", d))
        d = driver()
        d.type("x")
        out.append(Snapshot("questionTypedWrong", d))
        d = driver()
        d.answerCorrectly()
        out.append(Snapshot("correctTimer", d))
        d = driver(autoAdvance: false)
        d.answerCorrectly()
        out.append(Snapshot("correctManual", d))
        d = driver(autoAdvance: false)
        d.answer("x")
        d.press(.returnKey)
        d.answerCorrectly()
        d.press(.returnKey)
        d.answerCorrectly()
        out.append(Snapshot("correctEndOfRound", d))
        d.press(.returnKey)
        out.append(Snapshot("summary", d))
        d.press(.returnKey)
        d.answerCorrectly()
        out.append(Snapshot("correctEndOfSession", d))
        d.press(.returnKey)
        out.append(Snapshot("resultsRetry", d))
        d.press(.returnKey)
        d.answerCorrectly()
        d.press(.returnKey)
        out.append(Snapshot("resultsDone", d))
        d = driver()
        d.answer("x")
        out.append(Snapshot("wrong", d))
        d = driver()
        d.press(.optionReturn)
        out.append(Snapshot("dontKnow", d))
        d = driver(copy: true)
        d.answer("x")
        out.append(Snapshot("copy", d))
        d.type("le chat")
        out.append(Snapshot("copyTypedCorrect", d))
        d = driver(copy: true)
        d.press(.optionReturn)
        out.append(Snapshot("copyDontKnow", d))
        d = driver(WriteFlowSamples.personen, open: false)
        d.open(subset: .starred)
        out.append(Snapshot("emptyStarred", d))
        d = driver([Card(id: "x", term: "un", definition: " ")])
        out.append(Snapshot("emptyAll", d))
        out.append(
            Snapshot(
                "missing", state: WriteFlow.start(set: nil, options: .default, saved: nil, env: .init(now: 1)).0, now: 1))
        d = driver()
        d.answer("x")
        out.append(Snapshot("starting", d.reopen(subset: .starred)))
        d = driver()
        d.answerCorrectly()
        d.send(.requestOptions)
        out.append(Snapshot("overlayOptions", d))
        d = driver()
        d.answer("x")
        d.send(.requestEdit)
        out.append(Snapshot("overlayEditor", d))
        d = driver()
        d.send(.restart)
        out.append(Snapshot("promptRestart", d))
        return out
    }()

    static let blocked: Set<String> = ["starting", "overlayOptions", "overlayEditor", "promptRestart"]

    enum Outcome: Equatable, CustomStringConvertible {
        case nothing, exit, editSet, rejected
        case to(WriteFlow.Phase)

        var description: String {
            switch self {
            case .nothing: "nothing"
            case .exit: "exit"
            case .editSet: "editSet"
            case .rejected: "rejected"
            case let .to(phase): "→ \(phase)"
            }
        }
    }

    static func classify(_ before: State, _ after: State, _ effects: [Effect]) -> Outcome {
        if after == before {
            if effects.isEmpty { return .nothing }
            if effects == [.exit] { return .exit }
            if effects == [.editSet] { return .editSet }
        }
        if after.phase == before.phase && after.rejections == before.rejections + 1
            && after.questionSerial == before.questionSerial
        {
            return .rejected
        }
        return .to(after.phase)
    }

    static func isPrintable(_ key: KeyInput) -> Bool {
        switch key {
        case .digit: true
        case let .character(text): text.utf16.count == 1
        default: false
        }
    }

    /// The table of spec §4.3 (plus the Write specifics of write-keys.js).
    static func expected(_ name: String, _ key: KeyInput) -> Outcome {
        if blocked.contains(name) { return .nothing }
        if key == .escape { return .exit }
        switch (name, key) {
        case ("question", .returnKey): return .rejected
        case ("questionTypedCorrect", .returnKey): return .to(.feedback(.correct))
        case ("questionTypedWrong", .returnKey): return .to(.feedback(.wrong))
        case ("question", .optionReturn), ("questionTypedCorrect", .optionReturn), ("questionTypedWrong", .optionReturn):
            return .to(.feedback(.dontKnow))
        case ("correctTimer", .returnKey), ("correctManual", .returnKey): return .to(.question)
        case ("correctEndOfRound", .returnKey): return .to(.summary)
        case ("correctEndOfSession", .returnKey): return .to(.results)
        case ("wrong", .returnKey), ("wrong", .commandReturn), ("dontKnow", .returnKey): return .to(.question)
        case ("copy", .returnKey), ("copyDontKnow", .returnKey): return .rejected
        case ("copyTypedCorrect", .returnKey), ("copy", .commandReturn), ("copyTypedCorrect", .commandReturn):
            return .to(.question)
        case ("summary", .returnKey), ("resultsRetry", .returnKey), ("emptyStarred", .returnKey): return .to(.question)
        case ("resultsDone", .returnKey), ("missing", .returnKey): return .exit
        case ("emptyAll", .returnKey): return .editSet
        default: break
        }
        // "Weiter mit beliebiger Taste" after a correct answer.
        if isPrintable(key) {
            switch name {
            case "correctTimer", "correctManual": return .to(.question)
            case "correctEndOfRound": return .to(.summary)
            case "correctEndOfSession": return .to(.results)
            default: break
            }
        }
        return .nothing
    }

    @Test("every scenario was built as intended")
    func scenarioPhases() {
        let phases = Dictionary(uniqueKeysWithValues: Self.scenarios.map { ($0.name, $0.state.phase) })
        #expect(phases["question"] == .question)
        #expect(phases["correctTimer"] == .feedback(.correct))
        #expect(phases["correctEndOfRound"] == .feedback(.correct))
        #expect(phases["summary"] == .summary)
        #expect(phases["resultsRetry"] == .results)
        #expect(phases["resultsDone"] == .results)
        #expect(phases["wrong"] == .feedback(.wrong))
        #expect(phases["dontKnow"] == .feedback(.dontKnow))
        #expect(phases["copy"] == .copy)
        #expect(phases["copyDontKnow"] == .copy)
        #expect(phases["emptyStarred"] == .empty)
        #expect(phases["emptyAll"] == .empty)
        #expect(phases["missing"] == .missing)
        #expect(phases["starting"] == .starting)
        #expect(Self.scenarios.filter { $0.state.isBlocked }.count == 4)
        #expect(Self.scenarios.first { $0.name == "resultsRetry" }?.state.results?.canRetry == true)
        #expect(Self.scenarios.first { $0.name == "resultsDone" }?.state.results?.canRetry == false)
    }

    @Test("every key in every step does what spec §4.3 says")
    func keyTable() {
        var checked = 0
        for snap in Self.scenarios {
            for key in Self.allKeys {
                let (after, effects) = snap.apply(.key(key), after: 1000)
                let outcome = Self.classify(snap.state, after, effects)
                #expect(outcome == Self.expected(snap.name, key), "\(snap.name) + \(key)")
                checked += 1
            }
        }
        #expect(checked == Self.scenarios.count * Self.allKeys.count)
    }

    @Test("a KeyPress of the view layer is the same event")
    func keyPressEvent() {
        #expect(WriteFlow.Event.key(KeyPress(.returnKey)) == .key(.returnKey))
        #expect(WriteFlow.Event.key(KeyPress(.escape, isRepeat: true)) == .key(.escape, isRepeat: true))
    }

    @Test("held keys (auto-repeat) never do anything")
    func repeatsNeverTransition() {
        for snap in Self.scenarios {
            for key in Self.allKeys {
                for dt in [0.0, 100, 1000, 60_000] {
                    let (after, effects) = snap.apply(.key(key, isRepeat: true), after: dt)
                    #expect(after == snap.state && effects.isEmpty, "\(snap.name) + held \(key)")
                }
            }
        }
    }

    @Test("Return, ⌥↩ and ⌘↩ are swallowed right after a transition; Esc is not")
    func lockAfterTransition() {
        var locked = 0
        for snap in Self.scenarios where !snap.state.isBlocked && snap.state.lockUntil > snap.now + 100 {
            locked += 1
            for key in [KeyInput.returnKey, .optionReturn, .commandReturn] {
                let (after, effects) = snap.apply(.key(key), after: 100)
                if key == .returnKey, snap.state.phase == .feedback(.correct) {
                    // After a correct answer Return is kept: it moves on when the lock ends.
                    #expect(Self.defersSkip(from: snap.state, to: after, effects: effects), "\(snap.name) + Return while locked")
                } else {
                    #expect(after == snap.state && effects.isEmpty, "\(snap.name) + \(key) while locked")
                }
            }
            #expect(snap.apply(.key(.escape), after: 100).1 == [.exit])
        }
        #expect(locked >= 15)
    }

    /// `to` is `from` with only the auto-advance moved up to the end of the input lock.
    static func defersSkip(from: WriteFlow.State, to: WriteFlow.State, effects: [WriteFlow.Effect]) -> Bool {
        guard let advance = to.autoAdvance, effects == [.scheduleAutoAdvance(ms: advance.ms, token: advance.token)],
            advance.token != from.autoAdvance?.token, advance.ms <= Int(WriteFlow.enterLockMs)
        else { return false }
        var expected = to
        expected.autoAdvance = from.autoAdvance
        return expected.phase == from.phase && expected.question == from.question && expected.feedback == from.feedback
    }

    @Test("one Return is one transition: an immediate second press does nothing")
    func oneReturnOneTransition() {
        var transitions = 0
        for snap in Self.scenarios {
            for key in [KeyInput.returnKey, .optionReturn, .commandReturn] {
                let (first, firstEffects) = snap.apply(.key(key), after: 1000)
                guard case .to = Self.classify(snap.state, first, firstEffects) else { continue }
                transitions += 1
                for dt in [0.0, 1, 150, 279] {
                    for again in [KeyInput.returnKey, .optionReturn, .commandReturn] {
                        let (second, effects) = WriteFlow.reduce(
                            first, .key(again), env: .init(now: snap.now + 1000 + dt, rng: mulberry32(seed: 5)))
                        if again == .returnKey, first.phase == .feedback(.correct), dt >= WriteFlow.skipMinGapMs {
                            // A second press after a correct answer is kept for the end of the lock.
                            #expect(
                                Self.defersSkip(from: first, to: second, effects: effects),
                                "\(snap.name): \(key) then \(again) after \(dt) ms")
                        } else {
                            #expect(second == first && effects.isEmpty, "\(snap.name): \(key) then \(again) after \(dt) ms")
                        }
                    }
                }
            }
        }
        #expect(transitions >= 15)
    }

    @Test("any key continues after a correct answer, even right away, and lands in the next field")
    func anyKeyContinues() {
        let snap = Self.scenarios.first { $0.name == "correctTimer" }!
        let (after, effects) = snap.apply(.key(.character("l")), after: 10)
        #expect(after.phase == .question)
        #expect(after.input == "l")
        #expect(after.autoAdvance == nil)
        #expect(effects == [.announce("Deutsch: der Hund")])
        #expect(snap.apply(.key(.character(" ")), after: 10).0.input == "")
        #expect(snap.apply(.key(.digit(7)), after: 10).0.input == "7")
        // Not after a miss: there the copy field or "Weiter" takes the key.
        let wrong = Self.scenarios.first { $0.name == "wrong" }!
        #expect(wrong.apply(.key(.character("l")), after: 1000).1.isEmpty)
    }

    @Test("returnAction names the step's primary action everywhere")
    func returnActions() {
        let labels = Dictionary(uniqueKeysWithValues: Self.scenarios.map { ($0.name, WriteFlow.returnAction($0.state)) })
        #expect(labels["question"] == "Antworten")
        #expect(labels["correctTimer"] == "Weiter")
        #expect(labels["wrong"] == "Weiter")
        #expect(labels["copy"] == "Weiter")
        #expect(labels["summary"] == "Weiter zu Runde 2")
        #expect(labels["resultsRetry"] == "Falsche nochmal üben")
        #expect(labels["resultsDone"] == "Fertig")
        #expect(labels["emptyStarred"] == "Alle Begriffe üben")
        #expect(labels["emptyAll"] == "Begriffe hinzufügen")
        #expect(labels["missing"] == "Zur Übersicht")
        for name in Self.blocked { #expect(labels[name] == .some(nil), "\(name)") }
        let hints = Dictionary(uniqueKeysWithValues: Self.scenarios.map { ($0.name, WriteFlow.returnHint($0.state)) })
        #expect(hints["question"] == "zum Antworten")
        #expect(hints["correctTimer"] == "Weiter mit beliebiger Taste")
        #expect(hints["correctManual"] == "zum Weitermachen")
        #expect(hints["copy"] == "zum Prüfen")
        #expect(hints["summary"] == .some(nil))
    }

    // MARK: - Fuzz

    /// A random event for the current state.
    static func randomEvent(_ d: WriteFlowDriver, _ r: RNG, allCards: [Card]) -> WriteFlow.Event {
        func pick<T>(_ list: [T]) -> T { list[min(list.count - 1, Int(r() * Double(list.count)))] }
        func chance(_ p: Double) -> Bool { r() < p }
        let s = d.state
        if s.prompt != nil && chance(0.7) { return .promptAnswered(confirmed: chance(0.5)) }
        if case .editor? = s.overlay, chance(0.6) {
            guard var card = WriteFlow.editorCard(s), chance(0.6) else { return .overlayDismissed() }
            card.term = pick([card.term, d.state.feedback?.given ?? "neu", "neu", " ", pick(allCards).term])
            return .editCard(card)
        }
        if case .options? = s.overlay, chance(0.6) {
            if chance(0.5) { return .overlayDismissed(restartRequested: chance(0.2)) }
            var o = s.options
            switch Int(r() * 5) {
            case 0: o.answerWith = pick(AnswerWith.allCases)
            case 1: o.shuffle.toggle()
            case 2: o.copyAnswer.toggle()
            case 3: o.autoAdvance.toggle()
            default: o.tolerance.typos.toggle()
            }
            return .optionsChanged(o)
        }
        let expected = s.question?.expected ?? ""
        switch Int(r() * 22) {
        case 0...5:
            return .key(pick(allKeys), isRepeat: chance(0.15))
        case 6, 7:
            return .key(.returnKey, isRepeat: chance(0.1))
        case 8, 9:
            let other = allCards.isEmpty ? [] : [pick(allCards).term, pick(allCards).definition]
            return .inputChanged(pick([expected, expected, "zzz", "", " ", String(expected.prefix(3))] + other))
        case 10: return .submit(pick([expected, "falsch", ""]))
        case 11: return pick([.dontKnow, .proceed, .override, .toggleStar, .speak(.prompt), .speak(.answer)])
        case 12: return pick([.requestEdit, .requestOptions, .restart, .retryMissed, .practiceAll, .leave])
        case 13:
            let token = s.autoAdvance?.token ?? 0
            return .autoAdvanceFired(token: chance(0.8) ? token : token - 1)
        case 14:
            // Cards deleted, restored or edited elsewhere.
            var cards = allCards
            if chance(0.5), !cards.isEmpty {
                cards.remove(at: Int(r() * Double(cards.count)))
            } else if chance(0.3), !cards.isEmpty {
                let i = Int(r() * Double(cards.count))
                cards[i].term = chance(0.5) ? cards[i].term + " (m)" : " "
            }
            return chance(0.98) ? .cardsChanged(cards) : .setDeleted
        case 15: return pick([.clockTick, .clockResumed])
        default:
            if s.phase.isCard && chance(0.6) {
                return .inputChanged(expected)
            }
            return .key(.returnKey)
        }
    }

    /// The rules that hold after every event.
    static func checkInvariants(
        _ before: State, _ event: WriteFlow.Event, _ after: State, _ effects: [Effect], _ context: String
    ) {
        func check(_ ok: Bool, _ what: String) {
            if !ok { Issue.record(Comment(rawValue: "\(context): \(what) after \(event)")) }
        }
        check(effects.filter(\.isSave).count <= 1, "at most one save")
        check(effects.filter(\.isAnnounce).count <= 1, "at most one announcement")
        let records = effects.compactMap { if case let .recordAnswer(id, c, _) = $0 { (id, c) } else { nil } }
        check(records.count <= 1, "at most one recorded answer")
        if case .key(_, true) = event { check(after == before && effects.isEmpty, "held key changed something") }
        if case .key = event, before.isBlocked { check(after == before && effects.isEmpty, "key while blocked") }
        if let (session, feedback) = effects.compactMap({ e -> (SessionState, WriteFlow.PendingFeedback?)? in
            if case let .saveSession(s, f) = e { (s, f) } else { nil }
        }).last {
            check(session == after.session && feedback == after.pending, "the last save is the current state")
        }
        if let (cardId, correct) = records.first {
            check(after.question?.cardId == cardId, "answer recorded for the shown card")
            check(after.session?.roundAnswered.last?.correct == correct, "the session got the answer")
            check(after.feedback?.isCorrect == correct, "feedback matches the answer")
        }
        switch after.phase {
        case .question:
            check(after.question != nil && after.feedback == nil, "question shown")
            check(after.question?.qid == after.session.flatMap(WriteSession.current)?.qid, "question is current")
        case let .feedback(kind):
            check(after.feedback != nil && after.question != nil, "feedback shown")
            check((kind == .correct) == (after.feedback?.isCorrect == true), "feedback kind")
            check(after.feedback?.copy != true, "no copy step in feedback")
            check(kind != .dontKnow || after.feedback?.dontKnow == true, "dontKnow kind")
        case .copy:
            check(after.feedback?.copy == true && after.feedback?.isCorrect == false, "copy step")
        case .summary:
            check(after.summary != nil, "summary present")
            if let session = after.session {
                check(WriteSession.isRoundOver(session) && !WriteSession.isFinished(session), "summary only between rounds")
            }
        case .results:
            check(after.results != nil && after.session?.finishedAt != nil, "results of a finished session")
        case .empty:
            check(after.emptySubset != nil, "empty subset known")
        case .missing:
            check(after.session == nil, "missing set")
        case .starting:
            check(after.prompt != nil, "starting only with a prompt")
        }
        if !after.phase.isCard { check(after.input.isEmpty, "no input outside the card") }
        if after.autoAdvance != nil {
            check(after.phase == .feedback(.correct) && !after.isBlocked, "timer only after a correct answer")
        }
        if let pending = after.pending {
            check(after.phase.isMiss && pending.qid == after.question?.qid, "open miss on screen")
        }
        check((WriteFlow.returnAction(after) == nil) == (after.isBlocked || after.phase == .starting), "returnAction")
    }

    /// Answers prompts, closes sheets and answers everything correctly until the results.
    static func finishSession(_ d: WriteFlowDriver, _ context: String) {
        for _ in 0..<400 {
            if d.state.prompt != nil {
                d.send(.promptAnswered(confirmed: false))
            } else if d.state.overlay != nil {
                d.send(.overlayDismissed())
            } else if [.question, .copy].contains(d.phase) {
                d.answerCorrectly()
            } else if d.phase == .results || d.phase == .empty || d.phase == .missing {
                return
            } else {
                d.press(.returnKey)
            }
        }
        Issue.record(Comment(rawValue: "\(context): the session did not finish (\(d.phase))"))
    }

    @Test("a seeded fuzz walk keeps every invariant", arguments: 0..<24)
    func fuzz(seed: Int) throws {
        let r = mulberry32(seed: 0x5EED + seed)
        let pool = [WriteFlowSamples.three(), WriteFlowSamples.personen, Array(WriteFlowSamples.userCards.prefix(12))]
        let cards = pool[seed % pool.count]
        var d = WriteFlowDriver(
            cards: cards,
            options: StudyOptionsPatch(
                answerWith: [AnswerWith.term, .definition, .both][seed % 3], shuffle: seed % 2 == 0,
                copyAnswer: seed % 4 < 2, autoAdvance: seed % 5 != 0),
            seed: seed)
        var answered = 0
        var visited: Set<WriteFlow.Phase> = []
        var changes = 0
        var dialogs = 0
        for step in 0..<800 {
            let event = Self.randomEvent(d, r, allCards: cards)
            let before = d.state
            let dt = [0.0, 30, 120, 250, 300, 1000, 2000, 400_000][Int(r() * 8)]
            let effects = d.send(event, after: dt)
            Self.checkInvariants(before, event, d.state, effects, "seed \(seed) step \(step)")
            answered += effects.count { if case .recordAnswer = $0 { true } else { false } }
            visited.insert(d.phase)
            if d.state != before { changes += 1 }
            if d.state.isBlocked { dialogs += 1 }
            if step % 97 == 0 {
                let data = try JSONEncoder().encode(d.state)
                #expect(try JSONDecoder().decode(State.self, from: data) == d.state)
            }
            // A relaunch now and then (and after the set was deleted, which only the flow was told):
            // the stored session resumes cleanly.
            if step % 131 == 130 || d.phase == .missing {
                let again = d.reopen(seed: seed + step, after: 1000)
                Self.checkInvariants(again.state, .clockTick, again.state, again.effects, "seed \(seed) relaunch \(step)")
                if d.phase == .missing { d = again }
            }
        }
        // The walk got around.
        #expect(answered >= 5)
        #expect(changes >= 80, "only \(changes) events changed the state")
        #expect(visited.count >= 5)
        #expect(dialogs > 0)
        #expect(visited.contains(.question) && visited.contains(.feedback(.correct)))
        #expect(visited.contains { $0.isMiss })
        d.send(.cardsChanged(cards))
        Self.finishSession(d, "seed \(seed)")
    }

    // MARK: - Enter-only session

    @Test("the user's 52 cards with Return only (plus ⌥↩ and ⌘↩)")
    func enterOnlySession() throws {
        let d = WriteFlowDriver(
            cards: WriteFlowSamples.userCards,
            options: StudyOptionsPatch(shuffle: true, copyAnswer: false, autoAdvance: true), seed: 7)
        #expect(WriteFlowSamples.userCards.count == 52)
        #expect(WriteFlowSamples.userCards.first == Card(id: "u1", term: "le monsieur, messieurs", definition: "der Herr"))
        // Round 1: first wrong, second "Weiss ich nicht", third wrong then "Ich hatte recht", the rest right.
        var i = 0
        while d.phase == .question {
            if i == 0 || i == 2 {
                d.answer("voll daneben")
                #expect(d.phase == .feedback(.wrong))
                if i == 2 { d.press(.commandReturn) } else { d.press(.returnKey) }
            } else if i == 1 {
                d.press(.optionReturn)
                #expect(d.phase == .feedback(.dontKnow))
                d.press(.returnKey)
            } else {
                d.answerCorrectly()
                #expect(d.phase == .feedback(.correct))
                #expect(d.state.feedback?.result?.exact == true)
                // Continue with Return or wait for the auto-advance.
                if i % 2 == 0 { d.press(.returnKey) } else { d.fireTimer() }
            }
            i += 1
        }
        #expect(i == 52)
        #expect(d.phase == .summary)
        let summary = try #require(d.state.summary)
        #expect(summary.total == 52)
        #expect(summary.incorrect == 2)
        #expect(WriteFlow.summaryText(summary) == "In Runde 2 übst du nur die 2 Begriffe, die noch nicht sassen.")

        // Relaunch at the summary: it comes back.
        let d2 = d.reopen(seed: 8)
        #expect(d2.phase == .summary)
        #expect(d2.effects == [.toast(.welcomeBack), .announce("Runde 1 geschafft: 50 von 52 richtig.")])

        // Round 2: only the two misses.
        d2.press(.returnKey)
        #expect(d2.session?.round == 2)
        #expect(d2.session?.queue.count == 2)
        while d2.phase == .question {
            d2.answerCorrectly()
            d2.press(.returnKey)
        }
        #expect(d2.phase == .results)
        let stats = try #require(d2.state.results?.stats)
        #expect(stats.total == 52)
        #expect(stats.firstTryCorrect == 50)
        #expect(stats.missedCardIds.count == 2)
        #expect(stats.rounds == 2)

        // Progress: every card answered right once (the two misses after a miss), none mastered yet.
        let sp = Mastery.setProgress(d2.store.getSet(d2.setId), d2.progress)
        #expect(sp.total == 52 && sp.learning == 52 && sp.mastered == 0)
        #expect(d2.store.getActivity().values.reduce(0, +) == 54)

        // "Falsche nochmal üben" with Return, then "Fertig".
        #expect(WriteFlow.returnAction(d2.state) == "Falsche nochmal üben")
        d2.press(.returnKey)
        #expect(d2.session?.order.count == 2)
        while d2.phase == .question {
            d2.answerCorrectly()
            d2.press(.returnKey)
        }
        #expect(d2.phase == .results)
        #expect(WriteFlow.returnAction(d2.state) == "Fertig")
        #expect(d2.press(.returnKey) == [.exit])
        // The two retried cards are mastered now (two right answers in a row).
        #expect(Mastery.setProgress(d2.store.getSet(d2.setId), d2.progress).mastered == 2)
    }
}
