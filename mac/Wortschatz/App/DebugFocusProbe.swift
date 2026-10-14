#if DEBUG
import AppKit
import SwiftUI
import WortschatzCore

/// `--focus-probe <learn|write>` (with `--sample-library fresh`): plays a study session like a
/// learner who only uses the keyboard — the right digit for multiple choice, the right answer
/// plus Return for written questions, Return on checkpoints — and logs for every written question
/// whether the answer field had the keys without a click ("FOCUSPROBE …" on stdout), then quits.
/// Debug builds only; the sample library lives in memory, so no real data is touched.
enum DebugFocusProbe {
    static func scheduleIfRequested(model: AppModel, arguments: [String] = CommandLine.arguments) {
        guard let flag = arguments.firstIndex(of: "--focus-probe"), flag + 1 < arguments.count else { return }
        let mode: StudyMode = arguments[flag + 1] == "write" ? .write : .learn
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            NSApp.activate()
            guard let set = model.store.listSets().first(where: { $0.cards.count >= 4 }) else {
                print("FOCUSPROBE no set")
                exit(2)
            }
            model.study(mode, setID: set.id, forceNew: true)
            try? await Task.sleep(for: .milliseconds(1000))
            var written = 0
            var missed = 0
            for step in 1...60 {
                guard let question = currentQuestion(model: model, set: set, mode: mode) else {
                    press("\r", keyCode: 36)
                    try? await Task.sleep(for: .milliseconds(1100))
                    continue
                }
                if question.type == "mc", let digit = question.choiceIndex {
                    press("\(digit + 1)", keyCode: [18, 19, 20, 21][min(digit, 3)])
                    try? await Task.sleep(for: .milliseconds(1400))
                    continue
                }
                // A written question: a learner starts typing a moment after it appears; the field
                // must have the keys by then.
                try? await Task.sleep(for: .milliseconds(450))
                let responder = NSApp.keyWindow?.firstResponder
                let focused = responder is NSTextView
                if NSApp.keyWindow == nil { print("FOCUSPROBE window not key - test invalid") }
                written += 1
                if !focused { missed += 1 }
                print("FOCUSPROBE step \(step): written «\(question.answer)» fieldFocused=\(focused) responder=\(responder.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
                fflush(stdout)
                if !focused {
                    try? await Task.sleep(for: .milliseconds(1500))
                    let later = NSApp.keyWindow?.firstResponder
                    print("FOCUSPROBE   1.5 s later: fieldFocused=\(later is NSTextView) responder=\(later.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
                    fflush(stdout)
                    break
                }
                for character in question.answer { press(String(character), keyCode: 0) }
                press("\r", keyCode: 36)
                try? await Task.sleep(for: .milliseconds(1500))
                if written >= 8 { break }
            }
            print("FOCUSPROBE RESULT written=\(written) withoutFocus=\(missed)")
            fflush(stdout)
            exit(0)
        }
    }

    private struct Question {
        let type: String
        let answer: String
        let choiceIndex: Int?
    }

    /// The question on screen, read from the saved session (Learn: `queue[0]` of the learn
    /// state; Write: `questions[queue[0]]`).
    private static func currentQuestion(model: AppModel, set: VocabSet, mode: StudyMode) -> Question? {
        let cards = Dictionary(uniqueKeysWithValues: set.cards.map { ($0.id, $0) })
        switch mode {
        case .learn:
            guard let json = model.store.getLearnJSON(set.id), let first = json["queue"]?[0],
                let cardId = first["cardId"]?.stringValue, let card = cards[cardId]
            else { return nil }
            let ask = first["ask"]?.stringValue ?? "term"
            let type = first["type"]?.stringValue ?? "written"
            let choices = first["choices"]?.arrayValue ?? []
            let index = choices.firstIndex { $0["cardId"]?.stringValue == cardId }
            return Question(type: type, answer: ask == "term" ? card.term : card.definition, choiceIndex: index)
        case .write:
            guard let json = model.store.getSessionJSON(set.id), let qid = json["queue"]?[0]?.stringValue,
                let question = json["questions"]?[qid], let cardId = question["cardId"]?.stringValue,
                let card = cards[cardId]
            else { return nil }
            let ask = question["ask"]?.stringValue ?? "term"
            return Question(type: "written", answer: ask == "term" ? card.term : card.definition, choiceIndex: nil)
        case .flashcards, .exam:
            return nil
        }
    }

    private static func press(_ characters: String, keyCode: UInt16) {
        guard let window = NSApp.keyWindow else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
            {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }
}
#endif
