import SwiftUI
import WortschatzCore

/// How the overview orders its set cards (`SORTS` in dashboard.js).
enum OverviewSort: String, CaseIterable, Identifiable {
    case recent, name, newest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: "Zuletzt gelernt"
        case .name: "Name"
        case .newest: "Neueste"
        }
    }

    /// `sortItems` of dashboard.js ("recent" keeps the store order).
    func sorted(_ sets: [SetSummary]) -> [SetSummary] {
        let indexed = Array(sets.enumerated())
        switch self {
        case .recent:
            return sets
        case .name:
            let locale = Locale(identifier: "de_CH")
            return indexed.sorted { a, b in
                let order = a.element.set.title.compare(
                    b.element.set.title, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: locale)
                return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
            }.map(\.element)
        case .newest:
            return indexed.sorted { a, b in
                let (x, y) = (a.element.set.createdAt, b.element.set.createdAt)
                return x == y ? a.offset < b.offset : x > y
            }.map(\.element)
        }
    }
}

/// "Deine Lernsets": heading with count and sort control, then the cards.
struct OverviewSetGrid: View {
    let now: Date

    @Environment(AppModel.self) private var model
    @AppStorage("overview.sort") private var sort: OverviewSort = .recent

    private let columns = [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: Spacing.m, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text("Deine Lernsets")
                    .font(Typography.title)
                    .accessibilityAddTraits(.isHeader)
                Text("\(model.library.sets.count)")
                    .font(Typography.count)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel(Labels.plural(model.library.sets.count, "Lernset", "Lernsets"))
                Spacer()
                Picker("Sortieren nach", selection: $sort) {
                    ForEach(OverviewSort.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Sortieren nach")
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.m) {
                NewSetCard()
                ForEach(sort.sorted(model.library.sets)) { summary in
                    OverviewSetCard(summary: summary, now: now)
                }
            }
        }
    }
}

/// A set in the overview grid: language pair, title, count, mastery, status and a quick
/// "Lernen" / "Weiterlernen" (port of `setCard` in dashboard.js). Clicking the card opens the set.
struct OverviewSetCard: View {
    let summary: SetSummary
    let now: Date

    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Button {
                model.showSet(summary.id)
            } label: {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(alignment: .top, spacing: Spacing.s) {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            LanguageCapsule(termLang: summary.set.termLang, defLang: summary.set.defLang, style: .short)
                            Text(summary.set.title)
                                .font(Typography.headline)
                                .lineLimit(2, reservesSpace: true)
                                .multilineTextAlignment(.leading)
                            Text(StudyCopy.terms(summary.stats.total))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        MasteryGauge(counts: summary.counts, size: .medium)
                    }
                    StatusBar(counts: summary.counts, height: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary.set.title)
            .accessibilityValue("\(StudyCopy.terms(summary.stats.total)), \(summary.counts.accessibilityDescription)")
            .accessibilityHint("Öffnet das Lernset")

            HStack(spacing: Spacing.xs) {
                CardStatusLabel(summary: summary, now: now)
                Spacer(minLength: Spacing.xs)
                quickAction
            }
        }
        .padding(Spacing.l)
        // Content layer (spec §4.2): a grouped surface, not glass; its buttons are the glass.
        .contentSurface(cornerRadius: Radii.tile, isHighlighted: isHovered)
        .onHover { isHovered = $0 }
        .motionAnimation(Motion.snappy, value: isHovered)
        .contextMenu {
            SetActionsMenu(summary: summary)
        }
    }

    @ViewBuilder
    private var quickAction: some View {
        if summary.learn != nil {
            PrimaryActionButton("Weiterlernen", systemImage: "play.fill", key: nil, controlSize: .regular) {
                model.continueLearn(setID: summary.id)
            }
            .accessibilityHint("\(summary.set.title) weiterlernen")
        } else {
            SecondaryButton("Lernen", systemImage: "sparkles", controlSize: .regular) {
                model.continueLearn(setID: summary.id)
            }
            .disabled(summary.isEmpty)
            .accessibilityHint("\(summary.set.title) lernen")
        }
    }
}

/// The status line of a set card (`cardStatus` in dashboard.js).
private struct CardStatusLabel: View {
    let summary: SetSummary
    let now: Date

    @Environment(AppModel.self) private var model

    var body: some View {
        content
            .font(.callout)
            .lineLimit(1)
    }

    @ViewBuilder
    private var content: some View {
        if let learn = summary.learn {
            running(learn.shortDetail, full: "Lernen: \(learn.detail)")
        } else if let write = summary.write {
            running("Schreiben · \(write.shortDetail)", full: "Schreiben: \(write.roundText)")
        } else if summary.isAllMastered {
            Label("Alles gemeistert", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.mastered.text)
        } else if let last = summary.set.lastStudiedAt {
            let when = TimeUtil.relativeTime(last, now: now.timeIntervalSince1970 * 1000, timeZone: model.store.timeZone)
            Label(StudyCopy.capitalized(when), systemImage: "clock")
                .foregroundStyle(.secondary)
                .help("Zuletzt gelernt \(when)")
                .accessibilityLabel("Zuletzt gelernt \(when)")
        } else {
            Label("Noch nicht gelernt", systemImage: "sparkles")
                .foregroundStyle(.secondary)
        }
    }

    private func running(_ text: String, full: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 7, height: 7)
            Text(text)
                .foregroundStyle(Theme.accentText)
                .fontWeight(.medium)
        }
        .help(full)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(full)
    }
}

/// The dashed "Neues Lernset" card at the start of the grid.
private struct NewSetCard: View {
    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        Button {
            model.openEditor(.new)
        } label: {
            VStack(spacing: Spacing.s) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 44, height: 44)
                    .background(Theme.accentSoft, in: Circle())
                VStack(spacing: 2) {
                    Text("Neues Lernset")
                        .font(Typography.headline)
                    Text("Liste einfügen oder Foto, PDF und Textdatei importieren")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 150)
            .background {
                RoundedRectangle(cornerRadius: Radii.tile, style: .continuous)
                    .fill(Theme.accentSoft.opacity(isHovered ? 0.9 : 0.35))
                RoundedRectangle(cornerRadius: Radii.tile, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
            .contentShape(RoundedRectangle(cornerRadius: Radii.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .motionAnimation(Motion.snappy, value: isHovered)
        .help("Neues Lernset (⌘N)")
    }
}
