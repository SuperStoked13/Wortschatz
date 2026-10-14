import Testing
import WortschatzCore

/// Port of tests/time.test.js (all timestamps built in Europe/Zurich local time).
@Suite("TimeUtil (time.test.js)")
struct TimeUtilTests {
    static let SEC = 1000.0
    static let MIN = 60 * SEC
    static let HOUR = 60 * MIN

    static func at(_ y: Int, _ mo: Int, _ d: Int, _ hh: Int = 12, _ mm: Int = 0, _ ss: Int = 0) -> Double {
        TimeUtil.localTimestamp(year: y, month: mo, day: d, hour: hh, minute: mm, second: ss, timeZone: zurich)
    }

    static let NOW = at(2026, 10, 11, 14, 0)

    func dateKey(_ t: Double) -> String { TimeUtil.dateKey(t, timeZone: zurich) }
    func rel(_ t: Double?, _ now: Double = NOW) -> String { TimeUtil.relativeTime(t, now: now, timeZone: zurich) }
    func days(_ a: Double, _ b: Double) -> Int { TimeUtil.calendarDaysBetween(a, b, timeZone: zurich) }

    @Test func dateKeyLocalWithZeroPadding() {
        #expect(dateKey(Self.at(2026, 1, 5, 9, 30)) == "2026-01-05")
        #expect(dateKey(Self.at(2026, 12, 31, 23, 59, 59)) == "2026-12-31")
        #expect(dateKey(Self.at(2027, 1, 1, 0, 0, 0)) == "2027-01-01")
    }

    @Test func dateKeyUsesTheLocalDayNotUTC() {
        #expect(dateKey(Self.at(2026, 9, 12, 0, 30)) == "2026-09-12")
        #expect(dateKey(Self.at(2026, 9, 12, 23, 30)) == "2026-09-12")
    }

    @Test func dateKeyDefaultsToNow() {
        let key = TimeUtil.dateKey(timeZone: zurich)
        #expect(key.count == 10)
        #expect(key == TimeUtil.dateKey(TimeUtil.nowMs(), timeZone: zurich))
        // Invalid timestamps fall back to now, like JS.
        #expect(TimeUtil.dateKey(.nan, timeZone: zurich) == key)
    }

    @Test func relativeTimeJustNow() {
        let NOW = Self.NOW
        #expect(rel(NOW) == "gerade eben")
        #expect(rel(NOW - 10 * Self.SEC) == "gerade eben")
        #expect(rel(NOW - 59 * Self.SEC) == "gerade eben")
        #expect(rel(NOW + 5 * Self.SEC) == "gerade eben")
    }

    @Test func relativeTimeMinutes() {
        let NOW = Self.NOW
        #expect(rel(NOW - 60 * Self.SEC) == "vor 1 Minute")
        #expect(rel(NOW - 119 * Self.SEC) == "vor 1 Minute")
        #expect(rel(NOW - 5 * Self.MIN) == "vor 5 Minuten")
        #expect(rel(NOW - 59 * Self.MIN - 59 * Self.SEC) == "vor 59 Minuten")
    }

    @Test func relativeTimeHoursOnTheSameDay() {
        let NOW = Self.NOW
        #expect(rel(NOW - Self.HOUR) == "vor 1 Stunde")
        #expect(rel(NOW - Self.HOUR - 59 * Self.MIN) == "vor 1 Stunde")
        #expect(rel(NOW - 2 * Self.HOUR) == "vor 2 Stunden")
        #expect(rel(Self.at(2026, 10, 11, 0, 30)) == "vor 13 Stunden")
    }

    @Test func relativeTimeYesterday() {
        #expect(rel(Self.at(2026, 10, 10, 20, 0)) == "gestern")
        #expect(rel(Self.at(2026, 10, 10, 0, 1)) == "gestern")
        #expect(rel(Self.at(2026, 10, 10, 22, 0), Self.at(2026, 10, 11, 1, 0)) == "gestern")
        #expect(rel(Self.at(2026, 10, 10, 23, 50), Self.at(2026, 10, 11, 0, 10)) == "vor 20 Minuten")
    }

    @Test func relativeTimeDays() {
        #expect(rel(Self.at(2026, 10, 9, 18, 0)) == "vor 2 Tagen")
        #expect(rel(Self.at(2026, 10, 8, 9, 0)) == "vor 3 Tagen")
        #expect(rel(Self.at(2026, 10, 5, 23, 59)) == "vor 6 Tagen")
    }

    @Test func relativeTimeAbsoluteDate() {
        #expect(rel(Self.at(2026, 10, 4, 12, 0)) == "am 04.10.2026")
        #expect(rel(Self.at(2026, 9, 12, 9, 15)) == "am 12.09.2026")
        #expect(rel(Self.at(2025, 12, 31, 23, 0)) == "am 31.12.2025")
    }

    @Test func relativeTimeAcrossMonthAndYear() {
        #expect(rel(Self.at(2026, 9, 30, 21, 0), Self.at(2026, 10, 1, 9, 0)) == "gestern")
        #expect(rel(Self.at(2025, 12, 30, 12, 0), Self.at(2026, 1, 1, 12, 0)) == "vor 2 Tagen")
    }

    @Test func relativeTimeEmptyForMissingOrInvalidInput() {
        #expect(rel(nil) == "")
        #expect(rel(.nan) == "")
        #expect(rel(.infinity) == "")
    }

    @Test func calendarDaysBetweenIsDSTSafe() {
        #expect(days(Self.at(2026, 10, 11, 23, 59), Self.at(2026, 10, 12, 0, 1)) == 1)
        #expect(days(Self.at(2026, 10, 11, 0, 1), Self.at(2026, 10, 11, 23, 59)) == 0)
        #expect(days(Self.at(2026, 3, 28, 12), Self.at(2026, 3, 29, 12)) == 1)
        #expect(days(Self.at(2026, 3, 29, 12), Self.at(2026, 3, 30, 12)) == 1)
        #expect(days(Self.at(2026, 10, 24, 12), Self.at(2026, 10, 26, 12)) == 2)
        #expect(days(Self.at(2026, 10, 12), Self.at(2026, 10, 11)) == -1)
    }

    @Test func formatDate() {
        #expect(TimeUtil.formatDate(Self.at(2026, 9, 12), timeZone: zurich) == "12.09.2026")
        #expect(TimeUtil.formatDate(Self.at(2026, 1, 1), timeZone: zurich) == "01.01.2026")
        #expect(TimeUtil.formatDate(nil, timeZone: zurich) == "")
    }

    @Test func formatDurationSeconds() {
        #expect(TimeUtil.formatDuration(45 * Self.SEC) == "45 Sek.")
        #expect(TimeUtil.formatDuration(1 * Self.SEC) == "1 Sek.")
        #expect(TimeUtil.formatDuration(0) == "0 Sek.")
        #expect(TimeUtil.formatDuration(499) == "0 Sek.")
        #expect(TimeUtil.formatDuration(500) == "1 Sek.")
    }

    @Test func formatDurationMinutesAndSeconds() {
        #expect(TimeUtil.formatDuration(4 * Self.MIN + 12 * Self.SEC) == "4 Min. 12 Sek.")
        #expect(TimeUtil.formatDuration(4 * Self.MIN) == "4 Min.")
        #expect(TimeUtil.formatDuration(59 * Self.SEC + 600) == "1 Min.")
        #expect(TimeUtil.formatDuration(59 * Self.MIN + 59 * Self.SEC) == "59 Min. 59 Sek.")
    }

    @Test func formatDurationHoursAndMinutes() {
        #expect(TimeUtil.formatDuration(Self.HOUR) == "1 Std.")
        #expect(TimeUtil.formatDuration(Self.HOUR + 5 * Self.MIN) == "1 Std. 5 Min.")
        #expect(TimeUtil.formatDuration(2 * Self.HOUR + 5 * Self.MIN + 30 * Self.SEC) == "2 Std. 5 Min.")
    }

    @Test func formatDurationRobustAgainstBadInput() {
        #expect(TimeUtil.formatDuration(-5000) == "0 Sek.")
        #expect(TimeUtil.formatDuration(.nan) == "0 Sek.")
        #expect(TimeUtil.formatDuration(90000) == "1 Min. 30 Sek.")
    }

    @Test func localTimestampHandlesDSTLikeJS() {
        // Gap: 02:30 on the spring-forward day becomes 03:30 CEST.
        #expect(Self.at(2026, 3, 29, 2, 30) == 1_774_747_800_000)
        // Ambiguous: 02:30 on the fall-back day is the earlier (CEST) instant.
        #expect(Self.at(2026, 10, 25, 2, 30) == 1_792_888_200_000)
    }
}
