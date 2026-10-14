import Foundation
import WortschatzCore
import WortschatzImport

/// Texts for probable typos, shown with the other review hints of the detection (doubled
/// terms, unsure pairs) before the cards are taken over, and in the card list.
enum ImportSpelling {
    /// "Möglicher Tippfehler: «separee» (séparée?)".
    static func tooltip(_ issues: [SpellingIssue]) -> String? {
        guard !issues.isEmpty else { return nil }
        let words = issues.map { issue in
            issue.suggestions.first.map { "«\(issue.word)» (\($0)?)" } ?? "«\(issue.word)»"
        }
        let lead = issues.count == 1 ? "Möglicher Tippfehler" : "Mögliche Tippfehler"
        return "\(lead): \(words.joined(separator: ", "))"
    }

    /// "1 möglicher Tippfehler" / "3 mögliche Tippfehler".
    static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 möglicher Tippfehler" : "\(count) mögliche Tippfehler"
    }
}
