import SwiftUI
import WortschatzCore

/// "Prüfung einrichten": how many words, the time limit, the direction, what a small mistake
/// costs and (with starred cards) only the starred ones. Every change is kept for every set.
/// "Prüfung starten ↩" in the bar.
struct ExamSetupView: View {
    let controller: ExamController

    private var settings: ExamSettings { controller.settings }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                header
                settingsCard
                notes
            }
            .frame(maxWidth: 660)
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            ExamBar {
                ExamBarPill {
                    Label(summary, systemImage: "list.number")
                        .lineLimit(1)
                }
            } trailing: {
                SecondaryButton("Zurück zum Lernset", key: .escape, bindsShortcut: false, action: controller.exit)
                PrimaryActionButton("Prüfung starten", systemImage: ExamSymbols.mode, action: controller.start)
                    .accessibilityIdentifier("exam-start")
            }
            .reservesToastSpace()
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(spacing: Spacing.s) {
            ZStack {
                Circle()
                    .fill(Theme.accent.gradient)
                    .frame(width: 80, height: 80)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 5)
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, Spacing.xs)
            .accessibilityHidden(true)
            Text("Prüfungsmodus")
                .eyebrowStyle()
            Text("Prüfung einrichten")
                .font(Typography.display)
                .accessibilityAddTraits(.isHeader)
            Text("Alle Fragen auf einer Seite, mit Zeitlimit und einer Note wie in der Schule.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var settingsCard: some View {
        let names = LearnOptionsCopy.sideNames(termLang: controller.set.termLang, defLang: controller.set.defLang)
        let available = Exam.scope(controller.set.cards, settings: settings).count
        return GlassCard(padding: Spacing.xl, cornerRadius: Radii.panel) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                ExamSettingRow(title: String(localized: "Wörter"), systemImage: "number", caption: countCaption(available)) {
                    Picker("Wörter", selection: countBinding(available)) {
                        ForEach(countChoices(available), id: \.self) { count in
                            Text(count == 0 ? "Alle \(available)" : "\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Divider()
                ExamSettingRow(title: String(localized: "Zeitlimit"), systemImage: ExamSymbols.timer, caption: timeCaption) {
                    Picker("Zeitlimit", selection: binding(\.minutes)) {
                        ForEach(ExamSettings.minuteChoices, id: \.self) { minutes in
                            Text(minutes == 0 ? "Ohne" : "\(minutes) Min.").tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                ExamSettingRow(
                    title: String(localized: "Antworten auf"), systemImage: "arrow.left.arrow.right",
                    caption: LearnOptionsCopy.directionText(settings.answerWith, names: names)
                ) {
                    Picker("Antworten auf", selection: binding(\.answerWith)) {
                        Text(names.term.label).tag(AnswerWith.term)
                        Text(names.definition.label).tag(AnswerWith.definition)
                        Text("Beides").tag(AnswerWith.both)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Divider()
                ExamSettingRow(
                    title: String(localized: "Kleine Fehler"), systemImage: "checkmark.seal",
                    caption: ExamCopy.toleranceText(settings.tolerance)
                ) {
                    Picker("Kleine Fehler", selection: binding(\.tolerance)) {
                        ForEach(ExamTolerance.allCases, id: \.self) { tolerance in
                            Text(ExamCopy.toleranceTitle(tolerance)).tag(tolerance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .help(ExamCopy.smallMistakesText)
                if controller.starredCount > 0 {
                    Divider()
                    ExamToggleRow(
                        title: String(localized: "Nur markierte (\(controller.starredCount))"), systemImage: "star",
                        caption: String(localized: "Nur die Begriffe mit Stern abfragen."), isOn: binding(\.starredOnly))
                }
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(ExamCopy.smallMistakesText, systemImage: "info.circle")
            Label("Die Prüfung zählt nicht für «Gemeistert». Was falsch ist, kannst du danach gezielt lernen.", systemImage: "sparkles")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xs)
    }

    // MARK: Values

    /// "20 Wörter · 10 Minuten".
    private var summary: String {
        let count = controller.plannedCount
        return "\(Labels.plural(count, "Wort", "Wörter")) · \(ExamCopy.minutes(settings.minutes))"
    }

    private func countChoices(_ available: Int) -> [Int] {
        ExamSettings.countChoices.filter { $0 == 0 || $0 < available }
    }

    /// The count on the picker: "Alle" when the set has no more words than asked for.
    private func countBinding(_ available: Int) -> Binding<Int> {
        Binding(
            get: { settings.count <= 0 || settings.count >= available ? 0 : settings.count },
            set: { count in controller.update { $0.count = count } })
    }

    private func countCaption(_ available: Int) -> String {
        let planned = controller.plannedCount
        return planned >= available
            ? String(localized: "Alle Begriffe, in zufälliger Reihenfolge.")
            : String(localized: "\(planned) von \(available) Begriffen, zufällig ausgewählt.")
    }

    private var timeCaption: String {
        guard settings.minutes > 0 else {
            return String(localized: "So viel Zeit, wie du brauchst. Die Zeit wird trotzdem gemessen.")
        }
        let suggested = max(1, Int((Double(controller.plannedCount) * 0.5).rounded(.up)))
        return String(
            localized:
                "Ist die Zeit um, wird abgegeben. Empfohlen: etwa \(Labels.plural(suggested, "Minute", "Minuten")) für \(Labels.plural(controller.plannedCount, "Wort", "Wörter")).")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ExamSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in controller.update { $0[keyPath: keyPath] = value } })
    }
}

/// A setting of the exam: symbol, title and caption on the left (the caption wraps), the control
/// on the right at its own width, the same in every row.
private struct ExamSettingRow<Control: View>: View {
    let title: String
    let systemImage: String
    let caption: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            control
                .fixedSize()
        }
    }

    private var label: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            ExamSettingIcon(systemImage: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.headline)
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A switch of the exam settings.
private struct ExamToggleRow: View {
    let title: String
    let systemImage: String
    let caption: String

    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.s) {
                ExamSettingIcon(systemImage: systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typography.headline)
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.s)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// The accent symbol in front of a setting.
private struct ExamSettingIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.accentText)
            .frame(width: 28, height: 28)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}
