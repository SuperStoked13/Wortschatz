import SwiftUI
import WortschatzCore

/// The flashcards screen's content: the card on its stack (or the round summary, with the last
/// card still gliding off over it), and the floating action bar; an empty set gets a message
/// instead.
struct FlashcardsStage: View {
    let controller: FlashcardsController
    let onEditCard: () -> Void

    /// The stage's size in 16-pt steps, so a live resize does not rebuild it on every frame.
    @State private var size = CGSize(width: 1000, height: 748)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phase: FlashcardDeck.Phase { controller.phase }

    var body: some View {
        Group {
            if phase == .empty {
                FlashcardsEmptyView(controller: controller)
            } else {
                ScrollView {
                    ZStack(alignment: .top) {
                        summary
                        deck
                    }
                    .frame(maxWidth: LayoutMetrics.studyColumnWidth)
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.top, topInset)
                    .padding(.bottom, Spacing.xl)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                // The turning card and the cards gliding off may reach past the column.
                .scrollClipDisabled()
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    FlashcardsActionBar(controller: controller)
                        .reservesToastSpace()
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(width: (proxy.size.width / 16).rounded() * 16, height: (proxy.size.height / 16).rounded() * 16)
        } action: { size = $0 }
    }

    /// The deck, also after the round while its last card is still leaving.
    @ViewBuilder
    private var deck: some View {
        if phase == .card || !controller.departures.isEmpty {
            FlashcardDeckView(controller: controller, height: cardHeight, onEdit: onEditCard)
                // The first card rises like every later one.
                .entranceShift(y: StudyEntrance.tileShift)
                .transition(
                    .asymmetric(
                        insertion: reduceMotion
                            ? .opacity.animation(.easeOut(duration: 0.2))
                            : .opacity.combined(with: .offset(y: FlashcardMotion.riseDistance))
                                .animation(FlashcardMotion.arrive),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch phase {
        case .roundDone, .finished:
            FlashcardsSummaryView(deck: controller.deck)
                .id(phase == .finished)
                // After the last card has started to glide off.
                .transition(
                    .asymmetric(
                        insertion: .opacity.animation(Motion.soft(0.42).delay(0.22)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
        case .card, .empty:
            EmptyView()
        }
    }

    // MARK: Layout

    private var columnWidth: CGFloat {
        min(LayoutMetrics.studyColumnWidth, size.width - 2 * Spacing.xxl)
    }

    /// The card sits a little below the toolbar in tall windows and close to it in short ones.
    private var topInset: CGFloat {
        LayoutMetrics.studyCardTopInset(height: size.height) * 0.75
    }

    /// The card's height: what is left above the action bar, in an index-card shape.
    private var cardHeight: CGFloat {
        let actionBar: CGFloat = 84
        let available = size.height - topInset - actionBar - FlashcardMetrics.stackDepth - Spacing.xl
        return FlashcardMetrics.cardHeight(width: columnWidth, availableHeight: available)
    }
}

// MARK: - Action bar

/// The floating glass bar: ↶ Zurück on the left; on a card ← "Lerne ich noch", → "Weiss ich"
/// (with this round's counts) and "Umdrehen ↩"; after a round "Weiter mit N Karten ↩"; at the
/// end "Lernen" and "Nochmal von vorne ↩". It always ends with the Return action.
struct FlashcardsActionBar: View {
    let controller: FlashcardsController

    private var deck: FlashcardDeck { controller.deck }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(isCompact: false)
            bar(isCompact: true)
        }
        .frame(maxWidth: LayoutMetrics.studyColumnWidth)
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.l)
        .frame(maxWidth: .infinity)
        .motionAnimation(Motion.snappy, value: deck.phase)
    }

    private func bar(isCompact: Bool) -> some View {
        GlassEffectContainer(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Button(action: controller.undo) {
                    Label("Zurück", systemImage: FlashcardsSymbols.undo)
                        .labelStyle(.iconOnly)
                        .frame(height: Keycap.Size.regular.height)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(!deck.canUndo)
                .help("Letzte Karte zurückholen (⌫)")
                .shortcutAccessibilityHint(.delete)

                Spacer(minLength: 0)

                switch deck.phase {
                case .card:
                    FlashcardSortButton(verdict: .stillLearning, count: deck.learningCount, isCompact: isCompact) {
                        controller.sort(.stillLearning)
                    }
                    FlashcardSortButton(verdict: .know, count: deck.knownInRound, isCompact: isCompact) {
                        controller.sort(.know)
                    }
                    PrimaryActionButton("Umdrehen", bindsShortcut: false, action: controller.flip)
                case .roundDone:
                    SecondaryButton("Zurück zum Lernset", key: .escape, bindsShortcut: false, action: controller.exit)
                    PrimaryActionButton(
                        verbatim: FlashcardCopy.nextRoundAction(deck), bindsShortcut: false, action: controller.nextRound)
                case .finished:
                    SecondaryButton("Lernen", systemImage: "sparkles", bindsShortcut: false, action: controller.openLearn)
                        .help("Die Begriffe jetzt abfragen, damit sie als gemeistert zählen")
                    PrimaryActionButton("Nochmal von vorne", bindsShortcut: false) { controller.restart() }
                case .empty:
                    EmptyView()
                }
            }
        }
    }
}

/// "← ↺ Lerne ich noch 3" and "✓ Weiss ich 5 →": glass buttons with the verdict's colour on the
/// symbol and the count, the arrow key on the side the card goes to.
private struct FlashcardSortButton: View {
    let verdict: FlashcardVerdict
    let count: Int
    let isCompact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if verdict == .stillLearning { Keycap(.leftArrow) }
                Image(systemName: verdict.symbol)
                    .fontWeight(.bold)
                    .foregroundStyle(verdict.color.fill)
                if !isCompact {
                    Text(verdict.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                Text(count, format: .number)
                    .font(Typography.count)
                    .foregroundStyle(verdict.color.text)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(verdict.color.soft, in: Capsule(style: .continuous))
                    .pop(trigger: count, scale: 1.12)
                if verdict == .know { Keycap(.rightArrow) }
            }
            .padding(.horizontal, Spacing.xxs)
            .frame(minHeight: Keycap.Size.regular.height)
            .motionAnimation(Motion.snappy, value: count)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .help("\(verdict.title) (\(verdict == .know ? "→" : "←"))")
        .accessibilityLabel(verdict.title)
        .accessibilityValue(FlashcardCopy.cards(count))
        .shortcutAccessibilityHint(verdict == .know ? .rightArrow : .leftArrow)
    }
}

// MARK: - Round summary

/// After a round ("Du machst Fortschritte!") and once every card is known ("Super, du kennst
/// alle 12 Karten!", with confetti): what was sorted, as glass tiles on the backdrop.
struct FlashcardsSummaryView: View {
    let deck: FlashcardDeck

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    private var isFinished: Bool { deck.phase == .finished }

    var body: some View {
        let accent = isFinished ? Theme.success.fill : Theme.accent
        VStack(spacing: Spacing.xl) {
            VStack(spacing: Spacing.s) {
                ZStack {
                    Circle()
                        .fill(accent.gradient)
                        .frame(width: 88, height: 88)
                        .shadow(color: accent.opacity(0.35), radius: 16, y: 6)
                    Image(systemName: isFinished ? "hands.clap.fill" : FlashcardsSymbols.mode)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, options: .nonRepeating, value: bounce)
                }
                .padding(.bottom, Spacing.xs)
                .accessibilityHidden(true)

                Text(isFinished ? "Karteikarten" : "Runde \(deck.round) geschafft")
                    .eyebrowStyle()
                Text(isFinished ? FlashcardCopy.finishedTitle(deck) : FlashcardCopy.roundDoneTitle(deck))
                    .font(Typography.display)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(isFinished ? FlashcardCopy.finishedText(deck) : FlashcardCopy.roundDoneText(deck))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: Spacing.s) {
                StatTile("Weiss ich", value: "\(deck.knownCount)", systemImage: FlashcardsSymbols.know, tint: Theme.success.fill)
                if !isFinished {
                    StatTile(
                        "Lerne ich noch", value: "\(deck.learningCount)", systemImage: FlashcardsSymbols.stillLearning,
                        tint: Theme.learning.fill)
                }
                StatTile(
                    deck.round == 1 ? "Runde" : "Runden", value: "\(deck.round)",
                    systemImage: "arrow.trianglehead.2.clockwise", tint: Theme.info.fill)
            }
            .frame(maxWidth: 620)
        }
        .padding(.top, Spacing.l)
        .modifier(FinishCelebration(isActive: isFinished))
        .onAppear {
            if !reduceMotion { bounce += 1 }
        }
    }
}

/// Confetti once every card is known.
private struct FinishCelebration: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.celebration(origin: UnitPoint(x: 0.5, y: 0.1))
        } else {
            content
        }
    }
}

// MARK: - Empty set

/// No card with text in the set: back to the set, or add terms (Return).
struct FlashcardsEmptyView: View {
    let controller: FlashcardsController

    var body: some View {
        CenteredScrollView {
            EmptyStateView(
                systemImage: "rectangle.on.rectangle.slash",
                title: "Keine Karten zum Umdrehen",
                message: "Dieses Lernset hat noch keine Begriffe. Füge welche hinzu, dann geht es los."
            ) {
                SecondaryButton("Zurück zum Lernset", key: .escape, bindsShortcut: false, action: controller.exit)
                PrimaryActionButton("Begriffe hinzufügen", systemImage: "plus", action: controller.addCards)
            }
            .frame(maxWidth: LayoutMetrics.studyColumnWidth)
        }
    }
}
