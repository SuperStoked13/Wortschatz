using System.Text;

namespace Wortschatz.Core;

/// <summary>
/// Port of TextFileDecoder.swift: bytes → string for imported text files (<c>decodeText</c> in
/// src/import/files.js).
///
/// Byte order marks are honoured (UTF-8, UTF-16 LE/BE), UTF-16 without a BOM is recognised by its zero
/// byte lane, UTF-8 is tried strictly, and legacy files fall back to Windows-1252 (old Excel/Windows
/// exports) or, when that reads clearly worse, Mac OS Roman (old Mac exports).
/// </summary>
public static class TextFileDecoder
{
    /// <summary>The encoding a text file was read with.</summary>
    public enum Encoding { Utf8, Utf16LittleEndian, Utf16BigEndian, Windows1252, MacRoman }

    /// <summary>Decodes <paramref name="data"/> like the web app's <c>decodeText</c> (plus the Mac OS Roman fallback).</summary>
    public static string Decode(byte[] data) => DecodeDetectingEncoding(data).Text;

    /// <summary>Decodes <paramref name="bytes"/> and reports the encoding that was used.</summary>
    public static (string Text, Encoding Encoding) DecodeDetectingEncoding(byte[] bytes)
    {
        if (StartsWith(bytes, 0xEF, 0xBB, 0xBF))
            return (StripLeadingBOM(new UTF8Encoding(false, false).GetString(bytes, 3, bytes.Length - 3)), Encoding.Utf8);
        if (StartsWith(bytes, 0xFF, 0xFE)) return (StripLeadingBOM(DecodeUTF16(bytes, 2, true)), Encoding.Utf16LittleEndian);
        if (StartsWith(bytes, 0xFE, 0xFF)) return (StripLeadingBOM(DecodeUTF16(bytes, 2, false)), Encoding.Utf16BigEndian);
        if (Utf16Lane(bytes) is { } littleEndian)
            return (StripLeadingBOM(DecodeUTF16(bytes, 0, littleEndian)), littleEndian ? Encoding.Utf16LittleEndian : Encoding.Utf16BigEndian);
        if (StrictUTF8(bytes) is { } text) return (text, Encoding.Utf8);
        var windows = DecodeSingleByte(bytes, Windows1252High);
        var mac = DecodeSingleByte(bytes, MacRomanHigh);
        return Plausibility(mac, bytes) > Plausibility(windows, bytes) ? (mac, Encoding.MacRoman) : (windows, Encoding.Windows1252);
    }

    /// <summary>
    /// Binary data decoded as text shows up as many control characters (JS <c>looksBinary</c>): more than
    /// 2 % of the first 4096 UTF-16 units are C0 controls other than tab/line breaks, or DEL.
    /// </summary>
    public static bool LooksBinary(string text)
    {
        int n = Math.Min(4096, text.Length);
        if (n == 0) return false;
        int controls = 0;
        for (int i = 0; i < n; i++)
        {
            char u = text[i];
            if (u <= 0x08 || (u >= 0x0E && u <= 0x1F) || u == 0x7F) controls++;
        }
        return controls > 0 && controls > n * 0.02;
    }

    // MARK: - UTF-8 / UTF-16

    static bool StartsWith(byte[] bytes, params byte[] prefix) => bytes.AsSpan().StartsWith(prefix);

    /// <summary>The <c>TextDecoder</c> default (<c>ignoreBOM: false</c>) drops one more leading BOM.</summary>
    static string StripLeadingBOM(string s) => s.Length > 0 && s[0] == '\uFEFF' ? s[1..] : s;

    /// <summary>Strict (fatal) UTF-8: null when any sequence is invalid.</summary>
    static string? StrictUTF8(byte[] bytes)
    {
        try { return new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException) { return null; }
    }

    /// <summary>
    /// Lossy UTF-16 like <c>TextDecoder('utf-16le' | 'utf-16be')</c>: unpaired surrogates and a dangling odd
    /// byte become U+FFFD.
    /// </summary>
    static string DecodeUTF16(byte[] bytes, int offset, bool littleEndian)
    {
        int count = bytes.Length - offset;
        var units = new char[count / 2];
        for (int k = 0; k < units.Length; k++)
        {
            int a = bytes[offset + 2 * k], b = bytes[offset + 2 * k + 1];
            units[k] = (char)(littleEndian ? (b << 8 | a) : (a << 8 | b));
        }
        for (int k = 0; k < units.Length; k++)
        {
            if (char.IsHighSurrogate(units[k]))
            {
                if (k + 1 < units.Length && char.IsLowSurrogate(units[k + 1])) k++;
                else units[k] = '�';
            }
            else if (char.IsLowSurrogate(units[k])) units[k] = '�';
        }
        var text = new string(units);
        return count % 2 == 1 ? text + "�" : text;
    }

    /// <summary>UTF-16 without BOM: one of the two byte lanes is mostly zero (Latin text). true = little endian.</summary>
    static bool? Utf16Lane(byte[] bytes)
    {
        int n = Math.Min(bytes.Length, 1024) & ~1;
        if (n < 4) return null;
        int evenZero = 0, oddZero = 0;
        for (int i = 0; i < n; i += 2)
        {
            if (bytes[i] == 0) evenZero++;
            if (bytes[i + 1] == 0) oddZero++;
        }
        double pairs = n / 2;
        if (oddZero > pairs * 0.4 && evenZero < pairs * 0.05) return true;
        if (evenZero > pairs * 0.4 && oddZero < pairs * 0.05) return false;
        return null;
    }

    // MARK: - Single-byte encodings

    static string DecodeSingleByte(byte[] bytes, char[] table)
    {
        var chars = new char[bytes.Length];
        for (int i = 0; i < bytes.Length; i++) chars[i] = bytes[i] < 0x80 ? (char)bytes[i] : table[bytes[i] - 0x80];
        return new string(chars);
    }

    /// <summary>
    /// How natural the high bytes read in <paramref name="text"/>: letters and punctuation common in French,
    /// German, Spanish and Italian count +1, C1 controls and symbols that never occur in a vocabulary list
    /// count -2. Windows-1252 wins ties (the web app only knows Windows-1252).
    /// </summary>
    static int Plausibility(string text, byte[] bytes)
    {
        int score = 0;
        for (int i = 0; i < bytes.Length; i++)
        {
            if (bytes[i] < 0x80) continue;
            char c = text[i];
            if (PlausibleChars.Contains(c)) score++;
            else if ((c >= 0x80 && c <= 0x9F) || ImplausibleChars.Contains(c)) score -= 2;
        }
        return score;
    }

    static readonly HashSet<char> PlausibleChars = [.. "àâäáãåæçéèêëíìîïñóòôöõúùûüœÀÂÄÁÃÅÆÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜŒ«»¿¡€–—‘’“”…°·\u00A0"];

    static readonly HashSet<char> ImplausibleChars = [.. "ƒ†‡ˆ‰Š‹šŽž˜™›Ÿ¦¨¯´¸¹²³¼½¾×÷√∆∑∏π∫Ω≈≠≤≥◊ºª¬±µ∂¥¤¶§©®"];

    /// <summary>Windows-1252 bytes 0x80…0xFF (WHATWG mapping: the 5 unassigned bytes map to C1 controls).</summary>
    static readonly char[] Windows1252High =
    [
        '€', '\u0081', '‚', 'ƒ', '„', '…', '†', '‡', 'ˆ', '‰', 'Š', '‹', 'Œ', '\u008D', 'Ž', '\u008F',
        '\u0090', '‘', '’', '“', '”', '•', '–', '—', '˜', '™', 'š', '›', 'œ', '\u009D', 'ž', 'Ÿ',
        .. Enumerable.Range(0xA0, 0x60).Select(i => (char)i),
    ];

    /// <summary>Mac OS Roman bytes 0x80…0xFF (0xDB is the euro sign, as on Mac OS 8.5 and later).</summary>
    static readonly char[] MacRomanHigh =
    [
        'Ä', 'Å', 'Ç', 'É', 'Ñ', 'Ö', 'Ü', 'á', 'à', 'â', 'ä', 'ã', 'å', 'ç', 'é', 'è',
        'ê', 'ë', 'í', 'ì', 'î', 'ï', 'ñ', 'ó', 'ò', 'ô', 'ö', 'õ', 'ú', 'ù', 'û', 'ü',
        '†', '°', '¢', '£', '§', '•', '¶', 'ß', '®', '©', '™', '´', '¨', '≠', 'Æ', 'Ø',
        '∞', '±', '≤', '≥', '¥', 'µ', '∂', '∑', '∏', 'π', '∫', 'ª', 'º', 'Ω', 'æ', 'ø',
        '¿', '¡', '¬', '√', 'ƒ', '≈', '∆', '«', '»', '…', '\u00A0', 'À', 'Ã', 'Õ', 'Œ', 'œ',
        '–', '—', '“', '”', '‘', '’', '÷', '◊', 'ÿ', 'Ÿ', '⁄', '€', '‹', '›', 'ﬁ', 'ﬂ',
        '‡', '·', '‚', '„', '‰', 'Â', 'Ê', 'Á', 'Ë', 'È', 'Í', 'Î', 'Ï', 'Ì', 'Ó', 'Ô',
        '', 'Ò', 'Ú', 'Û', 'Ù', 'ı', 'ˆ', '˜', '¯', '˘', '˙', '˚', '¸', '˝', '˛', 'ˇ',
    ];
}
