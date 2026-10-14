import Testing
import WortschatzCore

@Suite("Parity: lib/time.js")
struct TimeParityTests {
    @Test("TimeUtil matches src/lib/time.js (TZ=Europe/Zurich)")
    func fixture() throws {
        try runParity("time") { c in
            switch c.fn {
            case "dateKey":
                return .string(TimeUtil.dateKey(try c.double(0), timeZone: zurich))
            case "formatDate":
                return .string(TimeUtil.formatDate(c.optionalDouble(0), timeZone: zurich))
            case "calendarDaysBetween":
                return .number(Double(TimeUtil.calendarDaysBetween(try c.double(0), try c.double(1), timeZone: zurich)))
            case "relativeTime":
                return .string(TimeUtil.relativeTime(c.optionalDouble(0), now: try c.double(1), timeZone: zurich))
            case "formatDuration":
                return .string(TimeUtil.formatDuration(try c.double(0)))
            case "localTimestamp":
                return .number(TimeUtil.localTimestamp(
                    year: try c.int(0), month: try c.int(1), day: try c.int(2), hour: try c.int(3),
                    minute: try c.int(4), second: try c.int(5), timeZone: zurich))
            default:
                return nil
            }
        }
    }
}
