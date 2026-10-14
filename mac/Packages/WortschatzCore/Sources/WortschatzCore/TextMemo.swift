import Foundation

/// Remembers the results of a pure text function (normalising, splitting alternatives), so the
/// texts of a set's cards are worked out once instead of once per question: building a Learn
/// round compares every question with every card of the set, which took ~170 ms for 500 cards.
///
/// Keys are the exact Unicode scalars (`String ==` would treat NFC and NFD spellings as equal).
/// Thread-safe; it forgets everything once it holds `limit` texts.
final class TextMemo<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Grading.JSText: Value] = [:]
    private let limit: Int

    init(limit: Int = 50_000) {
        self.limit = limit
    }

    /// `compute(text)`, computed once per distinct text.
    func value(for text: String, _ compute: (String) -> Value) -> Value {
        let key = Grading.JSText(text)
        if let value = lock.withLock({ values[key] }) { return value }
        let value = compute(text)
        lock.withLock {
            if values.count >= limit { values.removeAll(keepingCapacity: true) }
            values[key] = value
        }
        return value
    }
}
