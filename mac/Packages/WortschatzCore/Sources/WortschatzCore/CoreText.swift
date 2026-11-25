import Foundation

/// The language of the core's UI texts. The core writes them in German (the source language,
/// Swiss spelling: "ss", never the sharp s) and passes each one through `CoreText.translate`.
/// The Mac app points it at its String Catalog at launch (`AppLanguage.install`); unset, as in
/// `swift test`, on Linux and for the parity fixtures, every text stays German, word for word.
public enum CoreText {
    /// German text (a `%@` format for `L(_:_:)`) → the same text in the app's language. Set once,
    /// before the first text is built.
    nonisolated(unsafe) public static var translate: @Sendable (String) -> String = { $0 }

    /// The same for a string table of its own (`L(table:_:)`, `<table>.xcstrings`): German text,
    /// table name → the text in the app's language.
    nonisolated(unsafe) public static var translateInTable: @Sendable (String, String) -> String = { text, _ in text }

    /// Fills a format: `%@` takes the next argument, `%1$@`, `%2$@` … a numbered one (for
    /// translations that reorder them), `%%` is a percent sign. Anything else stays as written.
    public static func fill(_ format: String, _ args: [String]) -> String {
        var out = ""
        var next = 0
        var i = format.startIndex
        while i < format.endIndex {
            let c = format[i]
            guard c == "%" else {
                out.append(c)
                i = format.index(after: i)
                continue
            }
            let rest = format[format.index(after: i)...]
            if rest.hasPrefix("%") {
                out.append("%")
                i = format.index(i, offsetBy: 2)
            } else if rest.hasPrefix("@") {
                out += next < args.count ? args[next] : ""
                next += 1
                i = format.index(i, offsetBy: 2)
            } else if let dollar = rest.firstIndex(of: "$"),
                let n = Int(rest[rest.startIndex..<dollar]), n >= 1,
                format[format.index(after: dollar)...].hasPrefix("@")
            {
                out += n <= args.count ? args[n - 1] : ""
                i = format.index(dollar, offsetBy: 2)
            } else {
                out.append(c)
                i = format.index(after: i)
            }
        }
        return out
    }
}

/// A German UI text in the app's language.
package func L(_ german: String) -> String {
    CoreText.translate(german)
}

/// A German UI text with `%@` placeholders in the app's language, filled with `args` in order:
/// `L("Runde %@ geschafft", "\(round)")`. The arguments are not translated.
package func L(_ format: String, _ args: String...) -> String {
    CoreText.fill(CoreText.translate(format), args)
}

/// A German UI text of the string table `table` (a String Catalog of its own,
/// `<table>.xcstrings`, for texts not every build of the app carries) in the app's language.
package func L(table: String, _ german: String) -> String {
    CoreText.translateInTable(german, table)
}

/// `L(_:_:)` for the string table `table`.
package func L(table: String, _ format: String, _ args: String...) -> String {
    CoreText.fill(CoreText.translateInTable(format, table), args)
}
