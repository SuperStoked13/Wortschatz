import Foundation
import WortschatzCore

// Derived, read-only view data of the library (port of `loadData()` in
// src/screens/dashboard.js and `readModel()` in src/screens/set.js). `AppModel` rebuilds it
// after every store change, so views never touch `LibraryStore` directly.

/// Everything the sidebar, the overview and the set detail show, computed in one pass.
struct LibrarySnapshot {
    /// Sets in store order: most recently studied or edited first.
    var sets: [SetSummary]
    /// Lernserie, Heute beantwortet, Begriffe gemeistert.
    var stats: OverviewStats
    /// "Weiterlernen": the latest unfinished Learn session, else the latest Write session.
    var resume: ResumeItem?

    static let empty = LibrarySnapshot(
        sets: [], stats: OverviewStats(streak: StudyStreak(current: 0, today: 0, longest: 0), week: 0, mastered: 0, total: 0),
        resume: nil)

    func summary(for setID: String) -> SetSummary? {
        sets.first { $0.id == setID }
    }

    var isEmpty: Bool { sets.isEmpty }

    /// Builds the snapshot from the store's current contents. With the `previous` snapshot and
    /// the `change` since, a set whose card data, progress and sessions are untouched keeps its
    /// summary (an answer rebuilds only the studied set: decoding and checking every set's
    /// sessions took ~3.5 ms per answer for 1100 cards in four sets).
    @MainActor
    static func build(
        from store: LibraryStore, now: Double = TimeUtil.nowMs(), previous: LibrarySnapshot? = nil,
        change: StoreChange? = nil
    ) -> LibrarySnapshot {
        let activity = store.getActivity()
        let streak = Mastery.studyStreak(activity, now: now, timeZone: store.timeZone)
        var mastered = 0
        var total = 0
        var latestLearn: (summary: SetSummary, resume: LearnResume)?
        var latestWrite: (summary: SetSummary, resume: WriteResume)?

        // Summaries that cannot have changed (settings feed every set's options).
        var reusable: [String: SetSummary] = [:]
        if let previous, let change, change.keys != nil, !change.touches("settings") {
            for summary in previous.sets { reusable[summary.id] = summary }
        }

        let summaries = store.listSets().map { set -> SetSummary in
            let summary =
                if let old = reusable[set.id], old.set == set, !(change?.touchesSetData(set.id) ?? true) {
                    old
                } else {
                    SetSummary(set: set, store: store, now: now)
                }
            mastered += summary.stats.mastered
            total += summary.stats.total
            if let learn = summary.learn, learn.updatedAt > (latestLearn?.resume.updatedAt ?? -.infinity) {
                latestLearn = (summary, learn)
            }
            if let write = summary.write, write.updatedAt > (latestWrite?.resume.updatedAt ?? -.infinity) {
                latestWrite = (summary, write)
            }
            return summary
        }

        let resume: ResumeItem? =
            if let latestLearn {
                ResumeItem(setID: latestLearn.summary.id, kind: .learn(latestLearn.resume))
            } else if let latestWrite {
                ResumeItem(setID: latestWrite.summary.id, kind: .write(latestWrite.resume))
            } else {
                nil
            }

        return LibrarySnapshot(
            sets: summaries,
            stats: OverviewStats(
                streak: streak, week: weekTotal(activity, now: now, timeZone: store.timeZone), mastered: mastered,
                total: total),
            resume: resume)
    }

    /// Answers over the last seven calendar days including today (`weekTotal` of dashboard.js).
    static func weekTotal(_ activity: Activity, now: Double, timeZone: TimeZone) -> Int {
        let today = TimeUtil.localDate(now, timeZone: timeZone).dayNumber
        var sum = 0
        for offset in 0..<7 {
            let n = activity[TimeUtil.dateKey(dayNumber: today - offset)] ?? 0
            if n > 0 { sum += n }
        }
        return sum
    }
}

/// The statistics strip of the overview.
struct OverviewStats: Equatable {
    var streak: StudyStreak
    /// Answers in the last seven days.
    var week: Int
    /// Mastered cards over all sets.
    var mastered: Int
    /// Cards over all sets.
    var total: Int
}

/// One set with its progress and running sessions.
struct SetSummary: Identifiable {
    let set: VocabSet
    /// Stored progress of the set's cards.
    let progress: ProgressMap
    /// Status counts (`Mastery.setProgress`).
    let stats: SetProgress
    /// Number of starred cards.
    let starred: Int
    /// Cards answered wrong at least `difficultMistakes` times ("Schwierig"), most mistakes
    /// first, then in card order.
    let difficultCardIDs: [String]
    /// The unfinished Learn session, if any.
    let learn: LearnResume?
    /// The unfinished Write session, if any.
    let write: WriteResume?
    /// The set's effective study options (settings defaults merged with the set's own).
    let options: StudyOptions
    /// Whether "Fortschritt zurücksetzen" has anything to reset.
    let canReset: Bool

    var id: String { self.set.id }
    var counts: StatusCounts { StatusCounts(stats) }
    var isEmpty: Bool { self.set.cards.isEmpty }
    var isAllMastered: Bool { stats.total > 0 && stats.mastered == stats.total }

    func status(of card: Card) -> CardStatus {
        Mastery.cardStatus(progress[card.id])
    }

    /// From this many wrong answers (in total) a card counts as difficult.
    static let difficultMistakes = 4

    /// How often `card` was answered wrong (in total).
    func mistakes(of card: Card) -> Int {
        progress[card.id]?.incorrect ?? 0
    }

    @MainActor
    init(set: VocabSet, store: LibraryStore, now: Double) {
        self.set = set
        let progress = store.getProgress(set.id)
        self.progress = progress
        stats = Mastery.setProgress(set, progress)
        starred = set.cards.reduce(0) { $0 + ($1.starred ? 1 : 0) }
        difficultCardIDs = set.cards.enumerated()
            .map { (id: $0.element.id, position: $0.offset, mistakes: progress[$0.element.id]?.incorrect ?? 0) }
            .filter { $0.mistakes >= Self.difficultMistakes }
            .sorted { ($0.mistakes, -$0.position) > ($1.mistakes, -$1.position) }
            .map(\.id)
        options = store.getStudyOptions(set.id)
        let sessionJSON = store.getSessionJSON(set.id)
        let learnJSON = store.getLearnJSON(set.id)
        canReset = !progress.isEmpty || sessionJSON != nil || learnJSON != nil
        write = sessionJSON.flatMap { WriteResume(WriteSession.copyState($0)) }
        learn = learnJSON.flatMap { LearnResume(LearnEngine.copyState($0), progress: progress, now: now) }
    }
}

/// A running Learn session (`activeLearn` in dashboard.js, `readModel().learn` in set.js).
struct LearnResume: Equatable {
    /// The session synced with the stored progress (answers given in Schreiben count too).
    let state: LearnState
    let counts: LearnEngine.Counts
    let round: Int
    /// The round is over but the checkpoint was not dismissed yet ("Runde 3 geschafft").
    let roundOver: Bool

    var updatedAt: Double { state.updatedAt }
    var subset: StudySubset { state.subset }

    /// Whether starting over would throw answers away (`learnHasAnswers` in set.js).
    var hasAnswers: Bool { !state.rounds.isEmpty || state.answered > 0 }

    init?(_ stored: LearnState, progress: ProgressMap, now: Double) {
        guard stored.finishedAt == nil else { return nil }
        let state = LearnEngine.syncProgress(stored, progress: progress, now: now)
        let counts = LearnEngine.counts(state)
        guard counts.total > 0, !LearnEngine.isFinished(state) else { return nil }
        self.state = state
        self.counts = counts
        round = state.round > 0 ? state.round : 1
        // A round without answers (only after removals) shows no checkpoint: it is not "geschafft".
        roundOver = LearnEngine.isRoundOver(state) && LearnEngine.checkpoint(state).answered > 0
    }

    /// "Runde 3" or "Runde 3 geschafft".
    var roundText: String {
        roundOver ? String(localized: "Runde \(round) geschafft") : String(localized: "Runde \(round)")
    }

    /// "18 von 52 gemeistert".
    var masteredText: String {
        String(localized: "\(counts.mastered) von \(counts.total) gemeistert")
    }

    /// "Nur markierte · Runde 3 · 18 von 52 gemeistert" (`learnDetail` in set.js).
    var detail: String {
        StudyCopy.join([StudyCopy.subsetLabel(subset, objectLabel: String(localized: "Ausgewählte Begriffe")), roundText, masteredText])
    }

    /// "Runde 3 · 18/52" or "Runde 3 · 0/3 markierte" for compact places (set cards, sidebar).
    var shortDetail: String {
        let mastered = counts.mastered
        let total = counts.total
        let count: String =
            switch subset {
            case .all: "\(mastered)/\(total)"
            case .starred: String(localized: "\(mastered)/\(total) markierte")
            case .learning: String(localized: "\(mastered)/\(total) offene")
            case .missed: String(localized: "\(mastered)/\(total) falsche")
            case .cardIds: String(localized: "\(mastered)/\(total) ausgewählte")
            }
        return "\(roundText) · \(count)"
    }

    /// Mastered share of the session (0…1).
    var progressValue: Double { counts.progress }
}

/// A running Write session (`readModel().session` in set.js).
struct WriteResume: Equatable {
    let state: SessionState
    let counters: WriteSession.Counters

    var updatedAt: Double { state.updatedAt }
    var subset: StudySubset { state.subset }

    /// Whether starting over would throw answers away (`hasAnswers` in write-model.js).
    var hasAnswers: Bool { !state.rounds.isEmpty || !state.roundAnswered.isEmpty }

    init?(_ state: SessionState) {
        guard state.finishedAt == nil else { return nil }
        let counters = WriteSession.counters(state)
        guard counters.total > 0 else { return nil }
        self.state = state
        self.counters = counters
    }

    /// "Runde 2 · 5 übrig" or "Runde 2 geschafft" (`sessionLabel` in dashboard.js).
    var roundText: String {
        counters.remaining == 0
            ? String(localized: "Runde \(counters.round) geschafft")
            : String(localized: "Runde \(counters.round) · \(counters.remaining) übrig")
    }

    /// "Runde 2 · 5 übrig" or "Runde 2 geschafft · 3 zum Wiederholen", with the subset in front
    /// (`sessionDetail` in set.js).
    var detail: String {
        var parts = [StudyCopy.subsetLabel(subset, objectLabel: String(localized: "Falsche Begriffe"))]
        if counters.remaining > 0 {
            parts += [String(localized: "Runde \(counters.round)"), String(localized: "\(counters.remaining) übrig")]
        } else {
            parts.append(String(localized: "Runde \(counters.round) geschafft"))
            if counters.incorrect > 0 { parts.append(String(localized: "\(counters.incorrect) zum Wiederholen")) }
        }
        return StudyCopy.join(parts)
    }

    /// "5 übrig" or "Runde geschafft".
    var shortDetail: String {
        counters.remaining > 0 ? String(localized: "\(counters.remaining) übrig") : String(localized: "Runde geschafft")
    }

    var progressValue: Double { counters.progress }
}

/// The "Weiterlernen" hero of the overview.
struct ResumeItem: Equatable {
    enum Kind: Equatable {
        case learn(LearnResume)
        case write(WriteResume)
    }

    var setID: String
    var kind: Kind

    var mode: StudyMode {
        switch kind {
        case .learn: .learn
        case .write: .write
        }
    }
}

/// German copy shared by the overview, the sidebar and the set detail (dashboard.js, set.js).
enum StudyCopy {
    /// `SUBSET_LABELS` ("Nur markierte"); a card-id subset uses `objectLabel`.
    static func subsetLabel(_ subset: StudySubset, objectLabel: String) -> String? {
        switch subset {
        case .all: nil
        case .starred: String(localized: "Nur markierte")
        case .learning: String(localized: "Nur nicht gemeisterte")
        case .missed: String(localized: "Nur falsche")
        case .cardIds: objectLabel
        }
    }

    /// Parts joined by " · "; each part keeps its spaces unbreakable so a line only wraps
    /// between parts (`joinParts` in set.js).
    static func join(_ parts: [String?]) -> String {
        parts.compactMap(\.self).map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · ")
    }

    /// "52 Begriffe".
    static func terms(_ n: Int) -> String {
        Labels.plural(n, "Begriff", "Begriffe")
    }

    /// The text after "vor"/"gestern" starts in lower case; at the start of a label it is
    /// capitalised ("Vor 2 Tagen").
    static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Case-, accent- and sharp-s-insensitive search form (`fold` in dashboard.js).
    static func fold(_ text: String) -> String {
        if let known = folded[text] { return known }
        let lowered = TextNormalizer.stripDiacritics(text.lowercased())
        let result = lowered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if folded.count >= 50_000 { folded.removeAll(keepingCapacity: true) }
        folded[text] = result
        return result
    }

    /// `fold` of the texts searched so far: the sidebar and the term list fold every title, term
    /// and definition on each key typed into their search (7 ms per key for 1100 cards; 1 ms with
    /// this).
    private static var folded: [String: String] = [:]
}
