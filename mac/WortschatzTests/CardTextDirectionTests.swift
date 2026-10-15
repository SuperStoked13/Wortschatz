import AppKit
import SwiftUI
import Testing
import WortschatzCore

@testable import Wortschatz

/// Arabic card text runs right to left on the text view only (spec «Screens»): a text on a line
/// of its own starts at the right edge, a text that hugs its words keeps its place, and an answer
/// field aligns its text to the right; every other language stays left to right.
@MainActor
@Suite("Kartentext: Schreibrichtung")
struct CardTextDirectionTests {
    @Test("Nur Arabisch läuft von rechts nach links")
    func directions() {
        #expect(CardTextDirection.layoutDirection(.ar) == .rightToLeft)
        #expect(CardTextDirection.fieldAlignment(.ar) == .trailing)
        for lang in Lang.allCases where lang != .ar {
            #expect(CardTextDirection.layoutDirection(lang) == .leftToRight, "\(lang)")
            #expect(CardTextDirection.fieldAlignment(lang) == .leading, "\(lang)")
        }
        #expect(CardTextDirection.layoutDirection(nil) == .leftToRight)
        #expect(CardTextDirection.fieldAlignment(nil) == .leading)
    }

    @Test("Arabischer Text auf eigener Zeile beginnt am rechten Rand")
    func textLine() throws {
        let arabic = try #require(Self.ink(Text("مرحبا بكم").cardTextLine(.ar)))
        #expect(arabic.lowerBound > Self.width / 2, "Arabisch: \(arabic)")
        #expect(arabic.upperBound > Self.width - 20, "Arabisch: \(arabic)")

        let french = try #require(Self.ink(Text("la maison").cardTextLine(.fr)))
        #expect(french.lowerBound < 20, "Französisch: \(french)")
        #expect(french.upperBound < Self.width / 2, "Französisch: \(french)")
    }

    @Test("Ein Text, der seine Wörter umschliesst, bleibt, wo er ist")
    func huggingText() throws {
        let view = VStack(alignment: .leading) {
            Text("مرحبا بكم").cardTextDirection(.ar)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        let arabic = try #require(Self.ink(view))
        #expect(arabic.lowerBound < 20, "Arabisch: \(arabic)")
    }

    @Test("Ein arabisches Antwortfeld richtet seinen Text rechts aus", arguments: [false, true])
    func field(vertical: Bool) throws {
        #expect(try Self.fieldAlignment(lang: .ar, vertical: vertical) == .right)
        #expect(try Self.fieldAlignment(lang: .fr, vertical: vertical) != .right)
        #expect(try Self.fieldAlignment(lang: .zh, vertical: vertical) != .right)
    }

    // MARK: Helpers

    private static let width: CGFloat = 320

    /// A field in `lang` like the study screens' (plain style, `cardFieldDirection`): the
    /// alignment AppKit draws it with.
    private static func fieldAlignment(lang: Lang, vertical: Bool) throws -> NSTextAlignment {
        let field = FieldHost(text: "مرحبا", vertical: vertical).cardFieldDirection(lang)
        let host = host(field)
        defer { host.window?.close() }
        let textField = try #require(Self.textField(in: host))
        return textField.alignment
    }

    private struct FieldHost: View {
        @State var text: String
        let vertical: Bool

        var body: some View {
            if vertical {
                TextField("Antwort", text: $text, axis: .vertical).textFieldStyle(.plain)
            } else {
                TextField("Antwort", text: $text).textFieldStyle(.plain)
            }
        }
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = textField(in: subview) { return field }
        }
        return nil
    }

    /// Hosts `view` (`width` × 40, white, light) in an off-screen window and lays it out.
    private static func host(_ view: some View) -> NSHostingView<AnyView> {
        let root = AnyView(
            view.frame(width: width, height: 40)
                .background(Color.white)
                .environment(\.colorScheme, .light))
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: width, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The horizontal extent (in points) of the dark pixels `view` draws, nil when it draws none.
    private static func ink(_ view: some View) -> ClosedRange<CGFloat>? {
        let host = host(view)
        defer { host.window?.close() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        var minX = Int.max
        var maxX = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent + color.greenComponent + color.blueComponent < 2 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        let scale = CGFloat(rep.pixelsWide) / width
        return CGFloat(minX) / scale...CGFloat(maxX) / scale
    }
}
