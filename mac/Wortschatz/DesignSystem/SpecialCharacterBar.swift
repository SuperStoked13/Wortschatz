import SwiftUI
import WortschatzCore

/// Accent characters per language for the written-answer field (port of `SPECIAL_CHARS` /
/// `charsFor` in src/lib/keyboard.js).
nonisolated enum SpecialCharacters {
    static let byLanguage: [Lang: [String]] = [
        .fr: ["é", "è", "ê", "ë", "à", "â", "ç", "î", "ï", "ô", "û", "ù", "ü", "œ", "æ"],
        .de: ["ä", "ö", "ü", "Ä", "Ö", "Ü"],
        .es: ["á", "é", "í", "ó", "ú", "ñ", "ü", "¿", "¡"],
        .it: ["à", "è", "é", "ì", "ò", "ù"],
        .en: [],
        // Arabic needs an Arabic keyboard (vowel marks never count); pinyin tones can be typed as
        // numbers (ni3), so only ü.
        .ar: [],
        .zh: ["ü"],
        .other: [],
    ]

    /// `charsFor(lang)`: the characters for a language, empty when it has none.
    static func characters(for lang: Lang?) -> [String] {
        lang.flatMap { byLanguage[$0] } ?? []
    }

    /// `insertAtCaret`: replaces the selection (or inserts at the caret, or appends when there is
    /// no selection) and moves the caret behind the inserted text. Use with
    /// `TextField(text:selection:)`.
    static func insert(_ insertion: String, into text: inout String, selection: inout TextSelection?) {
        var range = text.endIndex..<text.endIndex
        if let selection {
            switch selection.indices {
            case let .selection(selected):
                range = selected
            case let .multiSelection(ranges):
                range = ranges.ranges.first ?? range
            @unknown default:
                break
            }
        }
        // A stale selection (from before an external change) falls back to the end.
        if range.lowerBound < text.startIndex || range.upperBound > text.endIndex {
            range = text.endIndex..<text.endIndex
        }
        let caretOffset = text.utf8.distance(from: text.startIndex, to: range.lowerBound) + insertion.utf8.count
        text.replaceSubrange(range, with: insertion)
        let caret = text.utf8.index(text.startIndex, offsetBy: min(caretOffset, text.utf8.count))
        selection = TextSelection(insertionPoint: caret)
    }
}

/// A row of keycap-like buttons that insert accented characters into the answer field
/// (spec §4.4: é è ê … for French, ä ö ü for German). Plain buttons, so it can sit inside the
/// glass study card. Clicking does not move keyboard focus away from the text field.
/// Renders nothing for languages without special characters.
///
/// ```swift
/// SpecialCharacterBar(lang: set.defLang) { char in
///     SpecialCharacters.insert(char, into: &answer, selection: &selection)
/// }
/// ```
struct SpecialCharacterBar: View {
    let lang: Lang?
    let onInsert: (String) -> Void

    var body: some View {
        let characters = SpecialCharacters.characters(for: lang)
        if !characters.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(characters, id: \.self) { character in
                    Button {
                        onInsert(character)
                    } label: {
                        Text(character)
                    }
                    .buttonStyle(CharacterKeyStyle())
                    .focusable(false)
                    .accessibilityLabel("\(character) einfügen")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sonderzeichen")
        }
    }
}

/// Keycap-looking button for one character.
private struct CharacterKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CharacterKey(configuration: configuration)
    }

    private struct CharacterKey: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            configuration.label
                .font(Typography.specialCharacter)
                .foregroundStyle(isHovered ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.primary))
                .frame(minWidth: 32, minHeight: 30)
                .background {
                    shape.fill(isHovered ? AnyShapeStyle(Theme.accentSoft) : AnyShapeStyle(.quaternary))
                }
                .overlay {
                    shape.strokeBorder(isHovered ? AnyShapeStyle(Theme.accent.opacity(0.5)) : AnyShapeStyle(.tertiary), lineWidth: 0.5)
                }
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .animation(Motion.snappy, value: configuration.isPressed)
                .animation(Motion.snappy, value: isHovered)
        }
    }
}

/// Lays children out left to right and wraps onto new lines (chips, special characters).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
