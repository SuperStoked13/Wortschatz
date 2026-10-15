import SwiftUI
import WortschatzCore

/// "Karte bearbeiten" (✎, ⌘E) for the card on screen: term and definition with the side the
/// learner had to type focused (usually the one to fix), saved with Return, cancelled with esc
/// (write-dialogs.js `openCardEditor`). The flow applies the change at once: a corrected card
/// may now accept the typed answer ("Als richtig zählen").
struct WriteCardEditor: View {
    let card: Card
    let termLang: Lang
    let defLang: Lang
    let focus: AskSide
    let onSave: (Card) -> Void
    let onCancel: () -> Void

    @State private var term: String
    @State private var definition: String
    @FocusState private var focusedField: AskSide?

    init(
        card: Card, termLang: Lang, defLang: Lang, focus: AskSide, onSave: @escaping (Card) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.card = card
        self.termLang = termLang
        self.defLang = defLang
        self.focus = focus
        self.onSave = onSave
        self.onCancel = onCancel
        _term = State(initialValue: card.term)
        _definition = State(initialValue: card.definition)
    }

    var body: some View {
        let labels = WriteFlow.editorLabels(termLang: termLang, defLang: defLang)
        let errors = WriteFlow.editorErrors(term: term, definition: definition)
        VStack(alignment: .leading, spacing: 0) {
            Text("Karte bearbeiten")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.l)

            Form {
                // A grouped form ends a field's text at the right edge already, so Arabic needs
                // no right-to-left direction here (it would move the label to the right too).
                Section {
                    TextField(labels.term, text: $term)
                        .focused($focusedField, equals: .term)
                    if let error = errors.term {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(Theme.failure.text)
                    }
                    TextField(labels.definition, text: $definition)
                        .focused($focusedField, equals: .definition)
                    if let error = errors.definition {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(Theme.failure.text)
                    }
                }
            }
            .formStyle(.grouped)
            .autocorrectionDisabled()
            .scrollDisabled(true)

            HStack(spacing: Spacing.s) {
                Spacer()
                Button("Abbrechen", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    var edited = card
                    edited.term = term
                    edited.definition = definition
                    onSave(edited)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(errors.term != nil || errors.definition != nil)
            }
            .controlSize(.large)
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.l)
        }
        .frame(width: 480)
        .onAppear { focusedField = focus }
    }
}
