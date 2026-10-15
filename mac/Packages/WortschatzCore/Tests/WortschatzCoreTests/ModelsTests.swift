import Foundation
import Testing
import WortschatzCore

@Suite("Models")
struct ModelsTests {
    // MARK: Defaults (db.js DEFAULT_STUDY_OPTIONS / DEFAULT_SETTINGS)

    @Test func defaultsMatchTheWebApp() throws {
        let expected = try JSONValue.parse("""
        {"answerWith":"term","shuffle":true,"copyAnswer":true,"autoAdvance":true,"audio":false,
         "tolerance":{"articles":true,"abbreviations":true,"multipleAnswers":true,"parentheses":true,
                      "ignoreCase":true,"ignoreAccents":false,"typos":false},
         "learn":{"roundSize":7,"mc":true,"written":true,"retype":false}}
        """)
        assertParity(try JSONValue(encoding: DEFAULT_STUDY_OPTIONS), expected, "DEFAULT_STUDY_OPTIONS")
        assertParity(try JSONValue(encoding: DEFAULT_SETTINGS), ["theme": "system", "study": expected], "DEFAULT_SETTINGS")
    }

    // MARK: Lenient decoding of real web backups

    static let webSet = """
    {"id":"s1","title":"Französisch Unité 3","description":"","termLang":"fr","defLang":"de",
     "cards":[{"id":"c1","term":"le monsieur, messieurs","definition":"der Herr","starred":false},
              {"id":"c2","term":"l'homme","definition":"der Mann","starred":true},
              "garbage", {"term": 12, "definition": true}],
     "studyOptions":{"answerWith":"both","tolerance":{"typos":true,"bogus":1},"learn":{"mc":false,"written":false,"roundSize":10}},
     "createdAt":1760000000000,"updatedAt":1760000005000,"lastStudiedAt":null,"extra":"ignored"}
    """

    @Test func vocabSetDecodesLeniently() throws {
        let set = try JSONDecoder().decode(VocabSet.self, from: Data(Self.webSet.utf8))
        #expect(set.id == "s1")
        #expect(set.cards.count == 3)
        #expect(set.cards[1].starred)
        #expect(set.cards[2] == Card(id: "", term: "12", definition: "true"))
        #expect(set.studyOptions == StudyOptionsPatch(answerWith: .both, tolerance: TolerancePatch(typos: true), learn: LearnOptionsPatch(roundSize: 10)))
        #expect(set.lastStudiedAt == nil)
        #expect(set.updatedAt == 1_760_000_005_000)
    }

    @Test func vocabSetDefaultsForMissingFields() throws {
        let set = try JSONDecoder().decode(VocabSet.self, from: Data(#"{"id":"x","termLang":"klingon","createdAt":5}"#.utf8))
        #expect(set.termLang == .fr)
        #expect(set.defLang == .de)
        #expect(set.title == "")
        #expect(set.cards.isEmpty)
        #expect(set.studyOptions == nil)
        #expect(set.updatedAt == 5)
        #expect(VocabSet(json: "not a set") == nil)
    }

    @Test("Arabic and Chinese are set languages; other codes still fall back")
    func arabicAndChinese() throws {
        let set = try JSONDecoder().decode(VocabSet.self, from: Data(#"{"id":"x","termLang":"ar","defLang":"zh","createdAt":5}"#.utf8))
        #expect([set.termLang, set.defLang] == [.ar, .zh])
        #expect(try JSONValue(encoding: set)["termLang"] == "ar")
        let odd = try JSONDecoder().decode(VocabSet.self, from: Data(#"{"id":"x","termLang":"zh-CN","defLang":"AR","createdAt":5}"#.utf8))
        #expect([odd.termLang, odd.defLang] == [.fr, .de])
        #expect(Lang.allCases.map(\.rawValue) == ["fr", "en", "es", "it", "ar", "zh", "de", "other"])
        #expect(Lang.ar.isRTL && !Lang.zh.isRTL && !Lang.other.isRTL)
    }

    @Test func vocabSetEncodesNullsLikeJS() throws {
        let set = VocabSet(id: "a", title: "T", createdAt: 1)
        let json = try JSONValue(encoding: set)
        #expect(json["studyOptions"] == .null)
        #expect(json["lastStudiedAt"] == .null)
        #expect(json.objectValue?.keys.sorted() == ["cards", "createdAt", "defLang", "description", "id", "lastStudiedAt", "studyOptions", "termLang", "title", "updatedAt"])
        // Round trip
        #expect(try json.decode(as: VocabSet.self) == set)
    }

    @Test func cardProgressEncodesNulls() throws {
        let json = try JSONValue(encoding: CardProgress())
        assertParity(json, ["correct": 0, "incorrect": 0, "streak": 0, "streakBefore": 0, "lastResult": nil, "lastAnsweredAt": nil])
    }

    @Test func settingsDecodeLikeMergeSettings() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"theme":"neon","study":{"shuffle":false,"answerWith":"nonsense","tolerance":{"ignoreCase":"yes","typos":true}}}"#.utf8))
        #expect(s.theme == .system)
        #expect(s.study.shuffle == false)
        #expect(s.study.answerWith == .term)
        #expect(s.study.tolerance.typos)
        #expect(s.study.tolerance.ignoreCase)
    }

    @Test func studySubsetCoding() throws {
        #expect(try JSONValue(encoding: StudySubset.starred) == "starred")
        #expect(try JSONValue(encoding: StudySubset.cardIds(["a"])) == ["cardIds": ["a"]])
        #expect(StudySubset(json: "bogus") == .all)
        #expect(StudySubset(json: ["cardIds": ["a", "", nil, 5]]) == .cardIds(["a", "5"]))
        #expect(try JSONValue.parse(#"{"cardIds":["x"]}"#).decode(as: StudySubset.self) == .cardIds(["x"]))
    }

    @Test func langDictionariesEncodeAsObjects() throws {
        let scores: [Lang: Double] = [.fr: 1.5, .de: 0]
        #expect(try JSONValue(encoding: scores) == ["fr": 1.5, "de": 0])
    }

    // MARK: Deep merge (db.test.js study-option tests at model level)

    @Test func getStudyOptionsMergesDefaultsSettingsAndSet() {
        let settings = DEFAULT_SETTINGS.merging(SettingsPatch(study: StudyOptionsPatch(answerWith: .definition, tolerance: TolerancePatch(ignoreAccents: true))))
        #expect(settings.study.answerWith == .definition)
        let setPatch = StudyOptionsPatch().merging(StudyOptionsPatch(answerWith: .both, tolerance: TolerancePatch(typos: true)))
        #expect(setPatch == StudyOptionsPatch(answerWith: .both, tolerance: TolerancePatch(typos: true)))
        let opts = StudyOptions.full(StudyOptionsPatch(settings.study), setPatch)
        #expect(opts.answerWith == .both)
        #expect(opts.tolerance.typos)
        #expect(opts.tolerance.ignoreAccents)
        #expect(opts.tolerance.articles)
        let next = setPatch.merging(StudyOptionsPatch(tolerance: TolerancePatch(articles: false)))
        #expect(next == StudyOptionsPatch(answerWith: .both, tolerance: TolerancePatch(articles: false, typos: true)))
    }

    @Test func learnOptionsDeepMerge() {
        let s = DEFAULT_SETTINGS.merging(SettingsPatch(study: StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 10))))
        #expect(s.study.learn == LearnOptions(roundSize: 10))
        var set = StudyOptionsPatch().merging(StudyOptionsPatch(learn: LearnOptionsPatch(retype: true)))
        #expect(set == StudyOptionsPatch(learn: LearnOptionsPatch(retype: true)))
        #expect(StudyOptions.full(StudyOptionsPatch(s.study), set).learn == LearnOptions(roundSize: 10, retype: true))
        set = set.merging(StudyOptionsPatch(answerWith: .both, learn: LearnOptionsPatch(roundSize: 15)))
        #expect(set == StudyOptionsPatch(answerWith: .both, learn: LearnOptionsPatch(roundSize: 15, retype: true)))
    }

    @Test func invalidLearnValuesAreIgnored() throws {
        for raw in ["0", "-3", "7.5", "\"10\"", "51", "null"] {
            let patch = try JSONValue.parse(#"{"learn":{"roundSize":\#(raw)}}"#)
            #expect(StudyOptionsPatch(json: patch)?.isEmpty == true, "\(raw)")
        }
        let bad = try JSONValue.parse(#"{"learn":{"mc":"no","written":0,"retype":"yes","bogus":true}}"#)
        #expect(StudyOptionsPatch(json: bad)?.isEmpty == true)
        #expect(StudyOptionsPatch(json: ["learn": "all"])?.isEmpty == true)
        #expect(StudyOptionsPatch(json: ["learn": ["roundSize": 1]])?.learn?.roundSize == 1)
        #expect(StudyOptionsPatch(json: ["learn": ["roundSize": 50]])?.learn?.roundSize == 50)
        // A typed patch is sanitised when merged.
        #expect(StudyOptions.default.merging(StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 99))).learn.roundSize == 7)
    }

    @Test func learnOptionsNeverSwitchOffBothQuestionTypes() {
        var set = StudyOptionsPatch()
        func learn() -> LearnOptions { StudyOptions.full(set).learn }
        set = set.merging(StudyOptionsPatch(learn: LearnOptionsPatch(mc: false)))
        #expect([learn().mc, learn().written] == [false, true])
        // Turning the other one off: the newest choice wins, the first comes back on.
        set = set.merging(StudyOptionsPatch(learn: LearnOptionsPatch(written: false)))
        #expect([learn().mc, learn().written] == [true, false])
        #expect(set.learn == LearnOptionsPatch(mc: true, written: false))
        // Both off in one patch is not a valid choice: that part is ignored.
        set = set.merging(StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 10, mc: false, written: false)))
        #expect(learn() == LearnOptions(roundSize: 10, mc: true, written: false))

        // Across layers the set's own choice wins over the defaults in Settings.
        var settings = DEFAULT_SETTINGS.merging(SettingsPatch(study: StudyOptionsPatch(learn: LearnOptionsPatch(mc: false))))
        #expect(StudyOptions.full(StudyOptionsPatch(settings.study), set).learn.written == false)
        settings = settings.merging(SettingsPatch(study: StudyOptionsPatch(learn: LearnOptionsPatch(written: false))))
        #expect(settings.study.learn == LearnOptions(roundSize: 7, mc: true, written: false))
        settings = settings.merging(SettingsPatch(study: StudyOptionsPatch(learn: LearnOptionsPatch(mc: false, written: false))))
        #expect(settings.study.learn == LearnOptions(roundSize: 7, mc: true, written: false))
    }

    @Test func resettingSettingsToDefaults() {
        let s = DEFAULT_SETTINGS.merging(SettingsPatch(study: StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 15, mc: false, retype: true))))
        #expect(s.merging(SettingsPatch(study: StudyOptionsPatch(DEFAULT_STUDY_OPTIONS))).study == DEFAULT_STUDY_OPTIONS)
    }
}
