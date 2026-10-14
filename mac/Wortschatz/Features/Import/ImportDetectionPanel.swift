import SwiftUI
import WortschatzCore
import WortschatzImport

/// The recognition below the paste box (port of `renderDetect` in editor-import.js): the
/// detection bar ("✨ 52 Paare erkannt · Abwechselnde Zeilen · Französisch → Deutsch") with
/// the separator controls, warnings and skipped lines on a content panel, then the preview
/// table and "N Karten übernehmen".
struct ImportDetectionPanel: View {
    let model: ImportPanelModel
    var focus: FocusState<SetEditorField?>.Binding
    let onApply: () -> Void

    var body: some View {
        if let result = model.result {
            let count = result.cards.count
            let typos = model.typos
            VStack(alignment: .leading, spacing: Spacing.m) {
                ContentPanel(padding: Spacing.m) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ImportDetectionSummary(result: result, swapsSides: model.swapsSides, typos: typos.values.reduce(0) { $0 + $1.count })
                        if count == 0 {
                            Text(
                                model.needsCustomSeparator
                                    ? "Gib oben dein Trennzeichen ein."
                                    : "Wähle eine andere Trennung oder prüfe, ob jede Zeile einen Begriff und eine Übersetzung enthält."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        controls
                        if !model.warnings.isEmpty {
                            ImportWarnings(warnings: model.warnings)
                        }
                        if !result.skipped.isEmpty {
                            ImportSkippedLines(model: model, skipped: result.skipped)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if count > 0 {
                    ImportPreviewTable(result: result, typos: typos)
                }
                HStack {
                    if count > ImportPanelModel.previewRows {
                        Text("Alle \(count) Paare in der Vorschau – scrolle darin für mehr.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Spacing.s)
                    PrimaryActionButton(
                        verbatim: count > 0 ? "\(Labels.plural(count, "Karte", "Karten")) übernehmen" : "Karten übernehmen",
                        systemImage: "checkmark", key: nil
                    ) {
                        onApply()
                    }
                    .disabled(count == 0)
                    .help("Die erkannten Paare in die Kartenliste übernehmen")
                    .accessibilityIdentifier("editor-apply-import")
                }
            }
        }
    }

    /// "Trennung", the custom separator and "Seiten tauschen".
    private var controls: some View {
        HStack(spacing: Spacing.s) {
            Text("Trennung")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                separatorPicker
                    .pickerStyle(.segmented)
                    .fixedSize()
                separatorPicker
                    .pickerStyle(.menu)
                    .fixedSize()
            }
            if model.separator == .custom {
                TextField(
                    "Eigenes Trennzeichen",
                    text: Binding(get: { model.customSeparator }, set: { model.setCustomSeparator($0) }),
                    prompt: Text("z. B. /")
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
                .focused(focus, equals: .customSeparator)
                .onSubmit { model.parseNow() }
            }
            Spacer(minLength: Spacing.s)
            Toggle(isOn: Binding(get: { model.swapsSides }, set: { _ in model.toggleSwap() })) {
                Label("Seiten tauschen", systemImage: "arrow.left.arrow.right")
            }
            .toggleStyle(.button)
            .fixedSize()
            .help("Begriff und Definition in der Erkennung vertauschen")
        }
    }

    private var separatorPicker: some View {
        Picker(
            "Trennung zwischen Begriff und Definition",
            selection: Binding(
                get: { model.separator },
                set: { separator in
                    model.setSeparator(separator)
                    if separator == .custom {
                        // The field appears with this change.
                        Task { @MainActor in focus.wrappedValue = .customSeparator }
                    }
                })
        ) {
            ForEach(ImportSeparator.allCases) { separator in
                Text(separator.label).tag(separator)
            }
        }
        .labelsHidden()
    }
}

/// The summary line with its chips.
private struct ImportDetectionSummary: View {
    let result: ParseResult
    let swapsSides: Bool
    /// Probable typos in the recognised pairs (spell checker).
    let typos: Int

    var body: some View {
        let count = result.cards.count
        let flagged = result.cards.filter { SetEditorCopy.hasMarker($0.flags) }.count
        let parts = summaryParts
        HStack(alignment: .center, spacing: Spacing.s) {
            Image(systemName: count > 0 ? "sparkles" : "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(count > 0 ? Theme.accent : Color.secondary)
                .symbolEffect(.bounce, options: .nonRepeating, value: count)
                .accessibilityHidden(true)
            Text("\(Text(SetEditorCopy.pairsDetected(count)).fontWeight(.semibold))\(parts.isEmpty ? "" : " · " + parts.joined(separator: " · "))")
                .font(.body)
                .contentTransition(.numericText())
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            if count > 0, result.swapped, !swapsSides {
                TintedChip(
                    text: "Seiten automatisch getauscht", systemImage: "arrow.left.arrow.right",
                    palette: Theme.StatusPalette(fill: Theme.accent, text: Theme.accentText, soft: Theme.accentSoft),
                    size: .small)
            }
            if count > 0, flagged > 0 {
                TintedChip(
                    text: "\(flagged) bitte prüfen", systemImage: "exclamationmark.triangle", palette: Theme.warning, size: .small)
            }
            if count > 0, typos > 0 {
                TintedChip(
                    text: ImportSpelling.countLabel(typos), systemImage: "textformat.abc", palette: Theme.warning, size: .small)
                    .help("Diese Wörter kennt die Rechtschreibprüfung nicht – nach dem Übernehmen kannst du sie mit einem Klick korrigieren.")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Abwechselnde Zeilen", "Französisch → Deutsch".
    private var summaryParts: [String] {
        guard !result.cards.isEmpty else { return [] }
        var parts: [String] = []
        if let layout = SetEditorCopy.formatLabel(result) { parts.append(layout) }
        if result.termLang != .other || result.defLang != .other {
            parts.append("\(Labels.langName(result.termLang)) → \(Labels.langName(result.defLang))")
        }
        return parts
    }
}

/// Parser warnings and notes of partly read files.
private struct ImportWarnings: View {
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning.fill)
                        .accessibilityHidden(true)
                    Text(warning)
                        .foregroundStyle(Theme.warning.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.soft, in: RoundedRectangle(cornerRadius: Radii.small, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hinweise: \(warnings.joined(separator: " "))")
    }
}

/// "3 Zeilen übersprungen" with the lines and reasons.
private struct ImportSkippedLines: View {
    @Bindable var model: ImportPanelModel
    let skipped: [SkippedLine]

    var body: some View {
        DisclosureGroup(isExpanded: $model.showsSkippedLines) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                ForEach(skipped, id: \.line) { line in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        Text("Zeile \(line.line)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        Text(line.text.isEmpty ? "–" : line.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(SetEditorCopy.skipReason(line.reason))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.callout)
            .padding(.top, Spacing.xxs)
        } label: {
            Text("\(Labels.plural(skipped.count, "Zeile", "Zeilen")) übersprungen")
                .font(.callout)
        }
    }
}

/// The recognised pairs as a table; flagged rows and rows with probable typos carry an amber
/// marker with the reason.
struct ImportPreviewTable: View {
    let result: ParseResult
    /// Probable typos per card index (`ImportSpelling.typos`).
    var typos: [Int: [SpellingIssue]] = [:]

    private struct Row: Identifiable {
        let id: Int
        let term: String
        let definition: String
        let tooltip: String?
    }

    private static let rowHeight: CGFloat = 24
    /// Header plus the table's own top and bottom insets.
    private static let chromeHeight: CGFloat = 50

    var body: some View {
        let rows = result.cards.enumerated().map { index, card in
            let reasons = [SetEditorCopy.flagTooltip(card.flags), ImportSpelling.tooltip(typos[index] ?? [])].compactMap { $0 }
            return Row(
                id: index + 1, term: card.term, definition: card.definition,
                tooltip: reasons.isEmpty ? nil : reasons.joined(separator: "\n"))
        }
        let shape = RoundedRectangle(cornerRadius: Radii.small, style: .continuous)
        Table(rows) {
            TableColumn(Text(verbatim: "#")) { row in
                Text("\(row.id)")
                    .monospacedDigit()
                    .foregroundStyle(row.tooltip == nil ? Color.secondary : Theme.warning.text)
            }
            .width(min: 30, ideal: 34, max: 44)

            TableColumn(Text(verbatim: "Begriff · \(Labels.langName(result.termLang))")) { row in
                ImportPreviewCell(text: row.term, missing: "Begriff fehlt")
            }

            TableColumn(Text(verbatim: "Definition · \(Labels.langName(result.defLang))")) { row in
                ImportPreviewCell(text: row.definition, missing: "Definition fehlt")
            }

            TableColumn(Text(verbatim: "")) { row in
                if let tooltip = row.tooltip {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning.fill)
                        .help(tooltip)
                        .accessibilityLabel(tooltip)
                }
            }
            .width(22)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .frame(height: Self.chromeHeight + Self.rowHeight * CGFloat(min(rows.count, ImportPanelModel.previewRows)))
        .clipShape(shape)
        .overlay { shape.strokeBorder(Theme.hairline, lineWidth: 1).allowsHitTesting(false) }
        .accessibilityLabel("Vorschau der erkannten Karten")
    }
}

/// A preview cell; an empty side shows what is missing.
private struct ImportPreviewCell: View {
    let text: String
    let missing: String

    var body: some View {
        if text.isEmpty {
            Text(missing)
                .italic()
                .foregroundStyle(Theme.warning.text)
        } else {
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text)
        }
    }
}
