namespace Wortschatz.Core;

/// <summary>
/// Port of WordClass.swift (src/core/wordclass.js): word classes ("Wortart") for multiple-choice options
/// (since 23.11.2026).
///
/// Wrong options should look like the right one: they come from cards of the same word class (noun, verb,
/// adjective/adverb, expression, number) and among those from the most similar ones (LearnEngine ranks them).
///
/// The class of a card comes from cues on both of its sides. A side gives one class and a strength: 2 (strong)
/// for articles ("le", "der", "the"), "to", "se", "sich", gender marks (", f.", "(in)"), French feminine forms
/// ("amusant, amusante", "marié(e)"), sentence punctuation and numbers; 1 (weak) for German capitalisation and
/// lowercase, endings ("-ung", "-lich", "-tion", "-ous", French "-er") and long texts. Both sides agreeing or only
/// one having a cue gives the class; with different classes the stronger cue wins, equal strengths leave the
/// class open (""). Many cues hold in one language only ("-er" is a French verb but an English noun), so each
/// side's language is detected over the whole list (SideProfile, LangDetect.DetectColumn).
///
/// C# strings are UTF-16 like JS, so the JS string operations carry over; lengths count code points.
/// </summary>
public static class WordClass
{
    public const string Noun = "noun";
    public const string Verb = "verb";
    public const string Adj = "adj";
    public const string Phrase = "phrase";
    public const string Number = "number";

    /// <summary>What a side of a list says about its texts (<c>sideProfile</c>).</summary>
    /// <param name="WordCaps">German: nouns are capitalised, so a word in lowercase is no noun.</param>
    /// <param name="CapsNoun">German: texts start with capitals and with lowercase letters alike, so a capital means a noun.</param>
    /// <param name="CapsRare">Other languages: few texts start with a capital, so one that does is a name.</param>
    public sealed record SideProfile(DetectedLanguage Lang, bool WordCaps = false, bool CapsNoun = false, bool CapsRare = false)
        : IJsonEncodable
    {
        public static readonly SideProfile Unknown = new(DetectedLanguage.Unknown);

        /// <summary>The memo key part of the profile (<c>sideKey</c>).</summary>
        internal string Key => $"{Lang.Raw()}|{(WordCaps ? 1 : 0)}{(CapsNoun ? 1 : 0)}{(CapsRare ? 1 : 0)}|";

        public JSONValue ToJson() =>
            JSONValue.Obj(("lang", Lang.ToJson()), ("wordCaps", WordCaps), ("capsNoun", CapsNoun), ("capsRare", CapsRare));
    }

    /// <summary>The class one side points to (Cls "" = no cue) and how sure: 2 strong, 1 weak.</summary>
    public sealed record TextClass(string Cls, int Strength) : IJsonEncodable
    {
        internal static readonly TextClass None = new("", 0);

        public JSONValue ToJson() => JSONValue.Obj(("cls", Cls), ("strength", Strength));
    }

    /// <summary>What the options of a side are compared by: the article, the rest without it, its words and length in code points.</summary>
    public sealed record OptionShape(string Article, string Head, int Words, int Length) : IJsonEncodable
    {
        public JSONValue ToJson() => JSONValue.Obj(("article", Article), ("head", Head), ("words", Words), ("length", Length));
    }

    /// <summary>The profiles of both sides of a list.</summary>
    public sealed record ListProfiles(SideProfile Term, SideProfile Definition) : IJsonEncodable
    {
        public SideProfile Side(AskSide ask) => ask == AskSide.Term ? Term : Definition;

        public JSONValue ToJson() => JSONValue.Obj(("term", Term.ToJson()), ("definition", Definition.ToJson()));
    }

    // MARK: - Word lists

    static readonly Dictionary<DetectedLanguage, string[]> Articles = new()
    {
        [DetectedLanguage.Fr] = ["le", "la", "les", "un", "une", "des", "du"],
        [DetectedLanguage.De] = ["der", "die", "das", "ein", "eine"],
        [DetectedLanguage.En] = ["the", "a", "an"],
        [DetectedLanguage.Es] = ["el", "la", "los", "las", "un", "una", "unos", "unas"],
        [DetectedLanguage.It] = ["il", "lo", "la", "i", "gli", "le", "un", "uno", "una"],
    };
    /// <summary>A side of another language: the articles that are no other common word.</summary>
    static readonly string[] SafeArticles = ["le", "la", "les", "une", "der", "das", "the", "el", "los", "las", "lo", "gli", "una", "uno"];
    /// <summary>First words that make a verb: "to go", "se lever", "sich freuen".</summary>
    static readonly string[] VerbLeads = ["to", "se", "sich"];
    /// <summary>Placeholders for objects: "etw. vorschlagen", "to propose sth", "donner qc à qn".</summary>
    static readonly HashSet<string> Objects = new(StringComparer.Ordinal)
    {
        "etw", "etw.", "jmdn", "jmdn.", "jmdm", "jmdm.", "jmds", "jmds.", "jdn", "jdn.", "jdm", "jdm.", "jds", "jds.",
        "jemanden", "jemandem", "sth", "sth.", "sb", "sb.", "sb's", "qc", "qc.", "qn", "qn.", "qch", "qch.", "qqch",
        "qqch.", "qqn", "qqn.",
    };
    /// <summary>Gender marks after a comma: "l'oreille, f.", "l'œil, m. les yeux".</summary>
    static readonly string[] GenderMarks = ["m", "m.", "f", "f.", "n", "n.", "pl", "pl.", "m.pl.", "f.pl.", "m/f", "m./f."];
    static readonly string[] GenderParens = ["(m)", "(m.)", "(f)", "(f.)", "(n)", "(n.)", "(pl)", "(pl.)", "(in)"];
    /// <summary>French feminine endings in brackets or after a comma: "marié(e)", "grand, e", "heureux, -euse".</summary>
    static readonly string[] FeminineEndings = ["e", "ne", "le", "se", "te", "ve", "ère", "euse", "ive", "elle", "enne", "ienne", "trice"];
    // German: words after the verb ("Lust haben auf"), first words of adverbial phrases ("im Inland"), words with
    // a verb ending that are no verbs, noun and adjective endings.
    static readonly string[] DeParticles = ["an", "auf", "aus", "bei", "für", "gegen", "in", "mit", "nach", "um", "von", "vor", "zu", "über"];
    static readonly string[] DePrepositions =
    [
        "als", "am", "an", "ans", "auf", "aus", "bei", "beim", "durch", "für", "gegen", "im", "in", "ins", "mit", "nach",
        "ohne", "pro", "um", "unter", "vom", "von", "vor", "zu", "zum", "zur", "über",
    ];
    static readonly string[] DeNotVerbs =
    [
        "modern", "intern", "extern", "gestern", "morgen", "golden", "offen", "eigen", "trocken", "verschieden", "zufrieden",
        "oben", "unten", "innen", "aussen", "hinten", "vorne", "neben", "gegen", "eben", "selten", "wegen",
    ];
    static readonly string[] DeNounEndings = ["ung", "heit", "keit", "schaft", "tion", "tät", "ismus", "nis", "ment", "ling"];
    static readonly string[] DeAdjEndings = ["ig", "lich", "isch", "bar", "sam", "haft", "los", "voll"];
    static readonly string[] EnNounEndings = ["tion", "sion", "ment", "ness", "ity", "ism", "ship", "ance", "ence", "hood", "dom"];
    static readonly string[] EnAdjEndings = ["ous", "ful", "less", "ive", "able", "ible", "al", "ic", "ish", "ly"];
    static readonly string[] FrNounEndings = ["tion", "sion", "isme"];
    static readonly string[] FrAdjEndings = ["eux", "euse", "if", "ive", "able", "ible", "ique", "ment"];
    /// <summary>French words with an infinitive ending that are no verbs.</summary>
    static readonly string[] FrNotVerbs =
    [
        "hier", "cher", "fier", "amer", "super", "premier", "dernier", "entier", "léger", "étranger", "autre", "libre",
        "propre", "pauvre", "rare", "sombre", "célèbre", "contre", "entre", "notre", "votre", "quatre", "noir", "soir",
        "mer", "hiver", "plaisir", "désir", "avenir", "loisir",
    ];
    /// <summary>Spanish and Italian adjectives and adverbs.</summary>
    static readonly string[] RomanceAdjEndings = ["oso", "osa", "mente"];

    // MARK: - Small helpers

    static List<string> WordsOf(string s) => s.Split(' ').Where(w => w.Length > 0).ToList();

    static string Joined(IEnumerable<string> words) => string.Join(" ", words);

    static int Count(string s) => JSCompat.Scalars(s).Count();

    static bool IsDigit(char c) => c is >= '0' and <= '9';

    static bool Ends(string s, string end) => s.EndsWith(end, StringComparison.Ordinal);

    static bool Starts(string s, string start) => s.StartsWith(start, StringComparison.Ordinal);

    static bool EndsWithAny(string word, string[] endings, int minLength)
    {
        int n = Count(word);
        return n >= minLength && endings.Any(e => Ends(word, e) && n > Count(e));
    }

    /// <summary>The first code point of <paramref name="s"/> as a string, null for an empty one.</summary>
    static string? FirstChar(string s)
    {
        if (s.Length == 0) return null;
        return char.IsHighSurrogate(s[0]) && s.Length > 1 && char.IsLowSurrogate(s[1]) ? s[..2] : s[..1];
    }

    /// <summary>JS <c>ch.toLowerCase() !== ch</c> for one code point (false for none).</summary>
    static bool IsUpper(string? ch) => ch is not null && JSCompat.Lower(ch) != ch;

    static bool IsLower(string? ch) => ch is not null && TextNormalizer.IsLetter(ch) && JSCompat.Lower(ch) == ch;

    /// <summary>The text without bracketed parts ("(verabschiedetes) Gesetz" → "Gesetz") or, with keep, without only the brackets; single spaces.</summary>
    static string Brackets(string s, bool keep)
    {
        var sb = new System.Text.StringBuilder(s.Length);
        int depth = 0;
        foreach (char c in s)
        {
            if (c is '(' or '[') depth++;
            else if (c is ')' or ']' && depth > 0) depth--;
            else if (keep || depth == 0) sb.Append(c);
        }
        return Joined(WordsOf(sb.ToString()));
    }

    /// <summary>The pieces between commas and semicolons, trimmed.</summary>
    static List<string> Segments(string s) => s.Split(',', ';').Select(x => Joined(WordsOf(x))).ToList();

    /// <summary>The article a text starts with ("le", "l'", "der/die") or "". list: lowercase words.</summary>
    static string ArticleOf(IReadOnlyList<string> list, DetectedLanguage lang)
    {
        if (list.Count == 0) return "";
        var first = list[0];
        bool elides = lang is DetectedLanguage.Fr or DetectedLanguage.It || !Articles.ContainsKey(lang);
        if (elides && Starts(first, "l'") && Count(first) > 2) return "l'";
        if (list.Count < 2) return "";
        var known = Articles.TryGetValue(lang, out var a) ? a : SafeArticles;
        return first.Split('/').All(part => known.Contains(part)) ? first : "";
    }

    // MARK: - Sides

    /// <summary>
    /// What a side of the list says about its texts: the language (DetectColumn) and how it uses capitals.
    /// German: WordCaps – a fifth of the texts or more have a capitalised word; CapsNoun – texts start with
    /// capitals and with lowercase letters alike. Other languages: CapsRare – few texts start with a capital.
    /// </summary>
    public static SideProfile SideProfileOf(IEnumerable<string?> texts)
    {
        var list = texts.Select(t => TextNormalizer.NormalizeBasic(t)).Where(t => t.Length > 0).ToList();
        var lang = LangDetect.DetectColumn(list).Lang;
        int upper = 0, lower = 0, capitalised = 0;
        foreach (var t in list)
        {
            var first = FirstChar(t);
            if (IsUpper(first)) upper++;
            else if (IsLower(first)) lower++;
            if (WordsOf(t).Any(w => IsUpper(FirstChar(w)))) capitalised++;
        }
        int letters = upper + lower;
        bool german = lang == DetectedLanguage.De && letters > 0;
        return new SideProfile(lang,
            WordCaps: german && capitalised * 5 >= list.Count,
            CapsNoun: german && upper * 10 >= letters && lower * 10 >= letters,
            CapsRare: lang != DetectedLanguage.De && letters > 0 && upper * 4 <= letters);
    }

    // MARK: - Texts

    /// <summary>
    /// The parts of a text the cues look at: the whole text in lowercase, its comma pieces in lowercase, the first
    /// piece's words without brackets (Cut, lowercase; Caps: which start with a capital) and with the bracketed
    /// words (Keep, lowercase).
    /// </summary>
    sealed record Parsed(string Low, List<string> Segs, List<string> Cut, List<bool> Caps, List<string> Keep);

    static Parsed Parse(string? text)
    {
        var b = TextNormalizer.FoldScripts(TextNormalizer.NormalizeBasic(text));
        var segs = Segments(b);
        var main = segs[0];
        var without = Brackets(main, false);
        var cut = WordsOf(without.Length > 0 ? without : Brackets(main, true));
        return new Parsed(
            JSCompat.Lower(b),
            segs.Select(JSCompat.Lower).ToList(),
            cut.Select(JSCompat.Lower).ToList(),
            cut.Select(w => IsUpper(FirstChar(w))).ToList(),
            WordsOf(JSCompat.Lower(Brackets(main, true))));
    }

    /// <summary>Only digits and separators: "1474", "1914-1918", "3,5".</summary>
    static bool IsNumber(string low) =>
        low.Length > 0 && IsDigit(low[0]) && low.All(c => IsDigit(c) || " .,:/'-+%".Contains(c));

    /// <summary>A sentence or exclamation: "Achtung!", "Wie geht's?", "C'est mon tour." (not "etw. tun bei etw.").</summary>
    static bool IsSentence(Parsed p)
    {
        var codes = JSCompat.Scalars(p.Low).ToList();
        if (codes.Count == 0) return false;
        int first = codes[0], last = codes[^1];
        if (first is '¿' or '¡' || last is '!' or '?') return true;
        if (last is not ('.' or '…') || !p.Low.Contains(' ')) return false;
        return !Objects.Contains(WordsOf(p.Low)[^1]);
    }

    /// <summary>"amusant, amusante", "grand, e", "heureux, -euse", "marié(e)": French, Spanish or Italian adjective.</summary>
    static bool IsFeminineForm(Parsed p)
    {
        foreach (var w in WordsOf(p.Segs[0]))
            foreach (var e in FeminineEndings)
                if (Ends(w, $"({e})") && Count(w) > Count(e) + 2) return true;
        if (p.Segs.Count < 2 || p.Cut.Count != 1) return false;
        var a = p.Segs[0];
        var b = p.Segs[1];
        if (Starts(b, "-")) b = b[1..];
        if (FeminineEndings.Contains(b)) return true;
        if (WordsOf(b).Count != 1 || a == b) return false;
        var x = JSCompat.Scalars(a).ToArray();
        var y = JSCompat.Scalars(b).ToArray();
        int common = 0;
        while (common < x.Length && common < y.Length && x[common] == y[common]) common++;
        return common >= 3 && common >= x.Length - 2 && y.Length >= x.Length;
    }

    /// <summary>The words of the first piece without placeholders ("etw.", "sth"): lowercase, which start with a capital, and whether there were placeholders.</summary>
    static (List<string> List, List<bool> Caps, bool Objects) Content(Parsed p)
    {
        var list = new List<string>();
        var caps = new List<bool>();
        for (int i = 0; i < p.Cut.Count; i++)
        {
            if (Objects.Contains(p.Cut[i])) continue;
            list.Add(p.Cut[i]);
            caps.Add(p.Caps[i]);
        }
        return (list, caps, list.Count != p.Cut.Count);
    }

    /// <summary>
    /// German verb or verb phrase on a side with capitalised nouns: the last word (before particles) in lowercase
    /// with a verb ending. Strength 2 with placeholders or an article in front, otherwise 1; 0 = no verb.
    /// </summary>
    static int GermanVerb(Parsed p, SideProfile side)
    {
        var c = Content(p);
        if (!side.WordCaps || c.List.Count == 0) return 0;
        int v = c.List.Count - 1;
        if (v >= 1 && DeParticles.Contains(c.List[v])) v--;
        var verb = c.List[v];
        if (c.Caps[v] || DeNotVerbs.Contains(verb)) return 0;
        if (!EndsWithAny(verb, ["en", "ern", "eln"], 4) && !Ends(verb, "tun") && verb != "sein") return 0;
        return c.Objects || (v >= 1 && Articles[DetectedLanguage.De].Contains(c.List[0])) ? 2 : 1;
    }

    /// <summary>Cues of one language (weak ones and the language's own strong ones), then a name ("Noël") or a long text without other cues.</summary>
    static TextClass LanguageCues(Parsed p, SideProfile side)
    {
        var (list, caps, _) = Content(p);
        if (list.Count == 0) return TextClass.None;
        var last = list[^1];
        bool single = list.Count == 1;
        bool capital = caps[0];
        switch (side.Lang)
        {
            case DetectedLanguage.De:
            {
                int verb = GermanVerb(p, side);
                if (verb > 0) return new TextClass(Verb, verb);
                // The noun comes last, before particles: "gemeinsame Reaktion auf etw.".
                int h = list.Count - 1;
                if (h >= 1 && DeParticles.Contains(list[h])) h--;
                if (EndsWithAny(list[h], DeNounEndings, 5)) return new TextClass(Noun, 2);
                if (capital)
                {
                    if (side.CapsNoun) return new TextClass(Noun, 2);
                    break;
                }
                if (!side.WordCaps) break;
                // Lowercase: an adverbial phrase ("im Inland"), an adjective with a noun ("gemeinsame Politik") or an
                // adjective, adverb ("unbedingt erforderlich").
                if (!single && DePrepositions.Contains(list[0])) return new TextClass(Adj, 1);
                if (caps[h]) return new TextClass(Noun, 1);
                return new TextClass(Adj, EndsWithAny(list[h], DeAdjEndings, 4) ? 2 : 1);
            }
            case DetectedLanguage.En:
                if (EndsWithAny(last, EnNounEndings, 5)) return new TextClass(Noun, 1);
                if (single && EndsWithAny(last, EnAdjEndings, 5)) return new TextClass(Adj, 1);
                break;
            case DetectedLanguage.Fr:
            {
                var first = list[0];
                int n = Count(first);
                bool infinitive = !FrNotVerbs.Contains(first)
                    && ((n >= 5 && (Ends(first, "er") || Ends(first, "ir"))) || (n >= 4 && (Ends(first, "oir") || Ends(first, "re"))));
                if (infinitive) return new TextClass(Verb, 1);
                if (single && EndsWithAny(last, FrNounEndings, 5)) return new TextClass(Noun, 1);
                if (single && EndsWithAny(last, FrAdjEndings, 4)) return new TextClass(Adj, 1);
                break;
            }
            case DetectedLanguage.Es:
                if (single && (Ends(last, "arse") || Ends(last, "erse") || Ends(last, "irse"))) return new TextClass(Verb, 2);
                if (single && EndsWithAny(last, ["ar", "er", "ir"], 4)) return new TextClass(Verb, 1);
                if (single && EndsWithAny(last, RomanceAdjEndings, 4)) return new TextClass(Adj, 1);
                break;
            case DetectedLanguage.It:
                if (single && (Ends(last, "arsi") || Ends(last, "ersi") || Ends(last, "irsi"))) return new TextClass(Verb, 2);
                if (single && EndsWithAny(last, ["are", "ere", "ire"], 5)) return new TextClass(Verb, 1);
                if (single && EndsWithAny(last, RomanceAdjEndings, 4)) return new TextClass(Adj, 1);
                break;
        }
        if (side.CapsRare && capital) return new TextClass(Noun, 1);
        if (list.Count >= 5) return new TextClass(Phrase, 1);
        return TextClass.None;
    }

    /// <summary>The class one side of a card points to, with its strength (Cls "" = no cue).</summary>
    public static TextClass TextClassOf(string? text, SideProfile? side = null)
    {
        side ??= SideProfile.Unknown;
        var p = Parse(text);
        if (p.Cut.Count == 0) return TextClass.None;
        if (IsNumber(p.Low)) return new TextClass(Number, 2);
        if (p.Segs.Skip(1).Any(x => GenderMarks.Contains(x) || Starts(x, "m. ") || Starts(x, "f. "))) return new TextClass(Noun, 2);
        if (GenderParens.Any(x => p.Low.Contains(x, StringComparison.Ordinal))) return new TextClass(Noun, 2);
        if (IsSentence(p)) return new TextClass(Phrase, 2);
        var first = p.Keep.Count > 0 ? p.Keep[0] : "";
        if (p.Keep.Count >= 2 && VerbLeads.Contains(first)) return new TextClass(Verb, 2);
        if (side.Lang is DetectedLanguage.Fr or DetectedLanguage.Unknown && Starts(first, "s'") && Count(first) > 2)
            return new TextClass(Verb, 2);
        if (side.Lang == DetectedLanguage.De && p.Cut.Count >= 2)
        {
            int v = GermanVerb(p, side);
            if (v > 0) return new TextClass(Verb, v);
        }
        if (ArticleOf(p.Cut, side.Lang).Length > 0) return new TextClass(Noun, 2);
        bool romance = side.Lang is DetectedLanguage.Fr or DetectedLanguage.Es or DetectedLanguage.It or DetectedLanguage.Unknown;
        if (romance && IsFeminineForm(p)) return new TextClass(Adj, 2);
        return LanguageCues(p, side);
    }

    /// <summary>The class of a card from both sides ("" when open). Different strong classes make a class of their own ("number/phrase").</summary>
    public static string CombineClasses(TextClass term, TextClass definition)
    {
        if (term.Cls.Length == 0) return definition.Cls;
        if (definition.Cls.Length == 0 || term.Cls == definition.Cls) return term.Cls;
        if (term.Strength != definition.Strength) return term.Strength > definition.Strength ? term.Cls : definition.Cls;
        return term.Strength == 2 ? $"{term.Cls}/{definition.Cls}" : "";
    }

    /// <summary>The article, the rest without it ("head"), its words and length in code points.</summary>
    public static OptionShape OptionShapeOf(string? text, SideProfile? side = null)
    {
        side ??= SideProfile.Unknown;
        var p = Parse(text);
        var article = ArticleOf(p.Cut, side.Lang);
        var rest = p.Cut;
        if (article == "l'") rest = [p.Cut[0][2..], .. p.Cut.Skip(1)];
        else if (article.Length > 0) rest = p.Cut.Skip(1).ToList();
        var head = Joined(rest);
        return new OptionShape(article, head, rest.Count, Count(head));
    }

    /// <summary>Similarity points of two option shapes: the same article, as many words, a similar length, the same first two and last three letters (0–5).</summary>
    public static int ShapePoints(OptionShape a, OptionShape b) =>
        ShapePoints(a, JSCompat.Scalars(a.Head).ToArray(), b, JSCompat.Scalars(b.Head).ToArray());

    /// <summary>ShapePoints with the heads' code points worked out ahead (LearnEngine's ChoicePool, once per card).</summary>
    internal static int ShapePoints(OptionShape a, ReadOnlySpan<int> x, OptionShape b, ReadOnlySpan<int> y)
    {
        int points = 0;
        if (a.Article.Length > 0 && a.Article == b.Article) points++;
        if (a.Words == b.Words) points++;
        if (Math.Abs(a.Length - b.Length) <= Math.Max(2, a.Length / 5)) points++;
        if (x.Length >= 2 && y.Length >= 2 && x[0] == y[0] && x[1] == y[1]) points++;
        if (x.Length >= 3 && y.Length >= 3 && x[^3..].SequenceEqual(y[^3..])) points++;
        return points;
    }

    /// <summary>Points for cards close together in the set (sets are mostly ordered by topic): 3 up to 3 apart, 2 up to 10, 1 up to 25.</summary>
    public static int NearPoints(int distance) => distance <= 3 ? 3 : distance <= 10 ? 2 : distance <= 25 ? 1 : 0;

    // MARK: - Cards of a list

    // Results per text and side, computed once (a round compares every card with every card of the set).
    static readonly TextMemo<SideProfile> Profiles = new();
    static readonly TextMemo<TextClass> Classes = new();
    static readonly TextMemo<OptionShape> Shapes = new();

    /// <summary>A memo key for a list of texts (each with its length, so no two lists share one).</summary>
    static string ListKey(IEnumerable<string> texts) => string.Concat(texts.Select(t => $"{t.Length}:{t}"));

    /// <summary>The profiles of both sides of cards.</summary>
    public static ListProfiles ListProfilesOf(IReadOnlyList<Card> cards)
    {
        var term = cards.Select(c => c.Term).ToList();
        var definition = cards.Select(c => c.Definition).ToList();
        return new ListProfiles(
            Profiles.Value(ListKey(term), _ => SideProfileOf(term)),
            Profiles.Value(ListKey(definition), _ => SideProfileOf(definition)));
    }

    /// <summary>The word class of a card ("" when open). sides: ListProfilesOf its list.</summary>
    public static string CardClass(Card card, ListProfiles sides)
    {
        var term = Classes.Value(sides.Term.Key + card.Term, _ => TextClassOf(card.Term, sides.Term));
        var definition = Classes.Value(sides.Definition.Key + card.Definition, _ => TextClassOf(card.Definition, sides.Definition));
        return CombineClasses(term, definition);
    }

    /// <summary>OptionShapeOf, computed once per text and side.</summary>
    internal static OptionShape ShapeOf(string text, SideProfile side) => Shapes.Value(side.Key + text, _ => OptionShapeOf(text, side));
}
