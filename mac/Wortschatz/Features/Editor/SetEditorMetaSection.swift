import SwiftUI
import WortschatzCore

/// Titel, Beschreibung and the language pickers ("Ich lerne" ⇄ "Übersetzung"; a new set starts
/// on "Automatisch").
struct SetEditorMetaSection: View {
    let editor: SetEditorModel
    var focus: FocusState<SetEditorField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SetEditorFieldBox(
                label: String(localized: "Titel"), isFocused: focus.wrappedValue == .title, error: editor.titleError
            ) {
                TextField(
                    "Titel", text: Binding(get: { editor.title }, set: { editor.setTitle($0) }),
                    prompt: Text(SetEditorCopy.titlePlaceholder), axis: .vertical
                )
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .lineLimit(1...2)
                .focused(focus, equals: .title)
                .onSubmit { editor.submit(.title) }
                .accessibilityIdentifier("editor-title")
            } note: {
                if editor.titleFromFile {
                    Label(SetEditorCopy.titleFromFile, systemImage: "sparkles")
                        .font(.callout)
                        .foregroundStyle(Theme.accentText)
                        .transition(.opacity)
                }
            }

            SetEditorFieldBox(
                label: String(localized: "Beschreibung"), isFocused: focus.wrappedValue == .description
            ) {
                TextField(
                    "Beschreibung", text: Binding(get: { editor.details }, set: { editor.setDetails($0) }),
                    prompt: Text(SetEditorCopy.descriptionPlaceholder), axis: .vertical
                )
                .lineLimit(1...4)
                .focused(focus, equals: .description)
                .onSubmit { editor.submit(.description) }
            } note: {
                EmptyView()
            }

            languages
        }
    }

    private var languages: some View {
        // The pickers take the width of their text, so ⇄ sits evenly between them.
        HStack(alignment: .top, spacing: Spacing.m) {
            SetEditorLanguagePicker(
                label: String(localized: "Ich lerne"), languages: SetEditorCopy.termLanguages,
                selection: Binding(
                    get: { editor.termIsAuto ? nil : editor.termLang },
                    set: { lang in if let lang { editor.setTermLang(lang) } else { editor.setTermAuto() } }),
                isDetected: editor.termDetected)
            Button {
                editor.flipSides()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.top, 21)
            .help("Begriffe und Definitionen tauschen")
            .accessibilityLabel("Begriffe und Definitionen tauschen")
            SetEditorLanguagePicker(
                label: String(localized: "Übersetzung"), languages: SetEditorCopy.definitionLanguages,
                selection: Binding(
                    get: { editor.defIsAuto ? nil : editor.defLang },
                    set: { lang in if let lang { editor.setDefLang(lang) } else { editor.setDefAuto() } }),
                isDetected: editor.defDetected)
            Spacer(minLength: 0)
        }
    }
}

/// A language pop-up with its label and the "Automatisch erkannt" note; "Automatisch" (nil)
/// leaves the language to the recognition.
private struct SetEditorLanguagePicker: View {
    let label: String
    let languages: [Lang]
    @Binding var selection: Lang?
    let isDetected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Picker(label, selection: $selection) {
                Text(SetEditorCopy.automatic).tag(Lang?.none)
                Divider()
                ForEach(languages, id: \.self) { lang in
                    Text(Labels.langName(lang)).tag(Lang?.some(lang))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.large)
            .fixedSize()
            .accessibilityValue(accessibilityValue)
            Label(SetEditorCopy.detected, systemImage: "sparkles")
                .fixedSize()
                // Takes no width: the column is as wide as its picker (⇄ stays centred).
                .frame(width: 0, alignment: .leading)
                .font(.caption)
                .foregroundStyle(Theme.accentText)
                .opacity(isDetected ? 1 : 0)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityValue: String {
        guard let selection else { return SetEditorCopy.automatic }
        return isDetected
            ? String(localized: "\(Labels.langName(selection)), automatisch erkannt") : Labels.langName(selection)
    }
}

/// A labelled text field in a rounded box with a visible focus ring and an optional error.
struct SetEditorFieldBox<Field: View, Note: View>: View {
    let label: String
    let isFocused: Bool
    var error: String?
    @ViewBuilder var field: Field
    @ViewBuilder var note: Note

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radii.small + 2, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            field
                .textFieldStyle(.plain)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: shape)
                .overlay {
                    shape.strokeBorder(borderColor, lineWidth: isFocused || error != nil ? 2 : 1)
                        .allowsHitTesting(false)
                }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.failure.text)
                    .transition(.opacity)
            }
            note
        }
    }

    private var borderColor: Color {
        if error != nil { return Theme.failure.fill }
        return isFocused ? Theme.accent : Theme.hairline
    }
}
