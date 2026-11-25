import AppKit
import UniformTypeIdentifiers
import WortschatzCore

// Quitting (spec §4.1 "always saves on quit"): the app delegate asks the model before the app
// terminates. Unsaved changes are written first; when that fails (disk full, folder not
// writable) the learner decides, instead of the changes since the last save being lost
// without a word.

/// What the learner chose after the library could not be saved while quitting.
enum QuitAfterFailedSave: Equatable {
    /// "Nochmal versuchen" (Return): write again.
    case retry
    /// "Backup exportieren…": save everything to a backup file, then quit.
    case exportBackup
    /// "Trotzdem beenden": quit and lose the unsaved changes.
    case quitAnyway
    /// "Abbrechen" (esc): keep the app running.
    case stay
}

extension AppModel {
    /// `applicationShouldTerminate`: writes unsaved changes, and if that fails asks
    /// (`askAfterFailedSave`) until the changes are saved, exported or knowingly given up.
    ///
    /// - Parameters:
    ///   - ask: Shows the failure (its German message) and returns the learner's choice.
    ///   - exportBackup: Saves the backup document under the suggested file name; false when it
    ///     was cancelled or failed (the question then comes again).
    func replyToTermination(
        ask: @MainActor (_ message: String) -> QuitAfterFailedSave = AppModel.askAfterFailedSave,
        exportBackup: @MainActor (_ document: Data, _ fileName: String) -> Bool = AppModel.exportBackupWithPanel
    ) -> NSApplication.TerminateReply {
        while true {
            let failure: any Error
            do {
                try saveNow()
                return .terminateNow
            } catch {
                failure = error
            }
            switch ask(Self.message(for: failure, fallback: String(localized: "Die Daten konnten nicht gespeichert werden."))) {
            case .retry:
                continue
            case .exportBackup:
                if let document = try? Backup.jsonData(store.exportAll()),
                    exportBackup(document, Backup.backupFileName(timeZone: store.timeZone))
                {
                    return .terminateNow
                }
            case .quitAnyway:
                return .terminateNow
            case .stay:
                return .terminateCancel
            }
        }
    }

    /// The alert after a failed save while quitting. "Nochmal versuchen" is the default button
    /// (Return), "Abbrechen" answers esc.
    static func askAfterFailedSave(_ message: String) -> QuitAfterFailedSave {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Deine letzten Änderungen konnten nicht gespeichert werden")
        alert.informativeText = String(
            localized: """
                \(message)

                Wenn du Wortschatz jetzt beendest, gehen die Änderungen seit dem letzten Speichern verloren. \
                Mit «Backup exportieren…» sicherst du alle Lernsets in eine Datei und beendest danach.
                """)
        alert.addButton(withTitle: String(localized: "Nochmal versuchen"))
        alert.addButton(withTitle: String(localized: "Backup exportieren…"))
        let quit = alert.addButton(withTitle: String(localized: "Trotzdem beenden"))
        quit.hasDestructiveAction = true
        let stay = alert.addButton(withTitle: String(localized: "Abbrechen"))
        stay.keyEquivalent = "\u{1b}"
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .retry
        case .alertSecondButtonReturn: return .exportBackup
        case .alertThirdButtonReturn: return .quitAnyway
        default: return .stay
        }
    }

    /// The save panel for a backup while quitting (the main window may be closed, so no sheet).
    static func exportBackupWithPanel(_ document: Data, fileName: String) -> Bool {
        let panel = NSSavePanel()
        panel.title = String(localized: "Backup exportieren")
        panel.prompt = String(localized: "Sichern", comment: "Save panel button: save the backup file")
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try document.write(to: url, options: .atomic)
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Das Backup konnte nicht gesichert werden")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }
}
