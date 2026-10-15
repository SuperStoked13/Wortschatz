import Testing
import WortschatzCore

// Port of joinCjk and the plain-text fallback of ocrDataToText (src/import/ocr.js). Parity:
// Fixtures/ocr.json (`ocrPlainText` cases).
@Suite("OCRPostprocess (joinCjk)")
struct OCRPostprocessCJKTests {
    @Test("Spaces between two CJK characters are removed")
    func joinsCJK() {
        #expect(OCRPostprocess.joinCJK("你 好 ， 朋 友") == "你好，朋友")
        #expect(OCRPostprocess.joinCJK("谢 谢 xiè xie") == "谢谢 xiè xie")
        #expect(OCRPostprocess.joinCJK("你好  朋友") == "你好朋友") // a run of spaces
        #expect(OCRPostprocess.joinCJK("こん にち は") == "こんにちは") // kana
        #expect(OCRPostprocess.joinCJK("你好 。") == "你好。") // CJK punctuation
        #expect(OCRPostprocess.joinCJK("𠀀 𠀁") == "𠀀𠀁") // Extension B
    }

    @Test("Other spaces stay")
    func keepsOtherSpaces() {
        #expect(OCRPostprocess.joinCJK("你好 nǐ hǎo") == "你好 nǐ hǎo")
        #expect(OCRPostprocess.joinCJK("nǐ 你") == "nǐ 你")
        #expect(OCRPostprocess.joinCJK("你\t好") == "你\t好") // only plain spaces
        #expect(OCRPostprocess.joinCJK("你\u{A0}好") == "你\u{A0}好")
        #expect(OCRPostprocess.joinCJK("le chat  noir") == "le chat  noir")
        #expect(OCRPostprocess.joinCJK("كتاب قلم") == "كتاب قلم")
        #expect(OCRPostprocess.joinCJK("") == "")
        #expect(OCRPostprocess.joinCJK(" 你 ") == " 你 ")
    }

    @Test("The plain-text fallback joins Chinese words and restores umlauts")
    func plainText() {
        #expect(OCRPostprocess.plainTextLines("你 好 ， 朋 友\n谢 谢 xiè xie\n") == ["你好，朋友", "谢谢 xiè xie"])
        #expect(OCRPostprocess.plainTextLines("die Tûr\nla porte\n") == ["die Tür", "la porte"])
        #expect(OCRPostprocess.plainTextLines("") == [""])
        // CR stays in its line, like JS split('\n').
        #expect(OCRPostprocess.plainTextLines("a\r\nb") == ["a\r", "b"])
    }
}
