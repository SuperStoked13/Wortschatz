import AppKit
import SwiftUI
import WortschatzCore
import WortschatzImport

/// "Vokabelliste importieren" in the editor (spec §4.4, port of the panel of
/// src/screens/editor-import.js): a disclosure header, the paste box next to the file drop
/// zone, the progress of PDF reading and text recognition, and the detection (whose pairs are
/// the editor's cards).
struct ImportPanelView: View {
    let model: ImportPanelModel
    /// Files are dragged over the paste box (the sheet shows its drop overlay).
    @Binding var isTextDropTargeted: Bool
    var focus: FocusState<SetEditorField?>.Binding
    let onShowCards: () -> Void
    /// "Text leeren" (through the editor: its cards go too, undoably).
    let onClearText: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radii.panel, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            if model.isExpanded {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    HStack(alignment: .top, spacing: Spacing.m) {
                        ImportPasteBox(model: model, isDropTargeted: $isTextDropTargeted)
                        ImportDropZone(model: model)
                            .frame(width: 218)
                    }
                    .frame(height: 200)
                    tools
                    if model.importer.showsProgress, let progress = model.importer.progress {
                        ImportProgressRow(progress: progress) { model.cancelImport() }
                            .transition(.opacity)
                    }
                    if model.result != nil {
                        ImportDetectionPanel(model: model, focus: focus, onShowCards: onShowCards)
                            .id(SetEditorModel.ScrollTarget.detection)
                            .transition(.opacity)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(Spacing.l)
        .background(.fill.quinary, in: shape)
        .overlay { shape.strokeBorder(Theme.hairline, lineWidth: 1) }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: model.isExpanded)
        .animation(Motion.fade, value: model.importer.showsProgress)
        .animation(Motion.fade, value: model.result == nil)
    }

    private var header: some View {
        Button {
            model.isExpanded.toggle()
            if model.isExpanded { model.focusTextArea() }
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Radii.small, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vokabelliste importieren")
                        .font(Typography.headline)
                    Text("Text einfügen, Datei hochladen oder Foto – die Paare werden automatisch erkannt.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(model.isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Vokabelliste importieren")
        .accessibilityValue(model.isExpanded ? "Ausgeklappt" : "Eingeklappt")
        .accessibilityHint("Text einfügen, Datei hochladen oder Foto – die Paare werden automatisch erkannt.")
        .accessibilityAddTraits(.isHeader)
    }

    private var tools: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(ImportPanelModel.hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            if model.hasText {
                Button("Text leeren", systemImage: "xmark.circle", action: onClearText)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The paste box with its placeholder and focus ring.
private struct ImportPasteBox: View {
    let model: ImportPanelModel
    @Binding var isDropTargeted: Bool

    @State private var isFocused = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radii.small + 2, style: .continuous)
        ImportTextView(
            text: Binding(get: { model.text }, set: { model.edit($0) }),
            focusToken: model.focusToken,
            onFocusChange: { isFocused = $0 },
            onImport: { model.importSources($0) },
            onDragTargetChange: { isDropTargeted = $0 }
        )
        .overlay(alignment: .topLeading) {
            if model.text.isEmpty {
                Text(ImportPanelModel.placeholder)
                    .font(.system(size: NSFont.systemFontSize + 1))
                    .foregroundStyle(Color(nsColor: .placeholderTextColor))
                    .padding(.horizontal, ImportTextView.inset.width)
                    .padding(.vertical, ImportTextView.inset.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(isFocused ? Theme.accent : Theme.hairline, lineWidth: isFocused ? 2 : 1)
                .allowsHitTesting(false)
        }
    }
}

/// "Datei hierher ziehen": formats, the file chooser and the clipboard import.
private struct ImportDropZone: View {
    let model: ImportPanelModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radii.small + 2, style: .continuous)
        VStack(spacing: Spacing.xs) {
            ZStack {
                tile("doc.text")
                    .rotationEffect(.degrees(-8))
                    .offset(x: -13, y: 2)
                tile("photo")
                    .rotationEffect(.degrees(7))
                    .offset(x: 13, y: -1)
            }
            .frame(height: 46)
            .accessibilityHidden(true)
            VStack(spacing: 2) {
                Text("Datei hierher ziehen")
                    .font(.headline)
                Text("TXT, CSV, PDF oder Foto")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            SecondaryButton("Datei wählen…", systemImage: "folder", controlSize: .regular) {
                model.isChoosingFiles = true
            }
            .padding(.top, 2)
            Button {
                model.importFromPasteboard()
            } label: {
                HStack(spacing: 5) {
                    Text("Bild aus Zwischenablage")
                    Keycap(.command("V"), size: .small)
                }
                .font(.callout)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accentText)
            .help("Ein kopiertes Bild oder kopierte Dateien importieren (⌘V im Textfeld)")
            .accessibilityHint("Kurzbefehl im Textfeld: Befehlstaste-V")
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.accentSoft.opacity(0.5), in: shape)
        .overlay {
            shape.strokeBorder(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        }
    }

    private func tile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(Theme.accent)
            .frame(width: 38, height: 44)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}

/// Progress of a slow import (PDF pages, text recognition) with "Abbrechen".
private struct ImportProgressRow: View {
    let progress: ImportProgress
    let onCancel: () -> Void

    var body: some View {
        let fraction = min(1, max(0, progress.fraction))
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(progress.message)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: Spacing.s)
                Text("\(Int((fraction * 100).rounded())) %")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button("Abbrechen", action: onCancel)
                    .controlSize(.small)
                    .help("Import abbrechen (esc)")
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .accessibilityLabel("Fortschritt der Texterkennung")
                .accessibilityValue("\(Int((fraction * 100).rounded())) Prozent")
        }
        .padding(Spacing.s)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radii.small, style: .continuous))
    }
}
