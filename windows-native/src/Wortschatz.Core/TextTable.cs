using System.Globalization;
using System.Text.RegularExpressions;

namespace Wortschatz.Core;

/// <summary>
/// The English texts (<see cref="CoreText"/>): <c>Strings/en-mac.json</c> – the Mac's String Catalog
/// (<c>mac/Wortschatz/Resources/Localizable.xcstrings</c>) for every text both apps share, copied by
/// <c>tools/strings.py sync</c> – and <c>Strings/en.json</c> for the texts only Windows and Android have or word
/// differently («Ctrl+E» for «⌘E», «Computer» for «Mac»). <c>en.json</c> wins.
/// <para>
/// The copy is flat, with the Mac's «%lld» (a whole number in SwiftUI) and «%1$lld» as «%@»/«%1$@», so
/// <c>L($"{n} Karten")</c> finds the Mac's «%lld Karten»; it leaves out texts the public app must not contain
/// (tools/strings.py). A value with forms per number (<c>{"one": "…", "other": "…"}</c>) picks by the first whole number
/// among the values.
/// </para>
/// </summary>
public sealed partial class TextTable : ITextTable
{
    readonly Dictionary<string, Entry> _entries = new(StringComparer.Ordinal);

    /// <summary>A translation: one text, or one per number.</summary>
    public sealed record Entry(string Other, string? One = null);

    public string Language { get; }

    public TextTable(string language) => Language = language;

    /// <summary>All keys with a translation (for tests and the check of missing texts).</summary>
    public IReadOnlyCollection<string> Keys => _entries.Keys;

    public int Count => _entries.Count;

    public bool Contains(string key) => _entries.ContainsKey(key);

    public Entry? EntryFor(string key) => _entries.GetValueOrDefault(key);

    public string? Lookup(string key, IReadOnlyList<string>? args)
    {
        if (!_entries.TryGetValue(key, out var entry)) return null;
        if (entry.One is null || args is null) return entry.Other;
        foreach (var a in args)
            if (long.TryParse(a, NumberStyles.Integer, CultureInfo.InvariantCulture, out long n))
                return n == 1 ? entry.One : entry.Other;
        return entry.Other;
    }

    public void Set(string key, Entry entry) => _entries[key] = entry;

    // MARK: Reading

    /// <summary>«%lld», «%d», «%1$lld» … → «%@», «%1$@» (the Mac's number placeholders; Windows fills strings only).</summary>
    public static string NormalizePlaceholders(string format) => NumberPlaceholder().Replace(format, "%$1@");

    [GeneratedRegex(@"%(\d+\$)?(?:lld|ld|d|lu|u|lf|f)")]
    private static partial Regex NumberPlaceholder();

    /// <summary>
    /// Adds the translations of a String Catalog (<c>.xcstrings</c>) for <paramref name="language"/>, without texts
    /// that contain <paramref name="leaveOut"/> (what <c>tools/strings.py sync</c> writes to en-mac.json).
    /// </summary>
    public void AddCatalog(JSONValue catalog, string language, string? leaveOut = null)
    {
        if (catalog["strings"]?.ObjectValue is not { } strings) return;
        bool Private(string? s) => leaveOut is not null && s is not null && s.Contains(leaveOut, StringComparison.Ordinal);
        foreach (var (key, value) in strings)
        {
            var loc = value["localizations"]?[language];
            if (loc is null || Private(key)) continue;
            string norm = NormalizePlaceholders(key);
            if (loc["stringUnit"]?["value"]?.StringValue is { } text)
            {
                if (!Private(text)) _entries[norm] = new Entry(NormalizePlaceholders(text));
            }
            else if (loc["variations"]?["plural"] is { } plural)
            {
                string? other = plural["other"]?["stringUnit"]?["value"]?.StringValue;
                string? one = plural["one"]?["stringUnit"]?["value"]?.StringValue;
                if (other is null) continue;
                _entries[norm] = new Entry(NormalizePlaceholders(other), one is null ? null : NormalizePlaceholders(one));
            }
        }
    }

    /// <summary>Adds a flat table: <c>{"Deutsch": "English", "%@ Karte": {"one": "%@ card", "other": "%@ cards"}}</c>.</summary>
    public void AddFlat(JSONValue table)
    {
        if (table.ObjectValue is not { } map) return;
        foreach (var (key, value) in map)
        {
            if (key.StartsWith("//", StringComparison.Ordinal)) continue; // comments
            if (value.StringValue is { } text) _entries[key] = new Entry(text);
            else if (value["other"]?.StringValue is { } other) _entries[key] = new Entry(other, value["one"]?.StringValue);
        }
    }

    /// <summary>The built-in English table (the Mac's texts, then en.json on top); read once.</summary>
    public static TextTable English => _english.Value;

    static readonly Lazy<TextTable> _english = new(() =>
    {
        var table = new TextTable("en");
        if (Resource("Wortschatz.Core.Strings.en-mac.json") is { } mac) table.AddFlat(mac);
        if (Resource("Wortschatz.Core.Strings.en.json") is { } own) table.AddFlat(own);
        return table;
    });

    /// <summary>Only the Mac's texts (en-mac.json), for the test that it matches the catalog.</summary>
    public static TextTable MacCopy()
    {
        var table = new TextTable("en");
        if (Resource("Wortschatz.Core.Strings.en-mac.json") is { } mac) table.AddFlat(mac);
        return table;
    }

    static JSONValue? Resource(string name)
    {
        using var stream = typeof(TextTable).Assembly.GetManifestResourceStream(name);
        if (stream is null) return null;
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return JSONValue.Parse(buffer.ToArray());
    }
}
