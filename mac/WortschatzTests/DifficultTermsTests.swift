import Foundation
import Testing
import WortschatzCore

@testable import Wortschatz

/// «Schwierig» on the set page: terms answered wrong at least 4 times, most mistakes first, and
/// «Nur schwierige» to learn just those.
@MainActor
@Suite("Schwierige Begriffe")
struct DifficultTermsTests {
    /// The never-studied sample set, with `mistakes[i]` wrong answers for card i.
    private static func model(mistakes: [Int]) throws -> (AppModel, VocabSet) {
        let model = SampleLibrary.model(.fresh)
        let set = try #require(model.store.listSets().first)
        for (index, count) in mistakes.enumerated() {
            for _ in 0..<count {
                _ = try model.store.recordAnswer(set.id, set.cards[index].id, correct: false)
            }
        }
        return (model, set)
    }

    @Test("Ab 4× falsch, die meisten Fehler zuerst")
    func difficultFromFourMistakes() throws {
        let (model, set) = try Self.model(mistakes: [3, 4, 0, 6, 4])
        let summary = try #require(model.library.summary(for: set.id))
        #expect(summary.difficultCardIDs == [set.cards[3].id, set.cards[1].id, set.cards[4].id])
        #expect(TermFilter.difficult.count(in: summary) == 3)
        #expect(TermFilter.difficult.label == "Schwierig")
    }

    @Test("Der Filter zeigt nur sie, die meisten Fehler zuerst")
    func filterRows() throws {
        let (model, set) = try Self.model(mistakes: [3, 4, 0, 6, 4])
        let summary = try #require(model.library.summary(for: set.id))
        let rows = SetTermsSection.rows(summary, filter: .difficult, search: "", sortOrder: [])
        #expect(rows.map(\.id) == [set.cards[3].id, set.cards[1].id, set.cards[4].id])
        #expect(rows.map(\.mistakes) == [6, 4, 4])
        // The other filters keep the set's order.
        let all = SetTermsSection.rows(summary, filter: .all, search: "", sortOrder: [])
        #expect(all.map(\.id) == set.cards.map(\.id))
    }

    @Test("Ohne schwierige Begriffe bleibt der Filter leer")
    func noneYet() throws {
        let (model, set) = try Self.model(mistakes: [3, 1])
        let summary = try #require(model.library.summary(for: set.id))
        #expect(summary.difficultCardIDs.isEmpty)
        #expect(SetTermsSection.rows(summary, filter: .difficult, search: "", sortOrder: []).isEmpty)
    }

    @Test("«Nur schwierige» lernt genau diese Begriffe")
    func learnOnlyDifficult() throws {
        let (model, set) = try Self.model(mistakes: [5, 0, 4])
        let summary = try #require(model.library.summary(for: set.id))
        model.startLearn(setID: set.id, subset: .cardIds(summary.difficultCardIDs))
        let request = try #require(model.route.study)
        #expect(request.mode == .learn)
        #expect(request.subset == .cardIds([set.cards[0].id, set.cards[2].id]))

        var now = 1_760_000_000_000.0
        let controller = LearnController(
            model: model, request: request, rng: mulberry32(seed: 5),
            clock: {
                now += 1000
                return now
            }, isLive: false)
        controller.activate()
        let asked = try #require(controller.state.question?.cardId)
        #expect([set.cards[0].id, set.cards[2].id].contains(asked))
        #expect(controller.state.counts.total == 2)
    }
}
