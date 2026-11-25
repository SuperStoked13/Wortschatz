import SwiftUI
import WortschatzCore

// The exam screen (Prüfungsmodus): a vocabulary test with every question on one page, a time
// limit and a Swiss grade.
//
// Contract with the app shell (like Lernen, Schreiben and Karteikarten):
// - `init(request: StudyRequest)`: only `request.setID` is used (an exam starts with its
//   settings and is never kept). The shell recreates the view for every request, collapses the
//   sidebar and puts "‹ Lernsets" into the toolbar.
// - Leaving (esc, "Zurück zum Lernset", "Fertig") goes through `AppModel.finishStudy()`.
// - The Lernen menu is published with `.focusedSceneValue(\.studyCommands, …)` (⇧⌘R "Neu
//   starten" = Neue Prüfung, esc = Beenden).
// - Nothing goes into the progress.

/// SF Symbols of the exam.
nonisolated enum ExamSymbols {
    /// The mode (buttons, menus).
    static let mode = "graduationcap"
    static let timer = "timer"
}

/// The exam screen of a set: its settings, the sheet, the result.
struct ExamScreen: View {
    let request: StudyRequest

    @Environment(AppModel.self) private var model
    @State private var controller: ExamController?
    @State private var isRevealed = false

    init(request: StudyRequest) {
        self.request = request
    }

    var body: some View {
        ZStack {
            if let controller {
                ExamScreenContent(controller: controller, isRevealed: isRevealed)
            } else {
                AppBackdrop(intensity: AppBackdrop.studyIntensity)
            }
        }
        .task(id: model.isStudyLayoutSettling) {
            // See `StudyEntrance`: sidebar first, then build invisibly, then reveal.
            guard controller == nil, !model.isStudyLayoutSettling else { return }
            let controller = ExamController(model: model, request: request)
            self.controller = controller
            controller.activate()
            await StudyEntrance.waitUntilBuilt()
            withAnimation(StudyEntrance.reveal) { isRevealed = true }
        }
    }
}

/// The screen around a running `ExamController`: the phase's page, the toolbar (the time and the
/// answered questions while the exam runs) and the Lernen menu.
struct ExamScreenContent: View {
    let controller: ExamController
    /// False while the screen is built invisibly on entry (`StudyEntrance`).
    var isRevealed = true

    @Environment(AppModel.self) private var model
    @FocusState private var focus: Int?

    var body: some View {
        page
            .entranceReveal(isRevealed)
            .background { AppBackdrop(intensity: AppBackdrop.studyIntensity) }
            .navigationTitle("Prüfung")
            .navigationSubtitle(controller.set.title)
            .toolbar { toolbar }
            .focusedSceneValue(\.studyCommands, commandContext)
            .onChange(of: model.revision) { controller.storeDidChange() }
            .onDisappear { controller.deactivate() }
    }

    @ViewBuilder
    private var page: some View {
        ZStack {
            switch controller.phase {
            case .setup:
                if controller.isEmpty {
                    ExamEmptyView(controller: controller)
                        .transition(.opacity)
                } else {
                    ExamSetupView(controller: controller)
                        .transition(.opacity)
                }
            case .running:
                ExamSheetView(controller: controller, focus: $focus)
                    .transition(.opacity)
            case .results:
                ExamResultsView(controller: controller)
                    .transition(.opacity)
            }
        }
    }

    /// A sheet or alert lies over the screen.
    private var isCovered: Bool {
        model.confirmation != nil || model.isPresentingSheet
    }

    private var commandContext: StudyCommandContext {
        StudyCommandContext(
            owner: ObjectIdentifier(controller), mode: .exam, enabled: controller.enabledCommands(isCovered: isCovered)
        ) { command in
            controller.handle(command)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if controller.phase == .running {
            ToolbarItem(placement: .principal) {
                ExamToolbarStatus(controller: controller)
                    .opacity(isRevealed ? 1 : 0)
            }
        }
    }
}

/// The time (left, or taken without a limit) and the answered questions in the toolbar's centre;
/// amber in the last minute.
struct ExamToolbarStatus: View {
    let controller: ExamController

    @Environment(\.isSnapshotRendering) private var isSnapshot

    var body: some View {
        HStack(spacing: Spacing.m) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                clock(at: isSnapshot ? (controller.startedAt ?? context.date).addingTimeInterval(212) : context.date)
            }
            Text("\(controller.answeredCount)/\(controller.questions.count)")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .help("\(controller.answeredCount) von \(controller.questions.count) Fragen beantwortet")
        }
        .padding(.horizontal, Spacing.s)
        .motionAnimation(Motion.snappy, value: controller.answeredCount)
    }

    private func clock(at date: Date) -> some View {
        let deadline = controller.deadline
        let seconds: Int =
            if let deadline {
                max(0, Int(deadline.timeIntervalSince(date).rounded(.up)))
            } else {
                max(0, Int(date.timeIntervalSince(controller.startedAt ?? date)))
            }
        let isLastMinute = deadline != nil && seconds <= 60
        return Label {
            Text(ExamTime.clock(seconds))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: deadline != nil))
        } icon: {
            Image(systemName: ExamSymbols.timer)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(isLastMinute ? AnyShapeStyle(Theme.warning.text) : AnyShapeStyle(.primary))
        .accessibilityLabel(deadline != nil ? "Verbleibende Zeit" : "Verstrichene Zeit")
        .accessibilityValue(ExamTime.spoken(seconds))
        .help(deadline != nil ? "Verbleibende Zeit" : "Ohne Zeitlimit: so lange läuft die Prüfung schon")
    }
}

/// Times of the exam.
nonisolated enum ExamTime {
    /// "8:05", "1:02:05".
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let parts = (h: s / 3600, m: (s % 3600) / 60, s: s % 60)
        let two = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        return parts.h > 0 ? "\(parts.h):\(two(parts.m)):\(two(parts.s))" : "\(parts.m):\(two(parts.s))"
    }

    /// "8 Minuten 5 Sekunden" (VoiceOver).
    static func spoken(_ seconds: Int) -> String {
        let m = max(0, seconds) / 60
        let s = max(0, seconds) % 60
        if m == 0 { return Labels.plural(s, "Sekunde", "Sekunden") }
        return s == 0
            ? Labels.plural(m, "Minute", "Minuten")
            : String(
                localized: "\(Labels.plural(m, "Minute", "Minuten")) \(Labels.plural(s, "Sekunde", "Sekunden"))",
                comment: "Spoken duration: minutes, then seconds")
    }
}

/// The floating glass bar of the exam pages: something on the left, the actions on the right,
/// ending with the page's main action.
struct ExamBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        GlassEffectContainer(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                leading
                Spacer(minLength: 0)
                trailing
            }
        }
        .frame(maxWidth: LayoutMetrics.studyColumnWidth)
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.l)
        .frame(maxWidth: .infinity)
    }
}

/// A quiet glass pill on the left of the bar ("20 Wörter · 10 Minuten").
struct ExamBarPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: 44)
            .glassSurface(in: Capsule(style: .continuous))
    }
}

/// No card with both sides in the set.
struct ExamEmptyView: View {
    let controller: ExamController

    var body: some View {
        CenteredScrollView {
            EmptyStateView(
                systemImage: ExamSymbols.mode,
                title: String(localized: "Nichts zu prüfen"),
                message: String(
                    localized: "Dieses Lernset hat noch keine Begriffe mit Übersetzung. Füge welche hinzu, dann geht es los.")
            ) {
                SecondaryButton("Zurück zum Lernset", key: .escape, bindsShortcut: false, action: controller.exit)
                PrimaryActionButton("Begriffe hinzufügen", systemImage: "plus", action: controller.addCards)
            }
            .frame(maxWidth: LayoutMetrics.studyColumnWidth)
        }
    }
}
