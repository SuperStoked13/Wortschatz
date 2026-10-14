#if DEBUG
import AppKit
import SwiftUI
import WortschatzCore

/// Snapshot scenes of the set editor (`--render-snapshots <dir> --snapshot-filter editor-`).
/// Each scene drives a real `SetEditorModel` on the in-memory sample library; "pasted" uses
/// the user's 52-pair list laid out like tests/fixtures/user-example.txt.
final class SetEditorSnapshots: SnapshotCatalog {
    /// The sheet's ideal size.
    static let size = CGSize(width: 1000, height: 800)
    /// Tall enough to show the whole import panel and the first cards.
    static let tallSize = CGSize(width: 1000, height: 1640)
    /// The smallest sheet.
    static let compactSize = CGSize(width: 900, height: 680)

    override class var scenes: [SnapshotScene] {
        SetEditorSnapshotScenario.allCases.map { scenario in
            SnapshotScene("editor-\(scenario.rawValue)", sizes: scenario.sizes, settleTime: 0.9) {
                SetEditorSnapshotHost(scenario)
            }
        }
    }
}

/// The states rendered by `SetEditorSnapshots`.
enum SetEditorSnapshotScenario: String, CaseIterable {
    /// "Neues Lernset", nothing typed.
    case new
    /// The user's 52-pair list pasted into the import box.
    case pasted
    /// The pasted list taken over into the cards.
    case applied
    /// An existing set (the 52 pairs) opened for editing.
    case edit
    /// A save attempt without title, with an incomplete and a duplicate card.
    case validation
    /// A messy list: headings, a page number, flagged pairs and skipped lines.
    case review

    var sizes: [CGSize] {
        switch self {
        case .new: [SetEditorSnapshots.size, SetEditorSnapshots.compactSize]
        case .pasted, .review: [SetEditorSnapshots.size, SetEditorSnapshots.tallSize]
        case .applied, .edit, .validation: [SetEditorSnapshots.size]
        }
    }
}

/// The editor on a scripted model.
private struct SetEditorSnapshotHost: View {
    @State private var app: AppModel
    @State private var editor: SetEditorModel

    init(_ scenario: SetEditorSnapshotScenario) {
        let (app, editor) = SetEditorSnapshotScript.make(scenario)
        _app = State(initialValue: app)
        _editor = State(initialValue: editor)
    }

    var body: some View {
        SetEditorView(editor: editor)
            .environment(app)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Builds each scenario's model through the editor's own API.
@MainActor
enum SetEditorSnapshotScript {
    /// The user's list as in tests/fixtures/user-example.txt: term and translation on
    /// alternating lines, separated by runs of blank lines.
    static var userListText: String {
        SampleLibrary.userPairs.enumerated().map { index, pair in
            "\(pair.0)\n\(pair.1)" + String(repeating: "\n", count: index % 2 == 0 ? 5 : 6)
        }.joined()
    }

    /// A list as it comes out of a scanned worksheet.
    static let messyListText = """
        Unité 4 – La maison
        Vocabulaire

        la maison – das Haus
        le jardin – der Garten
        la cuisine – die Küche
        la chambre – das Schlafzimmer
        le salon
        la salle de bains – das Badezimmer
        l'escalier – die Treppe
        12
        le toit – das Dach
        la fenêtre – das Fenster
        la porte – die Tür
        le mur – the wall
        """

    static func make(_ scenario: SetEditorSnapshotScenario) -> (AppModel, SetEditorModel) {
        let app = SampleLibrary.model(.fresh)
        let setID = app.store.listSets().first?.id ?? ""
        switch scenario {
        case .new:
            return (app, SetEditorModel(app: app, request: EditorRequest(.new)))
        case .pasted:
            let editor = SetEditorModel(app: app, request: EditorRequest(.new))
            editor.importPanel.setText(userListText, append: false)
            return (app, editor)
        case .applied:
            let editor = SetEditorModel(app: app, request: EditorRequest(.new))
            editor.setTitle(SampleLibrary.mainSetTitle)
            editor.importPanel.setText(userListText, append: false)
            editor.applyImport()
            editor.toasts.dismissAll()
            return (app, editor)
        case .edit:
            return (app, SetEditorModel(app: app, request: EditorRequest(.edit(setID: setID))))
        case .validation:
            let editor = SetEditorModel(app: app, request: EditorRequest(.new))
            editor.importPanel.isExpanded = false
            let rows = editor.rows
            editor.setTerm(rows[0], "la maison")
            editor.setDefinition(rows[0], "das Haus")
            editor.setTerm(rows[1], "le jardin")
            let third = editor.addRow(focus: false)
            editor.setTerm(third, "la maison")
            editor.setDefinition(third, "das Heim")
            editor.save()
            return (app, editor)
        case .review:
            let editor = SetEditorModel(app: app, request: EditorRequest(.new))
            editor.importPanel.setText(messyListText, append: false)
            editor.importPanel.showsSkippedLines = true
            return (app, editor)
        }
    }
}
#endif
