using System.Text;

namespace Wortschatz.Core;

/// <summary>
/// Port of OCRPostprocess.swift (the pure part of src/import/ocr.js): clean-up of recognised text,
/// misread umlauts and the spaces between recognised Chinese words.
/// </summary>
public static class OCRPostprocess
{
    /// <summary>
    /// Restores umlauts that text recognition read as circumflexes in German text (<c>fixGermanUmlauts</c>).
    ///
    /// With a French model loaded, umlauts are often read as circumflexes ("schôn"), and German never
    /// writes â, ô or û. A cell is fixed when it is part of a German table column (unless the cell itself
    /// is clearly French), and any other cell or line only when it is clearly German on its own. Languages
    /// are judged with the doubtful letters made plain, so the misreading does not count as French
    /// evidence. French cells ("le rôle", "tôt") are never changed.
    ///
    /// Lines are table rows with tab-separated cells. Only the precomposed letters â ô û Â Ô Û are
    /// considered (a decomposed "o" + U+0302 is left alone, as in the JS regex).
    /// </summary>
    public static List<string> FixGermanUmlauts(IReadOnlyList<string> lines)
    {
        if (!lines.Any(HasCircumflex)) return lines.ToList();
        var rows = lines.Select(l => l.Split('\t')).ToList();

        // Column i collects the (plain) non-blank cells of every row with at least two cells. A column
        // that never got a cell stays null, like a hole in the sparse JS array.
        var columns = new List<List<string>?>();
        foreach (var cells in rows)
        {
            if (cells.Length < 2) continue;
            for (int i = 0; i < cells.Length; i++)
            {
                if (JSCompat.Trim(cells[i]).Length == 0) continue;
                while (columns.Count <= i) columns.Add(null);
                (columns[i] ??= []).Add(Plain(cells[i]));
            }
        }
        var germanColumn = columns.Select(column =>
        {
            if (column is null) return false;
            var detection = LangDetect.DetectColumn(column);
            return detection.Lang == DetectedLanguage.De && detection.Confidence >= 0.6;
        }).ToList();

        return rows.Select(cells => string.Join("\t", cells.Select((cell, i) =>
        {
            if (!HasCircumflex(cell)) return cell;
            bool inGermanColumn = cells.Length >= 2 && i < germanColumn.Count && germanColumn[i];
            return IsGerman(cell, inGermanColumn) ? Umlauted(cell) : cell;
        }))).ToList();
    }

    /// <summary>
    /// Chinese (and Japanese) text without the spaces between recognised words (<c>joinCjk</c>): recognition
    /// engines split Chinese text into many words, but Chinese has no spaces. Runs of plain spaces between
    /// two CJK characters (Han, kana, CJK and full-width punctuation) go.
    /// </summary>
    public static string JoinCJK(string line)
    {
        // line.replace(/([CJK]) +(?=[CJK])/gu, '$1')
        var u = JSCompat.Scalars(line).ToArray();
        if (!u.Any(IsCJK)) return line;
        var sb = new StringBuilder(line.Length);
        int i = 0;
        while (i < u.Length)
        {
            if (u[i] == ' ' && i > 0 && IsCJK(u[i - 1]))
            {
                int j = i;
                while (j < u.Length && u[j] == ' ') j++;
                if (j < u.Length && IsCJK(u[j]))
                {
                    i = j;
                    continue;
                }
            }
            sb.AppendScalar(u[i]);
            i++;
        }
        return sb.ToString();
    }

    /// <summary>
    /// The plain-text result of a recognition without usable word boxes (the fallback of
    /// <c>ocrDataToText</c>): <c>text.trim().split('\n')</c>, CJK words joined, misread umlauts restored.
    /// </summary>
    public static List<string> PlainTextLines(string text) =>
        FixGermanUmlauts(JSCompat.Trim(text).Split('\n').Select(JoinCJK).ToList());

    // MARK: - Helpers

    /// <summary>
    /// <c>[、-〿぀-ヿ㐀-䶿一-鿿豈-﫿！-｠\u{20000}-\u{2FA1F}]</c>:
    /// CJK punctuation, kana, Han characters and full-width forms.
    /// </summary>
    static bool IsCJK(int u) => u is (>= 0x3001 and <= 0x303F) or (>= 0x3040 and <= 0x30FF) or (>= 0x3400 and <= 0x4DBF)
        or (>= 0x4E00 and <= 0x9FFF) or (>= 0xF900 and <= 0xFAFF) or (>= 0xFF01 and <= 0xFF60) or (>= 0x20000 and <= 0x2FA1F);

    static bool IsGerman(string cell, bool inGermanColumn)
    {
        var detection = LangDetect.DetectLanguage(Plain(cell));
        if (inGermanColumn) return !(detection.Lang == DetectedLanguage.Fr && detection.Confidence >= 0.8);
        return detection.Lang == DetectedLanguage.De && detection.Confidence >= 0.9;
    }

    /// <summary><c>/[âôûÂÔÛ]/.test(s)</c></summary>
    static bool HasCircumflex(string s) => s.AsSpan().IndexOfAny("âôûÂÔÛ") >= 0;

    /// <summary>Circumflex → plain vowel (<c>PLAIN_OF</c>).</summary>
    static string Plain(string s) => Replacing(s, "âôûÂÔÛ", "aouAOU");

    /// <summary>Circumflex → umlaut (<c>UMLAUT_OF</c>).</summary>
    static string Umlauted(string s) => Replacing(s, "âôûÂÔÛ", "äöüÄÖÜ");

    static string Replacing(string s, string from, string to)
    {
        var chars = s.ToCharArray();
        for (int i = 0; i < chars.Length; i++)
        {
            int k = from.IndexOf(chars[i]);
            if (k >= 0) chars[i] = to[k];
        }
        return new string(chars);
    }
}
