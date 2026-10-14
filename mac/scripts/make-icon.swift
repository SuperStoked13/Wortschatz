// Renders the placeholder app icon (violet gradient squircle, two stacked white cards, a check)
// into every macOS AppIcon size.
// Usage: swift mac/scripts/make-icon.swift <AppIcon.appiconset directory>
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon in a 1024 × 1024 coordinate space (origin bottom-left).
func draw(_ ctx: CGContext) {
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    ctx.clear(canvas)

    // Squircle on the macOS icon grid (824 pt body, 100 pt margin) with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0x5146E5))
    ctx.fillPath()
    ctx.restoreGState()

    // Violet gradient (light top-left → deep bottom-right) plus a soft highlight.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let linear = CGGradient(colorsSpace: space, colors: [color(0x8F88FF), color(0x5146E5), color(0x3328B8)] as CFArray,
                            locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(linear, start: CGPoint(x: 160, y: 924), end: CGPoint(x: 880, y: 100), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 820), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 820), endRadius: 520, options: [])
    ctx.restoreGState()

    func card(center: CGPoint, size: CGSize, angle: CGFloat, fill: CGColor, shadow: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle * .pi / 180)
        let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x1B1464, shadow))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 48, cornerHeight: 48, transform: nil))
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Back card (tilted, translucent) and front card.
    card(center: CGPoint(x: 540, y: 575), size: CGSize(width: 480, height: 320), angle: 9, fill: color(0xFFFFFF, 0.5), shadow: 0.18)
    card(center: CGPoint(x: 500, y: 470), size: CGSize(width: 520, height: 350), angle: -4, fill: color(0xFFFFFF), shadow: 0.35)

    // Check mark on the front card.
    ctx.saveGState()
    ctx.translateBy(x: 500, y: 470)
    ctx.rotate(by: -4 * .pi / 180)
    let check = CGMutablePath()
    check.move(to: CGPoint(x: -105, y: 2))
    check.addLine(to: CGPoint(x: -30, y: -72))
    check.addLine(to: CGPoint(x: 118, y: 86))
    ctx.addPath(check)
    ctx.setLineWidth(52)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(color(0x5146E5))
    ctx.strokePath()
    ctx.restoreGState()
}

func render(pixels: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "icon", code: 1)
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    draw(ctx)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 2)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 3) }
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <AppIcon.appiconset>\n".utf8))
    exit(2)
}
let dir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale, to: dir.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: dir.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(dir.path)")
