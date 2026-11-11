// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Meercat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Meercat"),
        .executableTarget(name: "BSDetector"),  // live call fact-checker; needs macOS 26 at runtime
    ],
    swiftLanguageModes: [.v5]
)
