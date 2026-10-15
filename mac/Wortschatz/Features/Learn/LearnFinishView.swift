import SwiftUI
import WortschatzCore

/// The finish screen (spec §4.4): trophy with a confetti burst (a soft glow under Reduce
/// Motion), "Du hast alle Begriffe gemeistert!", the statistics as glass tiles and the cards
/// missed most often. Fertig ↩, Nochmal lernen and Schreiben üben are in the action bar.
struct LearnFinishView: View {
    let stats: LearnEngine.FinalStats
    let subset: StudySubset
    let cards: [Card]
    let termLang: Lang
    let defLang: Lang
    /// The longest run of correct answers while the screen was open (`AnswerStreak.best`).
    var bestStreak = 0
    /// The repetition questions of the session, if it had them.
    var review: LearnEngine.ReviewStats?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    var body: some View {
        VStack(spacing: Spacing.xl) {
            VStack(spacing: Spacing.s) {
                ZStack {
                    Circle()
                        .fill(Theme.accent.gradient)
                        .frame(width: 92, height: 92)
                        .shadow(color: Theme.accent.opacity(0.35), radius: 16, y: 6)
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, options: .nonRepeating, value: bounce)
                }
                .padding(.bottom, Spacing.xs)
                .accessibilityHidden(true)

                Text(LearnFlow.finishTitle(subset, total: stats.total))
                    .font(Typography.display)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(LearnFlow.finishSubtitle(stats, subset: subset))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            Grid(horizontalSpacing: Spacing.s, verticalSpacing: Spacing.s) {
                GridRow {
                    StatTile(stats.total == 1 ? "Begriff" : "Begriffe", value: "\(stats.total)", systemImage: "square.stack.3d.up.fill")
                    StatTile(
                        stats.rounds == 1 ? "Runde" : "Runden", value: "\(stats.rounds)",
                        systemImage: "arrow.trianglehead.2.clockwise", tint: Theme.info.fill)
                    StatTile(
                        stats.answered == 1 ? "Antwort" : "Antworten", value: "\(stats.answered)",
                        systemImage: "text.bubble.fill", tint: Theme.learning.fill)
                    StatTile("Treffer", value: WriteFlow.percentText(stats.accuracy), systemImage: "target", tint: Theme.success.fill)
                    let time = WriteFlow.compactDuration(stats.elapsedMs)
                    StatTile(time.label, value: time.value, systemImage: "clock.fill", tint: Theme.flame)
                }
            }

            if bestStreak >= AnswerStreak.visibleFrom {
                Label("Beste Serie: \(bestStreak) richtig in Folge", systemImage: "flame.fill")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Theme.flame)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(Theme.flame.opacity(0.12), in: Capsule(style: .continuous))
            }

            if let review, let line = LearnFlow.reviewLine(review) {
                Label(line, systemImage: "arrow.counterclockwise")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Theme.mastered.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(Theme.mastered.soft, in: Capsule(style: .continuous))
            }

            if hardestRows.isEmpty {
                Label("Kein einziger Fehler – beeindruckend!", systemImage: "sparkles")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Theme.accentText)
                    .padding(.top, Spacing.xs)
            } else {
                LearnTermList(title: "Am häufigsten falsch", rows: hardestRows, termLang: termLang, defLang: defLang)
            }
        }
        .celebration(origin: UnitPoint(x: 0.5, y: 0.1))
        .onAppear {
            if !reduceMotion { bounce += 1 }
        }
    }

    private var hardestRows: [LearnTermList.Row] {
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return stats.hardest.compactMap { missed in
            guard let card = byID[missed.cardId] else { return nil }
            return LearnTermList.Row(
                id: missed.cardId, term: card.term, definition: card.definition, trailing: .misses(missed.misses))
        }
    }
}

/// The message screens: everything in scope is mastered already, or there is nothing to study.
/// The primary button is the Return action ("Fortschritt zurücksetzen und neu lernen",
/// "Begriffe hinzufügen", "Alle Begriffe üben").
struct LearnMessageView: View {
    let state: LearnFlow.State
    let send: (LearnFlow.Event) -> Void
    let onWrite: () -> Void

    var body: some View {
        if let message = LearnFlow.message(state) {
            CenteredScrollView {
                EmptyStateView(systemImage: message.systemImage, title: message.title, message: message.text) {
                    // One row when it fits; else the primary action under the others.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.s) {
                            secondaryActions(message)
                            primaryAction
                        }
                        VStack(spacing: Spacing.s) {
                            HStack(spacing: Spacing.s) { secondaryActions(message) }
                            primaryAction
                        }
                    }
                }
                .frame(maxWidth: LayoutMetrics.studyColumnWidth)
            }
        }
    }

    @ViewBuilder
    private func secondaryActions(_ message: LearnFlow.MessageContent) -> some View {
        SecondaryButton("Zurück zum Lernset", key: .escape, bindsShortcut: false) { send(.exit) }
        if message.offersWrite {
            SecondaryButton("Schreiben üben", systemImage: "keyboard", bindsShortcut: false, action: onWrite)
        }
        if message.offersReview {
            SecondaryButton("Alle wiederholen", systemImage: "arrow.counterclockwise", bindsShortcut: false) {
                send(.startReview)
            }
            .help("Jeden gemeisterten Begriff einmal abfragen. Was falsch ist, lernst du neu.")
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let label = LearnFlow.returnAction(state) {
            PrimaryActionButton(verbatim: label, bindsShortcut: false) { send(.proceed) }
        }
    }
}
