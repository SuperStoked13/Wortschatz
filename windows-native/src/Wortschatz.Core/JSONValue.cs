using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace Wortschatz.Core;

public enum JSONKind { Null, Bool, Number, String, Array, Object }

/// <summary>
/// Port of JSONValue.swift: an arbitrary JSON value. Used where the web app accepts loosely typed
/// JSON (backup import, lenient decoding of stored data) and by the parity tests. Every model has
/// <c>FromJson(JSONValue)</c> / <c>ToJson()</c> instead of reflection-based serialisation, so the
/// JSON shape is exactly the web app's.
/// Objects keep their insertion order (like JS objects with string keys).
/// </summary>
public sealed class JSONValue
{
    public JSONKind Kind { get; }
    readonly bool _bool;
    readonly double _number;
    readonly string? _string;
    readonly List<JSONValue>? _array;
    readonly JsonObjectMap? _object;

    JSONValue(JSONKind kind, bool b = false, double n = 0, string? s = null, List<JSONValue>? a = null, JsonObjectMap? o = null)
    {
        Kind = kind; _bool = b; _number = n; _string = s; _array = a; _object = o;
    }

    public static readonly JSONValue Null = new(JSONKind.Null);
    public static readonly JSONValue True = new(JSONKind.Bool, b: true);
    public static readonly JSONValue False = new(JSONKind.Bool, b: false);

    public static JSONValue Bool(bool b) => b ? True : False;
    public static JSONValue Number(double n) => new(JSONKind.Number, n: n);
    public static JSONValue String(string? s) => s is null ? Null : new(JSONKind.String, s: s);
    public static JSONValue Array(IEnumerable<JSONValue> items) => new(JSONKind.Array, a: items.ToList());
    public static JSONValue Array(params JSONValue[] items) => new(JSONKind.Array, a: items.ToList());
    public static JSONValue Object(JsonObjectMap map) => new(JSONKind.Object, o: map);
    public static JSONValue Object(IEnumerable<KeyValuePair<string, JSONValue>> pairs)
    {
        var map = new JsonObjectMap();
        foreach (var (k, v) in pairs) map[k] = v;
        return new(JSONKind.Object, o: map);
    }

    /// <summary>An object built from (key, value) pairs; null values become JSON null.</summary>
    public static JSONValue Obj(params (string Key, JSONValue? Value)[] pairs)
    {
        var map = new JsonObjectMap();
        foreach (var (k, v) in pairs) map[k] = v ?? Null;
        return new(JSONKind.Object, o: map);
    }

    public static implicit operator JSONValue(string s) => String(s);
    public static implicit operator JSONValue(double n) => Number(n);
    public static implicit operator JSONValue(int n) => Number(n);
    public static implicit operator JSONValue(bool b) => Bool(b);

    /// <summary>A number, or null when <paramref name="n"/> is null.</summary>
    public static JSONValue Nullable(double? n) => n is { } v ? Number(v) : Null;
    public static JSONValue Nullable(int? n) => n is { } v ? Number(v) : Null;
    public static JSONValue Nullable(bool? b) => b is { } v ? Bool(v) : Null;

    // MARK: Accessors (JS-like)

    public JSONValue? this[string key] => Kind == JSONKind.Object && _object!.TryGetValue(key, out var v) ? v : null;
    public JSONValue? this[int index] => Kind == JSONKind.Array && index >= 0 && index < _array!.Count ? _array[index] : null;

    public bool IsObject => Kind == JSONKind.Object;
    public bool IsArray => Kind == JSONKind.Array;
    public bool IsNull => Kind == JSONKind.Null;

    public JsonObjectMap? ObjectValue => Kind == JSONKind.Object ? _object : null;
    public List<JSONValue>? ArrayValue => Kind == JSONKind.Array ? _array : null;
    public string? StringValue => Kind == JSONKind.String ? _string : null;
    public bool? BoolValue => Kind == JSONKind.Bool ? _bool : null;
    public double? NumberValue => Kind == JSONKind.Number ? _number : null;

    /// <summary>A finite number (<c>typeof v === 'number' &amp;&amp; Number.isFinite(v)</c>).</summary>
    public double? FiniteNumber => Kind == JSONKind.Number && double.IsFinite(_number) ? _number : null;

    /// <summary>An integer-valued number (<c>Number.isInteger(v)</c>) as int when it fits.</summary>
    public int? IntegerValue =>
        Kind == JSONKind.Number && double.IsFinite(_number) && _number == Math.Truncate(_number) && Math.Abs(_number) <= int.MaxValue
            ? (int)_number : null;

    /// <summary>An integer-valued number as long (up to 2^53).</summary>
    public long? LongValue =>
        Kind == JSONKind.Number && double.IsFinite(_number) && _number == Math.Truncate(_number) && Math.Abs(_number) <= 9_007_199_254_740_992
            ? (long)_number : null;

    /// <summary><c>String(v)</c> of primitives (strings, numbers in JS notation, booleans); null otherwise.</summary>
    public string? JsPrimitiveString => Kind switch
    {
        JSONKind.String => _string,
        JSONKind.Number => JSCompat.NumberToString(_number),
        JSONKind.Bool => _bool ? "true" : "false",
        _ => null,
    };

    // MARK: Equality

    /// <summary>Exact structural identity (strings ordinal, numbers ==, key order irrelevant).</summary>
    public static bool Identical(JSONValue? a, JSONValue? b)
    {
        if (a is null || b is null) return a is null && b is null;
        if (a.Kind != b.Kind) return false;
        switch (a.Kind)
        {
            case JSONKind.Null: return true;
            case JSONKind.Bool: return a._bool == b._bool;
            case JSONKind.Number: return a._number == b._number;
            case JSONKind.String: return string.Equals(a._string, b._string, StringComparison.Ordinal);
            case JSONKind.Array:
                if (a._array!.Count != b._array!.Count) return false;
                for (int i = 0; i < a._array.Count; i++) if (!Identical(a._array[i], b._array[i])) return false;
                return true;
            default:
                if (a._object!.Count != b._object!.Count) return false;
                foreach (var (k, v) in a._object)
                    if (!b._object.TryGetValue(k, out var w) || !Identical(v, w)) return false;
                return true;
        }
    }

    // MARK: Parsing / serialising

    /// <summary>Parses JSON text (any top-level value). Throws <see cref="JsonException"/>.</summary>
    public static JSONValue Parse(string text)
    {
        using var doc = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 512 });
        return FromElement(doc.RootElement);
    }

    public static JSONValue Parse(byte[] utf8)
    {
        using var doc = JsonDocument.Parse(utf8, new JsonDocumentOptions { MaxDepth = 512 });
        return FromElement(doc.RootElement);
    }

    /// <summary>Parses JSON text, or null when it is not JSON.</summary>
    public static JSONValue? TryParse(string text)
    {
        try { return Parse(text); }
        catch (JsonException) { return null; }
    }

    public static JSONValue FromElement(JsonElement e)
    {
        switch (e.ValueKind)
        {
            case JsonValueKind.Null: return Null;
            case JsonValueKind.True: return True;
            case JsonValueKind.False: return False;
            case JsonValueKind.Number: return Number(e.GetDouble());
            case JsonValueKind.String: return new(JSONKind.String, s: e.GetString());
            case JsonValueKind.Array:
                var list = new List<JSONValue>(e.GetArrayLength());
                foreach (var item in e.EnumerateArray()) list.Add(FromElement(item));
                return new(JSONKind.Array, a: list);
            case JsonValueKind.Object:
                var map = new JsonObjectMap();
                foreach (var p in e.EnumerateObject()) map[p.Name] = FromElement(p.Value);
                return new(JSONKind.Object, o: map);
            default: return Null;
        }
    }

    static readonly JsonWriterOptions WriterOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Indented = false,
        SkipValidation = true,
    };

    /// <summary>JSON text like <c>JSON.stringify</c> (integral numbers without fraction; NaN/∞ → null).</summary>
    public string ToJsonString(bool indented = false, bool sortedKeys = false)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream, WriterOptions with { Indented = indented }))
            Write(w, sortedKeys);
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    void Write(Utf8JsonWriter w, bool sortedKeys)
    {
        switch (Kind)
        {
            case JSONKind.Null: w.WriteNullValue(); break;
            case JSONKind.Bool: w.WriteBooleanValue(_bool); break;
            case JSONKind.Number:
                if (!double.IsFinite(_number)) w.WriteNullValue();
                else if (_number == Math.Truncate(_number) && Math.Abs(_number) < 9_007_199_254_740_992) w.WriteNumberValue((long)_number);
                else w.WriteRawValue(JSCompat.NumberToString(_number), skipInputValidation: true);
                break;
            case JSONKind.String: w.WriteStringValue(_string); break;
            case JSONKind.Array:
                w.WriteStartArray();
                foreach (var v in _array!) v.Write(w, sortedKeys);
                w.WriteEndArray();
                break;
            default:
                w.WriteStartObject();
                IEnumerable<KeyValuePair<string, JSONValue>> pairs = _object!;
                if (sortedKeys) pairs = pairs.OrderBy(p => p.Key, StringComparer.Ordinal);
                foreach (var (k, v) in pairs)
                {
                    w.WritePropertyName(k);
                    v.Write(w, sortedKeys);
                }
                w.WriteEndObject();
                break;
        }
    }

    public override string ToString() => ToJsonString(sortedKeys: true);
}

/// <summary>An insertion-ordered string-keyed map (JS object).</summary>
public sealed class JsonObjectMap : IEnumerable<KeyValuePair<string, JSONValue>>
{
    readonly Dictionary<string, JSONValue> _dict = new(StringComparer.Ordinal);
    readonly List<string> _keys = [];

    public int Count => _keys.Count;
    public IReadOnlyList<string> Keys => _keys;

    public JSONValue this[string key]
    {
        get => _dict[key];
        set
        {
            if (!_dict.ContainsKey(key)) _keys.Add(key);
            _dict[key] = value;
        }
    }

    public bool TryGetValue(string key, out JSONValue value) => _dict.TryGetValue(key, out value!);
    public bool ContainsKey(string key) => _dict.ContainsKey(key);

    public bool Remove(string key)
    {
        if (!_dict.Remove(key)) return false;
        _keys.Remove(key);
        return true;
    }

    public IEnumerator<KeyValuePair<string, JSONValue>> GetEnumerator()
    {
        foreach (var k in _keys) yield return new(k, _dict[k]);
    }

    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
}

/// <summary>Types with a JSON form identical to the web app's.</summary>
public interface IJsonEncodable
{
    JSONValue ToJson();
}

public static class JsonExtensions
{
    public static JSONValue ToJsonArray<T>(this IEnumerable<T> items) where T : IJsonEncodable =>
        JSONValue.Array(items.Select(i => i.ToJson()));

    public static JSONValue ToJsonArray(this IEnumerable<string> items) =>
        JSONValue.Array(items.Select(JSONValue.String));

    public static JSONValue ToJsonArray(this IEnumerable<int> items) =>
        JSONValue.Array(items.Select(i => JSONValue.Number(i)));

    public static JSONValue ToJsonArray(this IEnumerable<double> items) =>
        JSONValue.Array(items.Select(JSONValue.Number));

    public static JSONValue ToJsonOrNull(this IJsonEncodable? value) => value?.ToJson() ?? JSONValue.Null;

    /// <summary><c>count(v)</c> of mastery.js: a positive finite number, floored; anything else 0.</summary>
    public static int JsCount(this JSONValue? v)
    {
        if (v?.FiniteNumber is not { } n || n <= 0) return 0;
        return (int)Math.Floor(Math.Min(n, int.MaxValue));
    }

    public static string Format(this double d) => d.ToString(CultureInfo.InvariantCulture);
}
