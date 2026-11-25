import Foundation
import Testing
import WortschatzCore

@testable import Wortschatz

/// After a store change, `LibrarySnapshot.build` keeps the summaries of sets the change did not
/// touch; the result must be the same as building everything anew.
@MainActor
@Suite("Übersichtsdaten nach einer Änderung")
struct LibrarySnapshotTests {
    /// Whether two summaries show the same (every derived field).
    private static func same(_ a: SetSummary, _ b: SetSummary) -> Bool {
        a.set == b.set && a.progress == b.progress && a.stats == b.stats && a.starred == b.starred
            && a.difficultCardIDs == b.difficultCardIDs && a.options == b.options && a.canReset == b.canReset
            && a.learn == b.learn && a.write == b.write
    }

    private static func expectSameAsFullBuild(_ model: AppModel, sourceLocation: SourceLocation = #_sourceLocation) {
        let full = LibrarySnapshot.build(from: model.store)
        let kept = model.latestLibrary
        #expect(kept.sets.map(\.id) == full.sets.map(\.id), sourceLocation: sourceLocation)
        for (a, b) in zip(kept.sets, full.sets) {
            #expect(Self.same(a, b), "\(a.id)", sourceLocation: sourceLocation)
        }
        #expect(kept.stats == full.stats, sourceLocation: sourceLocation)
        #expect(kept.resume?.setID == full.resume?.setID, sourceLocation: sourceLocation)
    }

    @Test("Eine Antwort baut nur ihr Lernset neu, das Ergebnis bleibt gleich")
    func answerKeepsOtherSets() throws {
        let model = SampleLibrary.model(.learning)
        let sets = model.store.listSets()
        try #require(sets.count >= 2)
        let other = try #require(model.latestLibrary.summary(for: sets[1].id))
        let card = try #require(sets[0].cards.first)

        try model.store.recordAnswer(sets[0].id, card.id, correct: false)
        Self.expectSameAsFullBuild(model)
        // The untouched set kept its summary (same derived values without rebuilding).
        let kept = try #require(model.latestLibrary.summary(for: sets[1].id))
        #expect(Self.same(kept, other))
    }

    @Test("Stern, Optionen, Einstellungen und Zurücksetzen werden übernommen")
    func otherChanges() throws {
        let model = SampleLibrary.model(.learning)
        let sets = model.store.listSets()
        let first = try #require(sets.first)
        let card = try #require(first.cards.first)

        try model.store.toggleStar(first.id, card.id)
        Self.expectSameAsFullBuild(model)
        try model.store.updateStudyOptions(sets[1].id, StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 5)))
        Self.expectSameAsFullBuild(model)
        _ = try model.store.updateSettings(SettingsPatch(study: StudyOptionsPatch(answerWith: .term)))
        Self.expectSameAsFullBuild(model)
        try model.store.resetProgress(first.id)
        Self.expectSameAsFullBuild(model)
        try model.store.clearLearn(first.id)
        Self.expectSameAsFullBuild(model)
    }
}
