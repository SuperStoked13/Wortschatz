import SwiftUI
import WortschatzCore

/// The sidebar (spec §4.1): "Übersicht", then the section "Lernsets" with a row per set
/// (mastery gauge, title, "52 Begriffe"), and the daily streak (Lernserie) at its foot.
/// Searchable by title, description and terms; Return in the search field opens the first
/// match. ↑↓ move the selection; Return then triggers the detail's primary action (Lernen).
struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model
    /// The list starts with keyboard focus, so ↑↓ pick sets right after launch.
    @FocusState private var isListFocused: Bool

    var body: some View {
        @Bindable var model = model
        let query = StudyCopy.fold(model.sidebarSearch)
        let results = LibrarySearch.filter(model.library.sets, query: query)

        List(selection: selection) {
            Label("Übersicht", systemImage: "square.grid.2x2")
                .tag(SidebarItem.overview)

            Section {
                ForEach(results) { result in
                    SidebarSetRow(summary: result.summary, match: result.match)
                        .tag(SidebarItem.set(result.summary.id))
                        .contextMenu {
                            SetActionsMenu(summary: result.summary)
                        }
                }
            } header: {
                Text(query.isEmpty ? "Lernsets" : "Treffer")
            }
        }
        .focused($isListFocused)
        .defaultFocus($isListFocused, true)
        .overlay {
            if !query.isEmpty, results.isEmpty {
                ContentUnavailableView.search(text: model.sidebarSearch.trimmingCharacters(in: .whitespaces))
            } else if model.library.isEmpty {
                Text("Noch keine Lernsets")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 90)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.library.isEmpty {
                SidebarStreakFooter(streak: model.library.stats.streak)
            }
        }
        .searchable(text: $model.sidebarSearch, placement: .sidebar, prompt: "Lernsets durchsuchen")
        .onSubmit(of: .search) {
            if let first = results.first { model.showSet(first.summary.id) }
        }
        .toolbar { NewSetToolbarButton() }
    }

    /// The List's selection, routed through the model.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { model.sidebarSelection },
            set: { model.select($0) })
    }
}

/// "+" (Neues Lernset) in the sidebar's toolbar. Hidden while studying: the collapsed sidebar's
/// items move into the study toolbar. It follows the screen on show (also while one dissolves),
/// so the toolbar changes in one go with the study screen's own items. Its own content, so the
/// route changes of a transition re-evaluate only the button, not the whole list.
private struct NewSetToolbarButton: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        if !model.routeOnScreen.isStudy {
            ToolbarItem {
                Button {
                    model.openEditor(.new)
                } label: {
                    Label("Neues Lernset", systemImage: "plus")
                }
                .help("Neues Lernset (⌘N)")
            }
        }
    }
}

/// The daily streak at the foot of the sidebar, always in view: "🔥 6 Tage Lernserie" with
/// "Heute geschafft" / "Heute noch lernen". No bar behind it, only a soft flame tint while a
/// streak runs.
private struct SidebarStreakFooter: View {
    let streak: StudyStreak

    var body: some View {
        let isRunning = streak.current > 0
        HStack(spacing: Spacing.s) {
            Image(systemName: "flame.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(streak.flameTint)
                .symbolEffect(.bounce, options: .nonRepeating, value: streak.current)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 0) {
                // One line each, the caption under the title.
                Text(title)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(.numericText(value: Double(streak.current)))
                Text(streak.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.s + 2)
        .padding(.vertical, Spacing.xs + 2)
        .background {
            if isRunning {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.flame.opacity(streak.today > 0 ? 0.12 : 0.07))
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.bottom, Spacing.s)
        .animation(Motion.snappy, value: streak.current)
        .help(streak.longestHelp)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        streak.current > 0 ? "\(Labels.plural(streak.current, "Tag", "Tage")) Lernserie" : "Noch keine Lernserie"
    }
}

/// A set in the sidebar.
private struct SidebarSetRow: View {
    let summary: SetSummary
    let match: LibrarySearch.Match?

    var body: some View {
        HStack(spacing: Spacing.s) {
            MasteryGauge(counts: summary.counts, size: .small)
                .padding(.leading, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.set.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if summary.learn != nil || summary.write != nil {
                Image(systemName: "play.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .help(runningHelp)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.set.title)
        .accessibilityValue(accessibilityValue)
    }

    private var subtitle: String {
        if let card = match?.firstCard {
            let more = match.map { $0.cardCount - 1 } ?? 0
            let text = "\(card.term) – \(card.definition)"
            return more > 0 ? "\(text) (+\(more))" : text
        }
        return StudyCopy.terms(summary.stats.total)
    }

    private var runningHelp: String {
        if let learn = summary.learn { return "Lernen läuft: \(learn.detail)" }
        if let write = summary.write { return "Schreiben läuft: \(write.detail)" }
        return ""
    }

    private var accessibilityValue: String {
        var parts = [StudyCopy.terms(summary.stats.total), "\(summary.stats.percent) Prozent gemeistert"]
        if summary.learn != nil || summary.write != nil { parts.append(runningHelp) }
        if let card = match?.firstCard { parts.append("Treffer: \(card.term) – \(card.definition)") }
        return parts.joined(separator: ", ")
    }
}

/// Search over sets (port of `matchItem` in dashboard.js): titles, descriptions and every
/// term and definition, case-, accent- and sharp-s-insensitive.
enum LibrarySearch {
    struct Match {
        var inTitle: Bool
        var inDescription: Bool
        /// The first matching card (when the title does not match).
        var firstCard: Card?
        var cardCount: Int
    }

    struct Result: Identifiable {
        var summary: SetSummary
        var match: Match?
        var id: String { summary.id }
    }

    /// The sets matching `query` (already folded); all sets for an empty query.
    static func filter(_ sets: [SetSummary], query: String) -> [Result] {
        guard !query.isEmpty else { return sets.map { Result(summary: $0, match: nil) } }
        return sets.compactMap { summary in
            match(summary.set, query: query).map { Result(summary: summary, match: $0) }
        }
    }

    static func match(_ set: VocabSet, query: String) -> Match? {
        let inTitle = StudyCopy.fold(set.title).contains(query)
        let inDescription = StudyCopy.fold(set.description).contains(query)
        var first: Card?
        var count = 0
        for card in set.cards where "\(StudyCopy.fold(card.term))\n\(StudyCopy.fold(card.definition))".contains(query) {
            if first == nil { first = card }
            count += 1
        }
        guard inTitle || inDescription || count > 0 else { return nil }
        // A title hit needs no card hint.
        return Match(inTitle: inTitle, inDescription: inDescription, firstCard: inTitle ? nil : first, cardCount: count)
    }
}
