import Foundation
import WortschatzCore

/// «Wiederholungsfragen» and «Nachkontrolle nach Fehlern» as they are switched now (`UserDefaults`,
/// the same for every set).
struct LearnSwitches: Equatable {
    var review: Bool
    var recheck: Bool

    static var current: LearnSwitches {
        LearnSwitches(
            review: UserDefaults.standard.bool(forKey: LearnController.reviewKey), recheck: LearnController.recheckIsOn)
    }
}

extension AppModel {
    /// Brings the stored sessions in line with the Nachkontrolle now (sessions stored before the
    /// switches applied at once kept it for days), then watches the two Learn switches wherever
    /// they are switched: Einstellungen › Lernen, a set's options, Lernen's options.
    func observeLearnSwitches() -> any NSObjectProtocol {
        switchStoredSessions(review: nil, recheck: learnSwitches.recheck)
        return NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            // Any thread may write the defaults (the poster waits for nobody): look on the main actor.
            Task { @MainActor in self?.learnSwitchesMayHaveChanged() }
        }
    }

    /// A switch that changed applies at once to every stored Learn session (since 24.11.2026:
    /// before, a long session kept the rechecks for days after they were switched off). An open
    /// Lernen applies it to its own session too (`LearnScreen` → `LearnController.switchesChanged`).
    private func learnSwitchesMayHaveChanged() {
        let now = LearnSwitches.current
        let before = learnSwitches
        guard now != before else { return }
        learnSwitches = now
        switchStoredSessions(
            review: now.review != before.review ? now.review : nil,
            recheck: now.recheck != before.recheck ? now.recheck : nil)
    }

    /// Every unfinished stored session with the switched option(s) applied (nil: not switched),
    /// written as one change.
    private func switchStoredSessions(review: Bool?, recheck: Bool?) {
        let time = TimeUtil.nowMs()
        var switched: [(setID: String, saved: LearnFlow.SavedLearn)] = []
        for set in store.listSets() {
            guard let saved = store.getLearnJSON(set.id).flatMap(LearnFlow.SavedLearn.init(json:)),
                let next = saved.switching(review: review, recheck: recheck, progress: store.getProgress(set.id), now: time)
            else { continue }
            switched.append((set.id, next))
        }
        guard !switched.isEmpty else { return }
        do {
            try store.batch {
                for (setID, saved) in switched { try store.saveLearnJSON(setID, saved.json()) }
            }
        } catch {
            report(error)
        }
    }
}
