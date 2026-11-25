import SwiftUI
import WortschatzCore

/// The Write options (⌘K, toolbar "Optionen"): what this set does differently from the
/// standard, then direction, order, the copy step, auto-advance, read-aloud and the tolerance
/// (port of the web app's options sheet in Write mode, src/screens/write-dialogs.js with
/// src/ui/study-options.js). Every change is stored for this set and applies at once, also to the
/// running session (`WriteFlow`: direction and order via `WriteSession.setOptions`). "Neu starten"
/// asks right away, "Fertig" (↩) closes.
struct WriteOptionsPanel: View {
    let controller: WriteController

    private var options: StudyOptions { controller.state.options }
    private var termLang: Lang { controller.state.set?.termLang ?? .other }
    private var defLang: Lang { controller.state.set?.defLang ?? .other }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                StudyOptionsStandardNote(
                    options: options, standard: controller.standardOptions, termLang: termLang, defLang: defLang
                ) {
                    controller.resetOptionsToStandard()
                }
                WriteOptionsSections(options: options, termLang: termLang, defLang: defLang, setID: controller.setID) {
                    controller.updateOptions($0)
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
            .buttonBorderShape(.capsule)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
        }
        .frame(width: 440)
        .frame(minHeight: 320, idealHeight: 660, maxHeight: 700)
    }
}

/// The sections of the Write options: Abfrage and Toleranz. Shared by the options popover and
/// the set's options sheet (`SetOptionsSheet`); `update` stores a change for the set.
struct WriteOptionsSections: View {
    let options: StudyOptions
    let termLang: Lang
    let defLang: Lang
    /// The set whose own "Soundeffekte" and synonyms switches show (nil: none).
    var setID: String? = nil
    let update: (StudyOptionsPatch) -> Void

    var body: some View {
        let names = LearnOptionsCopy.sideNames(termLang: termLang, defLang: defLang)
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
            if let setID {
                SetSoundEffectsToggle(setID: setID)
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
            if let setID {
                SetExtendedSynonymsToggle(setID: setID)
            }
        } header: {
            Text("Toleranz")
        } footer: {
            Text("Was trotzdem als richtig zählt")
                .foregroundStyle(.secondary)
        }
    }

    /// A binding that stores every change as a patch.
    private func binding<Value>(_ value: Value, patch: @escaping (Value) -> StudyOptionsPatch) -> Binding<Value> {
        Binding(get: { value }, set: { update(patch($0)) })
    }
}

/// Texts of the Write options form (src/ui/study-options.js, Write mode).
enum WriteOptionsCopy {
    /// "Du siehst Deutsch und schreibst Französisch." (`directionText` in Write mode): one whole
    /// sentence per way the two sides are named (`sideNames` of study-options.js: by language,
    /// Begriff/Definition when both sides share one, Lernsprache/Übersetzung without one).
    static func directionText(_ answerWith: AnswerWith, termLang: Lang, defLang: Lang) -> String {
        if answerWith == .both { return String(localized: "Jede Karte wird in beide Richtungen abgefragt.") }
        if termLang != .other && termLang == defLang {
            return answerWith == .definition
                ? String(localized: "Du siehst den Begriff und schreibst die Definition.")
                : String(localized: "Du siehst die Definition und schreibst den Begriff.")
        }
        // The sides' language names; nil without a language.
        let termName = termLang != .other ? Labels.langName(termLang) : nil
        let definitionName = defLang != .other ? Labels.langName(defLang) : nil
        if answerWith == .definition {
            switch (termName, definitionName) {
            case let (term?, definition?):
                return String(localized: "Du siehst \(term) und schreibst \(definition).")
            case let (term?, nil):
                return String(localized: "Du siehst \(term) und schreibst die Übersetzung.")
            case let (nil, definition?):
                return String(localized: "Du siehst den Begriff in der Lernsprache und schreibst \(definition).")
            case (nil, nil):
                return String(localized: "Du siehst den Begriff in der Lernsprache und schreibst die Übersetzung.")
            }
        }
        switch (definitionName, termName) {
        case let (definition?, term?):
            return String(localized: "Du siehst \(definition) und schreibst \(term).")
        case let (definition?, nil):
            return String(localized: "Du siehst \(definition) und schreibst in der Lernsprache.")
        case let (nil, term?):
            return String(localized: "Du siehst die Übersetzung und schreibst \(term).")
        case (nil, nil):
            return String(localized: "Du siehst die Übersetzung und schreibst in der Lernsprache.")
        }
    }
}
