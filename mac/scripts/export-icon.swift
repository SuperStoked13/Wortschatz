// Renders the download site's icon images from the app icon (mac/Wortschatz/Resources/AppIcon.icon, made with
// Icon Composer) with Xcode's ictool: light and dark in the macOS shape with margin and shadow, the opaque
// apple-touch-icon and favicon.ico, compressed with pngcrush. Run it after changing the icon in Icon Composer.
// Usage (from the repo root, on a Mac with Xcode 26 or newer):
//   swift mac/scripts/export-icon.swift [<AppIcon.icon>] [<Downloadseite/public>]
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let iconURL = URL(fileURLWithPath: args.count > 1 ? args[1] : "mac/Wortschatz/Resources/AppIcon.icon")
let publicURL = URL(fileURLWithPath: args.count > 2 ? args[2] : "Downloadseite/public", isDirectory: true)
let imgURL = publicURL.appendingPathComponent("assets/img", isDirectory: true)
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("export-icon-\(getpid())", isDirectory: true)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("export-icon: \(message)\n".utf8))
    exit(1)
}

func run(_ path: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { fail("\(path): \(error)") }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    if process.terminationStatus != 0 { fail("\(path) \(arguments.joined(separator: " ")):\n\(output)") }
    return output
}

guard FileManager.default.fileExists(atPath: iconURL.appendingPathComponent("icon.json").path) else {
    fail("no icon at \(iconURL.path)")
}
let developer = run("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
let ictool = URL(fileURLWithPath: developer)
    .deletingLastPathComponent()
    .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool").path
guard FileManager.default.isExecutableFile(atPath: ictool) else { fail("ictool not found (Xcode 26 or newer?)") }

/// ictool's rendering of the icon, `pixels` wide, as the system draws it (macOS: masked squircle without margin).
func render(platform: String, rendition: String, pixels: Int) -> CGImage {
    let file = tmp.appendingPathComponent("\(platform)-\(rendition)-\(pixels).png")
    _ = run(ictool, [
        iconURL.path, "--export-image", "--output-file", file.path, "--platform", platform, "--rendition", rendition,
        "--width", "\(pixels)", "--height", "\(pixels)", "--scale", "1",
    ])
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("ictool wrote no image") }
    return image
}

func context(_ pixels: Int, opaque: Bool = false) -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: info)!
    ctx.interpolationQuality = .high
    return ctx
}

/// The icon on the macOS grid (824 of 1024 with a soft shadow below), like the Dock shows it.
func macIcon(_ rendition: String, pixels: Int) -> CGImage {
    let scale = CGFloat(pixels) / 1024
    let body = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let image = render(platform: "macOS", rendition: rendition, pixels: max(64, Int((824 * scale * 2).rounded())))
    let ctx = context(pixels)
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.draw(image, in: body)
    return ctx.makeImage()!
}

/// PNG, made smaller losslessly with Xcode's pngcrush (the site limits bytes per address, and a whole class often
/// shares one).
var pngCount = 0
func pngData(_ image: CGImage) -> Data {
    pngCount += 1
    let plain = tmp.appendingPathComponent("plain-\(pngCount).png")
    let crushed = tmp.appendingPathComponent("crushed-\(pngCount).png")
    guard let dest = CGImageDestinationCreateWithURL(plain as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("png encoding failed")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("png encoding failed") }
    _ = run("/usr/bin/xcrun", ["pngcrush", "-q", "-rem", "alla", "-reduce", "-brute", plain.path, crushed.path])
    guard let data = try? Data(contentsOf: crushed) else { fail("pngcrush wrote nothing") }
    return data
}

func write(_ data: Data, _ url: URL) {
    do { try data.write(to: url) } catch { fail("\(url.path): \(error)") }
    print("wrote \(url.path)")
}

for pixels in [64, 128, 256, 512] {
    write(pngData(macIcon("Default", pixels: pixels)), imgURL.appendingPathComponent("icon-\(pixels).png"))
    write(pngData(macIcon("Dark", pixels: pixels)), imgURL.appendingPathComponent("icon-dark-\(pixels).png"))
}

// apple-touch-icon: opaque and full bleed, iOS rounds the corners itself. ictool's rendering is already
// rounded, so the corners get the icon's background colours (top and bottom pixel of the centre column).
let touch = context(180, opaque: true)
let iosFull = render(platform: "iOS", rendition: "Default", pixels: 360)
let column = context(360)
column.draw(iosFull, in: CGRect(x: 0, y: 0, width: 360, height: 360))
func pixelColor(_ ctx: CGContext, x: Int, y: Int) -> CGColor {
    let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let i = (ctx.height - 1 - y) * ctx.bytesPerRow + x * 4
    let a = max(CGFloat(bytes[i + 3]) / 255, 0.001)
    return CGColor(srgbRed: CGFloat(bytes[i]) / 255 / a, green: CGFloat(bytes[i + 1]) / 255 / a,
                   blue: CGFloat(bytes[i + 2]) / 255 / a, alpha: 1)
}
let corners = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                         colors: [pixelColor(column, x: 180, y: 357), pixelColor(column, x: 180, y: 2)] as CFArray,
                         locations: [0, 1])!
touch.drawLinearGradient(corners, start: CGPoint(x: 0, y: 180), end: CGPoint(x: 0, y: 0), options: [])
touch.draw(iosFull, in: CGRect(x: 0, y: 0, width: 180, height: 180))
let touchPNG = pngData(touch.makeImage()!)
for path in ["assets/img/apple-touch-icon.png", "apple-touch-icon.png", "apple-touch-icon-precomposed.png"] {
    write(touchPNG, publicURL.appendingPathComponent(path))
}

// favicon.ico with PNG entries (16, 32, 48).
let entries = [16, 32, 48].map { ($0, pngData(macIcon("Default", pixels: $0))) }
var ico = Data([0, 0, 1, 0, UInt8(entries.count), 0])
var offset = 6 + 16 * entries.count
for (pixels, png) in entries {
    ico.append(contentsOf: [UInt8(pixels), UInt8(pixels), 0, 0, 1, 0, 32, 0])
    withUnsafeBytes(of: UInt32(png.count).littleEndian) { ico.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(offset).littleEndian) { ico.append(contentsOf: $0) }
    offset += png.count
}
for (_, png) in entries { ico.append(png) }
write(ico, publicURL.appendingPathComponent("favicon.ico"))
