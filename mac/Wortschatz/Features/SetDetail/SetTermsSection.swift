import SwiftUI
import WortschatzCore

/// The term filter of the set detail (`FILTERS` in set.js, plus "Schwierig": answered wrong at
/// least `SetSummary.difficultMistakes` times).
enum TermFilter: String, CaseIterable, Identifiable, Sendable {
    case all, new, learning, mastered, starred, difficult

    var id: String { rawValue }

    init(_ status: CardStatus) {
        switch status {
        case .new: self = .new
        case .learning: self = .learning
        case .mastered: self = .mastered
        }
    }

    var label: String {
        switch self {
        case .all: "Alle"
        case .new: CardStatus.new.label
        case .learning: CardStatus.learning.label
        case .mastered: CardStatus.mastered.label
        case .starred: "Markiert"
        case .difficult: "Schwierig"
        }
    }

    func count(in summary: SetSummary) -> Int {
        switch self {
        case .all: summary.stats.total
        case .new: summary.stats.fresh
        case .learning: summary.stats.learning
        case .mastered: summary.stats.mastered
        case .starred: summary.starred
        case .difficult: summary.difficultCardIDs.count
        }
    }

    func matches(_ card: Card, status: CardStatus, mistakes: Int) -> Bool {
        switch self {
        case .all: true
        case .starred: card.starred
        case .new: status == .new
        case .learning: status == .learning
        case .mastered: status == .mastered
        case .difficult: mistakes >= SetSummary.difficultMistakes
        }
    }

    /// The empty state of a filter without cards (`FILTER_EMPTY` in set.js).
    var emptyState: (symbol: String, title: String, text: String) {
        switch self {
        case .all, .new:
            ("sparkles", "Keine neuen Begriffe", "Du hast jeden Begriff schon mindestens einmal geübt.")
        case .learning:
            ("book", "Gerade nichts am Lernen", "Hier erscheinen Begriffe, die du schon geübt, aber noch nicht gemeistert hast.")
        case .mastered:
            ("trophy", "Noch nichts gemeistert", "Ein Begriff gilt als gemeistert, wenn du ihn zweimal hintereinander richtig beantwortest.")
        case .starred:
            ("star", "Keine markierten Begriffe", "Klicke bei einem Begriff auf den Stern, um ihn später gezielt zu üben.")
        case .difficult:
            ("flame", "Keine schwierigen Begriffe", "Hier erscheinen Begriffe, die du mindestens \(SetSummary.difficultMistakes)× falsch beantwortet hast.")
        }
    }
}

/// A row of the terms table.
struct SetTermRow: Identifiable, Hashable {
    let id: String
    let term: String
    let definition: String
    let starred: Bool
    let status: CardStatus
    /// Card order in the set (the table's natural order).
    let position: Int
    /// How often the card was answered wrong (in total).
    let mistakes: Int
    /// "3× richtig · 1× falsch".
    let progressTitle: String

    /// Sorts starred cards first.
    var starRank: Int { starred ? 0 : 1 }

    /// Sorts Neu < Am Lernen < Gemeistert.
    var statusRank: Int {
        switch status {
        case .new: 0
        case .learning: 1
        case .mastered: 2
        }
    }
}

/// "Begriffe" heading with filter and search, and the terms `Table`:
/// Begriff | Definition | Status | ★ | 🔊.
struct SetTermsSection: View {
    let summary: SetSummary
    @Binding var filter: TermFilter

    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selection = Set<SetTermRow.ID>()
    @State private var sortOrder: [KeyPathComparator<SetTermRow>] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, Spacing.s)
            let rows = self.rows
            table(rows)
                .overlay {
                    if rows.isEmpty { emptyOverlay }
                }
                // The table's edges line up with the page's content above (title, buttons,
                // progress panel, the "Begriffe" row); the inset style indents the cells within.
                .padding(.horizontal, Spacing.xxl)
        }
    }

    // MARK: Filter and search

    /// Heading, filter and search; the filter gets shorter (then a menu) in narrow windows.
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(searchWidth: 200) { segmentedFilter(withCounts: true) }
            toolbarRow(searchWidth: 170) { segmentedFilter(withCounts: false) }
            toolbarRow(searchWidth: 160) { menuFilter }
        }
    }

    private func toolbarRow(searchWidth: CGFloat, @ViewBuilder filter: () -> some View) -> some View {
        HStack(spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text("Begriffe")
                    .font(Typography.title)
                    .accessibilityAddTraits(.isHeader)
                Text("\(summary.stats.total)")
                    .font(Typography.count)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .fixedSize()
            Spacer(minLength: Spacing.s)
            filter()
            searchField
                .frame(width: searchWidth)
        }
    }

    private func segmentedFilter(withCounts: Bool) -> some View {
        Picker("Begriffe filtern", selection: $filter) {
            ForEach(TermFilter.allCases) { option in
                Text(withCounts ? "\(option.label) \(option.count(in: summary))" : option.label)
                    .accessibilityLabel("\(option.label), \(StudyCopy.terms(option.count(in: summary)))")
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var menuFilter: some View {
        Picker("Anzeigen", selection: $filter) {
            ForEach(TermFilter.allCases) { option in
                Text("\(option.label) (\(option.count(in: summary)))").tag(option)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Begriffe suchen", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { search = "" }
                .accessibilityLabel("Begriffe durchsuchen")
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Suche löschen")
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 5)
        .background(.background.opacity(0.7), in: Capsule())
        .overlay {
            Capsule().strokeBorder(searchFocused ? Theme.accent.opacity(0.8) : Theme.hairline, lineWidth: searchFocused ? 2 : 1)
        }
    }

    // MARK: Table

    private var rows: [SetTermRow] {
        Self.rows(summary, filter: filter, search: search, sortOrder: sortOrder)
    }

    /// The table's rows: the cards that pass `filter` and `search`, in card order (Schwierig:
    /// most mistakes first) unless a column header sorts them.
    static func rows(
        _ summary: SetSummary, filter: TermFilter, search: String, sortOrder: [KeyPathComparator<SetTermRow>]
    ) -> [SetTermRow] {
        let query = StudyCopy.fold(search)
        var rows: [SetTermRow] = []
        for (index, card) in summary.set.cards.enumerated() {
            let status = summary.status(of: card)
            let mistakes = summary.mistakes(of: card)
            guard filter.matches(card, status: status, mistakes: mistakes) else { continue }
            if !query.isEmpty,
               !"\(StudyCopy.fold(card.term))\n\(StudyCopy.fold(card.definition))".contains(query) {
                continue
            }
            rows.append(SetTermRow(
                id: card.id, term: card.term, definition: card.definition, starred: card.starred, status: status,
                position: index, mistakes: mistakes,
                progressTitle: SetDetailCopy.progressTitle(summary.progress[card.id])))
        }
        if !sortOrder.isEmpty {
            rows.sort(using: sortOrder)
        } else if filter == .difficult {
            rows.sort { ($0.mistakes, -$0.position) > ($1.mistakes, -$1.position) }
        }
        return rows
    }

    private func table(_ rows: [SetTermRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Begriff", value: \.term, comparator: .localizedStandard) { row in
                CellText(text: row.term, lang: summary.set.termLang)
            }
            .width(min: 120, ideal: 170)

            TableColumn("Definition", value: \.definition, comparator: .localizedStandard) { row in
                CellText(text: row.definition, lang: summary.set.defLang)
            }
            .width(min: 120, ideal: 170)

            TableColumn("Status", value: \.statusRank) { row in
                StatusChip(status: row.status, size: .small)
                    .help(row.progressTitle)
                    .accessibilityValue(row.progressTitle)
            }
            .width(min: 100, ideal: 104, max: 130)

            TableColumn(Text("\(Image(systemName: "star"))"), value: \.starRank) { row in
                StarToggle(isStarred: row.starred) {
                    model.toggleStar(setID: summary.id, cardID: row.id)
                }
            }
            .width(40)

            TableColumn(Text("\(Image(systemName: "speaker.wave.2"))")) { row in
                Button {
                    model.speak(row.term, lang: summary.set.termLang)
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(row.term.isEmpty)
                .help("Vorlesen")
                .accessibilityLabel("\(row.term) vorlesen")
            }
            .width(40)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: SetTermRow.ID.self) { ids in
            rowMenu(ids)
        } primaryAction: { _ in
            model.openEditor(.edit(setID: summary.id))
        }
        .accessibilityLabel("Begriffe")
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<SetTermRow.ID>) -> some View {
        let cards = summary.set.cards.filter { ids.contains($0.id) }
        if cards.count == 1, let card = cards.first {
            Button(card.starred ? "Markierung entfernen" : "Markieren", systemImage: card.starred ? "star.slash" : "star") {
                model.toggleStar(setID: summary.id, cardID: card.id)
            }
            Button("Begriff vorlesen", systemImage: "speaker.wave.2") {
                model.speak(card.term, lang: summary.set.termLang)
            }
            .disabled(card.term.isEmpty)
            Button("Definition vorlesen", systemImage: "speaker.wave.2") {
                model.speak(card.definition, lang: summary.set.defLang)
            }
            .disabled(card.definition.isEmpty)
            Divider()
        } else if cards.count > 1 {
            let allStarred = cards.allSatisfy(\.starred)
            Button(allStarred ? "Markierungen entfernen" : "Alle markieren", systemImage: allStarred ? "star.slash" : "star") {
                for card in cards where card.starred == allStarred {
                    model.toggleStar(setID: summary.id, cardID: card.id)
                }
            }
            Divider()
        }
        Button("Bearbeiten", systemImage: "pencil") {
            model.openEditor(.edit(setID: summary.id))
        }
    }

    // MARK: Empty results

    @ViewBuilder
    private var emptyOverlay: some View {
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            ContentUnavailableView {
                Label("Keine Treffer für «\(query)»", systemImage: "magnifyingglass")
            } description: {
                Text(filter == .all ? "Gesucht wird in Begriffen und Definitionen." : "Gesucht wird in den Begriffen dieses Filters.")
            } actions: {
                Button("Suche zurücksetzen") { search = "" }
            }
        } else if filter != .all {
            let info = filter.emptyState
            ContentUnavailableView {
                Label(info.title, systemImage: info.symbol)
            } description: {
                Text(info.text)
            } actions: {
                Button("Alle Begriffe anzeigen") { filter = .all }
            }
        }
    }
}

/// A term or definition in the table ("–" when empty), tagged with its language (Chinese glyphs,
/// VoiceOver's voice); Arabic starts at the column's right edge.
private struct CellText: View {
    let text: String
    let lang: Lang

    var body: some View {
        if text.isEmpty {
            Text("–")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("leer")
        } else {
            Text(LearnText.spoken(text, lang: lang))
                .lineLimit(2)
                .cardTextLine(lang)
        }
    }
}

/// The ★ toggle of a row.
private struct StarToggle: View {
    let isStarred: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isStarred ? "star.fill" : "star")
                .foregroundStyle(isStarred ? AnyShapeStyle(Theme.star) : AnyShapeStyle(.tertiary))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(isStarred ? "Markierung entfernen" : "Markieren")
        .accessibilityLabel(isStarred ? "Markierung entfernen" : "Markieren")
        .accessibilityValue(isStarred ? "markiert" : "nicht markiert")
    }
}
