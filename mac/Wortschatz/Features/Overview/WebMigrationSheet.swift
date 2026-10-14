import SwiftUI
import UniformTypeIdentifiers
import WortschatzCore

/// "Aus der Web-Version übernehmen" (spec §4.4): how to move the web app's data over, in three
/// steps, then the file chooser for the web app's backup (Return). The chosen file opens the
/// import sheet once this sheet is gone.
struct WebMigrationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isChoosingFile = false

    private static let steps: [(title: String, text: String)] = [
        ("Backup in der Web-Version sichern",
         "Öffne Wortschatz im Browser, gehe zu Einstellungen → Backup & Daten und klicke bei «Backup exportieren» auf «Exportieren»."),
        ("Datei finden",
         "Die Datei «wortschatz-backup-…json» liegt danach in deinem Download-Ordner."),
        ("Hier importieren",
         "Wähle die Datei aus. Lernsets, Lernfortschritt, Statistik und Einstellungen werden übernommen."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "globe")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Radii.small, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aus der Web-Version übernehmen")
                        .font(Typography.title)
                    Text("In drei Schritten sind deine Lernsets auf dem Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: Spacing.s) {
                        Text("\(index + 1)")
                            .font(.system(.callout, design: .rounded).weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Theme.accent, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .fontWeight(.semibold)
                            Text(step.text)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Schritt \(index + 1): \(step.title). \(step.text)")
                }
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                PrimaryActionButton("Backup-Datei wählen…", systemImage: "doc.badge.arrow.up") {
                    isChoosingFile = true
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 540)
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.json]) { result in
            if model.stageBackupImport(result) { dismiss() }
        }
    }
}
