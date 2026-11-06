using System.Globalization;

namespace Wortschatz.Core;

// Port of WortschatzImport/VocabSpellChecker.swift. The Mac asks NSSpellChecker; here the platform's spell checker sits
// behind ISpellEngine (Windows: ISpellCheckerFactory, see the app's Services/WindowsSpellEngine.cs), and the vocab-list
// tuning is the same: abbreviations, acronyms and numbers are never typos, German follows Swiss spelling, suggestions are
// ranked by closeness, ignored words are remembered.

/// <summary>A word the spell checker does not know, with replacement suggestions (best first).</summary>
public sealed record SpellingIssue(string Word, int Start, int Length, IReadOnlyList<string> Suggestions)
{
    public string Id => $"{Start}:{Word}";
}

/// <summary>A platform spell checker for one language tag at a time ("fr-FR", "de-CH" …).</summary>
public interface ISpellEngine
{
    /// <summary>The engine's language for a set language (first supported candidate), or null without a dictionary.</summary>
    string? Language(IReadOnlyList<string> candidates);
    /// <summary>The misspelled ranges of <paramref name="text"/> (UTF-16 start and length), in order.</summary>
    IReadOnlyList<(int Start, int Length)> Check(string text, string language);
    /// <summary>Replacements for a misspelled word, best first.</summary>
    IReadOnlyList<string> Suggest(string word, string language);
}

/// <summary>Finds probable typos in vocabulary entries (Mac: VocabSpellChecker).</summary>
public sealed class VocabSpellChecker
{
    /// <summary>At most this many issues are reported per field.</summary>
    public const int MaxIssuesPerText = 6;

    readonly ISpellEngine? _engine;
    readonly HashSet<string> _ignored;
    readonly Action<IReadOnlyCollection<string>>? _saveIgnored;
    readonly Dictionary<string, IReadOnlyList<SpellingIssue>> _cache = new(StringComparer.Ordinal);
    readonly Dictionary<Lang, string?> _languages = [];

    /// <param name="engine">The platform spell checker (null: nothing is ever reported).</param>
    /// <param name="ignored">Ignored words ("lang:word", lowercased), e.g. from the preferences.</param>
    /// <param name="saveIgnored">Called with the whole list after "Ignorieren" or a reset.</param>
    public VocabSpellChecker(ISpellEngine? engine, IEnumerable<string>? ignored = null, Action<IReadOnlyCollection<string>>? saveIgnored = null)
    {
        _engine = engine;
        _ignored = new HashSet<string>(ignored ?? [], StringComparer.Ordinal);
        _saveIgnored = saveIgnored;
    }

    // MARK: Languages

    /// <summary>Dictionary candidates per set language (Swiss German first; no Chinese dictionary).</summary>
    public static IReadOnlyList<string> Candidates(Lang lang) => lang switch
    {
        Lang.Fr => ["fr-FR", "fr-CH", "fr"],
        Lang.De => ["de-CH", "de-DE", "de"],
        Lang.En => ["en-GB", "en-US", "en"],
        Lang.Es => ["es-ES", "es"],
        Lang.It => ["it-IT", "it"],
        Lang.Ar => ["ar-SA", "ar"],
        _ => [],
    };

    /// <summary>The spell checker's language for a set language, null when it has no dictionary.</summary>
    public string? Language(Lang lang)
    {
        if (_engine is null) return null;
        if (!_languages.TryGetValue(lang, out var language))
        {
            var candidates = Candidates(lang);
            language = candidates.Count == 0 ? null : _engine.Language(candidates);
            _languages[lang] = language;
        }
        return language;
    }

    public bool Supports(Lang lang) => Language(lang) is not null;

    // MARK: Checking

    /// <summary>The probable typos in <paramref name="text"/>, in order of appearance.</summary>
    public IReadOnlyList<SpellingIssue> Issues(string text, Lang lang)
    {
        if (Language(lang) is not { } language || JSCompat.Trim(text).Length == 0) return [];
        var key = $"{(int)lang}\u0001{text}";
        if (_cache.TryGetValue(key, out var cached)) return cached;

        var found = new List<SpellingIssue>();
        foreach (var (start, length) in _engine!.Check(text, language))
        {
            if (found.Count >= MaxIssuesPerText) break;
            if (start < 0 || length <= 0 || start + length > text.Length) continue;
            var word = text.Substring(start, length);
            if (ShouldSkip(word, start, length, text, lang)) continue;
            if (lang == Lang.De && SwissFormIsCorrect(word, language)) continue;
            found.Add(new SpellingIssue(word, start, length, Suggestions(word, language, lang)));
        }
        if (_cache.Count > 4000) _cache.Clear();
        _cache[key] = found;
        return found;
    }

    // MARK: Ignoring

    /// <summary>"Ignorieren": the word is not reported again (in any set).</summary>
    public void Ignore(string word, Lang lang)
    {
        _ignored.Add(IgnoreKey(word, lang));
        _saveIgnored?.Invoke(_ignored.OrderBy(k => k, StringComparer.Ordinal).ToList());
        _cache.Clear();
    }

    public bool IsIgnored(string word, Lang lang) => _ignored.Contains(IgnoreKey(word, lang));

    /// <summary>Forgets every ignored word.</summary>
    public void ResetIgnored()
    {
        _ignored.Clear();
        _saveIgnored?.Invoke([]);
        _cache.Clear();
    }

    static string IgnoreKey(string word, Lang lang) => $"{lang.ToJson().StringValue}:{word.ToLowerInvariant()}";

    // MARK: Filters

    /// <summary>Short forms that vocab lists use on purpose (compared lowercased, without dots).</summary>
    public static readonly IReadOnlySet<string> Abbreviations = new HashSet<string>(StringComparer.Ordinal)
    {
        "etw", "jd", "jdn", "jdm", "jds", "jmd", "jmdn", "jmdm", "jmds", "sth", "sb", "smb", "smth", "so", "sthg",
        "qc", "qch", "qqch", "qn", "qqn", "qqc", "zb", "usw", "bzw", "etc", "ca", "vgl", "ugs", "fam", "pl", "sg",
        "adj", "adv", "inf", "vb", "subst", "mask", "fem", "neutr", "od", "ua", "evtl", "bsp", "akk", "dat",
        "gen", "pers", "präs", "perf", "imp", "fut", "pp", "ppa", "ppp", "lat", "engl", "franz", "frz", "dt",
    };

    bool ShouldSkip(string word, int start, int length, string text, Lang lang)
    {
        if (IsIgnored(word, lang)) return true;
        int letters = word.Count(char.IsLetter);
        if (letters < 2) return true;
        if (word.Any(char.IsDigit)) return true;
        // Acronyms and abbreviations written in capitals (TGV, USA, CH).
        if (word == word.ToUpperInvariant() && word != word.ToLowerInvariant()) return true;
        var compact = word.ToLowerInvariant().Replace(".", "");
        if (Abbreviations.Contains(compact)) return true;
        // A short token directly followed by a period is an abbreviation (vgl., Bsp., qqch.).
        int end = start + length;
        if (end < text.Length && text[end] == '.' && letters <= 5) return true;
        return false;
    }

    /// <summary>Swiss spelling: "Strasse" is right when "Straße" is.</summary>
    bool SwissFormIsCorrect(string word, string language)
    {
        if (!word.Contains("ss", StringComparison.Ordinal) && !word.Contains("SS", StringComparison.Ordinal)) return false;
        var pieces = word.Split("ss");
        var variants = new HashSet<string>(StringComparer.Ordinal) { word.Replace("ss", "ß") };
        if (pieces.Length > 2)
        {
            // Each "ss" on its own (Schlussstrich, Fussballschuss …).
            for (int i = 1; i < pieces.Length; i++)
                variants.Add(string.Join("ss", pieces[..i]) + "ß" + string.Join("ss", pieces[i..]));
        }
        return variants.Any(v => IsCorrect(v, language));
    }

    bool IsCorrect(string word, string language) => _engine!.Check(word, language).Count == 0;

    // MARK: Suggestions

    IReadOnlyList<string> Suggestions(string word, string language, Lang lang)
    {
        IEnumerable<string> raw = _engine!.Suggest(word, language);
        if (lang == Lang.De) raw = raw.Select(s => s.Replace("ß", "ss").Replace("ẞ", "SS"));
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var unique = raw.Where(s => s.Length > 0 && s != word && seen.Add(s)).ToList();
        return Ranked(unique, word).Take(4).ToList();
    }

    /// <summary>
    /// Closest spelling first. Changing the capitalisation of the first letter counts as one more edit (and loses ties),
    /// so "mason" suggests "maçon"/"maison" before "Mason"; a different first letter loses ties too; remaining ties keep
    /// the spell checker's order.
    /// </summary>
    public static List<string> Ranked(IReadOnlyList<string> suggestions, string word)
    {
        var folded = Fold(word);
        bool firstIsUpper = word.Length > 0 && char.IsUpper(word[0]);
        var firstFolded = Fold(word.Length > 0 ? word[..1] : "");
        return suggestions
            .Select((s, index) =>
            {
                int caseChange = (s.Length > 0 && char.IsUpper(s[0])) != firstIsUpper ? 1 : 0;
                int cost = EditDistance(folded, Fold(s)) + caseChange;
                int firstLetter = Fold(s.Length > 0 ? s[..1] : "") == firstFolded ? 0 : 1;
                return (s, cost, caseChange, firstLetter, index);
            })
            .OrderBy(t => t.cost).ThenBy(t => t.caseChange).ThenBy(t => t.firstLetter).ThenBy(t => t.index)
            .Select(t => t.s).ToList();
    }

    public static string Fold(string s) => TextNormalizer.StripDiacritics(s.ToLowerInvariant());

    /// <summary>Optimal string alignment distance (adjacent swaps count as one edit), on text elements.</summary>
    public static int EditDistance(string a, string b)
    {
        var x = Elements(a);
        var y = Elements(b);
        if (x.Count == 0) return y.Count;
        if (y.Count == 0) return x.Count;
        var previous2 = new int[y.Count + 1];
        var previous = Enumerable.Range(0, y.Count + 1).ToArray();
        var current = new int[y.Count + 1];
        for (int i = 1; i <= x.Count; i++)
        {
            current[0] = i;
            for (int j = 1; j <= y.Count; j++)
            {
                int cost = x[i - 1] == y[j - 1] ? 0 : 1;
                int value = Math.Min(Math.Min(previous[j] + 1, current[j - 1] + 1), previous[j - 1] + cost);
                if (i > 1 && j > 1 && x[i - 1] == y[j - 2] && x[i - 2] == y[j - 1]) value = Math.Min(value, previous2[j - 2] + 1);
                current[j] = value;
            }
            (previous2, previous, current) = (previous, current, previous2);
        }
        return previous[y.Count];
    }

    static List<string> Elements(string s)
    {
        var list = new List<string>();
        var e = StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext()) list.Add((string)e.Current);
        return list;
    }
}
