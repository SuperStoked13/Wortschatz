import Foundation
import WortschatzCore

/// The "Trennung" choices of the import panel and their `parseVocab` options (`SEPARATORS` in
/// src/screens/editor-util.js).
nonisolated enum ImportSeparator: String, CaseIterable, Identifiable, Sendable {
    case auto, tab, comma, semicolon, dash, lines, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Automatisch"
        case .tab: "Tab"
        case .comma: "Komma"
        case .semicolon: "Strichpunkt"
        case .dash: "Bindestrich"
        case .lines: "Zeilenweise"
        case .custom: "Eigenes…"
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
