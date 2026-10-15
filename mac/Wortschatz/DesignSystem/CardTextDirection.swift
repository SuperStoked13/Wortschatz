import SwiftUI
import WortschatzCore

/// The direction card text is written in (spec «Screens»): Arabic runs right to left, every other
/// language left to right. Only the view that holds the card text gets it; the buttons, badges
/// and chips around it keep the app's left-to-right layout.
nonisolated enum CardTextDirection {
    /// The layout direction of a text view: right to left for Arabic (`Lang.isRTL`).
    static func layoutDirection(_ lang: Lang?) -> LayoutDirection {
        lang?.isRTL == true ? .rightToLeft : .leftToRight
    }

    /// The alignment of a text field. AppKit draws a field's text from the left even in a
    /// right-to-left layout (measured: `.leading` becomes natural alignment, which stays left), so
    /// an Arabic field aligns its text, its placeholder and its empty caret to the right edge
    /// within the app's left-to-right layout instead.
    static func fieldAlignment(_ lang: Lang?) -> TextAlignment {
        lang?.isRTL == true ? .trailing : .leading
    }
}

extension View {
    /// Card text in its language's direction: the lines of an Arabic text start at the right edge
    /// of this view. Put it after the text's own frame: a text that fills its line then starts at
    /// the right, one that hugs its words keeps its place and only aligns its lines.
    func cardTextDirection(_ lang: Lang?) -> some View {
        environment(\.layoutDirection, CardTextDirection.layoutDirection(lang))
    }

    /// Card text on a line of its own, starting where its language starts (the right edge for
    /// Arabic).
    func cardTextLine(_ lang: Lang?) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .cardTextDirection(lang)
    }

    /// An answer field in its language's direction (`CardTextDirection.fieldAlignment`).
    func cardFieldDirection(_ lang: Lang?) -> some View {
        multilineTextAlignment(CardTextDirection.fieldAlignment(lang))
    }
}
