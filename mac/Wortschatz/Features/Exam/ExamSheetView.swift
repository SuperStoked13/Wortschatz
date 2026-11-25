import SwiftUI
import WortschatzCore

/// The exam sheet: every question on one page, numbered, each with its answer field. ↩ moves to
/// the next question, ⌘↩ hands the exam in. The accents of the focused question's language float
/// above the bar.
struct ExamSheetView: View {
    let controller: ExamController
    var focus: FocusState<Int?>.Binding

    /// The caret of the focused answer (one at a time), for the accent buttons.
    @State private var selection: TextSelection?
    @State private var isWide = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    intro
                        .id(0)
                    ContentPanel(padding: 0, cornerRadius: Radii.panel) {
                        VStack(spacing: 0) {
                            ForEach(controller.questions) { question in
                                if question.number > 1 {
                                    Divider()
                                        .padding(.leading, Spacing.l + 34 + Spacing.m)
                                }
                                row(question, proxy: proxy)
                                    .id(question.number)
                            }
                        }
                        // The focused row's band follows the panel's corners.
                        .clipShape(RoundedRectangle(cornerRadius: Radii.panel, style: .continuous))
                    }
                }
                .frame(maxWidth: LayoutMetrics.studyColumnWidth)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.xl)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: Bool.self) { $0.size.width >= 640 } action: { isWide = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: Spacing.xs) {
                accents
                ExamBar {
                    ExamBarPill {
                        HStack(spacing: Spacing.s) {
                            Text("\(controller.answeredCount) von \(controller.questions.count) beantwortet")
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            WriteProgressLine(
                                value: controller.questions.isEmpty
                                    ? 0 : Double(controller.answeredCount) / Double(controller.questions.count),
                                tint: Theme.accent
                            )
                            .frame(width: 80)
                        }
                        .motionAnimation(Motion.snappy, value: controller.answeredCount)
                    }
                } trailing: {
                    PrimaryActionButton("Abgeben", systemImage: "checkmark", key: .commandReturn) {
                        controller.requestSubmit()
                    }
                    .accessibilityIdentifier("exam-submit")
                }
            }
            .reservesToastSpace()
        }
        .onAppear(perform: focusFirst)
        .onChange(of: focus.wrappedValue) { selection = nil }
    }

    // MARK: Parts

    /// "20 Fragen · Antworten auf Französisch" and the keys.
    private var intro: some View {
        HStack(spacing: Spacing.m) {
            Label(introText, systemImage: "list.number")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.s)
            HStack(spacing: 6) {
                Keycap(.returnKey, size: .small)
                Text("nächste Frage")
                Keycap(.commandReturn, size: .small)
                    .padding(.leading, Spacing.xs)
                Text("abgeben")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, Spacing.xs)
    }

    private var introText: String {
        let count = Labels.plural(controller.questions.count, "Frage", "Fragen")
        let langs = Set(controller.questions.map(\.answerLang))
        guard langs.count == 1, let lang = langs.first, lang != .other,
            controller.set.termLang != controller.set.defLang
        else { return count }
        return String(localized: "\(count) · Antworten auf \(Labels.langName(lang))")
    }

    private func row(_ question: ExamQuestion, proxy: ScrollViewProxy) -> some View {
        let isFocused = focus.wrappedValue == question.number
        return ExamQuestionRow(
            question: question,
            answer: controller.answers[question.number] ?? "",
            selectionShown: isFocused ? selection : nil,
            isFocused: isFocused,
            text: Binding(
                get: { controller.answers[question.number] ?? "" },
                set: { controller.setAnswer($0, for: question.number) }),
            selection: Binding(
                get: { focus.wrappedValue == question.number ? selection : nil },
                set: { if focus.wrappedValue == question.number { selection = $0 } }),
            focus: focus,
            promptLabel: promptLabel(question),
            placeholder: placeholder(question),
            isWide: isWide,
            onEscape: controller.exit
        ) {
            // ↩: on to the next question (the last one keeps the keys).
            let next = question.number + 1
            guard controller.questions.contains(where: { $0.number == next }) else { return }
            focus.wrappedValue = next
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(next) }
        }
        // Only the row whose answer, caret or focus changed is rebuilt, not every row per key.
        .equatable()
    }

    /// The accent buttons of the focused answer's language, floating over the bar.
    @ViewBuilder
    private var accents: some View {
        if let number = focus.wrappedValue,
            let question = controller.questions.first(where: { $0.number == number }),
            !SpecialCharacters.characters(for: question.answerLang).isEmpty
        {
            GlassPanel(padding: Spacing.s, cornerRadius: 16) {
                SpecialCharacterBar(lang: question.answerLang) { insert($0, into: number) }
            }
            .frame(maxWidth: LayoutMetrics.studyColumnWidth - 2 * Spacing.xxl)
            .padding(.horizontal, Spacing.xxl)
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }

    /// Not while an input method composes in the field (its marked text is not in the answer yet).
    private func insert(_ character: String, into number: Int) {
        guard !LearnKeyRouter.isComposingText else { return }
        var text = controller.answers[number] ?? ""
        var caret = selection
        SpecialCharacters.insert(character, into: &text, selection: &caret)
        controller.setAnswer(text, for: number)
        selection = caret
        if focus.wrappedValue != number { focus.wrappedValue = number }
    }

    private func focusFirst() {
        guard let first = controller.questions.first?.number else { return }
        Task { @MainActor in focus.wrappedValue = first }
    }

    // MARK: Texts

    /// "Französisch", or "Begriff"/"Definition" when both sides share a language.
    private func promptLabel(_ question: ExamQuestion) -> String {
        let set = controller.set
        if set.termLang == set.defLang || question.promptLang == .other {
            return question.ask == .term ? String(localized: "Definition") : String(localized: "Begriff")
        }
        return Labels.langName(question.promptLang)
    }

    private func placeholder(_ question: ExamQuestion) -> String {
        let set = controller.set
        if set.termLang == set.defLang || question.answerLang == .other { return String(localized: "Antwort") }
        return String(localized: "Auf \(Labels.langName(question.answerLang)) …")
    }
}

/// One question of the sheet: its number, the prompt and the answer field; side by side in wide
/// windows, one under the other in narrow ones. Equatable on what it shows (`answer`,
/// `selectionShown`, `isFocused` …), so typing in one field leaves the other rows alone; the
/// bindings and actions read the live values.
private struct ExamQuestionRow: View, Equatable {
    let question: ExamQuestion
    /// The answer as typed (`text` reads the same, live).
    let answer: String
    /// The caret, for the focused row only (`selection` reads the same, live).
    let selectionShown: TextSelection?
    let isFocused: Bool
    @Binding var text: String
    @Binding var selection: TextSelection?
    var focus: FocusState<Int?>.Binding
    let promptLabel: String
    let placeholder: String
    let isWide: Bool
    /// esc: the field editor would swallow it before the Lernen menu's "Beenden" sees it.
    let onEscape: () -> Void
    let onSubmit: () -> Void

    private var isAnswered: Bool { LearnText.hasText(answer) }

    static func == (a: Self, b: Self) -> Bool {
        a.question == b.question && a.answer == b.answer && a.selectionShown == b.selectionShown
            && a.isFocused == b.isFocused && a.promptLabel == b.promptLabel && a.placeholder == b.placeholder
            && a.isWide == b.isWide
    }

    var body: some View {
        let layout =
            isWide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.l))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s))
        HStack(alignment: .top, spacing: Spacing.m) {
            ExamNumberBadge(number: question.number, isAnswered: isAnswered, isFocused: isFocused)
            layout {
                VStack(alignment: .leading, spacing: Spacing.xxs + 2) {
                    Text(promptLabel)
                        .eyebrowStyle()
                        .accessibilityHidden(true)
                    Text(LearnText.spoken(question.prompt, lang: question.promptLang))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .cardTextDirection(question.promptLang)
                        .accessibilityLabel(
                            Text(
                                AttributedString(String(localized: "Frage \(question.number), \(promptLabel): "))
                                    + LearnText.spoken(question.prompt, lang: question.promptLang)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                field
                    .frame(width: isWide ? 290 : nil)
                    .frame(maxWidth: isWide ? nil : .infinity)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .background {
            if isFocused {
                Theme.accentSoft.opacity(0.5)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return TextField("Antwort \(question.number)", text: $text, selection: $selection, prompt: Text(placeholder))
            .textFieldStyle(.plain)
            .font(Typography.answer)
            .cardFieldDirection(question.answerLang)
            .autocorrectionDisabled()
            .writingToolsBehavior(.disabled)
            .focused(focus, equals: question.number)
            .onSubmit(onSubmit)
            .onKeyPress(.escape, phases: .down) { _ in
                guard !LearnKeyRouter.isComposingText else { return .ignored }
                onEscape()
                return .handled
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs + 2)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.72), in: shape)
            .overlay {
                shape.strokeBorder(isFocused ? Theme.accent : Theme.hairline, lineWidth: isFocused ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .animation(Motion.snappy, value: isFocused)
            .accessibilityLabel("Antwort zu Frage \(question.number)")
            .accessibilityIdentifier("exam-answer-\(question.number)")
    }
}

/// The question's number in a circle, filled once it is answered.
private struct ExamNumberBadge: View {
    let number: Int
    let isAnswered: Bool
    let isFocused: Bool

    var body: some View {
        Text("\(number)")
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isAnswered ? AnyShapeStyle(.white) : AnyShapeStyle(isFocused ? Theme.accentText : .secondary))
            .frame(width: 34, height: 34)
            .background {
                Circle()
                    .fill(isAnswered ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Theme.accentSoft.opacity(isFocused ? 1 : 0.6)))
            }
            .padding(.top, 2)
            .animation(Motion.snappy, value: isAnswered)
            .accessibilityHidden(true)
    }
}

