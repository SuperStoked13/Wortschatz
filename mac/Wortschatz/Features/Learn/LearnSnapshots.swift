#if DEBUG
import SwiftUI
import WortschatzCore

/// Snapshot scenes of the Learn screen (`--render-snapshots <dir> --snapshot-filter learn-`).
/// Each scene plays the real `LearnFlow` on the in-memory sample library (the user's 52 pairs)
/// with a seeded random source and a scripted clock, so the states are the app's own.
/// The window's toolbar is not part of the capture (borderless snapshot window).
final class LearnSnapshots: SnapshotCatalog {
    /// The main window's content below the toolbar.
    static let size = CGSize(width: 1240, height: 748)
    /// The smallest window (980×640) below the toolbar.
    static let compactSize = CGSize(width: 980, height: 588)

    override class var scenes: [SnapshotScene] {
        LearnSnapshotScenario.allCases.map { scenario in
            SnapshotScene("learn-\(scenario.rawValue)", sizes: scenario.sizes) {
                LearnSnapshotHost(scenario)
            }
        } + [
            SnapshotScene("learn-options-panel", size: CGSize(width: 440, height: 660)) {
                LearnSnapshotPanels.options()
            },
            SnapshotScene("learn-card-editor", size: CGSize(width: 480, height: 300)) {
                LearnSnapshotPanels.cardEditor()
            },
        ]
    }
}

/// The states rendered by `LearnSnapshots`.
enum LearnSnapshotScenario: String, CaseIterable {
    case mcIdle = "mc-idle"
    case mcHighlight = "mc-highlight"
    case mcCorrect = "mc-correct"
    case mcWrong = "mc-wrong"
    case writtenIdle = "written-idle"
    case writtenCorrect = "written-correct"
    case writtenWrong = "written-wrong"
    case writtenCopy = "written-copy"
    case checkpoint = "checkpoint"
    case finish = "finish"
    case allMastered = "all-mastered"

    var sizes: [CGSize] {
        switch self {
        case .mcWrong, .writtenWrong: [LearnSnapshots.size, LearnSnapshots.compactSize]
        default: [LearnSnapshots.size]
        }
    }
}

/// The Learn screen on a scripted controller.
private struct LearnSnapshotHost: View {
    @State private var model: AppModel
    @State private var controller: LearnController

    init(_ scenario: LearnSnapshotScenario) {
        let (model, controller) = LearnSnapshotScript.make(scenario)
        _model = State(initialValue: model)
        _controller = State(initialValue: controller)
    }

    var body: some View {
        LearnScreenContent(controller: controller)
            .environment(model)
            .environment(model.toasts)
    }
}

/// The options popover and the card editor on their own.
@MainActor
private enum LearnSnapshotPanels {
    static func options() -> some View {
        let (model, controller) = LearnSnapshotScript.make(.mcIdle)
        return LearnOptionsPanel(controller: controller)
            .environment(model)
            .background(.background)
    }

    static func cardEditor() -> some View {
        let (_, controller) = LearnSnapshotScript.make(.mcIdle)
        let card = controller.currentCard ?? Card(id: "c", term: "aimable", definition: "freundlich")
        return LearnCardEditor(card: card, termLang: .fr, defLang: .de, onSave: { _ in }, onCancel: {})
            .background(.background)
    }
}

/// Plays the flow into each scenario's state.
@MainActor
private enum LearnSnapshotScript {
    static func make(_ scenario: LearnSnapshotScenario) -> (AppModel, LearnController) {
        let model = SampleLibrary.model(.fresh)
        let store = model.store
        var setID = store.listSets().first?.id ?? ""
        var now = TimeUtil.nowMs() - 20 * 60_000
        do {
            switch scenario {
            case .writtenIdle, .writtenCorrect, .writtenWrong:
                _ = try store.updateStudyOptions(setID, StudyOptionsPatch(learn: LearnOptionsPatch(mc: false)))
            case .writtenCopy:
                _ = try store.updateStudyOptions(
                    setID, StudyOptionsPatch(learn: LearnOptionsPatch(mc: false, retype: true)))
            case .finish, .allMastered:
                let small = try store.createSet(
                    title: "Unité 3 – Les personnes (Auszug)", termLang: .fr, defLang: .de,
                    cards: SampleLibrary.userPairs.prefix(6).map { CardDraft(term: $0.0, definition: $0.1) })
                setID = small.id
                if scenario == .allMastered {
                    for card in small.cards {
                        _ = try store.recordAnswer(setID, card.id, correct: true, at: now)
                        _ = try store.recordAnswer(setID, card.id, correct: true, at: now + 1000)
                    }
                }
            case .mcIdle, .mcHighlight, .mcCorrect, .mcWrong, .checkpoint:
                break
            }
        } catch {
            assertionFailure("Learn snapshot setup: \(error)")
        }
        let clock: () -> Double = {
            now += 1_500
            return now
        }
        let controller = LearnController(
            model: model, request: StudyRequest(setID: setID, mode: .learn, forceNew: true), rng: mulberry32(seed: 11),
            clock: clock, isLive: false)
        controller.activate()
        drive(controller, into: scenario)
        return (model, controller)
    }

    private static func drive(_ c: LearnController, into scenario: LearnSnapshotScenario) {
        switch scenario {
        case .mcIdle, .writtenIdle, .allMastered:
            break
        case .mcHighlight:
            c.send(.key(.arrow(.down)))
            c.send(.key(.arrow(.right)))
        case .mcCorrect:
            c.send(.choose(correctIndex(c) ?? 0))
        case .mcWrong:
            let right = correctIndex(c) ?? 0
            c.send(.choose(right == 0 ? 1 : 0))
        case .writtenCorrect:
            // Answer until a term with an article comes up, then leave the article out.
            for _ in 0..<20 {
                let expected = c.state.question?.expected ?? ""
                if tolerated(expected) != expected { break }
                c.send(.draftChanged(expected))
                c.send(.proceed)
                c.send(.proceed)
            }
            c.send(.draftChanged(tolerated(c.state.question?.expected ?? "")))
            c.send(.proceed)
        case .writtenWrong:
            c.send(.draftChanged(nearMiss(c.state.question?.expected ?? "")))
            c.send(.proceed)
        case .writtenCopy:
            let expected = c.state.question?.expected ?? ""
            c.send(.draftChanged(nearMiss(expected)))
            c.send(.proceed)
            c.send(.draftChanged(String(expected.prefix(max(1, expected.count / 2)))))
        case .checkpoint:
            play(c, until: .checkpoint)
        case .finish:
            play(c, until: .finished)
        }
    }

    /// Answers until `target`: mostly right, every third question wrong (the first round shows
    /// both chips), copying where needed.
    private static func play(_ c: LearnController, until target: LearnFlow.Phase) {
        var asked = 0
        for _ in 0..<400 {
            let state = c.state
            if state.phase == target { return }
            switch state.phase {
            case .question(.mc):
                asked += 1
                let right = correctIndex(c) ?? 0
                c.send(.choose(asked % 3 == 2 ? (right == 0 ? 1 : 0) : right))
            case .question(.written):
                asked += 1
                let expected = state.question?.expected ?? ""
                c.send(.draftChanged(asked % 5 == 3 ? nearMiss(expected) : expected))
                c.send(.proceed)
            case .copy:
                // Typed out as shown, the copy continues by itself.
                c.send(.draftChanged(state.question?.expected ?? ""))
            case .feedback, .checkpoint:
                c.send(.proceed)
            case .finished, .allMastered, .empty:
                return
            }
        }
    }

    private static func correctIndex(_ c: LearnController) -> Int? {
        guard let question = c.state.question else { return nil }
        return question.choices.firstIndex { $0.cardId == question.cardId }
    }

    /// The answer without its leading article ("tête" for "la tête"): right, but not exact.
    private static func tolerated(_ expected: String) -> String {
        for article in ["la ", "le ", "les ", "l'", "l’", "un ", "une "] where expected.hasPrefix(article) {
            return String(expected.dropFirst(article.count))
        }
        return expected
    }

    /// One letter of the last word dropped and one swapped: a near miss with a visible diff.
    private static func nearMiss(_ expected: String) -> String {
        var characters = Array(expected)
        guard characters.count > 4 else { return expected + "e" }
        characters.remove(at: characters.count - 2)
        if let index = characters.indices.dropFirst(3).first(where: { "aeiou".contains(characters[$0]) }) {
            characters[index] = characters[index] == "e" ? "a" : "e"
        }
        return String(characters)
    }
}
#endif
