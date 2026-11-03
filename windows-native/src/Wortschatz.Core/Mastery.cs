namespace Wortschatz.Core;

/// <summary>Mastery counts of a set (<c>setProgress</c> result).</summary>
public sealed record SetProgress(int Total, int Mastered, int Learning, int Fresh, int Percent) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("total", Total), ("mastered", Mastered), ("learning", Learning), ("fresh", Fresh), ("percent", Percent));
}

/// <summary>Study streak (<c>studyStreak</c> result).</summary>
public sealed record StudyStreak(int Current, int Today, int Longest) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("current", Current), ("today", Today), ("longest", Longest));
}

/// <summary>Port of Mastery.swift (src/core/mastery.js): card status, set progress and study streaks.</summary>
public static class Mastery
{
    /// <summary>A card counts as mastered after this many correct answers in a row.</summary>
    public const int MASTERY_STREAK = 2;

    public static CardProgress NormalizeProgress(CardProgress? p)
    {
        if (p is null) return CardProgress.Fresh;
        return new CardProgress(Math.Max(0, p.Correct), Math.Max(0, p.Incorrect), Math.Max(0, p.Streak), Math.Max(0, p.StreakBefore),
            p.LastResult, p.LastAnsweredAt is { } t && double.IsFinite(t) ? t : null);
    }

    public static CardStatus CardStatusOf(CardProgress? p)
    {
        if (p is null) return CardStatus.New;
        if (Math.Max(0, p.Streak) >= MASTERY_STREAK) return CardStatus.Mastered;
        if (Math.Max(0, p.Correct) + Math.Max(0, p.Incorrect) > 0) return CardStatus.Learning;
        return CardStatus.New;
    }

    public static SetProgress SetProgressOf(VocabSet? set, IReadOnlyDictionary<string, CardProgress>? progressMap) =>
        SetProgressOf(set?.Cards ?? [], progressMap);

    public static SetProgress SetProgressOf(IReadOnlyList<Card> cards, IReadOnlyDictionary<string, CardProgress>? progressMap)
    {
        int mastered = 0, learning = 0, fresh = 0;
        foreach (var card in cards)
        {
            CardProgress? p = null;
            progressMap?.TryGetValue(card.Id, out p);
            switch (CardStatusOf(p))
            {
                case CardStatus.Mastered: mastered++; break;
                case CardStatus.Learning: learning++; break;
                default: fresh++; break;
            }
        }
        int total = cards.Count;
        int percent = total > 0 ? (int)JSCompat.Round((double)mastered / total * 100) : 0;
        if (mastered < total) percent = Math.Min(percent, 99);
        if (mastered > 0) percent = Math.Max(percent, 1);
        return new SetProgress(total, mastered, learning, fresh, percent);
    }

    /// <summary>Day number of a valid "YYYY-MM-DD" key (years ≥ 100), else null.</summary>
    public static int? DayNumber(string key)
    {
        if (key.Length != 10 || key[4] != '-' || key[7] != '-') return null;
        int? Num(int from, int to)
        {
            int n = 0;
            for (int i = from; i < to; i++)
            {
                if (key[i] < '0' || key[i] > '9') return null;
                n = n * 10 + (key[i] - '0');
            }
            return n;
        }
        if (Num(0, 4) is not { } y || Num(5, 7) is not { } m || Num(8, 10) is not { } d) return null;
        if (y < 100 || m < 1 || m > 12 || d < 1) return null;
        bool leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        int[] lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        if (d > lengths[m - 1]) return null;
        return TimeUtil.DaysFromCivil(y, m, d);
    }

    /// <summary>Current/today/longest streak from the activity map (local calendar days).</summary>
    public static StudyStreak StudyStreakOf(IReadOnlyDictionary<string, double>? activity, double? now = null, TimeZoneInfo? timeZone = null)
    {
        var counts = activity ?? new Dictionary<string, double>();
        var tz = timeZone ?? TimeUtil.Local;
        bool Answered(string key) => counts.TryGetValue(key, out var n) && n > 0;

        var t = JSCompat.TimeClip(now ?? TimeUtil.NowMs()) ?? TimeUtil.NowMs();
        var todayKey = TimeUtil.DateKey(t, tz);
        int today = Answered(todayKey) ? (int)counts[todayKey] : 0;

        int cursor = TimeUtil.LocalDateOf(t, tz).DayNumber;
        if (today == 0) cursor--;
        int current = 0;
        while (Answered(TimeUtil.DateKeyOfDay(cursor))) { current++; cursor--; }

        var days = new List<int>();
        foreach (var key in counts.Keys)
            if (Answered(key) && DayNumber(key) is { } n) days.Add(n);
        days.Sort();
        int longest = 0, run = 0;
        int? prev = null;
        foreach (var d in days)
        {
            if (d == prev) continue;
            run = prev is { } p && d == p + 1 ? run + 1 : 1;
            prev = d;
            if (run > longest) longest = run;
        }
        return new StudyStreak(current, today, Math.Max(longest, current));
    }

    /// <summary>The progress after one answer (<paramref name="at"/>: epoch ms; non-finite → now).</summary>
    public static CardProgress ApplyAnswer(CardProgress? prev, bool correct, double? at = null)
    {
        var p = NormalizeProgress(prev);
        var time = at is { } a && double.IsFinite(a) ? a : TimeUtil.NowMs();
        return correct
            ? new CardProgress(p.Correct + 1, p.Incorrect, p.Streak + 1, p.Streak, AnswerResult.Correct, time)
            : new CardProgress(p.Correct, p.Incorrect + 1, 0, p.Streak, AnswerResult.Incorrect, time);
    }

    /// <summary>"Ich hatte recht": turns the last (incorrect) answer into a correct one.</summary>
    public static CardProgress ApplyOverride(CardProgress? prev)
    {
        var p = NormalizeProgress(prev);
        if (p.LastResult != AnswerResult.Incorrect) return p;
        return p with
        {
            Correct = p.Correct + 1,
            Incorrect = Math.Max(0, p.Incorrect - 1),
            Streak = p.StreakBefore + 1,
            LastResult = AnswerResult.Correct,
        };
    }

    // MARK: JSON helpers for maps

    public static Dictionary<string, CardProgress>? ProgressMapFromJson(JSONValue json)
    {
        if (json.ObjectValue is not { } o) return null;
        var map = new Dictionary<string, CardProgress>(StringComparer.Ordinal);
        foreach (var (k, v) in o) if (CardProgress.FromJson(v) is { } p) map[k] = p;
        return map;
    }

    public static JSONValue ProgressMapToJson(IReadOnlyDictionary<string, CardProgress> map) =>
        JSONValue.Object(map.Select(p => new KeyValuePair<string, JSONValue>(p.Key, p.Value.ToJson())));
}
