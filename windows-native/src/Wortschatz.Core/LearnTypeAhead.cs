using System.Text;

namespace Wortschatz.Core;

// Port of LearnTypeAhead.swift: typing on a multiple-choice question. Instead of a digit or a click,
// the learner starts typing the answer ("la vo…") and the one option those letters start is
// highlighted, so Return chooses it; typed out ("la voiture"), it is chosen at once (TypeAhead.IsTypedOut,
// since 23.11.2026 like the Mac; not in typeahead.js). The letters must leave no doubt: an article alone never picks
// anything ("la" starts many words), at least TYPE_AHEAD_MIN_LETTERS letters after it are needed, and
// exactly one option may match. Case, accents and the kind of apostrophe do not matter; an option can
// also be started without its article ("voi" → la voiture) or at one of its alternatives ("laide" in
// "laid, laide"). Arabic: vowel marks, tatweel, hamza forms, ة/ه and ى/ي do not matter and «ال» is a
// glued article. Chinese: spaces do not matter and the pinyin of «你好 (nǐ hǎo)» starts it too («ni»).
//
// Written after src/core/typeahead.js (the web app's mirror of the Swift file), because C# strings
// are UTF-16 like JS: ranges are UTF-16 offsets [Start, End) – what Avalonia text runs need – where
// Swift has Character offsets. Matching is identical (a "character" = a code point plus the combining
// marks after it, like Swift's Character for these texts).

public static partial class LearnFlow
{
    /// <summary>The most characters kept while typing on a multiple-choice question.</summary>
    public const int TYPE_AHEAD_MAX = 80;
    /// <summary>Letters needed after the article before the typed letters pick an option.</summary>
    public const int TYPE_AHEAD_MIN_LETTERS = 2;

    /// <summary>The typed part of an option's text: UTF-16 offsets [Start, End).</summary>
    public readonly record struct TextRange(int Start, int End)
    {
        public int Length => End - Start;
    }

    /// <summary>What the letters typed on a multiple-choice question match.</summary>
    public sealed record TypeAhead
    {
        /// <summary>The option the letters pick (Return chooses it), null = none yet.</summary>
        public int? Selected { get; init; }
        /// <summary>The options the letters start, in order (empty while nothing is typed).</summary>
        public IReadOnlyList<int> Matching { get; init; } = [];
        /// <summary>The typed part of each matching option's text, for highlighting.</summary>
        public IReadOnlyDictionary<int, TextRange> Ranges { get; init; } = new Dictionary<int, TextRange>();
        /// <summary>Letters are typed.</summary>
        public bool IsActive { get; init; }
        /// <summary>Enough letters for a pick, should a single option match.</summary>
        public bool HasEnoughLetters { get; init; }
        /// <summary>
        /// The picked option is typed out: to its end or to the end of one of its alternatives ("le cerveau" of
        /// "le cerveau, les cerveaux"), and no other option matches. It is chosen without Return. Not before a note
        /// in brackets: "Aussenminister" may go on with "(in)".
        /// </summary>
        public bool IsTypedOut { get; init; }

        public static readonly TypeAhead None = new();

        public bool Equals(TypeAhead? other) =>
            other is not null && Selected == other.Selected && Matching.SequenceEqual(other.Matching) && IsActive == other.IsActive
            && HasEnoughLetters == other.HasEnoughLetters && IsTypedOut == other.IsTypedOut && Ranges.Count == other.Ranges.Count
            && Ranges.All(p => other.Ranges.TryGetValue(p.Key, out var r) && r == p.Value);

        public override int GetHashCode() => HashCode.Combine(Selected, Matching.Count, IsActive, HasEnoughLetters);
    }

    /// <summary>
    /// Which of <paramref name="choices"/> the letters <paramref name="typed"/> start, and the one they pick. <paramref name="lang"/> is the
    /// language of the options (its articles); null allows the articles of every language.
    /// (Swift: <c>typeAhead(_:choices:lang:)</c>; renamed because of the TypeAhead type.)
    /// </summary>
    public static TypeAhead TypeAheadOf(string typed, IReadOnlyList<string> choices, Lang? lang)
    {
        // Chinese: spaces do not count, in the letters typed and in the options.
        bool noSpaces = lang == Lang.Zh;
        var input = new TypeAheadText(typed, noSpaces);
        if (!input.Chars.Any(c => c != " ")) return TypeAhead.None;
        var prefixes = TypeAheadText.ArticlePrefixes(lang);

        // The letters after a leading article ("la vo" → "vo"); none for an article alone.
        int? contentStart = TypeAheadText.ArticleEnd(input.Chars, 0, prefixes);
        bool articleOnly = contentStart is null && TypeAheadText.IsArticle(input.Chars, prefixes);
        var content = articleOnly ? [] : input.Chars.Skip(contentStart ?? 0).ToList();
        int letters = content.Count(TypeAheadText.IsAlnum);

        var strong = new List<(int Index, TextRange Range, bool Complete, bool TypedOut)>();
        var weak = new List<(int Index, TextRange Range, bool Complete, bool TypedOut)>();
        for (int index = 0; index < choices.Count; index++)
        {
            var option = new TypeAheadText(choices[index], noSpaces);
            var starts = option.Starts(prefixes);
            // The whole input from the start of the option, an alternative or a word after an article.
            int? start = FirstOrNull(starts, s => TypeAheadText.StartsWithAt(option.Chars, s, input.Chars));
            if (start is { } st)
            {
                int end = st + input.Chars.Count;
                strong.Add((index, option.Range(st, input.Chars.Count), option.IsComplete(end), option.EndsWord(end)));
                continue;
            }
            // Another article than the option's ("le voi" for "la voiture"): the content alone.
            if (contentStart is not null && content.Count > 0
                && FirstOrNull(starts, s => TypeAheadText.StartsWithAt(option.Chars, s, content)) is { } s2)
            {
                int end = s2 + content.Count;
                weak.Add((index, option.Range(s2, content.Count), option.IsComplete(end), option.EndsWord(end)));
            }
        }
        // Options that match with the typed article win over those matching only after it.
        var matches = strong.Count > 0 ? strong : weak;
        var complete = matches.Where(m => m.Complete).ToList();
        bool enough = letters >= TYPE_AHEAD_MIN_LETTERS || (letters >= 1 && matches.Count == 1 && matches[0].Complete);

        int? selected = null;
        if (enough)
        {
            if (matches.Count == 1) selected = matches[0].Index;
            // "le pain" picks "le pain", not "le pain de mie".
            else if (complete.Count == 1) selected = complete[0].Index;
        }
        return new TypeAhead
        {
            Selected = selected,
            Matching = matches.Select(m => m.Index).ToList(),
            Ranges = matches.ToDictionary(m => m.Index, m => m.Range),
            IsActive = true,
            HasEnoughLetters = enough,
            IsTypedOut = selected is not null && matches.Count == 1 && matches[0].TypedOut,
        };
    }

    static int? FirstOrNull(List<int> list, Func<int, bool> predicate)
    {
        foreach (var x in list)
            if (predicate(x)) return x;
        return null;
    }

    /// <summary>
    /// The digit 0–9 a key types, ASCII or Arabic-Indic (٠–٩, ۰–۹: an Arabic keyboard chooses like 1–4
    /// and 0); null for anything else (typeahead.js <c>digitValue</c>).
    /// </summary>
    public static int? DigitValue(string text)
    {
        if (text.Length != 1) return null;
        int v = text[0];
        return v switch
        {
            >= 0x30 and <= 0x39 => v - 0x30,
            >= 0x660 and <= 0x669 => v - 0x660,
            >= 0x6F0 and <= 0x6F9 => v - 0x6F0,
            _ => null,
        };
    }
}

/// <summary>
/// A text folded for type-ahead comparison: lower case, no accents, one kind of apostrophe, single
/// spaces, no leading space, a trailing space kept ("la " means the article is done); no spaces between
/// two Han characters, none at all with noSpaces (Chinese). Each folded character is one code point (as
/// a string); Origin/OriginEnd map it to the UTF-16 range of the original character it came from.
/// </summary>
internal sealed class TypeAheadText
{
    public List<string> Chars { get; } = [];
    public List<int> Origin { get; } = [];
    public List<int> OriginEnd { get; } = [];

    public TypeAheadText(string text, bool noSpaces = false)
    {
        (int Start, int End)? pending = null; // the whitespace before the next character, once something came before it
        foreach (var (ch, start, end) in Characters(text))
        {
            if (IsWhitespace(ch))
            {
                if (Chars.Count > 0 && !noSpaces) pending = (start, end);
                continue;
            }
            var folded = Fold(ch);
            // Nothing to compare (tatweel, a lone mark): a space before it waits for the next character.
            if (folded.Length == 0) continue;
            if (pending is { } p)
            {
                if (!(Chars.Count > 0 && IsHan(Chars[^1]) && IsHan(folded)))
                {
                    Chars.Add(" ");
                    Origin.Add(p.Start);
                    OriginEnd.Add(p.End);
                }
                pending = null;
            }
            foreach (var f in JSCompat.CodePoints(folded))
            {
                Chars.Add(f);
                Origin.Add(start);
                OriginEnd.Add(end);
            }
        }
        if (pending is { } last)
        {
            Chars.Add(" ");
            Origin.Add(last.Start);
            OriginEnd.Add(last.End);
        }
    }

    /// <summary>
    /// The "characters" of a text as the Mac counts them (Swift Character): a code point and the combining
    /// marks after it (leading marks form one character), with their UTF-16 range.
    /// </summary>
    static IEnumerable<(string Text, int Start, int End)> Characters(string text)
    {
        int i = 0;
        while (i < text.Length)
        {
            int start = i;
            int u = JSCompat.CodePointAt(text, i);
            i += u > 0xFFFF ? 2 : 1;
            while (i < text.Length)
            {
                int v = JSCompat.CodePointAt(text, i);
                if (!TextNormalizer.IsMark(v)) break;
                i += v > 0xFFFF ? 2 : 1;
            }
            yield return (text[start..i], start, i);
        }
    }

    /// <summary>/^[\s\u0085]+$/u</summary>
    static bool IsWhitespace(string ch) => ch.Length > 0 && ch.All(c => JSCompat.IsWhitespace(c) || c == '\u0085');

    static readonly HashSet<string> Apostrophes = new(StringComparer.Ordinal) { "’", "‘", "`", "´", "ʼ", "′" };

    /// <summary>
    /// One character folded for comparison (typeahead.js <c>foldChar</c>): lower case, no accents (NFD, marks
    /// dropped), one kind of apostrophe, ß → ss. Arabic: the script folds, hamza goes with the accents
    /// (أ → ا), ٱ → ا, ة → ه, ى → ي.
    /// </summary>
    public static string Fold(string ch)
    {
        if (Apostrophes.Contains(ch)) return "'";
        var lower = JSCompat.Nfd(JSCompat.Lower(TextNormalizer.FoldScripts(ch)));
        var sb = new StringBuilder(lower.Length);
        foreach (int u in JSCompat.Scalars(lower))
        {
            if (TextNormalizer.IsMark(u)) continue;
            switch (u)
            {
                case 0xDF: sb.Append("ss"); break; // ß
                case 0x671: sb.Append('ا'); break; // ٱ → ا
                case 0x629: sb.Append('ه'); break; // ة → ه
                case 0x649: sb.Append('ي'); break; // ى → ي
                default: sb.AppendScalar(u); break;
            }
        }
        return sb.ToString();
    }

    /// <summary>A Han character (Chinese).</summary>
    public static bool IsHan(string ch) => ch.Length > 0 && TextNormalizer.HasHan(ch);

    /// <summary>/^[\p{L}\p{N}]$/u for one folded character.</summary>
    public static bool IsAlnum(string ch)
    {
        int u = JSCompat.CodePointAt(ch, 0);
        return TextNormalizer.IsLetterScalar(u) || TextNormalizer.IsNumberScalar(u);
    }

    static bool IsLatinLower(string ch) => ch.Length == 1 && ch[0] is >= 'a' and <= 'z';

    public static bool StartsWithAt(List<string> chars, int at, List<string> seq)
    {
        if (at + seq.Count > chars.Count) return false;
        for (int i = 0; i < seq.Count; i++)
            if (chars[at + i] != seq[i]) return false;
        return true;
    }

    /// <summary>The original UTF-16 range of <paramref name="length"/> folded characters from <paramref name="start"/> ([0, 0) for none).</summary>
    public LearnFlow.TextRange Range(int start, int length)
    {
        if (!(length > 0) || start >= Origin.Count) return new(0, 0);
        int end = Math.Min(start + length, Origin.Count) - 1;
        return new(Origin[start], OriginEnd[end]);
    }

    /// <summary>Whether the option ends at folded position end (or an alternative or a note in brackets starts there).</summary>
    public bool IsComplete(int end)
    {
        int i = end;
        while (i < Chars.Count && Chars[i] == " ") i++;
        return i >= Chars.Count || Chars[i] is "," or ";" or "/" or "(";
    }

    /// <summary>Whether the option or one of its alternatives ends at folded position end (a note in brackets does not end it: "Aussenminister(in)").</summary>
    public bool EndsWord(int end)
    {
        int i = end;
        while (i < Chars.Count && Chars[i] == " ") i++;
        return i >= Chars.Count || Chars[i] is "," or ";" or "/";
    }

    /// <summary>
    /// Where typing may start: the option itself and each alternative ("laid, laide"), and the word after
    /// their leading article or pronoun ("la voiture" → "voiture"). An option with Chinese characters also
    /// starts after a bracket and where pinyin follows the characters.
    /// </summary>
    public List<int> Starts(List<List<string>> prefixes)
    {
        var alternatives = new List<int> { 0 };
        bool chinese = Chars.Any(IsHan);
        bool lastHan = false; // the last letter before i is a Han character
        for (int i = 0; i < Chars.Count; i++)
        {
            var ch = Chars[i];
            bool pinyin = chinese && lastHan && IsLatinLower(ch);
            if (ch != " ") lastHan = IsHan(ch);
            if (pinyin && alternatives[^1] != i) alternatives.Add(i);
            if (!(ch is "," or ";" or "/") && !(chinese && ch is "(" or "[")) continue;
            int j = i + 1;
            while (j < Chars.Count && Chars[j] == " ") j++;
            if (j < Chars.Count) alternatives.Add(j);
        }
        var all = new List<int>();
        foreach (int start in alternatives)
        {
            all.Add(start);
            if (ArticleEnd(Chars, start, prefixes) is { } end) all.Add(end);
        }
        return all;
    }

    /// <summary>The position after a leading article or pronoun at start ("la " or "l'"), null if none starts there or nothing follows.</summary>
    public static int? ArticleEnd(List<string> chars, int start, List<List<string>> prefixes)
    {
        foreach (var prefix in prefixes)
            if (StartsWithAt(chars, start, prefix) && chars.Count > start + prefix.Count) return start + prefix.Count;
        return null;
    }

    /// <summary>Whether the letters are only an article or pronoun, possibly unfinished by its space ("la", "la ", "l'").</summary>
    public static bool IsArticle(List<string> chars, List<List<string>> prefixes)
    {
        int n = chars.Count;
        while (n > 0 && chars[n - 1] == " ") n--;
        var trimmed = chars.Take(n).ToList();
        return prefixes.Any(p => p.SequenceEqual(trimmed) || (p.Count > 0 && p[^1] == " " && p.Take(p.Count - 1).SequenceEqual(trimmed)));
    }

    static readonly Dictionary<string, List<List<string>>> PrefixCache = new(StringComparer.Ordinal);
    static readonly Lock PrefixLock = new();

    /// <summary>ExtendedSynonyms.ArticlePrefixes, folded.</summary>
    public static List<List<string>> ArticlePrefixes(Lang? lang)
    {
        var key = lang?.Raw() ?? "\0";
        lock (PrefixLock)
        {
            if (!PrefixCache.TryGetValue(key, out var list))
                PrefixCache[key] = list = ExtendedSynonyms.ArticlePrefixes(lang).Select(p => new TypeAheadText(p).Chars).ToList();
            return list;
        }
    }
}
