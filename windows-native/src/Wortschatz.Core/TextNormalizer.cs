using System.Globalization;
using System.Text;

namespace Wortschatz.Core;

/// <summary>
/// Port of TextNormalizer.swift (src/core/text.js): shared text normalisation used by the parser
/// and the grader. Works on code points so results match JS exactly.
/// </summary>
public static class TextNormalizer
{
    /// <summary><c>[’‘`´ʼ′ʹ]</c> → "'"</summary>
    internal static bool IsApostrophe(int v) => v is 0x2019 or 0x2018 or 0x60 or 0xB4 or 0x2BC or 0x2032 or 0x2B9;

    /// <summary><c>[–—‒‐‑−]</c> → "-"</summary>
    internal static bool IsDash(int v) => v is 0x2013 or 0x2014 or 0x2012 or 0x2010 or 0x2011 or 0x2212;

    /// <summary>Odd spaces → " "</summary>
    internal static bool IsOddSpace(int v) => v is 0xA0 or 0x2007 or 0x2009 or 0x200A or 0x202F or 0x205F or 0x3000;

    /// <summary>Zero-width characters (removed).</summary>
    internal static bool IsZeroWidth(int v) => v is 0x200B or 0x200C or 0x200D or 0x2060 or 0xFEFF;

    /// <summary>Bidi controls copied along with Arabic text (removed).</summary>
    internal static bool IsBidiControl(int v) => v is 0x200E or 0x200F or 0x61C or (>= 0x202A and <= 0x202E) or (>= 0x2066 and <= 0x2069);

    /// <summary>
    /// NFC, unify apostrophes/dashes/odd spaces, drop zero-width and bidi controls, collapse
    /// whitespace and trim. With <paramref name="keepTabs"/> only <c>[ \f\v\r\n]</c> runs collapse and
    /// spaces around tabs go. null gives "".
    /// </summary>
    public static string NormalizeBasic(string? s, bool keepTabs = false)
    {
        if (s is null) return "";
        var unified = new StringBuilder(s.Length);
        foreach (var v in JSCompat.Scalars(JSCompat.Nfc(s)))
        {
            if (IsZeroWidth(v) || IsBidiControl(v)) continue;
            if (IsApostrophe(v)) unified.Append('\'');
            else if (IsDash(v)) unified.Append('-');
            else if (IsOddSpace(v)) unified.Append(' ');
            else unified.AppendScalar(v);
        }

        var output = new StringBuilder(unified.Length);
        if (keepTabs)
        {
            var collapsed = new StringBuilder(unified.Length);
            bool inRun = false;
            for (int i = 0; i < unified.Length; i++)
            {
                char c = unified[i];
                if (c is ' ' or '\f' or '\v' or '\r' or '\n')
                {
                    if (!inRun) collapsed.Append(' ');
                    inRun = true;
                }
                else
                {
                    collapsed.Append(c);
                    inRun = false;
                }
            }
            bool skipSpaces = false;
            for (int i = 0; i < collapsed.Length; i++)
            {
                char c = collapsed[i];
                if (c == '\t')
                {
                    while (output.Length > 0 && output[^1] == ' ') output.Length--;
                    output.Append(c);
                    skipSpaces = true;
                }
                else if (c == ' ' && skipSpaces) continue;
                else
                {
                    output.Append(c);
                    skipSpaces = false;
                }
            }
        }
        else
        {
            bool inRun = false;
            for (int i = 0; i < unified.Length; i++)
            {
                char c = unified[i];
                if (JSCompat.IsWhitespace(c))
                {
                    if (!inRun) output.Append(' ');
                    inRun = true;
                }
                else
                {
                    output.Append(c);
                    inRun = false;
                }
            }
        }
        return JSCompat.Trim(output.ToString());
    }

    /// <summary>Remove diacritics: é→e, ç→c, ä→a; ß→ss, œ→oe, æ→ae, ø→o.</summary>
    public static string StripDiacritics(string s)
    {
        var expanded = new StringBuilder(s.Length + 4);
        foreach (char c in s)
        {
            switch ((int)c)
            {
                case 0xDF: expanded.Append("ss"); break;
                case 0x1E9E: expanded.Append("SS"); break;
                case 0x153: expanded.Append("oe"); break;
                case 0x152: expanded.Append("OE"); break;
                case 0xE6: expanded.Append("ae"); break;
                case 0xC6: expanded.Append("AE"); break;
                case 0xF8: expanded.Append('o'); break;
                case 0xD8: expanded.Append('O'); break;
                default: expanded.Append(c); break;
            }
        }
        var stripped = new StringBuilder(expanded.Length);
        foreach (var u in JSCompat.Scalars(JSCompat.Nfd(expanded.ToString())))
            if (!IsMark(u)) stripped.AppendScalar(u);
        return JSCompat.Nfc(stripped.ToString());
    }

    /// <summary>German transliteration: ä→ae, ö→oe, ü→ue (precomposed only), then strip diacritics.</summary>
    public static string FoldUmlauts(string s)
    {
        var sb = new StringBuilder(s.Length + 4);
        foreach (char c in s)
        {
            switch ((int)c)
            {
                case 0xE4: sb.Append("ae"); break;
                case 0xF6: sb.Append("oe"); break;
                case 0xFC: sb.Append("ue"); break;
                case 0xC4: sb.Append("Ae"); break;
                case 0xD6: sb.Append("Oe"); break;
                case 0xDC: sb.Append("Ue"); break;
                default: sb.Append(c); break;
            }
        }
        return StripDiacritics(sb.ToString());
    }

    /// <summary><c>/\p{L}/u.test(ch)</c>.</summary>
    public static bool IsLetter(string ch)
    {
        foreach (var u in JSCompat.Scalars(ch)) if (IsLetterScalar(u)) return true;
        return false;
    }

    // MARK: Arabic and Chinese script folds

    public static bool IsArabicScalar(int u) =>
        u is (>= 0x600 and <= 0x6FF) or (>= 0x750 and <= 0x77F) or (>= 0x8A0 and <= 0x8FF) or (>= 0xFB50 and <= 0xFDFF) or (>= 0xFE70 and <= 0xFEFE);

    public static bool IsHanScalar(int u) =>
        u is (>= 0x3400 and <= 0x4DBF) or (>= 0x4E00 and <= 0x9FFF) or (>= 0xF900 and <= 0xFAFF) or (>= 0x20000 and <= 0x2FA1F);

    internal static bool IsArabicMark(int v) =>
        v is (>= 0x610 and <= 0x61A) or (>= 0x64B and <= 0x652) or (>= 0x656 and <= 0x65F) or 0x670
            or (>= 0x6D6 and <= 0x6DC) or (>= 0x6DF and <= 0x6E8) or (>= 0x6EA and <= 0x6ED) or 0x640;

    public static bool HasArabic(string s) => JSCompat.Scalars(s).Any(IsArabicScalar);
    public static bool HasHan(string s) => JSCompat.Scalars(s).Any(IsHanScalar);

    /// <summary>Arabic vowel marks, Quranic marks and tatweel removed (then NFC).</summary>
    public static string StripArabicMarks(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var u in JSCompat.Scalars(s)) if (!IsArabicMark(u)) sb.AppendScalar(u);
        return JSCompat.Nfc(sb.ToString());
    }

    /// <summary>
    /// What Arabic and Chinese text treats as the same, folded away: presentation forms → letters,
    /// marks and tatweel removed, ، ؛ ؟ and full-width/CJK punctuation → ASCII, no spaces between
    /// two Han characters. Latin text only gets NFC.
    /// </summary>
    public static string FoldScripts(string s)
    {
        var nfc = JSCompat.Nfc(s);
        if (!JSCompat.Scalars(nfc).Any(u => u >= 0x600)) return nfc;
        var plain = new StringBuilder(nfc.Length);
        foreach (var u in JSCompat.Scalars(nfc))
        {
            if (u is (>= 0xFB50 and <= 0xFDFF) or (>= 0xFE70 and <= 0xFEFE))
            {
                foreach (var k in JSCompat.Scalars(JSCompat.Nfkc(char.ConvertFromUtf32(u))))
                    if (!IsArabicMark(k)) plain.AppendScalar(k);
            }
            else if (IsArabicMark(u)) continue;
            else plain.AppendScalar(u);
        }
        var folded = new List<int>(plain.Length);
        foreach (var u in JSCompat.Scalars(JSCompat.Nfc(plain.ToString())))
        {
            folded.Add(u switch
            {
                0x60C or 0x3001 => ',',
                0x61B => ';',
                0x61F => '?',
                0x3002 => '.',
                0x3010 => '[',
                0x3011 => ']',
                >= 0xFF01 and <= 0xFF5E => u - 0xFEE0,
                _ => u,
            });
        }
        var output = new StringBuilder(folded.Count);
        int i = 0;
        while (i < folded.Count)
        {
            if (folded[i] != ' ')
            {
                output.AppendScalar(folded[i]);
                i++;
                continue;
            }
            int j = i;
            while (j < folded.Count && folded[j] == ' ') j++;
            bool betweenHan = i > 0 && IsHanScalar(folded[i - 1]) && j < folded.Count && IsHanScalar(folded[j]);
            if (!betweenHan) for (int k = i; k < j; k++) output.Append(' ');
            i = j;
        }
        return output.ToString();
    }

    // MARK: Unicode property helpers

    /// <summary><c>\p{L}</c></summary>
    public static bool IsLetterScalar(int u) => JSCompat.Category(u) is UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter
        or UnicodeCategory.TitlecaseLetter or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter;

    /// <summary><c>\p{M}</c></summary>
    public static bool IsMark(int u) => JSCompat.Category(u) is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark;

    /// <summary><c>\p{N}</c></summary>
    public static bool IsNumberScalar(int u) => JSCompat.Category(u) is UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber;

    /// <summary><c>\p{Lu}</c></summary>
    public static bool IsUppercaseLetter(int u) => JSCompat.Category(u) == UnicodeCategory.UppercaseLetter;

    /// <summary><c>\p{Ll}</c></summary>
    public static bool IsLowercaseLetter(int u) => JSCompat.Category(u) == UnicodeCategory.LowercaseLetter;
}
