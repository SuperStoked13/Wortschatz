using System.Text;

namespace Wortschatz.Core;

// Port of Grading.swift (src/core/grading.js): answer grading for Write and Learn mode.
//
// `Grade` decides whether a typed answer matches the stored answer under the learner's tolerance
// options. Both sides run through the same pipeline:
//   normalise → split alternatives (, ; /) → parenthesis variants → abbreviation expansion →
//   strip punctuation → split leading article or reflexive pronoun → compare with progressively
//   more tolerant comparators (exact, case, accents, typo).
// Every tolerance that was needed is reported as a note; for wrong answers the most helpful hint
// is computed. The functions have the names of the JS/Swift functions (PascalCase); C# strings
// are UTF-16 like JS, so the JS slices and regexes (JsRegex) carry over directly.

/// <summary>A tolerance that was needed to accept an answer (<c>result.notes</c>, in NOTE_ORDER).</summary>
public enum GradeNote
{
    Article, Pronoun, Abbreviation, Partial, Parentheses,
    /// <summary>A Chinese answer typed in pinyin only.</summary>
    Pinyin,
    /// <summary>JSON "case": capitalisation differed (German only).</summary>
    [Raw("case")] LetterCase,
    Accents,
    /// <summary>The accents of a Chinese answer (pinyin tones).</summary>
    Tones,
    /// <summary>An Arabic letter variant; always accepted.</summary>
    Variant,
    Typo, Order,
    /// <summary>Accepted as the answer of a synonym card (Synonyms.GradeWithSynonyms).</summary>
    Synonym,
    /// <summary>A word with the same meaning that is not in the set.</summary>
    ExtendedSynonym,
}

public enum GradeHint { WrongArticle, MissingArticle, AccentsOnly, TonesOnly, CaseOnly, Typo, Almost }

/// <summary>Result of <c>grade</c>. <c>hint</c> is encoded as explicit null when absent (like JS).</summary>
public sealed record GradeResult(bool Correct, bool Exact, IReadOnlyList<GradeNote> Notes, GradeHint? Hint, string ExpectedDisplay) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(
        ("correct", Correct), ("exact", Exact), ("notes", JSONValue.Array(Notes.Select(n => n.ToJson()))),
        ("hint", Hint.ToJson()), ("expectedDisplay", ExpectedDisplay));

    public bool Equals(GradeResult? o) => o is not null && Correct == o.Correct && Exact == o.Exact && Notes.SequenceEqual(o.Notes)
        && Hint == o.Hint && ExpectedDisplay == o.ExpectedDisplay;

    public override int GetHashCode() => HashCode.Combine(Correct, Exact, Notes.Count, Hint, ExpectedDisplay);
}

/// <summary>Kind of a diff segment: same, del (typed but wrong), add (missing).</summary>
public enum DiffType { Same, Del, Add }

public sealed record DiffSegment(DiffType Type, string Text) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("type", Type.ToJson()), ("text", Text));
}

/// <summary>An ABBREVIATIONS entry: <c>Pattern</c> is the JS RegExp source (flags "giu").</summary>
public sealed record AbbreviationRule(string Pattern, string Canonical)
{
    public const string WordStart = @"(?<![\p{L}\p{N}])";
    public const string WordEnd = @"(?![\p{L}\p{N}])";
    public const string WordStartNoDot = @"(?<![\p{L}\p{N}.])";

    public static AbbreviationRule Abbr(string body, string canonical, string start = WordStart) =>
        new($"{start}(?:{body}){WordEnd}", canonical);
}

public static class Grading
{
    public static readonly IReadOnlyDictionary<Lang, string[]> ARTICLES = new Dictionary<Lang, string[]>
    {
        [Lang.Fr] = ["le", "la", "les", "l'", "un", "une", "des", "du", "de la", "de l'"],
        [Lang.De] = ["der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines"],
        [Lang.En] = ["the", "a", "an", "to"],
        [Lang.Es] = ["el", "la", "los", "las", "un", "una", "unos", "unas"],
        [Lang.It] = ["il", "lo", "la", "i", "gli", "le", "l'", "un", "uno", "una", "un'"],
        [Lang.Ar] = ["ال"],
        [Lang.Zh] = [],
    };

    /// <summary>Reflexive pronouns per answer language (note the trailing spaces, as in JS).</summary>
    public static readonly IReadOnlyDictionary<Lang, string[]> REFLEXIVES = new Dictionary<Lang, string[]>
    {
        [Lang.Fr] = ["se ", "s'"],
        [Lang.De] = ["sich "],
        [Lang.En] = ["oneself"],
        [Lang.Es] = [],
        [Lang.It] = [],
        [Lang.Ar] = [],
        [Lang.Zh] = [],
    };

    /// <summary>Articles written onto the word without a space or apostrophe (الكتاب = ال + كتاب).</summary>
    public static readonly string[] GLUED_ARTICLES = ["ال"];

    public static readonly AbbreviationRule[] ABBREVIATIONS =
    [
        AbbreviationRule.Abbr(@"etw\.?", "etwas"),
        AbbreviationRule.Abbr(@"jdn\.?|jmdn\.?", "jemanden"),
        AbbreviationRule.Abbr(@"jdm\.?|jmdm\.?", "jemandem"),
        AbbreviationRule.Abbr(@"jds\.?|jmds\.?", "jemandes"),
        AbbreviationRule.Abbr(@"jd\.?|jmd\.?", "jemand"),
        AbbreviationRule.Abbr(@"s\.\s?th\.?|smth\.?|sth\.?", "something"),
        AbbreviationRule.Abbr(@"s\.\s?b\.?|s\.\s?o\.?|smb\.?|sb\.?|someone", "somebody"),
        AbbreviationRule.Abbr(@"o\.\s?s\.?", "oneself"),
        AbbreviationRule.Abbr(@"qqch\.?|qqc\.?|qch\.?|qc\.?", "quelque chose"),
        AbbreviationRule.Abbr(@"qqn\.?|qn\.?", "quelqu'un"),
        AbbreviationRule.Abbr(@"z\.?\s?b\.?", "zum Beispiel"),
        AbbreviationRule.Abbr(@"usw\.?", "und so weiter"),
        AbbreviationRule.Abbr(@"bzw\.?", "beziehungsweise"),
        AbbreviationRule.Abbr(@"od\.?", "oder"),
        AbbreviationRule.Abbr(@"u\.", "und", AbbreviationRule.WordStartNoDot),
    ];

    public static readonly Tolerance DEFAULT_TOLERANCE = Tolerance.Default;

    public static readonly string[] NOTE_ORDER =
        ["article", "pronoun", "abbreviation", "partial", "parentheses", "pinyin", "case", "accents", "tones", "variant", "typo", "order"];

    public static readonly string[] HINT_ORDER = ["wrongArticle", "missingArticle", "accentsOnly", "tonesOnly", "caseOnly", "typo", "almost"];

    const int MAX_PARTS = 24;
    const int MAX_DIST_LEN = 200;
    const int MAX_DIFF_CELLS = 1_000_000;
    const int MAX_PAREN_VARIANTS = 64;
    const int MAX_SLASH_VARIANTS = 16;
    const double ALMOST_SIMILARITY = 0.75;

    /// <summary>Elided forms and the full articles/pronouns they stand for (l'homme ≡ le homme).</summary>
    static readonly Dictionary<Lang, Dictionary<string, string[]>> ELISIONS = new()
    {
        [Lang.Fr] = new() { ["l'"] = ["le", "la"], ["s'"] = ["se"], ["de l'"] = ["de la", "du"] },
        [Lang.It] = new() { ["l'"] = ["lo", "la"], ["un'"] = ["una"] },
    };

    sealed record ArticleEntry(string Token, string Kind, bool Elided);

    static readonly Dictionary<Lang, List<ArticleEntry>> ARTICLE_TABLE = BuildArticleTable();
    static readonly HashSet<string> BARE_ARTICLES = new(StringComparer.Ordinal);
    static readonly HashSet<string> ELIDED_ARTICLES = new(StringComparer.Ordinal);
    static readonly HashSet<string> NOUN_ARTICLES = new(StringComparer.Ordinal);
    // JS Set iteration order (insertion order) matters for the `for (const t of …)` loops.
    static readonly List<string> ELIDED_ARTICLES_ORDER = [];
    static readonly List<string> NOUN_ARTICLES_ORDER = [];

    static readonly HashSet<string> PHRASE_STARTERS = new(StringComparer.Ordinal) { "au", "aux" };
    static readonly Dictionary<string, string> CONTRACTED = new() { ["au"] = "à", ["aux"] = "à", ["du"] = "de", ["des"] = "de" };
    static readonly HashSet<string> SLOT_WORDS = new(StringComparer.Ordinal)
    {
        "etwas", "jemand", "jemanden", "jemandem", "jemandes", "sich",
        "something", "somebody", "oneself",
        "quelque chose", "quelqu'un", "se", "s'",
    };
    static readonly HashSet<string> REFLEXIVE_SLOTS = new(StringComparer.Ordinal) { "sich", "oneself", "se", "s'" };
    static readonly HashSet<string> PREVERBAL_REFLEXIVES = new(StringComparer.Ordinal) { "se", "s'" };
    static readonly HashSet<string> SHORT_FORMS = new(StringComparer.Ordinal)
    {
        "je", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles", "me", "te", "lui", "leur", "eux", "moi", "toi",
        "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "ce", "cet", "cette", "ces",
        "ich", "du", "er", "sie", "es", "wir", "ihr", "mir", "dir", "mich", "dich",
        "he", "she", "it", "we", "they", "him", "her", "us", "them", "his", "its", "my", "your", "our", "their",
    };
    const string ANNOTATION = @"^(?:[-¨~].*|(?:m|f|n|pl|Pl|sg|Sg)\.?|m\.?\/f\.?)$";
    static string NoteKey(string s) => JsRegex.ReplaceAll(JSCompat.Lower(s), @"[\s.]", "");
    static readonly HashSet<string> GRAMMAR_MARKERS = new(StringComparer.Ordinal) { "m", "f", "n", "pl", "sg", "etc", "irr", "ugs", "fam", "adj", "adv" };

    static Dictionary<Lang, List<ArticleEntry>> BuildArticleTable()
    {
        var table = new Dictionary<Lang, List<ArticleEntry>>();
        foreach (var lang in new[] { Lang.Fr, Lang.De, Lang.En, Lang.Es, Lang.It, Lang.Ar, Lang.Zh })
        {
            var entries = new List<ArticleEntry>();
            void Add(string raw, string kind)
            {
                var token = JSCompat.Lower(JSCompat.Trim(raw));
                if (token.Length > 0) entries.Add(new ArticleEntry(token, kind, token.EndsWith('\'') || GLUED_ARTICLES.Contains(token)));
            }
            foreach (var a in ARTICLES[lang]) Add(a, "article");
            foreach (var r in REFLEXIVES[lang]) Add(r, "pronoun");
            // JS sort is stable: longer tokens first, otherwise insertion order.
            table[lang] = entries.Select((e, i) => (e, i)).OrderByDescending(x => x.e.Token.Length).ThenBy(x => x.i).Select(x => x.e).ToList();
        }
        return table;
    }

    static Grading()
    {
        foreach (var entries in ARTICLE_TABLE.Values)
        {
            foreach (var e in entries)
            {
                if (e.Elided) { if (ELIDED_ARTICLES.Add(e.Token)) ELIDED_ARTICLES_ORDER.Add(e.Token); }
                else BARE_ARTICLES.Add(e.Token);
                if (e.Kind == "article" && e.Token != "to" && NOUN_ARTICLES.Add(e.Token)) NOUN_ARTICLES_ORDER.Add(e.Token);
            }
        }
    }

    // MARK: - Small helpers

    static int CountLetters(string s) => JSCompat.Scalars(s).Count(TextNormalizer.IsLetterScalar);

    static bool HasAlnum(string s) => JSCompat.Scalars(s).Any(u => TextNormalizer.IsLetterScalar(u) || TextNormalizer.IsNumberScalar(u));

    static bool HasLigature(string s) => s.AsSpan().IndexOfAny("ßẞœŒæÆ") >= 0;

    /// <summary>ß ≡ ss, œ ≡ oe, æ ≡ ae.</summary>
    static string FoldLigatures(string s)
    {
        if (!HasLigature(s)) return s;
        s = s.Replace("ẞ", "SS").Replace("ß", "ss");
        s = JsRegex.ReplaceAll(s, @"Œ(?=\p{Ll})", "Oe").Replace("Œ", "OE").Replace("œ", "oe");
        s = JsRegex.ReplaceAll(s, @"Æ(?=\p{Ll})", "Ae").Replace("Æ", "AE").Replace("æ", "ae");
        return s;
    }

    static string SqueezeApostrophes(string s) => JsRegex.ReplaceAll(s, " *' *", "'");

    /// <summary>Normalisation that always applies (whitespace, apostrophes, dashes, ligatures, script folds).</summary>
    static string Prep(string? value) => SqueezeApostrophes(FoldLigatures(TextNormalizer.FoldScripts(TextNormalizer.NormalizeBasic(value ?? ""))));

    const string PUNCT = "[.,!?;:\"«»‹›¿¡…~*„“”‚「」『』《》〈〉]";
    const string BRACKETS = @"[()[\]{}]";

    static string Tidy(string s) => JSCompat.Trim(SqueezeApostrophes(JsRegex.ReplaceAll(s, @"\s+", " ")));
    /// <summary>Comparison text: hyphen ≡ space, punctuation and leftover brackets dropped.</summary>
    static string Clean(string s) => Tidy(JsRegex.ReplaceAll(JsRegex.ReplaceAll(s.Replace('-', ' '), PUNCT, ""), BRACKETS, ""));
    /// <summary>Exactness key: like Clean but brackets still count.</summary>
    static string KeyOf(string s) => Tidy(JsRegex.ReplaceAll(s.Replace('-', ' '), PUNCT, ""));

    static bool StartsWithUpper(string s) => s.Length > 0 && TextNormalizer.IsUppercaseLetter(JSCompat.Scalars(s).First());
    static bool StartsWithLower(string s) => s.Length > 0 && TextNormalizer.IsLowercaseLetter(JSCompat.Scalars(s).First());

    /// <summary>A capitalised abbreviation ("Etw.") expands capitalised ("Etwas").</summary>
    static string ExpandAbbreviations(string s)
    {
        var output = s;
        foreach (var rule in ABBREVIATIONS)
        {
            output = JsRegex.ReplaceAll(output, rule.Pattern,
                m => StartsWithUpper(m.Value) ? JSCompat.Upper(rule.Canonical[..1]) + rule.Canonical[1..] : rule.Canonical, "iu");
        }
        return output;
    }

    // MARK: - Alternatives

    static bool IsOpener(char c) => c is '(' or '[' or '（' or '［' or '【';
    static bool IsCloser(char c) => c is ')' or ']' or '）' or '］' or '】';
    static bool IsComma(char c) => c is ',' or '،' or '，' or '、';
    static bool IsSemicolon(char c) => c is ';' or '؛' or '；';

    static bool BracketsBalanced(string s)
    {
        int depth = 0;
        foreach (char ch in s)
        {
            if (IsOpener(ch)) depth++;
            else if (IsCloser(ch) && --depth < 0) return false;
        }
        return depth == 0;
    }

    /// <summary>Calls <paramref name="visit"/>(ch, i) for every character outside brackets (when balanced); false stops.</summary>
    static void ScanTopLevel(string s, Func<char, int, bool> visit)
    {
        bool track = BracketsBalanced(s);
        int depth = 0;
        for (int i = 0; i < s.Length; i++)
        {
            char ch = s[i];
            if (track && IsOpener(ch)) depth++;
            else if (track && IsCloser(ch)) depth--;
            else if (depth == 0 && !visit(ch, i)) return;
        }
    }

    static bool IsAsciiDigit(char c) => c is >= '0' and <= '9';

    /// <summary>Split on top-level , ; and spaced / (never between digits: "1,5 kg").</summary>
    static List<string> SplitSegments(string s, bool commas = true)
    {
        var output = new List<string>();
        int start = 0;
        ScanTopLevel(s, (ch, i) =>
        {
            char prev = i > 0 ? s[i - 1] : ' ';
            char next = i + 1 < s.Length ? s[i + 1] : ' ';
            bool cut = IsSemicolon(ch)
                || (IsComma(ch) && (commas ? !(IsAsciiDigit(prev) && IsAsciiDigit(next)) : prev is '?' or '!' or '…' or '؟' or '？' or '！'))
                || (ch == '/' && (prev == ' ' || next == ' '));
            if (cut)
            {
                output.Add(s[start..i]);
                start = i + 1;
            }
            return true;
        });
        output.Add(s[start..]);
        return output;
    }

    /// <summary>A comma inside a sentence does not separate answers (see the JS comment).</summary>
    static bool IsSentenceLike(string s, Lang? lang)
    {
        if (!s.Contains(',')) return false;
        var t = JsRegex.ReplaceFirst(s, "[\\s\"»«”“„)\\]」』》〉]+$", "");
        if (JsRegex.Test(@"(?:[?!…]|\.\.\.)$", t)) return true;
        if (t.EndsWith('.') && (TextNormalizer.HasArabic(t) || TextNormalizer.HasHan(t))) return true;
        if (!JsRegex.Test("^[\\s\"«„“¿¡([]*\\p{Lu}", t)) return false;
        var m = JsRegex.Match(t, @"([\p{L}']+)\.$");
        if (m is null) return false;
        var word = JSCompat.Lower(m.Groups[1].Value);
        if (CountLetters(word) < 2 || GRAMMAR_MARKERS.Contains(word) || BARE_ARTICLES.Contains(word)) return false;
        if (ExpandAbbreviations(m.Groups[1].Value + ".") != m.Groups[1].Value + ".") return false;
        return !(lang == Lang.De && IsGermanNounList(t));
    }

    static bool IsGermanNounList(string t)
    {
        var stripped = JsRegex.ReplaceFirst(JsRegex.ReplaceFirst(t, "^[\\s\"«„“([]+", ""), @"\.$", "");
        var parts = stripped.Split(',', ';').Select(JSCompat.Trim).Where(p => p.Length > 0);
        return parts.All(part =>
        {
            var words = JsRegex.Split(part, @"\s+");
            bool article = words.Length == 2 && ARTICLES[Lang.De].Contains(JSCompat.Lower(words[0]));
            return (words.Length == 1 || article) && JsRegex.Test(@"^\p{Lu}[\p{L}'-]*$", words[^1]);
        });
    }

    static bool IsBareArticle(string w) => BARE_ARTICLES.Contains(JSCompat.Lower(w));

    static bool StartsPhrase(string w)
    {
        var low = JSCompat.Lower(w);
        if (BARE_ARTICLES.Contains(low) || PHRASE_STARTERS.Contains(low)) return true;
        foreach (var t in ELIDED_ARTICLES_ORDER) if (low.Length > t.Length && low.StartsWith(t, StringComparison.Ordinal)) return true;
        return false;
    }

    static bool OpensNounPhrase(string w)
    {
        var low = JSCompat.Lower(w);
        if (NOUN_ARTICLES.Contains(low)) return true;
        foreach (var t in NOUN_ARTICLES_ORDER)
            if (t.EndsWith('\'') && low.Length > t.Length && low.StartsWith(t, StringComparison.Ordinal)) return true;
        return false;
    }

    static int ParallelGroupStart(string[] lw, string firstRight)
    {
        bool OpensGroup(string w) => OpensNounPhrase(w) || PHRASE_STARTERS.Contains(JSCompat.Lower(w));
        if (!OpensGroup(firstRight) || OpensNounPhrase(lw[0])) return -1;
        for (int j = lw.Length - 1; j >= 1; j--)
        {
            var low = JSCompat.Lower(lw[j]);
            bool bare = NOUN_ARTICLES.Contains(low) || PHRASE_STARTERS.Contains(low);
            if (!OpensGroup(lw[j]) || (bare && j == lw.Length - 1)) continue;
            return CONTRACTED.TryGetValue(JSCompat.Lower(firstRight), out var prep) && JSCompat.Lower(lw[j - 1]) == prep ? j - 1 : j;
        }
        return -1;
    }

    static string SlotWord(string text) => JSCompat.Lower(ExpandAbbreviations(Clean(text)));
    static bool IsSlot(string text) => SLOT_WORDS.Contains(SlotWord(text));

    static int SlotSpan(string[] words, bool atEnd)
    {
        for (int n = Math.Min(2, words.Length); n > 0; n--)
        {
            var part = atEnd ? words[^n..] : words[..n];
            if (IsSlot(string.Join(' ', part))) return n;
        }
        return 0;
    }

    /// <summary><c>s.match(/[^\s/]*$/)[0]</c></summary>
    static string TrailingWord(string s)
    {
        int i = s.Length;
        while (i > 0 && s[i - 1] != '/' && !JSCompat.IsWhitespace(s[i - 1])) i--;
        return s[i..];
    }

    /// <summary><c>s.match(/^[^\s/]*/)[0]</c></summary>
    static string LeadingWord(string s)
    {
        int i = 0;
        while (i < s.Length && s[i] != '/' && !JSCompat.IsWhitespace(s[i])) i++;
        return s[..i];
    }

    static bool IsAlternationSlash(string seg, int i)
    {
        var left = seg[..i];
        var right = seg[(i + 1)..];
        var lw = TrailingWord(left);
        var rw = LeadingWord(right);
        if (lw.Length == 0 || rw.Length == 0 || rw[0] == '-') return false;
        if (IsSlot(lw) && IsSlot(rw)) return true;
        if (SHORT_FORMS.Contains(JSCompat.Lower(lw)) && SHORT_FORMS.Contains(JSCompat.Lower(rw))) return true;
        int rightWords = JSCompat.Trim(right).Split(' ').Length;
        if (rightWords == 1 && StartsWithUpper(lw) && StartsWithLower(rw)) return false;
        if (IsBareArticle(lw) && IsBareArticle(rw)) return true;
        if (StartsPhrase(rw) && rightWords >= 2 && CountLetters(lw) >= 2) return true;
        bool WordLike(string w) => CountLetters(w) >= 3 || TextNormalizer.HasHan(w) || (IsSlot(w) && !REFLEXIVE_SLOTS.Contains(SlotWord(w)));
        return WordLike(lw) && WordLike(rw);
    }

    static List<string> ExpandSlashes(string seg, int depth = 0)
    {
        int at = -1;
        if (depth < 6)
        {
            ScanTopLevel(seg, (ch, i) =>
            {
                if (ch == '/' && IsAlternationSlash(seg, i)) { at = i; return false; }
                return true;
            });
        }
        if (at < 0) return [seg];
        var left = JSCompat.Trim(seg[..at]);
        var right = JSCompat.Trim(seg[(at + 1)..]);
        var lw = left.Split(' ');
        var rw = right.Split(' ');
        var lastLeft = TrailingWord(left);
        var firstRight = LeadingWord(right);
        string[] Bind(int nl, int nr)
        {
            var prefix = lw[..(lw.Length - nl)];
            var suffix = rw[nr..];
            return
            [
                string.Join(' ', prefix.Concat(lw[(lw.Length - nl)..]).Concat(suffix)),
                string.Join(' ', prefix.Concat(rw[..nr]).Concat(suffix)),
            ];
        }
        int nl = SlotSpan(lw, true);
        int nr = SlotSpan(rw, false);
        int group = ParallelGroupStart(lw, firstRight);
        string[] pieces;
        if (nl > 0 && nr > 0)
        {
            var leftSlot = SlotWord(string.Join(' ', lw[(lw.Length - nl)..]));
            var rightSlot = SlotWord(string.Join(' ', rw[..nr]));
            bool verbPhrases = lw.Length > nl && rw.Length > nr && PREVERBAL_REFLEXIVES.Contains(rightSlot) && !REFLEXIVE_SLOTS.Contains(leftSlot);
            pieces = verbPhrases ? [left, right] : Bind(nl, nr);
        }
        else if (IsBareArticle(lastLeft) && IsBareArticle(firstRight)) pieces = Bind(1, 1);
        else if (group > 0) pieces = [left, string.Join(' ', lw[..group].Concat(rw))];
        else if (lw.Length == rw.Length || (StartsPhrase(firstRight) && !IsBareArticle(lastLeft))) pieces = [left, right];
        else pieces = Bind(1, 1);
        var output = new List<string>();
        foreach (var piece in pieces)
            foreach (var x in ExpandSlashes(piece, depth + 1))
                if (output.Count < MAX_SLASH_VARIANTS) output.Add(x);
        return output;
    }

    /// <summary>Splits an answer into alternatives and sets aside grammar annotations ("der Tisch, -e").</summary>
    static (List<string> Alts, List<string> Notes) SplitInternal(string s, bool commas = true, HashSet<string>? allowed = null)
    {
        var alts = new List<string>();
        var notes = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var seg in SplitSegments(s, commas))
        {
            foreach (var piece in ExpandSlashes(JSCompat.Trim(seg)))
            {
                var alt = TextNormalizer.NormalizeBasic(piece);
                if (Clean(TextNormalizer.FoldScripts(alt)).Length == 0 || seen.Contains(alt)) continue;
                bool annotation = alts.Count > 0 && JsRegex.Test(ANNOTATION, alt) && !JsRegex.Test(ANNOTATION, alts[^1]);
                if (annotation && (allowed is null || allowed.Contains(NoteKey(alt))))
                {
                    notes.Add(alt);
                    continue;
                }
                seen.Add(alt);
                alts.Add(alt);
            }
        }
        return (alts, notes);
    }

    /// <summary>The alternatives of an answer ("laid, laide" → ["laid", "laide"]), without grammar annotations.</summary>
    public static List<string> SplitAlternatives(string? expected, Lang? lang = null)
    {
        try
        {
            var s = TextNormalizer.NormalizeBasic(expected ?? "");
            return SplitInternal(s, !IsSentenceLike(TextNormalizer.FoldScripts(s), ResolvedLang(lang))).Alts;
        }
        catch (Exception) { return []; }
    }

    // MARK: - Parentheses

    sealed record BracketGroup(int Start, int End, string Content);

    static List<BracketGroup> BracketGroups(string s)
    {
        var groups = new List<BracketGroup>();
        if (!BracketsBalanced(s)) return groups;
        int depth = 0, start = -1;
        for (int i = 0; i < s.Length; i++)
        {
            char ch = s[i];
            if (IsOpener(ch)) { if (depth++ == 0) start = i; }
            else if (IsCloser(ch) && --depth == 0) groups.Add(new BracketGroup(start, i + 1, s[(start + 1)..i]));
        }
        return groups;
    }

    sealed record Source(string Text, bool Omitted, bool Lock, bool Pinyin = false);
    readonly record struct Choice(string Text, bool Omitted);

    static List<Source> ParenVariants(string alt, bool optional)
    {
        var groups = BracketGroups(alt);
        if (groups.Count == 0) return [new Source(alt, false, false)];
        bool lockIt = !optional && alt.Length > 0 && alt[0] is '(' or '[';
        var choices = groups.Select(g =>
        {
            var list = new List<Choice> { new(g.Content, false) };
            if (optional)
            {
                list.Insert(0, new Choice("", HasAlnum(g.Content)));
                var subs = SplitSegments(g.Content).SelectMany(x => ExpandSlashes(JSCompat.Trim(x))).Where(x => Clean(x).Length > 0).ToList();
                if (subs.Count > 1) foreach (var x in subs) list.Add(new Choice(x, false));
            }
            return list;
        }).ToList();
        long total = choices.Aggregate(1L, (n, list) => n * list.Count);
        List<List<Choice>> picks;
        if (total > MAX_PAREN_VARIANTS)
        {
            picks = [choices.Select(list => list[list.Count > 1 ? 1 : 0]).ToList()];
            if (optional) picks.Add(choices.Select(list => list[0]).ToList());
        }
        else
        {
            picks = [[]];
            foreach (var list in choices)
                picks = picks.SelectMany(p => list.Select(c => new List<Choice>(p) { c })).ToList();
        }
        return picks.Select(p =>
        {
            var text = new StringBuilder();
            int pos = 0;
            for (int k = 0; k < groups.Count; k++)
            {
                text.Append(alt[pos..groups[k].Start]).Append(p[k].Text);
                pos = groups[k].End;
            }
            return new Source(Tidy(text + alt[pos..]), p.Any(c => c.Omitted), lockIt);
        }).ToList();
    }

    // MARK: - Chinese: tone numbers and answers in characters and pinyin

    static readonly string[] TONE_MARKS = ["", "̄", "́", "̌", "̀"];
    const string TONE_SYLLABLE = "((?:[A-Za-zÜü]|[Uu]:)+)([0-5])";

    static int ToneVowel(string syllable)
    {
        var low = JSCompat.Lower(syllable);
        foreach (var v in new[] { "a", "e" }) if (low.Contains(v)) return low.IndexOf(v, StringComparison.Ordinal);
        if (low.Contains("ou")) return low.IndexOf("ou", StringComparison.Ordinal);
        int at = -1;
        for (int i = 0; i < low.Length; i++) if ("aeiouü".Contains(low[i])) at = i;
        return at;
    }

    /// <summary>"ni3 hao3" → "nǐ hǎo", "lv4" → "lǜ", "ma5" → "ma".</summary>
    static string ToneMarks(string s)
    {
        if (!s.Any(c => c is >= '0' and <= '5')) return s;
        return JsRegex.ReplaceAll(s, TONE_SYLLABLE, m =>
        {
            var syllable = m.Groups[1].Value.Replace("u:", "ü").Replace("U:", "Ü").Replace('v', 'ü').Replace('V', 'Ü');
            int at = ToneVowel(syllable);
            if (at < 0) return m.Value;
            int digit = m.Groups[2].Value[0] - '0';
            var mark = digit < TONE_MARKS.Length ? TONE_MARKS[digit] : "";
            return JSCompat.Nfc(syllable[..(at + 1)] + mark + syllable[(at + 1)..]);
        });
    }

    const string LATIN_LETTER = @"[A-Za-zÀ-ɏḀ-ỿ]";
    const string BRACKET = @"[()[\]（）［］【】]";
    const string TRAILING_GROUP = @"^([^()[\]（）［］【】]+?) ?[(（[［【]([^()[\]（）［］【】]+)[)）\]］】]$";
    static bool IsHanPart(string s) => TextNormalizer.HasHan(s) && !JsRegex.Test(LATIN_LETTER, s);
    static bool IsLatinPart(string s) => JsRegex.Test(LATIN_LETTER, s) && !TextNormalizer.HasHan(s);

    sealed record HanLatin(string Han, string Latin);

    /// <summary>«你好 (nǐ hǎo)», «你好 nǐ hǎo» → { han: 你好, latin: nǐ hǎo }; null otherwise.</summary>
    static HanLatin? HanLatinParts(string text)
    {
        HanLatin? Pair(string a, string b)
        {
            if (IsHanPart(a) && IsLatinPart(b)) return new HanLatin(JSCompat.Trim(a), JSCompat.Trim(b));
            if (IsLatinPart(a) && IsHanPart(b)) return new HanLatin(JSCompat.Trim(b), JSCompat.Trim(a));
            return null;
        }
        var m = JsRegex.Match(text, TRAILING_GROUP);
        if (m is not null) return Pair(m.Groups[1].Value, m.Groups[2].Value);
        if (JsRegex.Test(BRACKET, text)) return null;
        for (int i = text.IndexOf(' '); i > 0; i = text.IndexOf(' ', i + 1))
            if (Pair(text[..i], text[(i + 1)..]) is { } found) return found;
        return null;
    }

    // MARK: - Articles and reflexive pronouns

    sealed record Split(string Text, string? Article, string? Kind, string Core);

    static Split SplitArticle(string text, Lang? lang)
    {
        if (lang is { } l && ARTICLE_TABLE.TryGetValue(l, out var table))
        {
            foreach (var e in table)
            {
                var head = text.Length >= e.Token.Length ? text[..e.Token.Length] : text;
                if (JSCompat.Lower(head) != e.Token) continue;
                var rest = text[Math.Min(e.Token.Length, text.Length)..];
                if (!e.Elided && (rest.Length == 0 || rest[0] != ' ')) continue;
                var core = JSCompat.Trim(rest);
                if (core.Length > 0 && HasAlnum(core)) return new Split(text, text[..e.Token.Length], e.Kind, core);
            }
        }
        return new Split(text, null, null, text);
    }

    static bool SameArticle(string a, string b, Lang? lang)
    {
        var x = JSCompat.Lower(a);
        var y = JSCompat.Lower(b);
        if (x == y) return true;
        if (lang is not { } l || !ELISIONS.TryGetValue(l, out var map)) return false;
        return (map.TryGetValue(x, out var xs) && xs.Contains(y)) || (map.TryGetValue(y, out var ys) && ys.Contains(x));
    }

    /// <summary>"Herr, der" (dictionary style) → "der Herr".</summary>
    static List<string> MergeLoneArticles(List<string> alts, Lang lang)
    {
        if (!ARTICLE_TABLE.TryGetValue(lang, out var table)) return alts;
        ArticleEntry? LoneArticle(string alt)
        {
            var low = JSCompat.Lower(Clean(alt));
            return table.FirstOrDefault(e => e.Kind == "article" && e.Token == low);
        }
        var output = new List<string>();
        foreach (var alt in alts)
        {
            var low = JSCompat.Lower(Clean(alt));
            var entry = LoneArticle(alt);
            var prev = output.Count > 0 ? output[^1] : null;
            if (entry is not null && prev is not null && LoneArticle(prev) is null && SplitArticle(Clean(prev), lang).Article is null)
                output[^1] = entry.Elided ? low + prev : low + " " + prev;
            else output.Add(alt);
        }
        return output;
    }

    // MARK: - Comparators

    readonly record struct Combo(bool C, bool A, bool T, bool V = false);

    static readonly Combo[] COMBOS =
    [
        new(false, false, false), new(true, false, false), new(false, true, false), new(true, true, false),
        new(false, false, true), new(true, false, true), new(false, true, true), new(true, true, true),
    ];
    static readonly Combo[] VARIANT_COMBOS = COMBOS.SelectMany(c => new[] { c, c with { V = true } }).ToArray();

    readonly record struct Allow(bool C, bool A, bool T, bool Art = false, bool Abbr = false, bool HintPass = false);
    static readonly Allow NON_TYPO = new(true, true, false);
    static readonly Allow ANY_COMBO = new(true, true, true);

    /// <summary>Arabic letter variants: hamza forms and alef wasla → ا, ؤ → و, ئ/ى → ي, ة → ه, U+0653–0655 dropped.</summary>
    static string FoldVariants(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (char c in s)
        {
            switch (c)
            {
                case 'أ' or 'إ' or 'آ' or 'ٱ': sb.Append('ا'); break;
                case 'ؤ': sb.Append('و'); break;
                case 'ئ' or 'ى': sb.Append('ي'); break;
                case 'ة': sb.Append('ه'); break;
                case >= 'ٓ' and <= 'ٕ': break;
                default: sb.Append(c); break;
            }
        }
        return sb.ToString();
    }

    static string[] FoldForms(string s, Combo combo)
    {
        var b = combo.C ? JSCompat.Lower(s) : s;
        if (combo.V) b = FoldVariants(b);
        return combo.A ? [TextNormalizer.StripDiacritics(b), TextNormalizer.FoldUmlauts(b)] : [b];
    }

    static string HanOf(string s)
    {
        var sb = new StringBuilder();
        foreach (var u in JSCompat.Scalars(s)) if (TextNormalizer.IsHanScalar(u)) sb.AppendScalar(u);
        return sb.ToString();
    }

    /// <summary>Chinese characters earn no typo budget: a wrong character is never a typo.</summary>
    static int TypoBudget(string s, Lang? lang)
    {
        int n = CountLetters(s) - (lang == Lang.Zh ? JSCompat.Scalars(HanOf(s)).Count() : 0);
        return n >= 10 ? 2 : n >= 4 ? 1 : 0;
    }

    /// <summary>Optimal-string-alignment distance; returns max + 1 once it exceeds max.</summary>
    static int EditDistance(string a, string b, int max)
    {
        if (a == b) return 0;
        var x = JSCompat.Scalars(a).ToArray();
        var y = JSCompat.Scalars(b).ToArray();
        int n = x.Length, m = y.Length;
        if (Math.Abs(n - m) > max) return max + 1;
        if (n == 0 || m == 0) return Math.Max(n, m);
        if (n > MAX_DIST_LEN || m > MAX_DIST_LEN) return max + 1;
        var prev2 = new int[m + 1];
        var prev = new int[m + 1];
        for (int j = 0; j <= m; j++) prev[j] = j;
        var cur = new int[m + 1];
        for (int i = 1; i <= n; i++)
        {
            cur[0] = i;
            int rowMin = i;
            for (int j = 1; j <= m; j++)
            {
                int cost = x[i - 1] == y[j - 1] ? 0 : 1;
                int v = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
                if (i > 1 && j > 1 && x[i - 1] == y[j - 2] && x[i - 2] == y[j - 1]) v = Math.Min(v, prev2[j - 2] + 1);
                cur[j] = v;
                if (v < rowMin) rowMin = v;
            }
            if (rowMin > max) return max + 1;
            (prev2, prev, cur) = (prev, cur, prev2);
        }
        return prev[m];
    }

    static bool ComboMatches(string g, string e, Combo combo, Lang? lang)
    {
        var gs = FoldForms(g, combo);
        var es = FoldForms(e, combo);
        for (int i = 0; i < es.Length; i++)
        {
            if (gs[i] == es[i]) return true;
            if (combo.T)
            {
                int max = TypoBudget(es[i], lang);
                bool sameHan = lang != Lang.Zh || HanOf(gs[i]) == HanOf(es[i]);
                if (max > 0 && sameHan && EditDistance(gs[i], es[i], max) <= max) return true;
            }
        }
        return false;
    }

    /// <summary>First (least tolerant) permitted comparator under which g matches e.</summary>
    static Combo? FindCombo(string g, string e, Allow allow, Lang? lang)
    {
        foreach (var combo in TextNormalizer.HasArabic(g) || TextNormalizer.HasArabic(e) ? VARIANT_COMBOS : COMBOS)
        {
            if ((combo.C && !allow.C) || (combo.A && !allow.A) || (combo.T && !allow.T)) continue;
            if (ComboMatches(g, e, combo, lang)) return combo;
        }
        return null;
    }

    sealed record Best(Combo Combo, string? Art, int Rank, bool Abbr = false, bool Paren = false, bool Lock = false, bool Pinyin = false);
    sealed record PairResult(Best? Best, bool WrongArticle, bool Near);

    static PairResult EvalPair(Split g, Split e, Allow allow, bool artOk, Lang? lang)
    {
        Best? best = null;
        bool wrongArticle = false, near = false;
        void Consider(Combo? combo, string? art)
        {
            if (combo is not { } c) return;
            int rank = (c.C ? 1 : 0) + (c.A ? 2 : 0) + (c.V ? 2 : 0) + (c.T ? 8 : 0) + (art is not null ? 4 : 0);
            if (best is null || rank < best.Rank) best = new Best(c, art, rank);
        }
        if (e.Article is not null)
        {
            if (g.Article is not null)
            {
                if (SameArticle(g.Article, e.Article, lang)) Consider(FindCombo(g.Core, e.Core, allow, lang), null);
                else if (FindCombo(g.Core, e.Core, NON_TYPO, lang) is not null) wrongArticle = true;
                else if (allow.HintPass && FindCombo(g.Core, e.Core, ANY_COMBO, lang) is not null) near = true;
            }
            else
            {
                if (artOk) Consider(FindCombo(g.Text, e.Core, allow, lang), e.Kind);
                Consider(FindCombo(g.Text, e.Text, allow, lang), null);
            }
        }
        else
        {
            Consider(FindCombo(g.Text, e.Text, allow, lang), null);
            if (g.Article is not null) Consider(FindCombo(g.Core, e.Text, allow, lang), null);
        }
        return new PairResult(best, wrongArticle, near);
    }

    sealed record Forms(Split Raw, Split? Exp);

    /// <summary>Chinese: spaces do not count (pinyin syllables, characters).</summary>
    static Forms MakeForms(string text, Tolerance tol, Lang? lang)
    {
        string Squeeze(string s) => lang == Lang.Zh ? s.Replace(" ", "") : s;
        var rawText = Squeeze(Clean(text));
        var raw = SplitArticle(rawText, lang);
        Split? exp = null;
        if (tol.Abbreviations)
        {
            var expText = Squeeze(Clean(ExpandAbbreviations(text)));
            if (expText != rawText) exp = SplitArticle(expText, lang);
        }
        return new Forms(raw, exp);
    }

    sealed record Variant(Split Raw, Split? Exp, bool Omitted, bool Lock, bool Pinyin);
    sealed record Alt(List<Variant> Variants, List<string> Articles);

    /// <summary>One expected alternative: its comparison variants and the articles it declares.</summary>
    static Alt PrepareAlt(string text, Tolerance tol, Lang? lang)
    {
        var variants = new List<Variant>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var articles = new List<string>();
        void AddArticle(string a) { if (!articles.Contains(a)) articles.Add(a); }
        var sources = ParenVariants(text, tol.Parentheses);
        if (lang is { } l && ARTICLE_TABLE.TryGetValue(l, out var table))
        {
            foreach (var g in BracketGroups(text))
            {
                var low = JSCompat.Lower(Clean(g.Content));
                var entry = table.FirstOrDefault(e => e.Token == low);
                if (entry is null) continue;
                AddArticle(low);
                var head = Tidy(text[..g.Start]);
                if (!HasAlnum(text[g.End..]) && HasAlnum(head) && BracketGroups(head).Count == 0 && SplitArticle(Clean(head), lang).Article is null)
                    sources.Add(new Source(entry.Elided ? low + head : low + " " + head, false, !tol.Parentheses));
            }
        }
        var zh = lang == Lang.Zh ? HanLatinParts(text) : null;
        if (zh is not null)
        {
            sources.Add(new Source(zh.Han, false, false));
            var subs = SplitSegments(zh.Latin).SelectMany(x => ExpandSlashes(JSCompat.Trim(x))).Where(x => Clean(x).Length > 0).ToList();
            foreach (var p in subs.Count > 1 ? subs.Prepend(zh.Latin) : [zh.Latin]) sources.Add(new Source(p, false, false, true));
        }
        foreach (var v in sources)
        {
            var forms = MakeForms(v.Text, tol, lang);
            var id = $"{forms.Raw.Text}\u0001{(v.Omitted ? "true" : "false")}\u0001{(v.Pinyin ? "true" : "false")}";
            if (forms.Raw.Text.Length == 0 || !seen.Add(id)) continue;
            if (forms.Raw.Article is not null) AddArticle(JSCompat.Lower(forms.Raw.Article));
            variants.Add(new Variant(forms.Raw, forms.Exp, v.Omitted, v.Lock, v.Pinyin));
        }
        return new Alt(variants, articles);
    }

    sealed record PartMatch(Best? Best, bool WrongArticle, bool Near);

    /// <summary>Best match of a given part against one expected alternative.</summary>
    static PartMatch MatchPart(Forms part, Alt alt, Allow allow, Lang? lang)
    {
        Best? best = null;
        bool wrongArticle = false, near = false;
        var given = part.Raw.Article;
        bool conflict = given is not null && alt.Articles.Count > 0 && !alt.Articles.Any(a => SameArticle(given, a, lang));
        foreach (var v in alt.Variants)
        {
            if (conflict && v.Raw.Article is null)
            {
                if (FindCombo(part.Raw.Core, v.Raw.Core, NON_TYPO, lang) is not null) wrongArticle = true;
                continue;
            }
            bool artOk = allow.Art && (allow.HintPass || !v.Lock);
            var tries = new List<(Split G, Split E, bool UsedAbbr)> { (part.Raw, v.Raw, false) };
            if (allow.Abbr && (part.Exp is not null || v.Exp is not null)) tries.Add((part.Exp ?? part.Raw, v.Exp ?? v.Raw, true));
            foreach (var (g, e, usedAbbr) in tries)
            {
                var r = EvalPair(g, e, allow, artOk, lang);
                if (r.WrongArticle) wrongArticle = true;
                if (r.Near) near = true;
                if (r.Best is null) continue;
                int rank = r.Best.Rank + (usedAbbr ? 1 : 0) + (v.Omitted ? 3 : 0) + (v.Pinyin ? 1 : 0);
                if (best is null || rank < best.Rank)
                    best = r.Best with { Rank = rank, Abbr = usedAbbr, Paren = v.Omitted, Lock = v.Lock, Pinyin = v.Pinyin };
            }
        }
        return new PartMatch(best, wrongArticle, near);
    }

    // MARK: - Whole-answer evaluation

    sealed record Evaluation(bool Correct, HashSet<string>? Notes, List<List<PartMatch>>? Results, List<int>? Failing);

    static Evaluation Evaluate(List<Forms> parts, List<Alt> alts, Tolerance tol, Lang? lang)
    {
        var allow = new Allow(tol.IgnoreCase, tol.IgnoreAccents, tol.Typos, tol.Articles, tol.Abbreviations);
        var results = parts.Select(p => alts.Select(alt => MatchPart(p, alt, allow, lang)).ToList()).ToList();
        var edges = results.Select(row =>
        {
            bool blocked = row.Any(r => r.WrongArticle);
            var list = new List<(Best B, int J)>();
            for (int j = 0; j < row.Count; j++)
                if (row[j].Best is { } b && !(blocked && b.Combo.T)) list.Add((b, j));
            return list.OrderBy(x => x.B.Rank).ThenBy(x => x.J).ToList();
        }).ToList();
        var failing = new List<int>();
        for (int i = 0; i < edges.Count; i++) if (edges[i].Count == 0) failing.Add(i);
        if (failing.Count > 0) return new Evaluation(false, null, results, failing);

        var partOfAlt = Enumerable.Repeat(-1, alts.Count).ToArray();
        var altOfPart = Enumerable.Repeat(-1, parts.Count).ToArray();
        bool Assign(int i, HashSet<int> seen)
        {
            foreach (var edge in edges[i])
            {
                if (!seen.Add(edge.J)) continue;
                if (partOfAlt[edge.J] < 0 || Assign(partOfAlt[edge.J], seen))
                {
                    partOfAlt[edge.J] = i;
                    altOfPart[i] = edge.J;
                    return true;
                }
            }
            return false;
        }
        for (int i = 0; i < parts.Count; i++) Assign(i, []);
        int covered = partOfAlt.Count(i => i >= 0);
        if (!tol.MultipleAnswers && covered < alts.Count) return new Evaluation(false, null, results, failing);

        var notes = new HashSet<string>(StringComparer.Ordinal);
        var sequence = new List<int>();
        for (int i = 0; i < edges.Count; i++)
        {
            var list = edges[i];
            var chosen = list.FirstOrDefault(edge => edge.J == altOfPart[i]);
            if (chosen.B is null) chosen = list[0];
            sequence.Add(chosen.J);
            var b = chosen.B;
            if (b.Art is not null) notes.Add(b.Art);
            if (b.Abbr) notes.Add("abbreviation");
            if (b.Paren) notes.Add("parentheses");
            if (b.Pinyin) notes.Add("pinyin");
            if (b.Combo.C && lang == Lang.De) notes.Add("case");
            if (b.Combo.A) notes.Add(lang == Lang.Zh ? "tones" : "accents");
            if (b.Combo.V) notes.Add("variant");
            if (b.Combo.T) notes.Add("typo");
        }
        if (covered < alts.Count) notes.Add("partial");
        else if (sequence.Where((j, k) => k > 0 && j < sequence[k - 1]).Any()) notes.Add("order");
        return new Evaluation(true, notes, null, null);
    }

    static string? HintFromMatch(Best best, Tolerance tol, Lang? lang)
    {
        var (c, a, t, _) = best.Combo;
        if (best.Art is not null && (!tol.Articles || best.Lock)) return "missingArticle";
        bool offA = a && !tol.IgnoreAccents, offC = c && !tol.IgnoreCase, offT = t && !tol.Typos;
        if (!offA && !offC && !offT) return null;
        if (offA && !t) return offC ? "almost" : lang == Lang.Zh ? "tonesOnly" : "accentsOnly";
        if (offC && !t) return "caseOnly";
        if (offT) return "typo";
        return "almost";
    }

    static string SimFold(string s) => TextNormalizer.StripDiacritics(JSCompat.Lower(Clean(s)));

    static bool IsAlmost(string given, string target)
    {
        var a = SimFold(given);
        var b = SimFold(target);
        int len = Math.Max(JSCompat.Scalars(a).Count(), JSCompat.Scalars(b).Count());
        if (len == 0 || len > MAX_DIST_LEN) return false;
        int budget = (int)Math.Floor(len * (1 - ALMOST_SIMILARITY));
        return EditDistance(a, b, budget) <= budget;
    }

    static string? ComputeHint(List<Forms> parts, Evaluation res, List<Alt> alts, List<string> altTexts, Tolerance tol, Lang? lang, string givenText, string expectedText)
    {
        var found = new HashSet<string>(StringComparer.Ordinal);
        var hintAllow = new Allow(true, true, true, true, tol.Abbreviations, true);
        foreach (var i in res.Failing!)
        {
            if (res.Results![i].Any(r => r.WrongArticle)) found.Add("wrongArticle");
            foreach (var alt in alts)
            {
                var r = MatchPart(parts[i], alt, hintAllow, lang);
                if (r.WrongArticle) found.Add("wrongArticle");
                if (r.Near) found.Add("almost");
                if (r.Best is not null && HintFromMatch(r.Best, tol, lang) is { } h) found.Add(h);
            }
        }
        foreach (var h in HINT_ORDER) if (found.Contains(h)) return h;
        var targets = altTexts.Prepend(expectedText);
        return targets.Any(t => IsAlmost(givenText, t)) ? "almost" : null;
    }

    /// <summary>JS resolveLang: the grading language of a code ("de", "DE", " de-CH" → De); null for codes without articles.</summary>
    public static Lang? ResolveLang(string? code)
    {
        if (code is null) return null;
        var lowered = JSCompat.Lower(JSCompat.Trim(code));
        var shortCode = lowered.Length > 2 ? lowered[..2] : lowered;
        return ResolvedLang(LangExtensions.ParseLang(shortCode));
    }

    /// <summary>Only languages with an article table count; Other grades without articles.</summary>
    public static Lang? ResolvedLang(Lang? lang) => lang is { } l && ARTICLE_TABLE.ContainsKey(l) ? l : null;

    static string SymbolKey(string s) => JsRegex.ReplaceAll(s, @"\s+", "").Replace("...", "…");

    static GradeResult GradeInner(string given, string expected, Tolerance tol, Lang? lang, string expectedDisplay)
    {
        GradeResult Result(bool correct, bool exact, IReadOnlyList<GradeNote>? notes = null, string? hint = null) =>
            new(correct, exact, notes ?? [], EnumRaw.Parse<GradeHint>(hint), expectedDisplay);
        var L = ResolvedLang(lang);
        var gPrep = L == Lang.Zh ? ToneMarks(Prep(given)) : Prep(given);
        var ePrep = L == Lang.Zh ? ToneMarks(Prep(expected)) : Prep(expected);
        if (gPrep.Length == 0) return Result(false, false);

        bool commas = !IsSentenceLike(ePrep, L);
        var (eSegs, eNotes) = SplitInternal(ePrep, commas);
        var gSegs = SplitInternal(gPrep, commas, new HashSet<string>(eNotes.Select(NoteKey), StringComparer.Ordinal)).Alts;
        var eKey = string.Join("|", eSegs.Select(KeyOf));
        if (eKey.Length > 0 && string.Join("|", gSegs.Select(KeyOf)) == eKey) return Result(true, true);
        if (eSegs.Count == 0 && !HasAlnum(ePrep))
        {
            bool ok = SymbolKey(gPrep) == SymbolKey(ePrep);
            return Result(ok, ok);
        }

        var altTexts = L is { } lang2 ? MergeLoneArticles(eSegs, lang2) : eSegs;
        if (altTexts.Count > MAX_PARTS) altTexts = [ePrep];
        var alts = altTexts.Select(t => PrepareAlt(t, tol, L)).Where(a => a.Variants.Count > 0).ToList();
        Forms GivenPart(string t) => MakeForms(t, tol, L);
        var parts = (gSegs.Count > MAX_PARTS ? [gPrep] : gSegs).Select(GivenPart).Where(p => p.Raw.Text.Length > 0).ToList();
        if (alts.Count == 0 || parts.Count == 0) return Result(false, false);

        var readings = new List<List<Forms>> { parts };
        if (parts.Count > 1) readings.Add([GivenPart(gPrep)]);
        (List<Forms> Parts, Evaluation Res)? failure = null;
        foreach (var ps in readings)
        {
            var res = Evaluate(ps, alts, tol, L);
            if (res.Correct)
            {
                var notes = NOTE_ORDER.Where(res.Notes!.Contains).Select(n => EnumRaw.Parse<GradeNote>(n)!.Value).ToList();
                return Result(true, false, notes);
            }
            failure ??= (ps, res);
        }
        return Result(false, false, null, ComputeHint(failure!.Value.Parts, failure.Value.Res, alts, altTexts, tol, L, gPrep, ePrep));
    }

    /// <summary>Whether <paramref name="given"/> matches <paramref name="expected"/> under <paramref name="tolerance"/>; lang is the answer's language.</summary>
    public static GradeResult Grade(string? given, string? expected, Tolerance? tolerance = null, Lang? lang = null)
    {
        var expectedDisplay = expected ?? "";
        try
        {
            return GradeInner(given ?? "", expectedDisplay, tolerance ?? Tolerance.Default, lang, expectedDisplay);
        }
        catch (Exception)
        {
            // Safety net: grading must never break a study session.
            var g = TextNormalizer.NormalizeBasic(given ?? "");
            bool ok = g.Length > 0 && g == TextNormalizer.NormalizeBasic(expectedDisplay);
            return new GradeResult(ok, ok, [], null, expectedDisplay);
        }
    }

    // MARK: - Character diff for highlighting

    static List<string> Clusters(string s)
    {
        var scalars = JSCompat.Scalars(JSCompat.Trim(JSCompat.Nfc(s))).ToArray();
        var output = new List<string>();
        int i = 0;
        while (i < scalars.Length)
        {
            int j = i + 1;
            while (j < scalars.Length && TextNormalizer.IsMark(scalars[j])) j++;
            var sb = new StringBuilder();
            for (int k = i; k < j; k++) sb.AppendScalar(scalars[k]);
            output.Add(sb.ToString());
            i = j;
        }
        return output;
    }

    /// <summary>Character diff (NFC, trimmed): del = typed but wrong, add = missing; letters with their marks.</summary>
    public static List<DiffSegment> DiffChars(string? given, string? expected)
    {
        var a = Clusters(given ?? "");
        var b = Clusters(expected ?? "");
        var output = new List<DiffSegment>();
        void Push(DiffType type, IEnumerable<string> chars)
        {
            var text = string.Concat(chars);
            if (text.Length == 0) return;
            if (output.Count > 0 && output[^1].Type == type) output[^1] = output[^1] with { Text = output[^1].Text + text };
            else output.Add(new DiffSegment(type, text));
        }
        int pre = 0;
        while (pre < a.Count && pre < b.Count && a[pre] == b[pre]) pre++;
        int suf = 0;
        while (suf < a.Count - pre && suf < b.Count - pre && a[a.Count - 1 - suf] == b[b.Count - 1 - suf]) suf++;
        Push(DiffType.Same, a.Take(pre));
        var x = a.Skip(pre).Take(a.Count - suf - pre).ToList();
        var y = b.Skip(pre).Take(b.Count - suf - pre).ToList();
        int n = x.Count, m = y.Count;
        if (n > 0 && m > 0 && (long)(n + 1) * (m + 1) <= MAX_DIFF_CELLS)
        {
            int w = m + 1;
            var dp = new uint[(n + 1) * w];
            for (int i = n - 1; i >= 0; i--)
                for (int j = m - 1; j >= 0; j--)
                    dp[i * w + j] = x[i] == y[j] ? dp[(i + 1) * w + j + 1] + 1 : Math.Max(dp[(i + 1) * w + j], dp[i * w + j + 1]);
            int ii = 0, jj = 0;
            while (ii < n && jj < m)
            {
                if (x[ii] == y[jj]) { Push(DiffType.Same, [x[ii++]]); jj++; }
                else if (dp[(ii + 1) * w + jj] >= dp[ii * w + jj + 1]) Push(DiffType.Del, [x[ii++]]);
                else Push(DiffType.Add, [y[jj++]]);
            }
            Push(DiffType.Del, x.Skip(ii));
            Push(DiffType.Add, y.Skip(jj));
        }
        else
        {
            Push(DiffType.Del, x);
            Push(DiffType.Add, y);
        }
        Push(DiffType.Same, a.Skip(a.Count - suf));
        return output;
    }

    /// <summary>The number of typed-but-wrong plus missing characters of a diff (Swift <c>diffCost</c>).</summary>
    public static int DiffCost(IReadOnlyList<DiffSegment> parts) => parts.Sum(p => p.Type == DiffType.Same ? 0 : p.Text.Length);

    /// <summary>DiffChars for the answer feedback, with the normalisation grading treats as equal.</summary>
    public static List<DiffSegment> DiffAnswer(string? given, string? expected, Lang? lang = null)
    {
        var g = SqueezeApostrophes(TextNormalizer.NormalizeBasic(given ?? ""));
        var e = SqueezeApostrophes(TextNormalizer.NormalizeBasic(expected ?? ""));
        if (!HasLigature(g)) e = FoldLigatures(e);
        else if (!HasLigature(e)) g = FoldLigatures(g);
        if (TextNormalizer.HasArabic(e) && TextNormalizer.StripArabicMarks(g) == g) e = TextNormalizer.StripArabicMarks(e);
        if (ResolvedLang(lang) != Lang.Zh) return DiffChars(g, e);
        g = ToneMarks(g);
        e = ToneMarks(e);
        var parts = HanLatinParts(e);
        var best = DiffChars(g, e);
        if (parts is not null)
        {
            foreach (var form in new[] { parts.Han, parts.Latin })
            {
                var d = DiffChars(g, form);
                if (DiffCost(d) < DiffCost(best)) best = d;
            }
        }
        return best;
    }
}
