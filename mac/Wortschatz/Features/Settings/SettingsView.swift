import SwiftUI
import WortschatzCore

/// The Settings window (⌘,, spec §4.4): a native macOS settings window with toolbar tabs
/// Allgemein, Lernen, Schreiben, Toleranz and Daten. Every change is stored at once as a global
/// default (`LibraryStore.updateSettings`); what a set changes in its own options still wins for
/// that set. Port of src/screens/settings.js.
///
/// Hosted by the `Settings` scene with `AppModel` and `ToastCenter` in the environment. Toasts
/// (import summary, saved backup, errors) also show here while this window is the active one.
struct SettingsView: View {
    init() {}

    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive
    @AppStorage("settings.selectedTab") private var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            Tab(SettingsTab.general.title, systemImage: SettingsTab.general.systemImage, value: .general) {
                SettingsGeneralTab()
                    .settingsPaneFrame(.general)
            }
            Tab(SettingsTab.learn.title, systemImage: SettingsTab.learn.systemImage, value: .learn) {
                SettingsLearnTab()
                    .settingsPaneFrame(.learn)
            }
            Tab(SettingsTab.write.title, systemImage: SettingsTab.write.systemImage, value: .write) {
                SettingsWriteTab()
                    .settingsPaneFrame(.write)
            }
            Tab(SettingsTab.tolerance.title, systemImage: SettingsTab.tolerance.systemImage, value: .tolerance) {
                SettingsToleranceTab()
                    .settingsPaneFrame(.tolerance)
            }
            Tab(SettingsTab.data.title, systemImage: SettingsTab.data.systemImage, value: .data) {
                SettingsDataTab()
                    .settingsPaneFrame(.data)
            }
        }
        .overlay {
            // The main window draws the same toasts; here they show only while this window is in
            // front, so feedback appears where the learner is looking.
            if appearsActive {
                ToastOverlay(center: model.toasts)
            }
        }
    }
}

/// The tabs of the Settings window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, learn, write, tolerance, data

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "Allgemein"
        case .learn: "Lernen"
        case .write: "Schreiben"
        case .tolerance: "Toleranz"
        case .data: "Daten"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .learn: "sparkles"
        case .write: "keyboard"
        case .tolerance: "checkmark.seal"
        case .data: "externaldrive"
        }
    }

    /// The pane size: the window takes it on (and animates between tabs), so every pane shows
    /// all of its rows without scrolling.
    var size: CGSize {
        let width: CGFloat = 620
        return switch self {
        case .general: CGSize(width: width, height: 470)
        case .learn: CGSize(width: width, height: 720)
        case .write: CGSize(width: width, height: 270)
        case .tolerance: CGSize(width: width, height: 500)
        case .data: CGSize(width: width, height: 580)
        }
    }
}

extension View {
    /// Gives a settings pane its fixed size (`SettingsTab.size`).
    func settingsPaneFrame(_ tab: SettingsTab) -> some View {
        frame(width: tab.size.width, height: tab.size.height)
    }
}

/// Writes the global defaults through the store and reports failures as a toast.
struct SettingsWriter {
    let model: AppModel

    func update(_ patch: SettingsPatch) {
        do {
            try model.store.updateSettings(patch)
        } catch {
            model.report(error, fallback: "Die Einstellung konnte nicht gespeichert werden.")
        }
    }

    func updateStudy(_ patch: StudyOptionsPatch) {
        update(SettingsPatch(study: patch))
    }

    /// A binding showing `value` (read in the view's body, so the view tracks it) that stores
    /// every change as a study-options patch.
    func binding<Value>(_ value: Value, patch: @escaping (Value) -> StudyOptionsPatch) -> Binding<Value> {
        Binding(get: { value }, set: { updateStudy(patch($0)) })
    }

    /// "Standard wiederherstellen": stores `patch` (the defaults of one tab) and confirms it.
    func restoreDefaults(_ patch: StudyOptionsPatch, scope: String) {
        do {
            try model.store.updateSettings(SettingsPatch(study: patch))
            model.toasts.show("\(scope): Standardwerte wiederhergestellt", tone: .success)
        } catch {
            model.report(error, fallback: "Die Standardwerte konnten nicht wiederhergestellt werden.")
        }
    }
}

/// The note under the study tabs with "Standard wiederherstellen" (disabled while the tab
/// already shows the defaults); it names the sets with options of their own.
struct SettingsDefaultsFooter: View {
    let isDefault: Bool
    let restore: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(
                "Gilt für alle Lernsets. Was du in den Optionen eines Lernsets umstellst, gilt nur für dieses Lernset."
                    + SettingsCopy.ownOptionsText(model.library.sets, standard: model.settings.study)
            )
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Standard wiederherstellen", action: restore)
                .disabled(isDefault)
                .help(isDefault ? "Es sind bereits die Standardwerte eingestellt." : "Setzt die Einstellungen dieses Bereichs auf die Standardwerte zurück.")
        }
        .padding(.top, Spacing.xxs)
    }
}
