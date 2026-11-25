using System.Runtime.CompilerServices;
using System.Text;

namespace Wortschatz.Core;

/// <summary>
/// The language of the UI texts (Mac: CoreText.swift). Every text is written in German – the source language, Swiss
/// spelling («ss») – and passes through <see cref="L(string)"/>. The app sets <see cref="Table"/> at start for English
/// (<c>AppLanguage</c>); without a table (tests, parity, German) every text stays German, word for word.
/// <para>
/// Keys are the German text with <c>%@</c> for each value, exactly as on the Mac: <c>L($"Runde {n} geschafft")</c>
/// looks up «Runde %@ geschafft» and fills in <c>n</c>. The English comes from the Mac's String Catalog
/// (<c>mac/Wortschatz/Resources/Localizable.xcstrings</c>) plus <c>Strings/en.json</c> for texts only Windows has
/// (<see cref="TextTable"/>). Write whole sentences: a sentence glued together from pieces cannot be translated.
/// </para>
/// </summary>
public static class CoreText
{
    /// <summary>The table of the app's language; null = German (the texts as written).</summary>
    public static ITextTable? Table { get; set; }

    /// <summary>The language of the texts on screen: "de" or "en".</summary>
    public static string Language => Table?.Language ?? "de";

    /// <summary>A German UI text in the app's language (no values; a «%» in it stays as it is).</summary>
    public static string L(string german) => Table?.Lookup(german, null) ?? german;

    /// <summary>
    /// A German UI text with values, in the app's language: <c>L($"Noch {n} Karten")</c>. The key is the literal text
    /// with «%@» for each value; the values themselves are not translated.
    /// </summary>
    public static string L(ref TextHandler text) => text.Resolve();

    /// <summary>A German format with «%@» placeholders, filled with <paramref name="args"/> in order (Mac: <c>L(_:_:)</c>).</summary>
    public static string L(string format, params string[] args) =>
        Fill(Table?.Lookup(format, args) ?? format, args);

    /// <summary>
    /// Fills a format: «%@» takes the next value, «%1$@», «%2$@» … a numbered one (for translations that reorder
    /// them), «%%» is a percent sign. Anything else stays as written (Mac: <c>CoreText.fill</c>).
    /// </summary>
    public static string Fill(string format, IReadOnlyList<string> args)
    {
        var sb = new StringBuilder(format.Length + 16);
        int next = 0;
        for (int i = 0; i < format.Length; i++)
        {
            char c = format[i];
            if (c != '%' || i + 1 >= format.Length)
            {
                sb.Append(c);
                continue;
            }
            char d = format[i + 1];
            if (d == '%')
            {
                sb.Append('%');
                i++;
            }
            else if (d == '@')
            {
                if (next < args.Count) sb.Append(args[next]);
                next++;
                i++;
            }
            else
            {
                int j = i + 1;
                while (j < format.Length && char.IsAsciiDigit(format[j])) j++;
                if (j > i + 1 && j + 1 < format.Length && format[j] == '$' && format[j + 1] == '@'
                    && int.TryParse(format.AsSpan(i + 1, j - i - 1), out int n) && n >= 1)
                {
                    if (n <= args.Count) sb.Append(args[n - 1]);
                    i = j + 1;
                }
                else sb.Append(c);
            }
        }
        return sb.ToString();
    }
}

/// <summary>A language's texts: German key (a format with «%@») → the translated format.</summary>
public interface ITextTable
{
    /// <summary>"en" …</summary>
    string Language { get; }

    /// <summary>
    /// The translation of <paramref name="key"/>, or null when the table has none (the German text is shown). With
    /// <paramref name="args"/>, a text with forms per number (one/other) picks the form for the first whole number.
    /// </summary>
    string? Lookup(string key, IReadOnlyList<string>? args);
}

/// <summary>
/// Builds the key of an interpolated text: the literal parts as written (a «%» doubled), «%@» for each value. Values
/// are formatted exactly as a plain <c>$"…"</c> would (current culture, with their format), so German stays unchanged.
/// </summary>
[InterpolatedStringHandler]
public ref struct TextHandler
{
    readonly StringBuilder _key;
    readonly List<string> _args;
    bool _percent;

    public TextHandler(int literalLength, int formattedCount)
    {
        _key = new StringBuilder(literalLength + formattedCount * 2);
        _args = new List<string>(formattedCount);
        _percent = false;
    }

    public void AppendLiteral(string s)
    {
        if (s.Contains('%'))
        {
            _percent = true;
            s = s.Replace("%", "%%");
        }
        _key.Append(s);
    }

    public void AppendFormatted<T>(T value) => Add(value is IFormattable f ? f.ToString(null, null) : value?.ToString());

    public void AppendFormatted<T>(T value, string? format) => Add(value is IFormattable f ? f.ToString(format, null) : value?.ToString());

    public void AppendFormatted<T>(T value, int alignment) => AppendFormatted(value, alignment, null);

    public void AppendFormatted<T>(T value, int alignment, string? format)
    {
        string s = value is IFormattable f ? f.ToString(format, null) : value?.ToString() ?? "";
        Add(alignment >= 0 ? s.PadLeft(alignment) : s.PadRight(-alignment));
    }

    public void AppendFormatted(string? value) => Add(value);

    void Add(string? value)
    {
        _key.Append("%@");
        _args.Add(value ?? "");
    }

    /// <summary>The key as the table sees it (for tests).</summary>
    public readonly string Key => _key.ToString();

    internal readonly string Resolve()
    {
        string key = _key.ToString();
        if (_args.Count == 0)
        {
            // Only literal parts (a «%» doubled): look up the text as written.
            string plain = _percent ? key.Replace("%%", "%") : key;
            return CoreText.L(plain);
        }
        return CoreText.Fill(CoreText.Table?.Lookup(key, _args) ?? key, _args);
    }
}
