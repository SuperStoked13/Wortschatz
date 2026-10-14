import Foundation
import Testing
import WortschatzCore

/// Replays Fixtures/learn.json (mac/Parity/gen-learn.js): scripted Learn sessions compared with
/// src/core/learn.js snapshot by snapshot (state, current, counts, checkpoint, isRoundOver,
/// isFinished, finalStats and matchesProgress after creation and after every action), plus
/// buildChoices and stageFromProgress.
@Suite("Parity: learn.js")
struct LearnEngineParityTests {
    static let slices = 8
    /// Loaded once and shared by the tests (the fixture is about 10 MB).
    private static let fixture = Result { try Fixtures.load("learn") }

    /// The Swift result of one case (nil for an unknown fn).
    static func run(_ c: ParityCase) throws -> JSONValue? {
        switch c.fn {
        case "scenario": try scenario(c)
        case "restore": try restore(c)
        case "buildChoices": try buildChoices(c)
        case "stageFromProgress": .number(Double(LearnEngine.stageFromProgress(CardProgress(json: c.arg(0)))))
        default: nil
        }
    }

    @Test("LearnEngine matches src/core/learn.js after every scripted action", arguments: 0..<slices)
    func fixture(slice: Int) throws {
        let doc = try Self.fixture.get()
        var failed = 0
        var unknown: Set<String> = []
        var byFn: [String: Int] = [:]
        for (index, c) in doc.cases.enumerated() where index % Self.slices == slice {
            let actual: JSONValue?
            do {
                actual = try Self.run(c)
            } catch {
                failed += 1
                if failed <= 10 { Issue.record("\(c.id) threw: \(error)") }
                continue
            }
            guard let actual else {
                unknown.insert(c.fn)
                continue
            }
            let diffs = ParityDiff.differences(expected: c.out, actual: actual)
            if diffs.isEmpty { continue }
            failed += 1
            byFn[c.fn, default: 0] += 1
            if failed <= 10 {
                Issue.record(Comment(rawValue: "Parity mismatch \(c.id)\n  " + diffs.joined(separator: "\n  ")
                    + "\n  args: " + ParityDiff.describe(.array(c.args), max: 600)))
            }
        }
        #expect(unknown.isEmpty, "unhandled fns \(unknown.sorted())")
        let summary = byFn.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        #expect(failed == 0, "slice \(slice): \(failed) cases differ (\(summary))")
    }

    /// The fixture is complete, large and varied enough to mean something.
    @Test("The fixture covers every function and many steps")
    func coverage() throws {
        let doc = try Self.fixture.get()
        #expect(doc.module == "learn")
        #expect(doc.count == doc.cases.count)
        var byFn: [String: Int] = [:]
        var snapshots = 0
        var ops: [String: Int] = [:]
        for c in doc.cases {
            byFn[c.fn, default: 0] += 1
            snapshots += c.out.arrayValue?.count ?? 0
            let actions = c.fn == "scenario" ? c.arg(3) : c.fn == "restore" ? c.arg(4) : .null
            for a in actions.arrayValue ?? [] { ops[a["op"]?.stringValue ?? "?", default: 0] += 1 }
        }
        #expect(Set(byFn.keys) == ["scenario", "restore", "buildChoices", "stageFromProgress"])
        #expect((byFn["scenario"] ?? 0) > 400)
        #expect((byFn["restore"] ?? 0) > 150)
        #expect((byFn["buildChoices"] ?? 0) > 400)
        #expect(snapshots > 5000)
        for op in ["answer", "override", "nextRound", "removeCard", "tick", "sync", "write", "reset"] {
            #expect((ops[op] ?? 0) > 20, "few \(op) actions")
        }
    }

    /// Every state the JS produced decodes strictly, survives `copyState` unchanged (typed and
    /// JSON) and encodes back to the same JSON.
    @Test("JS learn states round-trip through LearnState")
    func roundTrip() throws {
        let doc = try Self.fixture.get()
        var checked = 0
        for c in doc.cases where c.fn == "scenario" || c.fn == "restore" {
            for (step, snap) in (c.out.arrayValue ?? []).enumerated() {
                guard let json = snap["state"] else { continue }
                let id = "\(c.id) step \(step)"
                let strict = try json.decode(as: LearnState.self)
                let repaired = LearnEngine.copyState(json)
                #expect(strict == repaired, "\(id): strict decoding differs from copyState")
                #expect(LearnEngine.copyState(strict) == strict, "\(id): copyState is not idempotent")
                assertParity(try encodeToJSONValue(repaired), json, id)
                checked += 1
            }
        }
        #expect(checked > 1500)
    }

    // MARK: Replay

    static let T0: Double = 1_760_000_000_000

    /// A scripted run: the session, the set's cards and the tracked progress (what the store
    /// would hold after `recordAnswer` / `overrideLastAnswer`).
    struct Run {
        var s: LearnState
        var cards: [Card]?
        var progress: ProgressMap
        let rng: RNG
        let caseID: String

        mutating func apply(_ a: JSONValue) throws -> JSONValue {
            let now = LearnEngineParityTests.time(a["now"])
            let op = a["op"]?.stringValue ?? ""
            switch op {
            case "answer":
                let correct = a["correct"] == .bool(true)
                if let q = LearnEngine.current(s) {
                    progress[q.cardId] = Mastery.applyAnswer(progress[q.cardId], correct: correct, at: T0)
                }
                s = LearnEngine.answer(s, correct: correct, now: now)
            case "override":
                if let l = LearnEngine.copyState(s).last, !l.correct, let prev = progress[l.cardId],
                    prev.lastResult == .incorrect
                {
                    progress[l.cardId] = Mastery.applyOverride(prev)
                }
                s = LearnEngine.override(s, now: now)
            case "nextRound":
                var list = cards
                if let value = a["cards"] {
                    list = LearnEngineParityTests.cards(value)
                    if value.isArray { cards = list }
                }
                s = LearnEngine.nextRound(s, cards: list, rng: rng(for: a), now: now)
            case "removeCard":
                let cardId = a["cardId"]?.stringValue ?? ""
                if let value = a["cards"] {
                    var list: [Card]?
                    if value == .string("set") {
                        list = cards
                    } else {
                        list = LearnEngineParityTests.cards(value)
                        if value.isArray { cards = list }
                    }
                    s = LearnEngine.removeCard(s, cardId: cardId, now: now, cards: list, rng: rng(for: a))
                } else {
                    s = LearnEngine.removeCard(s, cardId: cardId, now: now)
                }
            case "tick":
                s = LearnEngine.tick(s, now: now)
            case "sync":
                if let value = a["progress"] { progress = LearnEngineParityTests.progress(value) }
                s = LearnEngine.syncProgress(s, progress: progress, now: now)
            case "write":
                let cardId = a["cardId"]?.stringValue ?? ""
                progress[cardId] = Mastery.applyAnswer(progress[cardId], correct: a["correct"] == .bool(true), at: T0)
                return ["matches": .bool(LearnEngine.matchesProgress(s, progress: progress))]
            case "reset":
                if let ids = a["cardIds"]?.arrayValue {
                    for id in ids { progress[id.stringValue ?? ""] = nil }
                } else {
                    progress = [:]
                }
                return ["matches": .bool(LearnEngine.matchesProgress(s, progress: progress))]
            default:
                throw ReplayError.unknownAction(caseID, a)
            }
            return try LearnEngineParityTests.snapshot(s, progress, lite: ["answer", "override", "tick"].contains(op))
        }

        /// The run's shared rng, or a fresh mulberry32 when the action carries its own seed.
        func rng(for a: JSONValue) -> RNG {
            if let seed = a["seed"]?.integerValue { return mulberry32(seed: seed) }
            return rng
        }
    }

    static func scenario(_ c: ParityCase) throws -> JSONValue {
        let options = c.arg(1).objectValue ?? [:]
        let create = c.arg(2)
        let rng = mulberry32(seed: create["seed"]?.integerValue ?? 0)
        let cards = cards(c.arg(0))
        let progress = progress(create["progress"])
        let s = LearnEngine.createLearn(
            cards ?? [], answerWith: options["answerWith"]?.stringValue.flatMap(AnswerWith.init(rawValue:)) ?? .term,
            learn: LearnOptions(json: options["learn"] ?? .null), subset: StudySubset(json: create["subset"] ?? .null),
            progress: progress, rng: rng, now: time(create["now"]))
        var run = Run(s: s, cards: cards, progress: progress, rng: rng, caseID: c.id)
        var out = [try snapshot(s, progress)]
        for action in c.arg(3).arrayValue ?? [] { out.append(try run.apply(action)) }
        return .array(out)
    }

    static func restore(_ c: ParityCase) throws -> JSONValue {
        let s = LearnEngine.copyState(c.arg(0))
        let progress = progress(c.arg(3))
        var run = Run(s: s, cards: cards(c.arg(1)), progress: progress, rng: mulberry32(seed: try c.int(2)), caseID: c.id)
        var out = [try snapshot(s, progress)]
        for action in c.arg(4).arrayValue ?? [] { out.append(try run.apply(action)) }
        return .array(out)
    }

    static func buildChoices(_ c: ParityCase) throws -> JSONValue {
        let card = c.arg(1)
        let choices = LearnEngine.buildChoices(
            choiceCards(c.arg(0)),
            card: Card(
                id: card["id"].map(jsString) ?? "", term: toStr(card["term"]), definition: toStr(card["definition"])),
            ask: c.arg(2) == .string("definition") ? .definition : .term, rng: mulberry32(seed: try c.int(3)),
            n: c.arg(4).finiteNumber.map { $0 >= 1 ? Int($0.rounded(.down)) : 0 } ?? 0)
        return try encodeToJSONValue(choices)
    }

    /// The JS snapshot of `s`; `lite` (after answer, override, tick) reduces each queued question
    /// to its qid and records checkpoint and finalStats only once the round is over.
    static func snapshot(_ s: LearnState, _ progress: ProgressMap, lite: Bool = false) throws -> JSONValue {
        var state = try encodeToJSONValue(LearnEngine.tick(s, now: .nan))
        let over = LearnEngine.isRoundOver(s)
        if lite, case var .object(o) = state {
            o["queue"] = .array((o["queue"]?.arrayValue ?? []).map { $0["qid"] ?? .null })
            state = .object(o)
        }
        var out: [String: JSONValue] = [
            lite ? "stateLite" : "state": state,
            "current": try LearnEngine.current(s).map { try encodeToJSONValue($0) } ?? .null,
            "counts": try encodeToJSONValue(LearnEngine.counts(s)),
            "isRoundOver": .bool(over),
            "isFinished": .bool(LearnEngine.isFinished(s)),
            "matches": .bool(LearnEngine.matchesProgress(s, progress: progress)),
        ]
        if !lite || over {
            out["checkpoint"] = try encodeToJSONValue(LearnEngine.checkpoint(s))
            out["finalStats"] = try encodeToJSONValue(LearnEngine.finalStats(s))
        }
        return .object(out)
    }

    enum ReplayError: Error, CustomStringConvertible {
        case unknownAction(String, JSONValue)

        var description: String {
            switch self {
            case let .unknownAction(id, action): "\(id): unknown action \(ParityDiff.describe(action))"
            }
        }
    }

    // MARK: JS arguments → typed API

    /// A timestamp argument: JS `null` (not a number) maps to NaN, which the engine treats the
    /// same way (the clock is left alone).
    static func time(_ v: JSONValue?) -> Double { v?.numberValue ?? .nan }

    /// Scenario cards as createLearn and nextRound read them (nil for a non-array): entries that
    /// are not objects or have no id (`null`/`''`) are dropped, ids are stringified like
    /// `String(raw.id)`, non-string sides count as empty (such a card is never askable) and only
    /// `starred === true` stars a card. Repeated ids stay: the engine keeps the first one.
    static func cards(_ v: JSONValue) -> [Card]? {
        guard let list = v.arrayValue else { return nil }
        return list.compactMap { raw in
            guard let o = raw.objectValue, let id = o["id"], id != .null, id != .string("") else { return nil }
            return Card(
                id: jsString(id), term: o["term"]?.stringValue ?? "", definition: o["definition"]?.stringValue ?? "",
                starred: o["starred"] == .bool(true))
        }
    }

    /// buildChoices cards: its distractors come from every card with an id, read with
    /// answerSide's `toStr` (`String(v)`, null → '').
    static func choiceCards(_ v: JSONValue) -> [Card] {
        (v.arrayValue ?? []).compactMap { raw in
            guard let o = raw.objectValue, let id = o["id"], id != .null, id != .string("") else { return nil }
            return Card(id: jsString(id), term: toStr(o["term"]), definition: toStr(o["definition"]))
        }
    }

    /// `progress[card.id]` as the engine reads it: non-object maps are empty, non-object entries
    /// count as "no progress".
    static func progress(_ v: JSONValue?) -> ProgressMap {
        (v?.objectValue ?? [:]).compactMapValues { CardProgress(json: $0) }
    }

    /// `toStr` of synonyms.js: null/undefined → '', anything else `String(v)`.
    static func toStr(_ v: JSONValue?) -> String {
        guard let v, v != .null else { return "" }
        return jsString(v)
    }

    /// JS `String(v)`.
    static func jsString(_ v: JSONValue) -> String {
        switch v {
        case .null: "null"
        case let .bool(b): b ? "true" : "false"
        case let .number(n): JSCompat.numberToString(n)
        case let .string(s): s
        case let .array(a): a.map { $0 == .null ? "" : jsString($0) }.joined(separator: ",")
        case .object: "[object Object]"
        }
    }
}
