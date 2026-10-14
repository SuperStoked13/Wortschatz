import Foundation
import Testing
import WortschatzCore
@testable import WortschatzImport

@Suite("VocabSpellChecker")
@MainActor
struct VocabSpellCheckerTests {
    /// A checker with its own ignore list, so tests never touch the app's settings.
    static func checker() -> VocabSpellChecker {
        let suite = "VocabSpellCheckerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return VocabSpellChecker(defaults: defaults)
    }

    static func words(_ issues: [SpellingIssue]) -> [String] { issues.map(\.word) }

    @Test("The user's 52-pair list has no false alarms")
    func userListIsClean() throws {
        let checker = Self.checker()
        try #require(checker.supports(.fr) && checker.supports(.de), "macOS spell checker without French/German")
        let text = try #require(String(data: try TestDocuments.resource("user-example.txt"), encoding: .utf8))
        let result = VocabParser.parseVocab(text, options: ParseOptions())
        #expect(result.cards.count == 52)
        for card in result.cards {
            #expect(checker.issues(in: card.term, lang: .fr).isEmpty, "term \(card.term)")
            #expect(checker.issues(in: card.definition, lang: .de).isEmpty, "definition \(card.definition)")
        }
    }

    @Test("Typos are found with the right suggestion first")
    func typos() {
        let checker = Self.checker()
        let separee = checker.issues(in: "séparé, separee", lang: .fr)
        #expect(Self.words(separee) == ["separee"])
        #expect(separee.first?.suggestions.first == "séparée")
        #expect(separee.first?.range == NSRange(location: 8, length: 7))

        let hausnummer = checker.issues(in: "die Hausnumer", lang: .de)
        #expect(hausnummer.first?.suggestions.first == "Hausnummer")

        let heissen = checker.issues(in: "heisen", lang: .de)
        #expect(heissen.first?.suggestions.first == "heissen", "Swiss spelling, closest word first")
    }

    @Test("Swiss spelling: ss is right, suggestions never use the sharp s")
    func swissSpelling() {
        let checker = Self.checker()
        for word in ["die Strasse", "heissen", "gross", "der Fussball", "schliessen", "das Schloss", "der Schlussstrich"] {
            #expect(checker.issues(in: word, lang: .de).isEmpty, "\(word)")
        }
        let strase = checker.issues(in: "die Strase", lang: .de)
        #expect(!strase.isEmpty)
        #expect(strase.allSatisfy { !$0.suggestions.joined().contains("ß") })
        #expect(strase.first?.suggestions.contains("Strasse") == true)
    }

    @Test("Vocab abbreviations, acronyms and numbers are not typos")
    func abbreviations() {
        let checker = Self.checker()
        #expect(checker.issues(in: "an jdn./etw. denken", lang: .de).isEmpty)
        #expect(checker.issues(in: "jdm. etw. geben, z.B. ein Buch", lang: .de).isEmpty)
        #expect(checker.issues(in: "penser à qn/qc", lang: .fr).isEmpty)
        #expect(checker.issues(in: "to think of sb/sth", lang: .en).isEmpty)
        #expect(checker.issues(in: "le TGV, la SNCF", lang: .fr).isEmpty)
        #expect(checker.issues(in: "le 14 juillet, 3e étage", lang: .fr).isEmpty)
    }

    @Test("Ignored words stay ignored, per language")
    func ignoring() {
        let checker = Self.checker()
        #expect(!checker.issues(in: "Kevinou", lang: .fr).isEmpty)
        checker.ignore("Kevinou", lang: .fr)
        #expect(checker.issues(in: "Kevinou", lang: .fr).isEmpty)
        #expect(checker.isIgnored("kevinou", lang: .fr))
        #expect(!checker.isIgnored("Kevinou", lang: .de))
        checker.resetIgnored()
        #expect(!checker.issues(in: "Kevinou", lang: .fr).isEmpty)
    }

    @Test("Other languages and empty text are skipped")
    func unsupported() {
        let checker = Self.checker()
        #expect(checker.language(for: .other) == nil)
        #expect(checker.issues(in: "xqzt", lang: .other).isEmpty)
        #expect(checker.issues(in: "   ", lang: .fr).isEmpty)
    }

    @Test("Ranking prefers the closest word with the same first letter and case")
    func ranking() {
        #expect(VocabSpellChecker.ranked(["eisen", "weisen", "heissen"], for: "heisen") == ["heissen", "eisen", "weisen"])
        #expect(VocabSpellChecker.ranked(["sépare", "séparée"], for: "separee").first == "séparée")
        #expect(VocabSpellChecker.ranked(["Mason", "maçon", "maison"], for: "mason").last == "Mason")
        #expect(VocabSpellChecker.editDistance(Array("ab"), Array("ba")) == 1)
        #expect(VocabSpellChecker.editDistance(Array(""), Array("abc")) == 3)
    }
}
