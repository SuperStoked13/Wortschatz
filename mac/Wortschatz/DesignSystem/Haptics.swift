import AppKit
import SwiftUI

/// Trackpad haptics (spec §4.2: `NSHapticFeedbackManager`, `.levelChange`). They are felt only
/// while a finger rests on a Force Touch trackpad; elsewhere they do nothing.
nonisolated enum Haptics {
    enum Feedback: Sendable {
        /// Correct answer, round finished.
        case success
        /// Wrong answer.
        case failure
        /// Moving the multiple-choice highlight, snapping into place.
        case selection
    }

    static func play(_ feedback: Feedback) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch feedback {
        case .success: .levelChange
        case .failure: .generic
        case .selection: .alignment
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    static func success() { play(.success) }
    static func failure() { play(.failure) }
    static func selection() { play(.selection) }
}
