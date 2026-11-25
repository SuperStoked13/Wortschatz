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
            // Once both languages are known (not "Automatisch").
            if !editor.termIsAuto, !editor.defIsAuto {
                LanguageCapsule(termLang: editor.termLang, defLang: editor.defLang)
                    .animation(.default, value: editor.termLang)
                    .animation(.default, value: editor.defLang)
                    .transition(.opacity)
            }
        }
    }
}

/// The floating glass bar at the bottom of the sheet: the card count and what still blocks
/// saving, "Abbrechen esc" and the primary "Lernset erstellen ⌘↩" / "Sichern ⌘↩" (the only
/// button that takes cards over: pairs from the import box are cards already).
struct SetEditorActionBar: View {
    let editor: SetEditorModel

    var body: some View {
        let stats = editor.stats
        // From these stats: `editor.readiness` would count every row again.
        let blocker = SetEditorCopy.readiness(titleIsEmpty: editor.isTitleEmpty, completeCards: stats.complete)
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
                    .help(saveHelp(blocker: blocker))
                    .accessibilityIdentifier("editor-save")
            }
        }
        .frame(maxWidth: SetEditorLayout.contentWidth)
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.l)
        .frame(maxWidth: .infinity)
    }

    /// The save button's tooltip: what still blocks saving, else its keys.
    private func saveHelp(blocker: String?) -> String {
        switch (blocker, editor.isEditing) {
        case let (blocker?, true): String(localized: "\(blocker) – Sichern zeigt, was fehlt")
        case let (blocker?, false): String(localized: "\(blocker) – Erstellen zeigt, was fehlt")
        case (nil, true): String(localized: "Sichern (⌘↩ oder ⌘S)")
        case (nil, false): String(localized: "Lernset erstellen (⌘↩ oder ⌘S)")
        }
    }

    private func status(_ stats: SetEditorModel.Stats, blocker: String?) -> some View {
        var extras: [String] = []
        if stats.duplicates > 0 { extras.append(String(localized: "\(stats.duplicates) doppelt")) }
        if stats.invalid > 0 { extras.append(String(localized: "\(stats.invalid) unvollständig")) }
        if stats.typos > 0 { extras.append(String(localized: "\(stats.typos) Tippfehler?")) }
        // Both sides in the same language (Deutsch → Deutsch) went through without a word (Joan's
        // test, 06.11.2026; Windows the same): said first, before what still blocks saving.
        let isAuto = editor.termIsAuto || editor.defIsAuto
        let sameLang = !isAuto && editor.termLang == editor.defLang && editor.termLang != .other
        return HStack(spacing: Spacing.xs) {
            Text(Labels.plural(stats.filled, "Karte", "Karten"))
                .fontWeight(.semibold)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(isAuto ? String(localized: "Sprachen automatisch") : Labels.langPair(editor.termLang, editor.defLang))
                .foregroundStyle(.secondary)
            if sameLang {
                Text("·").foregroundStyle(.tertiary)
                Text("Zweimal dieselbe Sprache?")
                    .foregroundStyle(Theme.warning.text)
            }
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

/// The buttons of an editor prompt. Return takes the safe answer ("Weiter bearbeiten"); esc
/// cancels.
struct SetEditorPromptButtons: View {
    let prompt: SetEditorModel.Prompt
    let editor: SetEditorModel

    var body: some View {
        switch prompt {
        case .discard:
            Button("Verwerfen", role: .destructive) { editor.discard() }
            Button("Weiter bearbeiten", role: .cancel) { editor.prompt = nil }
                .keyboardShortcut(.defaultAction)
        }
    }
}
