import AppKit
import Observation
import SwiftUI
import WortschatzCore

/// The app's single source of truth (spec §4.1): owns the `LibraryStore`, persists it, and
/// holds the navigation and presentation state of the main window.
///
/// ## Data
/// - `store`: the library (`LibraryStore` on `FileBackend.defaultURL()`). Write to it directly
///   (`model.store.recordAnswer(…)`, `saveLearn`, …) or through the actions below; every change
///   rebuilds `library` (derived view data), bumps `revision` and schedules a save.
/// - Saving: at most 300 ms after the first unsaved change (coalesced, not postponed by further
///   changes), and always when the app quits (`replyToTermination()` from the app delegate, and
///   `NSApplication.willTerminateNotification`). The coalesced save encodes and writes off the
///   main thread; `save()` writes immediately. Save errors are shown once as a sticky toast;
///   the changes stay in memory and the next change retries. A save that fails while quitting
///   asks the learner what to do (try again, export a backup, stay, quit anyway).
/// - `library`: sets with progress and running sessions, overview statistics and the
///   "Weiterlernen" item. `settings`: the global settings (theme, default study options).
///
/// ## Navigation (main window)
/// - `sidebarSelection` / `route`: change them with `select(_:)`, `showOverview()`,
///   `showSet(_:)` and the study calls. `route` is `.overview`, `.set(id)`, or a study screen:
///   `.learn`, `.write`, `.flashcards` or `.exam` (each with its `StudyRequest`).
/// - Study mode: entering a study screen collapses the sidebar (`columnVisibility =
///   .detailOnly`); leaving restores the previous visibility.
///
/// ## API for the screens
/// - Study: `continueLearn(setID:)` / `continueWrite(setID:)` (resume or start, the "Lernen ↩"
///   button and ⌘L / ⇧⌘L), `startLearn(setID:subset:forceNew:)` / `startWrite(…)` (subset
///   shortcuts; they ask first when a session with answers would end),
///   `restartLearn(setID:)` / `restartWrite(setID:)` ("Neu starten", asks first),
///   `study(_:setID:subset:forceNew:)` (plain navigation, no questions: for the study screens
///   themselves, e.g. after their own "Neu starten?" or "Schreiben üben"),
///   `resume()` (overview hero), `finishStudy()` (Esc / "Lernsets" back button / Fertig: back
///   to the set and the sidebar), `studySessionStarted(requestID:)` (study controllers, once
///   their session runs: the route then resumes it, e.g. after the window was reopened).
/// - Editor: `openEditor(_:)` (`.new`, `.importList`, `.edit(setID:)`), `closeEditor()`,
///   `editorDidSave(setID:)` (closes the sheet and shows the saved set).
/// - Set actions: `duplicateSet(_:)`, `deleteSet(_:)` (undoable with ⌘Z and the toast),
///   `confirmResetProgress(_:)`, `exportText(_:)`, `toggleStar(setID:cardID:)`,
///   `speak(_:lang:)`.
/// - Data: `exportBackup()`, `importBackup()` (file chooser → preview sheet),
///   `prepareBackupImport(from:)` + `performBackupImport(_:mode:)` for other screens with their
///   own file chooser (Settings).
/// - Feedback: `toasts` (`ToastCenter`), `confirm(_:)` for a confirmation alert, `report(_:)`
///   for errors.
@MainActor
@Observable
final class AppModel {
    /// Whether the model writes the store to its backend (off for previews and snapshots).
    enum Persistence: Sendable {
        case enabled, disabled
    }

    /// The longest a change waits before it is written.
    static let saveDelay: Duration = .milliseconds(300)

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let persistence: Persistence
    let toasts: ToastCenter

    /// Derived view data, rebuilt after every store change. It holds still while a study screen
    /// is open (see `latestLibrary`).
    private(set) var library: LibrarySnapshot = .empty
    /// The newest derived data, for the model's own decisions (which session runs, the daily
    /// streak). `library` follows only once the study screen is left: views kept alive under it
    /// were rebuilt after every answer and every save of the study clock. On the iPhone the
    /// Übersicht and the set page under the study screen (2–3 frames each, measured 2026-11-10);
    /// on the Mac the hidden sidebar (re-filtering every term when a search is left in it), the
    /// Lernset menu and an open Settings window (2026-11-24).
    @ObservationIgnored private(set) var latestLibrary: LibrarySnapshot = .empty
    /// Global settings (theme, default study options).
    private(set) var settings: WortschatzCore.Settings = .default
    /// Incremented after every store change.
    private(set) var revision = 0
    /// «Wiederholungsfragen» and «Nachkontrolle nach Fehlern» as switched now; an open Lernen
    /// applies a change at once (`AppModel+LearnSwitches`, which alone sets it).
    var learnSwitches = LearnSwitches.current

    // MARK: Navigation

    private(set) var sidebarSelection: SidebarItem = .overview
    private(set) var route: DetailRoute = .overview
    /// Bound to the `NavigationSplitView`.
    var columnVisibility: NavigationSplitViewVisibility = .all
    /// The route whose screen is on show: the departing one while it dissolves, else `route`.
    var routeOnScreen: DetailRoute {
        departingRoute ?? route
    }
    @ObservationIgnored private var columnVisibilityBeforeStudy: NavigationSplitViewVisibility?
    /// The layout is still changing around a study screen (the sidebar sliding away before
    /// Lernen/Schreiben, coming back after it); the incoming screen builds its content once this
    /// turns false (`StudyEntrance`).
    private(set) var isStudyLayoutSettling = false
    /// The page that stays on screen, fading under `detailCover`, for a moment after Lernen or
    /// Schreiben was opened (`StudyEntrance`); nil otherwise.
    private(set) var departingRoute: DetailRoute?
    /// Opacity of the backdrop over the detail column that the page fades into before Lernen.
    private(set) var detailCover: Double = 0
    /// The backdrop under the detail column's page while the page is not (fully) shown: after
    /// Lernen while the sidebar slides back and the page fades in, and at launch.
    private(set) var showsDetailBase = false
    /// False while the page (Übersicht, set page) is built invisibly before its entrance
    /// (`StudyEntrance`): after Lernen/Schreiben and at launch.
    private(set) var isPageRevealed = true
    /// Opacity of the sidebar's content: it fades out before the sidebar slides away for a study
    /// screen (and is back to full once the sidebar is hidden).
    private(set) var sidebarFade: Double = 1
    @ObservationIgnored private var sidebarSlideTask: Task<Void, Never>?
    @ObservationIgnored private var lastDetailWidthChange = ContinuousClock.now

    /// The detail column's width changed (it grows while the sidebar slides away).
    func detailWidthChanged() {
        lastDetailWidthChange = .now
    }
    /// The sidebar's search text (filters by title, description and terms).
    var sidebarSearch = ""

    /// The flashcard decks per set, stored beside the library file (`AppModel+Flashcards`).
    /// Change them with `storeFlashcardDeck(_:for:)`.
    var flashcardDecks: [String: FlashcardDeck] = [:]
    @ObservationIgnored var flashcardsSaveTask: Task<Void, Never>?

    /// The set detail's term filter per set, kept while the app runs (`filterMemory` in set.js).
    @ObservationIgnored private var termFilters: [String: TermFilter] = [:]

    func termFilter(for setID: String) -> TermFilter {
        termFilters[setID] ?? .all
    }

    func rememberTermFilter(_ filter: TermFilter, for setID: String) {
        termFilters[setID] = filter
    }

    // MARK: Presentation

    /// The editor sheet (nil: closed).
    var editorRequest: EditorRequest?
    /// The confirmation alert (nil: none).
    var confirmation: ConfirmationRequest?
    /// The "Als Text exportieren" sheet.
    var textExport: TextExportRequest?
    /// A backup waiting for the save panel.
    var backupExport: BackupExportFile?
    /// The backup file chooser.
    var isChoosingBackup = false
    /// A read backup waiting for the import sheet.
    var backupImport: BackupImportPreview?
    /// An informational alert (load recovery, errors that need reading).
    var alert: AppAlert?

    /// The main window's undo manager (set by the root view); delete-set undo goes there so
    /// ⌘Z in the Edit menu works.
    @ObservationIgnored weak var windowUndoManager: UndoManager?
    @ObservationIgnored private let fallbackUndoManager = UndoManager()
    /// Whether the main window is on screen (commands open it when it is not).
    @ObservationIgnored var isMainWindowVisible = false

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveFailureToast: ToastCenter.Toast.ID?
    @ObservationIgnored private var unsubscribe: (@Sendable () -> Void)?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var learnSwitchesObserver: (any NSObjectProtocol)?

    /// Read-aloud for the whole app (set screens, Learn, Write, the voice samples in Settings):
    /// one synthesizer, so a new utterance always cancels the previous one, and the voice
    /// chosen in Settings › Allgemein applies everywhere at once.
    let speech = SpeechService()

    // MARK: Lifecycle

    init(store: LibraryStore, persistence: Persistence = .enabled, toasts: ToastCenter = ToastCenter()) {
        self.store = store
        self.persistence = persistence
        self.toasts = toasts
        refresh()
        // A set's own "Soundeffekte" switch mutes the sounds while it is on screen.
        SoundEffects.shared.currentSetID = { [weak self] in self?.route.setID }
        if persistence == .enabled { flashcardDecks = loadFlashcardDecks() }
        unsubscribe = store.subscribe { [weak self] change in
            self?.storeDidChange(change)
        }
        guard persistence == .enabled else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            // Posted on the main thread, synchronously, while the app quits.
            MainActor.assumeIsolated { self?.save() }
        }
        learnSwitchesObserver = observeLearnSwitches()
        if store.hasUnsavedChanges { scheduleSave() }
        alert = AppAlert(recovery: store.recovery)
    }

    /// The model of the running app: the library file in the app container. If even the
    /// location cannot be determined, the app runs on an in-memory library and says so.
    static func launch(arguments: [String] = CommandLine.arguments) -> AppModel {
        #if DEBUG
        // `--ui-test-library <name> [--reset-library] [--sample-library <scenario>]`: a library
        // file of its own that survives a relaunch (UI tests of resuming a session).
        if let model = SampleLibrary.persistentModel(arguments: arguments) {
            return model
        }
        // `--sample-library <populated|learning|fresh|empty|empty-set>`: run on in-memory sample
        // data (UI tests, manual checks); nothing is read from or written to the library file.
        if let scenario = SampleLibrary.Scenario(arguments: arguments) {
            return SampleLibrary.model(scenario)
        }
        // The host app of the unit tests (WortschatzTests) runs on an empty in-memory library:
        // tests never read or write the learner's data.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return SampleLibrary.model(.empty)
        }
        #endif
        do {
            let backend = FileBackend(url: try FileBackend.defaultURL())
            return AppModel(store: LibraryStore(backend: backend))
        } catch {
            let model = AppModel(store: LibraryStore(backend: MemoryBackend()), persistence: .disabled)
            model.alert = AppAlert(
                title: String(localized: "Die Daten können nicht gespeichert werden"),
                message: String(
                    localized:
                        "Wortschatz findet seinen Speicherort nicht. Änderungen gehen beim Beenden verloren. (\(error.localizedDescription))"
                ))
            return model
        }
    }

    /// The library file, for "Speicherort im Finder zeigen" (nil for in-memory libraries).
    var libraryFileURL: URL? {
        (store.backend as? FileBackend)?.url
    }

    // MARK: Store changes

    private func storeDidChange(_ change: StoreChange) {
        refresh(after: change)
        if change.kind == .local { scheduleSave() }
    }

    /// Rebuilds the derived data and keeps the navigation valid (a deleted set leaves its screens).
    /// `change` (nil = everything) lets sets it did not touch keep their summaries.
    private func refresh(after change: StoreChange? = nil) {
        #if DEBUG
        latestLibrary = DebugTiming.measure("LibrarySnapshot.build") {
            LibrarySnapshot.build(from: store, previous: latestLibrary, change: change)
        }
        #else
        latestLibrary = LibrarySnapshot.build(from: store, previous: latestLibrary, change: change)
        #endif
        if !route.isStudy { library = latestLibrary }
        celebrateDailyStreak()
        let newSettings = store.getSettings()
        if newSettings != settings {
            settings = newSettings
            applyAppearance()
        }
        revision += 1
        if let setID = route.setID, store.getSet(setID) == nil {
            show(.overview)
        }
    }

    /// `UserDefaults` key: the day ("YYYY-MM-DD") whose Lernserie was last celebrated.
    private static let celebratedStreakDayKey = "dailyStreakCelebrated"
    /// The day last celebrated (`celebratedStreakDayKey`), read once: `refresh()` runs after
    /// every store change.
    @ObservationIgnored private lazy var celebratedStreakDay = UserDefaults.standard.string(forKey: Self.celebratedStreakDayKey)

    /// The first answer of a day keeps the Lernserie going (or starts it): a flame toast and a
    /// short fanfare, once per day, while studying. A moment late, so it does not sound over
    /// the answer's own chime.
    private func celebrateDailyStreak() {
        let streak = latestLibrary.stats.streak
        guard persistence == .enabled, route.isStudy, streak.today > 0, streak.current > 0 else { return }
        let today = TimeUtil.dateKey(timeZone: store.timeZone)
        guard celebratedStreakDay != today else { return }
        celebratedStreakDay = today
        UserDefaults.standard.set(today, forKey: Self.celebratedStreakDayKey)
        let message =
            streak.current == 1
            ? String(localized: "Neue Lernserie gestartet – lerne morgen weiter!")
            : String(localized: "Lernserie: \(streak.current) Tage in Folge!")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard let self else { return }
            self.toasts.show(message, tone: .streak, duration: .seconds(3.5))
            SoundEffects.shared.play(.dailyStreak)
        }
    }

    // MARK: Saving

    /// Saves soon (also after the sync took over the server's state, an `.external` change).
    func scheduleSave() {
        guard persistence == .enabled, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            // Encoding and writing the library take several milliseconds: done off the main
            // thread, so a save never costs an animation frame (e.g. the sidebar sliding back
            // after Lernen, 300 ms after the session was stored).
            let store = self.store
            let result = await Task.detached(priority: .utility) { Result { try store.save() } }.value
            self.saveFinished(result)
        }
    }

    /// Writes unsaved changes now; a failure shows a sticky toast (the changes stay in memory and
    /// the next change retries).
    func save() {
        saveFlashcardsNow()
        do {
            try saveNow()
        } catch {
            saveFinished(.failure(error))
        }
    }

    /// Writes unsaved changes now and throws when that fails (quitting asks the learner then,
    /// see `replyToTermination`).
    func saveNow() throws {
        saveTask?.cancel()
        saveTask = nil
        guard persistence == .enabled, store.hasUnsavedChanges else { return }
        #if DEBUG
        try DebugTiming.measure("store.save") { try store.save() }
        #else
        try store.save()
        #endif
        saveFinished(.success(()))
    }

    /// A failed save shows a sticky toast once; the next successful save removes it.
    private func saveFinished(_ result: Result<Void, any Error>) {
        switch result {
        case .success:
            guard let id = saveFailureToast else { return }
            toasts.dismiss(id)
            saveFailureToast = nil
        case let .failure(error):
            guard saveFailureToast == nil else { return }
            saveFailureToast = toasts.show(Self.message(for: error), tone: .danger, duration: nil)
        }
    }

    // MARK: Appearance

    /// Applies the theme setting (System / Hell / Dunkel) to every window, alerts included.
    func applyAppearance() {
        let appearance: NSAppearance? =
            switch settings.theme {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        if NSApp?.appearance != appearance { NSApp?.appearance = appearance }
    }

    /// The colour scheme forced by the theme setting (nil: follow the system).
    var preferredColorScheme: ColorScheme? {
        switch settings.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    // MARK: Navigation

    /// The set the window is about (selected in the sidebar, shown or studied).
    var currentSetID: String? { route.setID }

    /// Sidebar selection: shows the overview or the set (and leaves a running study screen).
    func select(_ item: SidebarItem?) {
        guard let item, item != route.sidebarItem || route.isStudy else { return }
        switch item {
        case .overview: show(.overview)
        case let .set(id): show(.set(id))
        }
    }

    func showOverview() {
        show(.overview)
    }

    func showSet(_ setID: String) {
        guard store.getSet(setID) != nil else { return }
        show(.set(setID))
    }

    /// Sets the route and keeps the sidebar selection and the study layout in step. When Return
    /// caused the change, the new screen's Return button waits a moment (`KeyActionGate`). A study
    /// screen that must not be left without asking (`studyLeaveGuard`) asks first, whichever way
    /// it is left (esc, "‹ Lernsets", the Lernset menu, the sidebar, a saved new set).
    private func show(_ newRoute: DetailRoute, leaveConfirmed: Bool = false) {
        if !leaveConfirmed, let leaveGuard = studyLeaveGuard, let study = route.study, study.id == leaveGuard.requestID,
            newRoute.study?.id != study.id,
            leaveGuard.askBeforeLeaving({ [weak self] in self?.show(newRoute, leaveConfirmed: true) })
        {
            return
        }
        KeyActionGate.returnKeyMoved(by: NSApp?.currentEvent)
        let oldRoute = route
        route = newRoute
        sidebarSelection = newRoute.sidebarItem
        if newRoute.isStudy, !oldRoute.isStudy {
            columnVisibilityBeforeStudy = columnVisibility
            enterStudyLayout(from: oldRoute)
        } else if !newRoute.isStudy, oldRoute.isStudy {
            // The views that held still under the study screen catch up (`latestLibrary`).
            library = latestLibrary
            let restored = columnVisibilityBeforeStudy ?? .all
            columnVisibilityBeforeStudy = nil
            leaveStudyLayout(from: oldRoute, restoring: restored)
        }
    }

    /// Into Lernen/Schreiben (`StudyEntrance`): the page and the sidebar's content fade into the
    /// backdrop, the sidebar slides away over the bare backdrop (cheap to draw on every frame),
    /// then the study screen builds and fades in.
    private func enterStudyLayout(from oldRoute: DetailRoute) {
        // A page entrance still running ends at once.
        isPageRevealed = true
        showsDetailBase = false
        let slides = columnVisibility != .detailOnly
        changeStudyLayout(from: oldRoute, fadingSidebar: slides) { [weak self] in
            // Under the opaque cover the page has gone; the study screen shows the same
            // backdrop until it is built.
            guard let self else { return }
            if slides {
                await self.slideSidebar(to: .detailOnly)
                guard !Task.isCancelled else { return }
            }
            self.isStudyLayoutSettling = false
        }
    }

    /// Out of Lernen/Schreiben, the mirror image of coming in (`StudyEntrance`): the study
    /// screen dissolves into the backdrop, the sidebar slides back over the bare backdrop, then
    /// the set page (or overview) is built invisibly, terms table included, and fades in.
    private func leaveStudyLayout(from oldRoute: DetailRoute, restoring visibility: NavigationSplitViewVisibility) {
        sidebarFade = 1
        showsDetailBase = false
        isPageRevealed = false
        let slides = visibility != .detailOnly
        changeStudyLayout(from: oldRoute, underCover: { [weak self] in
            // The backdrop under the column stands in until the page has faded in.
            self?.showsDetailBase = true
        }) { [weak self] in
            guard let self else { return }
            if slides {
                await self.slideSidebar(to: visibility)
                guard !Task.isCancelled else { return }
            }
            self.isStudyLayoutSettling = false
            await StudyEntrance.waitUntilBuilt()
            guard !Task.isCancelled, !self.route.isStudy else { return }
            #if DEBUG
            DebugTiming.mark("CoverFade")
            #endif
            await self.revealPage()
        }
    }

    /// The part both directions share: the layout settles while `oldRoute`'s screen stays a
    /// moment longer; one frame later (so the route switch's own work does not eat the fade's
    /// start) it dissolves into the cover (with the sidebar's content, `fadingSidebar`), and
    /// under the opaque cover it goes (`underCover` runs in the same update). Then `then`.
    private func changeStudyLayout(
        from oldRoute: DetailRoute, fadingSidebar: Bool = false, underCover: @escaping @MainActor () -> Void = {},
        then: @escaping @MainActor () async -> Void
    ) {
        sidebarSlideTask?.cancel()
        isStudyLayoutSettling = true
        departingRoute = oldRoute
        detailCover = 0
        sidebarSlideTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            withAnimation(StudyEntrance.dissolve) {
                self.detailCover = 1
                if fadingSidebar { self.sidebarFade = 0 }
            }
            try? await Task.sleep(for: StudyEntrance.dissolveDuration)
            guard !Task.isCancelled else { return }
            underCover()
            self.departingRoute = nil
            self.detailCover = 0
            await then()
        }
    }

    /// The app starts with the first page hidden, so it can come in (`revealFirstPage`).
    func hideFirstPage() {
        isPageRevealed = false
        showsDetailBase = true
    }

    /// The main window is on screen: the first page comes in once it is built.
    func revealFirstPage() {
        guard !isPageRevealed, !isStudyLayoutSettling else { return }
        sidebarSlideTask?.cancel()
        sidebarSlideTask = Task { @MainActor [weak self] in
            await StudyEntrance.waitUntilBuilt()
            guard let self, !Task.isCancelled else { return }
            await self.revealPage()
        }
    }

    /// The page fades in over the backdrop as one piece (`StudyEntrance`); the backdrop under it
    /// goes once the page is fully there.
    private func revealPage() async {
        withAnimation(StudyEntrance.reveal) { isPageRevealed = true }
        try? await Task.sleep(for: StudyEntrance.revealDuration)
        guard !Task.isCancelled else { return }
        showsDetailBase = false
    }

    /// Slides the sidebar to `visibility` and returns once the slide is over.
    private func slideSidebar(to visibility: NavigationSplitViewVisibility) async {
        let start = ContinuousClock.now
        lastDetailWidthChange = start
        withAnimation(StudyEntrance.sidebar) { columnVisibility = visibility }
        // AppKit animates the split view itself, so SwiftUI's completion fires too early:
        // the slide is over once the detail column keeps its width.
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(25))
            let now = ContinuousClock.now
            let quiet = now - lastDetailWidthChange
            if (now - start > .milliseconds(120) && quiet > .milliseconds(70)) || now - start > .milliseconds(900) {
                break
            }
        }
        // Hidden now; back to full strength for the next time it shows.
        if visibility == .detailOnly { sidebarFade = 1 }
    }

    // MARK: Study

    /// Opens a study screen without asking anything (see `StudyRequest` for the semantics).
    /// Study screens use it for their own restarts; buttons elsewhere use the calls below.
    func study(
        _ mode: StudyMode, setID: String, subset: StudySubset? = nil, forceNew: Bool = false, reviewMastered: Bool = false
    ) {
        guard store.getSet(setID) != nil else { return }
        show(.study(StudyRequest(
            setID: setID, mode: mode, subset: subset, forceNew: forceNew, reviewMastered: reviewMastered)))
    }

    /// "Lernen ↩" / "Weiterlernen ↩" (⌘L): continues the running Learn session, else starts one.
    func continueLearn(setID: String) {
        if case let .learn(request) = route, request.setID == setID { return }
        let running = latestLibrary.summary(for: setID)?.learn != nil
        study(.learn, setID: setID, forceNew: !running)
    }

    /// "Schreiben" / "Schreiben fortsetzen" (⇧⌘L): continues the running Write session, else
    /// starts one.
    func continueWrite(setID: String) {
        if case let .write(request) = route, request.setID == setID { return }
        let running = latestLibrary.summary(for: setID)?.write != nil
        study(.write, setID: setID, forceNew: !running)
    }

    /// Starts a new Learn session (for subsets: "Nur markierte", "Nur schwierige"). A running
    /// session with answers only ends after asking (`startSubset` in set.js).
    /// `reviewMastered`: see `StudyRequest`.
    func startLearn(setID: String, subset: StudySubset = .all, forceNew: Bool = true, reviewMastered: Bool = false) {
        startSession(.learn, setID: setID, subset: subset, forceNew: forceNew, reviewMastered: reviewMastered)
    }

    /// Starts a new Write session; asks first like `startLearn`.
    func startWrite(setID: String, subset: StudySubset = .all, forceNew: Bool = true) {
        startSession(.write, setID: setID, subset: subset, forceNew: forceNew)
    }

    private func startSession(
        _ mode: StudyMode, setID: String, subset: StudySubset, forceNew: Bool, reviewMastered: Bool = false
    ) {
        guard forceNew, let summary = latestLibrary.summary(for: setID) else {
            study(mode, setID: setID, subset: subset, forceNew: forceNew, reviewMastered: reviewMastered)
            return
        }
        let running: (detail: String, hasAnswers: Bool)? =
            switch mode {
            case .learn: summary.learn.map { ($0.detail, $0.hasAnswers) }
            case .write: summary.write.map { ($0.detail, $0.hasAnswers) }
            case .flashcards, .exam: nil
            }
        guard let running, running.hasAnswers else {
            study(mode, setID: setID, subset: subset, forceNew: true, reviewMastered: reviewMastered)
            return
        }
        let copy = SubsetConfirmCopy(mode: mode)
        confirm(ConfirmationRequest(
            title: copy.title,
            message: copy.message(detail: running.detail, subset: subset),
            confirmLabel: copy.confirmLabel
        ) { [weak self] in
            guard let self else { return }
            do {
                // The study screen would otherwise offer to resume the stored session.
                if mode == .learn { try store.clearLearn(setID) } else { try store.clearSession(setID) }
            } catch {
                // The new session replaces it anyway (forceNew).
            }
            study(mode, setID: setID, subset: subset, forceNew: true, reviewMastered: reviewMastered)
        })
    }

    /// "Neu starten" next to a running Learn session: same scope; a session with answers
    /// only ends after asking (`restartLearn` in set.js).
    func restartLearn(setID: String) {
        guard let learn = latestLibrary.summary(for: setID)?.learn else {
            study(.learn, setID: setID, forceNew: true)
            return
        }
        let subset = Self.namedSubset(learn.subset)
        guard learn.hasAnswers else {
            study(.learn, setID: setID, subset: subset, forceNew: true)
            return
        }
        confirm(ConfirmationRequest(
            title: String(localized: "Neu starten?"), message: Self.restartSessionMessage(learn.subset),
            confirmLabel: String(localized: "Neu starten")
        ) { [weak self] in
            self?.study(.learn, setID: setID, subset: subset, forceNew: true)
        })
    }

    /// "Neu starten" for a running Write session (asks first when it has answers).
    func restartWrite(setID: String) {
        guard let write = latestLibrary.summary(for: setID)?.write, write.hasAnswers else {
            study(.write, setID: setID, forceNew: true)
            return
        }
        confirm(ConfirmationRequest(
            title: String(localized: "Neue Runde starten?"),
            message: String(localized: "Deine gespeicherte Runde (\(write.detail)) endet. Dein Lernfortschritt bleibt erhalten."),
            confirmLabel: String(localized: "Neu starten")
        ) { [weak self] in
            self?.study(.write, setID: setID, forceNew: true)
        })
    }

    /// The overview's "Weiterlernen ↩": the latest running session, else the most recent set.
    func resume() {
        if let item = latestLibrary.resume {
            study(item.mode, setID: item.setID)
        } else if let first = latestLibrary.sets.first {
            showSet(first.id)
        } else {
            openEditor(.new)
        }
    }

    /// A study screen that asks before it is left (an exam with answers): `askBeforeLeaving`
    /// gets the navigation and returns true when it asked instead (the navigation then runs only
    /// once confirmed). Only for the route of `requestID`.
    struct StudyLeaveGuard {
        let requestID: UUID
        let askBeforeLeaving: (_ leave: @escaping () -> Void) -> Bool
    }

    @ObservationIgnored var studyLeaveGuard: StudyLeaveGuard?

    /// Called by a study screen once it has started (or resumed) its session for `requestID`:
    /// from then on the route resumes that session (`StudyRequest.resuming`). Without this, a
    /// screen rebuilt for a "start new" request (the main window was closed and reopened while
    /// studying) would quietly replace the running session with a fresh one.
    func studySessionStarted(requestID: UUID) {
        guard let request = route.study, request.id == requestID else { return }
        let resuming = request.resuming
        guard resuming != request else { return }
        route = .study(resuming)
    }

    /// Leaves a study screen (Esc, the "Lernsets" back button, "Fertig"): back to the set, with the
    /// sidebar restored.
    func finishStudy() {
        guard let setID = route.study?.setID else { return }
        if store.getSet(setID) != nil { show(.set(setID)) } else { show(.overview) }
    }

    /// The scope a restart keeps (`learnSubsetQuery` in set.js: only named subsets).
    static func namedSubset(_ subset: StudySubset) -> StudySubset? {
        switch subset {
        case .starred, .learning, .missed: subset
        case .all, .cardIds: nil
        }
    }

    /// `restartSessionMessage` of learn-model.js.
    static func restartSessionMessage(_ subset: StudySubset) -> String {
        switch subset {
        case .starred:
            String(
                localized:
                    "Du beginnst eine neue Lerneinheit mit allen markierten Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert."
            )
        case .missed:
            String(
                localized:
                    "Du beginnst eine neue Lerneinheit mit allen zuletzt falsch beantworteten Begriffen. Dein Lernfortschritt bleibt gespeichert."
            )
        case .cardIds:
            String(
                localized:
                    "Du beginnst eine neue Lerneinheit mit den ausgewählten Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert."
            )
        case .all, .learning:
            String(
                localized:
                    "Du beginnst eine neue Lerneinheit mit allen Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert."
            )
        }
    }

    // MARK: Editor

    /// Opens the editor sheet. Ignored while a sheet is open (a second ⌘N / ⌘E must not
    /// replace an editor with unsaved changes).
    func openEditor(_ kind: EditorRequest.Kind) {
        guard !isPresentingSheet else { return }
        if case let .edit(setID) = kind, store.getSet(setID) == nil { return }
        editorRequest = EditorRequest(kind)
    }

    /// Whether a sheet covers the main window (menu commands for sets and study pause then).
    var isPresentingSheet: Bool {
        editorRequest != nil || textExport != nil || backupImport != nil
    }

    func closeEditor() {
        editorRequest = nil
    }

    /// Called by the editor after saving: closes the sheet and shows the set (unless a study
    /// screen of that set is open, which picks up the changes itself).
    func editorDidSave(setID: String) {
        editorRequest = nil
        if route.study?.setID == setID { return }
        showSet(setID)
    }

    // MARK: Feedback

    func confirm(_ request: ConfirmationRequest) {
        confirmation = request
    }

    /// Shows an error as a toast (`LibraryStoreError` messages are German already).
    func report(_ error: any Error, fallback: String = String(localized: "Etwas ist schiefgelaufen. Bitte versuche es nochmal.")) {
        toasts.show(Self.message(for: error, fallback: fallback), tone: .danger, duration: .seconds(6))
    }

    static func message(for error: any Error, fallback: String = String(localized: "Etwas ist schiefgelaufen. Bitte versuche es nochmal.")) -> String {
        if let error = error as? LibraryStoreError { return error.message }
        if let error = error as? BackupFileError { return error.message }
        if let error = error as? LocalizedError, let text = error.errorDescription, !text.isEmpty { return text }
        return fallback
    }

    /// "Unité 3 – La maison" shortened to 40 characters for toasts (`shortTitle`).
    static func shortTitle(_ title: String, max: Int = 40) -> String {
        guard title.count > max else { return title }
        let head = title.prefix(max - 1)
        return String(head).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Speech

    /// Reads `text` aloud in the language of the side it belongs to.
    func speak(_ text: String, lang: Lang) {
        speech.speak(text, lang: lang)
    }

    // MARK: Undo

    var undoManager: UndoManager {
        windowUndoManager ?? fallbackUndoManager
    }
}

/// The wording of "Laufende Lerneinheit beenden?" per mode (`SUBSET_CONFIRM` in set.js).
private struct SubsetConfirmCopy {
    let mode: StudyMode
    let title: String
    let confirmLabel: String

    init(mode: StudyMode) {
        self.mode = mode
        switch mode {
        case .learn:
            title = String(localized: "Laufende Lerneinheit beenden?")
            confirmLabel = String(localized: "Neu beginnen")
        case .write, .flashcards, .exam:
            title = String(localized: "Laufende Runde beenden?")
            confirmLabel = String(localized: "Neue Runde starten")
        }
    }

    /// "Deine gespeicherte Runde (…) endet, wenn du jetzt nur die markierten Begriffe übst. …",
    /// one whole sentence per mode and scope.
    func message(detail: String, subset: StudySubset) -> String {
        switch (mode, subset) {
        case (.learn, .starred):
            String(
                localized:
                    "Deine gespeicherte Lerneinheit (\(detail)) endet, wenn du jetzt nur die markierten Begriffe lernst. Dein Lernfortschritt bleibt erhalten."
            )
        case (.learn, .learning):
            String(
                localized:
                    "Deine gespeicherte Lerneinheit (\(detail)) endet, wenn du jetzt nur die nicht gemeisterten Begriffe lernst. Dein Lernfortschritt bleibt erhalten."
            )
        case (.learn, .missed):
            String(
                localized:
                    "Deine gespeicherte Lerneinheit (\(detail)) endet, wenn du jetzt nur die falschen Begriffe lernst. Dein Lernfortschritt bleibt erhalten."
            )
        case (.learn, .cardIds):
            String(
                localized:
                    "Deine gespeicherte Lerneinheit (\(detail)) endet, wenn du jetzt nur die ausgewählten Begriffe lernst. Dein Lernfortschritt bleibt erhalten."
            )
        case (.learn, .all):
            String(
                localized:
                    "Deine gespeicherte Lerneinheit (\(detail)) endet, wenn du jetzt alle Begriffe lernst. Dein Lernfortschritt bleibt erhalten."
            )
        case (_, .starred):
            String(
                localized:
                    "Deine gespeicherte Runde (\(detail)) endet, wenn du jetzt nur die markierten Begriffe übst. Dein Lernfortschritt bleibt erhalten."
            )
        case (_, .learning):
            String(
                localized:
                    "Deine gespeicherte Runde (\(detail)) endet, wenn du jetzt nur die nicht gemeisterten Begriffe übst. Dein Lernfortschritt bleibt erhalten."
            )
        case (_, .missed):
            String(
                localized:
                    "Deine gespeicherte Runde (\(detail)) endet, wenn du jetzt nur die falschen Begriffe übst. Dein Lernfortschritt bleibt erhalten."
            )
        case (_, .cardIds):
            String(
                localized:
                    "Deine gespeicherte Runde (\(detail)) endet, wenn du jetzt nur die ausgewählten Begriffe übst. Dein Lernfortschritt bleibt erhalten."
            )
        case (_, .all):
            String(
                localized:
                    "Deine gespeicherte Runde (\(detail)) endet, wenn du jetzt alle Begriffe übst. Dein Lernfortschritt bleibt erhalten."
            )
        }
    }
}

/// A confirmation alert. `isDestructive` dialogs keep "Abbrechen" as the default button
/// (Return), like the web app's danger dialogs; others confirm with Return.
struct ConfirmationRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmLabel: String
    var isDestructive = false
    var action: () -> Void

    init(title: String, message: String, confirmLabel: String, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.isDestructive = isDestructive
        self.action = action
    }
}

/// An informational alert with an OK button.
struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    /// The notice for a library that had to be recovered (nil when it loaded normally).
    init?(recovery: LoadRecovery) {
        switch recovery {
        case .none:
            return nil
        case .fromBackup:
            self.init(
                title: String(localized: "Deine Daten wurden wiederhergestellt"),
                message: String(
                    localized:
                        "Die Datei mit deinen Lernsets war beschädigt oder fehlte. Wortschatz hat die neueste lesbare Sicherung geladen; die letzten Minuten vor dem Problem können fehlen."
                ))
        case .reset:
            self.init(
                title: String(localized: "Deine Daten konnten nicht gelesen werden"),
                message: String(
                    localized:
                        "Die Datei mit deinen Lernsets ist beschädigt, und es gibt keine lesbare Sicherung. Wortschatz startet leer; die beschädigte Datei bleibt als «library-corrupt.json» im Speicherort erhalten. Mit einem Backup kannst du deine Lernsets wiederherstellen."
                ))
        }
    }
}
