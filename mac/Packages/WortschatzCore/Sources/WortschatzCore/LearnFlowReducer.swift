import Foundation

// The reducer behind `LearnFlow.start` / `LearnFlow.reduce`: a port of the screen logic of the web
// app's Learn mode (src/screens/learn.js, learn-answer.js, learn-dialogs.js, learn-keys.js). The
// methods carry the names of their JS counterparts.

extension LearnFlow {
    /// One reduction: the state, the effects so far and the environment. Mirrors the screen
    /// context `c` of the web app; the methods carry the names of their JS counterparts.
    struct Machine {
        var s: State
        var effects: [Effect] = []
        /// A save was requested: one `.saveLearn` with the final state ends the effect list (it
        /// comes before a `.navigate`).
        var wantsSave = false
        /// Guards the (theoretical) loop "start fresh → nothing usable → start fresh".
        var freshStarts = 0
        let env: Env

        init(_ state: State, env: Env) {
            s = state
            self.env = env
        }

        var now: Double { env.now }

        mutating func result() -> (State, [Effect]) {
            if wantsSave, let session = s.session {
                // Saved before leaving the screen.
                let save = Effect.saveLearn(session, feedback: s.pending)
                if let i = effects.firstIndex(where: { if case .navigate = $0 { true } else { false } }) {
                    effects.insert(save, at: i)
                } else {
                    effects.append(save)
                }
            }
            return (s, effects)
        }

        mutating func emit(_ effect: Effect) { effects.append(effect) }

        mutating func persist() { wantsSave = true }

        mutating func announce(_ text: String) { emit(.announce(text)) }

        /// No prompt or overlay is open.
        var isFree: Bool { s.prompt == nil && s.overlay == nil }

        var locked: Bool { now < s.inputLockedUntil }

        mutating func lock() {
            if now.isFinite { s.inputLockedUntil = now + INPUT_LOCK_MS }
        }

        mutating func clearAdvance() {
            s.autoAdvanceToken = nil
            s.autoAdvancePaused = false
        }

        mutating func startAdvance(_ ms: Int) {
            s.lastToken += 1
            s.autoAdvanceToken = s.lastToken
            emit(.scheduleAutoAdvance(ms: ms, token: s.lastToken))
        }

        /// A press to move on from a correct answer that came within the input lock: instead of
        /// being swallowed it moves on the moment the lock ends (the praise can always be
        /// skipped). Only for correct answers; a miss must stay readable for the whole lock.
        mutating func skipPraiseWhenUnlocked() {
            guard isFree, case .feedback(.correct) = s.phase, locked else { return }
            let lockedAt = s.inputLockedUntil - INPUT_LOCK_MS
            guard now - lockedAt >= SKIP_MIN_GAP_MS else { return }
            let remaining = Int((s.inputLockedUntil - now).rounded(.up))
            startAdvance(max(1, remaining))
        }

        mutating func pauseAdvance() {
            if s.autoAdvanceToken != nil {
                s.autoAdvanceToken = nil
                s.autoAdvancePaused = true
            }
        }

        // MARK: Events

        mutating func handle(_ event: Event) {
            switch event {
            case let .key(key, isRepeat):
                // Repeats never transition; only a held ⌫ keeps deleting typed letters.
                guard isFree, !isRepeat || key.isDeletion else { return }
                handleKey(key)
            case let .choose(index):
                guard isFree else { return }
                choose(index)
            case let .highlight(index):
                guard isFree, case .question(.mc) = s.phase, let q = s.question else { return }
                s.highlighted = index.flatMap { q.choices.indices.contains($0) ? $0 : nil }
            case let .draftChanged(text):
                if acceptsText { s.draft = text }
            case let .submit(text):
                guard isFree else { return }
                if acceptsText { s.draft = text }
                primaryAction(fromKey: true)
            case .dontKnow:
                guard isFree else { return }
                dontKnow()
            case .proceed:
                guard isFree else { return }
                primaryAction(fromKey: false)
            case .override:
                guard isFree else { return }
                overrideLast()
            case .speakPrompt:
                if let q = s.question { emit(.speak(text: q.prompt, lang: q.promptLang)) }
            case .toggleStar:
                toggleStar()
            case let .editCard(card):
                editCard(card)
            case let .optionsChanged(options):
                optionsChanged(options)
            case let .reviewChanged(review):
                s.review = review
            case let .recheckChanged(recheck):
                s.recheck = recheck
            case .startReview:
                guard isFree, s.phase == .allMastered else { return }
                startFresh(s.subset, review: true)
            case let .setChanged(set):
                s.setTitle = set.title
                s.termLang = set.termLang
                s.defLang = set.defLang
                s.cards = set.cards
                reconcile()
            case let .cardsChanged(cards):
                s.cards = cards
                reconcile()
            case .progressChanged:
                reconcile()
            case let .overlayPresented(kind):
                if s.overlay == nil { pauseAdvance() }
                s.overlay = kind
                if kind == .options && s.optionsBeforeOverlay == nil {
                    s.optionsBeforeOverlay = s.options
                    s.reviewBeforeOverlay = s.review
                    s.recheckBeforeOverlay = s.recheck
                }
            case .overlayDismissed:
                overlayDismissed()
            case let .promptAnswered(confirmed):
                promptAnswered(confirmed)
            case .restart:
                guard isFree else { return }
                restart()
            case .relearn:
                guard isFree else { return }
                requestRelearn()
            case .studyAll:
                guard isFree, s.phase == .empty else { return }
                startFresh(.all)
            case let .autoAdvanceFired(token):
                guard isFree, token == s.autoAdvanceToken else { return }
                s.autoAdvanceToken = nil
                continueNext(fromUser: false)
            case .tick:
                guard s.isStudying, let session = s.session else { return }
                s.session = LearnEngine.tick(session, now: now)
                persist()
            case .resume:
                guard var session = s.session, session.finishedAt == nil, now.isFinite else { return }
                session.updatedAt = now
                s.session = session
            case .exit:
                leave()
            }
        }

        /// The answer field (written question) or the copy field is on screen.
        var acceptsText: Bool {
            switch s.phase {
            case .question(.written), .copy: true
            default: false
            }
        }

        mutating func handleKey(_ key: KeyInput) {
            switch key {
            case .returnKey:
                primaryAction(fromKey: true)
            case .optionReturn:
                guard !locked else { return }
                dontKnow()
            case .commandReturn:
                guard !locked else { return }
                overrideLast()
            case .escape:
                // Letters typed on a multiple-choice question go first.
                if case .question(.mc) = s.phase, !s.typed.isEmpty {
                    clearTyped()
                    return
                }
                leave()
            case let .digit(n):
                guard case .question(.mc) = s.phase else {
                    anyKey(String(n))
                    return
                }
                guard !locked, let q = s.question else { return }
                if n == 0 {
                    dontKnow()
                } else if n >= 1 && n <= q.choices.count {
                    choose(n - 1)
                }
            case let .arrow(direction):
                if case .question(.mc) = s.phase { s.typed = "" }
                moveHighlight(direction)
            case let .character(text):
                if case .question(.mc) = s.phase {
                    typeOnChoices(text)
                } else {
                    anyKey(text)
                }
            case .deleteBackward:
                deleteTyped()
            case .deleteWordBackward:
                deleteTyped(word: true)
            }
        }

        // MARK: Typing on multiple choice (learn-typeahead)

        /// A letter typed on a multiple-choice question: the one option the letters start is
        /// highlighted, so Return chooses it (`LearnFlow.typeAhead`). No input lock: typing is no
        /// transition, and the first letter often comes right after the question appears.
        mutating func typeOnChoices(_ text: String) {
            guard let q = s.question else { return }
            if s.typed.isEmpty && text.allSatisfy(\.isWhitespace) { return }
            guard s.typed.count + text.count <= TYPE_AHEAD_MAX else { return }
            s.typed += text
            updateTypeAhead(q)
        }

        /// ⌫ removes the last letter, ⌥⌫ the last word ("la voi" → "la ").
        mutating func deleteTyped(word: Bool = false) {
            guard case .question(.mc) = s.phase, let q = s.question, !s.typed.isEmpty else { return }
            if word {
                while s.typed.last?.isWhitespace == true { s.typed.removeLast() }
                while let last = s.typed.last, !last.isWhitespace { s.typed.removeLast() }
            } else {
                s.typed.removeLast()
            }
            if s.typed.allSatisfy(\.isWhitespace) { s.typed = "" }
            updateTypeAhead(q)
        }

        mutating func clearTyped() {
            s.typed = ""
            s.highlighted = nil
            announce("Eingabe gelöscht")
        }

        mutating func updateTypeAhead(_ q: QuestionInfo) {
            let match = LearnFlow.typeAhead(s.typed, choices: q.choices.map(\.text), lang: q.answerLang)
            let previous = s.highlighted
            s.highlighted = match.selected
            if let index = match.selected, index != previous {
                announce("Antwort \(index + 1): \(q.choices[index].text). Eingabetaste wählt sie.")
            }
        }

        /// After multiple-choice feedback any key continues (without picking anything in the
        /// next question); after a correct written answer any key continues and, unless it is a
        /// space, starts the next written answer.
        mutating func anyKey(_ text: String) {
            guard case let .feedback(kind) = s.phase, let q = s.question else { return }
            if q.type == .mc {
                guard !locked else {
                    skipPraiseWhenUnlocked()
                    return
                }
                continueNext(fromUser: false)
                return
            }
            guard kind == .correct else { return }
            continueNext(fromUser: false)
            if case .question(.written) = s.phase, text != " " { s.draft = text }
        }

        /// Return / the primary button.
        mutating func primaryAction(fromKey: Bool) {
            if fromKey && locked {
                skipPraiseWhenUnlocked()
                return
            }
            switch s.phase {
            case .question(.mc):
                if let index = s.highlighted {
                    choose(index)
                } else if !s.typed.isEmpty, let q = s.question {
                    // Typed letters that pick no option yet: Return cannot guess.
                    s.rejections += 1
                    announce("Keine eindeutige Antwort – tippe weiter oder wähle mit 1 bis \(q.choices.count).")
                }
            case .question(.written):
                submitAnswer(s.draft)
            case .feedback:
                continueNext(fromUser: true)
            case .copy:
                submitCopy(s.draft)
            case .checkpoint:
                goNextRound(fromUser: true)
            case .finished:
                emit(.navigate(.set))
            case .allMastered:
                requestRelearn()
            case .empty:
                if s.subset == .all { emit(.navigate(.editSet)) } else { startFresh(.all) }
            }
        }

        /// Arrow keys on a 2-column grid; the first press lands on option 1.
        mutating func moveHighlight(_ direction: Direction) {
            guard case .question(.mc) = s.phase, let q = s.question, !q.choices.isEmpty else { return }
            let count = q.choices.count
            var next = 0
            if let h = s.highlighted {
                next = h
                switch direction {
                case .left: if h % 2 == 1 { next = h - 1 }
                case .right: if h % 2 == 0 && h + 1 < count { next = h + 1 }
                case .up: if h >= 2 { next = h - 2 }
                case .down:
                    if h + 2 < count {
                        next = h + 2
                    } else if h / 2 < (count - 1) / 2 {
                        next = count - 1
                    }
                }
            }
            guard next != s.highlighted else { return }
            s.highlighted = next
            announce("Antwort \(next + 1): \(q.choices[next].text)")
        }

        // MARK: Session lifecycle (learn.js)

        mutating func boot(saved: SavedLearn?, wanted: StudySubset?, forceNew: Bool) {
            // A stored session with the answers given elsewhere since.
            var stored = saved?.state
            var synced = false
            if let state = stored, !LearnEngine.matchesProgress(state, progress: env.progress) {
                stored = LearnEngine.syncProgress(state, progress: env.progress, now: now)
                synced = true
            }
            guard let stored, canResumeLearn(stored, forceNew: forceNew, subset: wanted) else {
                // A requested subset must not end a session with answers without asking.
                if let wanted, !forceNew, let stored, canResumeLearn(stored), hasLearnAnswers(stored) {
                    if resumeSaved(stored, feedback: saved?.feedback, wanted: nil, synced: synced, welcome: false) {
                        pauseAdvance()
                        s.prompt = .replaceSession(wanted)
                    }
                    return
                }
                startFresh(wanted ?? .all)
                return
            }
            resumeSaved(stored, feedback: saved?.feedback, wanted: wanted, synced: synced, welcome: true)
        }

        /// Resumes a stored session; false when it had to start a new one instead.
        @discardableResult
        mutating func resumeSaved(
            _ saved: LearnState, feedback: JSONValue?, wanted: StudySubset?, synced: Bool, welcome: Bool
        ) -> Bool {
            var state = saved
            // Time away from the screen is not study time.
            if now.isFinite && state.finishedAt == nil { state.updatedAt = now }
            s.session = state
            s.subset = state.subset
            let pruned = pruneState()
            let changed = syncProgress(env.progress) || synced || pruned
            s.pending = pendingFeedback(s.session!, feedback)
            s.roundStartCounts = nil
            if changed { persist() }
            if s.session?.order.isEmpty ?? true {
                startFresh(wanted ?? .all)
                return false
            }
            if welcome && hasLearnAnswers(s.session) { emit(.toast(WELCOME_BACK, tone: .neutral)) }
            if s.pending != nil { reopenFeedback() } else { advance() }
            return true
        }

        /// A new session over `subset` (`progress`: the stored progress, by default the env's;
        /// `review`: with repetition questions, by default as `State.review` says).
        mutating func startFresh(_ subset: StudySubset, progress: ProgressMap? = nil, review: Bool? = nil) {
            clearAdvance()
            s.feedback = nil
            s.pending = nil
            s.question = nil
            s.highlighted = nil
            s.draft = ""
            freshStarts += 1
            let fresh = LearnEngine.createLearn(
                s.cards, options: s.options, subset: subset, progress: progress ?? env.progress, rng: env.rng, now: now,
                review: review ?? s.review, recheck: s.recheck)
            s.subset = fresh.subset
            if fresh.order.isEmpty || LearnEngine.isFinished(fresh) {
                // Nothing to study.
                s.session = nil
                if fresh.order.isEmpty { showEmpty(fresh.subset) } else { showAllMastered(fresh) }
                return
            }
            s.session = fresh
            s.roundStartCounts = LearnEngine.counts(fresh)
            persist()
            showQuestion()
        }

        /// Drops cards that were deleted (or emptied) since the session started; their options
        /// in other questions are replaced by other cards of the set.
        mutating func pruneState() -> Bool {
            guard var session = s.session else { return false }
            let byId = cardsById(s.cards)
            var changed = false
            for id in session.order where !isUsable(byId[id]) {
                session = LearnEngine.removeCard(session, cardId: id, now: now, cards: s.cards, rng: env.rng)
                changed = true
            }
            s.session = session
            return changed
        }

        /// Learn and Write share one progress model: answers given elsewhere move a card's stage
        /// here too. Returns whether the session changed.
        mutating func syncProgress(_ progress: ProgressMap) -> Bool {
            guard let session = s.session, !LearnEngine.matchesProgress(session, progress: progress) else {
                return false
            }
            s.session = LearnEngine.syncProgress(session, progress: progress, now: now)
            return true
        }

        /// The next step after a question, a round or a resume.
        mutating func advance() {
            guard let session = s.session, !session.order.isEmpty else {
                sessionEmptied()
                return
            }
            if LearnEngine.isFinished(session) {
                finish()
            } else if LearnEngine.isRoundOver(session) {
                showCheckpoint()
            } else {
                showQuestion()
            }
        }

        /// Every card of the session vanished (deleted elsewhere).
        mutating func sessionEmptied() {
            let subset: StudySubset =
                switch s.session?.subset ?? .all {
                case .cardIds: .all
                case let named: named
                }
            if s.cards.contains(where: { isUsable($0) }) && freshStarts < 2 {
                startFresh(subset)
            } else {
                s.session = nil
                emit(.clearLearn)
                showEmpty(.all)
            }
        }

        // MARK: Questions

        func questionInfo(for q: LearnEngine.Question) -> QuestionInfo? {
            guard let card = cardsById(s.cards)[q.cardId] else { return nil }
            return LearnFlow.questionInfo(q, card: card, cards: s.cards, termLang: s.termLang, defLang: s.defLang)
        }

        /// `info` with the current texts of its card (the stored one when the card is gone).
        func refreshedInfo(_ info: QuestionInfo) -> QuestionInfo {
            questionInfo(
                for: LearnEngine.Question(
                    qid: info.qid, cardId: info.cardId, type: info.type, ask: info.ask,
                    choices: info.type == .mc ? info.storedChoices : nil)) ?? info
        }

        mutating func showQuestion() {
            clearAdvance()
            guard var session = s.session else {
                advance()
                return
            }
            var q = LearnEngine.current(session)
            var pruned = false
            let byId = cardsById(s.cards)
            while let head = q, !isUsable(byId[head.cardId]) {
                session = LearnEngine.removeCard(session, cardId: head.cardId, now: now, cards: s.cards, rng: env.rng)
                pruned = true
                q = LearnEngine.current(session)
            }
            s.session = session
            if pruned { persist() }
            guard let q else {
                advance()
                return
            }
            // Never nil: a usable card exists.
            guard let info = questionInfo(for: q) else { return }
            s.phase = .question(q.type)
            s.question = info
            s.feedback = nil
            s.highlighted = nil
            s.typed = ""
            s.draft = ""
            s.transitions += 1
            let lead = info.isReview ? "\(REVIEW_LABEL). " : ""
            if q.type == .mc {
                announce(
                    "\(lead)\(info.promptLabel): \(info.prompt). Wähle die richtige Antwort, 1 bis \(info.choices.count).")
            } else {
                announce(
                    "\(lead)\(info.promptLabel): \(info.prompt)"
                        + (session.answerWith == .both ? ". \(info.placeholder)." : ""))
            }
            lock()
            if s.options.audio && info.ask == .definition { emit(.speak(text: info.prompt, lang: info.promptLang)) }
        }

        // MARK: Answering (learn-answer.js)

        /// The question on screen must be the session's current one before an answer counts.
        mutating func isAnswerable(_ type: QuestionType) -> Bool {
            guard case .question(let shown) = s.phase, shown == type, let info = s.question, let session = s.session
            else { return false }
            if LearnEngine.current(session)?.qid == info.qid { return true }
            showQuestion()
            return false
        }

        mutating func record(_ info: QuestionInfo, correct: Bool) {
            guard let session = s.session else { return }
            emit(.recordAnswer(cardId: info.cardId, correct: correct, at: now))
            s.session = LearnEngine.answer(session, correct: correct, now: now)
        }

        /// Audio option: read the target-language side once the answer is known.
        mutating func speakAnswer(_ cardId: String) {
            guard s.options.audio, let card = cardsById(s.cards)[cardId] else { return }
            emit(.speak(text: card.term, lang: s.termLang))
        }

        mutating func choose(_ index: Int) {
            guard let q = s.question, q.choices.indices.contains(index) else { return }
            if isAnswerable(.mc) { commitMc(index) }
        }

        mutating func dontKnow() {
            switch s.phase {
            case .question(.mc):
                if isAnswerable(.mc) { commitMc(nil) }
            case .question(.written):
                if isAnswerable(.written), let info = s.question {
                    commitWritten(info, given: "", result: nil, dontKnow: true, synonym: false)
                }
            default:
                break
            }
        }

        mutating func commitMc(_ chosenIndex: Int?) {
            guard let info = s.question else { return }
            clearAdvance()
            let correctIndex = info.choices.firstIndex { $0.cardId == info.cardId }
            let correct = chosenIndex != nil && chosenIndex == correctIndex
            record(info, correct: correct)
            s.pending =
                correct
                ? nil
                : PendingFeedback(
                    mcQid: info.qid, cardId: info.cardId, ask: info.ask, choices: info.storedChoices,
                    chosen: chosenIndex.map { info.choices[$0].cardId })
            persist()
            s.feedback = Feedback(
                kind: correct ? .correct : chosenIndex == nil ? .dontKnow : .wrong, correctIndex: correctIndex,
                chosenIndex: chosenIndex, demoted: info.isReview && !correct)
            s.highlighted = nil
            s.typed = ""
            speakAnswer(info.cardId)
            showMcResult(.answer)
        }

        enum Presentation { case answer, resume, refresh }

        /// The feedback of a multiple-choice answer (also after a relaunch).
        mutating func showMcResult(_ how: Presentation) {
            guard var f = s.feedback, let info = s.question else { return }
            s.phase = .feedback(f.kind)
            if how != .refresh { s.transitions += 1 }
            if f.kind == .correct {
                if f.title.isEmpty {
                    f.title = pickPraise(s.lastPraise, rng: env.rng)
                    s.lastPraise = f.title
                }
                f.autoAdvanceMs = ADVANCE_MS
                s.feedback = f
                announce(f.title)
                if how == .answer { emit(.haptic(.success)) }
                lock()
                startAdvance(ADVANCE_MS)
                return
            }
            f.title = f.kind == .dontKnow ? DONT_KNOW_TITLE : MISS_TITLE
            s.feedback = f
            let demoted = f.demoted ? " \(DEMOTED_TEXT)." : ""
            announce(
                "\(f.kind == .dontKnow ? "Kein Problem." : "Nicht ganz.") Richtige Antwort: \(info.expected).\(demoted)")
            if how == .answer && f.kind == .wrong { emit(.haptic(.failure)) }
            lock()
        }

        mutating func submitAnswer(_ value: String) {
            guard isAnswerable(.written), let shown = s.question else { return }
            let info = refreshedInfo(shown)
            guard hasText(value) else {
                s.rejections += 1
                announce("Gib zuerst eine Antwort ein – oder wähle «Weiss ich nicht?».")
                return
            }
            let graded = gradeQuestion(
                info, given: value, cards: s.cards, tolerance: s.options.tolerance,
                extraAnswers: env.extraAnswers(info.synonymQuery))
            commitWritten(
                info, given: JSCompat.trim(value), result: graded.result, dontKnow: false, synonym: graded.isSynonym)
        }

        mutating func commitWritten(
            _ info: QuestionInfo, given: String, result: GradeResult?, dontKnow: Bool, synonym: Bool
        ) {
            clearAdvance()
            let correct = result?.correct == true
            record(info, correct: correct)
            s.pending =
                correct
                ? nil
                : PendingFeedback(writtenQid: info.qid, cardId: info.cardId, ask: info.ask, given: given, dontKnow: dontKnow)
            persist()
            s.question = info
            s.feedback = Feedback(
                kind: correct ? .correct : dontKnow ? .dontKnow : .wrong, given: given, result: result, synonym: synonym,
                demoted: info.isReview && !correct)
            speakAnswer(info.cardId)
            if correct { showWrittenCorrect() } else { showWrittenIncorrect(.answer) }
        }

        mutating func showWrittenCorrect() {
            guard var f = s.feedback, let result = f.result else { return }
            s.phase = .feedback(.correct)
            s.transitions += 1
            // "Genau!" right above a "Genau: …" correction would read oddly; a synonym shows the
            // word the card asked for.
            if f.title.isEmpty {
                if f.synonym {
                    f.title = SYNONYM_TITLE
                } else if result.exact {
                    f.title = pickPraise(s.lastPraise, rng: env.rng)
                    s.lastPraise = f.title
                } else {
                    f.title = TOLERATED_TITLE
                }
            }
            let exactLabel = f.synonym ? "Gesucht war:" : "Genau:"
            f.exactLabel = result.exact ? nil : exactLabel
            let ms = result.exact ? ADVANCE_MS : ADVANCE_MS_WITH_NOTES
            f.autoAdvanceMs = ms
            s.feedback = f
            announce(result.exact ? f.title : "\(f.title) \(exactLabel) \(result.expectedDisplay)")
            emit(.haptic(.success))
            lock()
            startAdvance(ms)
        }

        mutating func showWrittenIncorrect(_ how: Presentation) {
            guard var f = s.feedback, let info = s.question else { return }
            let dontKnow = f.kind == .dontKnow
            f.copy = s.options.learn.retype
            f.hint = f.result?.hint.flatMap { Labels.HINT_LABELS[$0] }
            f.canOverride = !dontKnow && hasText(f.given)
            f.title = dontKnow ? DONT_KNOW_TITLE : MISS_TITLE
            s.feedback = f
            let phase: Phase = f.copy ? .copy : .feedback(f.kind)
            if phase != s.phase { s.draft = "" }
            s.phase = phase
            if how != .refresh { s.transitions += 1 }
            let lead = dontKnow ? "Kein Problem." : "Nicht ganz."
            let hint = f.hint.map { " \($0)." } ?? ""
            let demoted = f.demoted ? " \(DEMOTED_TEXT)." : ""
            let tail = f.copy ? " Tippe die richtige Antwort ab." : ""
            announce("\(lead) Richtige Antwort: \(info.expected).\(hint)\(demoted)\(tail)")
            if how == .answer && !dontKnow { emit(.haptic(.failure)) }
            lock()
        }

        mutating func submitCopy(_ value: String) {
            guard s.phase == .copy, let shown = s.question else { return }
            let info = refreshedInfo(shown)
            if copyAccepted(value, info: info, tolerance: s.options.tolerance) {
                continueNext(fromUser: true)
            } else {
                s.rejections += 1
                announce("Noch nicht ganz – tippe die richtige Antwort genau ab.")
            }
        }

        /// "Ich hatte recht": the written miss counts as correct (progress and session).
        mutating func overrideLast() {
            guard let q = s.question, q.type == .written, let f = s.feedback, f.kind == .wrong, let session = s.session
            else { return }
            switch s.phase {
            case .feedback(.wrong), .copy: break
            default: return
            }
            let cardId = q.cardId
            clearAdvance()
            emit(.overrideLastAnswer(cardId: cardId))
            s.session = LearnEngine.override(session, now: now)
            // The stored progress decides (it differs only if the card was answered elsewhere since).
            var progress = env.progress
            if let prev = progress[cardId], prev.lastResult == .incorrect { progress[cardId] = Mastery.applyOverride(prev) }
            _ = syncProgress(progress)
            s.pending = nil
            persist()
            emit(.toast("Als richtig gezählt", tone: .success))
            continueNext(fromUser: false)
        }

        /// The next question (or checkpoint/finish) after feedback. `fromUser`: clicks and keys
        /// respect the input lock so one press never skips two steps.
        mutating func continueNext(fromUser: Bool) {
            switch s.phase {
            case .feedback, .copy: break
            default: return
            }
            if fromUser && locked {
                skipPraiseWhenUnlocked()
                return
            }
            clearAdvance()
            if s.pending != nil {
                // The miss is dealt with: a relaunch now continues after it.
                s.pending = nil
                persist()
            }
            if let session = s.session, LearnEngine.isRoundOver(session) { advance() } else { showQuestion() }
        }

        /// The "Nicht ganz" screen that was open when the session was left; the answer itself
        /// is already recorded.
        mutating func reopenFeedback() {
            guard let p = s.pending else { return }
            let q = LearnEngine.Question(
                qid: p.qid, cardId: p.cardId, type: p.type, ask: p.ask, choices: p.type == .mc ? p.choices : nil)
            guard let info = questionInfo(for: q) else {
                s.pending = nil
                persist()
                advance()
                return
            }
            s.question = info
            s.highlighted = nil
            s.typed = ""
            s.draft = ""
            if p.type == .mc {
                let chosenIndex = p.chosen.flatMap { chosen in info.choices.firstIndex { $0.cardId == chosen } }
                s.feedback = Feedback(
                    kind: chosenIndex == nil ? .dontKnow : .wrong,
                    correctIndex: info.choices.firstIndex { $0.cardId == p.cardId }, chosenIndex: chosenIndex,
                    demoted: info.isReview)
                showMcResult(.resume)
            } else {
                let given = p.given ?? ""
                let dontKnow = p.dontKnow == true
                let result =
                    dontKnow ? nil : gradeQuestion(info, given: given, cards: s.cards, tolerance: s.options.tolerance).result
                s.feedback = Feedback(
                    kind: dontKnow ? .dontKnow : .wrong, given: given, result: result, demoted: info.isReview)
                showWrittenIncorrect(.resume)
            }
        }

        // MARK: Checkpoint and finish

        mutating func showCheckpoint(refresh: Bool = false) {
            clearAdvance()
            guard var session = s.session else { return }
            let cp = LearnEngine.checkpoint(session)
            if cp.answered == 0 {
                // Nothing was answered this round (its cards were removed): refill without a checkpoint.
                session = LearnEngine.nextRound(session, cards: s.cards, rng: env.rng, now: now)
                s.session = session
                s.roundStartCounts = LearnEngine.counts(session)
                persist()
                if LearnEngine.isFinished(session) {
                    finish()
                } else if LearnEngine.isRoundOver(session) {
                    sessionEmptied()
                } else {
                    showQuestion()
                }
                return
            }
            s.phase = .checkpoint
            s.question = nil
            s.feedback = nil
            s.highlighted = nil
            s.draft = ""
            if !refresh {
                s.transitions += 1
                announce("Runde \(cp.round) geschafft. \(masteredLine(cp.counts.mastered, cp.counts.total)).")
                lock()
            }
        }

        mutating func goNextRound(fromUser: Bool) {
            guard s.phase == .checkpoint, let session = s.session, !(fromUser && locked) else { return }
            let next = LearnEngine.nextRound(session, cards: s.cards, rng: env.rng, now: now)
            s.session = next
            s.roundStartCounts = LearnEngine.counts(next)
            persist()
            advance()
        }

        mutating func finish() {
            clearAdvance()
            guard let session = s.session else { return }
            // Closes the last round into the history and stamps finishedAt.
            s.session = LearnEngine.nextRound(session, cards: s.cards, rng: env.rng, now: now)
            s.pending = nil
            persist()
            showFinish()
        }

        mutating func showFinish(refresh: Bool = false) {
            guard let session = s.session else { return }
            let stats = LearnEngine.finalStats(session)
            guard stats.total > 0 else {
                sessionEmptied()
                return
            }
            s.phase = .finished
            s.question = nil
            s.feedback = nil
            s.highlighted = nil
            s.draft = ""
            if refresh { return }
            s.transitions += 1
            announce("Geschafft! \(finishTitle(session.subset, total: stats.total))")
            emit(.haptic(.success))
            lock()
        }

        mutating func showMessage(_ phase: Phase) {
            clearAdvance()
            s.phase = phase
            s.question = nil
            s.feedback = nil
            s.highlighted = nil
            s.draft = ""
            s.pending = nil
            s.transitions += 1
            lock()
        }

        mutating func showEmpty(_ subset: StudySubset) {
            s.subset = subset
            s.scopeCardIds = []
            showMessage(.empty)
        }

        /// Everything in scope is already mastered at the start.
        mutating func showAllMastered(_ fresh: LearnState) {
            s.subset = fresh.subset
            s.scopeCardIds = fresh.order
            showMessage(.allMastered)
        }

        mutating func leave() {
            // Leaving: the time studied until now is kept.
            if s.isStudying, let session = s.session {
                s.session = LearnEngine.tick(session, now: now)
                persist()
            }
            clearAdvance()
            emit(.navigate(.set))
        }

        // MARK: Live updates

        /// The set or the progress changed elsewhere.
        mutating func reconcile() {
            guard s.session != nil else {
                refreshMessage()
                return
            }
            let pruned = pruneState()
            // Answers given elsewhere (e.g. in Write mode) move the stages here too.
            let synced = syncProgress(env.progress)
            if pruned || synced { persist() }
            switch s.phase {
            case .question, .feedback, .copy:
                guard let shown = s.question, let current = s.session else { return }
                let head = LearnEngine.current(current)
                let same =
                    head?.qid == shown.qid && head?.type == shown.type
                    && (head?.choices ?? []) == (shown.type == .mc ? shown.storedChoices : [])
                if case .question = s.phase, !same {
                    showQuestion()
                } else if cardsById(s.cards)[shown.cardId] != nil {
                    refreshCurrent(regrade: false)
                }
            case .checkpoint:
                guard pruned || synced, let current = s.session else { return }
                if !current.order.isEmpty && !LearnEngine.isFinished(current) && LearnEngine.checkpoint(current).answered > 0 {
                    showCheckpoint(refresh: true)
                } else {
                    advance()
                }
            case .finished:
                if pruned { showFinish(refresh: true) }
            case .allMastered, .empty:
                break
            }
        }

        /// The message screens follow the set: the scope's cards of an "everything mastered"
        /// screen that were deleted drop out.
        mutating func refreshMessage() {
            guard s.phase == .allMastered else { return }
            let byId = cardsById(s.cards)
            s.scopeCardIds = s.scopeCardIds.filter { isUsable(byId[$0]) }
        }

        /// Shows the current texts of the question on screen (after an edit here or elsewhere).
        mutating func refreshCurrent(regrade: Bool) {
            guard let shown = s.question, cardsById(s.cards)[shown.cardId] != nil else { return }
            let info = refreshedInfo(shown)
            s.question = info
            if let h = s.highlighted, !info.choices.indices.contains(h) { s.highlighted = nil }
            if case .question(.mc) = s.phase, !s.typed.isEmpty { updateTypeAhead(info) }
            guard regrade, info.type == .written, var f = s.feedback, f.kind != .correct else { return }
            switch s.phase {
            case .feedback, .copy: break
            default: return
            }
            // If the corrected card now accepts what was typed, offer to count it.
            let r = f.kind == .wrong && hasText(f.given)
                ? gradeQuestion(info, given: f.given, cards: s.cards, tolerance: s.options.tolerance).result : nil
            f.editedCorrect = r?.correct == true
            s.feedback = f
            showWrittenIncorrect(.refresh)
        }

        // MARK: Dialogs and card actions (learn-dialogs.js)

        mutating func toggleStar() {
            guard s.isStudyStep, let q = s.question, let i = s.cards.firstIndex(where: { $0.id == q.cardId }) else {
                return
            }
            s.cards[i].starred.toggle()
            s.question?.starred = s.cards[i].starred
            emit(.toggleStar(cardId: q.cardId))
        }

        mutating func editCard(_ card: Card) {
            guard let i = s.cards.firstIndex(where: { $0.id == card.id }) else { return }
            emit(.updateCard(card))
            s.cards[i] = card
            if s.isStudyStep { refreshCurrent(regrade: true) }
            emit(.toast("Karte gespeichert", tone: .success))
        }

        mutating func optionsChanged(_ options: StudyOptions) {
            let before = s.options
            s.options = options
            // The copy step applies at once to an open written miss.
            guard before.learn.retype != options.learn.retype, s.question?.type == .written,
                let f = s.feedback, f.kind != .correct
            else { return }
            switch s.phase {
            case .feedback, .copy: showWrittenIncorrect(.refresh)
            default: break
            }
        }

        mutating func overlayDismissed() {
            guard s.overlay != nil else { return }
            let before = s.optionsBeforeOverlay
            let reviewBefore = s.reviewBeforeOverlay ?? s.review
            let recheckBefore = s.recheckBeforeOverlay ?? s.recheck
            s.overlay = nil
            s.optionsBeforeOverlay = nil
            s.reviewBeforeOverlay = nil
            s.recheckBeforeOverlay = nil
            // Direction, question types, round size, the repetition questions and the rechecks
            // shape the session: they need a restart.
            if let before, let session = s.session, session.finishedAt == nil {
                // Rechecks only exist in sessions with more than RECHECK_MIN_CARDS cards.
                let large = session.order.count > LearnEngine.RECHECK_MIN_CARDS
                let current = sessionSettings(s.options, review: s.review, recheck: s.recheck && large)
                let changes = settingsChanges(sessionSettings(session), current)
                let beforeSettings = sessionSettings(before, review: reviewBefore, recheck: recheckBefore && large)
                if !settingsChanges(beforeSettings, current).isEmpty && !changes.isEmpty {
                    s.prompt = .restartForOptions(changes)
                    return
                }
            }
            resumeAfterOverlay()
        }

        /// A closed overlay or prompt restarts the countdown it interrupted.
        mutating func resumeAfterOverlay() {
            guard s.autoAdvancePaused else { return }
            s.autoAdvancePaused = false
            guard s.phase == .feedback(.correct), let f = s.feedback else { return }
            lock()
            startAdvance(f.autoAdvanceMs ?? ADVANCE_MS)
        }

        mutating func restart() {
            switch s.phase {
            case .question, .feedback, .copy, .checkpoint:
                guard s.session != nil else { return }
                pauseAdvance()
                s.prompt = .restartSession
            case .finished, .allMastered:
                requestRelearn()
            case .empty:
                break
            }
        }

        /// "Nochmal lernen": asks before the scope's progress is reset.
        mutating func requestRelearn() {
            let ids: [String]
            switch s.phase {
            case .finished: ids = s.session?.order ?? []
            case .allMastered: ids = s.scopeCardIds
            default: return
            }
            guard !ids.isEmpty else { return }
            s.prompt = .relearn(cardIds: ids)
        }

        mutating func promptAnswered(_ confirmed: Bool) {
            guard let prompt = s.prompt else { return }
            s.prompt = nil
            switch prompt {
            case .restartSession, .restartForOptions:
                if confirmed { startFresh(s.session?.subset ?? s.subset) } else { resumeAfterOverlay() }
            case let .relearn(ids):
                guard confirmed else { return resumeAfterOverlay() }
                // Forget the progress of the scope's cards, then start over.
                let subset = s.subset
                var progress = env.progress
                if subset == .all {
                    emit(.resetProgress(cardIds: nil))
                    progress = [:]
                } else {
                    emit(.resetProgress(cardIds: ids))
                    for id in ids { progress[id] = nil }
                }
                startFresh(subset, progress: progress)
            case let .replaceSession(wanted):
                if confirmed {
                    startFresh(wanted)
                } else {
                    if hasLearnAnswers(s.session) { emit(.toast(WELCOME_BACK, tone: .neutral)) }
                    resumeAfterOverlay()
                }
            }
        }
    }
}
