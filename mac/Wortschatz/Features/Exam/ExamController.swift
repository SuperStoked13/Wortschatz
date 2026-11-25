import AppKit
import Observation
import SwiftUI
import WortschatzCore

/// Runs one exam screen (Prüfungsmodus): the settings ("Prüfung einrichten"), the sheet with
/// every question on one page and its time limit, and the marked result with a Swiss grade.
/// An exam records nothing: mastery stays with Lernen and Schreiben, and the result offers to
/// learn the words that went wrong.
///
/// The view only renders the published state and calls the actions.
@MainActor
@Observable
final class ExamController {
    enum Phase: Equatable {
        case setup, running, results
    }

    let setID: String
    private(set) var set: VocabSet
    private(set) var phase: Phase = .setup
    /// The settings, the same for every set (`UserDefaults`, `settingsKey`).
    private(set) var settings: ExamSettings
    /// A retake asks only these cards (the ones to practise after the last exam).
    private(set) var retakeCardIDs: [String]?
    private(set) var questions: [ExamQuestion] = []
    /// The answers by question number.
    private(set) var answers: [Int: String] = [:]
    private(set) var startedAt: Date?
    /// When the time runs out (nil without a time limit).
    private(set) var deadline: Date?
    private(set) var result: ExamResult?
    /// Grows with every new sheet (the timer of an earlier sheet then does nothing).
    private(set) var sheetID = 0

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let requestID: UUID
    @ObservationIgnored private let rng: RNG
    @ObservationIgnored private let clock: () -> Date
    /// Off for the snapshot harness: no timers, sounds or announcements.
    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var timer: Task<Void, Never>?

    /// `UserDefaults` key of the settings (JSON of `ExamSettings`).
    static let settingsKey = "exam.settings"

    private var store: LibraryStore { model.store }

    /// `settings`: instead of the stored ones (snapshots); they are then not stored either.
    init(
        model: AppModel,
        request: StudyRequest,
        settings: ExamSettings? = nil,
        rng: @escaping RNG = systemRNG(),
        clock: @escaping () -> Date = { Date() },
        isLive: Bool = true
    ) {
        self.model = model
        self.rng = rng
        self.clock = clock
        self.isLive = isLive
        requestID = request.id
        setID = request.setID
        set = model.store.getSet(request.setID) ?? VocabSet(id: request.setID, title: "", createdAt: 0)
        self.settings = settings ?? Self.storedSettings()
        storesSettings = settings == nil
    }

    /// The settings are kept in `UserDefaults` (not for snapshots).
    @ObservationIgnored private let storesSettings: Bool

    // MARK: Reading

    /// The cards the next exam can ask (with the starred-only setting and a retake applied).
    var scope: [Card] {
        Exam.scope(set.cards, settings: settings, cardIds: retakeCardIDs)
    }

    /// How many questions the next exam asks.
    var plannedCount: Int {
        retakeCardIDs != nil ? scope.count : Exam.questionCount(settings, available: scope.count)
    }

    var starredCount: Int {
        Exam.scope(set.cards, settings: ExamSettings()).count { $0.starred }
    }

    /// The set has no card with both sides filled in.
    var isEmpty: Bool { Exam.scope(set.cards, settings: ExamSettings()).isEmpty }

    var answeredCount: Int {
        questions.count { LearnText.hasText(answers[$0.number] ?? "") }
    }

    /// Whether the screen is the one being studied (not one dissolving after it was left).
    private var isCurrent: Bool {
        !isLive || model.route.study?.id == requestID
    }

    // MARK: Lifecycle

    /// The screen appeared: from now on the route shows this screen again, and leaving it while
    /// an exam with answers runs asks first, whichever way it is left (`AppModel.studyLeaveGuard`).
    func activate() {
        model.studySessionStarted(requestID: requestID)
        guard isLive else { return }
        SoundEffects.shared.prepare()
        model.studyLeaveGuard = AppModel.StudyLeaveGuard(requestID: requestID) { [weak self] leave in
            self?.askBeforeLeaving(leave) ?? false
        }
    }

    /// The screen went away: the timer stops (an exam is not kept).
    func deactivate() {
        timer?.cancel()
        timer = nil
        if model.studyLeaveGuard?.requestID == requestID { model.studyLeaveGuard = nil }
    }

    // MARK: Settings

    func update(_ change: (inout ExamSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        if storesSettings, let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    private static func storedSettings() -> ExamSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
            let settings = try? JSONDecoder().decode(ExamSettings.self, from: data)
        else { return .default }
        return settings
    }

    // MARK: The exam

    /// "Prüfung starten": a new sheet, the clock starts.
    func start() {
        guard isCurrent, phase != .running else { return }
        let sheet = Exam.makeQuestions(
            cards: set.cards, settings: settings, termLang: set.termLang, defLang: set.defLang, cardIds: retakeCardIDs,
            rng: rng)
        guard !sheet.isEmpty else { return }
        questions = sheet
        answers = [:]
        result = nil
        sheetID += 1
        let now = clock()
        startedAt = now
        deadline = settings.minutes > 0 ? now.addingTimeInterval(TimeInterval(settings.minutes * 60)) : nil
        withAnimation(Motion.animation(Motion.soft(0.42), reduceMotion: StudyEntrance.reducesMotion)) {
            phase = .running
        }
        startTimer()
        if isLive {
            Announcer.announce(
                settings.minutes > 0
                    ? String(
                        localized:
                            "Prüfung gestartet: \(Labels.plural(sheet.count, "Frage", "Fragen")), \(ExamCopy.minutes(settings.minutes)).")
                    : String(localized: "Prüfung gestartet: \(Labels.plural(sheet.count, "Frage", "Fragen")).")
            )
        }
    }

    func setAnswer(_ text: String, for number: Int) {
        guard phase == .running else { return }
        answers[number] = text
    }

    /// "Abgeben" (⌘↩): asks first while questions are still open.
    func requestSubmit() {
        guard isCurrent, phase == .running else { return }
        let open = questions.count - answeredCount
        guard open > 0 else {
            submit()
            return
        }
        model.confirm(ConfirmationRequest(
            title: String(localized: "Prüfung abgeben?"),
            message: open == 1
                ? String(localized: "Eine Frage ist noch offen. Sie zählt als falsch.")
                : String(localized: "\(open) Fragen sind noch offen. Sie zählen als falsch."),
            confirmLabel: String(localized: "Abgeben")
        ) { [weak self] in
            self?.submit()
        })
    }

    /// Marks the sheet and shows the result.
    func submit(timedOut: Bool = false) {
        guard phase == .running else { return }
        timer?.cancel()
        timer = nil
        // Handed in by the timer while the learner may be typing: a Return meant for the next
        // question must not press "Fertig" and throw the result away unseen.
        if timedOut { KeyActionGate.hold(for: .milliseconds(1200)) }
        let elapsed = startedAt.map { clock().timeIntervalSince($0) * 1000 } ?? 0
        let marked = Exam.evaluate(
            questions, answers: answers, cards: set.cards, tolerance: settings.tolerance, elapsedMs: elapsed,
            timedOut: timedOut)
        result = marked
        withAnimation(Motion.animation(Motion.soft(0.42), reduceMotion: StudyEntrance.reducesMotion)) {
            phase = .results
        }
        guard isLive else { return }
        let passed = Exam.passes(marked.grade)
        passed ? Haptics.success() : Haptics.failure()
        SoundEffects.shared.play(passed ? .finished : .roundDone)
        if timedOut {
            model.toasts.show(
                String(localized: "Die Zeit ist um. Deine Prüfung wurde abgegeben."), tone: .warning,
                systemImage: "clock.badge.exclamationmark")
        }
        Announcer.announce(String(localized: "Note \(Exam.gradeText(marked.grade)). \(ExamCopy.scoreLine(marked))."))
    }

    /// "Falsche nochmals prüfen": a new sheet with only the words to practise.
    func retakeMistakes() {
        guard isCurrent, let result, !result.cardIdsToPractise.isEmpty else { return }
        retakeCardIDs = result.cardIdsToPractise
        start()
    }

    /// "Neue Prüfung" (⇧⌘R): back to the settings; a running exam ends after asking.
    func requestNewExam() {
        guard isCurrent else { return }
        guard phase == .running, answeredCount > 0 else {
            newExam()
            return
        }
        model.confirm(ConfirmationRequest(
            title: String(localized: "Prüfung beenden?"),
            message: String(localized: "Die Prüfung wird nicht bewertet, deine Antworten gehen verloren."),
            confirmLabel: String(localized: "Beenden"), isDestructive: true
        ) { [weak self] in
            self?.newExam()
        })
    }

    private func newExam() {
        timer?.cancel()
        timer = nil
        retakeCardIDs = nil
        withAnimation(Motion.animation(Motion.soft(0.42), reduceMotion: StudyEntrance.reducesMotion)) {
            phase = .setup
        }
    }

    /// "Falsche lernen": a Learn session with the words to practise. Words Lernen counts as
    /// mastered are asked again too (`reviewMastered`): the exam just found them wrong.
    func learnMistakes() {
        guard isCurrent, let ids = result?.cardIdsToPractise, !ids.isEmpty else { return }
        model.startLearn(setID: setID, subset: .cardIds(ids), reviewMastered: true)
    }

    /// Back to the set (esc, "Fertig"); a running exam with answers ends after asking
    /// (`askBeforeLeaving`, through the navigation).
    func exit() {
        guard isCurrent else { return }
        model.finishStudy()
    }

    /// Leaving while an exam with answers runs: asks first and returns true; `leave` runs once
    /// confirmed. Anything else leaves at once (false).
    private func askBeforeLeaving(_ leave: @escaping () -> Void) -> Bool {
        guard phase == .running, answeredCount > 0 else { return false }
        model.confirm(ConfirmationRequest(
            title: String(localized: "Prüfung beenden?"),
            message: String(localized: "Die Prüfung wird nicht bewertet, deine Antworten gehen verloren."),
            confirmLabel: String(localized: "Beenden"), isDestructive: true
        ) { [weak self] in
            self?.deactivate()
            leave()
        })
        return true
    }

    /// "Begriffe hinzufügen" on an empty set.
    func addCards() {
        model.openEditor(.edit(setID: setID))
    }

    // MARK: Menu

    /// A Lernen menu command (⇧⌘R, esc).
    func handle(_ command: StudyCommand) {
        guard isCurrent else { return }
        let event = NSApp.currentEvent
        if event?.type == .keyDown, event?.isARepeat == true { return }
        switch command {
        case .restart: requestNewExam()
        case .exit: exit()
        case .override, .dontKnow, .options, .speak, .toggleStar: break
        }
    }

    /// What the Lernen menu offers now (`isCovered`: an alert or sheet is open).
    func enabledCommands(isCovered: Bool) -> Set<StudyCommand> {
        guard !isCovered else { return [] }
        return phase == .setup ? [.exit] : [.exit, .restart]
    }

    // MARK: Store

    /// The library changed (set editor, another window): the settings page and the result follow
    /// the set; a running sheet keeps the texts it was asked with.
    func storeDidChange() {
        guard let newSet = store.getSet(setID), newSet != set else { return }
        set = newSet
    }

    // MARK: Time

    private func startTimer() {
        timer?.cancel()
        timer = nil
        guard isLive, let deadline else { return }
        let sheet = sheetID
        timer = Task { [weak self] in
            let total = deadline.timeIntervalSinceNow
            // A minute before the end, once (only on exams longer than two minutes).
            if total > 120 {
                try? await Task.sleep(for: .seconds(total - 60))
                guard !Task.isCancelled, let self, sheetID == sheet, phase == .running, isCurrent else { return }
                model.toasts.show(String(localized: "Noch eine Minute"), tone: .warning, systemImage: "clock")
                Announcer.announce(String(localized: "Noch eine Minute"))
            }
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            // Not after the screen was left (it dissolves for a moment): no sound or toast there.
            guard !Task.isCancelled, let self, sheetID == sheet, isCurrent else { return }
            submit(timedOut: true)
        }
    }
}
