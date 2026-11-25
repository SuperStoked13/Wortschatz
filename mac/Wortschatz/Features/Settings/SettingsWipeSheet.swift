import AppKit
import SwiftUI
import WortschatzCore

/// "Alle Daten löschen…" with two confirmations (`wipeEverything` in src/screens/settings.js):
/// first what will be gone, with a backup offer; then "Wirklich alles löschen?". Return moves on
/// in the first step and cancels in the second, so two presses of Return never delete anything.
/// Esc cancels in both.
struct SettingsWipeSheet: View {
    enum Step {
        case explain, confirm
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Step
    @State private var exportFile: BackupExportFile?

    init(step: Step = .explain) {
        _step = State(initialValue: step)
    }

    var body: some View {
        let sets = model.library.sets.map(\.set)
        VStack(alignment: .leading, spacing: Spacing.l) {
            switch step {
            case .explain:
                header(
                    systemImage: "trash", title: String(localized: "Alle Daten löschen?"),
                    message: SettingsCopy.wipeMessage(sets: sets) + extraNote)
                if !sets.isEmpty { backupTip }
            case .confirm:
                header(
                    systemImage: "exclamationmark.triangle.fill", title: String(localized: "Wirklich alles löschen?"),
                    message: String(
                        localized: "Das kann nicht rückgängig gemacht werden. Ohne Backup sind deine Lernsets danach endgültig weg."
                    ))
            }
            buttons
        }
        .padding(Spacing.xl)
        .frame(width: 480)
        // Esc cancels: the first step through its "Abbrechen" button, the second (whose default
        // button "Abbrechen" is bound to Return) here.
        .onExitCommand(perform: step == .confirm ? { dismiss() } : nil)
        .settingsBackupExporter(file: $exportFile, model: model)
    }

    private func header(systemImage: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.failure.fill)
                .frame(width: 44, height: 44)
                .background(Theme.failure.soft, in: .rect(cornerRadius: Radii.small))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(Typography.title)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var backupTip: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "lightbulb")
                .foregroundStyle(Theme.warning.fill)
                .accessibilityHidden(true)
            Text("Tipp: Sichere vorher ein Backup.")
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Backup exportieren…") { exportFile = SettingsBackup.makeFile(model: model) }
        }
        .padding(Spacing.s)
        .background(Theme.warning.soft, in: .rect(cornerRadius: Radii.small))
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            switch step {
            case .explain:
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                PrimaryActionButton("Weiter", tint: Theme.failure.fill) { advance() }
            case .confirm:
                Button("Endgültig löschen", role: .destructive) { wipe() }
                    .tint(Theme.failure.fill)
                    .controlSize(.large)
                PrimaryActionButton("Abbrechen") { dismiss() }
            }
        }
    }

    private func advance() {
        // Ignore a held Return: the second step must be confirmed on purpose.
        if NSApp.currentEvent?.isARepeat == true { return }
        withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
            step = .confirm
        }
        Announcer.announce(String(localized: "Wirklich alles löschen? Das kann nicht rückgängig gemacht werden."))
    }

    /// What else wiping does, if anything (added to the explanation).
    private var extraNote: String {
        ""
    }

    /// Clears the library, the settings and the chosen voices, saves at once, removes the older
    /// copies of the library file and confirms.
    private func wipe() {
        do {
            try model.store.clearAll()
        } catch {
            model.report(error, fallback: String(localized: "Die Daten konnten nicht gelöscht werden."))
            dismiss()
            return
        }
        let speech = model.speech
        for lang in Lang.allCases where speech.preferredVoiceIDs[lang] != nil {
            speech.setPreferredVoice(nil, for: lang)
        }
        model.save()
        // "von diesem Mac gelöscht": the rotating backups and a set-aside damaged copy go too,
        // so no recovery can bring the deleted sets back.
        model.store.backend.discardBackups()
        model.toasts.show(String(localized: "Alle Daten wurden gelöscht."), tone: .success)
        dismiss()
    }
}
