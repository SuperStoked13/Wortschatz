import Foundation
import Testing
import WortschatzCore

/// Prüfungsmodus: the sheet, the marking with its tolerance and the Swiss grade.
@Suite("Exam")
struct ExamTests {
    static let cards: [Card] = [
        Card(id: "c1", term: "la maison", definition: "das Haus", starred: true),
        Card(id: "c2", term: "l'élève", definition: "der Schüler", starred: true),
        Card(id: "c3", term: "s'occuper de", definition: "sich kümmern um"),
        Card(id: "c4", term: "aimable, gentil", definition: "freundlich"),
        Card(id: "c5", term: "le cheval", definition: "das Pferd"),
        Card(id: "c6", term: "", definition: "leer"),
        Card(id: "c7", term: "le chien", definition: "der Hund"),
    ]

    static func question(_ cardId: String, ask: AskSide = .term) -> ExamQuestion {
        let card = cards.first { $0.id == cardId }!
        return ExamQuestion(
            number: 1, cardId: cardId, ask: ask, prompt: ask == .term ? card.definition : card.term,
            expected: ask == .term ? card.term : card.definition, promptLang: ask == .term ? .de : .fr,
            answerLang: ask == .term ? .fr : .de)
    }

    static func mark(_ given: String, _ cardId: String, ask: AskSide = .term, _ tolerance: ExamTolerance = .half)
        -> ExamItemResult
    {
        Exam.mark(given, question: question(cardId, ask: ask), cards: cards, tolerance: tolerance)
    }

    // MARK: - The sheet

    @Test func theSheetAsksTheWantedNumberOfUsableCards() {
        let settings = ExamSettings(count: 4, answerWith: .term)
        let questions = Exam.makeQuestions(
            cards: Self.cards, settings: settings, termLang: .fr, defLang: .de, rng: mulberry32(seed: 1))
        #expect(questions.count == 4)
        #expect(questions.map(\.number) == [1, 2, 3, 4])
        #expect(Set(questions.map(\.cardId)).count == 4)
        #expect(!questions.contains { $0.cardId == "c6" })
        for q in questions {
            let card = Self.cards.first { $0.id == q.cardId }!
            #expect(q.ask == .term)
            #expect(q.prompt == card.definition)
            #expect(q.expected == card.term)
            #expect(q.promptLang == .de && q.answerLang == .fr)
        }
        let all = Exam.makeQuestions(
            cards: Self.cards, settings: ExamSettings(count: 0), termLang: .fr, defLang: .de, rng: mulberry32(seed: 2))
        #expect(all.count == 6)
    }

    @Test func starredRetakesAndBothDirections() {
        let starred = Exam.makeQuestions(
            cards: Self.cards, settings: ExamSettings(count: 0, starredOnly: true), termLang: .fr, defLang: .de,
            rng: mulberry32(seed: 3))
        #expect(Set(starred.map(\.cardId)) == ["c1", "c2"])
        let retake = Exam.makeQuestions(
            cards: Self.cards, settings: ExamSettings(count: 2, starredOnly: true), termLang: .fr, defLang: .de,
            cardIds: ["c5", "c7", "c6"], rng: mulberry32(seed: 3))
        #expect(Set(retake.map(\.cardId)) == ["c5", "c7"])
        let both = Exam.makeQuestions(
            cards: Self.cards, settings: ExamSettings(count: 0, answerWith: .both), termLang: .fr, defLang: .de,
            rng: mulberry32(seed: 5))
        #expect(Set(both.map(\.ask)) == [.term, .definition])
        for q in both where q.ask == .definition {
            #expect(q.promptLang == .fr && q.answerLang == .de)
        }
        #expect(Exam.questionCount(ExamSettings(count: 20), available: 6) == 6)
    }

    // MARK: - Marking

    @Test func rightAnswersAndFormsThatAreNoMistake() {
        #expect(Self.mark("la maison", "c1").mark == .correct)
        #expect(Self.mark("  La maison ", "c1").mark == .correct)
        #expect(Self.mark("gentil", "c4").points == 1)
        #expect(Self.mark("das Haus", "c1", ask: .definition).mark == .correct)
    }

    @Test func smallMistakesCostWhatTheToleranceSays() {
        // Missing article, missing accent, a typo.
        for given in ["maison", "l'eleve", "la maisson"] {
            let id = given.contains("lev") ? "c2" : "c1"
            #expect(Self.mark(given, id, .half).mark == .minor, "\(given)")
            #expect(Self.mark(given, id, .half).points == 0.5)
            #expect(Self.mark(given, id, .strict).points == 0)
            #expect(Self.mark(given, id, .lenient).points == 1)
        }
        #expect(Self.mark("maison", "c1").note == "Artikel fehlte")
        #expect(Self.mark("l'eleve", "c2").note == "Akzente")
        #expect(Self.mark("la maisson", "c1").note == "Tippfehler")
        // A German noun's small first letter.
        let small = Self.mark("das haus", "c1", ask: .definition)
        #expect(small.mark == .minor)
        #expect(small.note == "Gross-/Kleinschreibung")
    }

    @Test func wrongAndBlankAnswers() {
        let article = Self.mark("le maison", "c1")
        #expect(article.mark == .wrong)
        #expect(article.points == 0)
        #expect(article.note == "Falscher Artikel")
        #expect(Self.mark("le chat", "c7").mark == .wrong)
        let blank = Self.mark("   ", "c1")
        #expect(blank.mark == .blank)
        #expect(blank.given == "")
    }

    @Test func theWholeSheet() {
        let questions = ["c1", "c2", "c5", "c7"].enumerated().map { i, id in
            var q = Self.question(id)
            q.number = i + 1
            return q
        }
        let result = Exam.evaluate(
            questions, answers: [1: "la maison", 2: "l'eleve", 3: "le cheval"], cards: Self.cards, tolerance: .half,
            elapsedMs: 90_000)
        #expect(result.points == 2.5)
        #expect(result.maxPoints == 4)
        #expect(result.count(.correct) == 2)
        #expect(result.count(.minor) == 1)
        #expect(result.count(.blank) == 1)
        #expect(result.grade == 4.1)
        #expect(result.cardIdsToPractise == ["c2", "c7"])
        #expect(ExamCopy.scoreLine(result) == "2.5 von 4 Punkten")
        #expect(ExamCopy.markLabel(result.items[1]) == "Halber Punkt")
    }

    // MARK: - The grade

    @Test func theSwissGrade() {
        #expect(Exam.grade(points: 20, of: 20) == 6)
        #expect(Exam.grade(points: 0, of: 20) == 1)
        #expect(Exam.grade(points: 10, of: 20) == 3.5)
        #expect(Exam.grade(points: 12, of: 20) == 4)
        #expect(Exam.grade(points: 17, of: 20) == 5.3)
        #expect(Exam.grade(points: 17.5, of: 20) == 5.4)
        #expect(Exam.grade(points: 3, of: 0) == 1)
        // Exact halves round up (going through the share in floating point gave 4.4 and 5.1).
        #expect(Exam.grade(points: 34.5, of: 50) == 4.5)
        #expect(Exam.grade(points: 41.5, of: 50) == 5.2)
        #expect(Exam.grade(points: 69, of: 100) == 4.5)
        #expect(Exam.grade(points: 25, of: 20) == 6)
        #expect(Exam.grade(points: -2, of: 20) == 1)
        #expect(Exam.gradeText(5.3) == "5.3")
        #expect(Exam.gradeText(6) == "6.0")
        #expect(Exam.gradeText(4) == "4.0")
        #expect(Exam.pointsText(17.5) == "17.5")
        #expect(Exam.pointsText(18) == "18")
        #expect(Exam.passes(4))
        #expect(!Exam.passes(3.9))
        #expect(Exam.verdict(6) == "Perfekt!")
        #expect(Exam.verdict(3.5) == "Noch nicht genügend")
    }

    @Test func settingsAreReadLeniently() throws {
        let json = #"{"minutes": 15.7, "count": -3, "answerWith": "both", "tolerance": "nope", "examples": true}"#
        let s = try JSONDecoder().decode(ExamSettings.self, from: Data(json.utf8))
        // Unknown keys ("examples" of an earlier version) are ignored.
        #expect(s == ExamSettings(minutes: 15, count: 0, answerWith: .both, tolerance: .half))
        let round = try JSONDecoder().decode(ExamSettings.self, from: JSONEncoder().encode(s))
        #expect(round == s)
        #expect(ExamCopy.minutes(0) == "Ohne Zeitlimit")
        #expect(ExamCopy.minutes(1) == "1 Minute")
    }

    @Test func storedNumbersSnapToTheChoicesOffered() throws {
        func decode(_ json: String) throws -> ExamSettings {
            try JSONDecoder().decode(ExamSettings.self, from: Data(json.utf8))
        }
        // The settings page always finds its value among the choices.
        #expect(try decode(#"{"minutes": 7, "count": 25}"#).minutes == 5)
        #expect(try decode(#"{"minutes": 7, "count": 25}"#).count == 20)
        #expect(try decode(#"{"minutes": 600, "count": 9999}"#) == ExamSettings(minutes: 45, count: 30))
        #expect(try decode(#"{"minutes": 0, "count": 0}"#) == ExamSettings(minutes: 0, count: 0))
        #expect(try decode(#"{"minutes": 2, "count": 1}"#) == ExamSettings(minutes: 5, count: 10))
    }

    @Test func aSynonymWithASmallMistakeIsComparedWithItsOwnWord() {
        let cards = [
            Card(id: "v1", term: "la voiture", definition: "das Auto"),
            Card(id: "v2", term: "l'automobile", definition: "das Auto"),
        ]
        let question = ExamQuestion(
            number: 1, cardId: "v1", ask: .term, prompt: "das Auto", expected: "la voiture", promptLang: .de,
            answerLang: .fr)
        let typo = Exam.mark("l'automobil", question: question, cards: cards, tolerance: .half)
        #expect(typo.mark == .minor)
        #expect(typo.synonym)
        #expect(typo.matched == "l'automobile")
        let own = Exam.mark("la voitur", question: question, cards: cards, tolerance: .half)
        #expect(own.mark == .minor)
        #expect(own.matched == nil)
    }
}
