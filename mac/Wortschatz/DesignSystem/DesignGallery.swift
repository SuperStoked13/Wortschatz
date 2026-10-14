#if DEBUG
import SwiftUI
import WortschatzCore

/// Every design-system component on one scrollable page (DEBUG only). Each section is also a
/// snapshot scene (`design-*`, see `DesignSystemSnapshots`).
struct DesignGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.huge) {
                GallerySection("Farben, Schrift & Glas") { GalleryFoundations() }
                GallerySection("Schaltflächen & Tasten") { GalleryControls() }
                GallerySection("Fortschritt") { GalleryProgress() }
                GallerySection("Chips") { GalleryChips() }
                GallerySection("Lernen – Frage") { GalleryStudyQuestion() }
                GallerySection("Lernen – Rückmeldung") { GalleryStudyFeedback() }
                GallerySection("Rückmeldungen & Leerzustand") { GalleryFeedback() }
            }
            .padding(Spacing.xxxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appBackdrop()
    }
}

// MARK: - Sample data

private enum Sample {
    static let set = StatusCounts(fresh: 21, learning: 12, mastered: 19)
    static let round = StatusCounts(fresh: 3, learning: 2, mastered: 2)
    static let allMastered = StatusCounts(fresh: 0, learning: 0, mastered: 52)
    static let untouched = StatusCounts(fresh: 52, learning: 0, mastered: 0)
    static let choices = ["la maison", "le jardin", "la fenêtre", "l’escalier"]
}

// MARK: - Layout helpers

private struct GallerySection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(title)
                .font(Typography.display)
            content
        }
    }
}

private struct GalleryGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title).eyebrowStyle()
            content
        }
    }
}

/// A snapshot page: backdrop, padding, a title.
private struct GalleryPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text(title)
                .font(Typography.display)
            content
            Spacer(minLength: 0)
        }
        .padding(Spacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .appBackdrop()
    }
}

// MARK: - Foundations

private struct GalleryFoundations: View {
    private let swatches: [(String, Color)] = [
        ("Akzent", Theme.accent),
        ("Gemeistert", Theme.mastered.fill),
        ("Am Lernen", Theme.learning.fill),
        ("Neu", Theme.new.fill),
        ("Richtig", Theme.success.fill),
        ("Falsch", Theme.failure.fill),
        ("Hinweis", Theme.warning.fill),
        ("Info", Theme.info.fill),
        ("Stern", Theme.star),
        ("Serie", Theme.flame),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xxl) {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                GalleryGroup("Farben") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: Spacing.s), count: 5), alignment: .leading, spacing: Spacing.s) {
                        ForEach(swatches, id: \.0) { name, color in
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: Radii.small, style: .continuous)
                                    .fill(color)
                                    .frame(height: 44)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: Radii.small, style: .continuous)
                                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                                    }
                                Text(name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                GalleryGroup("Glas") {
                    HStack(alignment: .top, spacing: Spacing.m) {
                        GlassCard(padding: Spacing.l) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("GlassCard").font(Typography.headline)
                                Text("Lernkarte, Hero").foregroundStyle(.secondary)
                            }
                            .frame(width: 150, alignment: .leading)
                        }
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("GlassPanel").font(Typography.headline)
                                Text("Schwebende Leiste").foregroundStyle(.secondary)
                            }
                            .frame(width: 150, alignment: .leading)
                        }
                        ContentPanel {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("ContentPanel").font(Typography.headline)
                                Text("Lernset-Karte, Erkennung (kein Glas)").foregroundStyle(.secondary)
                            }
                            .frame(width: 150, alignment: .leading)
                        }
                    }
                }
            }
            GalleryGroup("Schrift") {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Guten Morgen").font(Typography.display)
                    Text("la maison").font(Typography.prompt)
                    Text("Je voudrais un café, s’il vous plaît.").font(Typography.prompt(for: "Je voudrais un café, s’il vous plaît."))
                    Text("Lernsets").font(Typography.title)
                    Text("Richtige Antwort").font(Typography.headline)
                    Text("Füge deine Vokabelliste hier ein – Wortschatz erkennt Begriffe und Definitionen automatisch.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420, alignment: .leading)
                    Text("Französisch · Runde 2").eyebrowStyle()
                }
            }
        }
    }
}

// MARK: - Controls

private struct GalleryControls: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            GalleryGroup("Primär (glassProminent, ↩)") {
                HStack(spacing: Spacing.m) {
                    PrimaryActionButton("Weiter", bindsShortcut: false) {}
                    PrimaryActionButton("Lernen", systemImage: "graduationcap.fill", bindsShortcut: false) {}
                    PrimaryActionButton(verbatim: "Weiter zu Runde 3", bindsShortcut: false) {}
                    PrimaryActionButton("Speichern", key: .commandReturn, bindsShortcut: false) {}
                    PrimaryActionButton("Antworten", bindsShortcut: false) {}
                        .disabled(true)
                }
            }
            GalleryGroup("Sekundär (glass)") {
                HStack(spacing: Spacing.m) {
                    SecondaryButton("Weiss ich nicht", key: .optionReturn, bindsShortcut: false) {}
                    SecondaryButton("Ich hatte recht", key: .commandReturn, bindsShortcut: false) {}
                    SecondaryButton("Schreiben", systemImage: "pencil.line", bindsShortcut: false) {}
                    SecondaryButton("Beenden", key: .escape, bindsShortcut: false) {}
                }
            }
            GalleryGroup("Kleine Steuerelemente") {
                HStack(spacing: Spacing.m) {
                    PrimaryActionButton("Lernen", bindsShortcut: false, controlSize: .regular) {}
                    SecondaryButton("Bearbeiten", systemImage: "square.and.pencil", bindsShortcut: false, controlSize: .regular) {}
                    SecondaryButton("Vorlesen", systemImage: "speaker.wave.2.fill", key: .command("R"), bindsShortcut: false, controlSize: .regular) {}
                }
            }
            GalleryGroup("Schwebende Aktionsleiste") {
                GlassActionBar {
                    SecondaryButton("Weiss ich nicht", key: .optionReturn, bindsShortcut: false) {}
                    PrimaryActionButton("Antworten", bindsShortcut: false) {}
                }
            }
            GalleryGroup("Tasten") {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    HStack(spacing: Spacing.s) {
                        ForEach([KeyGlyph.returnKey, .optionReturn, .commandReturn, .escape, .digit(1), .digit(2), .digit(3), .digit(4), .tab, .arrows, .command("E"), .shiftCommand("L")], id: \.self) { glyph in
                            Keycap(glyph)
                        }
                        Keycap(.returnKey, size: .large)
                        Keycap(.digit(1), size: .small)
                    }
                    KeyHintRow([(.returnKey, "Weiter"), (.optionReturn, "Weiss ich nicht"), (.commandReturn, "Ich hatte recht"), (.escape, "Beenden")])
                }
            }
        }
    }
}

// MARK: - Progress

private struct GalleryProgress: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            HStack(spacing: Spacing.m) {
                StatTile("Lernserie", value: "5", unit: "Tage", systemImage: "flame.fill", tint: Theme.flame, caption: "Rekord: 12 Tage")
                StatTile("Heute beantwortet", value: "42", systemImage: "checkmark.bubble.fill", tint: Theme.accent, caption: "Weiter so!")
                StatTile("Begriffe gemeistert", value: "128", systemImage: "star.fill", tint: Theme.mastered.fill, caption: "von 312")
            }
            HStack(alignment: .top, spacing: Spacing.xxl) {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    GalleryGroup("Fortschrittskapsel") {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            ProgressCapsule(counts: Sample.round)
                            ProgressCapsule(counts: Sample.set, style: .compact)
                        }
                    }
                    GalleryGroup("Runde") {
                        RoundProgressBar(value: 3, total: 7, label: "Runde 2")
                            .frame(width: 420)
                    }
                    GalleryGroup("Seitenleiste") {
                        VStack(alignment: .leading, spacing: 10) {
                            sidebarRow("Unité 3 – La maison", count: 52, counts: Sample.set)
                            sidebarRow("Verbes irréguliers", count: 34, counts: Sample.untouched)
                            sidebarRow("Les couleurs", count: 52, counts: Sample.allMastered)
                        }
                        .frame(width: 280)
                    }
                }
                GalleryGroup("Lernstand") {
                    GlassPanel(padding: Spacing.xl) {
                        VStack(alignment: .leading, spacing: Spacing.l) {
                            MasteryGauge(counts: Sample.set, size: .large, showsLegend: true)
                            HStack(spacing: Spacing.l) {
                                MasteryGauge(counts: Sample.untouched, size: .medium)
                                MasteryGauge(counts: Sample.round, size: .medium)
                                MasteryGauge(counts: Sample.allMastered, size: .medium)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sidebarRow(_ title: String, count: Int, counts: StatusCounts) -> some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                Text(Labels.plural(count, "Begriff", "Begriffe")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MasteryGauge(counts: counts)
        }
    }
}

// MARK: - Chips

private struct GalleryChips: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            GalleryGroup("Status") {
                HStack(spacing: Spacing.xs) {
                    ForEach(CardStatus.allCases, id: \.self) { StatusChip(status: $0) }
                    ForEach(CardStatus.allCases, id: \.self) { StatusChip(status: $0, size: .small) }
                }
            }
            GalleryGroup("Sprachen") {
                HStack(spacing: Spacing.xs) {
                    LanguageCapsule(termLang: .fr, defLang: .de)
                    LanguageCapsule(termLang: .en, defLang: .de)
                    LanguageCapsule(termLang: .es, defLang: .de, style: .short)
                }
            }
            GalleryGroup("Hinweise zur Antwort") {
                FlowLayout(spacing: Spacing.xs, lineSpacing: Spacing.xs) {
                    ForEach([GradeNote.article, .accents, .typo, .letterCase, .parentheses, .synonym, .extendedSynonym], id: \.self) { NoteChip($0) }
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
            GalleryGroup("Tipps") {
                FlowLayout(spacing: Spacing.xs, lineSpacing: Spacing.xs) {
                    ForEach(GradeHint.allCases, id: \.self) { HintChip($0) }
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }
}

// MARK: - Study

private struct StudyCardMock: View {
    var prompt = "la maison"
    var showsAnswerField = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack {
                    Text("Französisch").eyebrowStyle()
                    Spacer()
                    HStack(spacing: Spacing.m) {
                        Image(systemName: "speaker.wave.2.fill")
                        Image(systemName: "star")
                        Image(systemName: "square.and.pencil")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                Text(prompt)
                    .font(Typography.prompt(for: prompt))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.s)
                if showsAnswerField {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("das Haus")
                            .font(Typography.answerField)
                            .padding(.horizontal, Spacing.m)
                            .padding(.vertical, Spacing.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Theme.accent, lineWidth: 2)
                            }
                        SpecialCharacterBar(lang: .de) { _ in }
                    }
                }
            }
        }
        .frame(maxWidth: LayoutMetrics.studyColumnWidth)
    }
}

private struct StudyTopBar: View {
    var body: some View {
        HStack {
            SecondaryButton("Lernsets", systemImage: "chevron.left", bindsShortcut: false, controlSize: .regular) {}
            Spacer()
            ProgressCapsule(counts: Sample.round)
            Spacer()
            Text("Runde 2")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
        }
    }
}

private struct GalleryStudyQuestion: View {
    var body: some View {
        VStack(spacing: Spacing.xl) {
            StudyTopBar()
            StudyCardMock()
            ChoiceGrid(choices: ["das Haus", "der Garten", "das Fenster", "die Treppe"], state: { $0 == 0 ? .highlighted : .idle }) { _ in }
                .frame(maxWidth: LayoutMetrics.studyColumnWidth)
            KeyHintRow([(.digit(1), "bis 4 wählen"), (.returnKey, "Auswahl bestätigen"), (.optionReturn, "Weiss ich nicht")])
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GalleryStudyFeedback: View {
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xxl) {
            VStack(spacing: Spacing.l) {
                ChoiceGrid(choices: ["das Haus", "der Garten", "das Fenster", "die Treppe"], state: { index in
                    switch index {
                    case 0: .correct
                    case 2: .wrong
                    default: .dimmed
                    }
                }) { _ in }
                LearnStatusPill(status: LearnStatus(kind: .wrong, title: "Nicht ganz – das lernst du noch!", message: "Richtig: das Haus"), countdown: nil, trigger: 0)
                GlassActionBar {
                    SecondaryButton("Ich hatte recht", key: .commandReturn, bindsShortcut: false) {}
                    PrimaryActionButton("Weiter", bindsShortcut: false) {}
                }
            }
            .frame(maxWidth: 540)
            VStack(spacing: Spacing.l) {
                StudyCardMock(prompt: "la fenêtre", showsAnswerField: true)
                LearnStatusPill(status: LearnStatus(kind: .correct, title: "Super!", message: "das Fenster"), countdown: nil, trigger: 0)
                HStack(spacing: Spacing.xs) {
                    NoteChip(.article)
                    NoteChip(.accents)
                }
            }
            .frame(maxWidth: 540)
        }
    }
}

// MARK: - Feedback

private struct GalleryFeedback: View {
    @State private var toasts = GalleryFeedback.sampleToasts()

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xxl) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                LearnStatusPill(status: LearnStatus(kind: .correct, title: "Klasse!"), countdown: nil, trigger: 0)
                LearnStatusPill(status: LearnStatus(kind: .wrong, title: "Nicht ganz – das lernst du noch!", message: "Gesucht war: la fenêtre"), countdown: nil, trigger: 0)
                LearnStatusPill(status: LearnStatus(kind: .dontKnow, title: "Kein Problem – merk dir:", message: "l’escalier – die Treppe"), countdown: nil, trigger: 0)
                HStack(spacing: Spacing.xs) {
                    HintChip(.wrongArticle)
                    NoteChip(.synonym)
                }
                ToastOverlay(center: toasts)
                    .frame(height: 170)
            }
            .frame(maxWidth: 560)
            GlassCard(padding: 0) {
                EmptyStateView(
                    systemImage: "rectangle.stack.badge.plus",
                    title: "Noch keine Lernsets",
                    message: "Füge deine Vokabelliste ein, wähle eine Datei oder ein Foto – Wortschatz erkennt die Paare automatisch."
                ) {
                    PrimaryActionButton("Erstes Lernset erstellen", bindsShortcut: false) {}
                    SecondaryButton("Aus der Web-Version übernehmen…", bindsShortcut: false) {}
                }
                .frame(height: 420)
                .celebration(playsOnAppear: false)
            }
        }
    }

    private static func sampleToasts() -> ToastCenter {
        let center = ToastCenter()
        center.show("Willkommen zurück – du warst in Runde 2.", systemImage: "hand.wave.fill", duration: nil)
        center.show("Lernset gelöscht", systemImage: "trash.fill", action: .init("Rückgängig") {}, duration: .seconds(3600))
        center.show("Backup gespeichert", tone: .success, duration: .seconds(3600))
        return center
    }
}

// MARK: - Composition example (overview)

/// How the pieces combine on a real screen (the Übersicht detail column). A layout reference
/// for the feature screens, not the Overview feature itself.
private struct GalleryOverviewMock: View {
    private struct SetCardModel: Identifiable {
        let id = UUID()
        let title: String
        let terms: Int
        let studied: String
        let counts: StatusCounts
    }

    private let sets = [
        SetCardModel(title: "Unité 3 – La maison", terms: 52, studied: "vor 2 Stunden", counts: Sample.set),
        SetCardModel(title: "Verbes irréguliers", terms: 34, studied: "noch nie", counts: StatusCounts(fresh: 34, learning: 0, mastered: 0)),
        SetCardModel(title: "Les couleurs", terms: 18, studied: "vor 3 Tagen", counts: StatusCounts(fresh: 0, learning: 0, mastered: 18)),
        SetCardModel(title: "Au restaurant", terms: 41, studied: "gestern", counts: StatusCounts(fresh: 12, learning: 20, mastered: 9)),
        SetCardModel(title: "Le corps humain", terms: 27, studied: "vor 1 Woche", counts: StatusCounts(fresh: 5, learning: 4, mastered: 18)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Guten Morgen").font(Typography.display)
                Text("Montag, 12. Oktober").font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: Spacing.m) {
                StatTile("Lernserie", value: "5", unit: "Tage", systemImage: "flame.fill", tint: Theme.flame)
                StatTile("Heute beantwortet", value: "42", systemImage: "checkmark.bubble.fill")
                StatTile("Begriffe gemeistert", value: "128", systemImage: "star.fill", tint: Theme.mastered.fill)
            }
            GlassCard(padding: Spacing.xl) {
                HStack(spacing: Spacing.l) {
                    MasteryGauge(counts: Sample.set, size: .medium)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Weiterlernen").eyebrowStyle()
                        Text("Unité 3 – La maison").font(Typography.title)
                        HStack(spacing: Spacing.xs) {
                            LanguageCapsule(termLang: .fr, defLang: .de, style: .short)
                            Text("Lernen · Runde 2 · 19 von 52 gemeistert")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: Spacing.m)
                    PrimaryActionButton("Weiterlernen", systemImage: "play.fill", bindsShortcut: false) {}
                }
            }
            Text("Lernsets").font(Typography.title)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.m), count: 3), spacing: Spacing.m) {
                ForEach(sets) { set in
                    GlassCard(padding: Spacing.l, cornerRadius: Radii.tile) {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(set.title).font(Typography.headline).lineLimit(1)
                                    Text("\(Labels.plural(set.terms, "Begriff", "Begriffe")) · \(set.studied)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: Spacing.xs)
                                MasteryGauge(counts: set.counts, size: .medium)
                            }
                            StatusBar(counts: set.counts, height: 6)
                        }
                    }
                }
                newSetCard
            }
        }
    }

    private var newSetCard: some View {
        RoundedRectangle(cornerRadius: Radii.tile, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .overlay {
                Label("Neues Lernset", systemImage: "plus")
                    .font(.headline)
                    .foregroundStyle(Theme.accentText)
            }
            .frame(minHeight: 104)
    }
}

// MARK: - Accessibility variants

private struct GalleryAccessibility: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            StudyCardMock()
            ChoiceGrid(choices: Sample.choices, state: { [.highlighted, .idle, .correct, .wrong][$0] }) { _ in }
                .frame(maxWidth: LayoutMetrics.studyColumnWidth)
            HStack(spacing: Spacing.m) {
                ProgressCapsule(counts: Sample.round)
                LearnStatusPill(status: LearnStatus(kind: .correct, title: "Genau!"), countdown: nil, trigger: 0)
            }
            .frame(maxWidth: LayoutMetrics.studyColumnWidth)
        }
    }
}

// MARK: - Snapshot scenes

/// Registers the gallery pages with the snapshot harness (`--render-snapshots`).
final class DesignSystemSnapshots: SnapshotCatalog {
    override class var scenes: [SnapshotScene] {
        [
            SnapshotScene("design-foundations") { GalleryPage("Farben, Schrift & Glas") { GalleryFoundations() } },
            SnapshotScene("design-controls") { GalleryPage("Schaltflächen & Tasten") { GalleryControls() } },
            SnapshotScene("design-progress") { GalleryPage("Fortschritt") { GalleryProgress() } },
            SnapshotScene("design-chips", size: CGSize(width: 1000, height: 560)) { GalleryPage("Chips") { GalleryChips() } },
            SnapshotScene("design-study-question") {
                GalleryStudyQuestion()
                    .padding(Spacing.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .appBackdrop()
            },
            SnapshotScene("design-study-feedback") { GalleryPage("Rückmeldung") { GalleryStudyFeedback() } },
            SnapshotScene("design-feedback") { GalleryPage("Rückmeldungen & Leerzustand") { GalleryFeedback() } },
            SnapshotScene("design-a11y-reduce-transparency", size: CGSize(width: 1000, height: 760)) {
                GalleryPage("Transparenz reduzieren") { GalleryAccessibility() }
                    .environment(\._accessibilityReduceTransparency, true)
            },
            SnapshotScene("design-a11y-increased-contrast", size: CGSize(width: 1000, height: 760)) {
                GalleryPage("Kontrast erhöhen") { GalleryAccessibility() }
                    .environment(\._colorSchemeContrast, .increased)
            },
            SnapshotScene("design-overview-mock", size: CGSize(width: 1000, height: 800)) {
                GalleryOverviewMock()
                    .padding(Spacing.xxl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .appBackdrop()
            },
            SnapshotScene("design-gallery", size: CGSize(width: 1240, height: 4200)) { DesignGallery() },
        ]
    }
}

#Preview("Design-Galerie") {
    DesignGallery()
        .frame(width: 1240, height: 900)
}
#endif
