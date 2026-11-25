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

/// The copy step ("Richtige Antwort abtippen", Lernen and Schreiben) continues by itself, after
/// a short beat (`advanceMs`), once the answer is typed out: accepted with the same tolerance as
/// an answer to the question ("le collègue" for "le/la collègue"), unless what is typed is only
/// the start of the answer as shown ("le cerveau" of "le cerveau, les cerveaux", "Aussenminister"
/// of "Aussenminister(in)"). Those wait for Return, so whoever copies the whole answer is never
/// cut off halfway and the rest of it never lands in the next question.
public enum CopyStep {
  /// The beat between the copy being typed out and the next question: the finished word shows
  /// for a moment instead of vanishing with its last letter. Return skips it.
  public static let advanceMs = 400

  public static func isTypedOut(_ value: String, expected: String, tolerance: Tolerance, lang: Lang?) -> Bool {
    let result = Grading.grade(given: value, expected: expected, tolerance: tolerance, lang: lang)
    guard result.correct else { return false }
    if result.exact { return true }
    let typed = fold(value)
    let shown = fold(expected)
    return typed == shown || !shown.hasPrefix(typed)
  }

  /// Upper/lower case, spacing, accents and ligatures do not matter ("l'oeil" starts "l'œil").
  private static func fold(_ text: String) -> String {
    TextNormalizer.stripDiacritics(TextNormalizer.foldScripts(TextNormalizer.normalizeBasic(text))).lowercased()
  }
}
