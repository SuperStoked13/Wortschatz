import Foundation

// Prüfungsmodus (exam): a vocabulary test over a set on one page, graded like a test at school
// with a Swiss grade from 1 to 6. Only the Mac app has it (the web app has no exam).
//
// Grading reuses the Write and Learn grader (`Grading`, `Synonyms`) in two passes: first with
// only the forms that are no mistake at all (one of several answers, optional brackets,
// abbreviations, capitals outside German; a German noun's small first letter is noted here as a
// small mistake), then with the small mistakes allowed (a typo, missing accents, a missing
// article or reflexive pronoun). How much a small mistake costs is the exam's tolerance. An exam records nothing: mastery stays with
// Lernen and Schreiben.

/// How small mistakes count in an exam (`ExamSettings.tolerance`).
public enum ExamTolerance: String, Codable, Sendable, CaseIterable, Hashable {
    /// Only fully right answers score.
    case strict
    /// A small mistake costs half a point.
    case half
    /// Small mistakes cost nothing.
    case lenient

    /// The points of an answer with a small mistake.
    public var minorPoints: Double {
        switch self {
        case .strict: 0
        case .half: 0.5
        case .lenient: 1
        }
    }
}

/// The settings of an exam ("Prüfung einrichten"); the app keeps them for every set.
public struct ExamSettings: Codable, Sendable, Equatable, Hashable {
    /// Time limit in minutes; 0 = none.
    public var minutes: Int
    /// How many words are asked; 0 = all of them.
    public var count: Int
    /// The side that is answered (`.both`: chosen at random for each question).
    public var answerWith: AnswerWith
    public var tolerance: ExamTolerance
    /// Only the starred cards (when the set has any).
    public var starredOnly: Bool

    public init(
        minutes: Int = 10, count: Int = 20, answerWith: AnswerWith = .term, tolerance: ExamTolerance = .half,
        starredOnly: Bool = false
    ) {
        self.minutes = minutes
        self.count = count
        self.answerWith = answerWith
        self.tolerance = tolerance
        self.starredOnly = starredOnly
    }

    public static let `default` = ExamSettings()

    /// The time limits offered (minutes, 0 = none).
    public static let minuteChoices = [0, 5, 10, 15, 20, 30, 45]
    /// The numbers of words offered (0 = all).
    public static let countChoices = [10, 15, 20, 30, 0]

    /// Lenient decoding: every missing or invalid field takes its default, numbers snap to the
    /// nearest choice offered (so the settings page always has one selected).
    public init(from decoder: any Decoder) throws {
        let d = ExamSettings.default
        let o = (try? JSONValue(from: decoder))?.objectValue ?? [:]
        minutes = o["minutes"]?.finiteNumber.map { Self.nearest($0, in: Self.minuteChoices) } ?? d.minutes
        count = o["count"]?.finiteNumber.map { Self.nearest($0, in: Self.countChoices) } ?? d.count
        answerWith = o["answerWith"]?.stringValue.flatMap(AnswerWith.init(rawValue:)) ?? d.answerWith
        tolerance = o["tolerance"]?.stringValue.flatMap(ExamTolerance.init(rawValue:)) ?? d.tolerance
        starredOnly = o["starredOnly"]?.boolValue ?? d.starredOnly
    }

    /// The choice nearest to `value` (the lower one on a tie); 0 ("none", "all") only for 0 or less.
    static func nearest(_ value: Double, in choices: [Int]) -> Int {
        let positive = choices.filter { $0 > 0 }.sorted()
        guard value > 0, let first = positive.first else { return 0 }
        return positive.reduce(first) { best, choice in
            abs(Double(choice) - value) < abs(Double(best) - value) ? choice : best
        }
    }
}

/// A question on the exam sheet, with the texts it was asked with.
public struct ExamQuestion: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// 1-based number on the sheet.
    public var number: Int
    public var cardId: String
    /// The side that is answered (`.term`: the definition is shown, the term typed).
    public var ask: AskSide
    public var prompt: String
    public var expected: String
    public var promptLang: Lang
    public var answerLang: Lang

    public var id: Int { number }

    public init(
        number: Int, cardId: String, ask: AskSide, prompt: String, expected: String, promptLang: Lang, answerLang: Lang
    ) {
        self.number = number
        self.cardId = cardId
        self.ask = ask
        self.prompt = prompt
        self.expected = expected
        self.promptLang = promptLang
        self.answerLang = answerLang
    }

    /// The card as it was asked.
    public var card: Card {
        Card(
            id: cardId, term: ask == .term ? expected : prompt, definition: ask == .term ? prompt : expected)
    }
}

/// How an answer was marked.
public enum ExamMark: String, Codable, Sendable, CaseIterable, Hashable {
    /// Right (a full point).
    case correct
    /// Right but for a small mistake (as many points as the tolerance gives).
    case minor
    case wrong
    /// No answer.
    case blank
}

/// One marked answer.
public struct ExamItemResult: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var question: ExamQuestion
    /// What was typed (trimmed).
    public var given: String
    public var mark: ExamMark
    public var points: Double
    /// The small mistake ("Tippfehler", "Akzente", …), the hint of a wrong answer ("Falscher
    /// Artikel") or why a right answer differs ("Anderes Wort mit gleicher Bedeutung").
    public var note: String?
    /// The answer belongs to another card with the same prompt.
    public var synonym: Bool
    /// That card's answer, which the typed one is compared with (a synonym with a small mistake).
    public var matched: String?

    public var id: Int { question.number }

    public init(
        question: ExamQuestion, given: String, mark: ExamMark, points: Double, note: String? = nil,
        synonym: Bool = false, matched: String? = nil
    ) {
        self.question = question
        self.given = given
        self.mark = mark
        self.points = points
        self.note = note
        self.synonym = synonym
        self.matched = matched
    }
}

/// The marked exam.
public struct ExamResult: Codable, Sendable, Equatable, Hashable {
    public var items: [ExamItemResult]
    public var tolerance: ExamTolerance
    /// Time taken (ms).
    public var elapsedMs: Double
    /// The time ran out before the exam was handed in.
    public var timedOut: Bool

    public init(items: [ExamItemResult], tolerance: ExamTolerance, elapsedMs: Double, timedOut: Bool) {
        self.items = items
        self.tolerance = tolerance
        self.elapsedMs = elapsedMs
        self.timedOut = timedOut
    }

    public var points: Double { items.reduce(0) { $0 + $1.points } }
    public var maxPoints: Int { items.count }
    /// The Swiss grade (1…6, tenths).
    public var grade: Double { Exam.grade(points: points, of: maxPoints) }

    public func count(_ mark: ExamMark) -> Int { items.count { $0.mark == mark } }

    /// The cards worth practising: wrong, left blank, or with a small mistake.
    public var cardIdsToPractise: [String] {
        var seen = Set<String>()
        return items.filter { $0.mark != .correct }.map(\.question.cardId).filter { seen.insert($0).inserted }
    }
}

/// The exam's logic (see the file header).
public enum Exam {
    /// Notes of an answer that count as a small mistake (`.tones`: the accents of pinyin). An
    /// Arabic letter variant (`.variant`) and an answer in pinyin only (`.pinyin`) are no mistake.
    public static let smallMistakes: [GradeNote] = [.article, .pronoun, .letterCase, .accents, .tones, .typo]

    /// Forms that are no mistake (any capitals are fine outside German, where a noun's small first
    /// letter is noted as a small mistake).
    static let acceptedForms = Tolerance(
        articles: false, abbreviations: true, multipleAnswers: true, parentheses: true, ignoreCase: true,
        ignoreAccents: false, typos: false)

    /// The forms that are no mistake plus the small mistakes.
    static let smallMistakesAllowed = Tolerance(
        articles: true, abbreviations: true, multipleAnswers: true, parentheses: true, ignoreCase: true,
        ignoreAccents: true, typos: true)

    // MARK: - The sheet

    /// The cards an exam can ask: both sides with text, each id once, in set order; only
    /// `cardIds` when given (a retake of the wrong ones), else only the starred ones when the
    /// settings ask for them and there are any.
    public static func scope(_ cards: [Card], settings: ExamSettings, cardIds: [String]? = nil) -> [Card] {
        var seen = Set<String>()
        var pool = cards.filter { !$0.id.isEmpty && hasText($0.term) && hasText($0.definition) && seen.insert($0.id).inserted }
        if let cardIds {
            let wanted = Set(cardIds)
            pool = pool.filter { wanted.contains($0.id) }
        } else if settings.starredOnly, pool.contains(where: \.starred) {
            pool = pool.filter(\.starred)
        }
        return pool
    }

    /// How many questions an exam over `available` cards asks.
    public static func questionCount(_ settings: ExamSettings, available: Int) -> Int {
        settings.count > 0 ? min(settings.count, available) : available
    }

    /// The exam sheet: `settings.count` cards of the scope (all for 0) in random order, each
    /// asked on the side the settings say (`.both`: at random).
    public static func makeQuestions(
        cards: [Card], settings: ExamSettings, termLang: Lang, defLang: Lang, cardIds: [String]? = nil,
        rng: RNG = systemRNG()
    ) -> [ExamQuestion] {
        let pool = scope(cards, settings: settings, cardIds: cardIds)
        let picked = shuffled(pool, rng).prefix(questionCount(settings, available: pool.count))
        return picked.enumerated().map { index, card in
            let ask: AskSide =
                switch settings.answerWith {
                case .term: .term
                case .definition: .definition
                case .both: randomIndex(rng, 2) == 0 ? .term : .definition
                }
            let askTerm = ask == .term
            return ExamQuestion(
                number: index + 1, cardId: card.id, ask: ask,
                prompt: JSCompat.trim(askTerm ? card.definition : card.term),
                expected: JSCompat.trim(askTerm ? card.term : card.definition), promptLang: askTerm ? defLang : termLang,
                answerLang: askTerm ? termLang : defLang)
        }
    }

    // MARK: - Marking

    /// Marks one answer. `cards`: the set's cards (an answer that is right for another card with
    /// the same prompt counts too).
    public static func mark(
        _ given: String, question: ExamQuestion, cards: [Card], tolerance: ExamTolerance
    ) -> ExamItemResult {
        let answer = JSCompat.trim(given)
        var item = ExamItemResult(question: question, given: answer, mark: .blank, points: 0)
        guard hasText(answer) else { return item }
        let card = question.card
        func graded(_ allowed: Tolerance) -> SynonymGradeResult {
            Synonyms.gradeWithSynonyms(
                given: answer, card: card, cards: cards, ask: question.ask, tolerance: allowed,
                answerLang: question.answerLang)
        }
        /// The answer of the card the typed one matched, when that is another card.
        func matchedAnswer(_ graded: SynonymGradeResult) -> String? {
            graded.matchedCard.map { JSCompat.trim(question.ask == .term ? $0.term : $0.definition) }
        }

        let first = graded(acceptedForms)
        if first.result.correct {
            item.synonym = first.isSynonym
            item.matched = matchedAnswer(first)
            let small = first.result.notes.filter(smallMistakes.contains)
            if small.isEmpty {
                item.mark = .correct
                item.points = 1
                item.note = first.isSynonym ? Labels.NOTE_LABELS[.synonym] : nil
            } else {
                item.mark = .minor
                item.points = tolerance.minorPoints
                item.note = noteText(small)
            }
            return item
        }

        let second = graded(smallMistakesAllowed)
        if second.result.correct {
            item.mark = .minor
            item.points = tolerance.minorPoints
            item.synonym = second.isSynonym
            item.matched = matchedAnswer(second)
            item.note = noteText(second.result.notes.filter(smallMistakes.contains)) ?? Labels.NOTE_LABELS[.typo]
            return item
        }
        item.mark = .wrong
        item.note = second.result.hint.flatMap { Labels.HINT_LABELS[$0] }
        return item
    }

    /// Marks the whole sheet (`answers` by question number).
    public static func evaluate(
        _ questions: [ExamQuestion], answers: [Int: String], cards: [Card], tolerance: ExamTolerance,
        elapsedMs: Double, timedOut: Bool = false
    ) -> ExamResult {
        ExamResult(
            items: questions.map { mark(answers[$0.number] ?? "", question: $0, cards: cards, tolerance: tolerance) },
            tolerance: tolerance, elapsedMs: max(0, elapsedMs.isFinite ? elapsedMs : 0), timedOut: timedOut)
    }

    // MARK: - The grade

    /// The Swiss grade for `points` of `maxPoints`: 1 + 5 × points / maximum, rounded to tenths
    /// (6 = everything right, 4 = half the points, the pass mark).
    public static func grade(points: Double, of maxPoints: Int) -> Double {
        guard maxPoints > 0, points.isFinite else { return 1 }
        let clamped = min(Double(maxPoints), max(0, points))
        // In tenths in one step: 34.5 of 50 is exactly 4.45 and must round up to 4.5 (going
        // through the share would land on 4.4499… and round down).
        return ((10 + 50 * clamped / Double(maxPoints)).rounded()) / 10
    }

    /// "5.3" (Swiss notation, always one decimal).
    public static func gradeText(_ grade: Double) -> String {
        let tenths = Int((grade * 10).rounded())
        return "\(tenths / 10).\(abs(tenths % 10))"
    }

    /// "17.5" or "18" (points, halves where there are any).
    public static func pointsText(_ points: Double) -> String {
        let halves = Int((points * 2).rounded())
        return halves % 2 == 0 ? "\(halves / 2)" : "\(halves / 2).5"
    }

    /// 4 and above passes.
    public static func passes(_ grade: Double) -> Bool { grade >= 4 }

    /// The results' title by grade.
    public static func verdict(_ grade: Double) -> String {
        switch grade {
        case 6...: L("Perfekt!")
        case 5.5...: L("Hervorragend!")
        case 5...: L("Sehr gut!")
        case 4.5...: L("Gut gemacht!")
        case 4...: L("Bestanden!")
        default: L("Noch nicht genügend")
        }
    }

    // MARK: - Internals

    /// The labels of small mistakes, joined ("Artikel fehlte · Akzente").
    static func noteText(_ notes: [GradeNote]) -> String? {
        let labels = notes.compactMap { Labels.NOTE_LABELS[$0] }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }

    static func hasText(_ s: String) -> Bool {
        s.unicodeScalars.contains { !JSCompat.isWhitespace($0) }
    }

    /// Integer in [0, n) from the rng, clamped so a misbehaving rng never breaks an index.
    static func randomIndex(_ rng: RNG, _ n: Int) -> Int {
        let r = (rng() * Double(n)).rounded(.down)
        if !(r >= 0) { return 0 }
        if r > Double(n - 1) { return n - 1 }
        return Int(r)
    }

    /// Fisher–Yates on a copy.
    static func shuffled<T>(_ list: [T], _ rng: RNG) -> [T] {
        var a = list
        var i = a.count - 1
        while i > 0 {
            a.swapAt(i, randomIndex(rng, i + 1))
            i -= 1
        }
        return a
    }
}

/// Texts of the exam settings and results (German source, translated with `L`).
public enum ExamCopy {
    /// "Ohne Zeitlimit", "1 Minute", "10 Minuten".
    public static func minutes(_ minutes: Int) -> String {
        minutes <= 0 ? L("Ohne Zeitlimit") : Labels.plural(minutes, "Minute", "Minuten")
    }

    public static func toleranceTitle(_ tolerance: ExamTolerance) -> String {
        switch tolerance {
        case .strict: L("Streng")
        case .half: L("Halber Punkt")
        case .lenient: L("Grosszügig")
        }
    }

    /// What a small mistake costs.
    public static func toleranceText(_ tolerance: ExamTolerance) -> String {
        switch tolerance {
        case .strict: L("Nur ganz richtige Antworten geben einen Punkt.")
        case .half: L("Ein kleiner Fehler kostet einen halben Punkt.")
        case .lenient: L("Kleine Fehler kosten nichts.")
        }
    }

    /// Which mistakes are small.
    public static var smallMistakesText: String {
        L(
            "Kleine Fehler sind ein Tippfehler, fehlende Akzente, die Grossschreibung deutscher Nomen und ein fehlender Artikel oder ein fehlendes Pronomen. Ein falscher Artikel ist ein Fehler.")
    }

    /// "17.5 von 20 Punkten".
    public static func scoreLine(_ result: ExamResult) -> String {
        L("%@ von %@", Exam.pointsText(result.points), Labels.plural(result.maxPoints, "Punkt", "Punkten"))
    }

    /// The mark's label in the results ("Richtig", "Halber Punkt", …).
    public static func markLabel(_ item: ExamItemResult) -> String {
        switch item.mark {
        case .correct: L("Richtig")
        case .minor:
            switch item.points {
            case 1: L("Richtig")
            case 0.5: L("Halber Punkt")
            default: L("Kleiner Fehler")
            }
        case .wrong: L("Falsch")
        case .blank: L("Keine Antwort")
        }
    }
}
