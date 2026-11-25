using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

// Second half of the parser port (parser.js from "Delimited lists" on): delimited lists
// (VocabParser+Delimited.swift), line-based lists and their alignment (VocabParser+LineBased.swift),
// explicit delimiter mode, orchestration, Finish and the warnings (German source, translated with CoreText.L;
// VocabParser.swift, VocabParser+Context.swift).
public static partial class VocabParser
{
    sealed record ParseOutcome(List<Pair> Pairs, string Format, string? Delimiter);

    // MARK: - Delimited lists

    sealed record ContentLine(Line Line, bool Optional);

    static List<ContentLine> ContentWithOptional(List<Line> lines)
    {
        var output = new List<ContentLine>();
        Line? prev = null;
        bool afterGap = true;
        foreach (var line in lines)
        {
            if (line.Blank) { prev = null; afterGap = true; continue; }
            if (line.Kind is not null)
            {
                if (line.Kind == "heading") { prev = null; afterGap = true; }
                continue;
            }
            var t = DisplayText(line);
            bool continuation = line.Indent >= 2 || (prev is not null && LooksUnfinished(DisplayText(prev)));
            bool title = afterGap && JsRegex.Test(@"^[\p{Lu}\d]", t) && !t.Contains(',') && SpaceSplit(t).Length <= 6;
            output.Add(new ContentLine(line, line.Weak || continuation || title));
            prev = line;
            afterGap = false;
        }
        return output;
    }

    static Cand? DetectDelimiter(Ctx ctx, List<Line> lines)
    {
        var content = ContentWithOptional(lines);
        if (content.Count == 0) return null;
        double RatioFor(Cand cand, bool strict)
        {
            int n = 0, denom = 0;
            foreach (var (line, optional) in content)
            {
                var parts = SplitWith(line, cand).Parts;
                bool ok = strict ? parts.Count == 2 && parts[0] != "" && parts[1] != "" : PairingCount(parts, cand) > 0;
                if (ok) { n++; denom++; }
                else if (!optional) denom++;
            }
            return n >= 1 && n >= 0.3 * content.Count ? (double)n / Math.Max(1, denom) : 0;
        }
        (Cand Cand, double Ratio)? best = null;
        foreach (var cand in CANDIDATES)
        {
            double ratio = RatioFor(cand, false);
            if (ratio >= 0.7 && (best is null || ratio > best.Value.Ratio + 0.05)) best = (cand, ratio);
        }
        if (best is not null) return PageColumnsGap(ctx, content, best.Value.Cand) ? GAP : best.Value.Cand;

        foreach (var comma in new[] { COMMA, TIGHT_COMMA })
        {
            if (RatioFor(comma, true) < 0.8) continue;
            var pairs = new List<List<string>>();
            foreach (var (line, _) in content)
            {
                var parts = SplitWith(line, comma).Parts;
                if (parts.Count == 2 && parts[0] != "" && parts[1] != "") pairs.Add(parts);
            }
            if (SidesContrast(ctx, pairs)) return comma;
        }
        return null;
    }

    static bool PageColumnsGap(Ctx ctx, List<ContentLine> content, Cand winner)
    {
        if (!INNER_CANDIDATES.Contains(winner)) return false;
        int wide = 0, paired = 0;
        var halves = new List<List<string>>();
        foreach (var (line, _) in content)
        {
            var cells = SplitWith(line, GAP).Parts;
            if (cells.Count < 2) continue;
            wide++;
            var split = cells.Where(c => c != "").Select(c => SplitWith(Line.FromText(c), winner).Parts).ToList();
            if (split.All(parts => parts.Count == 2 && parts[0] != "" && parts[1] != ""))
            {
                paired++;
                halves.AddRange(split);
            }
        }
        if (wide == 0 || paired < 0.8 * wide) return false;
        return (wide >= 2 && wide >= 0.7 * content.Count) || (paired == wide && SidesContrast(ctx, halves));
    }

    static bool SidesContrast(Ctx ctx, List<List<string>> pairs)
    {
        if (pairs.Count == 0) return false;
        var L = DetectColumnLang(pairs.Select(p => p[0]));
        var R = DetectColumnLang(pairs.Select(p => p[1]));
        if (L is null || R is null || L == R) return false;
        int agree = pairs.Count(p => PairProb(ctx, p[0], L, R) > 0.5 && PairProb(ctx, p[1], R, L) > 0.5);
        return (double)agree / pairs.Count >= 0.6;
    }

    /// <summary>Whole lists on one line: "le chat - die Katze; le chien - der Hund".</summary>
    static ParseOutcome? DetectInline(Ctx ctx, List<Line> content)
    {
        foreach (var sep in new[] { ";", "," })
        {
            int withSep = content.Count(l => l.Text.Contains(sep, StringComparison.Ordinal));
            if ((double)withSep / content.Count < 0.6) continue;
            var records = new List<Line>();
            foreach (var line in content)
                foreach (var piece in CsvSplit(line.Text.Replace('\t', ' '), sep))
                    if (piece.Length > 0 && HasLetter(piece)) records.Add(MakeLine(piece, line.No));
            if (records.Count < content.Count * 2) continue;
            foreach (var cand in sep == ";" ? CANDIDATES.Append(COMMA) : CANDIDATES)
            {
                if (cand.Kind is "cells" or "gap" || cand.Id == sep) continue;
                var pairs = new List<List<string>>();
                foreach (var r in records)
                {
                    var parts = SplitWith(r, cand).Parts;
                    if (parts.Count == 2 && parts[0] != "" && parts[1] != "") pairs.Add(parts);
                }
                if ((double)pairs.Count / records.Count < 0.7) continue;
                if (cand == COMMA && !SidesContrast(ctx, pairs)) continue;
                return ParseDelimitedLines(ctx, records, cand);
            }
            if (DetectBilingual(ctx, records) is { } bilingual) return bilingual;
        }
        return null;
    }

    sealed class Entry
    {
        public required Line Line;
        public bool Skip;
        public List<string> Parts = [];
        public string Joiner = ", ";
        public int Count;
        public bool Uncertain;
        public List<List<string>>? Groups;
    }

    /// <summary>Two page columns of "term – definition" entries side by side.</summary>
    static bool SplitInnerPairs(Ctx ctx, List<Entry> entries)
    {
        var rows = entries.Where(e => !e.Skip && e.Parts.Count(p => p != "") >= 2).ToList();
        if (rows.Count == 0) return false;
        foreach (var inner in INNER_CANDIDATES)
        {
            var pairs = new List<List<string>>();
            int cells = 0;
            foreach (var e in rows)
            {
                foreach (var cell in e.Parts)
                {
                    if (cell == "") continue;
                    cells++;
                    var parts = SplitWith(Line.FromText(cell), inner).Parts;
                    if (parts.Count == 2 && parts[0] != "" && parts[1] != "") pairs.Add(parts);
                }
            }
            if (pairs.Count < 0.8 * cells || !SidesContrast(ctx, pairs)) continue;
            foreach (var e in entries)
            {
                if (e.Skip || !e.Parts.Any(p => p != "")) continue;
                var groups = e.Parts.Select(cell => cell != "" ? SplitWith(Line.FromText(cell), inner).Parts : ["", ""]).ToList();
                if (groups.Select((g, i) => e.Parts[i] == "" || (g.Count == 2 && (g[0] != "" || g[1] != ""))).All(x => x))
                {
                    e.Groups = groups;
                    e.Count = groups.Count(g => g[0] != "" || (g.Count > 1 && g[1] != ""));
                }
            }
            return true;
        }
        return false;
    }

    static readonly HashSet<string> LABEL_STOP = new("der die das den dem des ein eine einen the a an le la les l un une el los las il lo gli".Split(' '), StringComparer.Ordinal);
    static List<string> TokensOf(string s) => JsRegex.MatchAll(JSCompat.Lower(s), @"\p{L}+");

    /// <summary>Word class / gender columns repeat the same label that never occurs in the translation column.</summary>
    static bool IsLabelColumn(List<string> col, List<string> other)
    {
        if (col.Count < 3) return false;
        var seen = new HashSet<string>(other.SelectMany(TokensOf), StringComparer.Ordinal);
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        var order = new List<string>();
        foreach (var cell in col)
            foreach (var t in TokensOf(cell).Distinct())
            {
                if (!counts.ContainsKey(t)) order.Add(t);
                counts[t] = counts.GetValueOrDefault(t) + 1;
            }
        foreach (var t in order) if (counts[t] >= col.Count / 2.0 && !seen.Contains(t) && !LABEL_STOP.Contains(t)) return true;
        return false;
    }

    static bool IsSentence(string t) => JsRegex.Test("[.!?]$", t) && JsRegex.Split(t, @"\s+").Length >= 3;

    static void ReduceThreeCells(Ctx ctx, List<Entry> entries, Cand cand)
    {
        var live = entries.Where(e => !e.Skip && e.Parts.Count >= 2).ToList();
        var rows = live.Where(e => e.Parts.Count == 3 && e.Parts.All(p => p != "")).ToList();
        if (rows.Count < 2 || rows.Count < 0.6 * live.Count) return;
        var cols = Enumerable.Range(0, 3).Select(c => rows.Select(e => e.Parts[c]).ToList()).ToList();
        var langs = cols.Select(col => DetectColumnLang(col)).ToList();
        var (l0, l1, l2) = (langs[0], langs[1], langs[2]);
        var avg = cols.Select(col => col.Sum(t => JsRegex.Split(t, @"\s+").Length) / (double)col.Count).ToList();
        var wordy = Enumerable.Range(0, 3).Where(i => avg[i] >= 4 && avg.Select((o, j) => j == i || avg[i] >= 2 * o).All(x => x)).ToList();
        var share = cols.Select(col => col.Count(IsSentence) / (double)col.Count).ToList();
        var sentences = Enumerable.Range(0, 3).Where(i => share[i] >= 0.8 && share.Select((s, j) => j == i || s <= 0.2).All(x => x)).ToList();
        int drop = wordy.Count == 1 ? wordy[0] : sentences.Count == 1 ? sentences[0] : -1;
        bool uncertain = false;
        if (drop < 0)
        {
            if (l0 is not null && l1 is not null && l0 != l1 && (l2 != l1 || IsLabelColumn(cols[2], cols[1]))) drop = 2;
            else if (l1 is not null && l2 is not null && l1 != l2 && l0 != l1 && l0 != l2) drop = 0;
        }
        var target = ctx.O.DefHint ?? "de";
        if (drop >= 0 && langs[drop] == target && !langs.Where((l, i) => i != drop && l == target).Any()) drop = -1;
        if (drop < 0) uncertain = !(l0 is not null && l2 is not null && l0 != l2) || (l1 is not null && l1 != l0 && l1 != l2);
        foreach (var e in rows)
        {
            if (drop >= 0)
            {
                e.Parts = e.Parts.Where((_, i) => i != drop).ToList();
                e.Count = PairingCount(e.Parts, cand);
            }
            else e.Uncertain = uncertain;
        }
    }

    const string LATIN_LETTER_RE = @"[A-Za-zÀ-ɏ]";
    const string PINYIN_SYLLABLE_RE = @"^(?:er|(?:[zcs]h|[bpmfdtnlgkhjqxrzcsyw])?(?:i(?:a(?:o|ng?)?|e|u|ng?|ong)?|u(?:a(?:i|ng?)?|o|i|e|n|eng)?|[üv](?:e|an|n)?|a(?:i|o|ng?)?|o(?:u|ng)?|e(?:i|ng?)?|ê))$";
    const string TONE_MARKS_RE = @"[̀́̄̌]";

    static bool IsPinyinWord(string word)
    {
        var w = JSCompat.Lower(JSCompat.Nfc(JsRegex.ReplaceAll(JSCompat.Nfd(word), TONE_MARKS_RE, "")));
        var pieces = JsRegex.Split(w, "['’0-5]+").Where(p => p.Length > 0).ToList();
        return pieces.Count > 0 && pieces.All(s =>
        {
            var ok = new bool[s.Length + 1];
            ok[0] = true;
            for (int i = 1; i <= s.Length; i++)
            {
                ok[i] = false;
                for (int k = Math.Max(0, i - 6); k < i && !ok[i]; k++) ok[i] = ok[k] && JsRegex.Test(PINYIN_SYLLABLE_RE, s[k..i]);
            }
            return ok[s.Length];
        });
    }

    static string Unbracket(string s)
    {
        var m = JsRegex.Match(s, "^[(（]([^()（）]*)[)）]$");
        return m is not null ? JSCompat.Trim(m.Groups[1].Value) : s;
    }

    static bool IsPinyinCell(string cell)
    {
        var t = Unbracket(cell);
        if (TextNormalizer.HasHan(t) || !JsRegex.Test(LATIN_LETTER_RE, t)) return false;
        var words = JsRegex.Split(t, @"[\s,;/-]+").Select(w => JsRegex.ReplaceAll(w, @"^[^\p{L}]+|[^\p{L}\d]+$", "")).Where(w => w.Length > 0).ToList();
        return words.Count > 0 && words.All(IsPinyinWord);
    }

    static bool IsHanCell(string cell) => TextNormalizer.HasHan(cell) && !JsRegex.Test(LATIN_LETTER_RE, cell);

    /// <summary>Rows of Chinese characters, pinyin and translation: characters and pinyin become one side.</summary>
    static void MergeHanPinyin(List<Entry> entries, Cand cand)
    {
        var live = entries.Where(e => !e.Skip && e.Parts.Count >= 2).ToList();
        var rows = live.Where(e => e.Parts.Count == 3 && e.Parts.All(p => p != "")).ToList();
        if (rows.Count == 0 || rows.Count < 0.6 * live.Count) return;
        double Share(int c, Func<string, bool> f) => rows.Count(e => f(e.Parts[c])) / (double)rows.Count;
        (int H, int P)? found = null;
        foreach (var (h, p) in new[] { (0, 1), (1, 0), (1, 2), (2, 1) })
            if (Share(h, IsHanCell) >= 0.8 && Share(p, IsPinyinCell) >= 0.8) { found = (h, p); break; }
        if (found is not { } f2) return;
        int at = Math.Min(f2.H, f2.P);
        foreach (var e in live)
        {
            if (e.Parts.Count != 3) continue;
            var han = e.Parts[f2.H];
            var pinyin = Unbracket(e.Parts[f2.P]);
            var merged = han != "" && pinyin != "" ? $"{han} ({pinyin})" : han != "" ? han : pinyin;
            e.Parts = e.Parts.Where((_, i) => i != f2.H && i != f2.P).ToList();
            e.Parts.Insert(at, merged);
            e.Count = PairingCount(e.Parts, cand);
        }
    }

    static ParseOutcome ParseDelimitedLines(Ctx ctx, List<Line> lines, Cand cand)
    {
        bool cellKind = cand.Kind is "cells" or "gap";
        var entries = lines.Select(line =>
        {
            if (line.Blank || line.Kind is not null) return new Entry { Line = line, Skip = true };
            var (parts, joiner) = SplitWith(line, cand);
            return new Entry { Line = line, Parts = parts, Joiner = joiner, Count = PairingCount(parts, cand) };
        }).ToList();
        bool pageColumns = cellKind && SplitInnerPairs(ctx, entries);
        if (!pageColumns) MergeHanPinyin(entries, cand);
        if (cellKind && !pageColumns) ReduceThreeCells(ctx, entries, cand);

        var two = entries.Where(e => !e.Skip && e.Parts.Count == 2 && e.Parts[0] != "" && e.Parts[1] != "").Select(e => e.Parts).ToList();
        if (two.Count == 0)
            two = entries.Where(e => !e.Skip && e.Parts.Count > 2 && e.Parts[0] != "" && e.Parts[^1] != "").Select(e => new List<string> { e.Parts[0], e.Parts[^1] }).ToList();
        var A = DetectColumnLang(two.Select(p => p[0]));
        var B = DetectColumnLang(two.Select(p => p[1]));
        if (A == B) A = null;
        if (A is null) B = null;

        var pairs = new List<Pair>();
        int multi = entries.Count(e => !e.Skip && e.Count >= 2);
        bool columnMajor = (pageColumns && multi >= 1)
            || (cellKind && multi >= 2 && multi / (double)Math.Max(1, entries.Count(e => e.Count >= 1)) >= 0.6);
        var run = new List<Line>();
        Pair? prevPair = null;
        void FlushRun(Pair? nextPair)
        {
            if (run.Count > 0) HandleRun(ctx, run, prevPair, nextPair, A, B, pairs);
            run = [];
        }
        foreach (var e in entries)
        {
            if (e.Skip)
            {
                if (e.Line.Blank || e.Line.Kind == "heading")
                {
                    FlushRun(null);
                    prevPair = null;
                }
                continue;
            }
            if (e.Groups is null && (e.Parts.Count < 2 || (e.Line.Weak && e.Count == 0)))
            {
                run.Add(e.Line);
                continue;
            }
            var groups = new List<List<string>>();
            bool uncertain = e.Uncertain;
            if (e.Groups is not null) groups = e.Groups;
            else if (cellKind && e.Count >= 2)
            {
                for (int g = 0; g < e.Parts.Count; g += 2) groups.Add([e.Parts[g], g + 1 < e.Parts.Count ? e.Parts[g + 1] : ""]);
            }
            else
            {
                var split = ResolveSplit(ctx, e.Parts, A, B, e.Joiner);
                groups.Add(split.Parts);
                uncertain = uncertain || split.Uncertain;
            }
            Pair? first = null;
            for (int g = 0; g < groups.Count; g++)
            {
                var term = groups[g][0];
                var def = groups[g].Count > 1 ? groups[g][1] : "";
                if (term == "" && def == "") continue;
                var pair = MakePair(term, def, e.Line.Span, uncertain: uncertain, group: g);
                pairs.Add(pair);
                first ??= pair;
            }
            FlushRun(first);
            if (first is not null) prevPair = pairs[^1];
        }
        FlushRun(null);

        if (columnMajor)
        {
            for (int i = 0; i < pairs.Count; i++) pairs[i].Order = i;
            pairs = pairs.OrderBy(p => p.Group ?? 0).ThenBy(p => p.Order).ToList();
        }
        return new ParseOutcome(pairs, "delimited", cand.Kind == "gap" ? "  " : cand.Id);
    }

    /// <summary>Lines inside a delimited list that do not contain the delimiter.</summary>
    static void HandleRun(Ctx ctx, List<Line> run, Pair? prevPair, Pair? nextPair, string? A, string? B, List<Pair> pairs)
    {
        int i = 0, j = run.Count;
        bool Bilingual(Line line)
        {
            var s = LanguageSplit(ctx, DisplayText(line), A, B);
            return s is not null && s.Order == 1;
        }
        while (i < j && prevPair is not null && prevPair.Def != "" && !Bilingual(run[i]) && IsContinuation(ctx, run[i], prevPair.Def, B, A))
        {
            prevPair.Def = JoinParts(prevPair.Def, DisplayText(run[i]));
            prevPair.Lines = SortedUnique(prevPair.Lines.Concat(run[i].Span));
            prevPair.Merged = true;
            ctx.Warnings.Line("merged", run[i].No);
            i++;
        }
        if (j > i && nextPair is not null && nextPair.Term != "" && !Bilingual(run[j - 1]) && IsTermPrefix(ctx, DisplayText(run[j - 1]), A, B))
        {
            nextPair.Term = JoinParts(DisplayText(run[j - 1]), nextPair.Term);
            nextPair.Lines = SortedUnique(nextPair.Lines.Concat(run[j - 1].Span));
            nextPair.Merged = true;
            ctx.Warnings.Line("merged", run[j - 1].No);
            j--;
        }
        var rest = run.GetRange(i, j - i);
        if (rest.Count == 0) return;
        var items = rest.Select(line => new Item(line, DisplayText(line), 0, line.Weak)).ToList();
        var steps = AlignBest(ctx, items, A, B, new AlignOpts("none", true, RUN_UNPAIRED_COST));
        var created = new List<Pair>();
        foreach (var st in steps)
        {
            if (st.Type == "skip") UnpairedLine(ctx, items[st.Index], true, A, B, st.Heading);
            else created.Add(StepToPair(ctx, items, st));
        }
        int insertAt = nextPair is not null ? pairs.IndexOf(nextPair) : -1;
        if (insertAt >= 0) pairs.InsertRange(insertAt, created);
        else pairs.AddRange(created);
    }

    static bool IsContinuation(Ctx ctx, Line line, string prevDef, string? defLang, string? termLang)
    {
        var text = DisplayText(line);
        if (!HasLetter(text) || line.Weak) return false;
        bool known = defLang is not null && termLang is not null;
        double p = PairProb(ctx, text, defLang, termLang);
        if (known && p < 0.6) return false;
        if (line.Indent >= 2) return true;
        if (LooksUnfinished(prevDef) || JsRegex.Test(@"^[,;/)(]", text)) return true;
        return known && StartsLower(text) && !JsRegex.Test(ENTRY_START_RE, text, "iu") && p >= 0.85;
    }

    static bool IsTermPrefix(Ctx ctx, string text, string? termLang, string? defLang)
    {
        if (termLang is null || defLang is null || !StartsLower(text)) return false;
        if (PairProb(ctx, text, termLang, defLang) < 0.6) return false;
        return LooksUnfinished(text);
    }

    static void UnpairedLine(Ctx ctx, Item item, bool inDelimitedList, string? A, string? B, bool isHeading = false)
    {
        var t = item.Text;
        int words = SpaceSplit(t).Length;
        bool heading = isHeading || item.Weak || JsRegex.Test(KEYWORD_RE, t, "iu") || t.EndsWith(':');
        if (!heading && JsRegex.Test(@"^[\p{Lu}\d]", t)) heading = inDelimitedList || (words >= 2 && !t.Contains(','));
        if (!heading && inDelimitedList && A is not null && B is not null)
        {
            double p = PairProb(ctx, t, A, B);
            heading = p > 0.25 && p < 0.75;
        }
        ctx.Skipped.Add(new SkippedLine(item.Line.No, t, heading ? SkipReason.Heading : SkipReason.Unpaired));
        if (!heading) ctx.Warnings.Line("unpaired", item.Line.No);
    }

    // MARK: - Line-based lists: alignment by dynamic programming

    sealed record Item(Line Line, string Text, int Block, bool Weak);
    sealed record DelimSplit(string Left, string Right, double Pl, double Pr, string? DelimId, bool Delim = true);

    static DelimSplit? DelimiterSplit(Ctx ctx, Line line, string? A, string? B)
    {
        bool known = A is not null && B is not null && A != B;
        foreach (var cand in CANDIDATES)
        {
            if (cand.Kind == "gap") continue;
            var split = SplitWith(line, cand);
            if (split.Parts.Count < 2 || split.Parts.Any(p => p == "")) continue;
            var lr = ResolveParts(ctx, split.Parts, A, B, split.Joiner);
            var (left, right) = (lr[0], lr[1]);
            if (left == "" || right == "") continue;
            if (!known) return new DelimSplit(left, right, 0.5, 0.5, cand.Id);
            double pl = PairProb(ctx, left, A, B), pr = PairProb(ctx, right, A, B);
            if ((pl - 0.5) * (pr - 0.5) < 0 && Math.Abs(pl - pr) >= 0.3) return new DelimSplit(left, right, pl, pr, cand.Id);
        }
        return null;
    }

    static DelimSplit? BilingualParts(Ctx ctx, Item item, string? A, string? B, bool known)
    {
        var split = DelimiterSplit(ctx, item.Line, known ? A : null, known ? B : null);
        if (split is not null) return split;
        if (!known || item.Line.Text.Contains('\t')) return null;
        var ls = LanguageSplit(ctx, item.Text, A, B);
        if (ls is null) return null;
        return new DelimSplit(ls.Left, ls.Right, PairProb(ctx, ls.Left, A, B), PairProb(ctx, ls.Right, A, B), null, false);
    }

    sealed record AlignOpts(string Boundary, bool AllowSplit, double UnpairedCost);
    sealed record SplitStep(string Left, string Right, double Cost, bool Lang, string DelimId);

    sealed class Step
    {
        public required string Type; // "card" | "split" | "skip"
        public List<int> Term = [];
        public List<int> Def = [];
        public int Index;
        public SplitStep? Split;
        public bool Heading;
    }

    static (double Cost, List<Step> Steps) Align(Ctx ctx, List<Item> items, string? A, string? B, AlignOpts opts)
    {
        int n = items.Count;
        var (xm, xj) = BOUNDARY[opts.Boundary];
        bool known = A is not null && B is not null && A != B;
        var cT = new double[n];
        var cD = new double[n];
        var splits = new SplitStep?[n];
        for (int i = 0; i < n; i++)
        {
            var bil = opts.AllowSplit ? BilingualParts(ctx, items[i], A, B, known) : null;
            if (bil is not null)
            {
                double extra = known ? 0 : 1;
                cT[i] = Nlog(bil.Pl) + Nlog(bil.Pr) + extra;
                cD[i] = Nlog(1 - bil.Pl) + Nlog(1 - bil.Pr) + extra;
                if (!known || (bil.Pl >= 0.5 && bil.Pr <= 0.5))
                {
                    double cost = Nlog(bil.Pl) + Nlog(1 - bil.Pr) + (bil.Delim ? DELIM_SPLIT_COST : LANG_SPLIT_COST);
                    splits[i] = new SplitStep(bil.Left, bil.Right, cost, !bil.Delim, bil.DelimId ?? " ");
                }
            }
            else
            {
                double p = known ? PairProb(ctx, items[i].Text, A, B) : 0.5;
                cT[i] = Nlog(p);
                cD[i] = Nlog(1 - p);
            }
        }
        var mc = new double[n];
        bool headings = known && A != "de";
        var heading = new bool[n];
        for (int i = 1; i < n; i++)
        {
            var (prev, next) = (items[i - 1].Text, items[i].Text);
            bool sameBlock = items[i].Block == items[i - 1].Block;
            bool inBlock = sameBlock && opts.Boundary == "strong";
            mc[i] = MergeCost(prev, next);
            if (inBlock) mc[i] = Math.Min(mc[i], 1);
            if (!sameBlock) mc[i] += xm;
            heading[i - 1] = headings && !inBlock && LooksLikeHeading(prev, A) && StartsLower(next) && !ContinuesSentence(next);
        }
        var words = items.Select(it => WordCount(it.Text)).ToArray();
        var cognate = items.Select((it, i) => i + 1 < n && !it.Weak && !items[i + 1].Weak && IsCognate(it.Text, items[i + 1].Text)).ToArray();
        var best = new double[n + 1];
        var choice = new (string Type, int A, int B)[n + 1];
        for (int i = n - 1; i >= 0; i--)
        {
            double skipCost = items[i].Weak ? WEAK_HEADING_COST : heading[i] ? Math.Min(HEADING_SKIP_COST, opts.UnpairedCost) : opts.UnpairedCost;
            double bc = skipCost + best[i + 1];
            var ch = ("skip", 0, 0);
            if (splits[i] is { } sp && sp.Cost + best[i + 1] < bc)
            {
                bc = sp.Cost + best[i + 1];
                ch = ("split", 0, 0);
            }
            double termCost = 0;
            int termWords = 0;
            for (int a = 1; a <= 3 && i + a < n; a++)
            {
                int ti = i + a - 1;
                termCost += cT[ti] + (a > 1 ? mc[ti] : 0);
                termWords += words[ti];
                double junction = items[i + a].Block != items[i + a - 1].Block ? xj : 0;
                double defCost = 0;
                int defWords = 0;
                for (int b = 1; b <= 3 && i + a + b <= n; b++)
                {
                    int di = i + a + b - 1;
                    defCost += cD[di] + (b > 1 ? mc[di] : 0);
                    defWords += words[di];
                    double total = termCost + junction + defCost + best[i + a + b];
                    if (a > 1 && heading[i] && RestMatchesLength(termWords, termWords - words[i], defWords)) total += HEADING_MERGE_COST;
                    if (a == 1 && b == 1 && cognate[i])
                        total = Math.Min(total, Math.Min(cT[i], Math.Log(2)) + junction + Math.Min(cD[i + 1], Math.Log(2)) + best[i + 2]);
                    if (total < bc - 1e-9)
                    {
                        bc = total;
                        ch = ("card", a, b);
                    }
                }
            }
            best[i] = bc;
            choice[i] = ch;
        }
        var steps = new List<Step>();
        for (int i = 0; i < n;)
        {
            var ch = choice[i];
            if (ch.Type == "card")
            {
                steps.Add(new Step { Type = "card", Term = Range(i, i + ch.A), Def = Range(i + ch.A, i + ch.A + ch.B) });
                i += ch.A + ch.B;
            }
            else
            {
                steps.Add(ch.Type == "split"
                    ? new Step { Type = "split", Index = i, Split = splits[i] }
                    : new Step { Type = "skip", Index = i, Heading = heading[i] });
                i++;
            }
        }
        return (best[0], steps);
    }

    /// <summary>Try both language orders (which language comes first in the source).</summary>
    static List<Step> AlignBest(Ctx ctx, List<Item> items, string? A, string? B, AlignOpts opts)
    {
        if (items.Count == 0) return [];
        var first = Align(ctx, items, A, B, opts);
        if (A is null || B is null || A == B) return first.Steps;
        var second = Align(ctx, items, B, A, opts);
        return (second.Cost < first.Cost - 1e-9 ? second : first).Steps;
    }

    static List<int> Range(int a, int b) => b > a ? Enumerable.Range(a, b - a).ToList() : [];

    static Pair StepToPair(Ctx ctx, List<Item> items, Step st)
    {
        if (st.Type == "split") return MakePair(st.Split!.Left, st.Split.Right, items[st.Index].Line.Span, langSplit: st.Split.Lang);
        var term = st.Term.Select(i => items[i].Text).Aggregate("", JoinParts);
        var def = st.Def.Select(i => items[i].Text).Aggregate("", JoinParts);
        var lines = st.Term.Concat(st.Def).SelectMany(i => items[i].Line.Span);
        var mergedLines = st.Term.Skip(1).Concat(st.Def.Skip(1)).Select(i => items[i].Line.No).ToList();
        foreach (var no in mergedLines) ctx.Warnings.Line("merged", no);
        return MakePair(term, def, lines, merged: mergedLines.Count > 0);
    }

    sealed class LabelRun
    {
        public int Label;
        public List<int> Idx = [];
    }

    /// <summary>Two-column OCR order: all term lines first, then all definition lines.</summary>
    static List<Pair>? DetectColumns(Ctx ctx, List<Item> items, string? L1, string? L2)
    {
        if (L1 is null || L2 is null || items.Count < 4) return null;
        var labels = items.Select(it =>
        {
            double p = PairProb(ctx, it.Text, L1, L2);
            return p > 0.65 ? 1 : p < 0.35 ? 2 : 0;
        }).ToList();
        var labelled = labels.Where(l => l != 0).ToList();
        int changes = 0;
        for (int k = 1; k < labelled.Count; k++) if (labelled[k] != labelled[k - 1]) changes++;
        if (labelled.Count < 4 || (double)changes / (labelled.Count - 1) >= 0.35) return null;

        if (items.Count % 2 == 0)
        {
            int h = items.Count / 2;
            var top = labels.Take(h).Where(l => l != 0).ToList();
            var bottom = labels.Skip(h).Where(l => l != 0).ToList();
            double Share(List<int> list, int lab) => list.Count(l => l == lab) / (double)list.Count;
            foreach (var (a, b) in new[] { (1, 2), (2, 1) })
            {
                if (top.Count >= 2 && bottom.Count >= 2 && Share(top, a) >= 0.8 && Share(bottom, b) >= 0.8)
                    return Range(0, h).Select(k => MakePair(items[k].Text, items[k + h].Text, items[k].Line.Span.Concat(items[k + h].Line.Span))).ToList();
            }
        }

        var runs = new List<LabelRun>();
        for (int i = 0; i < labels.Count; i++)
        {
            int lab = labels[i];
            var last = runs.Count > 0 ? runs[^1] : null;
            if (last is not null && (lab == 0 || last.Label == lab || last.Label == 0))
            {
                if (last.Label == 0) last.Label = lab;
                last.Idx.Add(i);
            }
            else runs.Add(new LabelRun { Label = lab, Idx = [i] });
        }
        for (bool changed = true; changed;)
        {
            changed = false;
            for (int r = 1; r < runs.Count - 1; r++)
            {
                var (a, m, b) = (runs[r - 1], runs[r], runs[r + 1]);
                if (m.Idx.Count == 1 && a.Label == b.Label && a.Idx.Count >= 2 && b.Idx.Count >= 2)
                {
                    a.Idx.AddRange(m.Idx);
                    a.Idx.AddRange(b.Idx);
                    runs.RemoveRange(r, 2);
                    changed = true;
                    break;
                }
            }
            if (changed || runs.Count < 3) continue;
            if (runs[0].Idx.Count == 1 && runs[1].Idx.Count >= 3)
            {
                runs[1].Idx.InsertRange(0, runs[0].Idx);
                runs.RemoveAt(0);
                changed = true;
            }
            else if (runs[^1].Idx.Count == 1 && runs[^2].Idx.Count >= 3)
            {
                runs[^2].Idx.AddRange(runs[^1].Idx);
                runs.RemoveAt(runs.Count - 1);
                changed = true;
            }
        }
        if (runs.Count < 2 || runs.Count % 2 != 0 || (double)items.Count / runs.Count < 3) return null;
        for (int r = 0; r < runs.Count; r++) if (runs[r].Label == 0 || (r > 0 && runs[r].Label == runs[r - 1].Label)) return null;

        var columns = new List<(List<int> Left, List<int> Right, int M)>();
        for (int r = 0; r < runs.Count; r += 2)
        {
            var left = runs[r].Idx;
            var right = runs[r + 1].Idx;
            if (runs.Count == 2 && items.Count % 2 == 0 && Math.Abs(left.Count - right.Count) <= 2)
            {
                left = Range(0, items.Count / 2);
                right = Range(items.Count / 2, items.Count);
            }
            int m = Math.Min(left.Count, right.Count);
            if (Math.Abs(left.Count - right.Count) > Math.Max(1, (int)JSCompat.Round(m * 0.25))) return null;
            columns.Add((left, right, m));
        }
        var pairs = new List<Pair>();
        foreach (var (left, right, m) in columns)
        {
            if (left.Count != right.Count) ctx.Warnings.Add(L($"Die beiden Spalten sind unterschiedlich lang ({left.Count} und {right.Count} Zeilen)."));
            for (int k = 0; k < m; k++)
            {
                var (a, b) = (items[left[k]], items[right[k]]);
                pairs.Add(MakePair(a.Text, b.Text, a.Line.Span.Concat(b.Line.Span)));
            }
            foreach (var i in left.Skip(m).Concat(right.Skip(m))) UnpairedLine(ctx, items[i], false, L1, L2);
        }
        return pairs;
    }

    static ParseOutcome ParseLineBased(Ctx ctx, List<Line> lines, bool allowSplit)
    {
        var items = new List<Item>();
        int block = 0;
        bool open = false;
        foreach (var line in lines)
        {
            if (line.Blank)
            {
                if (open) block++;
                open = false;
                continue;
            }
            if (line.Kind is not null) continue;
            items.Add(new Item(line, DisplayText(line), block, line.Weak));
            open = true;
        }
        var sizes = new Dictionary<int, int>();
        var blockOrder = new List<int>();
        foreach (var it in items)
        {
            if (!sizes.ContainsKey(it.Block)) blockOrder.Add(it.Block);
            sizes[it.Block] = sizes.GetValueOrDefault(it.Block) + 1;
        }
        var counts = blockOrder.Select(b => sizes[b]).ToList();
        int nb = counts.Count;
        double share1 = counts.Count(c => c == 1) / (double)nb;
        double share2 = counts.Count(c => c == 2) / (double)nb;
        var boundary = "medium";
        if (nb <= 1) boundary = "none";
        else if (share1 >= 0.6) boundary = "weak";
        else if (share2 >= 0.5) boundary = "strong";

        var (L1, L2) = TopTwoLanguages(ctx, items.Select(it => it.Text));
        if (boundary != "strong")
        {
            var colPairs = DetectColumns(ctx, items, L1, L2);
            if (colPairs is not null) return new ParseOutcome(colPairs, "columns", null);
        }
        var steps = AlignBest(ctx, items, L1, L2, new AlignOpts(boundary, allowSplit, UNPAIRED_COST));
        var pairs = new List<Pair>();
        var used = new List<string>();
        foreach (var st in steps)
        {
            if (st.Type == "skip") UnpairedLine(ctx, items[st.Index], false, L1, L2, st.Heading);
            else pairs.Add(StepToPair(ctx, items, st));
            if (st.Type == "split") used.Add(st.Split!.DelimId);
        }
        if (pairs.Count > 0 && used.Count >= 0.6 * pairs.Count) return new ParseOutcome(pairs, "delimited", MostFrequent(used));
        return new ParseOutcome(pairs, boundary == "strong" ? "blocks" : "alternating", null);
    }

    /// <summary>The most frequent element (the first one in insertion order on ties).</summary>
    static T? MostFrequent<T>(List<T> list) where T : notnull
    {
        var counts = new Dictionary<T, int>();
        var order = new List<T>();
        foreach (var x in list)
        {
            if (!counts.ContainsKey(x)) order.Add(x);
            counts[x] = counts.GetValueOrDefault(x) + 1;
        }
        T? best = default;
        bool has = false;
        foreach (var x in order) if (!has || counts[x] > counts[best!]) { best = x; has = true; }
        return best;
    }

    /// <summary>Bilingual lines without one common delimiter ("le chat die Katze", mixed delimiters).</summary>
    static ParseOutcome? DetectBilingual(Ctx ctx, List<Line> content)
    {
        var (L1, L2) = TopTwoLanguages(ctx, content.Select(DisplayText));
        (string?, string?) ByWords() => TopTwoLanguages(ctx, content.Take(200).SelectMany(l => SpaceSplit(DisplayText(l))));
        bool lineVote = L2 is not null;
        if (L1 is not null && L2 is null) (L1, L2) = ByWords();
        if (L1 is null || L2 is null) return null;
        LangSplitResult? Split(string text, string A, string B) => LanguageSplit(ctx, text, A, B) ?? TwoWordSplit(ctx, text, A, B);
        (string, string)? Ordered(string first, string second)
        {
            int ok = 0, order = 0;
            foreach (var line in content)
            {
                var d = DelimiterSplit(ctx, line, first, second);
                int? o = d is not null ? (d.Pl > d.Pr ? 1 : -1) : Split(DisplayText(line), first, second)?.Order;
                if (o is { } v) { ok++; order += v; }
            }
            if ((double)ok / content.Count < 0.7 || Math.Abs(order) / (double)ok < 0.6) return null;
            return order > 0 ? (first, second) : (second, first);
        }
        var langs = Ordered(L1, L2);
        if (langs is null && lineVote)
        {
            var (W1, W2) = ByWords();
            if (W1 is not null && W2 is not null && new HashSet<string> { L1, L2, W1, W2 }.Count > 2) langs = Ordered(W1, W2);
        }
        if (langs is not { } ab) return null;
        var (A, B) = ab;
        var pairs = new List<object?>();
        var used = new List<string>();
        var shapes = new List<(int L, int R)>();
        var pending = new List<(Line Line, int At)>();
        foreach (var line in content)
        {
            var d = DelimiterSplit(ctx, line, A, B);
            if (d is not null)
            {
                pairs.Add(MakePair(d.Left, d.Right, line.Span));
                used.Add(d.DelimId!);
                continue;
            }
            var s = Split(DisplayText(line), A, B);
            if (s is not null && s.Order == 1)
            {
                pairs.Add(MakePair(s.Left, s.Right, line.Span, langSplit: true));
                shapes.Add((Segments(s.Left).Count, Segments(s.Right).Count));
                used.Add(" ");
            }
            else
            {
                pairs.Add(null);
                pending.Add((line, pairs.Count - 1));
            }
        }
        ResolvePending(ctx, pairs, pending, shapes, A, B);
        var explicitIds = used.Where(id => id != " ").ToList();
        var delimiter = explicitIds.Count >= 0.5 * used.Count ? MostFrequent(explicitIds) : " ";
        return new ParseOutcome(pairs.OfType<Pair>().ToList(), "delimited", delimiter);
    }

    static void ResolvePending(Ctx ctx, List<object?> pairs, List<(Line Line, int At)> pending, List<(int L, int R)> shapes, string A, string B)
    {
        var run = new List<(Line Line, int At)>();
        void Flush()
        {
            if (run.Count == 0) return;
            var created = new List<Pair>();
            HandleRun(ctx, run.Select(p => p.Line).ToList(), null, null, A, B, created);
            pairs[run[0].At] = created;
            run = [];
        }
        int prevAt = -2;
        foreach (var p in pending)
        {
            if (p.At != prevAt + 1) Flush();
            prevAt = p.At;
            var text = DisplayText(p.Line);
            var segs = Segments(text);
            int k = UsualBoundary(shapes, segs.Count);
            if (k > 0)
            {
                var (left, right) = CutAt(text, segs, k);
                if (HasLetter(left) && HasLetter(right))
                {
                    Flush();
                    double Lean(string t) { var s = ctx.Score(t); return s[A] - s[B]; }
                    pairs[p.At] = MakePair(left, right, p.Line.Span, langSplit: true, uncertain: Lean(left) <= Lean(right));
                    continue;
                }
            }
            run.Add(p);
        }
        Flush();
        for (int i = pairs.Count - 1; i >= 0; i--)
        {
            if (pairs[i] is List<Pair> list)
            {
                pairs.RemoveAt(i);
                pairs.InsertRange(i, list);
            }
        }
    }

    static int UsualBoundary(List<(int L, int R)> shapes, int total)
    {
        var same = shapes.Where(s => s.L + s.R == total).ToList();
        if (same.Count < 3) return 0;
        int left = MostFrequent(same.Select(s => s.L).ToList());
        return same.Count(s => s.L == left) >= 0.6 * same.Count ? left : 0;
    }

    // MARK: - Explicit delimiter mode

    static string NormalizeDelimiter(string d)
    {
        var output = JsRegex.ReplaceAll(d, "[–—‒‐‑−]", "-");
        output = JsRegex.ReplaceAll(output, @"[  -   　]", " ");
        output = JsRegex.ReplaceAll(output, "[’‘`´ʼ′]", "'");
        return output == "" ? "\t" : output;
    }

    static List<(string Chunk, int No)> RecordsFrom(string source, string sep)
    {
        var t = source;
        if (t.Length > 0 && t[0] == '﻿') t = t[1..];
        t = JsRegex.ReplaceAll(t, @"\r\n?", "\n");
        var records = new List<(string, int)>();
        int start = 0;
        void Push(int end)
        {
            var chunk = t[start..end];
            int lead = chunk.Length - JSCompat.TrimStart(chunk).Length;
            records.Add((chunk, t[..(start + lead)].Count(c => c == '\n') + 1));
        }
        if (JsRegex.Test(@"^\n+$", sep))
        {
            foreach (System.Text.RegularExpressions.Match m in JsRegex.Get(@"\n[ \t]*\n\s*").Matches(t))
            {
                Push(m.Index);
                start = m.Index + m.Length;
            }
        }
        else
        {
            for (int idx = t.IndexOf(sep, StringComparison.Ordinal); idx != -1; idx = t.IndexOf(sep, start, StringComparison.Ordinal))
            {
                Push(idx);
                start = idx + sep.Length;
            }
        }
        Push(t.Length);
        return records;
    }

    static ParseOutcome ParseWithDelimiter(Ctx ctx, string source)
    {
        var o = ctx.O;
        var delim = NormalizeDelimiter(o.Delimiter ?? "\t");
        var sep = o.CardSeparator;
        if (delim.Contains('\n'))
        {
            var pairs = new List<Pair>();
            var inner = JSCompat.Trim(delim) is { Length: > 0 } tr ? tr : "\n";
            foreach (var (chunk, no) in RecordsFrom(source, sep == "\n" ? "\n\n" : sep))
            {
                var trimmed = JSCompat.Trim(chunk);
                if (trimmed.Length == 0) continue;
                int idx = trimmed.IndexOf(inner, StringComparison.Ordinal);
                var term = TextNormalizer.NormalizeBasic(idx == -1 ? trimmed : trimmed[..idx]);
                var def = idx == -1 ? "" : TextNormalizer.NormalizeBasic(trimmed[(idx + inner.Length)..]);
                int lastLine = no + trimmed.Count(c => c == '\n');
                if (term.Length > 0 || def.Length > 0) pairs.Add(MakePair(term, def, Range(no, lastLine + 1)));
            }
            return new ParseOutcome(pairs, "delimited", delim);
        }
        bool dashList = JSCompat.Trim(delim) == "-";
        List<Line> lines;
        if (sep is "\n" or "\r\n" or "\r") lines = Classify(ctx, Preprocess(source, dashList));
        else
        {
            var records = RecordsFrom(source, sep).Select(r =>
            {
                var line = MakeLine(SpaceGluedDashes([r.Chunk.Replace('\n', ' ')], dashList)[0], r.No);
                int extra = JSCompat.Trim(r.Chunk).Count(c => c == '\n');
                line.Span = Range(r.No, r.No + extra + 1);
                return line;
            }).ToList();
            lines = Classify(ctx, records);
        }
        var result = ParseDelimitedLines(ctx, lines, CustomCandidate(delim));
        return result with { Delimiter = delim };
    }

    // MARK: - Orchestration & post-processing

    static ParseResult ParseInternal(string source, Opts o)
    {
        var ctx = new Ctx(o);
        if (o.Mode == "delimiter") return Finish(ctx, ParseWithDelimiter(ctx, source));
        var lines = Classify(ctx, Preprocess(source));
        var content = lines.Where(l => !l.Blank && l.Kind is null).ToList();
        if (content.Count == 0) return Finish(ctx, new ParseOutcome([], "empty", null));
        if (o.Mode == "auto")
        {
            if (DetectInline(ctx, content) is { } inline) return Finish(ctx, inline);
            if (DetectDelimiter(ctx, lines) is { } cand) return Finish(ctx, ParseDelimitedLines(ctx, lines, cand));
            if (DetectBilingual(ctx, content) is { } bilingual) return Finish(ctx, bilingual);
        }
        return Finish(ctx, ParseLineBased(ctx, lines, o.Mode == "auto"));
    }

    static bool KnownLang(string? l) => l is not null && l != "unknown";

    static (string L, string R) DistinctLanguages(Ctx ctx, List<string> leftTexts, List<string> rightTexts, string L, string R)
    {
        if (!KnownLang(L) || L != R) return (L, R);
        var ls = LanguageShares(ctx, leftTexts);
        var rs = LanguageShares(ctx, rightTexts);
        (double S, string L, string R)? best = null;
        foreach (var a in ls)
            foreach (var b in rs)
            {
                if (a.Lang == b.Lang || a.Share < 0.15 || b.Share < 0.15) continue;
                double s = a.Share + b.Share;
                if (best is null || s > best.Value.S) best = (s, a.Lang, b.Lang);
            }
        return best is { } x ? (x.L, x.R) : (L, R);
    }

    static (string L, double LConf, string R, double RConf) ApplyTermHint(Ctx ctx, List<string> leftTexts, List<string> rightTexts, (string L, double LConf, string R, double RConf) langs)
    {
        var (L, lConf, R, rConf) = langs;
        var hint = ctx.O.TermHint;
        var target = ctx.O.DefHint ?? "de";
        if (hint is null || hint == target || L == hint || R == hint) return langs;
        bool Pinyin(List<string> texts) => hint == "zh" && texts.Count > 0 && texts.Count(IsPinyinCell) >= 0.8 * texts.Count;
        if (KnownLang(L) && L != target && Pinyin(leftTexts)) return (hint, Math.Max(lConf, 0.55), R, rConf);
        if (L == target && KnownLang(R) && Pinyin(rightTexts)) return (L, lConf, hint, Math.Max(rConf, 0.55));
        bool Close(List<string> texts)
        {
            var shares = LanguageShares(ctx, texts);
            int own = shares.FindIndex(s => s.Lang == hint);
            return own >= 0 && own < 2 && shares[own].Share >= 0.5 * shares[0].Share;
        }
        if (KnownLang(L) && L != target && Close(leftTexts)) return (hint, Math.Max(lConf, 0.55), R, rConf);
        if (L == target && KnownLang(R) && Close(rightTexts)) return (L, lConf, hint, Math.Max(rConf, 0.55));
        return langs;
    }

    /// <summary>Loanwords / cognates ("charmant, charmante" = "charmant") carry no language signal.</summary>
    static bool IsCognate(string a, string b)
    {
        List<string> Tok(string s) => JsRegex.MatchAll(JSCompat.Lower(s), @"\p{L}{3,}");
        var ta = Tok(a);
        var tb = Tok(b);
        if (ta.Count == 0 || tb.Count == 0) return false;
        var (small, big) = ta.Count <= tb.Count ? (ta, new HashSet<string>(tb, StringComparer.Ordinal)) : (tb, new HashSet<string>(ta, StringComparer.Ordinal));
        return small.All(big.Contains);
    }

    static ParseResult Finish(Ctx ctx, ParseOutcome result)
    {
        var o = ctx.O;
        var pairs = result.Pairs.Where(p => p.Term != "" || p.Def != "").ToList();
        var leftTexts = pairs.Select(p => p.Term).Where(t => t != "").ToList();
        var rightTexts = pairs.Select(p => p.Def).Where(t => t != "").ToList();
        var lc = LangDetect.DetectColumn(leftTexts);
        var rc = LangDetect.DetectColumn(rightTexts);
        var (L, R) = DistinctLanguages(ctx, leftTexts, rightTexts, lc.Lang.Raw(), rc.Lang.Raw());
        double lConf = lc.Confidence, rConf = rc.Confidence;
        (L, lConf, R, rConf) = ApplyTermHint(ctx, leftTexts, rightTexts, (L, lConf, R, rConf));

        if (ctx.Header is { Left: { } hl, Right: { } hr })
        {
            if (!KnownLang(L) || lConf < 0.55) (L, lConf) = (hl, 0.6);
            if (!KnownLang(R) || rConf < 0.55) (R, rConf) = (hr, 0.6);
        }

        var target = o.DefHint ?? "de";
        bool autoSwap = false;
        if (o.Orient && KnownLang(L) && KnownLang(R) && L != R)
        {
            if (L == target && R != target) autoSwap = true;
            else if (R != target && o.TermHint is not null && R == o.TermHint && L != o.TermHint) autoSwap = true;
        }
        else if (o.Orient && KnownLang(L) != KnownLang(R))
        {
            autoSwap = KnownLang(R) ? R != target : L == target;
        }
        bool swapped = autoSwap != o.Swap;
        if (swapped)
        {
            foreach (var p in pairs) (p.Term, p.Def) = (p.Def, p.Term);
            (L, R) = (R, L);
            (lConf, rConf) = (rConf, lConf);
        }

        bool distinct = KnownLang(L) && KnownLang(R) && L != R;
        var cards = new List<ParsedCard>();
        var seen = new Dictionary<string, (string Term, List<int> Lines)>(StringComparer.Ordinal);
        var seenOrder = new List<string>();
        foreach (var p in pairs)
        {
            var term = p.Term;
            var def = p.Def;
            double? pT = term != "" ? PairProb(ctx, term, L, R) : null;
            double? pD = def != "" ? PairProb(ctx, def, R, L) : null;
            bool cognate = term != "" && def != "" && IsCognate(term, def);
            if (distinct && !cognate && pT is { } t0 && pD is { } d0 && t0 < 0.1 && d0 < 0.1)
            {
                (term, def) = (def, term);
                (pT, pD) = (1 - d0, 1 - t0);
                ctx.Warnings.Line("reversed", p.Lines[0]);
            }
            var flags = new List<ParseFlag>();
            double confidence = 0.75;
            bool mismatch = false;
            if (distinct && !cognate)
            {
                if (pT is { } t && pD is { } d) confidence = t * d / (t * d + (1 - t) * (1 - d));
                else confidence = pT ?? pD ?? 0.5;
                mismatch = (pT is { } t1 && t1 < 0.1) || (pD is { } d1 && d1 < 0.1);
            }
            if (p.Merged) confidence *= 0.85;
            if (p.LangSplit) confidence *= 0.85;
            if (p.Uncertain) confidence *= 0.45;
            if (p.Merged) flags.Add(ParseFlag.Merged);
            if (confidence < 0.5) { flags.Add(ParseFlag.LowConfidence); ctx.Warnings.Line("lowConfidence", p.Lines[0]); }
            if (mismatch) { flags.Add(ParseFlag.LangMismatch); ctx.Warnings.Line("langMismatch", p.Lines[0]); }
            if (term == "") { flags.Add(ParseFlag.MissingTerm); ctx.Warnings.Line("missingTerm", p.Lines[0]); }
            if (def == "") { flags.Add(ParseFlag.MissingDefinition); ctx.Warnings.Line("missingDefinition", p.Lines[0]); }
            var key = JsRegex.ReplaceAll(JsRegex.ReplaceFirst(JSCompat.Lower(term), @"[\s.!?]+$", ""), @"\s+", " ");
            if (key.Length > 0)
            {
                if (seen.TryGetValue(key, out var entry))
                {
                    flags.Add(ParseFlag.Duplicate);
                    entry.Lines.Add(p.Lines[0]);
                }
                else
                {
                    seen[key] = (term, [p.Lines[0]]);
                    seenOrder.Add(key);
                }
            }
            cards.Add(new ParsedCard(term, def, JSCompat.Round(confidence * 100) / 100, flags, p.Lines));
        }

        foreach (var key in seenOrder)
        {
            var (term, lines) = seen[key];
            if (lines.Count > 1) ctx.Warnings.Duplicate(term, lines);
        }
        int skipCount = ctx.Skipped.Count(s => s.Reason != SkipReason.Unpaired);
        if (skipCount > 0) ctx.Warnings.Add(SkippedLinesWarning(skipCount));
        // CoreText.L in full: this method has a local L (the left side's language).
        if (cards.Count >= 3 && !distinct) ctx.Warnings.Add(CoreText.L("Die Sprachen der beiden Seiten konnten nicht sicher erkannt werden."));

        string PickLang(string lang, double conf, string? hint) => KnownLang(lang) && (conf >= 0.55 || hint is null) ? lang : hint ?? "other";
        var format = cards.Count > 0 || result.Format != "empty" ? result.Format : "empty";
        return new ParseResult(
            cards,
            EnumRaw.Parse<ParseFormat>(format)!.Value,
            format == "delimited" ? result.Delimiter : null,
            ToLang(PickLang(L, lConf, o.TermHintRaw)),
            ToLang(PickLang(R, rConf, o.DefHintRaw)),
            swapped,
            ctx.Skipped.OrderBy(s => s.Line).ToList(),
            ctx.Warnings.Build());
    }

    // MARK: - Warnings (German source, translated with CoreText.L)

    /// <summary>The kinds of line warnings, in display order.</summary>
    static readonly string[] LINE_WARNINGS = ["unpaired", "merged", "reversed", "lowConfidence", "langMismatch", "missingTerm", "missingDefinition"];

    /// <summary>The warning of a kind for the line numbers <paramref name="n"/> ("3", "3 und 5"); <paramref name="one"/>: a single line.</summary>
    static string LineWarning(string kind, bool one, string n) => kind switch
    {
        "unpaired" => one ? L($"Zeile {n} konnte keinem Paar zugeordnet werden.") : L($"Zeilen {n} konnten keinem Paar zugeordnet werden."),
        "merged" => one
            ? L($"Zeile {n} wurde als Fortsetzung der vorherigen Zeile übernommen.")
            : L($"Zeilen {n} wurden als Fortsetzung der vorherigen Zeile übernommen."),
        "reversed" => one
            ? L($"Zeile {n}: Begriff und Definition waren vertauscht und wurden umgedreht.")
            : L($"Zeilen {n}: Begriff und Definition waren vertauscht und wurden umgedreht."),
        "lowConfidence" => one ? L($"Zeile {n} wurde unsicher erkannt – bitte prüfen.") : L($"Zeilen {n} wurden unsicher erkannt – bitte prüfen."),
        "langMismatch" => one ? L($"Zeile {n} passt sprachlich nicht zu ihrer Spalte.") : L($"Zeilen {n} passen sprachlich nicht zu ihrer Spalte."),
        "missingTerm" => one ? L($"Zeile {n}: Der Begriff fehlt.") : L($"Zeilen {n}: Der Begriff fehlt."),
        _ => one ? L($"Zeile {n}: Die Definition fehlt.") : L($"Zeilen {n}: Die Definition fehlt."),
    };

    static string ListNumbers(List<int> nos)
    {
        var shown = nos.Take(6).ToList();
        int more = nos.Count - shown.Count;
        if (more > 0) return L($"{string.Join(", ", shown)} und {more} weitere");
        if (shown.Count == 1) return shown[0].ToString();
        return L($"{string.Join(", ", shown.Take(shown.Count - 1))} und {shown[^1]}");
    }

    sealed class Warnings
    {
        readonly Dictionary<string, List<int>> _byKind = new(StringComparer.Ordinal);
        readonly List<string> _extra = [];
        readonly List<(string Term, List<int> Nos)> _dups = [];

        public void Line(string kind, int no)
        {
            if (!_byKind.TryGetValue(kind, out var list)) _byKind[kind] = list = [];
            if (!list.Contains(no)) list.Add(no);
        }

        public void Add(string message)
        {
            if (!_extra.Contains(message)) _extra.Add(message);
        }

        public void Duplicate(string term, List<int> nos) => _dups.Add((term, nos));

        public List<string> Build()
        {
            var output = new List<string>();
            foreach (var kind in LINE_WARNINGS)
            {
                if (!_byKind.TryGetValue(kind, out var nos) || nos.Count == 0) continue;
                var sorted = nos.OrderBy(x => x).ToList();
                output.Add(LineWarning(kind, sorted.Count == 1, ListNumbers(sorted)));
            }
            if (_dups.Count > 3) output.Add(L($"{_dups.Count} Begriffe kommen mehrfach vor."));
            else foreach (var d in _dups) output.Add(L($"«{d.Term}» kommt mehrfach vor (Zeilen {ListNumbers(d.Nos)})."));
            output.AddRange(_extra);
            return output;
        }
    }
}
