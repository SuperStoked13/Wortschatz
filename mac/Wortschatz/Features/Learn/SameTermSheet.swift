import SwiftUI
import WortschatzCore

/// A written answer was wrong for the card but is the answer of another card with the same word
/// («etw. entführen» → «to hijack sth», written «to kidnap sb», the answer of «jmdn. entführen»;
/// Joan 10.11.2026, `SameTermCards`). Learn and Write show `SameTermSheet` for it.
struct SameTermQuestion: Identifiable, Equatable {
    let id = UUID()
    let asked: Card
    let other: Card
    let ask: AskSide
    let promptLang: Lang
    let answerLang: Lang
    let given: String

    var askedPrompt: String { Synonyms.promptSide(asked, ask: ask) }
    var otherPrompt: String { Synonyms.promptSide(other, ask: ask) }
}

/// What the answer counts as.
enum SameTermChoice {
    /// Right for the asked card (like "Ich hatte recht").
    case right
    /// The other card gets a right answer in its progress; the asked card stays wrong and comes again.
    case forOtherCard
    /// Stays wrong (Return and Esc: a slip never counts by accident).
    case wrong
}

/// Shows both cards and asks what the answer counts as; each button's effect is spelled out above it
/// (Joan: «Für … zählen» alone left open what happens). Windows: StudyChrome.AskSameTerm.
struct SameTermSheet: View {
    let question: SameTermQuestion
    let answer: (SameTermChoice) -> Void

    private var choices: [(button: String, explanation: String)] {
        SameTermCards.choices(askedPrompt: question.askedPrompt, otherPrompt: question.otherPrompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(SameTermCards.title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(
                SameTermCards.message(
                    given: question.given, askedPrompt: question.askedPrompt, otherPrompt: question.otherPrompt)
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            cardBox(String(localized: "Gefragt war"), card: question.asked, highlight: false)
            cardBox(String(localized: "Deine Antwort gehört zu"), card: question.other, highlight: true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                ForEach(choices.indices, id: \.self) { i in
                    Text("\(choices[i].button): \(choices[i].explanation)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            buttons
        }
        .padding(Spacing.xl)
        .frame(width: 560)
        .onExitCommand { answer(.wrong) }
    }

    private var buttons: some View {
        HStack(spacing: Spacing.s) {
            Spacer(minLength: 0)
            Button(choices[0].button) { answer(.right) }
            Button(choices[1].button) { answer(.forOtherCard) }
            Button(choices[2].button) { answer(.wrong) }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    private func cardBox(_ label: String, card: Card, highlight: Bool) -> some View {
        let prompt = Synonyms.promptSide(card, ask: question.ask)
        let answerText = Synonyms.answerSide(card, ask: question.ask)
        return VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(LearnText.spoken(prompt, lang: question.promptLang))
                .font(.body.weight(.semibold))
                .cardTextLine(question.promptLang)
            Text(LearnText.spoken(answerText, lang: question.answerLang))
                .foregroundStyle(highlight ? AnyShapeStyle(Theme.success.text) : AnyShapeStyle(.secondary))
                .cardTextLine(question.answerLang)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(
            highlight ? AnyShapeStyle(Theme.success.soft) : AnyShapeStyle(.background.opacity(0.6)),
            in: RoundedRectangle(cornerRadius: Radii.tile, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radii.tile, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Presents `SameTermSheet` for a controller's question (a modifier of its own, so the screens' long
/// modifier chains stay short for the type checker). Closing the sheet any other way counts as wrong.
struct SameTermPresenter: ViewModifier {
    let question: SameTermQuestion?
    let answer: (SameTermChoice) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { question }, set: { if $0 == nil { answer(.wrong) } })) { question in
            SameTermSheet(question: question, answer: answer)
        }
    }
}
