import Foundation
import WortschatzCore

// Prüfungsmodus in the app shell: opening the exam screen of a set. An exam is never stored and
// records nothing; its settings are kept for every set (`ExamController.settingsKey`).

extension AppModel {
    /// "Prüfung" (⌃⌘L): the set's exam screen, its settings first.
    func startExam(setID: String) {
        if case let .exam(request) = route, request.setID == setID { return }
        study(.exam, setID: setID)
    }
}
