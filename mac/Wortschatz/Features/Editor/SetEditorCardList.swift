import SwiftUI
import WortschatzCore
import WortschatzImport

/// Column metrics shared by the card rows and their pinned header.
nonisolated enum SetEditorLayout {
    /// Readable width of the editor's content column.
    static let contentWidth: CGFloat = 920
    static let numberWidth: CGFloat = 28
    static let columnSpacing: CGFloat = 12
    static let fieldSpacing: CGFloat = 20
    static let actionsWidth: CGFloat = 58
    static let rowPadding: CGFloat = 12
}

/// "Karten 52" with the issue chips, the lead for an empty list and the error after a save
/// attempt (the head of the cards section in editor.js).
struct SetEditorCardsHeader: View {
    let editor: SetEditorModel

    var body: some View {
        let stats = editor.stats
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text("Karten")
                    .font(Typography.title)
                    .accessibilityAddTraits(.isHeader)
                Text("\(stats.filled)")
                    .font(Typography.count)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .accessibilityLabel(Labels.plural(stats.filled, "Karte", "Karten"))
                Spacer(minLength: Spacing.s)
                HStack(spacing: Spacing.xs) {
                    if stats.duplicates > 0 {
                        TintedChip(
                            text: "\(Labels.plural(stats.duplicates, "Begriff", "Begriffe")) doppelt", systemImage: "doc.on.doc",
                            palette: Theme.warning, size: .small)
                    }
                    if stats.flagged > 0 {
                        TintedChip(
                            text: "\(stats.flagged) bitte prüfen", systemImage: "exclamationmark.triangle", palette: Theme.warning,
                            size: .small)
                    }
                    if stats.typos > 0 {
                        TintedChip(
                            text: ImportSpelling.countLabel(stats.typos), systemImage: "textformat.abc", palette: Theme.warning,
                            size: .small)
                            .help("Klicke in einer Karte auf den markierten Begriff, um ihn zu korrigieren oder zu ignorieren.")
                    }
                    if stats.invalid > 0 {
                        TintedChip(
                            text: "\(stats.invalid) unvollständig", systemImage: "exclamationmark.circle", palette: Theme.failure,
                            size: .small)
                    }
                }
            }
            if stats.filled == 0 {
                Text(SetEditorCopy.emptyLead)
                    .foregroundStyle(.secondary)
            }
            if let error = editor.cardsError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.failure.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }
}

/// "# · BEGRIFF · FRANZÖSISCH · DEFINITION · DEUTSCH", pinned above the rows while scrolling.
struct SetEditorColumnHeader: View {
    let termLang: Lang
    let defLang: Lang

    var body: some View {
        HStack(spacing: SetEditorLayout.columnSpacing) {
            Text(verbatim: "#")
                .frame(width: SetEditorLayout.numberWidth, alignment: .trailing)
            HStack(spacing: SetEditorLayout.fieldSpacing) {
                Text("Begriff · \(Labels.langName(termLang))")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Definition · \(Labels.langName(defLang))")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Color.clear
                .frame(width: SetEditorLayout.actionsWidth, height: 1)
        }
        .eyebrowStyle()
        .lineLimit(1)
        .padding(.horizontal, SetEditorLayout.rowPadding)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.xs)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityHidden(true)
    }
}

/// One card: number (with the parser's review marker), term and definition fields, ★ and
/// delete, plus "Begriff fehlt" / "Doppelter Begriff" notes.
///
/// Keys: Return in the term goes to the definition, Return in the definition to the next
/// card's term (a new card after the last filled one); ⇥ in the last definition adds a card;
/// ⌫ in an empty card's term removes it; ⌥↩ breaks a line.
struct SetEditorRowView: View {
    let row: SetEditorRow
    let number: Int
    let termLang: Lang
    let defLang: Lang
    let editor: SetEditorModel
    var focus: FocusState<SetEditorField?>.Binding

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .top, spacing: SetEditorLayout.columnSpacing) {
                numberColumn
                HStack(alignment: .top, spacing: SetEditorLayout.fieldSpacing) {
                    field(isTerm: true)
                    field(isTerm: false)
                }
                actions
            }
            if row.isInvalid || row.isDuplicate || row.hasSpellingIssues {
                notes
                    .padding(.leading, SetEditorLayout.numberWidth + SetEditorLayout.columnSpacing)
            }
        }
        .padding(.horizontal, SetEditorLayout.rowPadding)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .background(Color(nsColor: .textBackgroundColor), in: shape)
        .overlay { shape.strokeBorder(borderColor, lineWidth: 1).allowsHitTesting(false) }
    }

    private var numberColumn: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("\(number)")
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let tooltip = SetEditorCopy.flagTooltip(row.flags) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning.fill)
                    .help(tooltip)
                    .accessibilityLabel("Karte \(number): \(tooltip)")
            }
        }
        .frame(width: SetEditorLayout.numberWidth, alignment: .trailing)
        .padding(.top, 1)
    }

    private func field(isTerm: Bool) -> some View {
        let id: SetEditorField = isTerm ? .term(row.id) : .definition(row.id)
        let isFocused = focus.wrappedValue == id
        let isMissing = row.isInvalid && (isTerm ? row.trimmedTerm : row.trimmedDefinition).isEmpty
        let side = isTerm ? "Begriff" : "Definition"
        let lang = Labels.langName(isTerm ? termLang : defLang)
        return VStack(alignment: .leading, spacing: 6) {
            TextField(
                side,
                text: Binding(
                    get: { isTerm ? row.term : row.definition },
                    set: { isTerm ? editor.setTerm(row, $0) : editor.setDefinition(row, $0) }),
                prompt: Text(isTerm ? SetEditorCopy.termPlaceholder : SetEditorCopy.definitionPlaceholder),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(1...6)
            .focused(focus, equals: id)
            .onSubmit {
                withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) { editor.submit(id) }
            }
            .onKeyPress(keys: [.tab, .delete], phases: .down) { press in
                handle(press, isTerm: isTerm)
            }
            .accessibilityLabel("Karte \(number): \(side) (\(lang))")
            Rectangle()
                .fill(isMissing ? Theme.failure.fill : isFocused ? Theme.accent : Theme.hairline)
                .frame(height: isFocused || isMissing ? 2 : 1)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button {
                editor.toggleStar(row)
            } label: {
                Image(systemName: row.starred ? "star.fill" : "star")
                    .foregroundStyle(row.starred ? Theme.star : Color.secondary)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .help(row.starred ? "Markierung entfernen" : "Markieren")
            .accessibilityLabel(row.starred ? "Karte \(number): Markierung entfernen" : "Karte \(number) markieren")
            Button {
                withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                    editor.deleteRow(row, focused: focus.wrappedValue)
                }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .help("Karte löschen")
            .accessibilityLabel("Karte \(number) löschen")
        }
        .buttonStyle(.borderless)
        .frame(width: SetEditorLayout.actionsWidth, alignment: .trailing)
    }

    private var notes: some View {
        HStack(spacing: Spacing.xs) {
            if row.isInvalid {
                TintedChip(
                    text: row.trimmedTerm.isEmpty ? "Begriff fehlt" : "Definition fehlt", systemImage: "exclamationmark.circle",
                    palette: Theme.failure, size: .small)
            }
            if row.isDuplicate {
                TintedChip(text: "Doppelter Begriff", systemImage: "doc.on.doc", palette: Theme.warning, size: .small)
            }
            ForEach(spellingNotes.prefix(3)) { note in
                SpellingChip(issue: note.issue, number: number) { replacement in
                    withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                        editor.replaceSpelling(note.issue, in: row, isTerm: note.isTerm, with: replacement)
                    }
                } onIgnore: {
                    withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                        editor.ignoreSpelling(note.issue, isTerm: note.isTerm)
                    }
                }
            }
            if spellingNotes.count > 3 {
                Text("+\(spellingNotes.count - 3)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.warning.text)
            }
        }
    }

    private struct SpellingNote: Identifiable {
        let issue: SpellingIssue
        let isTerm: Bool
        var id: String { "\(isTerm ? "t" : "d")\(issue.id)" }
    }

    private var spellingNotes: [SpellingNote] {
        row.termSpelling.map { SpellingNote(issue: $0, isTerm: true) }
            + row.definitionSpelling.map { SpellingNote(issue: $0, isTerm: false) }
    }

    private var borderColor: Color {
        if row.isInvalid { return Theme.failure.fill.opacity(0.55) }
        if row.isDuplicate || row.isFlagged || row.hasSpellingIssues { return Theme.warning.fill.opacity(0.5) }
        return Theme.hairline
    }

    private func handle(_ press: SwiftUI.KeyPress, isTerm: Bool) -> SwiftUI.KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        let animation = Motion.animation(Motion.snappy, reduceMotion: reduceMotion)
        if press.key == .tab, !isTerm {
            return withAnimation(animation) { editor.tabFromDefinition(of: row) } ? .handled : .ignored
        }
        if press.key == .delete, isTerm {
            return withAnimation(animation) { editor.deleteBackwardInEmptyTerm(of: row) } ? .handled : .ignored
        }
        return .ignored
    }
}

/// "Karte hinzufügen" and the key hints below the rows.
struct SetEditorCardsFooter: View {
    let editor: SetEditorModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.m) {
            Button {
                withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) { _ = editor.addRow() }
            } label: {
                Label("Karte hinzufügen", systemImage: "plus")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.s)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .overlay {
                shape.strokeBorder(Theme.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .allowsHitTesting(false)
            }
            .accessibilityIdentifier("editor-add-card")

            ViewThatFits(in: .horizontal) {
                hints(spacing: Spacing.l)
                hints(spacing: Spacing.s)
            }
        }
        .padding(.top, Spacing.xxs)
    }

    private func hints(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            KeyHint(.returnKey, "nächstes Feld")
            KeyHint(.optionReturn, "Zeilenumbruch")
            KeyHint(.tab, "in der letzten Karte: neue Karte")
            KeyHint(.commandReturn, editor.saveLabel)
        }
        .fixedSize()
    }
}

/// A probable typo in a card ("«separee» → séparée?"): a menu with the spell checker's
/// suggestions and "Ignorieren".
private struct SpellingChip: View {
    let issue: SpellingIssue
    let number: Int
    let onReplace: (String) -> Void
    let onIgnore: () -> Void

    var body: some View {
        Menu {
            if issue.suggestions.isEmpty {
                Text("Keine Vorschläge")
            } else {
                Section("Ersetzen durch") {
                    ForEach(issue.suggestions, id: \.self) { suggestion in
                        Button(suggestion) { onReplace(suggestion) }
                    }
                }
            }
            Divider()
            Button("«\(issue.word)» ignorieren", systemImage: "eye.slash") { onIgnore() }
        } label: {
            TintedChip(text: label, systemImage: "textformat.abc", palette: Theme.warning, size: .small)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Möglicher Tippfehler – klicken für Vorschläge")
        .accessibilityLabel("Karte \(number): möglicher Tippfehler «\(issue.word)»\(issue.suggestions.first.map { ", Vorschlag \($0)" } ?? "")")
    }

    private var label: String {
        issue.suggestions.first.map { "«\(issue.word)» → \($0)?" } ?? "«\(issue.word)» unbekannt"
    }
}
