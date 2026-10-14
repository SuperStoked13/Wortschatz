import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WortschatzCore

/// Daten: backup export and import (compatible with the web app), moving over from the web
/// version, the library's location in the Finder and "Alle Daten löschen…". The panels and the
/// import sheet open in the Settings window itself; the import runs through the shell
/// (`BackupImportSheet` → `AppModel.performBackupImport`), which also shows the summary toast.
struct SettingsDataTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var exportFile: BackupExportFile?
    @State private var isChoosingBackup = false
    @State private var importPreview: BackupImportPreview?
    @State private var importError: String?
    @State private var isConfirmingWipe = false
    @State private var isDropTargeted = false
    /// The size of a backup right now (for the summary under the backup rows).
    @State private var backupSize: Int?

    var body: some View {
        let sets = model.library.sets.map(\.set)
        Form {
            backupSection(sets: sets)
            webMigrationSection
            locationSection
        }
        .formStyle(.grouped)
        .task(id: model.revision) {
            backupSize = SettingsBackup.byteCount(model: model)
        }
        .settingsBackupExporter(file: $exportFile, model: model)
        .fileImporter(isPresented: $isChoosingBackup, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                prepareImport(url)
            case let .failure(error):
                if (error as? CocoaError)?.code != .userCancelled {
                    importError = AppModel.message(for: error, fallback: Backup.READ_ERROR)
                }
            }
        }
        .sheet(item: $importPreview) { preview in
            BackupImportSheet(preview: preview)
                .environment(model)
        }
        .sheet(isPresented: $isConfirmingWipe) {
            SettingsWipeSheet()
                .environment(model)
                .environment(model.toasts)
        }
        .alert(
            "Backup kann nicht importiert werden",
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } }),
            presenting: importError
        ) { _ in
            Button("OK") {}
                .keyboardShortcut(.defaultAction)
        } message: { message in
            Text(message)
        }
        .dropDestination(for: URL.self) { urls, _ in
            isDropTargeted = false
            if let url = urls.first { prepareImport(url) }
        }
        .onDropSessionUpdated { session in
            switch session.phase {
            case .entering, .active: isDropTargeted = true
            default: isDropTargeted = false
            }
        }
        .overlay {
            if isDropTargeted {
                SettingsDropHighlight()
                    .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: isDropTargeted)
    }

    // MARK: Sections

    private func backupSection(sets: [VocabSet]) -> some View {
        Section {
            LabeledContent {
                Button("Exportieren…") { exportFile = SettingsBackup.makeFile(model: model) }
                    .accessibilityLabel("Backup exportieren")
            } label: {
                Label {
                    Text("Backup exportieren")
                    Text("Alle Lernsets, dein Fortschritt und deine Einstellungen als Datei.")
                } icon: {
                    SettingsRowIcon(systemImage: "square.and.arrow.up", tint: Theme.accent)
                }
            }
            LabeledContent {
                Button("Importieren…") { isChoosingBackup = true }
                    .accessibilityLabel("Backup importieren")
            } label: {
                Label {
                    Text("Backup importieren")
                    Text("Eine Backup-Datei (.json) wählen oder hierher ziehen.")
                } icon: {
                    SettingsRowIcon(systemImage: "square.and.arrow.down", tint: Theme.accent)
                }
            }
        } header: {
            Text("Backup")
        } footer: {
            Label(SettingsCopy.librarySummary(sets: sets, bytes: backupSize), systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var webMigrationSection: some View {
        Section {
            ForEach(Array(SettingsCopy.webMigrationSteps.enumerated()), id: \.offset) { index, step in
                LabeledContent {
                    if index == SettingsCopy.webMigrationSteps.count - 1 {
                        Button("Backup-Datei wählen…") { isChoosingBackup = true }
                    }
                } label: {
                    Label {
                        Text(step.title)
                        Text(step.text)
                    } icon: {
                        Text("\(index + 1)")
                            .font(.system(.callout, design: .rounded).weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Theme.accent.gradient, in: Circle())
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Schritt \(index + 1): \(step.title). \(step.text)")
                }
            }
        } header: {
            Text("Aus der Web-Version übernehmen")
        }
    }

    private var locationSection: some View {
        Section {
            LabeledContent {
                Button("Im Finder zeigen") { revealLibrary() }
                    .disabled(model.libraryFileURL == nil)
                    .accessibilityLabel("Speicherort im Finder zeigen")
            } label: {
                Label {
                    Text("Speicherort")
                    if let url = model.libraryFileURL {
                        Text(SettingsCopy.displayPath(url.deletingLastPathComponent()))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(url.deletingLastPathComponent().path(percentEncoded: false))
                    } else {
                        Text("Diese Bibliothek liegt nur im Arbeitsspeicher und wird nicht gesichert.")
                    }
                } icon: {
                    SettingsRowIcon(systemImage: "folder", tint: Theme.info.fill)
                }
            }
            LabeledContent {
                Button("Alle Daten löschen…", role: .destructive) { isConfirmingWipe = true }
                    .tint(Theme.failure.fill)
            } label: {
                Label {
                    Text("Neu beginnen")
                    Text("Entfernt Lernsets, Fortschritt, Statistik und Einstellungen.")
                } icon: {
                    SettingsRowIcon(systemImage: "trash", tint: Theme.failure.fill)
                }
            }
        } header: {
            Text("Auf diesem Mac")
        }
    }

    // MARK: Actions

    /// Validates a chosen or dropped file and opens the import sheet (or explains the problem).
    private func prepareImport(_ url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)
        guard type?.conforms(to: .json) == true else {
            importError = "Bitte wähle eine Backup-Datei im JSON-Format."
            return
        }
        do {
            importPreview = try model.prepareBackupImport(from: url)
        } catch {
            importError = AppModel.message(for: error, fallback: "Diese Datei ist kein gültiges Wortschatz-Backup.")
        }
    }

    /// Shows the library file in the Finder (its folder if nothing was saved yet).
    private func revealLibrary() {
        guard let url = model.libraryFileURL else { return }
        model.save()
        let target = FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

/// A small tinted symbol in front of a settings row, like the rows of System Settings.
struct SettingsRowIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(tint.gradient, in: .rect(cornerRadius: 6))
            .accessibilityHidden(true)
    }
}

/// The frame shown while a file is dragged over the Daten tab.
private struct SettingsDropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radii.panel, style: .continuous)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Theme.accentSoft, in: .rect(cornerRadius: Radii.panel))
            .overlay {
                Label("Backup hier ablegen", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .foregroundStyle(Theme.accentText)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(Spacing.s)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Backup export

/// Backup files for the Settings window's own save panel.
enum SettingsBackup {
    /// The current library as a backup file (`wortschatz-backup-YYYY-MM-DD.json`), or nil after
    /// reporting why it could not be built.
    static func makeFile(model: AppModel) -> BackupExportFile? {
        do {
            let data = try Backup.jsonData(model.store.exportAll())
            return BackupExportFile(data: data, fileName: Backup.backupFileName(timeZone: model.store.timeZone))
        } catch {
            model.report(error, fallback: "Das Backup konnte nicht erstellt werden.")
            return nil
        }
    }

    /// The size a backup of the library has right now (nil if it cannot be built).
    static func byteCount(model: AppModel) -> Int? {
        try? Backup.jsonData(model.store.exportAll()).count
    }
}

private struct SettingsBackupExporter: ViewModifier {
    @Binding var file: BackupExportFile?
    let model: AppModel

    func body(content: Content) -> some View {
        content.fileExporter(
            isPresented: Binding(get: { file != nil }, set: { if !$0 { file = nil } }),
            document: file?.document,
            contentType: .json,
            defaultFilename: file?.fileName
        ) { result in
            file = nil
            switch result {
            case let .success(url):
                model.toasts.show("Backup gespeichert: \(url.lastPathComponent)", tone: .success)
            case let .failure(error):
                if (error as? CocoaError)?.code == .userCancelled { return }
                model.report(error, fallback: "Das Backup konnte nicht gespeichert werden.")
            }
        }
    }
}

extension View {
    /// The save panel for a backup file (shows it while `file` is set; reports the result).
    func settingsBackupExporter(file: Binding<BackupExportFile?>, model: AppModel) -> some View {
        modifier(SettingsBackupExporter(file: file, model: model))
    }
}
