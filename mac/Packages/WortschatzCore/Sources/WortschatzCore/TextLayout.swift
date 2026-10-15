import Foundation

/// A positioned text fragment (from a PDF page or an OCR word box). Coordinates are top-origin:
/// `x` is the left edge, `y` the baseline (or the bottom of the word box), `w` the width and `h`
/// the glyph/font height. Missing or non-positive `w`/`h` are estimated by `itemsToLines`; items
/// with a non-finite `x`/`y` are skipped by it.
public struct TextItem: Codable, Sendable, Equatable, Hashable {
    public var str: String
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    /// The text direction of a PDF text run (pdf.js `dir`): "rtl" for a right-to-left run, whose
    /// text is in logical order and starts at the right edge. Any other value (or nil) is left to
    /// right. Encoded only when present.
    public var dir: String?

    public init(str: String, x: Double, y: Double, w: Double = 0, h: Double = 0, dir: String? = nil) {
        self.str = str
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.dir = dir
    }

    enum CodingKeys: String, CodingKey { case str, x, y, w, h, dir }

    /// Lenient like `readItems`: numbers or numeric strings (JS `parseFloat`) are accepted; `w`/`h`
    /// default to 0 when missing or invalid. Missing `str`/`x`/`y` decode as ""/0 (use
    /// `init?(json:)` to skip such entries the way `itemsToLines` does in JS).
    public init(from decoder: any Decoder) throws {
        let json = try JSONValue(from: decoder)
        let o = json.objectValue ?? [:]
        str = o["str"].flatMap(TextLayout.jsString) ?? ""
        x = TextLayout.toNumber(o["x"]) ?? 0
        y = TextLayout.toNumber(o["y"]) ?? 0
        w = TextLayout.toNumber(o["w"]) ?? 0
        h = TextLayout.toNumber(o["h"]) ?? 0
        dir = o["dir"]?.stringValue
    }

    /// An item as JS `readItems` reads it: nil when the entry is not an object, has no `str`
    /// (null or missing) or no finite `x`/`y` (numbers or numeric strings). `str` becomes
    /// `String(str)`; invalid `w`/`h` become 0. Whitespace-only strings are kept here and dropped
    /// by `itemsToLines`. `dir` is kept when it is a string (only "rtl" matters, `it.dir === 'rtl'`).
    public init?(json: JSONValue) {
        guard let o = json.objectValue, let raw = o["str"], let str = TextLayout.jsString(raw),
              let x = TextLayout.toNumber(o["x"]), let y = TextLayout.toNumber(o["y"]) else { return nil }
        self.init(
            str: str, x: x, y: y, w: TextLayout.toNumber(o["w"]) ?? 0, h: TextLayout.toNumber(o["h"]) ?? 0,
            dir: o["dir"]?.stringValue)
    }

    /// A right-to-left run (`it.dir === 'rtl'`).
    public var isRightToLeft: Bool { dir == "rtl" }
}

/// Options of `itemsToLines` (JS `opts`).
public struct LayoutOptions: Codable, Sendable, Equatable, Hashable {
    /// Row grouping tolerance as a fraction of the median glyph height (min 0.05).
    public var yTolerance: Double
    /// Horizontal gap (× char width) that splits a row into cells (min 0.5).
    public var gapFactor: Double

    public static let defaultYTolerance = 0.5
    public static let defaultGapFactor = 2.2

    /// Non-finite values fall back to the defaults (JS `toNumber(v) ?? default`).
    public init(yTolerance: Double = LayoutOptions.defaultYTolerance, gapFactor: Double = LayoutOptions.defaultGapFactor) {
        self.yTolerance = yTolerance
        self.gapFactor = gapFactor
    }

    /// `opts || {}`: numbers or numeric strings are taken, anything else gives the default.
    public init(json: JSONValue) {
        let o = json.objectValue ?? [:]
        yTolerance = TextLayout.toNumber(o["yTolerance"]) ?? LayoutOptions.defaultYTolerance
        gapFactor = TextLayout.toNumber(o["gapFactor"]) ?? LayoutOptions.defaultGapFactor
    }

    public init(from decoder: any Decoder) throws {
        self.init(json: try JSONValue(from: decoder))
    }
}

/// A text-line baseline segment `{ x0, y0, x1, y1 }` (top-origin), e.g. from OCR.
public struct BaselineSegment: Codable, Sendable, Equatable, Hashable {
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    /// A segment as `estimateSlope` reads it: nil unless all four coordinates are finite numbers
    /// (or numeric strings).
    public init?(json: JSONValue) {
        guard let o = json.objectValue,
              let x0 = TextLayout.toNumber(o["x0"]), let y0 = TextLayout.toNumber(o["y0"]),
              let x1 = TextLayout.toNumber(o["x1"]), let y1 = TextLayout.toNumber(o["y1"]) else { return nil }
        self.init(x0: x0, y0: y0, x1: x1, y1: y1)
    }
}

/// Port of src/import/layout.js: positioned text items (PDF text runs or OCR word boxes) → plain
/// text lines.
///
/// Pipeline: items → rows (grouped by y) → cells (split at wide horizontal gaps) → page-level
/// column model (gutters found by projecting cells onto the x axis) → reading order:
/// - single column: rows top to bottom, "" at paragraph gaps;
/// - 2-column table: "term\tdefinition" per row, wrapped cells merged;
/// - 4-column table: left pairs first, then right pairs;
/// - stacked pairs per column: each page column top to bottom (term line, definition line, gap, …);
/// - unaligned text columns: each page column top to bottom.
///
/// Right-to-left text (Arabic, Hebrew): a cell whose letters are mostly RTL is read from right to
/// left and belongs to the column of its right edge. Items with `dir` "rtl" (PDF runs) hold their
/// text in logical order, starting at the right edge. Han characters (Chinese) are joined without
/// spaces.
///
/// Strings are handled in UTF-16 code units where the JS code measures them (`str.length`,
/// regex indices), and the floating-point arithmetic follows the JS expression order exactly.
public enum TextLayout {
    /// Reading-order text lines: rows top to bottom, "" at paragraph gaps, "term\tdefinition"
    /// for table rows (see the pipeline above).
    public static func itemsToLines(_ items: [TextItem], options: LayoutOptions = LayoutOptions()) -> [String] {
        let yTolerance = options.yTolerance.isFinite ? options.yTolerance : LayoutOptions.defaultYTolerance
        let gapFactor = options.gapFactor.isFinite ? options.gapFactor : LayoutOptions.defaultGapFactor
        let raw = readItems(items)
        if raw.isEmpty { return [] }
        let metrics = measure(raw)
        let pieces = toPieces(raw, metrics)
        var rows = groupRows(pieces, jsMax(0.05, yTolerance) * metrics.height, metrics)
        for i in rows.indices { rows[i].cells = buildCells(rows[i], metrics, jsMax(0.5, gapFactor)) }
        var textRows = rows.filter { !$0.cells.isEmpty }
        let step = lineStepOf(textRows.map(\.y), metrics.height)
        let ctx = Context(metrics: metrics, paragraph: paragraphFactor * step)

        guard let bounds = findColumnBounds(textRows, metrics) else {
            return tidy(emitRows(textRows, { $0.cells.map(\.text).joined(separator: "\t") }, ctx))
        }

        let k = assignColumns(&textRows, bounds)
        var cols = (0..<k).filter { !isMarkerColumn(textRows, $0) }
        if cols.isEmpty { cols = Array(0..<k) }
        let sentence = sentenceColumn(textRows, cols)
        if sentence >= 0 { cols = cols.filter { $0 != sentence } }
        let joined: (Row) -> String = { r in cols.map { r.cols[$0] }.filter { !$0.isEmpty }.joined(separator: "\t") }

        if cols.count == 1 { return tidy(emitRows(textRows, joined, ctx)) }

        let aligned = textRows.filter { r in cols.filter { !r.cols[$0].isEmpty }.count >= 2 }.count
        let withText = textRows.filter { r in cols.contains { !r.cols[$0].isEmpty } }.count
        let lines: [String]
        if isStackedPairs(textRows, cols, ctx) {
            lines = emitFlow(textRows, cols, ctx)
        } else if aligned >= 2 && Double(aligned) >= 0.3 * Double(withText) {
            lines = cols.count % 2 == 0 ? emitTable(textRows, cols, ctx) : emitRows(textRows, joined, ctx)
        } else if isIndependentFlow(textRows, cols, ctx) {
            lines = emitFlow(textRows, cols, ctx)
        } else {
            lines = emitRows(textRows, joined, ctx)
        }
        return tidy(lines)
    }

    /// Median slope (dy/dx, top-origin) of the baseline segments; segments narrower than
    /// `minWidth` or steeper than 0.35 are ignored, as are segments with non-finite coordinates.
    /// 0 when unknown.
    public static func estimateSlope(_ segments: [BaselineSegment], minWidth: Double = 40) -> Double {
        var slopes: [Double] = []
        for s in segments {
            guard s.x0.isFinite, s.y0.isFinite, s.x1.isFinite, s.y1.isFinite else { continue }
            let dx = s.x1 - s.x0
            if dx < minWidth { continue }
            let slope = (s.y1 - s.y0) / dx
            if abs(slope) <= 0.35 { slopes.append(slope) }
        }
        return slopes.isEmpty ? 0 : median(slopes)
    }

    /// Rotates item positions so that text lines with the given slope become horizontal
    /// (straightens slightly rotated photos before row grouping). Returns the items unchanged for
    /// a non-finite slope or |slope| < 1e-4 or > 0.5; items with a non-finite `x`/`y` are kept as is.
    public static func deskewItems(_ items: [TextItem], slope: Double) -> [TextItem] {
        guard slope.isFinite, abs(slope) >= 1e-4, abs(slope) <= 0.5 else { return items }
        let theta = atan(slope)
        let cosine = cos(theta)
        let sine = sin(theta)
        return items.map { it in
            guard it.x.isFinite, it.y.isFinite else { return it }
            var out = it
            out.x = it.x * cosine + it.y * sine
            out.y = -it.x * sine + it.y * cosine
            return out
        }
    }
}

// MARK: - Pipeline

extension TextLayout {
    /// Gap (× char width) above which two fragments are separate words.
    private static let spaceFactor = 0.25
    /// Vertical gap (× line step) that starts a new paragraph.
    private static let paragraphFactor = 1.8

    private struct RawItem {
        let str: String
        let units: [UInt16]
        let x, y, w, h: Double
        /// A right-to-left run: its pieces are placed from the right edge.
        let rtl: Bool
    }

    private struct Piece {
        let str: String
        let x, y, w, h: Double
        /// Whitespace was trimmed before / after the piece inside its item (a word boundary).
        let lead, trail: Bool
    }

    private struct Cell {
        let text: String
        let x0, x1: Double
        /// Mostly right-to-left letters: read from right to left, anchored at the right edge.
        let rtl: Bool
    }

    private struct Row {
        var items: [Piece]
        var sumY: Double
        var y: Double
        var h = 0.0
        var cells: [Cell] = []
        /// Cell texts per page column (after `assignColumns`).
        var cols: [String] = []
    }

    private struct Metrics {
        let height: Double
        let charW: Double
    }

    private struct Context {
        let metrics: Metrics
        let paragraph: Double
    }

    // MARK: Items

    private static func readItems(_ items: [TextItem]) -> [RawItem] {
        var raw: [RawItem] = []
        for it in items {
            let str = cleaned(it.str)
            if JSCompat.trim(str).isEmpty { continue }
            guard it.x.isFinite, it.y.isFinite else { continue }
            let w = it.w.isFinite && it.w > 0 ? it.w : 0
            let h = it.h.isFinite && it.h > 0 ? it.h : 0
            raw.append(RawItem(str: str, units: Array(str.utf16), x: it.x, y: it.y, w: w, h: h, rtl: it.isRightToLeft))
        }
        return raw
    }

    /// Removes `INVISIBLE` characters and turns `ODD_SPACES` into plain spaces.
    private static func cleaned(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0xAD, 0x200B...0x200D, 0x2060, 0xFEFF:
                continue
            case 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
                out.append(" ")
            default:
                out.append(u)
            }
        }
        return String(out)
    }

    private static func measure(_ raw: [RawItem]) -> Metrics {
        let height = orIfFalsy(median(raw.filter { $0.h > 0 }.map(\.h)), 10)
        let widths = raw.filter { $0.w > 0 }.map { $0.w / Double($0.units.count) }
        let charW = orIfFalsy(median(widths), height * 0.5)
        return Metrics(height: height, charW: charW)
    }

    /// Fills missing sizes, then splits every item into visible pieces: leading and trailing
    /// whitespace is trimmed (remembered as word boundaries) and runs of tabs / 3+ spaces inside
    /// one item become separate pieces (monospace columns). A right-to-left item starts at its
    /// right edge.
    private static func toPieces(_ raw: [RawItem], _ metrics: Metrics) -> [Piece] {
        var pieces: [Piece] = []
        for it in raw {
            let length = Double(it.units.count)
            let h = orIfFalsy(it.h, metrics.height)
            let w = orIfFalsy(it.w, length * metrics.charW * (h / metrics.height))
            let cw = w / length
            for range in pieceRanges(it.units) {
                pieces.append(Piece(
                    str: String(decoding: it.units[range], as: UTF16.self),
                    x: it.rtl ? it.x + Double(it.units.count - range.upperBound) * cw : it.x + Double(range.lowerBound) * cw,
                    y: it.y,
                    w: Double(range.count) * cw,
                    h: h,
                    lead: range.lowerBound > 0,
                    trail: range.upperBound < it.units.count))
            }
        }
        return pieces
    }

    /// The matches of `PIECE = /[^\s]+(?: {1,2}[^\s]+)*/g`: a word followed by single or double
    /// spaces stays one piece; tabs, other whitespace or 3+ spaces split.
    private static func pieceRanges(_ u: [UInt16]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        let n = u.count
        var i = 0
        while i < n {
            if isWhitespace(u[i]) {
                i += 1
                continue
            }
            let start = i
            while i < n && !isWhitespace(u[i]) { i += 1 }
            while i < n && u[i] == space {
                let next: Int
                if i + 1 < n && u[i + 1] == space {
                    next = i + 2 // two spaces; one space would leave a space as the next unit
                } else {
                    next = i + 1
                }
                guard next < n && !isWhitespace(u[next]) else { break }
                i = next
                while i < n && !isWhitespace(u[i]) { i += 1 }
            }
            out.append(start..<i)
        }
        return out
    }

    // MARK: Rows and cells

    private static func groupRows(_ pieces: [Piece], _ tolerance: Double, _ metrics: Metrics) -> [Row] {
        let sorted = stableSorted(pieces) { a, b in
            if a.y < b.y { return -1 }
            if a.y > b.y { return 1 }
            return a.x < b.x ? -1 : a.x > b.x ? 1 : 0
        }
        var rows: [Row] = []
        for it in sorted {
            if let last = rows.indices.last, it.y - rows[last].y <= tolerance {
                rows[last].items.append(it)
                rows[last].sumY += it.y
                rows[last].y = rows[last].sumY / Double(rows[last].items.count)
            } else {
                rows.append(Row(items: [it], sumY: it.y, y: it.y))
            }
        }
        for i in rows.indices {
            let byX = stableSorted(rows[i].items) { a, b in a.x < b.x ? -1 : a.x > b.x ? 1 : 0 }
            rows[i].items = dedupe(byX, metrics.charW * 0.5)
            rows[i].h = median(rows[i].items.map(\.h))
        }
        return rows
    }

    /// Some PDFs fake bold text by drawing the same string twice with a tiny offset.
    private static func dedupe(_ items: [Piece], _ maxShift: Double) -> [Piece] {
        var out: [Piece] = []
        for it in items where !out.contains(where: { identical($0.str, it.str) && abs($0.x - it.x) < maxShift }) {
            out.append(it)
        }
        return out
    }

    private static func buildCells(_ row: Row, _ metrics: Metrics, _ gapFactor: Double) -> [Cell] {
        let cw = metrics.charW * clamp(row.h / metrics.height, 0.6, 3)
        let tabGap = gapFactor * cw
        let spaceGap = spaceFactor * cw
        var cells: [(items: [Piece], x0: Double, x1: Double)] = []
        for it in row.items {
            if let last = cells.indices.last, it.x - cells[last].x1 <= tabGap {
                cells[last].items.append(it)
                cells[last].x1 = jsMax(cells[last].x1, it.x + it.w)
                continue
            }
            cells.append(([it], it.x, it.x + it.w))
        }
        return cells
            .map { c in
                let rtl = isRtlText(c.items.map(\.str).joined())
                let text = JSCompat.trim(collapseWhitespace(cellText(c.items, rtl: rtl, spaceGap: spaceGap)))
                return Cell(text: text, x0: c.x0, x1: c.x1, rtl: rtl)
            }
            .filter { !$0.text.isEmpty }
    }

    /// The pieces of one cell in reading order (right to left for RTL text). A gap wider than a
    /// space or a word boundary inside an item becomes a space, except between two Han characters.
    private static func cellText(_ items: [Piece], rtl: Bool, spaceGap: Double) -> String {
        let order = rtl ? Array(items.reversed()) : items
        var text = order[0].str
        var edge = rtl ? order[0].x : order[0].x + order[0].w // where the text read so far ends
        var trail = order[0].trail
        for it in order.dropFirst() {
            let gap = rtl ? edge - (it.x + it.w) : it.x - edge
            let space = (trail || it.lead || gap > spaceGap) && !(endsWithHan(text) && startsWithHan(it.str))
            text += (space ? " " : "") + it.str
            edge = rtl ? jsMin(edge, it.x) : jsMax(edge, it.x + it.w)
            trail = it.trail
        }
        return text
    }

    /// Typical baseline-to-baseline distance of consecutive lines. The lower quartile is used so
    /// that frequent paragraph gaps (e.g. "term, definition, blank line" lists) do not inflate it.
    private static func lineStepOf(_ ys: [Double], _ height: Double) -> Double {
        var pitches: [Double] = []
        for i in ys.indices.dropFirst() {
            let d = ys[i] - ys[i - 1]
            if d > 0.75 * height { pitches.append(d) }
        }
        if pitches.count >= 3 { return lowerQuartile(pitches) }
        // Two pitches: the smaller one is the line step (equal ones mean uniform spacing).
        if pitches.count == 2 { return jsMin(pitches[0], pitches[1]) }
        // A single pitch cannot be compared: assume a normal leading.
        return jsMin(pitches.first ?? .infinity, 1.25 * height)
    }

    // MARK: Column model

    /// Projects all cells onto the x axis and looks for gutters: x ranges that (almost) no cell
    /// covers and that have cells starting to their right. Returns the boundaries between
    /// columns, or nil for a single column.
    private static func findColumnBounds(_ rows: [Row], _ metrics: Metrics) -> [Double]? {
        let cells = rows.flatMap(\.cells)
        if cells.count < 4 { return nil }
        var xMin = Double.infinity
        var xMax = -Double.infinity
        for c in cells {
            xMin = jsMin(xMin, c.x0)
            xMax = jsMax(xMax, c.x1)
        }
        let span = xMax - xMin
        guard span > 0 else { return nil }
        let binW = jsMax(metrics.charW * 0.5, span / 4000)
        // binW >= span / 4000, so nb <= 4002 for every finite span; the guard only protects
        // against overflowing coordinates (where the JS typed arrays would be empty or throw).
        let nbValue = (span / binW).rounded(.down) + 2
        guard nbValue.isFinite, nbValue >= 2, nbValue <= 1_000_000 else { return nil }
        let nb = Int(nbValue)
        var cover = [Int](repeating: 0, count: nb)
        var starts = [Int](repeating: 0, count: nb)
        for c in cells {
            let b0Value = ((c.x0 - xMin) / binW).rounded(.down)
            let b1Value = jsMax(b0Value, ((c.x1 - xMin) / binW).rounded(.up) - 1)
            guard b0Value.isFinite, b1Value.isFinite, b0Value >= 0 else { continue }
            let b0 = Int(min(b0Value, nbValue))
            let b1 = Int(min(b1Value, nbValue))
            // Right-to-left text starts at the right edge (right-aligned columns have ragged left edges).
            let start = c.rtl ? b1 : b0
            if start < nb { starts[start] += 1 }
            var b = b0
            while b <= b1 && b < nb {
                cover[b] += 1
                b += 1
            }
        }
        let textRows = rows.filter { !$0.cells.isEmpty }.count
        let allowed = max(1, Int((Double(textRows) * 0.12).rounded(.down)))
        let minWidth = jsMax(1, JSCompat.round(metrics.charW / binW))

        // Starts to the right of each bin (suffix sums) to reject trailing runs.
        var startsAfter = [Int](repeating: 0, count: nb + 1)
        for b in stride(from: nb - 1, through: 0, by: -1) { startsAfter[b] = startsAfter[b + 1] + starts[b] }

        var bounds: [Double] = []
        var b = 0
        while b < nb {
            if cover[b] > allowed || starts[b] > 0 {
                b += 1
                continue
            }
            var e = b
            while e + 1 < nb && cover[e + 1] <= allowed && starts[e + 1] == 0 { e += 1 }
            let hasLeft = b > 0
            let hasRight = startsAfter[e + 1] > 0
            if hasLeft && hasRight && Double(e - b + 1) >= minWidth {
                bounds.append(xMin + (Double(b + e + 1) / 2) * binW)
            }
            b = e + 1
        }
        if bounds.isEmpty { return nil }
        return pruneBounds(bounds, cells)
    }

    private static func columnIndex(_ bounds: [Double], _ x: Double) -> Int {
        var i = 0
        while i < bounds.count && x >= bounds[i] { i += 1 }
        return i
    }

    /// A cell belongs to the column of the edge its text starts at.
    private static func anchorX(_ cell: Cell) -> Double {
        cell.rtl ? cell.x1 : cell.x0
    }

    /// Drops columns that only a handful of cells start in (stray page numbers, one indented
    /// line, …) by merging them into a neighbour.
    private static func pruneBounds(_ bounds: [Double], _ cells: [Cell]) -> [Double]? {
        var bs = bounds
        while true {
            if bs.isEmpty { return nil }
            var counts = [Int](repeating: 0, count: bs.count + 1)
            for c in cells { counts[columnIndex(bs, anchorX(c))] += 1 }
            let maximum = counts.max() ?? 0
            let minStarts = max(2, Int((Double(maximum) * 0.2).rounded(.up)))
            var weakest = -1
            for i in counts.indices where counts[i] < minStarts && (weakest < 0 || counts[i] < counts[weakest]) {
                weakest = i
            }
            if weakest < 0 { return bs }
            // Remove the boundary on the weak column's left (or right for the first column).
            bs.remove(at: weakest == 0 ? 0 : weakest - 1)
        }
    }

    private static func assignColumns(_ rows: inout [Row], _ bounds: [Double]) -> Int {
        let k = bounds.count + 1
        for i in rows.indices {
            var parts = [[String]](repeating: [], count: k)
            for c in rows[i].cells { parts[columnIndex(bounds, anchorX(c))].append(c.text) }
            // Several cells in one column are read like the pieces of a cell.
            rows[i].cols = parts.map { p in
                guard let first = p.first else { return "" }
                if isRtlText(p.joined()) { return p.dropLast().reversed().reduce(p[p.count - 1], joinWords) }
                return p.dropFirst().reduce(first, joinWords)
            }
        }
        return k
    }

    private static func isMarkerColumn(_ rows: [Row], _ c: Int) -> Bool {
        let values = rows.map { $0.cols[c] }.filter { !$0.isEmpty }
        if values.count < 2 { return false }
        let markers = values.filter(isMarker).count
        return Double(markers) >= Double(values.count) * 0.8
    }

    /// `MARKER = /^(?:\(?\d{1,4}[.)]?|\(?[a-zA-Z][.)]|[•▪◦·∙●○■□►▸‣⁃*–—-])$/`: a list number,
    /// letter or bullet on its own.
    private static func isMarker(_ s: String) -> Bool {
        let u = Array(s.utf16)
        if u.count == 1, bullets.contains(u[0]) { return true }
        var i = 0
        if i < u.count && u[i] == 0x28 { i += 1 } // "("
        // \d{1,4}[.)]?
        var j = i
        while j < u.count && isASCIIDigit(u[j]) { j += 1 }
        let digits = j - i
        if digits >= 1 && digits <= 4 {
            if j == u.count { return true }
            if j + 1 == u.count && (u[j] == 0x2E || u[j] == 0x29) { return true }
        }
        // [a-zA-Z][.)]
        return i + 2 == u.count && isASCIILetter(u[i]) && (u[i + 1] == 0x2E || u[i + 1] == 0x29)
    }

    private static let bullets: Set<UInt16> = [
        0x2022, 0x25AA, 0x25E6, 0xB7, 0x2219, 0x25CF, 0x25CB, 0x25A0, 0x25A1, 0x25BA, 0x25B8, 0x2023, 0x2043,
        0x2A, 0x2013, 0x2014, 0x2D,
    ]

    private static func wordCount(_ s: String) -> Int {
        var count = 0
        var inWord = false
        for u in s.unicodeScalars {
            if JSCompat.isWhitespace(u) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// In a term | example sentence | translation table, the sentence column is clearly wordier
    /// than the other two and is not useful for flash cards. -1 when there is none.
    private static func sentenceColumn(_ rows: [Row], _ cols: [Int]) -> Int {
        if cols.count != 3 { return -1 }
        let avg: [Double] = cols.map { c in
            let values = rows.map { $0.cols[c] }.filter { !$0.isEmpty }
            return values.isEmpty ? 0 : Double(values.reduce(0) { $0 + wordCount($1) }) / Double(values.count)
        }
        let candidates = avg.indices.filter { i in
            avg[i] >= 4 && avg.indices.allSatisfy { j in j == i || avg[i] >= 2 * avg[j] }
        }
        return candidates.count == 1 ? cols[candidates[0]] : -1
    }

    // MARK: Layout classification

    private static func columnLines(_ rows: [Row], _ c: Int) -> [Row] {
        rows.filter { !$0.cols[c].isEmpty }
    }

    private static func blocksOf(_ lines: [Row], _ paragraph: Double) -> [[Row]] {
        var blocks: [[Row]] = []
        var prevY = 0.0
        for row in lines {
            if blocks.isEmpty || row.y - prevY > paragraph { blocks.append([]) }
            blocks[blocks.count - 1].append(row)
            prevY = row.y
        }
        return blocks
    }

    /// "term / definition / gap" pairs laid out in several page columns.
    private static func isStackedPairs(_ rows: [Row], _ cols: [Int], _ ctx: Context) -> Bool {
        var checked = 0
        for c in cols {
            let lines = columnLines(rows, c)
            if lines.count < 4 { continue }
            let blocks = blocksOf(lines, ctx.paragraph)
            let pairs = blocks.filter { $0.count == 2 }.count
            if blocks.count < 3 || Double(pairs) < Double(blocks.count) * 0.75 { return false }
            checked += 1
        }
        return checked >= 2
    }

    /// Text columns whose lines do not line up (different leading or offsets).
    private static func isIndependentFlow(_ rows: [Row], _ cols: [Int], _ ctx: Context) -> Bool {
        var ranges: [(Double, Double)] = []
        for c in cols {
            let lines = columnLines(rows, c)
            if lines.count < 3 { continue }
            let step = lineStepOf(lines.map(\.y), ctx.metrics.height)
            if step > 2 * ctx.metrics.height { return false }
            ranges.append((lines[0].y, lines[lines.count - 1].y))
        }
        if ranges.count < 2 { return false }
        // JS: ranges.sort((a, b) => b[1] - b[0] - (a[1] - a[0])), longest first, stable.
        ranges = stableSorted(ranges) { a, b in
            let d = (b.1 - b.0) - (a.1 - a.0)
            return d < 0 ? -1 : d > 0 ? 1 : 0
        }
        let (r1, r2) = (ranges[0], ranges[1])
        let overlap = jsMin(r1.1, r2.1) - jsMax(r1.0, r2.0)
        return overlap >= 0.5 * jsMax(1e-6, r2.1 - r2.0)
    }

    // MARK: Emitters

    private static func emitRows(_ rows: [Row], _ textOf: (Row) -> String, _ ctx: Context) -> [String] {
        var out: [String] = []
        var prevY: Double?
        for row in rows {
            let text = textOf(row)
            if text.isEmpty { continue }
            if let prevY, row.y - prevY > ctx.paragraph { out.append("") }
            out.append(text)
            prevY = row.y
        }
        return out
    }

    private static func emitFlow(_ rows: [Row], _ cols: [Int], _ ctx: Context) -> [String] {
        var out: [String] = []
        for c in cols {
            let lines = emitRows(rows, { $0.cols[c] }, ctx)
            if lines.isEmpty { continue }
            if !out.isEmpty { out.append("") }
            out.append(contentsOf: lines)
        }
        return out
    }

    private static func joinWrapped(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        return a.utf16.last == hyphen ? a + b : joinWords(a, b)
    }

    /// `WRAP_END = /[,;:\-–(/]$/`
    private static func endsWithWrapMark(_ s: String) -> Bool {
        guard let last = s.utf16.last else { return false }
        switch last {
        case 0x2C, 0x3B, 0x3A, hyphen, 0x2013, 0x28, 0x2F: return true
        default: return false
        }
    }

    private static func endsOpen(_ s: String) -> Bool {
        endsWithWrapMark(s) || endsWithOpenWord(s)
    }

    /// Typical distance between two consecutive rows that both fill columns a and b. Unlike the
    /// row pitch it is not inflated by wrapped lines in between.
    private static func fullRowGap(_ rows: [Row], _ a: Int, _ b: Int) -> Double {
        let filled = rows.filter { !$0.cols[a].isEmpty || !$0.cols[b].isEmpty }
        var gaps: [Double] = []
        for i in filled.indices.dropFirst() {
            let (p, r) = (filled[i - 1], filled[i])
            if !p.cols[a].isEmpty && !p.cols[b].isEmpty && !r.cols[a].isEmpty && !r.cols[b].isEmpty {
                gaps.append(r.y - p.y)
            }
        }
        return gaps.count >= 2 ? median(gaps) : .infinity
    }

    private struct Entry {
        var a: String
        var b: String
        var lastY: Double
        var gapBefore: Bool
    }

    /// Both cells of a row wrapped onto one tighter line ("s'entendre bien avec | sich mit jdm
    /// gut" + "qn | verstehen"). Each side must read as a continuation, two articles ("la femme |
    /// die Frau") start a new entry, and the row needs an open ending or a clearly tighter gap, so
    /// that lowercase entries ("manger | essen") at a slightly uneven pitch stay separate rows.
    private static func continuesBoth(_ prev: Entry, _ ta: String, _ tb: String, _ gap: Double, _ rowGap: Double) -> Bool {
        if !rowGap.isFinite || !(gap < 0.85 * rowGap) { return false }
        if startsEntry(ta) && startsEntry(tb) { return false }
        func continues(_ before: String, _ next: String) -> Bool { startsLower(next) || endsOpen(before) }
        if !continues(prev.a, ta) || !continues(prev.b, tb) { return false }
        return endsOpen(prev.a) || endsOpen(prev.b) || gap < 0.7 * rowGap
    }

    private static func emitTable(_ rows: [Row], _ cols: [Int], _ ctx: Context) -> [String] {
        var out: [String] = []
        var g = 0
        while g + 1 < cols.count {
            defer { g += 2 }
            let a = cols[g]
            let b = cols[g + 1]
            let complete = rows.filter { !$0.cols[a].isEmpty && !$0.cols[b].isEmpty }.map(\.y)
            let rowPitch = complete.count >= 2
                ? median(complete.indices.dropFirst().map { complete[$0] - complete[$0 - 1] })
                : .infinity
            let rowGap = fullRowGap(rows, a, b)
            var entries: [Entry] = []
            for row in rows {
                let ta = row.cols[a]
                let tb = row.cols[b]
                if ta.isEmpty && tb.isEmpty { continue }
                let p = entries.indices.last
                let gap = p.map { row.y - entries[$0].lastY } ?? .infinity
                let near = gap <= ctx.paragraph
                if let p, near {
                    let prev = entries[p]
                    if ta.isEmpty && !tb.isEmpty {
                        entries[p].b = joinWrapped(prev.b, tb)
                        entries[p].lastY = row.y
                        continue
                    }
                    if !ta.isEmpty && tb.isEmpty && !prev.a.isEmpty && !prev.b.isEmpty {
                        let tighter = gap < 0.85 * rowPitch
                        if endsWithWrapMark(prev.a) || (tighter && startsLower(ta)) {
                            entries[p].a = joinWrapped(prev.a, ta)
                            entries[p].lastY = row.y
                            continue
                        }
                    }
                    if !ta.isEmpty && !tb.isEmpty && !prev.a.isEmpty && !prev.b.isEmpty
                        && continuesBoth(prev, ta, tb, gap, rowGap) {
                        entries[p].a = joinWrapped(prev.a, ta)
                        entries[p].b = joinWrapped(prev.b, tb)
                        entries[p].lastY = row.y
                        continue
                    }
                }
                entries.append(Entry(a: ta, b: tb, lastY: row.y, gapBefore: p != nil && !near))
            }
            if entries.isEmpty { continue }
            if !out.isEmpty { out.append("") }
            for e in entries {
                if e.gapBefore { out.append("") }
                out.append(!e.a.isEmpty && !e.b.isEmpty ? "\(e.a)\t\(e.b)" : e.a.isEmpty ? e.b : e.a)
            }
        }
        return out
    }

    /// Collapses runs of spaces, removes spaces around tabs, trims, keeps single blank lines
    /// between blocks and drops trailing ones.
    private static func tidy(_ lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            let t = JSCompat.trim(tightenTabs(collapseSpaces(line)))
            if t.isEmpty {
                if let last = out.last, !last.isEmpty { out.append("") }
            } else {
                out.append(t)
            }
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out
    }
}

// MARK: - Word lists (case-insensitive like the JS `/iu` regexes)

extension TextLayout {
    /// `OPEN_END`: a cell ending in an article, preposition or object placeholder continues on the
    /// next line.
    private static let openEndWords: [[Unicode.Scalar]] = [
        "le", "la", "les", "l'", "un", "une", "des", "du", "de", "d'", "à", "au", "aux", "en", "et", "ou", "avec",
        "pour", "sur", "dans", "par", "chez", "der", "die", "das", "den", "dem", "ein", "eine", "einen", "einem",
        "einer", "und", "oder", "mit", "von", "für", "auf", "zu", "zum", "zur", "im", "am", "in", "über", "bei", "jdm",
        "jdn", "jds", "etw", "sich", "the", "a", "to", "of", "and", "or", "with", "for", "from", "into",
    ].map { Array($0.unicodeScalars) }

    /// The article alternatives of `ENTRY_START` (each followed by whitespace).
    private static let entryStartWords: [[Unicode.Scalar]] = [
        "le", "la", "les", "un", "une", "des", "du", "der", "die", "das", "den", "dem", "ein", "eine", "the", "a",
        "an", "to", "el", "los", "las", "il", "lo", "gli", "uno", "una",
    ].map { Array($0.unicodeScalars) }

    /// `OPEN_END = /(?:^|\s)(?:le|la|…|into)$/iu`
    private static func endsWithOpenWord(_ s: String) -> Bool {
        let u = s.unicodeScalars.map(caseFold)
        return openEndWords.contains { w in
            guard u.count >= w.count, u[(u.count - w.count)...].elementsEqual(w) else { return false }
            return u.count == w.count || JSCompat.isWhitespace(u[u.count - w.count - 1])
        }
    }

    /// `ENTRY_START = /^(?:(?:le|la|…|una)\s|l')/iu`
    private static func startsEntry(_ s: String) -> Bool {
        let u = s.unicodeScalars.map(caseFold)
        if u.count >= 2 && u[0] == "l" && u[1] == "'" { return true }
        return entryStartWords.contains { w in
            u.count > w.count && u[..<w.count].elementsEqual(w) && JSCompat.isWhitespace(u[w.count])
        }
    }

    /// `Canonicalize` of a `/iu` regex restricted to the scalars that fold onto a pattern letter of
    /// the word lists (verified against JavaScriptCore over all code points): A-Z, À, Ü, the long
    /// s (U+017F) and the Kelvin sign (U+212A).
    private static func caseFold(_ u: Unicode.Scalar) -> Unicode.Scalar {
        switch u.value {
        case 0x41...0x5A, 0xC0, 0xDC: return Unicode.Scalar(u.value + 0x20)!
        case 0x17F: return "s"
        case 0x212A: return "k"
        default: return u
        }
    }

    /// `STARTS_LOWER = /^[(\[]?[a-zà-ÿœæ]/` (UTF-16, case-sensitive).
    private static func startsLower(_ s: String) -> Bool {
        let u = Array(s.utf16.prefix(2))
        guard let first = u.first else { return false }
        let i = first == 0x28 || first == 0x5B ? 1 : 0
        guard i < u.count else { return false }
        switch u[i] {
        case 0x61...0x7A, 0xE0...0xFF, 0x153: return true
        default: return false
        }
    }
}

// MARK: - Helpers

extension TextLayout {
    private static let space: UInt16 = 0x20
    private static let hyphen: UInt16 = 0x2D

    // MARK: Scripts

    /// `RTL_CHAR = /[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFE]/u`: right-to-left scripts (Hebrew,
    /// Arabic, Syriac, Thaana, NKo, …) and their presentation forms.
    private static func isRtlScalar(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x590...0x8FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFE: return true
        default: return false
        }
    }

    /// More than half of the letters are right-to-left (Arabic, Hebrew, …): such text is read
    /// from right to left (`isRtlText`).
    public static func isRtlText(_ s: String) -> Bool {
        var letters = 0
        var rtl = 0
        for u in s.unicodeScalars where TextNormalizer.isLetterScalar(u) {
            letters += 1
            if isRtlScalar(u) { rtl += 1 }
        }
        return rtl * 2 > letters
    }

    /// `HAN_END.test(s)`: the last character is a Han character.
    private static func endsWithHan(_ s: String) -> Bool {
        s.unicodeScalars.last.map(TextNormalizer.isHanScalar) ?? false
    }

    /// `HAN_START.test(s)`: the first character is a Han character.
    private static func startsWithHan(_ s: String) -> Bool {
        s.unicodeScalars.first.map(TextNormalizer.isHanScalar) ?? false
    }

    /// Joins two words with a space, except between two Han characters.
    private static func joinWords(_ a: String, _ b: String) -> String {
        endsWithHan(a) && startsWithHan(b) ? a + b : "\(a) \(b)"
    }

    /// JS `\s` for one UTF-16 code unit (surrogates are never whitespace).
    private static func isWhitespace(_ u: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(u) else { return false }
        return JSCompat.isWhitespace(scalar)
    }

    private static func isASCIIDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }

    private static func isASCIILetter(_ u: UInt16) -> Bool { (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) }

    /// `s.replace(/\s+/g, ' ')`
    private static func collapseWhitespace(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var inRun = false
        for u in s.unicodeScalars {
            if JSCompat.isWhitespace(u) {
                if !inRun { out.append(" ") }
                inRun = true
            } else {
                out.append(u)
                inRun = false
            }
        }
        return String(out)
    }

    /// `s.replace(/ +/g, ' ')`
    private static func collapseSpaces(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var previousSpace = false
        for u in s.unicodeScalars {
            if u == " " && previousSpace { continue }
            out.append(u)
            previousSpace = u == " "
        }
        return String(out)
    }

    /// `s.replace(/ *\t */g, '\t')`
    private static func tightenTabs(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var afterTab = false
        for u in s.unicodeScalars {
            if u == "\t" {
                while out.last == " " { out.removeLast() }
                out.append(u)
                afterTab = true
            } else if u == " " && afterTab {
                continue
            } else {
                out.append(u)
                afterTab = false
            }
        }
        return String(out)
    }

    /// JS `===` on strings (Swift `==` uses canonical equivalence).
    private static func identical(_ a: String, _ b: String) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }

    /// `x || fallback` for numbers: 0 and NaN are falsy.
    private static func orIfFalsy(_ x: Double, _ fallback: Double) -> Double {
        x == 0 || x.isNaN ? fallback : x
    }

    /// JS `Math.max(a, b)`: NaN wins, +0 beats -0.
    private static func jsMax(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        if a == b { return a.sign == .minus ? b : a }
        return a > b ? a : b
    }

    /// JS `Math.min(a, b)`: NaN wins, -0 beats +0.
    private static func jsMin(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        if a == b { return a.sign == .minus ? a : b }
        return a < b ? a : b
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        jsMin(hi, jsMax(lo, v))
    }

    private static func median(_ values: [Double]) -> Double {
        if values.isEmpty { return 0 }
        let s = values.sorted()
        let mid = s.count >> 1
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    private static func lowerQuartile(_ values: [Double]) -> Double {
        if values.isEmpty { return 0 }
        let s = values.sorted()
        return s[Int((Double(s.count - 1) * 0.25).rounded(.down))]
    }

    /// `Array.prototype.sort` with a JS-style comparator (negative = a first): stable, like JSC.
    private static func stableSorted<T>(_ list: [T], by compare: (T, T) -> Int) -> [T] {
        list.enumerated()
            .sorted { a, b in
                let c = compare(a.element, b.element)
                return c != 0 ? c < 0 : a.offset < b.offset
            }
            .map(\.element)
    }

    // MARK: Lenient JSON (shared with the item / option / segment initialisers)

    /// JS `toNumber`: a finite number, or a string read with `parseFloat`; nil otherwise.
    static func toNumber(_ v: JSONValue?) -> Double? {
        switch v {
        case let .number(n)?:
            return n.isFinite ? n : nil
        case let .string(s)?:
            let n = parseFloat(s)
            return n.isFinite ? n : nil
        default:
            return nil
        }
    }

    /// JS `parseFloat`: the longest decimal-literal prefix after leading whitespace, NaN if none.
    static func parseFloat(_ s: String) -> Double {
        let u = Array(s.unicodeScalars)
        var i = 0
        while i < u.count && JSCompat.isWhitespace(u[i]) { i += 1 }
        var negative = false
        if i < u.count && (u[i] == "+" || u[i] == "-") {
            negative = u[i] == "-"
            i += 1
        }
        let sign = negative ? -1.0 : 1.0
        let infinity = Array("Infinity".unicodeScalars)
        if u.count - i >= infinity.count && u[i..<(i + infinity.count)].elementsEqual(infinity) {
            return sign * .infinity
        }
        func digits(from start: Int) -> Int {
            var j = start
            while j < u.count && ("0"..."9").contains(u[j]) { j += 1 }
            return j - start
        }
        let intDigits = digits(from: i)
        var j = i + intDigits
        var fracDigits = 0
        if j < u.count && u[j] == "." {
            fracDigits = digits(from: j + 1)
            if intDigits > 0 || fracDigits > 0 { j += 1 + fracDigits }
        }
        guard intDigits + fracDigits > 0 else { return .nan }
        var literal = String(String.UnicodeScalarView(u[i..<(i + intDigits)]))
        if literal.isEmpty { literal = "0" }
        if fracDigits > 0 { literal += "." + String(String.UnicodeScalarView(u[(i + intDigits + 1)..<j])) }
        if j < u.count && (u[j] == "e" || u[j] == "E") {
            var k = j + 1
            var exponentSign = ""
            if k < u.count && (u[k] == "+" || u[k] == "-") {
                exponentSign = u[k] == "-" ? "-" : ""
                k += 1
            }
            let expDigits = digits(from: k)
            if expDigits > 0 { literal += "e" + exponentSign + String(String.UnicodeScalarView(u[k..<(k + expDigits)])) }
        }
        guard let value = Double(literal) else { return .nan }
        return sign * value
    }

    /// JS `String(v)` for a JSON value; nil for null.
    static func jsString(_ v: JSONValue) -> String? {
        switch v {
        case .null: return nil
        case let .string(s): return s
        case let .number(n): return JSCompat.numberToString(n)
        case let .bool(b): return b ? "true" : "false"
        case let .array(a): return a.map { jsString($0) ?? "" }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }
}
