import SwiftUI
import WortschatzCore

/// The Learn screen's content for the current phase: the question card with its answer area,
/// the checkpoint or the finish screen in a scrolling column, and the floating action bar at
/// the bottom; the message screens (everything mastered, nothing to study) on their own.
struct LearnStage: View {
    @Environment(\.studyScale) private var studyScale
    let controller: LearnController
    var focus: FocusState<LearnKeyRouter.Focus?>.Binding
    @Binding var selection: TextSelection?
    let onEditCard: () -> Void

    @AppStorage("learn.introHintDismissed") private var introHintDismissed = false
    @State private var height: CGFloat = 748

    private var state: LearnFlow.State { controller.state }

    var body: some View {
        Group {
            switch state.phase {
            case .allMastered, .empty:
                LearnMessageView(state: state, send: controller.send, onWrite: controller.practiceWriting)
            case .question, .feedback, .copy, .checkpoint, .finished:
                ScrollView {
                    column
                        .frame(maxWidth: LayoutMetrics.studyColumnWidth * StudyScale.widthFactor(studyScale))
                        .padding(.horizontal, Spacing.xxl)
                        .padding(.top, topInset)
                        .padding(.bottom, Spacing.xl)
                        .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    LearnActionBar(
                        state: state, countdown: controller.countdown, streak: controller.streak.current,
                        send: controller.send, onWrite: controller.practiceWriting)
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
                VStack(spacing: Spacing.l) {
                    if state.showsIntroHint && !introHintDismissed {
                        LearnIntroHint { introHintDismissed = true }
                            .transition(.opacity)
                    }
                    LearnQuestionView(
                        controller: controller, question: question, focus: focus, selection: $selection,
                        onEditCard: onEditCard)
                }
                .motionAnimation(Motion.gentle, value: state.transitions)
            }
        case .checkpoint:
            if let checkpoint = state.checkpoint {
                LearnCheckpointView(
                    checkpoint: checkpoint, from: state.roundStartCounts, segments: state.segments, cards: state.cards,
                    termLang: state.termLang, defLang: state.defLang)
                    .transition(.opacity)
            }
        case .finished:
            if let stats = state.finalStats {
                LearnFinishView(
                    stats: stats, subset: state.session?.subset ?? state.subset, cards: state.cards,
                    termLang: state.termLang, defLang: state.defLang, setID: controller.setID,
                    bestStreak: controller.streak.best, review: state.session.flatMap(LearnEngine.reviewStats))
                    .transition(.opacity)
            }
        case .allMastered, .empty:
            EmptyView()
        }
    }

    /// The question sits a little below the toolbar in tall windows and close to it in short ones.
    private var topInset: CGFloat {
        switch state.phase {
        case .question, .feedback, .copy: LayoutMetrics.studyCardTopInset(height: height)
        default: Spacing.xl
        }
    }
}

// MARK: - Question

/// The prompt card and, for multiple choice, the 2×2 answer tiles.
struct LearnQuestionView: View {
    let controller: LearnController
    let question: LearnFlow.QuestionInfo
    var focus: FocusState<LearnKeyRouter.Focus?>.Binding
    @Binding var selection: TextSelection?
    let onEditCard: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: LearnFlow.State { controller.state }

    var body: some View {
        let typeAhead = LearnFlow.typeAhead(state)
        VStack(spacing: Spacing.l) {
            LearnPromptCard(
                question: question, isSpeaking: controller.speech.isSpeaking, send: controller.send, onEdit: onEditCard
            ) {
                if question.type == .written {
                    LearnWrittenSection(
                        controller: controller, question: question, focus: focus, selection: $selection,
                        onEditCard: onEditCard)
                }
            }

            if question.type == .mc {
                ZStack {
                    ChoiceGrid(
                        choices: question.choices.map(\.text),
                        lang: question.answerLang,
                        state: { ChoiceTileState(LearnFlow.optionState(state, at: $0, typeAhead: typeAhead)) },
                        emphasis: { typeAhead.ranges[$0] },
                        onChoose: { controller.send(.choose($0)) })
                    // The first question's tiles rise like every later question's.
                    .entranceShift(y: StudyEntrance.tileShift)
                    .id(question.qid)
                    .transition(questionTransition)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(String(localized: "Antworten (Mehrzahl)", defaultValue: "Antworten", comment: "Noun: the answers (not the button to answer)")))

                if typeAhead.isActive {
                    LearnTypeAheadHint(
                        typed: state.typed, typeAhead: typeAhead, choices: question.choices.map(\.text),
                        lang: question.answerLang, rejections: state.rejections
                    )
                    // Fades on its own: an outer animation would also move the tiles' answer states.
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
            }
        }
    }

    /// New tiles rise into place a moment after the old ones are gone: overlapping, their
    /// texts blurred into each other.
    private var questionTransition: AnyTransition {
        reduceMotion
            ? .answerSwap
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: StudyEntrance.tileShift))
                    .animation(Motion.gentle.delay(0.06)),
                removal: .opacity.animation(.easeOut(duration: 0.12)))
    }
}

extension ChoiceTileState {
    /// The design-system tile state for a `LearnFlow` option state.
    init(_ option: LearnFlow.OptionState) {
        switch option {
        case .idle: self = .idle
        case .highlighted: self = .highlighted
        case .filtered: self = .filtered
        case .correct: self = .correct
        case .wrong: self = .wrong
        case .dimmed: self = .dimmed
        }
    }
}

// MARK: - Typing on multiple choice

/// Below the answer tiles while letters are typed: the letters, what Return does with them
/// ("↩ wählt «la voiture»", "Weiter tippen …", "Keine Antwort passt") and how to correct them
/// (⌫, esc). Shakes when Return finds no answer to choose.
private struct LearnTypeAheadHint: View {
    let typed: String
    let typeAhead: LearnFlow.TypeAhead
    let choices: [String]
    let lang: Lang
    let rejections: Int

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(LearnText.spoken(typed, lang: lang))
                .fontWeight(.semibold)
                .foregroundStyle(typeAhead.matching.isEmpty ? Theme.failure.text : .primary)
                .lineLimit(1)
                .truncationMode(.head)
            if let selected = typeAhead.selected, choices.indices.contains(selected) {
                Keycap(.returnKey, size: .small)
                Text(AttributedString(localized: "wählt «\(LearnText.spoken(choices[selected], lang: lang))»"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(typeAhead.matching.isEmpty ? "Keine Antwort passt" : "Weiter tippen …")
                    .foregroundStyle(.secondary)
            }
            Text("⌫ korrigiert · esc löscht")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .background(.quaternary.opacity(0.6), in: Capsule(style: .continuous))
        .shake(trigger: rejections, amplitude: 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Intro hint

/// "Neue Begriffe kommen zuerst als Multiple Choice …" until the first checkpoint, closable.
private struct LearnIntroHint: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .accessibilityHidden(true)
            Text(LearnFlow.INTRO_HINT)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.xs)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Hinweis schliessen")
            .accessibilityLabel("Hinweis schliessen")
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, Spacing.xs)
        .padding(.vertical, Spacing.xs)
        .background(Theme.accentSoft, in: Capsule(style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
