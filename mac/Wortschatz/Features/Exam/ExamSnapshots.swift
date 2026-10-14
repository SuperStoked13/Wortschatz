#if DEBUG
import SwiftUI
import WortschatzCore

/// Snapshot scenes of the exam (`--render-snapshots <dir> --snapshot-filter exam-`): the settings,
/// the sheet half answered and the marked result, on the in-memory sample library with a seeded
/// random source and a fixed clock.
final class ExamSnapshots: SnapshotCatalog {
    override class var scenes: [SnapshotScene] {
        ExamSnapshotScenario.allCases.map { scenario in
            SnapshotScene("exam-\(scenario.rawValue)", sizes: scenario.sizes, settleTime: 0.9) {
                ExamSnapshotHost(scenario)
            }
        }
    }
}

enum ExamSnapshotScenario: String, CaseIterable {
    case setup
    case sheet
    case results

    var sizes: [CGSize] {
        switch self {
        case .sheet: [LearnSnapshots.size, LearnSnapshots.compactSize]
        default: [LearnSnapshots.size]
        }
    }
}

private struct ExamSnapshotHost: View {
    @State private var model: AppModel
    @State private var controller: ExamController

    init(_ scenario: ExamSnapshotScenario) {
        let (model, controller) = ExamSnapshotScript.make(scenario)
        _model = State(initialValue: model)
        _controller = State(initialValue: controller)
    }

    var body: some View {
        ExamScreenContent(controller: controller)
            .environment(model)
            .environment(model.toasts)
    }
}

@MainActor
private enum ExamSnapshotScript {
    static func make(_ scenario: ExamSnapshotScenario) -> (AppModel, ExamController) {
        let model = SampleLibrary.model(.fresh)
        let setID = model.store.listSets().first?.id ?? ""
        let start = Date(timeIntervalSince1970: 1_791_900_000)
        var now = start
        let settings = ExamSettings(minutes: 10, count: 10, answerWith: .term, tolerance: .half)
        let controller = ExamController(
            model: model, request: StudyRequest(setID: setID, mode: .exam), settings: settings,
            rng: mulberry32(seed: 11), clock: { now }, isLive: false)
        controller.activate()
        guard scenario != .setup else { return (model, controller) }

        controller.start()
        for question in controller.questions {
            let n = question.number
            guard scenario == .results || n <= 6 else { continue }
            switch n % 5 {
            case 0: break
            case 1: controller.setAnswer(typo(question.expected), for: n)
            case 2: controller.setAnswer(n == 2 ? "la chose" : "le truc", for: n)
            default: controller.setAnswer(question.expected, for: n)
            }
        }
        if scenario == .results {
            now = start.addingTimeInterval(521)
            controller.submit()
        }
        return (model, controller)
    }

    /// The word with two letters swapped (a small mistake).
    private static func typo(_ text: String) -> String {
        var chars = Array(text)
        guard chars.count > 4 else { return text + "e" }
        chars.swapAt(chars.count - 2, chars.count - 3)
        return String(chars)
    }
}
#endif
