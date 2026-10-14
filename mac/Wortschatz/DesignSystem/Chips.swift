import SwiftUI
import WortschatzCore

// Chips are plain (non-glass) capsules, so they can sit inside glass cards and table rows.

/// A small tinted capsule with an optional symbol: the base of all chips.
struct TintedChip: View {
    let text: String
    var systemImage: String?
    var palette: Theme.StatusPalette
    var size: ControlSize = .regular

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .fontWeight(.semibold)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(size == .small ? .caption.weight(.semibold) : .callout.weight(.medium))
        .foregroundStyle(palette.text)
        .padding(.horizontal, size == .small ? 7 : 10)
        .padding(.vertical, size == .small ? 2 : 4)
        .background(palette.soft, in: Capsule(style: .continuous))
        .fixedSize()
    }
}

/// Status of a card: "● Gemeistert" in green, "● Am Lernen" in amber, "● Neu" in grey.
struct StatusChip: View {
    let status: CardStatus
    var size: ControlSize = .regular

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.palette.fill)
                .frame(width: 7, height: 7)
            Text(status.label)
                .lineLimit(1)
        }
        .font(size == .small ? .caption.weight(.semibold) : .callout.weight(.medium))
        .foregroundStyle(status.palette.text)
        .padding(.horizontal, size == .small ? 7 : 10)
        .padding(.vertical, size == .small ? 2 : 4)
        .background(status.palette.soft, in: Capsule(style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.label)")
    }
}

/// The language pair of a set: "Französisch → Deutsch" (or "FR → DE" when `.short`).
struct LanguageCapsule: View {
    enum Style: Sendable { case full, short }

    let termLang: Lang
    let defLang: Lang
    var style: Style = .full

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "character.bubble")
                .imageScale(.small)
            Text(name(termLang))
            Image(systemName: "arrow.right")
                .imageScale(.small)
                .fontWeight(.semibold)
                .opacity(0.7)
            Text(name(defLang))
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(Theme.accentText)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.accentSoft, in: Capsule(style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Labels.langName(termLang)) nach \(Labels.langName(defLang))")
    }

    private func name(_ lang: Lang) -> String {
        style == .full ? Labels.langName(lang) : Labels.langShort(lang)
    }
}

/// A tolerance note of a correct answer ("Artikel fehlte", "Tippfehler"), `Labels.NOTE_LABELS`.
/// A synonym from outside the set ("Synonym – nicht im Set") gets the accent colour and ✦, with
/// a tooltip saying where it comes from.
struct NoteChip: View {
    let text: String
    var size: ControlSize = .regular
    private var isExtendedSynonym = false

    init(_ note: GradeNote, size: ControlSize = .regular) {
        text = Labels.NOTE_LABELS[note] ?? note.rawValue
        self.size = size
        isExtendedSynonym = note == .extendedSynonym
    }

    init(verbatim text: String, size: ControlSize = .regular) {
        self.text = text
        self.size = size
    }

    var body: some View {
        if isExtendedSynonym {
            TintedChip(
                text: text, systemImage: "sparkles",
                palette: Theme.StatusPalette(fill: Theme.accent, text: Theme.accentText, soft: Theme.accentSoft), size: size
            )
            .help(Self.extendedSynonymHelp)
            .accessibilityLabel("Hinweis: \(text)")
            .accessibilityHint(Self.extendedSynonymHelp)
        } else {
            TintedChip(text: text, systemImage: "info.circle", palette: Theme.info, size: size)
                .accessibilityLabel("Hinweis: \(text)")
        }
    }

    static let extendedSynonymHelp =
        "Apple Intelligence hat dein Wort als gleichbedeutend erkannt. Es steht nicht in deinem Lernset – gesucht war das Wort darüber."
}

/// A hint for a wrong answer ("Falscher Artikel", "Fast – ein kleiner Tippfehler"), `Labels.HINT_LABELS`.
struct HintChip: View {
    let text: String
    var size: ControlSize = .regular

    init(_ hint: GradeHint, size: ControlSize = .regular) {
        text = Labels.HINT_LABELS[hint] ?? hint.rawValue
        self.size = size
    }

    init(verbatim text: String, size: ControlSize = .regular) {
        self.text = text
        self.size = size
    }

    var body: some View {
        TintedChip(text: text, systemImage: "lightbulb.fill", palette: Theme.warning, size: size)
            .accessibilityLabel("Tipp: \(text)")
    }
}
