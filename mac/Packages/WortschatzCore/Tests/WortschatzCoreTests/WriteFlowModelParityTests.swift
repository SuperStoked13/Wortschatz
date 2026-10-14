import Foundation
import Testing
@testable import WortschatzCore

/// Replays the web app's results for write-model.js (and the answer diff of write-card.js) from
/// `WriteFlowWebCases` against the Swift port, JSON for JSON.
@Suite("Parity: write-model.js")
struct WriteFlowModelParityTests {
    struct Reference {
        var sets: [String: VocabSet]
        var sessions: [SessionState]
        var cases: [JSONValue]
    }

    static let reference: Reference? = {
        guard let doc = try? JSONValue.parse(WriteFlowWebCases.json) else { return nil }
        var sets: [String: VocabSet] = [:]
        for (name, value) in doc["sets"]?.objectValue ?? [:] {
            var json = value.objectValue ?? [:]
            json["id"] = .string(name)
            json["title"] = .string(name)
            sets[name] = VocabSet(json: .object(json), fallbackNow: 0)
        }
        return Reference(
            sets: sets, sessions: (doc["sessions"]?.arrayValue ?? []).map(WriteSession.copyState),
            cases: doc["cases"]?.arrayValue ?? [])
    }()

    static func lang(_ v: JSONValue?) -> Lang? { v?.stringValue.flatMap(Lang.init(rawValue:)) }

    static func question(_ set: VocabSet, _ cardId: String, _ ask: String) throws -> WriteFlow.Question {
        let card = try #require(set.cards.first { $0.id == cardId })
        let side: AskSide = ask == "term" ? .term : .definition
        return WriteFlow.questionInfo(
            set: set, card: card, question: SessionQuestion(qid: WriteSession.qid(cardId: cardId, ask: side), cardId: cardId, ask: side))
    }

    /// The Swift result of one reference case (nil for an unknown `fn`).
    static func run(_ fn: String, _ args: [JSONValue], _ ref: Reference) throws -> JSONValue? {
        func arg(_ i: Int) -> JSONValue { i < args.count ? args[i] : .null }
        func set(_ i: Int) throws -> VocabSet { try #require(ref.sets[arg(i).stringValue ?? ""]) }
        func session(_ i: Int) throws -> SessionState {
            let index = try #require(arg(i).integerValue)
            return ref.sessions[index]
        }
        switch fn {
        case "questionInfo":
            let termLang = try #require(lang(arg(0)))
            let defLang = try #require(lang(arg(1)))
            let card = try #require(Card(json: arg(2)))
            let q = try arg(3).decode(as: SessionQuestion.self)
            return try encodeToJSONValue(WriteFlow.questionInfo(termLang: termLang, defLang: defLang, card: card, question: q))
        case "gradeQuestion":
            let s = try set(0)
            let info = try question(s, arg(1).stringValue ?? "", arg(2).stringValue ?? "")
            let r = WriteFlow.gradeQuestion(
                set: s, question: info, given: arg(3).stringValue ?? "",
                tolerance: GradingParityTests.tolerance(mask: arg(4).integerValue ?? 0))
            return .object(["result": try encodeToJSONValue(r.result), "matchedCard": r.matchedCard.map { .string($0.id) } ?? .null])
        case "copyAccepted":
            let s = try set(0)
            let info = try question(s, arg(1).stringValue ?? "", arg(2).stringValue ?? "")
            return .bool(
                WriteFlow.copyAccepted(
                    arg(3).stringValue, question: info, tolerance: GradingParityTests.tolerance(mask: arg(4).integerValue ?? 0)))
        case "gradeQuestionOrphan":
            let s = try #require(ref.sets["personen"])
            var info = try question(s, arg(0).stringValue ?? "", "term")
            info.cardId = "gone"
            let r = WriteFlow.gradeQuestion(set: s, question: info, given: arg(1).stringValue ?? "", tolerance: .default)
            #expect(r.matchedCard == nil)
            return try encodeToJSONValue(r.result)
        case "diff":
            let given = arg(0).stringValue ?? ""
            let expected = arg(1).stringValue ?? ""
            let l = lang(arg(2))
            let closest = WriteFlow.closestDiff(given: given, expected: expected, lang: l)
            let view = WriteFlow.answerDiff(given: given, expected: expected, lang: l)
            return .object(["closest": try encodeToJSONValue(closest), "view": try view.map(encodeToJSONValue) ?? .null])
        case "pendingFeedback":
            let r = WriteFlow.pendingFeedback(try session(0), json: arg(1))
            return try r.map(encodeToJSONValue) ?? .null
        case "resumeGrid":
            let s = try session(0)
            var resume: [JSONValue] = []
            var results: [JSONValue] = []
            for forceNew in [false, true] {
                for subset in [nil, StudySubset.all, .starred, .missed, .learning] {
                    resume.append(.bool(WriteFlow.canResume(s, forceNew: forceNew, subset: subset)))
                    for marker in [nil, s.startedAt, s.startedAt + 1] {
                        results.append(
                            .bool(WriteFlow.canShowResults(s, forceNew: forceNew, subset: subset, marker: marker)))
                    }
                }
            }
            return .object(["resume": .array(resume), "results": .array(results)])
        case "compactDuration":
            return try encodeToJSONValue(WriteFlow.compactDuration(arg(0).numberValue ?? .nan))
        case "charColumns":
            return .number(Double(WriteFlow.charColumns(arg(0).numberValue ?? .nan, arg(1).numberValue ?? .nan)))
        default:
            return nil
        }
    }

    @Test("every reference case matches the web app")
    func referenceCases() throws {
        let ref = try #require(Self.reference)
        #expect(ref.sets["user"]?.cards.count == 52)
        #expect(ref.cases.count > 1500)
        var failed = 0
        var byFn: [String: Int] = [:]
        for (i, c) in ref.cases.enumerated() {
            let fn = c["fn"]?.stringValue ?? "?"
            let args = c["args"]?.arrayValue ?? []
            let actual = try #require(try Self.run(fn, args, ref), "unknown fn \(fn)")
            let ok = assertParity(actual, c["out"] ?? .null, "\(fn)#\(i)", args: args)
            byFn[fn, default: 0] += 1
            if !ok { failed += 1 }
            if failed > 25 { break }
        }
        #expect(failed == 0)
        // Every kind of case is present.
        #expect(
            Set(byFn.keys) == [
                "questionInfo", "gradeQuestion", "copyAccepted", "gradeQuestionOrphan", "diff", "pendingFeedback",
                "resumeGrid", "compactDuration", "charColumns",
            ])
    }

    @Test("the reference covers synonyms, plain diffs, pending misses and resumable sessions")
    func referenceCoverage() throws {
        let ref = try #require(Self.reference)
        let outs = { (fn: String) in ref.cases.filter { $0["fn"]?.stringValue == fn }.map { $0["out"] ?? .null } }
        #expect(outs("gradeQuestion").contains { $0["matchedCard"]?.stringValue != nil })
        #expect(outs("diff").contains { $0["view"] == .null })
        #expect(outs("diff").contains { $0["view"]?.arrayValue != nil })
        #expect(outs("pendingFeedback").contains { $0 != .null })
        #expect(outs("resumeGrid").contains { $0["resume"]?.arrayValue?.contains(.bool(true)) == true })
        #expect(outs("resumeGrid").contains { $0["results"]?.arrayValue?.contains(.bool(true)) == true })
    }
}
