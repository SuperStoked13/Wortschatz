import AppKit
import XCTest

/// The user's own list (tests/fixtures/user-example.txt, bundled with the tests): 52 French →
/// German pairs on alternating lines, separated by blank lines.
struct UserList {
    /// The file as the user pastes it.
    let text: String
    /// (term, definition) in file order.
    let pairs: [(term: String, definition: String)]

    static let setTitle = "Unité 3 – Les personnes"

    static func load() throws -> UserList {
        let url = try XCTUnwrap(
            Bundle(for: WortschatzUITests.self).url(forResource: "user-example", withExtension: "txt"),
            "user-example.txt fehlt im Test-Bundle")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let pairs = stride(from: 0, to: lines.count - 1, by: 2).map { (term: lines[$0], definition: lines[$0 + 1]) }
        return UserList(text: text, pairs: pairs)
    }

    /// Every answer that belongs to a prompt, whichever side is asked ("das Gesicht" →
    /// "le visage", "la figure").
    func answers(for prompt: String) -> [String] {
        pairs.compactMap { pair in
            if pair.term == prompt { return pair.definition }
            if pair.definition == prompt { return pair.term }
            return nil
        }
    }

    /// The prompt text inside an accessibility label such as "Deutsch: der Herr" (the card's
    /// language comes first) or the plain text.
    func prompt(in label: String) -> String? {
        if !answers(for: label).isEmpty { return label }
        guard let colon = label.range(of: ": ") else { return nil }
        let text = String(label[colon.upperBound...])
        return answers(for: text).isEmpty ? nil : text
    }
}

/// Puts a text on the general pasteboard for ⌘V and gives the previous text back afterwards.
@MainActor
final class PasteboardSwap {
    private let previous: String?

    init(_ text: String) {
        let pasteboard = NSPasteboard.general
        previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let previous { pasteboard.setString(previous, forType: .string) }
    }
}

@MainActor
extension XCUIApplication {
    /// The DEBUG app with launch arguments (sample data, see `AppModel.launch`), without window
    /// restoration from an earlier run, in German (the tests look for German texts, whatever
    /// language the Mac has).
    static func wortschatz(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(de)", "-AppleLocale", "de_CH"]
        return app
    }

    /// The single element with this accessibility identifier, of any type.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// How many elements carry this identifier (two while a transition still shows the old one).
    func count(of identifier: String) -> Int {
        descendants(matching: .any).matching(identifier: identifier).count
    }

    /// A text whose label or value starts with `prefix`.
    func text(startingWith prefix: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix)).firstMatch
    }

    /// A text whose label or value contains `part`.
    func text(containing part: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", part, part)).firstMatch
    }

    func pressReturn() {
        typeKey(.return, modifierFlags: [])
    }

    /// The study screens' primary button (the bar's last button, the one Return triggers);
    /// nil while Return does nothing (a multiple-choice question without highlight).
    func primaryLabel(_ identifier: String) -> String? {
        // One snapshot rather than `exists` and then `label`: the button can go away in between
        // (auto-advance), and a failed `label` lookup fails the test.
        (try? buttons[identifier].snapshot())?.label
    }
}

/// Polls `condition` until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: TimeInterval, poll: TimeInterval = 0.15, _ condition: () -> Bool) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while true {
        if condition() { return true }
        if Date.now >= deadline { return false }
        Thread.sleep(forTimeInterval: poll)
    }
}

/// The value of a text field or text view as a string.
@MainActor
func textValue(_ element: XCUIElement) -> String {
    element.value as? String ?? ""
}

/// Drives the Learn screen like a learner: digits 1-4 for multiple choice, typing and Return.
@MainActor
struct LearnDriver {
    let app: XCUIApplication
    let list: UserList

    /// A multiple-choice question that waits for an answer: its prompt and the four choices.
    struct ChoiceQuestion {
        let prompt: String
        let choices: [String]
    }

    /// The multiple-choice question on screen once it settled (one prompt, four idle tiles), nil
    /// when another step is showing.
    func choiceQuestion() -> ChoiceQuestion? {
        guard app.count(of: "learn-prompt") == 1 else { return nil }
        // Snapshots rather than live reads: the screen can move on between two lookups, and a
        // failed lookup fails the test.
        var choices: [String] = []
        for number in 1...4 {
            guard app.count(of: "choice-\(number)") == 1, let tile = try? app.buttons["choice-\(number)"].snapshot(),
                (tile.value as? String) == "Antwort \(number)"
            else { return nil }
            choices.append(tile.label)
        }
        guard let prompt = currentPrompt() else { return nil }
        return ChoiceQuestion(prompt: prompt, choices: choices)
    }

    /// The prompt of the question on screen (nil while none or two are shown).
    func currentPrompt() -> String? {
        guard app.count(of: "learn-prompt") == 1, let element = try? app.element("learn-prompt").snapshot() else {
            return nil
        }
        for candidate in [element.label, element.value as? String ?? ""] {
            if let prompt = list.prompt(in: candidate) { return prompt }
        }
        return nil
    }

    /// Answers the multiple-choice question correctly with its number key.
    func answerCorrectly(_ question: ChoiceQuestion) {
        let answers = list.answers(for: question.prompt)
        guard let index = question.choices.firstIndex(where: answers.contains) else {
            XCTFail("Keine richtige Antwort für «\(question.prompt)» unter \(question.choices)")
            return
        }
        app.typeKey("\(index + 1)", modifierFlags: [])
    }

    /// The step the bar's Return button names: "Weiter" after an answer, "Weiter zu Runde N" at
    /// the checkpoint, "Antworten" for a written question (nil: Return does nothing now).
    var primary: String? { app.primaryLabel("learn-primary") }

    var isAtCheckpoint: Bool { primary?.contains("Weiter zu Runde") == true }

    /// Feedback after an answer ("Weiter", not "Weiter zu Runde N").
    var isShowingFeedback: Bool {
        guard let primary else { return false }
        return primary.hasPrefix("Weiter") && !primary.contains("zu Runde")
    }

    /// Answers multiple-choice questions correctly (number keys only) until Return would start
    /// the next round, or until `limit` answers were given. Returns the prompts asked.
    @discardableResult
    func playChoices(limit: Int = .max, timeout: TimeInterval = 120) -> [String] {
        var asked: [String] = []
        let deadline = Date.now.addingTimeInterval(timeout)
        while asked.count < limit, Date.now < deadline {
            if isAtCheckpoint { break }
            if let question = choiceQuestion() {
                answerCorrectly(question)
                asked.append(question.prompt)
                // The tiles turn green: the answer arrived (one key = one transition).
                XCTAssertTrue(
                    waitUntil(timeout: 5) { choiceQuestion()?.prompt != question.prompt },
                    "Die Zifferntaste beantwortet «\(question.prompt)»")
                continue
            }
            if isShowingFeedback {
                // A correct choice moves on by itself after 0.9 s (to the next question or the
                // checkpoint); Return only if it does not, so no Return can skip the checkpoint.
                if !waitUntil(timeout: 3, { !isShowingFeedback }) {
                    app.pressReturn()
                }
                continue
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return asked
    }
}
