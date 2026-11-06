using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of SpeechServiceTests.swift (the pure parts: speakable text, Cantonese tags) plus the voice choice of
// speech.js scoreVoice with Windows-like voice lists.
public class SpeechTextTests
{
    [Theory]
    [InlineData("你好 (nǐ hǎo)", "你好")]
    [InlineData("你好（nǐ hǎo）", "你好")]
    [InlineData("你好 [nǐ hǎo]", "你好")]
    [InlineData("nǐ hǎo 你好", "你好")]
    [InlineData("ni3 hao3 你好", "你好")]
    [InlineData("nǐ hǎo / ní hǎo 你好", "你好")]
    [InlineData("谢谢/多谢 (xièxie)", "谢谢, 多谢")]
    [InlineData("你好 [nǐ hǎo]；您好", "你好, 您好")]
    [InlineData("你好 (你们好)", "你好 你们好")]
    [InlineData("绿 (lǜ)", "绿")]
    public void ChineseWithoutPinyin(string text, string spoken) => Assert.Equal(spoken, SpeechText.Speakable(text, Lang.Zh));

    [Fact]
    public void OtherTextsStayAsTheyAre()
    {
        Assert.Equal("nǐ hǎo", SpeechText.Speakable("nǐ hǎo", Lang.Zh));
        Assert.Equal("你好 nǐ hǎo", SpeechText.Speakable("你好 (nǐ hǎo)", Lang.Other));
        Assert.Equal("beau, belle", SpeechText.Speakable("beau/belle", Lang.Fr));
        Assert.Equal("sich freuen", SpeechText.Speakable("(sich) freuen", Lang.De));
        Assert.Equal("الكتاب كتب", SpeechText.Speakable("الكتاب (كتب)", Lang.Ar));
        Assert.Equal("beau, belle", SpeechText.Speakable("beau/belle"));
        Assert.Equal("le chien, la chienne", SpeechText.Speakable("le chien ; la chienne", Lang.Fr));
        Assert.Equal("to go, went, gone", SpeechText.Speakable("  to go /went/ gone  ", Lang.En));
        Assert.Equal("", SpeechText.Speakable("  ( ) ", Lang.Fr));
    }

    [Fact]
    public void SamplesAreReadAsWritten() =>
        Assert.Equal("你好！今天我们学习新词。", SpeechText.Speakable("你好！今天我们学习新词。", Lang.Zh));

    [Fact]
    public void CantoneseTags()
    {
        foreach (var tag in new[] { "zh-HK", "zh_HK", "zh-Hant-HK", "zh-MO", "yue", "yue-Hant-HK", "zh-yue" })
            Assert.True(SpeechText.IsCantonese(tag), tag);
        foreach (var tag in new[] { "zh-CN", "zh-TW", "zh-Hans-CN", "zh", "zh-Hant-TW", "de-CH" })
            Assert.False(SpeechText.IsCantonese(tag), tag);
    }

    [Fact]
    public void LanguageTags()
    {
        Assert.Equal("zh-CN", SpeechText.LanguageTag(Lang.Zh));
        Assert.Equal("ar", SpeechText.LanguageTag(Lang.Ar));
        Assert.Equal("de-CH", SpeechText.LanguageTag(Lang.De));
        Assert.Null(SpeechText.LanguageTag(Lang.Other));
    }

    // A typical Windows 11 with a few extra voices: OneCore voices are Enhanced, desktop SAPI voices Standard.
    static readonly VoiceInfo[] Installed =
    [
        new("HKLM\\Speech\\Voices\\TTS_MS_DE-DE_HEDDA_11.0", "Microsoft Hedda", "de-DE"),
        new("HKLM\\Speech_OneCore\\Voices\\MSTTS_V110_deDE_KatjaM", "Microsoft Katja", "de-DE", VoiceQuality.Enhanced),
        new("HKLM\\Speech_OneCore\\Voices\\MSTTS_V110_deCH_KarstenM", "Microsoft Karsten", "de-CH", VoiceQuality.Enhanced),
        new("HKLM\\Speech_OneCore\\Voices\\MSTTS_V110_frCA_CarolineM", "Microsoft Caroline", "fr-CA", VoiceQuality.Enhanced),
        new("HKLM\\Speech_OneCore\\Voices\\MSTTS_V110_frFR_JulieM", "Microsoft Julie", "fr-FR", VoiceQuality.Enhanced),
        new("HKLM\\Speech_OneCore\\Voices\\MSTTS_V110_enUS_ZiraM", "Microsoft Zira", "en-US", VoiceQuality.Enhanced),
        new("HKLM\\Speech_OneCore\\Voices\\MSTTS_V110_enGB_HazelM", "Microsoft Hazel", "en-GB", VoiceQuality.Enhanced),
        new("HKLM\\Speech_OneCore\\Voices\\MSTTS_V110_zhHK_TracyM", "Microsoft Tracy", "zh-HK", VoiceQuality.Enhanced),
        new("HKLM\\Speech_OneCore\\Voices\\MSTTS_V110_zhTW_HanHanM", "Microsoft Hanhan", "zh-TW", VoiceQuality.Enhanced),
    ];

    [Fact]
    public void BestVoiceByRegion()
    {
        Assert.Equal("Microsoft Karsten", SpeechText.VoiceFor(Lang.De, Installed, null)?.Name);
        Assert.Equal("Microsoft Julie", SpeechText.VoiceFor(Lang.Fr, Installed, null)?.Name);
        Assert.Equal("Microsoft Hazel", SpeechText.VoiceFor(Lang.En, Installed, null)?.Name);
        Assert.Null(SpeechText.VoiceFor(Lang.It, Installed, null));
        Assert.Null(SpeechText.VoiceFor(Lang.Other, Installed, null));
    }

    [Fact]
    public void SwissGermanFallsBackToGermanyGerman()
    {
        var voices = Installed.Where(v => v.Language != "de-CH").ToList();
        // de-DE gets a bonus for de-CH; the OneCore voice beats the desktop one.
        Assert.Equal("Microsoft Katja", SpeechText.VoiceFor(Lang.De, voices, null)?.Name);
        var austria = new VoiceInfo("onecore-deAT", "Microsoft Michael", "de-AT", VoiceQuality.Enhanced);
        Assert.Equal("Microsoft Katja", SpeechText.VoiceFor(Lang.De, [.. voices, austria], null)?.Name);
    }

    [Fact]
    public void ChineseNeverSpeaksWithACantoneseVoice()
    {
        Assert.Equal("Microsoft Hanhan", SpeechText.VoiceFor(Lang.Zh, Installed, null)?.Name);
        var onlyCantonese = Installed.Where(v => v.Language == "zh-HK").ToList();
        Assert.Null(SpeechText.VoiceFor(Lang.Zh, onlyCantonese, null));
        Assert.True(SpeechText.Score(onlyCantonese[0], "zh-CN") < 0);
        // Even when chosen in the settings.
        Assert.Equal("Microsoft Hanhan", SpeechText.VoiceFor(Lang.Zh, Installed, onlyCantonese[0].Id)?.Name);
    }

    [Fact]
    public void ChosenVoiceWinsWhileInstalled()
    {
        var hedda = Installed[0];
        Assert.Equal(hedda, SpeechText.VoiceFor(Lang.De, Installed, hedda.Id));
        // Gone, or of another language: automatic.
        Assert.Equal("Microsoft Karsten", SpeechText.VoiceFor(Lang.De, Installed, "removed-voice")?.Name);
        Assert.Equal("Microsoft Karsten", SpeechText.VoiceFor(Lang.De, Installed, Installed[4].Id)?.Name);
    }

    [Fact]
    public void RankedBestFirst()
    {
        var german = SpeechText.Ranked(Lang.De, Installed).Select(v => v.Name).ToList();
        Assert.Equal(["Microsoft Karsten", "Microsoft Katja", "Microsoft Hedda"], german);
        Assert.Equal(["Microsoft Julie", "Microsoft Caroline"], SpeechText.Ranked(Lang.Fr, Installed).Select(v => v.Name));
        Assert.Empty(SpeechText.Ranked(Lang.Other, Installed));
    }

    [Fact]
    public void TiesGoToTheFirstId()
    {
        VoiceInfo a = new("b-voice", "B", "it-IT"), b = new("a-voice", "A", "it-IT");
        Assert.Equal(b, SpeechText.BestVoice("it-IT", [a, b]));
        Assert.Equal(b, SpeechText.BestVoice("it-IT", [b, a]));
    }

    [Fact]
    public void NoveltyVoicesComeLast()
    {
        VoiceInfo odd = new("com.apple.speech.synthesis.voice.Novelty.Bells", "Bells", "en-GB"), plain = new("x", "Plain", "en-GB");
        // Same language: the novelty voice scores 100 - 40.
        Assert.Equal(plain, SpeechText.BestVoice("en-GB", [odd, plain]));
    }

    [Fact]
    public void DisplayNames()
    {
        Assert.Equal("Microsoft Karsten (Deutsch, Schweiz)", SpeechText.DisplayName(Installed[2]));
        Assert.Equal("Microsoft Hazel (Englisch, Vereinigtes Königreich)", SpeechText.DisplayName(Installed[6]));
        Assert.Equal("Microsoft Hoda (Arabisch, Ägypten)", SpeechText.DisplayName(new("x", "Microsoft Hoda", "ar-EG")));
        Assert.Equal("Voice (Arabisch)", SpeechText.DisplayName(new("x", "Voice", "ar")));
        Assert.Equal("Anna (Deutsch, Deutschland) – Premium", SpeechText.DisplayName(new("x", "Anna", "de-DE", VoiceQuality.Premium)));
    }

    [Fact]
    public void SlowerRate()
    {
        Assert.Equal(-1, SpeechText.SapiRate(0));
        Assert.Equal(2, SpeechText.SapiRate(3));
        Assert.Equal(-10, SpeechText.SapiRate(-10));
        Assert.Equal(0, SpeechText.SapiRate(0, 1));
        Assert.Equal(10, SpeechText.SapiRate(0, 3));
    }
}
