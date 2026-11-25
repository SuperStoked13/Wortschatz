import SwiftUI

/// Friendly empty state: a large symbol on a soft accent halo, title, message and actions
/// (e.g. the overview without sets: "Erstes Lernset erstellen ↩", "Backup
/// laden…"). Not glass: it is content, not a control.
///
/// ```swift
/// EmptyStateView(systemImage: "rectangle.stack.badge.plus", title: "Noch keine Lernsets",
///                message: "Füge deine Vokabelliste ein oder importiere ein Foto davon.") {
///     PrimaryActionButton("Erstes Lernset erstellen") { … }
///     SecondaryButton("Backup laden…") { … }
/// }
/// ```
struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions

    init(systemImage: String, title: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: Spacing.l) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0.0)],
                            center: .center,
                            startRadius: 10,
                            endRadius: 70
                        )
                    )
                    .frame(width: 140, height: 140)
                Image(systemName: systemImage)
                    .font(.system(size: 50, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent)
            }
            .frame(height: 112)
            .accessibilityHidden(true)

            VStack(spacing: Spacing.xs) {
                Text(title)
                    .font(Typography.title)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: Spacing.s) {
                actions
            }
            .padding(.top, Spacing.xxs)
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}
