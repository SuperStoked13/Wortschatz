import Foundation

/// Long words in a study text (Lernen's and Schreiben's prompt, a flashcard): a word wider than
/// its line used to break somewhere inside (a few letters or a lone «)» on the next line, Joan
/// 05.11.2026), and only shrinking made long words tiny (Joan 06.11.2026). So the size goes down
/// to `floor` at most until the widest word fits, and a word still too wide is broken at a
/// syllable with «-» at the end of each full line: «Geschwindigkeits-» «begrenzung». Port of
/// Windows' StudyText.FitWords/BreakLongWords (since 25.11.2026 on the Mac too).
///
/// The measuring and the syllables come from the caller (`width`: a text's width at a size;
/// `points`: where a word may be broken, as Character offsets), so the rules run anywhere; the
/// app measures with the system font and takes the system's hyphenation for the text's language.
public enum LongWords {
    /// How small long words may make a text: about 70 %, never below 26 (or the size itself when
    /// smaller).
    public static func floor(_ size: Double) -> Double {
        min(size, max(26, size * 0.7))
    }

    /// The size (in steps of 2, down to `floor`) at which the widest word fits `maxWidth`, and the
    /// text with the words still too wide broken (`breakLongWords`).
    public static func fit(
        _ text: String, size: Double, floor: Double, maxWidth: Double, width: (String, Double) -> Double,
        points: (String) -> [Int]
    ) -> (size: Double, text: String) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var s = size
        while s - 2 >= floor && words.contains(where: { width($0, s) > maxWidth }) { s -= 2 }
        return (s, breakLongWords(text, size: s, maxWidth: maxWidth, width: width, points: points))
    }

    /// Every word wider than `maxWidth` broken at its syllables (`points`, or after a hyphen it
    /// has) with «-» at the end of each piece, each piece as long as the line allows. A line breaks
    /// after a «-», so the pieces end up on lines of their own. Without syllables (Arabic,
    /// Chinese) a word stays as it is; a syllable wider than the line on its own is taken anyway.
    public static func breakLongWords(
        _ text: String, size: Double, maxWidth: Double, width: (String, Double) -> Double, points: (String) -> [Int]
    ) -> String {
        // A little less than the line: measured and laid-out widths can differ by a point.
        let line = maxWidth - 4
        var out = ""
        for part in pieces(text) {
            guard let first = part.first, !first.isWhitespace, width(part, size) > maxWidth else {
                out += part
                continue
            }
            let chars = Array(part)
            var breaks = Set(points(part).filter { $0 > 0 && $0 < chars.count })
            for i in 0..<max(0, chars.count - 1) where chars[i] == "-" { breaks.insert(i + 1) }
            let sorted = breaks.sorted()
            var start = 0
            while width(String(chars[start...]), size) > line {
                var best: Int?
                for p in sorted where p > start {
                    guard width(String(chars[start..<p]) + "-", size) <= line else { break }
                    best = p
                }
                // Even the next syllable is wider than the line: take it anyway.
                guard let cut = best ?? sorted.first(where: { $0 > start }) else { break }
                out += String(chars[start..<cut])
                if chars[cut - 1] != "-" { out += "-" }
                start = cut
            }
            out += String(chars[start...])
        }
        return out
    }

    /// `text` cut into words and the whitespace between them, in order.
    private static func pieces(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSpace: Bool?
        for c in text {
            let space = c.isWhitespace
            if let inSpace, inSpace != space {
                out.append(current)
                current = ""
            }
            current.append(c)
            inSpace = space
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
