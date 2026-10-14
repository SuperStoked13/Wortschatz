// Shared vocabulary for the study flow reducers (LearnFlow, WriteFlow).
// Views translate raw key events into `KeyPress` values; the reducers decide
// what each key does in the current phase (spec §4.3 and §6).

public enum Direction: String, Codable, Sendable, Equatable {
  case up, down, left, right
}

public enum KeyInput: Codable, Sendable, Equatable, Hashable {
  case returnKey
  case optionReturn
  case commandReturn
  case escape
  /// Number keys 0–9 (top row or keypad).
  case digit(Int)
  case arrow(Direction)
  /// Any other printable key, as typed (e.g. "r", "?").
  case character(String)
  /// The delete key (⌫, or fn-⌦): removes the last letter typed on a multiple-choice question.
  case deleteBackward
  /// ⌥⌫: removes the last word typed on a multiple-choice question.
  case deleteWordBackward
}

extension KeyInput {
  /// ⌫ and ⌥⌫: held down they keep deleting (their repeats count, unlike other keys').
  public var isDeletion: Bool {
    switch self {
    case .deleteBackward, .deleteWordBackward: true
    default: false
    }
  }
}

public struct KeyPress: Codable, Sendable, Equatable, Hashable {
  public var key: KeyInput
  /// True for auto-repeat events while a key is held; repeats never cause a transition.
  public var isRepeat: Bool

  public init(_ key: KeyInput, isRepeat: Bool = false) {
    self.key = key
    self.isRepeat = isRepeat
  }
}

public enum StudyMode: String, Codable, Sendable, Equatable {
  /// Lernen, Schreiben, Karteikarten (flashcards: sorted by the learner, no answers recorded) and
  /// Prüfung (exam: marked and graded, no answers recorded either).
  case learn, write, flashcards, exam
}

public enum HapticKind: String, Codable, Sendable, Equatable {
  case success, failure
}
