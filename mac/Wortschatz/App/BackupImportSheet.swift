import SwiftUI
import WortschatzCore

/// "Backup importieren" (port of `openImportDialog` in src/screens/settings.js): shows what
/// the file contains and lets the learner merge it into the library or replace everything.
/// Return imports, Esc cancels. Works with backups of the web app and of this app.
///
/// Presented by the main window for the Ablage menu; other screens (Settings) can present it
/// for a preview they got from `AppModel.prepareBackupImport(from:)`.
struct BackupImportSheet: View {
    let preview: BackupImportPreview

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ImportMode

    init(preview: BackupImportPreview) {
        self.preview = preview
        _mode = State(initialValue: preview.libraryIsEmpty ? .replace : .merge)
    }

    private var isDestructive: Bool { mode == .replace && !preview.libraryIsEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Backup importieren")
                .font(Typography.title)

            fileInfo

            if preview.libraryIsEmpty {
                Text("Das Backup wird vollständig wiederhergestellt – mit Lernfortschritt, Statistik und Einstellungen.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Wie möchtest du importieren?")
                        .font(.headline)
                    Picker("Wie möchtest du importieren?", selection: $mode) {
                        choice(
                            title: "Zusammenführen",
                            text: "Lernsets aus dem Backup kommen dazu. Deine übrigen Lernsets und Einstellungen bleiben erhalten.",
                            detail: preview.mergeDetail, isDanger: false
                        )
                        .tag(ImportMode.merge)
                        choice(
                            title: "Alles ersetzen",
                            text: "Alle aktuellen Lernsets, der Fortschritt und die Einstellungen werden durch das Backup ersetzt.",
                            detail: preview.replaceDetail, isDanger: true
                        )
                        .tag(ImportMode.replace)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                PrimaryActionButton(
                    verbatim: isDestructive ? "Alles ersetzen" : "Importieren",
                    tint: isDestructive ? Theme.failure.fill : nil
                ) {
                    model.performBackupImport(preview, mode: mode)
                    dismiss()
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 520)
    }

    private var fileInfo: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Radii.small, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(preview.meta(timeZone: model.store.timeZone))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func choice(title: String, text: String, detail: String, isDanger: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .fontWeight(.semibold)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.callout.weight(.medium))
                .foregroundStyle(isDanger ? Theme.failure.text : Theme.accentText)
        }
        .padding(.vertical, Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
