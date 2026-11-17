// swift-tools-version:5.9
//
// ItmzKit: lossless reader/writer for iThoughts (.itmz) mind map files.
// Foundation + Compression only, no third-party dependencies.
//
// The same source files are compiled directly into the MyThoughts app target
// (see the "ItmzKit" group in MyThoughts.xcodeproj); this package exists so
// the format layer can be tested on its own:
//
//     cd ItmzKit && swift test
//     ITMZ_SAMPLES=~/Desktop/iThoughts-main swift test   # also round-trip real maps
//
import PackageDescription

let package = Package(
    name: "ItmzKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ItmzKit", targets: ["ItmzKit"])
    ],
    targets: [
        .target(name: "ItmzKit"),
        .testTarget(name: "ItmzKitTests", dependencies: ["ItmzKit"])
    ]
)
