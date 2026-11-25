using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

/// <summary>
/// Port of TimeUtil.swift (src/lib/time.js): date/time helpers. The display texts are German (the source language) and
/// pass through <see cref="CoreText.L(string)"/>, so the app's language can reorder or reword them; <see cref="DateKey"/>
/// is a key and never translated. Timestamps are epoch
/// milliseconds as double (like JS). Local calendar logic takes an explicit time zone; the parity
/// fixtures use Europe/Zurich. Calendar arithmetic is proleptic Gregorian, like JS <c>Date</c>.
/// </summary>
public static class TimeUtil
{
    public const double MINUTE = 60 * 1000;
    public const double HOUR = 60 * MINUTE;
    public const double DAY = 24 * HOUR;

    /// <summary>Overridable clock for tests and snapshots.</summary>
    public static Func<double> Clock { get; set; } = () => Math.Floor((DateTime.UtcNow - DateTime.UnixEpoch).TotalMilliseconds);

    /// <summary><c>Date.now()</c>.</summary>
    public static double NowMs() => Clock();

    /// <summary>The time zone used when none is given (the computer's).</summary>
    public static TimeZoneInfo Local => TimeZoneInfo.Local;

    /// <summary>Local calendar day "YYYY-MM-DD" (invalid timestamps fall back to now).</summary>
    public static string DateKey(double? ms = null, TimeZoneInfo? timeZone = null)
    {
        var t = JSCompat.TimeClip(ms ?? NowMs()) ?? NowMs();
        var d = LocalDateOf(t, timeZone ?? Local);
        return $"{d.Year}-{Pad(d.Month)}-{Pad(d.Day)}";
    }

    /// <summary>Local date "DD.MM.YYYY" ("" for null/invalid). Display only: the order and the separators come from L (day, month, year).</summary>
    public static string FormatDate(double? ms, TimeZoneInfo? timeZone = null)
    {
        if (ms is not { } m || JSCompat.TimeClip(m) is not { } t) return "";
        var d = LocalDateOf(t, timeZone ?? Local);
        return L($"{Pad(d.Day)}.{Pad(d.Month)}.{d.Year}");
    }

    /// <summary>Whole local calendar days from <paramref name="from"/> to <paramref name="to"/>.</summary>
    public static int CalendarDaysBetween(double? from, double? to, TimeZoneInfo? timeZone = null)
    {
        if (from is not { } f || to is not { } g || JSCompat.TimeClip(f) is not { } a || JSCompat.TimeClip(g) is not { } b) return 0;
        var tz = timeZone ?? Local;
        return LocalDateOf(b, tz).DayNumber - LocalDateOf(a, tz).DayNumber;
    }

    /// <summary>"gerade eben" | "vor 5 Minuten" | "vor 2 Stunden" | "gestern" | "vor 3 Tagen" | "am 12.09.2026".</summary>
    public static string RelativeTime(double? ms, double? now = null, TimeZoneInfo? timeZone = null)
    {
        if (ms is not { } m || JSCompat.TimeClip(m) is not { } then || JSCompat.TimeClip(now ?? NowMs()) is not { } reference) return "";
        var tz = timeZone ?? Local;
        var diff = reference - then;
        if (diff < MINUTE) return L("gerade eben");
        if (diff < HOUR)
        {
            var mins = Math.Floor(diff / MINUTE);
            return mins == 1 ? L("vor 1 Minute") : L($"vor {JSCompat.NumberToString(mins)} Minuten");
        }
        var days = CalendarDaysBetween(then, reference, tz);
        if (days <= 0)
        {
            var hrs = Math.Floor(diff / HOUR);
            return hrs == 1 ? L("vor 1 Stunde") : L($"vor {JSCompat.NumberToString(hrs)} Stunden");
        }
        if (days == 1) return L("gestern");
        if (days < 7) return L($"vor {days} Tagen");
        return L($"am {FormatDate(then, tz)}");
    }

    /// <summary>"1 Std. 5 Min." | "4 Min. 12 Sek." | "4 Min." | "45 Sek.".</summary>
    public static string FormatDuration(double ms)
    {
        var seconds = double.IsNaN(ms) ? 0 : JSCompat.Round(ms / 1000);
        var total = Math.Max(0, seconds);
        if (!double.IsFinite(total)) return L($"{JSCompat.NumberToString(total)} Sek.");
        var h = Math.Floor(total / 3600);
        var m = Math.Floor(total % 3600 / 60);
        var s = total % 60;
        string hs = JSCompat.NumberToString(h), mins = JSCompat.NumberToString(m), secs = JSCompat.NumberToString(s);
        if (h > 0) return m > 0 ? L($"{hs} Std. {mins} Min.") : L($"{hs} Std.");
        if (m > 0) return s > 0 ? L($"{mins} Min. {secs} Sek.") : L($"{mins} Min.");
        return L($"{secs} Sek.");
    }

    // MARK: Local calendar helpers

    /// <summary>A local calendar date/time (proleptic Gregorian, like JS <c>Date</c> getters).</summary>
    public readonly record struct LocalDate(int Year, int Month, int Day, int Hour, int Minute, int Second, int Millisecond)
    {
        /// <summary>Days since 1970-01-01 of this calendar day.</summary>
        public int DayNumber => DaysFromCivil(Year, Month, Day);
    }

    static readonly long MinOffsetProbe = DateTimeOffset.MinValue.ToUnixTimeMilliseconds() + (long)DAY * 2;
    static readonly long MaxOffsetProbe = DateTimeOffset.MaxValue.ToUnixTimeMilliseconds() - (long)DAY * 2;

    /// <summary>The UTC offset of <paramref name="tz"/> at instant <paramref name="utcMs"/>, in ms.</summary>
    public static double OffsetMs(double utcMs, TimeZoneInfo tz)
    {
        var probe = (long)Math.Clamp(Math.Floor(utcMs), MinOffsetProbe, MaxOffsetProbe);
        return tz.GetUtcOffset(DateTimeOffset.FromUnixTimeMilliseconds(probe)).TotalMilliseconds;
    }

    /// <summary>The local date and time of <paramref name="ms"/> in <paramref name="timeZone"/>.</summary>
    public static LocalDate LocalDateOf(double ms, TimeZoneInfo timeZone)
    {
        var local = ms + OffsetMs(ms, timeZone);
        var days = Math.Floor(local / DAY);
        var msOfDay = (int)(local - days * DAY);
        var (y, mo, d) = CivilFromDays((long)days);
        return new LocalDate(y, mo, d, msOfDay / 3_600_000, msOfDay / 60000 % 60, msOfDay / 1000 % 60, msOfDay % 1000);
    }

    /// <summary>JS <c>new Date(y, m - 1, d, h, min, s, ms).getTime()</c> in <paramref name="timeZone"/>.</summary>
    public static double LocalTimestamp(int year, int month, int day, int hour = 0, int minute = 0, int second = 0, int millisecond = 0, TimeZoneInfo? timeZone = null)
    {
        var tz = timeZone ?? Local;
        var localMs = DaysFromCivil(year, month, day) * DAY + hour * 3_600_000.0 + minute * 60000.0 + second * 1000.0 + millisecond;
        var instants = new List<double>();
        foreach (var probe in new[] { localMs - DAY, localMs, localMs + DAY })
        {
            var candidate = localMs - OffsetMs(probe, tz);
            if (OffsetMs(candidate, tz) == localMs - candidate && !instants.Contains(candidate)) instants.Add(candidate);
        }
        if (instants.Count > 0) return instants.Min();
        return localMs - OffsetMs(localMs - DAY, tz);
    }

    /// <summary>"YYYY-MM-DD" of a day number.</summary>
    public static string DateKeyOfDay(int dayNumber)
    {
        var (y, m, d) = CivilFromDays(dayNumber);
        return $"{y}-{Pad(m)}-{Pad(d)}";
    }

    public static int DaysFromCivil(int year, int month, int day)
    {
        long y = month <= 2 ? year - 1 : year;
        long era = (y >= 0 ? y : y - 399) / 400;
        long yoe = y - era * 400;
        long mp = (month + 9) % 12;
        long doy = (153 * mp + 2) / 5 + day - 1;
        long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return (int)(era * 146_097 + doe - 719_468);
    }

    public static (int Year, int Month, int Day) CivilFromDays(long days)
    {
        long z = days + 719_468;
        long era = (z >= 0 ? z : z - 146_096) / 146_097;
        long doe = z - era * 146_097;
        long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
        long y = yoe + era * 400;
        long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        long mp = (5 * doy + 2) / 153;
        long d = doy - (153 * mp + 2) / 5 + 1;
        long m = mp < 10 ? mp + 3 : mp - 9;
        return ((int)(m <= 2 ? y + 1 : y), (int)m, (int)d);
    }

    internal static string Pad(int n) => n is >= 0 and < 10 ? "0" + n : n.ToString();
}
