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

    /// NFC, unify apostrophes/dashes/odd spaces, drop zero-width characters, collapse
    /// whitespace and trim. Tabs are kept only when `keepTabs` is true (the parser needs them
    /// as column separators); then only `[ \f\v\r\n]` runs collapse and spaces around tabs go.
    /// `nil` gives "" (JS `s == null`).
    public static func normalizeBasic(_ s: String?, keepTabs: Bool = false) -> String {
        guard let s else { return "" }
        var unified = String.UnicodeScalarView()
        for u in s.precomposedStringWithCanonicalMapping.unicodeScalars {
            let v = u.value
            if isZeroWidth(v) { continue }
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
