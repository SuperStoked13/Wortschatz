import SwiftUI

/// Centres its content in the available space and scrolls when the window is too small for it.
///
/// Use it for full-screen messages (empty states) in the detail column: the split view asks
/// the detail for its minimum size with a tiny width, and wrapping text that is measured there
/// would otherwise demand a huge height and push the whole window content off screen.
struct CenteredScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
