import SwiftUI
import WortschatzCore

/// The actions of a set, shared by the sidebar's context menu, the overview's set cards and
/// the set detail's "…" menu (spec §4.1: Lernen, Schreiben, Karteikarten, Prüfung, Bearbeiten,
/// Duplizieren, Als Text exportieren…, Löschen with undo).
struct SetActionsMenu: View {
    let summary: SetSummary
    /// The set detail shows Lernen/Schreiben/Bearbeiten as buttons already.
    var includesStudy = true

    @Environment(AppModel.self) private var model

    var body: some View {
        let id = summary.id
        if includesStudy {
            Button(summary.learn != nil ? "Weiterlernen" : "Lernen", systemImage: summary.learn != nil ? "play.fill" : "sparkles") {
                model.continueLearn(setID: id)
            }
            .disabled(summary.isEmpty)
            Button(summary.write != nil ? "Schreiben fortsetzen" : "Schreiben", systemImage: "keyboard") {
                model.continueWrite(setID: id)
            }
            .disabled(summary.isEmpty)
            Button("Karteikarten", systemImage: FlashcardsSymbols.mode) {
                model.continueFlashcards(setID: id)
            }
            .disabled(summary.isEmpty)
            Button("Prüfung", systemImage: ExamSymbols.mode) {
                model.startExam(setID: id)
            }
            .disabled(summary.isEmpty)
            Divider()
            Button("Bearbeiten", systemImage: "pencil") {
                model.openEditor(.edit(setID: id))
            }
        }
        Button("Duplizieren", systemImage: "plus.square.on.square") {
            model.duplicateSet(id)
        }
        Button("Als Text exportieren…", systemImage: "square.and.arrow.up") {
            model.exportText(id)
        }
        .disabled(summary.isEmpty)
        if !includesStudy {
            Divider()
            Button("Fortschritt zurücksetzen…", systemImage: "arrow.counterclockwise") {
                model.confirmResetProgress(id)
            }
            .disabled(!summary.canReset)
        }
        Divider()
        Button("Löschen", systemImage: "trash", role: .destructive) {
            model.deleteSet(id)
        }
    }
}
