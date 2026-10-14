import Foundation
import Testing
import WortschatzCore

/// Replays Fixtures/session.json (mac/Parity/gen-session.js): scripted Write sessions compared
/// with src/core/session.js snapshot by snapshot (state, current, counters, roundSummary,
/// isRoundOver, isFinished, finalStats after creation and after every action).
@Suite("Parity: session.js")
struct WriteSessionParityTests {
    @Test("WriteSession matches src/core/session.js after every scripted action")
    func fixture() throws {
        try runParity("session") { c in
            switch c.fn {
            case "scenario": try Self.scenario(c)
            case "restore": try Self.restore(c)
            default: nil
            }
        }
    }

    /// Every state the JS produced decodes strictly, survives `copyState` unchanged and encodes
    /// back to the same JSON.
    @Test("JS session states round-trip through SessionState")
    func roundTrip() throws {
        let doc = try Fixtures.load("session")
        var checked = 0
        for c in doc.cases {
            for (step, snap) in (c.out.arrayValue ?? []).enumerated() {
                guard let json = snap["state"] else {
                    Issue.record("\(c.id) step \(step): snapshot without state")
                    continue
                }
                let id = "\(c.id) step \(step)"
                let strict = try json.decode(as: SessionState.self)
                let repaired = WriteSession.copyState(json)
                #expect(strict == repaired, "\(id): strict decoding differs from copyState")
                #expect(WriteSession.copyState(strict) == strict, "\(id): copyState is not idempotent")
                assertParity(try encodeToJSONValue(repaired), json, id)
                checked += 1
            }
        }
        #expect(checked > 3000)
    }

    // MARK: Replay

    static func scenario(_ c: ParityCase) throws -> JSONValue {
        let options = c.arg(1).objectValue ?? [:]
        let create = c.arg(2)
        let rng = mulberry32(seed: create["seed"]?.integerValue ?? 0)
        var s = WriteSession.createSession(
            cards(c.arg(0)),
            answerWith: options["answerWith"]?.stringValue.flatMap(AnswerWith.init(rawValue:)) ?? .term,
            shuffle: options["shuffle"] != .bool(false), subset: StudySubset(json: create["subset"] ?? .null),
            rng: rng, now: time(create["now"]), progress: progress(create["progress"]))
        var out = [try snapshot(s)]
        for action in c.arg(3).arrayValue ?? [] {
            s = try apply(action, to: s, rng: rng, caseID: c.id)
            out.append(try snapshot(s))
        }
        return .array(out)
    }

    static func restore(_ c: ParityCase) throws -> JSONValue {
        let rng = mulberry32(seed: try c.int(1))
        var s = WriteSession.copyState(c.arg(0))
        var out = [try snapshot(s)]
        for action in c.arg(2).arrayValue ?? [] {
            s = try apply(action, to: s, rng: rng, caseID: c.id)
            out.append(try snapshot(s))
        }
        return .array(out)
    }

    static func apply(_ action: JSONValue, to s: SessionState, rng: @escaping RNG, caseID: String) throws
        -> SessionState
    {
        let now = time(action["now"])
        switch action["op"]?.stringValue {
        case "answer":
            return WriteSession.answer(s, correct: action["correct"] == .bool(true), now: now)
        case "override":
            return WriteSession.override(s, qid: action["qid"]?.stringValue ?? "", now: now)
        case "nextRound":
            let seeded = action["seed"]?.integerValue.map { mulberry32(seed: $0) }
            return WriteSession.nextRound(s, rng: seeded ?? rng, now: now)
        case "removeCard":
            return WriteSession.removeCard(s, cardId: action["cardId"]?.stringValue ?? "", now: now)
        case "tick":
            return WriteSession.tick(s, now: now)
        default:
            throw ReplayError.unknownAction(caseID, action)
        }
    }

    static func snapshot(_ s: SessionState) throws -> JSONValue {
        [
            "state": try encodeToJSONValue(s),
            "current": try WriteSession.current(s).map { try encodeToJSONValue($0) } ?? .null,
            "counters": try encodeToJSONValue(WriteSession.counters(s)),
            "roundSummary": try encodeToJSONValue(WriteSession.roundSummary(s)),
            "isRoundOver": .bool(WriteSession.isRoundOver(s)),
            "isFinished": .bool(WriteSession.isFinished(s)),
            "finalStats": try encodeToJSONValue(WriteSession.finalStats(s)),
        ]
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

    /// The cards as `createSession` reads them: entries that are not objects or have no id
    /// (`null`/`''`) are dropped, ids are stringified like `String(raw.id)`, non-string sides
    /// count as empty and only `starred === true` stars a card.
    static func cards(_ v: JSONValue) -> [Card] {
        (v.arrayValue ?? []).compactMap { raw in
            guard let o = raw.objectValue, let id = o["id"], id != .null, id != .string("") else { return nil }
            return Card(
                id: jsString(id), term: o["term"]?.stringValue ?? "", definition: o["definition"]?.stringValue ?? "",
                starred: o["starred"] == .bool(true))
        }
    }

    /// `progress[card.id]` as the subsets read it: non-object maps are empty, non-object entries
    /// count as "no progress".
    static func progress(_ v: JSONValue?) -> ProgressMap {
        (v?.objectValue ?? [:]).compactMapValues { CardProgress(json: $0) }
    }

    /// JS `String(v)` for the id values the generator uses.
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
