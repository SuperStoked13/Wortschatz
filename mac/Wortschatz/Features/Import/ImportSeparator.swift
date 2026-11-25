import Foundation
import WortschatzCore

/// The "Trennung" choices of the import panel and their `parseVocab` options (`SEPARATORS` in
/// src/screens/editor-util.js).
nonisolated enum ImportSeparator: String, CaseIterable, Identifiable, Sendable {
    case auto, tab, comma, semicolon, dash, lines, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: String(localized: "Automatisch", comment: "Import separator: detect it")
        case .tab: String(localized: "Tab", comment: "Separator: the tab character")
        case .comma: String(localized: "Komma")
        case .semicolon: String(localized: "Strichpunkt")
        case .dash: String(localized: "Bindestrich")
        case .lines: String(localized: "Zeilenweise")
        case .custom: String(localized: "Eigenes…", comment: "Import separator: one the learner types")
        }
    }

    /// Applies the choice to `options`. An empty custom separator keeps automatic detection
    /// (the detection bar then asks for one); a separator of only spaces is used as typed.
    func configure(_ options: inout ParseOptions, custom: String) {
        switch self {
        case .auto:
            break
        case .tab:
            options.mode = .delimiter
            options.delimiter = "\t"
        case .comma:
            options.mode = .delimiter
            options.delimiter = ","
        case .semicolon:
            options.mode = .delimiter
            options.delimiter = ";"
        case .dash:
            options.mode = .delimiter
            options.delimiter = "-"
        case .lines:
            options.mode = .lines
        case .custom:
            guard !custom.isEmpty else { return }
            let trimmed = JSCompat.trim(custom)
            options.mode = .delimiter
            options.delimiter = trimmed.isEmpty ? custom : trimmed
        }
    }
}
