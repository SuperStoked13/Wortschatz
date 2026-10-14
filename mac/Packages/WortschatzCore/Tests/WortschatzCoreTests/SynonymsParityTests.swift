import Testing
import WortschatzCore

/// Replays Fixtures/synonyms.json (mac/Parity/gen-synonyms.js): findSynonymCards for every card of
/// every fixture list (also with added synonym cards) and both ask sides, and gradeWithSynonyms
/// for about 4,500 answers.
@Suite("Parity: synonyms.js")
struct SynonymsParityTests {
    struct BadQuery: Error, CustomStringConvertible {
        let query: JSONValue
        var description: String { "bad query \(ParityDiff.describe(query))" }
    }

    /// JS treats every `ask` other than 'term' as 'definition'.
    static func ask(_ v: JSONValue) -> AskSide { v.stringValue == "term" ? .term : .definition }

    @Test("Synonyms matches src/core/synonyms.js on every fixture case")
    func fixture() throws {
        try runParity("synonyms") { c in
            switch c.fn {
            case "sides":
                guard let card = Card(json: c.arg(0)) else { return nil }
                let ask = Self.ask(c.arg(1))
                return [.string(Synonyms.promptSide(card, ask: ask)), .string(Synonyms.answerSide(card, ask: ask))]
            case "synonymSet":
                let cards = (c.arg(0).arrayValue ?? []).compactMap(Card.init(json:))
                let ask = Self.ask(c.arg(1))
                let lang = Grading.resolveLang(c.arg(2).stringValue)
                let synonyms = cards.map { card in
                    JSONValue.array(Synonyms.findSynonymCards(cards, card: card, ask: ask).map { .string($0.id) })
                }
                let results = try (c.arg(3).arrayValue ?? []).map { query -> JSONValue in
                    guard let q = query.arrayValue, q.count == 3, let i = q[0].integerValue, cards.indices.contains(i),
                          let given = q[1].stringValue, let mask = q[2].integerValue
                    else { throw BadQuery(query: query) }
                    let r = Synonyms.gradeWithSynonyms(
                        given: given, card: cards[i], cards: cards, ask: ask,
                        tolerance: GradingParityTests.tolerance(mask: mask), answerLang: lang)
                    return try encodeToJSONValue(r)
                }
                return ["synonyms": .array(synonyms), "results": .array(results)]
            default:
                return nil
            }
        }
    }
}
