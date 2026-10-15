import Testing
import WortschatzCore

/// Port of src/lib/labels.js (no JS test file; checks the data and helpers).
@Suite("Labels")
struct LabelsTests {
    @Test func langs() {
        #expect(Labels.langName(.fr) == "Französisch")
        #expect(Labels.langName(.de) == "Deutsch")
        #expect(Labels.LANGS[.de]?.bcp47 == "de-CH")
        #expect(Labels.LANGS[.en]?.bcp47 == "en-GB")
        #expect(Labels.langShort(.other) == "—")
        #expect(Labels.langName("xx") == "Andere")
        #expect(Labels.langPair(.fr, .de) == "FR → DE")
        #expect(Labels.LANG_ORDER == [.fr, .en, .es, .it, .ar, .zh, .de, .other])
        #expect(Set(Labels.LANGS.keys) == Set(Lang.allCases))
        #expect(Set(Labels.LANG_ORDER) == Set(Lang.allCases))
    }

    @Test("Arabic and Chinese")
    func arabicAndChinese() {
        #expect(Labels.LANGS[.ar] == LangInfo(name: "Arabisch", short: "AR", bcp47: "ar"))
        #expect(Labels.LANGS[.zh] == LangInfo(name: "Chinesisch", short: "ZH", bcp47: "zh-CN"))
        #expect(Labels.langName("ar") == "Arabisch")
        #expect(Labels.langPair(.zh, .de) == "ZH → DE")
        // Only Arabic is written right to left.
        #expect(Lang.allCases.filter(\.isRTL) == [.ar])
        #expect(Labels.NOTE_LABELS[.pinyin] == "Nur Pinyin")
        #expect(Labels.NOTE_LABELS[.tones] == "Töne")
        #expect(Labels.NOTE_LABELS[.variant] == "Schreibvariante")
        #expect(Labels.HINT_LABELS[.tonesOnly] == "Nur die Töne fehlen")
    }

    @Test func statusNotesAndHints() {
        #expect(Labels.STATUS[.learning] == "Am Lernen")
        #expect(Labels.NOTE_LABELS[.letterCase] == "Gross-/Kleinschreibung")
        #expect(Set(Labels.NOTE_LABELS.keys) == Set(GradeNote.allCases))
        #expect(Set(Labels.HINT_LABELS.keys) == Set(GradeHint.allCases))
        #expect(Labels.HINT_LABELS[.typo] == "Fast – ein kleiner Tippfehler")
    }

    @Test func plural() {
        #expect(Labels.plural(1, "Begriff", "Begriffe") == "1 Begriff")
        #expect(Labels.plural(3, "Begriff", "Begriffe") == "3 Begriffe")
        #expect(Labels.plural(0, "Begriff", "Begriffe") == "0 Begriffe")
    }

    /// Swiss spelling: no sharp s in any UI label.
    @Test func noSharpS() {
        let all = Labels.LANGS.values.map(\.name) + Array(Labels.STATUS.values) + Array(Labels.NOTE_LABELS.values)
            + Array(Labels.HINT_LABELS.values)
        #expect(!all.contains { $0.contains("ß") })
    }
}
