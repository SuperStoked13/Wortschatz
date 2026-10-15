import Testing
import WortschatzCore

@testable import Wortschatz

/// What the study screens offer for Arabic and Chinese answers: the special characters, the
/// accent example of the options and the Apple-Intelligence synonyms.
@MainActor
@Suite("Lernen: Arabisch und Chinesisch")
struct StudyLanguageTests {
    @Test("Sonderzeichen: keine für Arabisch, ü für Pinyin")
    func specialCharacters() {
        #expect(SpecialCharacters.characters(for: .ar).isEmpty)
        #expect(SpecialCharacters.characters(for: .zh) == ["ü"])
        #expect(SpecialCharacters.characters(for: .de) == ["ä", "ö", "ü", "Ä", "Ö", "Ü"])
        #expect(SpecialCharacters.characters(for: nil).isEmpty)
    }

    @Test("Akzente ignorieren: fehlende Töne als Beispiel für Chinesisch")
    func accentExample() throws {
        func example(_ lang: Lang) throws -> String {
            try #require(LearnOptionsCopy.toleranceItems(termLang: lang).first { $0.id == "ignoreAccents" }).example
        }
        #expect(try example(.zh) == "«ni hao» = «nǐ hǎo», «ahnlich» = «ähnlich»")
        #expect(try example(.ar) == "«ahnlich» = «ähnlich»")
        #expect(try example(.fr) == "«ecole» = «école», «ahnlich» = «ähnlich»")
    }

    @Test("Synonyme mit Apple Intelligence: Chinesisch nur, wenn das Modell es kann, Arabisch nie")
    func synonymLanguages() {
        let chinese = SynonymQuery(prompt: "Hallo", expected: "你好", promptLang: .de, answerLang: .zh)
        #expect(SynonymAssistant.supports(chinese, modelSpeaks: { _ in true }))
        #expect(!SynonymAssistant.supports(chinese, modelSpeaks: { $0 != .zh }))

        let arabic = SynonymQuery(prompt: "Buch", expected: "كتاب", promptLang: .de, answerLang: .ar)
        #expect(!SynonymAssistant.supports(arabic, modelSpeaks: { _ in true }))

        let french = SynonymQuery(prompt: "gemeinsam", expected: "ensemble", promptLang: .de, answerLang: .fr)
        #expect(SynonymAssistant.supports(french, modelSpeaks: { _ in true }))
        #expect(SynonymAssistant.checkedLocales[.zh] != nil)
        #expect(SynonymAssistant.checkedLocales[.fr] == nil)
        // The real check runs (whatever this Mac's model speaks).
        _ = SynonymAssistant.shared.supports(chinese)
    }
}
