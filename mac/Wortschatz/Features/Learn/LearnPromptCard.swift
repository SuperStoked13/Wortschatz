import SwiftUI
import WortschatzCore

/// The study card (glass): the prompt's language, the prompt in large rounded type, the tools
/// 🔊 (⌘R), ★ (⌘D) and ✎ (⌘E), and below it the written answer area.
struct LearnPromptCard<Answer: View>: View {
    @Environment(\.studyScale) private var studyScale
    let question: LearnFlow.QuestionInfo
    let speech: SpeechService
    let send: (LearnFlow.Event) -> Void
    let onEdit: () -> Void
    @ViewBuilder var answer: Answer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassCard(padding: Spacing.xl + Spacing.xxs) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .center, spacing: Spacing.s) {
                    Text(question.promptLabel)
                        .eyebrowStyle()
                        .accessibilityHidden(true)
                    if question.isReview {
                        LearnReviewChip()
                    } else if question.isRecheck {
                        LearnRecheckChip()
                    }
                    Spacer(minLength: Spacing.s)
                    tools
                }
                ZStack(alignment: .leading) {
                    // Long words shrink a little, then break at syllables (`LongWordText`).
                    LongWordText(
                        text: question.prompt, lang: question.promptLang, size: Typography.promptSize(for: question.prompt) * studyScale)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .cardTextLine(question.promptLang)
                        // The first question glides in like every later one.
                        .entranceShift(x: StudyEntrance.promptShift)
                        .id(question.qid)
                        .transition(promptTransition)
                        .accessibilityLabel(Text(LearnText.labeled(question.promptLabel, question.prompt, lang: question.promptLang)))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("learn-prompt")
                }
                .padding(.bottom, Spacing.xxs)
                answer
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tools: some View {
        HStack(spacing: Spacing.xxs) {
            LearnIconButton(
                label: String(localized: "Vorlesen"), help: String(localized: "Vorlesen (⌘R)"), systemImage: "speaker.wave.2.fill"
            ) {
                send(.speakPrompt)
            }
            .modifier(SpeakingWaves(speech: speech))

            LearnIconButton(
                label: question.starred ? String(localized: "Markierung entfernen") : String(localized: "Markieren"),
                help: question.starred ? String(localized: "Markierung entfernen (⌘D)") : String(localized: "Markieren (⌘D)"),
                systemImage: question.starred ? "star.fill" : "star",
                tint: question.starred ? Theme.star : nil
            ) {
                send(.toggleStar)
            }
            .symbolEffect(.bounce, options: .nonRepeating, value: question.starred)

            // ⌘E wins over the Lernset menu's ⌘E while a card is on screen: it edits this card.
            LearnIconButton(
                label: String(localized: "Karte bearbeiten"), help: String(localized: "Karte bearbeiten (⌘E)"),
                systemImage: "square.and.pencil", shortcut: KeyboardShortcut("e", modifiers: .command)
            ) {
                onEdit()
            }
        }
    }

    private var promptTransition: AnyTransition {
        .promptSwap(reduceMotion: reduceMotion)
    }
}

/// "↺ Wiederholung" next to the prompt's language: a card mastered before the session is asked
/// again (Wiederholungsfragen), in the colour of "Gemeistert".
struct LearnReviewChip: View {
    var body: some View {
        TintedChip(text: LearnFlow.REVIEW_LABEL, systemImage: "arrow.counterclockwise", palette: Theme.mastered, size: .small)
            .help("Diesen Begriff hast du schon gemeistert. Ist deine Antwort falsch, ist er wieder am Lernen.")
            .accessibilityLabel("Wiederholungsfrage")
    }
}

/// "Nachkontrolle" next to the prompt's language: a card missed earlier in the session comes back
/// once more after it was mastered (Nachkontrolle nach Fehlern), in the colour of "Am Lernen".
struct LearnRecheckChip: View {
    var body: some View {
        TintedChip(text: LearnFlow.RECHECK_LABEL, systemImage: "arrow.trianglehead.2.clockwise", palette: Theme.learning, size: .small)
            .help(LearnFlow.RECHECK_HELP)
            .accessibilityLabel(LearnFlow.RECHECK_LABEL)
    }
}

/// A round, borderless icon button for the card tools, with a hover highlight.
struct LearnIconButton: View {
    let label: String
    let help: String
    let systemImage: String
    var tint: Color?
    var shortcut: KeyboardShortcut?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .frame(width: 32, height: 32)
                .background {
                    Circle().fill(Color.primary.opacity(isHovered ? 0.08 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shortcut(shortcut)
        .onHover { isHovered = $0 }
        .animation(Motion.snappy, value: isHovered)
        .help(help)
        .accessibilityLabel(label)
    }
}

// MARK: - Written answer

/// The written answer area inside the card: the answer field with the special characters while
/// asking, the typed answer after a correct one, and "Deine Antwort" / "Richtige Antwort" (plus
/// the copy field) after a miss.
struct LearnWrittenSection: View {
    let controller: LearnController
    let question: LearnFlow.QuestionInfo
    var focus: FocusState<LearnKeyRouter.Focus?>.Binding
    @Binding var selection: TextSelection?
    let onEditCard: () -> Void

    private var state: LearnFlow.State { controller.state }

    var body: some View {
        // The steps take each other's place in one spot (the old one gone before the new one
        // fades in): stacked, the card first grew by both and then jumped back.
        ZStack(alignment: .topLeading) {
            switch state.phase {
            case .question(.written), .feedback(.correct):
                // One branch for both steps, so a correct answer turns the field green where it
                // stands and the next question turns it back.
                let correct = state.phase == .feedback(.correct) ? state.feedback : nil
                VStack(alignment: .leading, spacing: Spacing.s) {
                    answerBox(copy: false, correctAnswer: correct.map { LearnText.spoken($0.given, lang: question.answerLang) })
                    ZStack(alignment: .topLeading) {
                        if let correct {
                            if LearnCorrectDetails.hasContent(correct) {
                                LearnCorrectDetails(feedback: correct, answerLang: question.answerLang)
                                    .transition(.answerSwap)
                            }
                        } else {
                            SpecialCharacterBar(lang: question.answerLang, onInsert: insert)
                                .transition(.answerSwap)
                        }
                    }
                }
                .transition(.answerSwap)
            case .feedback(.wrong), .feedback(.dontKnow), .copy:
                if let feedback = state.feedback {
                    LearnMissDetails(
                        feedback: feedback, question: question, onSpeak: controller.speak, onEdit: onEditCard
                    ) {
                        if state.phase == .copy {
                            VStack(alignment: .leading, spacing: Spacing.s) {
                                answerBox(copy: true)
                                SpecialCharacterBar(lang: question.answerLang, onInsert: insert)
                            }
                        }
                    }
                    .transition(.answerSwap)
                }
            default:
                EmptyView()
            }
        }
    }

    /// The answer (or copy) field in its box; after a correct answer the box shows what was
    /// typed, in green, in the field's place.
    private func answerBox(copy: Bool, correctAnswer: AttributedString? = nil) -> some View {
        let wantsFocus = LearnKeyRouter.focus(for: state) == .answer
        return StudyAnswerBox(
            correctAnswer: correctAnswer,
            lang: question.answerLang,
            // Ringed as soon as the step wants the keys there, not only once AppKit has moved
            // them (a few frames later): the ring no longer flickers in after the field.
            isActive: wantsFocus || focus.wrappedValue == .answer,
            rejections: state.rejections,
            isChecking: controller.isCheckingSynonym && !copy
        ) {
            LearnAnswerField(
                text: Binding(get: { controller.draft }, set: { controller.send(.draftChanged($0)) }),
                selection: $selection,
                isCopy: copy,
                lang: question.answerLang,
                placeholder: copy ? String(localized: "Richtige Antwort abtippen") : question.placeholder,
                focus: focus,
                wantsFocus: wantsFocus,
                focusKey: "\(question.qid)|\(copy ? "copy" : "answer")",
                onSubmit: controller.submitFromField,
                onKey: controller.press)
        }
    }

    /// The special-character bar inserts at the caret (or replaces the selection); not while an
    /// input method composes in the field (its marked text is not in `draft` yet).
    private func insert(_ character: String) {
        guard !LearnKeyRouter.isComposingText else { return }
        var text = state.draft
        var caret = selection
        SpecialCharacters.insert(character, into: &text, selection: &caret)
        controller.send(.draftChanged(text))
        selection = caret
        // Only when the field lost the keys: setting the focus it already has makes SwiftUI
        // move the keys away from it, and typing stopped after each special character.
        if focus.wrappedValue != .answer { focus.wrappedValue = .answer }
    }
}

/// The large answer (or copy) field, a plain text field; `StudyAnswerBox` draws its box.
private struct LearnAnswerField: View {
    @Environment(\.studyScale) private var studyScale
    @Binding var text: String
    @Binding var selection: TextSelection?
    let isCopy: Bool
    /// The answer's language (Arabic is typed from the right edge).
    let lang: Lang
    let placeholder: String
    var focus: FocusState<LearnKeyRouter.Focus?>.Binding
    /// The step wants the keys in this field (no popover, sheet or alert is open).
    let wantsFocus: Bool
    /// Changes with every question and between answer and copy field.
    let focusKey: String
    let onSubmit: () -> Void
    /// ⌥↩ and esc while typing (`studyFieldKeys`).
    let onKey: (KeyInput, _ isRepeat: Bool) -> Void

    var body: some View {
        // Read here, so a text changed by the app (a special character) reaches the field: the
        // screen around it is not rebuilt when only the text changes (`LearnController.draft`).
        let _ = text
        field
            .textFieldStyle(.plain)
            .font(Typography.answerField(studyScale))
            .cardFieldDirection(lang)
            .autocorrectionDisabled()
            .writingToolsBehavior(.disabled)
            .focused(focus, equals: .answer)
            .focusWhenShown(focus, equals: .answer, isWanted: wantsFocus, key: focusKey, fieldIdentifier: isCopy ? "learn-copy" : "learn-answer")
            .onSubmit(onSubmit)
            .studyFieldKeys(onKey)
            .accessibilityHint(isCopy ? String(localized: "Tippe die richtige Antwort ab") : placeholder)
            .accessibilityIdentifier(isCopy ? "learn-copy" : "learn-answer")
    }

    @ViewBuilder
    private var field: some View {
        if isCopy {
            TextField("Richtige Antwort abtippen", text: $text, selection: $selection, prompt: Text(placeholder))
        } else {
            TextField("Deine Antwort", text: $text, selection: $selection, prompt: Text(placeholder))
        }
    }
}

/// The box of a study screen's answer field (Lernen, Schreiben). It stays where it is through
/// a question and its answer and only changes colour: after a correct answer it turns green
/// and the typed word turns green with it (the same word, so it simply cross-fades); for the
/// next question it turns back into the field, the old answer gone before the empty field
/// fades in, so two different texts never sit on top of each other half-visible. Accent ring
/// while the field has the keys, red after a rejected copy; it shakes when an empty answer or a
/// wrong copy is rejected. While an answer is looked up as a synonym outside the set, a small
/// "Prüfe …" shows at its end.
struct StudyAnswerBox<Field: View>: View {
    @Environment(\.studyScale) private var studyScale
    /// What was typed, after a correct answer; nil while the field asks.
    let correctAnswer: AttributedString?
    /// The answer's language: Arabic stays at the right edge, where the field had it.
    var lang: Lang = .other
    /// The field has (or is about to get) the keys.
    var isActive = false
    /// A rejected copy.
    var isInvalid = false
    var rejections = 0
    /// The answer is being looked up as a synonym outside the set (`SynonymAssistant`).
    var isChecking = false
    @ViewBuilder var field: Field

    @State private var checked = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack(alignment: .leading) {
            if let correctAnswer {
                HStack(spacing: Spacing.s) {
                    Text(correctAnswer)
                        .font(Typography.answerField(studyScale))
                        .foregroundStyle(Theme.success.text)
                        .lineLimit(3)
                        .cardTextLine(lang)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.success.fill)
                        .symbolEffect(.bounce, options: .nonRepeating, value: checked)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(AttributedString(String(localized: "Deine Antwort, richtig: ")) + correctAnswer))
                .onAppear { checked += 1 }
                .transition(Self.acceptedTransition)
            } else {
                field
                    .transition(Self.fieldTransition)
            }
        }
        .overlay(alignment: .trailing) {
            if isChecking && correctAnswer == nil {
                HStack(spacing: Spacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Prüfe Synonym …")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Antwort wird geprüft")
                // Quick checks finish before it shows.
                .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.25)))
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(fill, in: shape)
        .overlay {
            shape.strokeBorder(ring, lineWidth: ringWidth)
                .allowsHitTesting(false)
        }
        .shake(trigger: rejections, amplitude: 8)
        .animation(Motion.snappy, value: isActive)
        .animation(Motion.snappy, value: isInvalid)
        // The box changes colour in one smooth move while its text swaps.
        .animation(.easeInOut(duration: 0.3), value: correctAnswer == nil)
    }

    /// The accepted answer cross-fades with the typed word it replaces, and leaves quickly
    /// for the next question.
    private static var acceptedTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.2)),
            removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    /// The field fades in once the old answer is gone, and cross-fades into the green answer.
    private static var fieldTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.08)),
            removal: .opacity.animation(.easeOut(duration: 0.2)))
    }

    private var fill: Color {
        correctAnswer == nil ? Color(nsColor: .windowBackgroundColor).opacity(0.72) : Theme.success.soft
    }

    private var ring: Color {
        if correctAnswer != nil { return Theme.success.fill.opacity(0.55) }
        if isInvalid { return Theme.failure.fill }
        return isActive ? Theme.accent : Theme.hairline
    }

    private var ringWidth: CGFloat {
        if correctAnswer != nil { return 1.5 }
        return isActive || isInvalid ? 2 : 1
    }
}

/// Below a correct written answer: "Genau: …" / "Gesucht war: …" for a tolerated or synonym
/// answer, and the tolerance notes.
private struct LearnCorrectDetails: View {
    let feedback: LearnFlow.Feedback
    let answerLang: Lang

    static func hasContent(_ feedback: LearnFlow.Feedback) -> Bool {
        exact(feedback) != nil || !notes(feedback).isEmpty
    }

    private static func exact(_ feedback: LearnFlow.Feedback) -> (label: String, expected: String)? {
        guard let label = feedback.exactLabel, let expected = feedback.result?.expectedDisplay, !expected.isEmpty
        else { return nil }
        return (label, expected)
    }

    private static func notes(_ feedback: LearnFlow.Feedback) -> [GradeNote] {
        (feedback.result?.notes ?? []).filter { Labels.NOTE_LABELS[$0] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let exact = Self.exact(feedback) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(exact.label)
                        .foregroundStyle(.secondary)
                    Text(LearnText.spoken(exact.expected, lang: answerLang))
                        .fontWeight(.semibold)
                        .cardTextDirection(answerLang)
                }
                .font(.title3)
                .accessibilityElement(children: .combine)
            }

            let notes = Self.notes(feedback)
            if !notes.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(notes, id: \.self) { note in
                        NoteChip(note, size: .small)
                    }
                }
            }
        }
    }
}

/// After a written miss: "Deine Antwort" with the character diff and the hint chip,
/// "Richtige Antwort" with 🔊, the note after a correcting edit, the copy field (if on) and
/// "Bearbeiten ⌘E".
private struct LearnMissDetails<Copy: View>: View {
    @Environment(\.studyScale) private var studyScale
    let feedback: LearnFlow.Feedback
    let question: LearnFlow.QuestionInfo
    let onSpeak: (String, Lang) -> Void
    let onEdit: () -> Void
    @ViewBuilder var copy: Copy

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if feedback.kind == .wrong, LearnText.hasText(feedback.given) {
                StudyFeedbackRow(title: String(localized: "Deine Antwort")) {
                    if let hint = feedback.hint, !feedback.editedCorrect {
                        HintChip(verbatim: hint, size: .small)
                    }
                } content: {
                    StudyDiffText(given: feedback.given, expected: question.expected, lang: question.answerLang)
                }
            }

            StudyFeedbackRow(title: String(localized: "Richtige Antwort")) {
                EmptyView()
            } content: {
                HStack(alignment: .center, spacing: Spacing.xs) {
                    Text(LearnText.spoken(question.expected, lang: question.answerLang))
                        .font(Typography.answerField(studyScale))
                        .foregroundStyle(Theme.success.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .cardTextDirection(question.answerLang)
                    LearnIconButton(
                        label: String(localized: "Antwort vorlesen"), help: String(localized: "Antwort vorlesen"),
                        systemImage: "speaker.wave.2"
                    ) {
                        onSpeak(question.expected, question.answerLang)
                    }
                }
            }

            if feedback.editedCorrect {
                Label(LearnFlow.EDITED_CORRECT_TEXT, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.success.text)
            }

            copy

            SecondaryButton(
                "Bearbeiten", systemImage: "square.and.pencil", key: .command("E"), bindsShortcut: false,
                controlSize: .regular, action: onEdit)
        }
        .padding(.top, Spacing.xxs)
    }
}

/// A labelled block of the miss details ("DEINE ANTWORT", "RICHTIGE ANTWORT"), in Lernen and
/// Schreiben.
struct StudyFeedbackRow<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs + 2) {
            HStack(spacing: Spacing.xs) {
                Text(title).eyebrowStyle()
                accessory
            }
            content
        }
        .accessibilityElement(children: .combine)
    }
}

/// What was typed, with the characters that were wrong struck through in red and the missing
/// ones underlined in green (`WriteFlow.answerDiff` against the closest accepted variant). A
/// different word is shown plainly: a character diff would only be noise there. Shared by
/// Lernen and Schreiben.
struct StudyDiffText: View {
    let given: String
    let expected: String
    let lang: Lang
    var font: Font = Typography.answerField

    var body: some View {
        Group {
            if let parts = WriteFlow.answerDiff(given: given, expected: expected, lang: lang) {
                Text(Self.attributed(parts, lang: lang))
            } else {
                Text(LearnText.spoken(given, lang: lang))
                    .foregroundStyle(Theme.failure.text)
            }
        }
        .font(font)
        .fixedSize(horizontal: false, vertical: true)
        .cardTextDirection(lang)
        .accessibilityLabel(Text(LearnText.spoken(given, lang: lang)))
    }

    private static func attributed(_ parts: [DiffSegment], lang: Lang) -> AttributedString {
        var out = AttributedString()
        for part in parts {
            var piece = AttributedString(part.text)
            switch part.type {
            case .same:
                break
            case .del:
                piece.foregroundColor = Theme.failure.text
                piece.backgroundColor = Theme.failure.soft
                piece.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Theme.failure.text)
            case .add:
                piece.foregroundColor = Theme.success.text
                piece.backgroundColor = Theme.success.soft
                piece.underlineStyle = Text.LineStyle(pattern: .solid, color: Theme.success.text)
            }
            out += piece
        }
        let tag = Labels.info(lang).bcp47
        if !tag.isEmpty { out.languageIdentifier = tag }
        return out
    }
}

// MARK: - Text helpers

enum LearnText {
    /// A text tagged with its language, so VoiceOver reads French words with a French voice.
    static func spoken(_ text: String, lang: Lang) -> AttributedString {
        var attributed = AttributedString(text)
        let tag = Labels.info(lang).bcp47
        if !tag.isEmpty { attributed.languageIdentifier = tag }
        return attributed
    }

    /// "Französisch: la maison", with the text part tagged with its language.
    static func labeled(_ label: String, _ text: String, lang: Lang) -> AttributedString {
        AttributedString("\(label): ") + spoken(text, lang: lang)
    }

    /// JS `s.trim() !== ''`.
    static func hasText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
