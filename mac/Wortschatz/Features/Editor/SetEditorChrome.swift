import SwiftUI
import WortschatzCore

/// "Neues Lernset" / "Lernset bearbeiten" with the language pair.
struct SetEditorHeader: View {
    let editor: SetEditorModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(editor.heading)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text(
                    editor.isEditing
                        ? "Ändere Begriffe, ergänze neue oder importiere eine weitere Liste."
                        : "Tippe deine Vokabeln ein oder importiere eine ganze Liste – aus Text, Datei oder Foto."
                )
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.m)
            LanguageCapsule(termLang: editor.termLang, defLang: editor.defLang)
                .animation(.default, value: editor.termLang)
                .animation(.default, value: editor.defLang)
        }
    }
}

/// The floating glass bar at the bottom of the sheet: the card count and what still blocks
/// saving, "Abbrechen esc" and the primary "Erstellen ⌘↩" / "Sichern ⌘↩".
struct SetEditorActionBar: View {
    let editor: SetEditorModel

    var body: some View {
        let stats = editor.stats
        let blocker = editor.readiness
        GlassEffectContainer(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                status(stats, blocker: blocker)
                    .padding(.horizontal, Spacing.m)
                    .frame(minHeight: 40)
                    .glassSurface(in: Capsule(style: .continuous))
                    .layoutPriority(1)
                Spacer(minLength: 0)
                SecondaryButton("Abbrechen", key: .escape) { editor.cancel() }
                    .help(editor.importPanel.isBusy ? "Import abbrechen (esc)" : "Ohne Speichern schliessen (esc)")
                PrimaryActionButton(verbatim: editor.saveLabel, key: .commandReturn) { editor.save() }
                    .help(blocker.map { "\($0) – \(editor.saveLabel) zeigt, was fehlt" } ?? "\(editor.saveLabel) (⌘↩ oder ⌘S)")
                    .accessibilityIdentifier("editor-save")
            }
        }
        .frame(maxWidth: SetEditorLayout.contentWidth)
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.l)
        .frame(maxWidth: .infinity)
    }

    private func status(_ stats: SetEditorModel.Stats, blocker: String?) -> some View {
        var extras: [String] = []
        if stats.duplicates > 0 { extras.append("\(stats.duplicates) doppelt") }
        if stats.invalid > 0 { extras.append("\(stats.invalid) unvollständig") }
        if stats.typos > 0 { extras.append("\(stats.typos) Tippfehler?") }
        return HStack(spacing: Spacing.xs) {
            Text(Labels.plural(stats.filled, "Karte", "Karten"))
                .fontWeight(.semibold)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(Labels.langPair(editor.termLang, editor.defLang))
                .foregroundStyle(.secondary)
            if let blocker {
                Text("·").foregroundStyle(.tertiary)
                Text(blocker)
                    .foregroundStyle(.secondary)
            } else if !extras.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(extras.joined(separator: " · "))
                    .foregroundStyle(Theme.warning.text)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// Shown while files are dragged over the sheet.
struct SetEditorDropOverlay: View {
    var body: some View {
        ZStack {
            Theme.accent.opacity(0.06)
            RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2.5, dash: [10, 7]))
                .padding(Spacing.s)
            VStack(spacing: Spacing.xs) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Datei loslassen zum Importieren")
                    .font(Typography.feedbackTitle)
                Text("Text, CSV, PDF oder Foto – mehrere Dateien gehen auch.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.xl)
            .glassSurface(cornerRadius: Radii.card)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The buttons of an editor prompt. Return takes the safe or the expected answer
/// ("Anhängen", "N Karten anhängen", "Weiter bearbeiten"); esc cancels.
struct SetEditorPromptButtons: View {
    let prompt: SetEditorModel.Prompt
    let editor: SetEditorModel

    var body: some View {
        switch prompt {
        case .applyImport:
            Button("Anhängen") { editor.resolveApply(prompt, mode: .append) }
                .keyboardShortcut(.defaultAction)
            Button("Ersetzen") { editor.resolveApply(prompt, mode: .replace) }
            Button("Abbrechen", role: .cancel) { editor.resolveApply(prompt, mode: nil) }
        case let .pendingImport(count):
            Button("\(Labels.plural(count, "Karte", "Karten")) anhängen") { editor.resolvePendingImport(prompt, append: true) }
                .keyboardShortcut(.defaultAction)
            Button("Ohne Liste") { editor.resolvePendingImport(prompt, append: false) }
            Button("Abbrechen", role: .cancel) { editor.resolvePendingImport(prompt, append: nil) }
        case .discard:
            Button("Verwerfen", role: .destructive) { editor.discard() }
            Button("Weiter bearbeiten", role: .cancel) { editor.prompt = nil }
                .keyboardShortcut(.defaultAction)
        }
    }
}
