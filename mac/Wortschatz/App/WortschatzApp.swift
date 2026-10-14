import AppKit
import SwiftUI
import WortschatzCore

/// Entry point (spec §4.1): the main window, the Settings scene (⌘,) and the menu commands.
@main
struct WortschatzApp: App {
    /// The id of the main window (for `openWindow` after it was closed).
    static let mainWindowID = "main"

    @State private var model: AppModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        // `--render-snapshots <dir>` / `--list-snapshots`: render views to PNGs and quit
        // (see App/DebugSnapshot.swift). Does nothing for a normal launch, and runs before the
        // library is opened.
        DebugSnapshotHarness.runIfRequested()
        #endif
        // One window, one navigation state: no window tabs ("Tab-Leiste einblenden").
        NSWindow.allowsAutomaticWindowTabbing = false
        let model = AppModel.launch()
        // The first page comes in once the window is up (`StudyEntrance`).
        model.hideFirstPage()
        _model = State(initialValue: model)
        // Quitting saves first and asks when that fails.
        appDelegate.model = model
        SoundEffects.shared.synthesizeAhead()
        #if DEBUG
        DebugFocusProbe.scheduleIfRequested(model: model)
        DebugTransitionProbe.scheduleIfRequested(model: model)
        #endif
    }

    var body: some Scene {
        WindowGroup("Wortschatz", id: Self.mainWindowID) {
            WindowMinimumLayout(minWidth: 980, minHeight: 640) {
                ContentView()
                    .environment(model)
            }
            // The window's own background is the app's backdrop, still, instead of the system
            // grey: wherever no page covers the window for a moment (under the toolbar, around
            // the sidebar while it slides), no grey band shows.
            .containerBackground(for: .window) {
                AppBackdrop(drifts: false)
            }
        }
        .defaultSize(width: 1240, height: 800)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(model: model)
        }

        SwiftUI.Settings {
            SettingsView()
                .environment(model)
                // Toasts show in the main window; the center is here for `@Environment(ToastCenter.self)`.
                .environment(model.toasts)
        }
    }
}
