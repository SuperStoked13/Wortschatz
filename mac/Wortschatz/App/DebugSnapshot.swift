#if DEBUG
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Debug snapshot harness
//
// Renders registered SwiftUI views to PNG files (light and dark) and quits. DEBUG builds only.
//
//     APP="<derived data>/Build/Products/Debug/Wortschatz.app/Contents/MacOS/Wortschatz"
//     "$APP" --render-snapshots /path/to/dir                       # every scene, light + dark
//     "$APP" --render-snapshots /path/to/dir --snapshot-filter learn,design-buttons
//     "$APP" --list-snapshots                                      # print scene names
//
// Options:
//   --snapshot-filter a,b         only scenes whose name contains one of the substrings
//   --snapshot-appearance light|dark|both   (default: each scene's own list, normally both)
//   --snapshot-renderer window|image        (default: window, see below)
//   --snapshot-inactive           render controls in their inactive-window look
//
// Output: <dir>/<scene>-light.png and <scene>-dark.png (scenes with several sizes add
// `-<w>x<h>`), at the screen's backing scale (2× on Retina). The last line printed is
// `SNAPSHOT_DIR=<absolute path>`.
//
// SANDBOX: the app is sandboxed, so it can only write inside its container. When <dir> is not
// writable the PNGs go to
//     ~/Library/Containers/app.wortschatz.mac/Data/tmp/WortschatzSnapshots/<name>-<hash>/
// (one folder per requested path, so parallel runs do not collide). Read SNAPSHOT_DIR and copy:
//     out=$("$APP" --render-snapshots "$DIR" | sed -n 's/^SNAPSHOT_DIR=//p'); ditto "$out" "$DIR"
//
// How it renders: each scene is hosted in a borderless, off-screen window, and
// the window server's composite of that window is captured (CGWindowListCreateImage, looked up at
// runtime because the SDK marks it obsolete; capturing your own windows needs no screen-recording
// permission). This is the only route that shows real Liquid Glass, materials, MeshGradient and
// AppKit-backed controls. `ImageRenderer` draws glass, glass buttons and toggles as nothing or
// flat, and `NSView.cacheDisplay` misses glass and Metal-backed gradients; ImageRenderer is kept
// as an automatic fallback (and `--snapshot-renderer image`) if the capture is unavailable.
// The app is never activated (accessory policy: no Dock icon, no menu bar, keyboard focus stays
// where it is); the window reports key appearance so controls still render in their active look.
//
// The harness takes over the process in `WortschatzApp.init()`, before SwiftUI creates any scene,
// so no app window appears, no window state is saved and the library store is never opened.
//
// REGISTERING VIEWS (from any file, no central list): subclass `SnapshotCatalog`.
//
//     #if DEBUG
//     final class LearnSnapshots: SnapshotCatalog {
//         override class var scenes: [SnapshotScene] {
//             [
//                 SnapshotScene("learn-mc") { LearnPreviewHost(state: .sampleMultipleChoice) },
//                 SnapshotScene("learn-written", size: CGSize(width: 1000, height: 700)) { … },
//                 SnapshotScene("learn-card", sizes: [CGSize(width: 980, height: 640), CGSize(width: 1440, height: 900)]) { … },
//             ]
//         }
//     }
//     #endif
//
// Rules for scene content: use in-memory sample data (e.g. `LibraryStore` with a MemoryBackend),
// never the real store or the network; the view is laid out at exactly the scene size (add
// `AppBackdrop()` yourself for screens that have one); `@Environment(\.isSnapshotRendering)` is true
// so decorative animation shows a still frame. Scene names: lowercase-kebab, unique.

/// One view rendered by `--render-snapshots`.
struct SnapshotScene {
    /// Default size: the app window's default size (spec §4.1).
    static let windowSize = CGSize(width: 1240, height: 800)

    let name: String
    let sizes: [CGSize]
    let colorSchemes: [ColorScheme]
    /// Seconds the window runs before the capture (layout, `.task`, appear animations).
    let settleTime: TimeInterval
    let makeContent: () -> AnyView

    init<Content: View>(
        _ name: String,
        size: CGSize = SnapshotScene.windowSize,
        colorSchemes: [ColorScheme] = [.light, .dark],
        settleTime: TimeInterval = 0.6,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(name, sizes: [size], colorSchemes: colorSchemes, settleTime: settleTime, content: content)
    }

    init<Content: View>(
        _ name: String,
        sizes: [CGSize],
        colorSchemes: [ColorScheme] = [.light, .dark],
        settleTime: TimeInterval = 0.6,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.name = name
        self.sizes = sizes.isEmpty ? [SnapshotScene.windowSize] : sizes
        self.colorSchemes = colorSchemes.isEmpty ? [.light, .dark] : colorSchemes
        self.settleTime = settleTime
        makeContent = { AnyView(content()) }
    }
}

/// Subclass this (in a `#if DEBUG` block of your own file) and override `scenes` to register
/// views with the snapshot harness. Subclasses are found at runtime.
class SnapshotCatalog: NSObject {
    /// The catalog's scenes, in render order.
    class var scenes: [SnapshotScene] { [] }
}

// MARK: - Harness

enum DebugSnapshotHarness {
    /// Called from `WortschatzApp.init()`. Returns immediately unless the process was launched
    /// with `--render-snapshots <dir>` or `--list-snapshots`; then it renders and exits.
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        if arguments.contains("--list-snapshots") {
            for scene in allScenes() {
                let sizes = scene.sizes.map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: ", ")
                print("\(scene.name)  [\(sizes)]")
            }
            exit(0)
        }
        guard let flag = arguments.firstIndex(of: "--render-snapshots") else { return }
        guard flag + 1 < arguments.count, !arguments[flag + 1].hasPrefix("--") else {
            printError("--render-snapshots needs an output directory")
            exit(2)
        }
        let options = Options(arguments: arguments, output: arguments[flag + 1])
        exit(render(options))
    }

    // MARK: Options

    private struct Options {
        enum Renderer { case window, image }

        var output: String
        var filters: [String] = []
        var appearances: [ColorScheme]?
        var renderer: Renderer = .window
        var activeLook = true

        init(arguments: [String], output: String) {
            self.output = (output as NSString).expandingTildeInPath
            func value(_ name: String) -> String? {
                guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
                return arguments[i + 1]
            }
            if let filter = value("--snapshot-filter") {
                filters = filter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            switch value("--snapshot-appearance") {
            case "light": appearances = [.light]
            case "dark": appearances = [.dark]
            default: appearances = nil
            }
            if value("--snapshot-renderer") == "image" { renderer = .image }
            if arguments.contains("--snapshot-inactive") { activeLook = false }
        }
    }

    // MARK: Run

    private static func render(_ options: Options) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let scenes = allScenes().filter { scene in
            options.filters.isEmpty || options.filters.contains { scene.name.localizedCaseInsensitiveContains($0) }
        }
        guard !scenes.isEmpty else {
            printError("no snapshot scenes match \(options.filters)")
            return 1
        }
        guard let directory = outputDirectory(for: options.output) else {
            printError("cannot create an output directory")
            return 1
        }

        var failures = 0
        for scene in scenes {
            for size in scene.sizes {
                for scheme in options.appearances ?? scene.colorSchemes {
                    let sizeSuffix = scene.sizes.count > 1 ? "-\(Int(size.width))x\(Int(size.height))" : ""
                    let file = directory.appending(path: "\(scene.name)\(sizeSuffix)-\(scheme == .dark ? "dark" : "light").png")
                    let rendered = renderImage(scene, size: size, scheme: scheme, options: options)
                    if let (image, via) = rendered, write(image, to: file) {
                        print("ok  \(file.lastPathComponent)  \(image.width)x\(image.height)  (\(via))")
                    } else {
                        failures += 1
                        printError("failed: \(file.lastPathComponent)")
                    }
                }
            }
        }
        print("SNAPSHOT_DIR=\(directory.path(percentEncoded: false))")
        fflush(stdout)
        return failures == 0 ? 0 : 1
    }

    // MARK: Scenes

    static func allScenes() -> [SnapshotScene] {
        // Every subclass in this image (the app, or its debug dylib), wherever it is declared.
        let classes = objc_enumerateClasses(fromImage: .machHeader(#dsohandle), subclassing: SnapshotCatalog.self)
            .compactMap { $0 as? SnapshotCatalog.Type }
            .sorted { NSStringFromClass($0) < NSStringFromClass($1) }
        var seen = Set<String>()
        var scenes: [SnapshotScene] = []
        for catalog in classes {
            for scene in catalog.scenes {
                if seen.insert(scene.name).inserted {
                    scenes.append(scene)
                } else {
                    printError("duplicate scene name \"\(scene.name)\" in \(NSStringFromClass(catalog)), skipped")
                }
            }
        }
        return scenes
    }

    // MARK: Rendering

    private static func renderImage(
        _ scene: SnapshotScene, size: CGSize, scheme: ColorScheme, options: Options
    ) -> (CGImage, String)? {
        let root = scene.makeContent()
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshotRendering, true)

        if options.renderer == .window, WindowCapture.isAvailable {
            if let image = captureInWindow(root, size: size, scheme: scheme, settleTime: scene.settleTime, activeLook: options.activeLook),
               !isBlank(image) {
                return (image, "window")
            }
        }
        let renderer = ImageRenderer(content: root)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        renderer.proposedSize = ProposedViewSize(size)
        renderer.isOpaque = true
        return renderer.cgImage.map { ($0, "ImageRenderer") }
    }

    private static func captureInWindow(
        _ root: some View, size: CGSize, scheme: ColorScheme, settleTime: TimeInterval, activeLook: Bool
    ) -> CGImage? {
        let frame = CGRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = frame

        let window = activeLook
            ? KeyLookingSnapshotWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            : SnapshotWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.hasShadow = false
        // No zoom-in animation: the window server would capture the window mid-transform.
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        // Far outside every screen: invisible to the user, still composited by the window server.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        pump(for: settleTime)
        return WindowCapture.image(of: window)
    }

    /// Runs the event loop (SwiftUI updates, `.task`, appear animations) for a while.
    private static func pump(for seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// True when the capture came back fully transparent (window not composited).
    private static func isBlank(_ image: CGImage) -> Bool {
        let side = 8
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return false }
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        for i in stride(from: 3, to: side * side * 4, by: 4) where bytes[i] != 0 {
            return false
        }
        return true
    }

    // MARK: Files

    /// `path` if the sandbox lets us write there, else a per-path folder in the container's tmp.
    private static func outputDirectory(for path: String) -> URL? {
        let requested = URL(filePath: path, directoryHint: .isDirectory)
        if isWritableDirectory(requested) { return requested }
        let fallback = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "WortschatzSnapshots", directoryHint: .isDirectory)
            .appending(path: "\(sanitized(requested.lastPathComponent))-\(stableHash(path))", directoryHint: .isDirectory)
        print("note: \(path) is outside the app sandbox, writing to the container instead")
        return isWritableDirectory(fallback) ? fallback : nil
    }

    private static func isWritableDirectory(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appending(path: ".write-probe-\(ProcessInfo.processInfo.processIdentifier)")
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private static func sanitized(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(name.map { allowed.contains($0) ? $0 : "_" }.prefix(48))
        return cleaned.isEmpty ? "snapshots" : cleaned
    }

    /// FNV-1a, so the same requested path always maps to the same fallback folder.
    private static func stableHash(_ text: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(hash, radix: 16)
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
    }
}

/// The off-screen window a scene is hosted in.
private class SnapshotWindow: NSWindow {}

/// Draws its controls as in the frontmost key window (accent-filled `.glassProminent`
/// buttons, tinted switches, glass shadows) without activating the app, so a snapshot run never
/// takes keyboard focus away from the user. AppKit asks the window for `hasKeyAppearance`
/// (an AppKit-internal property) when it styles controls; DEBUG builds only.
private final class KeyLookingSnapshotWindow: SnapshotWindow {
    @objc var hasKeyAppearance: Bool { true }
}

/// Window-server capture of one of our own windows.
private enum WindowCapture {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage` is obsolete in the SDK (Swift cannot call it) but still exported
    /// by CoreGraphics; the snapshot harness only needs it for its own windows.
    private static let createImage: CreateImage? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    static var isAvailable: Bool { createImage != nil }

    static func image(of window: NSWindow) -> CGImage? {
        guard let createImage, window.windowNumber > 0 else { return nil }
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        return createImage(
            .null,
            CGWindowListOption.optionIncludingWindow.rawValue,
            UInt32(window.windowNumber),
            options.rawValue
        )?.takeRetainedValue()
    }
}
#endif
