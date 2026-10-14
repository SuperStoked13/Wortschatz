import SwiftUI
import WortschatzCore

/// The results of a finished Write session (spec §4.4): trophy with a confetti burst (a soft
/// glow under Reduce Motion), "Geschafft!", the statistics as glass tiles, the set's mastery
/// and the cards missed most often. "Falsche nochmal üben ↩" (or "Fertig ↩"), "Nochmal von
/// vorne ⇧⌘R" and "Fertig" are in the action bar.
struct WriteResultsView: View {
    let results: WriteFlow.Results
    let hardest: [WriteFlow.TermRow]
    let setCounts: StatusCounts

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    private var stats: WriteSession.FinalStats { results.stats }

    var body: some View {
        VStack(spacing: Spacing.xl) {
            VStack(spacing: Spacing.s) {
                ZStack {
                    Circle()
                        .fill(Theme.accent.gradient)
                        .frame(width: 92, height: 92)
                        .shadow(color: Theme.accent.opacity(0.35), radius: 16, y: 6)
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, options: .nonRepeating, value: bounce)
                }
                .padding(.bottom, Spacing.xs)
                .accessibilityHidden(true)

                Text("Geschafft!")
                    .font(Typography.display)
                    .accessibilityAddTraits(.isHeader)
                Text(WriteFlow.resultsSubtitle(results))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            Grid(horizontalSpacing: Spacing.s, verticalSpacing: Spacing.s) {
                GridRow {
                    // Every tile has a caption, so the row's glass tiles are equally tall.
                    StatTile(
                        results.cardCount == 1 ? "Begriff" : "Begriffe", value: "\(results.cardCount)",
                        systemImage: "square.stack.3d.up.fill",
                        caption: results.bothDirections ? "in beide Richtungen" : "geschrieben")
                    StatTile(
                        "Treffer", value: WriteFlow.percentText(stats.accuracy), systemImage: "target",
                        tint: Theme.success.fill, caption: "beim ersten Versuch")
                    StatTile(
                        stats.rounds == 1 ? "Runde" : "Runden", value: "\(stats.rounds)",
                        systemImage: "arrow.trianglehead.2.clockwise", tint: Theme.info.fill,
                        caption: "bis alles sass")
                    let time = WriteFlow.compactDuration(stats.elapsedMs)
                    StatTile(
                        time.label, value: time.value, systemImage: "clock.fill", tint: Theme.flame,
                        caption: "aktive Lernzeit"
                    )
                    .accessibilityLabel("Zeit")
                    .accessibilityValue(TimeUtil.formatDuration(stats.elapsedMs))
                }
            }

            GlassCard(padding: Spacing.xl, cornerRadius: Radii.panel) {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Dein Lernset")
                            .font(Typography.headline)
                        Spacer()
                        Text("\(setCounts.percentText) gemeistert")
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(
                                setCounts.mastered > 0 ? AnyShapeStyle(Theme.mastered.text) : AnyShapeStyle(.secondary))
                    }
                    StatusBar(counts: setCounts, height: 10)
                    HStack(spacing: Spacing.l) {
                        ForEach([CardStatus.mastered, .learning, .new], id: \.self) { status in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(status.palette.fill)
                                    .frame(width: 8, height: 8)
                                Text(status.label)
                                    .foregroundStyle(.secondary)
                                Text(setCounts.count(status), format: .number)
                                    .font(Typography.count)
                            }
                            .font(.callout)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Dein Lernset")
                .accessibilityValue("\(setCounts.percent) Prozent gemeistert. \(setCounts.accessibilityDescription)")
            }

            if hardest.isEmpty {
                Label(WriteFlow.flawlessText, systemImage: "sparkles")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Theme.accentText)
                    .padding(.top, Spacing.xs)
            } else {
                WriteTermList(title: "Am häufigsten falsch", rows: hardest, marker: .misses)
            }
        }
        .celebration(origin: UnitPoint(x: 0.5, y: 0.1))
        .onAppear {
            if !reduceMotion { bounce += 1 }
        }
    }
}
