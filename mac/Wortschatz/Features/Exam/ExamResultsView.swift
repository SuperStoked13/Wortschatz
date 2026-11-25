import SwiftUI
import WortschatzCore

/// The marked exam: the Swiss grade with a verdict, the points and the time, the counts as glass
/// tiles and every answer with its mark (what was typed, with the mistakes marked, and the right
/// answer). "Falsche lernen", "Falsche prüfen", "Neue Prüfung" and "Fertig ↩" in the bar.
struct ExamResultsView: View {
    let controller: ExamController

    var body: some View {
        if let result = controller.result {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    ExamGradeHero(result: result)
                    ExamResultTiles(result: result)
                    ExamAnswerList(result: result, set: controller.set)
                }
                .frame(maxWidth: LayoutMetrics.studyColumnWidth)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.xl)
                .frame(maxWidth: .infinity)
                .modifier(ExamCelebration(isActive: result.grade >= 5.5))
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    bar(result, isCompact: false)
                    bar(result, isCompact: true)
                }
                .reservesToastSpace()
            }
        }
    }

    private func bar(_ result: ExamResult, isCompact: Bool) -> some View {
        let toPractise = result.cardIdsToPractise.count
        return ExamBar {
            SecondaryButton(
                verbatim: isCompact
                    ? String(localized: "Neu", comment: "Button (compact): a new exam")
                    : String(localized: "Neue Prüfung"),
                systemImage: "arrow.counterclockwise",
                key: .shiftCommand("R"), bindsShortcut: false, action: controller.requestNewExam)
        } trailing: {
            if toPractise > 0 {
                SecondaryButton(
                    verbatim: isCompact
                        ? String(localized: "Lernen", comment: "Button (compact): learn the wrong answers")
                        : String(localized: "Falsche lernen"),
                    systemImage: "sparkles", action: controller.learnMistakes)
                    .help("Die \(Labels.plural(toPractise, "Frage", "Fragen")) mit Fehlern in Lernen üben")
                SecondaryButton(
                    verbatim: isCompact
                        ? String(localized: "Prüfen", comment: "Button (compact): a new exam with only the wrong answers")
                        : String(localized: "Falsche prüfen"),
                    systemImage: ExamSymbols.mode, action: controller.retakeMistakes)
                    .help("Eine neue Prüfung nur mit den \(Labels.plural(toPractise, "Frage", "Fragen")) mit Fehlern")
            }
            PrimaryActionButton("Fertig", action: controller.exit)
                .accessibilityIdentifier("exam-done")
        }
    }
}

/// The grade in a large circle, the verdict, the points and the time.
private struct ExamGradeHero: View {
    let result: ExamResult

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotRendering) private var isSnapshot
    @State private var isShown = false

    var body: some View {
        let grade = result.grade
        let palette = ExamGradeStyle.palette(grade)
        VStack(spacing: Spacing.s) {
            ZStack {
                Circle()
                    .fill(palette.fill.gradient)
                    .frame(width: 132, height: 132)
                    .shadow(color: palette.fill.opacity(0.35), radius: 18, y: 7)
                VStack(spacing: 0) {
                    Text("Note")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .opacity(0.85)
                    Text(Exam.gradeText(grade))
                        .font(.system(size: 50, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
            }
            .scaleEffect(isShown || reduceMotion || isSnapshot ? 1 : 0.86)
            .opacity(isShown || reduceMotion || isSnapshot ? 1 : 0)
            .padding(.bottom, Spacing.xs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Note \(Exam.gradeText(grade))")

            Text(Exam.verdict(grade))
                .font(Typography.display)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if result.timedOut {
                Label("Die Zeit war um, die Prüfung wurde abgegeben.", systemImage: "clock.badge.exclamationmark")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.warning.text)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(Motion.arrive(0.6).delay(0.1)) { isShown = true }
        }
    }

    /// "17.5 von 20 Punkten in 8:41" (the verdict says whether it passes).
    private var subtitle: String {
        let seconds = Int((result.elapsedMs / 1000).rounded())
        return String(localized: "\(ExamCopy.scoreLine(result)) in \(ExamTime.clock(seconds))")
    }
}

/// Colours of a grade: green from 5, the accent from 4, amber below.
enum ExamGradeStyle {
    static func palette(_ grade: Double) -> Theme.StatusPalette {
        if grade >= 5 { return Theme.success }
        if grade >= 4 { return Theme.StatusPalette(fill: Theme.accent, text: Theme.accentText, soft: Theme.accentSoft) }
        return Theme.warning
    }
}

/// Richtig · Kleine Fehler · Falsch · Ohne Antwort.
private struct ExamResultTiles: View {
    let result: ExamResult

    var body: some View {
        let minor = result.count(.minor)
        let blank = result.count(.blank)
        Grid(horizontalSpacing: Spacing.s, verticalSpacing: Spacing.s) {
            GridRow {
                StatTile(
                    String(localized: "Richtig"), value: "\(result.count(.correct))", systemImage: "checkmark",
                    tint: Theme.success.fill, caption: String(localized: "ganzer Punkt"))
                StatTile(
                    String(localized: "Kleine Fehler"), value: "\(minor)", systemImage: "checkmark.seal", tint: Theme.info.fill,
                    caption: minorCaption)
                StatTile(
                    String(localized: "Falsch"), value: "\(result.count(.wrong))", systemImage: "xmark",
                    tint: Theme.failure.fill, caption: String(localized: "kein Punkt"))
                if blank > 0 {
                    StatTile(
                        String(localized: "Ohne Antwort"), value: "\(blank)", systemImage: "minus", tint: Theme.new.fill,
                        caption: String(localized: "kein Punkt"))
                }
            }
        }
    }

    private var minorCaption: String {
        switch result.tolerance {
        case .strict: String(localized: "kein Punkt")
        case .half: String(localized: "je ½ Punkt")
        case .lenient: String(localized: "ganzer Punkt")
        }
    }
}

/// Every answer with its mark, in the order of the sheet.
private struct ExamAnswerList: View {
    let result: ExamResult
    let set: VocabSet

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                Text("Deine Antworten")
                    .font(Typography.title)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(ExamCopy.toleranceText(result.tolerance))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(ExamCopy.smallMistakesText)
            }
            ContentPanel(padding: 0, cornerRadius: Radii.panel) {
                VStack(spacing: 0) {
                    ForEach(result.items) { item in
                        if item.question.number > 1 {
                            Divider().padding(.leading, Spacing.l + 28 + Spacing.m)
                        }
                        ExamAnswerRow(item: item, promptLabel: promptLabel(item.question))
                    }
                }
            }
        }
    }

    private func promptLabel(_ question: ExamQuestion) -> String {
        if set.termLang == set.defLang || question.promptLang == .other {
            return question.ask == .term ? String(localized: "Definition") : String(localized: "Begriff")
        }
        return Labels.langName(question.promptLang)
    }
}

/// One answer: the mark, the question, what was typed (mistakes marked) and the right answer,
/// the note and the points.
private struct ExamAnswerRow: View {
    let item: ExamItemResult
    let promptLabel: String

    var body: some View {
        let q = item.question
        HStack(alignment: .top, spacing: Spacing.m) {
            ExamMarkBadge(item: item)
            VStack(alignment: .leading, spacing: Spacing.xxs + 2) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text("\(q.number).")
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Text(LearnText.spoken(q.prompt, lang: q.promptLang))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .cardTextDirection(q.promptLang)
                }
                answer
                if let note = item.note {
                    TintedChip(text: note, systemImage: noteSymbol, palette: notePalette, size: .small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(pointsText)
                .font(Typography.count)
                .foregroundStyle(item.points > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(minWidth: 28, alignment: .trailing)
                .accessibilityLabel(pointsLabel)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s + 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var answer: some View {
        let q = item.question
        switch item.mark {
        case .correct:
            Text(LearnText.spoken(item.given, lang: q.answerLang))
                .font(Typography.answer)
                .foregroundStyle(Theme.success.text)
                .fixedSize(horizontal: false, vertical: true)
                .cardTextDirection(q.answerLang)
            if item.synonym {
                expectedLine
            }
        case .minor, .wrong:
            // A synonym is compared with its own word, not with the one that was asked.
            StudyDiffText(
                given: item.given, expected: item.matched ?? q.expected, lang: q.answerLang, font: Typography.answer)
            expectedLine
        case .blank:
            Text("Keine Antwort")
                .font(Typography.answer)
                .foregroundStyle(.tertiary)
            expectedLine
        }
    }

    /// "Richtig: la maison".
    private var expectedLine: some View {
        let q = item.question
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(item.mark == .correct || item.matched != nil ? "Gesucht war:" : "Richtig:")
                .foregroundStyle(.secondary)
            Text(LearnText.spoken(q.expected, lang: q.answerLang))
                .fontWeight(.semibold)
                .foregroundStyle(Theme.success.text)
                .cardTextDirection(q.answerLang)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pointsText: String {
        switch item.points {
        case 1: "1"
        case 0.5: "½"
        default: "0"
        }
    }

    private var pointsLabel: String {
        switch item.points {
        case 1: String(localized: "1 Punkt")
        case 0.5: String(localized: "ein halber Punkt")
        default: String(localized: "kein Punkt")
        }
    }

    private var noteSymbol: String {
        switch item.mark {
        case .correct, .minor: "info.circle"
        case .wrong, .blank: "lightbulb.fill"
        }
    }

    private var notePalette: Theme.StatusPalette {
        switch item.mark {
        case .correct, .minor: Theme.info
        case .wrong, .blank: Theme.warning
        }
    }
}

/// ✓, ½ or ✗ in a coloured circle.
private struct ExamMarkBadge: View {
    let item: ExamItemResult

    private var symbol: String {
        switch item.mark {
        case .correct: "checkmark"
        case .minor: item.points >= 1 ? "checkmark" : item.points > 0 ? "circle.lefthalf.filled" : "xmark"
        case .wrong: "xmark"
        case .blank: "minus"
        }
    }

    private var palette: Theme.StatusPalette {
        switch item.mark {
        case .correct: Theme.success
        case .minor: item.points >= 1 ? Theme.success : item.points > 0 ? Theme.info : Theme.failure
        case .wrong: Theme.failure
        case .blank: Theme.new
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(palette.text)
            .frame(width: 28, height: 28)
            .background(palette.soft, in: Circle())
            .padding(.top, 1)
            .accessibilityLabel(ExamCopy.markLabel(item))
    }
}

/// Confetti for a grade of 5.5 or more.
private struct ExamCelebration: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.celebration(origin: UnitPoint(x: 0.5, y: 0.1))
        } else {
            content
        }
    }
}
