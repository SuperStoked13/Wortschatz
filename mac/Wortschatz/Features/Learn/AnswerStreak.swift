import Foundation

/// Correct answers in a row on a study screen (Lernen, Schreiben): the flame in the action bar's
/// pill, with a milestone every five. It lives as long as the screen, so every visit starts at
/// zero; the daily streak (Lernserie) is the one that lasts.
struct AnswerStreak: Equatable {
    /// A milestone every this many correct answers in a row (5, 10, 15 …).
    static let milestoneStep = 5
    /// The pill shows the flame from this many on.
    static let visibleFrom = 3

    private(set) var current = 0
    private(set) var best = 0
    /// The last change reached a milestone (the next sound is the streak fanfare).
    private(set) var reachedMilestone = false
    /// The streak the last miss ended, given back by "Ich hatte recht".
    private var endedByMiss = 0

    /// An answer was recorded.
    mutating func record(correct: Bool) {
        if correct {
            current += 1
            endedByMiss = 0
        } else {
            endedByMiss = current
            current = 0
        }
        settle(grew: correct)
    }

    /// "Ich hatte recht": the miss counts as correct, so the streak it ended goes on.
    mutating func overrideMiss() {
        current = endedByMiss + 1
        endedByMiss = 0
        settle(grew: true)
    }

    static func isMilestone(_ count: Int) -> Bool {
        count > 0 && count % milestoneStep == 0
    }

    private mutating func settle(grew: Bool) {
        best = max(best, current)
        reachedMilestone = grew && Self.isMilestone(current)
    }
}
