import SwiftUI
import WortschatzCore

/// Set detail (spec §4.4, port of src/screens/set.js): header with title, description,
/// language pair, facts and the mastery gauge with legend; the study actions (Lernen ↩ /
/// Weiterlernen ↩, Schreiben, Karteikarten, Prüfung, Nur markierte, Nur schwierige, Bearbeiten,
/// "…"); and the terms table with filter and search.
struct SetDetailScreen: View {
    let setID: String

    @Environment(AppModel.self) private var model
    @State private var filter: TermFilter = .all
    @State private var layout = SetDetailLayout(size: CGSize(width: 1000, height: 800))

    var body: some View {
        Group {
            if let summary = model.library.summary(for: setID) {
                content(summary)
                    .navigationTitle(summary.set.title)
                    // The content shows the title large; the window keeps it for the Window menu.
                    .toolbar(removing: .title)
            } else {
                CenteredScrollView {
                    EmptyStateView(
                        systemImage: "questionmark.folder",
                        title: "Lernset nicht gefunden",
                        message: "Dieses Lernset gibt es nicht mehr – vielleicht wurde es gelöscht."
                    ) {
                        PrimaryActionButton("Zur Übersicht", systemImage: "chevron.left") { model.showOverview() }
                    }
                }
                .navigationTitle("Lernset")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: SetDetailLayout.self) { proxy in
            SetDetailLayout(size: proxy.size)
        } action: { newValue in
            layout = newValue
        }
        .appBackdrop()
        .onAppear { filter = model.termFilter(for: setID) }
        .onChange(of: filter) { _, newValue in model.rememberTermFilter(newValue, for: setID) }
    }

    private func content(_ summary: SetSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: layout.isShort ? Spacing.s : Spacing.l) {
                SetDetailHeader(summary: summary, layout: layout, filter: $filter)
                if !summary.isEmpty {
                    SetStudyActions(summary: summary, layout: layout)
                }
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, layout.isShort ? Spacing.s : Spacing.l)
            .padding(.bottom, Spacing.l)

            if summary.isEmpty {
                CenteredScrollView {
                    EmptyStateView(
                        systemImage: "rectangle.stack.badge.plus",
                        title: "Noch keine Begriffe",
                        message: "Tippe Begriffe ein oder importiere eine Vokabelliste."
                    ) {
                        PrimaryActionButton("Begriffe hinzufügen", systemImage: "plus") {
                            model.openEditor(.edit(setID: summary.id))
                        }
                    }
                }
            } else {
                SetTermsSection(summary: summary, filter: $filter)
            }
        }
    }
}

/// How much room the set detail has: narrow windows get the compact mastery panel, short
/// windows also drop the explanations, so the terms table keeps enough rows.
nonisolated struct SetDetailLayout: Equatable, Sendable {
    var isNarrow: Bool
    var isShort: Bool

    init(size: CGSize) {
        isNarrow = size.width < 880
        isShort = size.height < 700
    }

    var isCompact: Bool { isNarrow || isShort }
}

// MARK: - Header

/// Title block and the mastery panel.
private struct SetDetailHeader: View {
    let summary: SetSummary
    let layout: SetDetailLayout
    @Binding var filter: TermFilter

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: layout.isNarrow ? Spacing.l : Spacing.xxl) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                LanguageCapsule(termLang: summary.set.termLang, defLang: summary.set.defLang)
                Text(summary.set.title)
                    .font(Typography.display)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if !summary.set.description.isEmpty {
                    Text(summary.set.description)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(layout.isShort ? 1 : 3)
                        .textSelection(.enabled)
                }
                TimelineView(.everyMinute) { context in
                    Text(SetDetailCopy.facts(
                        summary.set, now: context.date.timeIntervalSince1970 * 1000, timeZone: model.store.timeZone))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !summary.isEmpty {
                MasteryPanel(summary: summary, isCompact: layout.isCompact, filter: $filter)
            }
        }
    }
}

/// Gauge, clickable legend (shows that status in the table) and caption; compact: a smaller
/// gauge and no caption.
private struct MasteryPanel: View {
    let summary: SetSummary
    let isCompact: Bool
    @Binding var filter: TermFilter

    private static let legendWidth: CGFloat = 176

    var body: some View {
        ContentPanel(padding: isCompact ? Spacing.m : Spacing.l, cornerRadius: Radii.tile) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: isCompact ? Spacing.m : Spacing.l) {
                    MasteryGauge(counts: summary.counts, size: isCompact ? .medium : .large)
                        .scaleEffect(isCompact ? 1.3 : 1)
                        .frame(width: isCompact ? 66 : nil, height: isCompact ? 66 : nil)
                    VStack(alignment: .leading, spacing: isCompact ? 0 : 2) {
                        ForEach([CardStatus.mastered, .learning, .new], id: \.self) { status in
                            legendRow(status)
                        }
                    }
                }
                if !isCompact {
                    Text(SetDetailCopy.progressCaption(summary.stats))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: MasteryGauge.Size.large.diameter + Spacing.l + Self.legendWidth, alignment: .leading)
                }
            }
        }
        .help(SetDetailCopy.progressCaption(summary.stats))
    }

    private func legendRow(_ status: CardStatus) -> some View {
        let count = summary.counts.count(status)
        let target = TermFilter(status)
        return Button {
            filter = target
        } label: {
            HStack(spacing: Spacing.xs) {
                Circle()
                    .fill(status.palette.fill)
                    .frame(width: 9, height: 9)
                Text(status.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: Spacing.xs)
                Text(count, format: .number)
                    .font(Typography.count)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, isCompact ? 3 : 5)
            .background {
                if filter == target {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(status.palette.soft)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: Self.legendWidth)
        .accessibilityLabel("\(status.label): \(StudyCopy.terms(count)) anzeigen")
    }
}

// MARK: - Study actions

/// Lernen ↩ (or Weiterlernen ↩), Schreiben, Karteikarten, Prüfung, the subset shortcuts,
/// Bearbeiten, Optionen and "…", then the running sessions, what Lernen asks and the options
/// this set has of its own.
private struct SetStudyActions: View {
    let summary: SetSummary
    let layout: SetDetailLayout

    @Environment(AppModel.self) private var model
    @State private var isShowingOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            // One row of large buttons when it fits, else regular ones, else wrapped.
            ViewThatFits(in: .horizontal) {
                GlassEffectContainer(spacing: Spacing.s) {
                    HStack(spacing: Spacing.s) { buttons(.large) }
                }
                GlassEffectContainer(spacing: Spacing.xs) {
                    HStack(spacing: Spacing.xs) { buttons(.regular) }
                }
                GlassEffectContainer(spacing: Spacing.xs) {
                    FlowLayout(spacing: Spacing.xs, lineSpacing: Spacing.xs) { buttons(.regular) }
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if let learn = summary.learn {
                    RunningLine(symbol: "sparkles", text: "Lernen läuft: \(learn.detail)", progress: learn.progressValue)
                }
                if let write = summary.write {
                    RunningLine(symbol: "keyboard", text: "Schreiben läuft: \(write.detail)", progress: write.progressValue)
                }
                if let deck = model.runningFlashcardDeck(for: summary.id) {
                    RunningLine(
                        symbol: FlashcardsSymbols.mode, text: "Karteikarten: \(FlashcardCopy.runningDetail(deck))",
                        progress: deck.knownShare)
                }
                if !layout.isShort {
                    Label(SetDetailCopy.studyNote(summary.set, options: summary.options), systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    // The options this set has of its own (they differ from Einstellungen; "Optionen"
                    // shows and resets them).
                    let own = LearnOptionsCopy.deviations(
                        summary.options, standard: model.settings.study,
                        names: LearnOptionsCopy.sideNames(termLang: summary.set.termLang, defLang: summary.set.defLang),
                        termLang: summary.set.termLang)
                    if !own.isEmpty {
                        Label(SetDetailCopy.ownOptionsNote(own), systemImage: "slider.horizontal.3")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if summary.starred == 0, summary.learn == nil {
                        Label("Markiere schwierige Begriffe mit dem Stern, um sie gezielt zu üben.", systemImage: "lightbulb")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingOptions) {
            SetOptionsSheet(setID: summary.id)
                .environment(model)
        }
    }

    @ViewBuilder
    private func buttons(_ size: ControlSize) -> some View {
        let id = summary.id
        PrimaryActionButton(
            summary.learn != nil ? "Weiterlernen" : "Lernen",
            systemImage: summary.learn != nil ? "play.fill" : "sparkles",
            controlSize: size
        ) {
            model.continueLearn(setID: id)
        }
        .help(summary.learn.map(\.detail) ?? SetDetailCopy.learnTagline(summary.options))

        SecondaryButton(summary.write != nil ? "Schreiben fortsetzen" : "Schreiben", systemImage: "keyboard", controlSize: size) {
            model.continueWrite(setID: id)
        }
        .help(summary.write.map(\.detail) ?? "Jede Karte schriftlich · \(SetDetailCopy.writeAnswerLabel(summary.set, options: summary.options)) (⇧⌘L)")

        SecondaryButton("Karteikarten", systemImage: FlashcardsSymbols.mode, controlSize: size) {
            model.continueFlashcards(setID: id)
        }
        .help(model.runningFlashcardDeck(for: id).map(FlashcardCopy.runningDetail) ?? "Karten umdrehen und sortieren: Weiss ich oder Lerne ich noch (⌥⌘L)")

        SecondaryButton("Prüfung", systemImage: ExamSymbols.mode, controlSize: size) {
            model.startExam(setID: id)
        }
        .help("Alle Fragen auf einer Seite, mit Zeitlimit und einer Note wie in der Schule (⌃⌘L)")

        if summary.starred > 0 {
            SecondaryButton(verbatim: "Nur markierte (\(summary.starred))", systemImage: "star.fill", controlSize: size) {
                model.startLearn(setID: id, subset: .starred)
            }
            .help("Nur die markierten Begriffe lernen")
        }
        if !summary.difficultCardIDs.isEmpty {
            SecondaryButton(verbatim: "Nur schwierige (\(summary.difficultCardIDs.count))", systemImage: "flame", controlSize: size) {
                model.startLearn(setID: id, subset: .cardIds(summary.difficultCardIDs))
            }
            .help("Nur die Begriffe lernen, die du mindestens \(SetSummary.difficultMistakes)× falsch beantwortet hast")
        }
        SecondaryButton("Bearbeiten", systemImage: "pencil", controlSize: size) {
            model.openEditor(.edit(setID: id))
        }
        .help("Begriffe hinzufügen oder bearbeiten (⌘E)")

        SecondaryButton("Optionen", systemImage: "slider.horizontal.3", controlSize: size) {
            isShowingOptions = true
        }
        .help("Abfrage, Fragetypen und Toleranz für dieses Lernset")

        MoreMenu(summary: summary, controlSize: size)
    }
}

/// A running session under the buttons: "Lernen läuft: Runde 3 · 18 von 52 gemeistert" ━━──.
private struct RunningLine: View {
    let symbol: String
    let text: String
    let progress: Double

    var body: some View {
        HStack(spacing: Spacing.s) {
            Label(text, systemImage: symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.accentText)
            ProgressView(value: min(1, max(0, progress)))
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .frame(width: 120)
                .accessibilityHidden(true)
        }
    }
}

/// The "…" menu: restarts, Schreiben subsets, then the set's other actions.
private struct MoreMenu: View {
    let summary: SetSummary
    var controlSize: ControlSize = .large

    @Environment(AppModel.self) private var model

    var body: some View {
        let id = summary.id
        Menu {
            if summary.learn != nil {
                Button("Lernen neu starten", systemImage: "arrow.counterclockwise") {
                    model.restartLearn(setID: id)
                }
            }
            if summary.write != nil {
                Button("Schreiben neu starten", systemImage: "arrow.counterclockwise") {
                    model.restartWrite(setID: id)
                }
            }
            if hasFlashcards {
                Button("Karteikarten neu starten", systemImage: "arrow.counterclockwise") {
                    model.restartFlashcards(setID: id)
                }
            }
            if summary.starred > 0 {
                Button("Nur markierte schreiben (\(summary.starred))", systemImage: "star") {
                    model.startWrite(setID: id, subset: .starred)
                }
            }
            if summary.learn != nil || summary.write != nil || hasFlashcards || summary.starred > 0 {
                Divider()
            }
            SetActionsMenu(summary: summary, includesStudy: false)
        } label: {
            Label("Weitere Aktionen", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(height: 20)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .controlSize(controlSize)
        .fixedSize()
        .help("Weitere Aktionen")
    }

    private var hasFlashcards: Bool {
        model.runningFlashcardDeck(for: summary.id) != nil
    }
}
