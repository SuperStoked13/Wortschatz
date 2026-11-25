using System.Text.RegularExpressions;

namespace Wortschatz.Core;

/// <summary>How good an installed voice sounds (Mac: SpeechService.Voice.Quality). Windows: the OneCore voices are
/// <see cref="Enhanced"/>, the older desktop SAPI voices <see cref="Standard"/>.</summary>
public enum VoiceQuality { Standard, Enhanced, Premium }

/// <summary>One installed voice: Id identifies it for the settings, Language is its BCP 47 tag ("de-CH").</summary>
public sealed record VoiceInfo(string Id, string Name, string Language, VoiceQuality Quality = VoiceQuality.Standard, bool IsNovelty = false);

/// <summary>
/// The platform-free part of read-aloud (Mac: the pure helpers of SpeechService.swift, a port of src/lib/speech.js):
/// vocabulary notation made speakable ("beau/belle" → "beau, belle", Chinese without its pinyin), the best installed
/// voice per language (fr-FR, de-CH falling back to de-DE, en-GB, es-ES, it-IT, ar, zh-CN but never a Cantonese voice)
/// and the slightly slower rate. The Windows app's SpeechService feeds it the SAPI voices.
/// </summary>
public static class SpeechText
{
    /// <summary>Like the web app (0.92 × the normal rate): vocabulary is easier to follow a little slower.</summary>
    public const double RateFactor = 0.92;

    /// <summary>The language to speak in (<c>LANGS[lang].bcp47</c>): fr-FR, de-CH, en-GB, es-ES, it-IT, ar, zh-CN; null for Other.</summary>
    public static string? LanguageTag(Lang lang) =>
        Labels.LANGS.TryGetValue(lang, out var info) && info.Bcp47.Length > 0 ? info.Bcp47 : null;

    // Latin letters (the ranges of the Latin script: Basic Latin, Latin-1, Extended A/B, IPA, Extended Additional,
    // Extended C/D/E, ligatures, full width) – .NET has no \p{Script=Latin}.
    const string Latin = "A-Za-zªºÀ-ÖØ-öø-ʯḀ-ỿⱠ-ⱿꜢ-ꟿꬰ-ꭤﬀ-ﬆＡ-Ｚａ-ｚ";

    static readonly Regex BracketedPart = new(@"[(（\[［【][^()（）\[\]［］【】]*[)）\]］】]");
    static readonly Regex PinyinWord = new($@"[{Latin}][{Latin}\p{{M}}'’]*[0-5]?");
    static readonly Regex Brackets = new(@"[()\[\]{}（）［］【】]");
    static readonly Regex Slash = new(@"\s*[/／]\s*");
    static readonly Regex Semicolon = new(@"\s*[;；]\s*");
    static readonly Regex Spaces = new(@"\s+");
    static readonly Regex Commas = new(@"\s*,(\s*,)*\s*");
    static readonly Regex EdgeCommas = new(@"^[,\s]+|[,\s]+$");
    static readonly Regex CantoneseTag = new(@"^(yue|zh-yue|zh-(hant-)?(hk|mo))(-|$)");

    /// <summary>
    /// Vocabulary notation read naturally (speech.js <c>speakable</c>): brackets dropped, "/" and ";" become pauses
    /// ("beau/belle" → "beau, belle"), whitespace collapsed. Chinese with characters reads only the characters: the
    /// pinyin beside them (in brackets or not) is left out, «你好 (nǐ hǎo)» → «你好».
    /// </summary>
    public static string Speakable(string text, Lang? lang = null)
    {
        var s = text;
        bool chinese = lang == Lang.Zh && TextNormalizer.HasHan(s);
        if (chinese)
        {
            // A bracketed part (half or full width) without characters, and a run of Latin letters with its tone number.
            s = BracketedPart.Replace(s, m => TextNormalizer.HasHan(m.Value) ? m.Value : " ");
            s = PinyinWord.Replace(s, " ");
        }
        s = Brackets.Replace(s, " ");
        s = Slash.Replace(s, ", ");
        s = Semicolon.Replace(s, ", ");
        s = Spaces.Replace(s, " ").Trim();
        if (!chinese) return s;
        // Separators the pinyin left behind («nǐ hǎo / ní hǎo 你好»).
        s = Commas.Replace(s, ", ");
        return EdgeCommas.Replace(s, "");
    }

    static string Normalized(string tag) => tag.Replace('_', '-').ToLowerInvariant();

    static string Primary(string normalizedTag) => normalizedTag.Split('-')[0];

    /// <summary>Cantonese voices (Hong Kong, Macau, yue) share the primary tag zh but cannot read Mandarin.</summary>
    public static bool IsCantonese(string tag) => CantoneseTag.IsMatch(Normalized(tag));

    /// <summary>
    /// Port of <c>scoreVoice</c>: the exact language beats the same language from another region (Swiss German is rare,
    /// so Germany German gets a bonus for de-CH); premium and enhanced voices beat standard ones; novelty voices come
    /// last; Cantonese voices never read Chinese. Negative: the voice does not speak the language.
    /// </summary>
    public static int Score(VoiceInfo voice, string wanted)
    {
        var wantedTag = Normalized(wanted);
        var tag = Normalized(voice.Language);
        var primary = Primary(wantedTag);
        if (primary == "zh" && IsCantonese(tag) && !IsCantonese(wantedTag)) return -1;
        int score;
        if (tag == wantedTag) score = 100;
        else if (Primary(tag) == primary) score = 50;
        else return -1;
        if (wantedTag == "de-ch" && tag == "de-de") score += 20;
        score += voice.Quality switch
        {
            VoiceQuality.Premium => 30,
            VoiceQuality.Enhanced => 20,
            _ => 0,
        };
        var id = voice.Id.ToLowerInvariant();
        if (voice.IsNovelty || id.Contains("eloquence") || id.Contains("novelty")) score -= 40;
        return score;
    }

    /// <summary>The best voice for a BCP 47 tag, null when no installed voice speaks the language. Ties go to the
    /// alphabetically first id, so the choice is stable.</summary>
    public static VoiceInfo? BestVoice(string wanted, IEnumerable<VoiceInfo> voices)
    {
        VoiceInfo? best = null;
        int bestScore = -1;
        foreach (var voice in voices)
        {
            int score = Score(voice, wanted);
            if (score < 0) continue;
            if (best is not null && (bestScore > score || (bestScore == score && string.CompareOrdinal(best.Id, voice.Id) <= 0))) continue;
            best = voice;
            bestScore = score;
        }
        return best;
    }

    /// <summary>The installed voices that fit lang, best first (the voice picker of the settings).</summary>
    public static List<VoiceInfo> Ranked(Lang lang, IEnumerable<VoiceInfo> voices)
    {
        if (LanguageTag(lang) is not { } tag) return [];
        return voices.Select(v => (Voice: v, Score: Score(v, tag)))
            .Where(x => x.Score >= 0)
            .OrderByDescending(x => x.Score)
            .ThenBy(x => x.Voice.Name, StringComparer.Ordinal)
            .Select(x => x.Voice)
            .ToList();
    }

    /// <summary>
    /// The voice used for lang: the chosen one (by id) if it is still installed and fits the language, else the best
    /// match; null when none speaks the language (and for Other).
    /// </summary>
    public static VoiceInfo? VoiceFor(Lang lang, IReadOnlyList<VoiceInfo> voices, string? preferredId)
    {
        if (LanguageTag(lang) is not { } tag) return null;
        if (preferredId is not null && voices.FirstOrDefault(v => v.Id == preferredId) is { } chosen && Score(chosen, tag) >= 0) return chosen;
        return BestVoice(tag, voices);
    }

    /// <summary>
    /// SAPI's rate (−10 … 10, where ±10 is three times faster or slower) for factor × the user's rate: 0.92 is one step
    /// slower.
    /// </summary>
    public static int SapiRate(int baseRate, double factor = RateFactor) =>
        Math.Clamp((int)Math.Round(baseRate + 10 * Math.Log(factor) / Math.Log(3), MidpointRounding.AwayFromZero), -10, 10);

    static readonly Dictionary<string, string> Regions = new(StringComparer.OrdinalIgnoreCase)
    {
        ["DE"] = "Deutschland", ["CH"] = "Schweiz", ["AT"] = "Österreich", ["LI"] = "Liechtenstein", ["LU"] = "Luxemburg",
        ["FR"] = "Frankreich", ["CA"] = "Kanada", ["BE"] = "Belgien", ["GB"] = "Vereinigtes Königreich", ["US"] = "Vereinigte Staaten",
        ["AU"] = "Australien", ["IE"] = "Irland", ["IN"] = "Indien", ["NZ"] = "Neuseeland", ["ZA"] = "Südafrika",
        ["ES"] = "Spanien", ["MX"] = "Mexiko", ["AR"] = "Argentinien", ["CO"] = "Kolumbien", ["IT"] = "Italien",
        ["SA"] = "Saudi-Arabien", ["EG"] = "Ägypten", ["AE"] = "Vereinigte Arabische Emirate", ["MA"] = "Marokko",
        ["CN"] = "China", ["TW"] = "Taiwan", ["HK"] = "Hongkong", ["MO"] = "Macau", ["SG"] = "Singapur",
    };

    /// <summary>A region's name in the app's language: German from the list above, English from .NET (Mac: the locale).</summary>
    static string RegionName(string region)
    {
        if (CoreText.Language == "en")
        {
            try { return new System.Globalization.RegionInfo(region).EnglishName; }
            catch (ArgumentException) { }
        }
        return Regions.TryGetValue(region, out var name) ? name : region.ToUpperInvariant();
    }

    /// <summary>"Microsoft Hedda (Deutsch, Deutschland)" (Mac: Voice.displayName, region names in the app's language).</summary>
    public static string DisplayName(VoiceInfo voice)
    {
        var parts = voice.Language.Replace('_', '-').Split('-');
        var language = LangOf(voice.Language) is { } lang ? Labels.LangName(lang) : parts[0];
        var region = parts.Skip(1).LastOrDefault(p => p.Length == 2 && p.All(char.IsLetter));
        var place = region is null ? language : $"{language}, {RegionName(region)}";
        var label = voice.Quality == VoiceQuality.Premium ? " – Premium" : "";
        return $"{voice.Name} ({place}){label}";
    }

    /// <summary>The app language of a BCP 47 tag (by its primary subtag), null for any other language.</summary>
    public static Lang? LangOf(string tag)
    {
        var primary = Primary(Normalized(tag));
        foreach (var (lang, info) in Labels.LANGS)
            if (info.Bcp47.Length > 0 && Primary(Normalized(info.Bcp47)) == primary) return lang;
        return null;
    }
}
