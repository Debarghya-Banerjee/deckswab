// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Deckswab",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Deckswab"),
    ],
    swiftLanguageModes: [.v5]
)
