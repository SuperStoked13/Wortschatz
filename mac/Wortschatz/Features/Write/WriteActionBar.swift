import SwiftUI
import WortschatzCore

/// The Write screen's action bar (`StudyActionBar`, like Learn's): its Return action is
/// `WriteFlow.returnAction`; the pill shows "Antwort schreiben" while a question waits and the
/// feedback (with the auto-advance countdown) after an answer.
struct WriteActionBar: View {
    let state: WriteFlow.State
    let countdown: StudyCountdown?
    /// Correct answers in a row (`WriteController.streak`).
    var streak = 0
    let send: (WriteFlow.Event) -> Void

    var body: some View {
        StudyActionBar(
            status: Self.status(for: state)?.withStreak(streak), countdown: runningCountdown,
            trigger: state.questionSerial, returnAction: WriteFlow.returnAction(state),
            primaryIdentifier: "write-primary", onProceed: { send(.proceed) }
        ) {
            secondaryActions
        }
    }

    /// The countdown of the auto-advance that is still pending. Not for the short beat after a
    /// copy is typed out (`CopyStep`): there it would only flicker.
    private var runningCountdown: StudyCountdown? {
        guard let countdown, countdown.token == state.autoAdvance?.token, state.phase != .copy else { return nil }
        return countdown
    }

    @ViewBuilder
    private var secondaryActions: some View {
        switch state.phase {
        case .question:
            SecondaryButton("Weiss ich nicht", key: .optionReturn, bindsShortcut: false) { send(.dontKnow) }
                .accessibilityIdentifier("write-dont-know")
        case .feedback(.wrong), .copy:
            if let feedback = state.feedback, feedback.canOverride {
                SecondaryButton(
                    verbatim: feedback.overrideLabel, systemImage: "checkmark", key: .commandReturn, bindsShortcut: false,
                    tint: feedback.editedCorrect ? Theme.success.fill : nil
                ) {
                    send(.override)
                }
                .accessibilityIdentifier("write-override")
            }
        case .summary:
            SecondaryButton("Zurück zum Lernset", key: .escape, bindsShortcut: false) { send(.leave) }
        case .results:
            if state.results?.canRetry == true {
                SecondaryButton("Fertig", key: .escape, bindsShortcut: false) { send(.leave) }
            }
            SecondaryButton(
                "Nochmal von vorne", systemImage: "arrow.counterclockwise", key: .shiftCommand("R"), bindsShortcut: false
            ) {
                send(.restart)
            }
        case .feedback, .starting, .empty, .missing:
            EmptyView()
        }
    }

    /// The pill for `state`, nil when there is none (summary, results).
    static func status(for state: WriteFlow.State) -> LearnStatus? {
        if state.phase == .question { return LearnStatus(kind: .typing) }
        guard let feedback = state.feedback else { return nil }
        switch state.phase {
        case .feedback(.correct):
            // "Weiter mit beliebiger Taste" while the auto-advance runs.
            let hint = state.autoAdvance != nil ? WriteFlow.returnHint(state) : nil
            return LearnStatus(kind: .correct, title: feedback.title, message: hint)
        case .feedback(.wrong):
            return LearnStatus(kind: .wrong, title: feedback.title)
        case .feedback(.dontKnow):
            return LearnStatus(kind: .dontKnow, title: feedback.title)
        case .copy:
            // "Tippe die richtige Antwort ab" labels the copy field on the card.
            return LearnStatus(kind: feedback.dontKnow ? .dontKnow : .wrong, title: feedback.title)
        case .starting, .question, .summary, .results, .empty, .missing:
            return nil
        }
    }
}
