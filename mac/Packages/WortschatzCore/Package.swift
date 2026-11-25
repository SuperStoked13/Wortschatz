// swift-tools-version: 6.0
// WortschatzCore: platform-independent logic of the Wortschatz Mac app (a faithful port of the
// web app's src/core, src/lib, src/import/layout.js and src/store). No UI code lives here.
// WortschatzImport: the native file importers (text files, PDFKit, Vision OCR) built on top of it.
// Both modules ship in the WortschatzCore library product, so the app links them without changes
// to its project file.
import PackageDescription

let coreSettings: [SwiftSetting] = []

let package = Package(
    name: "WortschatzCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WortschatzCore", targets: ["WortschatzCore", "WortschatzImport"]),
    ],
    targets: [
        .target(
            name: "WortschatzCore",
            path: "Sources/WortschatzCore",
            swiftSettings: coreSettings
        ),
        .target(
            name: "WortschatzImport",
            dependencies: ["WortschatzCore"],
            path: "Sources/WortschatzImport"
        ),
        .testTarget(
            name: "WortschatzCoreTests",
            dependencies: ["WortschatzCore"],
            path: "Tests/WortschatzCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: coreSettings
        ),
        .testTarget(
            name: "WortschatzImportTests",
            dependencies: ["WortschatzImport", "WortschatzCore"],
            path: "Tests/WortschatzImportTests",
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
