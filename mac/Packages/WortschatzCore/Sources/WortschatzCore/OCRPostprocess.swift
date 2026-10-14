import Foundation

/// Clean-up of recognised text (port of the pure part of src/import/ocr.js).
public enum OCRPostprocess {
    /// Restores umlauts that text recognition read as circumflexes in German text (`fixGermanUmlauts`).
    ///
    /// With a French model loaded, umlauts are often read as circumflexes ("schôn"), and German never
    /// writes â, ô or û. A cell is fixed when it is part of a German table column (unless the cell
    /// itself is clearly French), and any other cell or line only when it is clearly German on its
    /// own. Languages are judged with the doubtful letters made plain, so the misreading does not
    /// count as French evidence. French cells ("le rôle", "tôt") are never changed.
    ///
    /// Lines are table rows with tab-separated cells. Only the precomposed letters â ô û Â Ô Û are
    /// considered (a decomposed "o" + U+0302 is left alone, as in the JS regex).
    public static func fixGermanUmlauts(_ lines: [String]) -> [String] {
        guard lines.contains(where: hasCircumflex) else { return lines }
        let rows = lines.map(splitCells)

        // Column i collects the (plain) non-blank cells of every row with at least two cells. A
        // column that never got a cell stays nil, like a hole in the sparse JS array.
        var columns: [[String]?] = []
        for cells in rows where cells.count >= 2 {
            for (i, cell) in cells.enumerated() where !JSCompat.trim(cell).isEmpty {
                if columns.count <= i { columns.append(contentsOf: repeatElement(nil, count: i + 1 - columns.count)) }
                if columns[i] == nil { columns[i] = [] }
                columns[i]?.append(plain(cell))
            }
        }
        let germanColumn: [Bool] = columns.map { column in
            guard let column else { return false }
            let detection = LangDetect.detectColumn(column)
            return detection.lang == .de && detection.confidence >= 0.6
        }

        return rows.map { cells in
            cells.enumerated().map { i, cell in
                guard hasCircumflex(cell) else { return cell }
                let inGermanColumn = cells.count >= 2 && i < germanColumn.count && germanColumn[i]
                return isGerman(cell, inGermanColumn: inGermanColumn) ? umlauted(cell) : cell
            }.joined(separator: "\t")
        }
    }

    // MARK: - Helpers

    private static func isGerman(_ cell: String, inGermanColumn: Bool) -> Bool {
        let detection = LangDetect.detectLanguage(plain(cell))
        if inGermanColumn { return !(detection.lang == .fr && detection.confidence >= 0.8) }
        return detection.lang == .de && detection.confidence >= 0.9
    }

    /// Circumflex → umlaut (`UMLAUT_OF`).
    private static let umlautOf: [Unicode.Scalar: Unicode.Scalar] = [
        "â": "ä", "ô": "ö", "û": "ü", "Â": "Ä", "Ô": "Ö", "Û": "Ü",
    ]

    /// Circumflex → plain vowel (`PLAIN_OF`).
    private static let plainOf: [Unicode.Scalar: Unicode.Scalar] = [
        "â": "a", "ô": "o", "û": "u", "Â": "A", "Ô": "O", "Û": "U",
    ]

    /// `/[âôûÂÔÛ]/.test(s)`
    private static func hasCircumflex(_ s: String) -> Bool {
        s.unicodeScalars.contains { umlautOf[$0] != nil }
    }

    private static func plain(_ s: String) -> String { replacing(s, with: plainOf) }

    private static func umlauted(_ s: String) -> String { replacing(s, with: umlautOf) }

    private static func replacing(_ s: String, with table: [Unicode.Scalar: Unicode.Scalar]) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s.unicodeScalars.map { table[$0] ?? $0 })
        return String(out)
    }

    /// `line.split('\t')`: every tab splits, empty cells are kept.
    private static func splitCells(_ line: String) -> [String] {
        line.unicodeScalars.split(separator: "\t", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }
}
