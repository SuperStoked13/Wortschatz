import SwiftUI

/// The main window's content with a fixed minimum size (980 × 640) that is answered without
/// measuring the content.
///
/// With `.frame(minWidth:minHeight:)` and `.windowResizability(.contentMinSize)` the hosting view
/// asks the whole app for its minimum size on every layout pass — on every frame of the sidebar
/// sliding away and on every tick of the animated backdrop. Profiling showed that measurement
/// as the main cause of dropped frames when opening Lernen; this layout returns the minimum
/// straight away and only lays out the content at the window's real size.
///
/// The detail column uses it too: the split view measures that column the same way.
struct WindowMinimumLayout: Layout {
    var minWidth: CGFloat = 980
    var minHeight: CGFloat = 640

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: proposal.width.map { max($0, minWidth) } ?? minWidth,
            height: proposal.height.map { max($0, minHeight) } ?? minHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }

    // No alignment guides from the content: the default implementation asks the content for
    // them at the measuring size, which lays it all out again (profiled: up to 90 ms when the
    // set page appears, and on every frame of a fade).

    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        nil
    }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        nil
    }
}
