import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WortschatzCore

/// "Als Text exportieren" (port of `openExport` in set.js): separators for terms and cards, a
/// preview, "Kopieren" and "Sichern… ↩" (a UTF-8 text file named after the set). With "Neue
/// Zeile" between cards the list can be imported again here and in Quizlet.
struct TextExportSheet: View {
    let request: TextExportRequest

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var termSeparator: TermSeparator = .tab
    @State private var cardSeparator: CardSeparator = .newline
    @State private var isSaving = false

    enum TermSeparator: String, CaseIterable, Identifiable {
        case tab, comma, dash
        var id: String { rawValue }
        var label: String {
            switch self {
            case .tab: "Tab"
            case .comma: "Komma"
            case .dash: "Bindestrich"
            }
        }

        var separator: String {
            switch self {
            case .tab: "\t"
            case .comma: ", "
            case .dash: " - "
            }
        }
    }

    enum CardSeparator: String, CaseIterable, Identifiable {
        case newline, semicolon
        var id: String { rawValue }
        var label: String {
            switch self {
            case .newline: "Neue Zeile"
            case .semicolon: "Strichpunkt"
            }
        }

        var separator: String {
            switch self {
            case .newline: "\n"
            case .semicolon: ";"
            }
        }
    }

    private var set: VocabSet? { model.store.getSet(request.setID) }

    private var text: String {
        guard let set else { return "" }
        return Backup.setToText(set, termSep: termSeparator.separator, cardSep: cardSeparator.separator)
    }

    /// The preview: real tabs would jump to 8-column stops; like the web app's tab size, they
    /// are expanded to the column after the longest term (at most 48), so the list reads as two
    /// columns. Copying and saving keep the tabs.
    private var previewText: String {
        guard termSeparator == .tab, let set else { return text }
        let longest = set.cards.map(\.term.count).max() ?? 0
        let tabSize = min(48, longest + 3)
        var out = ""
        var column = 0
        for ch in text {
            switch ch {
            case "\t":
                let spaces = tabSize - column % tabSize
                out += String(repeating: " ", count: spaces)
                column += spaces
            case "\n":
                out.append(ch)
                column = 0
            default:
                out.append(ch)
                column += 1
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Als Text exportieren")
                    .font(Typography.title)
                Text("Kopiere die Liste oder sichere sie als Textdatei. Mit «Neue Zeile» zwischen den Karten lässt sie sich in Wortschatz und Quizlet wieder importieren.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
                GridRow {
                    Text("Zwischen Begriff und Definition")
                        .gridColumnAlignment(.trailing)
                    Picker("Zwischen Begriff und Definition", selection: $termSeparator) {
                        ForEach(TermSeparator.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Zwischen den Karten")
                    Picker("Zwischen den Karten", selection: $cardSeparator) {
                        ForEach(CardSeparator.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            ScrollView {
                Text(previewText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Spacing.s)
            }
            .frame(height: 260)
            .background(.background, in: RoundedRectangle(cornerRadius: Radii.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radii.small, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .accessibilityLabel("Exportierter Text")

            HStack {
                Button("Kopieren", systemImage: "doc.on.doc") { copy() }
                    .controlSize(.large)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                PrimaryActionButton("Sichern…", systemImage: "square.and.arrow.down") {
                    isSaving = true
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 600)
        .fileExporter(
            isPresented: $isSaving,
            document: DataFileDocument(text: text),
            contentType: .plainText,
            defaultFilename: Backup.textFileName(for: set?.title ?? "")
        ) { result in
            switch result {
            case .success:
                model.toasts.show("«\(AppModel.shortTitle(set?.title ?? ""))» als Textdatei exportiert", tone: .success)
                dismiss()
            case let .failure(error):
                if (error as? CocoaError)?.code != .userCancelled {
                    model.report(error, fallback: "Der Export ist fehlgeschlagen.")
                }
            }
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
            model.toasts.show("Text kopiert", tone: .success)
        } else {
            model.toasts.show("Kopieren hat nicht geklappt. Markiere den Text und kopiere ihn von Hand.", tone: .danger)
        }
    }
}
