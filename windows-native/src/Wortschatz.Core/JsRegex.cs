using System.Collections.Concurrent;
using System.Text;
using System.Text.RegularExpressions;

namespace Wortschatz.Core;

/// <summary>
/// JavaScript regular expressions in .NET. The web app's JS regexes are copied verbatim and
/// translated here, so their meaning stays the JS one: <c>\s</c> (JS whitespace set), <c>\d</c>/<c>\w</c>/<c>\b</c>
/// (ASCII only), <c>.</c> (no line terminators), <c>$</c> (end of input, not before a final "\n"),
/// <c>^</c>/<c>$</c> with the m flag, <c>[^]</c>, <c>\u{…}</c>. Flags: i (case-insensitive, invariant), m, s, g
/// (g is up to the caller: <see cref="ReplaceAll"/> vs <see cref="ReplaceFirst"/>), u (ignored: C# strings
/// are UTF-16 like JS; astral characters inside classes are not supported).
/// </summary>
public static class JsRegex
{
    const string WS = @"\t\n\v\f\r    -     　﻿";
    const string W = "A-Za-z0-9_";
    const string LT = @"\n\r  ";

    static readonly ConcurrentDictionary<(string, string), Regex> Cache = new();

    /// <summary>The compiled .NET regex for JS <c>/pattern/flags</c>.</summary>
    public static Regex Get(string pattern, string flags = "") =>
        Cache.GetOrAdd((pattern, flags), key =>
        {
            var options = RegexOptions.CultureInvariant;
            if (key.Item2.Contains('i')) options |= RegexOptions.IgnoreCase;
            return new Regex(Translate(key.Item1, key.Item2), options);
        });

    /// <summary>Translates JS pattern syntax to .NET (see the class summary).</summary>
    public static string Translate(string p, string flags = "")
    {
        bool multiline = flags.Contains('m');
        bool dotAll = flags.Contains('s');
        // /iu folds with Unicode simple case folding: ſ (U+017F) ≡ s and K (U+212A, Kelvin) ≡ k, which
        // .NET's invariant IgnoreCase does not know.
        bool fold = flags.Contains('i') && flags.Contains('u');
        var sb = new StringBuilder(p.Length + 16);
        bool inClass = false;
        int classStart = 0;
        for (int i = 0; i < p.Length; i++)
        {
            char c = p[i];
            if (c == '\\' && i + 1 < p.Length)
            {
                char n = p[i + 1];
                i++;
                switch (n)
                {
                    case 's': sb.Append(inClass ? WS : "[" + WS + "]"); break;
                    case 'S': sb.Append(inClass ? @"\S" : "[^" + WS + "]"); break;
                    case 'd': sb.Append(inClass ? "0-9" : "[0-9]"); break;
                    case 'D': sb.Append(inClass ? @"\D" : "[^0-9]"); break;
                    case 'w': sb.Append(inClass ? W : "[" + W + "]"); break;
                    case 'W': sb.Append(inClass ? @"\W" : "[^" + W + "]"); break;
                    case 'b':
                        if (inClass) sb.Append(@"\b");
                        else sb.Append($"(?:(?<=[{W}])(?![{W}])|(?<![{W}])(?=[{W}]))");
                        break;
                    case 'B':
                        sb.Append($"(?:(?<=[{W}])(?=[{W}])|(?<![{W}])(?![{W}]))");
                        break;
                    case 'u' when i + 1 < p.Length && p[i + 1] == '{':
                    {
                        int close = p.IndexOf('}', i + 2);
                        var cp = Convert.ToInt32(p[(i + 2)..close], 16);
                        i = close;
                        if (cp <= 0xFFFF) sb.Append($@"\u{cp:X4}");
                        else if (inClass) throw new NotSupportedException($"JsRegex: astral character in a class: {p}");
                        else
                        {
                            var pair = char.ConvertFromUtf32(cp);
                            sb.Append($@"(?:\u{(int)pair[0]:X4}\u{(int)pair[1]:X4})");
                        }
                        break;
                    }
                    case '/': sb.Append('/'); break;
                    case '-': sb.Append(@"\-"); break;
                    default: sb.Append('\\').Append(n); break;
                }
                continue;
            }
            if (inClass)
            {
                if (c == ']')
                {
                    inClass = false;
                    if (fold)
                    {
                        var raw = p[classStart..i];
                        if (raw.Contains('s') || raw.Contains('S') || raw.Contains("a-z") || raw.Contains("A-Z")) sb.Append('\u017F');
                        if (raw.Contains('k') || raw.Contains('K') || raw.Contains("a-z") || raw.Contains("A-Z")) sb.Append('\u212A');
                    }
                }
                else if (c == '[') { sb.Append(@"\["); continue; } // literal in JS, subtraction in .NET
                sb.Append(c);
                continue;
            }
            if (fold && c is 's' or 'S') { sb.Append("[s\u017F]"); continue; }
            if (fold && c is 'k' or 'K') { sb.Append("[k\u212A]"); continue; }
            switch (c)
            {
                case '[':
                    if (p.AsSpan(i).StartsWith("[^]")) { sb.Append(@"[\s\S]"); i += 2; break; }
                    if (p.AsSpan(i).StartsWith("[]")) { sb.Append("(?!)"); i += 1; break; }
                    inClass = true;
                    classStart = i + 1;
                    sb.Append('[');
                    if (i + 1 < p.Length && p[i + 1] == '^') { sb.Append('^'); i++; }
                    // A ']' right after '[' or '[^' closes the (empty) class in JS; .NET reads it as literal.
                    break;
                case '.': sb.Append(dotAll ? @"[\s\S]" : "[^" + LT + "]"); break;
                case '$': sb.Append(multiline ? $"(?=[{LT}]|\\z)" : @"\z"); break;
                case '^': sb.Append(multiline ? $"(?<=[{LT}]|\\A)" : @"\A"); break;
                default: sb.Append(c); break;
            }
        }
        return sb.ToString();
    }

    public static bool Test(string pattern, string s, string flags = "") => Get(pattern, flags).IsMatch(s);

    /// <summary><c>s.replace(/pattern/g, replacement)</c> (JS <c>$1</c>/<c>$&amp;</c> work in .NET too).</summary>
    public static string ReplaceAll(string s, string pattern, string replacement, string flags = "") =>
        Get(pattern, flags).Replace(s, replacement);

    public static string ReplaceAll(string s, string pattern, MatchEvaluator evaluator, string flags = "") =>
        Get(pattern, flags).Replace(s, evaluator);

    /// <summary><c>s.replace(/pattern/, replacement)</c> without the g flag: only the first match.</summary>
    public static string ReplaceFirst(string s, string pattern, string replacement, string flags = "") =>
        Get(pattern, flags).Replace(s, replacement, 1);

    public static string ReplaceFirst(string s, string pattern, MatchEvaluator evaluator, string flags = "") =>
        Get(pattern, flags).Replace(s, evaluator, 1);

    /// <summary><c>s.match(/pattern/)</c> (first match with groups) or null.</summary>
    public static Match? Match(string s, string pattern, string flags = "")
    {
        var m = Get(pattern, flags).Match(s);
        return m.Success ? m : null;
    }

    /// <summary><c>s.match(/pattern/g)</c>: every match text (empty list for none).</summary>
    public static List<string> MatchAll(string s, string pattern, string flags = "") =>
        Get(pattern, flags).Matches(s).Select(m => m.Value).ToList();

    /// <summary><c>s.split(/pattern/)</c> (captured groups are not included).</summary>
    public static string[] Split(string s, string pattern, string flags = "")
    {
        var re = Get(pattern, flags);
        var output = new List<string>();
        int last = 0;
        foreach (Match m in re.Matches(s))
        {
            if (m.Length == 0 && (m.Index == 0 || m.Index == s.Length)) continue;
            output.Add(s[last..m.Index]);
            last = m.Index + m.Length;
        }
        output.Add(s[last..]);
        return output.ToArray();
    }

    /// <summary>The value of group <paramref name="i"/>, or null when it did not participate (JS undefined).</summary>
    public static string? Group(this Match m, int i) => m.Groups[i].Success ? m.Groups[i].Value : null;
}
