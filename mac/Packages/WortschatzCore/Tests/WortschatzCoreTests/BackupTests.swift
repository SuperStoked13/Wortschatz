import Foundation
import Testing
import WortschatzCore

// Port of the backup.js part of tests/db.test.js, plus the Mac additions.

@Suite("Backup (backup.js)")
struct BackupTests {
    private static func cards(_ pairs: [(String, String)]) -> [Card] {
        pairs.enumerated().map { Card(id: "c\($0.offset)", term: $0.element.0, definition: $0.element.1) }
    }

    @Test func setToTextProducesQuizletCompatibleText() {
        let sample = Self.cards([
            ("le monsieur, messieurs", "der Herr"), ("la mademoiselle", "das Fräulein,\ndie Frau"), (" ", ""),
        ])
        #expect(Backup.setToText(cards: sample) == "le monsieur, messieurs\tder Herr\nla mademoiselle\tdas Fräulein, die Frau")
        #expect(
            Backup.setToText(cards: sample, termSep: " - ", cardSep: "\n")
                == "le monsieur, messieurs - der Herr\nla mademoiselle - das Fräulein, die Frau")
        #expect(
            Backup.setToText(cards: sample, termSep: ",", cardSep: ";")
                == "\"le monsieur, messieurs\",der Herr;la mademoiselle,\"das Fräulein, die Frau\"")
        #expect(Backup.setToText(cards: []) == "")
        // A ';' inside a field would split the card; grading treats ';' and ',' alike, so it becomes ', '.
        #expect(Backup.setToText(cards: Self.cards([("say \"hi\"", "a;b")]), termSep: "\t", cardSep: ";") == "say \"hi\"\ta, b")
        #expect(Backup.setToText(cards: Self.cards([("a ; b", "c;  d;")]), termSep: " - ", cardSep: ";") == "a, b - c, d,")
        // With a newline between cards a ';' is harmless and stays as typed.
        #expect(Backup.setToText(cards: Self.cards([("aimer", "lieben; mögen")])) == "aimer\tlieben; mögen")
    }

    @Test func setToTextOfASetUsesItsCards() {
        let set = VocabSet(id: "s", title: "A", cards: Self.cards([("aimer", "lieben"), ("le temps", "das Wetter; die Zeit")]), createdAt: 0)
        #expect(Backup.setToText(set, termSep: " - ", cardSep: ";") == "aimer - lieben;le temps - das Wetter, die Zeit")
        #expect(Backup.setToText(set) == Backup.setToText(cards: set.cards))
    }

    @Test func aSemicolonSeparatedExportHasNoStrayQuotes() {
        let cards = Self.cards([
            ("aimer", "lieben; mögen"), ("le temps", "das Wetter; die Zeit"), ("la maison", "das Haus"), ("le chien", "der Hund"),
        ])
        let text = Backup.setToText(cards: cards, termSep: " - ", cardSep: ";")
        #expect(!text.contains("\""))
        #expect(text == "aimer - lieben, mögen;le temps - das Wetter, die Zeit;la maison - das Haus;le chien - der Hund")
    }

    @Test func fieldsAreQuotedOnlyWhenASeparatorRemains() {
        #expect(Backup.setToText(cards: Self.cards([("a|b", "c")]), termSep: "|", cardSep: "\n") == "\"a|b\"|c")
        // Whitespace-only separators never quote.
        #expect(Backup.setToText(cards: Self.cards([("a b", "c d")]), termSep: " ", cardSep: "\n") == "a b c d")
        // Canonically equivalent text is not a separator (exact code points, like JS includes).
        #expect(Backup.setToText(cards: Self.cards([("e\u{301}", "x")]), termSep: "e", cardSep: "\n") == "\"e\u{301}\"ex")
        // Runs of spaces collapse, other Unicode spaces stay; tabs and line breaks become spaces.
        #expect(Backup.setToText(cards: Self.cards([(" a \t\r\n b\u{00A0}c  ", "d")])) == "a b\u{00A0}c\td")
    }

    // MARK: readJSON

    @Test func readJSONParsesObjectsAndRejectsJunk() throws {
        #expect(try Backup.readJSON(Data("\u{FEFF}{\"app\":\"wortschatz\"}".utf8)) == ["app": "wortschatz"])
        #expect(try Backup.readJSON(Data([0xEF, 0xBB, 0xBF] + Array("{\"a\":1}".utf8))) == ["a": 1])
        for junk in ["nope", "[1,2]", "null", "5", "\"x\"", "", "{\"a\":1,}", "{\"a\":01}", "{\"a\":.5}", "{'a':1}",
                     "{\"a\":1} x", "/*c*/{}", "{\"a\":\"tab\there\"}", "{\"a\":NaN}", "\u{00A0}{}"] {
            #expect(throws: BackupFileError(message: Backup.PARSE_ERROR)) { try Backup.readJSON(Data(junk.utf8)) }
        }
        #expect(Backup.PARSE_ERROR.contains("keine gültige Backup-Datei"))
        #expect(Backup.READ_ERROR.contains("nicht gelesen"))
    }

    @Test func readJSONFollowsJSONParse() throws {
        // The last of duplicate keys wins.
        #expect(try Backup.readJSON(Data("{\"a\":1,\"a\":2}".utf8)) == ["a": 2])
        // Escapes, surrogate pairs, and a lone surrogate (not representable in Swift) as U+FFFD.
        let text = try Backup.readJSON(Data(#"{"s":"\"\\\/\b\f\n\r\té😀","lone":"x\ud800y"}"#.utf8))
        #expect(text["s"] == .string("\"\\/\u{8}\u{C}\n\r\té😀"))
        #expect(text["lone"] == .string("x\u{FFFD}y"))
        // Numbers beyond the Double range become infinity, like in JS.
        #expect(try Backup.readJSON(Data("{\"n\":1e400,\"m\":-1E+2,\"z\":-0}".utf8)) == ["n": .number(.infinity), "m": -100, "z": 0])
        // Deeply nested files are rejected instead of overflowing the stack.
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        #expect(throws: BackupFileError.self) { try Backup.readJSON(Data("{\"a\":\(deep)}".utf8)) }
        let nested = String(repeating: "[", count: 500) + String(repeating: "]", count: 500)
        #expect(try Backup.readJSON(Data("{\"a\":\(nested)}".utf8))["a"]?.isArray == true)
    }

    @Test func aVersionBeyondTheDoubleRangeIsNoBackup() throws {
        let data = try Backup.readJSON(Data("{\"app\":\"wortschatz\",\"version\":1e400,\"sets\":[]}".utf8))
        let store = LibraryStore(backend: MemoryBackend())
        #expect(throws: LibraryStoreError(.invalidBackup, StoreMessages.notBackup)) { try store.importAll(data) }
    }

    // MARK: Writing

    @Test func jsonDataIsAReadableWebBackup() throws {
        let store = LibraryStore(backend: MemoryBackend(), now: { 1_760_000_000_000 }, timeZone: zurich)
        let set = try store.createSet(title: "Personen / Leute", cards: [CardDraft(term: "l'homme", definition: "der Mann")])
        try store.recordAnswer(set.id, set.cards[0].id, correct: true)
        let data = try Backup.jsonData(store.exportAll())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"app\": \"wortschatz\",\n  \"version\": 1,\n  \"exportedAt\": 1760000000000,\n  \"sets\": [\n    {\n      \"id\": "))
        #expect(text.contains("\"title\": \"Personen / Leute\""))
        #expect(text.hasSuffix("\n  \"activity\": {\n    \"2025-10-09\": 1\n  }\n}"))
        let parsed = try Backup.readJSON(data)
        #expect(parsed == (try JSONValue(encoding: store.exportAll())))
        let target = LibraryStore(backend: MemoryBackend())
        #expect(try target.importAll(parsed, mode: .replace) == ImportSummary(setsAdded: 1, setsUpdated: 0))
        #expect(target.getProgress(set.id) == store.getProgress(set.id))
    }

    @Test func jsonTextFormatsLikeJSONStringify() {
        #expect(Backup.jsonText([:]) == "{}")
        #expect(Backup.jsonText(["b": [], "a": [:], "title": "x", "id": 1]) == "{\n  \"id\": 1,\n  \"title\": \"x\",\n  \"a\": {},\n  \"b\": []\n}")
        #expect(Backup.jsonText(["k": [1.5, true, nil, "a\"b\\c/\u{1}\u{7F}\u{2028}"]]) == "{\n  \"k\": [\n    1.5,\n    true,\n    null,\n    \"a\\\"b\\\\c/\\u0001\u{7F}\u{2028}\"\n  ]\n}")
        #expect(Backup.jsonText(.number(.infinity)) == "null")
        #expect(Backup.jsonText(1e21) == "1e+21")
    }

    @Test func fileNamesMatchTheWebApp() {
        #expect(Backup.backupFileName(now: 1_760_140_800_000, timeZone: zurich) == "wortschatz-backup-2025-10-11.json")
        #expect(Backup.textFileName(for: "Französisch: Unité 1/2") == "Französisch Unité 1 2.txt")
        #expect(Backup.textFileName(for: "  \t ") == "Lernset.txt")
        #expect(Backup.textFileName(for: "a\u{0}b\u{1F}c  \n d?*") == "a b c d.txt")
        #expect(Backup.textFileName(for: "Cafe\u{301}") == "Café.txt")
        let long = String(repeating: "x", count: 79) + "😀abc"
        #expect(Backup.textFileName(for: long) == String(repeating: "x", count: 79) + ".txt")
    }
}
