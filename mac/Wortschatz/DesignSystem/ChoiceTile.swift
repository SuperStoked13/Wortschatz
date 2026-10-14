import SwiftUI

/// Visual state of a multiple-choice tile.
enum ChoiceTileState: Sendable, Equatable {
    /// Waiting for an answer.
    case idle
    /// The keyboard highlight (↑↓←→, or the letters typed): Return chooses this tile.
    case highlighted
    /// Waiting, but the letters typed so far do not start this answer.
    case filtered
    /// The right answer (after answering).
    case correct
    /// The answer the learner chose, and it was wrong.
    case wrong
    /// Any other tile after answering.
    case dimmed

    var isAnswered: Bool {
        switch self {
        case .idle, .highlighted, .filtered: false
        case .correct, .wrong, .dimmed: true
        }
    }
}

/// A multiple-choice answer on interactive glass, with its number badge (1-4) as keycap
/// (spec §4.4). Put the tiles of one question into a single `GlassEffectContainer`; `ChoiceGrid`
/// does that and lays them out 2×2.
///
/// ```swift
/// ChoiceTile(number: 1, text: "la maison", state: .highlighted) { send(.choose(0)) }
/// ```
struct ChoiceTile: View {
    let number: Int
    let text: String
    var state: ChoiceTileState = .idle
    /// The letters of `text` the learner typed (`Character` offsets), drawn in the accent colour.
    var emphasis: Range<Int>? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
        }
        .buttonStyle(ChoiceTileStyle(number: number, state: state))
        .focusEffectDisabled()
        .accessibilityLabel(text)
        .accessibilityValue(accessibilityState)
        .accessibilityIdentifier("choice-\(number)")
        .shortcutAccessibilityHint(state.isAnswered ? nil : .digit(number))
        .accessibilityAddTraits(state == .highlighted ? .isSelected : [])
    }

    /// `text` with the typed letters underlined in the accent colour.
    private var label: AttributedString {
        var out = AttributedString(text)
        guard let emphasis, !emphasis.isEmpty, emphasis.lowerBound >= 0, emphasis.upperBound <= text.count else {
            return out
        }
        let lower = out.index(out.startIndex, offsetByCharacters: emphasis.lowerBound)
        let upper = out.index(out.startIndex, offsetByCharacters: emphasis.upperBound)
        out[lower..<upper].foregroundColor = Theme.accentText
        out[lower..<upper].underlineStyle = .single
        return out
    }

    private var accessibilityState: String {
        switch state {
        case .idle, .highlighted, .filtered: "Antwort \(number)"
        case .correct: "Richtige Antwort"
        case .wrong: "Deine Antwort, falsch"
        case .dimmed: ""
        }
    }
}

private struct ChoiceTileStyle: ButtonStyle {
    let number: Int
    let state: ChoiceTileState

    func makeBody(configuration: Configuration) -> some View {
        ChoiceTileBody(configuration: configuration, number: number, state: state)
    }
}

private struct ChoiceTileBody: View {
    let configuration: ButtonStyleConfiguration
    let number: Int
    let state: ChoiceTileState

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shake = 0
    @State private var bounce = 0

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radii.tile, style: .continuous)
    }

    // Inside a GlassEffectContainer, modifiers applied *outside* `.glassEffect` (opacity,
    // overlay, scaleEffect) are not rendered, so every state visual lives in the content.
    // Offsets (the shake) are fine; pressing is answered by the interactive glass itself.
    var body: some View {
        HStack(spacing: Spacing.m) {
            badge
            configuration.label
                .font(Typography.answer)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(state == .dimmed ? 0.4 : state == .filtered ? 0.5 : 1)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, minHeight: LayoutMetrics.choiceTileMinHeight, maxHeight: .infinity, alignment: .leading)
        .overlay {
            if let ring {
                shape.strokeBorder(ring, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(shape)
        .glassSurface(tint: tint, interactive: !state.isAnswered, in: shape)
        .shake(trigger: shake, amplitude: 7)
        .motionAnimation(Motion.snappy, value: state)
        .onChange(of: state) { _, new in
            if new == .correct || new == .wrong { bounce += 1 }
            if new == .wrong, !reduceMotion { shake += 1 }
        }
    }

    private var tint: Color? {
        switch state {
        case .idle, .filtered, .dimmed: nil
        case .highlighted: Theme.accent.opacity(0.14)
        case .correct: Theme.success.fill.opacity(0.28)
        case .wrong: Theme.failure.fill.opacity(0.26)
        }
    }

    private var ring: Color? {
        switch state {
        case .highlighted: Theme.accent
        case .correct: Theme.success.fill
        case .wrong: Theme.failure.fill
        case .idle, .filtered: isFocused ? Theme.accent : nil
        case .dimmed: nil
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .correct:
            badgeSymbol("checkmark.circle.fill", Theme.success.fill)
        case .wrong:
            badgeSymbol("xmark.circle.fill", Theme.failure.fill)
        case .highlighted:
            Text(String(number))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .idle, .filtered, .dimmed:
            Text(String(number))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.tertiary, lineWidth: 0.5)
                }
        }
    }

    private func badgeSymbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 26, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, color)
            .frame(width: 28, height: 28)
            .transition(.scale.combined(with: .opacity))
            .symbolEffect(.bounce, options: .nonRepeating, value: bounce)
    }
}

/// The 2×2 multiple-choice grid: tiles numbered 1…n in one `GlassEffectContainer`, rows of
/// equal height.
///
/// ```swift
/// ChoiceGrid(choices: question.choices.map(\.text), state: { i in tileState(i) }) { i in
///     send(.choose(i))
/// }
/// ```
struct ChoiceGrid: View {
    let choices: [String]
    /// State of the tile at a 0-based index.
    var state: (Int) -> ChoiceTileState = { _ in .idle }
    /// The typed letters of the tile at a 0-based index (`ChoiceTile.emphasis`).
    var emphasis: (Int) -> Range<Int>? = { _ in nil }
    let onChoose: (Int) -> Void

    /// Two tiles per row.
    private let columns = 2

    var body: some View {
        GlassEffectContainer(spacing: Spacing.s) {
            Grid(horizontalSpacing: Spacing.s + 2, verticalSpacing: Spacing.s + 2) {
                ForEach(rows, id: \.self) { row in
                    GridRow {
                        ForEach(row, id: \.self) { index in
                            ChoiceTile(
                                number: index + 1,
                                text: choices[index],
                                state: state(index),
                                emphasis: emphasis(index)
                            ) {
                                onChoose(index)
                            }
                        }
                    }
                }
            }
            // Rows take their natural height (tallest tile of the row), never the whole column.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rows: [[Int]] {
        stride(from: 0, to: choices.count, by: columns).map { start in
            Array(start..<min(start + columns, choices.count))
        }
    }
}
