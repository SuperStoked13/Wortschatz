import SwiftUI
import WortschatzCore

/// The round summary ("Runde 1 geschafft", spec §4.4): the round's verdict, a glass panel with
/// the share of right answers as a ring, the counts and the whole session's progress, and the
/// round's cards grouped into "Noch üben" and "Richtig". "Weiter zu Runde N ↩" is in the action
/// bar.
struct WriteSummaryView: View {
    let summary: WriteSession.RoundSummary
    let rows: [WriteFlow.TermRow]
    let counters: WriteSession.Counters?

    private var ratio: Double { WriteFlow.summaryRatio(summary) }

    var body: some View {
        VStack(spacing: Spacing.xl) {
            VStack(spacing: Spacing.xs) {
                Text(WriteFlow.summaryEyebrow(summary))
                    .eyebrowStyle()
                Text(WriteFlow.summaryTitle(ratio: ratio))
                    .font(Typography.display)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(WriteFlow.summaryText(summary))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.xxs)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            GlassCard(padding: Spacing.xl, cornerRadius: Radii.panel) {
                HStack(spacing: Spacing.xl) {
                    WriteRatioRing(value: ratio, tint: ratio >= 0.8 ? Theme.success.fill : Theme.accent)
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("\(summary.correct) von \(summary.total) richtig")
                            .font(Typography.headline)
                        HStack(spacing: Spacing.xs) {
                            TintedChip(text: "\(summary.correct) richtig", systemImage: "checkmark", palette: Theme.success)
                            TintedChip(text: "\(summary.incorrect) falsch", systemImage: "xmark", palette: Theme.failure)
                        }
                        if let counters {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Insgesamt")
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: Spacing.s)
                                    Text("\(counters.correct) von \(counters.total) geschafft")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                                WriteProgressLine(value: counters.progress, height: 8)
                            }
                            .padding(.top, Spacing.xxs)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Insgesamt")
                            .accessibilityValue("\(counters.correct) von \(counters.total) geschafft")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            let missed = rows.filter { $0.correct != true }
            let hit = rows.filter { $0.correct == true }
            if !missed.isEmpty {
                WriteTermList(title: "Noch üben", rows: missed, marker: .result)
            }
            if !hit.isEmpty {
                WriteTermList(title: "Richtig", rows: hit, marker: .result)
            }
        }
    }
}

/// The share of right answers of a round as a ring with the percentage in the middle.
struct WriteRatioRing: View {
    let value: Double
    let tint: Color
    var diameter: CGFloat = 104

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotRendering) private var isSnapshot
    @State private var shown: Double = 0

    var body: some View {
        let lineWidth: CGFloat = 10
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(WriteFlow.percentText(value))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("richtig")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Richtig in dieser Runde")
        .accessibilityValue(WriteFlow.percentText(value))
        .onAppear {
            if reduceMotion || isSnapshot {
                shown = value
            } else {
                withAnimation(Motion.gentle.delay(0.15)) { shown = value }
            }
        }
        .onChange(of: value) { _, new in shown = new }
    }
}

/// A plain (non-glass) list of cards: term and definition, with a ✓/✗ marker (round summary)
/// or a misses chip (results).
struct WriteTermList: View {
    enum Marker {
        /// A green check or red cross in front of each row (`row.correct`).
        case result
        /// "2× falsch" at the end of each row (`row.misses`).
        case misses
    }

    let title: String
    let rows: [WriteFlow.TermRow]
    let marker: Marker

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
                    .accessibilityLabel("\(rows.count) \(rows.count == 1 ? "Begriff" : "Begriffe")")
            }
            .accessibilityElement(children: .combine)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().padding(.leading, marker == .result ? 52 : Spacing.l)
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

    private func rowView(_ row: WriteFlow.TermRow) -> some View {
        HStack(spacing: Spacing.s) {
            if marker == .result {
                let correct = row.correct == true
                Image(systemName: correct ? "checkmark" : "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(correct ? Theme.success.text : Theme.failure.text)
                    .frame(width: 22, height: 22)
                    .background(correct ? Theme.success.soft : Theme.failure.soft, in: Circle())
                    .accessibilityLabel(correct ? "Richtig" : "Falsch")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(LearnText.spoken(row.term, lang: row.termLang))
                    .font(.body.weight(.semibold))
                    .cardTextLine(row.termLang)
                Text(LearnText.spoken(row.definition, lang: row.defLang))
                    .foregroundStyle(.secondary)
                    .cardTextLine(row.defLang)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if marker == .misses, let label = row.missesLabel {
                TintedChip(text: label, palette: Theme.failure, size: .small)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .accessibilityElement(children: .combine)
    }
}
