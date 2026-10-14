import Foundation

// The texts and pure view logic of Write mode: the parts of src/screens/write-card.js and
// write-views.js that do not touch the DOM (answer diff, summary and results texts, empty states,
// dialog texts). German UI copy with Swiss spelling ("ss", never the sharp s).

extension WriteFlow {
    // MARK: - Question card

    /// The label of the answer field: "Deine Antwort", or "Tippe die richtige Antwort ab" in the
    /// copy step.
    public static func fieldLabel(_ state: State) -> String {
        state.phase == .copy ? "Tippe die richtige Antwort ab" : "Deine Antwort"
    }

    /// The placeholder of the answer field (`short` for narrow layouts).
    public static func fieldPlaceholder(_ state: State, short: Bool = false) -> String {
        if state.phase == .copy { return short ? "Antwort abtippen" : "Richtige Antwort abtippen" }
        guard let q = state.question else { return "Antwort eingeben" }
        return short ? q.placeholderShort : q.placeholder
    }

    /// "Runde 2 · nur die Begriffe, die noch nicht sassen" above the card from round 2 on.
    public static func roundNote(_ state: State) -> String? {
        guard state.phase.isCard, let c = counters(state), c.round > 1 else { return nil }
        return "Runde \(c.round) · nur die Begriffe, die noch nicht sassen"
    }

    /// The VoiceOver label of the sidebar counters.
    public static func countersAccessibilityLabel(_ c: WriteSession.Counters) -> String {
        "Runde \(c.round): \(c.remaining) verbleibend, \(c.incorrect) falsch, \(c.correct) von \(c.total) richtig"
    }

    /// The answer diff under "Deine Antwort" (write-card.js `diffView`): segments against the
    /// closest accepted variant, or nil when the answer is a different word altogether (less than
    /// half of the typed characters match) and should be shown as plain text. In the segments,
    /// `.del` is typed but wrong and `.add` is missing.
    public static func answerDiff(given: String, expected: String, lang: Lang?) -> [DiffSegment]? {
        let parts = closestDiff(given: given, expected: expected, lang: lang)
        let same = parts.reduce(0) { $0 + ($1.type == .same ? nonWhitespaceLength($1.text) : 0) }
        let typed = nonWhitespaceLength(given)
        if typed == 0 || Double(same) / Double(typed) < 0.5 { return nil }
        return parts
    }

    /// The diff against whichever accepted variant is closest to what was typed
    /// (write-card.js `closestDiff`), so a small slip in "le monsieur" is not drowned by the
    /// missing ", messieurs".
    public static func closestDiff(given: String, expected: String, lang: Lang?) -> [DiffSegment] {
        var candidates = [expected]
        for alt in Grading.splitAlternatives(expected, lang: lang)
        where !alt.isEmpty && !candidates.contains(where: { JSCompat.identical($0, alt) }) {
            candidates.append(alt)
        }
        var best: [DiffSegment]?
        var bestCost = Int.max
        for target in candidates {
            let parts = Grading.diffAnswer(given, target)
            let cost = parts.reduce(0) { $0 + ($1.type == .same ? 0 : $1.text.utf16.count) }
            if cost < bestCost {
                best = parts
                bestCost = cost
            }
        }
        return best ?? []
    }

    // MARK: - Round summary

    /// The round summary's rows in answer order (the view groups them into "Noch üben" and
    /// "Richtig").
    public static func summaryRows(_ state: State) -> [TermRow] {
        guard let set = state.set, let summary = state.summary else { return [] }
        return termRows(set: set, items: summary.items.map { ($0.qid, $0.cardId, $0.correct, nil) })
    }

    /// The share of right answers in the round (0…1).
    public static func summaryRatio(_ summary: WriteSession.RoundSummary) -> Double {
        Double(summary.correct) / Double(max(1, summary.total))
    }

    /// "Hervorragend!", "Gut gemacht!", "Weiter so!" or "Dranbleiben – das wird!".
    public static func summaryTitle(ratio: Double) -> String {
        if ratio >= 0.9 { return "Hervorragend!" }
        if ratio >= 0.7 { return "Gut gemacht!" }
        if ratio >= 0.4 { return "Weiter so!" }
        return "Dranbleiben – das wird!"
    }

    /// "Runde 1 geschafft".
    public static func summaryEyebrow(_ summary: WriteSession.RoundSummary) -> String {
        "Runde \(summary.round) geschafft"
    }

    /// "In Runde 2 übst du nur die 3 Begriffe, die noch nicht sassen."
    public static func summaryText(_ summary: WriteSession.RoundSummary) -> String {
        let one = summary.incorrect == 1
        let what = one ? "den Begriff, der" : "die \(summary.incorrect) Begriffe, die"
        return "In Runde \(summary.round + 1) übst du nur \(what) noch nicht sass\(one ? "" : "en")."
    }

    // MARK: - Results

    /// "Am häufigsten falsch": up to 10 cards with their misses.
    public static func hardestRows(_ state: State) -> [TermRow] {
        guard let set = state.set, let results = state.results else { return [] }
        return termRows(set: set, items: results.stats.hardest.map { ($0.cardId, $0.cardId, nil, $0.misses) })
    }

    /// The line under "Geschafft!".
    public static func resultsSubtitle(cardCount: Int, accuracy: Double, bothDirections: Bool) -> String {
        let dir = bothDirections ? " in beide Richtungen" : ""
        if cardCount == 1 {
            return accuracy >= 1
                ? "Beim ersten Versuch richtig\(dir) – perfekt!" : "Du hast den Begriff\(dir) richtig geschrieben."
        }
        let what = Labels.plural(cardCount, "Begriff", "Begriffe")
        if accuracy >= 1 { return "Alle \(what)\(dir) beim ersten Versuch richtig – perfekt!" }
        return "Du hast alle \(what)\(dir) richtig geschrieben."
    }

    /// `resultsSubtitle` for the results in `state`.
    public static func resultsSubtitle(_ results: Results) -> String {
        resultsSubtitle(
            cardCount: results.cardCount, accuracy: results.stats.accuracy, bothDirections: results.bothDirections)
    }

    /// "42 %" for a share (clamped to 0…1).
    public static func percentText(_ value: Double) -> String {
        let v = value.isNaN ? 0 : min(1, max(0, value))
        return "\(JSCompat.numberToString(JSCompat.round(v * 100))) %"
    }

    /// "Kein einziger Fehler in dieser Lernrunde." (results without misses).
    public static let flawlessText = "Kein einziger Fehler in dieser Lernrunde."

    // MARK: - Messages

    /// An empty or missing screen.
    public struct Message: Codable, Sendable, Equatable, Hashable {
        /// SF Symbol.
        public var systemImage: String
        public var title: String
        public var text: String
        /// The primary button (Return).
        public var primaryLabel: String
        /// The primary button opens the set editor (else it practises all cards, or leaves).
        public var primaryOpensEditor: Bool
    }

    /// The screen when the requested subset has nothing to practise (`emptySubsetView`).
    public static func emptyMessage(for subset: StudySubset) -> Message {
        switch subset {
        case .starred:
            Message(
                systemImage: "star", title: "Keine markierten Begriffe",
                text: "Markiere schwierige Begriffe mit dem Stern, um sie gezielt zu üben.",
                primaryLabel: "Alle Begriffe üben", primaryOpensEditor: false)
        case .learning:
            Message(
                systemImage: "trophy", title: "Alles gemeistert!",
                text: "Du beherrschst bereits alle Begriffe in diesem Lernset. "
                    + "Übe trotzdem alle, damit sie frisch bleiben.",
                primaryLabel: "Alle Begriffe üben", primaryOpensEditor: false)
        case .missed, .cardIds:
            Message(
                systemImage: "checkmark.circle", title: "Keine falschen Begriffe",
                text: "Hier gibt es gerade nichts nachzuholen.", primaryLabel: "Alle Begriffe üben",
                primaryOpensEditor: false)
        case .all:
            Message(
                systemImage: "square.stack.3d.up", title: "Noch keine Begriffe zum Üben",
                text: "Füge diesem Lernset Begriffe mit Übersetzung hinzu, dann kann es losgehen.",
                primaryLabel: "Begriffe hinzufügen", primaryOpensEditor: true)
        }
    }

    /// The screen of a set that does not exist (any more).
    public static let missingMessage = Message(
        systemImage: "magnifyingglass", title: "Lernset nicht gefunden",
        text: "Dieses Lernset gibt es nicht mehr. Vielleicht wurde es gelöscht.", primaryLabel: "Zur Übersicht",
        primaryOpensEditor: false)

    /// What a new round of a named subset asks (`SUBSET_WHAT`), for "Laufende Runde beenden?".
    public static func subsetDescription(_ subset: StudySubset) -> String {
        switch subset {
        case .all: "alle Begriffe"
        case .starred: "nur die markierten Begriffe"
        case .learning: "nur die nicht gemeisterten Begriffe"
        case .missed: "nur die zuletzt falsch beantworteten Begriffe"
        case .cardIds: "eine neue Runde"
        }
    }

    // MARK: - Card editor

    /// The editor's field labels: "Begriff · Französisch" / "Definition · Deutsch".
    public static func editorLabels(termLang: Lang, defLang: Lang) -> (term: String, definition: String) {
        (
            termLang == .other ? "Begriff" : "Begriff · \(Labels.langName(termLang))",
            defLang == .other ? "Definition" : "Definition · \(Labels.langName(defLang))"
        )
    }

    /// The editor's validation errors for an empty side (nil when the side is fine).
    public static func editorErrors(term: String, definition: String) -> (term: String?, definition: String?) {
        (
            JSCompat.trim(term).isEmpty ? "Bitte gib den Begriff ein." : nil,
            JSCompat.trim(definition).isEmpty ? "Bitte gib die Definition ein." : nil
        )
    }
}

// MARK: - Prompt texts

extension WriteFlow.Prompt {
    public var title: String {
        switch self {
        case .restart, .restartForOptions: "Neu starten?"
        case .replaceRound: "Laufende Runde beenden?"
        }
    }

    public var message: String {
        switch self {
        case .restart:
            "Alle Begriffe dieser Lernrunde werden von vorne abgefragt. Dein Lernfortschritt bleibt gespeichert."
        case let .restartForOptions(directionChanged, _, _):
            "\(directionChanged ? "Die neue Abfragerichtung" : "Die neue Reihenfolge") gilt ab einem Neustart. "
                + "Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert."
        case let .replaceRound(wanted, _, _):
            "Deine gespeicherte Runde endet, wenn du jetzt \(WriteFlow.subsetDescription(wanted)) übst. "
                + "Dein Lernfortschritt bleibt erhalten."
        }
    }

    /// The default button (Return).
    public var confirmLabel: String {
        switch self {
        case .restart, .restartForOptions: "Neu starten"
        case .replaceRound: "Neue Runde starten"
        }
    }

    /// The cancel button (Esc).
    public var cancelLabel: String {
        switch self {
        case .restart: "Abbrechen"
        case .restartForOptions: "Später"
        case .replaceRound: "Runde fortsetzen"
        }
    }
}
