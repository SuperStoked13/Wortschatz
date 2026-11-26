import Foundation
import Testing
import WortschatzCore

// Port of tests/grading.test.js. JS-only inputs (null/undefined/objects/Symbols, objects with a
// throwing toString, lone surrogates) cannot reach the typed Swift API; where the JS test passes
// such values, the Swift test passes their `String(value)` form or the empty string.

/// Every tolerance off.
let gradingAllOff = Tolerance(
    articles: false, abbreviations: false, multipleAnswers: false, parentheses: false, ignoreCase: false,
    ignoreAccents: false, typos: false)
/// Every tolerance on.
let gradingAllOn = Tolerance(
    articles: true, abbreviations: true, multipleAnswers: true, parentheses: true, ignoreCase: true,
    ignoreAccents: true, typos: true)

/// The 52 pairs of tests/fixtures/user-example.txt (term = French, definition = German).
let gradingPairs: [(term: String, definition: String)] = [
    ("le monsieur, messieurs", "der Herr"),
    ("l'homme", "der Mann"),
    ("la madame, mesdames", "Frau"),
    ("la femme", "die Frau"),
    ("la dame", "die Dame"),
    ("la mademoiselle, mesdemoiselles", "das Fräulein, die Frau"),
    ("l'enfant", "das Kind"),
    ("le garçon", "der Junge"),
    ("la fille", "das Mädchen"),
    ("appeler", "nennen"),
    ("s'appeler", "heissen"),
    ("le nom", "der Name"),
    ("le nom de famille", "der Familienname, der Nachname"),
    ("le prénom", "der Vorname"),
    ("marié, mariée", "verheiratet"),
    ("veuf, veuve", "verwitwet"),
    ("séparé, séparée", "getrennt"),
    ("la personne", "die Person"),
    ("l'adresse", "die Adresse, die Anschrift"),
    ("la rue", "die Strasse"),
    ("le numéro de la maison", "die Hausnummer"),
    ("brave", "lieb"),
    ("gentil, gentille", "lieb, nett"),
    ("bon, bonne", "gut, gütig"),
    ("aimable", "freundlich"),
    ("sage", "brav, artig"),
    ("le charme", "der Charme"),
    ("charmant, charmante", "charmant"),
    ("la raison", "die Vernunft"),
    ("raisonnable", "vernünftig"),
    ("sérieux, sérieuse", "ernst, ernsthaft"),
    ("sympathique", "sympathisch"),
    ("calme", "ruhig"),
    ("tranquille", "still"),
    ("comique", "komisch"),
    ("le courage", "der Mut"),
    ("courageux, courageuse", "mutig"),
    ("la bêtise", "die Dummheit"),
    ("bête", "dumm"),
    ("méchant, méchante", "böse, gemein"),
    ("lâche", "feige"),
    ("le visage", "das Gesicht"),
    ("la figure", "das Gesicht"),
    ("les cheveux", "das Haar, die Haare"),
    ("ressembler à", "ähneln, gleichen"),
    ("se ressembler", "sich ähnlich sein, sich gleichen"),
    ("joli, jolie", "hübsch"),
    ("la beauté", "die Schönheit"),
    ("beau, bel, belle", "schön"),
    ("attirant, attirante", "attraktiv, anziehend"),
    ("laid, laide", "hässlich"),
    ("moche", "hässlich"),
]

/// Assertion helpers of the grading tests. They are protocol members so that they shadow
/// same-named helpers of other test files.
protocol GradingAssertions {}

extension GradingAssertions {
    /// "Expect no hint" for `rejects` (nil = do not check the hint).
    var noHint: GradeHint?? { .some(nil) }

    /// Asserts the answer is accepted without a hint; checks the notes when given.
    @discardableResult
    func accepts(
        _ given: String, _ expected: String, _ lang: Lang?, _ tolerance: Tolerance = .default, _ notes: [GradeNote]? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> GradeResult {
        let r = Grading.grade(given: given, expected: expected, tolerance: tolerance, lang: lang)
        #expect(r.correct, "\"\(given)\" should be correct for \"\(expected)\" (hint \(String(describing: r.hint)))",
                sourceLocation: sourceLocation)
        #expect(r.hint == nil, sourceLocation: sourceLocation)
        if let notes { #expect(r.notes == notes, "\"\(given)\" for \"\(expected)\"", sourceLocation: sourceLocation) }
        return r
    }

    /// Asserts the answer is rejected (never exact, no notes); checks the hint when given.
    @discardableResult
    func rejects(
        _ given: String, _ expected: String, _ lang: Lang?, _ tolerance: Tolerance = .default, _ hint: GradeHint?? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> GradeResult {
        let r = Grading.grade(given: given, expected: expected, tolerance: tolerance, lang: lang)
        #expect(!r.correct, "\"\(given)\" should be wrong for \"\(expected)\" (notes \(r.notes))", sourceLocation: sourceLocation)
        #expect(!r.exact, sourceLocation: sourceLocation)
        #expect(r.notes.isEmpty, sourceLocation: sourceLocation)
        if let hint { #expect(r.hint == hint, "\"\(given)\" for \"\(expected)\"", sourceLocation: sourceLocation) }
        return r
    }

    func exactMatch(
        _ given: String, _ expected: String, _ lang: Lang?, _ tolerance: Tolerance = .default,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let r = accepts(given, expected, lang, tolerance, [], sourceLocation: sourceLocation)
        #expect(r.exact, "\"\(given)\" should be exact for \"\(expected)\"", sourceLocation: sourceLocation)
    }

    /// `{ given, expected }` rebuilt from diff segments.
    func rebuild(_ segments: [DiffSegment]) -> (given: String, expected: String) {
        (segments.filter { $0.type != .add }.map(\.text).joined(), segments.filter { $0.type != .del }.map(\.text).joined())
    }

    func seg(_ type: DiffType, _ text: String) -> DiffSegment { DiffSegment(type: type, text: text) }

    /// Scalar-exact comparison (Swift `==` ignores NFC/NFD differences).
    func identical(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { JSCompat.identical($0, $1) }
    }
}

// MARK: - Fixture: every pair in both directions

@Suite("Grading: user-example fixture")
struct GradingFixtureTests: GradingAssertions {
    @Test("inline pairs match Website/tests/fixtures/user-example.txt")
    func pairsMatchFixture() throws {
        #expect(gradingPairs.count == 52)
        // mac/Packages/WortschatzCore/Tests/WortschatzCoreTests → project root
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // A missing file fails the test: it used to look in the wrong folder and silently checked nothing.
        let url = root.appendingPathComponent("Website/tests/fixtures/user-example.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        let blocks = text.components(separatedBy: "\n").map { JSCompat.trim($0) }
            .split(separator: "", omittingEmptySubsequences: true).map(Array.init)
        #expect(blocks.map { [$0[0], $0[1]] } == gradingPairs.map { [$0.term, $0.definition] })
    }

    @Test("every answer is exact in its own language under every tolerance", arguments: 0..<52)
    func exactAnswers(index: Int) {
        let (term, def) = gradingPairs[index]
        for tol in [Tolerance.default, gradingAllOff, gradingAllOn] {
            exactMatch(term, term, .fr, tol)
            exactMatch(def, def, .de, tol)
        }
    }

    @Test("each single alternative is a partial answer (multipleAnswers ON) and wrong when OFF")
    func singleAlternatives() {
        var checked = 0
        for (term, def) in gradingPairs {
            for (stored, lang) in [(term, Lang.fr), (def, Lang.de)] {
                let alts = Grading.splitAlternatives(stored)
                if alts.count < 2 { continue }
                for alt in alts {
                    let r = accepts(alt, stored, lang)
                    #expect(r.notes.contains(.partial))
                    rejects(alt, stored, lang, Tolerance(multipleAnswers: false))
                    checked += 1
                }
            }
        }
        #expect(checked > 30)
    }

    @Test("all alternatives in reverse order are accepted with note order")
    func reversedAlternatives() {
        for (term, def) in gradingPairs {
            for (stored, lang) in [(term, Lang.fr), (def, Lang.de)] {
                let alts = Grading.splitAlternatives(stored)
                if alts.count < 2 { continue }
                let reversed = alts.reversed().joined(separator: ", ")
                #expect(accepts(reversed, stored, lang).notes.contains(.order))
                #expect(accepts(reversed, stored, lang, Tolerance(multipleAnswers: false)).notes.contains(.order))
            }
        }
    }

    @Test("French nouns without article are accepted (articles ON) and wrong when OFF")
    func frenchNounsWithoutArticle() throws {
        var checked = 0
        let pattern = try Regex(#"^(?:(?:les|le|la) |l')([^,]+)$"#)
        for (term, _) in gradingPairs {
            guard let m = term.wholeMatch(of: pattern), let core = m.output[1].substring else { continue }
            let bare = JSCompat.trim(String(core))
            #expect(accepts(bare, term, .fr).notes == [.article])
            rejects(bare, term, .fr, Tolerance(articles: false), .missingArticle)
            checked += 1
        }
        #expect(checked >= 20)
    }

    @Test("German nouns without article are accepted (articles ON) and wrong when OFF")
    func germanNounsWithoutArticle() throws {
        var checked = 0
        let pattern = try Regex(#"^(der|die|das) ([^,]+)$"#)
        for (_, def) in gradingPairs {
            guard let m = def.wholeMatch(of: pattern), let core = m.output[2].substring else { continue }
            #expect(accepts(String(core), def, .de).notes == [.article])
            rejects(String(core), def, .de, Tolerance(articles: false), .missingArticle)
            checked += 1
        }
        #expect(checked >= 15)
    }

    @Test("a different card's answer is never accepted")
    func otherCardsAnswer() {
        rejects("der Mann", "der Herr", .de)
        rejects("die Frau", "die Dame", .de)
        rejects("nennen", "heissen", .de)
        rejects("la fille", "le garçon", .fr)
        rejects("veuf", "marié, mariée", .fr)
        rejects("calme", "tranquille", .fr, gradingAllOn)
    }
}

// MARK: - Always-on normalisation

@Suite("Grading: always-on normalisation")
struct GradingNormalisationTests: GradingAssertions {
    @Test func identicalAnswerIsExact() {
        let r = Grading.grade(given: "der Herr", expected: "der Herr", lang: .de)
        #expect(r == GradeResult(correct: true, exact: true, notes: [], hint: nil, expectedDisplay: "der Herr"))
    }

    @Test func expectedDisplayIsTheStoredAnswer() {
        #expect(Grading.grade(given: "x", expected: "le monsieur, messieurs", lang: .fr).expectedDisplay == "le monsieur, messieurs")
        #expect(Grading.grade(given: "Herr", expected: "der Herr", lang: .de).expectedDisplay == "der Herr")
        #expect(Grading.grade(given: "x", expected: "", lang: .de).expectedDisplay == "")
        // Unchanged, even when not NFC.
        let nfd = "séparée".decomposedStringWithCanonicalMapping
        #expect(JSCompat.identical(Grading.grade(given: "x", expected: nfd, lang: .fr).expectedDisplay, nfd))
    }

    @Test func extraWhitespaceIsIgnored() {
        exactMatch("  der    Herr  ", "der Herr", .de, gradingAllOff)
        exactMatch("le\tnom de\nfamille", "le nom de famille", .fr, gradingAllOff)
    }

    @Test func curlyApostrophesEqualStraightOnes() {
        exactMatch("l’homme", "l'homme", .fr, gradingAllOff)
        exactMatch("l'homme", "l’homme", .fr, gradingAllOff)
    }

    @Test func spacesNextToApostrophesAreRemoved() {
        exactMatch("s' appeler", "s'appeler", .fr, gradingAllOff)
        exactMatch("s 'appeler", "s'appeler", .fr, gradingAllOff)
        exactMatch("l' homme", "l'homme", .fr, gradingAllOff)
    }

    @Test func sharpSEqualsDoubleS() {
        exactMatch("Straße", "Strasse", .de, gradingAllOff)
        exactMatch("heißen", "heissen", .de, gradingAllOff)
        exactMatch("heissen", "heißen", .de, gradingAllOff)
        exactMatch("die Straße", "die Strasse", .de, gradingAllOff)
    }

    @Test func ligaturesEqualSpelledOutForms() {
        exactMatch("cœur", "coeur", .fr, gradingAllOff)
        exactMatch("le coeur", "le cœur", .fr, gradingAllOff)
        exactMatch("ex æquo", "ex aequo", .fr, gradingAllOff)
        exactMatch("Œuvre", "Oeuvre", .fr, gradingAllOff)
    }

    @Test func hyphenEqualsSpace() {
        exactMatch("c'est à dire", "c'est-à-dire", .fr, gradingAllOff)
        exactMatch("e-mail", "e mail", .en, gradingAllOff)
        exactMatch("Grand–mère", "Grand-mère", .fr, gradingAllOff)
    }

    @Test func punctuationIsIgnored() {
        exactMatch("der Herr.", "der Herr", .de, gradingAllOff)
        exactMatch("Hallo!", "Hallo", .de, gradingAllOff)
        exactMatch("Wie geht's", "Wie geht's?", .de, gradingAllOff)
        exactMatch("« bonjour »", "bonjour", .fr, gradingAllOff)
        exactMatch("¿qué?", "qué", .es, gradingAllOff)
        exactMatch("ja…", "ja", .de, gradingAllOff)
    }

    @Test func decomposedInputEqualsComposedText() {
        exactMatch("séparée".decomposedStringWithCanonicalMapping, "séparée", .fr, gradingAllOff)
        exactMatch("Mädchen", "Mädchen".decomposedStringWithCanonicalMapping, .de, gradingAllOff)
    }

    @Test func emptyAnswersAreIncorrect() {
        for given in ["", "   ", "\n\t"] {
            rejects(given, "der Herr", .de, .default, noHint)
            rejects(given, "der Herr", .de, gradingAllOn, noHint)
        }
    }

    @Test func punctuationOnlyAnswersAreIncorrect() {
        rejects("...", "der Herr", .de, gradingAllOn)
        rejects(",", "lieb, nett", .de, gradingAllOn)
        rejects("?", "lieb", .de, gradingAllOn)
    }

    @Test func unrelatedAnswerHasNoHint() {
        rejects("Katze", "der Herr", .de, .default, noHint)
        rejects("voiture", "la maison", .fr, gradingAllOn, noHint)
    }

    @Test func emptyStoredAnswerAcceptsNothing() {
        rejects("irgendwas", "", .de, gradingAllOn)
        rejects("irgendwas", "   ", .de, gradingAllOn)
    }
}

// MARK: - multipleAnswers

@Suite("Grading: multipleAnswers")
struct GradingMultipleAnswersTests: GradingAssertions {
    @Test func oneOfTwoIsPartial() {
        accepts("lieb", "lieb, nett", .de, .default, [.partial])
        accepts("nett", "lieb, nett", .de, .default, [.partial])
    }

    @Test func reorderedGetsNoteOrder() {
        accepts("nett, lieb", "lieb, nett", .de, .default, [.order])
    }

    @Test func separatorsAreInterchangeable() {
        exactMatch("lieb, nett", "lieb, nett", .de)
        exactMatch("lieb,nett", "lieb, nett", .de)
        exactMatch("lieb; nett", "lieb, nett", .de)
    }

    @Test func spacesDoNotSplit() {
        rejects("lieb nett", "lieb, nett", .de, .default, .almost)
    }

    @Test func articleAndPartial() {
        accepts("monsieur", "le monsieur, messieurs", .fr, .default, [.article, .partial])
        accepts("messieurs", "le monsieur, messieurs", .fr, .default, [.partial])
        accepts("le monsieur", "le monsieur, messieurs", .fr, .default, [.partial])
    }

    @Test func anySingleForm() {
        accepts("belle", "beau, bel, belle", .fr, .default, [.partial])
        accepts("bel", "beau, bel, belle", .fr, .default, [.partial])
        accepts("beau, belle", "beau, bel, belle", .fr, .default, [.partial])
    }

    @Test func pluralForms() {
        accepts("Haare", "das Haar, die Haare", .de, .default, [.article, .partial])
        accepts("die Haare", "das Haar, die Haare", .de, .default, [.partial])
        accepts("das Haar", "das Haar, die Haare", .de, .default, [.partial])
    }

    @Test func genderPairs() {
        accepts("mariée", "marié, mariée", .fr, .default, [.partial])
        accepts("marié", "marié, mariée", .fr, .default, [.partial])
    }

    @Test func wrongExtraPart() {
        rejects("lieb, böse", "lieb, nett", .de)
        rejects("lieb, nett", "lieb", .de)
    }

    @Test func repeatedAlternativeIsPartial() {
        accepts("lieb, lieb", "lieb, nett", .de, .default, [.partial])
    }

    @Test func familienname() {
        accepts("Nachname", "der Familienname, der Nachname", .de, .default, [.article, .partial])
    }

    @Test func slashAlternatives() {
        accepts("belle", "beau/belle", .fr, .default, [.partial])
        accepts("beau / belle", "beau/belle", .fr)
        accepts("belle", "beau / belle", .fr, .default, [.partial])
    }

    @Test func eitherArticle() {
        accepts("die Angestellte", "der/die Angestellte", .de, .default, [.partial])
        accepts("der Angestellte", "der/die Angestellte", .de, .default, [.partial])
        exactMatch("der/die Angestellte", "der/die Angestellte", .de)
        accepts("la secrétaire", "le/la secrétaire", .fr, .default, [.partial])
    }

    @Test func suffixNotationIsOneAnswer() {
        rejects("Lehrer", "Lehrer/in", .de)
        exactMatch("Lehrer/in", "Lehrer/in", .de)
    }

    @Test func offOneOfTwoIsWrong() {
        let off = Tolerance(multipleAnswers: false)
        rejects("lieb", "lieb, nett", .de, off)
        rejects("marié", "marié, mariée", .fr, off)
        rejects("Haare", "das Haar, die Haare", .de, off)
    }

    @Test func offAllAnswersInAnyOrder() {
        let off = Tolerance(multipleAnswers: false)
        exactMatch("lieb, nett", "lieb, nett", .de, off)
        accepts("nett, lieb", "lieb, nett", .de, off, [.order])
        accepts("belle, beau, bel", "beau, bel, belle", .fr, off, [.order])
    }

    @Test func offOtherTolerancesStillApply() {
        accepts("monsieur, messieurs", "le monsieur, messieurs", .fr, Tolerance(multipleAnswers: false), [.article])
    }

    @Test func offDuplicateDoesNotCoverMissing() {
        rejects("lieb, lieb", "lieb, nett", .de, Tolerance(multipleAnswers: false))
    }
}

// MARK: - splitAlternatives

@Suite("Grading: splitAlternatives")
struct GradingSplitAlternativesTests: GradingAssertions {
    @Test func commasAndSemicolons() {
        #expect(Grading.splitAlternatives("lieb, nett") == ["lieb", "nett"])
        #expect(Grading.splitAlternatives("gut; gütig") == ["gut", "gütig"])
        #expect(Grading.splitAlternatives("a,, b ;") == ["a", "b"])
        #expect(Grading.splitAlternatives("der Herr") == ["der Herr"])
    }

    @Test func bracketsAndDigitsDoNotSplit() {
        #expect(Grading.splitAlternatives("(sich) freuen (über, auf)") == ["(sich) freuen (über, auf)"])
        #expect(Grading.splitAlternatives("1,5 kg") == ["1,5 kg"])
    }

    @Test func slashRules() {
        #expect(Grading.splitAlternatives("beau/belle") == ["beau", "belle"])
        #expect(Grading.splitAlternatives("beau/bel/belle") == ["beau", "bel", "belle"])
        #expect(Grading.splitAlternatives("Lehrer/in") == ["Lehrer/in"])
        #expect(Grading.splitAlternatives("Lehrer/innen") == ["Lehrer/innen"])
        #expect(Grading.splitAlternatives("km/h") == ["km/h"])
        #expect(Grading.splitAlternatives("marié/e") == ["marié/e"])
    }

    @Test func slashBindsWordsOrPhrases() {
        #expect(Grading.splitAlternatives("der/die Angestellte") == ["der Angestellte", "die Angestellte"])
        #expect(Grading.splitAlternatives("der Lehrer/die Lehrerin") == ["der Lehrer", "die Lehrerin"])
        #expect(Grading.splitAlternatives("le chat/la chatte") == ["le chat", "la chatte"])
        #expect(Grading.splitAlternatives("etw. tun/machen") == ["etw. tun", "etw. machen"])
        #expect(Grading.splitAlternatives("l'homme/la femme") == ["l'homme", "la femme"])
        #expect(Grading.splitAlternatives("s'appeler/se nommer") == ["s'appeler", "se nommer"])
    }

    @Test func spacedSlashAlwaysSeparates() {
        #expect(Grading.splitAlternatives("beau / belle") == ["beau", "belle"])
    }

    @Test func oddInputs() {
        #expect(Grading.splitAlternatives("") == [])
        #expect(Grading.splitAlternatives("42") == ["42"])
        #expect(Grading.splitAlternatives("...") == [])
        #expect(Grading.splitAlternatives("lieb, lieb") == ["lieb"])
    }

    @Test func alternativesAreNormalisedNFC() {
        let alts = Grading.splitAlternatives("séparé, séparée".decomposedStringWithCanonicalMapping)
        #expect(identical(alts, ["séparé", "séparée"]))
    }
}

// MARK: - Parentheses

@Suite("Grading: parentheses")
struct GradingParenthesesTests: GradingAssertions {
    @Test func optionalReflexive() {
        accepts("freuen", "(sich) freuen", .de, .default, [.parentheses])
        let r = accepts("sich freuen", "(sich) freuen", .de, .default, [])
        #expect(!r.exact)
    }

    @Test func optionalEnding() {
        accepts("marié", "marié(e)", .fr, .default, [.parentheses])
        accepts("mariée", "marié(e)", .fr, .default, [])
    }

    @Test func typingTheBracketsIsExact() {
        exactMatch("(sich) freuen", "(sich) freuen", .de)
        exactMatch("marié(e)", "marié(e)", .fr)
    }

    @Test func alternativesInsideBrackets() {
        accepts("freuen über", "freuen (über, auf)", .de, .default, [])
        accepts("freuen auf", "freuen (über, auf)", .de, .default, [])
        accepts("freuen", "freuen (über, auf)", .de, .default, [.parentheses])
        accepts("freuen über, auf", "freuen (über, auf)", .de, .default, [])
    }

    @Test func optionalWordInTheMiddle() {
        accepts("la fille", "la (petite) fille", .fr, .default, [.parentheses])
        accepts("la petite fille", "la (petite) fille", .fr, .default, [])
        accepts("fille", "la (petite) fille", .fr, .default, [.article, .parentheses])
    }

    @Test func squareBrackets() {
        accepts("freuen", "[sich] freuen", .de, .default, [.parentheses])
    }

    @Test func offMissingContentIsWrong() {
        rejects("freuen", "(sich) freuen", .de, Tolerance(parentheses: false), .missingArticle)
        rejects("freuen", "(sich) freuen", .de, Tolerance(articles: false, parentheses: false), .missingArticle)
    }

    @Test func offFullContentIsAccepted() {
        accepts("sich freuen", "(sich) freuen", .de, Tolerance(parentheses: false), [])
        accepts("mariée", "marié(e)", .fr, Tolerance(parentheses: false), [])
    }

    @Test func offMissingEndingIsTypo() {
        rejects("marié", "marié(e)", .fr, Tolerance(parentheses: false), .typo)
    }

    @Test func unbalancedBrackets() {
        accepts("mariée", "marié(e", .fr)
        accepts("freuen", "freuen)", .de)
    }
}

// MARK: - Articles and reflexive pronouns

@Suite("Grading: articles")
struct GradingArticleTests: GradingAssertions {
    @Test func frenchElidedArticle() {
        let r = accepts("homme", "l'homme", .fr, .default, [.article])
        #expect(!r.exact)
    }

    @Test func elisionEqualsFullArticle() {
        accepts("le homme", "l'homme", .fr, .default, [])
        accepts("la homme", "l'homme", .fr, .default, [])
        accepts("le homme", "l'homme", .fr, Tolerance(articles: false), [])
        accepts("l'enfant", "le enfant", .fr, .default, [])
    }

    @Test func offMissingArticle() {
        rejects("homme", "l'homme", .fr, Tolerance(articles: false), .missingArticle)
    }

    @Test func wrongArticleIsAlwaysWrong() {
        for tol in [Tolerance.default, Tolerance(articles: false), gradingAllOn] {
            rejects("la monsieur", "le monsieur, messieurs", .fr, tol, .wrongArticle)
            rejects("un homme", "l'homme", .fr, tol, .wrongArticle)
            rejects("la garçon", "le garçon", .fr, tol, .wrongArticle)
            rejects("le cheveux", "les cheveux", .fr, tol, .wrongArticle)
        }
    }

    @Test func multiWordNouns() {
        accepts("nom de famille", "le nom de famille", .fr, .default, [.article])
        accepts("numéro de la maison", "le numéro de la maison", .fr, .default, [.article])
    }

    @Test func partitive() {
        accepts("eau", "de l'eau", .fr, .default, [.article])
        accepts("de la eau", "de l'eau", .fr, .default, [])
        accepts("pain", "du pain", .fr, .default, [.article])
    }

    @Test func extraArticleIsIgnored() {
        accepts("la personne", "personne", .fr, .default, [])
        accepts("die Frau", "Frau", .de, .default, [])
        accepts("die Frau", "Frau", .de, gradingAllOff, [])
    }

    @Test func capitalisedArticleWithCaseOff() {
        accepts("Le monsieur", "le monsieur", .fr, Tolerance(ignoreCase: false), [])
        accepts("Der Mann", "der Mann", .de, Tolerance(ignoreCase: false), [])
    }

    @Test func reflexives() {
        accepts("appeler", "s'appeler", .fr, .default, [.pronoun])
        accepts("se appeler", "s'appeler", .fr, .default, [])
        accepts("ressembler", "se ressembler", .fr, .default, [.pronoun])
        rejects("ressembler", "se ressembler", .fr, Tolerance(articles: false), .missingArticle)
        rejects("gleichen", "sich gleichen", .de, Tolerance(articles: false), .missingArticle)
        accepts("gleichen", "sich gleichen", .de, .default, [.pronoun])
        accepts("gleichen", "sich ähnlich sein, sich gleichen", .de, .default, [.pronoun, .partial])
        accepts("ähnlich sein", "sich ähnlich sein, sich gleichen", .de, .default, [.pronoun, .partial])
        rejects("le appeler", "s'appeler", .fr, .default, .wrongArticle)
    }

    @Test func german() {
        accepts("Herr", "der Herr", .de, .default, [.article])
        rejects("Herr", "der Herr", .de, Tolerance(articles: false), .missingArticle)
        rejects("den Herr", "der Herr", .de, .default, .wrongArticle)
        rejects("den Herr", "der Herr", .de, Tolerance(articles: false), .wrongArticle)
        rejects("die Haar", "das Haar, die Haare", .de, .default, .wrongArticle)
        rejects("die Haar", "das Haar, die Haare", .de, Tolerance(typos: true), .wrongArticle)
        accepts("Frau", "das Fräulein, die Frau", .de, .default, [.article, .partial])
        accepts("Fräulein", "das Fräulein, die Frau", .de, .default, [.article, .partial])
        rejects("der Frau", "das Fräulein, die Frau", .de, .default, .wrongArticle)
        rejects("ein Mann", "der Mann", .de, .default, .wrongArticle)
    }

    @Test func strasse() {
        accepts("Strasse", "die Strasse", .de, .default, [.article])
        accepts("Straße", "die Strasse", .de, .default, [.article])
        exactMatch("la rue", "la rue", .fr)
        accepts("rue", "la rue", .fr, .default, [.article])
    }

    @Test func dictionaryStyle() {
        accepts("der Herr", "Herr, der", .de, .default, [])
        accepts("Herr", "Herr, der", .de, .default, [.article])
        rejects("die Herr", "Herr, der", .de, .default, .wrongArticle)
        // Answers that are only articles stay separate alternatives.
        accepts("la", "le, la", .fr, .default, [.partial])
        exactMatch("le, la", "le, la", .fr)
    }

    @Test func articlesOnlyForTheirLanguage() {
        rejects("Hard", "die Hard", .en)
        rejects("Herr", "der Herr", .fr)
    }

    @Test func otherOrUnknownLanguageStripsNothing() {
        rejects("Herr", "der Herr", .other)
        rejects("Herr", "der Herr", nil)
        rejects("homme", "l'homme", Grading.resolveLang("xx"))
        accepts("Herr", "der Herr", Grading.resolveLang("de-CH"), .default, [.article])
    }

    @Test func english() {
        accepts("appear", "to appear", .en, .default, [.article])
        accepts("house", "the house", .en, .default, [.article])
        accepts("apple", "an apple", .en, .default, [.article])
        rejects("appear", "to appear", .en, Tolerance(articles: false), .missingArticle)
        accepts("die", "to die", .en, .default, [.article])
        rejects("the apple", "an apple", .en, .default, .wrongArticle)
    }

    @Test func spanishAndItalian() {
        accepts("perro", "el perro", .es, .default, [.article])
        rejects("la perro", "el perro", .es, .default, .wrongArticle)
        accepts("amico", "l'amico", .it, .default, [.article])
        accepts("lo amico", "l'amico", .it, .default, [])
        accepts("una amica", "un'amica", .it, .default, [])
        accepts("ragazzi", "i ragazzi", .it, .default, [.article])
    }

    @Test func wrongArticleWithBracketedArticle() {
        rejects("den Herr", "(der) Herr", .de, .default, .wrongArticle)
        rejects("die Herr", "Herr (der)", .de, .default, .wrongArticle)
        rejects("la monsieur", "(le) monsieur", .fr, .default, .wrongArticle)
        rejects("den Herr", "(der) Herr", .de, gradingAllOn, .wrongArticle)
        accepts("Herr", "(der) Herr", .de, .default, [.parentheses])
        accepts("der Herr", "(der) Herr", .de, .default, [])
        accepts("Herr", "Herr (der)", .de, .default, [.parentheses])
        accepts("le homme", "(l')homme", .fr, .default, [])
        // A trailing bracketed article also reads in front, without a "parentheses" note.
        accepts("der Herr", "Herr (der)", .de, .default, [])
        accepts("l'homme", "homme (l')", .fr, .default, [])
        accepts("to appear", "appear (to)", .en, .default, [])
        accepts("der Herr", "Herr (der)", .de, Tolerance(parentheses: false), [])
        rejects("Herr", "Herr (der)", .de, Tolerance(parentheses: false), .missingArticle)
        accepts("la secrétaire", "(le/la) secrétaire", .fr)
        // An extra article is still ignored when the answer declares none.
        accepts("die Frau", "Frau (Dame)", .de, .default, [.parentheses])
    }
}

// MARK: - Abbreviations

@Suite("Grading: abbreviations")
struct GradingAbbreviationTests: GradingAssertions {
    @Test func etwBothDirections() {
        accepts("etwas machen", "etw. machen", .de, .default, [.abbreviation])
        accepts("etw. machen", "etwas machen", .de, .default, [.abbreviation])
        accepts("etw machen", "etwas machen", .de, .default, [.abbreviation])
    }

    @Test func offAbbreviationsDiffer() {
        rejects("etwas machen", "etw. machen", .de, Tolerance(abbreviations: false))
        rejects("etw. machen", "etwas machen", .de, Tolerance(abbreviations: false))
        exactMatch("etw. machen", "etw. machen", .de, Tolerance(abbreviations: false))
    }

    @Test func german() {
        accepts("jemanden fragen", "jdn. fragen", .de, .default, [.abbreviation])
        accepts("jemandem helfen", "jdm. helfen", .de, .default, [.abbreviation])
        accepts("jemandes Freund", "jds. Freund", .de, .default, [.abbreviation])
        accepts("jemand", "jd.", .de, .default, [.abbreviation])
    }

    @Test func english() {
        accepts("to do something", "to do sth", .en, .default, [.abbreviation])
        accepts("do something", "to do sth", .en, .default, [.article, .abbreviation])
        accepts("to help somebody", "to help sb", .en, .default, [.abbreviation])
        accepts("to help someone", "to help sb", .en, .default, [.abbreviation])
        accepts("to help s.o.", "to help somebody", .en, .default, [.abbreviation])
        accepts("to tell s.th.", "to tell something", .en, .default, [.abbreviation])
        accepts("to wash oneself", "to wash o.s.", .en, .default, [.abbreviation])
    }

    @Test func french() {
        accepts("faire quelque chose", "faire qc", .fr, .default, [.abbreviation])
        accepts("faire qqch", "faire quelque chose", .fr, .default, [.abbreviation])
        accepts("aider quelqu'un", "aider qn", .fr, .default, [.abbreviation])
        accepts("aider quelqu' un", "aider qqn", .fr, .default, [.abbreviation])
    }

    @Test func zbUswBzwOd() {
        accepts("zum Beispiel", "z.B.", .de, .default, [.abbreviation])
        accepts("zum Beispiel", "z. B.", .de, .default, [.abbreviation])
        accepts("zum beispiel", "z.B.", .de, .default, [.abbreviation, .letterCase])
        accepts("Etwas machen", "Etw. machen", .de, Tolerance(ignoreCase: false), [.abbreviation])
        accepts("und so weiter", "usw.", .de, .default, [.abbreviation])
        accepts("beziehungsweise", "bzw.", .de, .default, [.abbreviation])
        accepts("ja oder nein", "ja od. nein", .de, .default, [.abbreviation])
    }

    @Test func standaloneU() {
        accepts("Herr und Frau", "Herr u. Frau", .de, .default, [.abbreviation])
        rejects("und a", "u.a.", .de)
    }

    @Test func combinesWithReflexives() {
        accepts("etwas leisten", "sich etw. leisten", .de, .default, [.pronoun, .abbreviation])
    }

    @Test func wordsThatMerelyStartLikeOne() {
        rejects("etwasig", "etw.", .de)
        exactMatch("sbire", "sbire", .fr)
    }

    @Test func zbWithoutDots() {
        for zb in ["zB", "zb", "z.B.", "zb.", "z. B.", "z B"] {
            accepts(zb, "zum Beispiel", .de, .default, [.abbreviation])
            accepts("zum Beispiel", zb, .de, .default, [.abbreviation])
        }
        accepts("zB", "z. B.", .de, .default, [.abbreviation])
        rejects("zbx", "zum Beispiel", .de)
    }

    @Test("case-insensitive like the JS regex: the long s matches s")
    func longS() {
        accepts("to do ſth", "to do something", .en, .default, [.abbreviation])
    }
}

// MARK: - ignoreCase, ignoreAccents, typos

@Suite("Grading: case, accents, typos")
struct GradingComparatorTests: GradingAssertions {
    @Test func ignoreCase() {
        accepts("der mann", "der Mann", .de, .default, [.letterCase])
        accepts("frau", "Frau", .de, .default, [.letterCase])
        let r = accepts("Monsieur", "monsieur", .fr, .default, [])
        #expect(!r.exact)
        accepts("APPEAR", "to appear", .en, .default, [.article])
        rejects("der mann", "der Mann", .de, Tolerance(ignoreCase: false), .caseOnly)
        rejects("Appeler", "appeler", .fr, Tolerance(ignoreCase: false), .caseOnly)
        accepts("Mann", "der Mann", .de, Tolerance(ignoreCase: false), [.article])
        accepts("mann", "der Mann", .de, .default, [.article, .letterCase])
    }

    @Test func ignoreAccents() {
        rejects("ressembler a", "ressembler à", .fr, .default, .accentsOnly)
        rejects("bete", "bête", .fr, .default, .accentsOnly)
        rejects("hasslich", "hässlich", .de, .default, .accentsOnly)
        rejects("cafe", "café", .fr, .default, .accentsOnly)
        let on = Tolerance(ignoreAccents: true)
        accepts("ressembler a", "ressembler à", .fr, on, [.accents])
        accepts("bete", "bête", .fr, on, [.accents])
        accepts("hasslich", "hässlich", .de, on, [.accents])
        accepts("café", "cafe", .fr, on, [.accents])
    }

    @Test func umlautTransliteration() {
        let on = Tolerance(ignoreAccents: true)
        accepts("die Haeuser", "die Häuser", .de, on, [.accents])
        accepts("huebsch", "hübsch", .de, on, [.accents])
        accepts("Häuser", "Haeuser", .de, on, [.accents])
        rejects("huebsch", "hübsch", .de, .default, .accentsOnly)
        accepts("Madchen", "das Mädchen", .de, on, [.article, .accents])
        accepts("separee", "séparé, séparée", .fr, on, [.partial, .accents])
    }

    @Test func accentsOnlyNeedsTheRightCase() {
        rejects("madchen", "Mädchen", .de, Tolerance(ignoreCase: false), .almost)
        rejects("madchen", "Mädchen", .de, Tolerance(ignoreCase: false, ignoreAccents: true), .caseOnly)
        rejects("Garcon", "garçon", .fr, Tolerance(ignoreCase: false), .almost)
        rejects("GARCON", "le garçon", .fr, Tolerance(ignoreCase: false), .almost)
        rejects("Hubsch", "hübsch", .de, gradingAllOff, .almost)
        rejects("garcon", "garçon", .fr, Tolerance(ignoreCase: false), .accentsOnly)
    }

    @Test func typos() {
        let on = Tolerance(typos: true)
        accepts("verheiratat", "verheiratet", .de, on, [.typo])
        accepts("freundlich", "freundlisch", .de, on, [.typo])
        accepts("le monsieu", "le monsieur, messieurs", .fr, on, [.partial, .typo])
        accepts("ntet", "nett", .de, on, [.typo])
        accepts("Shcönheit", "die Schönheit", .de, on, [.article, .typo])
        rejects("ntet", "nett", .de, .default, .typo)
        rejects("verheiratat", "verheiratet", .de, .default, .typo)
        rejects("bom", "bon", .fr, on)
        rejects("der Mutt", "der Mut", .de, on)
        accepts("der Familliennamme", "der Familienname", .de, on, [.typo])
        rejects("der Familliennammee", "der Familienname", .de, on, .almost)
        rejects("verwidwed", "verwitwet", .de, on, .almost)
        rejects("den Mann", "der Mann", .de, gradingAllOn, .wrongArticle)
        accepts("lemonsieur", "le monsieur", .fr, on, [.typo])
        accepts("hand", "Hand", .de, Tolerance(ignoreCase: false, typos: true), [.typo])
        accepts("separe", "séparée", .fr, Tolerance(ignoreAccents: true, typos: true), [.accents, .typo])
        rejects("separe", "séparée", .fr, on, .almost)
    }
}

// MARK: - Hints and combinations

@Suite("Grading: hints and combined tolerances")
struct GradingHintTests: GradingAssertions {
    @Test func hints() {
        rejects("Aufmärksamkat", "Aufmerksamkeit", .de, .default, .almost)
        rejects("la numero", "le numéro", .fr, .default, .wrongArticle)
        rejects("numero", "le numéro", .fr, Tolerance(articles: false), .missingArticle)
        rejects("Fraulein", "das Fräulein, die Frau", .de, Tolerance(articles: false), .missingArticle)
        rejects("Fraulein", "das Fräulein, die Frau", .de, .default, .accentsOnly)
        rejects("Her", "der Herr", .de, .default, .typo)
        rejects("Vornahme", "der Vorname", .de, .default, .typo)
        rejects("Hrr", "der Herr", .de, .default, .typo)
        #expect(Grading.grade(given: "Herr", expected: "der Herr", lang: .de).hint == nil)
        #expect(Grading.grade(given: "den Herr", expected: "der Herr", lang: .de).notes == [])
    }

    @Test func wrongArticlePlusTypoIsAlmost() {
        rejects("der Strase", "die Straße", .de, .default, .almost)
        rejects("der Name", "die Dame", .de, .default, .almost)
        rejects("der Strasse", "die Straße", .de, .default, .wrongArticle)
        rejects("la nome", "le nom", .fr, .default, noHint)
    }

    @Test func allOn() {
        accepts("ressembler a", "ressembler à", .fr, gradingAllOn, [.accents])
        accepts("Freundlichkiet", "freundlichkeit, die Güte", .de, gradingAllOn)
        accepts("gute", "die Güte", .de, gradingAllOn, [.article, .letterCase, .accents])
        accepts("Gute", "die Güte", .de, gradingAllOn, [.article, .accents])
    }

    @Test func allOffOnlyAcceptsTheFullAnswer() {
        rejects("monsieur", "le monsieur, messieurs", .fr, gradingAllOff, .missingArticle)
        rejects("le monsieur", "le monsieur, messieurs", .fr, gradingAllOff)
        exactMatch("le monsieur, messieurs", "le monsieur, messieurs", .fr, gradingAllOff)
    }

    @Test func defaultTolerance() {
        accepts("Herr", "der Herr", .de, Grading.DEFAULT_TOLERANCE, [.article])
        rejects("bete", "bête", .fr, Tolerance(json: ["typos": "yes"]), .accentsOnly)
        #expect(Grading.DEFAULT_TOLERANCE == Tolerance(
            articles: true, abbreviations: true, multipleAnswers: true, parentheses: true, ignoreCase: true,
            ignoreAccents: false, typos: false))
    }

    @Test("odd tolerance values fall back to the defaults")
    func oddTolerances() {
        for json: JSONValue in [nil, 5, "x", [], ["articles": 1], [:]] {
            let tol = Tolerance(json: json)
            #expect(tol == .default)
            #expect(Grading.grade(given: "Herr", expected: "der Herr", tolerance: tol, lang: .de).correct)
        }
    }

    @Test("resolveLang reads codes like JS")
    func resolveLang() {
        #expect(Grading.resolveLang("de") == .de)
        #expect(Grading.resolveLang("DE") == .de)
        #expect(Grading.resolveLang(" de-CH ") == .de)
        #expect(Grading.resolveLang("fr_CH") == .fr)
        #expect(Grading.resolveLang("en-GB") == .en)
        for code: String? in [nil, "", "zz", "other", "xx", "d"] { #expect(Grading.resolveLang(code) == nil) }
        #expect(Grading.grade(given: "Herr", expected: "der Herr", lang: Grading.resolveLang("DE")).correct)
    }
}

// MARK: - Robustness

@Suite("Grading: robustness")
struct GradingRobustnessTests: GradingAssertions {
    @Test("String forms of JS primitives never break grading")
    func oddValues() {
        let odd = ["", "0", "42", "-1.5", "NaN", "true", "false", "[object Object]", "a,b", "() => 1"]
        for g in odd {
            for e in odd {
                let r = Grading.grade(given: g, expected: e, lang: .de)
                if r.correct { #expect(r.hint == nil) } else { #expect(r.notes.isEmpty) }
            }
        }
        exactMatch("42", "42", .de)
    }

    @Test func emojiAndUnusualUnicode() {
        exactMatch("🙂", "🙂", .de)
        rejects("🙂", "lieb", .de)
        rejects("lieb", "🙂", .de)
        exactMatch("Haus 🏠", "Haus 🏠", .de)
        _ = Grading.grade(given: "İstanbul", expected: "istanbul", tolerance: gradingAllOn, lang: .en)
        rejects("\u{200B}", "a", .en, gradingAllOn)
    }

    @Test("Greek final sigma is lowercased like JS")
    func finalSigma() {
        // JS: "ΟΔΟΣ".toLowerCase() === "οδος" (final ς), so it differs from "οδοσ".
        accepts("ΟΔΟΣ", "οδος", nil, .default, [])
        rejects("ΟΔΟΣ", "οδοσ", nil)
    }

    @Test func veryLongStrings() {
        let long = String(repeating: "a", count: 100_000)
        exactMatch(long, long, .de)
        rejects(long, String(repeating: "b", count: 100_000), .de, gradingAllOn)
        rejects(long + "b", long + "c", .de, gradingAllOn)
        #expect(!Grading.grade(given: long, expected: "Herr", tolerance: gradingAllOn, lang: .de).correct)
        #expect(!Grading.grade(given: "Herr", expected: long, tolerance: gradingAllOn, lang: .de).correct)
    }

    @Test func manySeparatorsSlashesAndBrackets() {
        let manyAlts = (0..<3000).map { "wort\($0)" }.joined(separator: ", ")
        _ = Grading.grade(given: "wort5", expected: manyAlts, tolerance: gradingAllOn, lang: .de)
        #expect(Grading.grade(given: manyAlts, expected: manyAlts, tolerance: gradingAllOn, lang: .de).exact)
        _ = Grading.grade(
            given: "a/b/c/d/e/f/g/h/i/j/k/l/m", expected: "aaa/bbb/ccc/ddd/eee/fff/ggg/hhh/iii", tolerance: gradingAllOn,
            lang: .de)
        _ = Grading.grade(given: "a", expected: "((((((((a))))))))", tolerance: gradingAllOn, lang: .de)
        accepts("abcdefghij", "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)", .de, gradingAllOn)
        _ = Grading.grade(given: "x", expected: ")))(((", tolerance: gradingAllOn, lang: .de)
    }

    @Test("the whole fixture grades under every eighth toggle combination")
    func everyToggleCombination() {
        for mask in stride(from: 0, to: 128, by: 9) {
            let tol = GradingParityTests.tolerance(mask: mask)
            for i in gradingPairs.indices {
                let (term, def) = gradingPairs[i]
                let (otherTerm, otherDef) = gradingPairs[(i + 7) % gradingPairs.count]
                #expect(Grading.grade(given: term, expected: term, tolerance: tol, lang: .fr).exact)
                _ = Grading.grade(given: otherTerm, expected: term, tolerance: tol, lang: .fr)
                _ = Grading.grade(given: otherDef, expected: def, tolerance: tol, lang: .de)
            }
        }
    }
}

// MARK: - Review regressions: slashes, sentences, annotations

@Suite("Grading: slashes, sentences and annotations")
struct GradingRegressionTests: GradingAssertions {
    @Test func slashBindsToPlaceholders() {
        #expect(Grading.splitAlternatives("an jdn./etw. denken") == ["an jdn. denken", "an etw. denken"])
        #expect(Grading.splitAlternatives("auf jdn./etw. warten") == ["auf jdn. warten", "auf etw. warten"])
        #expect(Grading.splitAlternatives("mit jdm./etw. sprechen") == ["mit jdm. sprechen", "mit etw. sprechen"])
        #expect(Grading.splitAlternatives("an jemanden/etwas denken") == ["an jemanden denken", "an etwas denken"])
        #expect(Grading.splitAlternatives("etw./sich ändern") == ["etw. ändern", "sich ändern"])
        #expect(Grading.splitAlternatives("jdn./sich vorstellen") == ["jdn. vorstellen", "sich vorstellen"])
        #expect(Grading.splitAlternatives("penser à quelqu'un/quelque chose") == ["penser à quelqu'un", "penser à quelque chose"])
    }

    @Test func fullAnswersAcceptedFragmentsNot() {
        accepts("an jemanden denken", "an jdn./etw. denken", .de, .default, [.abbreviation, .partial])
        accepts("an jdn. denken", "an jdn./etw. denken", .de, .default, [.partial])
        accepts("auf etwas warten", "auf jdn./etw. warten", .de, .default, [.abbreviation, .partial])
        accepts("mit jemandem sprechen", "mit jdm./etw. sprechen", .de, .default, [.abbreviation, .partial])
        accepts("etwas ändern", "etw./sich ändern", .de, .default, [.abbreviation, .partial])
        accepts("sich ändern", "etw./sich ändern", .de, .default, [.partial])
        exactMatch("an jdn./etw. denken", "an jdn./etw. denken", .de)
        rejects("an jemanden", "an jdn./etw. denken", .de)
        rejects("etwas denken", "an jdn./etw. denken", .de)
        rejects("mit jemandem", "mit jdm./etw. sprechen", .de)
        rejects("etwas", "etw./sich ändern", .de)
    }

    @Test func trailingArticleGroupReplacesParallelGroup() {
        #expect(Grading.splitAlternatives("faire du vélo/du ski") == ["faire du vélo", "faire du ski"])
        #expect(Grading.splitAlternatives("to play the piano/the guitar") == ["to play the piano", "to play the guitar"])
        #expect(Grading.splitAlternatives("jouer au foot/au tennis") == ["jouer au foot", "jouer au tennis"])
        accepts("faire du ski", "faire du vélo/du ski", .fr, .default, [.partial])
        accepts("jouer au tennis", "jouer au foot/au tennis", .fr, .default, [.partial])
        rejects("du ski", "faire du vélo/du ski", .fr)
        #expect(Grading.splitAlternatives("faire du vélo/du ski/du golf") == ["faire du vélo", "faire du ski", "faire du golf"])
        #expect(Grading.splitAlternatives("faire du vélo électrique/du ski") == ["faire du vélo électrique", "faire du ski"])
        #expect(Grading.splitAlternatives("ich habe einen Hund/eine Katze") == ["ich habe einen Hund", "ich habe eine Katze"])
        // A contracted article replaces the preposition too.
        #expect(Grading.splitAlternatives("aller à la plage/au cinéma") == ["aller à la plage", "aller au cinéma"])
        #expect(Grading.splitAlternatives("aller à l'école/au cinéma") == ["aller à l'école", "aller au cinéma"])
        #expect(Grading.splitAlternatives("parler de la famille/du travail") == ["parler de la famille", "parler du travail"])
        accepts("aller au cinéma", "aller à la plage/au cinéma", .fr, .default, [.partial])
        // Whole phrases on both sides stay whole.
        #expect(Grading.splitAlternatives("Guten Morgen/Guten Tag") == ["Guten Morgen", "Guten Tag"])
        #expect(Grading.splitAlternatives("das Haus der Familie/die Wohnung") == ["das Haus der Familie", "die Wohnung"])
        #expect(Grading.splitAlternatives("aller au lit/se coucher") == ["aller au lit", "se coucher"])
        #expect(Grading.splitAlternatives("to go to bed/to sleep") == ["to go to bed", "to sleep"])
        #expect(Grading.splitAlternatives("ein Glas Wasser/eine Tasse Tee") == ["ein Glas Wasser", "eine Tasse Tee"])
    }

    @Test func articlePairBindsToTheNoun() {
        #expect(Grading.splitAlternatives("mit der/dem Lehrer") == ["mit der Lehrer", "mit dem Lehrer"])
        #expect(Grading.splitAlternatives("avec le/la secrétaire") == ["avec le secrétaire", "avec la secrétaire"])
        accepts("mit dem Lehrer", "mit der/dem Lehrer", .de, .default, [.partial])
        rejects("dem Lehrer", "mit der/dem Lehrer", .de)
    }

    @Test func frenchVerbPhrasePairs() {
        let cases: [(String, [String])] = [
            ("laver qc/se laver", ["laver qc", "se laver"]),
            ("réveiller qn/se réveiller", ["réveiller qn", "se réveiller"]),
            ("changer qc/se changer", ["changer qc", "se changer"]),
            ("coucher qn/se coucher", ["coucher qn", "se coucher"]),
            ("lever qc/se lever", ["lever qc", "se lever"]),
            ("promener qn/se promener", ["promener qn", "se promener"]),
            ("demander qc/se demander", ["demander qc", "se demander"]),
            ("lever qc/se coucher", ["lever qc", "se coucher"]),
            ("habiller qn/s'habiller", ["habiller qn", "s'habiller"]),
        ]
        for (stored, alts) in cases { #expect(Grading.splitAlternatives(stored) == alts) }
        accepts("se laver", "laver qc/se laver", .fr, .default, [.partial])
        accepts("laver quelque chose", "laver qc/se laver", .fr, .default, [.abbreviation, .partial])
        accepts("se réveiller", "réveiller qn/se réveiller", .fr, .default, [.partial])
        accepts("s'habiller", "habiller qn/s'habiller", .fr, .default, [.partial])
        exactMatch("changer qc, se changer", "changer qc/se changer", .fr)
        exactMatch("laver qc / se laver", "laver qc/se laver", .fr, gradingAllOff)
        rejects("laver qc laver", "laver qc/se laver", .fr)
        // German and English reflexives share the verb with the object placeholder.
        #expect(Grading.splitAlternatives("an jdn./sich denken") == ["an jdn. denken", "an sich denken"])
        #expect(Grading.splitAlternatives("to wash sth/oneself") == ["to wash sth", "to wash oneself"])
        #expect(Grading.splitAlternatives("to look after sb/oneself well") == ["to look after sb well", "to look after oneself well"])
        // "se" is also a suffix.
        #expect(Grading.splitAlternatives("heureux/se") == ["heureux/se"])
    }

    @Test func shortPlaceholders() {
        #expect(Grading.splitAlternatives("to think of sb/sth") == ["to think of sb", "to think of sth"])
        #expect(Grading.splitAlternatives("penser à qn/qc") == ["penser à qn", "penser à qc"])
        accepts("think of somebody", "to think of sb/sth", .en, .default, [.article, .abbreviation, .partial])
        accepts("think of sb", "to think of sb/sth", .en, .default, [.article, .partial])
        accepts("be afraid of sb", "to be afraid of sb/sth", .en, .default, [.article, .partial])
        accepts("penser à quelqu'un", "penser à qn/qc", .fr, .default, [.abbreviation, .partial])
        accepts("attendre quelque chose", "attendre qn/qc", .fr, .default, [.abbreviation, .partial])
        exactMatch("to think of sb/sth", "to think of sb/sth", .en)
    }

    @Test func shortPronounLists() {
        #expect(Grading.splitAlternatives("il/elle") == ["il", "elle"])
        #expect(Grading.splitAlternatives("er/sie/es") == ["er", "sie", "es"])
        #expect(Grading.splitAlternatives("mon/ma/mes") == ["mon", "ma", "mes"])
        #expect(Grading.splitAlternatives("Er/sie") == ["Er", "sie"])
        exactMatch("il, elle", "il/elle", .fr)
        exactMatch("he / she", "he/she", .en)
        exactMatch("er, sie, es", "er/sie/es", .de)
        exactMatch("mon, ma, mes", "mon/ma/mes", .fr)
        accepts("tu", "tu/vous", .fr, .default, [.partial])
    }

    @Test func suffixNotation() {
        for s in ["Lehrer/in", "Lehrer/innen", "marié/e", "km/h", "bon/ne", "gros/se", "ein/e", "jede/r"] {
            #expect(Grading.splitAlternatives(s) == [s])
        }
    }

    @Test func commasInsideSentences() {
        let cases: [(String, String, Lang)] = [
            ("please", "Can you help me, please?", .en),
            ("merci", "Ça va bien, merci.", .fr),
            ("Madame", "Excusez-moi, Madame.", .fr),
            ("Danke", "Danke, gleichfalls!", .de),
            ("Hallo", "Hallo, wie geht's?", .de),
            ("Oui", "Oui, merci.", .fr),
            ("Monsieur", "Bonjour, Monsieur!", .fr),
            ("Hallo", "Hallo, wie geht es dir…", .de),
        ]
        for (given, expected, lang) in cases {
            rejects(given, expected, lang)
            #expect(Grading.splitAlternatives(expected) == [expected])
            exactMatch(expected, expected, lang)
        }
        exactMatch("Ça va bien merci", "Ça va bien, merci.", .fr)
        accepts("ca va bien, merci", "Ça va bien, merci.", .fr, Tolerance(ignoreAccents: true), [.accents])
    }

    @Test func listsEndingInAbbreviationOrMarker() {
        #expect(Grading.splitAlternatives("jdn. fragen, etw. tun") == ["jdn. fragen", "etw. tun"])
        #expect(Grading.splitAlternatives("zum Beispiel, z. B.") == ["zum Beispiel", "z. B."])
        #expect(Grading.splitAlternatives("lieb, nett") == ["lieb", "nett"])
        #expect(Grading.splitAlternatives("Ça va?, Comment vas-tu?") == ["Ça va?", "Comment vas-tu?"])
        accepts("lieb", "lieb, nett", .de, .default, [.partial])
    }

    @Test func finalDotAloneIsNoSentence() {
        // Lowercase start: a list with a trailing dot.
        #expect(Grading.splitAlternatives("ja, nein.") == ["ja", "nein."])
        #expect(Grading.splitAlternatives("das Auto, die Autos.") == ["das Auto", "die Autos."])
        accepts("ja", "ja, nein.", .de, .default, [.partial])
        // Dictionary form with a trailing article.
        #expect(Grading.splitAlternatives("Herr, der.") == ["Herr", "der."])
        accepts("der Herr", "Herr, der.", .de, .default, [])
        accepts("Herr", "Herr, der.", .de, .default, [.article])
        // Capitalised sentences, also inside quotes.
        #expect(Grading.splitAlternatives("«Oui, merci.»") == ["«Oui, merci.»"])
        rejects("Oui", "«Oui, merci.»", .fr)
    }

    @Test func germanNounListsWithFinalDot() {
        #expect(Grading.splitAlternatives("Mappe, Tasche.", lang: .de) == ["Mappe", "Tasche."])
        #expect(Grading.splitAlternatives("Haus, Gebäude.", lang: .de) == ["Haus", "Gebäude."])
        #expect(Grading.splitAlternatives("Die Mappe, die Tasche.", lang: .de) == ["Die Mappe", "die Tasche."])
        accepts("Mappe", "Mappe, Tasche.", .de, .default, [.partial])
        accepts("Tasche", "Mappe, Tasche.", .de, .default, [.partial])
        accepts("Haus", "Haus, Gebäude.", .de, .default, [.partial])
        accepts("Mappe", "Die Mappe, die Tasche.", .de, .default, [.article, .partial])
        exactMatch("Mappe, Tasche", "Mappe, Tasche.", .de)
        // Real German sentences stay one answer.
        for s in ["Ja, gerne.", "Guten Tag, Frau Müller.", "Danke, gleichfalls!"] {
            #expect(Grading.splitAlternatives(s, lang: .de) == [s])
        }
        rejects("Ja", "Ja, gerne.", .de)
        rejects("Frau Müller", "Guten Tag, Frau Müller.", .de)
        // Only German capitalises nouns: in French this is a sentence.
        #expect(Grading.splitAlternatives("Excusez-moi, Madame.", lang: .fr) == ["Excusez-moi, Madame."])
        rejects("Madame", "Excusez-moi, Madame.", .fr)
    }

    @Test func commaAnnotations() {
        #expect(Grading.splitAlternatives("der Tisch, -e") == ["der Tisch"])
        #expect(Grading.splitAlternatives("das Auto, -s") == ["das Auto"])
        #expect(Grading.splitAlternatives("die Mutter, ¨") == ["die Mutter"])
        #expect(Grading.splitAlternatives("die Stadt, ¨-e") == ["die Stadt"])
        #expect(Grading.splitAlternatives("maison, f") == ["maison"])
        #expect(Grading.splitAlternatives("les gens, pl.") == ["les gens"])
        #expect(Grading.splitAlternatives("le/la secrétaire, m./f.") == ["le secrétaire", "la secrétaire"])
        // A card whose answer is only markers keeps them.
        #expect(Grading.splitAlternatives("m, f") == ["m", "f"])
        rejects("e", "der Tisch, -e", .de)
        rejects("s", "das Auto, -s", .de)
        rejects("f", "maison, f", .fr)
        exactMatch("der Tisch", "der Tisch, -e", .de)
        exactMatch("der Tisch, -e", "der Tisch, -e", .de)
        exactMatch("das Auto", "das Auto, -s", .de, Tolerance(multipleAnswers: false))
        exactMatch("maison", "maison, f", .fr, Tolerance(multipleAnswers: false))
    }

    @Test func learnersAnnotationMustBeTheStoredOne() {
        rejects("der Tisch, -s", "der Tisch, -e", .de, gradingAllOff, .almost)
        rejects("der Tisch, -s", "der Tisch, -e", .de, .default, .almost)
        rejects("maison, m", "maison, f", .fr, .default, .almost)
        rejects("das Auto, -en", "das Auto, -s", .de, .default, .almost)
        rejects("le chat, m", "le chat", .fr, .default, .almost)
        exactMatch("der Tisch, -e", "der Tisch, -e", .de, gradingAllOff)
        exactMatch("maison, f.", "maison, f", .fr, gradingAllOff)
        exactMatch("die Eltern, Pl.", "die Eltern, Pl.", .de, gradingAllOff)
        exactMatch("die Eltern", "die Eltern, Pl.", .de, gradingAllOff)
        // Capitals are answers, not markers.
        #expect(Grading.splitAlternatives("Mme, M.") == ["Mme", "M."])
        #expect(Grading.splitAlternatives("S, M, L") == ["S", "M", "L"])
        accepts("M.", "Mme, M.", .fr, .default, [.partial])
        accepts("M", "S, M, L", .en, .default, [.partial])
    }

    @Test func punctuationOnlyStoredAnswers() {
        for s in ["?", "!", "…", "...", "-", "–", "*", "~", "\"", "«»", "%", "&", "+"] { exactMatch(s, s, .fr) }
        exactMatch("–", "-", .de)
        exactMatch(". . .", "...", .de)
        rejects("!", "?", .fr, gradingAllOn)
        rejects("frage", "?", .de, gradingAllOn)
        rejects("?", "lieb", .de, gradingAllOn)
    }
}

// MARK: - diffChars / diffAnswer

@Suite("Grading: diffChars and diffAnswer")
struct GradingDiffTests: GradingAssertions {
    @Test func identicalStrings() {
        #expect(Grading.diffChars("Herr", "Herr") == [seg(.same, "Herr")])
    }

    @Test func emptyStrings() {
        #expect(Grading.diffChars("", "") == [])
        #expect(Grading.diffChars("", "abc") == [seg(.add, "abc")])
        #expect(Grading.diffChars("abc", "") == [seg(.del, "abc")])
    }

    @Test func substitution() {
        #expect(Grading.diffChars("Herz", "Herr") == [seg(.same, "Her"), seg(.del, "z"), seg(.add, "r")])
    }

    @Test func missingAndExtraCharacters() {
        #expect(Grading.diffChars("Madchen", "Mädchen") == [seg(.same, "M"), seg(.del, "a"), seg(.add, "ä"), seg(.same, "dchen")])
        #expect(Grading.diffChars("Herr", "der Herr") == [seg(.add, "der "), seg(.same, "Herr")])
        #expect(Grading.diffChars("der Herrr", "der Herr") == [seg(.same, "der Herr"), seg(.del, "r")])
    }

    @Test func segmentsRebuildBothStringsAndAreMerged() {
        let words = gradingPairs.flatMap { [$0.term, $0.definition] }
        for i in words.indices {
            let a = words[i]
            let b = words[(i + 5) % words.count]
            let segs = Grading.diffChars(a, b)
            let rebuilt = rebuild(segs)
            #expect(rebuilt.given == a && rebuilt.expected == b)
            for (k, s) in segs.enumerated() {
                #expect(!s.text.isEmpty)
                if k > 0 { #expect(s.type != segs[k - 1].type) }
            }
        }
    }

    @Test func lcsKeepsTheLongestCommonSubsequence() {
        let same = Grading.diffChars("ressembler", "se ressembler").filter { $0.type == .same }.map(\.text).joined()
        #expect(same == "ressembler")
    }

    @Test func surrogatePairsStayIntactAndInputIsNFC() {
        #expect(Grading.diffChars("a🙂b", "a🙃b") == [seg(.same, "a"), seg(.del, "🙂"), seg(.add, "🙃"), seg(.same, "b")])
        let segs = Grading.diffChars("séparée".decomposedStringWithCanonicalMapping, "séparée")
        #expect(segs.count == 1 && segs[0].type == .same && JSCompat.identical(segs[0].text, "séparée"))
    }

    @Test func veryLongStringsFallBack() {
        let a = "x" + String(repeating: "a", count: 3000)
        let b = "y" + String(repeating: "b", count: 3000)
        let rebuilt = rebuild(Grading.diffChars(a, b))
        #expect(rebuilt.given == a && rebuilt.expected == b)
        let c = String(repeating: "a", count: 50_000)
        #expect(Grading.diffChars(c, c) == [seg(.same, c)])
    }

    @Test func diffAnswerIgnoresGradingEquivalences() {
        #expect(Grading.diffAnswer("Fussbal", "Fußball") == [seg(.same, "Fussbal"), seg(.add, "l")])
        #expect(Grading.diffAnswer("die Strase", "die Straße") == [seg(.same, "die Stras"), seg(.add, "s"), seg(.same, "e")])
        #expect(Grading.diffAnswer("l'homm", "l’homme") == [seg(.same, "l'homm"), seg(.add, "e")])
        #expect(Grading.diffAnswer("le  monsieur", "le monsieur") == [seg(.same, "le monsieur")])
        #expect(Grading.diffAnswer("l' homme", "l'homme") == [seg(.same, "l'homme")])
        #expect(Grading.diffAnswer("coer", "cœur") == [seg(.same, "coe"), seg(.add, "u"), seg(.same, "r")])
    }

    @Test func diffAnswerKeepsATypedSharpS() {
        #expect(Grading.diffAnswer("Straße", "Straße") == [seg(.same, "Straße")])
        let r1 = rebuild(Grading.diffAnswer("Strase", "Straße"))
        #expect(r1.given == "Strase" && r1.expected == "Strasse")
        let r2 = rebuild(Grading.diffAnswer("Straß", "Straße"))
        #expect(r2.given == "Straß" && r2.expected == "Straße")
        #expect(Grading.diffAnswer("", "") == [])
    }
}

// MARK: - Exported constants

@Suite("Grading: constants")
struct GradingConstantsTests: GradingAssertions {
    @Test func articles() {
        #expect(Grading.ARTICLES[.fr]?.contains("l'") == true)
        #expect(Grading.ARTICLES[.fr]?.contains("de la") == true)
        #expect(Grading.ARTICLES[.de]?.contains("der") == true)
        #expect(Grading.ARTICLES[.de]?.contains("eines") == true)
        #expect(Grading.ARTICLES[.en]?.contains("to") == true)
        #expect(Grading.ARTICLES[.es]?.contains("unas") == true)
        #expect(Grading.ARTICLES[.it]?.contains("un'") == true)
    }

    @Test func reflexives() {
        #expect(Grading.REFLEXIVES == [.fr: ["se ", "s'"], .de: ["sich "], .en: ["oneself"], .es: [], .it: [], .ar: [], .zh: []])
    }

    @Test("Arabic has the glued article ال, Chinese has none")
    func scriptArticles() {
        #expect(Grading.ARTICLES[.ar] == ["ال"])
        #expect(Grading.ARTICLES[.zh] == [])
        #expect(Grading.GLUED_ARTICLES == ["ال"])
        #expect(Set(Grading.ARTICLES.keys) == [.fr, .de, .en, .es, .it, .ar, .zh])
        #expect(Grading.resolveLang("ar-SA") == .ar)
        #expect(Grading.resolveLang("zh-CN") == .zh)
        #expect(Grading.resolveLang("ZH") == .zh)
    }

    @Test func abbreviations() {
        #expect(Grading.ABBREVIATIONS.count > 10)
        for rule in Grading.ABBREVIATIONS {
            #expect(rule.pattern.hasSuffix(AbbreviationRule.wordEnd))
            #expect(!rule.canonical.isEmpty)
        }
        // Every rule is understood by the matcher: its canonical form is accepted for its shortest spelling.
        accepts("etwas", "etw.", .de, .default, [.abbreviation])
        accepts("und", "u.", .de, .default, [.abbreviation])
    }

    @Test func orders() {
        #expect(Grading.NOTE_ORDER.map(\.rawValue) == [
            "article", "pronoun", "abbreviation", "partial", "parentheses", "pinyin", "case", "accents", "tones", "variant",
            "typo", "order",
        ])
        #expect(Grading.HINT_ORDER.map(\.rawValue) == [
            "wrongArticle", "missingArticle", "accentsOnly", "tonesOnly", "caseOnly", "typo", "almost",
        ])
        // Every note a grade can give is ordered (the synonym notes are added by Synonyms).
        #expect(Set(GradeNote.allCases).subtracting(Grading.NOTE_ORDER) == [.synonym, .extendedSynonym])
        #expect(Set(GradeHint.allCases) == Set(Grading.HINT_ORDER))
    }

    @Test("GradeResult encodes like JS, with an explicit null hint")
    func resultJSON() throws {
        let r = Grading.grade(given: "Herr", expected: "der Herr", lang: .de)
        let json = try JSONValue(encoding: r)
        #expect(json == ["correct": true, "exact": false, "notes": ["article"], "hint": nil, "expectedDisplay": "der Herr"])
        let wrong = try JSONValue(encoding: Grading.grade(given: "den Herr", expected: "der Herr", lang: .de))
        #expect(wrong["hint"] == "wrongArticle")
    }
}
