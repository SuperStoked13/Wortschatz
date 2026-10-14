import SwiftUI
import WortschatzCore

/// The Learn options (⌘K, toolbar "Optionen"): direction, question types, terms per round, the
/// copy step, read-aloud, the repetition questions and the tolerance (port of the web app's
/// study options form in Learn mode, src/ui/study-options.js, plus "Wiederholungsfragen", which
/// only the Mac app has and keeps for every set). Every change is stored at once; tolerance,
/// read-aloud and the copy step apply immediately, the others ask to restart when the popover
/// closes (`LearnFlow`).
struct LearnOptionsPanel: View {
    let controller: LearnController

    private var options: StudyOptions { controller.state.options }
    private var termLang: Lang { controller.state.termLang }
    private var defLang: Lang { controller.state.defLang }

    var body: some View {
        let names = LearnOptionsCopy.sideNames(termLang: termLang, defLang: defLang)
        let lock = LearnOptionsCopy.typeLock(options.learn)
        Form {
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
                Picker(
                    "Begriffe pro Runde",
                    selection: binding(options.learn.roundSize) { StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: $0)) }
                ) {
                    ForEach(LearnOptionsCopy.roundSizes(including: options.learn.roundSize), id: \.self) { size in
                        Text("\(size)").tag(size)
                    }
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

            Section {
                Toggle(isOn: Binding(get: { controller.state.review }, set: { controller.setReview($0) })) {
                    Text("Wiederholungsfragen")
                    Text("Gemeisterte Begriffe kommen zwischendurch nochmals dran. Ist eine Antwort falsch, ist der Begriff wieder am Lernen.")
                }
            } header: {
                Text("Wiederholung")
            } footer: {
                Text("Gilt für alle Lernsets.")
                    .foregroundStyle(.secondary)
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
        .frame(width: 440)
        .frame(minHeight: 320, idealHeight: 620, maxHeight: 660)
    }

    /// A binding that stores every change as a patch (`LibraryStore.updateStudyOptions`).
    private func binding<Value>(_ value: Value, patch: @escaping (Value) -> StudyOptionsPatch) -> Binding<Value> {
        Binding(get: { value }, set: { controller.updateOptions(patch($0)) })
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

    /// "Begriffe pro Runde" choices; a stored size outside them stays selectable.
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
