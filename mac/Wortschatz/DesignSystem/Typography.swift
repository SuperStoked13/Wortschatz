import SwiftUI

/// Type ramp (spec §4.2). SF Pro everywhere; SF Pro Rounded for "display" moments
/// (study prompt, big numbers, greetings) so the app feels friendly but stays native.
/// Body text keeps the system text styles so it follows the user's settings.
nonisolated enum Typography {
    /// The study prompt: ~40 pt semibold rounded.
    static let prompt = Font.system(size: 40, weight: .semibold, design: .rounded)

    /// Prompt for longer terms (sentences, multiple meanings).
    static let promptMedium = Font.system(size: 32, weight: .semibold, design: .rounded)

    /// Prompt for very long terms.
    static let promptSmall = Font.system(size: 25, weight: .semibold, design: .rounded)

    /// Picks the prompt size for a text, like the web app's `clamp()`: short words get the
    /// full 40 pt, sentences step down so they still fit on two or three lines.
    static func prompt(for text: String) -> Font {
        switch text.count {
        case ..<28: prompt
        case ..<70: promptMedium
        default: promptSmall
        }
    }

    /// The text on a flashcard: a little larger than the study prompt, stepping down for
    /// sentences so they still fit on the card.
    static func flashcard(for text: String) -> Font {
        let m = flashcardMetrics(for: text)
        return .system(size: m.size, weight: m.weight, design: .rounded)
    }

    /// Size and weight of `flashcard(for:)` (rounded), for `LongWordText`.
    static func flashcardMetrics(for text: String) -> (size: CGFloat, weight: Font.Weight) {
        switch text.count {
        case ..<24: (46, .semibold)
        case ..<60: (36, .semibold)
        case ..<140: (28, .semibold)
        default: (22, .medium)
        }
    }

    /// Size of `prompt(for:)` (semibold rounded), for `LongWordText`.
    static func promptSize(for text: String) -> CGFloat {
        switch text.count {
        case ..<28: 40
        case ..<70: 32
        default: 25
        }
    }

    /// Big screen titles ("Guten Morgen", set title in the detail header).
    static let display = Font.system(size: 34, weight: .bold, design: .rounded)

    /// Section and card titles.
    static let title = Font.system(.title2, design: .rounded).weight(.semibold)

    /// Smaller headings inside cards ("Richtige Antwort").
    static let headline = Font.system(.headline, design: .rounded)

    /// Multiple-choice answer text and written answers.
    static let answer = Font.system(.title3, design: .rounded).weight(.medium)

    /// Large written-answer field.
    static let answerField = Font.system(size: 24, weight: .medium, design: .rounded)

    /// `answerField` on a study screen that grew (`studyScale`).
    static func answerField(_ scale: CGFloat) -> Font {
        scale == 1 ? answerField : .system(size: 24 * scale, weight: .medium, design: .rounded)
    }

    /// `answer` (the text of a multiple-choice tile) on a study screen that grew (`studyScale`);
    /// title3 is 15 pt on the Mac.
    static func answer(_ scale: CGFloat) -> Font {
        scale == 1 ? answer : .system(size: 15 * scale, weight: .medium, design: .rounded)
    }

    /// Big statistic numbers (stat tiles, results).
    static let statValue = Font.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit()

    /// Gauge centre percentage.
    static let gaugeValue = Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()

    /// Feedback banner titles ("Super!", "Nicht ganz – das lernst du noch!").
    static let feedbackTitle = Font.system(.title3, design: .rounded).weight(.semibold)

    /// Uppercase eyebrow labels ("FRANZÖSISCH", "RUNDE 2").
    static let eyebrow = Font.system(size: 11, weight: .semibold, design: .rounded)

    /// Counts next to legends and chips.
    static let count = Font.system(.callout, design: .rounded).weight(.semibold).monospacedDigit()

    /// Glyphs on keycaps (↩, ⌥↩, 1-4, esc).
    static let keycap = Font.system(size: 11, weight: .semibold, design: .rounded)

    /// Characters of the special-character bar.
    static let specialCharacter = Font.system(size: 15, weight: .medium, design: .rounded)
}

extension View {
    /// Small uppercase, tracked label ("FRANZÖSISCH · RUNDE 2").
    func eyebrowStyle() -> some View {
        font(Typography.eyebrow)
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}
