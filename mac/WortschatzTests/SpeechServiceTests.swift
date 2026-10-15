import AVFoundation
import Testing
import WortschatzCore

@testable import Wortschatz

/// Read-aloud for Arabic and Chinese (spec «Read aloud»): Chinese with characters is read without
/// its pinyin, never with a Cantonese voice, and the voice settings list every language but
/// «Andere» in the pickers' order.
@MainActor
@Suite("Vorlesen: Arabisch und Chinesisch")
struct SpeechServiceTests {
    @Test("Chinesisch mit Zeichen liest nur die Zeichen", arguments: [
        ("你好 (nǐ hǎo)", "你好"),
        ("你好（nǐ hǎo）", "你好"),
        ("你好 [nǐ hǎo]", "你好"),
        ("nǐ hǎo 你好", "你好"),
        ("ni3 hao3 你好", "你好"),
        ("nǐ hǎo / ní hǎo 你好", "你好"),
        ("谢谢/多谢 (xièxie)", "谢谢, 多谢"),
        ("你好 [nǐ hǎo]；您好", "你好, 您好"),
        ("你好 (你们好)", "你好 你们好"),
    ])
    func chineseWithoutPinyin(text: String, spoken: String) {
        #expect(SpeechService.speakable(text, lang: .zh) == spoken)
    }

    @Test("Nur Pinyin und andere Sprachen bleiben, wie sie sind")
    func otherTexts() {
        #expect(SpeechService.speakable("nǐ hǎo", lang: .zh) == "nǐ hǎo")
        #expect(SpeechService.speakable("你好 (nǐ hǎo)", lang: .other) == "你好 nǐ hǎo")
        #expect(SpeechService.speakable("beau/belle", lang: .fr) == "beau, belle")
        #expect(SpeechService.speakable("(sich) freuen", lang: .de) == "sich freuen")
        #expect(SpeechService.speakable("الكتاب (كتب)", lang: .ar) == "الكتاب كتب")
        #expect(SpeechService.speakable("beau/belle") == "beau, belle")
    }

    @Test("Kantonesische Stimmen erkennen")
    func cantonese() {
        for tag in ["zh-HK", "zh_HK", "zh-Hant-HK", "zh-MO", "yue", "yue-Hant-HK", "zh-yue"] {
            #expect(SpeechService.isCantonese(tag), "\(tag)")
        }
        for tag in ["zh-CN", "zh-TW", "zh-Hans-CN", "zh", "zh-Hant-TW", "de-CH"] {
            #expect(!SpeechService.isCantonese(tag), "\(tag)")
        }
    }

    @Test("Chinesisch spricht nie eine kantonesische Stimme")
    func noCantoneseVoiceForChinese() {
        // Whatever this Mac has installed: no Hong Kong or Macau voice qualifies for Mandarin.
        for voice in AVSpeechSynthesisVoice.speechVoices() where SpeechService.isCantonese(voice.language) {
            #expect(SpeechService.score(voice, wanted: "zh-CN") < 0, "\(voice.identifier)")
        }
        if let best = SpeechService.bestVoice(for: "zh-CN", among: AVSpeechSynthesisVoice.speechVoices()) {
            #expect(!SpeechService.isCantonese(best.language), "\(best.identifier)")
        }
        #expect(SpeechService.languageTag(for: .zh) == "zh-CN")
        #expect(SpeechService.languageTag(for: .ar) == "ar")
    }

    @Test("Stimmen in der Reihenfolge der Sprachwahl, ohne «Andere», mit Hörproben")
    func voiceSettings() {
        #expect(SettingsVoiceCatalog.languages == [.fr, .en, .es, .it, .ar, .zh, .de])
        #expect(SettingsVoiceCatalog.sample(for: .ar) == "مرحبًا! اليوم نتعلّم كلمات جديدة.")
        #expect(SettingsVoiceCatalog.sample(for: .zh) == "你好！今天我们学习新词。")
        #expect(SettingsVoiceCatalog.sample(for: .de) == "Hallo! Heute lernen wir neue Wörter.")
        // The sample is read as written.
        #expect(SpeechService.speakable(SettingsVoiceCatalog.sample(for: .zh), lang: .zh) == "你好！今天我们学习新词。")
    }
}
