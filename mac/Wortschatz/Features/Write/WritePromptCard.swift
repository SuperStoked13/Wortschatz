import SwiftUI
import WortschatzCore

/// The Write question card (glass): the prompt's language, the prompt in large rounded type,
/// the tools 🔊 (⌘R), ★ (⌘D) and ✎ (⌘E), and below it the answer area of the current step:
/// the answer field with the special characters, the accepted answer, or the miss with
/// "Deine Antwort", "Richtige Antwort" and the copy field.
struct WritePromptCard: View {
    let controller: WriteController
    let question: WriteFlow.Question
    var focus: FocusState<WriteKeyRouter.Focus?>.Binding
    @Binding var selection: TextSelection?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: WriteFlow.State { controller.state }

    var body: some View {
        GlassCard(padding: Spacing.xl + Spacing.xxs) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .center, spacing: Spacing.s) {
                    Text(question.promptLabel)
                        .eyebrowStyle()
                        .accessibilityHidden(true)
                    Spacer(minLength: Spacing.s)
                    tools
                }
                ZStack(alignment: .leading) {
                    Text(LearnText.spoken(question.prompt, lang: question.promptLang))
                        .font(Typography.prompt(for: question.prompt))
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
                        .accessibilityIdentifier("write-prompt")
                }
                .padding(.bottom, Spacing.xxs)
                .animation(state.animatesQuestion ? Motion.animation(Motion.gentle, reduceMotion: reduceMotion) : nil, value: question.qid)
                answerArea
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Abfrage")
    }

    // MARK: Tools

    private var tools: some View {
        HStack(spacing: Spacing.xxs) {
            if question.promptLang != .other {
                LearnIconButton(label: "Vorlesen", help: "Vorlesen (⌘R)", systemImage: "speaker.wave.2.fill") {
                    controller.send(.speak(.prompt))
                }
                .symbolEffect(.variableColor.iterative, isActive: controller.speech.isSpeaking && !reduceMotion)
            }

            LearnIconButton(
                label: question.starred ? "Markierung entfernen" : "Markieren",
                help: question.starred ? "Markierung entfernen (⌘D)" : "Markieren (⌘D)",
                systemImage: question.starred ? "star.fill" : "star",
                tint: question.starred ? Theme.star : nil
            ) {
                controller.send(.toggleStar)
            }
            .symbolEffect(.bounce, options: .nonRepeating, value: question.starred)

            // ⌘E wins over the Lernset menu's ⌘E while a card is on screen: it edits this card.
            LearnIconButton(
                label: "Karte bearbeiten", help: "Karte bearbeiten (⌘E)", systemImage: "square.and.pencil",
                shortcut: KeyboardShortcut("e", modifiers: .command)
            ) {
                controller.send(.requestEdit)
            }
        }
    }

    private var promptTransition: AnyTransition {
        .promptSwap(reduceMotion: reduceMotion)
    }

    // MARK: Answer area

    private var answerArea: some View {
        // The steps take each other's place in one spot (the old one gone before the new one
        // fades in): stacked, the card first grew by both and then jumped back.
        ZStack(alignment: .topLeading) {
            switch state.phase {
            case .question, .feedback(.correct):
                // One branch for both steps, so a correct answer turns the field green where it
                // stands and the next question turns it back.
                let correct = state.phase == .feedback(.correct) ? state.feedback : nil
                VStack(alignment: .leading, spacing: Spacing.s) {
                    answerBox(isCopy: false, correctAnswer: correct.map { LearnText.spoken($0.given, lang: question.answerLang) })
                    ZStack(alignment: .topLeading) {
                        if let correct {
                            if WriteCorrectDetails.hasContent(correct) {
                                WriteCorrectDetails(feedback: correct, answerLang: question.answerLang)
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
                    WriteMissDetails(
                        feedback: feedback, question: question,
                        onSpeak: { controller.send(.speak(.answer)) },
                        onEdit: { controller.send(.requestEdit) }
                    ) {
                        if state.phase == .copy {
                            VStack(alignment: .leading, spacing: Spacing.s) {
                                Text(WriteFlow.fieldLabel(state))
                                    .eyebrowStyle()
                                    .accessibilityHidden(true)
                                answerBox(isCopy: true)
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
    private func answerBox(isCopy: Bool, correctAnswer: AttributedString? = nil) -> some View {
        let wantsFocus = WriteKeyRouter.focus(for: state) == .answer
        return StudyAnswerBox(
            correctAnswer: correctAnswer,
            lang: question.answerLang,
            // Ringed as soon as the step wants the keys there, not only once AppKit has moved
            // them (a few frames later): the ring no longer flickers in after the field.
            isActive: wantsFocus || focus.wrappedValue == .answer,
            isInvalid: state.inputInvalid,
            rejections: state.rejections,
            isChecking: controller.isCheckingSynonym && state.phase == .question
        ) {
            WriteAnswerField(
                // AppKit writes the text back when the field becomes first responder: only real
                // edits reach the flow (an edit clears the rejected-copy mark).
                text: Binding(
                    get: { controller.state.input },
                    set: { text in
                        if text != controller.state.input { controller.send(.inputChanged(text)) }
                    }),
                selection: $selection,
                label: WriteFlow.fieldLabel(state),
                placeholder: WriteFlow.fieldPlaceholder(state),
                lang: question.answerLang,
                isCopy: isCopy,
                isInvalid: state.inputInvalid,
                focus: focus,
                wantsFocus: wantsFocus,
                focusKey: "\(question.qid)|\(isCopy ? "copy" : "answer")",
                onSubmit: controller.submitFromField,
                onKey: controller.press)
        }
    }

    /// The special-character bar inserts at the caret (or replaces the selection); not while an
    /// input method composes in the field (its marked text is not in `input` yet).
    private func insert(_ character: String) {
        guard !LearnKeyRouter.isComposingText else { return }
        var text = state.input
        var caret = selection
        SpecialCharacters.insert(character, into: &text, selection: &caret)
        controller.send(.inputChanged(text))
        selection = caret
        // Only when the field lost the keys: setting the focus it already has can make SwiftUI
        // move the keys away from it (it did on the Learn screen).
        if focus.wrappedValue != .answer { focus.wrappedValue = .answer }
    }
}

// MARK: - Answer field

/// The large answer (or copy) field, a plain text field; `StudyAnswerBox` draws its box (with
/// a red ring after a rejected copy).
private struct WriteAnswerField: View {
    @Binding var text: String
    @Binding var selection: TextSelection?
    let label: String
    let placeholder: String
    /// The answer's language (Arabic is typed from the right edge).
    let lang: Lang
    let isCopy: Bool
    let isInvalid: Bool
    var focus: FocusState<WriteKeyRouter.Focus?>.Binding
    /// The step wants the keys in this field (no popover, sheet or alert is open).
    let wantsFocus: Bool
    /// Changes with every question and between answer and copy field.
    let focusKey: String
    let onSubmit: () -> Void
    /// ⌥↩ and esc while typing (`studyFieldKeys`).
    let onKey: (KeyInput, _ isRepeat: Bool) -> Void

    var body: some View {
        TextField(label, text: $text, selection: $selection, prompt: Text(placeholder))
            .textFieldStyle(.plain)
            .font(Typography.answerField)
            .cardFieldDirection(lang)
            .autocorrectionDisabled()
            .writingToolsBehavior(.disabled)
            .focused(focus, equals: .answer)
            .focusWhenShown(focus, equals: .answer, isWanted: wantsFocus, key: focusKey, fieldIdentifier: isCopy ? "write-copy" : "write-answer")
            .onSubmit(onSubmit)
            .studyFieldKeys(onKey)
            .accessibilityLabel("\(label): \(placeholder)")
            .accessibilityHint(isInvalid ? "Noch nicht ganz – tippe die richtige Antwort genau ab." : placeholder)
            .accessibilityIdentifier(isCopy ? "write-copy" : "write-answer")
    }
}

// MARK: - Correct answer

/// Below a correct answer (shown in the field's box by `StudyAnswerBox`):
/// "Genau: …" / "Gesucht war: …" for a tolerated or synonym answer, and the tolerance notes.
private struct WriteCorrectDetails: View {
    let feedback: WriteFlow.Feedback
    let answerLang: Lang

    static func hasContent(_ feedback: WriteFlow.Feedback) -> Bool {
        (feedback.showsExact && feedback.result?.expectedDisplay != nil) || !feedback.notes.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if feedback.showsExact, let expected = feedback.result?.expectedDisplay {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(feedback.exactLabel)
                        .foregroundStyle(.secondary)
                    Text(LearnText.spoken(expected, lang: answerLang))
                        .fontWeight(.semibold)
                        .cardTextDirection(answerLang)
                }
                .font(.title3)
                .accessibilityElement(children: .combine)
            }

            if !feedback.notes.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(feedback.notes, id: \.self) { note in
                        if note.isSynonym && note.note != .extendedSynonym {
                            TintedChip(text: note.label, systemImage: "equal.circle", palette: WriteText.accentPalette, size: .small)
                                .accessibilityLabel("Hinweis: \(note.label)")
                        } else {
                            NoteChip(note.note, size: .small)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Miss

/// After a miss: "Deine Antwort" with the character diff and the hint chip, "Richtige Antwort"
/// with 🔊, the note after a correcting edit, the copy field (if on) and "Bearbeiten ⌘E".
private struct WriteMissDetails<Copy: View>: View {
    let feedback: WriteFlow.Feedback
    let question: WriteFlow.Question
    let onSpeak: () -> Void
    let onEdit: () -> Void
    @ViewBuilder var copy: Copy

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if feedback.showsGiven {
                StudyFeedbackRow(title: "Deine Antwort") {
                    if feedback.showsHint, let hint = feedback.hintLabel {
                        HintChip(verbatim: hint, size: .small)
                    }
                } content: {
                    StudyDiffText(given: feedback.given, expected: question.expected, lang: question.answerLang)
                }
            }

            StudyFeedbackRow(title: "Richtige Antwort") {
                EmptyView()
            } content: {
                HStack(alignment: .center, spacing: Spacing.xs) {
                    // Not selectable (like Learn): selectable text takes the keyboard focus when
                    // clicked, and Return ("Weiter") or the copy field would stop getting keys.
                    Text(LearnText.spoken(question.expected, lang: question.answerLang))
                        .font(Typography.answerField)
                        .foregroundStyle(Theme.success.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .cardTextDirection(question.answerLang)
                    if question.answerLang != .other {
                        LearnIconButton(label: "Antwort vorlesen", help: "Antwort vorlesen", systemImage: "speaker.wave.2", action: onSpeak)
                    }
                }
            }

            if let note = feedback.editedNote {
                Label(note, systemImage: "checkmark.circle.fill")
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

/// Small helpers of the Write screen's views.
enum WriteText {
    /// Accent chip colours (synonym notes).
    static let accentPalette = Theme.StatusPalette(fill: Theme.accent, text: Theme.accentText, soft: Theme.accentSoft)
}
