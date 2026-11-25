import Foundation

/// Port of src/lib/time.js: date/time helpers. The display texts are German (the source language)
/// and pass through `L`, so the app's language can reorder or reword them; `dateKey` is a key and
/// never translated.
///
/// All timestamps are epoch milliseconds as `Double` (like JS). Local calendar logic takes an
/// explicit `TimeZone` (the web app uses the browser's zone); the parity fixtures are generated
/// with TZ=Europe/Zurich. Calendar arithmetic is proleptic Gregorian, like JS `Date`.
public enum TimeUtil {
    public static let MINUTE: Double = 60 * 1000
    public static let HOUR: Double = 60 * MINUTE
    public static let DAY: Double = 24 * HOUR

    /// `Date.now()`.
    public static func nowMs() -> Double {
        (Date().timeIntervalSince1970 * 1000).rounded(.down)
    }

    /// Local calendar day as "YYYY-MM-DD" (invalid timestamps fall back to now, like JS).
    public static func dateKey(_ ms: Double = nowMs(), timeZone: TimeZone = .current) -> String {
        let t = JSCompat.timeClip(ms) ?? nowMs()
        let d = localDate(t, timeZone: timeZone)
        return "\(d.year)-\(pad(d.month))-\(pad(d.day))"
    }

    /// Local date as "DD.MM.YYYY" ("" for nil/invalid input). Display only: the order and the
    /// separators come from `L` (day, month, year).
    public static func formatDate(_ ms: Double?, timeZone: TimeZone = .current) -> String {
        guard let ms, let t = JSCompat.timeClip(ms) else { return "" }
        let d = localDate(t, timeZone: timeZone)
        return L("%@.%@.%@", pad(d.day), pad(d.month), "\(d.year)")
    }

    /// Whole local calendar days from `from` to `to` (DST-safe); 0 for nil/invalid input.
    public static func calendarDaysBetween(_ from: Double?, _ to: Double?, timeZone: TimeZone = .current) -> Int {
        guard let from, let to, let a = JSCompat.timeClip(from), let b = JSCompat.timeClip(to) else { return 0 }
        return localDate(b, timeZone: timeZone).dayNumber - localDate(a, timeZone: timeZone).dayNumber
    }

    /// "gerade eben" | "vor 5 Minuten" | "vor 2 Stunden" | "gestern" | "vor 3 Tagen" | "am 12.09.2026"
    /// ("" for nil/invalid input).
    public static func relativeTime(_ ms: Double?, now: Double = nowMs(), timeZone: TimeZone = .current) -> String {
        guard let ms, let then = JSCompat.timeClip(ms), let ref = JSCompat.timeClip(now) else { return "" }
        let diff = ref - then
        if diff < MINUTE { return L("gerade eben") } // also absorbs small clock skew into the future
        if diff < HOUR {
            let m = (diff / MINUTE).rounded(.down)
            return m == 1 ? L("vor 1 Minute") : L("vor %@ Minuten", JSCompat.numberToString(m))
        }
        let days = calendarDaysBetween(then, ref, timeZone: timeZone)
        if days <= 0 {
            let hrs = (diff / HOUR).rounded(.down)
            return hrs == 1 ? L("vor 1 Stunde") : L("vor %@ Stunden", JSCompat.numberToString(hrs))
        }
        if days == 1 { return L("gestern") }
        if days < 7 { return L("vor %@ Tagen", "\(days)") }
        return L("am %@", formatDate(then, timeZone: timeZone))
    }

    /// "1 Std. 5 Min." | "4 Min. 12 Sek." | "4 Min." | "45 Sek." (NaN and negatives give "0 Sek.").
    public static func formatDuration(_ ms: Double) -> String {
        let seconds = ms.isNaN ? 0 : JSCompat.round(ms / 1000)
        let total = max(0, seconds)
        guard total.isFinite else { return L("%@ Sek.", JSCompat.numberToString(total)) }
        let h = (total / 3600).rounded(.down)
        let m = (total.truncatingRemainder(dividingBy: 3600) / 60).rounded(.down)
        let s = total.truncatingRemainder(dividingBy: 60)
        let hs = JSCompat.numberToString(h)
        let mins = JSCompat.numberToString(m)
        let secs = JSCompat.numberToString(s)
        if h > 0 { return m > 0 ? L("%@ Std. %@ Min.", hs, mins) : L("%@ Std.", hs) }
        if m > 0 { return s > 0 ? L("%@ Min. %@ Sek.", mins, secs) : L("%@ Min.", mins) }
        return L("%@ Sek.", secs)
    }

    // MARK: - Local calendar helpers (shared with Mastery and the store)

    /// A local calendar date/time (proleptic Gregorian, like JS `Date` getters).
    public struct LocalDate: Sendable, Equatable, Hashable {
        public var year: Int
        public var month: Int // 1…12
        public var day: Int // 1…31
        public var hour: Int
        public var minute: Int
        public var second: Int
        public var millisecond: Int

        /// Days since 1970-01-01 of this calendar day (`Date.UTC(y, m, d) / DAY`).
        public var dayNumber: Int { TimeUtil.daysFromCivil(year, month, day) }
    }

    /// The local date and time of `ms` in `timeZone` (JS `getFullYear()`, `getMonth() + 1`, …).
    public static func localDate(_ ms: Double, timeZone: TimeZone) -> LocalDate {
        let offset = Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: ms / 1000))) * 1000
        let local = ms + offset
        let days = (local / DAY).rounded(.down)
        let msOfDay = Int(local - days * DAY)
        let (y, m, d) = civilFromDays(Int(days))
        return LocalDate(
            year: y, month: m, day: d, hour: msOfDay / 3_600_000, minute: (msOfDay / 60000) % 60,
            second: (msOfDay / 1000) % 60, millisecond: msOfDay % 1000)
    }

    /// The timestamp of a local date/time, like JS `new Date(year, month - 1, day, hour, minute,
    /// second, millisecond).getTime()`: an ambiguous time (DST end) takes the earlier instant, a
    /// time in a gap (DST start) moves forward by the gap.
    public static func localTimestamp(
        year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0, millisecond: Int = 0,
        timeZone: TimeZone
    ) -> Double {
        let localMs = Double(daysFromCivil(year, month, day)) * DAY
            + Double(hour) * 3_600_000 + Double(minute) * 60000 + Double(second) * 1000 + Double(millisecond)
        func offset(_ utc: Double) -> Double {
            Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: utc / 1000))) * 1000
        }
        var instants: [Double] = []
        for probe in [localMs - DAY, localMs, localMs + DAY] {
            let candidate = localMs - offset(probe)
            if offset(candidate) == localMs - candidate, !instants.contains(candidate) { instants.append(candidate) }
        }
        if let earliest = instants.min() { return earliest }
        // In a gap: use the offset before the transition (the time moves forward).
        return localMs - offset(localMs - DAY)
    }

    /// "YYYY-MM-DD" of a day number (days since 1970-01-01).
    public static func dateKey(dayNumber: Int) -> String {
        let (y, m, d) = civilFromDays(dayNumber)
        return "\(y)-\(pad(m))-\(pad(d))"
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (month 1…12).
    public static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Proleptic Gregorian date (year, month 1…12, day) of a day number.
    public static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    static func pad(_ n: Int) -> String {
        n >= 0 && n < 10 ? "0\(n)" : "\(n)"
    }
}
