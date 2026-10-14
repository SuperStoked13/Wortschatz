#if DEBUG
import SwiftUI
import WortschatzCore

/// Snapshot scenes of the Write screen (`--render-snapshots <dir> --snapshot-filter write-`).
/// Each scene plays the real `WriteFlow` on the in-memory sample library (the user's 52 pairs)
/// with a seeded random source and a scripted clock, so the states are the app's own.
/// The window's toolbar is not part of the capture (borderless snapshot window); its counters
/// are rendered on their own (`write-toolbar`).
final class WriteSnapshots: SnapshotCatalog {
    /// The main window's content below the toolbar.
    static let size = CGSize(width: 1240, height: 748)
    /// The smallest window (980×640) below the toolbar.
    static let compactSize = CGSize(width: 980, height: 588)

    override class var scenes: [SnapshotScene] {
        WriteSnapshotScenario.allCases.map { scenario in
            SnapshotScene("write-\(scenario.rawValue)", sizes: scenario.sizes) {
                WriteSnapshotHost(scenario)
            }
        } + [
            SnapshotScene("write-toolbar", size: CGSize(width: 760, height: 150)) {
                WriteSnapshotPanels.toolbar()
            },
            SnapshotScene("write-options-panel", size: CGSize(width: 440, height: 700)) {
                WriteSnapshotPanels.options()
            },
            SnapshotScene("write-card-editor", size: CGSize(width: 480, height: 250)) {
                WriteSnapshotPanels.cardEditor()
            },
        ]
    }
}

/// The states rendered by `WriteSnapshots`.
enum WriteSnapshotScenario: String, CaseIterable {
    case question = "question"
    case questionRound2 = "question-round2"
    case correct = "correct"
    case wrong = "wrong"
    case dontKnow = "dont-know"
    case copy = "copy"
    case summary = "summary"
    case results = "results"
    case resultsFlawless = "results-flawless"
    case empty = "empty"
    case resume = "resume"

    var sizes: [CGSize] {
        switch self {
        case .wrong, .copy: [WriteSnapshots.size, WriteSnapshots.compactSize]
        default: [WriteSnapshots.size]
        }
    }
}

/// The Write screen on a scripted controller.
private struct WriteSnapshotHost: View {
    let scenario: WriteSnapshotScenario
    @State private var model: AppModel
    @State private var controller: WriteController

    init(_ scenario: WriteSnapshotScenario) {
        self.scenario = scenario
        let (model, controller) = WriteSnapshotScript.make(scenario)
        _model = State(initialValue: model)
        _controller = State(initialValue: controller)
    }

    var body: some View {
        if scenario == .resume {
            content.toastOverlay(model.toasts)
        } else {
            content
        }
    }

    private var content: some View {
        WriteScreenContent(controller: controller)
            .environment(model)
            .environment(model.toasts)
    }
}

/// The toolbar counters, the options popover and the card editor on their own.
@MainActor
private enum WriteSnapshotPanels {
    static func toolbar() -> some View {
        let counters = WriteSession.Counters(remaining: 38, correct: 12, incorrect: 2, total: 52, round: 1, progress: 12 / 52)
        return VStack(spacing: Spacing.l) {
            WriteToolbarProgress(counters: counters, isCompact: false)
            WriteToolbarProgress(counters: counters, isCompact: true)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
    }

    static func options() -> some View {
        let (model, controller) = WriteSnapshotScript.make(.question)
        return WriteOptionsPanel(controller: controller)
            .environment(model)
            .background(.background)
    }

    static func cardEditor() -> some View {
        let (_, controller) = WriteSnapshotScript.make(.question)
        let card = controller.currentCard ?? Card(id: "c", term: "aimable", definition: "freundlich")
        return WriteCardEditor(card: card, termLang: .fr, defLang: .de, focus: .term, onSave: { _ in }, onCancel: {})
            .background(.background)
    }
}

/// Plays the flow into each scenario's state.
@MainActor
private enum WriteSnapshotScript {
    static func make(_ scenario: WriteSnapshotScenario) -> (AppModel, WriteController) {
        let model = SampleLibrary.model(scenario == .empty ? .emptySet : .fresh)
        let store = model.store
        var setID = store.listSets().first?.id ?? ""
        var now = TimeUtil.nowMs() - 20 * 60_000
        let clock: () -> Double = {
            now += 1_500
            return now
        }
        do {
            switch scenario {
            case .wrong, .dontKnow, .summary, .questionRound2, .resume:
                _ = try store.updateStudyOptions(setID, StudyOptionsPatch(copyAnswer: false))
            case .results, .resultsFlawless:
                let small = try store.createSet(
                    title: "Unité 3 – Les personnes (Auszug)", termLang: .fr, defLang: .de,
                    cards: SampleLibrary.userPairs.prefix(8).map { CardDraft(term: $0.0, definition: $0.1) })
                setID = small.id
                _ = try store.updateStudyOptions(setID, StudyOptionsPatch(copyAnswer: false))
            case .question, .correct, .copy, .empty:
                break
            }
        } catch {
            assertionFailure("Write snapshot setup: \(error)")
        }

        func controller(forceNew: Bool) -> WriteController {
            let controller = WriteController(
                model: model, request: StudyRequest(setID: setID, mode: .write, forceNew: forceNew),
                rng: mulberry32(seed: 11), clock: clock, isLive: false)
            controller.activate()
            return controller
        }

        let c = controller(forceNew: true)
        drive(c, into: scenario)
        guard scenario == .resume else { return (model, c) }
        // Leave with the miss open and come back: "Willkommen zurück" and the miss again.
        c.deactivate()
        return (model, controller(forceNew: false))
    }

    private static func drive(_ c: WriteController, into scenario: WriteSnapshotScenario) {
        switch scenario {
        case .empty:
            break
        case .question:
            // Halfway through typing the answer.
            let expected = c.state.question?.expected ?? ""
            c.send(.inputChanged(String(expected.prefix(max(2, expected.count * 3 / 5)))))
        case .correct:
            // Answer until a term with an article comes up, then leave the article out.
            for _ in 0..<20 {
                let expected = c.state.question?.expected ?? ""
                if tolerated(expected) != expected { break }
                answer(c, expected)
                c.send(.proceed)
            }
            answer(c, tolerated(c.state.question?.expected ?? ""))
        case .wrong, .copy:
            answer(c, nearMiss(c.state.question?.expected ?? ""))
            if scenario == .copy {
                let expected = c.state.question?.expected ?? ""
                c.send(.inputChanged(String(expected.prefix(max(1, expected.count / 2))) + "x"))
                c.send(.proceed)
            }
        case .dontKnow:
            c.send(.dontKnow)
        case .summary:
            play(c, until: .summary, missEvery: 4)
        case .questionRound2:
            play(c, until: .summary, missEvery: 4)
            c.send(.proceed)
        case .results:
            play(c, until: .results, missEvery: 3)
        case .resultsFlawless:
            play(c, until: .results, missEvery: nil)
        case .resume:
            for _ in 0..<3 {
                answer(c, c.state.question?.expected ?? "")
                c.send(.proceed)
            }
            answer(c, nearMiss(c.state.question?.expected ?? ""))
        }
    }

    /// Types `text` into the answer field and submits it.
    private static func answer(_ c: WriteController, _ text: String) {
        c.send(.inputChanged(text))
        c.send(.proceed)
    }

    /// Answers until `target`: right, except every `missEvery`-th question of round 1.
    private static func play(_ c: WriteController, until target: WriteFlow.Phase, missEvery: Int?) {
        var asked = 0
        for _ in 0..<600 {
            let state = c.state
            if state.phase == target { return }
            switch state.phase {
            case .question:
                asked += 1
                let expected = state.question?.expected ?? ""
                let misses = (state.session?.round ?? 1) == 1 && missEvery.map { asked % $0 == 2 } == true
                answer(c, misses ? nearMiss(expected) : expected)
            case .copy:
                answer(c, state.question?.expected ?? "")
            case .feedback, .summary:
                c.send(.proceed)
            case .starting, .results, .empty, .missing:
                return
            }
        }
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
