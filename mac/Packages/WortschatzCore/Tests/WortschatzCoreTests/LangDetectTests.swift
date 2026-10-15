import Testing
import WortschatzCore

// Port of tests/langdetect.test.js. Inputs JS accepts but Swift's types cannot express
// (numbers, objects, `undefined`) are covered by the langdetect parity fixture instead.

@Suite("LangDetect (langdetect.test.js)")
struct LangDetectTests {
    private static let zeros: [Lang: Double] = [.fr: 0, .de: 0, .en: 0, .es: 0, .it: 0, .ar: 0, .zh: 0]

    /// `text.split('\n')` (CR stays in the line, like JS).
    private static func lines(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    /// `text.split('\n').filter((l) => l.trim())`
    private static func nonEmptyLines(_ name: String) -> [String] {
        lines(LangDetectWebFixtures.read(name)).filter { !JSCompat.trim($0).isEmpty }
    }

    private static func lang(_ text: String?) -> DetectedLanguage { LangDetect.detectLanguage(text).lang }

    @Test("SUPPORTED lists the five Latin languages, then Arabic and Chinese")
    func supported() {
        #expect(LangDetect.SUPPORTED == [.fr, .de, .en, .es, .it, .ar, .zh])
    }

    @Test("scoreLanguages returns non-negative scores for every language",
          arguments: ["le chat", "die Katze", "the house", "el perro", "il cane", "xyz", "Frau"])
    func nonNegativeScores(text: String) {
        let s = LangDetect.scoreLanguages(text)
        #expect(Set(s.keys) == Set(LangDetect.SUPPORTED))
        for lang in LangDetect.SUPPORTED { #expect((s[lang] ?? -1) >= 0) }
    }

    @Test("scoreLanguages is all zero without letters and never fails")
    func zeroWithoutLetters() {
        for input: String? in ["", "   ", "123 - 456", "!!!", nil, "\t\n"] {
            let s = LangDetect.scoreLanguages(input)
            for lang in LangDetect.SUPPORTED { #expect((s[lang] ?? -1) >= 0) }
        }
        #expect(LangDetect.scoreLanguages("") == Self.zeros)
        #expect(LangDetect.scoreLanguages("12 / 40") == Self.zeros)
        // Arabic punctuation and digits, the tatweel and vowel marks alone are no letters.
        #expect(LangDetect.scoreLanguages("١٢ ، ؟ ـ") == Self.zeros)
        #expect(LangDetect.scoreLanguages("，。！") == Self.zeros)
    }

    @Test("articles push their language up")
    func articles() {
        func score(_ text: String, _ lang: Lang) -> Double { LangDetect.scoreLanguages(text)[lang] ?? 0 }
        #expect(score("le jardin", .fr) > score("jardin", .fr))
        #expect(score("der Garten", .de) > score("Garten", .de))
        #expect(score("the garden", .en) > score("garden", .en))
        #expect(score("gli amici", .it) > score("amici", .it))
        #expect(score("los amigos", .es) > score("amigos", .es))
    }

    @Test("detectLanguage: clear cases in every language", arguments: [
        (Lang.fr, ["le chat", "l'homme", "les cheveux", "garçon", "sérieux, sérieuse", "la bêtise", "s'appeler", "beaucoup"]),
        (Lang.de, ["die Katze", "das Mädchen", "sich gleichen", "die Schönheit", "freundlich", "die Strasse", "heissen", "etw. suchen"]),
        (Lang.en, ["the house", "to appear", "beautiful", "something", "to look for sth", "the neighbourhood", "quickly"]),
        (Lang.es, ["el perro", "el niño", "¿Qué tal?", "la canción", "los amigos", "la ciudad", "hablar"]),
        (Lang.it, ["il cane", "gli amici", "la città", "la stazione", "perché", "lo studente", "mangiare"]),
    ])
    func clearCases(lang: Lang, texts: [String]) {
        for text in texts {
            let d = LangDetect.detectLanguage(text)
            #expect(d.lang == DetectedLanguage(lang), "\(text)")
            #expect(d.confidence > 0 && d.confidence <= 1, "\(text)")
        }
    }

    @Test("detectLanguage: short single words of the user list")
    func userListWords() {
        let fr = ["calme", "tranquille", "sage", "aimable", "comique", "sympathique", "moche", "bête", "lâche", "appeler"]
        let de = ["lieb", "ruhig", "still", "Frau", "komisch", "sympathisch", "mutig", "dumm", "feige", "nennen", "hübsch"]
        for w in fr { #expect(Self.lang(w) == .fr, "\(w)") }
        for w in de { #expect(Self.lang(w) == .de, "\(w)") }
    }

    @Test("detectLanguage: unknown for empty or letterless input")
    func unknownWithoutLetters() {
        #expect(LangDetect.detectLanguage("") == .unknown)
        #expect(LangDetect.detectLanguage("  12 - 13 !! ") == .unknown)
        #expect(LangDetect.detectLanguage(nil) == .unknown)
        #expect(LangDetect.detectLanguage(nil).lang == .unknown)
    }

    @Test("user example: at least 95% of individual lines classified correctly")
    func userExampleLines() {
        let lines = Self.nonEmptyLines("user-example.txt")
        #expect(lines.count == 104)
        var correct = 0
        for (i, line) in lines.enumerated() where Self.lang(line) == (i % 2 == 0 ? .fr : .de) { correct += 1 }
        #expect(Double(correct) / Double(lines.count) >= 0.95)
    }

    @Test("user example: both columns detected with high confidence")
    func userExampleColumns() {
        let lines = Self.nonEmptyLines("user-example.txt")
        let a = LangDetect.detectColumn(lines.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
        let b = LangDetect.detectColumn(lines.enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
        #expect(a.lang == .fr)
        #expect(b.lang == .de)
        #expect(a.confidence > 0.8)
        #expect(b.confidence > 0.8)
    }

    @Test("generalises to words that are not in the lexicon", arguments: [
        (Lang.fr, ["la grenouille", "l'épicerie", "étroit", "le bouleau", "la pieuvre", "s'évanouir", "le tournevis",
                   "la quincaillerie", "ensoleillé", "le parapluie", "la cheminée", "le marteau", "épouvantable", "la serrure",
                   "le grenier", "la citrouille", "le hérisson", "déménager", "le brouillard", "la bougie", "nettoyer",
                   "pourtant", "la boucherie", "malheureusement", "coudre", "le genou", "la poubelle", "la tasse"]),
        (Lang.de, ["die Wäscheklammer", "verschwommen", "der Regenschirm", "das Eichhörnchen", "die Glühbirne", "umziehen",
                   "der Nebel", "die Kerze", "das Schloss", "der Dachboden", "der Kürbis", "der Igel", "schrecklich", "sonnig",
                   "der Kamin", "der Schraubenzieher", "der Frosch", "ohnmächtig werden", "putzen", "trotzdem", "die Metzgerei",
                   "leider", "nähen", "das Knie", "der Mülleimer", "plaudern", "Zahnbürste", "Wolke"]),
        (Lang.en, ["the umbrella", "to faint", "the hedgehog", "the screwdriver", "the attic", "the pumpkin", "the candle",
                   "foggy", "sunny", "the fireplace", "awful", "narrow", "the squirrel", "the lightbulb", "to move house",
                   "the frog", "the grocery store", "blurry", "to clean", "however", "unfortunately", "to sew", "toothbrush"]),
    ])
    func heldOut(lang: Lang, texts: [String]) {
        let misses = texts.filter { Self.lang($0) != DetectedLanguage(lang) }
        let rate = Double(texts.count - misses.count) / Double(texts.count)
        #expect(rate >= 0.85, "\(lang) held-out accuracy \(rate): \(misses.joined(separator: ", "))")
    }

    @Test("Spanish and Italian columns are told apart")
    func spanishItalian() {
        let es = ["la rana", "el paraguas", "estrecho", "la vela", "el martillo", "la calabaza", "mudarse", "la niebla",
                  "limpiar", "sin embargo", "la rodilla", "el cepillo de dientes", "charlar", "la carnicería"]
        let it = ["la rana", "l'ombrello", "stretto", "la candela", "il martello", "la zucca", "traslocare", "la nebbia",
                  "pulire", "tuttavia", "il ginocchio", "lo spazzolino", "chiacchierare", "la macelleria"]
        #expect(LangDetect.detectColumn(es).lang == .es)
        #expect(LangDetect.detectColumn(it).lang == .it)
    }

    @Test("detectColumn: one outlier line does not change the column")
    func outlier() {
        let col = ["le chat", "le chien", "la souris", "the cat", "le lapin", "la vache", "le cheval", "brave", "sage"]
        #expect(LangDetect.detectColumn(col).lang == .fr)
        let de = ["der Hund", "still", "die Katze", "charmant", "lieb", "ruhig"]
        #expect(LangDetect.detectColumn(de).lang == .de)
    }

    /// The delimiters of the JS table (strings and regexes).
    private enum Delimiter: Sendable {
        case text(String)
        case pattern(String)

        func split(_ line: String) -> [String] {
            switch self {
            case let .text(d):
                return line.components(separatedBy: d)
            case let .pattern(p):
                let regex = try! Regex(p).matchingSemantics(.unicodeScalar)
                return line.split(separator: regex, omittingEmptySubsequences: false).map(String.init)
            }
        }
    }

    @Test("detectColumn: right language for every fixture column", arguments: [
        ("quizlet-export.txt", Delimiter.text("\t"), Lang.fr, Lang.de),
        ("dash-hyphen.txt", .text(" - "), .fr, .de),
        ("dash-en-em.txt", .pattern(#"\s[–—]\s"#), .fr, .de),
        ("equals.txt", .text(" = "), .fr, .de),
        ("semicolon.txt", .text(";"), .fr, .de),
        ("german-first.txt", .text(" - "), .de, .fr),
        ("english-german.txt", .text(" - "), .en, .de),
        ("pdf-columns.txt", .pattern(#"\s{2,}"#), .fr, .de),
        ("numbered.txt", .pattern(#"\s–\s"#), .fr, .de),
        ("spanish.txt", .pattern(#"\s–\s"#), .es, .de),
        ("italian.txt", .text(" = "), .it, .de),
        ("four-cells.tsv", .text("\t"), .fr, .de),
    ])
    private func fixtureColumns(file: String, delimiter: Delimiter, left: Lang, right: Lang) {
        let rows = Self.nonEmptyLines(file).map(delimiter.split)
        let leftCol = rows.flatMap { $0.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) }
        let rightCol = rows.flatMap { $0.enumerated().filter { $0.offset % 2 == 1 }.map(\.element) }
        #expect(LangDetect.detectColumn(leftCol).lang == DetectedLanguage(left), "\(file)")
        #expect(LangDetect.detectColumn(rightCol).lang == DetectedLanguage(right), "\(file)")
    }

    @Test("detectColumn: OCR halves and alternating lines")
    func ocrAndAlternating() {
        let ocr = Self.nonEmptyLines("two-column-ocr.txt")
        #expect(LangDetect.detectColumn(Array(ocr.prefix(8))).lang == .fr)
        #expect(LangDetect.detectColumn(Array(ocr.dropFirst(8))).lang == .de)
        let alt = Self.nonEmptyLines("alternating.txt")
        #expect(LangDetect.detectColumn(alt.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)).lang == .fr)
        #expect(LangDetect.detectColumn(alt.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)).lang == .de)
    }

    @Test("detectColumn: empty and odd input")
    func emptyColumns() {
        #expect(LangDetect.detectColumn([]) == .unknown)
        #expect(LangDetect.detectColumn(["", "  ", "42"]) == .unknown)
        #expect(LangDetect.detectColumn(["le chat"]).lang == .fr)
        // JS: [null, 'die Katze', undefined, 7]
        #expect(LangDetect.detectColumn(["", "die Katze", "", "7"]).lang == .de)
    }

    @Test("detectColumn confidence grows with agreeing lines")
    func confidenceGrows() {
        let one = LangDetect.detectColumn(["le chat"])
        let many = LangDetect.detectColumn(["le chat", "le chien", "la maison", "les enfants", "l'école", "la rue"])
        #expect(many.confidence > one.confidence)
        #expect(many.confidence <= 1)
    }

    @Test("French -ein / -eindre words are French; German -ein words stay German")
    func einWords() {
        for w in ["plein", "pleine", "serein, sereine", "freiner", "atteindre", "peindre", "éteindre", "craindre", "peine", "la ceinture"] {
            #expect(Self.lang(w) == .fr, "\(w)")
        }
        for w in ["klein", "Schwein", "allein", "mein", "meine", "seine", "Bein", "Wein", "Stein", "einfach", "die Leine"] {
            #expect(Self.lang(w) == .de, "\(w)")
        }
    }

    @Test("German -eint / -einte verb forms stay German and confident")
    func eintWords() {
        for w in ["vereinte", "verneinte", "beweinte", "meinte", "weinte", "vereint", "gemeint", "erscheint", "vereinigt"] {
            let d = LangDetect.detectLanguage(w)
            #expect(d.lang == .de, "\(w)")
            #expect(d.confidence >= 0.55, "\(w)")
        }
        // French words with the same letters keep their language too.
        for w in ["peinte", "atteinte", "éteinte", "teinte", "enceinte", "pleines"] {
            #expect(Self.lang(w) == .fr, "\(w)")
        }
    }

    @Test("English school and media words are English",
          arguments: ["lesson", "chapter", "exercise", "homework", "grammar", "newspaper", "advertisement", "channel"])
    func englishSchoolWords(word: String) {
        #expect(Self.lang(word) == .en)
    }

    // MARK: Port-specific checks

    @Test("Scores are deterministic and rounded to 3 decimals")
    func rounding() {
        for text in ["le chat", "die Katze", "the house", "Ἀθῆναι", "le 😀 chat"] {
            let s = LangDetect.scoreLanguages(text)
            #expect(s == LangDetect.scoreLanguages(text))
            for value in s.values { #expect(abs(value * 1000 - JSCompat.round(value * 1000)) < 1e-6) }
        }
    }

    @Test("Canonically equivalent spellings score alike (input is NFC-normalised)")
    func nfc() {
        #expect(LangDetect.scoreLanguages("e\u{301}te\u{301}") == LangDetect.scoreLanguages("été"))
        #expect(LangDetect.detectLanguage("Ma\u{308}dchen") == LangDetect.detectLanguage("Mädchen"))
    }

    @Test("DetectedLanguage maps to the set language")
    func detectedLanguage() {
        #expect(DetectedLanguage(.fr).lang == .fr)
        #expect(DetectedLanguage(.other) == .unknown)
        #expect(DetectedLanguage.unknown.lang == nil)
        #expect(LanguageDetection.unknown == LanguageDetection(lang: .unknown, confidence: 0))
    }
}
