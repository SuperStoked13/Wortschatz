import Foundation
import Observation
import WortschatzCore
import WortschatzImport

/// Runs file imports for the editor (port of the file part of the web editor's import panel):
/// one import at a time, cancellable, with progress for a `ProgressView` that appears only for
/// slow imports (text files finish instantly), and VoiceOver announcements of the status line.
///
/// ```swift
/// @State private var importer = ImportCoordinator()
///
/// switch await importer.run(sources, termLang: set.termLang, defLang: set.defLang) {
/// case let .finished(batch):
///     for message in batch.errorMessages { toasts.show(message, tone: .danger, duration: .seconds(7)) }
///     importText = batch.appended(to: importText)          // then parse; batch.warnings → hints
/// case .cancelled: toasts.show(ImportCoordinator.cancelledMessage)
/// case .busy: toasts.show(ImportCoordinator.busyMessage)
/// }
///
/// if importer.showsProgress, let progress = importer.progress {
///     ProgressView(value: progress.fraction) { Text(progress.message) }
///     Button("Abbrechen") { importer.cancel() }
/// }
/// ```
@Observable
final class ImportCoordinator {
    enum Outcome {
        /// Every file was tried: texts, failures and warnings are in the batch.
        case finished(ImportBatch)
        /// `cancel()` stopped the import; nothing was read.
        case cancelled
        /// Another import is still running.
        case busy
    }

    /// Toast after `cancel()`.
    static let cancelledMessage = "Import abgebrochen"
    /// Toast when files arrive while an import runs.
    static let busyMessage = "Bitte warte, bis der aktuelle Import fertig ist."
    /// The progress view appears only for imports slower than this (like the web app).
    static let progressDelay: Duration = .milliseconds(160)

    /// An import is running.
    private(set) var isRunning = false
    /// Show the progress view (the import has been running for `progressDelay`).
    private(set) var showsProgress = false
    /// The latest progress, nil when idle.
    private(set) var progress: ImportProgress?

    @ObservationIgnored private let pipeline: ImportPipeline
    @ObservationIgnored private var task: Task<ImportBatch, any Error>?
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastAnnouncement: ContinuousClock.Instant?

    init(pipeline: ImportPipeline = ImportPipeline()) {
        self.pipeline = pipeline
    }

    /// Reads `sources` one after another; text recognition uses the set's languages.
    func run(_ sources: [ImportSource], termLang: Lang?, defLang: Lang?) async -> Outcome {
        guard !sources.isEmpty else { return .finished(ImportBatch()) }
        guard !isRunning else { return .busy }
        generation += 1
        let current = generation
        isRunning = true
        progress = ImportProgress(fraction: 0, message: "Datei wird gelesen …")
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: Self.progressDelay)
            guard let self, !Task.isCancelled, self.generation == current, self.isRunning else { return }
            self.showsProgress = true
        }

        let pipeline = self.pipeline
        // Progress arrives on background threads and is applied on the main actor.
        let deliver: @MainActor (ImportProgress) -> Void = { [weak self] update in
            self?.receive(update, generation: current)
        }
        let task = Task {
            try await pipeline.readAll(sources, termLang: termLang, defLang: defLang) { update in
                Task { @MainActor in deliver(update) }
            }
        }
        self.task = task
        let result = await task.result
        // Cancelled (or superseded) while it ran: the result is dropped, like the web app does.
        guard generation == current else { return .cancelled }
        finish()
        switch result {
        case let .success(batch): return .finished(batch)
        case .failure: return .cancelled
        }
    }

    /// Stops the running import (PDF reading and text recognition) and drops its result.
    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        finish()
        Announcer.announce(Self.cancelledMessage)
    }

    // MARK: - Private

    private func receive(_ update: ImportProgress, generation: Int) {
        guard generation == self.generation, isRunning else { return }
        let changed = progress?.message != update.message
        progress = update
        // Announce new status lines, but not more often than every 1.5 s.
        guard changed, showsProgress else { return }
        let now = ContinuousClock.now
        if let last = lastAnnouncement, now - last < .milliseconds(1500) { return }
        lastAnnouncement = now
        Announcer.announce(update.message)
    }

    private func finish() {
        generation += 1
        isRunning = false
        showsProgress = false
        progress = nil
        task = nil
        revealTask?.cancel()
        revealTask = nil
        lastAnnouncement = nil
    }
}
