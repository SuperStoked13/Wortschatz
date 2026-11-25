import SwiftUI
import WortschatzCore

// The Write screen (spec §4.4 "Write", §4.3 key map, §6 WriteFlow): Quizlet's "Schreiben".
//
// Contract with the app shell:
// - `init(request: StudyRequest)`: `request.setID`, `request.subset` (nil: resume whatever is
//   stored), `request.forceNew` (start over). The shell recreates the view for every request
//   (`.id(request.id)`), collapses the sidebar and puts "‹ Lernsets" into the toolbar.
// - Leaving (esc, "Fertig", "Zurück zum Lernset") goes through `AppModel.finishStudy()`.
// - The Lernen menu is published with `.focusedSceneValue(\.studyCommands, …)`.
// - Everything is persisted through `model.store` by `WriteController`.

/// The Write screen of a set: written questions in rounds, feedback with the copy step, the
/// round summary and the results, operable with Return alone.
struct WriteScreen: View {
    let request: StudyRequest

    @Environment(AppModel.self) private var model
    @State private var controller: WriteController?
    @State private var isRevealed = false

    init(request: StudyRequest) {
        self.request = request
    }

    var body: some View {
        ZStack {
            if let controller {
                WriteScreenContent(controller: controller, isRevealed: isRevealed)
                    .modifier(SameTermPresenter(question: controller.sameTerm, answer: controller.answerSameTerm))
            } else {
                AppBackdrop(intensity: AppBackdrop.studyIntensity)
            }
        }
        .task(id: model.isStudyLayoutSettling) {
            // See `StudyEntrance`: sidebar first, then build invisibly, then reveal.
            guard controller == nil, !model.isStudyLayoutSettling else { return }
            let controller = WriteController(model: model, request: request)
            self.controller = controller
            controller.activate(holdingToasts: true)
            await StudyEntrance.waitUntilBuilt()
            withAnimation(StudyEntrance.reveal) { isRevealed = true }
            try? await Task.sleep(for: StudyEntrance.toastDelay)
            guard !Task.isCancelled else { return }
            controller.releaseToasts()
        }
    }
}

/// The screen around a running `WriteController`: stage, toolbar, key handling, focus, the
/// Lernen menu, the options popover, the card editor and the confirmation alerts. Also used by
/// the snapshot harness with a scripted controller.
struct WriteScreenContent: View {
    let controller: WriteController
    /// False while the screen is built invisibly on entry (`StudyEntrance`).
    var isRevealed = true

    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive
    @FocusState private var focus: WriteKeyRouter.Focus?
    @State private var selection: TextSelection?
    /// Set when the answer field is focused programmatically: the caret then goes behind the
    /// text (a key typed after a correct answer starts the next answer) instead of selecting it.
    @State private var placesCaretAtEnd = false
    /// Narrow window: the toolbar counters get compact. Only the threshold is tracked, so the
    /// sidebar sliding away does not rebuild the screen on every animation frame.
    @State private var isCompactToolbar = false

    private var state: WriteFlow.State { controller.state }

    var body: some View {
        WriteStage(controller: controller, focus: $focus, selection: $selection)
            .entranceReveal(isRevealed)
            .background {
                ZStack {
                    AppBackdrop(intensity: AppBackdrop.studyIntensity)
                    // The screen's key target. It sits behind the content rather than around
                    // it, so controls inside do not read its focus as theirs.
                    Color.clear
                        .focusable(interactions: .edit)
                        .focused($focus, equals: .screen)
                        .focusEffectDisabled()
                        .onKeyPress(phases: [.down, .repeat], action: handleKey)
                        .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width < 1120 } action: { isCompactToolbar = $0 }
            .navigationTitle("Schreiben")
            .navigationSubtitle(state.set?.title ?? "")
            .toolbar { toolbar }
            .alert(
                state.prompt?.title ?? "",
                isPresented: Binding(get: { state.prompt != nil }, set: { _ in }),
                presenting: state.prompt
            ) { prompt in
                Button(prompt.confirmLabel) { controller.send(.promptAnswered(confirmed: true)) }
                    .keyboardShortcut(.defaultAction)
                Button(prompt.cancelLabel, role: .cancel) { controller.send(.promptAnswered(confirmed: false)) }
            } message: { prompt in
                Text(prompt.message)
            }
            .sheet(item: editorBinding) { card in
                WriteCardEditor(card: card, termLang: state.set?.termLang ?? .other, defLang: state.set?.defLang ?? .other, focus: editorFocus) { edited in
                    controller.send(.editCard(edited))
                } onCancel: {
                    controller.send(.overlayDismissed())
                }
            }
            .focusedSceneValue(\.studyCommands, commandContext)
            .defaultFocus($focus, WriteKeyRouter.focus(for: state) ?? .screen)
            .onAppear {
                focusForState()
                // The split view settles its own focus (the sidebar list) in the same pass.
                Task { @MainActor in focusForState() }
            }
            .onChange(of: WriteKeyRouter.focus(for: state)) { focusForState() }
            .onChange(of: state.questionSerial) { focusForState() }
            .onChange(of: state.focusSerial) { focusForState() }
            .onChange(of: focus) { _, newFocus in
                if newFocus == .answer, placesCaretAtEnd {
                    placesCaretAtEnd = false
                    // After AppKit's select-all on becoming first responder.
                    Task { @MainActor in selection = TextSelection(insertionPoint: state.input.endIndex) }
                } else if newFocus == .screen, WriteKeyRouter.focus(for: state) == .answer {
                    // A click beside the field while typing: the keys stay in the field.
                    focusForState()
                }
            }
            .onChange(of: model.revision) { controller.storeDidChange() }
            .onChange(of: model.isPresentingSheet) { _, shown in
                // The set editor ("Begriffe hinzufügen", Lernset › Bearbeiten) closed.
                if !shown { controller.setEditorClosed() }
            }
            .onChange(of: appearsActive) { _, active in controller.windowActivityChanged(active) }
            .task { await controller.runClock() }
            .onDisappear { controller.deactivate() }
            .studyKeyFallback { [controller] input, isRepeat in
                // The window holds the keys for a moment (a removed answer field had them).
                guard WriteKeyRouter.focus(for: controller.state) == .screen,
                    WriteKeyRouter.consumes(input, in: controller.state, focus: .screen)
                else { return false }
                controller.press(input, isRepeat: isRepeat)
                return true
            }
    }

    // MARK: Keys and focus

    private func handleKey(_ press: SwiftUI.KeyPress) -> SwiftUI.KeyPress.Result {
        guard let input = WriteKeyRouter.input(for: press),
            WriteKeyRouter.consumes(input, in: state, focus: focus)
        else { return .ignored }
        controller.press(input, isRepeat: press.phase == .repeat)
        return .handled
    }

    /// Puts the keyboard focus where the step needs it (`WriteKeyRouter.focus(for:)`).
    private func focusForState() {
        guard let wanted = WriteKeyRouter.focus(for: state), focus != wanted else { return }
        if wanted == .answer { placesCaretAtEnd = true }
        focus = wanted
    }

    // MARK: Dialogs

    /// The card editor follows the flow's `Overlay.editor`; closing it any other way than
    /// "Sichern" cancels.
    private var editorBinding: Binding<Card?> {
        Binding(
            get: { WriteFlow.editorCard(controller.state) },
            set: { card in
                guard card == nil, case .editor? = controller.state.overlay else { return }
                controller.send(.overlayDismissed())
            })
    }

    /// The side the learner had to type: the editor focuses it.
    private var editorFocus: AskSide {
        if case let .editor(_, focus, _)? = state.overlay { return focus }
        return .term
    }

    private var optionsBinding: Binding<Bool> {
        Binding(
            get: {
                if case .options? = controller.state.overlay { return true }
                return false
            },
            set: { shown in
                if shown {
                    controller.send(.requestOptions)
                } else if case .options? = controller.state.overlay {
                    controller.send(.overlayDismissed())
                }
            })
    }

    // MARK: Menu and toolbar

    private var commandContext: StudyCommandContext {
        StudyCommandContext(
            owner: ObjectIdentifier(controller), mode: .write, enabled: controller.enabledCommands,
            isStarred: state.question?.starred ?? false
        ) { command in
            controller.handle(command)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let counters = WriteFlow.counters(state), state.phase != .starting, state.phase != .empty {
            ToolbarItem(placement: .principal) {
                WriteToolbarProgress(counters: counters, isCompact: isCompactToolbar)
                    // Comes in with the screen, not before it.
                    .opacity(isRevealed ? 1 : 0)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                controller.send(.requestOptions)
            } label: {
                Label("Optionen", systemImage: "slider.horizontal.3")
            }
            .help("Optionen (⌘K)")
            .disabled(!controller.canShowOptions)
            .popover(isPresented: optionsBinding, arrowEdge: .bottom) {
                WriteOptionsPanel(controller: controller)
            }

            Button {
                controller.send(.restart)
            } label: {
                Label(state.phase == .results ? "Nochmal von vorne" : "Neu starten", systemImage: "arrow.counterclockwise")
            }
            .help(state.phase == .results ? "Nochmal von vorne (⇧⌘R)" : "Neu starten (⇧⌘R)")
            .disabled(!controller.enabledCommands.contains(.restart))
        }
    }
}

/// "Runde 2", the counters Verbleibend · Falsch · Richtig and the session's progress in the
/// toolbar's centre (the toolbar provides the glass). Compact: numbers with coloured dots.
struct WriteToolbarProgress: View {
    let counters: WriteSession.Counters
    let isCompact: Bool

    var body: some View {
        HStack(spacing: isCompact ? Spacing.s : Spacing.m) {
            Text("Runde \(counters.round)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .fixedSize()
            HStack(spacing: isCompact ? Spacing.xs : Spacing.s) {
                counter(counters.remaining, label: String(localized: "Verbleibend"), color: Theme.new.fill)
                counter(counters.incorrect, label: String(localized: "Falsch"), color: Theme.failure.fill)
                counter(counters.correct, label: String(localized: "Richtig"), color: Theme.success.fill)
            }
            WriteProgressLine(value: counters.progress)
                .frame(width: isCompact ? 56 : 88)
            Text("\(counters.correct)/\(counters.total)")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .fixedSize()
        }
        .padding(.horizontal, Spacing.s)
        .motionAnimation(Motion.snappy, value: counters)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fortschritt")
        .accessibilityValue(WriteFlow.countersAccessibilityLabel(counters))
        .help(WriteFlow.countersAccessibilityLabel(counters))
    }

    private func counter(_ value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(value, format: .number)
                .font(Typography.count)
                .contentTransition(.numericText())
            if !isCompact {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}

/// A slim accent progress line (0…1).
struct WriteProgressLine: View {
    let value: Double
    var tint: Color = Theme.success.fill
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.09))
                Capsule(style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: value > 0 ? max(height, proxy.size.width * min(1, value)) : 0)
            }
        }
        .frame(height: height)
        .motionAnimation(Motion.gentle, value: value)
        .accessibilityHidden(true)
    }
}
