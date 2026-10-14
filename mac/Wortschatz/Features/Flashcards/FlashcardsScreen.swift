import SwiftUI
import WortschatzCore

// The Flashcards screen (Karteikarten, Quizlet's Flashcards with "Fortschritt verfolgen").
//
// Contract with the app shell (like Lernen and Schreiben):
// - `init(request: StudyRequest)`: `request.setID`, `request.subset` (`.starred`: only the starred
//   cards; nil: resume the stored deck), `request.forceNew` (start over). The shell recreates the
//   view for every request, collapses the sidebar and puts "‹ Lernsets" into the toolbar.
// - Leaving (esc, "Zurück zum Lernset") goes through `AppModel.finishStudy()`.
// - The Lernen menu is published with `.focusedSceneValue(\.studyCommands, …)`.
// - The deck is kept per set by `AppModel.storeFlashcardDeck`; nothing goes into the progress.

/// The Flashcards screen of a set: one card at a time, turned over with the space bar (or a
/// click, Return, ↑↓) and sorted with ← "Lerne ich noch" and → "Weiss ich" (or swiped there with
/// two fingers on the trackpad or the mouse), in rounds until every card is known.
struct FlashcardsScreen: View {
    let request: StudyRequest

    @Environment(AppModel.self) private var model
    @State private var controller: FlashcardsController?
    @State private var isRevealed = false

    init(request: StudyRequest) {
        self.request = request
    }

    var body: some View {
        ZStack {
            if let controller {
                FlashcardsScreenContent(controller: controller, isRevealed: isRevealed)
            } else {
                AppBackdrop(intensity: AppBackdrop.studyIntensity)
            }
        }
        .task(id: model.isStudyLayoutSettling) {
            // See `StudyEntrance`: sidebar first, then build invisibly, then reveal.
            guard controller == nil, !model.isStudyLayoutSettling else { return }
            let controller = FlashcardsController(model: model, request: request)
            self.controller = controller
            controller.activate()
            await StudyEntrance.waitUntilBuilt()
            withAnimation(StudyEntrance.reveal) { isRevealed = true }
        }
    }
}

/// The screen around a running `FlashcardsController`: stage, toolbar, keys, focus, the Lernen
/// menu, the options popover and the card editor.
struct FlashcardsScreenContent: View {
    let controller: FlashcardsController
    /// False while the screen is built invisibly on entry (`StudyEntrance`).
    var isRevealed = true

    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool
    @State private var isShowingOptions = false
    @State private var editingCard: Card?
    /// Narrow window: the toolbar progress gets compact. Only the threshold is tracked.
    @State private var isCompactToolbar = false

    private var deck: FlashcardDeck { controller.deck }

    var body: some View {
        FlashcardsStage(controller: controller, onEditCard: editCurrentCard)
            .entranceReveal(isRevealed)
            .background {
                ZStack {
                    AppBackdrop(intensity: AppBackdrop.studyIntensity)
                    // The screen's key target, behind the content (see LearnScreen).
                    Color.clear
                        .focusable(interactions: .edit)
                        .focused($isFocused)
                        .focusEffectDisabled()
                        .onKeyPress(phases: [.down, .repeat], action: handleKey)
                        .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width < 1120 } action: { isCompactToolbar = $0 }
            .navigationTitle("Karteikarten")
            .navigationSubtitle(controller.set.title)
            .toolbar { toolbar }
            .sheet(item: $editingCard) { card in
                LearnCardEditor(card: card, termLang: controller.set.termLang, defLang: controller.set.defLang) { edited in
                    controller.saveEdit(edited)
                    editingCard = nil
                } onCancel: {
                    editingCard = nil
                }
            }
            .focusedSceneValue(\.studyCommands, commandContext)
            .defaultFocus($isFocused, true)
            .onAppear {
                focusScreen()
                // The split view settles its own focus (the sidebar list) in the same pass.
                Task { @MainActor in focusScreen() }
            }
            // A new step: the screen gets the keys again (e.g. after a click on a button).
            .onChange(of: deck.sortedInRound) { focusScreen() }
            .onChange(of: deck.round) { focusScreen() }
            .onChange(of: isShowingOptions) { _, shown in if !shown { focusScreen() } }
            .onChange(of: editingCard == nil) { _, closed in if closed { focusScreen() } }
            .onChange(of: model.revision) { controller.storeDidChange() }
            // A popover, sheet or alert opening mid-drag ends the drag without its end: the card
            // goes back to the middle instead of staying where the pointer left it.
            .onChange(of: isCovered) { _, covered in
                if covered, controller.swipe.isTracking { controller.swipeCancelled() }
            }
            .onDisappear { controller.deactivate() }
            // Two fingers sideways move the card; up and down still scroll.
            .flashcardTrackpadSwipe(controller, isEnabled: !isCovered && deck.phase == .card)
            .studyKeyFallback { [controller] input, isRepeat in
                // The window holds the keys for a moment (after a click or a closed sheet).
                controller.press(input, isRepeat: isRepeat)
            }
    }

    // MARK: Keys

    private func handleKey(_ press: SwiftUI.KeyPress) -> SwiftUI.KeyPress.Result {
        guard !isCovered, let input = LearnKeyRouter.input(for: press) else { return .ignored }
        return controller.press(input, isRepeat: press.phase == .repeat) ? .handled : .ignored
    }

    private func focusScreen() {
        guard !isCovered, !isFocused else { return }
        isFocused = true
    }

    /// A popover, sheet or alert lies over the screen.
    private var isCovered: Bool {
        isShowingOptions || editingCard != nil || model.confirmation != nil || model.isPresentingSheet
    }

    private func editCurrentCard() {
        guard !isCovered, let card = controller.currentCard else { return }
        editingCard = card
    }

    // MARK: Menu and toolbar

    private var commandContext: StudyCommandContext {
        StudyCommandContext(
            owner: ObjectIdentifier(controller), mode: .flashcards, enabled: controller.enabledCommands(isCovered: isCovered),
            isStarred: controller.currentCard?.starred ?? false
        ) { command in
            controller.handle(command) { isShowingOptions = true }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if deck.phase != .empty {
            ToolbarItem(placement: .principal) {
                FlashcardsToolbarProgress(deck: deck, isCompact: isCompactToolbar)
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
            .disabled(deck.phase == .empty)
            .popover(isPresented: $isShowingOptions, arrowEdge: .bottom) {
                FlashcardsOptionsPanel(controller: controller)
            }

            Button {
                controller.requestRestart()
            } label: {
                Label("Neu starten", systemImage: "arrow.counterclockwise")
            }
            .help("Neu starten (⇧⌘R)")
            .disabled(!deck.hasProgress)
        }
    }
}

/// "Runde 2", how far the round is and "5/12" in the toolbar's centre (the toolbar provides
/// the glass).
struct FlashcardsToolbarProgress: View {
    let deck: FlashcardDeck
    let isCompact: Bool

    var body: some View {
        let shown = min(deck.sortedInRound + (deck.phase == .card ? 1 : 0), deck.roundSize)
        HStack(spacing: isCompact ? Spacing.s : Spacing.m) {
            Text("Runde \(deck.round)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .fixedSize()
            WriteProgressLine(
                value: deck.roundSize > 0 ? Double(deck.sortedInRound) / Double(deck.roundSize) : 0, tint: Theme.accent
            )
            .frame(width: isCompact ? 72 : 120)
            Text("\(shown)/\(deck.roundSize)")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .fixedSize()
        }
        .padding(.horizontal, Spacing.s)
        .motionAnimation(Motion.snappy, value: deck.sortedInRound)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fortschritt")
        .accessibilityValue("Runde \(deck.round), Karte \(shown) von \(deck.roundSize)")
        .help("Runde \(deck.round) · \(deck.sortedInRound) von \(FlashcardCopy.cards(deck.roundSize)) sortiert")
    }
}
