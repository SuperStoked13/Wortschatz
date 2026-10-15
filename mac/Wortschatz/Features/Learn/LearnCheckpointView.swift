import SwiftUI
import WortschatzCore

/// "Runde N geschafft" after each round (spec §4.4): the round's verdict, the overall progress
/// (the segmented bar grows from where the round started), the counts and the round's cards
/// with their answers and new status. "Weiter zu Runde N ↩" is in the action bar.
struct LearnCheckpointView: View {
    let checkpoint: LearnEngine.Checkpoint
    /// The counts when the round started (the bar grows from there; nil: no animation).
    let from: LearnEngine.Counts?
    let segments: Int
    let cards: [Card]
    let termLang: Lang
    let defLang: Lang

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotRendering) private var isSnapshot
    @State private var hasGrown = false

    private var counts: LearnEngine.CheckpointCounts { checkpoint.counts }

    private var ratio: Double {
        checkpoint.answered > 0 ? Double(checkpoint.correct) / Double(checkpoint.answered) : 0
    }

    var body: some View {
        VStack(spacing: Spacing.xl) {
            VStack(spacing: Spacing.xs) {
                Text("Runde \(checkpoint.round) geschafft")
                    .eyebrowStyle()
                Text(LearnFlow.checkpointTitle(ratio))
                    .font(Typography.display)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(LearnFlow.checkpointText(checkpoint))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.xxs)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            GlassCard(padding: Spacing.xl, cornerRadius: Radii.panel) {
                progress
            }

            if !rows.isEmpty {
                LearnTermList(title: "In dieser Runde", rows: rows, termLang: termLang, defLang: defLang)
            }
        }
        .onAppear {
            guard !hasGrown else { return }
            if reduceMotion || isSnapshot || from == nil {
                hasGrown = true
            } else {
                withAnimation(Motion.gentle.delay(0.25)) { hasGrown = true }
            }
        }
    }

    private var progress: some View {
        let total = counts.total
        let shown = hasGrown || from == nil
            ? (fresh: counts.fresh, learning: counts.learning, mastered: counts.mastered)
            : (fresh: from?.fresh ?? 0, learning: from?.learning ?? 0, mastered: from?.mastered ?? 0)
        return VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(LearnFlow.masteredLine(counts.mastered, total))
                    .font(Typography.headline)
                Spacer()
                Text(WriteFlow.percentText(total > 0 ? Double(counts.mastered) / Double(total) : 0))
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(counts.mastered > 0 ? AnyShapeStyle(Theme.mastered.text) : AnyShapeStyle(.secondary))
            }
            LearnSegmentedBar(
                fills: LearnFlow.segmentFills(
                    mastered: shown.mastered, learning: shown.learning, total: total, count: segments))
            HStack(spacing: Spacing.l) {
                legend(.new, counts.fresh)
                legend(.learning, counts.learning)
                legend(.mastered, counts.mastered)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gesamtfortschritt")
        .accessibilityValue(
            LearnFlow.progressText(
                fresh: counts.fresh, learning: counts.learning, mastered: counts.mastered, total: total))
    }

    private func legend(_ status: CardStatus, _ value: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.palette.fill)
                .frame(width: 8, height: 8)
            Text(status.label)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(Typography.count)
        }
        .font(.callout)
    }

    private var rows: [LearnTermList.Row] {
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return checkpoint.items.compactMap { item in
            guard let card = byID[item.cardId] else { return nil }
            let status = LearnFlow.checkpointStatus(item.stage)
            return LearnTermList.Row(
                id: item.cardId, term: card.term, definition: card.definition,
                trailing: .checkpoint(results: item.results, status: status.status))
        }
    }
}

/// The segmented progress bar of the web Learn mode: one pill per round-sized batch, filled
/// from the left with the mastered (green) and the learning (amber) share.
struct LearnSegmentedBar: View {
    let fills: [LearnFlow.SegmentFill]
    var height: CGFloat = 10

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(fills.enumerated()), id: \.offset) { _, fill in
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Theme.new.fill.opacity(0.45))
                        Capsule(style: .continuous)
                            .fill(Theme.learning.fill)
                            .frame(width: proxy.size.width * fill.reached)
                        Capsule(style: .continuous)
                            .fill(Theme.mastered.fill)
                            .frame(width: proxy.size.width * fill.mastered)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A plain (non-glass) list of cards: term and definition (in their languages) with a status or
/// a misses chip.
struct LearnTermList: View {
    struct Row: Identifiable {
        enum Trailing {
            case checkpoint(results: [Bool], status: CardStatus)
            case misses(Int)
        }

        let id: String
        let term: String
        let definition: String
        let trailing: Trailing
    }

    let title: String
    let rows: [Row]
    let termLang: Lang
    let defLang: Lang

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                Text(title)
                    .font(Typography.title)
                    .accessibilityAddTraits(.isHeader)
                Text(rows.count, format: .number)
                    .font(Typography.count)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule(style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().padding(.leading, Spacing.l)
                    }
                    rowView(row)
                }
            }
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: Radii.tile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radii.tile, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LearnText.spoken(row.term, lang: termLang))
                    .font(.body.weight(.semibold))
                    .cardTextLine(termLang)
                Text(LearnText.spoken(row.definition, lang: defLang))
                    .foregroundStyle(.secondary)
                    .cardTextLine(defLang)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing(row.trailing)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func trailing(_ trailing: Row.Trailing) -> some View {
        switch trailing {
        case let .checkpoint(results, status):
            HStack(spacing: Spacing.s) {
                HStack(spacing: 3) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, correct in
                        Circle()
                            .fill(correct ? Theme.success.fill : Theme.failure.fill)
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Antworten: \(results.map { $0 ? "richtig" : "falsch" }.joined(separator: ", "))")
                StatusChip(status: status, size: .small)
            }
        case let .misses(count):
            TintedChip(text: "\(count)× falsch", palette: Theme.failure, size: .small)
        }
    }
}
