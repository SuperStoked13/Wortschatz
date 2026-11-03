namespace Wortschatz.Core;

/// <summary>
/// Port of TextMemo.swift: remembers the results of a pure text function, so the texts of a
/// set's cards are worked out once instead of once per question. Thread-safe; forgets everything
/// once it holds <c>limit</c> texts. Keys compare ordinally (like JS ===).
/// </summary>
internal sealed class TextMemo<TValue>(int limit = 50_000)
{
    readonly Dictionary<string, TValue> _values = new(StringComparer.Ordinal);
    readonly Lock _lock = new();

    public TValue Value(string text, Func<string, TValue> compute)
    {
        lock (_lock) if (_values.TryGetValue(text, out var v)) return v;
        var value = compute(text);
        lock (_lock)
        {
            if (_values.Count >= limit) _values.Clear();
            _values[text] = value;
        }
        return value;
    }
}
