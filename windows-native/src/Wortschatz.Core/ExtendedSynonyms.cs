using System.Text;

namespace Wortschatz.Core;

/// <summary>A written question as the synonym check sees it.</summary>
public sealed record SynonymQuery(string Prompt, string Expected, Lang PromptLang, Lang AnswerLang);

/// <summary>
/// Port of ExtendedSynonyms.swift: the pure part of accepting synonyms that are not in the set.
/// The Mac app asks Apple's on-device language model for translations; Windows and Android have no
/// such model and take the expected answer's synonyms from built-in thesauri instead
/// (ExtendedSynonyms.Thesaurus.cs, SynonymLexicon). The Swift file's language-model part (translation
/// request, cleaning and matching the model's answers) has no counterpart here.
/// </summary>
public static partial class ExtendedSynonyms
{
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

    /// <summary>
    /// The articles and reflexive pronouns <see cref="LooseKey"/> drops, longest first. Worked out once per language:
    /// LooseKey runs for every card of the set after a wrong answer (is it another card's answer?), and building the
    /// list every time cost more than the rest of the key.
    /// </summary>
    internal static IReadOnlyList<string> ArticlePrefixes(Lang? lang)
    {
        var key = lang?.Raw() ?? "\0";
        lock (PrefixLock)
        {
            if (!PrefixCache.TryGetValue(key, out var list)) PrefixCache[key] = list = BuildArticlePrefixes(lang);
            return list;
        }
    }

    static readonly Dictionary<string, IReadOnlyList<string>> PrefixCache = new(StringComparer.Ordinal);
    static readonly Lock PrefixLock = new();

    static IReadOnlyList<string> BuildArticlePrefixes(Lang? lang)
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
        return prefixes.OrderByDescending(p => p.Length).ThenBy(p => p, StringComparer.Ordinal).ToArray();
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
