import Foundation

/// Mastery counts of a set (`setProgress` result).
public struct SetProgress: Codable, Sendable, Equatable, Hashable {
    public var total: Int
    public var mastered: Int
    public var learning: Int
    /// Cards never answered ("new"; `fresh` because `new` reads badly in JS).
    public var fresh: Int
    /// 0…100; never 100 before everything is mastered, never 0 once something is.
    public var percent: Int

    public init(total: Int, mastered: Int, learning: Int, fresh: Int, percent: Int) {
        self.total = total
        self.mastered = mastered
        self.learning = learning
        self.fresh = fresh
        self.percent = percent
    }
}

/// Study streak (`studyStreak` result).
public struct StudyStreak: Codable, Sendable, Equatable, Hashable {
    /// Consecutive days with answers, ending today (or yesterday when nothing was answered today yet).
    public var current: Int
    /// Answers given today.
    public var today: Int
    /// Longest run of consecutive days ever (at least `current`).
    public var longest: Int

    public init(current: Int, today: Int, longest: Int) {
        self.current = current
        self.today = today
        self.longest = longest
    }
}

/// Port of src/core/mastery.js: card mastery status, set progress and study-streak computations.
public enum Mastery {
    /// A card counts as mastered after this many correct answers in a row (across rounds and
    /// sessions).
    public static let MASTERY_STREAK = 2

    /// A complete, well-typed CardProgress for any input (nil becomes a fresh record, negative
    /// counts become 0, a non-finite `lastAnsweredAt` becomes nil). For raw JSON use
    /// `CardProgress(json:)`, which applies the same rules.
    public static func normalizeProgress(_ p: CardProgress?) -> CardProgress {
        guard let p else { return .fresh }
        return CardProgress(
            correct: max(0, p.correct), incorrect: max(0, p.incorrect), streak: max(0, p.streak),
            streakBefore: max(0, p.streakBefore), lastResult: p.lastResult,
            lastAnsweredAt: p.lastAnsweredAt.flatMap { $0.isFinite ? $0 : nil })
    }

    public static func cardStatus(_ progress: CardProgress?) -> CardStatus {
        guard let p = progress else { return .new }
        if max(0, p.streak) >= MASTERY_STREAK { return .mastered }
        if max(0, p.correct) + max(0, p.incorrect) > 0 { return .learning }
        return .new
    }

    /// Status counts of the set's cards (progress entries of other ids are ignored).
    public static func setProgress(_ set: VocabSet?, _ progressMap: ProgressMap?) -> SetProgress {
        setProgress(cards: set?.cards ?? [], progress: progressMap)
    }

    public static func setProgress(cards: [Card], progress progressMap: ProgressMap?) -> SetProgress {
        let map = progressMap ?? [:]
        var mastered = 0
        var learning = 0
        var fresh = 0
        for card in cards {
            switch cardStatus(map[card.id]) {
            case .mastered: mastered += 1
            case .learning: learning += 1
            case .new: fresh += 1
            }
        }
        let total = cards.count
        var percent = total > 0 ? Int(JSCompat.round(Double(mastered) / Double(total) * 100)) : 0
        // Never show 100 % before everything is mastered, nor 0 % once something is.
        if mastered < total { percent = min(percent, 99) }
        if mastered > 0 { percent = max(percent, 1) }
        return SetProgress(total: total, mastered: mastered, learning: learning, fresh: fresh, percent: percent)
    }

    /// Day number (days since epoch) of a valid "YYYY-MM-DD" key, else nil. Like JS
    /// `Date.UTC`, years 0000…0099 are invalid (they would map to 1900…1999).
    public static func dayNumber(_ key: String) -> Int? {
        let s = Array(key.unicodeScalars)
        guard s.count == 10, s[4] == "-", s[7] == "-" else { return nil }
        func num(_ range: Range<Int>) -> Int? {
            var n = 0
            for i in range {
                guard s[i].value >= 0x30, s[i].value <= 0x39 else { return nil }
                n = n * 10 + Int(s[i].value - 0x30)
            }
            return n
        }
        guard let y = num(0..<4), let m = num(5..<7), let d = num(8..<10) else { return nil }
        guard y >= 100, (1...12).contains(m), d >= 1 else { return nil }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard d <= lengths[m - 1] else { return nil }
        return TimeUtil.daysFromCivil(y, m, d)
    }

    /// Current/today/longest streak from the activity map. Days are local calendar days in
    /// `timeZone`.
    public static func studyStreak(
        _ activity: Activity?, now: Double = TimeUtil.nowMs(), timeZone: TimeZone = .current
    ) -> StudyStreak {
        let counts = activity ?? [:]
        func answered(_ key: String) -> Bool { (counts[key] ?? 0) > 0 }

        let t = JSCompat.timeClip(now) ?? TimeUtil.nowMs()
        let todayKey = TimeUtil.dateKey(t, timeZone: timeZone)
        let today = answered(todayKey) ? counts[todayKey]! : 0

        // Walk back day by day in local time.
        var cursor = TimeUtil.localDate(t, timeZone: timeZone).dayNumber
        if today == 0 { cursor -= 1 }
        var current = 0
        while answered(TimeUtil.dateKey(dayNumber: cursor)) {
            current += 1
            cursor -= 1
        }

        var days: [Int] = []
        for key in counts.keys where answered(key) {
            if let n = dayNumber(key) { days.append(n) }
        }
        days.sort()
        var longest = 0
        var run = 0
        var prev: Int?
        for d in days {
            if d == prev { continue }
            if let p = prev, d == p + 1 { run += 1 } else { run = 1 }
            prev = d
            if run > longest { longest = run }
        }
        return StudyStreak(current: current, today: today, longest: max(longest, current))
    }

    /// The progress after one answer (`at`: epoch ms; non-finite → now).
    public static func applyAnswer(_ prev: CardProgress?, correct: Bool, at: Double = TimeUtil.nowMs()) -> CardProgress {
        let p = normalizeProgress(prev)
        let time = at.isFinite ? at : TimeUtil.nowMs()
        if correct {
            return CardProgress(
                correct: p.correct + 1, incorrect: p.incorrect, streak: p.streak + 1, streakBefore: p.streak,
                lastResult: .correct, lastAnsweredAt: time)
        }
        return CardProgress(
            correct: p.correct, incorrect: p.incorrect + 1, streak: 0, streakBefore: p.streak,
            lastResult: .incorrect, lastAnsweredAt: time)
    }

    /// "Ich hatte recht": turns the last (incorrect) answer into a correct one. Anything else is
    /// returned unchanged (normalised), so a second override is a no-op.
    public static func applyOverride(_ prev: CardProgress?) -> CardProgress {
        var p = normalizeProgress(prev)
        guard p.lastResult == .incorrect else { return p }
        p.correct += 1
        p.incorrect = max(0, p.incorrect - 1)
        p.streak = p.streakBefore + 1
        p.lastResult = .correct
        return p
    }
}
