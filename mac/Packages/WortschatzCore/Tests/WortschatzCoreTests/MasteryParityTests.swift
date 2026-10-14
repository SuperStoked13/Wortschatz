import Testing
import WortschatzCore

@Suite("Parity: mastery.js")
struct MasteryParityTests {
    /// JS accepts any value: objects become (normalised) progress, everything else is "no progress".
    static func progress(_ v: JSONValue) -> CardProgress? { CardProgress(json: v) }

    /// `isObject(map) ? map : {}` with non-object entries dropped (they count as "new" in JS).
    static func progressMap(_ v: JSONValue) -> ProgressMap? {
        guard let o = v.objectValue else { return nil }
        return o.compactMapValues { CardProgress(json: $0) }
    }

    @Test("Mastery matches src/core/mastery.js on every fixture case")
    func fixture() throws {
        try runParity("mastery") { c in
            switch c.fn {
            case "MASTERY_STREAK":
                return .number(Double(Mastery.MASTERY_STREAK))
            case "normalizeProgress":
                return try encodeToJSONValue(Mastery.normalizeProgress(Self.progress(c.arg(0))))
            case "cardStatus":
                return .string(Mastery.cardStatus(Self.progress(c.arg(0))).rawValue)
            case "setProgress":
                let set = VocabSet(json: c.arg(0))
                return try encodeToJSONValue(Mastery.setProgress(set, Self.progressMap(c.arg(1))))
            case "studyStreak":
                let activity: Activity? = c.arg(0).isNull ? nil : try c.decode(0, as: Activity.self)
                return try encodeToJSONValue(Mastery.studyStreak(activity, now: try c.double(1), timeZone: zurich))
            case "applyAnswer":
                return try encodeToJSONValue(
                    Mastery.applyAnswer(Self.progress(c.arg(0)), correct: try c.bool(1), at: try c.double(2)))
            case "applyOverride":
                return try encodeToJSONValue(Mastery.applyOverride(Self.progress(c.arg(0))))
            case "sequence":
                var p: CardProgress?
                var out: [JSONValue] = []
                for op in c.arg(0).arrayValue ?? [] {
                    if op["override"] == .bool(true) {
                        p = Mastery.applyOverride(p)
                    } else {
                        p = Mastery.applyAnswer(p, correct: op["correct"]?.boolValue ?? false, at: op["at"]?.numberValue ?? 0)
                    }
                    out.append(["progress": try encodeToJSONValue(p), "status": .string(Mastery.cardStatus(p).rawValue)])
                }
                return .array(out)
            default:
                return nil
            }
        }
    }
}
