import SwiftUI
import WortschatzCore

/// Card counts per status (Neu / Am Lernen / Gemeistert), the input of the progress capsule,
/// the mastery gauge and the status bar.
struct StatusCounts: Hashable, Sendable {
    var fresh: Int
    var learning: Int
    var mastered: Int

    nonisolated init(fresh: Int, learning: Int, mastered: Int) {
        self.fresh = max(0, fresh)
        self.learning = max(0, learning)
        self.mastered = max(0, mastered)
    }

    /// From `Mastery.setProgress` (set cards, sidebar, overview).
    nonisolated init(_ progress: SetProgress) {
        self.init(fresh: progress.fresh, learning: progress.learning, mastered: progress.mastered)
    }

    /// From `LearnEngine.counts` (progress capsule while learning).
    nonisolated init(_ counts: LearnEngine.Counts) {
        self.init(fresh: counts.fresh, learning: counts.learning, mastered: counts.mastered)
    }

    /// From `LearnEngine.checkpoint(_:).counts`.
    nonisolated init(_ counts: LearnEngine.CheckpointCounts) {
        self.init(fresh: counts.fresh, learning: counts.learning, mastered: counts.mastered)
    }

    nonisolated var total: Int { fresh + learning + mastered }

    nonisolated func count(_ status: CardStatus) -> Int {
        switch status {
        case .new: fresh
        case .learning: learning
        case .mastered: mastered
        }
    }

    /// 0…100 like `setProgress().percent` in mastery.js: never 100 before everything is
    /// mastered, never 0 once something is.
    nonisolated var percent: Int {
        guard total > 0 else { return 0 }
        var percent = Int(JSCompat.round(Double(mastered) / Double(total) * 100))
        if mastered < total { percent = min(percent, 99) }
        if mastered > 0 { percent = max(percent, 1) }
        return percent
    }

    /// "45 %" (with a no-break space, like the web app).
    nonisolated var percentText: String { String(localized: "\(percent)\u{00A0}%") }

    /// VoiceOver description, as in the web app: "3 gemeistert, 5 am Lernen, 12 neu".
    nonisolated var accessibilityDescription: String {
        String(localized: "\(mastered) gemeistert, \(learning) am Lernen, \(fresh) neu")
    }
}

// MARK: - Status bar

/// A horizontal bar split into Gemeistert (green) · Am Lernen (amber) · Neu (grey).
/// Empty sets show a full grey bar.
struct StatusBar: View {
    var counts: StatusCounts
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let segments = self.segments
            let gap: CGFloat = segments.count > 1 ? 2 : 0
            let available = max(0, proxy.size.width - gap * CGFloat(segments.count - 1))
            // Every visible segment is at least as wide as it is tall (a dot), the rest is shared
            // proportionally, so tiny counts stay visible without overflowing the bar.
            let minimum = min(height, available / CGFloat(max(1, segments.count)))
            let shared = available - minimum * CGFloat(segments.count)
            HStack(spacing: gap) {
                ForEach(segments, id: \.status) { segment in
                    Capsule(style: .continuous)
                        .fill(segment.status.palette.fill)
                        .frame(width: minimum + shared * segment.fraction)
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
        }
        .frame(height: height)
        .clipShape(Capsule(style: .continuous))
        .motionAnimation(Motion.spring, value: counts)
        .accessibilityHidden(true)
    }

    private struct Segment {
        let status: CardStatus
        let fraction: Double
    }

    private var segments: [Segment] {
        let total = counts.total
        guard total > 0 else { return [Segment(status: .new, fraction: 1)] }
        return [CardStatus.mastered, .learning, .new].compactMap { status in
            let n = counts.count(status)
            return n > 0 ? Segment(status: status, fraction: Double(n) / Double(total)) : nil
        }
    }
}

// MARK: - Progress capsule

/// The learn screen's progress capsule: segmented bar plus counts "Neu · Am Lernen ·
/// Gemeistert" (spec §4.4). Glass by default; pass `isGlass: false` inside a toolbar, which
/// already provides system glass (no glass on glass).
struct ProgressCapsule: View {
    enum Style: Sendable {
        /// Bar and counts with labels ("12 Neu  5 Am Lernen  3 Gemeistert").
        case full
        /// Bar and bare numbers with coloured dots (toolbars, narrow windows).
        case compact
    }

    var counts: StatusCounts
    var style: Style = .full
    var isGlass = true

    var body: some View {
        let content = HStack(spacing: style == .full ? Spacing.m : Spacing.s) {
            StatusBar(counts: counts, height: 7)
                .frame(width: style == .full ? 120 : 72)
            HStack(spacing: style == .full ? Spacing.s : Spacing.xs) {
                ForEach([CardStatus.new, .learning, .mastered], id: \.self) { status in
                    legendItem(status)
                }
            }
        }
        .padding(.horizontal, style == .full ? Spacing.m : Spacing.s)
        .padding(.vertical, style == .full ? 9 : 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lernfortschritt")
        .accessibilityValue(counts.accessibilityDescription)
        .help("\(counts.fresh) Neu · \(counts.learning) Am Lernen · \(counts.mastered) Gemeistert")

        if isGlass {
            content.glassSurface(in: Capsule(style: .continuous))
        } else {
            content
        }
    }

    private func legendItem(_ status: CardStatus) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.palette.fill)
                .frame(width: 7, height: 7)
            Text(counts.count(status), format: .number)
                .font(Typography.count)
                .contentTransition(.numericText())
                .motionAnimation(Motion.snappy, value: counts.count(status))
            if style == .full {
                Text(status.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}

// MARK: - Mastery gauge

/// Circular mastery gauge: green arc for Gemeistert, amber for Am Lernen, on a grey track.
/// `.small` for sidebar rows (no text), `.medium` for set cards (percentage), `.large` for the
/// set header (percentage + "gemeistert").
struct MasteryGauge: View {
    enum Size: Sendable {
        case small, medium, large

        var diameter: CGFloat {
            switch self {
            case .small: 18
            case .medium: 50
            case .large: 128
            }
        }

        var lineWidth: CGFloat {
            switch self {
            case .small: 3.5
            case .medium: 5
            case .large: 12
            }
        }
    }

    var counts: StatusCounts
    var size: Size = .small

    private var total: Double { Double(counts.total) }
    private var masteredEnd: Double { total > 0 ? Double(counts.mastered) / total : 0 }
    private var learningEnd: Double { total > 0 ? Double(counts.mastered + counts.learning) / total : 0 }
    private var isComplete: Bool { counts.total > 0 && counts.mastered == counts.total }

    var body: some View {
        ring
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Lernstand")
            .accessibilityValue("\(counts.percent) Prozent gemeistert. \(counts.accessibilityDescription)")
    }

    private var ring: some View {
        let width = size.lineWidth
        let style = StrokeStyle(lineWidth: width, lineCap: size == .small ? .butt : .round)
        return ZStack {
            Circle()
                .stroke(Theme.new.fill.opacity(size == .small ? 0.9 : 0.55), lineWidth: width)
            if learningEnd > 0 {
                Circle()
                    .trim(from: 0, to: learningEnd)
                    .stroke(Theme.learning.fill, style: style)
                    .rotationEffect(.degrees(-90))
            }
            if masteredEnd > 0 {
                Circle()
                    .trim(from: 0, to: masteredEnd)
                    .stroke(Theme.mastered.fill, style: style)
                    .rotationEffect(.degrees(-90))
            }
            center
        }
        .padding(width / 2)
        .frame(width: size.diameter, height: size.diameter)
        .motionAnimation(Motion.gentle, value: counts)
    }

    @ViewBuilder
    private var center: some View {
        switch size {
        case .small:
            if isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(Theme.mastered.fill)
            }
        case .medium:
            if isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.mastered.text)
            } else {
                Text(counts.percentText)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
        case .large:
            VStack(spacing: 0) {
                Text(counts.percentText)
                    .font(Typography.gaugeValue)
                    .contentTransition(.numericText())
                Text("gemeistert")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
