using System.Globalization;
using System.Text;

namespace Wortschatz.Core;

/// <summary>A written question as the synonym check sees it.</summary>
public sealed record SynonymQuery(string Prompt, string Expected, Lang PromptLang, Lang AnswerLang);

/// <summary>
/// Port of ExtendedSynonyms.swift: the pure part of accepting synonyms that are not in the set.
/// The Mac app asks Apple's on-device language model for translations; Windows has no such model
/// yet, so the app passes no <c>extraAnswers</c>. The functions are here so a future model (or a
/// dictionary) can plug in exactly like on the Mac.
/// </summary>
public static class ExtendedSynonyms
{
    public static readonly IReadOnlyDictionary<Lang, string> ModelLanguageNames = new Dictionary<Lang, string>
    {
        [Lang.De] = "German", [Lang.Fr] = "French", [Lang.En] = "English", [Lang.Es] = "Spanish", [Lang.It] = "Italian", [Lang.Zh] = "Chinese",
    };

    const int MaxAnswerLength = 60;
    const int MaxAnswerWords = 5;
    const int MaxTranslations = 8;

    public static bool Supports(SynonymQuery q) =>
        q.PromptLang != q.AnswerLang && ModelLanguageNames.ContainsKey(q.PromptLang) && ModelLanguageNames.ContainsKey(q.AnswerLang)
        && HasLetters(q.Prompt) && HasLetters(q.Expected);

    public static string? TranslationRequest(string text, Lang from, Lang to)
    {
        if (!ModelLanguageNames.TryGetValue(from, out var source) || !ModelLanguageNames.TryGetValue(to, out var target)) return null;
        var quoted = TextNormalizer.NormalizeBasic(text).Replace("\"", "'");
        return $"Translate the {source} word or phrase \"{quoted}\" into {target}.";
    }

    public static bool WorthChecking(string given, GradeResult result, SynonymQuery query, Card? card, IReadOnlyList<Card> cards, AskSide ask)
    {
        if (result.Correct || result.Hint is not null || !Supports(query)) return false;
        var text = JSCompat.Trim(given);
        if (!HasLetters(text) || new StringInfo(text).LengthInTextElements > MaxAnswerLength
            || text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length > MaxAnswerWords) return false;
        if (AlternativeKeys(query.Prompt, query.PromptLang).Contains(LooseKey(text, query.PromptLang))) return false;
        if (card is not null && Synonyms.IsAnswerOfOtherCard(text, card, cards, ask, query.AnswerLang)) return false;
        return true;
    }

    public static List<string> CleanTranslations(IEnumerable<string> raw, Lang lang)
    {
        var output = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in raw)
        {
            foreach (var alt in Grading.SplitAlternatives(item, lang))
            {
                var text = JSCompat.Trim(StripBracketed(alt)).Trim('"', '\'', '«', '»', '“', '”', '„', '.', ' ', '\t');
                if (!HasLetters(text) || new StringInfo(text).LengthInTextElements > MaxAnswerLength) continue;
                var key = LooseKey(text, lang);
                if (key.Length == 0 || !seen.Add(key)) continue;
                output.Add(text);
                if (output.Count == MaxTranslations) return output;
            }
        }
        return output;
    }

    public static string? MatchingTranslation(string given, IEnumerable<string> translations, Tolerance tolerance, Lang lang) =>
        translations.FirstOrDefault(t => Grading.Grade(given, t, tolerance, lang).Correct);

    public static bool ConfirmsPrompt(IReadOnlyList<string> backTranslations, string prompt, Lang lang) =>
        backTranslations.Count > 0 && AlternativeKeys(prompt, lang).Contains(LooseKey(backTranslations[0], lang));

    /// <summary>Comparison key: lower case, no accents, ss for ß, no punctuation or bracketed notes, no leading article.</summary>
    public static string LooseKey(string text, Lang? lang)
    {
        var t = TextNormalizer.StripDiacritics(JSCompat.Lower(StripBracketed(TextNormalizer.FoldScripts(TextNormalizer.NormalizeBasic(text)))));
        t = t.Replace("ß", "ss").Replace("œ", "oe").Replace("æ", "ae");
        var prefix = ArticlePrefixes(lang).FirstOrDefault(p => t.StartsWith(p, StringComparison.Ordinal) && t.Length > p.Length);
        if (prefix is not null) t = t[prefix.Length..];
        var sb = new StringBuilder();
        bool space = false;
        foreach (var u in JSCompat.Scalars(t))
        {
            if (TextNormalizer.IsLetterScalar(u) || TextNormalizer.IsNumberScalar(u) || (TextNormalizer.IsMark(u) && sb.Length > 0 && !space))
            {
                if (space && sb.Length > 0) sb.Append(' ');
                space = false;
                sb.AppendScalar(u);
            }
            else if (JSCompat.IsWhitespace(u) || u == '-') space = true;
        }
        return sb.ToString();
    }

    internal static List<string> ArticlePrefixes(Lang? lang)
    {
        var langs = lang is { } l ? [l] : Grading.ARTICLES.Keys.ToArray();
        var prefixes = new HashSet<string>(StringComparer.Ordinal);
        foreach (var l2 in langs)
        {
            foreach (var article in Grading.ARTICLES.GetValueOrDefault(l2) ?? [])
            {
                bool glued = article.EndsWith('\'') || Grading.GLUED_ARTICLES.Contains(article);
                prefixes.Add(glued ? article : article + " ");
            }
            foreach (var pronoun in Grading.REFLEXIVES.GetValueOrDefault(l2) ?? [])
                if (pronoun.EndsWith(' ') || pronoun.EndsWith('\'')) prefixes.Add(pronoun);
        }
        return prefixes.OrderByDescending(p => p.Length).ThenBy(p => p, StringComparer.Ordinal).ToList();
    }

    internal static HashSet<string> AlternativeKeys(string text, Lang? lang)
    {
        var keys = new HashSet<string>(StringComparer.Ordinal) { LooseKey(text, lang) };
        foreach (var alt in Grading.SplitAlternatives(text, lang)) keys.Add(LooseKey(alt, lang));
        keys.Remove("");
        return keys;
    }

    internal static bool HasLetters(string text) => JSCompat.Scalars(text).Any(TextNormalizer.IsLetterScalar);

    /// <summary><paramref name="text"/> without "(…)" and "[…]" notes.</summary>
    internal static string StripBracketed(string text)
    {
        var sb = new StringBuilder(text.Length);
        int depth = 0;
        foreach (char ch in text)
        {
            switch (ch)
            {
                case '(' or '[': depth++; break;
                case ')' or ']': depth = Math.Max(0, depth - 1); break;
                default: if (depth == 0) sb.Append(ch); break;
            }
        }
        return sb.ToString();
    }
}
