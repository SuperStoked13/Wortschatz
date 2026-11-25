import SwiftUI
import WortschatzCore

// The Learn screen (spec §4.4 "Learn", §4.3 key map, §6 LearnFlow).
//
// Contract with the app shell:
// - `init(request: StudyRequest)`: `request.setID`, `request.subset` (nil: resume whatever is
//   stored), `request.forceNew` (start over). The shell recreates the view for every request
//   (`.id(request.id)`), collapses the sidebar and puts "‹ Lernsets" into the toolbar.
// - Leaving (esc, "Fertig", "Zurück zum Lernset") goes through `AppModel.finishStudy()`;
//   "Schreiben üben" through `AppModel.study(.write, setID:, forceNew: true)`.
// - The Lernen menu is published with `.focusedSceneValue(\.studyCommands, …)`.
// - Everything is persisted through `model.store` by `LearnController`.

/// The Learn screen of a set: multiple choice, written questions, feedback, checkpoints and the
/// finish screen, operable with Return alone.
struct LearnScreen: View {
    let request: StudyRequest

    @Environment(AppModel.self) private var model
    @State private var controller: LearnController?
    @State private var isRevealed = false

    init(request: StudyRequest) {
        self.request = request
    }

    var body: some View {
        ZStack {
            if let controller {
                LearnScreenContent(controller: controller, isRevealed: isRevealed)
                    .modifier(SameTermPresenter(question: controller.sameTerm, answer: controller.answerSameTerm))
            } else {
                AppBackdrop(intensity: AppBackdrop.studyIntensity)
            }
        }
        .task(id: model.isStudyLayoutSettling) {
            // See `StudyEntrance`: sidebar first, then build invisibly, then reveal.
            guard controller == nil, !model.isStudyLayoutSettling else { return }
            #if DEBUG
            let controller = DebugTiming.measure("LearnController.init") { LearnController(model: model, request: request) }
            #else
            let controller = LearnController(model: model, request: request)
            #endif
            self.controller = controller
            #if DEBUG
            DebugTiming.measure("LearnController.activate") { controller.activate(holdingToasts: true) }
            #else
            controller.activate(holdingToasts: true)
            #endif
            // The (invisible) first layout, then the reveal.
            await StudyEntrance.waitUntilBuilt()
            #if DEBUG
            DebugTiming.mark("Reveal")
            #endif
            withAnimation(StudyEntrance.reveal) { isRevealed = true }
            try? await Task.sleep(for: StudyEntrance.toastDelay)
            guard !Task.isCancelled else { return }
            controller.releaseToasts()
        }
    }
}

/// The screen around a running `LearnController`: stage, toolbar, key handling, focus, the
/// Lernen menu, the options popover, the card editor and the confirmation prompts. Also used
/// by the snapshot harness with a scripted controller.
struct LearnScreenContent: View {
    let controller: LearnController
    /// False while the screen is built invisibly on entry (`StudyEntrance`).
    var isRevealed = true

    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive
    @FocusState private var focus: LearnKeyRouter.Focus?
    @State private var isShowingOptions = false
    @State private var editingCard: Card?
    @State private var selection: TextSelection?
    /// Set when the answer field is focused programmatically: the caret then goes behind the
    /// text (a key typed after a correct answer starts the next one) instead of selecting it.
    @State private var placesCaretAtEnd = false
    /// Narrow window: the toolbar capsule gets compact. Only the threshold is tracked, so the
    /// sidebar sliding away does not rebuild the screen on every animation frame.
    @State private var isCompactToolbar = false

    private var state: LearnFlow.State { controller.state }

    /// The stage with its toolbar, prompts and editor; `body` adds the observers. Split in two so
    /// the type checker keeps up with the chain.
    private var stage: some View {
        LearnStage(controller: controller, focus: $focus, selection: $selection, onEditCard: editCurrentCard)
            .entranceReveal(isRevealed)
            .background {
                ZStack {
                    AppBackdrop(intensity: AppBackdrop.studyIntensity)
                    // The screen's key target. It sits behind the content rather than around
                    // it, so controls inside (the answer tiles) do not read its focus as theirs.
                    Color.clear
                        .focusable(interactions: .edit)
                        .focused($focus, equals: .screen)
                        .focusEffectDisabled()
                        .onKeyPress(phases: [.down, .repeat], action: handleKey)
                        .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width < 1120 } action: { isCompactToolbar = $0 }
            .navigationTitle("Lernen")
            .navigationSubtitle(state.setTitle)
            .toolbar { toolbar }
            .alert(
                LearnFlow.promptContent(state)?.title ?? "",
                isPresented: Binding(get: { state.prompt != nil }, set: { _ in }),
                presenting: LearnFlow.promptContent(state)
            ) { content in
                LearnPromptButtons(content: content) { confirmed in
                    controller.send(.promptAnswered(confirmed: confirmed))
                }
            } message: { content in
                Text(content.message)
            }
            .sheet(item: $editingCard) { card in
                LearnCardEditor(card: card, termLang: state.termLang, defLang: state.defLang) { edited in
                    controller.send(.editCard(edited))
                    editingCard = nil
                } onCancel: {
                    editingCard = nil
                }
            }
            .focusedSceneValue(\.studyCommands, commandContext)
            .defaultFocus($focus, LearnKeyRouter.focus(for: state) ?? .screen)
    }

    var body: some View {
        stage
            .onAppear {
                focusForState()
                // The split view settles its own focus (the sidebar list) in the same pass.
                Task { @MainActor in focusForState() }
            }
            .onChange(of: LearnKeyRouter.focus(for: state)) { focusForState() }
            .onChange(of: state.transitions) {
                // A new step: the field (or the screen) gets the keys again, e.g. after a click.
                focusForState()
            }
            .onChange(of: focus) { _, newFocus in
                if newFocus == .answer, placesCaretAtEnd {
                    placesCaretAtEnd = false
                    // After AppKit's select-all on becoming first responder.
                    Task { @MainActor in selection = TextSelection(insertionPoint: state.draft.endIndex) }
                } else if newFocus == .screen, LearnKeyRouter.focus(for: state) == .answer {
                    // A click beside the field while typing: the keys stay in the field.
                    focusForState()
                }
            }
            .onChange(of: model.revision) { controller.storeDidChange() }
            .onChange(of: model.learnSwitches) { _, switches in controller.switchesChanged(switches) }
            .onChange(of: controller.optionsRequest) { isShowingOptions = true }
            .onChange(of: isShowingOptions) { _, shown in
                controller.send(shown ? .overlayPresented(.options) : .overlayDismissed)
            }
            .onChange(of: editingCard != nil) { _, shown in
                controller.send(shown ? .overlayPresented(.editor) : .overlayDismissed)
            }
            .onChange(of: model.isPresentingSheet) { _, shown in
                // The set editor (Lernset › Bearbeiten, "Begriffe hinzufügen") covers the screen.
                if shown {
                    controller.setEditorOpened()
                } else {
                    controller.setEditorClosed()
                }
            }
            .onChange(of: appearsActive) { _, active in controller.windowActivityChanged(active) }
            .task { await controller.runClock() }
            .onDisappear { controller.deactivate() }
            .studyKeyFallback { [controller] input, isRepeat in
                // The window holds the keys for a moment (a removed answer field had them).
                guard LearnKeyRouter.focus(for: controller.state) == .screen,
                    LearnKeyRouter.consumes(input, in: controller.state, focus: .screen)
                else { return false }
                controller.press(input, isRepeat: isRepeat)
                return true
            }
    }

    // MARK: Keys

    private func handleKey(_ press: SwiftUI.KeyPress) -> SwiftUI.KeyPress.Result {
        guard let input = LearnKeyRouter.input(for: press),
            LearnKeyRouter.consumes(input, in: state, focus: focus)
        else { return .ignored }
        controller.press(input, isRepeat: press.phase == .repeat)
        return .handled
    }

    /// Puts the keyboard focus where the step needs it (`LearnKeyRouter.focus(for:)`).
    private func focusForState() {
        guard let wanted = LearnKeyRouter.focus(for: state), focus != wanted else { return }
        if wanted == .answer { placesCaretAtEnd = true }
        focus = wanted
    }

    // MARK: Menu and toolbar

    private var commandContext: StudyCommandContext {
        StudyCommandContext(
            owner: ObjectIdentifier(controller), mode: .learn, enabled: controller.enabledCommands,
            isStarred: state.question?.starred ?? false
        ) { command in
            controller.handle(command) { isShowingOptions = true }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if state.session != nil {
            ToolbarItem(placement: .principal) {
                LearnToolbarProgress(
                    counts: StatusCounts(state.counts), round: state.round, isCompact: isCompactToolbar)
                    // Comes in with the screen, not before it.
                    .opacity(isRevealed ? 1 : 0)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                isShowingOptions = true
            } label: {
                Label("Optionen", systemImage: "slider.horizontal.3")
            }
            .help("Optionen (⌘K)")
            .disabled(!controller.canShowOptions)
            .popover(isPresented: $isShowingOptions, arrowEdge: .bottom) {
                LearnOptionsPanel(controller: controller)
            }

            Button {
                controller.send(.restart)
            } label: {
                Label(
                    state.phase == .finished ? "Nochmal lernen" : "Neu starten", systemImage: "arrow.counterclockwise")
            }
            .help(state.phase == .finished ? "Nochmal lernen (⇧⌘R)" : "Neu starten (⇧⌘R)")
            .disabled(!controller.enabledCommands.contains(.restart))
        }
    }

    private func editCurrentCard() {
        guard state.overlay == nil, state.prompt == nil, let card = controller.currentCard else { return }
        editingCard = card
    }
}

/// "Runde 2" and the progress capsule in the toolbar's centre (the toolbar provides the glass).
private struct LearnToolbarProgress: View {
    let counts: StatusCounts
    let round: Int
    let isCompact: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text("Runde \(round)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .fixedSize()
            ProgressCapsule(counts: counts, style: isCompact ? .compact : .full, isGlass: false)
        }
        .padding(.leading, Spacing.s)
        .accessibilityElement(children: .combine)
    }
}

/// The buttons of a `LearnFlow` prompt. Destructive prompts keep the cancel button on Return
/// (like the web app's danger dialogs); the others confirm with Return. Esc always cancels.
private struct LearnPromptButtons: View {
    let content: LearnFlow.PromptContent
    let answer: (Bool) -> Void

    var body: some View {
        if content.isDestructive {
            Button(content.confirmLabel, role: .destructive) { answer(true) }
            Button(content.cancelLabel, role: .cancel) { answer(false) }
                .keyboardShortcut(.defaultAction)
        } else {
            Button(content.confirmLabel) { answer(true) }
                .keyboardShortcut(.defaultAction)
            Button(content.cancelLabel, role: .cancel) { answer(false) }
        }
    }
}
