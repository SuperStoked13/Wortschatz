import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WortschatzCore

// Set and data actions of the app (context menus, the set detail's "…" menu, the Ablage and
// Lernset menus). Ports of the actions in src/screens/dashboard.js, set.js and settings.js.

extension AppModel {
    // MARK: Set actions

    /// "Duplizieren": a copy at the top, with a toast that opens it.
    func duplicateSet(_ setID: String) {
        guard let set = store.getSet(setID) else { return }
        do {
            let copy = try store.duplicateSet(setID)
            toasts.show(
                "Kopie von «\(Self.shortTitle(set.title))» erstellt", tone: .success,
                action: .init("Öffnen") { [weak self] in self?.showSet(copy.id) })
        } catch {
            report(error, fallback: "Das Lernset konnte nicht dupliziert werden.")
        }
    }

    /// "Löschen" (⌘⌫): deletes at once; ⌘Z or the toast's "Rückgängig" puts the set back with
    /// its progress and running sessions.
    func deleteSet(_ setID: String) {
        guard let snapshot = store.snapshotSet(setID) else { return }
        do {
            try store.deleteSet(setID)
        } catch {
            report(error, fallback: "Das Lernset konnte nicht gelöscht werden.")
            return
        }
        let record = DeletedSet(snapshot: snapshot)
        let undo = undoManager
        registerRestore(of: record, on: undo)
        let title = Self.shortTitle(snapshot.set.title)
        toasts.show(
            "«\(title)» gelöscht", systemImage: "trash",
            action: .init("Rückgängig") { [weak self] in
                guard let self else { return }
                // The undo stack must not restore it a second time.
                undo.removeAllActions(withTarget: record)
                restoreDeleted(record, via: nil)
            },
            duration: .seconds(7))
        Announcer.announce("Lernset «\(title)» gelöscht")
    }

    /// Registers "Widerrufen: Lernset löschen" for a deleted set.
    ///
    /// `UndoManager` does not retain its target, so the handler holds the record itself: it has
    /// to outlive the toast (whose "Rückgängig" is the only other reference and is gone after
    /// 7 seconds) for as long as the action is on the undo stack. The manager is captured weakly,
    /// because it owns the handler (it is alive whenever it runs one).
    private func registerRestore(of record: DeletedSet, on undo: UndoManager) {
        undo.registerUndo(withTarget: record) { [weak self, weak undo] _ in
            self?.restoreDeleted(record, via: undo)
        }
        undo.setActionName("Lernset löschen")
    }

    /// Puts a deleted set back. With an undo manager (an undo, not the toast) the redo deletes
    /// it again.
    private func restoreDeleted(_ record: DeletedSet, via undo: UndoManager?) {
        let snapshot = record.snapshot
        guard store.getSet(snapshot.set.id) == nil else { return }
        do {
            let set = try store.restoreSet(snapshot)
            if let undo {
                // As in `registerRestore`: the handler keeps the record alive.
                undo.registerUndo(withTarget: record) { [weak self, weak undo] _ in
                    guard let undo else { return }
                    self?.deleteRestored(set.id, record: record, via: undo)
                }
                undo.setActionName("Lernset löschen")
            }
            toasts.show("«\(Self.shortTitle(set.title))» wiederhergestellt", tone: .success)
            if route == .overview || route.setID == nil { showSet(set.id) }
        } catch {
            report(error, fallback: "Das Lernset konnte nicht wiederhergestellt werden.")
        }
    }

    /// Redo of a restored deletion.
    private func deleteRestored(_ setID: String, record: DeletedSet, via undo: UndoManager) {
        guard let snapshot = store.snapshotSet(setID) else { return }
        do {
            try store.deleteSet(setID)
        } catch {
            report(error)
            return
        }
        record.snapshot = snapshot
        registerRestore(of: record, on: undo)
    }

    /// "Fortschritt zurücksetzen…": asks first (Return keeps everything), then forgets the
    /// progress and ends running sessions.
    func confirmResetProgress(_ setID: String) {
        guard store.getSet(setID) != nil else { return }
        confirm(ConfirmationRequest(
            title: "Fortschritt zurücksetzen?",
            message: "Alle Begriffe gelten danach wieder als «Neu», und laufende Runden in Lernen und Schreiben werden beendet. Die Begriffe selbst bleiben erhalten.",
            confirmLabel: "Zurücksetzen",
            isDestructive: true
        ) { [weak self] in
            guard let self else { return }
            do {
                try store.resetProgress(setID)
                toasts.show("Fortschritt zurückgesetzt", tone: .success)
            } catch {
                report(error)
            }
        })
    }

    /// The ★ toggle of a card.
    func toggleStar(setID: String, cardID: String) {
        do {
            let starred = try store.toggleStar(setID, cardID)
            Announcer.announce(starred ? "Markiert" : "Markierung entfernt")
        } catch {
            report(error)
        }
    }

    /// "Als Text exportieren…": opens the export sheet (separators, preview, copy, save).
    func exportText(_ setID: String) {
        guard !isPresentingSheet, let set = store.getSet(setID), !set.cards.isEmpty else { return }
        textExport = TextExportRequest(setID: setID)
    }

    // MARK: Backup

    /// "Backup exportieren…": the save panel for `wortschatz-backup-YYYY-MM-DD.json`.
    func exportBackup() {
        do {
            let data = try Backup.jsonData(store.exportAll())
            backupExport = BackupExportFile(data: data, fileName: Backup.backupFileName(timeZone: store.timeZone))
        } catch {
            report(error, fallback: "Das Backup konnte nicht erstellt werden.")
        }
    }

    /// Result of the backup save panel.
    func backupExportFinished(_ result: Result<URL, any Error>) {
        let name = backupExport?.fileName
        backupExport = nil
        switch result {
        case let .success(url):
            toasts.show("Backup gespeichert: \(name ?? url.lastPathComponent)", tone: .success)
        case let .failure(error):
            if (error as? CocoaError)?.code == .userCancelled { return }
            report(error, fallback: "Das Backup konnte nicht gespeichert werden.")
        }
    }

    /// "Backup importieren…": the file chooser, then the import sheet.
    func importBackup() {
        guard !isPresentingSheet else { return }
        isChoosingBackup = true
    }

    /// "Aus der Web-Version übernehmen…": the how-to sheet that leads to the file chooser.
    func showWebMigration() {
        guard !isPresentingSheet else { return }
        isShowingWebMigration = true
    }

    /// Result of the backup file chooser.
    func backupFileChosen(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            do {
                backupImport = try prepareBackupImport(from: url)
            } catch {
                report(error, fallback: "Diese Datei ist kein gültiges Wortschatz-Backup.")
            }
        case let .failure(error):
            if (error as? CocoaError)?.code == .userCancelled { return }
            report(error, fallback: Backup.READ_ERROR)
        }
    }

    /// A backup chosen inside another sheet (the web migration how-to): validated now, shown in
    /// the import sheet once that sheet is gone (`webMigrationDismissed()`). True when the file
    /// is a valid backup.
    func stageBackupImport(_ result: Result<URL, any Error>) -> Bool {
        switch result {
        case let .success(url):
            do {
                stagedBackupImport = try prepareBackupImport(from: url)
                return true
            } catch {
                report(error, fallback: "Diese Datei ist kein gültiges Wortschatz-Backup.")
                return false
            }
        case let .failure(error):
            if (error as? CocoaError)?.code != .userCancelled { report(error, fallback: Backup.READ_ERROR) }
            return false
        }
    }

    /// Called when the web migration sheet is gone: opens the import sheet for a staged backup.
    func webMigrationDismissed() {
        guard let staged = stagedBackupImport else { return }
        stagedBackupImport = nil
        backupImport = staged
    }

    /// Reads and validates a backup file (web or Mac) without touching the library.
    func prepareBackupImport(from url: URL) throws -> BackupImportPreview {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackupFileError(message: Backup.READ_ERROR)
        }
        let json = try Backup.readJSON(data)
        let sets = try LibraryStore.previewImport(json)
        return BackupImportPreview(
            fileName: url.lastPathComponent, payload: json, sets: sets, existing: store.listSets(),
            exportedAt: json["exportedAt"]?.finiteNumber)
    }

    /// Imports a previewed backup and reports the result (`runImport` in settings.js).
    func performBackupImport(_ preview: BackupImportPreview, mode: ImportMode) {
        backupImport = nil
        let result: ImportSummary
        do {
            result = try store.importAll(preview.payload, mode: mode)
        } catch {
            report(error, fallback: "Das Backup konnte nicht importiert werden.")
            return
        }
        let total = result.setsAdded + result.setsUpdated
        let message: String
        if mode == .replace {
            message = "Backup wiederhergestellt: \(Labels.plural(total, "Lernset", "Lernsets"))"
        } else {
            var parts: [String] = []
            if result.setsAdded > 0 { parts.append(Labels.plural(result.setsAdded, "neues Lernset", "neue Lernsets")) }
            if result.setsUpdated > 0 { parts.append("\(result.setsUpdated) aktualisiert") }
            message = parts.isEmpty ? "Backup importiert – keine Änderungen" : "Backup importiert: \(parts.joined(separator: ", "))"
        }
        toasts.show(message, tone: .success, duration: .seconds(5))
        if route.isStudy == false { showOverview() }
        save()
    }

    // MARK: Text input safety

    /// ⌘⌫ means "delete to the start of the line" while typing: the Lernset menu's "Löschen"
    /// forwards it to the text field instead of deleting the set.
    func deleteCommand(setID: String) {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isEditable {
            textView.deleteToBeginningOfLine(nil)
            return
        }
        deleteSet(setID)
    }
}

/// A deleted set's snapshot, the target of its undo/redo actions (their handlers retain it; the
/// undo manager does not).
final class DeletedSet {
    var snapshot: SetSnapshot

    init(snapshot: SetSnapshot) {
        self.snapshot = snapshot
    }
}

/// The "Als Text exportieren" sheet's set.
struct TextExportRequest: Identifiable, Hashable {
    let id = UUID()
    var setID: String
}

/// A backup waiting for the save panel.
struct BackupExportFile: Identifiable {
    let id = UUID()
    var data: Data
    var fileName: String

    var document: DataFileDocument { DataFileDocument(data: data, contentType: .json) }
}

/// A read, validated backup and what importing it would do (`openImportDialog` in settings.js).
struct BackupImportPreview: Identifiable {
    let id = UUID()
    var fileName: String
    var payload: JSONValue
    /// The backup's sets, sanitised like an import would store them.
    var sets: [VocabSet]
    /// The library's sets before the import.
    var existing: [VocabSet]
    var exportedAt: Double?

    var cardCount: Int { sets.reduce(0) { $0 + $1.cards.count } }
    /// Backup sets whose id is already in the library (merge replaces them).
    var updates: Int {
        let ids = Set(existing.map(\.id))
        return sets.filter { ids.contains($0.id) }.count
    }

    var additions: Int { sets.count - updates }
    /// Library sets the backup does not contain (replace loses them).
    var lost: Int {
        let ids = Set(sets.map(\.id))
        return existing.filter { !ids.contains($0.id) }.count
    }

    var libraryIsEmpty: Bool { existing.isEmpty }

    /// "3 Lernsets · 120 Begriffe · vom 12.10.2026".
    func meta(timeZone: TimeZone = .current) -> String {
        var parts = [Labels.plural(sets.count, "Lernset", "Lernsets"), Labels.plural(cardCount, "Begriff", "Begriffe")]
        if let exportedAt {
            let date = TimeUtil.formatDate(exportedAt, timeZone: timeZone)
            if !date.isEmpty { parts.append("vom \(date)") }
        }
        return parts.joined(separator: " · ")
    }

    var mergeDetail: String {
        var parts: [String] = []
        if additions > 0 { parts.append(Labels.plural(additions, "neues Lernset", "neue Lernsets")) }
        if updates > 0 { parts.append("\(updates) \(updates == 1 ? "wird" : "werden") durch die Backup-Version ersetzt") }
        return parts.isEmpty ? "Keine Änderungen" : parts.joined(separator: " · ")
    }

    var replaceDetail: String {
        switch lost {
        case 0: "Alle deine Lernsets sind im Backup enthalten."
        case 1: "1 Lernset, das nicht im Backup ist, geht verloren."
        default: "\(lost) Lernsets, die nicht im Backup sind, gehen verloren."
        }
    }
}

/// A file document of raw bytes (backups, text exports) for `fileExporter`.
nonisolated struct DataFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json, .plainText]
    static let writableContentTypes: [UTType] = [.json, .plainText]

    var data: Data
    var contentType: UTType

    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }

    /// UTF-8 text without BOM, like the web app's downloads.
    init(text: String) {
        self.init(data: Data(text.utf8), contentType: .plainText)
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
