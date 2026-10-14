import AppKit
import SwiftUI
import Testing

@testable import Wortschatz

/// Buttons in one row (the set page's Lernen ↩ · Schreiben · Karteikarten · …) have the same
/// height, with or without keycap, whatever their symbol.
@MainActor
@Suite("Aktionsknöpfe")
struct ActionButtonTests {
    @MainActor
    private final class Heights {
        var values: [String: CGFloat] = [:]
    }

    @Test("Alle gleich hoch, mit und ohne Tastenkappe", arguments: [ControlSize.large, .regular])
    func sameHeight(controlSize: ControlSize) async throws {
        let heights = Heights()
        func measured(_ name: String, _ button: some View) -> some View {
            button.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.values[name] = $0 }
        }
        let row = HStack(spacing: 12) {
            measured("Lernen ↩", PrimaryActionButton("Lernen", systemImage: "sparkles", controlSize: controlSize) {})
            measured("Schreiben", SecondaryButton("Schreiben", systemImage: "keyboard", controlSize: controlSize) {})
            measured("Karteikarten", SecondaryButton("Karteikarten", systemImage: "rectangle.on.rectangle.angled", controlSize: controlSize) {})
            measured("Nur schwierige", SecondaryButton(verbatim: "Nur schwierige (2)", systemImage: "flame", controlSize: controlSize) {})
            measured("ohne Symbol", SecondaryButton("Bearbeiten", controlSize: controlSize) {})
        }
        .padding(20)
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 1000, height: 120), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = NSHostingView(rootView: row)
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))

        #expect(heights.values.count == 5)
        #expect(Set(heights.values.values).count == 1, "Höhen: \(heights.values)")
    }
}
