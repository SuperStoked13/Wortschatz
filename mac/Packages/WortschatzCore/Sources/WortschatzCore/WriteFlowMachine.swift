import Foundation

// The engine of WriteFlow: one reducer step as a small mutable machine whose methods mirror the
// functions of src/screens/write.js one to one (startFresh, showNextQuestion, commitAnswer,
// continueNext, afterRoundEnds, reconcile, …). Only `WriteFlow.start` and `WriteFlow.reduce`
// use it.

extension WriteFlow {
    /// One reducer step: the state, the environment and the effects collected so far. The methods
    /// mirror the functions of write.js one to one.
    struct Machine {
        var s: State
        let env: Env
        var effects: [Effect] = []
        var cards: [String: Card]

        init(_ state: State, _ env: Env) {
            s = state
            self.env = env
            cards = WriteFlow.cardIndex(state.set?.cards ?? [])
        }

        /// The state and the effects, with repeated saves and announcements collapsed into the
        /// latest one (the web app's last write wins; its announcer drops all but the last).
        func finish() -> (State, [Effect]) {
            var seenSave = false
            var seenAnnounce = false
            var kept: [Effect] = []
            for effect in effects.reversed() {
                switch effect {
                case .saveSession:
                    if seenSave { continue }
                    seenSave = true
                case .announce:
                    if seenAnnounce { continue }
                    seenAnnounce = true
                default: break
                }
                kept.append(effect)
            }
            return (s, kept.reversed())
        }

        // MARK: Helpers

        /// Within `enterLockMs` after a transition. A lock further in the future than that is
        /// stale (the system clock was set back) and never blocks Return.
        var locked: Bool {
            let remaining = s.lockUntil - env.now
            return remaining > 0 && remaining <= WriteFlow.enterLockMs
        }

        mutating func lock() { s.lockUntil = env.now + WriteFlow.enterLockMs }

        mutating func clearAdvance() { s.autoAdvance = nil }

        /// Return (or a click on "Weiter") within the lock after a correct answer: instead of
        /// being swallowed it moves on the moment the lock ends, so the praise can always be
        /// skipped. A miss stays readable for the whole lock.
        mutating func skipPraiseWhenUnlocked() {
            guard !s.isBlocked, s.phase == .feedback(.correct), locked else { return }
            let lockedAt = s.lockUntil - WriteFlow.enterLockMs
            guard env.now - lockedAt >= WriteFlow.skipMinGapMs else { return }
            startAdvance(max(1, Int((s.lockUntil - env.now).rounded(.up))))
        }

        /// Schedules the auto-advance in `ms` (a new token, so an older timer is ignored).
        mutating func startAdvance(_ ms: Int) {
            s.nextToken += 1
            s.autoAdvance = AutoAdvance(token: s.nextToken, ms: ms)
            effects.append(.scheduleAutoAdvance(ms: ms, token: s.nextToken))
        }

        mutating func persist() {
            guard let session = s.session else { return }
            effects.append(.saveSession(session, feedback: s.pending))
        }

        mutating func announce(_ text: String) { effects.append(.announce(text)) }

        mutating func indexCards() { cards = WriteFlow.cardIndex(s.set?.cards ?? []) }

        func usable(_ cardId: String) -> Bool { WriteFlow.isUsableCard(cards[cardId]) }

        func questionInfo(_ q: SessionQuestion?) -> Question? {
            guard let q, let set = s.set, let card = cards[q.cardId] else { return nil }
            return WriteFlow.questionInfo(set: set, card: card, question: q)
        }

        func infoFor(_ info: Question?) -> Question? { questionInfo(info?.sessionQuestion) }

        /// `gradeQuestion` with the set and tolerance of the flow.
        func grade(_ info: Question, _ given: String) -> SynonymGradeResult {
            WriteFlow.gradeQuestion(
                set: s.set, question: info, given: given, tolerance: s.options.tolerance,
                extraAnswers: env.extraAnswers(info.synonymQuery))
        }

        /// The question whose card the star, the editor and the speaker act on.
        func activeInfo() -> Question? {
            guard s.phase.isCard, let session = s.session else { return nil }
            if s.phase == .question { return questionInfo(WriteSession.current(session)) }
            return s.feedback != nil ? infoFor(s.question) : nil
        }

        /// Distinct card ids of the session's questions, in asking order.
        func cardIdsInSession() -> [String] {
            guard let session = s.session else { return [] }
            var seen = Set<String>()
            var ids: [String] = []
            let ordered = Set(session.order)
            let rest = session.questions.keys.filter { !ordered.contains($0) }.sorted()
            for qid in session.order + rest {
                guard let cardId = session.questions[qid]?.cardId, seen.insert(cardId).inserted else { continue }
                ids.append(cardId)
            }
            return ids
        }

        /// A subset given as a name ("all", "starred", …), else `.all` (write.js
        /// `typeof session.subset === 'string' ? session.subset : 'all'`).
        func namedSubset() -> StudySubset {
            switch s.session?.subset {
            case .starred: .starred
            case .learning: .learning
            case .missed: .missed
            default: .all
            }
        }

        // MARK: Events

        mutating func handle(_ event: Event) {
            switch event {
            case let .key(key, isRepeat): handleKey(key, isRepeat: isRepeat)
            case .inputChanged: break // handled in `reduce`
            case let .submit(value):
                guard !s.isBlocked else { return }
                if s.phase == .question {
                    s.input = value
                    submitAnswer(value)
                } else if s.phase == .copy {
                    s.input = value
                    submitCopy(value)
                }
            case .dontKnow:
                guard !s.isBlocked else { return }
                dontKnow()
            case .proceed:
                guard !s.isBlocked else { return }
                primaryAction()
            case .override:
                guard !s.isBlocked else { return }
                overrideLast()
            case let .autoAdvanceFired(token):
                guard let pending = s.autoAdvance, pending.token == token else { return }
                continueNext(fromUser: false)
            case .toggleStar:
                guard !s.isBlocked else { return }
                toggleStar()
            case let .speak(target):
                guard let q = s.phase.isCard ? s.question : nil else { return }
                let (text, lang) = target == .prompt ? (q.prompt, q.promptLang) : (q.expected, q.answerLang)
                // The speaker buttons only exist for languages with a voice.
                if lang != .other && WriteFlow.hasText(text) { effects.append(.speak(text: text, lang: lang)) }
            case .requestEdit:
                guard !s.isBlocked else { return }
                openEdit()
            case let .editCard(card): saveEdit(card)
            case .requestOptions:
                guard !s.isBlocked else { return }
                openOptions()
            case let .optionsChanged(options):
                s.options = options
                applyOptions()
            case let .overlayDismissed(restartRequested): closeOverlay(restartRequested: restartRequested)
            case let .promptAnswered(confirmed): answerPrompt(confirmed)
            case .restart:
                guard !s.isBlocked else { return }
                if s.phase == .results {
                    startFresh(namedSubset())
                } else {
                    confirmRestart(resumesTimer: false)
                }
            case .retryMissed:
                guard !s.isBlocked else { return }
                retryMissed()
            case .practiceAll:
                guard !s.isBlocked, s.phase == .empty else { return }
                startFresh(.all)
            case .leave: effects.append(.exit)
            case let .setChanged(set): reconcile(set)
            case let .cardsChanged(newCards):
                guard var set = s.set else { return }
                set.cards = newCards
                reconcile(set)
            case .setDeleted: reconcile(nil)
            case .clockTick:
                guard WriteFlow.isStudying(s), let session = s.session else { return }
                s.session = WriteSession.tick(session, now: env.now)
                persist()
            case .clockResumed:
                guard var session = s.session, session.finishedAt == nil else { return }
                session.updatedAt = env.now
                s.session = session
            }
        }

        /// write-keys.js: Return is the primary action; held keys and presses right after a
        /// transition are swallowed; any printable key continues after a correct answer. Nothing
        /// happens while a sheet or alert is open (it handles its own keys).
        mutating func handleKey(_ key: KeyInput, isRepeat: Bool) {
            if s.isBlocked || isRepeat { return }
            switch key {
            case .returnKey:
                if locked {
                    skipPraiseWhenUnlocked()
                    return
                }
                primaryAction()
            case .optionReturn:
                if locked { return }
                if s.phase == .question { dontKnow() }
            case .commandReturn:
                if locked { return }
                if s.phase.isMiss { overrideLast() }
            case .escape:
                effects.append(.exit)
            case let .digit(n):
                continueOnKey(String(n))
            case let .character(text):
                continueOnKey(text)
            case .arrow, .deleteBackward, .deleteWordBackward:
                break
            }
        }

        /// "Weiter mit beliebiger Taste": a printable key continues after a correct answer and
        /// lands in the next question's field (a space only continues).
        mutating func continueOnKey(_ text: String) {
            guard s.phase == .feedback(.correct), text.utf16.count == 1 else { return }
            continueNext(fromUser: false)
            if s.phase == .question && text != " " { s.input = text }
        }

        /// What Return (and the primary button) does in the current phase (spec §4.3).
        mutating func primaryAction() {
            switch s.phase {
            case .starting: break
            case .question: submitAnswer(s.input)
            case .feedback: continueNext(fromUser: true)
            case .copy: submitCopy(s.input)
            case .summary: goNextRound(fromUser: true)
            case .results:
                if s.results?.canRetry == true { retryMissed() } else { effects.append(.exit) }
            case .empty:
                if case .all = s.emptySubset ?? .all { effects.append(.editSet) } else { startFresh(.all) }
            case .missing: effects.append(.exit)
            }
        }

        // MARK: Sessions

        mutating func boot(
            saved: SessionState?, feedback: PendingFeedback?, wanted: StudySubset?, forceNew: Bool, marker: Double?
        ) {
            let showResultsAgain = WriteFlow.canShowResults(saved, forceNew: forceNew, subset: wanted, marker: marker)
            guard let saved, showResultsAgain || WriteFlow.canResume(saved, forceNew: forceNew, subset: wanted) else {
                // A requested subset must not drop a round the learner already answered in
                // without asking.
                if let wanted, let saved, WriteFlow.canResume(saved), WriteFlow.hasAnswers(saved) {
                    s.prompt = .replaceRound(wanted: wanted, saved: saved, feedback: feedback)
                    return
                }
                startFresh(wanted ?? .all)
                return
            }
            resumeSaved(saved, feedback: feedback, showResultsAgain: showResultsAgain, wanted: wanted)
        }

        mutating func startFresh(_ subset: StudySubset) {
            clearAdvance()
            s.feedback = nil
            s.pending = nil
            guard let set = s.set else { return }
            let fresh = WriteSession.createSession(
                set.cards, options: s.options, subset: subset, rng: env.rng, now: env.now, progress: env.progress)
            if fresh.order.isEmpty {
                showEmpty(subset)
                return
            }
            s.session = fresh
            persist()
            showNextQuestion(animate: false)
        }

        /// Drops the questions whose card was deleted (or emptied) since the session started.
        mutating func pruneSession() -> Bool {
            var changed = false
            for id in cardIdsInSession() where !usable(id) {
                guard let session = s.session else { break }
                s.session = WriteSession.removeCard(session, cardId: id, now: env.now)
                changed = true
            }
            return changed
        }

        mutating func resumeSaved(
            _ saved: SessionState, feedback: PendingFeedback?, showResultsAgain: Bool, wanted: StudySubset?
        ) {
            var session = saved
            // Time away is not study time (a finished session's clock is stopped).
            if !showResultsAgain { session.updatedAt = env.now }
            // Direction and «Mischen» as they are set now (changed elsewhere since it was left).
            var applied = false
            if !showResultsAgain, let set = s.set {
                let next = WriteSession.setOptions(
                    session, answerWith: s.options.answerWith, shuffle: s.options.shuffle, cards: set.cards,
                    rng: env.rng, now: env.now)
                applied = next != session
                session = next
            }
            s.session = session
            let pruned = pruneSession()
            s.pending = showResultsAgain ? nil : WriteFlow.pendingFeedback(s.session, feedback)
            if pruned || applied { persist() }
            guard let current = s.session, !current.order.isEmpty else {
                startFresh(wanted ?? .all)
                return
            }
            if showResultsAgain {
                // Also closes the last round when the screen was left during the final "Richtig!".
                finishSession()
                return
            }
            if WriteFlow.hasAnswers(current) { effects.append(.toast(.welcomeBack)) }
            if s.pending != nil { reopenFeedback() } else { afterRoundEnds() }
        }

        /// The "Nicht ganz" screen that was open when Write mode was left; the answer itself is
        /// already recorded.
        mutating func reopenFeedback() {
            guard let pending = s.pending, let info = questionInfo(s.session?.questions[pending.qid]) else {
                s.pending = nil
                afterRoundEnds()
                return
            }
            let result = pending.dontKnow || !WriteFlow.hasText(pending.given) ? nil : grade(info, pending.given).result
            presentQuestion(info, animate: false)
            s.feedback = Feedback(given: pending.given, result: result, dontKnow: pending.dontKnow)
            showIncorrect()
        }

        // MARK: Question

        mutating func showNextQuestion(animate: Bool = true) {
            clearAdvance()
            guard var session = s.session else { return }
            var q = WriteSession.current(session)
            var pruned = false
            while let current = q, !usable(current.cardId) {
                session = WriteSession.removeCard(session, cardId: current.cardId, now: env.now)
                pruned = true
                q = WriteSession.current(session)
            }
            s.session = session
            if pruned { persist() }
            guard let q, let info = questionInfo(q) else {
                afterRoundEnds()
                return
            }
            // The answer field kept focus (VoiceOver does not read the new prompt by itself).
            let keepsFocus = s.phase == .question || s.phase == .feedback(.correct) || s.phase == .copy
            let enteringStage = !s.phase.isCard
            presentQuestion(info, animate: animate && !enteringStage)
            lock()
            if keepsFocus {
                let both = session.setOptions.answerWith == .both
                announce("\(info.promptLabel): \(info.prompt)\(both ? ". \(info.placeholder)." : "")")
            }
            if s.options.audio && info.ask == .definition {
                effects.append(.speak(text: info.prompt, lang: info.promptLang))
            }
        }

        /// `card.setQuestion`: the card shows `info` with an empty, editable answer field.
        mutating func presentQuestion(_ info: Question, animate: Bool) {
            s.phase = .question
            s.question = info
            s.feedback = nil
            s.input = ""
            s.inputInvalid = false
            s.questionSerial += 1
            s.animatesQuestion = animate
            s.summary = nil
            s.results = nil
            s.emptySubset = nil
        }

        mutating func submitAnswer(_ value: String) {
            guard s.phase == .question, let session = s.session,
                let info = questionInfo(WriteSession.current(session))
            else { return }
            guard WriteFlow.hasText(value) else {
                s.rejections += 1
                announce(L("Gib zuerst eine Antwort ein – oder wähle «Weiss ich nicht»."))
                return
            }
            let graded = grade(info, value)
            commitAnswer(
                info, given: JSCompat.trim(value), result: graded.result, dontKnow: false, synonym: graded.isSynonym)
        }

        mutating func dontKnow() {
            guard s.phase == .question, let session = s.session,
                let info = questionInfo(WriteSession.current(session))
            else { return }
            commitAnswer(info, given: "", result: nil, dontKnow: true, synonym: false)
        }

        mutating func commitAnswer(
            _ info: Question, given: String, result: GradeResult?, dontKnow: Bool, synonym: Bool
        ) {
            clearAdvance()
            guard let session = s.session else { return }
            let correct = result?.correct == true
            let at = env.now
            effects.append(.recordAnswer(cardId: info.cardId, correct: correct, at: at))
            s.session = WriteSession.answer(session, correct: correct, now: at)
            s.pending = correct ? nil : PendingFeedback(qid: info.qid, given: given, dontKnow: dontKnow)
            persist()
            s.question = info
            s.feedback = Feedback(given: given, result: result, dontKnow: dontKnow, synonym: synonym)
            if s.options.audio, let set = s.set, let card = cards[info.cardId] {
                effects.append(.speak(text: card.term, lang: set.termLang))
            }
            if correct {
                effects.append(.haptic(.success))
                showCorrect()
            } else {
                if !dontKnow { effects.append(.haptic(.failure)) }
                showIncorrect()
            }
        }

        mutating func pickPraise() -> String {
            let pool = WriteFlow.praise.filter { $0 != s.lastPraise }
            let index = Int((env.rng() * Double(pool.count)).rounded(.down))
            s.lastPraise = pool[min(max(index, 0), pool.count - 1)]
            return s.lastPraise
        }

        mutating func showCorrect() {
            guard var fb = s.feedback, let result = fb.result else { return }
            s.phase = .feedback(.correct)
            // "Genau!" right above a "Genau: …" correction would read oddly; a synonym shows the
            // word the card asked for.
            let praise = fb.synonym ? L("Auch richtig!") : result.exact ? pickPraise() : L("Richtig!")
            fb.praise = praise
            s.feedback = fb
            let ms = s.options.autoAdvance ? (result.exact ? WriteFlow.advanceMs : WriteFlow.advanceMsWithNotes) : 0
            if result.exact {
                announce(praise)
            } else {
                announce("\(praise) \(fb.exactLabel) \(result.expectedDisplay)")
            }
            lock()
            if ms > 0 { startAdvance(ms) }
        }

        mutating func showIncorrect() {
            guard var fb = s.feedback, let info = s.question else { return }
            fb.copy = s.options.copyAnswer
            s.feedback = fb
            s.phase = fb.copy ? .copy : .feedback(fb.dontKnow ? .dontKnow : .wrong)
            if fb.copy {
                // The copy field starts empty.
                s.input = ""
                s.inputInvalid = false
            }
            let lead = fb.dontKnow ? L("Kein Problem.") : L("Nicht ganz.")
            let answer = L("Richtige Antwort: %@.", info.expected)
            let hint = fb.hintLabel.map { " \($0)." } ?? ""
            let tail = fb.copy ? " " + L("Tippe die richtige Antwort ab.") : ""
            announce("\(lead) \(answer)\(hint)\(tail)")
            lock()
        }

        /// The copy typed out continues by itself after a short beat, like Return (`CopyStep`);
        /// typing on so that it no longer is stops the countdown.
        mutating func continueTypedOutCopy() {
            guard !s.isBlocked, s.phase == .copy, let info = infoFor(s.question) ?? s.question else { return }
            guard CopyStep.isTypedOut(s.input, expected: info.expected, tolerance: s.options.tolerance, lang: info.answerLang)
            else {
                clearAdvance()
                return
            }
            if s.autoAdvance == nil { startAdvance(CopyStep.advanceMs) }
        }

        mutating func submitCopy(_ value: String) {
            guard s.phase.isMiss, let fb = s.feedback else { return }
            guard fb.copy else {
                continueNext(fromUser: true)
                return
            }
            let info = infoFor(s.question) ?? s.question
            if WriteFlow.copyAccepted(value, question: info, tolerance: s.options.tolerance) {
                continueNext(fromUser: true)
            } else {
                s.inputInvalid = true
                s.rejections += 1
                announce(L("Noch nicht ganz – tippe die richtige Antwort genau ab."))
            }
        }

        /// `fromUser`: keys and clicks respect the short lock, so one press never skips two steps.
        mutating func continueNext(fromUser: Bool) {
            guard s.phase.isCard, s.phase != .question, let session = s.session else { return }
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
            if WriteSession.isRoundOver(session) { afterRoundEnds() } else { showNextQuestion() }
        }

        mutating func overrideLast() {
            guard s.phase.isMiss, let fb = s.feedback, fb.canOverride, let info = s.question,
                let session = s.session
            else { return }
            clearAdvance()
            effects.append(.overrideLastAnswer(cardId: info.cardId))
            s.session = WriteSession.override(session, qid: info.qid, now: env.now)
            s.pending = nil
            persist()
            effects.append(.toast(.countedAsCorrect))
            continueNext(fromUser: false)
        }

        // MARK: Rounds and results

        mutating func afterRoundEnds() {
            guard let session = s.session else { return }
            if session.order.isEmpty {
                sessionEmptied()
            } else if WriteSession.isFinished(session) {
                finishSession()
            } else if WriteSession.isRoundOver(session) {
                showSummary()
            } else {
                showNextQuestion()
            }
        }

        mutating func leaveCard() {
            s.question = nil
            s.feedback = nil
            s.input = ""
            s.inputInvalid = false
        }

        mutating func showSummary() {
            clearAdvance()
            guard let session = s.session else { return }
            let summary = WriteSession.roundSummary(session)
            leaveCard()
            s.phase = .summary
            s.summary = summary
            s.results = nil
            announce(
                L("Runde %@ geschafft: %@ von %@ richtig.", "\(summary.round)", "\(summary.correct)", "\(summary.total)"))
            lock()
        }

        mutating func goNextRound(fromUser: Bool) {
            guard s.phase == .summary, !(fromUser && locked), let session = s.session else { return }
            let next = WriteSession.nextRound(session, rng: env.rng, now: env.now)
            s.session = next
            persist()
            if WriteSession.isFinished(next) { finishSession() } else { showNextQuestion(animate: false) }
        }

        /// write.js `finish`: closes the last round into the history and stamps `finishedAt`.
        mutating func finishSession() {
            clearAdvance()
            guard let session = s.session else { return }
            s.session = WriteSession.nextRound(session, rng: env.rng, now: env.now)
            persist()
            showResults()
        }

        mutating func showResults() {
            guard let session = s.session else { return }
            leaveCard()
            s.phase = .results
            s.summary = nil
            let stats = WriteSession.finalStats(session)
            if stats.total == 0 {
                sessionEmptied()
                return
            }
            s.results = Results(
                stats: stats, retryCardIds: stats.missedCardIds.filter(usable), cardCount: cardIdsInSession().count,
                bothDirections: session.setOptions.answerWith == .both)
            let percent = JSCompat.numberToString(JSCompat.round(stats.accuracy * 100))
            announce(L("Geschafft! %@ Prozent beim ersten Versuch richtig.", percent))
            lock()
        }

        mutating func retryMissed() {
            guard s.phase == .results, let missed = s.results?.retryCardIds, !missed.isEmpty else { return }
            startFresh(.cardIds(missed))
        }

        // MARK: Messages

        mutating func showEmpty(_ subset: StudySubset) {
            clearAdvance()
            leaveCard()
            s.pending = nil
            s.phase = .empty
            s.emptySubset = subset
            s.summary = nil
            s.results = nil
        }

        /// Every question of the session vanished (cards deleted elsewhere).
        mutating func sessionEmptied() {
            if s.set?.cards.contains(where: WriteFlow.isUsableCard) == true {
                startFresh(namedSubset())
            } else {
                showEmpty(.all)
            }
        }

        mutating func showGone() {
            clearAdvance()
            leaveCard()
            s.phase = .missing
            s.set = nil
            s.session = nil
            s.pending = nil
            s.summary = nil
            s.results = nil
            s.emptySubset = nil
            s.overlay = nil
            s.prompt = nil
            indexCards()
        }

        // MARK: Card edits

        mutating func toggleStar() {
            guard let info = activeInfo(), var set = s.set,
                let index = set.cards.firstIndex(where: { $0.id == info.cardId })
            else { return }
            effects.append(.toggleStar(cardId: info.cardId))
            set.cards[index].starred.toggle()
            s.set = set
            indexCards()
            if s.question?.cardId == info.cardId { s.question?.starred = set.cards[index].starred }
        }

        mutating func openEdit() {
            guard let info = activeInfo(), cards[info.cardId] != nil else { return }
            let resumesTimer = s.autoAdvance != nil
            clearAdvance()
            s.overlay = .editor(question: info.sessionQuestion, focus: info.ask, resumesTimer: resumesTimer)
        }

        mutating func saveEdit(_ edited: Card) {
            guard case let .editor(question, _, resumesTimer)? = s.overlay, var set = s.set,
                let index = set.cards.firstIndex(where: { $0.id == question.cardId })
            else { return }
            let term = JSCompat.trim(edited.term)
            let definition = JSCompat.trim(edited.definition)
            // The editor never saves an empty side.
            guard !term.isEmpty, !definition.isEmpty else { return }
            set.cards[index].term = term
            set.cards[index].definition = definition
            effects.append(.updateCard(set.cards[index]))
            s.set = set
            indexCards()
            applyCardEdit(question)
            effects.append(.toast(.cardSaved))
            s.overlay = nil
            resumeAfterOverlay(resumesTimer: resumesTimer, copyChanged: false)
        }

        mutating func applyCardEdit(_ question: SessionQuestion) {
            guard let updated = questionInfo(question) else { return }
            if s.phase.isMiss, var fb = s.feedback {
                s.question = updated
                // If the corrected card now accepts what was typed, offer to count it.
                let r = !fb.dontKnow && WriteFlow.hasText(fb.given) ? grade(updated, fb.given).result : nil
                fb.editedCorrect = r?.correct == true
                s.feedback = fb
                showIncorrect()
            } else {
                s.question = updated
            }
        }

        // MARK: Options and dialogs

        mutating func openOptions() {
            guard s.phase.isCard || s.phase == .summary || s.phase == .results else { return }
            let resumesTimer = s.autoAdvance != nil
            clearAdvance()
            s.overlay = .options(before: OptionsBaseline(s.options), resumesTimer: resumesTimer)
        }

        mutating func closeOverlay(restartRequested: Bool) {
            switch s.overlay {
            case nil: return
            case let .editor(_, _, resumesTimer)?:
                s.overlay = nil
                resumeAfterOverlay(resumesTimer: resumesTimer, copyChanged: false)
            case let .options(before, resumesTimer)?:
                s.overlay = nil
                afterOptions(before: before, resumesTimer: resumesTimer, restartRequested: restartRequested)
            }
        }

        mutating func afterOptions(before: OptionsBaseline, resumesTimer: Bool, restartRequested: Bool) {
            if restartRequested {
                confirmRestart(resumesTimer: resumesTimer)
                return
            }
            // Direction and order applied when they were changed (`applyOptions`).
            resumeAfterOverlay(resumesTimer: resumesTimer, copyChanged: s.options.copyAnswer != before.copyAnswer)
        }

        /// Direction and «Mischen» apply to the running session at once (since 25.11.2026; before,
        /// they asked «Neu starten?» in the options and were ignored when changed elsewhere): the
        /// open questions follow them (`WriteSession.setOptions`). The question on screen is asked
        /// anew when it turned around or went; the round summary shows what is left.
        mutating func applyOptions() {
            guard let session = s.session, session.finishedAt == nil, let set = s.set else { return }
            let next = WriteSession.setOptions(
                session, answerWith: s.options.answerWith, shuffle: s.options.shuffle, cards: set.cards, rng: env.rng,
                now: env.now)
            guard next != session else { return }
            s.session = next
            persist()
            switch s.phase {
            case .question where WriteSession.current(next)?.qid != s.question?.qid: afterRoundEnds()
            case .summary: afterRoundEnds()
            default: break
            }
        }

        /// Hands the step back after a sheet or alert: restarts the auto-advance it paused and
        /// shows the copy step when it was switched on or off.
        mutating func resumeAfterOverlay(resumesTimer: Bool, copyChanged: Bool) {
            s.focusSerial += 1
            guard s.phase.isCard else { return }
            if s.phase == .feedback(.correct) && (resumesTimer || s.options.autoAdvance) {
                showCorrect()
            } else if s.phase.isMiss && copyChanged {
                showIncorrect()
            } else if s.phase == .copy {
                continueTypedOutCopy()
            }
        }

        mutating func confirmRestart(resumesTimer: Bool) {
            guard s.phase != .empty, s.phase != .missing, s.phase != .starting else { return }
            let timerWasRunning = resumesTimer || s.autoAdvance != nil
            clearAdvance()
            s.prompt = .restart(resumesTimer: timerWasRunning)
        }

        mutating func answerPrompt(_ confirmed: Bool) {
            guard let prompt = s.prompt else { return }
            s.prompt = nil
            switch prompt {
            case let .restart(resumesTimer):
                if confirmed {
                    startFresh(s.session?.subset ?? .all)
                } else {
                    resumeAfterOverlay(resumesTimer: resumesTimer, copyChanged: false)
                }
            case let .replaceRound(wanted, saved, feedback):
                if confirmed {
                    startFresh(wanted)
                } else {
                    // The round's own subset applies.
                    resumeSaved(saved, feedback: feedback, showResultsAgain: false, wanted: nil)
                }
            }
        }

        // MARK: Live updates

        /// The card being edited was deleted elsewhere: the editor closes (resuming the step).
        mutating func closeEditorOfDeletedCard() {
            guard case let .editor(question, _, resumesTimer)? = s.overlay, cards[question.cardId] == nil else {
                return
            }
            s.overlay = nil
            resumeAfterOverlay(resumesTimer: resumesTimer, copyChanged: false)
        }

        /// The set changed outside the flow (write.js `reconcile`).
        mutating func reconcile(_ fresh: VocabSet?) {
            guard let fresh else {
                showGone()
                return
            }
            s.set = fresh
            indexCards()
            defer { closeEditorOfDeletedCard() }
            guard s.session != nil else { return }
            let pruned = pruneSession()
            if pruned { persist() }
            switch s.phase {
            case .question:
                if let info = questionInfo(s.session.flatMap(WriteSession.current)) {
                    s.question = info
                } else {
                    afterRoundEnds()
                }
            case .feedback, .copy:
                if let info = infoFor(s.question) { s.question = info }
            case .summary where pruned:
                afterRoundEnds()
            case .results where pruned:
                showResults()
            default:
                break
            }
        }
    }
}
