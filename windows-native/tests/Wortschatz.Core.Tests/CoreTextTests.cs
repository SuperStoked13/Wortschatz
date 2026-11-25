using System.Text;
using System.Text.RegularExpressions;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// The texts' language (CoreText, TextTable; Mac: CoreTextTests.swift, LocalizationTests). Without a table every text stays
// German – what all other tests see. The tests that switch to English run alone (collection below), since the table is
// global and the parity tests compare German texts.

[CollectionDefinition("CoreText", DisableParallelization = true)]
public sealed class CoreTextCollection;

public class CoreTextFillTests
{
    static string KeyOf(ref TextHandler text) => text.Key;

    [Fact]
    public void FillTakesValuesInOrderOrByNumber()
    {
        Assert.Equal("Runde 3 geschafft", CoreText.Fill("Runde %@ geschafft", ["3"]));
        Assert.Equal("11/24/2026", CoreText.Fill("%2$@/%1$@/%3$@", ["24", "11", "2026"]));
        Assert.Equal("50 %", CoreText.Fill("%@ %%", ["50"]));
        Assert.Equal("a % b", CoreText.Fill("a % b", []));
        Assert.Equal("x  y", CoreText.Fill("x %@ %@y", [""]));
    }

    [Fact]
    public void AnInterpolatedTextIsItsLiteralWithPlaceholders()
    {
        int n = 3;
        string word = "Karten";
        Assert.Equal("Runde %@ geschafft", KeyOf($"Runde {n} geschafft"));
        Assert.Equal("%@ %@", KeyOf($"{n} {word}"));
        Assert.Equal("%@ %%", KeyOf($"{n} %"));
        Assert.Equal("«%@» gelöscht", KeyOf($"«{word}» gelöscht"));
    }

    [Fact]
    public void WithoutATableEverythingStaysGerman()
    {
        Assert.Null(CoreText.Table);
        int n = 4;
        Assert.Equal("Noch 4 Karten", CoreText.L($"Noch {n} Karten"));
        Assert.Equal("4 Karten", Labels.Plural(n, "Karte", "Karten"));
        Assert.Equal("Französisch", Labels.LangName(Lang.Fr));
        Assert.Equal("vor 4 Tagen", CoreText.L("vor %@ Tagen", "4"));
    }

    [Fact]
    public void TheMacNumberPlaceholdersBecomeStringPlaceholders()
    {
        Assert.Equal("%@ Karten", TextTable.NormalizePlaceholders("%lld Karten"));
        Assert.Equal("%2$@ von %1$@", TextTable.NormalizePlaceholders("%2$lld von %1$lld"));
        Assert.Equal("%@ %%", TextTable.NormalizePlaceholders("%lld %%"));
    }

    [Fact]
    public void TheEnglishTableHasTheMacCatalogAndTheWindowsTexts()
    {
        var en = TextTable.English;
        Assert.True(en.Count > 1000);
        Assert.Equal("Restart?", en.Lookup("Neu starten?", null));
        Assert.Equal("%@ cards", en.Lookup("%@ Karten", null));
        Assert.Equal("%2$@/%1$@/%3$@", en.Lookup("%@.%@.%@", null));
        // A Mac text with forms per number.
        Assert.Equal("%@ typo?", en.Lookup("%@ Tippfehler?", ["1"]));
        Assert.Equal("%@ typos?", en.Lookup("%@ Tippfehler?", ["2"]));
        Assert.Null(en.Lookup("Kein solcher Text", null));
    }
}

[Collection("CoreText")]
public class CoreTextEnglishTests
{
    [Fact]
    public void WithTheEnglishTableTextsAreEnglish()
    {
        try
        {
            CoreText.Table = TextTable.English;
            int n = 3;
            Assert.Equal("en", CoreText.Language);
            Assert.Equal("3 cards", CoreText.L($"{n} Karten"));
            Assert.Equal("1 card", Labels.Plural(1, "Karte", "Karten"));
            Assert.Equal("French", Labels.LangName(Lang.Fr));
            Assert.Equal("3 days ago", CoreText.L("vor %@ Tagen", "3"));
            // Not in the table: German, filled.
            Assert.Equal("Gibt es nicht 3", CoreText.L($"Gibt es nicht {n}"));
            // Voice names: language and region in English (German: «Englisch, Vereinigtes Königreich»).
            Assert.Equal("Microsoft Hazel (English, United Kingdom)", SpeechText.DisplayName(new VoiceInfo("hazel", "Microsoft Hazel", "en-GB")));
            Assert.Equal("Microsoft Karsten (German, Switzerland)", SpeechText.DisplayName(new VoiceInfo("karsten", "Microsoft Karsten", "de-CH")));
        }
        finally
        {
            CoreText.Table = null;
        }
    }
}

/// <summary>
/// Every text the app passes through <c>L(…)</c> (and every word of <c>Labels.Plural</c>) has English – the Mac's
/// catalog or Strings/en.json (Mac: test.sh reports texts without English). Same rules as <c>tools/strings.py check</c>,
/// which lists them with file and line.
/// </summary>
public class TranslationCoverageTests
{
    internal const string? SkippedIf = null;
    const string? LeftOut = null;
    static bool Skipped(string[] parts, string name) => false;

    static string SourceDir
    {
        get
        {
            var d = new DirectoryInfo(AppContext.BaseDirectory);
            while (d is not null)
            {
                var candidate = Path.Combine(d.FullName, "windows-native", "src");
                if (Directory.Exists(Path.Combine(candidate, "Wortschatz.App"))) return candidate;
                d = d.Parent;
            }
            throw new DirectoryNotFoundException("windows-native/src not found");
        }
    }

    [Fact]
    public void EveryTextHasEnglish()
    {
        var en = TextTable.English;
        var missing = new List<string>();
        int count = 0;
        foreach (var root in Directory.GetDirectories(SourceDir).Order(StringComparer.Ordinal))
        {
            foreach (var file in Directory.EnumerateFiles(root, "*.cs", SearchOption.AllDirectories))
            {
                var rel = Path.GetRelativePath(SourceDir, file);
                var parts = rel.Split(Path.DirectorySeparatorChar);
                if (parts.Contains("obj") || parts.Contains("bin") || Skipped(parts, Path.GetFileName(file))) continue;
                foreach (var (line, key) in SourceKeys.In(File.ReadAllText(file)))
                {
                    count++;
                    if (!en.Contains(key)) missing.Add($"{rel}:{line}: {key}");
                }
            }
        }
        Assert.True(count > 0);
        Assert.True(missing.Count == 0, $"{missing.Count} texts without English (tools/strings.py check):\n" + string.Join("\n", missing.Take(80)));
    }

    /// <summary>en-mac.json is the Mac's catalog as it is now (else: tools/strings.py sync).</summary>
    [Fact]
    public void TheCopyOfTheMacTextsIsUpToDate()
    {
        var repo = Path.GetDirectoryName(Path.GetDirectoryName(SourceDir))!;
        var catalog = JSONValue.Parse(File.ReadAllBytes(Path.Combine(repo, "mac", "Wortschatz", "Resources", "Localizable.xcstrings")));
        var fromCatalog = new TextTable("en");
        fromCatalog.AddCatalog(catalog, "en", leaveOut: LeftOut);
        var copy = TextTable.MacCopy();
        var stale = fromCatalog.Keys.Where(k => copy.EntryFor(k) != fromCatalog.EntryFor(k))
            .Concat(copy.Keys.Where(k => !fromCatalog.Contains(k))).Distinct().ToList();
        Assert.True(stale.Count == 0, $"en-mac.json is not the Mac catalog (python3 tools/strings.py sync): {string.Join(" | ", stale.Take(20))}");
        if (LeftOut is not null) Assert.DoesNotContain(copy.Keys, k => k.Contains(LeftOut));
    }

    [Fact]
    public void TheScannerReadsKeysLikeTheHandler()
    {
        const string src = """
            var a = L("Neu starten?");
            var b = L($"Runde {round} geschafft");
            var c = L($"«{AppModel.ShortTitle(set.Title)}» gelöscht");
            var d = Labels.Plural(n, "Karte", "Karten");
            var e = L($"{n} %");
            var f = L("vor %@ Tagen", days.ToString());
            var h = L($"{(x ? "a" : "b")} und {y:0.0}");
            var i = CoreText.L("Kern");
            /// <summary><c>L("Nur ein Beispiel")</c></summary>
            var j = L("%@ " + word, n.ToString());
            """;
        var keys = SourceKeys.In(src).Select(k => k.Key).ToList();
        Assert.Equal(["Neu starten?", "Runde %@ geschafft", "«%@» gelöscht", "%@ Karte", "%@ Karten", "%@ %%", "vor %@ Tagen", "%@ und %@", "Kern"], keys);
    }
}

/// <summary>Reads the keys of <c>L(…)</c> and <c>Labels.Plural(…)</c> calls from C# source (port of tools/strings.py).</summary>
static partial class SourceKeys
{
    [GeneratedRegex(@"(?<![\w.])(?:CoreText\.)?L\(\s*(?=[$@]*"")|Labels\.Plural\(")]
    private static partial Regex Call();

    public static IEnumerable<(int Line, string Key)> In(string source)
    {
        string src = WithoutSkippedBlocks(source);
        foreach (Match m in Call().Matches(src))
        {
            int line = 1 + src.AsSpan(0, m.Index).Count('\n');
            int j = m.Index + m.Length;
            if (m.Value.StartsWith("Labels.Plural", StringComparison.Ordinal))
            {
                int depth = 0;
                while (j < src.Length)
                {
                    char c = src[j];
                    if (c is '(' or '[') depth++;
                    else if (c is ')' or ']') { if (depth == 0) break; depth--; }
                    else if (c == ',' && depth == 0) break;
                    j++;
                }
                j++;
                for (int k = 0; k < 2; k++)
                {
                    while (j < src.Length && src[j] is ' ' or '\n' or '\r' or '\t' or ',') j++;
                    var lit = Literal(src, j);
                    if (lit is null || lit.Value.Holes) break;
                    yield return (line, "%@ " + lit.Value.Text);
                    j = lit.Value.End;
                }
                continue;
            }
            while (j < src.Length && char.IsWhiteSpace(src[j])) j++;
            if (Literal(src, j) is not { } l) continue;
            // L("%@ " + word): a key built at run time (Labels.Plural) – not a text of its own.
            int after = l.End;
            while (after < src.Length && char.IsWhiteSpace(src[after])) after++;
            if (after < src.Length && src[after] == '+') continue;
            yield return (line, l.Text);
        }
    }

    /// <summary>Blanks out comment lines and <c>#if</c> blocks of <see cref="TranslationCoverageTests.SkippedIf"/>.</summary>
    static string WithoutSkippedBlocks(string src)
    {
        var lines = src.Split('\n');
        var stack = new List<bool>();
        var sb = new StringBuilder(src.Length);
        foreach (var line in lines)
        {
            var s = line.Trim();
            if (s.StartsWith("#if", StringComparison.Ordinal)) stack.Add(TranslationCoverageTests.SkippedIf is { } skip && s.Contains(skip) && !s.Contains('!'));
            else if ((s.StartsWith("#else", StringComparison.Ordinal) || s.StartsWith("#elif", StringComparison.Ordinal)) && stack.Count > 0) stack[^1] = false;
            else if (s.StartsWith("#endif", StringComparison.Ordinal) && stack.Count > 0) stack.RemoveAt(stack.Count - 1);
            // Comment lines (doc comments show calls as examples).
            sb.Append(stack.Contains(true) || s.StartsWith("//", StringComparison.Ordinal) ? "" : line).Append('\n');
        }
        return sb.ToString();
    }

    /// <summary>A string literal at <paramref name="i"/> ("…", $"…", @"…", $@"…"): its key, whether it has holes, where it ends.</summary>
    static (string Text, bool Holes, int End)? Literal(string src, int i)
    {
        bool interp = false, verbatim = false;
        int j = i;
        while (j < src.Length && src[j] is '$' or '@')
        {
            interp |= src[j] == '$';
            verbatim |= src[j] == '@';
            j++;
        }
        if (j >= src.Length || src[j] != '"' || src.AsSpan(j).StartsWith("\"\"\"")) return null;
        j++;
        var sb = new StringBuilder();
        int holes = 0;
        while (j < src.Length)
        {
            char c = src[j];
            if (c == '"')
            {
                if (verbatim && j + 1 < src.Length && src[j + 1] == '"') { sb.Append('"'); j += 2; continue; }
                j++;
                break;
            }
            if (c == '\\' && !verbatim)
            {
                char n = src[j + 1];
                if (n == 'u') { sb.Append((char)Convert.ToInt32(src.Substring(j + 2, 4), 16)); j += 6; }
                else { sb.Append(n switch { 'n' => '\n', 't' => '\t', 'r' => '\r', '0' => '\0', _ => n }); j += 2; }
                continue;
            }
            if (interp && c == '{')
            {
                if (j + 1 < src.Length && src[j + 1] == '{') { sb.Append('{'); j += 2; continue; }
                int depth = 1;
                j++;
                while (j < src.Length && depth > 0)
                {
                    char d = src[j];
                    if (d == '{') depth++;
                    else if (d == '}') depth--;
                    else if (d == '"' || (d is '$' or '@' && j + 1 < src.Length && src[j + 1] is '"' or '$' or '@'))
                    {
                        if (Literal(src, j) is { } inner) { j = inner.End; continue; }
                    }
                    else if (d == '\'')
                    {
                        int k = j + 1;
                        while (k < src.Length && src[k] != '\'') k += src[k] == '\\' ? 2 : 1;
                        j = k + 1;
                        continue;
                    }
                    j++;
                }
                sb.Append('\0');
                holes++;
                continue;
            }
            if (interp && c == '}' && j + 1 < src.Length && src[j + 1] == '}') { sb.Append('}'); j += 2; continue; }
            sb.Append(c);
            j++;
        }
        string text = sb.ToString();
        if (holes > 0) text = text.Replace("%", "%%").Replace("\0", "%@");
        return (text, holes > 0, j);
    }
}
