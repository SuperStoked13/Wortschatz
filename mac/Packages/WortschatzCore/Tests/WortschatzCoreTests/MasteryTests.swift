import Testing
import WortschatzCore

/// Port of tests/mastery.test.js.
@Suite("Mastery (mastery.test.js)")
struct MasteryTests {
    /// 11 Oct 2026, 15:00 in Zurich.
    static let NOW = TimeUtil.localTimestamp(year: 2026, month: 10, day: 11, hour: 15, timeZone: zurich)

    /// Date key `offset` days relative to `base` (local noon).
    static func day(_ offset: Int, _ base: Double = NOW) -> String {
        TimeUtil.dateKey(dayNumber: TimeUtil.localDate(base, timeZone: zurich).dayNumber + offset)
    }

    static func p(_ correct: Int = 0, _ incorrect: Int = 0, _ streak: Int = 0) -> CardProgress {
        CardProgress(correct: correct, incorrect: incorrect, streak: streak)
    }

    func streak(_ activity: Activity?, _ now: Double = NOW) -> StudyStreak {
        Mastery.studyStreak(activity, now: now, timeZone: zurich)
    }

    @Test func masteryStreakIs2() {
        #expect(Mastery.MASTERY_STREAK == 2)
    }

    @Test func cardStatusNewWithoutProgress() {
        #expect(Mastery.cardStatus(nil) == .new)
        #expect(Mastery.cardStatus(Self.p(0, 0, 0)) == .new)
        #expect(Mastery.cardStatus(CardProgress(json: "garbage")) == .new)
    }

    @Test func cardStatusThresholds() {
        #expect(Mastery.cardStatus(Self.p(1, 0, 1)) == .learning)
        #expect(Mastery.cardStatus(Self.p(0, 3, 0)) == .learning)
        #expect(Mastery.cardStatus(Self.p(2, 0, 2)) == .mastered)
        #expect(Mastery.cardStatus(Self.p(9, 4, 5)) == .mastered)
        #expect(Mastery.cardStatus(Self.p(9, 4, 1)) == .learning)
    }

    @Test func applyAnswerFromNothing() {
        #expect(Mastery.applyAnswer(nil, correct: true, at: 1000)
            == CardProgress(correct: 1, incorrect: 0, streak: 1, streakBefore: 0, lastResult: .correct, lastAnsweredAt: 1000))
        #expect(Mastery.applyAnswer(nil, correct: false, at: 2000)
            == CardProgress(correct: 0, incorrect: 1, streak: 0, streakBefore: 0, lastResult: .incorrect, lastAnsweredAt: 2000))
    }

    @Test func statusTransitions() {
        var p: CardProgress?
        #expect(Mastery.cardStatus(p) == .new)
        p = Mastery.applyAnswer(p, correct: true, at: 1)
        #expect(Mastery.cardStatus(p) == .learning)
        p = Mastery.applyAnswer(p, correct: true, at: 2)
        #expect(p?.streak == 2)
        #expect(Mastery.cardStatus(p) == .mastered)
        p = Mastery.applyAnswer(p, correct: true, at: 3)
        #expect(p?.streak == 3)
        p = Mastery.applyAnswer(p, correct: false, at: 4)
        #expect(p?.streak == 0)
        #expect(p?.streakBefore == 3)
        #expect(Mastery.cardStatus(p) == .learning)
        p = Mastery.applyAnswer(p, correct: true, at: 5)
        #expect(Mastery.cardStatus(p) == .learning)
        p = Mastery.applyAnswer(p, correct: true, at: 6)
        #expect(Mastery.cardStatus(p) == .mastered)
        #expect(p?.correct == 5)
        #expect(p?.incorrect == 1)
        #expect(p?.lastAnsweredAt == 6)
    }

    @Test func applyOverrideRestoresTheStreakBeforeTheMiss() {
        var p = Mastery.applyAnswer(nil, correct: true, at: 1)
        p = Mastery.applyAnswer(p, correct: false, at: 2)
        #expect(p.streakBefore == 1)
        let o = Mastery.applyOverride(p)
        #expect(o.correct == 2)
        #expect(o.incorrect == 0)
        #expect(o.streak == 2)
        #expect(o.lastResult == .correct)
        #expect(Mastery.cardStatus(o) == .mastered)
        #expect(o.lastAnsweredAt == 2)
    }

    @Test func applyOverrideIsANoOpUnlessTheLastAnswerWasIncorrect() {
        let p = Mastery.applyAnswer(nil, correct: true, at: 1)
        #expect(Mastery.applyOverride(p) == p)
        let twice = Mastery.applyOverride(Mastery.applyOverride(Mastery.applyAnswer(nil, correct: false, at: 1)))
        #expect(twice.correct == 1)
        #expect(twice.incorrect == 0)
        #expect(twice.streak == 1)
        #expect(Mastery.applyOverride(nil) == Mastery.normalizeProgress(nil))
    }

    @Test func normalizeProgressRepairsCorruptEntries() throws {
        let raw = try JSONValue.parse(#"{"correct": -3, "incorrect": "x", "streak": 2.7, "lastResult": "maybe", "lastAnsweredAt": null}"#)
        #expect(CardProgress(json: raw) == CardProgress(correct: 0, incorrect: 0, streak: 2, streakBefore: 0))
        #expect(Mastery.normalizeProgress(CardProgress(correct: -1, lastAnsweredAt: .nan)) == CardProgress())
    }

    static func set(_ ids: [String]) -> VocabSet {
        VocabSet(id: "s", title: "S", cards: ids.map { Card(id: $0, term: $0, definition: $0) }, createdAt: 0)
    }

    @Test func setProgressCountsStatusesOfTheSetCardsOnly() {
        let map: ProgressMap = ["a": Self.p(2, 0, 2), "b": Self.p(1, 1, 0), "c": Self.p(1, 0, 1), "orphan": Self.p(5, 0, 5)]
        #expect(Mastery.setProgress(Self.set(["a", "b", "c", "d"]), map)
            == SetProgress(total: 4, mastered: 1, learning: 2, fresh: 1, percent: 25))
    }

    @Test func setProgressEdgeCases() {
        #expect(Mastery.setProgress(nil, nil) == SetProgress(total: 0, mastered: 0, learning: 0, fresh: 0, percent: 0))
        #expect(Mastery.setProgress(Self.set(["x"]), [:]) == SetProgress(total: 1, mastered: 0, learning: 0, fresh: 1, percent: 0))
        let all = Mastery.setProgress(Self.set(["x", "y"]), ["x": Self.p(2, 0, 2), "y": Self.p(3, 0, 3)])
        #expect(all.percent == 100)
        #expect(all.mastered == 2)
    }

    @Test func setProgressPercentNeverRoundsTo100Or0Misleadingly() {
        let ids = (0..<200).map { "c\($0)" }
        var almost: ProgressMap = [:]
        for i in 0..<199 { almost["c\(i)"] = Self.p(2, 0, 2) }
        #expect(Mastery.setProgress(Self.set(ids), almost).percent == 99)
        #expect(Mastery.setProgress(Self.set(ids), ["c0": Self.p(2, 0, 2)]).percent == 1)
        #expect(Mastery.setProgress(Self.set(["a", "b", "c"]), ["a": Self.p(2, 0, 2), "b": Self.p(2, 0, 2)]).percent == 67)
    }

    @Test func studyStreakEmptyActivity() {
        #expect(streak([:]) == StudyStreak(current: 0, today: 0, longest: 0))
        #expect(streak(nil) == StudyStreak(current: 0, today: 0, longest: 0))
    }

    @Test func studyStreakEndingToday() {
        let activity: Activity = [Self.day(0): 12, Self.day(-1): 3, Self.day(-2): 7]
        #expect(streak(activity) == StudyStreak(current: 3, today: 12, longest: 3))
    }

    @Test func studyStreakEndingYesterdayStillCounts() {
        #expect(streak([Self.day(-1): 4, Self.day(-2): 1]) == StudyStreak(current: 2, today: 0, longest: 2))
    }

    @Test func brokenStreakResetsCurrentButKeepsLongest() {
        let activity: Activity = [
            Self.day(-2): 5, Self.day(-3): 5, Self.day(-10): 1, Self.day(-11): 1, Self.day(-12): 1, Self.day(-13): 1,
        ]
        let s = streak(activity)
        #expect(s.current == 0)
        #expect(s.today == 0)
        #expect(s.longest == 4)
    }

    @Test func zeroCountsAndInvalidKeysAreIgnored() {
        let activity: Activity = [Self.day(0): 2, Self.day(-1): 0, Self.day(-2): 9, "not-a-date": 4, "2026-02-31": 3]
        #expect(streak(activity) == StudyStreak(current: 1, today: 2, longest: 1))
    }

    @Test func studyStreakAcrossTheEndOfDaylightSavingTime() {
        let base = TimeUtil.localTimestamp(year: 2026, month: 11, day: 2, hour: 9, timeZone: zurich)
        var activity: Activity = [:]
        for i in 0..<14 { activity[Self.day(-i, base)] = 1 }
        let s = streak(activity, base)
        #expect(s.current == 14)
        #expect(s.longest == 14)
    }

    @Test func studyStreakAcrossMonthAndYearBoundaries() {
        let base = TimeUtil.localTimestamp(year: 2027, month: 1, day: 2, hour: 8, timeZone: zurich)
        let activity: Activity = ["2027-01-02": 1, "2027-01-01": 1, "2026-12-31": 1, "2026-12-30": 1]
        #expect(streak(activity, base) == StudyStreak(current: 4, today: 1, longest: 4))
    }

    @Test func dayNumberValidation() {
        #expect(Mastery.dayNumber("1970-01-02") == 1)
        #expect(Mastery.dayNumber("2024-02-29") != nil)
        #expect(Mastery.dayNumber("2023-02-29") == nil)
        #expect(Mastery.dayNumber("0099-01-01") == nil)
        #expect(Mastery.dayNumber("2026-1-01") == nil)
    }
}
