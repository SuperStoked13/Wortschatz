import SwiftUI
import WortschatzCore

/// "Übersicht" (spec §4.4, port of src/screens/dashboard.js): greeting, glass stat tiles,
/// the "Weiterlernen" hero (Return), and the grid of sets with a "Neues Lernset" card. Without
/// sets it shows the empty state ("Erstes Lernset erstellen ↩").
struct OverviewScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Greeting, date and relative times stay current while the window stays open.
        TimelineView(.everyMinute) { context in
            if model.library.isEmpty {
                OverviewEmptyState(date: context.date)
            } else {
                content(date: context.date)
            }
        }
        .appBackdrop()
        .navigationTitle("Übersicht")
    }

    private func content(date: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                OverviewHeader(date: date, lead: leadText)
                OverviewStatsRow(stats: model.library.stats)
                OverviewHero(now: date)
                OverviewSetGrid(now: date)
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.huge)
            .frame(maxWidth: LayoutMetrics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// `leadText` of dashboard.js.
    private var leadText: String {
        let streak = model.library.stats.streak
        if streak.today > 0 {
            return String(localized: "Heute schon \(Labels.plural(streak.today, "Antwort", "Antworten")) – weiter so!")
        }
        if streak.current > 0 {
            return String(localized: "Lerne heute, damit deine Serie von \(Labels.plural(streak.current, "Tag", "Tagen")) weiterläuft.")
        }
        if model.library.resume != nil { return String(localized: "Mach dort weiter, wo du aufgehört hast.") }
        return String(localized: "Bereit für ein paar Wörter? Wähle ein Lernset und leg los.")
    }
}

// MARK: - Header

/// "MONTAG, 12. OKTOBER" / "Guten Morgen" / lead line.
struct OverviewHeader: View {
    let date: Date
    let lead: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(Self.dayLabel(date))
                .eyebrowStyle()
            Text(Self.greeting(date))
                .font(Typography.display)
                .accessibilityAddTraits(.isHeader)
            Text(lead)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Spacing.xs)
    }

    /// `greetingFor` of dashboard.js: Morgen 5–11 h, Tag 11–18 h, else Abend.
    static func greeting(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<11: return String(localized: "Guten Morgen")
        case 11..<18: return String(localized: "Guten Tag")
        default: return String(localized: "Guten Abend")
        }
    }

    /// "Montag, 12. Oktober".
    static func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.formattingLocale))
    }
}

// MARK: - Statistics

/// Lernserie, Heute beantwortet, Begriffe gemeistert (`statsStrip` of dashboard.js).
struct OverviewStatsRow: View {
    let stats: OverviewStats

    var body: some View {
        let streak = stats.streak
        GlassEffectContainer(spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                StatTile(
                    String(localized: "Lernserie"), value: "\(streak.current)",
                    unit: streak.current == 1
                        ? String(localized: "Tag", comment: "Unit after the streak count: 1 day")
                        : String(localized: "Tage", comment: "Unit after the streak count: several days"),
                    systemImage: "flame.fill", tint: streak.flameTint, caption: streak.caption
                )
                .help(streak.longestHelp)
                StatTile(
                    String(localized: "Heute beantwortet"), value: "\(streak.today)", systemImage: "checkmark.bubble.fill",
                    tint: streak.today > 0 ? Theme.accent : Theme.new.fill,
                    caption: String(localized: "Letzte 7 Tage: \(stats.week)")
                )
                StatTile(
                    String(localized: "Begriffe gemeistert"), value: "\(stats.mastered)", systemImage: "trophy.fill",
                    tint: stats.mastered > 0 ? Theme.mastered.fill : Theme.new.fill,
                    caption: String(localized: "von \(Labels.plural(stats.total, "Begriff", "Begriffen"))")
                )
                .help("Ein Begriff gilt als gemeistert, wenn du ihn zweimal in Folge richtig beantwortest.")
            }
        }
    }

}

/// How the daily streak (Lernserie) reads on the overview's tile and at the sidebar's foot.
extension StudyStreak {
    /// "Heute geschafft", "Heute noch lernen", "Rekord: 9 Tage", …
    var caption: String {
        if today > 0 { return String(localized: "Heute geschafft") }
        if current > 0 { return String(localized: "Heute noch lernen") }
        if longest > 0 { return String(localized: "Rekord: \(Labels.plural(longest, "Tag", "Tage"))") }
        return String(localized: "Lerne heute, um zu starten")
    }

    /// "Längste Serie: 9 Tage" (tooltip), empty before the first streak.
    var longestHelp: String {
        longest > 0 ? String(localized: "Längste Serie: \(Labels.plural(longest, "Tag", "Tage"))") : ""
    }

    /// The flame's colour: lit while a streak runs.
    var flameTint: Color {
        current > 0 ? Theme.flame : Theme.new.fill
    }
}
