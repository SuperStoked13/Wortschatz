import SwiftUI
import WortschatzCore

/// The options of a set outside a study session ("Optionen" on the set page): Lernen or
/// Schreiben, as in the study screens' options, with the note on what this set does differently
/// from the standard. Every change is stored for the set at once and applies at once, also to a
/// session already started (`LearnFlow`/`WriteFlow` follow it when it resumes). "Fertig" (↩, esc)
/// closes.
struct SetOptionsSheet: View {
    let setID: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .learn
    @AppStorage(LearnController.reviewKey) private var review = false
    @AppStorage(LearnController.recheckKey) private var recheck = true

    enum Mode: Hashable { case learn, write }

    var body: some View {
        let summary = model.library.summary(for: setID)
        let options = summary?.options ?? model.settings.study
        let termLang = summary?.set.termLang ?? .other
        let defLang = summary?.set.defLang ?? .other

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Optionen")
                    .font(.title2.weight(.bold))
                Picker("Optionen für", selection: $mode) {
                    Text("Lernen").tag(Mode.learn)
                    Text("Schreiben").tag(Mode.write)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.l)

            Form {
                StudyOptionsStandardNote(
                    options: options, standard: model.settings.study, termLang: termLang, defLang: defLang
                ) {
                    _ = model.resetStudyOptions(setID: setID)
                }
                switch mode {
                case .learn:
                    LearnOptionsSections(
                        options: options, termLang: termLang, defLang: defLang, review: $review, recheck: $recheck,
                        setID: setID, update: update)
                case .write:
                    WriteOptionsSections(
                        options: options, termLang: termLang, defLang: defLang, setID: setID, update: update)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
        }
        .frame(width: 460)
        .frame(minHeight: 360, idealHeight: 660, maxHeight: 720)
        .onExitCommand { dismiss() }
    }

    /// Stores a change for this set; an option set back to the standard is no longer its own
    /// (`LibraryStore.updateOwnStudyOptions`).
    private func update(_ patch: StudyOptionsPatch) {
        do {
            _ = try model.store.updateOwnStudyOptions(setID, patch)
        } catch {
            model.report(error, fallback: String(localized: "Die Option konnte nicht gespeichert werden."))
        }
    }
}
