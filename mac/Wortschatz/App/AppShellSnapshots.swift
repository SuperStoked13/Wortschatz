#if DEBUG
import SwiftUI
import WortschatzCore

/// Snapshot scenes of the app shell (window, sidebar, overview, set detail, sheets), rendered
/// with `--render-snapshots <dir> --snapshot-filter shell`. All data is in memory.
final class AppShellSnapshots: SnapshotCatalog {
    override class var scenes: [SnapshotScene] {
        [
            SnapshotScene("shell-window-overview", sizes: [SnapshotScene.windowSize, CGSize(width: 980, height: 640)]) {
                ShellWindowPreview(scenario: .populated)
            },
            SnapshotScene("shell-window-set", sizes: [SnapshotScene.windowSize, CGSize(width: 980, height: 640)]) {
                ShellWindowPreview(scenario: .populated) { model in
                    if let id = model.library.sets.first(where: { $0.set.title == SampleLibrary.mainSetTitle })?.id {
                        model.showSet(id)
                    }
                }
            },
            SnapshotScene("shell-window-search") {
                ShellWindowPreview(scenario: .populated) { model in
                    model.sidebarSearch = "visage"
                }
            },
            // Needs the LearnEngine port (getLearn → LearnEngine.copyState).
            SnapshotScene("shell-window-learning") {
                ShellWindowPreview(scenario: .learning) { model in
                    if let id = model.library.sets.first(where: { $0.set.title == SampleLibrary.mainSetTitle })?.id {
                        model.showSet(id)
                    }
                }
            },
            SnapshotScene("shell-overview-learning", size: CGSize(width: 980, height: 800)) {
                ShellScreenPreview(scenario: .learning) { OverviewScreen() }
            },
            SnapshotScene("shell-window-empty-library", size: CGSize(width: 980, height: 640)) {
                ShellWindowPreview(scenario: .empty)
            },
            SnapshotScene("shell-window-empty-set", size: CGSize(width: 980, height: 640)) {
                ShellWindowPreview(scenario: .emptySet) { model in
                    if let id = model.library.sets.first?.id { model.showSet(id) }
                }
            },
            SnapshotScene("shell-window-study", size: CGSize(width: 980, height: 640)) {
                ShellWindowPreview(scenario: .populated) { model in
                    if let id = model.library.sets.first?.id { model.study(.write, setID: id) }
                }
            },
            SnapshotScene("shell-overview-fresh", size: CGSize(width: 980, height: 800)) {
                ShellScreenPreview(scenario: .fresh) { OverviewScreen() }
            },
            SnapshotScene("shell-overview-empty", size: CGSize(width: 980, height: 800)) {
                ShellScreenPreview(scenario: .empty) { OverviewScreen() }
            },
            SnapshotScene("shell-set-filtered", size: CGSize(width: 980, height: 800)) {
                ShellScreenPreview(scenario: .populated) { model in
                    let id = model.library.sets.first { $0.set.title == SampleLibrary.mainSetTitle }?.id ?? ""
                    model.rememberTermFilter(.starred, for: id)
                    return SetDetailScreen(setID: id)
                }
            },
            SnapshotScene("shell-set-empty", size: CGSize(width: 980, height: 640)) {
                ShellScreenPreview(scenario: .emptySet) { model in
                    SetDetailScreen(setID: model.library.sets.first?.id ?? "")
                }
            },
            SnapshotScene("shell-sheet-text-export", size: CGSize(width: 600, height: 560)) {
                ShellScreenPreview(scenario: .fresh) { model in
                    TextExportSheet(request: TextExportRequest(setID: model.library.sets.first?.id ?? ""))
                }
            },
            SnapshotScene("shell-sheet-backup-import", size: CGSize(width: 520, height: 470)) {
                ShellScreenPreview(scenario: .populated) { model in
                    BackupImportSheet(preview: SampleBackup.preview(for: model))
                }
            },
            SnapshotScene("shell-sheet-web-migration", size: CGSize(width: 540, height: 420)) {
                ShellScreenPreview(scenario: .empty) { _ in WebMigrationSheet() }
            },
        ]
    }
}

/// The whole main window content on a sample library.
private struct ShellWindowPreview: View {
    @State private var model: AppModel

    init(scenario: SampleLibrary.Scenario, configure: (AppModel) -> Void = { _ in }) {
        let model = SampleLibrary.model(scenario)
        configure(model)
        _model = State(initialValue: model)
    }

    var body: some View {
        ContentView()
            .environment(model)
    }
}

/// One screen (or sheet) on a sample library.
private struct ShellScreenPreview<Content: View>: View {
    @State private var model: AppModel
    private let content: Content

    init(scenario: SampleLibrary.Scenario, @ViewBuilder content: (AppModel) -> Content) {
        let model = SampleLibrary.model(scenario)
        self.content = content(model)
        _model = State(initialValue: model)
    }

    init(scenario: SampleLibrary.Scenario, @ViewBuilder content: () -> Content) {
        self.init(scenario: scenario) { _ in content() }
    }

    var body: some View {
        content
            .environment(model)
            .environment(model.toasts)
            .background(.background)
    }
}

/// A backup preview built from the sample library itself (for the import sheet).
private enum SampleBackup {
    @MainActor
    static func preview(for model: AppModel) -> BackupImportPreview {
        var backup = model.store.exportAll()
        backup.sets = Array(backup.sets.prefix(2))
        let json = (try? JSONValue(encoding: backup)) ?? .null
        let sets = (try? LibraryStore.previewImport(json)) ?? []
        return BackupImportPreview(
            fileName: "wortschatz-backup-2026-10-11.json", payload: json, sets: sets + [sampleExtraSet],
            existing: model.store.listSets(), exportedAt: TimeUtil.nowMs() - TimeUtil.DAY)
    }

    private static let sampleExtraSet = VocabSet(
        id: "web-only", title: "Unité 2 – La famille", description: "", termLang: .fr, defLang: .de,
        cards: [Card(id: "c1", term: "la mère", definition: "die Mutter")], studyOptions: nil,
        createdAt: 0, updatedAt: 0, lastStudiedAt: nil)
}

#Preview("Hauptfenster") {
    ShellWindowPreview(scenario: .populated)
        .frame(width: 1240, height: 800)
}

#Preview("Übersicht leer") {
    ShellScreenPreview(scenario: .empty) { OverviewScreen() }
        .frame(width: 980, height: 800)
}
#endif
