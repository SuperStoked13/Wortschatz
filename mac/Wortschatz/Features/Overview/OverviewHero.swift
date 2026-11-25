import SwiftUI
import WortschatzCore

/// The overview's glass hero, bound to Return (spec §4.3): "Weiterlernen" for the latest
/// unfinished Learn session (else Write session, "Fortsetzen"), otherwise the most recent set
/// ("Öffnen"). Port of `resumeBanner` in dashboard.js.
struct OverviewHero: View {
    let now: Date

    @Environment(AppModel.self) private var model

    var body: some View {
        if let resume = model.library.resume, let summary = model.library.summary(for: resume.setID) {
            hero(
                summary: summary,
                counts: gaugeCounts(resume, summary: summary),
                eyebrow: resume.mode == .learn
                    ? String(localized: "Weiterlernen · Lernen") : String(localized: "Weiterlernen · Schreiben"),
                eyebrowSymbol: resume.mode == .learn ? "sparkles" : "keyboard",
                meta: meta(resume),
                progress: progress(resume),
                action: resume.mode == .learn ? String(localized: "Weiterlernen") : String(localized: "Fortsetzen"),
                actionSymbol: "play.fill"
            )
        } else if let recent = model.library.sets.first {
            hero(
                summary: recent,
                counts: recent.counts,
                eyebrow: recent.set.lastStudiedAt != nil
                    ? String(localized: "Zuletzt gelernt") : String(localized: "Zuletzt bearbeitet"),
                eyebrowSymbol: "clock",
                meta: recentMeta(recent),
                progress: nil,
                action: String(localized: "Öffnen"),
                actionSymbol: "arrow.right"
            )
        }
    }

    private func hero(
        summary: SetSummary, counts: StatusCounts, eyebrow: String, eyebrowSymbol: String, meta: String,
        progress: (value: Double, label: String)?, action: String, actionSymbol: String
    ) -> some View {
        GlassCard(padding: Spacing.xl) {
            HStack(spacing: Spacing.xl) {
                MasteryGauge(counts: counts, size: .medium)
                    .scaleEffect(1.25)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Label(eyebrow, systemImage: eyebrowSymbol)
                        .eyebrowStyle()
                    Text(summary.set.title)
                        .font(Typography.title)
                        .lineLimit(2)
                    HStack(spacing: Spacing.xs) {
                        LanguageCapsule(termLang: summary.set.termLang, defLang: summary.set.defLang, style: .short)
                        Text(meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let progress {
                        HeroProgressBar(value: progress.value)
                            .frame(maxWidth: 320)
                            .accessibilityLabel(progress.label)
                            .accessibilityValue("\(Int((progress.value * 100).rounded())) Prozent")
                            .padding(.top, Spacing.xxs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PrimaryActionButton(verbatim: action, systemImage: actionSymbol) {
                    model.resume()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(eyebrow)
    }

    /// Learn: the session's own counts; Write: the set's mastery.
    private func gaugeCounts(_ resume: ResumeItem, summary: SetSummary) -> StatusCounts {
        switch resume.kind {
        case let .learn(learn): StatusCounts(learn.counts)
        case .write: summary.counts
        }
    }

    private func meta(_ resume: ResumeItem) -> String {
        switch resume.kind {
        case let .learn(learn):
            return StudyCopy.join([StudyCopy.subsetLabel(learn.subset, objectLabel: String(localized: "Ausgewählte Begriffe")), learn.roundText, learn.masteredText])
        case let .write(write):
            let correct =
                write.counters.total > 0
                ? String(localized: "\(write.counters.correct) von \(write.counters.total) richtig") : nil
            return StudyCopy.join([write.roundText, correct])
        }
    }

    private func progress(_ resume: ResumeItem) -> (value: Double, label: String) {
        switch resume.kind {
        case let .learn(learn): (learn.progressValue, String(localized: "Gemeistert in dieser Lerneinheit"))
        case let .write(write): (write.progressValue, String(localized: "Fortschritt dieser Schreibrunde"))
        }
    }

    private func recentMeta(_ summary: SetSummary) -> String {
        var parts = [StudyCopy.terms(summary.stats.total)]
        if let last = summary.set.lastStudiedAt {
            parts.append(TimeUtil.relativeTime(last, now: now.timeIntervalSince1970 * 1000, timeZone: model.store.timeZone))
        } else {
            parts.append(String(localized: "noch nicht gelernt"))
        }
        return parts.joined(separator: " · ")
    }
}

/// A slim accent progress bar (0…1).
private struct HeroProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                Capsule(style: .continuous)
                    .fill(Theme.accent.gradient)
                    .frame(width: value > 0 ? max(6, proxy.size.width * min(1, value)) : 0)
            }
        }
        .frame(height: 6)
        .motionAnimation(Motion.gentle, value: value)
    }
}
