import SwiftUI
import WortschatzCore

/// The overview without sets (`emptyView` in dashboard.js): "Erstes Lernset erstellen ↩" and
/// "Backup laden…" (the file chooser for a backup, like Windows), plus the three steps of the app.
struct OverviewEmptyState: View {
    let date: Date

    @Environment(AppModel.self) private var model

    private static let steps: [(symbol: String, title: String, text: String)] = [
        ("doc.on.clipboard", String(localized: "Liste einfügen"),
         String(localized: "Wortschatz erkennt Begriffe und Übersetzungen automatisch – auch aus Fotos und PDFs.")),
        ("sparkles", String(localized: "Lernen"),
         String(localized: "Neue Begriffe kommen zuerst als Multiple Choice, danach schreibst du sie selbst – bis alles sitzt.")),
        ("trophy", String(localized: "Fortschritt sehen"),
         String(localized: "Zweimal in Folge richtig – und ein Begriff gilt als gemeistert.")),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xxl) {
                OverviewHeader(
                    date: date, lead: String(localized: "Schön, dass du da bist. Leg dein erstes Lernset an und starte direkt.")
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                EmptyStateView(
                    systemImage: "rectangle.stack.badge.plus",
                    title: String(localized: "Noch keine Lernsets"),
                    message: String(
                        localized:
                            "Erstelle dein erstes Lernset aus einer Vokabelliste – in wenigen Sekunden kannst du mit Lernen loslegen."
                    )
                ) {
                    PrimaryActionButton("Erstes Lernset erstellen", systemImage: "plus") {
                        model.openEditor(.new)
                    }
                    SecondaryButton("Backup laden…", systemImage: "square.and.arrow.down") {
                        model.importBackup()
                    }
                }

                HStack(alignment: .top, spacing: Spacing.m) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        StepTile(number: index + 1, symbol: step.symbol, title: step.title, text: step.text)
                    }
                }
                // Equal tile heights (inside the scroll view, so this cannot inflate the window).
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 860)
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.huge)
            .frame(maxWidth: LayoutMetrics.contentWidth)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One of the three "how it works" steps (content, not glass).
private struct StepTile: View {
    let number: Int
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 36, height: 36)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Radii.small, style: .continuous))
            Text("\(number). \(title)")
                .font(Typography.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: Radii.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radii.tile, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
