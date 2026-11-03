using System.Globalization;
using System.Text;

namespace Wortschatz.Core;

/// <summary>
/// Port of JSCompat.swift: helpers that reproduce JavaScript semantics exactly. C# strings are
/// UTF-16 like JS strings, so length/indices already match; whitespace, rounding and number
/// formatting still differ from .NET defaults.
/// </summary>
public static class JSCompat
{
    // MARK: Whitespace (`\s` and `String.prototype.trim` in JS)

    /// <summary>Whether code point <paramref name="u"/> matches JS <c>\s</c>.</summary>
    public static bool IsWhitespace(int u) => u switch
    {
        >= 0x09 and <= 0x0D => true,
        0x20 or 0xA0 or 0x1680 => true,
        >= 0x2000 and <= 0x200A => true,
        0x2028 or 0x2029 or 0x202F or 0x205F or 0x3000 or 0xFEFF => true,
        _ => false,
    };

    public static bool IsWhitespace(char c) => IsWhitespace((int)c);

    /// <summary>JS <c>s.trim()</c>.</summary>
    public static string Trim(string? s)
    {
        if (string.IsNullOrEmpty(s)) return "";
        int start = 0, end = s.Length - 1;
        while (start <= end && IsWhitespace(s[start])) start++;
        while (end >= start && IsWhitespace(s[end])) end--;
        return start > end ? "" : s.Substring(start, end - start + 1);
    }

    /// <summary>JS <c>s.trimStart()</c>.</summary>
    public static string TrimStart(string s)
    {
        int start = 0;
        while (start < s.Length && IsWhitespace(s[start])) start++;
        return s[start..];
    }

    /// <summary>JS <c>s.trimEnd()</c>.</summary>
    public static string TrimEnd(string s)
    {
        int end = s.Length - 1;
        while (end >= 0 && IsWhitespace(s[end])) end--;
        return s[..(end + 1)];
    }

    // MARK: Numbers

    /// <summary>JS <c>Math.round</c> (half rounds toward +∞).</summary>
    public static double Round(double x)
    {
        if (!double.IsFinite(x)) return x;
        var f = Math.Floor(x);
        return x - f >= 0.5 ? f + 1 : f;
    }

    /// <summary>JS <c>Number.isInteger(x)</c>.</summary>
    public static bool IsInteger(double x) => double.IsFinite(x) && x == Math.Truncate(x);

    /// <summary>JS <c>String(x)</c> of a number.</summary>
    public static string NumberToString(double x)
    {
        if (double.IsNaN(x)) return "NaN";
        if (double.IsPositiveInfinity(x)) return "Infinity";
        if (double.IsNegativeInfinity(x)) return "-Infinity";
        if (x == 0) return "0";
        bool negative = x < 0;
        // "R" gives the shortest round-trip digits like JS; normalise to JS notation.
        var desc = Math.Abs(x).ToString("R", CultureInfo.InvariantCulture);
        var mantissa = desc;
        int exponent = 0;
        int e = desc.IndexOfAny(['e', 'E']);
        if (e >= 0)
        {
            mantissa = desc[..e];
            exponent = int.Parse(desc[(e + 1)..], CultureInfo.InvariantCulture);
        }
        var parts = mantissa.Split('.');
        var intPart = parts[0];
        var fracPart = parts.Length > 1 ? parts[1] : "";
        var digits = new StringBuilder(intPart + fracPart);
        int n = intPart.Length + exponent;
        while (digits.Length > 1 && digits[0] == '0') { digits.Remove(0, 1); n--; }
        while (digits.Length > 1 && digits[^1] == '0') digits.Remove(digits.Length - 1, 1);
        int k = digits.Length;
        var ds = digits.ToString();
        string output;
        if (k <= n && n <= 21) output = ds + new string('0', n - k);
        else if (0 < n && n <= 21) output = ds[..n] + "." + ds[n..];
        else if (-6 < n && n <= 0) output = "0." + new string('0', -n) + ds;
        else
        {
            int ex = n - 1;
            var sign = ex < 0 ? "-" : "+";
            output = k == 1 ? ds : ds[0] + "." + ds[1..];
            output += "e" + sign + Math.Abs(ex).ToString(CultureInfo.InvariantCulture);
        }
        return negative ? "-" + output : output;
    }

    // MARK: Dates

    /// <summary>JS <c>TimeClip</c>: the time value of <c>new Date(ms)</c>, or null when invalid.</summary>
    public static double? TimeClip(double ms)
    {
        if (!double.IsFinite(ms) || Math.Abs(ms) > 8.64e15) return null;
        return Math.Truncate(ms) + 0.0;
    }

    // MARK: Strings

    /// <summary>JS <c>s.length</c> (UTF-16 code units).</summary>
    public static int Length(string s) => s.Length;

    /// <summary>JS <c>Array.from(s)</c>: code points as strings.</summary>
    public static List<string> CodePoints(string s)
    {
        var list = new List<string>(s.Length);
        for (int i = 0; i < s.Length; i++)
        {
            if (char.IsHighSurrogate(s[i]) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]))
            {
                list.Add(s.Substring(i, 2));
                i++;
            }
            else list.Add(s[i].ToString());
        }
        return list;
    }

    /// <summary>The code points of <paramref name="s"/> as ints (lone surrogates kept).</summary>
    public static IEnumerable<int> Scalars(string s)
    {
        for (int i = 0; i < s.Length; i++)
        {
            if (char.IsHighSurrogate(s[i]) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]))
            {
                yield return char.ConvertToUtf32(s[i], s[i + 1]);
                i++;
            }
            else yield return s[i];
        }
    }

    /// <summary>JS <c>s.codePointAt(i)</c>: the code point starting at UTF-16 index <paramref name="i"/> (a lone surrogate as itself).</summary>
    public static int CodePointAt(string s, int i) =>
        char.IsHighSurrogate(s[i]) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]) ? char.ConvertToUtf32(s[i], s[i + 1]) : s[i];

    /// <summary>Appends code point <paramref name="u"/> to <paramref name="sb"/>.</summary>
    public static StringBuilder AppendScalar(this StringBuilder sb, int u)
    {
        if (u < 0x10000) sb.Append((char)u);
        else sb.Append(char.ConvertFromUtf32(u));
        return sb;
    }

    /// <summary><c>s.normalize('NFC')</c>.</summary>
    public static string Nfc(string s) => Normalize(s, NormalizationForm.FormC);

    /// <summary><c>s.normalize('NFD')</c>.</summary>
    public static string Nfd(string s) => Normalize(s, NormalizationForm.FormD);

    /// <summary><c>s.normalize('NFKC')</c>.</summary>
    public static string Nfkc(string s) => Normalize(s, NormalizationForm.FormKC);

    static string Normalize(string s, NormalizationForm form)
    {
        try { return s.Normalize(form); }
        catch (ArgumentException) { return s; } // lone surrogates: JS leaves them alone
    }

    /// <summary>Exact string equality like JS <c>===</c>.</summary>
    public static bool Identical(string? a, string? b) => string.Equals(a, b, StringComparison.Ordinal);

    /// <summary>The Unicode general category of a code point.</summary>
    public static UnicodeCategory Category(int u) =>
        u is >= 0xD800 and <= 0xDFFF ? UnicodeCategory.Surrogate : CharUnicodeInfo.GetUnicodeCategory(u);

    /// <summary>
    /// JS <c>toLowerCase()</c>: Unicode default full case mapping. .NET's invariant mapping is the simple
    /// one; the differences JS makes are İ → "i̇" (i + U+0307) and the final sigma (Σ → ς at the end of a word).
    /// </summary>
    public static string Lower(string s)
    {
        if (s.AsSpan().IndexOfAny('\u0130', '\u03A3') < 0) return s.ToLowerInvariant();
        var sb = new StringBuilder(s.Length + 2);
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (c == '\u0130') sb.Append("i\u0307");
            else if (c == '\u03A3') sb.Append(IsFinalSigma(s, i) ? '\u03C2' : '\u03C3');
            else sb.Append(char.ToLowerInvariant(c));
        }
        return sb.ToString();
    }

    /// <summary>Unicode Final_Sigma: a cased letter before (skipping case-ignorables), none after.</summary>
    static bool IsFinalSigma(string s, int i)
    {
        static bool Ignorable(char c) => Category(c) is UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark
            or UnicodeCategory.Format or UnicodeCategory.ModifierLetter or UnicodeCategory.ModifierSymbol || c is '\'' or '.' or ':' or '\u00B7' or '\u2019';
        static bool Cased(char c) => char.IsUpper(c) || char.IsLower(c) || Category(c) == UnicodeCategory.TitlecaseLetter;
        int j = i - 1;
        while (j >= 0 && Ignorable(s[j])) j--;
        if (j < 0 || !Cased(s[j])) return false;
        int k = i + 1;
        while (k < s.Length && Ignorable(s[k])) k++;
        return k >= s.Length || !Cased(s[k]);
    }

    /// <summary>JS <c>toUpperCase()</c>: full mapping for ß and the Latin ligatures.</summary>
    public static string Upper(string s)
    {
        var up = s.ToUpperInvariant();
        if (up.AsSpan().IndexOfAny("ßﬀﬁﬂﬃﬄﬅﬆŉ") < 0) return up;
        return up.Replace("ß", "SS").Replace("ﬀ", "FF").Replace("ﬁ", "FI").Replace("ﬂ", "FL").Replace("ﬃ", "FFI")
            .Replace("ﬄ", "FFL").Replace("ﬅ", "ST").Replace("ﬆ", "ST").Replace("ŉ", "\u02BCN");
    }

    /// <summary>A double from an int, for JS-style arithmetic.</summary>
    public static int Clamp(int v, int lo, int hi) => Math.Max(lo, Math.Min(hi, v));
}
