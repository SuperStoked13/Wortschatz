#if DEBUG
import AppKit
import OSLog
import QuartzCore
import SwiftUI
import WortschatzCore

/// Debug-only timing helpers for `--transition-probe` (no effect otherwise).
enum DebugTiming {
    static let isEnabled = CommandLine.arguments.contains("--transition-probe")
    static let signposter = OSSignposter(subsystem: "app.wortschatz.mac", category: .pointsOfInterest)

    /// A point of interest in an Instruments trace (when the probe runs).
    static func mark(_ name: StaticString) {
        guard isEnabled else { return }
        signposter.emitEvent(name)
    }

    /// Runs `body` and logs how long it blocked the main thread (when the probe runs).
    @discardableResult
    static func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let start = CACurrentMediaTime()
        defer { print(String(format: "TIMING %@ %.1f ms (t=%.3f)", label, (CACurrentMediaTime() - start) * 1000, start)) }
        return try body()
    }
}

/// Records display-link callbacks; a late callback means the main thread missed frames.
@MainActor
final class DebugFrameRecorder: NSObject {
    private(set) var stamps: [CFTimeInterval] = []
    private var link: CADisplayLink?

    func start(in window: NSWindow) {
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(CACurrentMediaTime())
    }

    func stop() -> [CFTimeInterval] {
        link?.invalidate()
        link = nil
        return stamps
    }
}

/// `--transition-probe` (with `--ui-test-library <name>`): from the overview, presses
/// "Weiterlernen" three times (going back in between) and logs every frame the main thread
/// missed during the transition ("PROBE …"), then quits.
enum DebugTransitionProbe {
    static func scheduleIfRequested(model: AppModel) {
        guard DebugTiming.isEnabled else { return }
        Task { @MainActor in
            // `--probe-wait <s>`: time to attach a profiler (xctrace record --attach) first.
            let args = CommandLine.arguments
            let wait = args.firstIndex(of: "--probe-wait").flatMap { Double(args[safe: $0 + 1] ?? "") } ?? 2
            try? await Task.sleep(for: .seconds(wait))
            NSApp.activate()
            model.showOverview()
            try? await Task.sleep(for: .seconds(1.5))
            for run in 1...3 {
                guard let window = NSApp.keyWindow else {
                    print("PROBE window not key")
                    break
                }
                let recorder = DebugFrameRecorder()
                recorder.start(in: window)
                try? await Task.sleep(for: .milliseconds(400))
                let t0 = CACurrentMediaTime()
                print(String(format: "TIMING --- run %d: Weiterlernen at t=%.3f", run, t0))
                DebugTiming.mark("Weiterlernen")
                model.resume()
                let actionCost = (CACurrentMediaTime() - t0) * 1000
                try? await Task.sleep(for: .milliseconds(1600))
                let stamps = recorder.stop()
                report(run: run, label: "open", stamps: stamps, t0: t0, actionCost: actionCost)

                // Back to the set page (esc / "Lernsets").
                let back = DebugFrameRecorder()
                back.start(in: window)
                try? await Task.sleep(for: .milliseconds(300))
                let t1 = CACurrentMediaTime()
                DebugTiming.mark("Zurueck")
                model.finishStudy()
                let backCost = (CACurrentMediaTime() - t1) * 1000
                try? await Task.sleep(for: .milliseconds(2200))
                report(run: run, label: "back", stamps: back.stop(), t0: t1, actionCost: backCost, span: 1.9)
                model.showOverview()
                try? await Task.sleep(for: .milliseconds(1200))
            }
            exit(0)
        }
    }

    private static func report(run: Int, label: String, stamps: [CFTimeInterval], t0: CFTimeInterval, actionCost: Double, span: Double = 1.2) {
        let window = stamps.filter { $0 >= t0 - 0.05 && $0 <= t0 + span }
        var gaps: [(at: Double, ms: Double)] = []
        for (a, b) in zip(window, window.dropFirst()) {
            gaps.append((at: (a - t0) * 1000, ms: (b - a) * 1000))
        }
        let typical = gaps.map(\.ms).sorted().dropLast(gaps.count / 4).last ?? 0
        let hitches = gaps.filter { $0.ms > max(25, typical * 1.8) }
        let worst = gaps.map(\.ms).max() ?? 0
        print(String(format: "PROBE run %d %@: action %.1f ms, frames %d, typical %.1f ms, worst %.1f ms, hitches %d", run, label, actionCost, window.count, typical, worst, hitches.count))
        for hitch in hitches.prefix(12) {
            print(String(format: "PROBE   hitch at +%.0f ms lasting %.0f ms", hitch.at, hitch.ms))
        }
        fflush(stdout)
    }
}
#endif

#if DEBUG
private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
