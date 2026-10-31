// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LightNote", platforms: [.macOS(.v15)],
    products: [.library(name: "LightNoteCore", targets: ["LightNoteCore"])],
    targets: [
        .target(name: "LightNoteCore"),
        .testTarget(name: "LightNoteCoreTests", dependencies: ["LightNoteCore"])
    ]
)
