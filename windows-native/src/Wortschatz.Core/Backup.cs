using System.Globalization;
using System.Text;

namespace Wortschatz.Core;

public sealed class BackupFileError(string message) : Exception(message);

/// <summary>
/// Port of Backup.swift (src/store/backup.js): backup files (read like the browser's JSON.parse,
/// written like JSON.stringify(…, null, 2)), the text export of a set and the file names.
/// </summary>
public static class Backup
{
    public const string READ_ERROR = "Die Datei konnte nicht gelesen werden.";
    public const string PARSE_ERROR = "Die Datei ist keine gültige Backup-Datei (JSON).";

    // MARK: Text export

    public static string SetToText(VocabSet set, string termSep = "\t", string cardSep = "\n") => SetToText(set.Cards, termSep, cardSep);

    /// <summary>"term&lt;termSep&gt;definition" per card, joined with cardSep (fields quoted when they contain a separator).</summary>
    public static string SetToText(IEnumerable<Card> cards, string termSep = "\t", string cardSep = "\n") =>
        string.Join(cardSep, cards
            .Where(c => JSCompat.Trim(c.Term).Length > 0 || JSCompat.Trim(c.Definition).Length > 0)
            .Select(c => ExportField(c.Term, termSep, cardSep) + termSep + ExportField(c.Definition, termSep, cardSep)));

    static string ExportField(string value, string termSep, string cardSep)
    {
        var s = CollapseRuns(value, c => c is '\r' or '\n' or '\t', 1);
        if (JSCompat.Trim(cardSep) == ";") s = ReplaceSemicolons(s);
        s = CollapseRuns(s, c => c == ' ', 2);
        var text = JSCompat.Trim(s);
        bool clashes = new[] { termSep, cardSep }.Any(sep => sep.Length > 0 && JSCompat.Trim(sep).Length > 0 && text.Contains(sep, StringComparison.Ordinal));
        if (clashes) text = "\"" + text.Replace("\"", "\"\"") + "\"";
        return text;
    }

    static string CollapseRuns(string s, Func<char, bool> matches, int minimum)
    {
        var sb = new StringBuilder(s.Length);
        int i = 0;
        while (i < s.Length)
        {
            if (!matches(s[i])) { sb.Append(s[i]); i++; continue; }
            int j = i;
            while (j < s.Length && matches(s[j])) j++;
            if (j - i >= minimum) sb.Append(' ');
            else sb.Append(s, i, j - i);
            i = j;
        }
        return sb.ToString();
    }

    /// <summary><c>/\s*;\s*/g</c> → ", "</summary>
    static string ReplaceSemicolons(string s) => JsRegex.ReplaceAll(s, @"\s*;\s*", ", ");

    // MARK: Backup files

    /// <summary>Reads a backup file like the web app (UTF-8, up to two BOMs dropped, strict JSON, an object).</summary>
    public static JSONValue ReadJSON(byte[] data)
    {
        var text = new UTF8Encoding(false, false).GetString(data);
        for (int k = 0; k < 2 && text.Length > 0 && text[0] == '﻿'; k++) text = text[1..];
        var parser = new BackupJSONParser(text);
        var json = parser.ParseDocument();
        if (json is null || !json.IsObject) throw new BackupFileError(PARSE_ERROR);
        return json;
    }

    public static byte[] JsonData(BackupDocument backup) => Encoding.UTF8.GetBytes(JsonText(backup.ToJson()));

    /// <summary><c>JSON.stringify(value, null, 2)</c>.</summary>
    public static string JsonText(JSONValue value)
    {
        var sb = new StringBuilder();
        Write(value, "", sb);
        return sb.ToString();
    }

    public static string BackupFileName(double? now = null, TimeZoneInfo? timeZone = null) =>
        $"wortschatz-backup-{TimeUtil.DateKey(now ?? TimeUtil.NowMs(), timeZone)}.json";

    /// <summary>A safe file name for a set's text export: «Unité 3.txt».</summary>
    public static string TextFileName(string title)
    {
        var s = CollapseRuns(JSCompat.Nfc(title), c => c < 0x20 || "\\/:*?\"<>|".Contains(c), 1);
        s = CollapseRuns(s, JSCompat.IsWhitespace, 1);
        var trimmed = JSCompat.Trim(s);
        var b = new StringBuilder();
        int units = 0;
        foreach (var u in JSCompat.Scalars(trimmed))
        {
            int width = u > 0xFFFF ? 2 : 1;
            if (units + width > 80) break;
            units += width;
            b.AppendScalar(u);
        }
        return (b.Length == 0 ? "Lernset" : b.ToString()) + ".txt";
    }

    // MARK: JSON writer (JSON.stringify with 2 spaces)

    static readonly Dictionary<string, int> KeyRank = new[]
    {
        "app", "version", "exportedAt", "sets", "progress", "settings", "activity",
        "id", "title", "description", "termLang", "defLang", "cards", "term", "definition", "starred",
        "studyOptions", "theme", "study", "answerWith", "shuffle", "copyAnswer", "autoAdvance", "audio",
        "tolerance", "articles", "abbreviations", "multipleAnswers", "parentheses", "ignoreCase", "ignoreAccents",
        "typos", "learn", "roundSize", "mc", "written", "retype", "createdAt", "updatedAt", "lastStudiedAt",
        "correct", "incorrect", "streak", "streakBefore", "lastResult", "lastAnsweredAt",
    }.Select((k, i) => (k, i)).ToDictionary(x => x.k, x => x.i, StringComparer.Ordinal);

    static void Write(JSONValue value, string indent, StringBuilder sb)
    {
        switch (value.Kind)
        {
            case JSONKind.Null: sb.Append("null"); break;
            case JSONKind.Bool: sb.Append(value.BoolValue!.Value ? "true" : "false"); break;
            case JSONKind.Number:
                var n = value.NumberValue!.Value;
                sb.Append(double.IsFinite(n) ? JSCompat.NumberToString(n) : "null");
                break;
            case JSONKind.String: WriteString(value.StringValue!, sb); break;
            case JSONKind.Array:
            {
                var items = value.ArrayValue!;
                if (items.Count == 0) { sb.Append("[]"); break; }
                var inner = indent + "  ";
                sb.Append("[\n");
                for (int i = 0; i < items.Count; i++)
                {
                    sb.Append(inner);
                    Write(items[i], inner, sb);
                    sb.Append(i == items.Count - 1 ? "\n" : ",\n");
                }
                sb.Append(indent).Append(']');
                break;
            }
            default:
            {
                var obj = value.ObjectValue!;
                if (obj.Count == 0) { sb.Append("{}"); break; }
                var inner = indent + "  ";
                sb.Append("{\n");
                // The key order of the web app's objects (JSON.stringify keeps insertion order); other keys sorted.
                var keys = obj.Keys.OrderBy(k => KeyRank.TryGetValue(k, out var r) ? r : int.MaxValue).ThenBy(k => k, StringComparer.Ordinal).ToList();
                for (int i = 0; i < keys.Count; i++)
                {
                    sb.Append(inner);
                    WriteString(keys[i], sb);
                    sb.Append(": ");
                    Write(obj[keys[i]], inner, sb);
                    sb.Append(i == keys.Count - 1 ? "\n" : ",\n");
                }
                sb.Append(indent).Append('}');
                break;
            }
        }
    }

    static void WriteString(string s, StringBuilder sb)
    {
        sb.Append('"');
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    bool loneSurrogate = char.IsHighSurrogate(c) ? !(i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]))
                        : char.IsLowSurrogate(c) && !(i > 0 && char.IsHighSurrogate(s[i - 1]));
                    if (c < 0x20 || loneSurrogate) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }

    /// <summary>A strict JSON parser like JS <c>JSON.parse</c> (duplicate keys: the last wins at the first position).</summary>
    sealed class BackupJSONParser(string text)
    {
        int _pos;
        int _depth;
        const int MaxDepth = 512;

        public JSONValue? ParseDocument()
        {
            SkipWhitespace();
            var value = ParseValue();
            if (value is null) return null;
            SkipWhitespace();
            return _pos == text.Length ? value : null;
        }

        void SkipWhitespace()
        {
            while (_pos < text.Length && text[_pos] is ' ' or '\t' or '\n' or '\r') _pos++;
        }

        bool Consume(string literal)
        {
            if (string.CompareOrdinal(text, _pos, literal, 0, literal.Length) != 0) return false;
            _pos += literal.Length;
            return true;
        }

        JSONValue? ParseValue()
        {
            if (_pos >= text.Length) return null;
            return text[_pos] switch
            {
                '{' => ParseObject(),
                '[' => ParseArray(),
                '"' => ParseString() is { } s ? JSONValue.String(s) : null,
                't' => Consume("true") ? JSONValue.True : null,
                'f' => Consume("false") ? JSONValue.False : null,
                'n' => Consume("null") ? JSONValue.Null : null,
                _ => ParseNumber(),
            };
        }

        JSONValue? ParseObject()
        {
            if (++_depth > MaxDepth) return null;
            try
            {
                _pos++;
                var map = new JsonObjectMap();
                SkipWhitespace();
                if (_pos < text.Length && text[_pos] == '}') { _pos++; return JSONValue.Object(map); }
                while (true)
                {
                    SkipWhitespace();
                    if (_pos >= text.Length || text[_pos] != '"' || ParseString() is not { } key) return null;
                    SkipWhitespace();
                    if (_pos >= text.Length || text[_pos] != ':') return null;
                    _pos++;
                    SkipWhitespace();
                    if (ParseValue() is not { } value) return null;
                    map[key] = value;
                    SkipWhitespace();
                    if (_pos >= text.Length) return null;
                    if (text[_pos] == ',') { _pos++; continue; }
                    if (text[_pos] != '}') return null;
                    _pos++;
                    return JSONValue.Object(map);
                }
            }
            finally { _depth--; }
        }

        JSONValue? ParseArray()
        {
            if (++_depth > MaxDepth) return null;
            try
            {
                _pos++;
                var list = new List<JSONValue>();
                SkipWhitespace();
                if (_pos < text.Length && text[_pos] == ']') { _pos++; return JSONValue.Array(list); }
                while (true)
                {
                    SkipWhitespace();
                    if (ParseValue() is not { } value) return null;
                    list.Add(value);
                    SkipWhitespace();
                    if (_pos >= text.Length) return null;
                    if (text[_pos] == ',') { _pos++; continue; }
                    if (text[_pos] != ']') return null;
                    _pos++;
                    return JSONValue.Array(list);
                }
            }
            finally { _depth--; }
        }

        string? ParseString()
        {
            _pos++;
            var sb = new StringBuilder();
            while (_pos < text.Length)
            {
                char c = text[_pos++];
                if (c == '"') return sb.ToString();
                if (c == '\\')
                {
                    if (_pos >= text.Length) return null;
                    char e = text[_pos++];
                    switch (e)
                    {
                        case '"': sb.Append('"'); break;
                        case '\\': sb.Append('\\'); break;
                        case '/': sb.Append('/'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'u':
                            if (_pos + 4 > text.Length || !int.TryParse(text.AsSpan(_pos, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out int unit)) return null;
                            if (text.AsSpan(_pos, 4).ContainsAny("+- ")) return null;
                            _pos += 4;
                            sb.Append((char)unit);
                            break;
                        default: return null;
                    }
                    continue;
                }
                if (c < 0x20) return null;
                sb.Append(c);
            }
            return null;
        }

        JSONValue? ParseNumber()
        {
            int start = _pos;
            int Digits()
            {
                int from = _pos;
                while (_pos < text.Length && text[_pos] is >= '0' and <= '9') _pos++;
                return _pos - from;
            }
            if (_pos < text.Length && text[_pos] == '-') _pos++;
            if (_pos >= text.Length) return null;
            if (text[_pos] == '0') _pos++;
            else if (text[_pos] is >= '1' and <= '9') Digits();
            else return null;
            if (_pos < text.Length && text[_pos] == '.')
            {
                _pos++;
                if (Digits() == 0) return null;
            }
            if (_pos < text.Length && text[_pos] is 'e' or 'E')
            {
                _pos++;
                if (_pos < text.Length && text[_pos] is '+' or '-') _pos++;
                if (Digits() == 0) return null;
            }
            return double.TryParse(text.AsSpan(start, _pos - start), NumberStyles.Float, CultureInfo.InvariantCulture, out var n) ? JSONValue.Number(n) : null;
        }
    }
}
