using System.Collections.Concurrent;
using System.Reflection;

namespace Wortschatz.Core;

/// <summary>
/// The JSON value of an enum case (Swift <c>rawValue</c>): the case name with a lower-case first
/// letter (<c>CardStatus.Mastered</c> → "mastered"), or the <see cref="RawAttribute"/> value
/// (<c>[Raw("case")] LetterCase</c>).
/// </summary>
[AttributeUsage(AttributeTargets.Field)]
public sealed class RawAttribute(string value) : Attribute
{
    public string Value { get; } = value;
}

public static class EnumRaw
{
    static readonly ConcurrentDictionary<Type, (Dictionary<string, object> ByRaw, Dictionary<object, string> ByCase)> Cache = new();

    static (Dictionary<string, object> ByRaw, Dictionary<object, string> ByCase) Table(Type t) =>
        Cache.GetOrAdd(t, type =>
        {
            var byRaw = new Dictionary<string, object>(StringComparer.Ordinal);
            var byCase = new Dictionary<object, string>();
            foreach (var f in type.GetFields(BindingFlags.Public | BindingFlags.Static))
            {
                var value = f.GetValue(null)!;
                var raw = f.GetCustomAttribute<RawAttribute>()?.Value ?? char.ToLowerInvariant(f.Name[0]) + f.Name[1..];
                byRaw[raw] = value;
                byCase[value] = raw;
            }
            return (byRaw, byCase);
        });

    /// <summary>The raw (JSON) value of <paramref name="value"/>.</summary>
    public static string Raw<T>(this T value) where T : struct, Enum => Table(typeof(T)).ByCase[value];

    /// <summary>The case with raw value <paramref name="raw"/>, or null.</summary>
    public static T? Parse<T>(string? raw) where T : struct, Enum =>
        raw is not null && Table(typeof(T)).ByRaw.TryGetValue(raw, out var v) ? (T)v : null;

    /// <summary>The case named by a JSON string, or null.</summary>
    public static T? ParseJson<T>(JSONValue? json) where T : struct, Enum => Parse<T>(json?.StringValue);

    public static JSONValue ToJson<T>(this T value) where T : struct, Enum => JSONValue.String(value.Raw());

    public static JSONValue ToJson<T>(this T? value) where T : struct, Enum =>
        value is { } v ? JSONValue.String(v.Raw()) : JSONValue.Null;

    /// <summary>All cases in declaration order.</summary>
    public static T[] All<T>() where T : struct, Enum => Enum.GetValues<T>();
}
