#if os(macOS)
import SwiftUI

/// «Aktualisiert auf 1.8» at the foot of the sidebar, above the streak, after Wortschatz updated
/// itself (`AppUpdater.notice`): the first change, «+2 weitere», and all of them in a popover on a
/// click. ✕ closes it for good; otherwise it goes after a week (`UpdateNoticeStore`).
struct UpdateNoticeCard: View {
    let notice: UpdateNotice
    let onClose: () -> Void

    @State private var showsChanges = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Aktualisiert auf \(notice.version)")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let first = notice.changes.first {
                    Text(first)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if notice.changes.count > 1 {
                    Text("+\(notice.changes.count - 1) weitere")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accentText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { showChanges() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(notice.changes.isEmpty ? [] : .isButton)
            .accessibilityAction { showChanges() }
            .popover(isPresented: $showsChanges, arrowEdge: .trailing) {
                UpdateChangesList(notice: notice)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .frame(width: 16, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Schliessen")
            .accessibilityLabel("Hinweis schliessen")
        }
        .padding(.horizontal, Spacing.s + 2)
        .padding(.vertical, Spacing.xs + 2)
        .background(Theme.accent.opacity(0.1), in: .rect(cornerRadius: 12))
        .padding(.horizontal, Spacing.s)
        .padding(.bottom, Spacing.xs)
        .help(notice.changes.isEmpty ? "" : String(localized: "Klicken für alle Neuerungen"))
    }

    private func showChanges() {
        if !notice.changes.isEmpty { showsChanges = true }
    }
}

/// Every change of the update, in the popover of the notice.
private struct UpdateChangesList: View {
    let notice: UpdateNotice

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Neu in Version \(notice.version)")
                .font(.headline)
            ViewThatFits(in: .vertical) {
                changes
                ScrollView { changes }
            }
        }
        .padding(Spacing.m)
        .frame(width: 340)
        .frame(maxHeight: 420)
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(notice.changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•")
                        .foregroundStyle(.secondary)
                    Text(change)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
/// `--render-snapshots <dir> --snapshot-filter sidebar-update`: the notice with several changes,
/// with one, without any, and the popover's list.
final class UpdateNoticeSnapshots: SnapshotCatalog {
    private static func notice(_ changes: [String]) -> UpdateNotice {
        UpdateNotice(version: "1.8", build: "10", changes: changes, since: .now)
    }

    private static let changes = [
        "Neu: Wortschatz aktualisiert sich selbst: Neue Versionen kommen im Hintergrund und sind nach dem nächsten Start da.",
        "Verbessert: Tippen beim Lernen und in der Prüfung läuft flüssiger.",
        "Behoben: Karteikarten merken sich die Reihenfolge wieder.",
    ]

    override class var scenes: [SnapshotScene] {
        [
            SnapshotScene("sidebar-update-notice", size: CGSize(width: 260, height: 120)) {
                card(notice(changes))
            },
            SnapshotScene("sidebar-update-notice-one", size: CGSize(width: 260, height: 100), colorSchemes: [.light]) {
                card(notice(["Behoben: Karteikarten merken sich die Reihenfolge wieder."]))
            },
            SnapshotScene("sidebar-update-notice-none", size: CGSize(width: 260, height: 80), colorSchemes: [.light]) {
                card(notice([]))
            },
            SnapshotScene("sidebar-update-changes", size: CGSize(width: 340, height: 220)) {
                UpdateChangesList(notice: notice(changes))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(.background)
            },
        ]
    }

    private static func card(_ notice: UpdateNotice) -> some View {
        UpdateNoticeCard(notice: notice, onClose: {})
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .background(.background)
    }
}
#endif
#endif
