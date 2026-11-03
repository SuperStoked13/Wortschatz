using System.Text;

namespace Wortschatz.Core;

/// <summary>A detected language: one of <see cref="LangDetect.SUPPORTED"/> or Unknown.</summary>
public enum DetectedLanguage { Fr, De, En, Es, It, Ar, Zh, Unknown }

/// <summary><c>{ lang, confidence }</c> of DetectLanguage / DetectColumn.</summary>
public sealed record LanguageDetection(DetectedLanguage Lang, double Confidence) : IJsonEncodable
{
    public static readonly LanguageDetection Unknown = new(DetectedLanguage.Unknown, 0);

    /// <summary>The set-side language, null for Unknown.</summary>
    public Lang? SetLang => Lang == DetectedLanguage.Unknown ? null : LangExtensions.ParseLang(Lang.Raw());

    public JSONValue ToJson() => JSONValue.Obj(("lang", Lang.ToJson()), ("confidence", Confidence));
}

/// <summary>
/// Port of LangDetect.swift (src/core/langdetect.js): language identification for short vocabulary
/// lines (fr/de/en/es/it, plus ar/zh by their script). Several weak signals (lexicon, leading
/// articles, diacritics, German noun capitals, suffixes, letter groups, a character-trigram model,
/// the script) add up to evidence scores; column detection aggregates soft votes over lines.
/// The data is in LangDetectLexicon.cs (generated from the JS). Evidence is added in the JS order.
/// </summary>
public static class LangDetect
{
    public static readonly Lang[] SUPPORTED = [Lang.Fr, Lang.De, Lang.En, Lang.Es, Lang.It, Lang.Ar, Lang.Zh];
    static readonly string[] Codes = ["fr", "de", "en", "es", "it", "ar", "zh"];
    static readonly string[] LATIN = ["fr", "de", "en", "es", "it"];
    const int AR = 5, ZH = 6;
    static readonly double[] PRIOR = [0.2, 0.25, 0.1, 0.05, 0, 0, 0];

    const double W_FUNCTION = 1.4, W_VOCAB = 2.0, W_LEXICON_ONLY = 4.0, W_UNIQUE_BONUS = 0.8;
    const double TRIGRAM_K = 0.3, TRIGRAM_WEIGHT = 0.3, TRIGRAM_CAP = 3;
    const double W_SCRIPT = 4.0, W_PINYIN = 3.5, W_PINYIN_MACRON = 2.8;
    const string SEGMENT_BREAK = @"[,;/(|:]|\s-\s|^\s*-\s";

    static int Index(string code) => Array.IndexOf(Codes, code);

    sealed class Tables
    {
        public readonly Dictionary<string, List<(int Lang, double W)>> Lexicon = new(StringComparer.Ordinal);
        public readonly Dictionary<string, int>[] Counts = new Dictionary<string, int>[5];
        public readonly int[] Totals = new int[5];
        public int V;
    }

    static readonly Lazy<Tables> TablesLazy = new(BuildTables);

    static string[] Words(string? s) => (s ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries);

    static Tables BuildTables()
    {
        var t = new Tables();
        void Add(string word, int lang, double w)
        {
            if (!t.Lexicon.TryGetValue(word, out var entry)) t.Lexicon[word] = entry = [];
            int i = entry.FindIndex(e => e.Lang == lang);
            if (i < 0) entry.Add((lang, w));
            else entry[i] = (lang, Math.Max(entry[i].W, w));
        }
        foreach (var lang in LATIN)
        {
            int li = Index(lang);
            foreach (var w in Words(LangDetectLexicon.FUNCTION_WORDS[lang])) Add(w, li, W_FUNCTION);
            foreach (var w in Words(LangDetectLexicon.VOCAB_WORDS[lang])) Add(w, li, W_VOCAB);
            foreach (var w in Words(LangDetectLexicon.LEXICON_ONLY.GetValueOrDefault(lang))) Add(w, li, W_LEXICON_ONLY);
        }
        foreach (var entry in t.Lexicon.Values)
            if (entry.Count == 1) entry[0] = (entry[0].Lang, entry[0].W + W_UNIQUE_BONUS);

        var vocab = new HashSet<string>(StringComparer.Ordinal);
        foreach (var lang in LATIN)
        {
            int li = Index(lang);
            var c = new Dictionary<string, int>(StringComparer.Ordinal);
            int total = 0;
            foreach (var raw in Words(LangDetectLexicon.FUNCTION_WORDS[lang]).Concat(Words(LangDetectLexicon.VOCAB_WORDS[lang])))
            {
                var w = raw.Replace("'", "");
                if (w.Length < 2) continue;
                foreach (var g in Trigrams(w))
                {
                    c[g] = c.GetValueOrDefault(g) + 1;
                    vocab.Add(g);
                    total++;
                }
            }
            t.Counts[li] = c;
            t.Totals[li] = total;
        }
        t.V = vocab.Count + 2000;
        return t;
    }

    static List<string> Trigrams(string word)
    {
        var s = " " + word + " ";
        var output = new List<string>(s.Length);
        for (int i = 0; i + 3 <= s.Length; i++) output.Add(s.Substring(i, 3));
        return output;
    }

    static void AddWeights(double[] output, (string Lang, double W)[] weights, double factor = 1)
    {
        foreach (var (lang, w) in weights) output[Index(lang)] += w * factor;
    }

    static string FoldKey(string token) => token.Replace("ß", "ss");

    /// <summary>
    /// <c>LEADING[key]</c> is truthy in JS also for "constructor" (inherited from Object.prototype, no
    /// weights): kept for parity with the web and Mac apps.
    /// </summary>
    static bool LeadingHas(string key) => LangDetectLexicon.LEADING.ContainsKey(key) || key == "constructor";

    /// <summary>"Frau" yes; "frau", "FRAU", "l'" no.</summary>
    static bool IsCapitalised(string token)
    {
        var first = token[..1];
        if (first == JSCompat.Lower(first)) return false;
        var rest = token[1..].Replace("'", "");
        return rest.Length > 0 && rest != JSCompat.Upper(rest);
    }

    static void TrigramEvidence(string word, Tables t, double[] output)
    {
        var ll = new double[5];
        double min = double.PositiveInfinity;
        var grams = Trigrams(word);
        for (int li = 0; li < 5; li++)
        {
            var c = t.Counts[li];
            var denom = Math.Log(t.Totals[li] + TRIGRAM_K * t.V);
            double sum = 0;
            foreach (var g in grams) sum += Math.Log(c.GetValueOrDefault(g) + TRIGRAM_K) - denom;
            ll[li] = sum;
            if (sum < min) min = sum;
        }
        for (int li = 0; li < 5; li++) output[li] += Math.Min(TRIGRAM_CAP, (ll[li] - min) * TRIGRAM_WEIGHT);
    }

    static bool IsArabicRange(int u) => u is (>= 0x600 and <= 0x6FF) or (>= 0x750 and <= 0x77F) or (>= 0x8A0 and <= 0x8FF) or (>= 0xFB50 and <= 0xFDFF) or (>= 0xFE70 and <= 0xFEFE);

    static bool IsArabicMarkOrTatweel(char c) =>
        c is (>= 'ؐ' and <= 'ؚ') or (>= 'ً' and <= 'ٟ') or 'ٰ' or (>= 'ۖ' and <= 'ۜ') or (>= '۟' and <= 'ۨ') or (>= '۪' and <= 'ۭ') or 'ـ';

    readonly record struct Token(string Text, int Index, int Script); // Script: -1 none, AR, ZH

    /// <summary>Letter tokens (<c>/\p{L}+'?/gu</c>) with their UTF-16 offsets; tokens with Arabic or Han letters are cut into script runs.</summary>
    static List<Token> TokensOf(string s)
    {
        var output = new List<Token>();
        int i = 0;
        while (i < s.Length)
        {
            int u = s.ConvertToUtf32OrSelf(i, out int len);
            if (!TextNormalizer.IsLetterScalar(u)) { i += len; continue; }
            int start = i;
            while (i < s.Length)
            {
                int v = s.ConvertToUtf32OrSelf(i, out int l);
                if (!TextNormalizer.IsLetterScalar(v)) break;
                i += l;
            }
            if (i < s.Length && s[i] == '\'') i++;
            var token = s[start..i];
            bool hasScript = JSCompat.Scalars(token).Any(x => IsArabicRange(x) || TextNormalizer.IsHanScalar(x));
            if (!hasScript)
            {
                output.Add(new Token(token, start, -1));
                continue;
            }
            // Runs: Arabic, Han, or other.
            int j = 0;
            while (j < token.Length)
            {
                int w = token.ConvertToUtf32OrSelf(j, out int wl);
                int kind = IsArabicRange(w) ? AR : TextNormalizer.IsHanScalar(w) ? ZH : -1;
                int runStart = j;
                while (j < token.Length)
                {
                    int x = token.ConvertToUtf32OrSelf(j, out int xl);
                    int k = IsArabicRange(x) ? AR : TextNormalizer.IsHanScalar(x) ? ZH : -1;
                    if (k != kind) break;
                    j += xl;
                }
                var run = token[runStart..j];
                if (JSCompat.Scalars(run).Any(TextNormalizer.IsLetterScalar)) output.Add(new Token(run, start + runStart, kind));
            }
        }
        return output;
    }

    static double[] Score(string? text)
    {
        var output = new double[7];
        try
        {
            var normalized = TextNormalizer.NormalizeBasic(text ?? "");
            var sbm = new StringBuilder(normalized.Length);
            foreach (char c in normalized) if (!IsArabicMarkOrTatweel(c)) sbm.Append(c);
            var s = sbm.Length > 4000 ? sbm.ToString(0, 4000) : sbm.ToString();
            if (s.Length == 0 || !JSCompat.Scalars(s).Any(TextNormalizer.IsLetterScalar)) return output;
            var t = TablesLazy.Value;

            var seen = new Dictionary<int, int>();
            foreach (var u in JSCompat.Scalars(JSCompat.Lower(s)))
            {
                if (u > 0xFFFF || !LangDetectLexicon.CHAR_WEIGHTS.TryGetValue((char)u, out var w)) continue;
                int n = seen.GetValueOrDefault(u);
                seen[u] = n + 1;
                AddWeights(output, w, n == 0 ? 1 : n < 4 ? 0.5 : 0);
            }

            int prevEnd = 0, index = 0;
            string? prevLower = null;
            foreach (var tok in TokensOf(s))
            {
                var token = tok.Text;
                var lower = JSCompat.Lower(token);
                double pinyin = tok.Script < 0
                    ? (lower.AsSpan().IndexOfAny("ǎěǐǒǔǚǜǘǖ") >= 0 ? W_PINYIN : lower.AsSpan().IndexOfAny("āēīōū") >= 0 ? W_PINYIN_MACRON : 0)
                    : 0;
                if (tok.Script >= 0 || pinyin > 0)
                {
                    if (tok.Script >= 0) output[tok.Script] += W_SCRIPT;
                    else output[ZH] += pinyin;
                    prevEnd = tok.Index + token.Length;
                    prevLower = lower;
                    index++;
                    continue;
                }
                var key = FoldKey(lower);
                var gap = s[prevEnd..tok.Index];
                bool leading = index == 0 || JsRegex.Test(SEGMENT_BREAK, gap);

                if (t.Lexicon.TryGetValue(key, out var lex))
                    foreach (var (li, w) in lex) output[li] += w;

                if (leading && LangDetectLexicon.LEADING.TryGetValue(key, out var lead)) AddWeights(output, lead, index == 0 ? 1 : 0.7);

                if (IsCapitalised(token))
                {
                    if (prevLower is not null && LangDetectLexicon.DE_DETERMINERS.Contains(prevLower) && !JsRegex.Test(SEGMENT_BREAK, gap)) output[1] += 2.4;
                    else if (!leading) output[1] += 1.0;
                    else if (!LeadingHas(key)) output[1] += 0.5;
                }

                var bare = key.Replace("'", "");
                if (bare.Length >= 2)
                {
                    if (bare.Length >= 4)
                    {
                        foreach (var lang in LATIN)
                        {
                            double best = 0;
                            foreach (var (suffix, w) in LangDetectLexicon.SUFFIXES[lang])
                                if (w > best && bare.Length >= suffix.Length + 2 && bare.EndsWith(suffix, StringComparison.Ordinal)) best = w;
                            output[Index(lang)] += best;
                        }
                    }
                    foreach (var (gram, w) in LangDetectLexicon.NGRAMS)
                        if (bare.Contains(gram, StringComparison.Ordinal)) AddWeights(output, w);
                    if (bare.Length >= 4 && "aeiouàèéìòùy".IndexOf(bare[^1]) < 0) AddWeights(output, LangDetectLexicon.CONSONANT_END);
                    TrigramEvidence(bare, t, output);
                }

                prevEnd = tok.Index + token.Length;
                prevLower = lower;
                index++;
            }
            for (int i = 0; i < 7; i++) output[i] = JSCompat.Round(output[i] * 1000) / 1000;
        }
        catch (Exception)
        {
            return new double[7];
        }
        return output;
    }

    /// <summary>Additive evidence per language (rounded to 3 decimals), every supported language present.</summary>
    public static Dictionary<Lang, double> ScoreLanguages(string? text)
    {
        var scores = Score(text);
        var output = new Dictionary<Lang, double>();
        for (int i = 0; i < 7; i++) output[SUPPORTED[i]] = scores[i];
        return output;
    }

    static List<int> Contenders(double[] map)
    {
        var list = new List<int>();
        for (int i = 0; i < 7; i++) if (i < AR || map[i] > 0) list.Add(i);
        return list;
    }

    static double[] Softmax(double[] scores)
    {
        var langs = Contenders(scores);
        double max = double.NegativeInfinity;
        foreach (var l in langs) max = Math.Max(max, scores[l] + PRIOR[l]);
        var p = Enumerable.Repeat(double.NaN, 7).ToArray(); // NaN = undefined in JS
        double sum = 0;
        foreach (var l in langs)
        {
            p[l] = Math.Exp(scores[l] + PRIOR[l] - max);
            sum += p[l];
        }
        foreach (var l in langs) p[l] /= sum;
        return p;
    }

    static bool HasEvidence(double[] scores)
    {
        for (int i = 0; i < 7; i++) if (scores[i] >= 0.3) return true;
        return false;
    }

    static List<int> Rank(double[] map)
    {
        var list = Contenders(map.Select(v => double.IsNaN(v) ? 0 : v).ToArray());
        // Stable sort like JS Array.prototype.sort.
        return list.Select((l, i) => (l, i))
            .OrderByDescending(x => map[x.l]).ThenByDescending(x => PRIOR[x.l]).ThenBy(x => x.i)
            .Select(x => x.l).ToList();
    }

    static DetectedLanguage Detected(int i) => (DetectedLanguage)i;

    /// <summary>Most likely language of a single text with a 0…1 confidence.</summary>
    public static LanguageDetection DetectLanguage(string? text)
    {
        try
        {
            var scores = Score(text);
            if (!HasEvidence(scores)) return LanguageDetection.Unknown;
            var p = Softmax(scores);
            var top = Rank(p)[0];
            return new LanguageDetection(Detected(top), JSCompat.Round(p[top] * 1000) / 1000);
        }
        catch (Exception) { return LanguageDetection.Unknown; }
    }

    /// <summary>Language of a whole column: every line casts a soft vote; summed evidence breaks near-ties.</summary>
    public static LanguageDetection DetectColumn(IEnumerable<string?> lines)
    {
        try
        {
            var votes = new double[7];
            var evidence = new double[7];
            int n = 0;
            foreach (var line in lines)
            {
                var scores = Score(line);
                if (!HasEvidence(scores)) continue;
                var p = Softmax(scores);
                double max = 0;
                for (int i = 0; i < 7; i++) max = Math.Max(max, scores[i]);
                for (int i = 0; i < 7; i++)
                {
                    if (!double.IsNaN(p[i])) votes[i] += p[i];
                    evidence[i] += Math.Max(-8, scores[i] - max);
                }
                n++;
            }
            if (n == 0) return LanguageDetection.Unknown;
            var order = Rank(votes);
            int a = order[0], b = order[1];
            if (Math.Abs(votes[a] - votes[b]) / n < 0.04 && evidence[b] > evidence[a]) order = [b, a];
            int top = order[0], second = order[1];
            double share = votes[top] / n, secondShare = votes[second] / n;
            double separation = share / (share + secondShare);
            double sizeFactor = Math.Min(1, 0.7 + 0.1 * n);
            double confidence = Math.Max(0, Math.Min(1, separation * sizeFactor));
            return new LanguageDetection(Detected(top), JSCompat.Round(confidence * 1000) / 1000);
        }
        catch (Exception) { return LanguageDetection.Unknown; }
    }
}

internal static class CharExtensions
{
    /// <summary>The code point at <paramref name="i"/> (a lone surrogate as itself) and its UTF-16 length.</summary>
    public static int ConvertToUtf32OrSelf(this string s, int i, out int length)
    {
        if (char.IsHighSurrogate(s[i]) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]))
        {
            length = 2;
            return char.ConvertToUtf32(s[i], s[i + 1]);
        }
        length = 1;
        return s[i];
    }
}
