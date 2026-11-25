import SwiftUI
import WortschatzCore

/// The Learn options (⌘K, toolbar "Optionen"): what this set does differently from the standard,
/// then direction, question types, questions per round, the copy step, read-aloud, the
/// repetition questions and rechecks, and the tolerance (port of the web app's study options form
/// in Learn mode, src/ui/study-options.js, plus "Wiederholungsfragen" and "Nachkontrolle", which
/// hold for every set). Every change is stored and applies at once, also to the running session
/// (`LearnFlow`: direction, question types and round size via `LearnEngine.setOptions`).
struct LearnOptionsPanel: View {
    let controller: LearnController

    private var options: StudyOptions { controller.state.options }

    var body: some View {
        ScrollViewReader { proxy in
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
                    recheck: Binding(get: { controller.state.recheck }, set: { controller.setRecheck($0) }),
                    setID: controller.setID
                ) { controller.updateOptions($0) }
            }
            .formStyle(.grouped)
            .task {
                // Opened from the recheck hint: straight to "Nachkontrolle nach Fehlern".
                guard controller.takeRecheckReveal() else { return }
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation { proxy.scrollTo(LearnOptionsCopy.recheckAnchor, anchor: .center) }
            }
        }
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
    /// The set whose own "Soundeffekte" and synonyms switches show (nil: none).
    var setID: String? = nil
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
            if let setID {
                SetSoundEffectsToggle(setID: setID)
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

/// "Synonyme ausserhalb des Sets erlauben" of a set (Toleranz in its Lernen and Schreiben
/// options): words with the same meaning that are not in the set (`SynonymAssistant`). A setting
/// of this Mac like `SetSoundEffectsToggle`, so "Auf Standard zurücksetzen" leaves it. Off in
/// Settings ("Weitere Synonyme erkennen") or without Apple Intelligence: off and locked. Synonym
/// cards of the set count either way.
struct SetExtendedSynonymsToggle: View {
    @AppStorage(SynonymAssistant.defaultsKey) private var everywhere = true
    @AppStorage private var on: Bool

    init(setID: String) {
        _on = AppStorage(wrappedValue: true, SynonymAssistant.setKey(setID))
    }

    var body: some View {
        let unavailable = SynonymAssistant.shared.unavailableReason
        let locked = !everywhere || unavailable != nil
        Toggle(isOn: Binding(get: { !locked && on }, set: { on = $0 })) {
            Text(LearnOptionsCopy.synonymsLabel)
            Text(unavailable ?? (everywhere ? LearnOptionsCopy.synonymsNote : LearnOptionsCopy.synonymsOffEverywhere))
        }
        .disabled(locked)
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
            // "Optionen" in the hint at the first recheck scrolls here.
            .id(LearnOptionsCopy.recheckAnchor)
        } header: {
            Text("Wiederholung")
        } footer: {
            Text(LearnOptionsCopy.globalSwitchesFooter)
                .foregroundStyle(.secondary)
        }
    }
}

/// "Soundeffekte" of a set (Lernen and Schreiben options): a setting of this Mac, not a study
/// option, so it is not among the set's own options and "Auf Standard zurücksetzen" leaves it.
/// Off in Settings: off and locked. Windows: StudyChrome.SoundSwitch.
struct SetSoundEffectsToggle: View {
    @AppStorage(SoundEffects.defaultsKey) private var everywhere = true
    @AppStorage private var on: Bool

    init(setID: String) {
        _on = AppStorage(wrappedValue: true, SoundEffects.setKey(setID))
    }

    var body: some View {
        Toggle(isOn: Binding(get: { everywhere && on }, set: { on = $0 })) {
            Text(LearnOptionsCopy.soundLabel)
            Text(everywhere ? LearnOptionsCopy.soundNote : LearnOptionsCopy.soundOffEverywhere)
        }
        .disabled(!everywhere)
        .onChange(of: on) { _, isOn in
            // A taste of what comes back, like the switch in Settings.
            if isOn { SoundEffects.shared.play(.correct) }
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
            report(error, fallback: String(localized: "Die Optionen konnten nicht zurückgesetzt werden."))
            return nil
        }
        toasts.show(String(localized: "Dieses Lernset folgt wieder dem Standard"), tone: .success)
        return store.getStudyOptions(setID)
    }
}

/// Texts of the options form (src/ui/study-options.js, Learn mode).
enum LearnOptionsCopy {
    struct Side {
        /// How a side is named: by its language, as Begriff/Definition (both sides share a
        /// language) or as Lernsprache/Übersetzung (no language set). Picks the whole sentence
        /// of `directionText`.
        enum Kind { case language, shared, unknown }

        let label: String
        let kind: Kind
    }

    static let lockHint = String(localized: "Mindestens ein Fragetyp bleibt aktiv.")

    /// The round size: after so many questions the checkpoint shows the interim result (since 1.4
    /// a round is questions, not a group of terms).
    static let roundSizeLabel = String(localized: "Fragen pro Runde")
    static let roundSizeNote = String(localized: "Nach so vielen Fragen siehst du deinen Zwischenstand.")

    /// The two Learn switches that hold for every set (`UserDefaults`, not study options).
    static let reviewLabel = String(localized: "Wiederholungsfragen")
    static let reviewNote = String(
        localized:
            "Gemeisterte Begriffe kommen zwischendurch nochmals dran. Ist eine Antwort falsch, ist der Begriff wieder am Lernen."
    )
    static let recheckLabel = String(localized: "Nachkontrolle nach Fehlern")
    static let recheckNote = String(
        localized:
            "Hattest du einen Begriff einmal falsch, kommt er nach dem Meistern etwa 30 bis 50 Fragen später nochmals. Nur bei Lernsets mit mehr als 60 Begriffen."
    )
    static let globalSwitchesFooter = String(localized: "Gilt sofort für alle Lernsets, auch beim angefangenen Lernen.")
    /// Scroll target of "Nachkontrolle nach Fehlern" (the recheck hint's "Optionen").
    static let recheckAnchor = "learn-options-recheck"

    /// "Soundeffekte" of a set (its options; a setting of this Mac, `SetSoundEffectsToggle`).
    static let soundLabel = String(localized: "Soundeffekte")
    static let soundNote = String(
        localized: "Töne bei Antworten und geschafften Runden. Gilt nur für dieses Lernset und nur auf diesem Mac.")
    static let soundOffEverywhere = String(
        localized: "In den Einstellungen sind die Soundeffekte für alle Lernsets ausgeschaltet.")

    /// Synonyms outside the set of a set (Toleranz; a setting of this Mac, `SetExtendedSynonymsToggle`).
    static let synonymsLabel = String(localized: "Synonyme ausserhalb des Sets erlauben")
    static let synonymsNote = String(
        localized:
            "«ensemble» für «gemeinsam», erkannt mit Apple Intelligence. Steht ein Synonym als eigene Karte im Lernset, zählt es immer. Gilt nur für dieses Lernset und nur auf diesem Mac."
    )
    static let synonymsOffEverywhere = String(
        localized: "In den Einstellungen ist «Weitere Synonyme erkennen» für alle Lernsets ausgeschaltet.")

    /// What a set's options change from the standard (Einstellungen), as short phrases in the
    /// order of the options ("Multiple Choice: aus", "10 Fragen pro Runde"); empty when the set
    /// follows the standard.
    static func deviations(
        _ own: StudyOptions, standard: StudyOptions, names: (term: Side, definition: Side), termLang: Lang
    ) -> [String] {
        // "Vorlesen: an" / "Vorlesen: aus".
        func onOff(_ label: String, _ on: Bool) -> String {
            on
                ? String(localized: "\(label): an", comment: "An option that is switched on, e.g. «Vorlesen: an»")
                : String(localized: "\(label): aus", comment: "An option that is switched off, e.g. «Vorlesen: aus»")
        }
        var out: [String] = []
        if own.answerWith != standard.answerWith {
            switch own.answerWith {
            case .term: out.append(String(localized: "Antworten auf \(names.term.label)"))
            case .definition: out.append(String(localized: "Antworten auf \(names.definition.label)"))
            case .both: out.append(String(localized: "Antworten auf beides"))
            }
        }
        if own.learn.mc != standard.learn.mc { out.append(onOff(String(localized: "Multiple Choice"), own.learn.mc)) }
        if own.learn.written != standard.learn.written { out.append(onOff(String(localized: "Schriftlich"), own.learn.written)) }
        if own.learn.roundSize != standard.learn.roundSize {
            out.append(String(localized: "\(own.learn.roundSize) Fragen pro Runde"))
        }
        if own.learn.retype != standard.learn.retype {
            out.append(onOff(String(localized: "Abtippen nach Fehler (Lernen)"), own.learn.retype))
        }
        if own.shuffle != standard.shuffle { out.append(onOff(String(localized: "Mischen"), own.shuffle)) }
        if own.copyAnswer != standard.copyAnswer {
            out.append(onOff(String(localized: "Abtippen nach Fehler (Schreiben)"), own.copyAnswer))
        }
        if own.autoAdvance != standard.autoAdvance { out.append(onOff(String(localized: "Automatisch weiter"), own.autoAdvance)) }
        if own.audio != standard.audio { out.append(onOff(String(localized: "Vorlesen"), own.audio)) }
        for item in toleranceItems(termLang: termLang)
        where own.tolerance[keyPath: item.keyPath] != standard.tolerance[keyPath: item.keyPath] {
            out.append(onOff(item.label, own.tolerance[keyPath: item.keyPath]))
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
                Side(label: String(localized: "Begriff"), kind: .shared),
                Side(label: String(localized: "Definition"), kind: .shared)
            )
        }
        func named(_ lang: Lang) -> Side {
            Side(label: Labels.langName(lang), kind: .language)
        }
        return (
            termLang != .other ? named(termLang) : Side(label: String(localized: "Lernsprache"), kind: .unknown),
            defLang != .other ? named(defLang) : Side(label: String(localized: "Übersetzung"), kind: .unknown)
        )
    }

    /// "Du siehst Deutsch und antwortest auf Französisch." (`directionText` in Learn mode): one
    /// whole sentence per way the two sides are named.
    static func directionText(_ answerWith: AnswerWith, names: (term: Side, definition: Side)) -> String {
        let term = names.term
        let definition = names.definition
        switch answerWith {
        case .both:
            return String(localized: "Die Richtung wechselt zufällig von Frage zu Frage.")
        case .definition:
            // The term is shown, the definition is the answer.
            switch (term.kind, definition.kind) {
            case (.shared, _), (_, .shared):
                return String(localized: "Du siehst den Begriff und antwortest mit der Definition.")
            case (.language, .language):
                return String(localized: "Du siehst \(term.label) und antwortest auf \(definition.label).")
            case (.language, .unknown):
                return String(localized: "Du siehst \(term.label) und antwortest mit der Übersetzung.")
            case (.unknown, .language):
                return String(localized: "Du siehst den Begriff in der Lernsprache und antwortest auf \(definition.label).")
            case (.unknown, .unknown):
                return String(localized: "Du siehst den Begriff in der Lernsprache und antwortest mit der Übersetzung.")
            }
        case .term:
            // The definition is shown, the term is the answer.
            switch (definition.kind, term.kind) {
            case (.shared, _), (_, .shared):
                return String(localized: "Du siehst die Definition und antwortest mit dem Begriff.")
            case (.language, .language):
                return String(localized: "Du siehst \(definition.label) und antwortest auf \(term.label).")
            case (.language, .unknown):
                return String(localized: "Du siehst \(definition.label) und antwortest in der Lernsprache.")
            case (.unknown, .language):
                return String(localized: "Du siehst die Übersetzung und antwortest auf \(term.label).")
            case (.unknown, .unknown):
                return String(localized: "Du siehst die Übersetzung und antwortest in der Lernsprache.")
            }
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
        case nil: String(localized: "Neue Begriffe kommen zuerst als Multiple Choice, danach schreibst du sie selbst.")
        case .mc: String(localized: "Alle Fragen kommen als Multiple Choice. Mindestens ein Fragetyp bleibt aktiv.")
        case .written: String(localized: "Alle Fragen beantwortest du schriftlich. Mindestens ein Fragetyp bleibt aktiv.")
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
            case .fr: String(localized: "«homme» für «l'homme» – ein falscher Artikel bleibt falsch")
            case .en: String(localized: "«house» für «the house» – ein falscher Artikel bleibt falsch")
            case .es, .it: String(localized: "«casa» für «la casa» – ein falscher Artikel bleibt falsch")
            default: String(localized: "«Herr» für «der Herr» – ein falscher Artikel bleibt falsch")
            }
        let abbreviation: String =
            switch termLang {
            case .fr: String(localized: "«etw.» = «etwas», «qc» = «quelque chose»")
            case .en: String(localized: "«etw.» = «etwas», «sth» = «something»")
            default: String(localized: "«etw.» = «etwas», «jdn.» = «jemanden»")
            }
        let accents: String =
            switch termLang {
            case .fr: String(localized: "«ecole» = «école», «ahnlich» = «ähnlich»")
            case .es: String(localized: "«arbol» = «árbol», «ahnlich» = «ähnlich»")
            case .it: String(localized: "«citta» = «città», «ahnlich» = «ähnlich»")
            // Missing tones count like accents. Arabic has none: its vowel marks never count.
            case .zh: String(localized: "«ni hao» = «nǐ hǎo», «ahnlich» = «ähnlich»")
            default: String(localized: "«ahnlich» = «ähnlich»")
            }
        return [
            ToleranceItem(
                id: "articles", label: String(localized: "Artikel/Pronomen vergessen erlaubt"),
                example: article, keyPath: \.articles, patchKeyPath: \.articles),
            ToleranceItem(
                id: "abbreviations", label: String(localized: "Abkürzungen gleichwertig"), example: abbreviation,
                keyPath: \.abbreviations,
                patchKeyPath: \.abbreviations),
            ToleranceItem(
                id: "multipleAnswers", label: String(localized: "Eine von mehreren Antworten genügt"),
                example: String(localized: "«lieb» reicht bei «lieb, nett»"),
                keyPath: \.multipleAnswers, patchKeyPath: \.multipleAnswers),
            ToleranceItem(
                id: "parentheses", label: String(localized: "Klammerinhalt optional"),
                example: String(localized: "«freuen» für «(sich) freuen»"),
                keyPath: \.parentheses, patchKeyPath: \.parentheses),
            ToleranceItem(
                id: "ignoreCase", label: String(localized: "Gross-/Kleinschreibung ignorieren"),
                example: String(localized: "«herr» = «Herr»"),
                keyPath: \.ignoreCase, patchKeyPath: \.ignoreCase),
            ToleranceItem(
                id: "ignoreAccents", label: String(localized: "Akzente ignorieren"), example: accents,
                keyPath: \.ignoreAccents,
                patchKeyPath: \.ignoreAccents),
            ToleranceItem(
                id: "typos", label: String(localized: "Kleine Tippfehler erlauben"),
                example: String(localized: "«Mädhcen» statt «Mädchen» – ein Buchstabe daneben"),
                keyPath: \.typos, patchKeyPath: \.typos),
        ]
    }
}
