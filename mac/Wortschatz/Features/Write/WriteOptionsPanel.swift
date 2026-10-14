import SwiftUI
import WortschatzCore

/// The Write options (⌘K, toolbar "Optionen"): direction, order, the copy step, auto-advance,
/// read-aloud and the tolerance (port of the web app's options sheet in Write mode,
/// src/screens/write-dialogs.js with src/ui/study-options.js). Every change is stored at once
/// for this set; when the popover closes, a new direction or order asks to restart
/// (`WriteFlow`). "Neu starten" asks right away, "Fertig" (↩) closes.
struct WriteOptionsPanel: View {
    let controller: WriteController

    private var options: StudyOptions { controller.state.options }
    private var termLang: Lang { controller.state.set?.termLang ?? .other }
    private var defLang: Lang { controller.state.set?.defLang ?? .other }

    var body: some View {
        let names = LearnOptionsCopy.sideNames(termLang: termLang, defLang: defLang)
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Antworten auf", selection: binding(options.answerWith) { StudyOptionsPatch(answerWith: $0) }) {
                        Text(names.term.label).tag(AnswerWith.term)
                        Text(names.definition.label).tag(AnswerWith.definition)
                        Text("Beides").tag(AnswerWith.both)
                    }
                    .pickerStyle(.segmented)
                    Text(WriteOptionsCopy.directionText(options.answerWith, termLang: termLang, defLang: defLang))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Toggle(isOn: binding(options.shuffle) { StudyOptionsPatch(shuffle: $0) }) {
                        Text("Mischen")
                        Text("Karten in zufälliger Reihenfolge abfragen.")
                    }
                    Toggle(isOn: binding(options.copyAnswer) { StudyOptionsPatch(copyAnswer: $0) }) {
                        Text("Richtige Antwort abtippen")
                        Text("Nach einem Fehler tippst du die Lösung einmal ab.")
                    }
                    Toggle(isOn: binding(options.autoAdvance) { StudyOptionsPatch(autoAdvance: $0) }) {
                        Text("Automatisch weiter")
                        Text("Nach einer richtigen Antwort geht es von selbst weiter.")
                    }
                    Toggle(isOn: binding(options.audio) { StudyOptionsPatch(audio: $0) }) {
                        Text("Vorlesen")
                        Text("Begriffe in der Lernsprache automatisch vorlesen.")
                    }
                } header: {
                    Text("Abfrage")
                }

                Section {
                    ForEach(LearnOptionsCopy.toleranceItems(termLang: termLang)) { item in
                        Toggle(isOn: binding(options.tolerance[keyPath: item.keyPath]) { value in
                            var patch = TolerancePatch()
                            patch[keyPath: item.patchKeyPath] = value
                            return StudyOptionsPatch(tolerance: patch)
                        }) {
                            Text(item.label)
                            Text(item.example)
                        }
                    }
                } header: {
                    Text("Toleranz")
                } footer: {
                    Text("Was trotzdem als richtig zählt")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: Spacing.s) {
                Button {
                    controller.send(.overlayDismissed(restartRequested: true))
                } label: {
                    Label("Neu starten", systemImage: "arrow.counterclockwise")
                }
                .help("Die Runde mit diesen Optionen neu beginnen")
                Spacer()
                Button("Fertig") {
                    controller.send(.overlayDismissed())
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
        }
        .frame(width: 440)
        .frame(minHeight: 320, idealHeight: 660, maxHeight: 700)
    }

    /// A binding that stores every change as a patch (`LibraryStore.updateStudyOptions`).
    private func binding<Value>(_ value: Value, patch: @escaping (Value) -> StudyOptionsPatch) -> Binding<Value> {
        Binding(get: { value }, set: { controller.updateOptions(patch($0)) })
    }
}

/// Texts of the Write options form (src/ui/study-options.js, Write mode).
enum WriteOptionsCopy {
    /// "Du siehst Deutsch und schreibst Französisch." (`directionText` in Write mode).
    static func directionText(_ answerWith: AnswerWith, termLang: Lang, defLang: Lang) -> String {
        if answerWith == .both { return "Jede Karte wird in beide Richtungen abgefragt." }
        let names = sideNames(termLang: termLang, defLang: defLang)
        let (shown, typed) = answerWith == .definition ? (names.term, names.definition) : (names.definition, names.term)
        return "Du siehst \(shown.seen) und schreibst \(typed.written)."
    }

    private struct Side {
        let seen: String
        let written: String
    }

    /// `sideNames` of study-options.js (the parts Write mode's sentence needs).
    private static func sideNames(termLang: Lang, defLang: Lang) -> (term: Side, definition: Side) {
        if termLang != .other && termLang == defLang {
            return (
                Side(seen: "den Begriff", written: "den Begriff"),
                Side(seen: "die Definition", written: "die Definition")
            )
        }
        func named(_ lang: Lang) -> Side {
            let name = Labels.langName(lang)
            return Side(seen: name, written: name)
        }
        return (
            termLang != .other
                ? named(termLang) : Side(seen: "den Begriff in der Lernsprache", written: "in der Lernsprache"),
            defLang != .other ? named(defLang) : Side(seen: "die Übersetzung", written: "die Übersetzung")
        )
    }
}
