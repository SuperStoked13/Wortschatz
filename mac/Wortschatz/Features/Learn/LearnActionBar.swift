import SwiftUI
import WortschatzCore

/// The floating glass bar at the bottom of a study screen (Lernen, Schreiben). It always ends
/// with the screen's Return action (shown with the ↩ keycap), so Return is never a guess; the
/// screen's other actions sit before it. On the left sits a status pill: the key hints while a
/// question waits, the feedback after an answer, and the answer streak (🔥) from three in a row.
/// The pill and the Return button each sit in a `GlassEffectContainer` that lasts as long as the
/// bar, so the hint pill morphs into the green, red or amber feedback pill and the button
/// materializes in place (`glassEffectID`). The pill stays on screen through a question and its
/// feedback: glass that appears anew flashes white while it materializes.
///
/// The other buttons ("Weiss ich nicht?", "Ich hatte recht" …) stay outside any container: they
/// are different buttons in every phase, and a lasting container keeps the glass state of every
/// button it ever held, until the app quits: one more every few answers, 360 after five days of
/// Lernen (measured 23.11.2026). The bar looks the same as with one container, frame by frame.
struct StudyActionBar<Secondary: View>: View {
    @Environment(\.studyScale) private var studyScale
    let status: LearnStatus?
    let countdown: StudyCountdown?
    /// Changes with every step (replays the pill's bounce and shake).
    let trigger: Int
    let returnAction: String?
    let primaryIdentifier: String
    let onProceed: () -> Void
    @ViewBuilder var secondary: Secondary

    @Namespace private var glass

    var body: some View {
        // Gaps as padding, not HStack spacing: an empty container would still get its gap.
        HStack(spacing: 0) {
            GlassEffectContainer(spacing: Spacing.s) {
                if let status {
                    LearnStatusPill(status: status, countdown: countdown, trigger: trigger)
                        .glassEffectID("status", in: glass)
                }
            }
            .padding(.trailing, status == nil ? 0 : Spacing.s)
            .layoutPriority(1)
            Spacer(minLength: 0)
            // A group's modifiers apply to each button in it.
            Group { secondary }
                .padding(.leading, Spacing.s)
            GlassEffectContainer(spacing: Spacing.s) {
                if let returnAction {
                    PrimaryActionButton(verbatim: returnAction, bindsShortcut: false, action: onProceed)
                        .glassEffectID("primary", in: glass)
                        .accessibilityIdentifier(primaryIdentifier)
                        .padding(.leading, Spacing.s)
                }
            }
        }
        .frame(maxWidth: LayoutMetrics.studyColumnWidth * StudyScale.widthFactor(studyScale))
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.l)
        .frame(maxWidth: .infinity)
        .motionAnimation(Motion.spring, value: status)
        .motionAnimation(Motion.snappy, value: returnAction)
    }
}

/// The Learn screen's action bar (`StudyActionBar`): its Return action is
/// `LearnFlow.returnAction`.
struct LearnActionBar: View {
    let state: LearnFlow.State
    let countdown: StudyCountdown?
    /// Correct answers in a row (`LearnController.streak`).
    var streak = 0
    let send: (LearnFlow.Event) -> Void
    let onWrite: () -> Void

    var body: some View {
        StudyActionBar(
            status: LearnStatus(state)?.withStreak(streak), countdown: runningCountdown, trigger: state.transitions,
            returnAction: LearnFlow.returnAction(state), primaryIdentifier: "learn-primary", onProceed: { send(.proceed) }
        ) {
            secondaryActions
        }
    }

    /// The countdown of the auto-advance that is still pending. Not for the short beat after a
    /// copy is typed out (`CopyStep`): there it would only flicker.
    private var runningCountdown: StudyCountdown? {
        guard let countdown, countdown.token == state.autoAdvanceToken, state.phase != .copy else { return nil }
        return countdown
    }

    @ViewBuilder
    private var secondaryActions: some View {
        switch state.phase {
        case .question:
            SecondaryButton("Weiss ich nicht?", key: .optionReturn, bindsShortcut: false) { send(.dontKnow) }
        case .feedback(.wrong), .copy:
            if let label = LearnFlow.overrideLabel(state) {
                SecondaryButton(
                    verbatim: label, systemImage: "checkmark", key: .commandReturn, bindsShortcut: false,
                    tint: state.feedback?.editedCorrect == true ? Theme.success.fill : nil
                ) {
                    send(.override)
                }
            }
        case .checkpoint:
            SecondaryButton("Zurück zum Lernset", key: .escape, bindsShortcut: false) { send(.exit) }
        case .finished:
            SecondaryButton("Schreiben üben", systemImage: "keyboard", bindsShortcut: false, action: onWrite)
            SecondaryButton(
                "Nochmal lernen", systemImage: "arrow.counterclockwise", key: .shiftCommand("R"), bindsShortcut: false
            ) {
                send(.relearn)
            }
        case .feedback, .allMastered, .empty:
            EmptyView()
        }
    }
}

/// What the status pill shows.
struct LearnStatus: Equatable {
    enum Kind: Equatable {
        /// Key hints for a multiple-choice question with `choices` options.
        case keys(choices: Int)
        /// A written question waits for the answer.
        case typing
        case correct
        case wrong
        case dontKnow
    }

    var kind: Kind
    var title: String
    var message: String?
    /// Correct answers in a row (shown from `AnswerStreak.visibleFrom` on).
    var streak = 0

    init(kind: Kind, title: String = "", message: String? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
    }

    /// The same pill with the answer streak.
    func withStreak(_ streak: Int) -> LearnStatus {
        var status = self
        status.streak = streak
        return status
    }

    /// The pill for `state`, nil when there is none (checkpoint, finish).
    init?(_ state: LearnFlow.State) {
        switch state.phase {
        case .question(.mc):
            self.init(kind: .keys(choices: state.question?.choices.count ?? 4))
        case .question(.written):
            self.init(kind: .typing)
        case let .feedback(kind):
            guard let feedback = state.feedback else { return nil }
            switch kind {
            case .correct: self.init(kind: .correct, title: feedback.title)
            case .wrong: self.init(kind: .wrong, title: feedback.title, message: Self.demotedMessage(feedback))
            case .dontKnow: self.init(kind: .dontKnow, title: feedback.title, message: Self.demotedMessage(feedback))
            }
        case .copy:
            guard let feedback = state.feedback else { return nil }
            let copy = String(localized: "Tippe die richtige Antwort ab.")
            self.init(
                kind: feedback.kind == .dontKnow ? .dontKnow : .wrong, title: feedback.title,
                message: Self.demotedMessage(feedback).map { String(localized: "\($0). Tippe die richtige Antwort ab.") } ?? copy)
        case .checkpoint, .finished, .allMastered, .empty:
            return nil
        }
    }

    /// "Wieder am Lernen" after a missed repetition question.
    private static func demotedMessage(_ feedback: LearnFlow.Feedback) -> String? {
        feedback.demoted ? LearnFlow.DEMOTED_TEXT : nil
    }

    /// A correct answer that reached a streak milestone (5, 10, 15 … in a row).
    var isStreakMilestone: Bool {
        kind == .correct && AnswerStreak.isMilestone(streak)
    }
}

/// The bar's status pill on glass: key hints (plain glass) or the feedback (tinted glass with a
/// bouncing symbol; a wrong answer also shakes gently), with the answer streak's flame at the
/// end. A correct answer shows the auto-advance countdown along the bottom edge.
struct LearnStatusPill: View {
    let status: LearnStatus
    let countdown: StudyCountdown?
    /// Changes with every transition, replaying the symbol bounce and the shake.
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0
    @State private var shake = 0

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    var body: some View {
        HStack(spacing: Spacing.m) {
            content
            if status.streak >= AnswerStreak.visibleFrom {
                StreakBadge(count: status.streak, isMilestone: status.isStreakMilestone)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, Spacing.l)
        .padding(.vertical, Spacing.xs)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            // Drawn inside the glass: a GlassEffectContainer ignores overlays outside it.
            if let countdown {
                LearnCountdownLine(countdown: countdown, tint: palette?.fill ?? Theme.accent)
                    .padding(.horizontal, Spacing.l)
                    .padding(.bottom, 5)
            }
        }
        .glassSurface(tint: palette.map { $0.fill.opacity(0.24) }, in: shape)
        .shake(trigger: shake, amplitude: 7)
        .onAppear(perform: play)
        .onChange(of: trigger) { play() }
    }

    @ViewBuilder
    private var content: some View {
        switch status.kind {
        case let .keys(choices):
            HStack(spacing: Spacing.m) {
                HStack(spacing: 5) {
                    Keycap(.digit(1))
                    Text("–")
                    Keycap(.digit(max(1, choices)))
                    Text("wählen")
                }
                HStack(spacing: 6) {
                    Keycap(.arrows)
                    Text("markieren")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tasten 1 bis \(choices) wählen eine Antwort, die Pfeiltasten markieren eine.")
        case .typing:
            Label("Antwort schreiben", systemImage: "keyboard")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .correct, .wrong, .dontKnow:
            HStack(spacing: Spacing.s) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, palette?.fill ?? Theme.accent)
                    .symbolEffect(.bounce, options: .nonRepeating, value: bounce)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Typography.feedbackTitle)
                        .foregroundStyle(palette?.text ?? .primary)
                        .lineLimit(2)
                    if let message = status.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([accessibilityPrefix, title, status.message].compactMap(\.self).joined(separator: ". "))
        }
    }

    /// The feedback title; a streak milestone replaces the praise.
    private var title: String {
        status.isStreakMilestone ? String(localized: "\(status.streak) richtig in Folge!") : status.title
    }

    private var palette: Theme.StatusPalette? {
        switch status.kind {
        case .keys, .typing: nil
        case .correct: Theme.success
        case .wrong: Theme.failure
        case .dontKnow: Theme.warning
        }
    }

    private var symbol: String {
        switch status.kind {
        case .keys, .typing, .correct: "checkmark.circle.fill"
        case .wrong: "xmark.circle.fill"
        case .dontKnow: "lightbulb.circle.fill"
        }
    }

    private var accessibilityPrefix: String? {
        switch status.kind {
        case .keys, .typing: nil
        case .correct: String(localized: "Richtig")
        case .wrong: String(localized: "Falsch")
        case .dontKnow: String(localized: "Nicht gewusst")
        }
    }

    private func play() {
        guard !reduceMotion else { return }
        bounce += 1
        if status.kind == .wrong { shake += 1 }
    }
}

/// The answer streak in the pill: a flame and the number of correct answers in a row. It pops
/// when the number grows and the flame bounces at a milestone.
private struct StreakBadge: View {
    let count: Int
    let isMilestone: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .foregroundStyle(Theme.flame)
                .symbolEffect(.bounce, options: .nonRepeating, value: isMilestone ? count : 0)
            Text("\(count)")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 3)
        .background(Theme.flame.opacity(isMilestone ? 0.22 : 0.13), in: Capsule(style: .continuous))
        .pop(trigger: count, scale: isMilestone ? 1.12 : 1.05)
        .animation(reduceMotion ? nil : Motion.snappy, value: count)
        .help("\(count) richtig in Folge")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) richtig in Folge")
    }
}

/// A running auto-advance countdown of a study screen (Lernen, Schreiben), drawn in the
/// feedback pill.
struct StudyCountdown: Equatable {
    let token: Int
    let milliseconds: Int
    let start: Date
}

/// The auto-advance countdown: a thin line that shrinks to nothing until the next question.
private struct LearnCountdownLine: View {
    let countdown: StudyCountdown
    let tint: Color

    @Environment(\.isSnapshotRendering) private var isSnapshot

    var body: some View {
        TimelineView(.animation(paused: isSnapshot)) { context in
            let elapsed = context.date.timeIntervalSince(countdown.start) * 1000
            let remaining = isSnapshot ? 0.6 : max(0, 1 - elapsed / Double(max(1, countdown.milliseconds)))
            GeometryReader { proxy in
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.75))
                    .frame(width: proxy.size.width * remaining)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
