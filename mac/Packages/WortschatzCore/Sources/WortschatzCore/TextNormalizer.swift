import Foundation

/// Port of src/core/text.js: shared text normalisation primitives used by the parser and the
/// grader. Works on Unicode scalars (code points) so that results match JS exactly, including
/// strings that are canonically equivalent but not identical.
public enum TextNormalizer {
    /// `[’‘`´ʼ′ʹ]` → "'"
    static func isApostrophe(_ v: UInt32) -> Bool {
        switch v {
        case 0x2019, 0x2018, 0x60, 0xB4, 0x2BC, 0x2032, 0x2B9: return true
        default: return false
        }
    }

    /// `[–—‒‐‑−]` → "-"
    static func isDash(_ v: UInt32) -> Bool {
        switch v {
        case 0x2013, 0x2014, 0x2012, 0x2010, 0x2011, 0x2212: return true
        default: return false
        }
    }

    /// `[      　]` → " "
    static func isOddSpace(_ v: UInt32) -> Bool {
        switch v {
        case 0xA0, 0x2007, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// `[​‌‍⁠﻿]` (removed)
    static func isZeroWidth(_ v: UInt32) -> Bool {
        switch v {
        case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF: return true
        default: return false
        }
    }

    /// Bidi controls (LRM, RLM, ALM, embeddings, overrides, isolates) copied along with Arabic
    /// text: `[‎‏؜‪-‮⁦-⁩]` (removed).
    static func isBidiControl(_ v: UInt32) -> Bool {
        switch v {
        case 0x200E, 0x200F, 0x61C, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    /// NFC, unify apostrophes/dashes/odd spaces, drop zero-width characters and bidi controls,
    /// collapse whitespace and trim. Tabs are kept only when `keepTabs` is true (the parser needs
    /// them as column separators); then only `[ \f\v\r\n]` runs collapse and spaces around tabs
    /// go. `nil` gives "" (JS `s == null`).
    public static func normalizeBasic(_ s: String?, keepTabs: Bool = false) -> String {
        guard let s else { return "" }
        var unified = String.UnicodeScalarView()
        for u in s.precomposedStringWithCanonicalMapping.unicodeScalars {
            let v = u.value
            if isZeroWidth(v) || isBidiControl(v) { continue }
            if isApostrophe(v) {
                unified.append("'")
            } else if isDash(v) {
                unified.append("-")
            } else if isOddSpace(v) {
                unified.append(" ")
            } else {
                unified.append(u)
            }
        }

        var out = String.UnicodeScalarView()
        if keepTabs {
            // .replace(/[ \f\v\r\n]+/g, ' ')
            var collapsed = String.UnicodeScalarView()
            var inRun = false
            for u in unified {
                switch u.value {
                case 0x20, 0x0C, 0x0B, 0x0D, 0x0A:
                    if !inRun { collapsed.append(" ") }
                    inRun = true
                default:
                    collapsed.append(u)
                    inRun = false
                }
            }
            // .replace(/ *\t */g, '\t')
            var skipSpaces = false
            for u in collapsed {
                if u == "\t" {
                    while let last = out.last, last == " " { out.removeLast() }
                    out.append(u)
                    skipSpaces = true
                } else if u == " " && skipSpaces {
                    continue
                } else {
                    out.append(u)
                    skipSpaces = false
                }
            }
        } else {
            // .replace(/\s+/g, ' ')
            var inRun = false
            for u in unified {
                if JSCompat.isWhitespace(u) {
                    if !inRun { out.append(" ") }
                    inRun = true
                } else {
                    out.append(u)
                    inRun = false
                }
            }
        }
        return JSCompat.trim(String(out))
    }

    /// Remove diacritics: é→e, ç→c, ä→a. Ligatures and ß are expanded (ß→ss, œ→oe, æ→ae, ø→o).
    public static func stripDiacritics(_ s: String) -> String {
        var expanded = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0xDF: expanded.append(contentsOf: "ss".unicodeScalars) // ß
            case 0x1E9E: expanded.append(contentsOf: "SS".unicodeScalars) // ẞ
            case 0x153: expanded.append(contentsOf: "oe".unicodeScalars) // œ
            case 0x152: expanded.append(contentsOf: "OE".unicodeScalars) // Œ
            case 0xE6: expanded.append(contentsOf: "ae".unicodeScalars) // æ
            case 0xC6: expanded.append(contentsOf: "AE".unicodeScalars) // Æ
            case 0xF8: expanded.append("o") // ø
            case 0xD8: expanded.append("O") // Ø
            default: expanded.append(u)
            }
        }
        var stripped = String.UnicodeScalarView()
        for u in String(expanded).decomposedStringWithCanonicalMapping.unicodeScalars where !isMark(u) {
            stripped.append(u)
        }
        return String(stripped).precomposedStringWithCanonicalMapping
    }

    /// German-style transliteration: ä→ae, ö→oe, ü→ue (precomposed only, like the JS regexes),
    /// then strip remaining diacritics.
    public static func foldUmlauts(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0xE4: out.append(contentsOf: "ae".unicodeScalars) // ä
            case 0xF6: out.append(contentsOf: "oe".unicodeScalars) // ö
            case 0xFC: out.append(contentsOf: "ue".unicodeScalars) // ü
            case 0xC4: out.append(contentsOf: "Ae".unicodeScalars) // Ä
            case 0xD6: out.append(contentsOf: "Oe".unicodeScalars) // Ö
            case 0xDC: out.append(contentsOf: "Ue".unicodeScalars) // Ü
            default: out.append(u)
            }
        }
        return stripDiacritics(String(out))
    }

    /// `/\p{L}/u.test(ch)`: true when the string contains at least one letter.
    public static func isLetter(_ ch: String) -> Bool {
        ch.unicodeScalars.contains(where: isLetterScalar)
    }

    // MARK: Arabic and Chinese script folds (for comparing only, never applied to stored text)

    /// Arabic script (`ARABIC_RANGE`): U+0600–06FF, U+0750–077F, U+08A0–08FF, U+FB50–FDFF,
    /// U+FE70–FEFE. Explicit ranges: Swift has no Script property.
    public static func isArabicScalar(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x600...0x6FF, 0x750...0x77F, 0x8A0...0x8FF, 0xFB50...0xFDFF, 0xFE70...0xFEFE: return true
        default: return false
        }
    }

    /// Han characters (`HAN_RANGE`): U+3400–4DBF, U+4E00–9FFF, U+F900–FAFF, U+20000–2FA1F.
    public static func isHanScalar(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }

    /// Arabic vowel marks (harakat, shadda, sukun, tanwin, superscript alef), Quranic marks and
    /// tatweel. Madda and hamza (U+0653–U+0655) are not among them: they make letter variants.
    static func isArabicMark(_ v: UInt32) -> Bool {
        switch v {
        case 0x610...0x61A, 0x64B...0x652, 0x656...0x65F, 0x670, 0x6D6...0x6DC, 0x6DF...0x6E8, 0x6EA...0x6ED, 0x640:
            return true
        default:
            return false
        }
    }

    /// Whether the text contains a character of the Arabic script.
    public static func hasArabic(_ s: String) -> Bool { s.unicodeScalars.contains(where: isArabicScalar) }

    /// Whether the text contains a Han character (Chinese).
    public static func hasHan(_ s: String) -> Bool { s.unicodeScalars.contains(where: isHanScalar) }

    /// Arabic vowel marks, Quranic marks and tatweel removed (then NFC): كِتَابٌ → كتاب.
    public static func stripArabicMarks(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars where !isArabicMark(u.value) { out.append(u) }
        return String(out).precomposedStringWithCanonicalMapping
    }

    /// What Arabic and Chinese text treats as the same, folded away (NFC result): presentation
    /// forms → plain letters (NFKC of those characters only), vowel marks, Quranic marks and
    /// tatweel removed, ، ؛ ؟ and full-width/CJK punctuation → ASCII (，→, （→( 、→, 。→. 【→[), no
    /// spaces between two Han characters. Latin text only gets NFC.
    public static func foldScripts(_ s: String) -> String {
        let nfc = s.precomposedStringWithCanonicalMapping
        // Every character the fold changes lies at or above U+0600.
        guard nfc.unicodeScalars.contains(where: { $0.value >= 0x600 }) else { return nfc }
        var plain = String.UnicodeScalarView()
        for u in nfc.unicodeScalars {
            switch u.value {
            case 0xFB50...0xFDFF, 0xFE70...0xFEFE:
                let letters = String(u).precomposedStringWithCompatibilityMapping.unicodeScalars
                for k in letters where !isArabicMark(k.value) { plain.append(k) }
            case let v where isArabicMark(v):
                continue
            default:
                plain.append(u)
            }
        }
        var folded: [Unicode.Scalar] = []
        for u in String(plain).precomposedStringWithCanonicalMapping.unicodeScalars {
            switch u.value {
            case 0x60C, 0x3001: folded.append(",") // ، 、
            case 0x61B: folded.append(";") // ؛
            case 0x61F: folded.append("?") // ؟
            case 0x3002: folded.append(".") // 。
            case 0x3010: folded.append("[") // 【
            case 0x3011: folded.append("]") // 】
            case 0xFF01...0xFF5E: folded.append(Unicode.Scalar(u.value - 0xFEE0)!) // full width → ASCII
            default: folded.append(u)
            }
        }
        // `([HAN]) +(?=[HAN])` → '$1': a run of spaces between two Han characters goes.
        var out = String.UnicodeScalarView()
        var i = 0
        while i < folded.count {
            guard folded[i] == " " else {
                out.append(folded[i])
                i += 1
                continue
            }
            var j = i
            while j < folded.count && folded[j] == " " { j += 1 }
            let betweenHan = i > 0 && isHanScalar(folded[i - 1]) && j < folded.count && isHanScalar(folded[j])
            if !betweenHan { out.append(contentsOf: folded[i..<j]) }
            i = j
        }
        return String(out)
    }

    // MARK: Unicode property helpers (shared with the other ports)

    /// `\p{L}`
    public static func isLetterScalar(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// `\p{M}`
    public static func isMark(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// `\p{N}`
    public static func isNumberScalar(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// `\p{Lu}`
    public static func isUppercaseLetter(_ u: Unicode.Scalar) -> Bool {
        u.properties.generalCategory == .uppercaseLetter
    }

    /// `\p{Ll}`
    public static func isLowercaseLetter(_ u: Unicode.Scalar) -> Bool {
        u.properties.generalCategory == .lowercaseLetter
    }
}
