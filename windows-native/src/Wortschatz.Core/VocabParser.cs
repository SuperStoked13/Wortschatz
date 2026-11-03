using System.Text;

namespace Wortschatz.Core;

// Port of VocabParser.swift (+Context, +Lines, +Split, +Text, +Delimited, +LineBased) =
// src/core/parser.js: the smart vocabulary-list parser ("intelligente Texterkennung").
//
// Turns pasted, file-imported, PDF-extracted or OCR'd text into term/definition pairs. Handles
// delimited lists (tab, dash, equals, colon, semicolon, pipe, arrows, quoted CSV, Quizlet comma
// export, 2+ space PDF columns, 4-cell rows, 3-cell rows with an example or note column, page
// columns of "term – def" entries, mixed delimiters), line-based lists (blank-line blocks,
// alternating lines, wrapped continuation lines, two-column OCR order, number vocabulary) and
// noisy input (headings, page numbers, header rows, bullets). Ambiguous structure is resolved with
// per-line language detection. Never throws.
//
// The C# code follows parser.js function by function (same names, PascalCase); the Swift port
// spreads the same functions over VocabParser+*.swift (see PORTING.md). Languages are the JS
// codes ("fr", "de", …) inside the parser; the result uses Lang.

public enum ParseMode { Auto, Delimiter, Lines }

/// <summary>Options of ParseVocab (mode, delimiter, card separator, language hints, orient, swap).</summary>
public sealed record ParseOptions
{
    public ParseMode Mode { get; init; } = ParseMode.Auto;
    /// <summary>The delimiter for Mode == Delimiter (null = detect).</summary>
    public string? Delimiter { get; init; }
    public string CardSeparator { get; init; } = "\n";
    /// <summary>The learner's choice for the term side (null = detect).</summary>
    public Lang? TermLang { get; init; }
    /// <summary>The definition language (default de; null = none).</summary>
    public Lang? DefLang { get; init; } = Lang.De;
    public bool Orient { get; init; } = true;
    public bool Swap { get; init; }

    /// <summary>JS options object as the web app passes it (lenient).</summary>
    public static ParseOptions FromJson(JSONValue? json)
    {
        var o = json?.ObjectValue is null ? JSONValue.Obj() : json;
        Lang? Lang(JSONValue? v) => v?.StringValue is { } s ? LangExtensions.ParseLang(s) : null;
        return new ParseOptions
        {
            Mode = o["mode"]?.StringValue switch { "delimiter" => ParseMode.Delimiter, "lines" => ParseMode.Lines, _ => ParseMode.Auto },
            Delimiter = o["delimiter"]?.StringValue is { Length: > 0 } d ? d : null,
            CardSeparator = o["cardSeparator"]?.StringValue is { Length: > 0 } c ? c : "\n",
            TermLang = Lang(o["termLang"]),
            DefLang = o["defLang"] is null ? Core.Lang.De : Lang(o["defLang"]),
            Orient = o["orient"]?.BoolValue != false,
            Swap = o["swap"]?.BoolValue == true,
        };
    }
}

public enum ParseFormat { Empty, Delimited, Columns, Blocks, Alternating }
public enum ParseFlag { Merged, LowConfidence, LangMismatch, MissingTerm, MissingDefinition, Duplicate }
public enum SkipReason { Heading, PageNumber, Noise, Unpaired }

public sealed record ParsedCard(string Term, string Definition, double Confidence, IReadOnlyList<ParseFlag> Flags, IReadOnlyList<int> Lines) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("term", Term), ("definition", Definition), ("confidence", Confidence),
        ("flags", JSONValue.Array(Flags.Select(f => f.ToJson()))), ("lines", Lines.ToJsonArray()));
}

public sealed record SkippedLine(int Line, string Text, SkipReason Reason) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("line", Line), ("text", Text), ("reason", Reason.ToJson()));
}

public sealed record ParseResult(IReadOnlyList<ParsedCard> Cards, ParseFormat Format, string? Delimiter, Lang TermLang, Lang DefLang,
    bool Swapped, IReadOnlyList<SkippedLine> Skipped, IReadOnlyList<string> Warnings) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("cards", Cards.ToJsonArray()), ("format", Format.ToJson()), ("delimiter", JSONValue.String(Delimiter)),
        ("termLang", TermLang.ToJson()), ("defLang", DefLang.ToJson()), ("swapped", Swapped), ("skipped", Skipped.ToJsonArray()),
        ("warnings", Warnings.ToJsonArray()));
}

public static partial class VocabParser
{
    static readonly string[] LANG_CODES = ["fr", "de", "en", "es", "it", "ar", "zh", "other"];
    static readonly string[] SUPPORTED = ["fr", "de", "en", "es", "it", "ar", "zh"];
    static readonly Dictionary<string, double> BASE_PRIOR = new() { ["fr"] = 0.2, ["de"] = 0.25, ["en"] = 0.1, ["es"] = 0.05, ["it"] = 0, ["ar"] = 0, ["zh"] = 0 };
    static bool IsScriptLang(string l) => l is "ar" or "zh";

    const double CLIP = 0.04;
    const double PAIR_K = 0.9;
    const double MERGE_COST = 1.5;
    const double UNPAIRED_COST = 4;
    const double RUN_UNPAIRED_COST = 1.5;
    const double WEAK_HEADING_COST = 0.6;
    const double HEADING_SKIP_COST = 2.5;
    const double HEADING_MERGE_COST = 3;
    const double DELIM_SPLIT_COST = 0.3;
    const double LANG_SPLIT_COST = 1.2;
    const double SPLIT_MISFIT = 2;
    const double SPLIT_MARGIN = 0.5;
    static readonly Dictionary<string, (double M, double J)> BOUNDARY = new()
    {
        ["none"] = (0, 0), ["weak"] = (1, 0), ["medium"] = (2.5, 1.5), ["strong"] = (5, 5),
    };

    const string PAGE_RE = @"^(?:-\s*)?(?:(?:seite|page|pagina|página|pag\.?|s\.|p\.)\s*)?\d{1,4}(?:\s*(?:\/|von|of|sur|de|di)\s*\d{1,4})?(?:\s*-)?$";
    const string URL_RE = @"(?:https?:\/\/|www\.)\S|^©|^\(c\)\s";
    const string KEYWORD_RE = @"^(?:seite|page|unit[eé]?|unit[aà]|lektion|le[cç]on|lesson|chapitre|chapter|kapitel|capitolo|cap[ií]tulo|unidad|lezione|lecci[oó]n|module?|th[eè]me|thema|tema|vocabulaire|vocabulary|vocabulario|vocabolario|wortschatz|vokabeln|vokabular|glossar|glossaire|dossier|[eé]tape|abschnitt|section)(?!\p{L})";
    const string ALWAYS_HEADING_RE = @"^(?:vocabulaire|vocabulary|vocabulario|vocabolario|wortschatz|vokabeln|vokabular|glossar|glossaire)(?!\p{L})";
    const string ROMAN_RE = @"(?:^|\s)[IVXLC]{1,6}(?=[.:)]|\s|$)";
    const string MARKER_RE = @"^(?:\(?\d{1,3}[.)]|\d{1,3} ?[-:]|\(?[a-z]\)|[•·▪▫◦‣○●■□➢►▶✓✔✗☐*+>-])[ \t]+";
    const string NUMBER_CELL_RE = @"^\d{1,4}[.)]?\t";
    const string NUMBERED_RE = @"^\d{1,3} ?[-:][ \t]+";
    const string BARE_NUMBER_RE = @"^\d{1,4}$";
    const string ARROW_RE = @"\s*(?:<->|<=>|-->|->|=>|→|⇒|⟶|↔|⟹|➔|➜)\s*";
    /// <summary>JS whitespace without tab and newline (<c>[^\S\t\n]</c>).</summary>
    const string WS_NO_TAB_NL = @"[\v\f\r    -     　﻿]";

    static readonly Dictionary<string, string> LANG_NAMES = BuildLangNames();
    static Dictionary<string, string> BuildLangNames()
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (concept, names) in new[]
        {
            ("fr", "französisch franzoesisch franz frz français francais french francés frances francese"),
            ("de", "deutsch allemand german alemán aleman tedesco"),
            ("en", "englisch anglais english inglés ingles inglese"),
            ("es", "spanisch espagnol spanish español espanol spagnolo"),
            ("it", "italienisch italien italian italiano"),
            ("ar", "arabisch arabe arabic árabe arabo عربي العربية"),
            ("zh", "chinesisch chinois chinese chino cinese mandarin 中文 汉语 漢語 普通话 普通話"),
        })
            foreach (var name in names.Split(' ')) map[name] = concept;
        return map;
    }

    static readonly Dictionary<string, string> LABELS = new(StringComparer.Ordinal)
    {
        ["begriff"] = "term", ["begriffe"] = "term", ["term"] = "term", ["terms"] = "term", ["terme"] = "term", ["definition"] = "def",
        ["définition"] = "def", ["definitionen"] = "def", ["wort"] = "word", ["wörter"] = "word", ["vokabel"] = "word", ["mot"] = "word",
        ["mots"] = "word", ["word"] = "word", ["words"] = "word", ["palabra"] = "word", ["parola"] = "word", ["übersetzung"] = "trans",
        ["uebersetzung"] = "trans", ["traduction"] = "trans", ["translation"] = "trans", ["traducción"] = "trans", ["traduzione"] = "trans",
        ["bedeutung"] = "meaning", ["meaning"] = "meaning", ["signification"] = "meaning", ["frage"] = "q", ["question"] = "q",
        ["antwort"] = "a", ["answer"] = "a", ["réponse"] = "a", ["pinyin"] = "pinyin",
    };
    static readonly HashSet<string> CODES = new(StringComparer.Ordinal) { "FR", "DE", "EN", "ES", "IT", "AR", "ZH" };

    static readonly HashSet<string> OPEN_ENDINGS = new(
        (@"der die das den dem des ein eine einen einem einer le la les l' un une du de à au aux et ou und oder the a
   an to of and or el los las il lo gli i e y o sich se s' zu mit von für auf in en dans pour avec sur par chez
   sans sous vers entre que ne jdm jdn jds etw über unter bei gegen ohne durch zum zur im am beim vom with for
   from at on by into about").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries), StringComparer.Ordinal);
    const string DE_ARTICLE_RE = @"(?:^|\s)(?:sich|der|die|das|den|dem|des|ein|eine|einen|einem|einer)\s";
    const string FR_OBJECT_END_RE = @"\s(?:le|la|les|un|une|du|des)\s\p{Ll}+$";
    const string ENTRY_START_RE = @"^(?:(?:le|la|les|un|une|des|du|der|die|das|den|dem|ein|eine|the|a|an|to|el|los|las|il|lo|gli|uno|una|se|sich)\s|(?:l|d)'|s'(?!ils?\s))";

    /// <summary>A delimiter candidate. Compared by reference (like the JS objects).</summary>
    sealed class Cand(string id, string kind, string? re = null, string? joiner = null, string? spaced = null)
    {
        public string Id { get; } = id;
        /// <summary>"cells" | "first" | "regex" | "csv" | "gap"</summary>
        public string Kind { get; } = kind;
        public string? Re { get; } = re;
        public string? Joiner { get; } = joiner;
        public string? Spaced { get; } = spaced;
    }

    static readonly Cand[] CANDIDATES =
    [
        new("\t", "cells"),
        new(" - ", "first"),
        new(" → ", "regex", ARROW_RE),
        new(" = ", "first"),
        new("=", "first"),
        new(" : ", "first"),
        new(": ", "first"),
        new(": ", "regex", @"\s*：\s*", "："),
        new(";", "csv"),
        new("|", "csv"),
        new("  ", "gap"),
    ];
    static readonly Cand GAP = CANDIDATES[^1];
    static readonly Cand COMMA = new(",", "csv");
    static readonly Cand TIGHT_COMMA = new(",", "regex", @",(?![\s,])", ", ");
    static readonly Cand[] INNER_CANDIDATES = CANDIDATES.Where(c => c.Kind is "first" or "regex").ToArray();

    // MARK: - Public API

    public static ParseResult ParseVocab(string? text, ParseOptions? options = null)
    {
        Opts? o = null;
        try
        {
            o = NormalizeOptions(options ?? new ParseOptions());
            return ParseInternal(text ?? "", o);
        }
        catch (Exception)
        {
            var fallback = o ?? NormalizeOptions(new ParseOptions());
            return new ParseResult([], ParseFormat.Empty, null, ToLang(fallback.TermHintRaw ?? "other"), ToLang(fallback.DefHintRaw ?? "de"), false, [],
                ["Der Text konnte nicht verarbeitet werden."]);
        }
    }

    static Lang ToLang(string code) => LangExtensions.ParseLang(code) ?? Lang.Other;

    // MARK: - Options & language helpers

    sealed record Opts(string Mode, string? Delimiter, string CardSeparator, string? TermHintRaw, string? DefHintRaw, string? TermHint, string? DefHint, bool Orient, bool Swap);

    static Opts NormalizeOptions(ParseOptions p)
    {
        var termHintRaw = p.TermLang?.Raw();
        var defHintRaw = p.DefLang?.Raw();
        return new Opts(
            p.Mode switch { ParseMode.Delimiter => "delimiter", ParseMode.Lines => "lines", _ => "auto" },
            p.Delimiter is { Length: > 0 } ? p.Delimiter : null,
            p.CardSeparator is { Length: > 0 } ? p.CardSeparator : "\n",
            termHintRaw, defHintRaw,
            termHintRaw is not null && termHintRaw != "other" ? termHintRaw : null,
            defHintRaw is not null && defHintRaw != "other" ? defHintRaw : null,
            p.Orient, p.Swap);
    }

    /// <summary>Language scores of a text, keyed by JS code.</summary>
    sealed class Scores(Dictionary<Lang, double> s)
    {
        public double this[string code] => code switch
        {
            "fr" => s[Lang.Fr], "de" => s[Lang.De], "en" => s[Lang.En], "es" => s[Lang.Es], "it" => s[Lang.It], "ar" => s[Lang.Ar], "zh" => s[Lang.Zh],
            _ => double.NaN,
        };
    }

    sealed class Ctx(Opts o)
    {
        readonly Dictionary<string, Scores> _cache = new(StringComparer.Ordinal);
        public Opts O { get; } = o;
        public Dictionary<string, double> Prior { get; } = MakePrior(o);
        public List<SkippedLine> Skipped { get; } = [];
        public Warnings Warnings { get; } = new();
        public (string? Left, string? Right)? Header;

        static Dictionary<string, double> MakePrior(Opts o)
        {
            var prior = new Dictionary<string, double>(BASE_PRIOR);
            if (o.TermHint is { } t) prior[t] += 0.4;
            if (o.DefHint is { } d) prior[d] += 0.3;
            return prior;
        }

        public Scores Score(string text)
        {
            if (!_cache.TryGetValue(text, out var s)) _cache[text] = s = new Scores(LangDetect.ScoreLanguages(text));
            return s;
        }
    }

    static bool HasEvidence(Scores s) => SUPPORTED.Any(l => s[l] >= 0.3);

    /// <summary>Probability that <paramref name="text"/> is in language A rather than B.</summary>
    static double PairProb(Ctx ctx, string? text, string? A, string? B)
    {
        if (A is null || B is null || A == B || string.IsNullOrEmpty(text)) return 0.5;
        var s = ctx.Score(text);
        return 1 / (1 + Math.Exp(-PAIR_K * (s[A] - s[B])));
    }

    static double Clip(double p) => Math.Min(1 - CLIP, Math.Max(CLIP, p));
    static double Nlog(double p) => -Math.Log(Clip(p));

    /// <summary>Soft language votes over many texts (hint-aware prior), sorted by share (stable).</summary>
    static List<(string Lang, double Share)> LanguageShares(Ctx ctx, IEnumerable<string> texts)
    {
        var votes = SUPPORTED.ToDictionary(l => l, _ => 0.0);
        int n = 0;
        foreach (var t in texts)
        {
            var s = ctx.Score(t);
            if (!HasEvidence(s)) continue;
            var langs = SUPPORTED.Where(l => !IsScriptLang(l) || s[l] > 0).ToList();
            double max = double.NegativeInfinity;
            foreach (var l in langs) max = Math.Max(max, s[l] + ctx.Prior[l]);
            double sum = 0;
            var e = new Dictionary<string, double>();
            foreach (var l in langs) sum += e[l] = Math.Exp(s[l] + ctx.Prior[l] - max);
            foreach (var l in langs) votes[l] += e[l] / sum;
            n++;
        }
        return SUPPORTED.Select((lang, i) => (lang, share: n > 0 ? votes[lang] / n : 0, i))
            .OrderByDescending(x => x.share).ThenBy(x => x.i).Select(x => (x.lang, x.share)).ToList();
    }

    static (string? L1, string? L2) TopTwoLanguages(Ctx ctx, IEnumerable<string> texts)
    {
        var shares = LanguageShares(ctx, texts);
        if (shares[0].Share == 0) return (null, null);
        return (shares[0].Lang, shares[1].Share >= 0.1 ? shares[1].Lang : null);
    }

    static string? DetectColumnLang(IEnumerable<string> texts)
    {
        var lang = LangDetect.DetectColumn(texts).Lang;
        return lang == DetectedLanguage.Unknown ? null : lang.Raw();
    }

    // MARK: - Small text helpers

    static bool HasLetter(string s) => JSCompat.Scalars(s).Any(TextNormalizer.IsLetterScalar);
    static bool StartsUpper(string s) => s.Length > 0 && TextNormalizer.IsUppercaseLetter(JSCompat.Scalars(s).First());
    static bool StartsLower(string s) => s.Length > 0 && TextNormalizer.IsLowercaseLetter(JSCompat.Scalars(s).First());
    static bool HasScriptText(string s) => JSCompat.Scalars(s).Any(u => TextNormalizer.IsArabicScalar(u) || TextNormalizer.IsHanScalar(u));
    static string[] SpaceSplit(string s) => s.Split(' ');
    static List<int> SortedUnique(IEnumerable<int> lines) => lines.Distinct().OrderBy(x => x).ToList();

    // MARK: - Preprocessing & line classification

    const string GLUED_DASH_RE = @"(\p{L}[.!?)）]?)[–—](?=[\p{L}(（«""„“])";

    static bool GluedDash(string raw) =>
        raw.Count(c => c is '–' or '—') == 1 && !JsRegex.Test(@"\t|\s[-–—]\s", raw) && JsRegex.Test(GLUED_DASH_RE, raw);

    const string BRACKET_DASH_RE = @"([)）])([-–—])(?=[  　])";

    static string SpaceBracketDash(string raw)
    {
        if (!HasScriptText(raw) || JsRegex.Test(@"\t|\s[-–—]\s", raw)) return raw;
        return JsRegex.ReplaceAll(raw, BRACKET_DASH_RE, "$1 $2");
    }

    static List<string> SpaceGluedDashes(List<string> input, bool? dashList = null)
    {
        var raws = dashList == false ? input : input.Select(SpaceBracketDash).ToList();
        bool rewrite;
        if (dashList is { } d) rewrite = d;
        else
        {
            var content = raws.Where(r => JSCompat.Trim(r).Length > 0).ToList();
            int glued = content.Count(GluedDash);
            int spaced = content.Count(r => JsRegex.Test(@"\s[-–—]\s", r));
            rewrite = glued > 0 && glued + spaced >= 0.6 * content.Count;
        }
        return rewrite ? raws.Select(r => GluedDash(r) ? JsRegex.ReplaceFirst(r, GLUED_DASH_RE, "$1 - ") : r).ToList() : raws;
    }

    sealed class Line
    {
        public int No;
        public List<int> Span = [];
        public string Raw = "";
        public string Text = "";
        public string Gap = "";
        public bool Blank;
        public string? Kind;
        public bool Weak;
        public int Indent;

        /// <summary>The <c>{ text }</c> objects the JS passes to splitWith.</summary>
        public static Line FromText(string text) => new() { Text = text, Gap = text };
    }

    static Line MakeLine(string raw, int no)
    {
        var b = TextNormalizer.NormalizeBasic(raw, keepTabs: true);
        if (b.Length == 0) return new Line { No = no, Span = [no], Raw = raw, Text = "", Gap = "", Blank = true };
        string KeepEdges(string s)
        {
            var output = JsRegex.ReplaceAll(s, @"\t{2,}", "\t");
            if (JsRegex.Test("^" + WS_NO_TAB_NL + @"*\t", raw) && !output.StartsWith('\t')) output = "\t" + output;
            if (JsRegex.Test(@"\t" + WS_NO_TAB_NL + "*$", raw) && !output.EndsWith('\t')) output += "\t";
            return output;
        }
        var text = KeepEdges(b);
        var gap = KeepEdges(TextNormalizer.NormalizeBasic(JsRegex.ReplaceAll(raw, @"[   -   　]{2,}", "\t"), keepTabs: true));
        int leadLen = 0;
        while (leadLen < raw.Length && raw[leadLen] is ' ' or '\t' or ' ') leadLen++;
        int tabs = raw[..leadLen].Count(c => c == '\t');
        return new Line { No = no, Span = [no], Raw = raw, Text = text, Gap = gap, Indent = leadLen + 3 * tabs };
    }

    static int QuoteCount(string s) => s.Count(c => c == '"');

    static List<Line> Preprocess(string source, bool? dashList = null)
    {
        var t = source;
        if (t.Length > 0 && t[0] == '﻿') t = t[1..];
        t = JsRegex.ReplaceAll(JsRegex.ReplaceAll(t, @"\r\n?", "\n"), @"[  \u0085\v\f]", "\n");
        var raws = SpaceGluedDashes(t.Split('\n').ToList(), dashList);
        var lines = new List<Line>();
        for (int i = 0; i < raws.Count; i++)
        {
            var raw = raws[i];
            var span = new List<int> { i + 1 };
            if (QuoteCount(raw) % 2 == 1 && JsRegex.Test("(?:^|[,;\\t|])\\s*\"[^\"]*$", raw))
            {
                var joined = raw;
                for (int j = i + 1; j < raws.Count && j <= i + 4 && JSCompat.Trim(raws[j]).Length > 0; j++)
                {
                    joined += " " + raws[j];
                    if (QuoteCount(joined) % 2 == 0)
                    {
                        raw = joined;
                        for (int k = i + 1; k <= j; k++) span.Add(k + 1);
                        i = j;
                        break;
                    }
                }
            }
            var line = MakeLine(raw, span[0]);
            line.Span = span;
            lines.Add(line);
        }
        return lines;
    }

    static string DisplayText(Line line) => JSCompat.Trim(line.Text.Replace('\t', ' '));

    static void Skip(Ctx ctx, Line line, string reason)
    {
        line.Kind = reason;
        ctx.Skipped.Add(new SkippedLine(line.No, DisplayText(line), EnumRaw.Parse<SkipReason>(reason)!.Value));
    }

    static string StripMarker(string s)
    {
        var output = JsRegex.ReplaceFirst(s, MARKER_RE, "");
        if (JsRegex.Test(NUMBER_CELL_RE, output))
        {
            var rest = JsRegex.ReplaceFirst(output, NUMBER_CELL_RE, "");
            if (JsRegex.Test(@"\t| - | = |: ", rest)) output = rest;
        }
        return output;
    }

    /// <summary>Header row naming the languages or columns ("Französisch | Deutsch", "Begriff - Definition").</summary>
    static (string? Left, string? Right)? HeaderRow(string text)
    {
        var words = JsRegex.Split(text, @"[^\p{L}.]+").Select(w => JsRegex.ReplaceFirst(w, @"\.+$", "")).Where(w => w.Length > 0).ToList();
        if (words.Count < 2 || words.Count > 6) return null;
        if (words.All(CODES.Contains) && words.Distinct().Count() == words.Count) return (JSCompat.Lower(words[0]), JSCompat.Lower(words[1]));
        var langs = new List<string>();
        var labels = new List<string>();
        foreach (var w in words)
        {
            var lw = JSCompat.Lower(w);
            if (LANG_NAMES.TryGetValue(lw, out var l)) langs.Add(l);
            else if (LABELS.TryGetValue(lw, out var lab)) labels.Add(lab);
            else return null;
        }
        if (langs.Distinct().Count() != langs.Count || labels.Distinct().Count() != labels.Count) return null;
        if (langs.Count >= 2) return (langs[0], langs[1]);
        return (null, null);
    }

    static (bool KeepMarkers, bool KeepBare) NumberVocabulary(Ctx ctx, List<Line> lines)
    {
        var flat = lines.Where(l => !l.Blank).Select(DisplayText).ToList();
        var numbered = flat.Where(t => JsRegex.Test(NUMBERED_RE, t)).ToList();
        bool keepMarkers = false;
        if (numbered.Count >= 2 && numbered.Count >= 0.8 * flat.Count)
            keepMarkers = NumberWords(ctx, numbered.Select(t => JsRegex.ReplaceFirst(t, NUMBERED_RE, "")).ToList());
        var bare = flat.Select(t => JsRegex.Test(BARE_NUMBER_RE, t)).ToList();
        int alternations = 0;
        for (int k = 1; k < flat.Count; k++) if (bare[k] != bare[k - 1]) alternations++;
        bool keepBare = bare.Count(b => b) >= 3 && alternations >= 0.8 * (flat.Count - 1)
            && NumberWords(ctx, flat.Where((_, k) => !bare[k]).ToList());
        return (keepMarkers, keepBare);
    }

    static bool NumberWords(Ctx ctx, List<string> words)
    {
        if (words.Count(t => JsRegex.Test(@"\t| - | = |=| : |: |;|\||->|→", t)) > 0.2 * words.Count) return false;
        var shares = LanguageShares(ctx, words);
        if (shares[1].Share >= 0.3) return false;
        var (L1, L2) = (shares[0].Lang, shares[1].Lang);
        return words.Count(t => LanguageSplit(ctx, t, L1, L2) is not null) <= 0.2 * words.Count;
    }

    static List<Line> Classify(Ctx ctx, List<Line> lines)
    {
        var numbers = NumberVocabulary(ctx, lines);
        foreach (var line in lines)
        {
            if (line.Blank) continue;
            var flat = DisplayText(line);
            if (numbers.KeepBare && JsRegex.Test(BARE_NUMBER_RE, flat)) continue;
            if (JsRegex.Test(PAGE_RE, flat, "iu")) { Skip(ctx, line, "pageNumber"); continue; }
            if (!HasLetter(flat) || JsRegex.Test(URL_RE, flat, "i")) { Skip(ctx, line, "noise"); continue; }
            if (!numbers.KeepMarkers || !JsRegex.Test(NUMBERED_RE, flat))
            {
                line.Text = StripMarker(line.Text);
                line.Gap = StripMarker(line.Gap);
            }
            var t = DisplayText(line);
            if (!HasLetter(t)) { Skip(ctx, line, "noise"); continue; }
            var header = HeaderRow(t);
            if (header is { } h)
            {
                if (ctx.Header is null && h.Left is not null) ctx.Header = h;
                Skip(ctx, line, "heading");
                continue;
            }
            var kw = JsRegex.Match(t, KEYWORD_RE, "iu");
            if (kw is not null)
            {
                var rest = JsRegex.ReplaceFirst(t[kw.Value.Length..], @"^[\s:.-]+", "");
                bool title = StartsUpper(t) && !(JsRegex.Test(KEYWORD_RE, rest, "iu") && !JsRegex.Test(@"\s", rest));
                if (JsRegex.Test(@"\d", rest) || JsRegex.Test(ROMAN_RE, rest) || (rest.Length > 0 && title && JsRegex.Test(ALWAYS_HEADING_RE, t, "iu")))
                {
                    Skip(ctx, line, "heading");
                    continue;
                }
                if (rest.Length == 0) line.Weak = true;
            }
            if (JsRegex.Test(@"^\p{Lu}$", t)) { Skip(ctx, line, "heading"); continue; }
            if (JsRegex.Test(@"^\p{Ll}$", t) || (JsRegex.Test(@"^[^\p{Ll}]+$", t) && JsRegex.MatchAll(t, @"\p{Lu}").Count >= 4)) line.Weak = true;
        }
        return lines;
    }

    // MARK: - Splitting helpers

    /// <summary>Delimiter-separated fields with double-quote support ("a, b","c").</summary>
    static List<string> CsvSplit(string text, string delim)
    {
        var cells = new List<string>();
        int i = 0;
        while (true)
        {
            int j = i;
            while (j < text.Length && text[j] == ' ') j++;
            if (j < text.Length && text[j] == '"')
            {
                int k = j + 1;
                var val = new StringBuilder();
                while (k < text.Length)
                {
                    if (text[k] == '"')
                    {
                        if (k + 1 < text.Length && text[k + 1] == '"') { val.Append('"'); k += 2; continue; }
                        break;
                    }
                    val.Append(text[k++]);
                }
                if (k >= text.Length)
                {
                    cells.Add(JSCompat.Trim(text[j..]));
                    break;
                }
                int next = text.IndexOf(delim, k + 1, StringComparison.Ordinal);
                if (next == -1)
                {
                    cells.Add(JSCompat.Trim(val + text[(k + 1)..]));
                    break;
                }
                cells.Add(JSCompat.Trim(val + text[(k + 1)..next]));
                i = next + delim.Length;
            }
            else
            {
                int next = text.IndexOf(delim, Math.Min(i, text.Length), StringComparison.Ordinal);
                if (next == -1)
                {
                    cells.Add(JSCompat.Trim(i <= text.Length ? text[i..] : ""));
                    break;
                }
                cells.Add(JSCompat.Trim(text[i..next]));
                i = next + delim.Length;
            }
        }
        return cells;
    }

    static readonly string[] QUOTE_PAIRS = ["\"\"", "“”", "„“", "„”", "«»", "»«", "‹›", "''"];

    /// <summary>Strip one pair of surrounding quotes.</summary>
    static string Unquote(string s)
    {
        var t = JSCompat.Trim(s);
        if (t.Length >= 2 && QUOTE_PAIRS.Contains($"{t[0]}{t[^1]}"))
        {
            var inner = t[1..^1];
            if (!inner.Contains(t[0]) && !inner.Contains(t[^1])) return JSCompat.Trim(inner);
        }
        return t;
    }

    static Cand CustomCandidate(string delim)
    {
        if (delim == "\t") return new Cand("\t", "cells");
        if (delim is "," or ";" or "|") return new Cand(delim, "csv");
        var spaced = JSCompat.Trim(delim) == delim && JsRegex.Test(@"^[^\p{L}\p{N}]+$", delim) ? $" {delim} " : null;
        return new Cand(delim, "first", spaced: spaced);
    }

    readonly record struct SplitResult(List<string> Parts, string Joiner);

    /// <summary>Split one line with a candidate. One part = delimiter absent.</summary>
    static SplitResult SplitWith(Line line, Cand cand)
    {
        if (cand.Kind is "cells" or "gap")
        {
            var src = cand.Kind == "gap" ? line.Gap : line.Text;
            if (!src.Contains('\t')) return new([JSCompat.Trim(src)], ", ");
            return new(CsvSplit(src, "\t").Select(Unquote).ToList(), ", ");
        }
        var text = JSCompat.Trim(line.Text.Replace('\t', ' '));
        if (cand.Kind == "csv")
        {
            var cells = CsvSplit(text, cand.Id);
            var joiner = cand.Id is ";" or "," ? cand.Id + " " : ", ";
            if (cand.Id == "|" && cells.Count > 2)
            {
                bool lead = cells[0] == "";
                bool trail = cells[^1] == "";
                if (lead && trail) return new(cells[1..^1], joiner);
                if (lead || trail) return new(lead ? cells[1..] : cells[..^1], joiner);
            }
            return new(cells, joiner);
        }
        if (cand.Kind == "regex")
            return new(JsRegex.Split(text, cand.Re!).Select(Unquote).ToList(), cand.Joiner ?? cand.Id);
        var delim = cand.Spaced is { } sp && text.Contains(sp, StringComparison.Ordinal) ? sp : cand.Id;
        if (text.Contains(delim, StringComparison.Ordinal)) return new(text.Split(delim).Select(Unquote).ToList(), delim);
        var bare = JSCompat.Trim(delim);
        if (bare.Length > 0 && bare != delim)
        {
            if (text.EndsWith(" " + bare, StringComparison.Ordinal)) return new([Unquote(text[..^(bare.Length + 1)]), ""], delim);
            if (text.StartsWith(bare + " ", StringComparison.Ordinal)) return new(["", Unquote(text[(bare.Length + 1)..])], delim);
        }
        return new([text], delim);
    }

    /// <summary>How many cards a split represents for detection purposes (0 = not a pairing).</summary>
    static int PairingCount(List<string> parts, Cand cand)
    {
        if (parts.Count < 2) return 0;
        int filled = parts.Count(p => p != "");
        if (cand == COMMA || cand == TIGHT_COMMA) return parts.Count == 2 && filled == 2 ? 1 : 0;
        if (cand.Kind is "cells" or "gap" && parts.Count >= 4 && parts.Count % 2 == 0 && filled == parts.Count) return parts.Count / 2;
        if (filled == parts.Count) return 1;
        return parts.Count == 2 && filled == 1 ? 1 : 0;
    }

    /// <summary>Reduce &gt;2 parts to [term, definition] at the strongest language contrast.</summary>
    static (List<string> Parts, bool Uncertain) ResolveSplit(Ctx ctx, List<string> rawParts, string? A, string? B, string joiner)
    {
        if (rawParts.Count <= 2) return (rawParts, false);
        var parts = rawParts.Where(p => p != "").ToList();
        if (parts.Count < 2) return ([parts.Count > 0 ? parts[0] : "", ""], false);
        int best = 1;
        bool uncertain = false;
        if (A is not null && B is not null && A != B)
        {
            var d = parts.Select(p => { var s = ctx.Score(p); return s[A] - s[B]; }).ToList();
            var prefixes = new List<double>();
            double prefix = 0;
            for (int k = 1; k < parts.Count; k++)
            {
                prefix += d[k - 1];
                prefixes.Add(prefix);
                if (prefix > prefixes[best - 1] + 1e-9) best = k;
            }
            double runnerUp = double.NegativeInfinity;
            for (int i = 0; i < prefixes.Count; i++) if (i != best - 1) runnerUp = Math.Max(runnerUp, prefixes[i]);
            bool misplaced = d.Select((v, i) => i < best ? v <= -SPLIT_MISFIT : v >= SPLIT_MISFIT).Any(x => x);
            uncertain = misplaced || prefixes[best - 1] - runnerUp < SPLIT_MARGIN;
        }
        return ([string.Join(joiner, parts.Take(best)), string.Join(joiner, parts.Skip(best))], uncertain);
    }

    static List<string> ResolveParts(Ctx ctx, List<string> rawParts, string? A, string? B, string joiner) => ResolveSplit(ctx, rawParts, A, B, joiner).Parts;

    readonly record struct Seg(int Start, int End);

    /// <summary>Word segments: split at whitespace and at - , ; glued between letters.</summary>
    static List<Seg> Segments(string text)
    {
        var segs = new List<Seg>();
        foreach (System.Text.RegularExpressions.Match m in JsRegex.Get(@"\S+").Matches(text))
        {
            int start = m.Index;
            var chunk = m.Value;
            for (int i = 1; i < chunk.Length - 1; i++)
            {
                if ("-,;".Contains(chunk[i]) && IsLetterAt(chunk, i - 1) && IsLetterAt(chunk, i + 1))
                {
                    segs.Add(new Seg(start, m.Index + i));
                    start = m.Index + i + 1;
                }
            }
            segs.Add(new Seg(start, m.Index + chunk.Length));
        }
        return segs;
    }

    /// <summary><c>/\p{L}/u.test(s[i])</c> on one UTF-16 unit.</summary>
    static bool IsLetterAt(string s, int i) => !char.IsSurrogate(s[i]) && TextNormalizer.IsLetterScalar(s[i]);

    static (string Left, string Right) CutAt(string text, List<Seg> segs, int k) => (
        Unquote(JsRegex.ReplaceFirst(text[..segs[k - 1].End], @"[\s\-=:;,/|>→]+$", "")),
        Unquote(JsRegex.ReplaceFirst(text[segs[k].Start..], @"^[\s\-=:;,/|<>→]+", "")));

    sealed record LangSplitResult(string Left, string Right, int Order, double Score);

    /// <summary>Split a single bilingual line ("le chat die Katze") at the strongest language contrast.</summary>
    static LangSplitResult? LanguageSplit(Ctx ctx, string rawText, string? A, string? B)
    {
        if (A is null || B is null || A == B) return null;
        var text = rawText.Replace('\t', ' ');
        var segs = Segments(text);
        if (segs.Count < 2 || segs.Count > 24) return null;
        var tokens = segs.Select(sg => text[sg.Start..sg.End]).ToList();
        var d = tokens.Select(tok => { var s = ctx.Score(tok); return s[A] - s[B]; }).ToList();
        double total = d.Aggregate(0.0, (a, b) => a + b);
        double prefix = 0;
        (int K, double V, int Order)? best = null;
        for (int k = 1; k < tokens.Count; k++)
        {
            prefix += d[k - 1];
            double suffix = total - prefix;
            double v1 = Math.Min(prefix, -suffix);
            double v2 = Math.Min(-prefix, suffix);
            if (best is null || v1 > best.Value.V) best = (k, v1, 1);
            if (v2 > best.Value.V) best = (k, v2, -1);
        }
        if (best is null || best.Value.V < 1) return null;
        var (left, right) = CutAt(text, segs, best.Value.K);
        if (!HasLetter(left) || !HasLetter(right)) return null;
        double pl = PairProb(ctx, left, A, B), pr = PairProb(ctx, right, A, B);
        double score = best.Value.Order == 1 ? Math.Min(pl, 1 - pr) : Math.Min(1 - pl, pr);
        return score >= 0.8 ? new LangSplitResult(left, right, best.Value.Order, score) : null;
    }

    /// <summary>A line of exactly two words that lean to different languages ("chien Hund").</summary>
    static LangSplitResult? TwoWordSplit(Ctx ctx, string rawText, string A, string B)
    {
        var text = rawText.Replace('\t', ' ');
        var segs = Segments(text);
        if (segs.Count != 2 || A == B) return null;
        var d = segs.Select(sg => { var s = ctx.Score(text[sg.Start..sg.End]); return s[A] - s[B]; }).ToList();
        if (Math.Min(Math.Abs(d[0]), Math.Abs(d[1])) < 1 || (d[0] > 0) == (d[1] > 0)) return null;
        var (left, right) = CutAt(text, segs, 1);
        if (!HasLetter(left) || !HasLetter(right)) return null;
        int order = d[0] > 0 ? 1 : -1;
        double pl = PairProb(ctx, left, A, B), pr = PairProb(ctx, right, A, B);
        double score = order == 1 ? Math.Min(pl, 1 - pr) : Math.Min(1 - pl, pr);
        return new LangSplitResult(left, right, order, score);
    }

    static string LastWord(string s) => JsRegex.Match(JSCompat.Lower(s), @"[\p{L}']+$")?.Value ?? "";

    /// <summary>Does <paramref name="prev"/> look unfinished (trailing comma, hyphenation, open article)?</summary>
    static bool LooksUnfinished(string prev) =>
        JsRegex.Test(@"[,;/(]$", prev) || JsRegex.Test(@"\p{L}-$", prev) || OPEN_ENDINGS.Contains(LastWord(prev));

    /// <summary>Cost of treating <paramref name="next"/> as the continuation of <paramref name="prev"/> on the same side.</summary>
    static double MergeCost(string prev, string next)
    {
        if (LooksUnfinished(prev) || JsRegex.Test(@"^[,;/)]", next)) return 0.5;
        if (StartsUpper(next)) return 4.5;
        if (JsRegex.Test(ENTRY_START_RE, next, "iu") && !(JsRegex.Test(@"[.!?…]$", next) && StartsUpper(prev) && !JsRegex.Test(@"[.!?…:]$", prev))) return 4.5;
        return MERGE_COST;
    }

    /// <summary>A section heading labels a group of entries ("Les couleurs:", "B) Couleurs", "Adjectifs").</summary>
    static bool LooksLikeHeading(string text, string? lang)
    {
        if (!JsRegex.Test(@"^[\p{Lu}\d]", text) || text.Contains(',') || JsRegex.Test(@"[.!?…]$", text) || LooksUnfinished(text)) return false;
        if (JsRegex.Test(@":$", text) || JsRegex.Test(@"^(?:[A-Z]|\d{1,2}|[IVX]{1,4})[.)]\s", text)) return true;
        var words = SpaceSplit(text);
        return words.Length <= 3 && JsRegex.Test(lang == "it" ? "[ie]$" : "[sx]$", words[^1]);
    }

    /// <summary>Lines that continue a sentence rather than start an entry.</summary>
    static bool ContinuesSentence(string text) =>
        JsRegex.Test(@"[.!?…]$", text) || JsRegex.Test(@"^(?:(?:et|ou|que|qui|dont|and|or|of|than)\s|qu')", text, "iu");

    static int WordCount(string text) => JsRegex.MatchAll(text, @"[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*").Count;

    static bool RestMatchesLength(int termWords, int restWords, int defWords)
    {
        double Misfit(int w) => Math.Abs(Math.Log((double)Math.Max(1, w) / Math.Max(1, defWords)));
        return Misfit(restWords) <= Misfit(termWords);
    }

    /// <summary>Join a continuation line onto the previous part.</summary>
    static string JoinParts(string a, string b)
    {
        if (a.Length == 0) return b;
        if (b.Length == 0) return a;
        if (JsRegex.Test(@"\p{L}-$", a)) return StartsLower(b) ? a[..^1] + b : a + b;
        if (JsRegex.Test(@"^[,;:)/]", b)) return a + b;
        if (JsRegex.Test(@"[,;:/(]$", a) || OPEN_ENDINGS.Contains(LastWord(a))) return $"{a} {b}";
        bool sentenceStart = StartsUpper(a) && !a.Contains(',') && SpaceSplit(a).Length >= 3;
        if (StartsLower(b) && !JsRegex.Test(@"[.!?…]$", a) && (JsRegex.Test(@"[.!?…]$", b) || sentenceStart)) return $"{a} {b}";
        if (!a.Contains(',') && JsRegex.Test(@"^\p{Ll}[\p{Ll}'-]*$", b))
        {
            if (JsRegex.Test("(?:en|ern|eln)$", b) && JsRegex.Test(DE_ARTICLE_RE, " " + a) && JsRegex.Test(@"\p{Lu}\p{Ll}*$", a)) return $"{a} {b}";
            if (SpaceSplit(a).Length >= 3 && JsRegex.Test(FR_OBJECT_END_RE, a)) return $"{a} {b}";
        }
        return $"{a}, {b}";
    }

    /// <summary>A pair under construction (mutable like the JS objects).</summary>
    sealed class Pair
    {
        public string Term = "";
        public string Def = "";
        public List<int> Lines = [];
        public bool Merged;
        public bool LangSplit;
        public bool Uncertain;
        public int? Group;
        public int Order;
        // Set by Finish:
        public bool Reversed;
    }

    static Pair MakePair(string? term, string? def, IEnumerable<int> lines, bool merged = false, bool langSplit = false, bool uncertain = false, int? group = null) =>
        new() { Term = term ?? "", Def = def ?? "", Lines = SortedUnique(lines), Merged = merged, LangSplit = langSplit, Uncertain = uncertain, Group = group };
}
