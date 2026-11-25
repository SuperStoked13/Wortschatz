import SwiftUI
import WortschatzCore

#if os(macOS)
import AppKit
private typealias PlatformFont = NSFont
#else
import UIKit
private typealias PlatformFont = UIFont
#endif

/// A study text (Lernen's and Schreiben's prompt, a flashcard's side) whose long words never break
/// somewhere inside: the size goes down to about 70 % at most (never below 26) until the widest
/// word fits, and a word still too wide is broken at a syllable with «-» (`LongWords` in the
/// package; the syllables from the system's hyphenation for the text's language, none for Arabic
/// and Chinese). Port of Windows' StudyText.FitWords (since 25.11.2026; before, a long word broke
/// anywhere, and a flashcard only shrank it, down to 55 %). Fills the width it is offered and
/// measures it; VoiceOver reads the text without the inserted hyphens.
struct LongWordText: View {
    let text: String
    let lang: Lang
    let size: CGFloat
    var weight: Font.Weight = .semibold
    var alignment: Alignment = .leading

    @State private var width: CGFloat = 0

    var body: some View {
        let fitted = LongWordFit.fit(text, lang: lang, size: size, weight: weight, maxWidth: width)
        Text(LearnText.spoken(fitted.text, lang: lang))
            .font(.system(size: fitted.size, weight: weight, design: .rounded))
            .accessibilityLabel(Text(LearnText.spoken(text, lang: lang)))
            .frame(maxWidth: .infinity, alignment: alignment)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The measuring and the syllables for `LongWords`.
enum LongWordFit {
    /// `text` at `size` for a line of `maxWidth` (0: not measured yet, as it is).
    static func fit(_ text: String, lang: Lang, size: CGFloat, weight: Font.Weight, maxWidth: CGFloat)
        -> (size: CGFloat, text: String)
    {
        // Chinese breaks between any two characters anyway. A word can only be too wide when it
        // has more characters than the line has room for at one em each (most never are).
        guard maxWidth > 40, lang != .zh,
            text.split(whereSeparator: \.isWhitespace).contains(where: { CGFloat($0.count) * size > maxWidth - 4 })
        else { return (size, text) }
        // One font per size tried (a fit measures 10–40 times, mostly at the same few sizes).
        var fonts: [CGFloat: PlatformFont] = [:]
        let r = LongWords.fit(
            text, size: Double(size), floor: LongWords.floor(Double(size)), maxWidth: Double(maxWidth),
            width: { text, size in
                let size = CGFloat(size)
                let font = fonts[size] ?? roundedFont(size: size, weight: weight)
                fonts[size] = font
                return width(of: text, font: font)
            },
            points: { points(in: $0, lang: lang) })
        return (CGFloat(r.size), r.text)
    }

    /// The width of `text` in the rounded system font.
    static func width(of text: String, size: CGFloat, weight: Font.Weight) -> Double {
        width(of: text, font: roundedFont(size: size, weight: weight))
    }

    private static func width(of text: String, font: PlatformFont) -> Double {
        Double((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The rounded system font (`.system(size:weight:design: .rounded)`).
    private static func roundedFont(size: CGFloat, weight: Font.Weight) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size, weight: platformWeight(weight))
        return base.fontDescriptor.withDesign(.rounded).flatMap { PlatformFont(descriptor: $0, size: size) } ?? base
    }

    /// Where the system's hyphenation for `lang` may break `word` (Character offsets).
    static func points(in word: String, lang: Lang) -> [Int] {
        let tag = Labels.info(lang).bcp47
        guard !tag.isEmpty else { return [] }
        let locale = Locale(identifier: tag) as CFLocale
        guard CFStringIsHyphenationAvailableForLocale(locale) else { return [] }
        let s = word as CFString
        let length = CFStringGetLength(s)
        var out: [Int] = []
        var before = length
        while before > 0 {
            let p = CFStringGetHyphenationLocationBeforeIndex(s, before, CFRange(location: 0, length: length), 0, locale, nil)
            guard p != kCFNotFound, p > 0, p < before else { break }
            let utf16 = word.utf16.index(word.utf16.startIndex, offsetBy: p)
            if let index = utf16.samePosition(in: word) { out.append(word.distance(from: word.startIndex, to: index)) }
            before = p
        }
        return out.reversed()
    }

    private static func platformWeight(_ weight: Font.Weight) -> PlatformFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

#if DEBUG
// MARK: - Snapshots

/// Long words on a flashcard and a prompt line, before and after: German, French, a compound
/// with a hyphen, Arabic (no syllables) and a sentence (`--snapshot-filter design-long-words`).
final class LongWordSnapshots: SnapshotCatalog {
    override class var scenes: [SnapshotScene] {
        [SnapshotScene("design-long-words", size: CGSize(width: 1100, height: 760)) { LongWordSamples() }]
    }
}

private struct LongWordSamples: View {
    private let samples: [(String, Lang)] = [
        ("die Geschwindigkeitsbegrenzung", .de),
        ("Donaudampfschifffahrtsgesellschaftskapitän", .de),
        ("anticonstitutionnellement", .fr),
        ("Rhein-Main-Verkehrsverbundgesellschaft", .de),
        ("مستشفىمستشفىمستشفى", .ar),
        ("Je voudrais un café, s’il vous plaît.", .fr),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: "Prompt, 320 pt").font(.caption).foregroundStyle(.secondary)
                ForEach(samples, id: \.0) { text, lang in
                    LongWordText(text: text, lang: lang, size: Typography.promptSize(for: text))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 320)
                        .border(.red.opacity(0.3))
                }
            }
            VStack(spacing: 18) {
                Text(verbatim: "Karteikarte, 420 pt").font(.caption).foregroundStyle(.secondary)
                ForEach(samples, id: \.0) { text, lang in
                    let m = Typography.flashcardMetrics(for: text)
                    LongWordText(text: text, lang: lang, size: m.size, weight: m.weight, alignment: .center)
                        .multilineTextAlignment(.center)
                        .lineLimit(7)
                        .cardTextDirection(lang)
                        .frame(width: 420)
                        .border(.red.opacity(0.3))
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}
#endif
