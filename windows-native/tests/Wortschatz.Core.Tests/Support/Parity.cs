using System.Text;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of Tests/WortschatzCoreTests/Support/Parity.swift + ParityDiff.swift. The fixtures are the
// Mac app's (mac/Packages/WortschatzCore/Tests/WortschatzCoreTests/Fixtures), generated from the
// web app's JS by mac/Parity/gen-*.js. They are read in place, never copied.

/// <summary>One generated case: <c>fn</c> names the JS function, <c>args</c> its arguments, <c>out</c> the JS result.</summary>
public sealed class ParityCase(string id, string fn, List<JSONValue> args, JSONValue output)
{
    public string Id { get; } = id;
    public string Fn { get; } = fn;
    public List<JSONValue> Args { get; } = args;
    public JSONValue Out { get; } = output;

    public JSONValue Arg(int i) => i < Args.Count ? Args[i] : JSONValue.Null;
    public string Str(int i) => Arg(i).StringValue ?? throw new InvalidOperationException($"{Id}: argument {i} is not a string");
    public string? OptStr(int i) => Arg(i).StringValue;
    public double Num(int i) => Arg(i).NumberValue ?? throw new InvalidOperationException($"{Id}: argument {i} is not a number");
    public double? OptNum(int i) => Arg(i).NumberValue;
    public int Int(int i) => Arg(i).IntegerValue ?? throw new InvalidOperationException($"{Id}: argument {i} is not an integer");
    public bool Bool(int i) => Arg(i).BoolValue ?? throw new InvalidOperationException($"{Id}: argument {i} is not a boolean");
}

public static class Fixtures
{
    static string? _dir;

    /// <summary>The Mac fixture folder, found from the test binary upwards.</summary>
    public static string Dir
    {
        get
        {
            if (_dir is not null) return _dir;
            var d = new DirectoryInfo(AppContext.BaseDirectory);
            while (d is not null)
            {
                var candidate = Path.Combine(d.FullName, "mac", "Packages", "WortschatzCore", "Tests", "WortschatzCoreTests", "Fixtures");
                if (Directory.Exists(candidate)) return _dir = candidate;
                d = d.Parent;
            }
            throw new DirectoryNotFoundException("mac/Packages/WortschatzCore/Tests/WortschatzCoreTests/Fixtures not found");
        }
    }

    public static List<ParityCase> Load(string name)
    {
        var doc = JSONValue.Parse(File.ReadAllBytes(Path.Combine(Dir, name + ".json")));
        var cases = new List<ParityCase>();
        foreach (var c in doc["cases"]!.ArrayValue!)
            cases.Add(new ParityCase(c["id"]!.StringValue!, c["fn"]!.StringValue!, c["args"]?.ArrayValue ?? [], c["out"] ?? JSONValue.Null));
        Assert.Equal(doc["count"]!.IntegerValue, cases.Count);
        return cases;
    }

    /// <summary>Europe/Zurich, the zone the fixtures are generated in.</summary>
    public static readonly TimeZoneInfo Zurich = TimeZoneInfo.FindSystemTimeZoneById("Europe/Zurich");
}

public static class ParityDiff
{
    /// <summary>
    /// Rules: numbers equal within <paramref name="tolerance"/>; strings ordinal; arrays element by
    /// element; objects same keys, except that a key JS omitted may be null here (and with
    /// <paramref name="nullMatchesMissing"/> a JS null matches a missing key).
    /// </summary>
    public static List<string> Differences(JSONValue expected, JSONValue actual, double tolerance = 1e-9, bool nullMatchesMissing = false, int limit = 12)
    {
        var output = new List<string>();
        Walk(expected, actual, "$", tolerance, nullMatchesMissing, limit, output);
        return output;
    }

    static void Walk(JSONValue e, JSONValue a, string path, double tol, bool nullMatchesMissing, int limit, List<string> output)
    {
        if (output.Count >= limit) return;
        if (e.Kind != a.Kind)
        {
            output.Add($"{path}: expected {Describe(e)}, got {Describe(a)}");
            return;
        }
        switch (e.Kind)
        {
            case JSONKind.Null: return;
            case JSONKind.Bool:
                if (e.BoolValue != a.BoolValue) output.Add($"{path}: expected {e.BoolValue}, got {a.BoolValue}");
                return;
            case JSONKind.Number:
                double x = e.NumberValue!.Value, y = a.NumberValue!.Value;
                if (x == y || (double.IsFinite(x) && double.IsFinite(y) && Math.Abs(x - y) <= tol)) return;
                output.Add($"{path}: expected {JSCompat.NumberToString(x)}, got {JSCompat.NumberToString(y)}");
                return;
            case JSONKind.String:
                if (!JSCompat.Identical(e.StringValue, a.StringValue)) output.Add($"{path}: expected {Describe(e)}, got {Describe(a)}");
                return;
            case JSONKind.Array:
                var ea = e.ArrayValue!; var aa = a.ArrayValue!;
                if (ea.Count != aa.Count) output.Add($"{path}: expected {ea.Count} elements, got {aa.Count}");
                for (int i = 0; i < Math.Min(ea.Count, aa.Count); i++) Walk(ea[i], aa[i], $"{path}[{i}]", tol, nullMatchesMissing, limit, output);
                return;
            default:
                var eo = e.ObjectValue!; var ao = a.ObjectValue!;
                foreach (var key in eo.Keys.OrderBy(k => k, StringComparer.Ordinal))
                {
                    if (!ao.TryGetValue(key, out var av))
                    {
                        if (nullMatchesMissing && eo[key].IsNull) continue;
                        output.Add($"{path}.{key}: missing (expected {Describe(eo[key])})");
                        continue;
                    }
                    Walk(eo[key], av, $"{path}.{key}", tol, nullMatchesMissing, limit, output);
                }
                foreach (var key in ao.Keys.OrderBy(k => k, StringComparer.Ordinal))
                {
                    if (eo.ContainsKey(key) || ao[key].IsNull) continue;
                    output.Add($"{path}.{key}: unexpected key (got {Describe(ao[key])})");
                }
                return;
        }
    }

    public static string Describe(JSONValue v, int max = 240)
    {
        var s = v.ToJsonString(sortedKeys: true);
        var sb = new StringBuilder();
        foreach (var u in JSCompat.Scalars(s))
        {
            if (u < 0x20 || u == 0x7F || (u > 0x7F && char.IsWhiteSpace((char)Math.Min(u, 0xFFFF)) && u != ' ')) sb.Append($"\\u{{{u:X4}}}");
            else sb.AppendScalar(u);
        }
        s = sb.ToString();
        return s.Length > max ? s[..max] + "…" : s;
    }
}

public static class ParityRunner
{
    /// <summary>
    /// Runs every case of <c>Fixtures/&lt;fixture&gt;.json</c> through <paramref name="body"/>, which returns the
    /// C# result (or null for an unknown fn, which fails). Reports up to <paramref name="maxReported"/> mismatches.
    /// </summary>
    public static void Run(string fixture, Func<ParityCase, JSONValue?> body, double tolerance = 1e-9, bool nullMatchesMissing = false,
        int maxReported = 25, Func<ParityCase, bool>? only = null)
    {
        var cases = Fixtures.Load(fixture);
        Assert.NotEmpty(cases);
        var failures = new List<string>();
        var unknown = new SortedSet<string>(StringComparer.Ordinal);
        var byFn = new SortedDictionary<string, int>(StringComparer.Ordinal);
        int failed = 0, ran = 0;
        foreach (var c in cases)
        {
            if (only is not null && !only(c)) continue;
            ran++;
            JSONValue? actual;
            try { actual = body(c); }
            catch (Exception ex)
            {
                failed++;
                byFn[c.Fn] = byFn.GetValueOrDefault(c.Fn) + 1;
                if (failures.Count < maxReported) failures.Add($"{c.Id} threw: {ex.GetType().Name}: {ex.Message}\n    at {ex.StackTrace?.Split('\n').FirstOrDefault()?.Trim()}\n  args: {ParityDiff.Describe(JSONValue.Array(c.Args), 600)}");
                continue;
            }
            if (actual is null) { unknown.Add(c.Fn); continue; }
            var diffs = ParityDiff.Differences(c.Out, actual, tolerance, nullMatchesMissing);
            if (diffs.Count == 0) continue;
            failed++;
            byFn[c.Fn] = byFn.GetValueOrDefault(c.Fn) + 1;
            if (failures.Count < maxReported)
                failures.Add($"Parity mismatch {c.Id}\n  {string.Join("\n  ", diffs)}\n  args: {ParityDiff.Describe(JSONValue.Array(c.Args), 600)}");
        }
        var summary = string.Join(", ", byFn.Select(p => $"{p.Key}: {p.Value}"));
        Assert.True(unknown.Count == 0, $"fixture {fixture}: unhandled fns {string.Join(", ", unknown)}");
        Assert.True(failed == 0, $"fixture {fixture}: {failed} of {ran} cases differ ({summary})\n\n{string.Join("\n\n", failures)}");
    }
}
