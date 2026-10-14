import SwiftUI
import WortschatzCore

/// The Write screen's content for the current phase: the question card, the round summary or
/// the results in a scrolling column with the floating action bar at the bottom; the message
/// screens (nothing to practise, set gone) on their own.
struct WriteStage: View {
    let controller: WriteController
    var focus: FocusState<WriteKeyRouter.Focus?>.Binding
    @Binding var selection: TextSelection?

    @State private var height: CGFloat = 748

    private var state: WriteFlow.State { controller.state }

    var body: some View {
        Group {
            switch state.phase {
            case .starting:
                // Only the "Laufende Runde beenden?" alert is shown.
                Color.clear
            case .empty, .missing:
                WriteMessageView(state: state, send: controller.send)
            case .question, .feedback, .copy, .summary, .results:
                ScrollView {
                    column
                        .frame(maxWidth: LayoutMetrics.studyColumnWidth)
                        .padding(.horizontal, Spacing.xxl)
                        .padding(.top, topInset)
                        .padding(.bottom, Spacing.xl)
                        .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    WriteActionBar(
                        state: state, countdown: controller.countdown, streak: controller.streak.current,
                        send: controller.send)
                        .reservesToastSpace()
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { ($0.size.height / 16).rounded() * 16 } action: { height = $0 }
    }

    @ViewBuilder
    private var column: some View {
        switch state.phase {
        case .question, .feedback, .copy:
            if let question = state.question {
                VStack(spacing: Spacing.m) {
                    if let note = WriteFlow.roundNote(state) {
                        WriteRoundNote(text: note)
                            .transition(.opacity)
                    }
                    WritePromptCard(controller: controller, question: question, focus: focus, selection: $selection)
                }
                .motionAnimation(Motion.gentle, value: state.phase)
            }
        case .summary:
            if let summary = state.summary {
                WriteSummaryView(summary: summary, rows: WriteFlow.summaryRows(state), counters: WriteFlow.counters(state))
                    .transition(.opacity)
            }
        case .results:
            if let results = state.results {
                WriteResultsView(results: results, hardest: WriteFlow.hardestRows(state), setCounts: controller.setCounts)
                    .transition(.opacity)
            }
        case .starting, .empty, .missing:
            EmptyView()
        }
    }

    /// The card sits a little below the toolbar in tall windows and close to it in short ones.
    private var topInset: CGFloat {
        state.phase.isCard ? LayoutMetrics.studyCardTopInset(height: height) : Spacing.xl
    }
}

/// "Runde 2 · nur die Begriffe, die noch nicht sassen" above the card from round 2 on.
private struct WriteRoundNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "arrow.trianglehead.2.clockwise")
            .font(.callout.weight(.medium))
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, 6)
            .background(Theme.accentSoft, in: Capsule(style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The message screens: nothing to practise in the requested subset, or the set is gone. The
/// primary button is the Return action ("Alle Begriffe üben", "Begriffe hinzufügen",
/// "Zur Übersicht").
struct WriteMessageView: View {
    let state: WriteFlow.State
    let send: (WriteFlow.Event) -> Void

    var body: some View {
        let message = state.phase == .missing ? WriteFlow.missingMessage : WriteFlow.emptyMessage(for: state.emptySubset ?? .all)
        CenteredScrollView {
            EmptyStateView(systemImage: message.systemImage, title: message.title, message: message.text) {
                if state.phase == .empty {
                    SecondaryButton("Zurück zum Lernset", key: .escape, bindsShortcut: false) { send(.leave) }
                }
                if let label = WriteFlow.returnAction(state) {
                    PrimaryActionButton(
                        verbatim: label, systemImage: message.primaryOpensEditor ? "plus" : nil, bindsShortcut: false
                    ) {
                        send(.proceed)
                    }
                    .accessibilityIdentifier("write-primary")
                }
            }
            .frame(maxWidth: LayoutMetrics.studyColumnWidth)
        }
    }
}
