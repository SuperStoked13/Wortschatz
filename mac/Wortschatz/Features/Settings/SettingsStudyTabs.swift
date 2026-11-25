import SwiftUI
import WortschatzCore

// The study defaults of the Settings window: the tabs Lernen, Schreiben and Toleranz. They are the
// web app's "Standard-Lernoptionen" (src/ui/study-options.js in mode 'all'), split by topic. The
// texts are shared with the Learn options popover (`LearnOptionsCopy`).

// MARK: - Lernen

/// Lernen: question types, questions per round, the answer direction, Wiederholungsfragen and
/// Nachkontrolle (the same for every set, also switchable in the Learn options), the copy step
/// after a written miss and read-aloud.
struct SettingsLearnTab: View {
    @Environment(AppModel.self) private var model
    @AppStorage(LearnController.reviewKey) private var review = false
    @AppStorage(LearnController.recheckKey) private var recheck = true

    var body: some View {
        let writer = SettingsWriter(model: model)
        let options = model.settings.study
        let learn = options.learn
        let lock = LearnOptionsCopy.typeLock(learn)
        let names = LearnOptionsCopy.sideNames(termLang: .other, defLang: SettingsCopy.sharedDefLang(model.library.sets.map(\.set)))

        Form {
            Section {
                Toggle(isOn: writer.binding(learn.mc) { StudyOptionsPatch(learn: LearnOptionsPatch(mc: $0)) }) {
                    Text("Multiple Choice")
                    Text("Vier Antworten zur Auswahl")
                }
                .disabled(lock == .mc)
                .help(lock == .mc ? LearnOptionsCopy.lockHint : "")
                Toggle(isOn: writer.binding(learn.written) { StudyOptionsPatch(learn: LearnOptionsPatch(written: $0)) }) {
                    Text("Schriftlich")
                    Text("Antwort selbst eintippen")
                }
                .disabled(lock == .written)
                .help(lock == .written ? LearnOptionsCopy.lockHint : "")
            } header: {
                Text("Fragetypen")
            } footer: {
                Text(LearnOptionsCopy.questionTypesHint(learn))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: writer.binding(learn.roundSize) { StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: $0)) }) {
                    ForEach(LearnOptionsCopy.roundSizes(including: learn.roundSize), id: \.self) { size in
                        Text("\(size)").tag(size)
                    }
                } label: {
                    Text(LearnOptionsCopy.roundSizeLabel)
                    Text(LearnOptionsCopy.roundSizeNote)
                }
                .pickerStyle(.segmented)

                Picker("Antworten auf", selection: writer.binding(options.answerWith) { StudyOptionsPatch(answerWith: $0) }) {
                    Text(names.term.label).tag(AnswerWith.term)
                    Text(names.definition.label).tag(AnswerWith.definition)
                    Text("Beides").tag(AnswerWith.both)
                }
                .pickerStyle(.segmented)
                .accessibilityHint(SettingsCopy.directionText(options.answerWith, names: names))
            } header: {
                Text("Abfrage")
            } footer: {
                Text(SettingsCopy.directionText(options.answerWith, names: names))
                    .foregroundStyle(.secondary)
            }

            LearnGlobalSwitchesSection(review: $review, recheck: $recheck)

            Section {
                Toggle(isOn: writer.binding(learn.retype) { StudyOptionsPatch(learn: LearnOptionsPatch(retype: $0)) }) {
                    Text("Richtige Antwort abtippen")
                    Text("Nach einem Fehler bei einer schriftlichen Frage tippst du die Lösung einmal ab.")
                }
                Toggle(isOn: writer.binding(options.audio) { StudyOptionsPatch(audio: $0) }) {
                    Text("Vorlesen")
                    Text("Begriffe in der Lernsprache automatisch vorlesen. Gilt auch für Schreiben.")
                }
            } footer: {
                // The two switches above are on this tab too: their standard is off / on.
                SettingsDefaultsFooter(isDefault: SettingsDefaults.learnIsDefault(options) && !review && recheck) {
                    writer.restoreDefaults(SettingsDefaults.learnPatch, scope: String(localized: "Lernen"))
                    review = false
                    recheck = true
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Schreiben

/// Schreiben: shuffling, the copy step after a miss and auto-advance.
struct SettingsWriteTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let writer = SettingsWriter(model: model)
        let options = model.settings.study

        Form {
            Section {
                Toggle(isOn: writer.binding(options.shuffle) { StudyOptionsPatch(shuffle: $0) }) {
                    Text("Mischen")
                    Text("Karten in zufälliger Reihenfolge abfragen.")
                }
                Toggle(isOn: writer.binding(options.copyAnswer) { StudyOptionsPatch(copyAnswer: $0) }) {
                    Text("Richtige Antwort abtippen")
                    Text("Nach einem Fehler tippst du die Lösung einmal ab.")
                }
                Toggle(isOn: writer.binding(options.autoAdvance) { StudyOptionsPatch(autoAdvance: $0) }) {
                    Text("Automatisch weiter")
                    Text("Nach einer richtigen Antwort geht es von selbst weiter.")
                }
            } header: {
                Text("Jede Karte schriftlich")
            } footer: {
                SettingsDefaultsFooter(isDefault: SettingsDefaults.writeIsDefault(options)) {
                    writer.restoreDefaults(SettingsDefaults.writePatch, scope: String(localized: "Schreiben"))
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Toleranz

/// Toleranz: the seven grading switches, each with a German example of what still counts.
struct SettingsToleranceTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let writer = SettingsWriter(model: model)
        let options = model.settings.study

        // Examples in the language all sets are learned in; German ones when the sets differ.
        let termLang = SettingsCopy.sharedTermLang(model.library.sets.map(\.set))

        Form {
            Section {
                ForEach(LearnOptionsCopy.toleranceItems(termLang: termLang)) { item in
                    Toggle(isOn: writer.binding(options.tolerance[keyPath: item.keyPath]) { value in
                        var patch = TolerancePatch()
                        patch[keyPath: item.patchKeyPath] = value
                        return StudyOptionsPatch(tolerance: patch)
                    }) {
                        Text(item.label)
                        Text(item.example)
                    }
                }
            } header: {
                Text("Was trotzdem als richtig zählt")
            } footer: {
                SettingsDefaultsFooter(isDefault: options.tolerance == .default) {
                    writer.restoreDefaults(StudyOptionsPatch(tolerance: TolerancePatch(.default)), scope: String(localized: "Toleranz"))
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Defaults per tab

/// What "Standard wiederherstellen" resets in each study tab (`DEFAULT_STUDY_OPTIONS`).
enum SettingsDefaults {
    private static let defaults = StudyOptions.default

    static let learnPatch = StudyOptionsPatch(
        answerWith: defaults.answerWith, audio: defaults.audio, learn: LearnOptionsPatch(defaults.learn))

    static let writePatch = StudyOptionsPatch(
        shuffle: defaults.shuffle, copyAnswer: defaults.copyAnswer, autoAdvance: defaults.autoAdvance)

    static func learnIsDefault(_ options: StudyOptions) -> Bool {
        options.answerWith == defaults.answerWith && options.audio == defaults.audio && options.learn == defaults.learn
    }

    static func writeIsDefault(_ options: StudyOptions) -> Bool {
        options.shuffle == defaults.shuffle && options.copyAnswer == defaults.copyAnswer
            && options.autoAdvance == defaults.autoAdvance
    }
}
