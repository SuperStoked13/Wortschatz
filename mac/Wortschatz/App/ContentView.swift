import SwiftUI
import UniformTypeIdentifiers
import WortschatzCore

/// The main window's root (spec §4.1): sidebar (Übersicht + Lernsets) and the detail column
/// (Übersicht, set detail, Learn or Write), plus every sheet, alert and file panel the app shell
/// presents.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarColumn()
                // No sidebar button in the toolbar: Lernen and Schreiben hide and bring back the
                // sidebar themselves.
                .toolbar(removing: .sidebarToggle)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } detail: {
            DetailColumn()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in model.detailWidthChanged() }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        // No grey toolbar band over the pages: the backdrop runs on under the toolbar, whose
        // items float on it as glass. Set on each column too: the window toolbar takes its
        // settings from the column whose content changed last, so set only here the band came
        // back now and then (after switching pages or leaving Lernen).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // The sidebar may be dragged out to half the window at most (in 10-pt steps, so a live
        // resize does not update it on every frame).
        .onGeometryChange(for: CGFloat.self) { proxy in
            max(SidebarColumn.minWidth, (proxy.size.width / 2 / 10).rounded(.down) * 10)
        } action: { width in
            model.sidebarMaxWidth = width
        }
        .alert(
            model.confirmation?.title ?? "",
            isPresented: isPresented(\.confirmation),
            presenting: model.confirmation
        ) { request in
            ConfirmationButtons(request: request)
        } message: { request in
            Text(request.message)
        }
        .toastOverlay(model.toasts)
        .alert(
            model.alert?.title ?? "",
            isPresented: isPresented(\.alert),
            presenting: model.alert
        ) { _ in
            Button("OK") {}
                .keyboardShortcut(.defaultAction)
        } message: { alert in
            Text(alert.message)
        }
        .sheet(item: $model.editorRequest) { request in
            EditorSheet(request: request)
        }
        .sheet(item: $model.textExport) { request in
            TextExportSheet(request: request)
        }
        .sheet(item: $model.backupImport) { preview in
            BackupImportSheet(preview: preview)
        }
        .sheet(isPresented: $model.isShowingWebMigration, onDismiss: model.webMigrationDismissed) {
            WebMigrationSheet()
        }
        .fileImporter(isPresented: $model.isChoosingBackup, allowedContentTypes: [.json]) { result in
            model.backupFileChosen(result.map { [$0] })
        }
        .fileExporter(
            isPresented: isPresented(\.backupExport),
            document: model.backupExport?.document,
            contentType: .json,
            defaultFilename: model.backupExport?.fileName
        ) { result in
            model.backupExportFinished(result)
        }
        .focusedSceneValue(model)
        .preferredColorScheme(model.preferredColorScheme)
        .onAppear {
            model.isMainWindowVisible = true
            model.windowUndoManager = undoManager
            model.applyAppearance()
            model.revealFirstPage()
        }
        .onDisappear {
            model.isMainWindowVisible = false
            model.save()
        }
        .onChange(of: undoManager) { _, manager in
            model.windowUndoManager = manager
        }
    }

    /// A Bool binding for an optional presentation value (dismissal clears it).
    private func isPresented<Value>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value?>) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath] != nil },
            set: { shown in if !shown { model[keyPath: keyPath] = nil } })
    }
}

/// The detail column for the current route.
private struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The split view asks the detail column for its minimum size after every change (each
        // animation frame and backdrop tick too), which measured the whole page again: up to
        // 90 ms when the set page appears. 640 × 540 is what the set page measured.
        WindowMinimumLayout(minWidth: 640, minHeight: 540) {
            ZStack {
                DetailBase()
                // One branch for every route, so the page that stays a moment after Lernen was
                // opened (`departingRoute`) is the same view, not built again.
                if let shown = shownRoute {
                    screen(for: shown)
                        .entranceReveal(model.isPageRevealed || shown.isStudy)
                        .allowsHitTesting(model.departingRoute == nil)
                }
                DetailCover()
            }
        }
    }

    /// The route on screen: the departing screen while it dissolves (into Lernen/Schreiben and
    /// out of them); after them, nothing while the sidebar slides back (the backdrop shows),
    /// then the page (`StudyEntrance`).
    private var shownRoute: DetailRoute? {
        let route = model.routeOnScreen
        return model.departingRoute != nil || route.isStudy || !model.isStudyLayoutSettling ? route : nil
    }

    @ViewBuilder
    private func screen(for route: DetailRoute) -> some View {
        switch route {
        case .overview:
            OverviewScreen()
        case let .set(setID):
            SetDetailScreen(setID: setID)
                .id(setID)
        case let .learn(request):
            LearnScreen(request: request)
                .id(request.id)
                .toolbar { StudyBackButton() }
        case let .write(request):
            WriteScreen(request: request)
                .id(request.id)
                .toolbar { StudyBackButton() }
        case let .flashcards(request):
            FlashcardsScreen(request: request)
                .id(request.id)
                .toolbar { StudyBackButton() }
        case let .exam(request):
            ExamScreen(request: request)
                .id(request.id)
                .toolbar { StudyBackButton() }
        }
    }
}

/// "‹ Lernsets" in the study screens' toolbar (spec §4.1): leaves the study screen and brings the
/// sidebar back (a running exam with answers asks first, `AppModel.studyLeaveGuard`). Esc does the
/// same through the Lernen menu's "Beenden".
private struct StudyBackButton: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.finishStudy()
            } label: {
                Label("Lernsets", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .help("Zurück zum Lernset (esc)")
        }
    }
}

/// Buttons of a confirmation alert. Danger dialogs keep "Abbrechen" on Return (like the web
/// app); the others confirm with Return. Esc always cancels.
private struct ConfirmationButtons: View {
    let request: ConfirmationRequest

    var body: some View {
        if request.isDestructive {
            Button(request.confirmLabel, role: .destructive) { request.action() }
            Button("Abbrechen", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } else {
            Button(request.confirmLabel) { request.action() }
                .keyboardShortcut(.defaultAction)
            Button("Abbrechen", role: .cancel) {}
        }
    }
}

/// The backdrop over the detail column that the outgoing screen dissolves into, into
/// Lernen/Schreiben and out of them (`AppModel.detailCover`). Its own view, so fading it
/// re-evaluates nothing but itself.
private struct DetailCover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.detailCover > 0 {
            AppBackdrop(intensity: AppBackdrop.studyIntensity)
                .opacity(model.detailCover)
        }
    }
}

/// The backdrop under the detail column while its page is not fully shown: after
/// Lernen/Schreiben and at launch (`AppModel.showsDetailBase`).
private struct DetailBase: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.showsDetailBase {
            AppBackdrop(intensity: AppBackdrop.studyIntensity)
        }
    }
}

/// The sidebar, whose content fades out before it slides away for a study screen
/// (`AppModel.sidebarFade`).
private struct SidebarColumn: View {
    /// Wide enough that the Lernserie at its foot ("2 Tage Lernserie" over "Heute geschafft")
    /// never wraps, also when an earlier, narrower width is restored.
    nonisolated static let minWidth: CGFloat = 250

    @Environment(AppModel.self) private var model

    var body: some View {
        LibrarySidebar()
            .opacity(model.sidebarFade)
            // At most half the window (`AppModel.sidebarMaxWidth`): the page keeps the rest.
            .navigationSplitViewColumnWidth(
                min: Self.minWidth, ideal: 280, max: model.sidebarMaxWidth)
    }
}
