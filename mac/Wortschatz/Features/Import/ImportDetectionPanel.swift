import SwiftUI
import WortschatzCore
import WortschatzImport

/// The recognition below the paste box (port of `renderDetect` in editor-import.js): the
/// detection bar ("✨ 52 Paare erkannt · Abwechselnde Zeilen · Französisch → Deutsch") with
/// the separator controls, warnings and skipped lines on a content panel. The pairs themselves
/// are the cards below (`SetEditorModel.syncImport`): no preview of its own and no "übernehmen"
/// (Anthony, 25.11.2026); "Trennung" and "Seiten tauschen" change the cards at once.
struct ImportDetectionPanel: View {
    let model: ImportPanelModel
    var focus: FocusState<SetEditorField?>.Binding
    /// "Zu den Karten": scrolls to the card list.
    let onShowCards: () -> Void

    var body: some View {
        if let result = model.result {
            let count = result.cards.count
            VStack(alignment: .leading, spacing: Spacing.m) {
                ContentPanel(padding: Spacing.m) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ImportDetectionSummary(result: result, swapsSides: model.swapsSides)
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
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        Label(
                            "Die erkannten Paare stehen unten in den Karten – Trennung und Seiten tauschen ändern sie sofort.",
                            systemImage: "arrow.down"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Spacing.s)
                        Button("Zu den Karten", systemImage: "arrow.down.circle", action: onShowCards)
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.accentText)
                            .fixedSize()
                            .accessibilityIdentifier("editor-show-cards")
                    }
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
            .help("Begriff und Definition der erkannten Karten vertauschen")
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
                    text: String(localized: "Seiten automatisch getauscht"), systemImage: "arrow.left.arrow.right",
                    palette: Theme.StatusPalette(fill: Theme.accent, text: Theme.accentText, soft: Theme.accentSoft),
                    size: .small)
            }
            if count > 0, flagged > 0 {
                TintedChip(
                    text: String(localized: "\(flagged) bitte prüfen"), systemImage: "exclamationmark.triangle",
                    palette: Theme.warning, size: .small)
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
