#if DEBUG
import SwiftUI
import WortschatzCore

/// Snapshot scenes of the Settings window (`--render-snapshots <dir> --snapshot-filter settings-`):
/// every tab at its pane size on the in-memory sample library, in light and dark, plus the
/// Daten tab of an empty library and both steps of "Alle Daten löschen". The window's toolbar
/// tabs are not part of the capture (borderless snapshot window).
final class SettingsSnapshots: SnapshotCatalog {
    override class var scenes: [SnapshotScene] {
        SettingsTab.allCases.map { tab in
            SnapshotScene("settings-\(tab.rawValue)", size: tab.size) {
                SettingsSnapshotHost(.populated) { SettingsSnapshotPane(tab: tab) }
            }
        } + [
            SnapshotScene("settings-data-empty", size: SettingsTab.data.size) {
                SettingsSnapshotHost(.empty) { SettingsSnapshotPane(tab: .data) }
            },
            SnapshotScene("settings-data-file", size: SettingsTab.data.size, colorSchemes: [.light]) {
                SettingsSnapshotHost(model: SettingsSnapshotData.fileModel()) { SettingsSnapshotPane(tab: .data) }
            },
            SnapshotScene("settings-learn-custom", size: SettingsTab.learn.size) {
                SettingsSnapshotHost(.populated, study: SettingsSnapshotData.customLearn) {
                    SettingsSnapshotPane(tab: .learn)
                }
            },
            SnapshotScene("settings-wipe-explain", size: CGSize(width: 480, height: 250)) {
                SettingsSnapshotHost(.populated) {
                    SettingsWipeSheet(step: .explain)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(.background)
                }
            },
            SnapshotScene("settings-wipe-confirm", size: CGSize(width: 480, height: 190)) {
                SettingsSnapshotHost(.populated) {
                    SettingsWipeSheet(step: .confirm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(.background)
                }
            },
        ]
    }
}

/// Changed settings for the scenes that show non-default values.
enum SettingsSnapshotData {
    /// Only written questions, 10 per round, answers in both directions, read-aloud on.
    static let customLearn = StudyOptionsPatch(
        answerWith: .both, audio: true, learn: LearnOptionsPatch(roundSize: 10, mc: false, written: true))
}

extension SettingsSnapshotData {
    /// An empty library on a file that is never written (persistence off), so the Daten tab shows
    /// a real "Speicherort". The file lies in the snapshot process's temporary folder.
    @MainActor
    static func fileModel() -> AppModel {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "WortschatzSettingsSnapshot/Library/Application Support/Wortschatz/library.json")
        return AppModel(store: LibraryStore(backend: FileBackend(url: url)), persistence: .disabled)
    }
}

/// A sample model in the environment, optionally with changed study defaults.
private struct SettingsSnapshotHost<Content: View>: View {
    @State private var model: AppModel
    private let content: Content

    init(_ scenario: SampleLibrary.Scenario, study: StudyOptionsPatch? = nil, @ViewBuilder content: () -> Content) {
        let model = SampleLibrary.model(scenario)
        if let study {
            _ = try? model.store.updateSettings(SettingsPatch(study: study))
        }
        self.init(model: model, content: content)
    }

    init(model: AppModel, @ViewBuilder content: () -> Content) {
        _model = State(initialValue: model)
        self.content = content()
    }

    var body: some View {
        content
            .environment(model)
            .environment(model.toasts)
    }
}

/// One settings tab as it sits in the window.
private struct SettingsSnapshotPane: View {
    let tab: SettingsTab

    var body: some View {
        switch tab {
        case .general: SettingsGeneralTab()
        case .learn: SettingsLearnTab()
        case .write: SettingsWriteTab()
        case .tolerance: SettingsToleranceTab()
        case .data: SettingsDataTab()
        }
    }
}
#endif
