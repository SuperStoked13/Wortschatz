import SwiftUI
import WortschatzCore

/// The Learn options (⌘K, toolbar "Optionen"): what this set does differently from the standard,
/// then direction, question types, questions per round, the copy step, read-aloud, the
/// repetition questions and rechecks, and the tolerance (port of the web app's study options form
/// in Learn mode, src/ui/study-options.js, plus "Wiederholungsfragen" and "Nachkontrolle", which
/// hold for every set). Every change is stored at once; tolerance, read-aloud and the copy step
/// apply immediately, the others ask to restart when the popover closes (`LearnFlow`).
struct LearnOptionsPanel: View {
    let controller: LearnController

    private var options: StudyOptions { controller.state.options }

    var body: some View {
        Form {
            StudyOptionsStandardNote(
                options: options, standard: controller.standardOptions, termLang: controller.state.termLang,
                defLang: controller.state.defLang
            ) {
                controller.resetOptionsToStandard()
            }
            LearnOptionsSections(
                options: options, termLang: controller.state.termLang, defLang: controller.state.defLang,
                review: Binding(get: { controller.state.review }, set: { controller.setReview($0) }),
                recheck: Binding(get: { controller.state.recheck }, set: { controller.setRecheck($0) })
            ) { controller.updateOptions($0) }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 320, idealHeight: 620, maxHeight: 660)
    }
}

/// The sections of the Learn options: Abfrage, Fragetypen, the round, Wiederholung (the two
/// switches that hold for every set) and Toleranz. Shared by the options popover and the set's
/// options sheet (`SetOptionsSheet`); `update` stores a change for the set.
struct LearnOptionsSections: View {
    let options: StudyOptions
    let termLang: Lang
    let defLang: Lang
    @Binding var review: Bool
    @Binding var recheck: Bool
    let update: (StudyOptionsPatch) -> Void

    var body: some View {
        let names = LearnOptionsCopy.sideNames(termLang: termLang, defLang: defLang)
        let lock = LearnOptionsCopy.typeLock(options.learn)

        Section {
            Picker("Antworten auf", selection: binding(options.answerWith) { StudyOptionsPatch(answerWith: $0) }) {
                Text(names.term.label).tag(AnswerWith.term)
                Text(names.definition.label).tag(AnswerWith.definition)
                Text("Beides").tag(AnswerWith.both)
            }
            .pickerStyle(.segmented)
            Text(LearnOptionsCopy.directionText(options.answerWith, names: names))
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("Abfrage")
        }

        Section {
            Toggle(isOn: binding(options.learn.mc) { StudyOptionsPatch(learn: LearnOptionsPatch(mc: $0)) }) {
                Text("Multiple Choice")
                Text("Vier Antworten zur Auswahl")
            }
            .disabled(lock == .mc)
            .help(lock == .mc ? LearnOptionsCopy.lockHint : "")
            Toggle(isOn: binding(options.learn.written) { StudyOptionsPatch(learn: LearnOptionsPatch(written: $0)) }) {
                Text("Schriftlich")
                Text("Antwort selbst eintippen")
            }
            .disabled(lock == .written)
            .help(lock == .written ? LearnOptionsCopy.lockHint : "")
        } header: {
            Text("Fragetypen")
        } footer: {
            Text(LearnOptionsCopy.questionTypesHint(options.learn))
                .foregroundStyle(.secondary)
        }

        Section {
            Picker(selection: binding(options.learn.roundSize) { StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: $0)) }) {
                ForEach(LearnOptionsCopy.roundSizes(including: options.learn.roundSize), id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            } label: {
                Text(LearnOptionsCopy.roundSizeLabel)
                Text(LearnOptionsCopy.roundSizeNote)
            }
            .pickerStyle(.segmented)
            Toggle(isOn: binding(options.learn.retype) { StudyOptionsPatch(learn: LearnOptionsPatch(retype: $0)) }) {
                Text("Richtige Antwort abtippen")
                Text("Nach einem Fehler bei einer schriftlichen Frage tippst du die Lösung einmal ab.")
            }
            Toggle(isOn: binding(options.audio) { StudyOptionsPatch(audio: $0) }) {
                Text("Vorlesen")
                Text("Begriffe in der Lernsprache automatisch vorlesen.")
            }
        }

        LearnGlobalSwitchesSection(review: $review, recheck: $recheck)

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

    /// A binding that stores every change as a patch.
    private func binding<Value>(_ value: Value, patch: @escaping (Value) -> StudyOptionsPatch) -> Binding<Value> {
        Binding(get: { value }, set: { update(patch($0)) })
    }
}

/// "Wiederholung": Wiederholungsfragen and Nachkontrolle nach Fehlern, the two Learn switches that
/// hold for every set (`UserDefaults`, not study options). In the Learn options, the set's options
/// sheet and Einstellungen › Lernen.
struct LearnGlobalSwitchesSection: View {
    @Binding var review: Bool
    @Binding var recheck: Bool

    var body: some View {
        Section {
            Toggle(isOn: $review) {
                Text(LearnOptionsCopy.reviewLabel)
                Text(LearnOptionsCopy.reviewNote)
            }
            Toggle(isOn: $recheck) {
                Text(LearnOptionsCopy.recheckLabel)
                Text(LearnOptionsCopy.recheckNote)
            }
        } header: {
            Text("Wiederholung")
        } footer: {
            Text(LearnOptionsCopy.globalSwitchesFooter)
                .foregroundStyle(.secondary)
        }
    }
}

/// The note at the top of a set's options (Lernen and Schreiben): the options this set has of
/// its own (they differ from the standard in Einstellungen) with "Auf Standard zurücksetzen", or
/// that changes here only apply to this set.
struct StudyOptionsStandardNote: View {
    /// The set's options in effect.
    let options: StudyOptions
    /// The standard of every set (Einstellungen).
    let standard: StudyOptions
    let termLang: Lang
    let defLang: Lang
    let reset: () -> Void

    var body: some View {
        let deviations = LearnOptionsCopy.deviations(
            options, standard: standard, names: LearnOptionsCopy.sideNames(termLang: termLang, defLang: defLang),
            termLang: termLang)
        Section {
            if deviations.isEmpty {
                Label {
                    Text("Was du hier umstellst, gilt nur für dieses Lernset. Den Standard für alle Lernsets legst du in den Einstellungen fest.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.tertiary)
                }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("Dieses Lernset hat eigene Optionen: \(deviations.joined(separator: " · ")).")
                            .font(.callout.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Button(action: reset) {
                            Label("Auf Standard zurücksetzen", systemImage: "arrow.uturn.backward")
                        }
                        .help("Alle Optionen dieses Lernsets wieder wie in den Einstellungen")
                    }
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Theme.accentText)
                }
            }
        }
    }
}

extension AppModel {
    /// "Auf Standard zurücksetzen" in a set's options: clears the set's own options (an empty
    /// patch), so it follows the standard in Einstellungen again. Returns the options now in
    /// effect, nil when storing failed (reported as a toast).
    @discardableResult
    func resetStudyOptions(setID: String) -> StudyOptions? {
        do {
            _ = try store.updateSet(setID, SetPatch(studyOptions: StudyOptionsPatch()))
        } catch {
            report(error, fallback: "Die Optionen konnten nicht zurückgesetzt werden.")
            return nil
        }
        toasts.show("Dieses Lernset folgt wieder dem Standard", tone: .success)
        return store.getStudyOptions(setID)
    }
}

/// Texts of the options form (src/ui/study-options.js, Learn mode).
enum LearnOptionsCopy {
    struct Side {
        let label: String
        let seen: String
        let answered: String
    }

    static let lockHint = "Mindestens ein Fragetyp bleibt aktiv."

    /// The round size: after so many questions the checkpoint shows the interim result (since 1.4
    /// a round is questions, not a group of terms).
    static let roundSizeLabel = "Fragen pro Runde"
    static let roundSizeNote = "Nach so vielen Fragen siehst du deinen Zwischenstand."

    /// The two Learn switches that hold for every set (`UserDefaults`, not study options).
    static let reviewLabel = "Wiederholungsfragen"
    static let reviewNote =
        "Gemeisterte Begriffe kommen zwischendurch nochmals dran. Ist eine Antwort falsch, ist der Begriff wieder am Lernen."
    static let recheckLabel = "Nachkontrolle nach Fehlern"
    static let recheckNote =
        "Hattest du einen Begriff einmal falsch, kommt er nach dem Meistern etwa 30 bis 50 Fragen später nochmals. Nur bei Lernsets mit mehr als 60 Begriffen."
    static let globalSwitchesFooter = "Gilt für alle Lernsets, ab dem nächsten Start."

    /// What a set's options change from the standard (Einstellungen), as short phrases in the
    /// order of the options ("Multiple Choice: aus", "10 Fragen pro Runde"); empty when the set
    /// follows the standard.
    static func deviations(
        _ own: StudyOptions, standard: StudyOptions, names: (term: Side, definition: Side), termLang: Lang
    ) -> [String] {
        func onOff(_ on: Bool) -> String { on ? "an" : "aus" }
        var out: [String] = []
        if own.answerWith != standard.answerWith {
            let side =
                switch own.answerWith {
                case .term: names.term.label
                case .definition: names.definition.label
                case .both: "beides"
                }
            out.append("Antworten auf \(side)")
        }
        if own.learn.mc != standard.learn.mc { out.append("Multiple Choice: \(onOff(own.learn.mc))") }
        if own.learn.written != standard.learn.written { out.append("Schriftlich: \(onOff(own.learn.written))") }
        if own.learn.roundSize != standard.learn.roundSize { out.append("\(own.learn.roundSize) \(roundSizeLabel)") }
        if own.learn.retype != standard.learn.retype {
            out.append("Abtippen nach Fehler (Lernen): \(onOff(own.learn.retype))")
        }
        if own.shuffle != standard.shuffle { out.append("Mischen: \(onOff(own.shuffle))") }
        if own.copyAnswer != standard.copyAnswer {
            out.append("Abtippen nach Fehler (Schreiben): \(onOff(own.copyAnswer))")
        }
        if own.autoAdvance != standard.autoAdvance { out.append("Automatisch weiter: \(onOff(own.autoAdvance))") }
        if own.audio != standard.audio { out.append("Vorlesen: \(onOff(own.audio))") }
        for item in toleranceItems(termLang: termLang)
        where own.tolerance[keyPath: item.keyPath] != standard.tolerance[keyPath: item.keyPath] {
            out.append("\(item.label): \(onOff(own.tolerance[keyPath: item.keyPath]))")
        }
        return out
    }

    /// "Fragen pro Runde" choices; a stored size outside them stays selectable.
    static func roundSizes(including current: Int) -> [Int] {
        var sizes = [5, 7, 10, 15]
        if current >= 1, !sizes.contains(current) {
            sizes.append(current)
            sizes.sort()
        }
        return sizes
    }

    /// How the two sides are called: by language, or Begriff/Definition when both sides share one.
    static func sideNames(termLang: Lang, defLang: Lang) -> (term: Side, definition: Side) {
        if termLang != .other && termLang == defLang {
            return (
                Side(label: "Begriff", seen: "den Begriff", answered: "mit dem Begriff"),
                Side(label: "Definition", seen: "die Definition", answered: "mit der Definition")
            )
        }
        func named(_ lang: Lang) -> Side {
            let name = Labels.langName(lang)
            return Side(label: name, seen: name, answered: "auf \(name)")
        }
        return (
            termLang != .other
                ? named(termLang)
                : Side(label: "Lernsprache", seen: "den Begriff in der Lernsprache", answered: "in der Lernsprache"),
            defLang != .other
                ? named(defLang)
                : Side(label: "Übersetzung", seen: "die Übersetzung", answered: "mit der Übersetzung")
        )
    }

    /// "Du siehst Deutsch und antwortest auf Französisch." (`directionText` in Learn mode).
    static func directionText(_ answerWith: AnswerWith, names: (term: Side, definition: Side)) -> String {
        switch answerWith {
        case .both: "Die Richtung wechselt zufällig von Frage zu Frage."
        case .definition: "Du siehst \(names.term.seen) und antwortest \(names.definition.answered)."
        case .term: "Du siehst \(names.definition.seen) und antwortest \(names.term.answered)."
        }
    }

    enum TypeLock { case mc, written }

    /// The question type that cannot be switched off because it is the only one on.
    static func typeLock(_ learn: LearnOptions) -> TypeLock? {
        if learn.mc && !learn.written { return .mc }
        if learn.written && !learn.mc { return .written }
        return nil
    }

    static func questionTypesHint(_ learn: LearnOptions) -> String {
        switch typeLock(learn) {
        case nil: "Neue Begriffe kommen zuerst als Multiple Choice, danach schreibst du sie selbst."
        case .mc: "Alle Fragen kommen als Multiple Choice. \(lockHint)"
        case .written: "Alle Fragen beantwortest du schriftlich. \(lockHint)"
        }
    }

    struct ToleranceItem: Identifiable {
        let id: String
        let label: String
        let example: String
        let keyPath: WritableKeyPath<Tolerance, Bool>
        let patchKeyPath: WritableKeyPath<TolerancePatch, Bool?>
    }

    /// The seven tolerance switches with an example in the set's language.
    static func toleranceItems(termLang: Lang) -> [ToleranceItem] {
        let article: String =
            switch termLang {
            case .fr: "«homme» für «l'homme»"
            case .en: "«house» für «the house»"
            case .es, .it: "«casa» für «la casa»"
            default: "«Herr» für «der Herr»"
            }
        let abbreviation: String =
            switch termLang {
            case .fr: "«etw.» = «etwas», «qc» = «quelque chose»"
            case .en: "«etw.» = «etwas», «sth» = «something»"
            default: "«etw.» = «etwas», «jdn.» = «jemanden»"
            }
        let accents: String =
            switch termLang {
            case .fr: "«ecole» = «école», «ahnlich» = «ähnlich»"
            case .es: "«arbol» = «árbol», «ahnlich» = «ähnlich»"
            case .it: "«citta» = «città», «ahnlich» = «ähnlich»"
            // Missing tones count like accents. Arabic has none: its vowel marks never count.
            case .zh: "«ni hao» = «nǐ hǎo», «ahnlich» = «ähnlich»"
            default: "«ahnlich» = «ähnlich»"
            }
        return [
            ToleranceItem(
                id: "articles", label: "Artikel/Pronomen vergessen erlaubt",
                example: "\(article) – ein falscher Artikel bleibt falsch", keyPath: \.articles, patchKeyPath: \.articles),
            ToleranceItem(
                id: "abbreviations", label: "Abkürzungen gleichwertig", example: abbreviation, keyPath: \.abbreviations,
                patchKeyPath: \.abbreviations),
            ToleranceItem(
                id: "multipleAnswers", label: "Eine von mehreren Antworten genügt", example: "«lieb» reicht bei «lieb, nett»",
                keyPath: \.multipleAnswers, patchKeyPath: \.multipleAnswers),
            ToleranceItem(
                id: "parentheses", label: "Klammerinhalt optional", example: "«freuen» für «(sich) freuen»",
                keyPath: \.parentheses, patchKeyPath: \.parentheses),
            ToleranceItem(
                id: "ignoreCase", label: "Gross-/Kleinschreibung ignorieren", example: "«herr» = «Herr»",
                keyPath: \.ignoreCase, patchKeyPath: \.ignoreCase),
            ToleranceItem(
                id: "ignoreAccents", label: "Akzente ignorieren", example: accents, keyPath: \.ignoreAccents,
                patchKeyPath: \.ignoreAccents),
            ToleranceItem(
                id: "typos", label: "Kleine Tippfehler erlauben", example: "«Mädhcen» statt «Mädchen» – ein Buchstabe daneben",
                keyPath: \.typos, patchKeyPath: \.typos),
        ]
    }
}
