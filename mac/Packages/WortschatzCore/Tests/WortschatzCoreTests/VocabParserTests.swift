import Foundation
import Testing
import WortschatzCore

// Port of tests/parser.test.js. Every input of that file is also replayed field by field against
// the JS reference in VocabParserParityTests (Fixtures/parser.json).

private func parse(_ text: String?, _ options: ParseOptions = ParseOptions()) -> ParseResult {
    VocabParser.parseVocab(text, options: options)
}

private func read(_ name: String) -> String { VocabParserWebFixtures.read(name) }

private func pairs(_ r: ParseResult) -> [[String]] { r.cards.map { [$0.term, $0.definition] } }

private func flagged(_ r: ParseResult) -> [String] {
    r.cards.filter { !$0.flags.isEmpty }.map { "\($0.term): \($0.flags.map(\.rawValue))" }
}

/// Lines that are not blank (JS `split('\n').filter((l) => l.trim())`).
private func contentLines(_ text: String) -> [String] {
    text.components(separatedBy: "\n").filter { !JSCompat.trim($0).isEmpty }
}

/// The structural invariants of every result (JS `expectShape`).
private func expectShape(_ r: ParseResult, sourceLocation: SourceLocation = #_sourceLocation) {
    if r.format != .delimited { #expect(r.delimiter == nil, sourceLocation: sourceLocation) }
    for c in r.cards {
        #expect(c.confidence >= 0 && c.confidence <= 1, sourceLocation: sourceLocation)
        #expect(!c.lines.isEmpty, sourceLocation: sourceLocation)
        #expect(c.lines == c.lines.sorted(), sourceLocation: sourceLocation)
    }
    #expect(r.skipped.map(\.line) == r.skipped.map(\.line).sorted(), sourceLocation: sourceLocation)
    for w in r.warnings {
        #expect(!w.contains("\u{DF}"), "Swiss spelling: \(w)", sourceLocation: sourceLocation) // never the sharp s
    }
}

/// JS `checkFixture(name, n, format, delimiter, termLang, defLang, swapped, some)`.
@discardableResult
private func checkFixture(
    _ name: String, _ n: Int, _ format: ParseFormat, _ delimiter: String?, _ termLang: Lang, _ defLang: Lang,
    _ swapped: Bool, _ some: [[String]], sourceLocation: SourceLocation = #_sourceLocation
) -> ParseResult {
    let r = parse(read(name))
    expectShape(r, sourceLocation: sourceLocation)
    #expect(r.cards.count == n, "\(name)", sourceLocation: sourceLocation)
    #expect(r.format == format, "\(name)", sourceLocation: sourceLocation)
    #expect(r.delimiter == delimiter, "\(name)", sourceLocation: sourceLocation)
    #expect(r.termLang == termLang && r.defLang == defLang, "\(name): \(r.termLang)/\(r.defLang)", sourceLocation: sourceLocation)
    #expect(r.swapped == swapped, "\(name)", sourceLocation: sourceLocation)
    let all = pairs(r)
    for p in some { #expect(all.contains(p), "\(name) lacks \(p)", sourceLocation: sourceLocation) }
    return r
}

private let userPairs: [[String]] = [
    ["le monsieur, messieurs", "der Herr"], ["l'homme", "der Mann"], ["la madame, mesdames", "Frau"],
    ["la femme", "die Frau"], ["la dame", "die Dame"], ["la mademoiselle, mesdemoiselles", "das Fräulein, die Frau"],
    ["l'enfant", "das Kind"], ["le garçon", "der Junge"], ["la fille", "das Mädchen"], ["appeler", "nennen"],
    ["s'appeler", "heissen"], ["le nom", "der Name"], ["le nom de famille", "der Familienname, der Nachname"],
    ["le prénom", "der Vorname"], ["marié, mariée", "verheiratet"], ["veuf, veuve", "verwitwet"],
    ["séparé, séparée", "getrennt"], ["la personne", "die Person"], ["l'adresse", "die Adresse, die Anschrift"],
    ["la rue", "die Strasse"], ["le numéro de la maison", "die Hausnummer"], ["brave", "lieb"],
    ["gentil, gentille", "lieb, nett"], ["bon, bonne", "gut, gütig"], ["aimable", "freundlich"],
    ["sage", "brav, artig"], ["le charme", "der Charme"], ["charmant, charmante", "charmant"],
    ["la raison", "die Vernunft"], ["raisonnable", "vernünftig"], ["sérieux, sérieuse", "ernst, ernsthaft"],
    ["sympathique", "sympathisch"], ["calme", "ruhig"], ["tranquille", "still"], ["comique", "komisch"],
    ["le courage", "der Mut"], ["courageux, courageuse", "mutig"], ["la bêtise", "die Dummheit"],
    ["bête", "dumm"], ["méchant, méchante", "böse, gemein"], ["lâche", "feige"], ["le visage", "das Gesicht"],
    ["la figure", "das Gesicht"], ["les cheveux", "das Haar, die Haare"], ["ressembler à", "ähneln, gleichen"],
    ["se ressembler", "sich ähnlich sein, sich gleichen"], ["joli, jolie", "hübsch"], ["la beauté", "die Schönheit"],
    ["beau, bel, belle", "schön"], ["attirant, attirante", "attraktiv, anziehend"], ["laid, laide", "hässlich"],
    ["moche", "hässlich"],
]

// MARK: - The user's own example

@Suite("VocabParser: the user's example")
struct VocabParserUserExampleTests {
    @Test("exactly the 52 expected pairs, in order")
    func exactPairs() {
        let r = parse(read("user-example.txt"))
        expectShape(r)
        #expect(r.cards.count == 52)
        #expect(pairs(r) == userPairs)
    }

    @Test("blocks, fr -> de, not swapped, no flags, nothing skipped")
    func structure() {
        let r = parse(read("user-example.txt"))
        #expect(r.format == .blocks)
        #expect(r.delimiter == nil)
        #expect(r.termLang == .fr)
        #expect(r.defLang == .de)
        #expect(!r.swapped)
        #expect(r.skipped.isEmpty)
        #expect(r.warnings.isEmpty)
        for c in r.cards {
            #expect(c.flags.isEmpty, "\(c.term)")
            #expect(c.confidence >= 0.5)
        }
        #expect(r.cards[0].lines == [1, 2])
        #expect(r.cards[2].lines == [14, 15])
        #expect(r.cards[51].lines == [311, 312])
    }

    @Test("same pairs with single blank lines, CRLF, no blank lines and hints")
    func variants() {
        let lines = contentLines(read("user-example.txt"))
        let blocks = stride(from: 0, to: lines.count, by: 2).map { "\(lines[$0])\n\(lines[$0 + 1])" }
        let single = parse(blocks.joined(separator: "\n\n"))
        #expect(single.format == .blocks)
        #expect(pairs(single) == userPairs)
        let crlf = parse(read("user-example.txt").replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(pairs(crlf) == userPairs)
        let dense = parse(lines.joined(separator: "\n"))
        #expect(dense.format == .alternating)
        #expect(pairs(dense) == userPairs)
        let hinted = parse(read("user-example.txt"), ParseOptions(termLang: .fr, defLang: .de))
        #expect(pairs(hinted) == userPairs)
        #expect(parse(read("user-example.txt"), ParseOptions(mode: .lines)).cards.count == 52)
    }

    @Test("written German-first it is auto-swapped")
    func germanFirst() {
        let lines = contentLines(read("user-example.txt"))
        let flipped = stride(from: 0, to: lines.count, by: 2).map { "\(lines[$0 + 1])\n\(lines[$0])" }
        let r = parse(flipped.joined(separator: "\n\n\n"))
        #expect(r.swapped)
        #expect(r.termLang == .fr)
        #expect(r.defLang == .de)
        #expect(pairs(r) == userPairs)
    }
}

// MARK: - Fixture layouts

@Suite("VocabParser: fixture layouts")
struct VocabParserFixtureTests {
    @Test("Quizlet export (tab + newline)")
    func quizletExport() {
        checkFixture("quizlet-export.txt", 10, .delimited, "\t", .fr, .de, false, [
            ["le chien", "der Hund"], ["avoir faim", "Hunger haben"], ["beau, bel, belle", "schön"], ["c'est-à-dire", "das heisst"],
        ])
    }

    @Test("\" - \" separated (hyphenated words stay intact)")
    func dashHyphen() {
        checkFixture("dash-hyphen.txt", 8, .delimited, " - ", .fr, .de, false, [
            ["le monsieur", "der Herr"], ["c'est-à-dire", "das heisst"], ["le grand-père", "der Grossvater"],
            ["aujourd'hui", "heute"],
        ])
    }

    @Test("en dash and em dash separated")
    func dashEnEm() {
        checkFixture("dash-en-em.txt", 6, .delimited, " - ", .fr, .de, false, [
            ["la fenêtre", "das Fenster"], ["la porte", "die Tür"], ["l'escalier", "die Treppe"],
        ])
    }

    @Test("\" = \" separated")
    func equals() {
        checkFixture("equals.txt", 6, .delimited, " = ", .fr, .de, false, [
            ["manger", "essen"], ["la boulangerie", "die Bäckerei"], ["acheter", "kaufen"],
        ])
    }

    @Test("quoted CSV with commas and escaped quotes inside fields")
    func csvQuoted() {
        checkFixture("csv-quoted.csv", 6, .delimited, ",", .fr, .de, false, [
            ["le monsieur, messieurs", "der Herr"], ["gentil, gentille", "lieb, nett"], ["le chat", "die Katze"],
            ["le \"bon\" vin", "der \"gute\" Wein"], ["bon, bonne", "gut"],
        ])
    }

    @Test("semicolon separated")
    func semicolon() {
        checkFixture("semicolon.txt", 7, .delimited, ";", .fr, .de, false, [
            ["le livre", "das Buch"], ["le taille-crayon", "der Spitzer"], ["le sac à dos", "der Rucksack"],
        ])
    }

    @Test("German first is swapped automatically")
    func germanFirst() {
        let r = checkFixture("german-first.txt", 7, .delimited, " - ", .fr, .de, true, [
            ["le chien", "der Hund"], ["le chat", "die Katze"], ["l'oiseau", "der Vogel"],
        ])
        #expect(r.cards[0].term == "le chien")
    }

    @Test("alternating lines without blank lines")
    func alternating() {
        let r = checkFixture("alternating.txt", 7, .alternating, nil, .fr, .de, false, [
            ["le printemps", "der Frühling"], ["l'été", "der Sommer"], ["il pleut", "es regnet"], ["le soleil", "die Sonne"],
        ])
        #expect(r.cards[0].lines == [1, 2])
    }

    @Test("single lines separated by single blank lines")
    func singleBlank() {
        checkFixture("single-blank-alternating.txt", 5, .alternating, nil, .fr, .de, false, [
            ["la tête", "der Kopf"], ["le pied", "der Fuss"], ["le genou", "das Knie"],
        ])
    }

    @Test("wrapped definitions are merged and flagged")
    func wrappedBlocks() {
        let r = checkFixture("wrapped-blocks.txt", 6, .blocks, nil, .fr, .de, false, [
            ["la voiture", "das Auto, der Wagen"], ["le cours", "der Kurs, die Unterrichtsstunde"],
            ["l'ordinateur", "der Computer"], ["la pomme de terre", "die Kartoffel"],
        ])
        #expect(r.cards[1].flags.contains(.merged))
        #expect(r.cards[1].lines == [4, 5, 6])
        #expect(r.cards[2].flags.contains(.merged))
        #expect(r.cards[0].flags.isEmpty)
        #expect(r.warnings.contains { $0.contains("Fortsetzung") })
    }

    @Test("numbered and bulleted list")
    func numbered() {
        checkFixture("numbered.txt", 8, .delimited, " - ", .fr, .de, false, [
            ["le chat", "die Katze"], ["la souris", "die Maus"], ["le poisson", "der Fisch"], ["l'oiseau", "der Vogel"],
            ["le cheval", "das Pferd"], ["la vache", "die Kuh"],
        ])
    }

    @Test("two-column OCR order pairs line i with line i + n/2")
    func twoColumnOCR() {
        let r = checkFixture("two-column-ocr.txt", 8, .columns, nil, .fr, .de, false, [
            ["le frère", "der Bruder"], ["la sœur", "die Schwester"], ["les parents", "die Eltern"],
            ["les grands-parents", "die Grosseltern"],
        ])
        #expect(r.cards[0].lines == [1, 9])
    }

    @Test("English-German list")
    func englishGerman() {
        checkFixture("english-german.txt", 9, .delimited, " - ", .en, .de, false, [
            ["to appear", "erscheinen"], ["to look for sth", "etw. suchen"], ["the house", "das Haus"],
            ["to take care of sb", "sich um jdn. kümmern"],
        ])
    }

    @Test("PDF text with 2+ spaces between columns (incl. a collapsed row)")
    func pdfColumns() {
        checkFixture("pdf-columns.txt", 8, .delimited, "  ", .fr, .de, false, [
            ["la gare", "der Bahnhof"], ["l'arrivée", "die Ankunft"], ["le numéro de la voie", "die Gleisnummer"],
            ["le guichet", "der Schalter"],
        ])
    }

    @Test("noise: headings, page numbers and header row are skipped")
    func noisy() {
        let r = checkFixture("noisy.txt", 7, .delimited, " - ", .fr, .de, false, [
            ["le monsieur", "der Herr"], ["gentil, gentille", "lieb, nett"], ["sérieux, sérieuse", "ernst"],
            ["la voisine", "die Nachbarin"],
        ])
        let reasons = Dictionary(uniqueKeysWithValues: r.skipped.map { ($0.line, $0.reason) })
        #expect(reasons == [1: .heading, 2: .heading, 4: .heading, 8: .heading, 11: .pageNumber, 12: .pageNumber])
        #expect(r.skipped[0].text == "Unité 3 - Les personnes")
        for c in r.cards {
            #expect(!c.term.contains("Unité"))
            #expect(!c.term.contains("Vocabulaire"))
        }
        #expect(r.warnings.contains("6 Zeilen ohne Vokabeln wurden übersprungen."))
    }

    @Test("four tab cells per line give two cards per line (left column first)")
    func fourCells() {
        let r = checkFixture("four-cells.tsv", 8, .delimited, "\t", .fr, .de, false, [
            ["le lundi", "der Montag"], ["le vendredi", "der Freitag"], ["la semaine", "die Woche"],
        ])
        #expect(r.cards.map(\.term) == [
            "le lundi", "le mardi", "le mercredi", "le jeudi", "le vendredi", "le samedi", "le dimanche", "la semaine",
        ])
        #expect(r.cards[4].lines == [1])
    }

    @Test("Windows line endings, BOM and non-breaking spaces")
    func windowsBOM() {
        let r = checkFixture("windows-bom.txt", 4, .delimited, " - ", .fr, .de, false, [
            ["le chien", "der Hund"], ["le lapin", "das Kaninchen"], ["l'écureuil", "das Eichhörnchen"],
        ])
        #expect(r.cards[0].term.unicodeScalars.first == "l")
        #expect(r.cards[3].lines == [5])
    }

    @Test("Spanish-German list")
    func spanish() {
        checkFixture("spanish.txt", 10, .delimited, " - ", .es, .de, false, [
            ["el perro", "der Hund"], ["el niño", "das Kind"], ["¿Qué tal?", "Wie geht's?"], ["bonito, bonita", "hübsch"],
        ])
    }

    @Test("Italian-German list")
    func italian() {
        checkFixture("italian.txt", 10, .delimited, " = ", .it, .de, false, [
            ["il cane", "der Hund"], ["gli amici", "die Freunde"], ["la città", "die Stadt"], ["perché", "warum"],
        ])
    }

    @Test("Markdown table with header and separator row")
    func markdownTable() {
        let r = checkFixture("markdown-table.txt", 4, .delimited, "|", .fr, .de, false, [
            ["le pain", "das Brot"], ["la viande", "das Fleisch"],
        ])
        #expect(r.skipped.map(\.reason) == [.heading, .noise])
    }

    @Test("whole list on one line separated by semicolons")
    func inlineSemicolon() {
        checkFixture("inline-semicolon.txt", 4, .delimited, " - ", .fr, .de, false, [
            ["le chat", "die Katze"], ["le lapin", "das Kaninchen"],
        ])
    }

    @Test("collapsed PDF columns without any delimiter are split by language")
    func collapsedColumns() {
        let r = checkFixture("collapsed-columns.txt", 6, .delimited, " ", .fr, .de, false, [
            ["le chat", "die Katze"], ["le cheval", "das Pferd"], ["le cochon", "das Schwein"],
        ])
        for c in r.cards { #expect(c.flags.isEmpty) }
    }

    @Test("German-first blocks are swapped")
    func germanFirstBlocks() {
        checkFixture("german-first-blocks.txt", 4, .blocks, nil, .fr, .de, true, [
            ["la cuillère", "der Löffel"], ["l'assiette", "der Teller"],
        ])
    }
}

// MARK: - Options

@Suite("VocabParser: options")
struct VocabParserOptionTests {
    @Test("mode delimiter with a custom delimiter")
    func customDelimiter() {
        let r = parse("le chat :: die Katze\nle chien :: der Hund\n\nla souris :: die Maus", ParseOptions(mode: .delimiter, delimiter: "::"))
        #expect(r.format == .delimited)
        #expect(r.delimiter == "::")
        #expect(pairs(r) == [["le chat", "die Katze"], ["le chien", "der Hund"], ["la souris", "die Maus"]])
        #expect(r.cards[2].lines == [4])
    }

    @Test("mode delimiter with cardSeparator \";\"")
    func cardSeparator() {
        let r = parse(
            "le chat - die Katze; le chien - der Hund;\nla souris - die Maus;",
            ParseOptions(mode: .delimiter, delimiter: " - ", cardSeparator: ";"))
        #expect(pairs(r) == [["le chat", "die Katze"], ["le chien", "der Hund"], ["la souris", "die Maus"]])
        #expect(r.cards[2].lines == [2])
        let quizlet = parse(
            "le chat,die Katze;le chien,der Hund;la souris,die Maus", ParseOptions(mode: .delimiter, delimiter: ",", cardSeparator: ";"))
        #expect(quizlet.delimiter == ",")
        #expect(pairs(quizlet) == [["le chat", "die Katze"], ["le chien", "der Hund"], ["la souris", "die Maus"]])
    }

    @Test("mode delimiter: bare dash prefers the spaced dash, then the language boundary")
    func bareDash() {
        let r = parse("c'est-à-dire - das heisst\nle grand-père-der Grossvater\nle chat-die Katze", ParseOptions(mode: .delimiter, delimiter: "-"))
        #expect(pairs(r) == [["c'est-à-dire", "das heisst"], ["le grand-père", "der Grossvater"], ["le chat", "die Katze"]])
    }

    @Test("mode delimiter: tab default, newline delimiter with blank-line card separator")
    func tabDefaultAndNewline() {
        #expect(pairs(parse("le chat\tdie Katze", ParseOptions(mode: .delimiter))) == [["le chat", "die Katze"]])
        let r = parse(
            "le chat\ndie Katze\n\n\n\nle chien\nder Hund", ParseOptions(mode: .delimiter, delimiter: "\n", cardSeparator: "\n\n"))
        #expect(pairs(r) == [["le chat", "die Katze"], ["le chien", "der Hund"]])
        #expect(r.cards[1].lines == [6, 7])
    }

    @Test("mode delimiter: en dash delimiter matches normalised text")
    func enDashDelimiter() {
        let r = parse("le chat – die Katze\nle chien – der Hund", ParseOptions(mode: .delimiter, delimiter: " – "))
        #expect(pairs(r) == [["le chat", "die Katze"], ["le chien", "der Hund"]])
    }

    @Test("swap flips the sides after orientation")
    func swap() {
        let r = parse(read("dash-hyphen.txt"), ParseOptions(swap: true))
        #expect(r.swapped)
        #expect(r.termLang == .de)
        #expect(r.defLang == .fr)
        #expect(r.cards[0].term == "der Herr")
        #expect(r.cards[0].definition == "le monsieur")
        // German-first input: auto swap and forced swap cancel out.
        let g = parse(read("german-first.txt"), ParseOptions(swap: true))
        #expect(!g.swapped)
        #expect(g.cards[0].term == "der Hund")
        #expect(g.termLang == .de)
    }

    @Test("orient: false keeps the source order")
    func noOrientation() {
        let r = parse(read("german-first.txt"), ParseOptions(orient: false))
        #expect(!r.swapped)
        #expect(r.cards[0].term == "der Hund")
        #expect(r.termLang == .de)
        #expect(r.defLang == .fr)
    }

    @Test("English first stays; German first with English is swapped (English is learned)")
    func englishLearned() {
        let r = parse("der Hund - the dog\ndie Katze - the cat\ndas Haus - the house")
        #expect(r.swapped)
        #expect(r.termLang == .en)
        #expect(pairs(r) == [["the dog", "der Hund"], ["the cat", "die Katze"], ["the house", "das Haus"]])
    }

    @Test("mode lines never splits on delimiters")
    func linesMode() {
        let r = parse("le chat - die Katze\nle chien - der Hund", ParseOptions(mode: .lines))
        #expect(r.format == .alternating)
        #expect(pairs(r) == [["le chat - die Katze", "le chien - der Hund"]])
    }

    @Test("language hints are used when detection is impossible")
    func hints() {
        // Only one side has words: it becomes the term, the other side takes the hint.
        let r = parse("12\tdouze\n13\ttreize", ParseOptions(termLang: .fr, defLang: .de))
        #expect(pairs(r) == [["douze", "12"], ["treize", "13"]])
        #expect(r.swapped)
        #expect(r.termLang == .fr)
        #expect(r.defLang == .de)
        let german = parse("12 - zwölf\n13 - dreizehn")
        #expect(!german.swapped)
        #expect(german.defLang == .de)
        let empty = parse("", ParseOptions(termLang: .en, defLang: .de))
        #expect(empty.termLang == .en)
        #expect(empty.defLang == .de)
    }

    @Test("header row naming the languages is skipped")
    func headerRow() {
        let r = parse("Deutsch - Französisch\nder Hund - le chien\ndie Katze - le chat")
        #expect(r.skipped == [SkippedLine(line: 1, text: "Deutsch - Französisch", reason: .heading)])
        #expect(r.swapped)
        #expect(pairs(r) == [["le chien", "der Hund"], ["le chat", "die Katze"]])
        let fr = parse("FR | DE\nle chat | die Katze\nle chien | der Hund")
        #expect(fr.cards.count == 2)
        #expect(fr.skipped.first?.reason == .heading)
    }

    @Test("a translation of a language name is a card, not a header")
    func languageNameCard() {
        let r = parse("le français - Französisch\nfrançais - Französisch\nl’allemand - Deutsch")
        #expect(r.cards.count == 3)
        #expect(r.skipped.isEmpty)
    }

    @Test("ParseOptions(json:) mirrors normalizeOptions")
    func normalizeOptions() throws {
        let defaults = ParseOptions(json: .null)
        #expect(defaults == ParseOptions())
        #expect(defaults.defLang == .de && defaults.termLang == nil && defaults.orient && !defaults.swap)
        let odd = ParseOptions(json: try JSONValue.parse(#"{"mode":"nope","delimiter":"","cardSeparator":"","termLang":"xx","defLang":7,"swap":"yes","orient":0}"#))
        #expect(odd == ParseOptions(mode: .auto, delimiter: nil, cardSeparator: "\n", termLang: nil, defLang: nil, orient: true, swap: false))
        let full = ParseOptions(json: try JSONValue.parse(#"{"mode":"delimiter","delimiter":" - ","cardSeparator":";","termLang":"other","defLang":"fr","orient":false,"swap":true}"#))
        #expect(full == ParseOptions(mode: .delimiter, delimiter: " - ", cardSeparator: ";", termLang: .other, defLang: .fr, orient: false, swap: true))
        // Codable round trip (explicit nulls for absent hints).
        let data = try JSONEncoder().encode(odd)
        #expect(try JSONDecoder().decode(ParseOptions.self, from: data) == odd)
        #expect(try JSONValue.parse(data).objectValue?["defLang"] == .null)
    }

    @Test("an empty delimiter or card separator set in Swift behaves like the JS defaults")
    func emptyOptionStrings() {
        let text = "le chat\tdie Katze\nle chien\tder Hund"
        let explicit = parse(text, ParseOptions(mode: .delimiter, delimiter: "", cardSeparator: ""))
        #expect(explicit == parse(text, ParseOptions(mode: .delimiter)))
        #expect(explicit.delimiter == "\t")
    }
}

// MARK: - Robustness

@Suite("VocabParser: robustness")
struct VocabParserRobustnessTests {
    @Test("headings and page numbers inside a blocks list")
    func headingsInBlocks() {
        let r = parse("Les animaux\n\nle chat\ndie Katze\n\nSeite 4\n\nle chien\nder Hund\n\n12\n\nla souris\ndie Maus")
        #expect(r.format == .blocks)
        #expect(pairs(r) == [["le chat", "die Katze"], ["le chien", "der Hund"], ["la souris", "die Maus"]])
        #expect(r.skipped.map { "\($0.line):\($0.reason.rawValue)" } == ["1:heading", "6:pageNumber", "11:pageNumber"])
    }

    @Test("mixed list: delimited lines and an alternating pair")
    func mixedList() {
        let r = parse("le chat - die Katze\nle chien\nder Hund\nla souris - die Maus\nle lapin - das Kaninchen")
        #expect(pairs(r) == [["le chat", "die Katze"], ["le chien", "der Hund"], ["la souris", "die Maus"], ["le lapin", "das Kaninchen"]])
    }

    @Test("missing translation in an alternating list is reported, not merged")
    func missingTranslation() {
        let r = parse("le chat\ndie Katze\nle chien\nla souris\ndie Maus\nle lapin\ndas Kaninchen")
        #expect(pairs(r) == [["le chat", "die Katze"], ["la souris", "die Maus"], ["le lapin", "das Kaninchen"]])
        #expect(r.skipped == [SkippedLine(line: 3, text: "le chien", reason: .unpaired)])
        #expect(r.warnings.contains("Zeile 3 konnte keinem Paar zugeordnet werden."))
    }

    @Test("wrapped definition inside a delimited list")
    func wrappedDefinition() {
        let r = parse("le chat - die Katze,\n   der Kater\nle chien - der Hund")
        #expect(r.format == .delimited)
        #expect(pairs(r) == [["le chat", "die Katze, der Kater"], ["le chien", "der Hund"]])
        #expect(r.cards[0].flags.contains(.merged))
        #expect(r.cards[0].lines == [1, 2])
    }

    @Test("missing sides are kept and flagged")
    func missingSides() {
        let r = parse("le chat\t\n\tder Hund\nla souris\tdie Maus\nle lapin\tdas Kaninchen")
        #expect(r.delimiter == "\t")
        #expect(pairs(r) == [["le chat", ""], ["", "der Hund"], ["la souris", "die Maus"], ["le lapin", "das Kaninchen"]])
        #expect(r.cards[0].flags.contains(.missingDefinition))
        #expect(r.cards[1].flags.contains(.missingTerm))
        #expect(r.warnings.contains("Zeile 1: Die Definition fehlt."))
        #expect(r.warnings.contains("Zeile 2: Der Begriff fehlt."))
        let dash = parse("le chat -\nle chien - der Hund\nla souris - die Maus")
        #expect(dash.cards[0].definition == "")
        #expect(dash.cards[0].flags.contains(.missingDefinition))
    }

    @Test("duplicates are flagged on repeated terms only")
    func duplicates() {
        let r = parse("le chat - die Katze\nle chien - der Hund\nle chat - der Kater\nle visage - das Gesicht\nla figure - das Gesicht")
        #expect(r.cards[0].flags.isEmpty)
        #expect(r.cards[2].flags.contains(.duplicate))
        #expect(r.cards[4].flags.isEmpty)
        #expect(r.warnings.contains("«le chat» kommt mehrfach vor (Zeilen 1 und 3)."))
    }

    @Test("a single reversed row is turned around")
    func reversedRow() {
        let r = parse("le chat - die Katze\nder Hund - le chien\nla souris - die Maus\nle lapin - das Kaninchen")
        #expect(r.cards[1].term == "le chien")
        #expect(r.cards[1].definition == "der Hund")
        #expect(r.warnings.contains { $0.hasPrefix("Zeile 2: Begriff und Definition") })
    }

    @Test("low confidence and language mismatch are flagged")
    func lowConfidence() {
        let r = parse("le chat - die Katze\nder Hund - 42\nla souris - die Maus\nle lapin - das Kaninchen")
        let card = r.cards[1]
        #expect(card.term == "der Hund")
        #expect(card.flags.contains(.lowConfidence))
        #expect(card.flags.contains(.langMismatch))
        #expect(card.confidence < 0.5)
        #expect(r.cards[0].flags.isEmpty)
    }

    @Test("comma inside entries of an alternating list is not taken as delimiter")
    func commaInEntries() {
        let r = parse("gentil, gentille\nlieb, nett\nbon, bonne\ngut, gütig")
        #expect(r.format == .alternating)
        #expect(pairs(r) == [["gentil, gentille", "lieb, nett"], ["bon, bonne", "gut, gütig"]])
    }

    @Test("multi-line quoted CSV field")
    func multilineCSV() {
        let r = parse("\"le monsieur,\nmessieurs\",\"der Herr\"\n\"la dame\",\"die Dame\"\nle chat,die Katze")
        #expect(r.delimiter == ",")
        #expect(pairs(r) == [["le monsieur, messieurs", "der Herr"], ["la dame", "die Dame"], ["le chat", "die Katze"]])
        #expect(r.cards[0].lines == [1, 2])
    }

    @Test("arrows of mixed styles, colons and pipes")
    func arrowsColonsPipes() {
        let arrows = parse("le chat -> die Katze\nle chien => der Hund\nla souris → die Maus")
        #expect(arrows.format == .delimited)
        #expect(pairs(arrows) == [["le chat", "die Katze"], ["le chien", "der Hund"], ["la souris", "die Maus"]])
        let colon = parse("le chat: die Katze\nle chien : der Hund\nla souris: die Maus")
        #expect(pairs(colon) == [["le chat", "die Katze"], ["le chien", "der Hund"], ["la souris", "die Maus"]])
        #expect(parse("le chat | die Katze\nle chien | der Hund").delimiter == "|")
    }

    @Test("a leading title does not hide the delimiter")
    func leadingTitle() {
        let r = parse("Les animaux\nle chat - die Katze\nle chien - der Hund")
        #expect(r.format == .delimited)
        #expect(r.cards.count == 2)
        #expect(r.skipped == [SkippedLine(line: 1, text: "Les animaux", reason: .heading)])
    }

    @Test("non-breaking spaces and curly apostrophes are normalised")
    func normalisation() {
        let r = parse("l’homme\u{A0}-\u{A0}der Mann\naujourd’hui - heute")
        #expect(pairs(r) == [["l'homme", "der Mann"], ["aujourd'hui", "heute"]])
    }

    @Test("empty and blank input")
    func emptyInput() {
        for input: String? in ["", "   ", "\n\n\t\n", nil] {
            let r = parse(input)
            expectShape(r)
            #expect(r.format == .empty)
            #expect(r.cards.isEmpty)
            #expect(r.delimiter == nil)
            #expect(!r.swapped)
        }
        let pages = parse("1\n- 2 -\nSeite 3")
        #expect(pages.format == .empty)
        #expect(pages.skipped.map(\.reason) == [.pageNumber, .pageNumber, .pageNumber])
    }

    @Test("a single line without partner is reported")
    func singleLine() {
        let r = parse("le chat")
        #expect(r.cards.isEmpty)
        #expect(r.skipped == [SkippedLine(line: 1, text: "le chat", reason: .unpaired)])
        #expect(r.warnings == ["Zeile 1 konnte keinem Paar zugeordnet werden."])
    }

    @Test("never fails on odd input or options")
    func oddInput() throws {
        // JS also passes 42, {}, [], ['a', 'b'] and true; parseVocab sees String(input).
        let inputs: [String?] = [
            "42", "[object Object]", "", "a,b", "true", "\u{FEFF}", "\"", "\"\"\"\"", "\t\t\t", ";;;;", " - - - ", "|||", "===",
            "\u{2028}\u{2029}", String(repeating: "a", count: 50_000), String(repeating: "le chat - ", count: 2000), "\r\r\r",
            "\"a\n\"b\n\"c", nil,
        ]
        let options: [JSONValue] = try [
            "null", "5", "\"x\"", "{}", #"{"mode":"nope"}"#, #"{"mode":"delimiter"}"#, #"{"mode":"delimiter","delimiter":""}"#,
            #"{"mode":"delimiter","delimiter":"-","cardSeparator":";"}"#, #"{"mode":"lines"}"#,
            #"{"termLang":"xx","defLang":7,"swap":"yes"}"#,
        ].map { try JSONValue.parse($0) }
        for input in inputs {
            for json in options {
                let r = parse(input, ParseOptions(json: json))
                expectShape(r)
                #expect(!r.warnings.contains(VocabParser.FAILURE_WARNING))
            }
        }
    }

    @Test("fuzz: random text always gives a well-formed result")
    func fuzz() {
        // The LCG of the JS test, in doubles like JS (so the strings are the same).
        var seed = 12345.0
        func rnd() -> Double {
            seed = (seed * 1_103_515_245 + 12345).truncatingRemainder(dividingBy: 2_147_483_648)
            return seed / 2_147_483_648
        }
        let alphabet = [
            "a", "é", "ü", "Der ", "le ", "\t", "\n", "\n\n", " ", "  ", "-", " - ", "\"", ",", ";", "|", "=", "1", ".", "–",
            "\u{A0}", "\r", "(", ")", "*", "•", "¿", ":", "→", "Seite ", "x", "Z",
        ]
        let options = [
            ParseOptions(), ParseOptions(mode: .lines), ParseOptions(mode: .delimiter, delimiter: " - ", cardSeparator: ";"),
        ]
        for _ in 0..<250 {
            var s = ""
            let len = Int(rnd() * 160)
            for _ in 0..<len { s += alphabet[Int(rnd() * Double(alphabet.count))] }
            for o in options {
                let r = parse(s, o)
                expectShape(r)
                #expect(!r.warnings.contains(VocabParser.FAILURE_WARNING))
            }
        }
    }

    @Test("large lists parse quickly")
    func largeLists() {
        let clock = ContinuousClock()
        let big = String(repeating: read("dash-hyphen.txt"), count: 250)
        var count = 0
        let t0 = clock.measure { count = parse(big).cards.count }
        #expect(count == 2000)
        let blocks = Array(repeating: read("user-example.txt"), count: 10).joined(separator: "\n\n")
        let t1 = clock.measure { count = parse(blocks).cards.count }
        #expect(count == 520)
        #if DEBUG
        let limit = Duration.seconds(10) // unoptimised build
        #else
        let limit = Duration.seconds(2)
        #endif
        #expect(t0 < limit && t1 < limit, "\(t0), \(t1)")
    }

    @Test("500 pairs parse well under 50 ms in release builds")
    func performance() {
        let clock = ContinuousClock()
        let user = read("user-example.txt")
        let blocks = Array(repeating: user, count: 10).joined(separator: "\n\n") // 520 pairs
        let alternating = Array(repeating: contentLines(user).joined(separator: "\n"), count: 10).joined(separator: "\n")
        let dash = String(repeating: read("dash-hyphen.txt"), count: 63) // 504 pairs
        for text in [blocks, alternating, dash] {
            var best = Duration.seconds(1000)
            var count = 0
            for _ in 0..<3 {
                best = min(best, clock.measure { count = parse(text).cards.count })
            }
            #expect(count >= 500)
            #if DEBUG
            #expect(best < .seconds(3), "\(best) (unoptimised build)")
            #else
            #expect(best < .milliseconds(50), "\(best)")
            #endif
        }
    }

    @Test("two-column OCR order repeated per page")
    func columnsPerPage() {
        let r = parse(
            "le chat\nle chien\nla souris\nle lapin\n\ndie Katze\nder Hund\ndie Maus\ndas Kaninchen\n\n"
                + "le cheval\nla vache\nle cochon\n\ndas Pferd\ndie Kuh\ndas Schwein")
        #expect(r.format == .columns)
        #expect(pairs(r) == [
            ["le chat", "die Katze"], ["le chien", "der Hund"], ["la souris", "die Maus"], ["le lapin", "das Kaninchen"],
            ["le cheval", "das Pferd"], ["la vache", "die Kuh"], ["le cochon", "das Schwein"],
        ])
        #expect(r.cards[4].lines == [11, 15])
    }

    @Test("columns of different length report the leftover line")
    func unevenColumns() {
        let r = parse("le chat\nle chien\nla souris\nle lapin\nle cheval\ndie Katze\nder Hund\ndie Maus\ndas Kaninchen")
        #expect(r.format == .columns)
        #expect(r.cards.count == 4)
        #expect(r.skipped == [SkippedLine(line: 5, text: "le cheval", reason: .unpaired)])
        #expect(r.warnings.contains("Die beiden Spalten sind unterschiedlich lang (5 und 4 Zeilen)."))
    }

    @Test("hyphen without spaces is split at the language boundary")
    func gluedHyphen() {
        let r = parse("le chat-die Katze\nle chien-der Hund\nle grand-père-der Grossvater\nla pomme de terre-die Kartoffel")
        #expect(pairs(r) == [
            ["le chat", "die Katze"], ["le chien", "der Hund"], ["le grand-père", "der Grossvater"], ["la pomme de terre", "die Kartoffel"],
        ])
        let q = parse("le chat-die Katze;le chien-der Hund;la souris-die Maus")
        #expect(pairs(q) == [["le chat", "die Katze"], ["le chien", "der Hund"], ["la souris", "die Maus"]])
    }

    @Test("typographic quotes and guillemets around fields are removed")
    func quotes() {
        let r = parse("« le chat » - « die Katze »\n„le chien“ - \"der Hund\"\n“la souris” - ‹die Maus›")
        #expect(pairs(r) == [["le chat", "die Katze"], ["le chien", "der Hund"], ["la souris", "die Maus"]])
    }

    @Test("Swiss spellings and Spanish blocks")
    func swissAndSpanish() {
        let ch = parse("la rue\ndie Strasse\n\ngrand\ngross\n\nfermer\nschliessen")
        #expect(ch.format == .blocks)
        #expect(pairs(ch) == [["la rue", "die Strasse"], ["grand", "gross"], ["fermer", "schliessen"]])
        let es = parse("el perro\nder Hund\n\nla casa\ndas Haus\n\nhablar\nsprechen")
        #expect(es.termLang == .es)
        #expect(es.cards.count == 3)
    }
}

// MARK: - Review regressions

@Suite("VocabParser: review regressions")
struct VocabParserRegressionTests {
    @Test("lines with 3+ parts split where the languages change, not at the first delimiter")
    func threeParts() {
        let komma = parse(
            "le monsieur, messieurs, der Herr, die Herren\nbeau, belle, schön\nle chat, die Katze\nheureux, heureuse, glücklich\ngentil, gentille, nett, freundlich",
            ParseOptions(mode: .delimiter, delimiter: ","))
        #expect(pairs(komma) == [
            ["le monsieur, messieurs", "der Herr, die Herren"], ["beau, belle", "schön"], ["le chat", "die Katze"],
            ["heureux, heureuse", "glücklich"], ["gentil, gentille", "nett, freundlich"],
        ])
        #expect(flagged(komma).isEmpty)
        let dash = parse("Comment ça va ? - Ça va bien. - Wie geht es dir? - Es geht mir gut.")
        #expect(pairs(dash) == [["Comment ça va ? - Ça va bien.", "Wie geht es dir? - Es geht mir gut."]])
        let forms = parse("le monsieur - messieurs - der Herr\nle chat - die Katze\nle chien - der Hund")
        #expect(pairs(forms)[0] == ["le monsieur - messieurs", "der Herr"])
    }

    @Test("3-cell rows without any 2-cell row still split by language")
    func threeCellsByLanguage() {
        let r = parse("le monsieur\tmessieurs\tder Herr\nle cheval\tchevaux\tdas Pferd\nbeau\tbelle\tschön\nheureux\theureuse\tglücklich")
        #expect(pairs(r) == [
            ["le monsieur, messieurs", "der Herr"], ["le cheval, chevaux", "das Pferd"], ["beau, belle", "schön"],
            ["heureux, heureuse", "glücklich"],
        ])
        #expect(flagged(r).isEmpty)
    }

    @Test("a part left on the wrong side of a 3-part split is flagged for review")
    func misplacedPart() {
        let r = parse("le chat - die Katze - le chien\nla vache - die Kuh\nle cheval - das Pferd\nla souris - die Maus")
        #expect(r.cards[0].flags.contains(.lowConfidence))
        #expect(r.cards[1].flags.isEmpty)
    }

    @Test("Quizlet comma export keeps \", \" inside the fields")
    func quizletComma() {
        let r = parse(
            "beau, belle,schön\nle monsieur, messieurs,der Herr\nla plage,der Strand\nle soleil,die Sonne\nheureux, heureuse,glücklich\nnager,schwimmen\ngrand, grande,gross\nla mer,das Meer")
        #expect(r.format == .delimited)
        #expect(r.delimiter == ",")
        #expect(pairs(r) == [
            ["beau, belle", "schön"], ["le monsieur, messieurs", "der Herr"], ["la plage", "der Strand"], ["le soleil", "die Sonne"],
            ["heureux, heureuse", "glücklich"], ["nager", "schwimmen"], ["grand, grande", "gross"], ["la mer", "das Meer"],
        ])
        #expect(flagged(r).isEmpty)
        let few = parse("la plage,der Strand\nle soleil,die Sonne\nnager,schwimmen\nbeau, belle,schön\ngrand, grande,gross\nla vague,die Welle")
        #expect(pairs(few) == [
            ["la plage", "der Strand"], ["le soleil", "die Sonne"], ["nager", "schwimmen"], ["beau, belle", "schön"],
            ["grand, grande", "gross"], ["la vague", "die Welle"],
        ])
    }

    @Test("number vocabulary keeps its numbers")
    func numberVocabulary() {
        let dash = parse("11 - onze\n12 - douze\n13 - treize\n14 - quatorze\n15 - quinze\n16 - seize\n20 - vingt\n21 - vingt et un\n30 - trente\n100 - cent")
        #expect(dash.cards.count == 10)
        #expect(Array(pairs(dash).prefix(2)) == [["onze", "11"], ["douze", "12"]])
        #expect(pairs(dash).contains(["vingt et un", "21"]))
        #expect(dash.termLang == .fr)
        let colon = parse("11: onze\n12: douze\n13: treize\n14: quatorze\n15: quinze")
        #expect(pairs(colon)[4] == ["quinze", "15"])
        let alt = parse("onze\n11\ndouze\n12\ntreize\n13\nquatorze\n14\nquinze\n15")
        #expect(pairs(alt) == [["onze", "11"], ["douze", "12"], ["treize", "13"], ["quatorze", "14"], ["quinze", "15"]])
        #expect(alt.skipped.isEmpty)
        // Real list numbering is still removed.
        let numbered = parse("1 - le chat - die Katze\n2 - le chien - der Hund\n3 - la vache - die Kuh\n4 - le cheval - das Pferd")
        #expect(pairs(numbered)[0] == ["le chat", "die Katze"])
        #expect(numbered.cards.count == 4)
    }

    @Test("3-cell rows: example sentences and note columns are dropped, forms are merged")
    func threeCellRows() {
        let sentence = parse(
            "le chat\tdie Katze\tLe chat dort sur le lit.\nle chien\tder Hund\tLe chien aboie.\nla maison\tdas Haus\tLa maison est grande et belle.\nle jardin\tder Garten\tJe travaille dans le jardin.")
        #expect(pairs(sentence) == [["le chat", "die Katze"], ["le chien", "der Hund"], ["la maison", "das Haus"], ["le jardin", "der Garten"]])
        let klett = parse(
            "la maison\tMa maison est grande.\tdas Haus\nle chat\tLe chat dort sur le lit.\tdie Katze\nle chien\tLe chien aboie très fort.\tder Hund\nle jardin\tLe jardin est très beau.\tder Garten")
        #expect(pairs(klett) == [["la maison", "das Haus"], ["le chat", "die Katze"], ["le chien", "der Hund"], ["le jardin", "der Garten"]])
        let notes = parse("la maison\tdas Haus\tNomen, f.\nle chat\tdie Katze\tNomen, m.\nmanger\tessen\tVerb\nle chien\tder Hund\tNomen, m.")
        #expect(pairs(notes) == [["la maison", "das Haus"], ["le chat", "die Katze"], ["manger", "essen"], ["le chien", "der Hund"]])
        let german = parse("le chat\tdie Katze\tDie Katze schläft.\nle chien\tder Hund\tDer Hund bellt.\nla maison\tdas Haus\tDas Haus ist gross.")
        #expect(pairs(german)[0] == ["le chat", "die Katze"])
        let synonyms = parse("beau\tschön\thübsch\ngrand\tgross\thoch\npetit\tklein\tgering")
        #expect(pairs(synonyms)[0] == ["beau", "schön, hübsch"])
    }

    @Test("3-cell rows in three languages keep the German column and are flagged")
    func threeLanguages() {
        let r = parse("cat\tle chat\tdie Katze\ndog\tle chien\tder Hund\nhouse\tla maison\tdas Haus\ncow\tla vache\tdie Kuh")
        #expect(r.cards.count == 4)
        #expect(r.cards.filter { $0.definition.contains("die Katze") }.count == 1)
        for c in r.cards { #expect(c.flags.contains(.lowConfidence)) }
        #expect(r.defLang == .de)
    }

    @Test("two page columns of \"term – definition\" entries give one card per entry, left column first")
    func pageColumns() {
        let left = [["le chat", "die Katze"], ["le chien", "der Hund"], ["la vache", "die Kuh"]]
        let right = [["le lapin", "das Kaninchen"], ["la poule", "das Huhn"], ["le canard", "die Ente"]]
        let text = left.indices.map { "\(left[$0][0]) – \(left[$0][1])\t\(right[$0][0]) – \(right[$0][1])" }.joined(separator: "\n")
        let r = parse(text)
        #expect(pairs(r) == left + right)
        #expect(flagged(r).isEmpty)
        // A page column that ends early leaves an empty cell.
        let uneven = parse("\(text)\nle cheval – das Pferd\n\tle renard – der Fuchs")
        #expect(pairs(uneven) == left + [["le cheval", "das Pferd"]] + right + [["le renard", "der Fuchs"]])
        // Pasted with a wide gap instead of a tab.
        let gap = parse(left.indices.map { "\(left[$0][0]) – \(left[$0][1])        \(right[$0][0]) – \(right[$0][1])" }.joined(separator: "\n"))
        #expect(pairs(gap) == left + right)
        // Verb forms on both sides are not page columns.
        let forms = parse("aller - allé\tgehen - gegangen\nvenir - venu\tkommen - gekommen\nprendre - pris\tnehmen - genommen\nfaire - fait\tmachen - gemacht")
        #expect(pairs(forms)[0] == ["aller - allé", "gehen - gegangen"])
    }

    @Test("column order survives a misdetected first or last line")
    func columnOrder() {
        let r = parse("timide\ndrôle\nsérieux, sérieuse\npoli, polie\ncalme\nsage\nbrave\ncharmant, charmante\nschüchtern\nlustig\nernst\nhöflich\nruhig\nbrav\nlieb\ncharmant")
        #expect(r.format == .columns)
        #expect(pairs(r) == [
            ["timide", "schüchtern"], ["drôle", "lustig"], ["sérieux, sérieuse", "ernst"], ["poli, polie", "höflich"],
            ["calme", "ruhig"], ["sage", "brav"], ["brave", "lieb"], ["charmant, charmante", "charmant"],
        ])
        let first = parse("plein, pleine\nle chat\nle chien\nla vache\nle cheval\nla souris\nvoll\ndie Katze\nder Hund\ndie Kuh\ndas Pferd\ndie Maus")
        #expect(first.format == .columns)
        #expect(pairs(first)[0] == ["plein, pleine", "voll"])
        #expect(pairs(first)[5] == ["la souris", "die Maus"])
    }

    @Test("mixed separators: each line is split at its own tab or dash")
    func mixedSeparators() {
        let expected = [
            ["le pantalon", "die Hose"], ["la chemise", "das Hemd"], ["le pull", "der Pullover"], ["la jupe", "der Rock"],
            ["le short", "die kurze Hose"], ["la robe", "das Kleid"], ["le manteau", "der Mantel"], ["le lit", "das Bett"],
            ["les chaussures", "die Schuhe"], ["le chapeau", "der Hut"],
        ]
        let r = parse(
            "le pantalon - die Hose\nla chemise\tdas Hemd\nle pull\tder Pullover\nla jupe - der Rock\nle short\tdie kurze Hose\nla robe - das Kleid\nle manteau - der Mantel\nle lit\tdas Bett\nles chaussures - die Schuhe\nle chapeau\tder Hut")
        #expect(pairs(r) == expected)
        #expect(r.format == .delimited)
        let more = parse(
            "le pantalon - die Hose\nla chemise = das Hemd\nle pull\tder Pullover\nla jupe - der Rock\nle short = die kurze Hose\nla robe - das Kleid\nle manteau : der Mantel\nle lit : das Bett\nles chaussures - die Schuhe\nle chapeau\tder Hut")
        #expect(pairs(more).contains(["le short", "die kurze Hose"]))
        #expect(pairs(more).contains(["le lit", "das Bett"]))
        #expect(more.cards.count == 10)
        // A line written the other way round is turned around.
        let reversed = parse(
            "le pantalon - die Hose\nla chemise\tdas Hemd\nle pull\tder Pullover\nder Rock - la jupe\nle short\tdie kurze Hose\nla robe - das Kleid\nle manteau - der Mantel\nle lit\tdas Bett\nles chaussures - die Schuhe\nle chapeau\tder Hut")
        #expect(pairs(reversed)[3] == ["la jupe", "der Rock"])
    }

    @Test("mixed separators label the format as delimited")
    func mixedSeparatorFormat() {
        let r = parse(
            "le lit - das Bett\nle bus - der Bus\nle train - der Zug\nla table - der Tisch\nle sport - der Sport\nla radio = das Radio\nle film = der Film\nle fils = der Sohn\nle mur = die Wand\nle sol = der Boden")
        #expect(r.cards.count == 10)
        #expect(r.format == .delimited)
        #expect(r.delimiter == " - ")
    }

    @Test("a cognate definition in an alternating list stays one card")
    func cognate() {
        let text = "calme\nruhig\nintelligent, intelligente\nintelligent\ntimide\nschüchtern\ndrôle\nlustig"
        let expected = [["calme", "ruhig"], ["intelligent, intelligente", "intelligent"], ["timide", "schüchtern"], ["drôle", "lustig"]]
        #expect(pairs(parse(text)) == expected)
        #expect(pairs(parse(text, ParseOptions(mode: .lines))) == expected)
    }

    @Test("a section heading inside an alternating list is not merged into the next term",
          arguments: ["Les couleurs", "Couleurs", "Adjectifs", "B) Couleurs et formes", "Les couleurs:"])
    func sectionHeading(heading: String) {
        let r = parse("le chat\ndie Katze\nle chien\nder Hund\nla vache\ndie Kuh\n\(heading)\nrouge\nrot\nbleu, bleue\nblau\nvert, verte\ngrün\njaune\ngelb")
        #expect(pairs(r)[3] == ["rouge", "rot"])
        #expect(r.cards.count == 7)
        #expect(r.skipped.map(\.text) == [heading])
    }

    @Test("French words ending in -ein / -eindre are French")
    func frenchEin() {
        let r = parse("peindre\nmalen\néteindre\nausschalten\natteindre\nerreichen\ncraindre\nfürchten\nplein, pleine\nvoll\nserein, sereine\ngelassen\nfreiner\nbremsen\nrejoindre\ntreffen")
        #expect(r.cards.count == 8)
        #expect(pairs(r).contains(["plein, pleine", "voll"]))
        #expect(pairs(r).contains(["serein, sereine", "gelassen"]))
        let dash = parse("plein, pleine - voll\nserein, sereine - gelassen\nfreiner - bremsen\npeindre - malen\natteindre - erreichen")
        #expect(flagged(dash).isEmpty)
    }

    @Test("English school and media words are English; the picked language wins a close call")
    func englishWords() {
        let school = parse(
            "homework - Hausaufgaben\nlesson - Lektion\npage - Seite\nunit - Einheit\nchapter - Kapitel\nexercise - Übung\nvocabulary - Wortschatz\ngrammar - Grammatik\nmodule - Modul\nsection - Abschnitt")
        #expect(school.termLang == .en)
        let media = parse(
            "newspaper - Zeitung\narticle - Artikel\nadvertisement - Werbung\nchannel - Sender\naudience - Publikum\njournalist - Journalist\ninterview - Interview\nopinion - Meinung\nsource - Quelle\ninformation - Information")
        #expect(media.termLang == .en)
        // Words that are also French: detection alone says French, the hint decides.
        let shared = "module - Modul\nsection - Abschnitt\npage - Seite\narticle - Artikel\naudience - Publikum\nsource - Quelle\nopinion - Meinung\nlesson - Lektion"
        let hinted = parse(shared, ParseOptions(termLang: .en))
        #expect(hinted.termLang == .en)
        #expect(flagged(hinted).isEmpty)
        // A clearly French list keeps French.
        #expect(parse("le chat - die Katze\nle chien - der Hund\nla maison - das Haus\nmanger - essen", ParseOptions(termLang: .en)).termLang == .fr)
    }

    @Test("a table border on only one side is not part of the row")
    func tableBorder() {
        let left = parse("| le chat | die Katze\n| le chien | der Hund\n| la vache | die Kuh\n| le cheval | das Pferd\n| la souris | die Maus\n| le cochon | das Schwein")
        #expect(left.delimiter == "|")
        #expect(pairs(left)[0] == ["le chat", "die Katze"])
        #expect(left.cards.count == 6)
        let right = parse("le chat | die Katze |\nle chien | der Hund |\nla vache | die Kuh |\nle cheval | das Pferd |")
        #expect(pairs(right)[3] == ["le cheval", "das Pferd"])
        let missing = parse("le chat | die Katze\nle chien |\nla vache | die Kuh\nle cheval | das Pferd")
        #expect(pairs(missing)[1] == ["le chien", ""])
    }

    @Test("wrapped phrases are joined with a space, not a comma")
    func wrappedPhrases() {
        let blocks = parse("se mettre en\ncolère\nwütend werden\n\navoir lieu\nstattfinden\n\nfaire la grasse\nmatinée\nausschlafen")
        #expect(pairs(blocks) == [["se mettre en colère", "wütend werden"], ["avoir lieu", "stattfinden"], ["faire la grasse matinée", "ausschlafen"]])
        let tab = parse("s'entendre avec qn\tsich mit jdm\nverstehen\navoir lieu\tstattfinden\nle chat\tdie Katze\nle chien\tder Hund")
        #expect(pairs(tab)[0] == ["s'entendre avec qn", "sich mit jdm verstehen"])
        let verb = parse("se brosser les dents\nsich die Zähne\nputzen\n\nle chat\ndie Katze\n\nle chien\nder Hund")
        #expect(pairs(verb)[0] == ["se brosser les dents", "sich die Zähne putzen"])
        // Separate alternatives keep their comma.
        let alt = parse("le chat\ndie Katze\nder Kater\n\nle chien\nder Hund\n\nla maison\ndas Haus")
        #expect(pairs(alt)[0] == ["le chat", "die Katze, der Kater"])
    }

    @Test("\"both languages per line\" lists keep every line")
    func bilingualLines() {
        let list = [
            ["attendre", "warten"], ["oublier", "vergessen"], ["essayer", "versuchen"], ["chanter", "singen"], ["danser", "tanzen"],
            ["grandir", "wachsen"], ["grossir", "zunehmen"], ["maigrir", "abnehmen"], ["emprunter", "ausleihen"], ["prêter", "leihen"],
            ["perdre", "verlieren"], ["gagner", "gewinnen"], ["peindre", "malen"], ["dessiner", "zeichnen"], ["écrire", "schreiben"],
            ["lire", "lesen"], ["dormir", "schlafen"], ["manger", "essen"], ["boire", "trinken"], ["parler", "sprechen"],
            ["chercher", "suchen"], ["trouver", "finden"], ["ouvrir", "öffnen"], ["fermer", "schliessen"], ["acheter", "kaufen"],
            ["vendre", "verkaufen"], ["payer", "bezahlen"], ["courir", "rennen"], ["nager", "schwimmen"], ["voyager", "reisen"],
        ]
        let r = parse(list.map { "\($0[0]) \($0[1])" }.joined(separator: "\n"))
        #expect(r.format == .delimited)
        #expect(r.delimiter == " ")
        #expect(pairs(r) == list)
        #expect(r.skipped.isEmpty)
    }

    @Test("an en dash glued between words is the delimiter, not a hyphen")
    func gluedEnDash() {
        let r = parse("c'est-à-dire–das heisst\nle chat–die Katze\nle week-end–das Wochenende\npeut-être–vielleicht\nla grand-mère–die Grossmutter\nlà-bas–dort")
        #expect(pairs(r) == [
            ["c'est-à-dire", "das heisst"], ["le chat", "die Katze"], ["le week-end", "das Wochenende"], ["peut-être", "vielleicht"],
            ["la grand-mère", "die Grossmutter"], ["là-bas", "dort"],
        ])
        let short = parse("le chat–die Katze\nle chien—der Hund\nla vache–die Kuh\nle cheval–das Pferd\nle week-end–das Wochenende")
        #expect(short.cards.count == 5)
        #expect(pairs(short)[4] == ["le week-end", "das Wochenende"])
    }

    @Test("\"vocabulary - Wortschatz\" is a card, \"Vocabulaire : les animaux\" a heading")
    func vocabularyKeyword() {
        let r = parse("homework - Hausaufgaben\nlesson - Lektion\npage - Seite\nvocabulary - Wortschatz\ngrammar - Grammatik")
        #expect(r.cards.count == 5)
        #expect(pairs(r).contains(["vocabulary", "Wortschatz"]))
        #expect(r.skipped.isEmpty)
        #expect(pairs(parse("vocabulaire - Wortschatz\nle chat - die Katze\nle chien - der Hund"))[0] == ["vocabulaire", "Wortschatz"])
        let headings = parse("Wortschatz Unité 3\nVocabulaire : les animaux\nle chat - die Katze\nle chien - der Hund\nla vache - die Kuh")
        #expect(headings.cards.count == 3)
        #expect(headings.skipped.map(\.reason) == [.heading, .heading])
    }

    @Test("the first line of a wrapped sentence term is kept, not skipped as a heading")
    func wrappedSentence() {
        let blocks = parse("Bonjour\nGuten Tag\n\nComment allez-vous\naujourd'hui ?\nWie geht es Ihnen heute?\n\nMerci beaucoup\nVielen Dank")
        #expect(pairs(blocks)[1] == ["Comment allez-vous aujourd'hui ?", "Wie geht es Ihnen heute?"])
        #expect(blocks.cards[1].flags == [.merged])
        #expect(blocks.skipped.isEmpty)
        let blocks2 = parse(
            "Je voudrais un café\ns'il vous plaît\nIch hätte gern einen Kaffee, bitte\n\nComment tu t'appelles\net quel âge as-tu ?\nWie heisst du und wie alt bist du?\n\nJ'ai faim\nIch habe Hunger")
        #expect(Array(pairs(blocks2).prefix(2)) == [
            ["Je voudrais un café s'il vous plaît", "Ich hätte gern einen Kaffee, bitte"],
            ["Comment tu t'appelles et quel âge as-tu ?", "Wie heisst du und wie alt bist du?"],
        ])
        #expect(blocks2.skipped.isEmpty)
        let question = parse("Qu'est-ce que tu fais\nce week-end ?\nWas machst du dieses Wochenende?\n\nJ'ai faim\nIch habe Hunger\n\nOù habites-tu ?\nWo wohnst du?")
        #expect(pairs(question)[0] == ["Qu'est-ce que tu fais ce week-end ?", "Was machst du dieses Wochenende?"])
        let article = parse("Il fait beau\naujourd'hui\nDas Wetter ist heute schön\n\nOù est\nla gare ?\nWo ist der Bahnhof?\n\nJ'ai faim\nIch habe Hunger")
        #expect(pairs(article)[1] == ["Où est la gare ?", "Wo ist der Bahnhof?"])
        // Alternating lines without blank lines, French and English.
        let alt = parse("le chat\ndie Katze\nComment tu t'appelles\net quel âge as-tu ?\nWie heisst du und wie alt bist du?\nle chien\nder Hund\nla vache\ndie Kuh")
        #expect(pairs(alt)[1] == ["Comment tu t'appelles et quel âge as-tu ?", "Wie heisst du und wie alt bist du?"])
        #expect(alt.skipped.isEmpty)
        let en = parse("the dog\nder Hund\nThe weather is nice\ntoday\nDas Wetter ist heute schön\nthe cat\ndie Katze\nThank you\nvery much\nVielen Dank\nthe cow\ndie Kuh")
        #expect(pairs(en)[1] == ["The weather is nice today", "Das Wetter ist heute schön"])
        #expect(en.cards[3].term.contains("Thank you"))
        #expect(en.cards[3].term.contains("very much"))
        #expect(en.skipped.isEmpty)
        // A heading before a group of entries is still skipped.
        let nombres = parse("le chat\ndie Katze\nle chien\nder Hund\nLes nombres\nvingt et un\neinundzwanzig\ntrente\ndreissig\ncent\nhundert")
        #expect(pairs(nombres)[2] == ["vingt et un", "einundzwanzig"])
        #expect(nombres.skipped.map { "\($0.text)|\($0.reason.rawValue)" } == ["Les nombres|heading"])
    }

    @Test("bare numbers before the entries of a table are numbering, not number vocabulary",
          arguments: ["dash", "tab", "lines", "blocks", "bilingual"])
    func tableNumbering(layout: String) {
        let expected = [["le chat", "die Katze"], ["le chien", "der Hund"], ["la vache", "die Kuh"], ["le cheval", "das Pferd"]]
        func rows(_ fmt: (String, String) -> String) -> [String] {
            expected.enumerated().map { "\($0.offset + 1)\n\(fmt($0.element[0], $0.element[1]))" }
        }
        let text: String
        switch layout {
        case "dash": text = rows { "\($0) - \($1)" }.joined(separator: "\n")
        case "tab": text = rows { "\($0)\t\($1)" }.joined(separator: "\n")
        case "lines": text = rows { "\($0)\n\($1)" }.joined(separator: "\n")
        case "blocks": text = rows { "\($0)\n\($1)" }.joined(separator: "\n\n")
        default: text = rows { "\($0) \($1)" }.joined(separator: "\n")
        }
        let r = parse(text)
        #expect(pairs(r) == expected)
        #expect(r.skipped.map(\.reason) == [.pageNumber, .pageNumber, .pageNumber, .pageNumber])
    }

    @Test("number vocabulary on alternating lines and in blocks keeps its numbers")
    func numberVocabularyLines() {
        #expect(pairs(parse("11\nonze\n12\ndouze\n13\ntreize\n14\nquatorze"))[3] == ["quatorze", "14"])
        #expect(pairs(parse("onze\n11\n\ndouze\n12\n\ntreize\n13"))[2] == ["treize", "13"])
    }

    @Test("en dashes inside compounds of line-based lists stay hyphens")
    func compoundDashes() {
        let blocks = parse("l'amitié franco–allemande\ndie deutsch-französische Freundschaft\n\nle chat\ndie Katze\n\nle chien\nder Hund\n\nla vache\ndie Kuh")
        #expect(pairs(blocks)[0] == ["l'amitié franco-allemande", "die deutsch-französische Freundschaft"])
        let alt = parse("le chat\ndie Katze\nla relation mère–fille\ndie Mutter-Tochter-Beziehung\nle chien\nder Hund\nle trajet Paris–Berlin\ndie Strecke Paris-Berlin")
        #expect(pairs(alt)[1] == ["la relation mère-fille", "die Mutter-Tochter-Beziehung"])
        #expect(pairs(alt)[3] == ["le trajet Paris-Berlin", "die Strecke Paris-Berlin"])
        // A glued en dash mixed into a list of spaced dashes is still the delimiter.
        let mixed = parse("le chat – die Katze\nle week-end–das Wochenende\nla vache – die Kuh\nle cheval – das Pferd")
        #expect(pairs(mixed)[1] == ["le week-end", "das Wochenende"])
        // The user picked the tab: the dash belongs to the term.
        let tab = parse("la relation mère–fille\tdie Mutter-Tochter-Beziehung\nle chat\tdie Katze", ParseOptions(mode: .delimiter, delimiter: "\t"))
        #expect(pairs(tab)[0] == ["la relation mère-fille", "die Mutter-Tochter-Beziehung"])
    }

    @Test("a right page column that ends early still splits every entry, left column first")
    func shortRightColumn() {
        let left = [
            ["le chat", "die Katze"], ["le chien", "der Hund"], ["la vache", "die Kuh"], ["le cheval", "das Pferd"],
            ["la souris", "die Maus"], ["le cochon", "das Schwein"], ["la poule", "das Huhn"],
        ]
        let right = [["le lapin", "das Kaninchen"], ["le mouton", "das Schaf"]]
        for sep in ["\t", "        "] {
            let text = left.indices.map { i in
                i < right.count ? "\(left[i][0]) – \(left[i][1])\(sep)\(right[i][0]) – \(right[i][1])" : "\(left[i][0]) – \(left[i][1])"
            }.joined(separator: "\n")
            let r = parse(text)
            #expect(pairs(r) == left + right)
            #expect(flagged(r).isEmpty)
        }
        let equals = parse(left.indices.map { i in
            i < right.count ? "\(left[i][0])=\(left[i][1])      \(right[i][0])=\(right[i][1])" : "\(left[i][0])=\(left[i][1])"
        }.joined(separator: "\n"))
        #expect(pairs(equals) == left + right)
        // A dash list with notes after a wide gap is not two page columns.
        let notes = parse("le chat - die Katze   (f)\nle chien - der Hund\nla vache - die Kuh   (f)\nle cheval - das Pferd")
        #expect(pairs(notes)[0] == ["le chat", "die Katze (f)"])
    }

    @Test("German -ein / -einte words next to French -ein words keep their language")
    func germanEin() {
        let r = parse("uni, unie - vereint\npleurer - weinen\npenser - meinen\nplein, pleine - voll\nserein, sereine - gelassen\nla pierre - der Stein")
        #expect(r.cards.count == 6)
        #expect(flagged(r).isEmpty)
        let alt = parse("pleurer\nweinen\nil pleurait\ner weinte\nil pensait\ner meinte\nuni, unie\nvereint")
        #expect(pairs(alt)[3] == ["uni, unie", "vereint"])
        #expect(flagged(alt).isEmpty)
    }
}

// MARK: - One word per side, no delimiter

/// "Bonjour Hallo" used to be skipped as a heading, and a list of such lines was read as
/// alternating lines.
@Suite("VocabParser: one word per side without a delimiter")
struct VocabParserOneWordPerSideTests {
    @Test("a single line with a greeting on each side is one card")
    func singleLine() {
        for (fr, de) in [("Bonjour", "Hallo"), ("Merci", "Danke"), ("Salut", "Hallo"), ("Oui", "Ja"), ("chien", "Hund")] {
            let r = parse("\(fr) \(de)")
            #expect(pairs(r) == [[fr, de]])
            #expect(r.skipped.isEmpty)
            #expect(r.termLang == .fr && r.defLang == .de)
        }
    }

    @Test("a list of greetings is split on every line, not paired line by line")
    func greetingList() {
        let r = parse("Bonjour Hallo\nMerci Danke\nAu revoir Tschüss\nOui Ja\nNon Nein")
        #expect(r.format == .delimited)
        #expect(r.delimiter == " ")
        #expect(pairs(r) == [["Bonjour", "Hallo"], ["Merci", "Danke"], ["Au revoir", "Tschüss"], ["Oui", "Ja"], ["Non", "Nein"]])
        #expect(flagged(r).isEmpty)
    }

    @Test("a two-word line with a weak side is kept instead of dropped")
    func weakSide() {
        // "chien" looks a little German ("ch", "ie").
        let r = parse("Salut Hallo\nBonsoir Guten Abend\nS'il vous plaît Bitte\nmaison Haus\nchien Hund")
        #expect(pairs(r) == [["Salut", "Hallo"], ["Bonsoir", "Guten Abend"], ["S'il vous plaît", "Bitte"], ["maison", "Haus"], ["chien", "Hund"]])
        let words = parse("les grands-parents die Grosseltern\nle stylo der Kugelschreiber\ngrandir wachsen\nl’enfant das Kind")
        #expect(pairs(words)[2] == ["grandir", "wachsen"])
    }

    @Test("alternating lines of two words in one language stay alternating")
    func alternatingTwoWordLines() {
        let r = parse("le chien\nder Hund\nla maison\ndas Haus\nGuten Tag\nBonjour")
        #expect(r.format == .alternating)
        #expect(pairs(r) == [["le chien", "der Hund"], ["la maison", "das Haus"], ["Bonjour", "Guten Tag"]])
    }
}

// MARK: - Imports and exports that end in the parser

/// The parseVocab steps of tests/layout.test.js (PDF/OCR lines), tests/db.test.js (text export
/// round trips) and tests/integration.test.js.
@Suite("VocabParser: imports and round trips")
struct VocabParserRoundTripTests {
    /// One item per cell like pdf.js text runs (6 pt per character, 12 pt high).
    private func run(_ x: Double, _ y: Double, _ text: String) -> TextItem {
        TextItem(str: text, x: x, y: y, w: Double(text.utf16.count) * 6, h: 12)
    }

    private let people = [
        ["le monsieur, messieurs", "der Herr"], ["l'homme", "der Mann"], ["la femme", "die Frau"], ["l'enfant", "das Kind"],
        ["le garçon", "der Junge"], ["la fille", "das Mädchen"],
    ]
    private let more = [["appeler", "nennen"], ["s'appeler", "heissen"], ["le nom", "der Name"], ["le prénom", "der Vorname"], ["la rue", "die Strasse"]]

    @Test("a PDF row whose term and definition both wrap stays one card")
    func wrappedRow() {
        let rows = [["avoir lieu", "stattfinden"], ["le chat", "die Katze"], ["le chien", "der Hund"], ["manger", "essen"], ["boire", "trinken"]]
        var items = [run(50, 100, "s'entendre bien avec"), run(260, 100, "sich mit jdm gut"), run(50, 114, "qn"), run(260, 114, "verstehen")]
        for (i, row) in rows.enumerated() {
            items += [run(50, 136 + Double(i) * 22, row[0]), run(260, 136 + Double(i) * 22, row[1])]
        }
        let lines = TextLayout.itemsToLines(items)
        #expect(lines == ["s'entendre bien avec qn\tsich mit jdm gut verstehen"] + rows.map { "\($0[0])\t\($0[1])" })
        let cards = parse(lines.joined(separator: "\n")).cards
        #expect(cards.first?.term == "s'entendre bien avec qn")
        #expect(cards.first?.definition == "sich mit jdm gut verstehen")
        #expect(cards.count == 6)
    }

    @Test("two PDF page columns of \"term – definition\" entries give one card per entry")
    func pdfPageColumns() {
        let left = people + more.prefix(2)
        let right = Array(more.dropFirst(2)) + [["le chat", "die Katze"], ["le chien", "der Hund"], ["la vache", "die Kuh"], ["le cheval", "das Pferd"]]
        var items: [TextItem] = []
        for (i, p) in left.enumerated() { items.append(run(50, 100 + Double(i) * 16, "\(p[0]) – \(p[1])")) }
        for (i, p) in right.enumerated() { items.append(run(320, 100 + Double(i) * 16, "\(p[0]) – \(p[1])")) }
        let lines = TextLayout.itemsToLines(items)
        #expect(lines.first == "\(left[0][0]) – \(left[0][1])\t\(right[0][0]) – \(right[0][1])")
        let r = parse(lines.joined(separator: "\n"))
        #expect(pairs(r) == left + right)
        #expect(flagged(r).isEmpty)
    }

    @Test("a right PDF page column that ends early still gives one card per entry", arguments: [6, 5, 3, 1])
    func shortRightPageColumn(k: Int) {
        let left = people + more.prefix(4)
        let right = [
            ["le chat", "die Katze"], ["le chien", "der Hund"], ["la vache", "die Kuh"], ["le cheval", "das Pferd"],
            ["la souris", "die Maus"], ["le cochon", "das Schwein"],
        ]
        var items: [TextItem] = []
        for (i, p) in left.enumerated() { items.append(run(50, 100 + Double(i) * 16, "\(p[0]) – \(p[1])")) }
        for (i, p) in right.prefix(k).enumerated() { items.append(run(320, 100 + Double(i) * 16, "\(p[0]) – \(p[1])")) }
        let r = parse(TextLayout.itemsToLines(items).joined(separator: "\n"))
        #expect(pairs(r) == left + right.prefix(k))
        #expect(flagged(r).isEmpty)
    }

    @Test("a semicolon-separated export re-imports every card without stray quotes")
    func semicolonExport() {
        let cards = [
            Card(id: "a", term: "aimer", definition: "lieben; mögen"), Card(id: "b", term: "le temps", definition: "das Wetter; die Zeit"),
            Card(id: "c", term: "la maison", definition: "das Haus"), Card(id: "d", term: "le chien", definition: "der Hund"),
        ]
        let text = Backup.setToText(cards: cards, termSep: " - ", cardSep: ";")
        #expect(!text.contains("\""))
        #expect(pairs(parse(text)) == [
            ["aimer", "lieben, mögen"], ["le temps", "das Wetter, die Zeit"], ["la maison", "das Haus"], ["le chien", "der Hund"],
        ])
    }

    @Test("every export option re-imports the 52-card example list card for card")
    func exportRoundTrip() {
        let original = parse(read("user-example.txt")).cards.enumerated().map {
            Card(id: "c\($0.offset)", term: $0.element.term, definition: $0.element.definition)
        }
        #expect(original.count == 52)
        for termSep in ["\t", ", ", " - "] {
            for cardSep in ["\n", ";"] {
                let back = parse(Backup.setToText(cards: original, termSep: termSep, cardSep: cardSep))
                #expect(pairs(back) == original.map { [$0.term, $0.definition] }, "\(termSep.debugDescription) \(cardSep.debugDescription)")
            }
        }
    }

    @Test("the hinted user example round-trips through the default text export")
    func editorFlow() {
        let parsed = parse(read("user-example.txt"), ParseOptions(termLang: .fr, defLang: .de))
        #expect(parsed.cards.count == 52)
        #expect(parsed.termLang == .fr && parsed.defLang == .de)
        let cards = parsed.cards.enumerated().map { Card(id: "c\($0.offset)", term: $0.element.term, definition: $0.element.definition) }
        let again = parse(Backup.setToText(cards: cards), ParseOptions(termLang: .fr, defLang: .de))
        #expect(pairs(again) == pairs(parsed))
    }
}
