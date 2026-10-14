import SwiftUI

/// A glass statistic tile for the overview and results: symbol, big number, title and an
/// optional caption (spec §4.4: Lernserie, Heute beantwortet, Begriffe gemeistert).
///
/// ```swift
/// StatTile("Lernserie", value: "5", unit: "Tage", systemImage: "flame.fill", tint: Theme.flame,
///          caption: "Rekord: 12 Tage")
/// ```
struct StatTile: View {
    let title: String
    let value: String
    var unit: String?
    var systemImage: String
    var tint: Color
    var caption: String?

    init(
        _ title: String,
        value: String,
        unit: String? = nil,
        systemImage: String,
        tint: Color = Theme.accent,
        caption: String? = nil
    ) {
        self.title = title
        self.value = value
        self.unit = unit
        self.systemImage = systemImage
        self.tint = tint
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(Typography.statValue)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .glassSurface(cornerRadius: Radii.tile)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value, unit, caption].compactMap(\.self).joined(separator: " "))
    }
}
