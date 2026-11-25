using System.Collections.Concurrent;
using System.Globalization;
using System.Text;

namespace Wortschatz.Core;

/// <summary>
/// Syllable hyphenation with Frank Liang's algorithm (the one TeX uses) and the TeX patterns of hyph-utf8
/// (<c>Hyphenation/*.txt</c>, sources and licences in <c>Hyphenation/README.md</c>). Only for showing a word that is
/// wider than its line (the phone's prompts and flashcards): «Geschwindigkeits-» / «begrenzung» instead of a break
/// somewhere inside the word. No Mac counterpart (its windows are wide enough).
/// </summary>
public sealed class Hyphenator
{
    readonly Dictionary<string, byte[]> _patterns = new(StringComparer.Ordinal);
    readonly Dictionary<string, int[]> _exceptions = new(StringComparer.Ordinal);
    readonly int _maxPattern;
    readonly int _leftMin, _rightMin;

    /// <summary>Patterns as in TeX: letters with the priority digits between them, «.» marks a word edge.</summary>
    public Hyphenator(string patterns, string? exceptions = null, int leftMin = 2, int rightMin = 3)
    {
        _leftMin = leftMin;
        _rightMin = rightMin;
        foreach (var pattern in patterns.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            var letters = new StringBuilder();
            var values = new List<byte> { 0 };
            foreach (var c in pattern)
            {
                if (c is >= '0' and <= '9') values[^1] = (byte)(c - '0');
                else
                {
                    letters.Append(Normalize(c));
                    values.Add(0);
                }
            }
            var key = letters.ToString();
            _patterns[key] = [.. values];
            _maxPattern = Math.Max(_maxPattern, key.Length);
        }
        foreach (var word in (exceptions ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            var points = new List<int>();
            int length = 0;
            foreach (var c in word)
            {
                if (c == '-') points.Add(length);
                else length++;
            }
            _exceptions[word.Replace("-", "")] = [.. points];
        }
    }

    /// <summary>
    /// Where <paramref name="word"/> may be hyphenated: the indices i with a hyphen allowed between word[i-1] and word[i],
    /// ascending. Only inside runs of letters (a bracket or digit is never split off); empty for short words.
    /// </summary>
    public IReadOnlyList<int> Points(string word)
    {
        var result = new List<int>();
        int i = 0;
        while (i < word.Length)
        {
            if (!char.IsLetter(word[i])) { i++; continue; }
            int start = i;
            while (i < word.Length && (char.IsLetter(word[i]) || IsApostrophe(word[i]))) i++;
            foreach (var p in RunPoints(word[start..i])) result.Add(start + p);
        }
        return result;
    }

    IEnumerable<int> RunPoints(string run)
    {
        if (run.Length < _leftMin + _rightMin) return [];
        var lower = new StringBuilder(run.Length);
        foreach (var c in run) lower.Append(Normalize(char.ToLower(c, CultureInfo.InvariantCulture)));
        var key = lower.ToString();
        if (_exceptions.TryGetValue(key, out var fixedPoints)) return fixedPoints;
        var w = "." + key + ".";
        var values = new int[w.Length + 1];
        for (int start = 0; start < w.Length; start++)
        {
            for (int length = 1; length <= _maxPattern && start + length <= w.Length; length++)
            {
                if (!_patterns.TryGetValue(w.Substring(start, length), out var v)) continue;
                for (int k = 0; k < v.Length; k++) values[start + k] = Math.Max(values[start + k], v[k]);
            }
        }
        // values[j] sits before w[j]; w[j] = key[j-1], so a break before key[p] is values[p + 1].
        var points = new List<int>();
        for (int p = _leftMin; p <= key.Length - _rightMin; p++)
            if (values[p + 1] % 2 == 1 && !IsApostrophe(key[p - 1]) && !IsApostrophe(key[p])) points.Add(p);
        return points;
    }

    static bool IsApostrophe(char c) => c is '\'' or '’';

    static char Normalize(char c) => c == '’' ? '\'' : c;

    // MARK: Languages

    static readonly ConcurrentDictionary<Lang, Hyphenator?> Cache = new();

    /// <summary>The hyphenator for a language (loaded on first use), null where there is none (Arabic, Chinese, other).</summary>
    public static Hyphenator? For(Lang? lang) => lang is { } l ? Cache.GetOrAdd(l, Load) : null;

    static Hyphenator? Load(Lang lang)
    {
        string? name = lang switch
        {
            Lang.De => "de", Lang.Fr => "fr", Lang.Es => "es", Lang.It => "it", Lang.En => "en",
            _ => null,
        };
        if (name is null) return null;
        var patterns = Resource($"{name}.pat.txt");
        return patterns is null ? null : new Hyphenator(patterns, Resource($"{name}.hyp.txt"));
    }

    static string? Resource(string file)
    {
        using var stream = typeof(Hyphenator).Assembly.GetManifestResourceStream($"Wortschatz.Core.Hyphenation.{file}");
        if (stream is null) return null;
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }
}
