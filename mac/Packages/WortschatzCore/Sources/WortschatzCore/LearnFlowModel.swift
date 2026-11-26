import Foundation

// Pure helpers of the Learn screen: a port of src/screens/learn-model.js (praise, resuming a stored
// session and its open "Nicht ganz" screen, options that need a restart, option texts after edits,
// checkpoint status, the segmented progress bar and the German copy texts) and of the parts of
// src/screens/write-model.js the Learn screen uses (question texts, grading, the copy step).
// UI copy follows Swiss spelling: "ss", never the sharp s.

extension LearnFlow {
    // MARK: - Copy

    /// Praise after a correct answer, varied (never the same twice in a row).
    public static var PRAISE: [String] { [L("Super!"), L("Klasse!"), L("Genau!"), L("Weiter so!"), L("Stark!")] }
    /// Title after a wrong answer.
    public static var MISS_TITLE: String { L("Nicht ganz – das lernst du noch!") }
    /// Title after "Weiss ich nicht?" (short enough for one line).
    public static var DONT_KNOW_TITLE: String { L("Kein Problem – merk sie dir!") }
    /// Title of a correct answer that belongs to another card with the same prompt.
    public static var SYNONYM_TITLE: String { L("Auch richtig!") }
    /// Title of a correct answer that was accepted with a tolerance (not exact).
    public static var TOLERATED_TITLE: String { L("Richtig!") }
    /// The intro hint shown until the first checkpoint.
    public static var INTRO_HINT: String {
        L("Neue Begriffe kommen zuerst als Multiple Choice – beim nächsten Mal schreibst du sie.")
    }
    /// Shown when the edited card now accepts what was typed.
    public static var EDITED_CORRECT_TEXT: String { L("Mit deiner Korrektur stimmt deine Antwort jetzt.") }
    /// Toast when a session is resumed with answers.
    public static var WELCOME_BACK: String { L("Willkommen zurück – weiter geht's") }
    /// The mark of a repetition question (Wiederholungsfrage) of a mastered card.
    public static var REVIEW_LABEL: String { L("Wiederholung") }
    /// After a missed repetition question: the card is learned again.
    public static var DEMOTED_TEXT: String { L("Wieder am Lernen") }
    /// The mark of a recheck (Nachkontrolle) of a card missed earlier in the session.
    public static var RECHECK_LABEL: String { L("Nachkontrolle") }
    /// Its help text.
    public static var RECHECK_HELP: String { L("Diesen Begriff hattest du vorhin falsch. Er kommt zur Kontrolle nochmals.") }
    /// The hint at the first recheck of a session (a toast with "Optionen", `RECHECK_HINT_MS` long).
    public static var RECHECK_HINT: String { L("Merke: Die Nachkontrolle kannst du in den Optionen ausschalten.") }
    public static let RECHECK_HINT_MS = 10_000

    /// Auto-advance after a correct answer, and after one with notes ("Genau: …" needs reading).
    public static let ADVANCE_MS = 900
    public static let ADVANCE_MS_WITH_NOTES = 1800
    /// Key presses this soon after a transition are swallowed, so one press never skips a step.
    public static let INPUT_LOCK_MS: Double = 280
    /// After a correct answer a press within the input lock is not lost: it moves on as soon as
    /// the lock ends. Presses closer than this to the answer count as the answering press itself.
    public static let SKIP_MIN_GAP_MS: Double = 50
    /// The progress bar has one segment per round-sized batch, at most this many.
    public static let MAX_SEGMENTS = 12
    /// A stored written answer is kept up to this many UTF-16 units.
    public static let MAX_GIVEN = 1000

    private static let defaultRoundSize = 7

    /// A semantic tone (chips, toasts); the design system maps it to colours.
    public enum Tone: String, Codable, Sendable, Equatable, Hashable {
        case neutral, success, warning
    }

    /// `pickPraise(previous, rng, pool)`: a uniformly picked entry of `pool` other than
    /// `previous` (falls back to the whole pool when nothing else is left). Tolerates an rng
    /// returning values outside [0, 1).
    public static func pickPraise(_ previous: String? = nil, rng: RNG = systemRNG(), pool: [String] = PRAISE) -> String {
        let list = pool.isEmpty ? PRAISE : pool
        let others = list.filter { $0 != previous }
        let from = others.isEmpty ? list : others
        let r = (rng() * Double(from.count)).rounded(.down)
        if !(r >= 0) { return from[0] }
        return from[r > Double(from.count - 1) ? from.count - 1 : Int(r)]
    }

    // MARK: - Resuming

    /// `canResumeLearn`: a stored session is resumed unless a fresh one was requested, it is
    /// finished or empty, or a different subset was asked for (nil = any).
    public static func canResumeLearn(_ saved: LearnState?, forceNew: Bool = false, subset: StudySubset? = nil) -> Bool {
        guard !forceNew, let saved, saved.finishedAt == nil, !saved.order.isEmpty, !LearnEngine.isFinished(saved)
        else { return false }
        return subset == nil || saved.subset == subset
    }

    /// Whether the session has answers (in this round or in earlier ones).
    public static func hasLearnAnswers(_ state: LearnState?) -> Bool {
        guard let state else { return false }
        return state.answered > 0 || !state.rounds.isEmpty || !state.roundLog.isEmpty
    }

    /// `pendingLearnFeedback(state, feedback)`: the "Nicht ganz" screen that was open when the
    /// session was left, from the `feedback` record stored next to the state. It is valid while it
    /// describes the state's last answer and that answer is still counted as wrong (not
    /// overridden, round not closed). Returns the cleaned record or nil.
    public static func pendingFeedback(_ state: LearnState, _ feedback: JSONValue?) -> PendingFeedback? {
        guard let f = feedback?.objectValue, let last = state.last, !last.correct else { return nil }
        let cardId = last.cardId
        guard let qid = f["qid"]?.stringValue, JSCompat.identical(qid, last.qid) else { return nil }
        guard let rawId = f["cardId"], rawId != .null, JSCompat.jsString(rawId) == cardId else { return nil }
        guard state.order.contains(cardId) else { return nil }
        let type: QuestionType = f["type"] == .string("mc") ? .mc : .written
        guard type == last.type else { return nil }
        if type == .mc {
            guard let choices = cleanChoices(f["choices"], cardId) else { return nil }
            let chosen = f["chosen"].flatMap { $0 == .null ? nil : JSCompat.jsString($0) }
            // A chosen option must be one of the wrong ones (nil = "Weiss ich nicht").
            if let chosen, chosen == cardId || !choices.contains(where: { $0.cardId == chosen }) { return nil }
            return PendingFeedback(mcQid: qid, cardId: cardId, ask: last.ask, choices: choices, chosen: chosen)
        }
        let given = f["given"]?.stringValue.map(prefixUTF16) ?? ""
        return PendingFeedback(
            writtenQid: qid, cardId: cardId, ask: last.ask, given: given,
            dontKnow: f["dontKnow"] == .bool(true) || !hasText(given))
    }

    /// `pendingFeedback` for a typed record (validated the same way).
    public static func pendingFeedback(_ state: LearnState, _ feedback: PendingFeedback?) -> PendingFeedback? {
        guard let feedback, let json = try? JSONValue(encoding: feedback) else { return nil }
        return pendingFeedback(state, json)
    }

    // MARK: - Restart

    /// "Neu starten?" in a running session: what the new one covers.
    public static func restartSessionMessage(_ subset: StudySubset = .all) -> String {
        switch subset {
        case .starred:
            L(
                "Du beginnst eine neue Lerneinheit mit allen markierten Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert.")
        case .missed:
            L(
                "Du beginnst eine neue Lerneinheit mit allen zuletzt falsch beantworteten Begriffen. Dein Lernfortschritt bleibt gespeichert.")
        case .cardIds:
            L(
                "Du beginnst eine neue Lerneinheit mit den ausgewählten Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert.")
        case .all, .learning:
            L(
                "Du beginnst eine neue Lerneinheit mit allen Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert.")
        }
    }

    /// What a new session with a subset asks (for "Laufende Lerneinheit beenden?").
    public static func subsetWhat(_ subset: StudySubset) -> String {
        switch subset {
        case .all: L("alle Begriffe")
        case .starred: L("nur die markierten Begriffe")
        case .learning: L("nur die nicht gemeisterten Begriffe")
        case .missed: L("nur die zuletzt falsch beantworteten Begriffe")
        case .cardIds: L("eine neue Auswahl")
        }
    }

    // MARK: - Question texts

    /// The texts of a question's options from the current cards (so edits show at once); the
    /// stored text is kept for a card that no longer exists or has an empty side.
    public static func choiceTexts(_ choices: [Choice], cards: [Card], ask: AskSide) -> [Choice] {
        let byId = cardsById(cards)
        return choices.map { c in
            let live = byId[c.cardId].map { JSCompat.trim(Synonyms.answerSide($0, ask: ask)) } ?? ""
            return Choice(cardId: c.cardId, text: live.isEmpty ? c.text : live)
        }
    }

    /// Everything the question card shows for question `q` of `card` (`questionInfo`).
    /// `ask == .term`: the definition is shown and the term typed (and vice versa).
    public static func questionInfo(
        _ q: LearnEngine.Question, card: Card, cards: [Card], termLang: Lang, defLang: Lang
    ) -> QuestionInfo {
        let askTerm = q.ask == .term
        let promptLang = askTerm ? defLang : termLang
        let answerLang = askTerm ? termLang : defLang
        let sameLang = termLang == defLang
        let stored = q.type == .mc ? q.choices ?? [] : []
        return QuestionInfo(
            qid: q.qid, cardId: card.id, type: q.type, ask: q.ask, prompt: askTerm ? card.definition : card.term,
            expected: askTerm ? card.term : card.definition, promptLang: promptLang, answerLang: answerLang,
            promptLabel: sameLang || promptLang == .other
                ? (askTerm ? L("Definition") : L("Begriff")) : Labels.langName(promptLang),
            placeholder: sameLang || answerLang == .other
                ? L("Antwort eingeben") : L("Antwort auf %@ eingeben", Labels.langName(answerLang)),
            placeholderShort: sameLang || answerLang == .other
                ? L("Antwort eingeben") : L("Auf %@ …", Labels.langName(answerLang)),
            starred: card.starred, choices: choiceTexts(stored, cards: cards, ask: q.ask), storedChoices: stored,
            isReview: q.isReview, isRecheck: q.isRecheck)
    }

    /// Grades the written answer of `info` (`gradeQuestion`): an answer that is right for another
    /// card with the same prompt counts too (the learner cannot tell such cards apart), and so does
    /// one of `extraAnswers` (synonyms that are not in the set).
    public static func gradeQuestion(
        _ info: QuestionInfo, given: String, cards: [Card], tolerance: Tolerance, extraAnswers: [String] = []
    ) -> SynonymGradeResult {
        guard let card = cards.first(where: { $0.id == info.cardId }) else {
            return SynonymGradeResult(
                result: Grading.grade(given: given, expected: info.expected, tolerance: tolerance, lang: info.answerLang))
        }
        return Synonyms.gradeWithSynonyms(
            given: given, card: card, cards: cards, ask: info.ask, tolerance: tolerance, answerLang: info.answerLang,
            extraAnswers: extraAnswers)
    }

    /// The copy step after a miss needs the asked card's answer itself (no synonyms).
    public static func copyAccepted(_ value: String, info: QuestionInfo, tolerance: Tolerance) -> Bool {
        hasText(value)
            && Grading.grade(given: value, expected: info.expected, tolerance: tolerance, lang: info.answerLang).correct
    }

    // MARK: - Checkpoint and finish texts

    /// The status chip of a card by its stage.
    public struct StageStatus: Codable, Sendable, Equatable, Hashable {
        public var status: CardStatus
        public var label: String
        public var tone: Tone
        /// SF Symbol for the chip, if any.
        public var systemImage: String?

        public init(status: CardStatus, label: String, tone: Tone, systemImage: String?) {
            self.status = status
            self.label = label
            self.tone = tone
            self.systemImage = systemImage
        }
    }

    /// Gemeistert / Am Lernen / Noch neu.
    public static func stageStatus(_ stage: Int) -> StageStatus {
        if stage >= 2 {
            return StageStatus(status: .mastered, label: L("Gemeistert"), tone: .success, systemImage: "checkmark")
        }
        if stage == 1 { return StageStatus(status: .learning, label: L("Am Lernen"), tone: .warning, systemImage: nil) }
        return StageStatus(status: .new, label: L("Noch neu"), tone: .neutral, systemImage: nil)
    }

    /// The checkpoint chip of a card answered in the round: stage 0 there means "answered
    /// wrong", which the counters show as Am Lernen, not as Neu.
    public static func checkpointStatus(_ stage: Int) -> StageStatus {
        stageStatus(stage >= 1 ? stage : 1)
    }

    /// "18 von 52 gemeistert"
    public static func masteredLine(_ mastered: Int, _ total: Int) -> String {
        L("%@ von %@ gemeistert", "\(mastered)", "\(total)")
    }

    /// The checkpoint title by the round's share of correct answers.
    public static func checkpointTitle(_ ratio: Double) -> String {
        if ratio >= 0.9 { return L("Hervorragend!") }
        if ratio >= 0.7 { return L("Gut gemacht!") }
        if ratio >= 0.4 { return L("Du machst Fortschritte!") }
        return L("Dranbleiben – das wird!")
    }

    /// What is left after a checkpoint, e.g. "Noch 34 Begriffe, bis alles sitzt."
    public static func remainingText(mastered: Int, total: Int) -> String {
        let left = max(0, total - mastered)
        if left == 0 { return L("Alles sitzt!") }
        return L("Noch %@, bis alles sitzt.", Labels.plural(left, "Begriff", "Begriffe"))
    }

    /// "5 richtige Antworten von 7 in dieser Runde. Noch 34 Begriffe, bis alles sitzt."
    public static func checkpointText(_ cp: LearnEngine.Checkpoint) -> String {
        L(
            "%@ von %@ in dieser Runde. %@", Labels.plural(cp.correct, "richtige Antwort", "richtige Antworten"),
            "\(cp.answered)", remainingText(mastered: cp.counts.mastered, total: cp.counts.total))
    }

    /// "Du hast alle markierten Begriffe gemeistert!" (the finish screen's title). The scope's
    /// adjective (ausgewählten, markierten, offenen, falsch beantworteten; none for the whole set)
    /// is part of each whole sentence.
    public static func finishTitle(_ subset: StudySubset = .all, total: Int = 2) -> String {
        let one = total == 1
        switch subset {
        case .cardIds:
            return one ? L("Du hast den ausgewählten Begriff gemeistert!") : L("Du hast alle ausgewählten Begriffe gemeistert!")
        case .starred:
            return one ? L("Du hast den markierten Begriff gemeistert!") : L("Du hast alle markierten Begriffe gemeistert!")
        case .learning:
            return one ? L("Du hast den offenen Begriff gemeistert!") : L("Du hast alle offenen Begriffe gemeistert!")
        case .missed:
            return one
                ? L("Du hast den falsch beantworteten Begriff gemeistert!")
                : L("Du hast alle falsch beantworteten Begriffe gemeistert!")
        case .all:
            return one ? L("Du hast den Begriff gemeistert!") : L("Du hast alle Begriffe gemeistert!")
        }
    }

    /// "Alle 3 markierten Begriffe in 2 Runden gemeistert – stark!" or "44 Begriffe in 16 Runden
    /// gemeistert, 6 sassen schon vorher – stark!" (cards mastered before the session apart).
    public static func finishSubtitle(total: Int, rounds: Int, alreadyMastered: Int = 0, subset: StudySubset = .all)
        -> String
    {
        let before = max(0, alreadyMastered)
        let learned = total - before
        if before > 0 && learned > 0 {
            let cards = Labels.plural(learned, "Begriff", "Begriffe")
            if rounds > 0 {
                let inRounds = Labels.plural(rounds, "Runde", "Runden")
                return before == 1
                    ? L("%@ in %@ gemeistert, %@ sass schon vorher – stark!", cards, inRounds, "\(before)")
                    : L("%@ in %@ gemeistert, %@ sassen schon vorher – stark!", cards, inRounds, "\(before)")
            }
            return before == 1
                ? L("%@ gemeistert, %@ sass schon vorher – stark!", cards, "\(before)")
                : L("%@ gemeistert, %@ sassen schon vorher – stark!", cards, "\(before)")
        }
        if rounds > 0 {
            return finishSubtitleInRounds(subset, total: total, rounds: Labels.plural(rounds, "Runde", "Runden"))
        }
        let one = total == 1
        let n = "\(total)"
        switch subset {
        case .cardIds:
            return one ? L("Den ausgewählten Begriff gemeistert – stark!") : L("Alle %@ ausgewählten Begriffe gemeistert – stark!", n)
        case .starred:
            return one ? L("Den markierten Begriff gemeistert – stark!") : L("Alle %@ markierten Begriffe gemeistert – stark!", n)
        case .learning:
            return one ? L("Den offenen Begriff gemeistert – stark!") : L("Alle %@ offenen Begriffe gemeistert – stark!", n)
        case .missed:
            return one
                ? L("Den falsch beantworteten Begriff gemeistert – stark!")
                : L("Alle %@ falsch beantworteten Begriffe gemeistert – stark!", n)
        case .all:
            return one ? L("Den Begriff gemeistert – stark!") : L("Alle %@ Begriffe gemeistert – stark!", n)
        }
    }

    /// `finishSubtitle` with rounds ("Alle 3 markierten Begriffe in 2 Runden gemeistert – stark!");
    /// `rounds` is the plural text ("2 Runden").
    private static func finishSubtitleInRounds(_ subset: StudySubset, total: Int, rounds: String) -> String {
        let one = total == 1
        let n = "\(total)"
        switch subset {
        case .cardIds:
            return one
                ? L("Den ausgewählten Begriff in %@ gemeistert – stark!", rounds)
                : L("Alle %@ ausgewählten Begriffe in %@ gemeistert – stark!", n, rounds)
        case .starred:
            return one
                ? L("Den markierten Begriff in %@ gemeistert – stark!", rounds)
                : L("Alle %@ markierten Begriffe in %@ gemeistert – stark!", n, rounds)
        case .learning:
            return one
                ? L("Den offenen Begriff in %@ gemeistert – stark!", rounds)
                : L("Alle %@ offenen Begriffe in %@ gemeistert – stark!", n, rounds)
        case .missed:
            return one
                ? L("Den falsch beantworteten Begriff in %@ gemeistert – stark!", rounds)
                : L("Alle %@ falsch beantworteten Begriffe in %@ gemeistert – stark!", n, rounds)
        case .all:
            return one
                ? L("Den Begriff in %@ gemeistert – stark!", rounds) : L("Alle %@ Begriffe in %@ gemeistert – stark!", n, rounds)
        }
    }

    public static func finishSubtitle(_ stats: LearnEngine.FinalStats, subset: StudySubset = .all) -> String {
        finishSubtitle(total: stats.total, rounds: stats.rounds, alreadyMastered: stats.alreadyMastered, subset: subset)
    }

    /// "12 gemeisterte Begriffe wiederholt, 2 davon sind wieder am Lernen." (finish screen); nil
    /// before the first repetition question.
    public static func reviewLine(_ stats: LearnEngine.ReviewStats) -> String? {
        guard stats.asked > 0 else { return nil }
        let asked = Labels.plural(stats.asked, "gemeisterten Begriff", "gemeisterte Begriffe")
        let missed = stats.asked - stats.kept
        if missed == 0 {
            return stats.asked == 1 ? L("%@ wiederholt, er sass noch.", asked) : L("%@ wiederholt, alle sassen noch.", asked)
        }
        return missed == 1
            ? L("%@ wiederholt, %@ davon ist wieder am Lernen.", asked, "\(missed)")
            : L("%@ wiederholt, %@ davon sind wieder am Lernen.", asked, "\(missed)")
    }

    /// How many cards a scope covers, for the "everything mastered" screen.
    public static func scopeText(_ subset: StudySubset, count: Int) -> String {
        if subset == .starred {
            return count == 1 ? L("den markierten Begriff") : L("alle %@ markierten Begriffe", "\(count)")
        }
        return count == 1 ? L("den Begriff") : L("alle %@ Begriffe", "\(count)")
    }

    /// "18 von 52 gemeistert, 7 am Lernen, 27 neu"
    public static func progressText(fresh: Int, learning: Int, mastered: Int, total: Int) -> String {
        L("%@ von %@ gemeistert, %@ am Lernen, %@ neu", "\(mastered)", "\(total)", "\(learning)", "\(fresh)")
    }

    public static func progressText(_ counts: LearnEngine.Counts) -> String {
        progressText(fresh: counts.fresh, learning: counts.learning, mastered: counts.mastered, total: counts.total)
    }

    // MARK: - Segmented progress bar

    /// One segment per round-sized batch, at least one, at most `MAX_SEGMENTS`.
    public static func segmentCount(total: Int, roundSize: Int?) -> Int {
        guard total > 0 else { return 1 }
        let size = (roundSize ?? 0) >= 1 ? roundSize! : defaultRoundSize
        return max(1, min(MAX_SEGMENTS, (total + size - 1) / size))
    }

    /// The fill of one bar segment (0…1): mastered (green) and reached = mastered + learning.
    public struct SegmentFill: Codable, Sendable, Equatable, Hashable {
        public var mastered: Double
        public var reached: Double

        public init(mastered: Double, reached: Double) {
            self.mastered = mastered
            self.reached = reached
        }
    }

    /// Fills the bar from the left: mastered, then learning.
    public static func segmentFills(mastered: Int, learning: Int, total: Int, count: Int) -> [SegmentFill] {
        let n = max(1, count)
        let t = Double(max(0, total))
        func share(_ v: Int) -> Double { t > 0 ? Double(max(0, v)) / t * Double(n) : 0 }
        let m = share(mastered)
        let r = share(mastered + learning)
        func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
        return (0..<n).map { i in SegmentFill(mastered: clamp01(m - Double(i)), reached: clamp01(r - Double(i))) }
    }

    // MARK: - Internals

    /// JS `typeof v === 'string' && v.trim() !== ''`.
    static func hasText(_ s: String) -> Bool {
        s.unicodeScalars.contains { !JSCompat.isWhitespace($0) }
    }

    /// Cards by id; the first card wins for a repeated id (like the engine's card list).
    static func cardsById(_ cards: [Card]) -> [String: Card] {
        var out: [String: Card] = [:]
        for card in cards where out[card.id] == nil { out[card.id] = card }
        return out
    }

    /// A card can be asked only when both sides have text.
    static func isUsable(_ card: Card?) -> Bool {
        guard let card else { return false }
        return hasText(card.term) && hasText(card.definition)
    }

    /// JS `s.slice(0, MAX_GIVEN)` (UTF-16 units; a split surrogate pair is dropped).
    private static func prefixUTF16(_ s: String) -> String {
        let units = s.utf16
        guard units.count > MAX_GIVEN else { return s }
        return String(units.prefix(MAX_GIVEN)) ?? String(units.prefix(MAX_GIVEN - 1)) ?? ""
    }

    /// `cleanChoices`: each card id once; kept only with two or more options including `cardId`.
    private static func cleanChoices(_ v: JSONValue?, _ cardId: String) -> [Choice]? {
        guard let list = v?.arrayValue else { return nil }
        var seen = Set<String>()
        var out: [Choice] = []
        for c in list {
            guard let o = c.objectValue, let raw = o["cardId"], raw != .null, raw != .string("") else { continue }
            let id = JSCompat.jsString(raw)
            guard seen.insert(id).inserted else { continue }
            out.append(Choice(cardId: id, text: o["text"]?.stringValue ?? ""))
        }
        return out.count >= 2 && seen.contains(cardId) ? out : nil
    }

}
